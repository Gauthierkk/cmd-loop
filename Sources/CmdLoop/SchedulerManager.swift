import Foundation

/// Unifies the two local scheduling backends (cron via `CrontabManager`, launchd
/// via `LaunchDManager`) behind one interface. The UI talks only to this facade;
/// it merges jobs from both sources of truth and routes each operation to the
/// backend that owns the job.
final class SchedulerManager {
    static let shared = SchedulerManager()
    private init() {}

    /// Merges every job cmdloop can see: managed jobs (both backends) from config,
    /// external cron entries from the crontab, and external launchd agents from
    /// `~/Library/LaunchAgents`.
    func loadAllJobs() -> [CronJob] {
        // CrontabManager returns managed cron jobs, external cron entries, and any
        // disabled managed job (either backend). Enabled managed launchd jobs live
        // only in their plists, so they aren't in that list — add them from config.
        var jobs = CrontabManager.shared.loadAllJobs()
        var seen = Set(jobs.map { $0.id })

        for config in ConfigManager.shared.load()
        where config.backend == .launchd && config.isEnabled && !seen.contains(config.id) {
            jobs.append(config)
            seen.insert(config.id)
        }

        for external in LaunchDManager.shared.loadExternalJobs() where !seen.contains(external.id) {
            jobs.append(external)
            seen.insert(external.id)
        }

        // Run history is the most accurate last-run source (it includes scheduled
        // runs that happened while the app was closed). One pass over the merged
        // list — each check lists that job's log directory.
        for i in jobs.indices {
            if let latest = RunLogStore.shared.latestRunDate(for: jobs[i]),
               latest > (jobs[i].lastRunTime ?? .distantPast) {
                jobs[i].lastRunTime = latest
            }
        }

        return jobs
    }

    /// Persists and reconciles managed jobs across both backends. Cron rewrites the
    /// cmdloop crontab block; launchd writes/loads enabled agents and unloads +
    /// removes disabled ones.
    func syncManaged(_ jobs: [CronJob]) {
        CrontabManager.shared.sync(jobs)
        LaunchDManager.shared.syncManaged(jobs)
    }

    /// Runs a job immediately in the background — backend-agnostic direct shell
    /// execution, recorded as a manual run.
    func runNow(_ job: CronJob, onOutput: ((String) -> Void)? = nil) {
        CrontabManager.shared.runNow(job, onOutput: onOutput)
    }

    /// Removes a managed job's scheduler entry. Cron is handled by the subsequent
    /// re-sync (which rewrites the block without the deleted job); launchd needs an
    /// explicit plist removal since each job is its own file.
    func deleteManaged(_ job: CronJob) {
        if job.backend == .launchd {
            LaunchDManager.shared.remove(job)
        }
    }

    // MARK: - External entries

    func removeExternal(_ job: CronJob) {
        switch job.backend {
        case .cron:
            CrontabManager.shared.removeExternalEntry(cron: job.cronExpression, command: job.command)
        case .launchd:
            if let ref = LaunchDManager.shared.externalAgents[job.id] {
                LaunchDManager.shared.removeExternalAgent(ref: ref)
            }
        }
    }

    /// Rewrites an external launchd agent's command/schedule in place. Returns the
    /// stable name-store key so the caller can persist the display name.
    func updateExternalLaunchd(_ job: CronJob, command: String, schedule: JobSchedule) {
        guard let ref = LaunchDManager.shared.externalAgents[job.id] else { return }
        LaunchDManager.shared.updateExternalAgent(ref: ref, command: command, schedule: schedule)
    }

    // MARK: - Adoption (prototype)

    /// Adopts a pre-existing external entry (a crontab line or a LaunchAgent added
    /// outside cmdloop) as a cmdloop-managed job, so each scheduled run is captured
    /// in run history. The command itself is unchanged — the managed writers wrap
    /// it with the per-run log redirection (`CrontabManager.shellLine` /
    /// `LaunchDManager.wrappedCommand`), which is what "wraps it so it logs".
    ///
    /// The job's id is preserved. External ids are derived from stable content
    /// (cron+command, or the launchd label), so reusing the id carries over any
    /// logs already recorded for that entry and keeps the display name from
    /// `ExternalNameStore`.
    ///
    /// For launchd, the original agent's extra keys — EnvironmentVariables,
    /// WorkingDirectory, Nice, etc. — are captured onto the managed job
    /// (`launchdExtrasData`) so they're reproduced on every sync, including after a
    /// disable→enable that regenerates the plist from scratch.
    @discardableResult
    func adoptExternal(_ job: CronJob) -> CronJob? {
        guard job.source == .external else { return nil }
        var managed = job
        managed.source = .managed
        // For launchd, capture the original agent's extra keys onto the job before
        // the external plist is torn down.
        if job.backend == .launchd,
           let ref = LaunchDManager.shared.externalAgents[job.id],
           let dict = LaunchDManager.shared.plistDict(at: ref.url) {
            managed.launchdExtrasData = LaunchDManager.shared.extractExtrasData(fromPlist: dict)
        }
        // Drop the original external entry first so the command isn't scheduled
        // twice, then persist + sync the managed form (which adds log redirection).
        removeExternal(job)
        var jobs = ConfigManager.shared.load()
        jobs.append(managed)
        ConfigManager.shared.save(jobs)
        syncManaged(jobs)
        return managed
    }

    /// Adopts every external entry cmdloop can currently see, in one pass. Returns
    /// the number adopted. Idempotent: entries already managed aren't external, so
    /// re-running only picks up newly-appeared entries. Shells out to
    /// crontab/launchctl — call off the main thread.
    @discardableResult
    func adoptAllExternal() -> Int {
        // Snapshot the external set once. loadAllJobs() also (re)populates
        // LaunchDManager.externalAgents, which adoptExternal needs for launchd.
        let externals = loadAllJobs().filter { $0.source == .external }
        for job in externals { adoptExternal(job) }
        return externals.count
    }

    /// If the auto-adopt setting is on, runs `adoptAllExternal` on a background
    /// queue and refreshes the UI when anything changed. Safe to call from the main
    /// thread (e.g. a timer or the settings toggle).
    func autoAdoptScrape() {
        guard SettingsStore.shared.autoAdoptExternal else { return }
        DispatchQueue.global(qos: .utility).async {
            let adopted = self.adoptAllExternal()
            if adopted > 0 {
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .jobsDidChange, object: nil)
                }
            }
        }
    }

    /// Inverse of `adoptExternal`: hands a managed job back to plain cron/launchd
    /// and drops it from cmdloop's config. The schedule keeps running; cmdloop just
    /// stops owning it (and stops logging its runs). The job's display name is
    /// preserved in `ExternalNameStore` so it still reads sensibly as an external
    /// entry. Returns the job re-derived as external, or nil if it wasn't managed.
    @discardableResult
    func releaseManaged(_ job: CronJob) -> CronJob? {
        guard job.source == .managed else { return nil }

        // Remove it from config + reconcile backends. For cron this rewrites the
        // crontab block without the job; for launchd it unloads/removes the plist.
        var jobs = ConfigManager.shared.load()
        jobs.removeAll { $0.id == job.id }
        ConfigManager.shared.save(jobs)

        switch job.backend {
        case .cron:
            // Re-sync the (now shorter) cmdloop block, then append a plain,
            // unmarked crontab line carrying the raw command. Always materialize the
            // entry (external entries have no disabled state in cmdloop's model), so
            // releasing never silently drops the command.
            CrontabManager.shared.sync(jobs)
            CrontabManager.shared.addExternalEntry(cron: job.cronExpression, command: job.singleLineCommand)
            let key = ExternalNameStore.key(cron: job.cronExpression, command: job.singleLineCommand)
            ExternalNameStore.shared.setName(job.name, for: key)
        case .launchd:
            LaunchDManager.shared.syncManaged(jobs) // no-op for this job; keeps others in sync
            if let label = LaunchDManager.shared.releaseToExternal(job) {
                ExternalNameStore.shared.setName(job.name, for: LaunchDManager.shared.externalNameKey(label: label))
            }
        }
        return nil
    }
}

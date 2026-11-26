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
        var jobs = ConfigManager.shared.load()
        // External ids are derived from content, so an entry re-added after an
        // earlier adoption (or already adopted by an overlapping pass) has the id
        // of a job in config. Leave it alone: duplicate ids would lose a job and
        // trap in `CrontabManager.loadAllJobs`.
        if let existing = jobs.first(where: { $0.id == job.id }) {
            // A launchd agent that is back on disk under its original label was
            // re-created by its owner (an app or installer), and now runs next to
            // the adopted copy. Give it back: drop the managed copy and stop
            // adopting it. Run history is kept (same id).
            if job.backend == .launchd, existing.backend == .launchd,
               let ref = LaunchDManager.shared.externalAgents[job.id],
               FileManager.default.fileExists(atPath: ref.url.path) {
                jobs.removeAll { $0.id == job.id }
                ConfigManager.shared.save(jobs)
                LaunchDManager.shared.remove(existing)
                SettingsStore.shared.excludeFromAutoAdopt(job.id)
                NotificationCenter.default.post(name: .jobsDidChange, object: nil)
            }
            return nil
        }

        var managed = job
        managed.source = .managed
        switch job.backend {
        case .cron:
            // The crontab scan also surfaces non-job lines (`PATH=…`, `MAILTO=…`,
            // `@reboot …`) as external entries. Wrapping one would corrupt the
            // crontab, so only adopt a real five-field schedule with a command.
            guard isAdoptableCronEntry(job) else { return nil }
        case .launchd:
            // Capture the original agent's extra keys onto the job before the
            // external plist is torn down. Without the plist there is nothing to
            // adopt (and nothing `removeExternal` could remove).
            guard let ref = LaunchDManager.shared.externalAgents[job.id],
                  let dict = LaunchDManager.shared.plistDict(at: ref.url),
                  let command = LaunchDManager.shared.adoptionCommand(fromPlist: dict)
            else { return nil }
            managed.command = command
            managed.launchdExtrasData = LaunchDManager.shared.extractExtrasData(fromPlist: dict)
        }

        // Persist first and confirm the job is really on disk; only then drop the
        // original entry. A failed save must never cost the user their schedule.
        // The managed form is synced after the removal, so the command is never
        // scheduled twice.
        jobs.append(managed)
        ConfigManager.shared.save(jobs)
        guard ConfigManager.shared.load().contains(where: { $0.id == managed.id }) else { return nil }
        removeExternal(job)
        syncManaged(jobs)
        return managed
    }

    /// Whether an external crontab entry is a plain `m h dom mon dow command` job.
    private func isAdoptableCronEntry(_ job: CronJob) -> Bool {
        guard !job.command.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        let fieldChars = CharacterSet(charactersIn:
            "0123456789*/,-abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
        let fields = job.cronExpression.split(separator: " ", omittingEmptySubsequences: false)
        return fields.count == 5 && fields.allSatisfy { field in
            !field.isEmpty && field.unicodeScalars.allSatisfy { fieldChars.contains($0) }
        }
    }

    /// Runs `work` on the main thread. Config, the crontab and
    /// `LaunchDManager.externalAgents` are all read and written from the main
    /// thread by the UI, so adoption does its mutations there too instead of
    /// racing them (or another adoption pass) from a background queue.
    private func onMain<T>(_ work: () -> T) -> T {
        Thread.isMainThread ? work() : DispatchQueue.main.sync(execute: work)
    }

    /// Adopts every external entry cmdloop can currently see, in one pass. Returns
    /// the number actually adopted. Idempotent: entries already managed aren't
    /// external, so re-running only picks up newly-appeared entries. Call off the
    /// main thread: each entry is adopted in its own hop onto the main thread, so
    /// passes that overlap (launch, timer, settings toggle) interleave safely and
    /// the UI stays responsive between entries.
    @discardableResult
    func adoptAllExternal() -> Int {
        // Snapshot the external set once. loadAllJobs() also (re)populates
        // LaunchDManager.externalAgents, which adoptExternal needs for launchd.
        // Released entries (and agents handed back to their owner) are excluded,
        // so Release sticks while auto-adopt is on.
        let externals = onMain {
            let excluded = SettingsStore.shared.autoAdoptExcluded
            return self.loadAllJobs().filter {
                $0.source == .external && !excluded.contains($0.id.uuidString)
            }
        }
        var adopted = 0
        for job in externals {
            if onMain({ self.adoptExternal(job) }) != nil { adopted += 1 }
        }
        return adopted
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
            // cron ends a command at an unescaped `%`; the managed wrapper escaped
            // them, so the raw line must too.
            let command = job.singleLineCommand.replacingOccurrences(
                of: #"(?<!\\)%"#, with: #"\\%"#, options: .regularExpression)
            CrontabManager.shared.addExternalEntry(cron: job.cronExpression, command: command)
            let key = ExternalNameStore.key(cron: job.cronExpression, command: command)
            ExternalNameStore.shared.setName(job.name, for: key)
            SettingsStore.shared.excludeFromAutoAdopt(deterministicUUID(from: key))
        case .launchd:
            LaunchDManager.shared.syncManaged(jobs) // no-op for this job; keeps others in sync
            if let label = LaunchDManager.shared.releaseToExternal(job) {
                let key = LaunchDManager.shared.externalNameKey(label: label)
                ExternalNameStore.shared.setName(job.name, for: key)
                SettingsStore.shared.excludeFromAutoAdopt(deterministicUUID(from: key))
            }
        }
        return nil
    }
}

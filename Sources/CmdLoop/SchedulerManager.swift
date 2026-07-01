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
        // runs that happened while the app was closed). Enrich the launchd jobs we
        // just added; CrontabManager already enriched the rest (idempotent).
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
}

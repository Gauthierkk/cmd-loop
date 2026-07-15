import Foundation


// MARK: - Crontab Manager

extension Notification.Name {
    static let jobsDidChange = Notification.Name("jobsDidChange")
}

class CrontabManager {
    static let shared = CrontabManager()
    private init() {}

    private let marker = "# cmdloop:"

    /// Jobs currently executing via "Run now". Main-thread only.
    private(set) var runningJobIDs: Set<UUID> = []

    /// Most recent manual-run outcome per job this session. Covers external
    /// jobs, whose status has nowhere to persist. Main-thread only.
    private(set) var runtimeStatuses: [UUID: RunStatus] = [:]

    /// Reads crontab and returns all entries as CronJob objects.
    /// cmdloop-managed entries get their name from config. External entries get "cronjob".
    func loadAllJobs() -> [CronJob] {
        let lines = readCrontab()
        let configJobs = ConfigManager.shared.load()
        let configMap = Dictionary(uniqueKeysWithValues: configJobs.map { ($0.id, $0) })

        var jobs: [CronJob] = []
        var i = 0
        while i < lines.count {
            let line = lines[i]
            if line.hasPrefix(marker) {
                // cmdloop-managed entry
                let uuidStr = String(line.dropFirst(marker.count))
                i += 1
                if i < lines.count, let uuid = UUID(uuidString: uuidStr) {
                    let cronLine = lines[i]
                    if let config = configMap[uuid] {
                        jobs.append(config)
                    } else {
                        // cmdloop marker but no config — parse what we can
                        let parsed = parseCronLine(cronLine)
                        jobs.append(CronJob(id: uuid, name: "cronjob", command: parsed.command, cronExpression: parsed.cron))
                    }
                }
            } else if !line.isEmpty, !line.hasPrefix("#") {
                // External cron entry — not owned by cmdloop. Give it a stable id
                // derived from its content and apply any user-assigned name.
                let parsed = parseCronLine(line)
                if !parsed.cron.isEmpty {
                    let key = ExternalNameStore.key(cron: parsed.cron, command: parsed.command)
                    let name = ExternalNameStore.shared.name(for: key) ?? "cronjob"
                    jobs.append(CronJob(
                        id: deterministicUUID(from: key),
                        name: name,
                        command: parsed.command,
                        cronExpression: parsed.cron,
                        isEnabled: true,
                        source: .external
                    ))
                }
            }
            i += 1
        }

        // Also include disabled cmdloop jobs (not in crontab but in config)
        let activeIds = Set(jobs.compactMap { $0.id })
        for config in configJobs where !config.isEnabled && !activeIds.contains(config.id) {
            jobs.append(config)
        }

        // Last-run enrichment from run history happens once for the merged list
        // in SchedulerManager.loadAllJobs.
        return jobs
    }

    private func parseCronLine(_ line: String) -> (cron: String, command: String) {
        let parts = line.split(separator: " ", maxSplits: 5, omittingEmptySubsequences: false)
        guard parts.count >= 6 else { return (line, "") }
        let cron = parts[0..<5].joined(separator: " ")
        let command = String(parts[5...].joined(separator: " "))
        return (cron, command)
    }

    func sync(_ jobs: [CronJob]) {
        // Read existing crontab, preserve non-cmdloop entries
        var lines = readCrontab()
        lines = filterOutCmdloopEntries(lines)

        // Add enabled cron-backed jobs (launchd jobs are handled by LaunchDManager)
        for job in jobs where job.isEnabled && job.backend == .cron {
            lines.append("\(marker)\(job.id.uuidString)")
            lines.append("\(job.cronExpression) \(shellLine(for: job))")
        }

        writeCrontab(lines)
    }

    /// Appends a plain, unmarked crontab line (used when releasing a managed job
    /// back to a normal cron entry). No `# cmdloop:` marker and no log-redirection
    /// wrapper, so cmdloop treats it as external and stops recording its runs.
    func addExternalEntry(cron: String, command: String) {
        var lines = readCrontab()
        while lines.last?.isEmpty == true { lines.removeLast() }
        lines.append("\(cron) \(command)")
        writeCrontab(lines)
    }

    /// Removes a single external (non-cmdloop) entry from the crontab, leaving all
    /// cmdloop-managed entries and other external lines intact.
    func removeExternalEntry(cron: String, command: String) {
        writeCrontab(rewritingFirstExternalEntry(matching: cron, command: command, replacement: nil))
    }

    /// Replaces a single external (non-cmdloop) entry's schedule and/or command in
    /// place, preserving its position and all other entries.
    func updateExternalEntry(oldCron: String, oldCommand: String, newCron: String, newCommand: String) {
        writeCrontab(rewritingFirstExternalEntry(
            matching: oldCron, command: oldCommand, replacement: "\(newCron) \(newCommand)"
        ))
    }

    /// Reads the crontab and rewrites the first external entry matching the given
    /// cron + command: `replacement` nil drops the line, otherwise replaces it in
    /// place. cmdloop marker+entry pairs are never candidates.
    private func rewritingFirstExternalEntry(
        matching cron: String, command: String, replacement: String?
    ) -> [String] {
        var result: [String] = []
        var skipNext = false
        var done = false
        for line in readCrontab() {
            if line.hasPrefix(marker) {
                skipNext = true
                result.append(line)
                continue
            }
            if skipNext {
                skipNext = false
                result.append(line)
                continue
            }
            if !done, !line.isEmpty, !line.hasPrefix("#") {
                let parsed = parseCronLine(line)
                if parsed.cron == cron && parsed.command == command {
                    done = true
                    if let replacement { result.append(replacement) }
                    continue
                }
            }
            result.append(line)
        }
        while result.last?.isEmpty == true { result.removeLast() }
        return result
    }

    func runNow(_ job: CronJob, onOutput: ((String) -> Void)? = nil) {
        let logFile = RunLogStore.shared.newManualRunFile(for: job)
        let logHandle = try? FileHandle(forWritingTo: logFile)
        logHandle?.seekToEndOfFile()
        logHandle?.write("$ \(job.command)\n".data(using: .utf8)!)

        runningJobIDs.insert(job.id)
        NotificationCenter.default.post(name: .jobsDidChange, object: nil)

        DispatchQueue.global(qos: .utility).async {
            let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            let process = Process()
            process.executableURL = URL(fileURLWithPath: shell)
            process.arguments = ["-l", "-c", job.command]

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            // Stream output as it arrives
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                logHandle?.write(data)
                if let text = String(data: data, encoding: .utf8) {
                    DispatchQueue.main.async { onOutput?(text) }
                }
            }

            var status = RunStatus.failure
            do {
                try process.run()
                process.waitUntilExit()
                status = process.terminationStatus == 0 ? .success : .failure
            } catch {
                logHandle?.write("cmdloop: failed to launch: \(error)\n".data(using: .utf8)!)
            }

            // Read any remaining data
            pipe.fileHandleForReading.readabilityHandler = nil
            let remaining = pipe.fileHandleForReading.readDataToEndOfFile()
            if !remaining.isEmpty {
                logHandle?.write(remaining)
                if let text = String(data: remaining, encoding: .utf8) {
                    DispatchQueue.main.async { onOutput?(text) }
                }
            }
            logHandle?.closeFile()

            DispatchQueue.main.async {
                self.runningJobIDs.remove(job.id)
                self.runtimeStatuses[job.id] = status
                var jobs = ConfigManager.shared.load()
                if let idx = jobs.firstIndex(where: { $0.id == job.id }) {
                    jobs[idx].lastRunTime = Date()
                    jobs[idx].lastRunStatus = status
                    ConfigManager.shared.save(jobs)
                }
                RunLogStore.shared.prune()
                NotificationCenter.default.post(name: .jobsDidChange, object: nil)
            }
        }
    }

    // MARK: - Private

    private func shellLine(for job: CronJob) -> String {
        let escaped = job.singleLineCommand
            .replacingOccurrences(of: "'", with: "'\\''")
            // cron treats an unescaped % as end-of-command (rest becomes stdin),
            // which would truncate the command and lose its output.
            .replacingOccurrences(of: "%", with: "\\%")
        return "/bin/zsh -l -c '\(escaped)' \(RunLogStore.shared.cronRedirection(for: job))"
    }

    private func readCrontab() -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/crontab")
        process.arguments = ["-l"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        if output.isEmpty { return [] }
        return output.components(separatedBy: "\n")
    }

    private func filterOutCmdloopEntries(_ lines: [String]) -> [String] {
        var result: [String] = []
        var skipNext = false
        for line in lines {
            if line.hasPrefix(marker) {
                skipNext = true
                continue
            }
            if skipNext {
                skipNext = false
                continue
            }
            result.append(line)
        }
        // Remove trailing empty lines
        while result.last?.isEmpty == true { result.removeLast() }
        return result
    }

    private func writeCrontab(_ lines: [String]) {
        var content = lines.joined(separator: "\n")
        if !content.isEmpty { content += "\n" }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/crontab")
        process.arguments = ["-"]
        let pipe = Pipe()
        process.standardInput = pipe
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        pipe.fileHandleForWriting.write(content.data(using: .utf8)!)
        pipe.fileHandleForWriting.closeFile()
        process.waitUntilExit()
    }
}

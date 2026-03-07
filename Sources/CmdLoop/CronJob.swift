import Foundation

// MARK: - Data Model

struct CronJob: Codable, Identifiable {
    var id: UUID
    var name: String
    var command: String
    var cronExpression: String
    var isEnabled: Bool
    var lastRunTime: Date?

    init(id: UUID = UUID(), name: String, command: String, cronExpression: String, isEnabled: Bool = true, lastRunTime: Date? = nil) {
        self.id = id
        self.name = name
        self.command = command
        self.cronExpression = cronExpression
        self.isEnabled = isEnabled
        self.lastRunTime = lastRunTime
    }
}

// MARK: - Config Persistence

class ConfigManager {
    static let shared = ConfigManager()
    private init() {}

    private var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/cmd-loop/config.json")
    }

    func load() -> [CronJob] {
        guard let data = try? Data(contentsOf: configURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([CronJob].self, from: data)) ?? []
    }

    func save(_ jobs: [CronJob]) {
        let dir = configURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(jobs) else { return }
        try? data.write(to: configURL, options: .atomic)
    }
}

// MARK: - Cron Parser

enum CronError: Error {
    case invalidFormat
    case invalidField(String)
}

struct CronParser {
    let minutes: Set<Int>
    let hours: Set<Int>
    let daysOfMonth: Set<Int>
    let months: Set<Int>
    let daysOfWeek: Set<Int>

    init(_ expression: String) throws {
        let fields = expression.trimmingCharacters(in: .whitespaces).split(separator: " ")
        guard fields.count == 5 else { throw CronError.invalidFormat }
        minutes = try Self.parseField(String(fields[0]), range: 0...59)
        hours = try Self.parseField(String(fields[1]), range: 0...23)
        daysOfMonth = try Self.parseField(String(fields[2]), range: 1...31)
        months = try Self.parseField(String(fields[3]), range: 1...12)
        daysOfWeek = try Self.parseField(String(fields[4]), range: 0...6)
    }

    static func parseField(_ field: String, range: ClosedRange<Int>) throws -> Set<Int> {
        if field == "*" {
            return Set(range)
        }
        if field.hasPrefix("*/") {
            guard let step = Int(field.dropFirst(2)), step > 0 else {
                throw CronError.invalidField(field)
            }
            return Set(stride(from: range.lowerBound, through: range.upperBound, by: step))
        }
        var result = Set<Int>()
        for part in field.split(separator: ",") {
            if part.contains("-") {
                let bounds = part.split(separator: "-")
                guard bounds.count == 2,
                      let lo = Int(bounds[0]), let hi = Int(bounds[1]),
                      range.contains(lo), range.contains(hi), lo <= hi
                else { throw CronError.invalidField(field) }
                result.formUnion(lo...hi)
            } else {
                guard let val = Int(part), range.contains(val)
                else { throw CronError.invalidField(field) }
                result.insert(val)
            }
        }
        return result
    }

}

// MARK: - Crontab Manager

extension Notification.Name {
    static let jobsDidChange = Notification.Name("jobsDidChange")
}

class CrontabManager {
    static let shared = CrontabManager()
    private init() {}

    private let marker = "# cmdloop:"

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
                // External cron entry
                let parsed = parseCronLine(line)
                if !parsed.cron.isEmpty {
                    jobs.append(CronJob(name: "cronjob", command: parsed.command, cronExpression: parsed.cron, isEnabled: true))
                }
            }
            i += 1
        }

        // Also include disabled cmdloop jobs (not in crontab but in config)
        let activeIds = Set(jobs.compactMap { $0.id })
        for config in configJobs where !config.isEnabled && !activeIds.contains(config.id) {
            jobs.append(config)
        }

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

        // Add enabled jobs
        for job in jobs where job.isEnabled {
            lines.append("\(marker)\(job.id.uuidString)")
            lines.append("\(job.cronExpression) \(shellLine(for: job))")
        }

        writeCrontab(lines)
    }

    func runNow(_ job: CronJob, onOutput: ((String) -> Void)? = nil) {
        let logFile = self.logFileURL(for: job)
        self.ensureLogFile(logFile)
        let logHandle = try? FileHandle(forWritingTo: logFile)
        logHandle?.seekToEndOfFile()
        logHandle?.write("\n--- \(Date()) [manual] ---\n".data(using: .utf8)!)

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

            try? process.run()
            process.waitUntilExit()

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
                var jobs = ConfigManager.shared.load()
                if let idx = jobs.firstIndex(where: { $0.id == job.id }) {
                    jobs[idx].lastRunTime = Date()
                    ConfigManager.shared.save(jobs)
                }
                NotificationCenter.default.post(name: .jobsDidChange, object: nil)
            }
        }
    }

    // MARK: - Private

    private func shellLine(for job: CronJob) -> String {
        let escaped = job.command.replacingOccurrences(of: "'", with: "'\\''")
        let logFile = logFileURL(for: job).path
        return "/bin/zsh -l -c '\(escaped)' >> '\(logFile)' 2>&1"
    }

    private func logFileURL(for job: CronJob) -> URL {
        let logDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/cmd-loop/logs")
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        let safeName = job.name.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
        return logDir.appendingPathComponent("\(safeName)-\(job.id.uuidString).log")
    }

    private func ensureLogFile(_ url: URL) {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
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

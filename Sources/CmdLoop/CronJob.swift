import Foundation
import CryptoKit

// MARK: - Data Model

/// Where a job came from. `managed` jobs are owned by cmdloop (tagged with a
/// `# cmdloop:<uuid>` marker and persisted in config.json). `external` jobs were
/// added to the crontab outside of cmdloop; we only track a display name for them.
enum JobSource {
    case managed
    case external
}

/// Outcome of a job's most recent manual run (cron runs happen outside the app,
/// so their exit status isn't observable).
enum RunStatus: String, Codable {
    case success
    case failure
}

struct CronJob: Codable, Identifiable {
    var id: UUID
    var name: String
    var command: String
    var cronExpression: String
    var isEnabled: Bool
    var lastRunTime: Date?
    var lastRunStatus: RunStatus?

    /// Transient — not persisted. Defaults to `.managed` so decoded config jobs
    /// are always treated as cmdloop-owned.
    var source: JobSource = .managed

    private enum CodingKeys: String, CodingKey {
        case id, name, command, cronExpression, isEnabled, lastRunTime, lastRunStatus
    }

    init(id: UUID = UUID(), name: String, command: String, cronExpression: String, isEnabled: Bool = true, lastRunTime: Date? = nil, lastRunStatus: RunStatus? = nil, source: JobSource = .managed) {
        self.id = id
        self.name = name
        self.command = command
        self.cronExpression = cronExpression
        self.isEnabled = isEnabled
        self.lastRunTime = lastRunTime
        self.lastRunStatus = lastRunStatus
        self.source = source
    }
}

/// Derives a stable UUID from arbitrary text so external crontab entries keep the
/// same identity across reloads (used for SwiftUI-style diffing and name lookups).
func deterministicUUID(from string: String) -> UUID {
    let digest = Insecure.MD5.hash(data: Data(string.utf8))
    let bytes = [UInt8](digest)
    return bytes.withUnsafeBufferPointer { NSUUID(uuidBytes: $0.baseAddress!) as UUID }
}

// MARK: - External Name Store

/// Persists user-assigned display names for cron entries that cmdloop does not
/// own. Keyed by the entry's cron expression + command so a name survives reloads
/// without rewriting the user's crontab.
final class ExternalNameStore {
    static let shared = ExternalNameStore()

    private var names: [String: String]

    private init() {
        names = Self.loadFromDisk()
    }

    private static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/cmd-loop/names.json")
    }

    static func key(cron: String, command: String) -> String {
        cron + "\u{1}" + command
    }

    func name(for key: String) -> String? {
        names[key]
    }

    func setName(_ name: String, for key: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            names.removeValue(forKey: key)
        } else {
            names[key] = trimmed
        }
        persist()
    }

    private static func loadFromDisk() -> [String: String] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    private func persist() {
        let dir = Self.url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(names) else { return }
        try? data.write(to: Self.url, options: .atomic)
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

        // Run history is the most accurate last-run source — it includes cron
        // runs that happened while the app was closed, which config.json misses.
        for i in jobs.indices {
            if let latest = RunLogStore.shared.latestRunDate(for: jobs[i]),
               latest > (jobs[i].lastRunTime ?? .distantPast) {
                jobs[i].lastRunTime = latest
            }
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

    /// Removes a single external (non-cmdloop) entry from the crontab, leaving all
    /// cmdloop-managed entries and other external lines intact.
    func removeExternalEntry(cron: String, command: String) {
        var lines = readCrontab()
        var result: [String] = []
        var skipNext = false
        var removed = false
        for line in lines {
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
            if !removed, !line.isEmpty, !line.hasPrefix("#") {
                let parsed = parseCronLine(line)
                if parsed.cron == cron && parsed.command == command {
                    removed = true
                    continue
                }
            }
            result.append(line)
        }
        while result.last?.isEmpty == true { result.removeLast() }
        lines = result
        writeCrontab(lines)
    }

    /// Replaces a single external (non-cmdloop) entry's schedule and/or command in
    /// place, preserving its position and all other entries.
    func updateExternalEntry(oldCron: String, oldCommand: String, newCron: String, newCommand: String) {
        let lines = readCrontab()
        var result: [String] = []
        var skipNext = false
        var replaced = false
        for line in lines {
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
            if !replaced, !line.isEmpty, !line.hasPrefix("#") {
                let parsed = parseCronLine(line)
                if parsed.cron == oldCron && parsed.command == oldCommand {
                    result.append("\(newCron) \(newCommand)")
                    replaced = true
                    continue
                }
            }
            result.append(line)
        }
        while result.last?.isEmpty == true { result.removeLast() }
        writeCrontab(result)
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
        // A raw newline would split the crontab entry into invalid lines, so
        // join multi-line commands into one shell statement.
        let flattened = job.command
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "; ")
        let escaped = flattened
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

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

    func nextDate(after date: Date = Date()) -> Date? {
        let calendar = Calendar.current
        var comps = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        comps.second = 0
        guard let base = calendar.date(from: comps),
              var candidate = calendar.date(byAdding: .minute, value: 1, to: base)
        else { return nil }

        for _ in 0..<525_600 {
            let c = calendar.dateComponents([.minute, .hour, .day, .month, .weekday], from: candidate)
            let dow = c.weekday! - 1 // Calendar: 1=Sunday → 0=Sunday
            if minutes.contains(c.minute!) &&
               hours.contains(c.hour!) &&
               daysOfMonth.contains(c.day!) &&
               months.contains(c.month!) &&
               daysOfWeek.contains(dow) {
                return candidate
            }
            candidate = calendar.date(byAdding: .minute, value: 1, to: candidate)!
        }
        return nil
    }
}

// MARK: - Scheduler

extension Notification.Name {
    static let jobsDidChange = Notification.Name("jobsDidChange")
}

class Scheduler {
    static let shared = Scheduler()
    private init() {}
    private var timers: [UUID: Timer] = [:]

    func scheduleAll(_ jobs: [CronJob]) {
        timers.values.forEach { $0.invalidate() }
        timers.removeAll()
        for job in jobs where job.isEnabled {
            scheduleNext(job)
        }
    }

    private func scheduleNext(_ job: CronJob) {
        guard let cron = try? CronParser(job.cronExpression),
              let nextDate = cron.nextDate()
        else { return }

        let interval = nextDate.timeIntervalSinceNow
        guard interval > 0 else { return }

        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            self?.executeJob(job)
        }
        RunLoop.main.add(timer, forMode: .common)
        timers[job.id] = timer
    }

    func runNow(_ job: CronJob) {
        executeJob(job, reschedule: false)
    }

    private func executeJob(_ job: CronJob, reschedule: Bool = true) {
        DispatchQueue.global(qos: .utility).async {
            let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            let process = Process()
            process.executableURL = URL(fileURLWithPath: shell)
            process.arguments = ["-l", "-c", job.command]

            // Log output to ~/.config/cmd-loop/logs/<id>.log
            let logDir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".config/cmd-loop/logs")
            try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
            let safeName = job.name.lowercased()
                .replacingOccurrences(of: " ", with: "-")
                .filter { $0.isLetter || $0.isNumber || $0 == "-" }
            let logFile = logDir.appendingPathComponent("\(safeName)-\(job.id.uuidString).log")

            if !FileManager.default.fileExists(atPath: logFile.path) {
                FileManager.default.createFile(atPath: logFile.path, contents: nil)
            }
            if let fh = try? FileHandle(forWritingTo: logFile) {
                fh.seekToEndOfFile()
                let header = "\n--- \(Date()) ---\n".data(using: .utf8)!
                fh.write(header)
                process.standardOutput = fh
                process.standardError = fh
                try? process.run()
                process.waitUntilExit()
                fh.closeFile()
            } else {
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                try? process.run()
                process.waitUntilExit()
            }

            DispatchQueue.main.async {
                var jobs = ConfigManager.shared.load()
                if let idx = jobs.firstIndex(where: { $0.id == job.id }) {
                    jobs[idx].lastRunTime = Date()
                    ConfigManager.shared.save(jobs)
                    if reschedule {
                        self.scheduleNext(jobs[idx])
                    }
                }
                NotificationCenter.default.post(name: .jobsDidChange, object: nil)
            }
        }
    }
}

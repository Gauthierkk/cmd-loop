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

/// Which local scheduler runs a job. Both are treated as sources of truth:
/// cron jobs live in the crontab, launchd jobs live in `~/Library/LaunchAgents`.
enum JobBackend: String, Codable {
    case cron
    case launchd
}

/// A job's schedule. Cron jobs carry a 5-field expression; launchd jobs carry
/// either a set of calendar intervals (`StartCalendarInterval`) or a plain
/// seconds interval (`StartInterval`).
enum JobSchedule: Codable, Equatable {
    case cron(String)
    case calendar([CalendarInterval])
    case interval(Int)

    private enum CodingKeys: String, CodingKey { case type, expression, intervals, seconds }
    private enum Kind: String, Codable { case cron, calendar, interval }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .type) {
        case .cron:     self = .cron(try c.decode(String.self, forKey: .expression))
        case .calendar: self = .calendar(try c.decode([CalendarInterval].self, forKey: .intervals))
        case .interval: self = .interval(try c.decode(Int.self, forKey: .seconds))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .cron(let e):
            try c.encode(Kind.cron, forKey: .type)
            try c.encode(e, forKey: .expression)
        case .calendar(let intervals):
            try c.encode(Kind.calendar, forKey: .type)
            try c.encode(intervals, forKey: .intervals)
        case .interval(let seconds):
            try c.encode(Kind.interval, forKey: .type)
            try c.encode(seconds, forKey: .seconds)
        }
    }
}

/// Best-effort translation of a schedule into an English phrase (e.g.
/// "every 5 minutes", "daily at 8:00"). Falls back to the raw form when the
/// pattern isn't one of the common cases.
enum CronEnglish {
    static func describe(_ expr: String) -> String? {
        let f = expr.split(separator: " ").map(String.init)
        guard f.count == 5 else { return nil }
        let (min, hour, dom, mon, dow) = (f[0], f[1], f[2], f[3], f[4])

        if min == "*" && hour == "*" && dom == "*" && mon == "*" && dow == "*" {
            return "every minute"
        }
        if min.hasPrefix("*/"), let n = Int(min.dropFirst(2)),
           hour == "*", dom == "*", mon == "*", dow == "*" {
            return "every \(n) minutes"
        }
        if hour.hasPrefix("*/"), let n = Int(hour.dropFirst(2)),
           min == "0", dom == "*", mon == "*", dow == "*" {
            return "every \(n) hours"
        }
        if let m = Int(min), hour == "*", dom == "*", mon == "*", dow == "*" {
            return "hourly at :\(pad(m))"
        }
        guard let m = Int(min), let h = Int(hour) else { return nil }
        let at = "\(h):\(pad(m))"
        if dom == "*", mon == "*", let day = weekdayName(dow) {
            return "every \(day) at \(at)"
        }
        if let day = Int(dom), mon == "*", dow == "*" {
            return "monthly on day \(day) at \(at)"
        }
        if dom == "*", mon == "*", dow == "*" {
            return "daily at \(at)"
        }
        return nil
    }

    static func pad(_ n: Int) -> String { String(format: "%02d", n) }

    static func weekdayName(_ s: String) -> String? {
        let names = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
        guard let n = Int(s) else { return nil }
        let idx = n == 7 ? 0 : n
        return names.indices.contains(idx) ? names[idx] : nil
    }
}

extension JobSchedule {
    /// A human-readable English phrase describing when the job runs.
    var englishFrequency: String {
        switch self {
        case .cron(let expr):
            return CronEnglish.describe(expr) ?? expr
        case .interval(let seconds):
            if seconds >= 3600, seconds % 3600 == 0 {
                let n = seconds / 3600
                return "every \(n) hour\(n == 1 ? "" : "s")"
            }
            if seconds >= 60, seconds % 60 == 0 {
                let n = seconds / 60
                return "every \(n) minute\(n == 1 ? "" : "s")"
            }
            return "every \(seconds) second\(seconds == 1 ? "" : "s")"
        case .calendar(let intervals):
            if intervals.count == 1 { return intervals[0].englishFrequency }
            return "\(intervals.count) times daily"
        }
    }

    /// Compact, human-readable summary shown in the job row.
    var displaySummary: String {
        switch self {
        case .cron(let expr):
            return expr
        case .interval(let seconds):
            if seconds % 3600 == 0 { return "every \(seconds / 3600)h" }
            if seconds % 60 == 0 { return "every \(seconds / 60) min" }
            return "every \(seconds)s"
        case .calendar(let intervals):
            return intervals.map { $0.cronLikeSummary }.joined(separator: " | ")
        }
    }
}

/// One launchd `StartCalendarInterval` dictionary. A nil field means "every"
/// (that field is omitted from the plist, so launchd matches all values).
struct CalendarInterval: Codable, Equatable {
    var minute: Int?
    var hour: Int?
    var day: Int?
    var weekday: Int?
    var month: Int?

    init(minute: Int? = nil, hour: Int? = nil, day: Int? = nil, weekday: Int? = nil, month: Int? = nil) {
        self.minute = minute
        self.hour = hour
        self.day = day
        self.weekday = weekday
        self.month = month
    }

    var isEmpty: Bool {
        minute == nil && hour == nil && day == nil && weekday == nil && month == nil
    }

    /// A cron-style rendering (minute hour day month weekday), with "*" for the
    /// "every" fields. Familiar and compact for display.
    var cronLikeSummary: String {
        func f(_ v: Int?) -> String { v.map(String.init) ?? "*" }
        return "\(f(minute)) \(f(hour)) \(f(day)) \(f(month)) \(f(weekday))"
    }

    /// A human-readable English phrase for a single calendar interval.
    var englishFrequency: String {
        let at = hour.map { "\($0):\(CronEnglish.pad(minute ?? 0))" }
        if let wd = weekday, let name = CronEnglish.weekdayName(String(wd)) {
            return at.map { "every \(name) at \($0)" } ?? "every \(name)"
        }
        if let day = day {
            return at.map { "monthly on day \(day) at \($0)" } ?? "monthly on day \(day)"
        }
        if let at = at { return "daily at \(at)" }
        if let m = minute { return "hourly at :\(CronEnglish.pad(m))" }
        return "every minute"
    }
}

struct CronJob: Codable, Identifiable {
    var id: UUID
    var name: String
    var command: String
    var schedule: JobSchedule
    var backend: JobBackend
    var isEnabled: Bool
    var lastRunTime: Date?
    var lastRunStatus: RunStatus?

    /// Transient — not persisted. Defaults to `.managed` so decoded config jobs
    /// are always treated as cmdloop-owned.
    var source: JobSource = .managed

    /// The cron expression for cron-backed jobs; empty for launchd jobs.
    /// Convenience for cron-only code paths and display.
    var cronExpression: String {
        if case .cron(let expr) = schedule { return expr }
        return ""
    }

    /// The command as a single shell statement. A raw newline would split a
    /// crontab entry into invalid lines (and reads poorly in a plist), so
    /// multi-line commands are joined with ";".
    var singleLineCommand: String {
        command
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "; ")
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, command, schedule, backend, isEnabled, lastRunTime, lastRunStatus
        case cronExpression // legacy field, read-only for migration
    }

    init(id: UUID = UUID(), name: String, command: String, schedule: JobSchedule, backend: JobBackend = .cron, isEnabled: Bool = true, lastRunTime: Date? = nil, lastRunStatus: RunStatus? = nil, source: JobSource = .managed) {
        self.id = id
        self.name = name
        self.command = command
        self.schedule = schedule
        self.backend = backend
        self.isEnabled = isEnabled
        self.lastRunTime = lastRunTime
        self.lastRunStatus = lastRunStatus
        self.source = source
    }

    /// Convenience initializer for cron-backed jobs, keeping existing cron call
    /// sites and tests unchanged.
    init(id: UUID = UUID(), name: String, command: String, cronExpression: String, isEnabled: Bool = true, lastRunTime: Date? = nil, lastRunStatus: RunStatus? = nil, source: JobSource = .managed) {
        self.init(id: id, name: name, command: command, schedule: .cron(cronExpression), backend: .cron, isEnabled: isEnabled, lastRunTime: lastRunTime, lastRunStatus: lastRunStatus, source: source)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        command = try c.decode(String.self, forKey: .command)
        if let sched = try c.decodeIfPresent(JobSchedule.self, forKey: .schedule) {
            schedule = sched
        } else {
            // Legacy config: a bare `cronExpression` string, cron backend.
            let expr = try c.decodeIfPresent(String.self, forKey: .cronExpression) ?? ""
            schedule = .cron(expr)
        }
        backend = try c.decodeIfPresent(JobBackend.self, forKey: .backend) ?? .cron
        isEnabled = try c.decode(Bool.self, forKey: .isEnabled)
        lastRunTime = try c.decodeIfPresent(Date.self, forKey: .lastRunTime)
        lastRunStatus = try c.decodeIfPresent(RunStatus.self, forKey: .lastRunStatus)
        source = .managed
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(command, forKey: .command)
        try c.encode(schedule, forKey: .schedule)
        try c.encode(backend, forKey: .backend)
        try c.encode(isEnabled, forKey: .isEnabled)
        try c.encodeIfPresent(lastRunTime, forKey: .lastRunTime)
        try c.encodeIfPresent(lastRunStatus, forKey: .lastRunStatus)
    }
}

/// Derives a stable UUID from arbitrary text so external crontab entries keep the
/// same identity across reloads (used for SwiftUI-style diffing and name lookups).
func deterministicUUID(from string: String) -> UUID {
    let digest = Insecure.MD5.hash(data: Data(string.utf8))
    let bytes = [UInt8](digest)
    return bytes.withUnsafeBufferPointer { NSUUID(uuidBytes: $0.baseAddress!) as UUID }
}

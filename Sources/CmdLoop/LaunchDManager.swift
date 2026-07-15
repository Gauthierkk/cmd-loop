import Foundation

/// A reference to an on-disk external LaunchAgent, so operations (enable, edit,
/// delete) can find the plist a displayed job came from.
struct ExternalAgentRef {
    let url: URL
    let label: String
}

/// Owns the launchd backend: generating/parsing LaunchAgent plists, translating
/// schedules to/from launchd keys, and loading/unloading agents via launchctl.
/// The crontab equivalent lives in `CrontabManager`; `SchedulerManager` routes
/// between the two.
final class LaunchDManager {
    static let shared = LaunchDManager()
    private init() {}

    private let labelPrefix = "com.cmdloop."

    /// Label prefixes we never surface as adoptable "external" jobs: cmdloop's own
    /// managed agents (tracked via config instead) and common third-party noise.
    private let noisePrefixes = [
        "com.cmdloop.",
        "com.apple.",
        "homebrew.mxcl.",
        "com.microsoft.",
        "com.google.",
        "org.mongodb.",
        "com.docker.",
        "com.adobe.",
        "com.valvesoftware.",
        "com.logi.",
    ]

    /// Maps a displayed external job's id back to its plist file + label.
    /// Rebuilt on each `loadExternalJobs()`. Main-thread only.
    private(set) var externalAgents: [UUID: ExternalAgentRef] = [:]

    var agentsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents")
    }

    func label(for job: CronJob) -> String { labelPrefix + job.id.uuidString }

    func plistURL(for job: CronJob) -> URL {
        agentsDirectory.appendingPathComponent(label(for: job) + ".plist")
    }

    func isNoiseLabel(_ label: String) -> Bool {
        noisePrefixes.contains { label.hasPrefix($0) }
    }

    /// Whether a schedule round-trips through the launchd schedule editor. An
    /// agent with multiple calendar intervals can't be represented by the
    /// single-interval editor, so the UI shows it read-only.
    func isEditableSchedule(_ schedule: JobSchedule) -> Bool {
        if case .calendar(let intervals) = schedule, intervals.count > 1 { return false }
        return true
    }

    // MARK: - Schedule translation

    /// launchd schedule keys (`StartInterval` / `StartCalendarInterval`) for a
    /// schedule. Empty for `.cron` (which never reaches the launchd backend).
    func scheduleDict(for schedule: JobSchedule) -> [String: Any] {
        switch schedule {
        case .cron:
            return [:]
        case .interval(let seconds):
            return ["StartInterval": seconds]
        case .calendar(let intervals):
            let dicts = intervals.map(calendarDict)
            // launchd accepts a single dict or an array of dicts.
            return ["StartCalendarInterval": dicts.count == 1 ? dicts[0] : dicts]
        }
    }

    func schedule(fromPlist dict: [String: Any]) -> JobSchedule? {
        if let seconds = dict["StartInterval"] as? Int {
            return .interval(seconds)
        }
        if let one = dict["StartCalendarInterval"] as? [String: Any] {
            return .calendar([calendarInterval(from: one)])
        }
        if let many = dict["StartCalendarInterval"] as? [[String: Any]] {
            return .calendar(many.map(calendarInterval(from:)))
        }
        return nil
    }

    private func calendarDict(_ i: CalendarInterval) -> [String: Int] {
        var d: [String: Int] = [:]
        if let v = i.minute { d["Minute"] = v }
        if let v = i.hour { d["Hour"] = v }
        if let v = i.day { d["Day"] = v }
        if let v = i.weekday { d["Weekday"] = v }
        if let v = i.month { d["Month"] = v }
        return d
    }

    private func calendarInterval(from dict: [String: Any]) -> CalendarInterval {
        CalendarInterval(
            minute: dict["Minute"] as? Int,
            hour: dict["Hour"] as? Int,
            day: dict["Day"] as? Int,
            weekday: dict["Weekday"] as? Int,
            month: dict["Month"] as? Int
        )
    }

    // MARK: - Plist generation (managed jobs)

    /// Builds a managed plist for `job`. cmdloop owns three keys — Label,
    /// ProgramArguments, and the schedule — and writes them here; every extra key
    /// the job carries (EnvironmentVariables, WorkingDirectory, Nice, …) is layered
    /// underneath. Those extras live on the job (`launchdExtrasData`), not on disk,
    /// so they survive a disable→enable round-trip that removes and regenerates the
    /// plist file.
    func plistDictionary(for job: CronJob) -> [String: Any] {
        var dict = extras(from: job)
        // Drop any stale schedule keys the extras might carry so switching schedule
        // kinds (calendar↔interval) never leaves both behind.
        dict.removeValue(forKey: "StartInterval")
        dict.removeValue(forKey: "StartCalendarInterval")
        dict["Label"] = label(for: job)
        dict["ProgramArguments"] = ["/bin/zsh", "-l", "-c", wrappedCommand(for: job)]
        for (key, value) in scheduleDict(for: job.schedule) {
            dict[key] = value
        }
        return dict
    }

    func plistContent(for job: CronJob) -> String {
        let dict = plistDictionary(for: job)
        guard let data = try? PropertyListSerialization.data(
            fromPropertyList: dict, format: .xml, options: 0
        ) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// The extra (non-cmdloop-owned) plist keys stored on `job`, decoded from its
    /// `launchdExtrasData`. Empty when the job carries none.
    func extras(from job: CronJob) -> [String: Any] {
        guard let data = job.launchdExtrasData,
              let obj = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dict = obj as? [String: Any] else { return [:] }
        return dict
    }

    /// Extracts the extra keys from an external agent's plist (everything except the
    /// three cmdloop rewrites), serialized for storage on the adopted job. Nil when
    /// there are none, so cron jobs and key-less agents stay clean.
    func extractExtrasData(fromPlist dict: [String: Any]) -> Data? {
        var extra = dict
        for key in ["Label", "ProgramArguments", "StartInterval", "StartCalendarInterval"] {
            extra.removeValue(forKey: key)
        }
        guard !extra.isEmpty else { return nil }
        return try? PropertyListSerialization.data(fromPropertyList: extra, format: .xml, options: 0)
    }

    /// Wraps the user's command so each launchd fire writes its own run-log file,
    /// matching cron's per-run history. Unlike cron, launchd needs no `%` escaping.
    private func wrappedCommand(for job: CronJob) -> String {
        "\(job.singleLineCommand) \(RunLogStore.shared.launchdRedirection(for: job))"
    }

    // MARK: - External agent discovery

    func plistDict(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let obj = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dict = obj as? [String: Any] else { return nil }
        return dict
    }

    /// Scans `~/Library/LaunchAgents`, skipping cmdloop-managed and noise labels,
    /// and returns the remaining agents as external jobs.
    func loadExternalJobs() -> [CronJob] {
        externalAgents = [:]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: agentsDirectory, includingPropertiesForKeys: nil
        ) else { return [] }

        var jobs: [CronJob] = []
        for file in files where file.pathExtension == "plist" {
            guard let dict = plistDict(at: file) else { continue }
            let label = (dict["Label"] as? String) ?? file.deletingPathExtension().lastPathComponent
            if isNoiseLabel(label) { continue }
            guard let job = externalJob(fromPlist: dict, fallbackLabel: label) else { continue }
            externalAgents[job.id] = ExternalAgentRef(url: file, label: label)
            jobs.append(job)
        }
        return jobs
    }

    /// Builds an external job from a parsed plist. Returns nil for agents with no
    /// schedule or no command (e.g. socket/RunAtLoad-only agents) — cmdloop only
    /// surfaces scheduled command jobs.
    func externalJob(fromPlist dict: [String: Any], fallbackLabel: String) -> CronJob? {
        guard let schedule = schedule(fromPlist: dict) else { return nil }
        let command = commandFromProgramArguments(dict)
        guard !command.isEmpty else { return nil }

        let label = (dict["Label"] as? String) ?? fallbackLabel
        // Identity is anchored on the label (stable across schedule/command edits),
        // so run history isn't orphaned when a user edits an external agent.
        let key = "launchd:" + label
        let name = ExternalNameStore.shared.name(for: key) ?? "launchd job"
        return CronJob(
            id: deterministicUUID(from: key),
            name: name,
            command: command,
            schedule: schedule,
            backend: .launchd,
            isEnabled: true,
            source: .external
        )
    }

    /// Stable name-store key for an external launchd job (label-based).
    func externalNameKey(label: String) -> String { "launchd:" + label }

    private func commandFromProgramArguments(_ dict: [String: Any]) -> String {
        guard let args = dict["ProgramArguments"] as? [String], !args.isEmpty else { return "" }
        // Unwrap the "<shell> -l -c <command>" form we (and many agents) use.
        if let first = args.first, isShellPath(first),
           let ci = args.firstIndex(of: "-c"), ci + 1 < args.count {
            return args[(ci + 1)...].joined(separator: " ")
        }
        return args.joined(separator: " ")
    }

    private func isShellPath(_ path: String) -> Bool {
        ["zsh", "bash", "sh", "fish"].contains((path as NSString).lastPathComponent)
    }

    // MARK: - launchctl operations

    private var domainTarget: String { "gui/\(getuid())" }

    /// Reconciles managed launchd jobs at launch: enabled ones get written and
    /// loaded, disabled ones get unloaded and their plist removed (mirroring how
    /// cron drops disabled jobs from the crontab but keeps them in config).
    func syncManaged(_ jobs: [CronJob]) {
        for job in jobs where job.backend == .launchd && job.source == .managed {
            if job.isEnabled {
                writeAndLoad(job)
            } else {
                unloadAndRemove(job)
            }
        }
    }

    func enable(_ job: CronJob) { writeAndLoad(job) }
    func disable(_ job: CronJob) { unloadAndRemove(job) }
    func remove(_ job: CronJob) { unloadAndRemove(job) }

    private func writeAndLoad(_ job: CronJob) {
        let url = plistURL(for: job)
        // Extras come from the job (launchdExtrasData), not the on-disk file, so a
        // disabled agent (whose plist was removed) still regenerates with them.
        guard let content = plistContent(for: job).data(using: .utf8) else { return }
        // syncManaged re-runs on every save/toggle of any job; when the on-disk
        // agent already matches, skip the launchctl round-trip (two process
        // spawns per job, on the main thread).
        if let existing = try? Data(contentsOf: url), existing == content { return }
        try? FileManager.default.createDirectory(at: agentsDirectory, withIntermediateDirectories: true)
        try? content.write(to: url, options: .atomic)
        bootout(label: label(for: job)) // clear any stale registration first
        bootstrap(plistPath: url.path)
    }

    private func unloadAndRemove(_ job: CronJob) {
        let url = plistURL(for: job)
        // No plist on disk means the agent was never loaded (or a previous sync
        // already removed it) — nothing to boot out.
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        bootout(label: label(for: job))
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: External agent operations (keep the plist file unless deleting)

    func setExternalEnabled(_ enabled: Bool, ref: ExternalAgentRef) {
        if enabled {
            bootstrap(plistPath: ref.url.path)
        } else {
            bootout(label: ref.label)
        }
    }

    func removeExternalAgent(ref: ExternalAgentRef) {
        bootout(label: ref.label)
        try? FileManager.default.removeItem(at: ref.url)
    }

    /// Rewrites an external agent's command and schedule in place, preserving all
    /// other keys (EnvironmentVariables, WorkingDirectory, etc.).
    func updateExternalAgent(ref: ExternalAgentRef, command: String, schedule: JobSchedule) {
        guard var dict = plistDict(at: ref.url) else { return }
        dict["ProgramArguments"] = ["/bin/zsh", "-l", "-c", command]
        dict.removeValue(forKey: "StartInterval")
        dict.removeValue(forKey: "StartCalendarInterval")
        for (key, value) in scheduleDict(for: schedule) { dict[key] = value }
        guard let data = try? PropertyListSerialization.data(
            fromPropertyList: dict, format: .xml, options: 0
        ) else { return }
        try? data.write(to: ref.url, options: .atomic)
        bootout(label: ref.label)
        bootstrap(plistPath: ref.url.path)
    }

    // MARK: Adopt / release (prototype)

    /// Hands a managed launchd job back to launchd as a plain external agent:
    /// unloads/removes the `com.cmdloop.<uuid>` plist and writes a new one under a
    /// neutral label with the raw (un-wrapped, un-logged) command. The job's stored
    /// extra keys are carried over. Returns the new external label so the caller can
    /// persist the display name against it.
    @discardableResult
    func releaseToExternal(_ job: CronJob) -> String? {
        let newLabel = externalReleaseLabel(for: job)

        var dict = extras(from: job)
        dict.removeValue(forKey: "StartInterval")
        dict.removeValue(forKey: "StartCalendarInterval")
        dict["Label"] = newLabel
        // Raw command, no log redirection — cmdloop no longer records its runs.
        dict["ProgramArguments"] = ["/bin/zsh", "-l", "-c", job.singleLineCommand]
        for (key, value) in scheduleDict(for: job.schedule) { dict[key] = value }

        guard let data = try? PropertyListSerialization.data(
            fromPropertyList: dict, format: .xml, options: 0
        ) else { return nil }

        // Tear down the managed agent first, then write + load the external one.
        unloadAndRemove(job)
        let newURL = agentsDirectory.appendingPathComponent(newLabel + ".plist")
        try? FileManager.default.createDirectory(at: agentsDirectory, withIntermediateDirectories: true)
        try? data.write(to: newURL, options: .atomic)
        // Always load it: external agents have no disabled state in cmdloop's model,
        // so a released job surfaces as active (matching the crontab release path).
        bootstrap(plistPath: newURL.path)
        return newLabel
    }

    /// A non-cmdloop label for a released agent, derived from the job name (so it
    /// reads sensibly in the UI) with a uuid suffix for uniqueness. Deliberately
    /// avoids the `com.cmdloop.` prefix so the agent surfaces as external again.
    private func externalReleaseLabel(for job: CronJob) -> String {
        let allowed = CharacterSet.alphanumerics
        let slug = String(job.name.lowercased().unicodeScalars.map {
            allowed.contains($0) ? Character($0) : "-"
        })
        var base = slug.split(separator: "-").joined(separator: "-")
        if base.isEmpty { base = "job" }
        return "local.released.\(base).\(job.id.uuidString.prefix(8))"
    }

    private func bootstrap(plistPath: String) {
        runLaunchctl(["bootstrap", domainTarget, plistPath])
    }

    private func bootout(label: String) {
        runLaunchctl(["bootout", "\(domainTarget)/\(label)"])
    }

    @discardableResult
    private func runLaunchctl(_ args: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}

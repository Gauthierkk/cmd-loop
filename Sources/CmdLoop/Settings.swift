import Foundation

/// App-level preferences persisted to ~/.config/cmd-loop/settings.json.
final class SettingsStore {
    static let shared = SettingsStore()

    private struct Payload: Codable {
        var logRetentionRuns: Int?
        var autoAdoptExternal: Bool?
    }

    /// Keep this many runs per job (newest first). Defaults to 1; the user can
    /// raise it (up to 20) in Settings.
    var logRetentionRuns: Int = 1 {
        didSet { persist() }
    }

    /// When on, cmdloop periodically takes ownership of external cron/launchd
    /// entries (about twice a day, plus at launch) so their scheduled runs are
    /// logged. Defaults to off. See `SchedulerManager.autoAdoptScrape`.
    var autoAdoptExternal: Bool = false {
        didSet { persist() }
    }

    private init() {
        if let data = try? Data(contentsOf: Self.url),
           let payload = try? JSONDecoder().decode(Payload.self, from: data) {
            if let stored = payload.logRetentionRuns { logRetentionRuns = stored }
            if let stored = payload.autoAdoptExternal { autoAdoptExternal = stored }
        }
    }

    private static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/cmd-loop/settings.json")
    }

    private func persist() {
        let dir = Self.url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let payload = Payload(logRetentionRuns: logRetentionRuns, autoAdoptExternal: autoAdoptExternal)
        guard let data = try? encoder.encode(payload) else { return }
        try? data.write(to: Self.url, options: .atomic)
    }
}

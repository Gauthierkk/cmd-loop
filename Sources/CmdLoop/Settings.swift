import Foundation

/// App-level preferences persisted to ~/.config/cmd-loop/settings.json.
final class SettingsStore {
    static let shared = SettingsStore()

    private struct Payload: Codable {
        var logRetentionRuns: Int?
    }

    /// Keep this many runs per job (newest first). nil means the default policy:
    /// delete runs older than 10 days.
    var logRetentionRuns: Int? {
        didSet { persist() }
    }

    private init() {
        if let data = try? Data(contentsOf: Self.url),
           let payload = try? JSONDecoder().decode(Payload.self, from: data) {
            logRetentionRuns = payload.logRetentionRuns
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
        guard let data = try? encoder.encode(Payload(logRetentionRuns: logRetentionRuns)) else { return }
        try? data.write(to: Self.url, options: .atomic)
    }
}

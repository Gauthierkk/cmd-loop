import Foundation


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

import Foundation

struct RunRecord {
    let url: URL
    let date: Date
    let isManual: Bool
}

/// Stores one log file per run, per job, under ~/.config/cmd-loop/logs/<job-uuid>/.
/// Filenames encode the start time (run-yyyy-MM-dd'T'HH-mm-ss[-manual].log) so run
/// history can be listed and counted without an index file — including runs that
/// happened via cron while the app wasn't open.
final class RunLogStore {
    static let shared = RunLogStore()
    private init() {}

    static let defaultRetentionDays = 10

    private let fileManager = FileManager.default

    var logsRoot: URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/cmd-loop/logs")
    }

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    func directory(for job: CronJob) -> URL {
        logsRoot.appendingPathComponent(job.id.uuidString)
    }

    @discardableResult
    func ensureDirectory(for job: CronJob) -> URL {
        let dir = directory(for: job)
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        migrateLegacyLog(for: job, into: dir)
        return dir
    }

    /// Moves a pre-run-history single-file log (<name>-<uuid>.log) into the job's
    /// run directory as one historical run, so old output isn't lost.
    private func migrateLegacyLog(for job: CronJob, into dir: URL) {
        guard let files = try? fileManager.contentsOfDirectory(
            at: logsRoot, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        for file in files
        where file.pathExtension == "log" && file.lastPathComponent.contains(job.id.uuidString) {
            let mtime = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? Date()
            let dest = dir.appendingPathComponent("run-\(Self.timestampFormatter.string(from: mtime)).log")
            try? fileManager.moveItem(at: file, to: dest)
        }
    }

    /// Crontab redirection for scheduled runs: names a fresh run file from the
    /// current time at execution. The % signs are backslash-escaped because an
    /// unescaped % terminates the command portion of a crontab line.
    func cronRedirection(for job: CronJob) -> String {
        let dir = ensureDirectory(for: job)
        return ">> '\(dir.path)'/run-$(date +\\%Y-\\%m-\\%dT\\%H-\\%M-\\%S).log 2>&1"
    }

    func newManualRunFile(for job: CronJob) -> URL {
        let dir = ensureDirectory(for: job)
        let name = "run-\(Self.timestampFormatter.string(from: Date()))-manual.log"
        let url = dir.appendingPathComponent(name)
        // Only create when absent: two runs in the same second share the file
        // (the writer appends), rather than truncating the first run's output.
        if !fileManager.fileExists(atPath: url.path) {
            fileManager.createFile(atPath: url.path, contents: nil)
        }
        return url
    }

    /// Carries run history across an identity change (external jobs derive their
    /// UUID from cron + command, so editing either would orphan the old logs).
    func moveHistory(from oldID: UUID, to newID: UUID) {
        guard oldID != newID else { return }
        let oldDir = logsRoot.appendingPathComponent(oldID.uuidString)
        let newDir = logsRoot.appendingPathComponent(newID.uuidString)
        guard fileManager.fileExists(atPath: oldDir.path) else { return }
        if !fileManager.fileExists(atPath: newDir.path) {
            try? fileManager.moveItem(at: oldDir, to: newDir)
            return
        }
        if let files = try? fileManager.contentsOfDirectory(at: oldDir, includingPropertiesForKeys: nil) {
            for file in files {
                try? fileManager.moveItem(at: file, to: newDir.appendingPathComponent(file.lastPathComponent))
            }
        }
        try? fileManager.removeItem(at: oldDir)
    }

    /// All recorded runs for a job, newest first.
    func runs(for job: CronJob) -> [RunRecord] {
        records(in: directory(for: job))
    }

    func latestRunDate(for job: CronJob) -> Date? {
        runs(for: job).first?.date
    }

    private func records(in dir: URL) -> [RunRecord] {
        guard let files = try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return [] }
        var result: [RunRecord] = []
        for file in files where file.pathExtension == "log" {
            var stem = file.deletingPathExtension().lastPathComponent
            guard stem.hasPrefix("run-") else { continue }
            stem.removeFirst(4)
            let isManual = stem.hasSuffix("-manual")
            if isManual { stem.removeLast("-manual".count) }
            guard let date = Self.timestampFormatter.date(from: stem) else { continue }
            result.append(RunRecord(url: file, date: date, isManual: isManual))
        }
        return result.sorted { $0.date > $1.date }
    }

    /// Applies the retention policy across all job log directories: keep the
    /// newest N runs when the user has set a run-count limit in Settings,
    /// otherwise drop runs older than `defaultRetentionDays`.
    func prune() {
        guard let dirs = try? fileManager.contentsOfDirectory(
            at: logsRoot, includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return }
        let retainCount = SettingsStore.shared.logRetentionRuns
        let cutoff = Calendar.current.date(
            byAdding: .day, value: -Self.defaultRetentionDays, to: Date()
        ) ?? .distantPast
        for dir in dirs {
            guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            else { continue }
            let runs = records(in: dir)
            let expired: [RunRecord]
            if let n = retainCount, n > 0 {
                expired = Array(runs.dropFirst(n))
            } else {
                expired = runs.filter { $0.date < cutoff }
            }
            for run in expired {
                try? fileManager.removeItem(at: run.url)
            }
        }
    }

    func clearAll() {
        guard let items = try? fileManager.contentsOfDirectory(at: logsRoot, includingPropertiesForKeys: nil)
        else { return }
        for item in items {
            try? fileManager.removeItem(at: item)
        }
    }
}

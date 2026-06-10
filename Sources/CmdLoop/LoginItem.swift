import Foundation

/// Manages whether cmdloop launches automatically at login by installing or
/// removing a LaunchAgent in ~/Library/LaunchAgents. This mirrors how install.sh
/// sets the app up, so toggling it in Settings stays consistent with the CLI.
final class LoginItemManager {
    static let shared = LoginItemManager()
    private init() {}

    private let label = "com.cmdloop"

    private var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    /// True when the LaunchAgent plist is installed.
    var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    func setEnabled(_ enabled: Bool) {
        if enabled {
            enable()
        } else {
            disable()
        }
    }

    private func executablePath() -> String {
        if let path = Bundle.main.executablePath, !path.isEmpty {
            return path
        }
        return ProcessInfo.processInfo.arguments[0]
    }

    private func enable() {
        // Launch the daemon directly so launchd owns the running GUI process
        // (no self-relaunch). KeepAlive is off so the Quit button actually quits.
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executablePath(), "--daemon"],
            "RunAtLoad": true,
            "KeepAlive": false,
        ]
        let dir = plistURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = try? PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0
        ) else { return }
        try? data.write(to: plistURL, options: .atomic)
        // Reload so the change takes effect immediately; unload first in case an
        // older definition is already registered.
        launchctl(["unload", plistURL.path])
        launchctl(["load", "-w", plistURL.path])
    }

    private func disable() {
        launchctl(["unload", "-w", plistURL.path])
        try? FileManager.default.removeItem(at: plistURL)
    }

    @discardableResult
    private func launchctl(_ args: [String]) -> Int32 {
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

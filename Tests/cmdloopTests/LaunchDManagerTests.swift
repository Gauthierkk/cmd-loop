import XCTest
@testable import cmdloop

final class LaunchDManagerTests: XCTestCase {
    private let manager = LaunchDManager.shared

    // MARK: - Managed plist generation

    func testManagedPlistContainsLabelProgramAndSchedule() {
        let job = CronJob(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            name: "Nightly sync",
            command: "echo hello",
            schedule: .calendar([CalendarInterval(minute: 0, hour: 2)]),
            backend: .launchd
        )

        let plist = manager.plistContent(for: job)

        XCTAssertTrue(plist.contains("<key>Label</key>"))
        XCTAssertTrue(plist.contains("com.cmdloop.11111111-1111-1111-1111-111111111111"))
        XCTAssertTrue(plist.contains("/bin/zsh"))
        XCTAssertTrue(plist.contains("<string>-l</string>"))
        XCTAssertTrue(plist.contains("<string>-c</string>"))
        XCTAssertTrue(plist.contains("echo hello"))
        XCTAssertTrue(plist.contains("<key>StartCalendarInterval</key>"))
        // Per-run redirection gives each launchd fire its own log file.
        XCTAssertTrue(plist.contains("run-$(date"))
    }

    // We deliberately don't use RunAtLoad (a scheduled job shouldn't fire on every
    // load) or StandardOutPath (per-run logging is handled by the wrapped command).
    func testManagedPlistOmitsRunAtLoadAndStandardOutPath() {
        let job = CronJob(name: "j", command: "echo hi", schedule: .interval(300), backend: .launchd)
        let plist = manager.plistContent(for: job)
        XCTAssertFalse(plist.contains("RunAtLoad"))
        XCTAssertFalse(plist.contains("StandardOutPath"))
        XCTAssertFalse(plist.contains("StandardErrorPath"))
    }

    // MARK: - Schedule translation

    func testCalendarScheduleRoundTripsThroughPlistKeys() {
        let schedule = JobSchedule.calendar([CalendarInterval(minute: 30, hour: 8, weekday: 1)])
        let dict = manager.scheduleDict(for: schedule)
        XCTAssertNotNil(dict["StartCalendarInterval"])
        XCTAssertEqual(manager.schedule(fromPlist: dict), schedule)
    }

    func testIntervalScheduleRoundTripsThroughPlistKeys() {
        let schedule = JobSchedule.interval(300)
        let dict = manager.scheduleDict(for: schedule)
        XCTAssertEqual(dict["StartInterval"] as? Int, 300)
        XCTAssertEqual(manager.schedule(fromPlist: dict), schedule)
    }

    func testMultipleCalendarIntervalsUseAnArray() {
        let schedule = JobSchedule.calendar([
            CalendarInterval(hour: 8), CalendarInterval(hour: 20),
        ])
        let dict = manager.scheduleDict(for: schedule)
        XCTAssertTrue(dict["StartCalendarInterval"] is [[String: Int]])
        XCTAssertEqual(manager.schedule(fromPlist: dict), schedule)
    }

    // MARK: - External agent parsing

    func testExternalJobUnwrapsShellCommandAndSchedule() {
        let dict: [String: Any] = [
            "Label": "com.example.backup",
            "ProgramArguments": ["/bin/zsh", "-l", "-c", "backup.sh --now"],
            "StartInterval": 3600,
        ]
        let job = manager.externalJob(fromPlist: dict, fallbackLabel: "com.example.backup")
        XCTAssertEqual(job?.command, "backup.sh --now")
        XCTAssertEqual(job?.schedule, .interval(3600))
        XCTAssertEqual(job?.backend, .launchd)
        XCTAssertEqual(job?.source, .external)
    }

    func testExternalJobJoinsRawProgramArguments() {
        let dict: [String: Any] = [
            "Label": "com.example.raw",
            "ProgramArguments": ["/usr/local/bin/tool", "--flag"],
            "StartInterval": 60,
        ]
        let job = manager.externalJob(fromPlist: dict, fallbackLabel: "com.example.raw")
        XCTAssertEqual(job?.command, "/usr/local/bin/tool --flag")
    }

    func testExternalJobRejectsAgentsWithoutSchedule() {
        let dict: [String: Any] = [
            "Label": "com.example.daemon",
            "ProgramArguments": ["/usr/local/bin/tool"],
            "KeepAlive": true,
        ]
        XCTAssertNil(manager.externalJob(fromPlist: dict, fallbackLabel: "com.example.daemon"))
    }

    // MARK: - Noise filter

    func testNoiseLabelsAreFiltered() {
        XCTAssertTrue(manager.isNoiseLabel("com.apple.something"))
        XCTAssertTrue(manager.isNoiseLabel("homebrew.mxcl.postgresql"))
        XCTAssertTrue(manager.isNoiseLabel("com.cmdloop.some-uuid")) // our own managed agents
        XCTAssertFalse(manager.isNoiseLabel("com.mycompany.backup"))
    }

    // MARK: - Editor round-trip guardrail

    func testMultiDictCalendarIsNotEditable() {
        XCTAssertTrue(manager.isEditableSchedule(.calendar([CalendarInterval(hour: 8)])))
        XCTAssertTrue(manager.isEditableSchedule(.interval(300)))
        XCTAssertFalse(manager.isEditableSchedule(.calendar([
            CalendarInterval(hour: 8), CalendarInterval(hour: 20),
        ])))
    }
}

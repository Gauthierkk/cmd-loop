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

    // MARK: - Adoption: extra-key preservation

    /// Round-trips an external plist's extra keys through `extractExtrasData` (what
    /// adoption stores on the job) → `plistDictionary` (what a sync writes).
    func testExtractedExtrasSurviveIntoManagedPlist() {
        let external: [String: Any] = [
            "Label": "com.example.old",
            "ProgramArguments": ["/old/path"],
            "StartInterval": 999,
            "EnvironmentVariables": ["PATH": "/opt/bin"],
            "WorkingDirectory": "/tmp/work",
            "Nice": 5,
        ]
        let extras = manager.extractExtrasData(fromPlist: external)
        XCTAssertNotNil(extras, "agent carries extra keys, so data should not be nil")

        let job = CronJob(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            name: "Adopted", command: "run.sh",
            schedule: .interval(600), backend: .launchd, launchdExtrasData: extras
        )
        let dict = manager.plistDictionary(for: job)

        // cmdloop's three owned keys are rewritten (owned keys from the source are
        // not carried through)...
        XCTAssertEqual(dict["Label"] as? String, "com.cmdloop.22222222-2222-2222-2222-222222222222")
        XCTAssertEqual(dict["StartInterval"] as? Int, 600)
        let args = dict["ProgramArguments"] as? [String]
        XCTAssertEqual(args?.first, "/bin/zsh")
        XCTAssertTrue((args?.last ?? "").contains("run.sh"))
        // ...while every extra key the agent carried survives.
        XCTAssertEqual(dict["WorkingDirectory"] as? String, "/tmp/work")
        XCTAssertEqual(dict["Nice"] as? Int, 5)
        XCTAssertEqual((dict["EnvironmentVariables"] as? [String: String])?["PATH"], "/opt/bin")
    }

    func testExtractExtrasReturnsNilWhenAgentHasNoExtraKeys() {
        let external: [String: Any] = [
            "Label": "com.example.plain",
            "ProgramArguments": ["/bin/zsh", "-l", "-c", "echo hi"],
            "StartInterval": 300,
        ]
        XCTAssertNil(manager.extractExtrasData(fromPlist: external))
    }

    func testManagedPlistDropsStaleScheduleKeysFromStoredExtras() {
        // Stored extras accidentally include a schedule key; a schedule change to a
        // calendar interval must not leave the stale StartInterval behind.
        let extras = try? PropertyListSerialization.data(
            fromPropertyList: ["StartInterval": 300], format: .xml, options: 0)
        let job = CronJob(name: "j", command: "echo hi",
                          schedule: .calendar([CalendarInterval(hour: 3)]),
                          backend: .launchd, launchdExtrasData: extras)
        let dict = manager.plistDictionary(for: job)
        XCTAssertNil(dict["StartInterval"], "stale interval key must not linger")
        XCTAssertNotNil(dict["StartCalendarInterval"])
    }

    // MARK: - Adopt / release

    func testAdoptionCommandKeepsShellFormCommand() {
        let dict: [String: Any] = ["ProgramArguments": ["/bin/bash", "-c", "echo hi && date"]]
        XCTAssertEqual(manager.adoptionCommand(fromPlist: dict), "echo hi && date")
    }

    func testAdoptionCommandQuotesDirectArgv() {
        let dict: [String: Any] = [
            "ProgramArguments": ["/usr/local/bin/backup", "--dest", "/Volumes/My Disk", "it's"],
        ]
        XCTAssertEqual(manager.adoptionCommand(fromPlist: dict),
                       "/usr/local/bin/backup --dest '/Volumes/My Disk' 'it'\\''s'")
    }

    func testAdoptionCommandRefusesAgentsItCannotReproduce() {
        // `Program` would override the rewritten ProgramArguments.
        XCTAssertNil(manager.adoptionCommand(fromPlist: [
            "Program": "/usr/bin/true", "ProgramArguments": ["true"],
        ]))
        // Extra positional arguments after the -c command string.
        XCTAssertNil(manager.adoptionCommand(fromPlist: [
            "ProgramArguments": ["/bin/sh", "-c", "echo $0", "name"],
        ]))
        XCTAssertNil(manager.adoptionCommand(fromPlist: ["Label": "x"]))
    }

    func testReleaseLabelIsAsciiAndNotCmdloopOwned() {
        let id = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let job = CronJob(id: id, name: "Café  Sync!", command: "echo hi",
                          schedule: .interval(300), backend: .launchd)
        let label = manager.externalReleaseLabel(for: job)
        XCTAssertEqual(label, "local.released.caf-sync.22222222-2222-2222-2222-222222222222")
        XCTAssertFalse(manager.isNoiseLabel(label), "a released agent must surface as external")
    }

    func testAdoptThenReleaseRoundTripsCommandScheduleAndExtras() {
        let external: [String: Any] = [
            "Label": "com.example.backup",
            "ProgramArguments": ["/bin/zsh", "-l", "-c", "echo hi"],
            "StartInterval": 300,
            "WorkingDirectory": "/tmp/work",
        ]
        let job = CronJob(name: "Backup",
                          command: manager.adoptionCommand(fromPlist: external) ?? "",
                          schedule: .interval(300), backend: .launchd,
                          launchdExtrasData: manager.extractExtrasData(fromPlist: external))

        let released = manager.releasePlistDictionary(for: job, label: "local.released.backup")

        XCTAssertEqual(released["Label"] as? String, "local.released.backup")
        // Raw command again: no log redirection once cmdloop stops managing it.
        XCTAssertEqual(released["ProgramArguments"] as? [String], ["/bin/zsh", "-l", "-c", "echo hi"])
        XCTAssertEqual(released["StartInterval"] as? Int, 300)
        XCTAssertEqual(released["WorkingDirectory"] as? String, "/tmp/work")
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

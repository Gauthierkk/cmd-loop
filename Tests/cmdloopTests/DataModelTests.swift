import XCTest
@testable import cmdloop

final class DataModelTests: XCTestCase {
    // Existing config.json files predate the backend/schedule fields. They must
    // still load: a legacy `cronExpression` becomes a `.cron` schedule and the
    // backend defaults to `.cron`.
    func testLegacyConfigDecodesToCronBackend() throws {
        let json = """
        [{"id":"11111111-1111-1111-1111-111111111111","name":"Nightly",\
        "command":"echo hi","cronExpression":"0 2 * * *","isEnabled":true}]
        """
        let jobs = try JSONDecoder().decode([CronJob].self, from: Data(json.utf8))

        XCTAssertEqual(jobs.count, 1)
        XCTAssertEqual(jobs[0].backend, .cron)
        XCTAssertEqual(jobs[0].schedule, .cron("0 2 * * *"))
        XCTAssertEqual(jobs[0].cronExpression, "0 2 * * *")
    }

    func testJobScheduleRoundTripsAllCases() throws {
        let schedules: [JobSchedule] = [
            .cron("*/5 * * * *"),
            .calendar([CalendarInterval(minute: 30, hour: 8)]),
            .interval(300),
        ]
        for schedule in schedules {
            let data = try JSONEncoder().encode(schedule)
            let decoded = try JSONDecoder().decode(JobSchedule.self, from: data)
            XCTAssertEqual(decoded, schedule)
        }
    }

    // A launchd job saved to config and read back keeps its backend and schedule.
    func testLaunchdJobRoundTripsThroughConfigShape() throws {
        let job = CronJob(
            name: "Interval job",
            command: "echo hi",
            schedule: .interval(600),
            backend: .launchd
        )
        let data = try JSONEncoder().encode([job])
        let decoded = try JSONDecoder().decode([CronJob].self, from: data)

        XCTAssertEqual(decoded[0].backend, .launchd)
        XCTAssertEqual(decoded[0].schedule, .interval(600))
    }
}

// Copyright (c) 2026 DOTS
// Cron parsing, due-detection, and task store round-trip tests.

import XCTest
import PluginRuntime
import DotsHarnessCore

final class ScheduledTaskTests: XCTestCase {
    private var utc: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }()

    private func date(_ iso: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.date(from: iso)!
    }

    // MARK: CronExpression

    func testRejectsMalformedExpressions() {
        XCTAssertNil(CronExpression(""))
        XCTAssertNil(CronExpression("* * * *"))
        XCTAssertNil(CronExpression("60 * * * *"))
        XCTAssertNil(CronExpression("* 24 * * *"))
        XCTAssertNil(CronExpression("*/0 * * * *"))
        XCTAssertNil(CronExpression("5-1 * * * *"))
        XCTAssertNil(CronExpression("abc * * * *"))
    }

    func testEveryFiveHoursFromMidnight() {
        let cron = CronExpression("0 */5 * * *")!
        let next = cron.nextDate(after: date("2026-08-27T01:30:00Z"), calendar: utc)
        XCTAssertEqual(next, date("2026-08-27T05:00:00Z"))
    }

    func testDailyAtFixedTime() {
        let cron = CronExpression("30 9 * * *")!
        let next = cron.nextDate(after: date("2026-08-27T09:30:00Z"), calendar: utc)
        XCTAssertEqual(next, date("2026-08-28T09:30:00Z"))
    }

    func testDayOfWeekMondayNineAM() {
        let cron = CronExpression("0 9 * * 1")!
        // 2026-08-27 is a Thursday; next Monday is 2026-08-31.
        let next = cron.nextDate(after: date("2026-08-27T12:00:00Z"), calendar: utc)
        XCTAssertEqual(next, date("2026-08-31T09:00:00Z"))
    }

    func testSundayAcceptsZeroAndSeven() {
        let a = CronExpression("0 0 * * 0")!.nextDate(after: date("2026-08-27T00:00:00Z"), calendar: utc)
        let b = CronExpression("0 0 * * 7")!.nextDate(after: date("2026-08-27T00:00:00Z"), calendar: utc)
        XCTAssertEqual(a, date("2026-08-30T00:00:00Z"))
        XCTAssertEqual(a, b)
    }

    func testListAndRange() {
        let cron = CronExpression("0,30 8-10 * * *")!
        XCTAssertEqual(
            cron.nextDate(after: date("2026-08-27T08:15:00Z"), calendar: utc),
            date("2026-08-27T08:30:00Z")
        )
        XCTAssertEqual(
            cron.nextDate(after: date("2026-08-27T10:30:00Z"), calendar: utc),
            date("2026-08-28T08:00:00Z")
        )
    }

    func testRestrictedDomAndDowUseOrSemantics() {
        // 1st of the month OR any Friday.
        let cron = CronExpression("0 0 1 * 5")!
        XCTAssertEqual(
            cron.nextDate(after: date("2026-08-27T00:00:00Z"), calendar: utc),
            date("2026-08-28T00:00:00Z") // Friday comes before the 1st
        )
    }

    // MARK: isDue

    func testIsDueFiresForMissedSlotThenClears() {
        var task = ScheduledTask(
            name: "backup",
            cron: "0 */5 * * *",
            prompt: "run backup",
            workspacePath: "/tmp/ws",
            createdAt: date("2026-08-27T02:00:00Z")
        )
        XCTAssertTrue(task.isDue(now: date("2026-08-27T06:01:00Z"), calendar: utc))

        task.lastRunAt = date("2026-08-27T06:01:00Z")
        XCTAssertFalse(task.isDue(now: date("2026-08-27T06:30:00Z"), calendar: utc))
        XCTAssertTrue(task.isDue(now: date("2026-08-27T10:02:00Z"), calendar: utc))
    }

    func testDisabledOrInvalidNeverDue() {
        var task = ScheduledTask(
            name: "x", cron: "0 * * * *", prompt: "p", workspacePath: "/tmp",
            enabled: false, createdAt: date("2026-08-27T00:00:00Z")
        )
        XCTAssertFalse(task.isDue(now: date("2026-08-27T05:00:00Z"), calendar: utc))
        task.enabled = true
        task.cron = "nonsense"
        XCTAssertFalse(task.isDue(now: date("2026-08-27T05:00:00Z"), calendar: utc))
    }

    // MARK: TaskStore

    func testStoreRoundTrip() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DotsHarnessTasks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = SupportPaths(
            root: root,
            plugins: root.appendingPathComponent("plugins"),
            presets: root.appendingPathComponent("presets"),
            settings: root.appendingPathComponent("settings.json"),
            hostPatch: root.appendingPathComponent("host.patch.yml"),
            trust: root.appendingPathComponent("trust.json"),
            models: root.appendingPathComponent("models"),
            runtime: root.appendingPathComponent("runtime")
        )
        let store = TaskStore(paths: paths)
        XCTAssertEqual(store.load().count, 0)

        let task = ScheduledTask(
            name: "mail", cron: "*/15 * * * *", prompt: "check mail", workspacePath: "/tmp/ws",
            lastState: ScheduledTask.RunState.failed("boom")
        )
        store.save([task])

        let loaded = store.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].name, "mail")
        XCTAssertEqual(loaded[0].lastState, ScheduledTask.RunState.failed("boom"))
    }
}

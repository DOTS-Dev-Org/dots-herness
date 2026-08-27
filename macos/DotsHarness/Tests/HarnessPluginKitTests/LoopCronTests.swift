// Copyright (c) 2026 DOTS
// `/loop` interval -> cron mapping.

import XCTest
@testable import DotsHarnessCore

@MainActor
final class LoopCronTests: XCTestCase {
    func testMinuteIntervals() {
        XCTAssertEqual(AppModel.loopCron(everyMinutes: 30), "*/30 * * * *")
        XCTAssertEqual(AppModel.loopCron(everyMinutes: 0), "*/1 * * * *")
    }

    func testHourIntervals() {
        XCTAssertEqual(AppModel.loopCron(everyMinutes: 120), "0 */2 * * *")
        XCTAssertEqual(AppModel.loopCron(everyMinutes: 60 * 30), "0 0 * * *")
    }

    func testProducesValidCron() {
        for m in [1, 5, 45, 60, 90, 240] {
            XCTAssertNotNil(CronExpression(AppModel.loopCron(everyMinutes: m)), "invalid cron for \(m)m")
        }
    }
}

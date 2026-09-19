// Copyright (c) 2026 DOTS

import XCTest
@testable import DotsHarnessCore

final class ClaudeUsageTests: XCTestCase {

    func testParseCanonicalBody() throws {
        let json = """
        {"five_hour":{"utilization":65,"resets_at":"2026-09-06T18:00:00Z"},
         "seven_day":{"utilization":43,"resets_at":"2026-09-09T00:00:00Z"},
         "resets_available":3}
        """.data(using: .utf8)!
        let usage = try ClaudeUsageService.parse(json)
        XCTAssertEqual(usage.windows.count, 2)
        XCTAssertEqual(usage.windows[0].kind, .fiveHour)
        XCTAssertEqual(usage.windows[0].usedPercent ?? -1, 0.65, accuracy: 0.001)
        XCTAssertEqual(usage.windows[1].usedPercent ?? -1, 0.43, accuracy: 0.001)
        XCTAssertNotNil(usage.windows[0].resetsAt)
        XCTAssertNotNil(usage.windows[1].resetsAt)
        XCTAssertEqual(usage.resetsAvailable, 3)
        XCTAssertFalse(usage.degraded)
    }

    func testParseOnlyFiveHour() throws {
        let json = #"{"five_hour":{"utilization":10}}"#.data(using: .utf8)!
        let usage = try ClaudeUsageService.parse(json)
        XCTAssertEqual(usage.windows.count, 1)
        XCTAssertEqual(usage.windows[0].kind, .fiveHour)
    }

    func testParseAlternateKeysAndFraction() throws {
        let json = #"{"fiveHour":{"used_percent":0.65}}"#.data(using: .utf8)!
        let usage = try ClaudeUsageService.parse(json)
        XCTAssertEqual(usage.windows[0].usedPercent ?? -1, 0.65, accuracy: 0.001)
    }

    func testParseEmptyThrows() {
        XCTAssertThrowsError(try ClaudeUsageService.parse(#"{}"#.data(using: .utf8)!))
    }

    func testHeatLevelThresholds() {
        XCTAssertEqual(ClaudeUsageService.heatLevel(0.24), 0)
        XCTAssertEqual(ClaudeUsageService.heatLevel(0.25), 1)
        XCTAssertEqual(ClaudeUsageService.heatLevel(0.49), 1)
        XCTAssertEqual(ClaudeUsageService.heatLevel(0.50), 2)
        XCTAssertEqual(ClaudeUsageService.heatLevel(0.74), 2)
        XCTAssertEqual(ClaudeUsageService.heatLevel(0.75), 3)
        XCTAssertEqual(ClaudeUsageService.heatLevel(0.99), 3)
    }

    func testResetTextRelativeAndWeekday() {
        let now = Date(timeIntervalSince1970: 1_757_000_000)

        guard case .relative(let soon) = ClaudeUsageService.resetText(now.addingTimeInterval(2 * 3600 + 14 * 60), now: now) else {
            return XCTFail("expected relative")
        }
        XCTAssertTrue(soon.contains("2") && soon.localizedCaseInsensitiveContains("h"))
        XCTAssertTrue(soon.contains("14"))

        guard case .relative(let mins) = ClaudeUsageService.resetText(now.addingTimeInterval(40 * 60), now: now) else {
            return XCTFail("expected relative")
        }
        XCTAssertTrue(mins.contains("40"))
        XCTAssertFalse(mins.contains(":"))

        guard case .weekday(let day) = ClaudeUsageService.resetText(now.addingTimeInterval(3 * 24 * 3600), now: now) else {
            return XCTFail("expected weekday")
        }
        XCTAssertFalse(day.trimmingCharacters(in: .whitespaces).isEmpty)
        XCTAssertFalse(day.contains("2"))
    }
}

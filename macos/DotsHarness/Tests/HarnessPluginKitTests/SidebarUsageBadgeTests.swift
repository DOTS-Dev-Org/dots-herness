import XCTest
@testable import DotsHarnessUI

@MainActor
final class SidebarUsageBadgeTests: XCTestCase {
    func testShowsHighestFiveHourUsageAcrossAccounts() {
        let router = RouterController()
        router.accountUsage = [
            "first": AccountUsageSnapshot(
                remainingFraction: 1,
                windows: [ClaudeUsageWindow(kind: .fiveHour, usedPercent: 0, resetsAt: nil)]
            ),
            "second": AccountUsageSnapshot(
                remainingFraction: 0.1,
                windows: [
                    ClaudeUsageWindow(kind: .fiveHour, usedPercent: 0.23, resetsAt: nil),
                    ClaudeUsageWindow(kind: .week, usedPercent: 0.9, resetsAt: nil),
                ]
            ),
        ]
        router.claudeUsage = .loaded(ClaudeUsage(windows: [
            ClaudeUsageWindow(kind: .fiveHour, usedPercent: 0, resetsAt: nil),
            ClaudeUsageWindow(kind: .week, usedPercent: 0.99, resetsAt: nil),
        ]))

        XCTAssertEqual(accountUsageUsedFraction(router) ?? -1, 0.23, accuracy: 0.001)
    }
}

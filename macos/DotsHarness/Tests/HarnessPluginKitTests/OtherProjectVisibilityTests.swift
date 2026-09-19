import XCTest
@testable import DotsHarnessUI

final class OtherProjectVisibilityTests: XCTestCase {
    func testCollapsedListShowsAtMostFiveProjectsInOriginalOrder() {
        let paths = (0..<6).map { "project-\($0)" }

        XCTAssertEqual(
            OtherProjectVisibility.visiblePaths(paths, isExpanded: false),
            Array(paths.prefix(5))
        )
        XCTAssertTrue(OtherProjectVisibility.shouldShowRevealControl(paths, isExpanded: false))
    }

    func testFiveOrFewerProjectsNeedNoRevealControl() {
        let paths = (0..<5).map { "project-\($0)" }

        XCTAssertEqual(
            OtherProjectVisibility.visiblePaths(paths, isExpanded: false),
            paths
        )
        XCTAssertFalse(OtherProjectVisibility.shouldShowRevealControl(paths, isExpanded: false))

        XCTAssertEqual(
            OtherProjectVisibility.visiblePaths([], isExpanded: false),
            []
        )
        XCTAssertFalse(OtherProjectVisibility.shouldShowRevealControl([], isExpanded: false))
    }

    func testExpandedListShowsAllProjectsAndDoesNotOfferCollapse() {
        let paths = (0..<8).map { "project-\($0)" }

        XCTAssertEqual(
            OtherProjectVisibility.visiblePaths(paths, isExpanded: true),
            paths
        )
        XCTAssertFalse(OtherProjectVisibility.shouldShowRevealControl(paths, isExpanded: true))
    }
}

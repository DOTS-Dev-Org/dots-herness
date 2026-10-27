import Foundation
import XCTest
@testable import DotsHarnessUI

final class ProjectFolderGroupingTests: XCTestCase {
    func testGroupsProjectsByImmediateParentFolder() {
        let groups = ProjectFolderGrouping.groups(for: [
            "/workspace/team-a/alpha",
            "/workspace/team-a/beta",
            "/workspace/team-b/gamma",
        ])

        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].title, "team-a")
        XCTAssertEqual(groups[0].paths, ["/workspace/team-a/alpha", "/workspace/team-a/beta"])
        XCTAssertEqual(groups[1].title, "team-b")
        XCTAssertTrue(groups.allSatisfy { $0.kind == .folder })
    }

    func testDisambiguatesFoldersWithTheSameName() {
        let groups = ProjectFolderGrouping.groups(for: [
            "/Users/alice/work/alpha",
            "/Users/bob/work/beta",
        ])

        XCTAssertEqual(groups.map(\.title), ["alice/work", "bob/work"])
    }
}

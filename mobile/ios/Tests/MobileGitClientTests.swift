import XCTest
@testable import HerNessMobile

final class MobileGitClientTests: XCTestCase {
    func testBranchSnapshotParsesCurrentAndLocalBranches() {
        let snapshot = MobileGitBranchSnapshot.parse("current\tmain\nbranch\tmain\nbranch\tfeature/mobile\n")

        XCTAssertEqual(snapshot.currentBranch, "main")
        XCTAssertEqual(snapshot.branches, ["main", "feature/mobile"])
    }

    func testBranchSnapshotKeepsUnbornHeadWithoutBranches() {
        let snapshot = MobileGitBranchSnapshot.parse("current\tmain\n")

        XCTAssertEqual(snapshot.currentBranch, "main")
        XCTAssertTrue(snapshot.branches.isEmpty)
    }
}

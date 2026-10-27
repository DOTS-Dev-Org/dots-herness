import XCTest
@testable import HerNessMobile

final class MobileCloudRunsTests: XCTestCase {
    func testOnlyOwnerSlashRepositoryNamesAreCloudTargets() {
        XCTAssertEqual(MobileCloudRepository(fullName: "octo/hello")?.fullName, "octo/hello")
        XCTAssertEqual(MobileCloudRepository(fullName: "octo/hello")?.branchURL("herness/cloud-1").absoluteString,
                       "https://github.com/octo/hello/tree/herness/cloud-1")
        XCTAssertNil(MobileCloudRepository(fullName: nil))
        XCTAssertNil(MobileCloudRepository(fullName: "hello"))
        XCTAssertNil(MobileCloudRepository(fullName: "octo/hello/tree"))
        XCTAssertNil(MobileCloudRepository(fullName: "octo/hel lo"))
    }

    func testRunDecodesTheWorkerPayload() throws {
        let json = """
        {"id":"r1","repository":"octo/hello","base_ref":"main","prompt":"Fix the build","model":null,"status":"running",
        "cancel_requested":false,"github_run_id":"42","github_run_url":"https://github.com/octo/hello/actions/runs/42",
        "result_branch":null,"result_commit":null,"summary":null,"error":null,"event_count":1,
        "created_at":"2026-10-27T17:13:19.444Z","updated_at":"2026-10-27T17:13:19.444Z","started_at":null,"finished_at":null}
        """
        let run = try JSONDecoder().decode(MobileCloudRun.self, from: Data(json.utf8))
        XCTAssertTrue(run.status.isActive)
        XCTAssertEqual(run.githubRunID, "42")
        XCTAssertNotNil(run.createdDate)
    }

    func testWorkflowTemplateIsBundled() throws {
        let url = try XCTUnwrap(Bundle(for: MobileCloudStore.self).url(forResource: "herness-cloud", withExtension: "yml")
            ?? Bundle.main.url(forResource: "herness-cloud", withExtension: "yml"))
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("workflow_dispatch:"))
    }
}

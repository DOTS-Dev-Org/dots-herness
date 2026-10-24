import Foundation
import XCTest
@testable import DotsHarnessCore

final class BrowserContractsTests: XCTestCase {
    func testBackendSelectionUsesOnlyExplicitUserRules() {
        XCTAssertEqual(BrowserBackendPolicy.resolveUserRule("siteyi aç"), .unknown)
        XCTAssertEqual(BrowserBackendPolicy.resolveUserRule("mevcut Chrome profilimi kullan"), .extension)
        XCTAssertEqual(BrowserBackendPolicy.resolveUserRule("izole managed browser kullan"), .managed)
        XCTAssertEqual(BrowserBackendPolicy.resolveUserRule("bunu Safari'de aç"), .safari)
        XCTAssertEqual(BrowserBackendPolicy.resolveUserRule("open it in Chrome"), .extension)
        XCTAssertEqual(BrowserBackendPolicy.resolveUserRule("safarihane sayfasını aç"), .unknown)
        XCTAssertEqual(BrowserBackend.unknown.rawValue, "Unknown")
        XCTAssertEqual(BrowserCleanupStatus.pendingRecovery.rawValue, "PendingRecovery")
    }

    func testBrowserScopeSeparatesProjectConversationAndRun() {
        let first = BrowserScope(scope: "project-a", conversationID: "conversation", runID: "run-a")
        let second = BrowserScope(scope: "project-b", conversationID: "conversation", runID: "run-a")
        let third = BrowserScope(scope: "project-a", conversationID: "conversation", runID: "run-b")
        XCTAssertNotEqual(first.key, second.key)
        XCTAssertNotEqual(first.key, third.key)
    }

    @MainActor
    func testModelCannotSupplyBackendArgument() async {
        let manager = BrowserSessionManager(
            rootURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("browser-contracts-\(UUID().uuidString)", isDirectory: true)
        )
        let call = AgentToolCall(
            id: "call",
            name: BrowserTools.openName,
            arguments: #"{"url":"https://example.com","backend":"Extension"}"#
        )
        let result = await manager.execute(
            call,
            scope: BrowserScope(scope: "project", conversationID: "c", runID: "r"),
            backend: .managed
        )
        XCTAssertTrue(result.contains("backend is selected by the host"), result)
    }

    func testStrictAgentPolicyDisablesNetworkAndMarksBrowserSafety() {
        let policy = SandboxExecutionPolicy(workspaceURL: URL(fileURLWithPath: "/tmp/project"))
            .strictAgentPolicy()
        XCTAssertFalse(policy.networkAccess)
        XCTAssertTrue(policy.browserSafe)
    }
}

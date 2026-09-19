import Foundation
import XCTest
@testable import DotsHarnessCore

final class BrowserContractsTests: XCTestCase {
    func testBackendSelectionUsesOnlyExplicitUserRules() {
        XCTAssertEqual(BrowserBackendPolicy.resolveUserRule("siteyi aç"), .unknown)
        XCTAssertEqual(BrowserBackendPolicy.resolveUserRule("mevcut Chrome profilimi kullan"), .extension)
        XCTAssertEqual(BrowserBackendPolicy.resolveUserRule("izole managed browser kullan"), .managed)
        XCTAssertEqual(BrowserBackendPolicy.parseConfirmation("Managed isolated browser"), .managed)
        XCTAssertEqual(BrowserBackendPolicy.parseConfirmation("Existing Chrome profile"), .extension)
        XCTAssertEqual(BrowserBackendPolicy.parseConfirmation("release 12"), .unknown)
        XCTAssertEqual(BrowserBackend.unknown.rawValue, "Unknown")
        XCTAssertEqual(BrowserCleanupStatus.pendingRecovery.rawValue, "PendingRecovery")
    }

    func testBrowserScopeSeparatesAreaConversationAndRun() {
        let first = BrowserScope(area: "chat", conversationID: "conversation", runID: "run-a")
        let second = BrowserScope(area: "coding", conversationID: "conversation", runID: "run-a")
        let third = BrowserScope(area: "chat", conversationID: "conversation", runID: "run-b")
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
            scope: BrowserScope(area: "coding", conversationID: "c", runID: "r"),
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

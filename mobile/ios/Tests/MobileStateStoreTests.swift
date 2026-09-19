import XCTest
@testable import HerNessMobile

@MainActor
final class MobileStateStoreTests: XCTestCase {
    private var databaseURL: URL!

    override func setUp() async throws {
        databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("herness-state-(UUID().uuidString).sqlite")
    }

    override func tearDown() async throws {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: databaseURL)
        try? fileManager.removeItem(atPath: databaseURL.path + "-wal")
        try? fileManager.removeItem(atPath: databaseURL.path + "-shm")
    }

    func testRunMessagesAndEventsSurviveAndRunningRunIsRecovered() {
        let conversationID: String
        do {
            let store = MobileStateStore(url: databaseURL)
            conversationID = store.startRun(mode: "agent", planMode: true, prompt: "Inspect the workspace")
            store.appendMessage(conversationID: conversationID, role: "assistant", content: "I will inspect it.")
            _ = store.appendEvent(conversationID: conversationID, kind: "tool_started", payload: ["tool": "list_files"])

            XCTAssertEqual(store.conversationStatus(conversationID), "running")
            XCTAssertEqual(store.messages(conversationID: conversationID).map(\.role), ["user", "assistant"])
            XCTAssertEqual(store.recentEvents().map(\.kind), ["tool_started"])
        }

        let reopened = MobileStateStore(url: databaseURL)
        XCTAssertEqual(reopened.conversationStatus(conversationID), "interrupted")
        XCTAssertEqual(reopened.messages(conversationID: conversationID).count, 2)
        XCTAssertEqual(reopened.recentEvents().count, 1)
    }

    func testCredentialLikeContentIsRedactedBeforeSQLite() {
        let store = MobileStateStore(url: databaseURL)
        let conversationID = store.startRun(mode: "agent", planMode: false, prompt: "api_key=sk-proj-1234567890123456")
        store.appendMessage(conversationID: conversationID, role: "tool", content: "Authorization: Bearer ghp_1234567890123456")
        store.savePendingAction(id: "pending", conversationID: conversationID, kind: "approval", payload: ["authorization": "Bearer sk-ant-1234567890123456"], status: "waiting")
        store.saveModelContext(conversationID: conversationID, content: "refresh_token=rt_1234567890123456")

        let messages = store.messages(conversationID: conversationID).map(\.content).joined(separator: "\n")
        XCTAssertFalse(messages.contains("sk-proj-1234567890123456"))
        XCTAssertFalse(messages.contains("ghp_1234567890123456"))
    }
}

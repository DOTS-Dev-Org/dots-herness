import XCTest
@testable import HerNessMobile

@MainActor
final class MobileStateStoreTests: XCTestCase {
    private var databaseURL: URL!

    override func setUp() async throws {
        databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("herness-state-\(UUID().uuidString).sqlite")
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

    func testTranscriptPagesStartAtNewestTenAndWalkBackwards() {
        let store = MobileStateStore(url: databaseURL)
        let conversationID = store.startRun(mode: "agent", planMode: false, prompt: "message-00")
        for index in 1..<25 {
            store.appendMessage(conversationID: conversationID, role: "assistant", content: String(format: "message-%02d", index))
        }

        let latest = store.messagePage(conversationID: conversationID)
        XCTAssertEqual(latest.messages.count, 10)
        XCTAssertEqual(latest.messages.map(\.content), (15..<25).map { String(format: "message-%02d", $0) })
        XCTAssertTrue(latest.hasOlder)

        let middle = store.messagePage(conversationID: conversationID, beforeRowID: latest.beforeRowID)
        XCTAssertEqual(middle.messages.map(\.content), (5..<15).map { String(format: "message-%02d", $0) })
        XCTAssertTrue(middle.hasOlder)

        let first = store.messagePage(conversationID: conversationID, beforeRowID: middle.beforeRowID)
        XCTAssertEqual(first.messages.map(\.content), (0..<5).map { String(format: "message-%02d", $0) })
        XCTAssertFalse(first.hasOlder)
    }

    func testPageLimitCountsConversationalMessagesOnly() {
        let store = MobileStateStore(url: databaseURL)
        let conversationID = store.startRun(mode: "agent", planMode: false, prompt: "apply 1 and 2")
        store.appendMessage(conversationID: conversationID, role: "assistant", content: "on it")
        for index in 0..<15 { store.appendMessage(conversationID: conversationID, role: "tool", content: "step \(index)") }
        for _ in 0..<3 { store.appendMessage(conversationID: conversationID, role: "system", content: "timeout") }

        let latest = store.messagePage(conversationID: conversationID)
        XCTAssertEqual(latest.messages.count, 20)
        XCTAssertEqual(latest.messages.first?.content, "apply 1 and 2")
        XCTAssertFalse(latest.hasOlder)
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

    func testSecretInModelContextIsRedactedWithoutLosingTheSnapshot() throws {
        let store = MobileStateStore(url: databaseURL)
        let conversationID = store.startRun(mode: "agent", planMode: false, prompt: "read .env")
        let snapshot: [String: Any] = ["version": 3, "messages": [
            ["role": "tool", "content": "DB_PASSWORD=hunter2secret\nAPI_KEY: \"quoted-value\"\nurl=https://x/y"],
            ["role": "assistant", "content": "Authorization: Bearer abc/def.ghi and ghp_1234567890123456"],
        ]]
        let text = String(decoding: try JSONSerialization.data(withJSONObject: snapshot), as: UTF8.self)
        XCTAssertTrue(store.saveModelContext(conversationID: conversationID, content: text))

        let stored = try XCTUnwrap(store.modelContext(conversationID: conversationID)?.content)
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(stored.utf8)) as? [String: Any])
        let messages = try XCTUnwrap(parsed["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 2)
        for secret in ["hunter2secret", "quoted-value", "abc", "def.ghi", "ghp_1234567890123456"] {
            XCTAssertFalse(stored.contains(secret), secret)
        }
        XCTAssertTrue(stored.contains("url=https"))
    }

    func testLatestModelContextReturnsPersistedConversationSnapshot() {
        let store = MobileStateStore(url: databaseURL)
        let conversationID = store.startRun(mode: "agent", planMode: false, prompt: "Attach V1")
        store.saveModelContext(conversationID: conversationID, content: "{\"version\":2,\"messages\":[]}")

        XCTAssertEqual(store.latestModelContext()?.conversationID, conversationID)
        XCTAssertEqual(store.latestModelContext()?.content, "{\"version\":2,\"messages\":[]}")
    }

    func testMissingProjectLocationKeepsHistoryReadableAndBlocksNewMessages() {
        let store = MobileStateStore(url: databaseURL)
        let previousID = store.startRun(mode: "agent", planMode: false, prompt: "Existing conversation")
        store.finishRun(conversationID: previousID, status: "completed")
        let agent = MobileAgent(apiKey: { "" }, systemPrompt: { "" }, stateStore: store)
        agent.setProjectLocationAvailabilityProvider { false }

        agent.send("This must not be added")
        agent.reset()

        XCTAssertEqual(agent.previousConversations().map(\.id), [previousID])
        XCTAssertEqual(store.messages(conversationID: previousID).map(\.content), ["Existing conversation"])
    }

    func testReservedQueueItemSurvivesRestartAndIsAtomicallyClaimed() throws {
        let conversationID: String
        let promptPayload = #"{"id":"queued-1","text":"plan this change","planIntentResolved":false}"#
        do {
            let store = MobileStateStore(url: databaseURL)
            conversationID = try XCTUnwrap(store.reserveConversation(
                projectID: "project-a",
                queuedPrompt: (id: "queued-1", payload: promptPayload),
                snapshot: #"{"version":3,"messages":[],"queued_prompts":[{"id":"queued-1"}]}"#
            ))
            XCTAssertEqual(store.conversationStatus(conversationID), "queued")
            XCTAssertEqual(store.queuedPromptPayloads(conversationID: conversationID).map(\.id), ["queued-1"])
        }

        let reopened = MobileStateStore(url: databaseURL)
        XCTAssertEqual(reopened.conversationStatus(conversationID), "queued")
        XCTAssertEqual(reopened.queuedPromptPayloads(conversationID: conversationID).first?.payload, promptPayload)
        XCTAssertTrue(reopened.beginReservedRun(
            conversationID: conversationID,
            mode: "queue",
            planMode: false,
            prompt: "plan this change",
            consumedPromptID: "queued-1",
            projectID: "project-a",
            snapshot: #"{"version":3,"messages":[{"role":"user","content":"plan this change"}],"queued_prompts":[]}"#,
            queuedPrompts: []
        ))

        XCTAssertEqual(reopened.conversationStatus(conversationID), "running")
        XCTAssertEqual(reopened.messages(conversationID: conversationID).map(\.content), ["plan this change"])
        XCTAssertTrue(reopened.queuedPromptPayloads(conversationID: conversationID).isEmpty)
        XCTAssertEqual(reopened.latestModelContext(projectID: "project-a")?.content, #"{"version":3,"messages":[{"role":"user","content":"plan this change"}],"queued_prompts":[]}"#)
    }

    func testAmbiguousPlanReservesConversationOrderBeforeClassification() async throws {
        let store = MobileStateStore(url: databaseURL)
        let agent = MobileAgent(apiKey: { "" }, systemPrompt: { "" }, stateStore: store)
        agent.planIntentClassifierOverride = { _ in false }

        XCTAssertTrue(agent.send("Read plan.md", mode: "steer"))
        XCTAssertTrue(agent.send("Fix the second file"))

        let conversationID = try XCTUnwrap(store.latestModelContext()?.conversationID)
        func pendingPrompts() -> [[String: Any]] {
            store.queuedPromptPayloads(conversationID: conversationID).compactMap { item in
                guard let data = item.payload.data(using: .utf8),
                      let prompt = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
                return prompt
            }
        }

        var initial = pendingPrompts()
        XCTAssertEqual(initial.compactMap { $0["text"] as? String }, ["Read plan.md", "Fix the second file"])
        XCTAssertEqual(initial.first?["planIntentResolved"] as? Bool, false)
        XCTAssertTrue(store.messages(conversationID: conversationID).isEmpty)

        for _ in 0..<50 where pendingPrompts().first?["planIntentResolved"] as? Bool != true {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        initial = pendingPrompts()
        XCTAssertEqual(initial.compactMap { $0["text"] as? String }, ["Read plan.md", "Fix the second file"])
        XCTAssertEqual(initial.first?["planIntentResolved"] as? Bool, true)
        XCTAssertTrue(store.messages(conversationID: conversationID).isEmpty)
    }

    func testEventsAndModelContextAreScopedToTheirProject() {
        let store = MobileStateStore(url: databaseURL)
        let first = store.startRun(mode: "agent", planMode: false, prompt: "first", projectID: "project-a")
        let second = store.startRun(mode: "agent", planMode: false, prompt: "second", projectID: "project-b")
        _ = store.appendEvent(conversationID: first, projectID: "project-a", kind: "first.event", payload: [:])
        _ = store.appendEvent(conversationID: second, projectID: "project-b", kind: "second.event", payload: [:])
        store.saveModelContext(conversationID: first, projectID: "project-a", content: "a")
        store.saveModelContext(conversationID: second, projectID: "project-b", content: "b")

        XCTAssertEqual(store.recentEvents(projectID: "project-a").map(\.kind), ["first.event"])
        XCTAssertEqual(store.recentEvents(projectID: "project-b").map(\.kind), ["second.event"])
        XCTAssertEqual(store.latestModelContext(projectID: "project-a")?.content, "a")
        XCTAssertEqual(store.latestModelContext(projectID: "project-b")?.content, "b")
    }
}

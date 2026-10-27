// Copyright (c) 2026 DOTS
// The Codex WebSocket sends only new input when a request extends the last one.

import XCTest
@testable import DotsHarnessCore

final class CodexWebSocketTests: XCTestCase {
    private let user: [String: Any] = ["role": "user", "content": [["type": "input_text", "text": "hi"]]]
    private let call: [String: Any] = ["type": "function_call", "call_id": "c1", "name": "read_file", "arguments": "{}"]
    private let output: [String: Any] = ["type": "function_call_output", "call_id": "c1", "output": "ok"]

    private func body(_ input: [Any], tools: String = "t", maxOutput: Int = 100) -> [String: Any] {
        ["model": "m", "instructions": "i", "tools": [tools], "input": input, "max_output_tokens": maxOutput]
    }

    func testAnExtendingRequestSendsOnlyTheNewItems() throws {
        let delta = try XCTUnwrap(NativeAgentClient.codexInputDelta(
            body: body([user, call, output], maxOutput: 200),
            lastBody: body([user]),
            lastOutput: [call]
        ))
        XCTAssertEqual(delta.count, 1)
        XCTAssertEqual((delta.first as? [String: Any])?["type"] as? String, "function_call_output")
    }

    func testChangedSettingsOrHistorySendTheFullBody() {
        XCTAssertNil(NativeAgentClient.codexInputDelta(
            body: body([user, call, output], tools: "other"), lastBody: body([user]), lastOutput: [call]))
        XCTAssertNil(NativeAgentClient.codexInputDelta(
            body: body([output, call, output]), lastBody: body([user]), lastOutput: [call]))
        // Nothing new: no delta to send.
        XCTAssertNil(NativeAgentClient.codexInputDelta(
            body: body([user, call]), lastBody: body([user]), lastOutput: [call]))
    }

    func testEachConversationGetsItsOwnSocket() {
        let a = NativeAgentClient.codexSocketKey(AgentCachePolicy(promptCacheKey: "project", comparisonScope: "chat-a"))
        let b = NativeAgentClient.codexSocketKey(AgentCachePolicy(promptCacheKey: "project", comparisonScope: "chat-b"))
        XCTAssertNotNil(a)
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(NativeAgentClient.codexSocketKey(AgentCachePolicy(promptCacheKey: "project")), "project")
        // One-off calls have no cache key and stay on HTTP.
        XCTAssertNil(NativeAgentClient.codexSocketKey(AgentCachePolicy(comparisonScope: "chat-a")))
        XCTAssertNil(NativeAgentClient.codexSocketKey(AgentCachePolicy(promptCacheKey: "")))
    }

    /// Two interleaved tool round trips on the real ChatGPT backend, sharing one
    /// project cache key: each chat's second request goes out as a delta on its own
    /// socket (`codex ws reused delta` in the codex-websocket log). Opt-in, like LiveProviderTests:
    ///   DOTS_LIVE=1 swift test --filter CodexWebSocketTests
    @MainActor
    func testLiveToolRoundTripContinuesOnTheSocket() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["DOTS_LIVE"] == "1", "Set DOTS_LIVE=1.")
        let store = NativeProviderStore(paths: .default())
        let account = try XCTUnwrap(store.state.accounts.first { $0.active && $0.api == RouterAPIKind.chatGPT.rawValue })
        var configuration = AgentConfiguration(
            baseURL: account.baseURL,
            model: account.model,
            apiKey: try store.credential(for: account),
            provider: RouterCatalog.label(for: account.provider),
            api: account.api,
            sessionAccountID: account.sessionAccountID,
            specID: account.provider,
            authType: account.authType
        )
        configuration.effort = "low"
        let client = NativeAgentClient(configuration: configuration)
        XCTAssertTrue(client.usesCodexWebSocket)
        let tool = AgentToolDefinition(
            name: "get_number",
            description: "Returns the secret number.",
            parameters: .object(["type": .string("object"), "properties": .object([:])])
        )
        let project = "dots-ws-live-" + UUID().uuidString
        let chats = [("chat-a", "4217"), ("chat-b", "9031")]
        var transcripts: [[AgentMessage]] = []
        for (scope, number) in chats {
            let policy = AgentCachePolicy(promptCacheKey: project, comparisonScope: scope)
            var messages = [AgentMessage(role: .user, content: "Call get_number, then reply with only the number.")]
            let first = try await client.complete(messages: messages, tools: [tool], cachePolicy: policy)
            let call = try XCTUnwrap(first.message.toolCalls.first)
            messages.append(first.message)
            messages.append(AgentMessage(role: .tool, content: number, toolCallID: call.id))
            transcripts.append(messages)
            print("live ws \(scope): first ttft=\(first.firstTokenMilliseconds ?? -1)")
        }
        for ((scope, number), messages) in zip(chats, transcripts) {
            let policy = AgentCachePolicy(promptCacheKey: project, comparisonScope: scope)
            let second = try await client.complete(messages: messages, tools: [tool], cachePolicy: policy)
            XCTAssertTrue(second.message.content.contains(number), second.message.content)
            print("live ws \(scope): second ttft=\(second.firstTokenMilliseconds ?? -1) cached=\(second.usage?.cachedTokens ?? -1)")
        }
    }
}

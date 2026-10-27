import Foundation
import HarnessPluginKit
import XCTest
import PluginRuntime
@testable import DotsHarnessCore

final class TokenEconomyTests: XCTestCase {
    @MainActor
    func testShortCodingResponsesUseSummariesInsteadOfDiscardingEvidence() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let paths = SupportPaths(root: root, plugins: root.appendingPathComponent("plugins"), presets: root.appendingPathComponent("presets"), settings: root.appendingPathComponent("settings"), hostPatch: root.appendingPathComponent("host"), trust: root.appendingPathComponent("trust"), models: root.appendingPathComponent("models"), runtime: root.appendingPathComponent("runtime"))
        let host = NativeAgentHost(paths: paths, endpoint: AgentEndpointController(baseURL: "http://127.0.0.1:1", modelID: "test"))
        let tools = [AgentToolDefinition(name: "read_file", description: "read", parameters: .object([:]))]
        for mode in [AgentUsageMode.standard, .economy] {
            var configuration = AgentConfiguration(baseURL: "https://example.test", model: "test")
            configuration.usageMode = mode
            configuration.responseStylePreference = .ultra
            let admission = host.contextAdmission(messages: [AgentMessage(role: .user, content: "fix the failing tests")], configuration: configuration, tools: tools, contextConfiguration: nil)
            XCTAssertFalse(admission.deterministic)
        }
        try? FileManager.default.removeItem(at: root)
    }

    func testLargeWindowsCompactAtTheirPercentageInEveryMode() {
        for window in [272_000, 1_000_000] {
            let standard = AgentContextCompaction.budget(contextWindow: window, policy: .baseline)
            XCTAssertEqual(standard.triggerTokens, Int(Double(window) * 0.90))
            XCTAssertLessThan(standard.targetTokens, standard.triggerTokens)
            let client = NativeAgentClient(configuration: AgentConfiguration(
                baseURL: "https://example.test", model: "test", api: "chatgpt",
                contextWindow: window, supportsNativeCompaction: true, compactionPolicy: .baseline
            ))
            let body = client.makeBody(messages: [AgentMessage(role: .user, content: "fix code")], tools: [], cachePolicy: .init())
            XCTAssertEqual((body["context_management"] as? [[String: Any]])?.first?["compact_threshold"] as? Int, Int(Double(window) * 0.90))
        }
    }

    func testLatestCheckpointReplacesOldReasoningButKeepsPolicyAndPendingToolPairs() throws {
        let checkpoint: JSONObject = ["type": .string("compaction"), "encrypted_content": .string(String(repeating: "c", count: 2_000))]
        let call: JSONObject = ["type": .string("function_call"), "call_id": .string("new"), "name": .string("read_file"), "arguments": .string("{}")]
        let history = [
            AgentMessage(role: .system, content: "preserve project security rules", systemKind: .promptStable),
            AgentMessage(role: .user, content: "fix the failing test"),
            AgentMessage(role: .assistant, content: "", providerItems: [["type": .string("reasoning"), "encrypted_content": .string(String(repeating: "r", count: 120_000))]]),
            AgentMessage(role: .assistant, content: "", toolCalls: [.init(id: "old", name: "read_file", arguments: "{}")]),
            AgentMessage(role: .tool, content: String(repeating: "source\n", count: 2_000), name: "read_file", toolCallID: "old"),
            AgentMessage(role: .assistant, content: "", toolCalls: [.init(id: "new", name: "read_file", arguments: "{}")], providerItems: [
                ["type": .string("reasoning"), "encrypted_content": .string("retired")], checkpoint, call,
            ]),
            AgentMessage(role: .tool, content: "current file lines", name: "read_file", toolCallID: "new"),
        ]
        let before = AgentContextCompaction.estimateTokens(history)
        let replay = AgentContextCompaction.responsesReplayMessages(history)
        XCTAssertEqual(replay.count, 3)
        XCTAssertEqual(replay.first, history.first)
        XCTAssertEqual(replay[1].providerItems, [checkpoint, call])
        XCTAssertEqual(replay[1].toolCalls.map(\.id), ["new"])
        XCTAssertEqual(replay.last, history.last)
        XCTAssertEqual(AgentContextCompaction.responsesReplayMessages(replay), replay)
        XCTAssertEqual(history.count, 7, "the source transcript remains intact")

        let client = NativeAgentClient(configuration: .init(baseURL: "https://example.test", model: "test", api: "chatgpt"))
        let body = client.makeBody(messages: history, tools: [], cachePolicy: .init())
        let input = try XCTUnwrap(body["input"] as? [[String: Any]])
        XCTAssertEqual(input.compactMap { $0["type"] as? String }, ["compaction", "function_call", "function_call_output"])
        XCTAssertFalse(String(decoding: try JSONSerialization.data(withJSONObject: body), as: UTF8.self).contains(String(repeating: "r", count: 100)))
        // A style limit caps prose turns only. This history carries tool calls, so it keeps its full budget.
        var strictHistory = history
        strictHistory[1].content = "En fazla 200 token kullan"
        let strictBody = client.makeBody(messages: strictHistory, tools: [], cachePolicy: .init())
        XCTAssertGreaterThan(strictBody["max_output_tokens"] as? Int ?? 0, 200, "a tool turn is never capped at a style limit")
        let proseBody = client.makeBody(messages: [AgentMessage(role: .user, content: "En fazla 200 token kullan")], tools: [], cachePolicy: .init())
        XCTAssertEqual(proseBody["max_output_tokens"] as? Int, 200, "a prose turn keeps the requested output cap")
        let after = AgentContextCompaction.estimateTokens(replay)
        let composition = AgentContextInputComposition(messages: history, tools: [], api: "chatgpt")
        XCTAssertLessThan(composition.estimatedTotalTokens * 10, before)
        let wireBefore = try JSONSerialization.data(withJSONObject: client.makeResponsesBody(messages: history, tools: [], cachePolicy: .init())).count
        let wireAfter = try JSONSerialization.data(withJSONObject: client.makeResponsesBody(messages: replay, tools: [], cachePolicy: .init())).count
        XCTAssertLessThan(after * 10, before)
        print("TOKEN_ECONOMY checkpoint estimated_before=\(before) estimated_after=\(after) wire_before=\(wireBefore) wire_after=\(wireAfter)")
    }

    /// Compaction drops read_file bodies, so the reads it drops must stop
    /// authorizing edits and rewrites in that conversation, and only there.
    @MainActor
    func testCompactionMakesTheConversationReadFilesAgain() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = SupportPaths(root: root, plugins: root.appendingPathComponent("plugins"), presets: root.appendingPathComponent("presets"), settings: root.appendingPathComponent("settings"), hostPatch: root.appendingPathComponent("host"), trust: root.appendingPathComponent("trust"), models: root.appendingPathComponent("models"), runtime: root.appendingPathComponent("runtime"))
        let host = NativeAgentHost(paths: paths, endpoint: AgentEndpointController(baseURL: "http://127.0.0.1:1", modelID: "test"))
        host.start(workspacePath: root.path)
        host.newConversation()
        let id = try XCTUnwrap(host.selectedID)
        let file = root.appendingPathComponent("kept.txt")
        let data = Data("alpha\n".utf8)
        try data.write(to: file)
        ReadLedger.shared.record(file, data: data, conversationID: id)
        ReadLedger.shared.record(file, data: data, conversationID: "other")

        let body = String(repeating: "source line\n", count: 40_000)
        var history = [AgentMessage(role: .system, content: "rules", systemKind: .promptStable)]
        for turn in 0..<4 {
            history += [
                AgentMessage(role: .user, content: "turn \(turn)"),
                AgentMessage(role: .assistant, content: "", toolCalls: [.init(id: "r\(turn)", name: "read_file", arguments: "{\"path\":\"kept.txt\"}")]),
                AgentMessage(role: .tool, content: body, name: "read_file", toolCallID: "r\(turn)"),
                AgentMessage(role: .assistant, content: "done \(turn)"),
            ]
        }
        let configuration = AgentConfiguration(baseURL: "https://example.test", model: "test")
        let outcome = try await host.compactIfNeeded(
            messages: history, conversationID: id, configuration: configuration, tools: [],
            modelOverride: nil, client: NativeAgentClient(configuration: configuration),
            nativeCompactionDisabled: true, force: true, forceDeterministic: true
        )
        XCTAssertNotEqual(outcome.messages, history, "the test needs a compaction that changes history")
        let conversation = try XCTUnwrap(host.conversations.first { $0.id == id })
        XCTAssertEqual(conversation.lastContextEstimatedTokens, 0, "the pre-compaction estimate cannot baseline the compacted context")
        XCTAssertEqual(ReadLedger.shared.state(for: file, data: data, conversationID: id), .unread)
        XCTAssertEqual(ReadLedger.shared.state(for: file, data: data, conversationID: "other"), .fresh)
        ReadLedger.shared.forgetConversation("other")
    }

    func testServerSideClearingKeepsReadFileBodies() {
        let client = NativeAgentClient(configuration: AgentConfiguration(baseURL: "https://example.test", model: "test", api: "anthropic"))
        let body = client.makeBody(messages: [AgentMessage(role: .user, content: "fix code")], tools: [], cachePolicy: .init())
        let edit = ((body["context_management"] as? [String: Any])?["edits"] as? [[String: Any]])?.first
        XCTAssertEqual(edit?["exclude_tools"] as? [String], ["read_file"])
    }

    func testReplayedProviderItemsAreNotDoubleCountedAndCiphertextIsDiscounted() {
        let arguments = #"{"path":"a.swift"}"#
        let call = AgentToolCall(id: "call_1", name: "read_file", arguments: arguments)
        let plain = AgentMessage(role: .assistant, content: "done", toolCalls: [call])
        let replayed = AgentMessage(role: .assistant, content: "done", toolCalls: [call], providerItems: [
            ["type": .string("function_call"), "call_id": .string("call_1"), "name": .string("read_file"), "arguments": .string(arguments)],
            ["type": .string("message"), "content": .array([.object(["type": .string("output_text"), "text": .string("done")])])],
            ["type": .string("reasoning"), "id": .string("rs_1"), "encrypted_content": .string(String(repeating: "A", count: 16_000))],
        ])
        // 16 KB of ciphertext replays as ~570 reasoning tokens, not 4k.
        let extra = AgentContextCompaction.estimateTokens(replayed) - AgentContextCompaction.estimateTokens(plain)
        XCTAssertGreaterThan(extra, 560)
        XCTAssertLessThan(extra, 600)
    }

    func testObservedInputIsTheProviderCountPlusOnlyTheNewEstimate() {
        // 245k counted for a request estimated at 260k; a 3k tool result was added since.
        XCTAssertEqual(AgentContextCompaction.observedInputTokens(estimate: 263_000, lastInput: 245_000, lastEstimate: 260_000), 248_000)
        // No counted baseline (new chat, route change, after compaction): full estimate.
        XCTAssertEqual(AgentContextCompaction.observedInputTokens(estimate: 263_000, lastInput: 245_000, lastEstimate: 0), 263_000)
        XCTAssertEqual(AgentContextCompaction.observedInputTokens(estimate: 263_000, lastInput: 0, lastEstimate: 260_000), 263_000)
    }

    @MainActor
    func testCompactionDecisionUsesOnlyEstimateDeltaAfterMeasuredRequest() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = SupportPaths(root: root, plugins: root.appendingPathComponent("plugins"), presets: root.appendingPathComponent("presets"), settings: root.appendingPathComponent("settings"), hostPatch: root.appendingPathComponent("host"), trust: root.appendingPathComponent("trust"), models: root.appendingPathComponent("models"), runtime: root.appendingPathComponent("runtime"))
        let host = NativeAgentHost(paths: paths, endpoint: AgentEndpointController(baseURL: "http://127.0.0.1:1", modelID: "test"))
        host.start(workspacePath: root.path)
        host.newConversation()
        let id = try XCTUnwrap(host.selectedID)
        var configuration = AgentConfiguration(baseURL: "https://example.test", model: "test", contextWindow: 300_000)
        configuration.usageMode = .economy
        let tools = [AgentToolDefinition(name: "read_file", description: "Read a workspace file", parameters: .object([:]))]
        let history = [AgentMessage(role: .user, content: String(repeating: "x", count: 1_100_000))]
        let admission = host.contextAdmission(messages: history, configuration: configuration, tools: tools, contextConfiguration: nil)
        let currentEstimate = admission.normalizedTokens + admission.budget.toolDefinitionTokens
        XCTAssertGreaterThan(admission.budget.toolDefinitionTokens, 0)
        XCTAssertTrue(admission.fits)
        XCTAssertGreaterThan(currentEstimate, admission.budget.triggerTokens)

        let index = try XCTUnwrap(host.conversations.firstIndex { $0.id == id })
        host.conversations[index].contextRouteIdentity = host.contextRouteIdentity(
            configuration: configuration, modelOverride: nil, router: nil, conversationID: id
        )
        host.conversations[index].lastContextInputTokens = 245_000
        host.conversations[index].lastContextEstimatedTokens = currentEstimate - 3_000

        let outcome = try await host.compactIfNeeded(
            messages: history, conversationID: id, configuration: configuration, tools: tools,
            modelOverride: nil, client: NativeAgentClient(configuration: configuration),
            nativeCompactionDisabled: true, forceDeterministic: true
        )
        let trace = try XCTUnwrap(outcome.trace)
        XCTAssertFalse(trace.shouldPrune, "provider count plus the 3k delta remains below the trigger")
        XCTAssertEqual(outcome.messages, history)
    }

    func testCountedRequestEstimateSurvivesPersistence() throws {
        var conversation = Conversation(title: "t")
        conversation.lastContextInputTokens = 245_000
        conversation.lastContextEstimatedTokens = 260_000
        let decoded = try JSONDecoder().decode(Conversation.self, from: JSONEncoder().encode(conversation))
        XCTAssertEqual(decoded.lastContextEstimatedTokens, 260_000)
        XCTAssertEqual(try JSONDecoder().decode(Conversation.self, from: Data(#"{"id":"x","title":"t"}"#.utf8)).lastContextEstimatedTokens, 0)
    }
}

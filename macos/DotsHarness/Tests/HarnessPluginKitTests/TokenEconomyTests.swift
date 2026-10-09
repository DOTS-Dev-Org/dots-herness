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

    func testLargeCodingWindowsCompactBeforeReplayGrowsToTheWindowLimit() {
        for window in [272_000, 1_000_000] {
            let standard = AgentContextCompaction.budget(contextWindow: window, policy: .baseline)
            let economy = AgentContextCompaction.budget(contextWindow: window, policy: .economy)
            XCTAssertEqual(standard.triggerTokens, 32_768)
            XCTAssertEqual(economy.triggerTokens, 16_384)
            XCTAssertLessThan(standard.targetTokens, standard.triggerTokens)
            XCTAssertLessThan(economy.targetTokens, economy.triggerTokens)
            let client = NativeAgentClient(configuration: AgentConfiguration(
                baseURL: "https://example.test", model: "test", api: "chatgpt",
                contextWindow: window, supportsNativeCompaction: true, compactionPolicy: .baseline
            ))
            let body = client.makeBody(messages: [AgentMessage(role: .user, content: "fix code")], tools: [], cachePolicy: .init())
            XCTAssertEqual((body["context_management"] as? [[String: Any]])?.first?["compact_threshold"] as? Int, 32_768)
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
        var strictHistory = history
        strictHistory[1].content = "En fazla 200 token kullan"
        let strictBody = client.makeBody(messages: strictHistory, tools: [], cachePolicy: .init())
        XCTAssertEqual(strictBody["max_output_tokens"] as? Int, 200, "checkpoint pruning must preserve the original requested output cap")
        let after = AgentContextCompaction.estimateTokens(replay)
        let composition = AgentContextInputComposition(messages: history, tools: [], api: "chatgpt")
        XCTAssertLessThan(composition.estimatedTotalTokens * 10, before)
        let wireBefore = try JSONSerialization.data(withJSONObject: client.makeResponsesBody(messages: history, tools: [], cachePolicy: .init())).count
        let wireAfter = try JSONSerialization.data(withJSONObject: client.makeResponsesBody(messages: replay, tools: [], cachePolicy: .init())).count
        XCTAssertLessThan(after * 10, before)
        print("TOKEN_ECONOMY checkpoint estimated_before=\(before) estimated_after=\(after) wire_before=\(wireBefore) wire_after=\(wireAfter)")
    }
}

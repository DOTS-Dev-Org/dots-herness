import XCTest
import Foundation
import PluginRuntime
@testable import DotsHarnessCore

final class PromptHistoryTests: XCTestCase {
    private func capture(_ history: [AgentMessage], context: String) -> [AgentMessage] {
        NativeAgentClient.foldingDynamicPrompt(into: [
            AgentMessage(role: .system, content: context, systemKind: .promptDynamic)
        ] + history)
    }

    func testSnapshotsSurviveRetriesNewTurnsAndReload() throws {
        let first = capture([
            AgentMessage(role: .system, content: "policy", systemKind: .promptStable),
            AgentMessage(role: .user, content: "question one")
        ], context: "project state one")
        let persisted = try JSONEncoder().encode(first)
        let restored = try JSONDecoder().decode([AgentMessage].self, from: persisted)
        XCTAssertEqual(first, restored)
        XCTAssertEqual(capture(restored, context: "changed during retry"), first)
        let tools = restored + [
            AgentMessage(role: .assistant, content: "", toolCalls: [AgentToolCall(id: "call", name: "skill.read", arguments: "{}")]),
            AgentMessage(role: .tool, content: "original skill instructions", toolCallID: "call")
        ]
        XCTAssertEqual(capture(tools, context: "changed during tool execution"), tools)
        let next = capture(tools + [AgentMessage(role: .user, content: "question two")], context: "project state two")
        XCTAssertEqual(Array(next.prefix(tools.count)), tools)
        XCTAssertEqual(next.last?.content, "project state two\n\nquestion two")
        XCTAssertFalse(next.contains { $0.systemKind == .promptDynamic })
    }

    func testAllTransportsPreserveEarlierRequestPrefix() throws {
        let first = capture([
            AgentMessage(role: .system, content: "policy", systemKind: .promptStable),
            AgentMessage(role: .user, content: "question one")
        ], context: "state one")
        let next = capture(first + [AgentMessage(role: .assistant, content: "answer"), AgentMessage(role: .user, content: "question two")], context: "state two")
        for api in ["openai-compatible", RouterAPIKind.anthropic.rawValue, RouterAPIKind.chatGPT.rawValue, RouterAPIKind.geminiCLI.rawValue] {
            let client = NativeAgentClient(configuration: AgentConfiguration(baseURL: "https://example.test/v1", model: "test", api: api))
            let before = client.makeBody(messages: first, tools: [], cachePolicy: AgentCachePolicy())
            let after = client.makeBody(messages: next, tools: [], cachePolicy: AgentCachePolicy())
            let oldItems = try requestItems(before)
            let newItems = try requestItems(after)
            XCTAssertEqual(try normalized(oldItems), try normalized(Array(newItems.prefix(oldItems.count))), api)
            for key in ["system", "instructions"] where before[key] != nil {
                XCTAssertEqual(try normalized(before[key]!), try normalized(after[key]!), api)
            }
            if let old = before["request"] as? [String: Any], let new = after["request"] as? [String: Any] {
                XCTAssertEqual(try normalized(old["systemInstruction"]!), try normalized(new["systemInstruction"]!), api)
            }
        }
    }

    @MainActor
    func testHostCapturesRuntimeAndPluginChangesOnlyOnNewTurn() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let paths = SupportPaths(
            root: root, plugins: root.appendingPathComponent("plugins"), presets: root.appendingPathComponent("presets"),
            settings: root.appendingPathComponent("settings.json"), hostPatch: root.appendingPathComponent("host.patch.yml"),
            trust: root.appendingPathComponent("trust.json"), models: root.appendingPathComponent("models"), runtime: root.appendingPathComponent("runtime")
        )
        let host = NativeAgentHost(paths: paths, endpoint: AgentEndpointController(baseURL: "http://127.0.0.1:1", modelID: "test"))
        host.updateSystemPrompt("plugin version one")
        let first = host.contextWithSystemPrompt([AgentMessage(role: .user, content: "first")], workspace: nil, planMode: false, prompt: "first")
        XCTAssertTrue(first.last!.content.contains("plugin version one"))
        XCTAssertFalse(first.first!.content.contains("Current date:"))
        host.updateSystemPrompt("plugin version two")
        let next = host.contextWithSystemPrompt(first + [AgentMessage(role: .assistant, content: "answer"), AgentMessage(role: .user, content: "second")], workspace: nil, planMode: false, prompt: "second")
        XCTAssertEqual(Array(next.prefix(first.count)), first)
        XCTAssertTrue(next.last!.content.contains("plugin version two"))
        XCTAssertEqual(host.contextWithSystemPrompt(next, workspace: nil, planMode: false, prompt: "retry"), next)
        let plan = host.contextWithSystemPrompt(next + [AgentMessage(role: .user, content: "plan next")], workspace: nil, planMode: true, prompt: "plan next")
        XCTAssertEqual(Array(plan.prefix(next.count)), next)
        XCTAssertTrue(plan.last!.content.contains("<plan_mode>"))
    }

    func testSummaryForkKeepsTheChatRequestAsItsPrefix() throws {
        let chat = capture([
            AgentMessage(role: .system, content: "policy", systemKind: .promptStable),
            AgentMessage(role: .user, content: "question"),
            AgentMessage(role: .assistant, content: "answer")
        ], context: "state")
        let fork = chat + [AgentMessage(role: .user, content: AgentContextCompaction.summaryForkInstruction)]
        for api in ["openai-compatible", RouterAPIKind.anthropic.rawValue, RouterAPIKind.chatGPT.rawValue] {
            let client = NativeAgentClient(configuration: AgentConfiguration(baseURL: "https://example.test/v1", model: "test", api: api))
            let before = try requestItems(client.makeBody(messages: chat, tools: [], cachePolicy: AgentCachePolicy()))
            let after = try requestItems(client.makeBody(messages: fork, tools: [], cachePolicy: AgentCachePolicy()))
            XCTAssertEqual(try normalized(before), try normalized(Array(after.prefix(before.count))), api)
        }
    }

    func testLegacyMessagesDecodeWithoutSnapshotFlag() throws {
        let message = try JSONDecoder().decode(AgentMessage.self, from: Data(#"{"role":"user","content":"old"}"#.utf8))
        XCTAssertFalse(message.promptContextCaptured)
        let captured = capture([message], context: "new state")
        XCTAssertEqual(captured.first?.content, "new state\n\nold")
        XCTAssertTrue(captured.first!.promptContextCaptured)
    }

    private func requestItems(_ body: [String: Any]) throws -> [[String: Any]] {
        if let messages = body["messages"] as? [[String: Any]] { return messages }
        if let input = body["input"] as? [[String: Any]] { return input }
        return try XCTUnwrap((body["request"] as? [String: Any])?["contents"] as? [[String: Any]])
    }

    private func normalized(_ value: Any) throws -> Data {
        func clean(_ value: Any) -> Any {
            if let object = value as? [String: Any] {
                return object.filter { $0.key != "cache_control" }.mapValues(clean)
            }
            if let array = value as? [Any] { return array.map(clean) }
            return value
        }
        return try JSONSerialization.data(withJSONObject: clean(value), options: [.sortedKeys, .fragmentsAllowed])
    }
}

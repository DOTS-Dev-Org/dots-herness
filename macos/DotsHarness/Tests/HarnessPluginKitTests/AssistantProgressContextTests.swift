import XCTest
import HarnessPluginKit
@testable import DotsHarnessCore

final class AssistantProgressContextTests: XCTestCase {
    private let tool = AgentToolDefinition(
        name: "read_file",
        description: "Read a file",
        parameters: .object([:])
    )
    private let prose = "I will inspect the file now. " + String(repeating: "Then compare it with the tests. ", count: 10)

    func testProgressProseIsOmittedWhileAnthropicThinkingAndToolCallRemain() throws {
        var progress = AgentMessage(
            role: .assistant,
            content: prose,
            thinking: "Keep the provider reasoning attached to this tool turn.",
            toolCalls: [AgentToolCall(id: "call-1", name: "read_file", arguments: #"{"path":"README.md"}"#)]
        )
        progress.markTransientProgressForToolCall()
        XCTAssertTrue(progress.isTransientProgressText)
        let configuration = AgentConfiguration(
            baseURL: "https://example.test/v1",
            model: "claude-sonnet",
            api: RouterAPIKind.anthropic.rawValue
        )
        let body = NativeAgentClient(configuration: configuration).makeBody(
            messages: [progress],
            tools: [tool],
            cachePolicy: AgentCachePolicy()
        )

        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        let content = try XCTUnwrap(messages.first?["content"] as? [[String: Any]])
        XCTAssertEqual(content.map { $0["type"] as? String }, ["thinking", "tool_use"])
        XCTAssertEqual(content.first?["thinking"] as? String, progress.thinking)
        XCTAssertEqual(content.last?["id"] as? String, "call-1")
        XCTAssertEqual(content.last?["name"] as? String, "read_file")
        XCTAssertEqual(progress.content, prose, "The durable/UI transcript input must remain unchanged")
        let projected = try XCTUnwrap(AgentContextCompaction.providerContextMessages([progress]).first)
        XCTAssertEqual(AgentContextCompaction.estimateTokens(projected), AgentContextCompaction.estimateTokens(progress))
        let unmarked = AgentMessage(
            role: .assistant,
            content: progress.content,
            toolCalls: progress.toolCalls
        )
        XCTAssertGreaterThan(AgentContextCompaction.estimateTokens(unmarked), AgentContextCompaction.estimateTokens(progress))
    }

    func testResponsesProviderItemsAreReplayedUnchangedForMarkedProgress() throws {
        let providerItems: [JSONObject] = [
            [
                "type": .string("reasoning"),
                "id": .string("rsn_1"),
                "summary": .array([.object(["type": .string("summary_text"), "text": .string("opaque reasoning")])]),
            ],
            [
                "type": .string("message"),
                "role": .string("assistant"),
                "content": .array([.object(["type": .string("output_text"), "text": .string("I will inspect the file now.")])]),
            ],
            [
                "type": .string("function_call"),
                "call_id": .string("call-1"),
                "name": .string("read_file"),
                "arguments": .string(#"{"path":"README.md"}"#),
            ],
        ]
        var progress = AgentMessage(
            role: .assistant,
            content: prose,
            toolCalls: [AgentToolCall(id: "call-1", name: "read_file", arguments: #"{"path":"README.md"}"#)],
            providerItems: providerItems
        )
        progress.markTransientProgressForToolCall()
        XCTAssertTrue(progress.isTransientProgressText)
        let configuration = AgentConfiguration(
            baseURL: "https://example.test/v1",
            model: "gpt-6-astra",
            api: RouterAPIKind.chatGPT.rawValue
        )
        let body = NativeAgentClient(configuration: configuration).makeBody(
            messages: [progress],
            tools: [tool],
            cachePolicy: AgentCachePolicy()
        )

        let input = try XCTUnwrap(body["input"] as? [[String: Any]])
        XCTAssertEqual(input.count, providerItems.count)
        XCTAssertEqual(input[0]["type"] as? String, "reasoning")
        XCTAssertEqual(input[0]["id"] as? String, "rsn_1")
        let messageContent = try XCTUnwrap(input[1]["content"] as? [[String: Any]])
        let replayedText = messageContent.first?["text"] as? String
        XCTAssertEqual(replayedText, "I will inspect the file now.")
        XCTAssertEqual(input[2]["type"] as? String, "function_call")
        XCTAssertEqual(input[2]["call_id"] as? String, "call-1")
    }

    func testProgressMarkerRoundTripsAndUnmarkedAssistantTextIsNotPruned() throws {
        var marked = AgentMessage(
            role: .assistant,
            content: prose,
            toolCalls: [AgentToolCall(id: "call-1", name: "read_file", arguments: "{}")]
        )
        marked.markTransientProgressForToolCall()
        let restored = try JSONDecoder().decode(AgentMessage.self, from: JSONEncoder().encode(marked))
        XCTAssertTrue(restored.isTransientProgressText)

        var unmarked = AgentMessage(
            role: .assistant,
            content: prose,
            toolCalls: [AgentToolCall(id: "call-1", name: "read_file", arguments: "{}")]
        )
        XCTAssertEqual(AgentContextCompaction.providerContextMessages([unmarked]), [unmarked])
        unmarked.markTransientProgressForToolCall()
        XCTAssertNotEqual(AgentContextCompaction.providerContextMessages([unmarked]).first?.content, unmarked.content)

        var brief = AgentMessage(
            role: .assistant,
            content: "Running the tests now.",
            toolCalls: [AgentToolCall(id: "call-2", name: "run_command", arguments: "{}")]
        )
        brief.markTransientProgressForToolCall()
        XCTAssertFalse(brief.isTransientProgressText, "A brief progress update stays visible to the model")

        let legacy = try JSONDecoder().decode(AgentMessage.self, from: Data(#"{"role":"assistant","content":"legacy"}"#.utf8))
        XCTAssertFalse(legacy.isTransientProgressText)
    }
}

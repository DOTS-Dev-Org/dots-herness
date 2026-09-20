import XCTest
@testable import HerNessMobile

final class MobilePromptHistoryTests: XCTestCase {
    func testNewContextDoesNotRewritePreviousTurnOrPolicy() throws {
        var history = MobilePromptHistory()
        let first = history.capture(prompt: "one", policy: "policy one", context: "plugin one")
        var messages = [first, "tool result", "answer"]
        let previous = messages
        history = try JSONDecoder().decode(MobilePromptHistory.self, from: JSONEncoder().encode(history))
        messages.append(history.capture(prompt: "two", policy: "policy two", context: "plugin two"))
        XCTAssertEqual(history.policy, "policy one")
        XCTAssertEqual(Array(messages.prefix(previous.count)), previous)
        XCTAssertTrue(messages.last!.contains("policy two"))
        XCTAssertTrue(messages.last!.contains("plugin two"))
        XCTAssertFalse(messages.last!.contains("plugin one"))
    }

    func testEmptyContextAndResetStartCleanly() {
        var history = MobilePromptHistory()
        XCTAssertEqual(history.capture(prompt: "one", policy: "policy", context: ""), "one")
        XCTAssertEqual(history.capture(prompt: "two", policy: "policy", context: ""), "two")
        history = MobilePromptHistory()
        XCTAssertEqual(history.capture(prompt: "new", policy: "new policy", context: ""), "new")
        XCTAssertEqual(history.policy, "new policy")
    }

    func testPromptCacheKeyIsStableForSamePrefixAndRotatesForNewSegments() {
        let tools = [
            AgentToolSpec(name: "read_file", description: "read", schema: ["type": "object"]) { _ in "" },
            AgentToolSpec(name: "list_files", description: "list", schema: ["type": "object"]) { _ in "" },
        ]
        let fingerprint = MobilePromptCache.toolFingerprint(tools)
        let first = MobilePromptCache.key(
            conversationID: "conversation-1",
            provider: "openai",
            route: "openai-chat",
            model: "gpt-4.1",
            accountScope: "openai",
            toolFingerprint: fingerprint,
            contextSegment: 0
        )
        let same = MobilePromptCache.key(
            conversationID: "conversation-1",
            provider: "openai",
            route: "openai-chat",
            model: "gpt-4.1",
            accountScope: "openai",
            toolFingerprint: fingerprint,
            contextSegment: 0
        )
        let compacted = MobilePromptCache.key(
            conversationID: "conversation-1",
            provider: "openai",
            route: "openai-chat",
            model: "gpt-4.1",
            accountScope: "openai",
            toolFingerprint: fingerprint,
            contextSegment: 1
        )
        XCTAssertEqual(first, same)
        XCTAssertNotEqual(first, compacted)
        XCTAssertTrue(first.hasPrefix("herness:mobile-v1:"))
    }
}

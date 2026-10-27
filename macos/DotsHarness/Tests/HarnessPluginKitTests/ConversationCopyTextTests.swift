import XCTest
@testable import DotsHarnessCore
@testable import DotsHarnessUI

final class ConversationCopyTextTests: XCTestCase {
    func testAssistantCopyIncludesWholeTurnButExcludesQuestionAndToolMessages() {
        let messages = [
            ChatMessage(kind: .user, text: "Question"),
            ChatMessage(kind: .assistant, text: "First answer part"),
            ChatMessage(kind: .tool, text: "Tool output"),
            ChatMessage(kind: .assistant, text: "Final answer part"),
            ChatMessage(kind: .user, text: "Next question"),
            ChatMessage(kind: .assistant, text: "Next answer"),
        ]

        XCTAssertEqual(
            ConversationCopyText.text(for: messages[3], in: messages),
            "First answer part\n\nFinal answer part"
        )
    }

    func testNonAssistantMessagesKeepTheirOwnCopyText() {
        let user = ChatMessage(kind: .user, text: "Question")
        let plan = ChatMessage(kind: .plan, text: "Plan text")
        let messages = [user, ChatMessage(kind: .assistant, text: "Answer"), plan]

        XCTAssertEqual(ConversationCopyText.text(for: user, in: messages), "Question")
        XCTAssertEqual(ConversationCopyText.text(for: plan, in: messages), "Plan text")
    }
}

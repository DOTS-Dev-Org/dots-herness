// Copyright (c) 2026 DOTS

import XCTest
@testable import DotsHarnessCore

final class ContinuationStateTests: XCTestCase {
    func testFinishedAnswerHidesContinue() {
        let paused = ContinuationState(reason: .userStopped)
        let finished = Conversation(
            modelContext: [
                AgentMessage(role: .user, content: "özetle"),
                AgentMessage(role: .assistant, content: "Özet hazır."),
            ],
            continuation: paused
        )
        XCTAssertFalse(finished.canContinue)

        let interrupted = Conversation(
            modelContext: [
                AgentMessage(role: .user, content: "özetle"),
                AgentMessage(role: .assistant, content: "", toolCalls: [AgentToolCall(id: "1", name: "read", arguments: "{}")]),
                AgentMessage(role: .tool, content: "ok", name: "read", toolCallID: "1"),
            ],
            continuation: paused
        )
        XCTAssertTrue(interrupted.canContinue)
    }
}

import XCTest
@testable import DotsHarnessCore

final class ContextCompactionTests: XCTestCase {
    func testSelectionKeepsFiveRecentTurnsAndStableSystem() {
        var messages = [AgentMessage(role: .system, content: "workspace rules")]
        for index in 1...7 {
            messages.append(AgentMessage(role: .user, content: "request \(index)"))
            messages.append(AgentMessage(role: .assistant, content: "answer \(index)"))
        }

        let selection = AgentContextCompaction.select(
            messages,
            previousSummary: nil,
            budget: AgentContextCompaction.budget(contextWindow: 32_768)
        )

        XCTAssertEqual(selection?.recentGroupCount, 5)
        XCTAssertEqual(selection?.stableSystem.first?.content, "workspace rules")
        XCTAssertEqual(selection?.recentMessages.first?.content, "request 3")
        XCTAssertFalse(selection?.recentMessages.contains(where: { $0.content == "request 2" }) == true)
    }

    func testArchiveKeepsToolPairButOmitsFileBody() {
        let body = String(repeating: "x", count: 8_000)
        let messages = [
            AgentMessage(role: .system, content: "rules"),
            AgentMessage(role: .user, content: "inspect the file"),
            AgentMessage(
                role: .assistant,
                content: "",
                toolCalls: [AgentToolCall(id: "call-1", name: "read_file", arguments: #"{"path":"src/a.swift"}"#)]
            ),
            AgentMessage(role: .tool, content: body, toolCallID: "call-1"),
            AgentMessage(role: .user, content: "now fix it"),
            AgentMessage(role: .assistant, content: "I will fix it."),
        ]

        let selection = AgentContextCompaction.select(
            messages,
            previousSummary: nil,
            budget: AgentContextCompaction.budget(contextWindow: 8_192)
        )

        XCTAssertEqual(selection?.archivedMessages.last?.toolCallID, "call-1")
        XCTAssertTrue(selection?.archiveText.localizedCaseInsensitiveContains("file body omitted") == true)
        XCTAssertFalse(selection?.archiveText.contains(body) == true)
    }

    func testFallbackSummaryUsesTheRequiredFourHeadings() {
        let summary = AgentContextCompaction.fallbackSummary(previousSummary: nil, archiveText: "test evidence")

        XCTAssertTrue(AgentContextCompaction.isValidSummary(summary))
        let composed = AgentContextCompactionSelection(
            stableSystem: [AgentMessage(role: .system, content: "rules")],
            archivedMessages: [],
            recentMessages: [AgentMessage(role: .user, content: "recent")],
            archiveText: "",
            recentGroupCount: 1
        ).compose(summary: summary, preserveProviderItems: false)
        XCTAssertTrue(composed[1].content.hasPrefix(AgentContextCompaction.summaryMarker))
        XCTAssertEqual(composed.last?.content, "recent")
    }
}

import XCTest
@testable import DotsHarnessCore

final class ContextCompactionTests: XCTestCase {
    func testOnlyTheLatestReadOfTheSameLinesKeepsItsBody() {
        func call(_ id: String, _ arguments: String) -> AgentMessage {
            AgentMessage(role: .assistant, content: "", toolCalls: [AgentToolCall(id: id, name: "read_file", arguments: arguments)])
        }
        func result(_ id: String, _ content: String) -> AgentMessage {
            AgentMessage(role: .tool, content: content, name: "read_file", toolCallID: id)
        }
        let messages = [
            AgentMessage(role: .user, content: "look"),
            call("a", #"{"path":"src/app.swift"}"#), result("a", "old body"),
            call("b", #"{"path":"src/app.swift","offset":251}"#), result("b", "second page"),
            call("c", #"{"path":"./src/app.swift","offset":1}"#), result("c", "new body"),
            call("d", #"{"path":"src/other.swift"}"#), result("d", "Tool error: missing"),
            call("e", #"{"path":"src/other.swift"}"#), result("e", "Tool error: missing again"),
        ]

        let reduced = AgentContextCompaction.supersedeRepeatedReads(messages)

        XCTAssertEqual(reduced[2].content, AgentContextCompaction.supersededReadMarker)
        XCTAssertEqual(reduced[4].content, "second page")
        XCTAssertEqual(reduced[6].content, "new body")
        XCTAssertEqual(reduced[8].content, "Tool error: missing")
        // Running it again changes nothing, so the persisted prefix stays stable.
        XCTAssertEqual(AgentContextCompaction.supersedeRepeatedReads(reduced), reduced)
    }

    func testPolicyUsesNinetyPercentAndReservesLargeDynamicOutput() {
        let budget = AgentContextCompaction.budget(
            contextWindow: 32_768,
            reservedOutputTokens: 20_000,
            toolDefinitionTokens: 1_000,
            policy: .baseline
        )

        XCTAssertEqual(budget.policy.triggerRatio, 0.90, accuracy: 0.0001)
        XCTAssertEqual(budget.triggerTokens, budget.usableInputTokens + budget.toolDefinitionTokens)
        XCTAssertGreaterThan(budget.reservedOutputTokens, 16_384)
        XCTAssertTrue(budget.fits(budget.usableInputTokens))
        XCTAssertFalse(budget.fits(budget.usableInputTokens, incomingTokens: 1))
    }

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
                toolCalls: [AgentToolCall(id: "call-1", name: "invoke_tool", arguments: #"{"name":"read_file","arguments":"{\"path\":\"src/a.swift\"}"}"#)]
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
        let omitted = AgentContextCompaction.fallbackSummary(previousSummary: nil, archiveText: "evidence [… compacted …] tail")
        XCTAssertTrue(omitted.localizedCaseInsensitiveContains("atlandı"))
        XCTAssertTrue(AgentContextCompaction.summarySystemPrompt.localizedCaseInsensitiveContains("eksik ayrıntıları varsayma"))
        let composed = AgentContextCompactionSelection(
            stableSystem: [AgentMessage(role: .system, content: "rules")],
            archivedMessages: [],
            recentMessages: [AgentMessage(role: .user, content: "recent")],
            archiveText: "",
            recentGroupCount: 1
        ).compose(summary: summary, preserveProviderItems: false)
        XCTAssertTrue(composed[1].content.hasPrefix(AgentContextCompaction.summaryMarker))
        XCTAssertEqual(composed[1].systemKind, AgentMessage.SystemKind.compactionSummary)
        XCTAssertEqual(composed.last?.content, "recent")
    }

    func testOversizedArchiveKeepsNewestEvidenceAndMarksOmittedMiddle() {
        var messages: [AgentMessage] = []
        for index in 0..<20 {
            messages.append(AgentMessage(role: .user, content: String(repeating: "u", count: 5_900) + "USER_\(String(format: "%02d", index))"))
            messages.append(AgentMessage(role: .assistant, content: String(repeating: "x", count: 5_900) + "ARCHIVE_TAIL_\(String(format: "%02d", index))"))
        }

        let selection = AgentContextCompaction.select(
            messages,
            previousSummary: nil,
            budget: AgentContextCompaction.budget(contextWindow: 32_768)
        )

        XCTAssertEqual(selection?.recentGroupCount, 5)
        XCTAssertTrue(selection?.archiveText.contains("[… compacted …]") == true)
        XCTAssertTrue(selection?.archiveText.contains("ARCHIVE_TAIL_14") == true)
        XCTAssertFalse(selection?.archiveText.contains("ARCHIVE_TAIL_15") == true)
        XCTAssertLessThanOrEqual(selection?.archiveText.utf8.count ?? .max, 48_000)
    }

    func testSummaryCarriesReadAndModifiedFilesAcrossCompactions() {
        let previous = "1. KULLANICI HEDEFİ: a\n\n<read-files>\nold.swift\nb.swift\n</read-files>"
        let archive = [AgentMessage(role: .assistant, content: "", toolCalls: [
            AgentToolCall(id: "1", name: "read_file", arguments: #"{"path":"./a.swift"}"#),
            AgentToolCall(id: "2", name: "edit_file", arguments: #"{"path":"b.swift"}"#),
            AgentToolCall(id: "3", name: "invoke_tool", arguments: #"{"name":"write_file","arguments":"{\"path\":\"c.swift\"}"}"#),
        ])]
        let lists = AgentContextCompaction.fileLists(previousSummary: previous, archive: archive)
        XCTAssertEqual(lists, "<read-files>\nold.swift\na.swift\n</read-files>\n\n<modified-files>\nb.swift\nc.swift\n</modified-files>")

        let selection = AgentContextCompactionSelection(
            stableSystem: [], archivedMessages: [], recentMessages: [], archiveText: "", recentGroupCount: 1, fileLists: lists
        )
        // A summary that echoes the old lists ends with exactly one current copy.
        XCTAssertEqual(selection.attachFileLists(to: previous), "1. KULLANICI HEDEFİ: a\n\n" + lists)
    }

    func testSinglePolicyCompactsAtNinetyPercentOfEachWindow() {
        let policy = AgentContextCompactionPolicy.baseline
        XCTAssertEqual(policy.triggerRatio, 0.90)
        XCTAssertEqual(policy.targetRatio, 0.65)
        XCTAssertEqual(policy.triggerTokens(window: 250_000), 225_000)
        XCTAssertEqual(policy.triggerTokens(window: 1_000_000), 900_000)
        XCTAssertEqual(policy.triggerTokens(window: 0), 1)
    }

    func testForkInstructionProducesAValidSummaryShape() {
        let instruction = AgentContextCompaction.summaryForkInstruction
        XCTAssertTrue(instruction.contains("Do not call any tool"))
        XCTAssertTrue(instruction.contains("Yukarıdaki konuşma geçmişini"))
        XCTAssertTrue(AgentContextCompaction.isValidSummary("""
        1. KULLANICI HEDEFİ: a
        2. YAPILAN DEĞİŞİKLİKLER: b
        3. ALINAN KARARLAR VE KISITLAR: c
        4. MEVCUT DURUM VE SON KANITLAR: d
        """))
    }

    func testCompactionPolicyControlsRecentTurnRetention() {
        var messages = [AgentMessage(role: .system, content: "rules")]
        for index in 1...7 {
            messages.append(AgentMessage(role: .user, content: "request \(index)"))
            messages.append(AgentMessage(role: .assistant, content: "answer \(index)"))
        }

        let policy = AgentContextCompactionPolicy(
            id: .cacheAware,
            triggerRatio: 0.80,
            targetRatio: 0.95,
            maxRecentGroups: 2
        )
        let selection = AgentContextCompaction.select(
            messages,
            previousSummary: nil,
            budget: AgentContextCompaction.budget(contextWindow: 32_768, policy: policy)
        )

        XCTAssertEqual(selection?.recentGroupCount, 2)
    }

    func testRecentTurnsStayUnderTheTokenCapOnLargeWindows() {
        // Each turn is ~12k tokens; a 1M window would otherwise keep all five.
        let big = String(repeating: "x", count: 48_000)
        var messages = [AgentMessage(role: .system, content: "rules")]
        for index in 1...7 {
            messages.append(AgentMessage(role: .user, content: "request \(index)"))
            messages.append(AgentMessage(role: .assistant, content: big))
        }

        let selection = AgentContextCompaction.select(
            messages,
            previousSummary: nil,
            budget: AgentContextCompaction.budget(contextWindow: 1_000_000)
        )

        XCTAssertEqual(selection?.recentGroupCount, 1)
    }

    func testCompactionKeepsTheLanguagePolicyInStableSystemContext() {
        let policy = HerNessPrompt.core(scope: "scope line", toolGuidance: "tool line")
        var messages = [AgentMessage(role: .system, content: policy)]
        for index in 1...7 {
            messages.append(AgentMessage(role: .user, content: "request \(index)"))
            messages.append(AgentMessage(role: .assistant, content: "answer \(index)"))
        }

        let selection = AgentContextCompaction.select(
            messages,
            previousSummary: nil,
            budget: AgentContextCompaction.budget(contextWindow: 32_768)
        )

        XCTAssertTrue(selection?.stableSystem.contains(where: { $0.content.contains("Accuracy and language") }) == true)
        let composed = selection?.compose(summary: "summary", preserveProviderItems: false)
        XCTAssertTrue(composed?.contains(where: { $0.role == .system && $0.content.contains("Accuracy and language") }) == true)
        XCTAssertTrue(AgentContextCompaction.summarySystemPrompt.contains("son güvenilir sohbet dilini"))
        XCTAssertTrue(AgentContextCompaction.summarySystemPrompt.contains("başka bir sohbetin dilini kullanma"))
    }

    func testCompactionPreservesTurkishEnglishAndSimplifiedChineseTurnSequence() {
        let policy = HerNessPrompt.core(scope: "scope line", toolGuidance: "tool line")
        let turns = [
            ("Merhaba, Türkçe devam edelim.", "Türkçe yanıt"),
            ("Please answer in English for this turn.", "English response"),
            ("请用简体中文回答。", "简体中文回复"),
        ]
        var messages = [AgentMessage(role: .system, content: policy)]
        for (user, assistant) in turns {
            messages.append(AgentMessage(role: .user, content: user))
            messages.append(AgentMessage(role: .assistant, content: assistant))
        }

        let selection = AgentContextCompaction.select(
            messages,
            previousSummary: nil,
            budget: AgentContextCompaction.budget(contextWindow: 8_192)
        )

        XCTAssertNotNil(selection)
        XCTAssertTrue(selection?.archiveText.contains("Türkçe") == true)
        XCTAssertTrue(selection?.archiveText.contains("English") == true)
        XCTAssertTrue(selection?.recentMessages.contains(where: { $0.content.contains("简体中文") }) == true)
        XCTAssertTrue(selection?.stableSystem.contains(where: { $0.content.contains("Accuracy and language") }) == true)
    }

    func testInvokeToolReadsAndWiderSpansSupersedeEarlierReads() {
        let messages = [
            AgentMessage(role: .user, content: "inspect"),
            AgentMessage(
                role: .assistant,
                content: "",
                toolCalls: [AgentToolCall(id: "r1", name: "invoke_tool", arguments: #"{"name":"read_file","arguments":"{\"path\":\"src/app.swift\",\"offset\":10,\"limit\":40}"}"#)]
            ),
            AgentMessage(role: .tool, content: "narrow slice", toolCallID: "r1"),
            AgentMessage(
                role: .assistant,
                content: "",
                toolCalls: [AgentToolCall(id: "r2", name: "invoke_tool", arguments: #"{"name":"read_file","arguments":"{\"path\":\"src/app.swift\",\"offset\":1,\"limit\":100}"}"#)]
            ),
            AgentMessage(role: .tool, content: "wider slice covering lines 1..100", toolCallID: "r2"),
        ]

        let reduced = AgentContextCompaction.supersedeRepeatedReads(messages)

        XCTAssertEqual(reduced[2].content, AgentContextCompaction.supersededReadMarker)
        XCTAssertEqual(reduced[4].content, "wider slice covering lines 1..100")
    }

    func testArchiveOmitsEditFilePayloadsAndBodies() {
        let oldBody = String(repeating: "a", count: 4_000)
        let newBody = String(repeating: "b", count: 4_000)
        let diffOutput = String(repeating: "d", count: 4_000)
        let messages = [
            AgentMessage(role: .system, content: "rules"),
            AgentMessage(role: .user, content: "patch the file"),
            AgentMessage(
                role: .assistant,
                content: "",
                toolCalls: [AgentToolCall(id: "edit-1", name: "edit_file", arguments: #"{"path":"src/app.swift","old_string":"\#(oldBody)","new_string":"\#(newBody)"}"#)]
            ),
            AgentMessage(role: .tool, content: diffOutput, toolCallID: "edit-1"),
            AgentMessage(role: .user, content: "next step"),
            AgentMessage(role: .assistant, content: "done"),
        ]

        let selection = AgentContextCompaction.select(
            messages,
            previousSummary: nil,
            budget: AgentContextCompaction.budget(contextWindow: 8_192)
        )

        XCTAssertNotNil(selection)
        XCTAssertTrue(selection?.archiveText.localizedCaseInsensitiveContains("file edits omitted") == true)
        XCTAssertTrue(selection?.archiveText.localizedCaseInsensitiveContains("file write result omitted") == true)
        XCTAssertFalse(selection?.archiveText.contains(oldBody) == true)
        XCTAssertFalse(selection?.archiveText.contains(newBody) == true)
        XCTAssertFalse(selection?.archiveText.contains(diffOutput) == true)
    }

    func testReadOnlyToolContainingErrorTextDoesNotResetRoutineEffort() {
        var session = DeferredToolSession()
        _ = session.control(
            AgentToolCall(id: "plan-1", name: DeferredToolSession.planName, arguments: #"{"steps":["Update config"],"routine":true,"uncertainties":[]}"#),
            catalog: [],
            planMode: false
        )
        XCTAssertEqual(session.effort(selected: "high", planMode: false), "low")

        session.record("Error: something failed in log line 42", callID: "call-1", toolName: "read_file")
        session.record("Tool error: no matches", callID: "call-2", toolName: "grep_files")
        XCTAssertEqual(session.effort(selected: "high", planMode: false), "low")

        session.record("Error: build failed", callID: "call-3", toolName: "run_command")
        XCTAssertEqual(session.effort(selected: "high", planMode: false), "high")
    }
}

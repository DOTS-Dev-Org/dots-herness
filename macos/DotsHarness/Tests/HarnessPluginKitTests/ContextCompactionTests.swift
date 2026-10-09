import XCTest
@testable import DotsHarnessCore

final class ContextCompactionTests: XCTestCase {
    func testEconomyPolicyUsesNinetyPercentAndReservesLargeDynamicOutput() {
        let budget = AgentContextCompaction.budget(
            contextWindow: 32_768,
            reservedOutputTokens: 20_000,
            toolDefinitionTokens: 1_000,
            policy: .economy
        )

        XCTAssertEqual(budget.policy.triggerRatio, 0.90, accuracy: 0.0001)
        XCTAssertEqual(budget.triggerTokens, Int(Double(budget.usableInputTokens) * 0.90))
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

    func testCompactionPoliciesUseNinetyPercentDefaultAndIgnoreLegacyOverrides() {
        XCTAssertEqual(AgentContextCompactionPolicy.baseline.triggerRatio, 0.90)
        XCTAssertEqual(AgentContextCompactionPolicy.baseline.targetRatio, 0.65)
        XCTAssertEqual(AgentContextCompactionPolicy.cacheAware.triggerRatio, 0.80)
        XCTAssertEqual(AgentContextCompactionPolicy.cacheAware.targetRatio, 0.55)
        XCTAssertEqual(AgentContextCompactionPolicy.highRetention.triggerRatio, 0.85)
        XCTAssertEqual(AgentContextCompactionPolicy.highRetention.targetRatio, 0.65)

        let suiteName = "ContextCompactionTests-\(UUID().uuidString)"
        let defaults = try! XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(
            AgentContextCompactionPolicy.ID.cacheAware.rawValue,
            forKey: AgentContextCompactionPolicy.userDefaultsKey
        )

        let migrated = AgentContextCompactionPolicy.current(defaults: defaults)
        XCTAssertEqual(migrated.id, .custom)
        XCTAssertEqual(migrated.triggerRatio, 0.90, accuracy: 0.0001)
    }

    func testUserThresholdAndReplayBudgetBoundEachModelsContextWindow() throws {
        let suiteName = "ContextCompactionTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(AgentContextCompactionPolicy.current(defaults: defaults).triggerRatio, 0.90, accuracy: 0.0001)

        defaults.set(70.0, forKey: AgentContextCompactionPolicy.triggerPercentKey)
        let percent = AgentContextCompactionPolicy.current(defaults: defaults)
        XCTAssertEqual(percent.id, .custom)
        XCTAssertEqual(percent.triggerTokens(window: 250_000), 32_768)
        XCTAssertEqual(percent.triggerTokens(window: 1_000_000), 32_768)

        // The old ignored key cannot override the new replay budget.
        defaults.set(300_000, forKey: AgentContextCompactionPolicy.maxTokensKey)
        let withoutLegacyCap = AgentContextCompactionPolicy.current(defaults: defaults)
        XCTAssertEqual(withoutLegacyCap.triggerTokens(window: 1_000_000), 32_768)
        XCTAssertEqual(withoutLegacyCap.maxTokens, 32_768)

        defaults.set(800_000, forKey: AgentContextCompactionPolicy.replayBudgetKey)
        XCTAssertEqual(AgentContextCompactionPolicy.current(defaults: defaults).triggerTokens(window: 1_000_000), 700_000)

        defaults.set(0, forKey: AgentContextCompactionPolicy.triggerPercentKey)
        XCTAssertEqual(AgentContextCompactionPolicy.current(defaults: defaults).triggerTokens(window: 1_000), 1)
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

        XCTAssertTrue(selection?.stableSystem.contains(where: { $0.content.contains("Response language") }) == true)
        let composed = selection?.compose(summary: "summary", preserveProviderItems: false)
        XCTAssertTrue(composed?.contains(where: { $0.role == .system && $0.content.contains("Response language") }) == true)
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
        XCTAssertTrue(selection?.stableSystem.contains(where: { $0.content.contains("Response language") }) == true)
    }
}

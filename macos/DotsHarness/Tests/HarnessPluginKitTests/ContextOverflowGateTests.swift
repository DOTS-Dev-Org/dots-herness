// Copyright (c) 2026 DOTS

import Foundation
import PluginRuntime
import XCTest
@testable import DotsHarnessCore

@MainActor
final class ContextOverflowGateTests: XCTestCase {
    private func temporaryPaths() -> SupportPaths {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DotsContextOverflowTests-\(UUID().uuidString)", isDirectory: true)
        return SupportPaths(
            root: root,
            plugins: root.appendingPathComponent("plugins", isDirectory: true),
            presets: root.appendingPathComponent("presets", isDirectory: true),
            settings: root.appendingPathComponent("settings.json"),
            hostPatch: root.appendingPathComponent("host.patch.yml"),
            trust: root.appendingPathComponent("trust.json"),
            models: root.appendingPathComponent("models", isDirectory: true),
            runtime: root.appendingPathComponent("runtime", isDirectory: true)
        )
    }

    private func account(_ id: String, provider: String, cooldownUntil: Date? = nil) -> StoredProviderAccount {
        StoredProviderAccount(
            id: id,
            provider: provider,
            name: id,
            active: true,
            model: "\(provider)-heavy",
            baseURL: "https://\(provider).test",
            api: "openai-compatible",
            credentialID: "account.\(id)",
            priority: 0,
            cooldownUntil: cooldownUntil
        )
    }

    /// Two accounts, each with a premium and a light model, so a choice between
    /// them is a choice about quota and not about availability.
    private func router(
        previousCooldown: Date? = nil,
        modelWindow: Int = 200_000
    ) throws -> RouterController {
        let paths = temporaryPaths()
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        let state = StoredProviderState(accounts: [
            account("old", provider: "oldprov", cooldownUntil: previousCooldown),
            account("new", provider: "newprov"),
        ])
        try JSONEncoder().encode(state).write(
            to: paths.root.appendingPathComponent("provider-state.json"),
            options: .atomic
        )
        let router = RouterController(baseURL: "http://127.0.0.1:1", paths: paths)
        router.models = [
            RouterModel(id: "old-heavy", owner: "oldprov", contextWindow: modelWindow, provider: "oldprov", tier: .premium),
            RouterModel(id: "old-light", owner: "oldprov", contextWindow: modelWindow, provider: "oldprov", tier: .light),
            RouterModel(id: "new-heavy", owner: "newprov", contextWindow: modelWindow, provider: "newprov", tier: .premium),
            RouterModel(id: "new-light", owner: "newprov", contextWindow: modelWindow, provider: "newprov", tier: .light),
        ]
        return router
    }

    // MARK: - how much a summarizer is asked to read

    func testArchiveUsesTheCeilingWhenTheWindowIsLarge() {
        let budget = AgentContextCompaction.budget(contextWindow: 200_000)
        XCTAssertEqual(
            AgentContextCompaction.archiveCharacters(fitting: budget),
            AgentContextCompaction.maxArchiveCharacters
        )
    }

    /// The reason the archive is sized to its reader: a small model asked to write
    /// the summary must not itself run out of context on the way in.
    func testArchiveShrinksToLeaveRoomForTheSummaryRequest() {
        let budget = AgentContextCompaction.budget(contextWindow: 8_000)
        let characters = AgentContextCompaction.archiveCharacters(fitting: budget)
        XCTAssertLessThan(characters, AgentContextCompaction.maxArchiveCharacters)
        XCTAssertEqual(
            characters,
            (budget.usableInputTokens - AgentContextCompaction.summaryRequestOverheadTokens) * 4
        )
    }

    func testSummarizerThresholdCoversTheWorstCaseArchive() {
        XCTAssertEqual(
            AgentContextCompaction.summarizerTokens,
            AgentContextCompaction.maxArchiveCharacters / 4 + AgentContextCompaction.summaryRequestOverheadTokens
        )
    }

    // MARK: - reading back the route a conversation ran on

    func testRouteIdentityExposesAccountAndModel() {
        let parsed = NativeAgentHost.parsedRoute("anthropic|claude|acct-1|https://api.example.test|claude-opus-4")
        XCTAssertEqual(parsed.accountID, "acct-1")
        XCTAssertEqual(parsed.model, "claude-opus-4")
    }

    func testSeparatorInsideBaseURLCannotShiftTheModel() {
        let parsed = NativeAgentHost.parsedRoute("openai|gpt|acct-2|https://a.test/x|y|gpt-6-luna")
        XCTAssertEqual(parsed.accountID, "acct-2")
        XCTAssertEqual(parsed.model, "gpt-6-luna")
    }

    func testUnresolvedRouteStillNamesTheStickyAccount() {
        let parsed = NativeAgentHost.parsedRoute("unresolved|acct-3|gpt-6-luna")
        XCTAssertEqual(parsed.accountID, "acct-3")
        XCTAssertEqual(parsed.model, "gpt-6-luna")
    }

    func testAutoSentinelIsNotReportedAsAModel() {
        XCTAssertNil(NativeAgentHost.parsedRoute("anthropic|claude|acct-1||auto").model)
        XCTAssertNil(NativeAgentHost.parsedRoute("").accountID)
    }

    // MARK: - who writes the summary

    func testSummarizerSpendsTheQuotaOfTheAccountThatServedTheConversation() throws {
        let pick = try router().contextSummarizer(
            previousAccountID: "old",
            targetAccountID: "new",
            archiveTokens: AgentContextCompaction.summarizerTokens
        )
        XCTAssertEqual(pick?.accountID, "old")
        XCTAssertEqual(pick?.model, "old-light")
    }

    func testSummarizerMovesToTheDestinationAccountWithoutQuota() throws {
        let router = try router()
        router.accountUsage = ["old": AccountUsageSnapshot(remainingFraction: 0)]
        let pick = router.contextSummarizer(
            previousAccountID: "old",
            targetAccountID: "new",
            archiveTokens: AgentContextCompaction.summarizerTokens
        )
        XCTAssertEqual(pick?.accountID, "new")
        XCTAssertEqual(pick?.model, "new-light")
    }

    func testSummarizerSkipsACoolingAccount() throws {
        let router = try router(previousCooldown: Date().addingTimeInterval(600))
        XCTAssertEqual(
            router.contextSummarizer(
                previousAccountID: "old",
                targetAccountID: "new",
                archiveTokens: AgentContextCompaction.summarizerTokens
            )?.accountID,
            "new"
        )
    }

    /// Nothing can hold the transcript, so the caller has to compact locally
    /// instead of promising a summary that would overflow as well.
    func testSummarizerDeclinesWhenNoModelCanReadTheArchive() throws {
        let router = try router(modelWindow: 4_000)
        XCTAssertNil(router.contextSummarizer(
            previousAccountID: "old",
            targetAccountID: "new",
            archiveTokens: AgentContextCompaction.summarizerTokens
        ))
    }

    func testSummarizerIgnoresAnInactiveAccount() throws {
        let paths = temporaryPaths()
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        var old = account("old", provider: "oldprov")
        old.active = false
        try JSONEncoder().encode(StoredProviderState(accounts: [old, account("new", provider: "newprov")]))
            .write(to: paths.root.appendingPathComponent("provider-state.json"), options: .atomic)
        let router = RouterController(baseURL: "http://127.0.0.1:1", paths: paths)
        router.models = [
            RouterModel(id: "old-light", owner: "oldprov", contextWindow: 200_000, provider: "oldprov", tier: .light),
        ]
        XCTAssertEqual(
            router.contextSummarizer(
                previousAccountID: "old",
                targetAccountID: "new",
                archiveTokens: AgentContextCompaction.summarizerTokens
            )?.accountID,
            "new"
        )
    }
}

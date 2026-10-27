// Copyright (c) 2026 DOTS

import Foundation
import PluginRuntime
import XCTest
@testable import DotsHarnessCore

/// Compaction waits for 90% of the provider's window. A cap that is applied
/// silently rewrites history at a few tens of thousands of tokens, and every
/// rewrite drops the cached prefix of a route that caches its prompt.
@MainActor
final class CompactionThresholdTests: XCTestCase {
    func testEveryRouteCompactsAtNinetyPercentOfItsWindow() {
        let budget = AgentContextCompaction.budget(
            contextWindow: 1_050_000, reservedOutputTokens: 37_888, toolDefinitionTokens: 5_200, policy: .baseline
        )
        XCTAssertEqual(budget.triggerTokens, 945_000)
    }

    func testProviderContextWindowErrorsAreDistinctFromQuotaLimits() throws {
        let payload = try JSONCodec.parse(Data(#"{"error":{"code":"context_length_exceeded","message":"Request rejected"}}"#.utf8))
        XCTAssertTrue(NativeAgentClient.contextWindowOverflow(from: payload))
        XCTAssertTrue(NativeAgentError("Your input exceeds the model context window.").isContextWindowExceeded)

        let quota = NativeAgentError("You have exceeded your monthly quota.", statusCode: 429, isLimit: true)
        XCTAssertFalse(quota.isContextWindowExceeded)
    }

    /// The model list is refreshed live and can lack a model for a while. The route's
    /// window must still come from the provider's documented capacity, not 32K.
    func testRouteWindowHoldsWhenTheCatalogLacksTheModel() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DotsThresholdTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let paths = SupportPaths(
            root: root,
            plugins: root.appendingPathComponent("plugins", isDirectory: true),
            presets: root.appendingPathComponent("presets", isDirectory: true),
            settings: root.appendingPathComponent("settings.json"),
            hostPatch: root.appendingPathComponent("host.patch.yml"),
            trust: root.appendingPathComponent("trust.json"),
            models: root.appendingPathComponent("models", isDirectory: true),
            runtime: root.appendingPathComponent("runtime", isDirectory: true)
        )
        let account = StoredProviderAccount(
            id: "gateway",
            provider: "gpt",
            name: "gateway",
            authType: "chatgpt",
            model: "gpt-5.6-terra",
            baseURL: "https://chatgpt.test",
            api: RouterAPIKind.chatGPT.rawValue,
            credentialID: "account.gateway"
        )
        try JSONEncoder().encode(StoredProviderState(accounts: [account])).write(
            to: root.appendingPathComponent("provider-state.json"), options: .atomic
        )
        let router = RouterController(baseURL: "http://127.0.0.1:1", paths: paths)
        router.models = []

        XCTAssertEqual(router.contextWindow(for: "gpt-6-luna", provider: "gpt"), 1_050_000)
        let config = try router.configuration(for: account, model: "gpt-6-luna", loadCredentials: false)
        XCTAssertEqual(config.contextWindow, 1_050_000)
        XCTAssertEqual(config.compactionPolicy, .baseline)
        try? FileManager.default.removeItem(at: root)
    }

    /// A failed catalog read must keep the last good listing of that provider, so its
    /// windows survive the failure and the selected model does not disappear.
    func testFailedListingKeepsTheLastGoodModelsOfThatProvider() {
        let known = [
            RouterModel(id: "gpt-6-luna", owner: "ChatGPT", contextWindow: 1_050_000, provider: "gpt"),
            RouterModel(id: "claude-sonnet-5", owner: "Claude", contextWindow: 200_000, provider: "claude"),
        ]
        let kept = RouterController.carriedListing(provider: "gpt", from: known)
        XCTAssertEqual(kept.map(\.id), ["gpt-6-luna"])
        XCTAssertEqual(kept.first?.contextWindow, 1_050_000)
    }
}

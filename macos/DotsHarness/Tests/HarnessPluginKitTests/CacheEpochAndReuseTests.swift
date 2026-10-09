import XCTest
import HarnessPluginKit
import PluginRuntime
@testable import DotsHarnessCore

final class CacheEpochAndReuseTests: XCTestCase {
    private func tool(_ name: String, description: String = "Read") -> AgentToolDefinition {
        .init(name: name, description: description, parameters: .object(["type": .string("object")]))
    }

    func testCatalogOrderDoesNotRotateEpochButSchemaAndBindingChangesDo() {
        let a = tool("a"), b = tool("b")
        var epoch = AgentConversationCacheEpoch(tools: [a, b], bindingsFingerprint: "one", policyFingerprint: "policy", contextSegment: 0)
        let id = epoch.id
        epoch.reconcile(tools: [b, a], bindings: "one", policy: "policy", segment: 0)
        XCTAssertEqual(epoch.id, id)
        epoch.reconcile(tools: [a, tool("b", description: "Write")], bindings: "one", policy: "policy", segment: 0)
        XCTAssertNotEqual(epoch.id, id)
        let changed = epoch.id
        epoch.reconcile(tools: [a, tool("b", description: "Write")], bindings: "two", policy: "policy", segment: 0)
        XCTAssertNotEqual(epoch.id, changed)
        XCTAssertEqual(epoch.lastChangeReason, "catalog_changed")
    }

    func testRevisionNoticesAppendOnceAndDoNotRewriteToolGroupOrOldUser() {
        let call = AgentToolCall(id: "call", name: "read_file", arguments: "{}")
        let prefix: [AgentMessage] = [.init(role: .user, content: "original"),
            .init(role: .assistant, content: "", toolCalls: [call]),
            .init(role: .tool, content: "immutable result", toolCallID: call.id)]
        var messages = prefix
        var epoch = AgentConversationCacheEpoch(tools: [], bindingsFingerprint: "", policyFingerprint: "", contextSegment: 0)
        epoch.appendNotice(key: "attachment", fingerprint: "changed-v2", text: "changed", to: &messages)
        epoch.appendNotice(key: "attachment", fingerprint: "changed-v2", text: "changed", to: &messages)
        XCTAssertEqual(Array(messages.prefix(prefix.count)), prefix)
        XCTAssertEqual(messages.count, prefix.count + 1)
        XCTAssertTrue(messages.last!.promptContextCaptured)
        epoch.appendNotice(key: "attachment", fingerprint: "missing", text: "missing", to: &messages)
        XCTAssertEqual(Array(messages.prefix(prefix.count)), prefix)
        XCTAssertEqual(messages.count, prefix.count + 2)
    }

    func testOldConversationAndNewEpochRoundTrip() throws {
        let old = try JSONDecoder().decode(Conversation.self, from: Data(#"{"id":"old","title":"old"}"#.utf8))
        XCTAssertNil(old.cacheEpoch)
        var conversation = old
        conversation.cacheEpoch = .init(tools: [tool("read")], bindingsFingerprint: "b", policyFingerprint: "p", contextSegment: 0)
        let saved = try JSONEncoder().encode(conversation)
        XCTAssertEqual(try JSONDecoder().decode(Conversation.self, from: saved).cacheEpoch, conversation.cacheEpoch)
    }

    @MainActor
    func testDisabledPluginKeepsDefinitionsButHasNoExecutableClosureAndRemovalDropsCatalog() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let paths = SupportPaths(root: root, plugins: root.appendingPathComponent("plugins"), presets: root.appendingPathComponent("presets"),
            settings: root.appendingPathComponent("settings"), hostPatch: root.appendingPathComponent("patch"),
            trust: root.appendingPathComponent("trust"), models: root.appendingPathComponent("models"), runtime: root.appendingPathComponent("runtime"))
        paths.ensure()
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = PluginCatalog(paths: paths)
        catalog.registerBuiltin(CacheFixturePlugin.self)
        let host = PluginHost(catalog: catalog)
        var entry = CompositionEntry(id: "fixture-owner", plugin: CacheFixturePlugin.manifest.id)
        XCTAssertTrue(host.mount(.init(plane: .host, entries: [entry])).isEmpty)
        let definitions = host.cacheableTools()
        XCTAssertEqual(definitions.count, 1)
        entry.disabled = true
        XCTAssertTrue(host.mount(.init(plane: .host, entries: [entry])).isEmpty)
        XCTAssertEqual(host.cacheableTools(), definitions)
        XCTAssertTrue(host.tools.tools().isEmpty)
        do {
            _ = try await host.tools.call("fixture.read", arguments: [:])
            XCTFail("disabled cached tools must never execute")
        } catch { }
        let restored = PluginHost(catalog: catalog)
        XCTAssertEqual(restored.cacheableTools(), definitions)
        XCTAssertTrue(restored.tools.tools().isEmpty)
        XCTAssertTrue(host.mount(.init(plane: .host, entries: [])).isEmpty)
        XCTAssertTrue(host.cacheableTools().isEmpty)
    }

    private func event(_ eligible: Int?, _ reused: Int?, classification: String = "eligible", reason: String? = nil) -> AgentContextUsageEvent {
        .init(conversationID: "one", provider: "Claude", api: "anthropic", model: "model", cacheKey: "key",
              requestKind: .main, strategy: .none, policyID: .baseline,
              usage: .init(inputTokens: 10, outputTokens: 1, cachedTokens: reused, cacheWriteTokens: 0),
              contextTokensBefore: 0, contextTokensAfter: 0, latencyMilliseconds: 5,
              cacheReuseEvidence: .init(prefixFingerprint: "prefix", settingsFingerprint: "settings",
                  classification: classification, reason: reason, evidenceSource: "provider_terminal_usage",
                  eligibleTokens: eligible, reusedTokens: reused))
    }

    @MainActor
    func testFailedPluginMountRetainsSuccessfulCatalogAndDisposesThrowingContext() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let paths = SupportPaths(root: root, plugins: root.appendingPathComponent("plugins"), presets: root.appendingPathComponent("presets"),
            settings: root.appendingPathComponent("settings"), hostPatch: root.appendingPathComponent("patch"),
            trust: root.appendingPathComponent("trust"), models: root.appendingPathComponent("models"), runtime: root.appendingPathComponent("runtime"))
        paths.ensure()
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = PluginCatalog(paths: paths)
        catalog.registerBuiltin(CacheFixturePlugin.self)
        catalog.registerBuiltin(CacheThrowingFixturePlugin.self)
        let host = PluginHost(catalog: catalog)
        var entry = CompositionEntry(id: "fixture-owner", plugin: CacheFixturePlugin.manifest.id)
        XCTAssertTrue(host.mount(.init(plane: .host, entries: [entry])).isEmpty)
        let successful = host.cacheableTools()
        entry.config = ["description": .string("Changed contract")]
        let failing = CompositionEntry(id: "throwing-owner", plugin: CacheThrowingFixturePlugin.manifest.id)
        XCTAssertFalse(host.mount(.init(plane: .host, entries: [entry, failing])).isEmpty)
        XCTAssertEqual(host.cacheableTools(), successful)
        XCTAssertTrue(host.tools.tools().isEmpty)
        XCTAssertEqual(PluginHost(catalog: catalog).cacheableTools(), successful)
        XCTAssertTrue(host.mount(.init(plane: .host, entries: [entry])).isEmpty)
        XCTAssertNotEqual(host.cacheableTools(), successful)
    }

    func testReuseIsTokenWeightedAndEvictionIsARealMiss() {
        let summary = AgentCacheReuseSummary(events: [event(900, 900), event(100, 0, reason: "cache_evicted")])
        XCTAssertEqual(summary.reuseRate!, 0.9, accuracy: 0.00001)
        XCTAssertEqual(summary.coverage, 1)
        XCTAssertEqual(summary.lostTokensByReason["cache_evicted"], 100)
        XCTAssertFalse(summary.targetMet)
    }

    func testFreshInputOutsideEligiblePrefixIsNotCacheLoss() {
        let response = AgentContextUsageEvent(conversationID: "one", provider: "ChatGPT", api: "chatgpt",
            model: "gpt-5.6-luna", cacheKey: "key", requestKind: .main, strategy: .none,
            policyID: .baseline,
            usage: .init(inputTokens: 14_640, outputTokens: 1, cachedTokens: 14_080, cacheWriteTokens: 0),
            contextTokensBefore: 0, contextTokensAfter: 0, latencyMilliseconds: 5,
            cacheReuseEvidence: .init(prefixFingerprint: "prefix", settingsFingerprint: "settings",
                classification: "eligible", evidenceSource: "provider_terminal_usage",
                eligibleTokens: 14_080, reusedTokens: 14_080))
        let summary = AgentCacheReuseSummary(events: [response])
        XCTAssertEqual(summary.reuseRate, 1)
        XCTAssertEqual(summary.freshInputTokens, 560)
        XCTAssertTrue(summary.lostTokensByReason.isEmpty)
    }

    func testQuantizedProviderTailRemainsFreshInputAcrossRepeatedReads() {
        let responses = [14_641, 14_792].map { input in
            AgentContextUsageEvent(conversationID: "one", provider: "ChatGPT", api: "chatgpt",
                model: "gpt-5.6-luna", cacheKey: "key", requestKind: .main, strategy: .none,
                policyID: .baseline,
                usage: .init(inputTokens: input, outputTokens: 1, cachedTokens: 14_080, cacheWriteTokens: 0),
                contextTokensBefore: 0, contextTokensAfter: 0, latencyMilliseconds: 5,
                cacheReuseEvidence: .init(prefixFingerprint: "prefix", settingsFingerprint: "settings",
                    classification: "eligible", evidenceSource: "provider_terminal_usage",
                    eligibleTokens: 14_080, reusedTokens: 14_080))
        }
        let summary = AgentCacheReuseSummary(events: responses)
        XCTAssertEqual(summary.reuseRate, 1)
        XCTAssertEqual(summary.freshInputTokens, (14_641 - 14_080) + (14_792 - 14_080))
        XCTAssertTrue(summary.lostTokensByReason.isEmpty)
    }

    func testUnknownCountsReduceCoverageAndInvalidEvidenceNeverCreatesAHit() {
        let summary = AgentCacheReuseSummary(events: [event(1000, 1000), event(nil, nil, classification: "inconclusive"), event(100, 101)])
        XCTAssertEqual(summary.reuseRate, 1)
        XCTAssertEqual(summary.coverage!, 1.0 / 3, accuracy: 0.00001)
        XCTAssertEqual(summary.unknownRequests, 2)
        XCTAssertFalse(summary.targetMet)
    }

    func testColdExpiryAndIntentionalChangesStaySeparatelyVisible() {
        let summary = AgentCacheReuseSummary(events: [event(10000, 9990), event(nil, nil, classification: "cold"),
            event(nil, nil, classification: "expired"), event(nil, nil, classification: "changed")])
        XCTAssertEqual(summary.reuseRate!, 0.999, accuracy: 0.000001)
        XCTAssertEqual(summary.coldRequests, 1)
        XCTAssertEqual(summary.expiredRequests, 1)
        XCTAssertEqual(summary.changedRequests, 1)
        XCTAssertTrue(summary.targetMet)
    }

    func testRollingWindowRetainsOnlyLastHundredCandidates() {
        let summary = AgentCacheReuseSummary(events: [event(100000, 0)] + (0..<100).map { _ in event(1000, 1000) })
        XCTAssertEqual(summary.candidateRequests, 100)
        XCTAssertEqual(summary.reuseRate, 1)
    }
}

private final class CacheFixturePlugin: DefaultPlugin {
    static let manifest = PluginManifest(id: "cache.fixture", name: "Cache fixture", version: "1.0", plane: .host)
    init() { }
    @MainActor func apply(_ context: PluginContext) throws {
        context.tools.register(name: "fixture.read", description: context.config["description"]?.string ?? "Read", parameters: []) { _ in "immutable" }
    }
}

private final class CacheThrowingFixturePlugin: DefaultPlugin {
    static let manifest = PluginManifest(id: "cache.throwing", name: "Throwing fixture", version: "1.0", plane: .host)
    init() { }
    @MainActor func apply(_ context: PluginContext) throws {
        context.tools.register(name: "fixture.partial", description: "Partial", parameters: []) { _ in "must be disposed" }
        throw PluginError.missingService("fixture.failure")
    }
}

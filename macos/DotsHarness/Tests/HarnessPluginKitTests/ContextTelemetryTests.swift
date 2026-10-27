import XCTest
import PluginRuntime
@testable import DotsHarnessCore

final class ContextTelemetryTests: XCTestCase {
    func testUsageBreakdownUsesProviderSpecificCacheSemantics() {
        let openAI = AgentUsage(inputTokens: 100, outputTokens: 5, cachedTokens: 70, cacheWriteTokens: 10)
            .breakdown(forAPI: RouterAPIKind.openAICompatible.rawValue)
        XCTAssertEqual(openAI.uncachedInputTokens, 20)
        XCTAssertEqual(openAI.totalInputTokens, 100)

        let anthropic = AgentUsage(inputTokens: 20, outputTokens: 5, cachedTokens: 70, cacheWriteTokens: 10)
            .breakdown(forAPI: RouterAPIKind.anthropic.rawValue)
        XCTAssertEqual(anthropic.uncachedInputTokens, 20)
        XCTAssertEqual(anthropic.totalInputTokens, 100)
    }

    func testPricingAndLedgerNeverPersistPromptContent() throws {
        let usage = AgentUsage(inputTokens: 100, outputTokens: 20, cachedTokens: 70, cacheWriteTokens: 10)
        let pricing = AgentTokenPricing(
            uncachedInputPerMillion: 1,
            cachedInputPerMillion: 0.5,
            cacheWritePerMillion: 2,
            outputPerMillion: 3
        )
        XCTAssertEqual(
            pricing.estimatedCost(usage: usage, api: RouterAPIKind.openAICompatible.rawValue),
            0.000135,
            accuracy: 0.000000001
        )

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DotsHarnessTelemetry-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
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
        paths.ensure()
        let store = AgentContextTelemetryStore(paths: paths, maxEvents: 2)

        for index in 0..<3 {
            store.append(AgentContextUsageEvent(
                conversationID: "conversation",
                provider: "OpenAI",
                api: RouterAPIKind.openAICompatible.rawValue,
                model: "test-model",
                cacheKey: "stable-prefix",
                requestKind: .main,
                strategy: .none,
                policyID: .baseline,
                usage: usage,
                contextTokensBefore: 1000 + index,
                contextTokensAfter: 900,
                latencyMilliseconds: 10
            ))
        }

        let events = store.events()
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events.last?.contextTokensBefore, 1002)
        let raw = try String(contentsOf: store.fileURL, encoding: .utf8)
        XCTAssertFalse(raw.contains("prompt content"))
        XCTAssertFalse(raw.contains("tool arguments"))
    }

    func testLedgerAppendsInPlaceAndTrimsPastTheSlack() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DotsHarnessTelemetry-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
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
        paths.ensure()
        func event(_ index: Int) -> AgentContextUsageEvent {
            AgentContextUsageEvent(
                conversationID: "conversation", provider: "OpenAI",
                api: RouterAPIKind.openAICompatible.rawValue, model: "test-model", cacheKey: nil,
                requestKind: .main, strategy: .none, policyID: .baseline,
                contextTokensBefore: index, contextTokensAfter: 0, latencyMilliseconds: 1,
                cpu: AgentStepCPUTrace(prepareStages: ["save": 3], requestMainThread: 5, requestProcess: 9)
            )
        }
        let store = AgentContextTelemetryStore(paths: paths, maxEvents: 10)
        for index in 0..<11 { store.append(event(index)) }
        // A fresh reader decodes the spliced file, not the writer's cache.
        let reread = AgentContextTelemetryStore(paths: paths, maxEvents: 10).events()
        XCTAssertEqual(reread.map(\.contextTokensBefore), Array(0..<11))
        XCTAssertEqual(reread.last?.cpu?.prepareMainThread, 3)
        XCTAssertNotNil(reread.last?.previousRequestGapSeconds)

        store.append(event(11))
        let trimmed = AgentContextTelemetryStore(paths: paths, maxEvents: 10).events()
        XCTAssertEqual(trimmed.map(\.contextTokensBefore), Array(2..<12))
    }

    func testRetryUsageIsStoredSeparatelyFromTheSuccessfulAttempt() {
        let event = AgentContextUsageEvent(
            conversationID: "conversation",
            provider: "OpenAI",
            api: RouterAPIKind.openAICompatible.rawValue,
            model: "test-model",
            cacheKey: "stable-prefix",
            requestKind: .main,
            strategy: .none,
            policyID: .baseline,
            retryCount: 1,
            retryUsage: AgentUsage(inputTokens: 80, outputTokens: 200, reasoningTokens: 120),
            usage: AgentUsage(inputTokens: 100, outputTokens: 40),
            contextTokensBefore: 1000,
            contextTokensAfter: 900,
            latencyMilliseconds: 10
        )

        XCTAssertEqual(event.retryCount, 1)
        XCTAssertEqual(event.retryInputTokens, 80)
        XCTAssertEqual(event.retryOutputTokens, 200)
        XCTAssertEqual(event.retryReasoningTokens, 120)
        XCTAssertEqual(event.inputTokens, 100)
        XCTAssertEqual(event.outputTokens, 40)
    }

    @MainActor
    func testLiveRunTokenCountAccumulatesAcrossRequests() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DotsHarnessRunTokens-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
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
        let host = NativeAgentHost(
            paths: paths,
            endpoint: AgentEndpointController(baseURL: "http://127.0.0.1:1", modelID: "test")
        )
        host.start(workspacePath: root.path)
        host.newConversation()
        let conversationID = try XCTUnwrap(host.selectedID)
        host.activeConversationID = conversationID
        let configuration = AgentConfiguration(
            baseURL: "https://example.test", model: "test", api: RouterAPIKind.openAICompatible.rawValue
        )

        for (input, output, cached, cacheWrite) in [(100, 10, 70, 10), (50, 5, 20, 5)] {
            let response = AgentResponse(
                message: AgentMessage(role: .assistant, content: "ok"),
                usage: AgentUsage(
                    inputTokens: input,
                    outputTokens: output,
                    cachedTokens: cached,
                    cacheWriteTokens: cacheWrite
                )
            )
            host.recordContextUsage(
                response,
                conversationID: conversationID,
                configuration: configuration,
                cacheKey: nil,
                requestKind: .main,
                strategy: .none,
                contextTokensBefore: 0,
                contextTokensAfter: 0,
                startedAt: Date()
            )
        }

        // Newly processed input is (100 - 70 cached + 10 written) and
        // (50 - 20 cached + 5 written), plus 15 output tokens.
        XCTAssertEqual(host.activeRunTokenCount, 75)
        XCTAssertEqual(host.activeRunUncachedInputTokenCount, 25, "the latest request input is distinct from the run total")
        XCTAssertFalse(host.activeRunTokenCountIncludesEstimate)

        let estimatedComposition = AgentContextInputComposition(
            messages: [AgentMessage(role: .user, content: String(repeating: "estimated prompt ", count: 20))],
            tools: []
        )
        let estimatedInputTokens = estimatedComposition.estimatedTotalTokens
        XCTAssertGreaterThan(estimatedInputTokens, 0)
        let responseWithZeroReportedInput = AgentResponse(
            message: AgentMessage(role: .assistant, content: "ok"),
            usage: AgentUsage(inputTokens: 0, outputTokens: 2, cachedTokens: 0, cacheWriteTokens: 0)
        )
        host.recordContextUsage(
            responseWithZeroReportedInput,
            conversationID: conversationID,
            configuration: configuration,
            cacheKey: nil,
            requestKind: .main,
            strategy: .none,
            contextTokensBefore: 0,
            contextTokensAfter: 0,
            startedAt: Date(),
            inputComposition: estimatedComposition
        )
        XCTAssertEqual(host.activeRunTokenCount, 77 + estimatedInputTokens)
        XCTAssertTrue(host.activeRunTokenCountIncludesEstimate)

        let responseWithoutCacheBreakdown = AgentResponse(
            message: AgentMessage(role: .assistant, content: "ok"),
            usage: AgentUsage(inputTokens: 40, outputTokens: 3)
        )
        host.recordContextUsage(
            responseWithoutCacheBreakdown,
            conversationID: conversationID,
            configuration: configuration,
            cacheKey: nil,
            requestKind: .main,
            strategy: .none,
            contextTokensBefore: 0,
            contextTokensAfter: 0,
            startedAt: Date()
        )
        XCTAssertEqual(host.activeRunTokenCount, 120 + estimatedInputTokens)
        XCTAssertEqual(host.activeRunUncachedInputTokenCount, 40)
        XCTAssertTrue(host.activeRunTokenCountIncludesEstimate)
    }
}

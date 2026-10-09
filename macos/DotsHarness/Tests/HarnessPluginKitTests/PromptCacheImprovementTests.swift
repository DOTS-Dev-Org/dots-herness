import XCTest
import Foundation
import PluginRuntime
@testable import DotsHarnessCore

final class PromptCacheImprovementTests: XCTestCase {
    private func event(_ usage: AgentUsage?, api: String = "anthropic", kind: AgentContextRequestKind = .main,
                       at: Date = Date(), trace: AgentCacheTrace? = nil, key: String = "key") -> AgentContextUsageEvent {
        AgentContextUsageEvent(timestamp: at, conversationID: "conversation", provider: "test", api: api,
            model: "model", cacheKey: key, requestKind: kind, strategy: .none, policyID: .baseline,
            usage: usage, contextTokensBefore: 0, contextTokensAfter: 0, latencyMilliseconds: 0, cacheTrace: trace)
    }

    func testSummaryIncludesWritesExcludesUnknownAndSummaryRequests() {
        let events = [event(AgentUsage(inputTokens: 2, outputTokens: 1, cachedTokens: 7834, cacheWriteTokens: 769)),
            event(AgentUsage(inputTokens: 10000, outputTokens: 1), api: "openai-compatible"),
            event(AgentUsage(inputTokens: 0, outputTokens: 1, cachedTokens: 10000), kind: .compactionSummary)]
        let summary = AgentContextCacheSummary(events: events)
        XCTAssertEqual(summary.requestCount, 2)
        XCTAssertEqual(summary.unknownRequestCount, 1)
        XCTAssertEqual(summary.unknownInputTokens, 10000)
        XCTAssertEqual(summary.measuredInputTokens, 8605)
        XCTAssertEqual(summary.cacheWriteTokens, 769)
        XCTAssertEqual(summary.cacheHitRate!, 7834.0 / 8605, accuracy: 0.000001)
    }

    func testReportedZeroIsMeasuredWhileAbsentCacheFieldsStayUnknown() {
        let zero = AgentUsage(inputTokens: 100, outputTokens: 1, cachedTokens: 0)
        XCTAssertEqual(zero.breakdown(forAPI: "openai-compatible").cacheHitRate, 0)
        XCTAssertEqual(event(zero, api: "openai-compatible").measuredCacheHitRate, 0)
        XCTAssertNil(AgentUsage(inputTokens: 100, outputTokens: 1).breakdown(forAPI: "openai-compatible").cacheHitRate)
        XCTAssertNil(AgentContextCacheSummary(events: [event(nil)]).cacheHitRate)
    }

    func testSummaryWeightsTokensRatherThanAveragingRequestPercentages() {
        let summary = AgentContextCacheSummary(events: [
            event(AgentUsage(inputTokens: 100, outputTokens: 1, cachedTokens: 100), api: "openai-compatible"),
            event(AgentUsage(inputTokens: 900, outputTokens: 1, cachedTokens: 0), api: "openai-compatible")])
        XCTAssertEqual(summary.cacheHitRate!, 0.1, accuracy: 0.000001)
    }

    func testTraceSeparatesToolChangesAndElapsedTTLWithoutClaimingAMiss() {
        let start = Date(timeIntervalSince1970: 10000)
        let trace: (String, Date) -> AgentCacheTrace = { fingerprint, time in
            AgentCacheTrace(toolFingerprint: fingerprint, policyRevision: 1, contextSegment: 0,
                            ttlSeconds: 300, requestStartedAt: time, fast: false)
        }
        let before = event(nil, at: start, trace: trace("old", start))
        let after = event(nil, at: start.addingTimeInterval(301), trace: trace("new", start.addingTimeInterval(301)), key: "new")
        let reasons = AgentCacheTrace.changes(from: before, to: after)
        XCTAssertTrue(reasons.contains("tools_changed"))
        XCTAssertTrue(reasons.contains("idle_beyond_requested_ttl"))
        XCTAssertTrue(reasons.contains("cache_usage_not_reported"))
        XCTAssertFalse(reasons.contains("cache_miss"))
    }

    func testResponsesToolNamesDoNotChangeWhenAnotherToolIsAdded() {
        let before = ToolCloak.responsesNameMap(for: ["read.file", "z_tool"])
        let after = ToolCloak.responsesNameMap(for: ["a_new_tool", "z_tool", "read.file"])
        XCTAssertEqual(before["read.file"], after["read.file"])
        XCTAssertEqual(before["z_tool"], after["z_tool"])
        XCTAssertNotEqual(after["read.file"], after["z_tool"])
    }

    func testHistoricalFunctionCallsUseTheCurrentStableWireName() throws {
        let client = NativeAgentClient(configuration: .init(baseURL: "https://test.invalid", model: "gpt-6-luna", api: "chatgpt"))
        let call = AgentToolCall(id: "call-one", name: "read.file", arguments: "{}")
        let history = AgentMessage(role: .assistant, content: "", toolCalls: [call], providerItems: [[
            "type": .string("function_call"), "call_id": .string(call.id), "name": .string("tool_0"),
            "arguments": .string("{}")]])
        let body = client.makeBody(messages: [history], tools: [], cachePolicy: .init())
        let item = try XCTUnwrap((body["input"] as? [[String: Any]])?.first)
        XCTAssertEqual(item["name"] as? String, ToolCloak.responsesNameMap(for: [call.name])[call.name])
        XCTAssertEqual(history.providerItems[0]["name"]?.string, "tool_0")
    }

    @MainActor
    func testComparisonsSurviveCacheKeyAndModelChangesAndIsolateAccounts() async throws {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [CacheFallbackURLProtocol.self]
        let session = URLSession(configuration: sessionConfig)
        defer { session.invalidateAndCancel() }
        CacheFallbackURLProtocol.bodies = []
        CacheFallbackURLProtocol.reject = ""
        var config = AgentConfiguration(baseURL: "https://api.openai.com/v1/" + UUID().uuidString, model: "gpt-6-luna", api: "chatgpt", accountID: "one")
        let messages: [AgentMessage] = [.init(role: .user, content: "one")]
        _ = try await NativeAgentClient(configuration: config, session: session).complete(messages: messages,
            cachePolicy: .init(promptCacheKey: "old-tools-key", comparisonScope: "conversation"))
        _ = try await NativeAgentClient(configuration: config, session: session).complete(messages: messages,
            cachePolicy: .init(promptCacheKey: "new-tools-key", comparisonScope: "conversation"))
        config.model = "gpt-6-astra"
        _ = try await NativeAgentClient(configuration: config, session: session).complete(messages: messages,
            cachePolicy: .init(promptCacheKey: "new-model-key", comparisonScope: "conversation"))
        config.accountID = "two"
        _ = try await NativeAgentClient(configuration: config, session: session).complete(messages: messages,
            cachePolicy: .init(promptCacheKey: "new-account-key", comparisonScope: "conversation"))
        XCTAssertEqual(CacheFallbackURLProtocol.bodies.count, 4)
        XCTAssertNotNil(CacheFallbackURLProtocol.bodies[0]["prompt_cache_options"])
        XCTAssertNil((CacheFallbackURLProtocol.bodies[0]["prompt_cache_options"] as? [String: String])?["comparison_response_id"])
        for index in [1, 2] {
            XCTAssertEqual((CacheFallbackURLProtocol.bodies[index]["prompt_cache_options"] as? [String: String])?["comparison_response_id"], "resp_next")
        }
        XCTAssertNotNil(CacheFallbackURLProtocol.bodies[3]["prompt_cache_options"])
        XCTAssertNil((CacheFallbackURLProtocol.bodies[3]["prompt_cache_options"] as? [String: String])?["comparison_response_id"])
    }

    @MainActor
    func testRejectedDiagnosticsRetryOnceAndAreDisabledForTheEndpoint() async throws {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [CacheFallbackURLProtocol.self]
        let session = URLSession(configuration: sessionConfig)
        defer { session.invalidateAndCancel() }
        CacheFallbackURLProtocol.bodies = []
        CacheFallbackURLProtocol.reject = "diagnostics"
        let config = AgentConfiguration(baseURL: "https://api.openai.com/v1/" + UUID().uuidString, model: "gpt-6-luna", api: "chatgpt")
        let client = NativeAgentClient(configuration: config, session: session)
        let policy = AgentCachePolicy(promptCacheKey: "key", comparisonResponseID: "resp_previous")
        _ = try await client.complete(messages: [.init(role: .user, content: "one")], cachePolicy: policy)
        _ = try await client.complete(messages: [.init(role: .user, content: "two")], cachePolicy: policy)
        XCTAssertEqual(CacheFallbackURLProtocol.bodies.count, 3)
        XCTAssertNotNil(CacheFallbackURLProtocol.bodies[0]["prompt_cache_options"])
        XCTAssertNil(CacheFallbackURLProtocol.bodies[1]["prompt_cache_options"])
        XCTAssertNil(CacheFallbackURLProtocol.bodies[2]["prompt_cache_options"])
    }

    @MainActor
    func testRejectedExtendedTTLUsesFiveMinutesWithoutRepeatedFailures() async throws {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [CacheFallbackURLProtocol.self]
        let session = URLSession(configuration: sessionConfig)
        defer { session.invalidateAndCancel() }
        CacheFallbackURLProtocol.bodies = []
        CacheFallbackURLProtocol.reject = "ttl"
        let config = AgentConfiguration(baseURL: "https://" + UUID().uuidString + ".invalid/v1", model: "claude-sonnet-5", api: "anthropic")
        let client = NativeAgentClient(configuration: config, session: session)
        let messages: [AgentMessage] = [.init(role: .system, content: "policy"), .init(role: .user, content: "one")]
        let first = try await client.complete(messages: messages)
        let second = try await client.complete(messages: messages)
        XCTAssertEqual(first.effectiveCacheTTLSeconds, 300)
        XCTAssertEqual(second.effectiveCacheTTLSeconds, 300)
        XCTAssertEqual(CacheFallbackURLProtocol.bodies.count, 3)
    }

    func testAnthropicOneHourTTLAndFiveMinuteOverrideKeepContentIntact() throws {
        var body: [String: Any] = ["system": "policy", "messages": [["role": "user", "content": "question"]]]
        NativeAgentClient.applyAnthropicCacheBreakpoints(to: &body)
        let blocks = try XCTUnwrap(body["system"] as? [[String: Any]])
        XCTAssertEqual((blocks[0]["cache_control"] as? [String: String])?["ttl"], "1h")
        NativeAgentClient.applyAnthropicCacheBreakpoints(to: &body, ttl: .fiveMinutes)
        let next = try XCTUnwrap(body["system"] as? [[String: Any]])
        XCTAssertEqual(next[0]["text"] as? String, "policy")
        XCTAssertEqual((next[0]["cache_control"] as? [String: String])?["ttl"], "5m")
    }

    func testDiagnosticsArePiggybackedAndNotSentToOlderModelsOrChatCompletions() {
        for (api, model, publicAPI, expected) in [("chatgpt", "gpt-6-luna", true, true),
            ("chatgpt", "gpt-5.6-luna", true, true), ("chatgpt", "gpt-6-luna", false, false),
            ("chatgpt", "gpt-5.5", true, false), ("openai-compatible", "gpt-6-luna", false, false)] {
            let baseURL = publicAPI ? "https://api.openai.com/v1" : "https://chatgpt.com/backend-api/codex"
            let client = NativeAgentClient(configuration: AgentConfiguration(baseURL: baseURL, model: model, api: api))
            let body = client.makeBody(messages: [.init(role: .user, content: "one")], tools: [],
                cachePolicy: AgentCachePolicy(promptCacheKey: "key", comparisonResponseID: "resp_prior"))
            XCTAssertEqual(body["prompt_cache_options"] != nil, expected)
        }
    }

    func testChatGPTSubscriptionGatewayDoesNotReceivePublicComparisonOptions() {
        let configuration = AgentConfiguration(
            baseURL: "https://chatgpt.com/backend-api/codex",
            model: "gpt-5.6-luna",
            api: "chatgpt"
        )
        let client = NativeAgentClient(configuration: configuration)
        let body = client.makeBody(
            messages: [.init(role: .user, content: "one")],
            tools: [],
            cachePolicy: AgentCachePolicy(promptCacheKey: "stable", comparisonResponseID: "resp_prior")
        )
        XCTAssertNil(body["prompt_cache_options"])
    }

    func testDiagnosticsSurviveBothSSEParsersAndOnlyStoreAllowedReasonLabels() throws {
        let data = Data("data: {\"type\":\"response.output_text.delta\",\"delta\":\"OK\"}\n\ndata: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_next\",\"output\":[],\"usage\":{\"input_tokens\":100,\"output_tokens\":1,\"input_tokens_details\":{\"cached_tokens\":80}},\"prompt_cache_diagnostics\":{\"type\":\"cache_miss\",\"reason\":\"tools_changed\",\"cache_missed_tokens\":20}}}\n\n".utf8)
        let response = try NativeAgentClient.responseFromSSE(data)
        XCTAssertEqual(response.providerResponseID, "resp_next")
        XCTAssertEqual(response.cacheDiagnostics?.reason, "tools_changed")
        var state = NativeAgentClient.ResponseStreamState()
        for line in String(decoding: data, as: UTF8.self).components(separatedBy: "\n") { _ = try state.consume(line: line) }
        XCTAssertEqual(try state.response().cacheDiagnostics, response.cacheDiagnostics)
        let unsafe = try JSONCodec.parse(Data(#"{"type":"cache_miss","reason":"private prompt text"}"#.utf8))
        XCTAssertEqual(AgentProviderCacheDiagnostics(value: unsafe)?.reason, "other")
    }

    func testOneHourTTLCostHelpsLongGapsButNotRapidFollowups() {
        // Official Claude multipliers, normalized to a $1/MTok base rate.
        let five = AgentTokenPricing(uncachedInputPerMillion: 1, cachedInputPerMillion: 0.1, cacheWritePerMillion: 1.25, outputPerMillion: 0)
        let hour = AgentTokenPricing(uncachedInputPerMillion: 1, cachedInputPerMillion: 0.1, cacheWritePerMillion: 2, outputPerMillion: 0)
        let write = AgentUsage(inputTokens: 0, outputTokens: 0, cachedTokens: 0, cacheWriteTokens: 10000)
        let read = AgentUsage(inputTokens: 0, outputTokens: 0, cachedTokens: 10000)
        let shortWrite = five.estimatedCost(usage: write, api: "anthropic")
        let longWrite = hour.estimatedCost(usage: write, api: "anthropic")
        let hit = hour.estimatedCost(usage: read, api: "anthropic")
        XCTAssertLessThan(longWrite + hit, 2 * shortWrite) // one 5–60 minute gap
        XCTAssertGreaterThan(longWrite + hit, shortWrite + hit) // rapid followup
    }
}

private final class CacheFallbackURLProtocol: URLProtocol {
    nonisolated(unsafe) static var bodies: [[String: Any]] = []
    nonisolated(unsafe) static var reject = ""
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
            stream.close()
        }
        let body = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        Self.bodies.append(body)
        let system = body["system"] as? [[String: Any]]
        let ttl = (system?.last?["cache_control"] as? [String: Any])?["ttl"] as? String
        let rejected = Self.reject == "diagnostics" ? body["prompt_cache_options"] != nil : ttl == "1h"
        let payload = rejected ? "{\"error\":{\"message\":\"Unsupported \(Self.reject == "ttl" ? "ttl" : "prompt_cache_options")\"}}"
            : Self.reject == "ttl"
                ? #"{"content":[{"type":"text","text":"OK"}],"usage":{"input_tokens":1,"output_tokens":1,"cache_read_input_tokens":0,"cache_creation_input_tokens":100}}"#
                : #"{"id":"resp_next","output":[{"type":"message","content":[{"type":"output_text","text":"OK"}]}],"usage":{"input_tokens":100,"output_tokens":1,"input_tokens_details":{"cached_tokens":80}}}"#
        let response = HTTPURLResponse(url: request.url!, statusCode: rejected ? 400 : 200,
            httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(payload.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

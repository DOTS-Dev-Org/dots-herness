import XCTest
import Foundation
import HarnessPluginKit
import PluginRuntime
@testable import DotsHarnessCore

final class PromptCacheProviderEvidenceTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 10_000)
    private func config(_ api: String = "anthropic", publicAPI: Bool = false) -> AgentConfiguration {
        AgentConfiguration(baseURL: publicAPI ? "https://api.openai.com/v1" : "https://cache-evidence.invalid/v1",
            model: api == "anthropic" ? "claude-sonnet-5" : "gpt-5.6-luna", api: api, accountID: "account")
    }
    private var initial: [AgentMessage] {
        [.init(role: .system, content: "invariant", systemKind: .promptStable),
         .init(role: .user, content: "first")]
    }
    private func body(_ messages: [AgentMessage], configuration: AgentConfiguration,
                      prior: AgentPromptCacheBoundary? = nil, tools: [AgentToolDefinition] = []) -> [String: Any] {
        NativeAgentClient(configuration: configuration).makeBody(messages: messages, tools: tools,
            cachePolicy: .init(priorBoundary: prior))
    }
    private func response(read: Int? = 0, write: Int? = 6000, input: Int = 10,
                          diagnostic: AgentProviderCacheDiagnostics? = nil) -> AgentResponse {
        AgentResponse(message: .init(role: .assistant, content: "OK"),
            usage: .init(inputTokens: input, outputTokens: 1, cachedTokens: read, cacheWriteTokens: write),
            providerResponseID: "msg_first", cacheDiagnostics: diagnostic)
    }
    private func warm(configuration: AgentConfiguration? = nil, tools: [AgentToolDefinition] = []) throws -> AgentPromptCacheBoundary {
        let configuration = configuration ?? config()
        let snapshot = AgentPromptCacheRequestSnapshot(body: body(initial, configuration: configuration, tools: tools),
            configuration: configuration, requestStartedAt: start)
        let r = snapshot.evaluate(response: response(input: configuration.api == "anthropic" ? 10 : 6000), prior: nil)
        let boundary = try XCTUnwrap(r.1)
        XCTAssertTrue(boundary.accepted)
        return boundary
    }

    func testClaudeFourDistinctMarkersKeepPriorTailBeyondTwentyBlocks() throws {
        let tool = AgentToolDefinition(name: "read.file", description: "Read", parameters: .object(["type": .string("object")]))
        let prior = try warm(tools: [tool])
        let history = initial + (0..<25).flatMap { n in
            [AgentMessage(role: .assistant, content: "answer \(n)"), AgentMessage(role: .user, content: "next \(n)")]
        }
        let request = body(history, configuration: config(), prior: prior, tools: [tool])
        let messages = try XCTUnwrap(request["messages"] as? [[String: Any]])
        let firstContent = try XCTUnwrap(messages[0]["content"] as? [[String: Any]])
        let lastContent = try XCTUnwrap(messages.last?["content"] as? [[String: Any]])
        XCTAssertNotNil(firstContent[0]["cache_control"])
        XCTAssertNotNil(lastContent[0]["cache_control"])
        let count = (request["tools"] as? [[String: Any]])!.filter { $0["cache_control"] != nil }.count
            + (request["system"] as? [[String: Any]])!.filter { $0["cache_control"] != nil }.count
            + messages.reduce(0) { $0 + (($1["content"] as? [[String: Any]])?.filter { $0["cache_control"] != nil }.count ?? 0) }
        XCTAssertEqual(count, 4)
        let after = AgentPromptCacheRequestSnapshot(body: request, configuration: config(), requestStartedAt: start.addingTimeInterval(1))
        XCTAssertTrue(after.unchanged(prior))
        let same = body(initial, configuration: config(), prior: prior, tools: [tool])
        let sameMessages = same["messages"] as! [[String: Any]]
        XCTAssertEqual(sameMessages.flatMap { $0["content"] as! [[String: Any]] }.filter { $0["cache_control"] != nil }.count, 1)
    }

    func testClaudeInvariantSystemUsesOnlyOneSystemMarker() throws {
        let request = body([initial[0], .init(role: .system, content: "summary", systemKind: .compactionSummary), initial[1]], configuration: config())
        let system = try XCTUnwrap(request["system"] as? [[String: Any]])
        XCTAssertNotNil(system[0]["cache_control"])
        XCTAssertNil(system[1]["cache_control"])
    }

    func testEligibleReuseExcludesNewTailAndDiagnosticsEstimates() throws {
        let prior = try warm()
        let history = initial + [.init(role: .assistant, content: "OK"), .init(role: .user, content: "new tail")]
        let request = body(history, configuration: config(), prior: prior)
        let snapshot = AgentPromptCacheRequestSnapshot(body: request, configuration: config(), requestStartedAt: start.addingTimeInterval(30))
        let estimate = try JSONCodec.parse(Data(#"{"type":"cache_miss","cache_missed_tokens":999999,"comparison_reusable_tokens":9999999}"#.utf8))
        let result = snapshot.evaluate(response: response(read: 6000, write: 500,
            diagnostic: AgentProviderCacheDiagnostics(value: estimate)), prior: prior)
        XCTAssertEqual(result.0.classification, "eligible")
        XCTAssertEqual(result.0.eligibleTokens, 6000)
        XCTAssertEqual(result.0.reusedTokens, 6000)
        XCTAssertEqual(result.1?.providerPrefixTokens, 6500)
        let lost = snapshot.evaluate(response: response(read: 0, write: 6500), prior: prior)
        XCTAssertEqual(lost.0.classification, "eligible")
        XCTAssertEqual(lost.0.eligibleTokens, 6000)
        XCTAssertEqual(lost.0.reusedTokens, 0)
    }

    func testWireRewriteWithinIntendedEpochCountsAsPreventableLoss() throws {
        let prior = try warm()
        var changed = initial
        changed[0].content = "accidentally rebuilt policy"
        let snapshot = AgentPromptCacheRequestSnapshot(body: body(changed, configuration: config(), prior: prior),
            configuration: config(), requestStartedAt: start.addingTimeInterval(30))
        let result = snapshot.evaluate(response: response(read: 6000, write: 1), prior: prior)
        XCTAssertEqual(result.0.classification, "eligible")
        XCTAssertEqual(result.0.reason, "prefix_changed")
        XCTAssertEqual(result.0.reusedTokens, 0)
    }

    func testShrinkingCacheExtentMeasuresCurrentLossWithoutPromotingFalseTerminalCheckpoint() throws {
        let prior = try warm()
        let history = initial + [.init(role: .assistant, content: "OK"), .init(role: .user, content: "appended tail")]
        let snapshot = AgentPromptCacheRequestSnapshot(body: body(history, configuration: config(), prior: prior),
            configuration: config(), requestStartedAt: start.addingTimeInterval(1))
        let result = snapshot.evaluate(response: response(read: 3000, write: 1000, input: 2000), prior: prior)
        XCTAssertEqual(result.0.classification, "eligible")
        XCTAssertEqual(result.0.eligibleTokens, 6000)
        XCTAssertEqual(result.0.reusedTokens, 3000)
        XCTAssertFalse(result.1?.accepted ?? true)
        XCTAssertNil(result.1?.providerPrefixTokens)
    }

    func testUnknownInvalidExpiredAndChangedRouteNeverFabricateSuccess() throws {
        let prior = try warm()
        let request = body(initial, configuration: config(), prior: prior)
        let snapshot = AgentPromptCacheRequestSnapshot(body: request, configuration: config(), requestStartedAt: start.addingTimeInterval(30))
        for r in [response(read: nil), response(write: nil), response(read: -1), response(read: Int.max, write: Int.max)] {
            let result = snapshot.evaluate(response: r, prior: prior)
            XCTAssertEqual(result.0.classification, "inconclusive")
            XCTAssertNil(result.0.reusedTokens)
            XCTAssertFalse(result.1?.accepted ?? true)
        }
        let expired = AgentPromptCacheRequestSnapshot(body: request, configuration: config(), requestStartedAt: start.addingTimeInterval(3600))
        XCTAssertEqual(expired.evaluate(response: response(read: 6000), prior: prior).0.classification, "expired")
        var other = config(); other.accountID = "another-account"
        let changed = AgentPromptCacheRequestSnapshot(body: request, configuration: other, requestStartedAt: start.addingTimeInterval(30))
        XCTAssertEqual(changed.evaluate(response: response(read: 6000), prior: prior).0.classification, "changed")
    }

    func testGatewayReadOnlyCountersDoNotProveWrittenBoundaryOrTTL() throws {
        let gateway = config("chatgpt")
        let first = AgentPromptCacheRequestSnapshot(body: body(initial, configuration: gateway),
            configuration: gateway, requestStartedAt: start)
        let warm = first.evaluate(response: response(read: 0, write: nil, input: 6000), prior: nil)
        XCTAssertEqual(warm.0.classification, "cold")
        let prior = try XCTUnwrap(warm.1)
        XCTAssertFalse(prior.accepted)
        XCTAssertNil(prior.providerPrefixTokens)
        XCTAssertNil(prior.effectiveTTLSeconds)
        let history = initial + [.init(role: .assistant, content: "OK"), .init(role: .user, content: "next")]
        func next(_ seconds: TimeInterval) -> AgentPromptCacheRequestSnapshot {
            .init(body: body(history, configuration: gateway, prior: prior), configuration: gateway,
                  requestStartedAt: start.addingTimeInterval(seconds))
        }
        let hit = next(30).evaluate(response: response(read: 5900, write: nil, input: 6100), prior: prior).0
        XCTAssertEqual(hit.classification, "inconclusive")
        XCTAssertNil(hit.eligibleTokens)
        XCTAssertNil(hit.reusedTokens)
        XCTAssertEqual(next(30).evaluate(response: response(read: nil, write: nil, input: 6100), prior: prior).0.classification, "inconclusive")
        XCTAssertEqual(next(300).evaluate(response: response(read: 0, write: nil, input: 6100), prior: prior).0.classification, "inconclusive")
        let rewritten = [initial[0], AgentMessage(role: .user, content: "rewritten")] + history.dropFirst(2)
        let lost = AgentPromptCacheRequestSnapshot(body: body(Array(rewritten), configuration: gateway, prior: prior),
            configuration: gateway, requestStartedAt: start.addingTimeInterval(30))
            .evaluate(response: response(read: 0, write: nil, input: 6100), prior: prior).0
        XCTAssertEqual(lost.classification, "inconclusive")
        XCTAssertNil(lost.reusedTokens)
    }

    func testOutputCeilingIsNotACacheSetting() {
        var request = body(initial, configuration: config())
        let before = AgentPromptCacheRequestSnapshot(body: request, configuration: config(), requestStartedAt: start)
        request["max_tokens"] = 123
        let after = AgentPromptCacheRequestSnapshot(body: request, configuration: config(), requestStartedAt: start)
        XCTAssertEqual(before.settingsFingerprint, after.settingsFingerprint)
    }

    func testPublicResponsesBreakpointAndImplicitOptionsNeverReachGatewayOrOldModels() throws {
        let publicBody = body(initial, configuration: config("chatgpt", publicAPI: true))
        let input = try XCTUnwrap(publicBody["input"] as? [[String: Any]])
        XCTAssertEqual(input[0]["role"] as? String, "developer")
        let content = try XCTUnwrap(input[0]["content"] as? [[String: Any]])
        XCTAssertEqual((content[0]["prompt_cache_breakpoint"] as? [String: String])?["mode"], "explicit")
        let options = publicBody["prompt_cache_options"] as? [String: String]
        XCTAssertEqual(options?["mode"], "implicit")
        XCTAssertEqual(options?["ttl"], "30m")
        XCTAssertEqual(publicBody["instructions"] as? String, "You are a helpful assistant.")
        for configuration in [config("chatgpt"), AgentConfiguration(baseURL: "https://api.openai.com/v1", model: "gpt-5.5", api: "chatgpt")] {
            let request = body(initial, configuration: configuration)
            XCTAssertNil(request["prompt_cache_options"])
            XCTAssertFalse(String(decoding: try JSONSerialization.data(withJSONObject: request), as: UTF8.self).contains("prompt_cache_breakpoint"))
        }
    }

    func testOpenAIGatewayWithBothCountersNeedsExactWholeInputBoundary() throws {
        let configuration = config("chatgpt")
        let snapshot = AgentPromptCacheRequestSnapshot(body: body(initial, configuration: configuration),
            configuration: configuration, requestStartedAt: start)
        XCTAssertTrue(snapshot.evaluate(response: response(input: 6000), prior: nil).1?.accepted ?? false)
        XCTAssertFalse(snapshot.evaluate(response: response(input: 6010), prior: nil).1?.accepted ?? true)
        let prior = try XCTUnwrap(snapshot.evaluate(response: response(input: 6000), prior: nil).1)
        let next = initial + [.init(role: .assistant, content: "OK"), .init(role: .user, content: "again")]
        let continuation = AgentPromptCacheRequestSnapshot(body: body(next, configuration: configuration),
            configuration: configuration, requestStartedAt: start.addingTimeInterval(1))
        let measured = continuation.evaluate(response: response(read: 6000, write: 100, input: 6100), prior: prior).0
        XCTAssertEqual(measured.classification, "inconclusive")
        XCTAssertEqual(measured.reason, "ttl_unverified")
        XCTAssertEqual(measured.eligibleTokens, 6000)
        XCTAssertNil(measured.reusedTokens)
    }

    func testRequestHashIgnoresMarkersButPreservesUserSchemaProperties() throws {
        let parameters: HarnessPluginKit.JSONValue = .object(["type": .string("object"), "properties": .object(["cache_control": .object(["type": .string("string")])])])
        let tool = AgentToolDefinition(name: "read", description: "Read", parameters: parameters)
        let a = body(initial, configuration: config(), tools: [tool])
        var b = a
        NativeAgentClient.applyAnthropicCacheBreakpoints(to: &b, ttl: .fiveMinutes)
        let pa = AgentPromptCacheRequestSnapshot(body: a, configuration: config(), requestStartedAt: start)
        let pb = AgentPromptCacheRequestSnapshot(body: b, configuration: config(), requestStartedAt: start)
        XCTAssertEqual(pa.prefixFingerprint, pb.prefixFingerprint)
        let changedTool = AgentToolDefinition(name: "read", description: "Read", parameters: .object(["type": .string("object")]))
        let changed = AgentPromptCacheRequestSnapshot(body: body(initial, configuration: config(), tools: [changedTool]),
            configuration: config(), requestStartedAt: start)
        XCTAssertNotEqual(pa.prefixFingerprint, changed.prefixFingerprint)
    }

    func testClaudeJSONAndMessageStartSSEPreserveActualCountersAndSafeDiagnostics() throws {
        let json = #"{"id":"msg_one","type":"message","content":[{"type":"text","text":"OK"}],"usage":{"input_tokens":5,"output_tokens":1,"cache_read_input_tokens":6000,"cache_creation_input_tokens":20},"diagnostics":{"cache_miss_reason":{"type":"tools_changed","cache_missed_input_tokens":777}}}"#
        let normal = try NativeAgentClient.response(from: JSONCodec.parse(Data(json.utf8)))
        let sse = #"data: {"type":"message_start","message":{"id":"msg_one","type":"message","content":[],"usage":{"input_tokens":5,"output_tokens":0,"cache_read_input_tokens":6000,"cache_creation_input_tokens":20},"diagnostics":{"cache_miss_reason":{"type":"tools_changed","cache_missed_input_tokens":777}}}}"#
            + "\n\n" + #"data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#
            + "\n\n" + #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"OK"}}"#
            + "\n\n" + #"data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":1}}"#
        let stream = try NativeAgentClient.anthropicResponseFromSSE(Data(sse.utf8))
        XCTAssertEqual(normal.usage, stream.usage)
        XCTAssertEqual(normal.providerResponseID, stream.providerResponseID)
        XCTAssertEqual(normal.cacheDiagnostics, stream.cacheDiagnostics)
        XCTAssertEqual(stream.cacheDiagnostics?.missedTokens, 777)
        XCTAssertEqual(stream.usage?.cachedTokens, 6000)
        XCTAssertEqual(stream.usage?.cacheWriteTokens, 20)
        let pending = AgentProviderCacheDiagnostics(anthropicValue: .object(["cache_miss_reason": .null]))
        XCTAssertEqual(pending?.type, "unavailable")
    }

    @MainActor
    func testRejectedPublicBreakpointFallsBackOnceWithoutDroppingNormalComparison() async throws {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [CacheEvidenceURLProtocol.self]
        let session = URLSession(configuration: sessionConfig)
        defer { session.invalidateAndCancel() }
        CacheEvidenceURLProtocol.requests = []
        CacheEvidenceURLProtocol.rejection = "input.0.content.0.prompt_cache_breakpoint"
        var configuration = config("chatgpt", publicAPI: true)
        configuration.baseURL += "/" + UUID().uuidString
        let client = NativeAgentClient(configuration: configuration, session: session)
        let policy = AgentCachePolicy(comparisonResponseID: "resp_prior")
        _ = try await client.complete(messages: initial, cachePolicy: policy)
        _ = try await client.complete(messages: initial, cachePolicy: policy)
        XCTAssertEqual(CacheEvidenceURLProtocol.requests.count, 3)
        let first = CacheEvidenceURLProtocol.requests[0]["input"] as! [[String: Any]]
        XCTAssertNotNil((first[0]["content"] as! [[String: Any]])[0]["prompt_cache_breakpoint"])
        for request in CacheEvidenceURLProtocol.requests.dropFirst() {
            XCTAssertFalse(String(decoding: try JSONSerialization.data(withJSONObject: request), as: UTF8.self).contains("prompt_cache_breakpoint"))
            XCTAssertEqual((request["prompt_cache_options"] as? [String: String])?["comparison_response_id"], "resp_prior")
            XCTAssertEqual((request["prompt_cache_options"] as? [String: String])?["mode"], "implicit")
        }
    }

    @MainActor
    func testRejectedImplicitTTLRetainsSupportedComparisonAndExplicitBreakpoint() async throws {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [CacheEvidenceURLProtocol.self]
        let session = URLSession(configuration: sessionConfig)
        defer { session.invalidateAndCancel() }
        CacheEvidenceURLProtocol.requests = []
        CacheEvidenceURLProtocol.rejection = "prompt_cache_options.ttl"
        var configuration = config("chatgpt", publicAPI: true)
        configuration.baseURL += "/" + UUID().uuidString
        _ = try await NativeAgentClient(configuration: configuration, session: session).complete(messages: initial,
            cachePolicy: .init(comparisonResponseID: "resp_prior"))
        XCTAssertEqual(CacheEvidenceURLProtocol.requests.count, 2)
        let fallback = CacheEvidenceURLProtocol.requests[1]
        XCTAssertEqual((fallback["prompt_cache_options"] as? [String: String])?["comparison_response_id"], "resp_prior")
        XCTAssertNil((fallback["prompt_cache_options"] as? [String: String])?["ttl"])
        let input = fallback["input"] as! [[String: Any]]
        XCTAssertNotNil((input[0]["content"] as! [[String: Any]])[0]["prompt_cache_breakpoint"])
    }
}

private final class CacheEvidenceURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requests: [[String: Any]] = []
    nonisolated(unsafe) static var rejection = ""
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var bytes = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&bytes, maxLength: bytes.count)
                if n <= 0 { break }
                data.append(contentsOf: bytes.prefix(n))
            }
            stream.close()
        }
        let body = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        Self.requests.append(body)
        let input = body["input"] as? [[String: Any]]
        let marker = (input?.first?["content"] as? [[String: Any]])?.first?["prompt_cache_breakpoint"]
        let hasRejectedField = Self.rejection.hasSuffix("prompt_cache_breakpoint") ? marker != nil
            : (body["prompt_cache_options"] as? [String: Any])?["ttl"] != nil
        let payload = hasRejectedField
            ? "{\"error\":{\"message\":\"Unsupported optional field\",\"param\":\"\(Self.rejection)\"}}"
            : #"{"id":"resp_next","output":[{"type":"message","content":[{"type":"output_text","text":"OK"}]}],"usage":{"input_tokens":100,"output_tokens":1,"input_tokens_details":{"cached_tokens":0,"cache_write_tokens":100}}}"#
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: hasRejectedField ? 400 : 200,
            httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(payload.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

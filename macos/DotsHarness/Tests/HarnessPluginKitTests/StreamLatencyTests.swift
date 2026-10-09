// Copyright (c) 2026 DOTS
// Streaming for chat-completions and Gemini routes, and the numbers behind it.

import XCTest
@testable import DotsHarnessCore
@testable import DotsHarnessUI

final class StreamLatencyTests: XCTestCase {
    private static let chatStream = [
        #"data: {"id":"c1","object":"chat.completion.chunk","model":"some/long-model-name-that-pushes-delta-past-the-head","choices":[{"index":0,"delta":{"role":"assistant","content":""}}]}"#,
        ": OPENROUTER PROCESSING",
        #"data: {"choices":[{"index":0,"delta":{"reasoning_content":"weigh it. "}}]}"#,
        #"data: {"choices":[{"index":0,"delta":{"content":"Hello"}}]}"#,
        #"data: {"choices":[{"index":0,"delta":{"content":" world"}}]}"#,
        #"data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_a","type":"function","function":{"name":"read_file","arguments":"{\"pa"}}]}}]}"#,
        #"data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"th\":\"a.txt\"}"}}]}}]}"#,
        #"data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":1,"id":"call_b","type":"function","function":{"name":"list_dir","arguments":""}}]}}]}"#,
        #"data: {"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}"#,
        #"data: {"choices":[],"usage":{"prompt_tokens":120,"completion_tokens":9,"prompt_tokens_details":{"cached_tokens":100}}}"#,
        "data: [DONE]",
    ]

    func testStreamedChatCompletionEqualsTheBufferedReply() throws {
        let response = try NativeAgentClient.chatCompletionFromSSE(Data(Self.chatStream.joined(separator: "\n\n").utf8))
        XCTAssertEqual(response.message.content, "Hello world")
        XCTAssertEqual(response.message.thinking, "weigh it. ")
        XCTAssertEqual(response.message.toolCalls.map(\.id), ["call_a", "call_b"])
        XCTAssertEqual(response.message.toolCalls.map(\.name), ["read_file", "list_dir"])
        XCTAssertEqual(response.message.toolCalls.map(\.arguments), [#"{"path":"a.txt"}"#, "{}"])
        XCTAssertEqual(response.usage?.inputTokens, 120)
        XCTAssertEqual(response.usage?.outputTokens, 9)
        XCTAssertEqual(response.usage?.cachedTokens, 100)
    }

    func testAMidStreamErrorIsThrownNotSwallowed() {
        let stream = #"data: {"choices":[{"delta":{"content":"par"}}]}"# + "\n\n"
            + #"data: {"error":{"message":"upstream overloaded","code":503}}"#
        XCTAssertThrowsError(try NativeAgentClient.chatCompletionFromSSE(Data(stream.utf8))) { error in
            XCTAssertEqual((error as? NativeAgentError)?.statusCode, 503)
        }
    }

    func testStreamedGeminiReplyMergesProseAndKeepsCallsAndUsage() throws {
        let stream = [
            #"data: {"response":{"candidates":[{"content":{"parts":[{"text":"hmm ","thought":true}]}}]}}"#,
            #"data: {"response":{"candidates":[{"content":{"parts":[{"text":"ok","thought":true}]}}]}}"#,
            #"data: {"response":{"candidates":[{"content":{"parts":[{"text":"Mer"}]}}]}}"#,
            #"data: {"response":{"candidates":[{"content":{"parts":[{"text":"haba"},{"functionCall":{"name":"read_file","args":{"path":"a"}}}]}}],"usageMetadata":{"promptTokenCount":7,"candidatesTokenCount":3}}}"#,
        ].joined(separator: "\n\n")
        let response = try NativeAgentClient.geminiResponseFromSSE(Data(stream.utf8))
        XCTAssertEqual(response.message.content, "Merhaba")
        XCTAssertEqual(response.message.thinking, "hmm ok")
        XCTAssertEqual(response.message.toolCalls.map(\.name), ["read_file"])
        XCTAssertEqual(response.usage?.inputTokens, 7)

        let line = Data(#"data: {"response":{"candidates":[{"content":{"parts":[{"text":"hmm","thought":true},{"text":"Mer"}]}}]}}"#.utf8)
        let output = NativeAgentClient.streamOutput(fromLine: line, api: RouterAPIKind.geminiCLI.rawValue)
        XCTAssertEqual(output.deltas, [.thinking("hmm"), .text("Mer")])
        let client = NativeAgentClient(configuration: AgentConfiguration(
            baseURL: "https://example.test/v1internal", model: "g", apiKey: "k", provider: "Gemini",
            api: RouterAPIKind.geminiCLI.rawValue))
        XCTAssertEqual(client.endpoint(streaming: true)?.absoluteString, "https://example.test/v1internal:streamGenerateContent?alt=sse")
        XCTAssertEqual(client.endpoint()?.absoluteString, "https://example.test/v1internal:generateContent")
    }

    /// The measurement: a chat-completions route that writes for ~1 s. Before,
    /// the first visible word arrived with the last one.
    func testChatCompletionsRouteStreamsAndReportsFirstToken() async throws {
        let (client, session) = Self.client(path: "stream")
        defer { session.invalidateAndCancel() }
        PacedSSEProtocol.reset(lines: Self.chatStream, gapMilliseconds: 100)

        let started = Date()
        let firstTextAt = FirstSeen()
        let response = try await client.complete(messages: [AgentMessage(role: .user, content: "hi")]) { delta in
            if case .text = delta { await firstTextAt.mark() }
        }
        let total = Int(Date().timeIntervalSince(started) * 1_000)
        let firstText = Int((await firstTextAt.date ?? Date()).timeIntervalSince(started) * 1_000)

        XCTAssertEqual(PacedSSEProtocol.bodies.first?["stream"] as? Bool, true)
        XCTAssertEqual((PacedSSEProtocol.bodies.first?["stream_options"] as? [String: Any])?["include_usage"] as? Bool, true)
        XCTAssertEqual(response.message.content, "Hello world")
        XCTAssertEqual(response.usage?.inputTokens, 120)
        let ttft = try XCTUnwrap(response.firstTokenMilliseconds)
        print("STREAM_LATENCY chat-completions first_output_ms=\(ttft) first_text_ms=\(firstText) total_ms=\(total) buffered_first_text_ms=\(total)")
        XCTAssertLessThan(firstText, total - 400, "the first word must not wait for the whole reply")
    }

    func testWithoutADeltaHandlerTheRequestStaysBuffered() async throws {
        let (client, session) = Self.client(path: "buffered")
        defer { session.invalidateAndCancel() }
        PacedSSEProtocol.reset(json: #"{"choices":[{"message":{"content":"ready"}}],"usage":{"prompt_tokens":3,"completion_tokens":2}}"#)
        let response = try await client.complete(messages: [AgentMessage(role: .user, content: "hi")])
        XCTAssertEqual(response.message.content, "ready")
        XCTAssertNil(PacedSSEProtocol.bodies.first?["stream"])
    }

    func testAnEndpointThatRejectsStreamOptionsIsAskedOnceThenRemembered() async throws {
        let (client, session) = Self.client(path: "strict")
        defer { session.invalidateAndCancel() }
        PacedSSEProtocol.reset(lines: Self.chatStream, gapMilliseconds: 0)
        PacedSSEProtocol.rejectsStreamOptions = true
        for _ in 0..<2 {
            let response = try await client.complete(messages: [AgentMessage(role: .user, content: "hi")]) { _ in }
            XCTAssertEqual(response.message.content, "Hello world")
        }
        // Probe, fallback, then the remembered shape: three requests, one with the field.
        XCTAssertEqual(PacedSSEProtocol.bodies.map { $0["stream_options"] != nil }, [true, false, false])
    }

    /// The measurement: a 400-line reply published as it grows. Before, every
    /// publish parsed every line again.
    @MainActor
    func testLiveMarkdownParsesOnlyTheGrowingLine() {
        let lines = (0..<400).map { "- item \($0) with **bold**, `code` and a [link](https://example.test/\($0))" }
        let publishes = (1...lines.count).map { lines.prefix($0).joined(separator: "\n") }

        var started = Date()
        for text in publishes {
            for line in text.components(separatedBy: .newlines) {
                _ = try? AttributedString(markdown: line, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
            }
        }
        let before = Date().timeIntervalSince(started) * 1_000

        started = Date()
        var last: MarkdownCache.ParsedPlanMarkdown?
        for text in publishes { last = MarkdownCache.shared.parsed(for: text, store: false) }
        let after = Date().timeIntervalSince(started) * 1_000

        XCTAssertEqual(last?.entries.count, lines.count)
        XCTAssertNotNil(last?.entries.last?.bulletText)
        print(String(format: "STREAM_LATENCY live-markdown lines=400 publishes=400 full_reparse_ms=%.0f per_line_cache_ms=%.0f speedup=%.1fx",
                     before, after, before / max(after, 0.001)))
        XCTAssertLessThan(after, before / 3)
    }

    @MainActor
    func testACodeFenceStillOwnsItsLines() {
        let parsed = MarkdownCache.shared.parsed(for: "# T\n```swift\n# not a heading\n```\n# H", store: false)
        XCTAssertEqual(parsed.entries.map(\.isCode), [false, true, true, true, false])
        XCTAssertNil(parsed.entries[2].heading)
        XCTAssertEqual(parsed.entries[4].heading?.level, 1)
    }

    func testPrewarmOpensOneConnectionPerWindow() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PacedSSEProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        PacedSSEProtocol.reset(json: "")
        let base = "https://\(UUID().uuidString).example.test/v1"
        await NativeAgentClient.prewarm(baseURL: base, session: session)
        await NativeAgentClient.prewarm(baseURL: base, session: session)
        XCTAssertEqual(PacedSSEProtocol.requests.map(\.httpMethod), ["HEAD"])
        XCTAssertEqual(PacedSSEProtocol.requests.first?.url?.path, "/")
        XCTAssertNil(PacedSSEProtocol.requests.first?.value(forHTTPHeaderField: "Authorization"))
    }

    func testTelemetryKeepsPrepareTimeAndOldEventsStillDecode() throws {
        let event = AgentContextUsageEvent(
            conversationID: "c", provider: "p", api: "a", model: "m", cacheKey: nil, requestKind: .main,
            strategy: .none, policyID: .baseline,
            contextTokensBefore: 0, contextTokensAfter: 0, latencyMilliseconds: 900,
            firstTokenMilliseconds: 300, prepareMilliseconds: 40)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(event)) as? [String: Any])
        XCTAssertEqual(object["prepareMilliseconds"] as? Int, 40)
        object.removeValue(forKey: "prepareMilliseconds")
        let old = try JSONDecoder().decode(AgentContextUsageEvent.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(old.prepareMilliseconds)
        let summary = AgentCacheReuseSummary(events: [event, old])
        XCTAssertEqual(summary.averageFirstTokenMilliseconds, 300)
        XCTAssertEqual(summary.averagePrepareMilliseconds, 40)
    }

    private static func client(path: String) -> (NativeAgentClient, URLSession) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PacedSSEProtocol.self]
        let session = URLSession(configuration: configuration)
        // A fresh base URL per test: the stream_options memory is per endpoint.
        return (NativeAgentClient(
            configuration: AgentConfiguration(
                baseURL: "http://example.test/\(path)-\(UUID().uuidString)/v1", model: "m", apiKey: "k",
                provider: "Custom", api: RouterAPIKind.openAICompatible.rawValue),
            session: session), session)
    }
}

private actor FirstSeen {
    var date: Date?
    func mark() { if date == nil { date = Date() } }
}

/// Serves SSE one line at a time with a pause between lines, the way a model writes.
private final class PacedSSEProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var lines: [String] = []
    nonisolated(unsafe) static var json = ""
    nonisolated(unsafe) static var gapMilliseconds = 0
    nonisolated(unsafe) static var rejectsStreamOptions = false
    nonisolated(unsafe) static var bodies: [[String: Any]] = []
    nonisolated(unsafe) static var requests: [URLRequest] = []

    static func reset(lines: [String] = [], json: String = "", gapMilliseconds: Int = 0) {
        self.lines = lines
        self.json = json
        self.gapMilliseconds = gapMilliseconds
        rejectsStreamOptions = false
        bodies = []
        requests = []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var bytes = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&bytes, maxLength: bytes.count)
                if count <= 0 { break }
                data.append(contentsOf: bytes.prefix(count))
            }
            stream.close()
        }
        let body = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        Self.bodies.append(body)
        Self.requests.append(request)

        func head(_ status: Int, _ type: String) {
            client?.urlProtocol(self, didReceive: HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": type])!,
                cacheStoragePolicy: .notAllowed)
        }
        if Self.rejectsStreamOptions, body["stream_options"] != nil {
            head(400, "application/json")
            client?.urlProtocol(self, didLoad: Data(#"{"error":{"message":"Unrecognized request argument supplied: stream_options"}}"#.utf8))
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        guard body["stream"] as? Bool == true else {
            head(200, "application/json")
            client?.urlProtocol(self, didLoad: Data(Self.json.utf8))
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        head(200, "text/event-stream")
        let lines = Self.lines
        let gap = Self.gapMilliseconds
        Thread.detachNewThread { [self] in
            for line in lines {
                if gap > 0 { Thread.sleep(forTimeInterval: Double(gap) / 1_000) }
                client?.urlProtocol(self, didLoad: Data((line + "\n\n").utf8))
            }
            client?.urlProtocolDidFinishLoading(self)
        }
    }
}

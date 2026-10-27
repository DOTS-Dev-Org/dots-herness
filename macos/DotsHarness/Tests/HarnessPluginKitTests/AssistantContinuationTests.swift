// Copyright (c) 2026 DOTS

import XCTest
import Foundation
import HarnessPluginKit
import PluginRuntime
@testable import DotsHarnessCore

final class AssistantContinuationTests: XCTestCase {
    func testResponseStyleUsesOriginalPromptWhenHistoryHasBeenCompacted() {
        let originalPrompt = "Give me one sentence only."
        let continuation = AgentMessage(
            role: .user,
            content: """
            Continue the assistant response. Do not repeat it.

            Original user request (verbatim):
            \(originalPrompt)

            The assistant message immediately following this instruction is the already delivered response.
            """,
            responseContinuationID: "continuation-1"
        )

        XCTAssertEqual(AgentMessage.responseStylePrompt(in: [continuation]), originalPrompt)
    }

    @MainActor
    func testOutputLimitedAnswerContinuesInOneVisibleMessage() async throws {
        ContinuationURLProtocol.responses = [
            Data(#"{"choices":[{"message":{"role":"assistant","content":"The first part. "},"finish_reason":"length"}],"usage":{"prompt_tokens":100000,"completion_tokens":8}}"#.utf8),
            Data(#"{"choices":[{"message":{"role":"assistant","content":"1. KULLANICI HEDEFİ: Continue the user's request.\n2. YAPILAN DEĞİŞİKLİKLER: None.\n3. ALINAN KARARLAR VE KISITLAR: Preserve the partial answer.\n4. MEVCUT DURUM VE SON KANITLAR: The answer was partially emitted."},"finish_reason":"stop"}]}"#.utf8),
            Data(#"{"choices":[{"message":{"role":"assistant","content":"The second part."},"finish_reason":"stop"}],"usage":{"prompt_tokens":16,"completion_tokens":7}}"#.utf8),
        ]
        URLProtocol.registerClass(ContinuationURLProtocol.self)
        defer {
            ContinuationURLProtocol.reset()
            URLProtocol.unregisterClass(ContinuationURLProtocol.self)
        }

        let paths = makeTemporaryPaths()
        let workspace = paths.root.appendingPathComponent("continuation-project", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let host = NativeAgentHost(
            paths: paths,
            endpoint: AgentEndpointController(baseURL: "http://continuation.test/v1", modelID: "test-model")
        )
        host.start(workspacePath: workspace.path)
        await host.refreshConnection()

        await host.send(text: "Explain this in a balanced way.", mode: .queue)

        let conversation = try XCTUnwrap(host.selected)
        let answers = conversation.messages.filter { $0.kind == .assistant }
        XCTAssertEqual(answers.count, 1)
        XCTAssertEqual(answers.first?.text, "The first part. The second part.")
        XCTAssertEqual(host.conversations.count, 1, "Continuation must not open a second conversation.")
        XCTAssertGreaterThan(conversation.contextCompactionCount, 0, "The reported full context should compact before continuation.")
        XCTAssertFalse(conversation.modelContext.contains(where: { $0.responseContinuationID != nil }))

        let requests = ContinuationURLProtocol.requestBodies
        XCTAssertEqual(requests.count, 3, "The middle request should compact the conversation before continuing the answer.")
        let secondRequest = try XCTUnwrap(
            JSONSerialization.jsonObject(with: requests[2]) as? [String: Any]
        )
        let wireMessages = try XCTUnwrap(secondRequest["messages"] as? [[String: Any]])
        XCTAssertTrue(wireMessages.contains {
            $0["role"] as? String == "assistant" && ($0["content"] as? String)?.contains("The first part.") == true
        })
        XCTAssertTrue(wireMessages.contains {
            $0["role"] as? String == "user" && ($0["content"] as? String)?.contains("Continue the assistant response") == true
        })
    }

    private func makeTemporaryPaths() -> SupportPaths {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DotsHarnessContinuationTests-\(UUID().uuidString)", isDirectory: true)
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
        return paths
    }
}

private final class ContinuationURLProtocol: URLProtocol {
    nonisolated(unsafe) static var responses: [Data] = []
    nonisolated(unsafe) static var requestBodies: [Data] = []
    private static let lock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "continuation.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let data = Self.responses.isEmpty
            ? Data(#"{"choices":[{"message":{"role":"assistant","content":"done"},"finish_reason":"stop"}]}"#.utf8)
            : Self.responses.removeFirst()
        let body = Self.bodyData(from: request)
        Self.requestBodies.append(body)
        Self.lock.unlock()

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func reset() {
        lock.lock()
        responses = []
        requestBodies = []
        lock.unlock()
    }

    private static func bodyData(from request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(contentsOf: buffer[..<count])
        }
        return data
    }
}

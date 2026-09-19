// Copyright (c) 2026 DOTS

import Foundation
import PluginRuntime
import XCTest
@testable import DotsHarnessCore

final class ConcurrentRunsTests: XCTestCase {
    override func setUp() {
        super.setUp()
        URLProtocol.registerClass(SlowEchoURLProtocol.self)
    }

    override func tearDown() {
        URLProtocol.unregisterClass(SlowEchoURLProtocol.self)
        super.tearDown()
    }

    /// Two chats run at once; switching chats leaves the first one running.
    @MainActor
    func testChatsRunInParallelAndKeepRunningInBackground() async throws {
        let host = NativeAgentHost(
            paths: temporaryPaths(),
            endpoint: AgentEndpointController(baseURL: "http://parallel.test", modelID: "test-model"),
            area: .chat
        )
        host.start(workspacePath: "")
        await host.refreshConnection()
        let started = Date()

        host.newConversation()
        let first = try XCTUnwrap(host.selectedID)
        let firstSend = Task { @MainActor in await host.send(text: "alpha", mode: .queue) }
        try await Self.waitUntil { host.isBusy }

        host.newConversation()
        let second = try XCTUnwrap(host.selectedID)
        XCTAssertNotEqual(first, second)
        XCTAssertFalse(host.isBusy, "The newly selected chat must not inherit the other chat's run.")
        let secondSend = Task { @MainActor in await host.send(text: "beta", mode: .queue) }
        try await Self.waitUntil { host.runningConversationIDs == [first, second] }
        XCTAssertTrue(host.anyRunBusy)

        await firstSend.value
        await secondSend.value
        XCTAssertLessThan(Date().timeIntervalSince(started), SlowEchoURLProtocol.delay * 1.9, "Runs were serialized.")
        XCTAssertFalse(host.anyRunBusy)

        func answers(_ id: String) -> [String] {
            host.conversations.first { $0.id == id }?.messages.filter { $0.kind == .assistant }.map(\.text) ?? []
        }
        // Each chat got exactly its own answer (the prompt may carry skill metadata first).
        XCTAssertEqual(answers(first).count, 1)
        XCTAssertEqual(answers(second).count, 1)
        XCTAssertTrue(answers(first).first?.hasSuffix("alpha") == true)
        XCTAssertTrue(answers(second).first?.hasSuffix("beta") == true)
    }

    @MainActor
    private static func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out")
    }

    private func temporaryPaths() -> SupportPaths {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConcurrentRunsTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
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
}

/// Answers each chat completion after a delay with the last user message echoed.
private final class SlowEchoURLProtocol: URLProtocol {
    static let delay: TimeInterval = 1.0

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "parallel.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = request.httpBody ?? request.httpBodyStream.map(Self.read) ?? Data()
        let messages = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["messages"] as? [[String: Any]] ?? []
        let last = messages.last { $0["role"] as? String == "user" }?["content"] as? String ?? ""
        let payload: [String: Any] = [
            "choices": [["message": ["role": "assistant", "content": "echo: \(last)"]]],
        ]
        let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.delay) { [weak self] in
            guard let self else { return }
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: data)
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}

    private static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

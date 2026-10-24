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
        let paths = temporaryPaths()
        let workspace = paths.root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let host = NativeAgentHost(
            paths: paths,
            endpoint: AgentEndpointController(baseURL: "http://parallel.test", modelID: "test-model")
        )
        host.start(workspacePath: workspace.path)
        await host.refreshConnection()
        SlowEchoURLProtocol.resetPeak()

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
        // Overlap, not wall-clock time: a timing budget flakes under suite load, while two
        // provider calls in flight at once cannot happen if the runs were serialized.
        XCTAssertEqual(SlowEchoURLProtocol.peakConcurrency, 2, "Runs were serialized.")
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

    /// A background task that exits wakes its idle chat: the notice becomes a turn of its own.
    @MainActor
    func testFinishedBackgroundTaskStartsATurnInItsIdleChat() async throws {
        let paths = temporaryPaths()
        let workspace = paths.root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let host = NativeAgentHost(
            paths: paths,
            endpoint: AgentEndpointController(baseURL: "http://parallel.test", modelID: "test-model")
        )
        host.start(workspacePath: workspace.path)
        await host.refreshConnection()
        host.newConversation()
        let id = try XCTUnwrap(host.selectedID)

        _ = host.agentTerminal(
            AgentToolCall(
                id: "1", name: TerminalSessionTool.name,
                arguments: #"{"action":"start","command":"true","description":"release build"}"#
            ),
            conversationID: id, workspace: workspace
        )
        func answers() -> [String] {
            host.conversations.first { $0.id == id }?.messages.filter { $0.kind == .assistant }.map(\.text) ?? []
        }
        for _ in 0..<1000 where answers().isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(answers().first?.contains("release build") == true, "\(answers())")
        XCTAssertTrue(host.conversations.first { $0.id == id }?.pendingPrompts.isEmpty == true)
    }

    /// The task's chat is not on screen when it exits: it still wakes, and the notice is not a user bubble.
    @MainActor
    func testFinishedBackgroundTaskWakesAChatThatIsNotOnScreen() async throws {
        let (host, workspace) = try await runningHost()
        host.newConversation()
        let id = try XCTUnwrap(host.selectedID)
        startTask("sleep 0.3", in: id, host: host, workspace: workspace)
        // A blank chat is reused by newConversation, so the other chat is added by hand.
        host.conversations.append(Conversation(id: "other", cwd: workspace.path))
        host.select("other")
        XCTAssertNotEqual(host.selectedID, id)

        func messages() -> [ChatMessage] { host.conversations.first { $0.id == id }?.messages ?? [] }
        for _ in 0..<1000 where !messages().contains(where: { $0.kind == .assistant }) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(messages().contains { $0.kind == .assistant && $0.text.contains("release build") })
        XCTAssertEqual(messages().first?.kind, .system)
        XCTAssertFalse(messages().contains { $0.kind == .user })
        XCTAssertNotEqual(host.selectedID, id)
    }

    /// A message sent while the task runs waits for it, then follows the agent's own notice.
    @MainActor
    func testQueuedMessageWaitsForARunningBackgroundTask() async throws {
        let (host, workspace) = try await runningHost()
        host.newConversation()
        let id = try XCTUnwrap(host.selectedID)
        startTask("sleep 0.6", in: id, host: host, workspace: workspace)
        host.submitPrompt(text: "next", attachments: [], mode: .queue, planMode: false, needsPlanIntentResolution: false)
        try await Task.sleep(nanoseconds: 300_000_000)
        func conversation() -> Conversation? { host.conversations.first { $0.id == id } }
        XCTAssertEqual(conversation()?.pendingPrompts.map(\.text), ["next"])
        XCTAssertTrue(conversation()?.messages.isEmpty == true)

        for _ in 0..<1000 where conversation()?.messages.filter({ $0.kind == .assistant }).count != 2 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(conversation()?.messages.filter { $0.kind != .assistant }.map(\.kind), [.system, .user])
        XCTAssertTrue(conversation()?.pendingPrompts.isEmpty == true)
    }

    /// Stopping the task by hand releases the message it held; a stopped turn is not woken.
    @MainActor
    func testStoppedTaskReleasesTheQueueAndAStoppedTurnStaysStopped() async throws {
        let (host, workspace) = try await runningHost()
        host.newConversation()
        let id = try XCTUnwrap(host.selectedID)
        startTask("sleep 30", in: id, host: host, workspace: workspace)
        host.submitPrompt(text: "next", attachments: [], mode: .queue, planMode: false, needsPlanIntentResolution: false)
        func conversation() -> Conversation? { host.conversations.first { $0.id == id } }
        XCTAssertEqual(conversation()?.pendingPrompts.count, 1)
        host.agentTerminals[id]?.first?.stop()
        for _ in 0..<1000 where conversation()?.messages.contains(where: { $0.kind == .assistant }) != true {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(conversation()?.messages.first?.text, "next")
        try await Self.waitUntil { !host.state(for: id).isBusy }

        host.state(for: id).queuePausedAfterStop = true
        startTask("true", in: id, host: host, workspace: workspace)
        try await Self.waitUntil { conversation()?.pendingPrompts.count == 1 }
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertNotNil(conversation()?.pendingPrompts.first?.notice)
        XCTAssertEqual(conversation()?.messages.filter { $0.kind == .assistant }.count, 1)
        host.stopAllAgentTerminals()
    }

    /// A task that reads the terminal wakes the agent, once per question; a task that only
    /// leaves a line unfinished while it works does not.
    @MainActor
    func testBackgroundTaskWaitingForInputWakesTheAgent() async throws {
        NativeAgentHost.backgroundInputQuiet = 0.4
        defer { NativeAgentHost.backgroundInputQuiet = 8 }
        let (host, workspace) = try await runningHost()
        host.newConversation()
        let id = try XCTUnwrap(host.selectedID)
        let waiting = AppCopy.text("backgroundTasks.waitingInput")
        func notices() -> [String] {
            host.conversations.first { $0.id == id }?.messages.filter { $0.kind == .system }.map(\.text) ?? []
        }
        func asked() -> Int { notices().filter { $0.hasSuffix(waiting) }.count }

        startTask("printf 'Building... '; sleep 2; echo done", in: id, host: host, workspace: workspace)
        try await Self.waitUntil(tries: 1000) { notices().count == 1 }
        XCTAssertEqual(asked(), 0, "\(notices())")
        XCTAssertEqual(host.agentTerminals[id]?.last?.output, "Building...done\n")

        startTask(
            "printf 'one? '; read a; sleep 1; printf 'two? '; read b; test \"$a$b\" = yn; exit $(($? + 5))",
            in: id, host: host, workspace: workspace
        )
        let session = try XCTUnwrap(host.agentTerminals[id]?.last)
        try await Self.waitUntil(tries: 1000) { asked() == 1 }
        session.sendInput("y\n")
        try await Self.waitUntil(tries: 1000) { asked() == 2 }
        XCTAssertTrue(session.isRunning)
        session.sendInput("n\n")
        try await Self.waitUntil(tries: 1000) { !session.isRunning }
        XCTAssertEqual(session.exitCode, 5)
        XCTAssertEqual(session.output, "one?y\ntwo?n\n")
        XCTAssertEqual(asked(), 2)

        // Key-reading prompts: one that blocks in read with the terminal in raw mode, and one
        // that, like node, unblocks SIGTTOU and waits with select before it reads.
        for unblock in ["", "sigprocmask(SIG_UNBLOCK, POSIX::SigSet->new(SIGTTOU)); "] {
            let before = asked()
            startTask(
                #"perl -MPOSIX -e '$|=1; "# + unblock + #"""
                $t=POSIX::Termios->new; $t->getattr(0); $o=$t->getlflag;
                $t->setlflag($o & ~(ICANON|ECHO)); until ($t->setattr(0,TCSANOW)) {} print "pick [a/b] ";
                vec($r,0,1)=1; select($r,undef,undef,undef); sysread(STDIN,$c,1);
                $t->setlflag($o); $t->setattr(0,TCSANOW); print "got $c\n"; exit($c eq "a" ? 6 : 1)'
                """#,
                in: id, host: host, workspace: workspace
            )
            let menu = try XCTUnwrap(host.agentTerminals[id]?.last)
            try await Self.waitUntil(tries: 1000) { asked() == before + 1 }
            XCTAssertTrue(menu.isRunning)
            menu.sendInput("a")
            try await Self.waitUntil(tries: 1000) { !menu.isRunning }
            XCTAssertEqual(menu.exitCode, 6, menu.output)
            XCTAssertEqual(menu.output, "pick [a/b]got a\n")
            XCTAssertEqual(asked(), before + 1)
        }
    }

    @MainActor
    private func runningHost() async throws -> (NativeAgentHost, URL) {
        let paths = temporaryPaths()
        let workspace = paths.root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let host = NativeAgentHost(
            paths: paths,
            endpoint: AgentEndpointController(baseURL: "http://parallel.test", modelID: "test-model")
        )
        host.start(workspacePath: workspace.path)
        await host.refreshConnection()
        return (host, workspace)
    }

    @MainActor
    private func startTask(_ command: String, in id: String, host: NativeAgentHost, workspace: URL) {
        let arguments = try! JSONSerialization.data(withJSONObject: [
            "action": "start", "command": command, "description": "release build",
        ])
        _ = host.agentTerminal(
            AgentToolCall(id: UUID().uuidString, name: TerminalSessionTool.name, arguments: String(decoding: arguments, as: UTF8.self)),
            conversationID: id, workspace: workspace
        )
    }

    @MainActor
    private static func waitUntil(tries: Int = 200, _ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<tries {
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
    private static let gauge = ProviderCallGauge()

    static var peakConcurrency: Int { gauge.peak }

    static func resetPeak() { gauge.reset() }

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
        Self.gauge.enter()
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.delay) { [weak self] in
            guard let self else { return }
            Self.gauge.leave()
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

/// Counts provider calls in flight at once. A lock keeps it safe under Swift 6 strict concurrency.
private final class ProviderCallGauge: @unchecked Sendable {
    private let lock = NSLock()
    private var inFlight = 0
    private var highest = 0

    var peak: Int { lock.withLock { highest } }

    func enter() {
        lock.withLock {
            inFlight += 1
            highest = max(highest, inFlight)
        }
    }

    func leave() { lock.withLock { inFlight -= 1 } }

    func reset() { lock.withLock { inFlight = 0; highest = 0 } }
}

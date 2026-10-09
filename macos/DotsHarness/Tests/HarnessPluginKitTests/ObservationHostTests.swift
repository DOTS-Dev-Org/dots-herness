// Copyright (c) 2026 DOTS

import Foundation
import Observation
import PluginRuntime
import XCTest
@testable import DotsHarnessCore

/// The native host is @Observable: a reader must be told about every change to what it
/// read, and must not be woken by changes to anything else.
@MainActor
final class ObservationHostTests: XCTestCase {
    private var root: URL!
    private var workspace: URL!
    private var paths: SupportPaths!

    override func setUp() async throws {
        URLProtocol.registerClass(ToolStepsURLProtocol.self)
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ObservationHost-\(UUID().uuidString)", isDirectory: true)
        workspace = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        for index in 0..<5 { try "file \(index)".write(to: workspace.appendingPathComponent("f\(index).txt"), atomically: true, encoding: .utf8) }
        paths = SupportPaths(
            root: root.appendingPathComponent("support", isDirectory: true),
            plugins: root.appendingPathComponent("plugins"),
            presets: root.appendingPathComponent("presets"),
            settings: root.appendingPathComponent("settings.json"),
            hostPatch: root.appendingPathComponent("host.patch.yml"),
            trust: root.appendingPathComponent("trust.json"),
            models: root.appendingPathComponent("models"),
            runtime: root.appendingPathComponent("runtime")
        )
    }

    override func tearDown() async throws {
        URLProtocol.unregisterClass(ToolStepsURLProtocol.self)
        try? FileManager.default.removeItem(at: root)
    }

    /// Counts changes of everything `read` touches, re-arming after each one.
    @MainActor
    private final class Watch {
        private(set) var fires = 0
        private let read: @MainActor () -> Void

        init(_ read: @escaping @MainActor () -> Void) {
            self.read = read
            arm()
        }

        private func arm() {
            withObservationTracking { read() } onChange: { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    self.fires += 1
                    self.arm()
                }
            }
        }
    }

    private func makeHost(steps: Int = 2, permission: AgentPermissionMode = .full) async -> NativeAgentHost {
        ToolStepsURLProtocol.steps = steps
        ToolStepsURLProtocol.scriptedCalls = []
        ToolStepsURLProtocol.failsWithLimit = false
        ToolStepsURLProtocol.externalFile = nil
        let host = NativeAgentHost(
            paths: paths,
            endpoint: AgentEndpointController(baseURL: "http://obs.test", modelID: "m")
        )
        host.start(workspacePath: workspace.path)
        host.setPermissionMode(permission)
        await host.refreshConnection()
        host.newConversation()
        return host
    }

    private func settle() async throws { try await Task.sleep(nanoseconds: 60_000_000) }

    func testCodingRunReadsEditsAndRereadsPastEightToolRounds() async throws {
        let host = await makeHost(steps: 14)
        let original = (1...240).map { "line-\($0):" + String(repeating: "x", count: 60) }.joined(separator: "\n")
        let file = workspace.appendingPathComponent("project.swift")
        try original.write(to: file, atomically: true, encoding: .utf8)
        ToolStepsURLProtocol.externalFile = workspace.appendingPathComponent("f0.txt")
        ToolStepsURLProtocol.scriptedCalls = stride(from: 1, through: 240, by: 20).map { start in
            ["name": "read_file", "arguments": "{\"path\":\"project.swift\",\"offset\":\(start),\"limit\":20}"]
        } + [
            ["name": "edit_file", "arguments": #"{"path":"project.swift","edits":[{"old_text":"line-180:","new_text":"fixed-180:"}]}"#],
            ["name": "read_file", "arguments": #"{"path":"project.swift","offset":180,"limit":1}"#],
        ]
        await host.send(text: "read the project, change line-180 to fixed-180 and reread it", mode: .queue)
        let conversation = try XCTUnwrap(host.selected)
        XCTAssertEqual(conversation.messages.last(where: { $0.kind == .assistant })?.text, "done")
        XCTAssertEqual(conversation.modelContext.filter { $0.role == .tool }.count, 14)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), original.replacingOccurrences(of: "line-180:", with: "fixed-180:"))
        XCTAssertTrue(conversation.modelContext.last(where: { $0.role == .tool })?.content.hasPrefix("fixed-180:") == true)
        XCTAssertEqual(conversation.messages.last(where: { $0.kind == .assistant })?.changedFiles.map(\.path), ["project.swift"])
        XCTAssertTrue(host.concurrentChanges.contains { $0.path == "f0.txt" })
        XCTAssertFalse(conversation.running)
        XCTAssertFalse(conversation.messages.contains { $0.text == AppCopy.text("agent.toolStepLimit") })
    }

    func testProviderLimitPreservesAnOrdinaryTasksContinuation() async throws {
        let host = await makeHost()
        ToolStepsURLProtocol.failsWithLimit = true
        await host.send(text: "inspect the project", mode: .queue)
        XCTAssertEqual(host.selected?.continuation?.reason, .providerLimit)
        XCTAssertTrue(host.canContinue)
        XCTAssertFalse(host.isBusy)
    }

    func testToolRoundBoundaryPausesWithCompletedToolResults() async throws {
        let host = await makeHost(steps: NativeAgentHost.maxToolSteps + 1)
        await host.send(text: "inspect the project", mode: .queue)
        let conversation = try XCTUnwrap(host.selected)
        XCTAssertEqual(conversation.continuation?.reason, .toolStepLimit)
        XCTAssertTrue(host.canContinue)
        let calls = conversation.modelContext.flatMap(\.toolCalls)
        let results = conversation.modelContext.filter { $0.role == .tool }
        XCTAssertEqual(calls.count, NativeAgentHost.maxToolSteps)
        XCTAssertEqual(Set(calls.map(\.id)), Set(results.compactMap(\.toolCallID)))
        let restored = try JSONDecoder().decode(Conversation.self, from: JSONEncoder().encode(conversation))
        XCTAssertEqual(restored.continuation?.reason, .toolStepLimit)
        XCTAssertTrue(restored.canContinue)
    }

    /// Everything the window shows about a run changes while it runs.
    func testRunNotifiesReadersOfRunState() async throws {
        let host = await makeHost()
        let busy = Watch { _ = host.isBusy }
        let anyBusy = Watch { _ = host.anyRunBusy }
        let running = Watch { _ = host.runningConversationIDs }
        let conversations = Watch { _ = host.conversations }
        let selected = Watch { _ = host.selected }
        await host.send(text: "list files", mode: .queue)
        try await settle()
        XCTAssertGreaterThan(busy.fires, 0, "isBusy")
        XCTAssertGreaterThan(anyBusy.fires, 0, "anyRunBusy")
        XCTAssertGreaterThan(running.fires, 0, "runningConversationIDs")
        XCTAssertGreaterThan(conversations.fires, 0, "conversations")
        XCTAssertGreaterThan(selected.fires, 0, "selected")
    }

    /// A clarification tool can pause a run without changing its busy state;
    /// the global question presenter must still be invalidated for the waiting run.
    func testPendingQuestionNotifiesReadersOfRunState() async throws {
        let host = await makeHost()
        let conversationID = try XCTUnwrap(host.selectedID)
        let questionReader = Watch { _ = host.pendingQuestion }
        let allQuestionReader = Watch { _ = host.pendingQuestions }
        let pending = PendingQuestion(
            conversationID: conversationID,
            toolCallID: "ask-user",
            questions: [AskUserQuestion(id: "q0", header: "Scope", prompt: "Which scope?", options: ["macOS"])]
        )

        AgentRunScope.$conversationID.withValue(conversationID) {
            host.pendingQuestion = pending
        }
        try await settle()
        XCTAssertGreaterThan(questionReader.fires, 0, "pendingQuestion")
        XCTAssertGreaterThan(allQuestionReader.fires, 0, "pendingQuestions")
        XCTAssertEqual(host.pendingQuestions, [pending])

        AgentRunScope.$conversationID.withValue(conversationID) {
            host.pendingQuestion = nil
        }
        XCTAssertTrue(host.pendingQuestions.isEmpty)
    }

    /// The clarification tool stays suspended until the matching conversation answers.
    func testAskUserReturnsTheAnswerToItsRun() async throws {
        let host = await makeHost()
        let conversationID = try XCTUnwrap(host.selectedID)
        let call = AgentToolCall(
            id: "ask-user-flow",
            name: AskUserTool.name,
            arguments: #"{"questions":[{"header":"Target","question":"Which target?","options":["macOS","Windows"]}]}"#
        )

        let task = Task { @MainActor in
            await AgentRunScope.$conversationID.withValue(conversationID) {
                await host.askUser(call, conversationID: conversationID)
            }
        }
        for _ in 0..<100 where host.pendingQuestion == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        let pending = try XCTUnwrap(host.pendingQuestion)
        XCTAssertEqual(pending.conversationID, conversationID)
        XCTAssertEqual(pending.questions.first?.prompt, "Which target?")

        host.answerQuestions(["macOS"], in: conversationID)
        let result = await task.value
        XCTAssertTrue(result.contains("Q: Which target?\nA: macOS"))
        XCTAssertNil(host.pendingQuestion)
    }

    /// What is not read is not woken: the composer's permission mode ignores a whole run.
    func testUnrelatedReadersAreNotWoken() async throws {
        let host = await makeHost()
        let permission = Watch { _ = host.permissionMode }
        let backend = Watch { _ = host.browserBackendSetting }
        let connection = Watch { _ = host.connection }
        let access = Watch { _ = host.accessRevision }
        await host.send(text: "list files", mode: .queue)
        try await settle()
        XCTAssertEqual(permission.fires, 0)
        XCTAssertEqual(backend.fires, 0)
        XCTAssertEqual(connection.fires, 0)
        XCTAssertEqual(access.fires, 0)
    }

    /// A conversation that starts running after the reader looked still wakes it.
    func testRunningSetSeesRunsThatStartLater() async throws {
        let host = await makeHost()
        let first = try XCTUnwrap(host.selectedID)
        await host.send(text: "alpha", mode: .queue)        // an untouched blank chat would be reused
        let running = Watch { _ = host.runningConversationIDs }
        let anyBusy = Watch { _ = host.anyRunBusy }
        host.newConversation()
        let second = try XCTUnwrap(host.selectedID)
        XCTAssertNotEqual(first, second)
        try await settle()
        let before = running.fires
        let send = Task { @MainActor in await host.send(text: "beta", mode: .queue) }
        for _ in 0..<100 where host.runningConversationIDs.isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(host.runningConversationIDs, [second])
        try await settle()
        XCTAssertGreaterThan(running.fires, before)
        XCTAssertGreaterThan(anyBusy.fires, 0)
        await send.value
        try await settle()
        XCTAssertTrue(host.runningConversationIDs.isEmpty)
    }

    /// A run waiting for permission is visible to the reader of `pendingApproval`.
    func testPendingApprovalNotifies() async throws {
        let host = await makeHost(steps: 1, permission: .ask)
        let approval = Watch { _ = host.pendingApproval }
        let send = Task { @MainActor in await host.send(text: "list files", mode: .queue) }
        for _ in 0..<200 where host.pendingApproval == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertNotNil(host.pendingApproval)
        try await settle()
        XCTAssertGreaterThan(approval.fires, 0)
        host.stopCurrentRun()
        await send.value
    }

    /// The sidebar lists come from the store: every kind of edit reaches their readers.
    func testStoreBackedListsNotify() async throws {
        let host = await makeHost()
        let workspacePath = workspace.path
        let currentProject = Watch { _ = host.conversations(inProject: workspacePath) }
        let outside = Watch { _ = host.conversations(outsideProjects: []) }
        let archived = Watch { _ = host.archivedConversations }
        let id = try XCTUnwrap(host.selectedID)

        await host.send(text: "hello", mode: .queue)
        try await settle()
        XCTAssertGreaterThan(currentProject.fires, 0, "send")
        XCTAssertGreaterThan(outside.fires, 0, "send")

        var fires = currentProject.fires
        host.renameConversation(id, to: "renamed")
        try await settle()
        XCTAssertGreaterThan(currentProject.fires, fires, "rename")
        XCTAssertEqual(host.conversations(inProject: workspacePath).first { $0.id == id }?.title, "renamed")

        fires = archived.fires
        host.setArchived(id, archived: true)
        try await settle()
        XCTAssertGreaterThan(archived.fires, fires, "archive")

        fires = currentProject.fires
        host.deleteConversation(id)
        try await settle()
        XCTAssertGreaterThan(currentProject.fires, fires, "delete")
        XCTAssertNil(host.conversations(inProject: workspacePath).first { $0.id == id })
    }

    /// Edits to another workspace's chats never touch a tracked property.
    func testOtherWorkspaceEditsNotifyProjectReaders() async throws {
        let host = await makeHost()
        let other = root.appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let store = ConversationStore(paths: paths)
        var chat = Conversation(
            id: "other-chat", title: "other", messages: [ChatMessage(kind: .user, text: "hi")],
            blank: false, cwd: other.path)
        chat.unread = true
        store.save([chat])

        let inProject = Watch { _ = host.conversations(inProject: other.path) }
        host.archiveAll(forWorkspace: other.path)
        try await settle()
        XCTAssertGreaterThan(inProject.fires, 0)
        XCTAssertTrue(host.conversations(inProject: other.path).allSatisfy(\.archived))
    }

    /// Workspace memory is not a tracked property; its readers follow `accessRevision`.
    func testMemoryDerivedReadersFollowAccessRevision() async throws {
        let host = await makeHost()
        let access = Watch { _ = host.workspaceAccess }
        let members = Watch { _ = host.workspaceMembers }
        let decisions = Watch { _ = host.pendingWorkspaceDecisions }
        let ready = Watch { _ = host.memoryReady }
        let other = root.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        host.setWorkspace(other.path)               // re-binds workspace memory and bumps the revision
        try await settle()
        XCTAssertGreaterThan(host.accessRevision, 0)
        XCTAssertGreaterThan(access.fires, 0)
        XCTAssertGreaterThan(members.fires, 0)
        XCTAssertGreaterThan(decisions.fires, 0)
        XCTAssertGreaterThan(ready.fires, 0)
    }
}

/// Answers each chat completion after a short delay: `steps` list_files calls, then text.
private final class ToolStepsURLProtocol: URLProtocol {
    nonisolated(unsafe) static var steps = 2
    nonisolated(unsafe) static var scriptedCalls: [[String: String]] = []
    nonisolated(unsafe) static var failsWithLimit = false
    nonisolated(unsafe) static var externalFile: URL?

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "obs.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = request.httpBody ?? request.httpBodyStream.map(Self.read) ?? Data()
        let messages = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["messages"] as? [[String: Any]] ?? []
        let done = messages.filter { $0["role"] as? String == "tool" }.count
        if done == 1, let file = Self.externalFile {
            try? "changed by another writer".write(to: file, atomically: true, encoding: .utf8)
        }
        let function: [String: String] = done < Self.scriptedCalls.count
            ? Self.scriptedCalls[done]
            : ["name": "list_files", "arguments": "{\"path\":\".\",\"n\":\(done)}"]
        let message: [String: Any] = done < Self.steps
            ? ["role": "assistant", "content": "", "tool_calls": [[
                "id": "call\(done)", "type": "function",
                "function": function,
            ]]]
            : ["role": "assistant", "content": "done"]
        let payload: [String: Any] = Self.failsWithLimit
            ? ["error": ["message": "quota exceeded"]]
            : ["choices": [["message": message]]]
        let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.failsWithLimit ? 429 : 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { [weak self] in
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

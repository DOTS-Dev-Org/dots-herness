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

    private func makeHost(steps: Int = 2, area: AgentArea = .coding, permission: AgentPermissionMode = .full) async -> NativeAgentHost {
        ToolStepsURLProtocol.steps = steps
        let host = NativeAgentHost(
            paths: paths,
            endpoint: AgentEndpointController(baseURL: "http://obs.test", modelID: "m"),
            area: area
        )
        host.start(workspacePath: area == .chat ? "" : workspace.path)
        host.setPermissionMode(permission)
        await host.refreshConnection()
        host.newConversation()
        return host
    }

    private func settle() async throws { try await Task.sleep(nanoseconds: 60_000_000) }

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
        let host = await makeHost(area: .chat)
        let projectless = Watch { _ = host.projectlessConversations }
        let outside = Watch { _ = host.conversations(outsideProjects: []) }
        let archived = Watch { _ = host.archivedConversations }
        let id = try XCTUnwrap(host.selectedID)

        await host.send(text: "hello", mode: .queue)
        try await settle()
        XCTAssertGreaterThan(projectless.fires, 0, "send")
        XCTAssertGreaterThan(outside.fires, 0, "send")

        var fires = projectless.fires
        host.renameConversation(id, to: "renamed")
        try await settle()
        XCTAssertGreaterThan(projectless.fires, fires, "rename")
        XCTAssertEqual(host.projectlessConversations.first { $0.id == id }?.title, "renamed")

        fires = archived.fires
        host.setArchived(id, archived: true)
        try await settle()
        XCTAssertGreaterThan(archived.fires, fires, "archive")

        fires = projectless.fires
        host.deleteConversation(id)
        try await settle()
        XCTAssertGreaterThan(projectless.fires, fires, "delete")
        XCTAssertNil(host.projectlessConversations.first { $0.id == id })
    }

    /// Edits to another workspace's chats never touch a tracked property.
    func testOtherWorkspaceEditsNotifyProjectReaders() async throws {
        let host = await makeHost()
        let other = root.appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let store = ConversationStore(paths: paths, area: .coding)
        var chat = Conversation(
            id: "other-chat", title: "other", messages: [ChatMessage(kind: .user, text: "hi")],
            blank: false, cwd: other.path)
        chat.unread = true
        chat.area = .coding
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

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "obs.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = request.httpBody ?? request.httpBodyStream.map(Self.read) ?? Data()
        let messages = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["messages"] as? [[String: Any]] ?? []
        let done = messages.filter { $0["role"] as? String == "tool" }.count
        let message: [String: Any] = done < Self.steps
            ? ["role": "assistant", "content": "", "tool_calls": [[
                "id": "call\(done)", "type": "function",
                "function": ["name": "list_files", "arguments": "{\"path\":\".\",\"n\":\(done)}"],
            ]]]
            : ["role": "assistant", "content": "done"]
        let data = (try? JSONSerialization.data(withJSONObject: ["choices": [["message": message]]])) ?? Data()
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
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

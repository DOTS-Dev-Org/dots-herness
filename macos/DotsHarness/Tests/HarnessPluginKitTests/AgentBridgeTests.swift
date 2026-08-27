// Copyright (c) 2026 DOTS

import XCTest
import Foundation
import HarnessPluginKit
import PluginRuntime
import DotsHarnessCore

final class AgentBridgeTests: XCTestCase {
    @MainActor
    func testFreshAppDoesNotInferCurrentDirectoryOrImportChats() {
        let model = AppModel(paths: temporaryPaths())
        XCTAssertTrue(model.isFirstLaunch)
        XCTAssertTrue(model.conversations.isEmpty)
        XCTAssertFalse(model.workspacePath == "/")
    }

    @MainActor
    func testEmptyWorkspaceStartsWithSelectedNewChat() throws {
        let paths = temporaryPaths()
        let workspace = paths.root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        let bridge = AgentBridge(paths: paths, router: RouterController(baseURL: "http://127.0.0.1:1"))
        bridge.start(workspacePath: workspace.path)

        XCTAssertEqual(bridge.conversations.count, 1)
        XCTAssertEqual(bridge.selected?.title, "New chat")
        XCTAssertTrue(bridge.selected?.blank == true)
        XCTAssertEqual(bridge.selected?.cwd, workspace.path)
    }

    @MainActor
    func testNativeAgentHostOwnsTheLoopBehindTheUIFacade() throws {
        let paths = temporaryPaths()
        let workspace = paths.root.appendingPathComponent("native-host-project", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        let nativeHost = NativeAgentHost(paths: paths, router: RouterController(baseURL: "http://127.0.0.1:1"))
        nativeHost.start(workspacePath: workspace.path)
        XCTAssertEqual(nativeHost.selected?.cwd, workspace.path)

        let bridge = AgentBridge(paths: paths, router: RouterController(baseURL: "http://127.0.0.1:1"))
        bridge.start(workspacePath: workspace.path)
        XCTAssertEqual(bridge.selected?.cwd, workspace.path)
    }

    @MainActor
    func testSendKeepsDraftWhenAgentIsNotReady() {
        let model = AppModel(paths: temporaryPaths())
        model.draft = "Keep this draft"

        model.send()

        XCTAssertEqual(model.draft, "Keep this draft")
    }

    @MainActor
    func testUnsentDraftReturnsWithNewChat() throws {
        let paths = temporaryPaths()
        let workspace = paths.root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        ConversationStore(paths: paths).save([
            Conversation(id: "draft", cwd: workspace.path),
            Conversation(
                id: "chat",
                title: "Existing chat",
                messages: [ChatMessage(kind: .user, text: "Already sent")],
                blank: false,
                cwd: workspace.path
            ),
        ])

        let model = AppModel(paths: paths)
        model.bridge.start(workspacePath: workspace.path)
        model.selectedConversationID = "draft"
        model.draft = "Keep this unsent"
        let image = workspace.appendingPathComponent("reference.png")
        model.addDraftImages([image])

        model.selectedConversationID = "chat"
        XCTAssertEqual(model.draft, "")
        XCTAssertTrue(model.draftImages.isEmpty)

        model.newConversation()
        XCTAssertEqual(model.selectedConversationID, "draft")
        XCTAssertEqual(model.draft, "Keep this unsent")
        XCTAssertEqual(model.draftImages, [image])
    }

    @MainActor
    func testNewConversationDoesNotCreateAdditionalDraft() throws {
        let paths = temporaryPaths()
        let workspace = paths.root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        let store = ConversationStore(paths: paths)
        let firstDraft = Conversation(id: "draft-a", cwd: workspace.path)
        let legacyChat = Conversation(
            id: "chat",
            title: "New chat",
            messages: [ChatMessage(kind: .user, text: "Fix login flow\nKeep the session alive")],
            blank: false,
            cwd: workspace.path
        )
        store.save([firstDraft, legacyChat])

        let bridge = AgentBridge(paths: paths, router: RouterController(baseURL: "http://127.0.0.1:1"))
        bridge.start(workspacePath: workspace.path)

        XCTAssertEqual(bridge.conversations.filter(\.blank).count, 1)
        XCTAssertEqual(bridge.conversations.first(where: { $0.id == "chat" })?.title, "Fix login flow")
        XCTAssertEqual(store.load(workspacePath: workspace.path).count, 2)

        bridge.newConversation()
        bridge.newConversation()
        XCTAssertEqual(bridge.conversations.filter(\.blank).count, 1)
        XCTAssertEqual(bridge.conversations.count, 2)
    }

    func testConversationStoreIsWorkspaceScoped() throws {
        let paths = temporaryPaths()
        let first = paths.root.appendingPathComponent("project-a", isDirectory: true)
        let second = paths.root.appendingPathComponent("project-b", isDirectory: true)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)

        let store = ConversationStore(paths: paths)
        let a = Conversation(id: "a", title: "A", blank: false, cwd: first.path)
        let b = Conversation(id: "b", title: "B", blank: false, cwd: second.path)
        store.save([a, b])

        XCTAssertEqual(store.load(workspacePath: first.path).map(\.id), ["a"])
        XCTAssertEqual(store.load(workspacePath: second.path).map(\.id), ["b"])
    }

    func testConversationStoreStartsEmpty() {
        let store = ConversationStore(paths: temporaryPaths())
        XCTAssertTrue(store.load(workspacePath: "/tmp").isEmpty)
    }

    func testPendingPromptsAreTransientAndNeverPersisted() throws {
        let paths = temporaryPaths()
        let workspace = paths.root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let store = ConversationStore(paths: paths)
        var conversation = Conversation(id: "queued", cwd: workspace.path)
        conversation.pendingPrompts = [PendingPrompt(text: "finish this", mode: .queue)]
        store.save([conversation])

        let recovered = store.load(workspacePath: workspace.path)
        XCTAssertEqual(recovered.map(\.id), ["queued"])
        XCTAssertTrue(recovered[0].pendingPrompts.isEmpty)
    }

    func testAgentMessageAndToolsEncodeExpectedShape() {
        let call = AgentToolCall(id: "call-1", name: "read_file", arguments: "{\"path\":\"README.md\"}")
        let message = AgentMessage(role: .assistant, content: "", toolCalls: [call])
        let object = message.jsonObject()
        XCTAssertEqual(object["role"] as? String, "assistant")
        let toolCalls = object["tool_calls"] as? [[String: Any]]
        XCTAssertEqual(toolCalls?.first?["id"] as? String, "call-1")
        XCTAssertEqual(WorkspaceTools.definitions.map(\.name), ["list_files", "read_file", "write_file", "run_command", "ios_simulator"])
    }

    func testWorkspaceToolsCannotEscapeWorkspace() throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("DotsHarnessTools-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let call = AgentToolCall(id: "call", name: "read_file", arguments: "{\"path\":\"../outside.txt\"}")
        let result = WorkspaceTools.execute(call, workspace: workspace)
        XCTAssertTrue(result.contains("outside the workspace"))
        let memoryCall = AgentToolCall(id: "memory", name: "read_file", arguments: "{\"path\":\".mem/state.json\"}")
        let memoryResult = WorkspaceTools.execute(memoryCall, workspace: workspace)
        XCTAssertFalse(memoryResult.contains(".mem"))
        XCTAssertFalse(memoryResult.contains("host-managed"))
        try? FileManager.default.removeItem(at: workspace)
    }

    func testRunCommandDoesNotDeadlockOnLargeOutput() throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("DotsHarnessTools-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        // ~300KB, far past the ~64KB pipe buffer that used to wedge the child.
        let call = AgentToolCall(id: "big", name: "run_command", arguments: "{\"command\":\"for i in $(seq 1 30000); do echo 0123456789; done\"}")
        let result = WorkspaceTools.execute(call, workspace: workspace)
        XCTAssertFalse(result.contains("timed out"))
        XCTAssertTrue(result.contains("0123456789"))
    }

    func testRunCommandRejectsSymlinkEscape() throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("DotsHarnessTools-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        try FileManager.default.createSymbolicLink(
            at: workspace.appendingPathComponent("escape"),
            withDestinationURL: URL(fileURLWithPath: "/etc")
        )
        let call = AgentToolCall(id: "esc", name: "read_file", arguments: "{\"path\":\"escape/hosts\"}")
        let result = WorkspaceTools.execute(call, workspace: workspace)
        XCTAssertTrue(result.contains("outside the workspace"))
    }

    func testNativeAgentConfigurationIsIndependentOfSessionIDs() {
        let configuration = AgentConfiguration(
            baseURL: "https://api.openai.com/v1",
            model: "gpt-4.1-mini",
            provider: "GPT"
        )
        XCTAssertEqual(configuration.model, "gpt-4.1-mini")
        let connection = AgentConnection(
            endpoint: URL(string: configuration.baseURL)!,
            provider: configuration.provider,
            model: configuration.model
        )
        XCTAssertEqual(connection.provider, "GPT")
        XCTAssertEqual(connection.endpoint.absoluteString, configuration.baseURL)
    }

    func testNativeAgentClientUsesOpenAICompatibleEndpoint() async throws {
        MockURLProtocol.response = Data("""
        {"choices":[{"message":{"role":"assistant","content":"ready"}}],"usage":{"prompt_tokens":3,"completion_tokens":2}}
        """.utf8)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let client = NativeAgentClient(
            configuration: AgentConfiguration(
                baseURL: "http://example.test",
                model: "test/model"
            ),
            session: URLSession(configuration: configuration)
        )

        let response = try await client.complete(messages: [
            AgentMessage(role: .user, content: "hello"),
        ])

        XCTAssertEqual(response.message.content, "ready")
        XCTAssertEqual(response.usage?.outputTokens, 2)
        XCTAssertEqual(MockURLProtocol.lastRequest?.url?.path, "/v1/chat/completions")
        XCTAssertNil(MockURLProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization"))
    }

    func testChatGPTSessionUsesSessionTransportAndNotOpenAIAPIKeyTransport() async throws {
        MockURLProtocol.response = Data("""
        {"output":[{"type":"message","content":[{"type":"output_text","text":"ready"}]}],"usage":{"input_tokens":3,"output_tokens":2}}
        """.utf8)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let client = NativeAgentClient(
            configuration: AgentConfiguration(
                baseURL: "http://example.test/backend-api/codex",
                model: "gpt-4.1-mini",
                apiKey: "session-token",
                provider: "GPT",
                api: RouterAPIKind.chatGPT.rawValue,
                sessionAccountID: "account-1"
            ),
            session: URLSession(configuration: configuration)
        )

        let response = try await client.complete(messages: [AgentMessage(role: .user, content: "hello")])

        XCTAssertEqual(response.message.content, "ready")
        XCTAssertEqual(MockURLProtocol.lastRequest?.url?.path, "/backend-api/codex/responses")
        XCTAssertEqual(MockURLProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer session-token")
        XCTAssertEqual(MockURLProtocol.lastRequest?.value(forHTTPHeaderField: "ChatGPT-Account-ID"), "account-1")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(MockURLProtocol.lastBody)) as? [String: Any])
        XCTAssertNil(body["messages"])
        XCTAssertEqual(body["store"] as? Bool, false)
    }

    @MainActor
    func testWorkspaceMemoryInitializesOnlyOnFirstPrompt() throws {
        let paths = temporaryPaths()
        let workspace = paths.root.appendingPathComponent("memory-project", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try Data("// swift-tools-version: 5.9\n".utf8).write(to: workspace.appendingPathComponent("Package.swift"))

        let memory = WorkspaceMemory(paths: paths)
        memory.setWorkspace(workspace)
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.appendingPathComponent(".mem").path))

        memory.prepareForPrompt(
            prompt: "Türkçe cevap ver ve bu projeyi haritala",
            runID: UUID(),
            provider: "Direct",
            model: "test/model"
        )

        let memoryRoot = workspace.appendingPathComponent(".mem")
        XCTAssertTrue(FileManager.default.fileExists(atPath: memoryRoot.appendingPathComponent("manifest.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: memoryRoot.appendingPathComponent("state.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: memoryRoot.appendingPathComponent("map.md").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.root.appendingPathComponent("memory-identity.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: memoryRoot.appendingPathComponent("memory-identity.json").path))
        XCTAssertEqual(memory.accessStatus().role, .owner)
        XCTAssertTrue(memory.snapshot(for: "Package.swift").text.contains("Project map"))

        let second = WorkspaceMemory(paths: paths)
        second.setWorkspace(workspace)
        XCTAssertEqual(second.projectID, memory.projectID)
        XCTAssertEqual(second.accessStatus().role, .owner)

        let invite = try memory.createInvite(
            displayName: "Review device",
            role: .observer,
            score: 10,
            publicKey: "new-device-public-key"
        )
        XCTAssertFalse(invite.isEmpty)
        XCTAssertTrue(memory.pendingDecisions().isEmpty)
    }

    @MainActor
    func testWorkspaceMemoryRejectsTamperedEvent() throws {
        let paths = temporaryPaths()
        let workspace = paths.root.appendingPathComponent("tamper-project", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let memory = WorkspaceMemory(paths: paths)
        memory.setWorkspace(workspace)
        memory.prepareForPrompt(prompt: "initialize", runID: UUID(), provider: "Direct", model: "test/model")

        let eventsURL = workspace.appendingPathComponent(".mem/events")
        let event = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: eventsURL, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .first { url in
                guard let object = try? JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else { return false }
                return object["type"] as? String == "workspace.initialized"
            })
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: event)) as? [String: Any])
        var payload = try XCTUnwrap(object["payload"] as? [String: Any])
        payload["tampered"] = true
        object["payload"] = payload
        try JSONSerialization.data(withJSONObject: object).write(to: event, options: .atomic)

        memory.reload()
        XCTAssertNil(memory.accessStatus().role)
    }

    @MainActor
    func testExplicitLanguagePreferenceIsProjectedAfterTask() async throws {
        let paths = temporaryPaths()
        let workspace = paths.root.appendingPathComponent("preference-project", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let memory = WorkspaceMemory(paths: paths)
        memory.setWorkspace(workspace)
        let runID = UUID()
        memory.prepareForPrompt(prompt: "Artık İngilizce cevap ver", runID: runID, provider: "Direct", model: "test/model")
        memory.finishTask(runID: runID, success: true, finalText: "Done")
        for _ in 0..<3 { await Task.yield() }
        XCTAssertTrue(memory.snapshot(for: "next").text.contains("English"))
    }

    @MainActor
    func testMemoryNotesUseObsidianFrontmatterAndLinks() throws {
        let paths = temporaryPaths()
        let workspace = paths.root.appendingPathComponent("obsidian-notes-project", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        let memory = WorkspaceMemory(paths: paths)
        memory.setWorkspace(workspace)

        let runID = UUID()
        memory.prepareForPrompt(
            prompt: "karar: use SQLite for storage",
            runID: runID,
            provider: "Direct",
            model: "test/model"
        )
        memory.finishTask(runID: runID, success: true, finalText: "done")

        let memoryRoot = workspace.appendingPathComponent(".mem")
        let taskNoteURL = memoryRoot.appendingPathComponent("tasks/\(runID.uuidString).md")
        for relative in ["map.md", "index.md", "preferences.md", "tasks/\(runID.uuidString).md"] {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: memoryRoot.appendingPathComponent(relative).path),
                "expected .mem/\(relative) to be written"
            )
        }

        func frontmatter(of url: URL) throws -> String {
            let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
            XCTAssertEqual(lines.first, "---", "\(url.lastPathComponent) must open with a YAML frontmatter block")
            guard let closing = lines.dropFirst().firstIndex(of: "---") else {
                XCTFail("frontmatter block is not closed in \(url.lastPathComponent)")
                return ""
            }
            return lines[1..<closing].joined(separator: "\n")
        }

        let indexFront = try frontmatter(of: memoryRoot.appendingPathComponent("index.md"))
        XCTAssertTrue(indexFront.contains("id: index"))
        XCTAssertTrue(indexFront.contains("type:"))
        XCTAssertTrue(indexFront.contains("tags: ["))
        XCTAssertTrue(indexFront.contains("links: ["))
        let indexBody = try String(contentsOf: memoryRoot.appendingPathComponent("index.md"), encoding: .utf8)
        XCTAssertTrue(indexBody.contains("[[task-\(runID.uuidString)]]"))

        let taskFront = try frontmatter(of: taskNoteURL)
        XCTAssertTrue(taskFront.contains("id: task-\(runID.uuidString)"))
        XCTAssertTrue(taskFront.contains("type: task"))
        XCTAssertTrue(taskFront.contains("tags: ["))
        XCTAssertTrue(taskFront.contains("links: ["))
        let taskBody = try String(contentsOf: taskNoteURL, encoding: .utf8)
        XCTAssertTrue(taskBody.contains("[[index]]"))
    }

    @MainActor
    func testMemoryVaultParsesNotesEdgesAndBacklinks() throws {
        let paths = temporaryPaths()
        let workspace = paths.root.appendingPathComponent("vault-project", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        let memory = WorkspaceMemory(paths: paths)
        memory.setWorkspace(workspace)

        let runID = UUID()
        memory.prepareForPrompt(
            prompt: "karar: use SQLite for storage",
            runID: runID,
            provider: "Direct",
            model: "test/model"
        )
        memory.finishTask(runID: runID, success: true, finalText: "done")

        let vault = memory.vault()

        let indexNote = try XCTUnwrap(vault.notes.first { $0.id == "index" })
        let taskNote = try XCTUnwrap(vault.notes.first { $0.id.hasPrefix("task-") })
        XCTAssertEqual(taskNote.id, "task-\(runID.uuidString)")

        XCTAssertTrue(taskNote.links.contains("index"), "task note should wikilink to the index")
        XCTAssertTrue(indexNote.backlinks.contains(taskNote.id), "index note should be backlinked from the task note")

        XCTAssertFalse(vault.edges.isEmpty)
        XCTAssertTrue(
            vault.edges.contains { $0.from == taskNote.id && $0.to == "index" },
            "vault should contain a task-* -> index edge"
        )
    }

    func testSupportedCacheFieldsAreOptInAndUsageIsParsed() async throws {
        MockURLProtocol.response = Data("""
        {"choices":[{"message":{"role":"assistant","content":"ready"}}],"usage":{"prompt_tokens":10,"completion_tokens":2,"prompt_tokens_details":{"cached_tokens":7,"cache_write_tokens":3}}}
        """.utf8)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let client = NativeAgentClient(
            configuration: AgentConfiguration(
                baseURL: "http://example.test",
                model: "test/model",
                cacheCapabilities: AgentCacheCapabilities(
                    promptCacheKey: true,
                    usageCacheTokens: true,
                    cacheWriteTokens: true
                )
            ),
            session: URLSession(configuration: configuration)
        )

        let response = try await client.complete(
            messages: [AgentMessage(role: .user, content: "hello")],
            cachePolicy: AgentCachePolicy(promptCacheKey: "herness:stable")
        )

        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(MockURLProtocol.lastBody)) as? [String: Any])
        XCTAssertEqual(body["prompt_cache_key"] as? String, "herness:stable")
        XCTAssertEqual(response.usage?.cachedTokens, 7)
        XCTAssertEqual(response.usage?.cacheWriteTokens, 3)
    }

    private func temporaryPaths() -> SupportPaths {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DotsHarnessTests-\(UUID().uuidString)", isDirectory: true)
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

private final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var response = Data()
    nonisolated(unsafe) static var lastRequest: URLRequest?
    nonisolated(unsafe) static var lastBody: Data?
    
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lastRequest = request
        Self.lastBody = request.httpBody
        if Self.lastBody == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = buffer.withUnsafeMutableBufferPointer { pointer in
                    stream.read(pointer.baseAddress!, maxLength: pointer.count)
                }
                if count <= 0 { break }
                data.append(contentsOf: buffer[0..<count])
            }
            stream.close()
            Self.lastBody = data
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.response)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

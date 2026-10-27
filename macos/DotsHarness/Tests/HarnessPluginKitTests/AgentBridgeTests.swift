// Copyright (c) 2026 DOTS

import XCTest
import Foundation
import AppKit
import HarnessPluginKit
import PluginRuntime
@testable import DotsHarnessUI
@testable import DotsHarnessCore

final class AgentBridgeTests: XCTestCase {
    @MainActor
    func testToolSignatureIgnoresKeyOrderAndWhitespace() {
        let a = AgentToolCall(id: "1", name: "edit_file", arguments: "{\"path\":\"a.txt\",\"old\":\"x\"}")
        let b = AgentToolCall(id: "2", name: "edit_file", arguments: "{ \"old\": \"x\", \"path\": \"a.txt\" }")
        let c = AgentToolCall(id: "3", name: "edit_file", arguments: "{\"path\":\"b.txt\",\"old\":\"x\"}")
        XCTAssertEqual(AgentBridge.toolSignature(a), AgentBridge.toolSignature(b))
        XCTAssertNotEqual(AgentBridge.toolSignature(a), AgentBridge.toolSignature(c))
    }

    @MainActor
    func testMediaCommandsStayOutOfContextButGeneratedAssetRemainsAvailable() {
        let mediaTurnID = UUID().uuidString
        let conversation = Conversation(messages: [
            ChatMessage(kind: .user, text: "hello", turnID: "chat-turn"),
            ChatMessage(kind: .assistant, text: "hi", turnID: "chat-turn"),
            ChatMessage(kind: .user, text: "/imagegen a red fox", turnID: mediaTurnID),
            ChatMessage(
                kind: .assistant,
                text: "Image generated.",
                media: ChatMedia(kind: .image, path: "/tmp/fox.png", mimeType: "image/png"),
                turnID: mediaTurnID
            ),
        ])

        let context = NativeAgentHost.modelMessagesForContext(conversation)

        XCTAssertEqual(context.count, 3)
        XCTAssertEqual(context[0].content, "hello")
        XCTAssertEqual(context[1].content, "hi")
        XCTAssertTrue(context[2].content.contains("Generated media artifact"))
        XCTAssertTrue(context[2].content.contains("/tmp/fox.png"))
        XCTAssertFalse(context.contains(where: { $0.content.contains("/imagegen") }))
        XCTAssertEqual(conversation.messages.count, 4)
    }

    @MainActor
    func testConversationActivityNoticesStayOutOfProviderContext() {
        let conversation = Conversation(messages: [
            ChatMessage(kind: .user, text: "Inspect the project"),
            ChatMessage(
                kind: .system,
                text: "18,000 → 7,500 tokens",
                activityCode: "context_compacted_auto"
            ),
            ChatMessage(kind: .assistant, text: "The project is ready."),
        ])

        let context = NativeAgentHost.modelMessagesForContext(conversation)

        XCTAssertEqual(context.map(\.content), ["Inspect the project", "The project is ready."])
    }

    @MainActor
    func testFreshAppDoesNotInferCurrentDirectoryOrImportChats() {
        let model = AppModel(paths: temporaryPaths())
        XCTAssertTrue(model.isFirstLaunch)
        XCTAssertTrue(model.conversations.isEmpty)
        XCTAssertFalse(model.workspacePath == "/")
    }

    @MainActor
    func testPermissionModeDefaultsToAskAndPersistsAcrossChatsAndReloads() throws {
        let paths = temporaryPaths()
        let workspace = paths.root.appendingPathComponent("permission-project", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        let model = AppModel(paths: paths)
        XCTAssertEqual(model.permissionMode, .ask)
        XCTAssertEqual(model.bridge.permissionMode, .ask)
        XCTAssertFalse(model.showsFullAccessWarning)

        // Workspace permissions belong to the selected project. A fresh install
        // has no project until the public app boundary selects one.
        model.setWorkspace(workspace.path)
        let existingID = try XCTUnwrap(model.bridge.selectedID)
        model.bridge.renameConversation(existingID, to: "Existing chat")
        model.setPermissionMode(.full)

        XCTAssertEqual(model.bridge.permissionMode, .full)
        XCTAssertEqual(model.permissionMode, .full)
        XCTAssertTrue(model.showsFullAccessWarning)

        model.bridge.newConversation()
        XCTAssertEqual(model.permissionMode, .full)
        XCTAssertEqual(model.bridge.permissionMode, .full)

        model.dismissFullAccessWarning()
        model.setPermissionMode(.ask)
        model.setPermissionMode(.full)
        XCTAssertFalse(model.showsFullAccessWarning)

        let reloaded = AppModel(paths: paths)
        XCTAssertEqual(reloaded.permissionMode, .full)
        XCTAssertTrue(reloaded.fullAccessWarningDismissed)
        XCTAssertFalse(reloaded.showsFullAccessWarning)

        let invalidSettings: [String: JSONValue] = ["agent.permissionMode": .string("invalid")]
        try JSONEncoder().encode(invalidSettings).write(to: paths.settings, options: .atomic)
        let fallback = AppModel(paths: paths)
        XCTAssertEqual(fallback.permissionMode, .ask)
    }

    @MainActor
    func testPermissionModesClassifyWorkspaceTools() {
        XCTAssertTrue(NativeAgentHost.requiresApproval(mode: .ask, toolName: "list_files"))
        XCTAssertTrue(NativeAgentHost.requiresApproval(mode: .ask, toolName: "run_command"))
        XCTAssertFalse(NativeAgentHost.requiresApproval(mode: .safe, toolName: "list_files"))
        XCTAssertFalse(NativeAgentHost.requiresApproval(mode: .safe, toolName: "read_file"))
        XCTAssertTrue(NativeAgentHost.requiresApproval(mode: .safe, toolName: "write_file"))
        XCTAssertTrue(NativeAgentHost.requiresApproval(mode: .safe, toolName: "ios_simulator"))
        XCTAssertFalse(NativeAgentHost.requiresApproval(mode: .safe, toolName: "skill.read"))
        XCTAssertFalse(NativeAgentHost.requiresApproval(mode: .full, toolName: "run_command"))
    }

    func testToolRiskClassification() {
        XCTAssertEqual(NativeAgentHost.risk("read_file"), .readOnly)
        XCTAssertEqual(NativeAgentHost.risk("grep_files"), .readOnly)
        XCTAssertEqual(NativeAgentHost.risk("inspect_generated_media"), .readOnly)
        XCTAssertEqual(NativeAgentHost.risk("skill.read"), .readOnly)
        XCTAssertEqual(NativeAgentHost.risk("run_command"), .sideEffect)
        XCTAssertEqual(NativeAgentHost.risk("ios_simulator"), .sideEffect)
        XCTAssertEqual(NativeAgentHost.risk("plugin__weather__lookup"), .sideEffect)
        XCTAssertEqual(NativeAgentHost.risk("mcp__docs__search"), .sideEffect)
        XCTAssertEqual(NativeAgentHost.risk("write_file"), .workspaceMutation)
        XCTAssertEqual(NativeAgentHost.risk("remove_file"), .workspaceMutation)
        XCTAssertEqual(NativeAgentHost.risk("sandbox_status"), .readOnly)
    }

    @MainActor
    func testSandboxStatusIsReadOnlyAndDescribesTheActiveBoundary() throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("sandbox-status-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let host = NativeAgentHost(paths: temporaryPaths(), endpoint: AgentEndpointController())
        host.setWorkspace(workspace.path)
        host.setSandboxPolicy(
            SandboxExecutionPolicy(workspaceURL: workspace, networkAccess: false),
            branch: "herness/sandbox-status"
        )
        let tools = host.agentTools(workspace: workspace).defs.map(\.name)
        XCTAssertTrue(tools.contains("sandbox_status"))
        let prompt = HerNessPrompt.assemble(host.systemPromptSections(workspace: workspace))
        XCTAssertTrue(prompt.contains("herness/sandbox-status"))
        XCTAssertTrue(prompt.contains("disabled"))
    }

    func testCompactCommandKeepsTheMessageThatFollowsIt() {
        XCTAssertEqual(NativeAgentHost.compactCommand("/compact"), "")
        XCTAssertEqual(NativeAgentHost.compactCommand("/compact fix the login bug"), "fix the login bug")
        XCTAssertEqual(NativeAgentHost.compactCommand("/compact\nsecond line"), "second line")
        XCTAssertNil(NativeAgentHost.compactCommand("/compactor"))
        XCTAssertNil(NativeAgentHost.compactCommand("please /compact"))
    }

    func testPlanModeExposesRunCommandButNotWorkspaceMutations() {
        // Mirrors the plan-mode filter in NativeAgentHost.run.
        let planTools = WorkspaceTools.definitions
            .map(\.name)
            .filter { NativeAgentHost.risk($0) != .workspaceMutation }
        XCTAssertTrue(planTools.contains("run_command"))
        XCTAssertTrue(planTools.contains("read_file"))
        XCTAssertTrue(planTools.contains("ios_simulator"))
        XCTAssertFalse(planTools.contains("write_file"))
        XCTAssertFalse(planTools.contains("remove_file"))
    }

    @MainActor
    func testAskRejectsToolBeforeItChangesWorkspace() async throws {
        let paths = temporaryPaths()
        let workspace = paths.root.appendingPathComponent("approval-project", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let file = workspace.appendingPathComponent("created.txt")
        installApprovalResponses()
        defer { ApprovalURLProtocol.reset(); URLProtocol.unregisterClass(ApprovalURLProtocol.self) }

        let host = NativeAgentHost(
            paths: paths,
            endpoint: AgentEndpointController(baseURL: "http://approval.test", modelID: "test-model"),
            permissionMode: .ask
        )
        host.start(workspacePath: workspace.path)
        await host.refreshConnection()

        let sendTask = Task { @MainActor in
            await host.send(text: "create the file", mode: .queue)
        }
        let approval = try await waitForApproval(host)
        XCTAssertEqual(approval.toolName, "write_file")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))

        host.answerApproval("rejected")
        await sendTask.value

        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertNil(host.pendingApproval)
    }

    @MainActor
    func testAskAllowOnceExecutesThePendingTool() async throws {
        let paths = temporaryPaths()
        let workspace = paths.root.appendingPathComponent("approval-project", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let file = workspace.appendingPathComponent("created.txt")
        installApprovalResponses()
        defer { ApprovalURLProtocol.reset(); URLProtocol.unregisterClass(ApprovalURLProtocol.self) }

        let host = NativeAgentHost(
            paths: paths,
            endpoint: AgentEndpointController(baseURL: "http://approval.test", modelID: "test-model"),
            permissionMode: .ask
        )
        host.start(workspacePath: workspace.path)
        await host.refreshConnection()

        let sendTask = Task { @MainActor in
            await host.send(text: "create the file", mode: .queue)
        }
        _ = try await waitForApproval(host)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        host.answerApproval("allowed-once")
        await sendTask.value

        XCTAssertEqual(try String(contentsOf: file), "changed")
        XCTAssertNil(host.pendingApproval)
    }

    @MainActor
    func testFullModeExecutesWithoutPendingApproval() async throws {
        let paths = temporaryPaths()
        let workspace = paths.root.appendingPathComponent("approval-project", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let file = workspace.appendingPathComponent("created.txt")
        installApprovalResponses()
        defer { ApprovalURLProtocol.reset(); URLProtocol.unregisterClass(ApprovalURLProtocol.self) }

        let host = NativeAgentHost(
            paths: paths,
            endpoint: AgentEndpointController(baseURL: "http://approval.test", modelID: "test-model"),
            permissionMode: .full
        )
        host.start(workspacePath: workspace.path)
        await host.refreshConnection()
        await host.send(text: "create the file", mode: .queue)

        XCTAssertNil(host.pendingApproval)
        XCTAssertEqual(try String(contentsOf: file), "changed")
    }

    @MainActor
    func testHeadlessHostRejectsApprovalRequiredToolsWithoutWaiting() async throws {
        let paths = temporaryPaths()
        let workspace = paths.root.appendingPathComponent("headless-approval-project", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let file = workspace.appendingPathComponent("created.txt")
        installApprovalResponses()
        defer { ApprovalURLProtocol.reset(); URLProtocol.unregisterClass(ApprovalURLProtocol.self) }

        let host = NativeAgentHost(
            paths: paths,
            endpoint: AgentEndpointController(baseURL: "http://approval.test", modelID: "test-model"),
            permissionMode: .ask,
            nonInteractive: true
        )
        host.start(workspacePath: workspace.path)
        await host.refreshConnection()
        await host.send(text: "create the file", mode: .queue)

        XCTAssertNil(host.pendingApproval)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    @MainActor
    func testEmptyWorkspaceStartsWithSelectedNewChat() throws {
        let paths = temporaryPaths()
        let workspace = paths.root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        let bridge = AgentBridge(paths: paths, router: RouterController(baseURL: "http://127.0.0.1:1"))
        bridge.start(workspacePath: workspace.path)

        XCTAssertEqual(bridge.conversations.count, 1)
        XCTAssertEqual(bridge.selected?.title, "New conversation")
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
    func testPastedImageDataBecomesPersistentDraftAttachment() throws {
        let paths = temporaryPaths()
        let model = AppModel(paths: paths)
        let imageData = Data([0x89, 0x50, 0x4E, 0x47])

        model.addDraftImageData(imageData)

        let attachment = try XCTUnwrap(model.draftAttachments.first)
        XCTAssertEqual(attachment.kind, .image)
        XCTAssertEqual(attachment.mimeType, "image/png")
        XCTAssertTrue(attachment.path.hasPrefix(paths.runtime.appendingPathComponent("pasted-images").path))
        XCTAssertEqual(try Data(contentsOf: attachment.url), imageData)
    }

    @MainActor
    func testPromptEditorDecodesPastedImageFromPasteboard() throws {
        let representation = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 1,
            pixelsHigh: 1,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        let image = NSImage(size: NSSize(width: 1, height: 1))
        image.addRepresentation(representation)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        XCTAssertTrue(pasteboard.writeObjects([image]))

        let pastedData = try XCTUnwrap(PromptNSTextView.pngImageData(from: pasteboard))
        XCTAssertNotNil(NSBitmapImageRep(data: pastedData))
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
        model.setWorkspace(workspace.path)
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
            title: "New conversation",
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

    @MainActor
    func testUnifiedStoreOnlyLoadsSelectedProjectConversations() throws {
        let paths = temporaryPaths()
        let workspace = paths.root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        let store = ConversationStore(paths: paths)
        store.save([
            Conversation(id: "project-chat", title: "Project chat", blank: false, cwd: workspace.path),
            Conversation(id: "free-chat", title: "Free chat", blank: false),
        ])
        XCTAssertEqual(store.load(workspacePath: workspace.path).map(\.id), ["project-chat"])

        let bridge = AgentBridge(
            paths: paths,
            router: RouterController(baseURL: "http://127.0.0.1:1")
        )
        bridge.start(workspacePath: workspace.path)
        XCTAssertTrue(bridge.conversations(outsideProjects: [workspace.path]).isEmpty)
        let model = AppModel(paths: paths)
        XCTAssertEqual(model.workspacePath, "")
        XCTAssertNil(model.selectedConversationID)
    }

    @MainActor
    func testRecentIncludesConversationsOfRemovedProjects() throws {
        let paths = temporaryPaths()
        let kept = paths.root.appendingPathComponent("project-a", isDirectory: true)
        let removed = paths.root.appendingPathComponent("project-b", isDirectory: true)
        try FileManager.default.createDirectory(at: kept, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: removed, withIntermediateDirectories: true)

        let store = ConversationStore(paths: paths)
        store.save([
            Conversation(id: "kept-chat", title: "Kept", blank: false, cwd: kept.path),
            Conversation(id: "orphan-chat", title: "Orphan", blank: false, cwd: removed.path),
        ])

        let bridge = AgentBridge(
            paths: paths,
            router: RouterController(baseURL: "http://127.0.0.1:1")
        )
        bridge.start(workspacePath: kept.path)

        XCTAssertEqual(
            Set(bridge.conversations(outsideProjects: [kept.path]).map(\.id)),
            ["orphan-chat"]
        )
        XCTAssertEqual(
            Set(bridge.conversations(outsideProjects: [kept.path, removed.path]).map(\.id)),
            []
        )
    }

    @MainActor
    func testRecentListIsCheapToRedraw() throws {
        let paths = temporaryPaths()
        let kept = paths.root.appendingPathComponent("project-a", isDirectory: true)
        let removed = paths.root.appendingPathComponent("project-b", isDirectory: true)
        try FileManager.default.createDirectory(at: kept, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: removed, withIntermediateDirectories: true)

        let chats = (0..<300).map { index in
            Conversation(
                id: "chat-\(index)",
                title: "Chat \(index)",
                messages: [ChatMessage(kind: .user, text: String(repeating: "context ", count: 200))],
                blank: false,
                cwd: index.isMultiple(of: 2) ? removed.path : kept.path
            )
        }
        ConversationStore(paths: paths).save(chats)

        let bridge = AgentBridge(paths: paths, router: RouterController(baseURL: "http://127.0.0.1:1"))
        bridge.start(workspacePath: kept.path)

        // The sidebar calls this once per redraw; 200 redraws must not re-read and
        // re-recover the store each time.
        let started = Date()
        for _ in 0..<200 {
            XCTAssertEqual(bridge.conversations(outsideProjects: [kept.path]).count, 150)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.0)
    }

    @MainActor
    func testConversationPinAndArchiveStatesPersistAcrossScopes() throws {
        let paths = temporaryPaths()
        let workspace = paths.root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        let store = ConversationStore(paths: paths)
        store.save([
            Conversation(id: "project-chat", title: "Project chat", blank: false, cwd: workspace.path)
        ])

        let bridge = AgentBridge(
            paths: paths,
            router: RouterController(baseURL: "http://127.0.0.1:1")
        )
        bridge.start(workspacePath: workspace.path)
        bridge.togglePinned("project-chat")
        bridge.setArchived("project-chat", archived: true)

        XCTAssertTrue(store.load(workspacePath: workspace.path).first?.pinned == true)
        XCTAssertTrue(store.load(workspacePath: workspace.path).first?.archived == true)
        XCTAssertEqual(Set(bridge.archivedConversations.map(\.id)), ["project-chat"])
    }

    func testConversationStoreStartsEmpty() {
        let store = ConversationStore(paths: temporaryPaths())
        XCTAssertTrue(store.load(workspacePath: "/tmp").isEmpty)
    }

    func testChatMessageReadsLegacyPayloadWithoutRewindMetadata() throws {
        let legacy = Data(#"{"id":"legacy","kind":"user","text":"hello"}"#.utf8)
        let message = try JSONDecoder().decode(ChatMessage.self, from: legacy)

        XCTAssertEqual(message.id, "legacy")
        XCTAssertEqual(message.text, "hello")
        XCTAssertNil(message.turnID)
        XCTAssertTrue(message.changedFiles.isEmpty)
    }

    func testConversationStoreReadsLegacySessionsWithoutHistoryMetadata() throws {
        let paths = temporaryPaths()
        let workspace = paths.root.appendingPathComponent("legacy-project", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let legacy = Data(#"[{"id":"legacy-chat","title":"Legacy","messages":[{"id":"m","kind":"user","text":"hello"}],"blank":false,"cwd":"\#(workspace.path)"} ]"#.utf8)
        try legacy.write(to: paths.root.appendingPathComponent("sessions.json"))

        let conversation = try XCTUnwrap(ConversationStore(paths: paths).load(workspacePath: workspace.path).first)
        XCTAssertEqual(conversation.id, "legacy-chat")
        XCTAssertNil(conversation.messages.first?.turnID)
        XCTAssertTrue(conversation.messages.first?.changedFiles.isEmpty == true)
    }

    @MainActor
    func testStaleQueryForPreviousChatDoesNotStrandSelectedLoad() async throws {
        let paths = temporaryPaths()
        let workspace = paths.root.appendingPathComponent("switch-project", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let messages = (0..<20).map { ChatMessage(kind: .assistant, text: "m\($0)") }
        ConversationStore(paths: paths).save([
            Conversation(id: "a", title: "A", messages: messages, blank: false, cwd: workspace.path),
            Conversation(id: "b", title: "B", messages: messages, blank: false, cwd: workspace.path),
        ])
        let bridge = AgentBridge(paths: paths, router: RouterController(baseURL: "http://127.0.0.1:1"))
        bridge.start(workspacePath: workspace.path)
        func waitLoaded() async throws {
            for _ in 0..<200 where bridge.selected?.contentLoaded != true {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        bridge.select("a")
        try await waitLoaded()
        let messageID = try XCTUnwrap(bridge.selected?.messages.first?.id)

        bridge.select("b")
        // The previous chat's rows render once more with their own id.
        _ = bridge.canRewind(messageID: messageID, in: "a")
        try await waitLoaded()

        XCTAssertEqual(bridge.selected?.id, "b")
        XCTAssertTrue(bridge.selected?.contentLoaded == true)
    }

    @MainActor
    func testOpeningUnreadCompletedConversationMarksItRead() async throws {
        let paths = temporaryPaths()
        let workspace = paths.root.appendingPathComponent("unread-project", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        ConversationStore(paths: paths).save([
            Conversation(id: "unread", title: "Completed", blank: false, unread: true, cwd: workspace.path)
        ])

        let bridge = AgentBridge(paths: paths, router: RouterController(baseURL: "http://127.0.0.1:1"))
        bridge.start(workspacePath: workspace.path)
        XCTAssertTrue(bridge.conversations.first?.unread == true)

        bridge.select("unread")

        XCTAssertFalse(bridge.conversations.first?.unread == true)
        // select() writes to disk after the switch has painted, not inline.
        func storedUnread() -> Bool {
            ConversationStore(paths: paths).load(workspacePath: workspace.path).first?.unread == true
        }
        for _ in 0..<200 where storedUnread() { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(storedUnread())
    }

    /// The edit button reads this from the view body: finishing must leave it cached.
    @MainActor
    func testAsyncTurnFinishCachesSnapshotCompleteness() async throws {
        let paths = temporaryPaths()
        let workspace = paths.root.appendingPathComponent("finish-cache-project", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try Data("before".utf8).write(to: workspace.appendingPathComponent("file.txt"))
        let memory = WorkspaceMemory(paths: paths)
        memory.setWorkspace(workspace)
        XCTAssertTrue(memory.beginTurn(conversationID: "chat", turnID: "t", workspace: workspace))
        try Data("after".utf8).write(to: workspace.appendingPathComponent("file.txt"))

        _ = await memory.finishTurnResultAsync(conversationID: "chat", turnID: "t", workspace: workspace)

        XCTAssertTrue(memory.completeSnapshotTurns.contains("chat|t|\(workspace.standardizedFileURL.path)"))
    }

    @MainActor
    func testWorkspaceSnapshotsCaptureNetChangesAndPreserveConflicts() throws {
        let paths = temporaryPaths()
        let workspace = paths.root.appendingPathComponent("snapshot-project", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try Data("before".utf8).write(to: workspace.appendingPathComponent("modified.txt"))
        try Data("gone".utf8).write(to: workspace.appendingPathComponent("deleted.txt"))
        try Data("stable".utf8).write(to: workspace.appendingPathComponent("stable.txt"))

        let memory = WorkspaceMemory(paths: paths)
        memory.setWorkspace(workspace)
        let turnID = "snapshot-turn"
        XCTAssertTrue(memory.beginTurn(conversationID: "chat", turnID: turnID, workspace: workspace))

        try Data("agent".utf8).write(to: workspace.appendingPathComponent("modified.txt"))
        try FileManager.default.removeItem(at: workspace.appendingPathComponent("deleted.txt"))
        try Data("added".utf8).write(to: workspace.appendingPathComponent("added.txt"))
        try Data("transient".utf8).write(to: workspace.appendingPathComponent("transient.txt"))
        try FileManager.default.removeItem(at: workspace.appendingPathComponent("transient.txt"))
        try FileManager.default.createDirectory(at: workspace.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try Data("ignored".utf8).write(to: workspace.appendingPathComponent(".git/ignored"))
        try FileManager.default.createDirectory(at: workspace.appendingPathComponent(".mem"), withIntermediateDirectories: true)
        try Data("ignored".utf8).write(to: workspace.appendingPathComponent(".mem/ignored"))

        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", "printf shell > shell.txt"]
        shell.currentDirectoryURL = workspace
        try shell.run()
        shell.waitUntilExit()
        XCTAssertEqual(shell.terminationStatus, 0)

        let changed = memory.finishTurn(conversationID: "chat", turnID: turnID, workspace: workspace)
        XCTAssertEqual(
            Set(changed.map { "\($0.operation.rawValue):\($0.path)" }),
            Set([
                "modified:modified.txt",
                "deleted:deleted.txt",
                "added:added.txt",
                "added:shell.txt",
            ])
        )
        XCTAssertTrue(memory.hasCompleteTurnSnapshot(conversationID: "chat", turnID: turnID, workspace: workspace))

        let reloaded = WorkspaceMemory(paths: paths)
        reloaded.setWorkspace(workspace)
        XCTAssertTrue(reloaded.hasCompleteTurnSnapshot(conversationID: "chat", turnID: turnID, workspace: workspace))

        // A user edit after the agent must block the whole edit transaction,
        // while an ordinary rewind can still restore the other files.
        try Data("user".utf8).write(to: workspace.appendingPathComponent("modified.txt"))
        let aborted = try memory.restoreTurns(
            conversationID: "chat",
            turnIDs: [turnID],
            workspace: workspace,
            abortOnConflict: true
        )
        XCTAssertEqual(aborted.conflictPaths, ["modified.txt"])
        XCTAssertEqual(try String(contentsOf: workspace.appendingPathComponent("modified.txt")), "user")
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("added.txt").path))

        let restored = try memory.restoreTurns(
            conversationID: "chat",
            turnIDs: [turnID],
            workspace: workspace,
            abortOnConflict: false
        )
        XCTAssertEqual(restored.conflictPaths, ["modified.txt"])
        XCTAssertEqual(Set(restored.restoredPaths), Set(["added.txt", "deleted.txt", "shell.txt"]))
        XCTAssertEqual(try String(contentsOf: workspace.appendingPathComponent("modified.txt")), "user")
        XCTAssertEqual(try String(contentsOf: workspace.appendingPathComponent("deleted.txt")), "gone")
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("added.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("shell.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.appendingPathComponent(".git/ignored").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.appendingPathComponent(".mem/ignored").path))

        let missingBackup = paths.root
            .appendingPathComponent("rewind/chat/snapshot-turn/before/modified.txt")
        try FileManager.default.removeItem(at: missingBackup)
        XCTAssertFalse(memory.hasCompleteTurnSnapshot(conversationID: "chat", turnID: turnID, workspace: workspace))

        let noOpTurn = "snapshot-no-op"
        XCTAssertTrue(memory.beginTurn(conversationID: "chat", turnID: noOpTurn, workspace: workspace))
        try Data("agent-added-again".utf8).write(to: workspace.appendingPathComponent("added-again.txt"))
        _ = memory.finishTurn(conversationID: "chat", turnID: noOpTurn, workspace: workspace)
        try FileManager.default.removeItem(at: workspace.appendingPathComponent("added-again.txt"))
        let noOpResult = try memory.restoreTurns(
            conversationID: "chat",
            turnIDs: [noOpTurn],
            workspace: workspace,
            abortOnConflict: false
        )
        XCTAssertEqual(noOpResult, RewindResult())
    }

    @MainActor
    func testRewindRemovesSelectedAndLaterMessagesAndRestoresWorkspace() throws {
        let paths = temporaryPaths()
        let workspace = paths.root.appendingPathComponent("rewind-project", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let file = workspace.appendingPathComponent("state.txt")
        try Data("initial".utf8).write(to: file)

        let memory = WorkspaceMemory(paths: paths)
        memory.setWorkspace(workspace)
        memory.prepareForPrompt(prompt: "initialize rewind tests", runID: UUID(), provider: "Direct", model: "test/model")
        let firstTurn = "first-turn"
        XCTAssertTrue(memory.beginTurn(conversationID: "chat", turnID: firstTurn, workspace: workspace))
        try Data("first".utf8).write(to: file)
        _ = memory.finishTurn(conversationID: "chat", turnID: firstTurn, workspace: workspace)
        let secondTurn = "second-turn"
        XCTAssertTrue(memory.beginTurn(conversationID: "chat", turnID: secondTurn, workspace: workspace))
        try Data("second".utf8).write(to: file)
        _ = memory.finishTurn(conversationID: "chat", turnID: secondTurn, workspace: workspace)

        let store = ConversationStore(paths: paths)
        store.save([
            Conversation(
                id: "chat",
                title: "Keep this context",
                messages: [
                    ChatMessage(id: "prior", kind: .user, text: "prior context"),
                    ChatMessage(id: "selected", kind: .user, text: "first request", turnID: firstTurn),
                    ChatMessage(id: "first-output", kind: .assistant, text: "first output", turnID: firstTurn),
                    ChatMessage(id: "later", kind: .user, text: "second request", turnID: secondTurn),
                    ChatMessage(id: "later-output", kind: .assistant, text: "second output", turnID: secondTurn),
                ],
                modelContext: [AgentMessage(role: .user, content: "stale context")],
                blank: false,
                cwd: workspace.path
            ),
        ])

        let bridge = AgentBridge(paths: paths, router: RouterController(baseURL: "http://127.0.0.1:1"))
        bridge.start(workspacePath: workspace.path)
        XCTAssertTrue(bridge.canRewind(messageID: "selected", in: "chat"))
        XCTAssertFalse(bridge.canEdit(messageID: "selected", in: "chat"))
        XCTAssertTrue(bridge.canEdit(messageID: "later", in: "chat"))

        let result = try bridge.rewind(conversationID: "chat", beforeMessageID: "selected")
        XCTAssertEqual(result.conflictPaths, [])
        XCTAssertEqual(result.restoredPaths, ["state.txt"])
        XCTAssertEqual(try String(contentsOf: file), "initial")
        XCTAssertEqual(bridge.selected?.messages.map(\.id), ["prior"])
        XCTAssertTrue(bridge.selected?.modelContext.isEmpty == true)
    }

    @MainActor
    func testEditWithoutProviderLeavesTranscriptAndWorkspaceUntouched() async throws {
        let paths = temporaryPaths()
        let workspace = paths.root.appendingPathComponent("edit-project", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let file = workspace.appendingPathComponent("state.txt")
        try Data("before".utf8).write(to: file)

        let memory = WorkspaceMemory(paths: paths)
        memory.setWorkspace(workspace)
        let turnID = "edit-turn"
        XCTAssertTrue(memory.beginTurn(conversationID: "chat", turnID: turnID, workspace: workspace))
        try Data("agent".utf8).write(to: file)
        _ = memory.finishTurn(conversationID: "chat", turnID: turnID, workspace: workspace)
        ConversationStore(paths: paths).save([
            Conversation(
                id: "chat",
                messages: [ChatMessage(id: "message", kind: .user, text: "old", turnID: turnID)],
                blank: false,
                cwd: workspace.path
            ),
        ])

        let bridge = AgentBridge(paths: paths, endpoint: AgentEndpointController())
        bridge.start(workspacePath: workspace.path)
        let beforeMessages = try XCTUnwrap(bridge.selected?.messages)
        do {
            try await bridge.editLatestMessage(
                conversationID: "chat",
                messageID: "message",
                text: "new",
                attachments: []
            )
            XCTFail("editing without a provider should fail")
        } catch let error as ConversationMutationError {
            XCTAssertEqual(error, .notReady)
        }
        XCTAssertEqual(bridge.selected?.messages, beforeMessages)
        XCTAssertEqual(try String(contentsOf: file), "agent")
    }

    func testAcceptedPendingPromptsSurviveRestartWithoutCrossingPlanGate() throws {
        let paths = temporaryPaths()
        let workspace = paths.root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let store = ConversationStore(paths: paths)
        var conversation = Conversation(id: "queued", cwd: workspace.path)
        conversation.planGateActive = true
        conversation.pendingPrompts = [PendingPrompt(text: "finish this", mode: .queue)]
        store.save([conversation])

        let recovered = store.load(workspacePath: workspace.path)
        XCTAssertEqual(recovered.map(\.id), ["queued"])
        XCTAssertEqual(recovered[0].pendingPrompts.map(\.text), ["finish this"])
        XCTAssertTrue(recovered[0].planGateActive)
        XCTAssertFalse(recovered[0].pendingPrompts[0].bypassesPlanGate)
    }

    @MainActor
    func testAmbiguousPlanPromptReservesDurableQueuePositionBeforeClassification() async throws {
        let paths = temporaryPaths()
        let workspace = paths.root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let host = NativeAgentHost(paths: paths, endpoint: AgentEndpointController())
        host.start(workspacePath: workspace.path)

        var classificationStarted = false
        var classification: CheckedContinuation<Bool, Never>?
        host.planIntentClassifierOverride = { _ in
            await withCheckedContinuation { continuation in
                classificationStarted = true
                classification = continuation
            }
        }

        host.submitPrompt(
            text: "plan.md should be updated",
            attachments: [],
            mode: .steer,
            planMode: false,
            needsPlanIntentResolution: true
        )
        let conversationID = try XCTUnwrap(host.selectedID)
        var stored = ConversationStore(paths: paths).load(workspacePath: workspace.path)
        XCTAssertEqual(stored.first?.pendingPrompts.map(\.text), ["plan.md should be updated"])
        XCTAssertFalse(try XCTUnwrap(stored.first?.pendingPrompts.first).isPlanIntentResolved)

        host.submitPrompt(
            text: "second message",
            attachments: [],
            mode: .queue,
            planMode: false,
            needsPlanIntentResolution: false
        )
        XCTAssertEqual(host.conversations.first?.pendingPrompts.map(\.text), ["plan.md should be updated", "second message"])
        XCTAssertNil(host.takeNextPrompt(in: conversationID, allowQueue: true))

        for _ in 0..<100 where !classificationStarted { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(classificationStarted)
        classification?.resume(returning: false)
        for _ in 0..<100 {
            if host.conversations.first?.pendingPrompts.first?.isPlanIntentResolved == true { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        stored = ConversationStore(paths: paths).load(workspacePath: workspace.path)
        XCTAssertEqual(stored.first?.pendingPrompts.map(\.text), ["plan.md should be updated", "second message"])
        XCTAssertTrue(try XCTUnwrap(stored.first?.pendingPrompts.first).isPlanIntentResolved)
    }

    /// A message held without an endpoint must not leave a blank chat that a later "New chat" reuses.
    @MainActor
    func testHeldMessageMakesChatRealSoNewChatDoesNotReuseIt() throws {
        let paths = temporaryPaths()
        let workspace = paths.root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let host = NativeAgentHost(paths: paths, endpoint: AgentEndpointController())
        host.start(workspacePath: workspace.path)

        host.newConversation()
        let draft = try XCTUnwrap(host.selectedID)
        host.submitPrompt(text: "What does this app do?", attachments: [], mode: .queue, planMode: false, needsPlanIntentResolution: false)

        let chat = try XCTUnwrap(host.conversations.first(where: { $0.id == draft }))
        XCTAssertFalse(chat.blank)
        XCTAssertEqual(chat.title, "What does this app do?")
        XCTAssertEqual(chat.pendingPrompts.map(\.text), ["What does this app do?"])
        let stored = try XCTUnwrap(ConversationStore(paths: paths).load(workspacePath: workspace.path).first(where: { $0.id == draft }))
        XCTAssertFalse(stored.blank)
        XCTAssertEqual(stored.pendingPrompts.map(\.text), ["What does this app do?"])

        host.newConversation()
        XCTAssertNotEqual(host.selectedID, draft)
    }

    /// Reselecting a chat whose start was refused gives its held message another start attempt.
    @MainActor
    func testSelectingChatRetriesItsHeldMessage() async throws {
        let paths = temporaryPaths()
        let workspace = paths.root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let host = NativeAgentHost(paths: paths, endpoint: AgentEndpointController())
        host.start(workspacePath: workspace.path)

        host.newConversation()
        let draft = try XCTUnwrap(host.selectedID)
        host.submitPrompt(text: "What does this app do?", attachments: [], mode: .queue, planMode: false, needsPlanIntentResolution: false)
        // Let the first start attempt finish while the chat is still selected: without an endpoint it is refused.
        for _ in 0..<100 where host.state(for: draft).pendingPromptStartID != nil {
            try await Task.sleep(for: .milliseconds(10))
        }

        host.newConversation()
        XCTAssertNotEqual(host.selectedID, draft)
        host.status = "sentinel"
        host.select(draft)
        for _ in 0..<100 where host.status == "sentinel" {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(host.status, AppCopy.text("agent.configureEndpoint"))
        XCTAssertEqual(host.conversations.first(where: { $0.id == draft })?.pendingPrompts.count, 1)
    }

    @MainActor
    func testQueueWaitsForPlanApprovalAndThenContinues() {
        let host = NativeAgentHost(paths: temporaryPaths(), endpoint: AgentEndpointController())
        var conversation = Conversation(id: "chat", cwd: "")
        conversation.messages = [ChatMessage(id: "plan", kind: .plan, text: "the plan")]
        conversation.pendingPlanMessageID = "plan"
        let later = PendingPrompt(text: "later", mode: .queue)
        let steering = PendingPrompt(text: "priority later", mode: .steer)
        let approval = PendingPrompt(text: "apply", mode: .queue, approvedPlanID: "plan")
        let stale = PendingPrompt(text: "apply old", mode: .queue, approvedPlanID: "old")
        conversation.pendingPrompts = [later, steering, stale, approval]
        host.conversations = [conversation]

        // The plan is pending: only its approval may run, and the stale approval is dropped.
        XCTAssertEqual(host.takeNextPrompt(in: "chat", allowQueue: true)?.id, approval.id)
        XCTAssertNil(host.takeNextPrompt(in: "chat", allowQueue: true))
        XCTAssertEqual(host.conversations[0].pendingPrompts.map(\.id), [later.id, steering.id])

        // Once the plan is applied the held message continues.
        host.conversations[0].pendingPlanMessageID = nil
        host.conversations[0].planGateActive = false
        XCTAssertEqual(host.takeNextPrompt(in: "chat", allowQueue: true)?.id, steering.id)
    }

    @MainActor
    func testExplicitQueuePromotionIsTheOnlyPlanGateBypass() {
        let host = NativeAgentHost(paths: temporaryPaths(), endpoint: AgentEndpointController())
        var conversation = Conversation(id: "chat", cwd: "")
        conversation.planGateActive = true
        let held = PendingPrompt(text: "held", mode: .queue)
        let normalSteer = PendingPrompt(text: "normal steer", mode: .steer)
        let promoted = PendingPrompt(
            text: "run this now",
            mode: .steer,
            placement: .steering,
            bypassesPlanGate: true
        )
        conversation.pendingPrompts = [held, normalSteer, promoted]
        host.conversations = [conversation]

        XCTAssertEqual(host.takeNextPrompt(in: "chat", allowQueue: true)?.id, promoted.id)
        XCTAssertTrue(host.conversations[0].planGateActive)
        XCTAssertNil(host.takeNextPrompt(in: "chat", allowQueue: true))

        host.conversations[0].planGateActive = false
        XCTAssertEqual(host.takeNextPrompt(in: "chat", allowQueue: true)?.id, normalSteer.id)
        XCTAssertEqual(host.takeNextPrompt(in: "chat", allowQueue: true)?.id, held.id)
    }

    func testPlanApprovalRequiresAnExplicitPhrase() {
        XCTAssertTrue(PlanApproval.matches("  Onaylıyorum!!! "))
        XCTAssertTrue(PlanApproval.matches("apply plan."))
        XCTAssertTrue(PlanApproval.matches("GO AHEAD"))
        XCTAssertTrue(PlanApproval.matches("devam et"))
        XCTAssertTrue(PlanApproval.matches("PLANI UYGULA"))
        XCTAssertFalse(PlanApproval.matches("evet"))
        XCTAssertFalse(PlanApproval.matches("please apply the plan"))
        XCTAssertFalse(PlanApproval.matches("continue"))
    }

    func testProviderLimitErrorIsNotRetryable() {
        let error = NativeAgentError("quota exceeded", statusCode: 429, retryable: true)

        XCTAssertTrue(error.isLimit)
        XCTAssertFalse(error.retryable)
    }

    @MainActor
    func testCompletedNormalRunHasNoContinueAndPromotionPreservesSeparatePause() async throws {
        URLProtocol.registerClass(ApprovalURLProtocol.self)
        defer { ApprovalURLProtocol.reset(); URLProtocol.unregisterClass(ApprovalURLProtocol.self) }
        let paths = temporaryPaths()
        let workspace = paths.root.appendingPathComponent("normal-project", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let host = NativeAgentHost(
            paths: paths,
            endpoint: AgentEndpointController(baseURL: "http://approval.test", modelID: "test-model")
        )
        host.start(workspacePath: workspace.path)
        await host.refreshConnection()

        await host.send(text: "inspect", mode: .queue)
        XCTAssertFalse(host.canContinue)
        XCTAssertNil(host.selected?.continuation)

        let id = try XCTUnwrap(host.selectedID)
        let pause = ContinuationState(reason: .userStopped)
        host.conversations[0].continuation = pause
        host.conversations[0].planGateActive = true
        let resolvedConfiguration = await host.currentConfiguration()
        let configuration = try XCTUnwrap(resolvedConfiguration)
        let task = host.startRun(
            runID: UUID(),
            conversationID: id,
            configuration: configuration,
            workspace: workspace,
            context: [AgentMessage(role: .user, content: "independent promoted request")],
            planGateOverride: true
        )
        await task.value

        XCTAssertTrue(host.canContinue)
        XCTAssertEqual(host.selected?.continuation, pause)
        XCTAssertTrue(host.selected?.planGateActive == true)
    }

    @MainActor
    func testCompletedContinueConsumesPauseAndReleasesPlanGate() async throws {
        URLProtocol.registerClass(ApprovalURLProtocol.self)
        defer { ApprovalURLProtocol.reset(); URLProtocol.unregisterClass(ApprovalURLProtocol.self) }

        for reason in [ContinuationPauseReason.userStopped, .providerLimit, .applicationClosed, .networkLost] {
            for hasPlan in [false, true] {
                let paths = temporaryPaths()
                let workspace = paths.root.appendingPathComponent("continue-project", isDirectory: true)
                try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
                let host = NativeAgentHost(
                    paths: paths,
                    endpoint: AgentEndpointController(baseURL: "http://approval.test", modelID: "test-model")
                )
                host.start(workspacePath: workspace.path)
                await host.refreshConnection()
                let plan = ChatMessage(kind: .plan, text: "Apply the changes")
                host.conversations = [Conversation(
                    id: "continued-chat",
                    messages: [ChatMessage(kind: .user, text: "inspect"), plan],
                    modelContext: [AgentMessage(role: .user, content: "inspect")],
                    continuation: ContinuationState(reason: reason),
                    blank: false,
                    planGateActive: hasPlan,
                    pendingPlanMessageID: hasPlan ? plan.id : nil,
                    cwd: workspace.path
                )]
                host.selectedID = "continued-chat"
                XCTAssertTrue(host.canContinue)

                await host.continueCurrentRun()

                let completed = try XCTUnwrap(host.selected)
                XCTAssertEqual(completed.messages.last(where: { $0.kind == .assistant })?.text, "done")
                XCTAssertFalse(completed.running)
                XCTAssertFalse(completed.canContinue)
                XCTAssertFalse(host.canContinue)
                XCTAssertNil(completed.continuation)
                XCTAssertFalse(completed.planGateActive)
                XCTAssertNil(completed.pendingPlanMessageID)
                let restored = try JSONDecoder().decode(Conversation.self, from: JSONEncoder().encode(completed))
                XCTAssertFalse(NativeAgentHost.recover(restored).canContinue)
            }
        }
    }

    @MainActor
    func testModelCanSwitchARunningTurnToPlanMode() async throws {
        URLProtocol.registerClass(ApprovalURLProtocol.self)
        defer { ApprovalURLProtocol.reset(); URLProtocol.unregisterClass(ApprovalURLProtocol.self) }
        ApprovalURLProtocol.responses = [
            DeferredToolScript.reply(["id": "plan-1", "type": "function",
                "function": ["name": DeferredToolSession.enterPlanName, "arguments": "{}"]]),
            Data(#"{"choices":[{"message":{"role":"assistant","content":"1. Read the code"}}]}"#.utf8),
        ]
        let paths = temporaryPaths()
        let workspace = paths.root.appendingPathComponent("plan-project", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let host = NativeAgentHost(
            paths: paths,
            endpoint: AgentEndpointController(baseURL: "http://approval.test", modelID: "test-model")
        )
        var entered = false
        host.onPlanModeEntered = { entered = true }
        host.start(workspacePath: workspace.path)
        await host.refreshConnection()

        await host.send(text: "bu özelliği nasıl kuracağımızı adım adım düşünelim, kod yazma", mode: .queue)
        for _ in 0..<200 where host.selected?.running == true { try await Task.sleep(for: .milliseconds(10)) }

        XCTAssertTrue(entered)
        let plan = try XCTUnwrap(host.selected?.messages.last)
        XCTAssertEqual(plan.kind, .plan)
        XCTAssertEqual(host.selected?.pendingPlanMessageID, plan.id)
    }

    @MainActor
    func testDroppedConnectionPausesAndResumesWhenNetworkReturns() async throws {
        URLProtocol.registerClass(ApprovalURLProtocol.self)
        defer { ApprovalURLProtocol.reset(); URLProtocol.unregisterClass(ApprovalURLProtocol.self) }
        let paths = temporaryPaths()
        let workspace = paths.root.appendingPathComponent("offline-project", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let host = NativeAgentHost(
            paths: paths,
            endpoint: AgentEndpointController(baseURL: "http://approval.test", modelID: "test-model")
        )
        host.start(workspacePath: workspace.path)
        await host.refreshConnection()

        ApprovalURLProtocol.failure = .notConnectedToInternet
        await host.send(text: "inspect", mode: .queue)
        XCTAssertEqual(host.selected?.continuation?.reason, .networkLost)
        XCTAssertTrue(host.canContinue)

        ApprovalURLProtocol.failure = nil
        await host.resumeAfterNetworkIfNeeded()
        XCTAssertEqual(host.selected?.messages.last(where: { $0.kind == .assistant })?.text, "done")
        XCTAssertNil(host.selected?.continuation)
    }

    @MainActor
    func testCompletedContinuedDraftWaitsForApprovalWithoutContinue() async throws {
        URLProtocol.registerClass(ApprovalURLProtocol.self)
        defer { ApprovalURLProtocol.reset(); URLProtocol.unregisterClass(ApprovalURLProtocol.self) }
        let paths = temporaryPaths()
        let workspace = paths.root.appendingPathComponent("draft-project", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let host = NativeAgentHost(
            paths: paths,
            endpoint: AgentEndpointController(baseURL: "http://approval.test", modelID: "test-model")
        )
        host.start(workspacePath: workspace.path)
        await host.refreshConnection()
        host.conversations = [Conversation(
            id: "draft-chat",
            modelContext: [AgentMessage(role: .user, content: "draft a plan")],
            continuation: ContinuationState(reason: .userStopped),
            planGateActive: true,
            cwd: workspace.path
        )]
        host.selectedID = "draft-chat"
        host.activeRunPlanMode = true

        await host.continueCurrentRun()

        XCTAssertNotNil(host.selected?.pendingPlanMessageID)
        XCTAssertTrue(host.selected?.planGateActive == true)
        XCTAssertNil(host.selected?.continuation)
        XCTAssertFalse(host.canContinue)
    }

    func testContinuationSnapshotPersistsToolCallAndFullOutput() throws {
        let conversation = Conversation(
            id: "paused-chat",
            modelContext: [
                AgentMessage(role: .system, content: "system prompt"),
                AgentMessage(role: .user, content: "inspect"),
                AgentMessage(
                    role: .assistant,
                    content: "",
                    toolCalls: [AgentToolCall(id: "call-1", name: "read_file", arguments: "{\"path\":\"a.txt\"}")]
                ),
                AgentMessage(role: .tool, content: "the complete file contents", toolCallID: "call-1"),
            ],
            continuation: ContinuationState(
                reason: .providerLimit,
                provider: "OpenAI",
                model: "test-model",
                message: "Provider limit reached."
            ),
            blank: false
        )

        let restored = try JSONDecoder().decode(
            Conversation.self,
            from: JSONEncoder().encode(conversation)
        )

        XCTAssertTrue(restored.canContinue)
        XCTAssertEqual(restored.modelContext.count, 4)
        XCTAssertEqual(restored.modelContext[2].toolCalls[0].arguments, "{\"path\":\"a.txt\"}")
        XCTAssertEqual(restored.modelContext[3].content, "the complete file contents")
        XCTAssertEqual(restored.modelContext[3].toolCallID, "call-1")
        XCTAssertEqual(restored.continuation?.reason, .providerLimit)
    }

    @MainActor
    func testApplicationCloseRecoveryDoesNotReplayAnInFlightTool() throws {
        let conversation = Conversation(
            id: "closed-chat",
            modelContext: [
                AgentMessage(
                    role: .assistant,
                    content: "",
                    toolCalls: [AgentToolCall(id: "write-1", name: "write_file", arguments: "{\"path\":\"a.txt\"}")]
                ),
            ],
            running: true,
            blank: false,
            planGateActive: true,
            inFlightToolCalls: [
                InFlightToolCall(id: "write-1", name: "write_file", arguments: "{\"path\":\"a.txt\"}"),
            ],
        )

        let recovered = NativeAgentHost.recover(conversation)

        XCTAssertFalse(recovered.running)
        XCTAssertTrue(recovered.planGateActive)
        XCTAssertTrue(recovered.requiresToolOutcomeRecovery)
        XCTAssertEqual(recovered.continuation?.reason, .applicationClosed)
        XCTAssertNotNil(recovered.modelContext.first {
            $0.role == AgentMessage.Role.tool
                && $0.toolCallID == "write-1"
                && $0.content.contains("result of this tool call was durably known")
        })

        let restored = try JSONDecoder().decode(
            Conversation.self,
            from: JSONEncoder().encode(recovered)
        )
        XCTAssertTrue(restored.requiresToolOutcomeRecovery)
        XCTAssertEqual(restored.inFlightToolCalls.first?.id, "write-1")
        XCTAssertEqual(restored.continuation?.reason, .applicationClosed)
    }

    @MainActor
    func testShutdownPausePreservesAnExplicitUserStop() throws {
        let paths = temporaryPaths()
        let workspace = paths.root.appendingPathComponent("stopped-project", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let host = NativeAgentHost(
            paths: paths,
            endpoint: AgentEndpointController(baseURL: "http://approval.test", modelID: "test-model")
        )
        host.start(workspacePath: workspace.path)

        let write = InFlightToolCall(id: "write-1", name: "write_file", arguments: #"{"path":"a.txt"}"#)
        host.conversations = [Conversation(
            id: "stopped-chat",
            modelContext: [AgentMessage(role: .assistant, content: "", toolCalls: [write])],
            continuation: ContinuationState(reason: .userStopped, provider: "OpenAI", model: "test-model"),
            running: true,
            blank: false,
            planGateActive: true,
            inFlightToolCalls: [write],
            cwd: workspace.path
        )]

        host.pauseCurrentConversation("stopped-chat", reason: .applicationClosed)

        XCTAssertEqual(host.conversations.first?.continuation?.reason, .userStopped)
        XCTAssertTrue(host.conversations.first?.requiresToolOutcomeRecovery == true)
    }

    @MainActor
    func testRecoveryPreservesUserStopAndUncertainToolOutcome() throws {
        let write = InFlightToolCall(id: "write-1", name: "write_file", arguments: #"{"path":"a.txt"}"#)
        let conversation = Conversation(
            id: "stopped-chat",
            modelContext: [AgentMessage(role: .assistant, content: "", toolCalls: [write])],
            continuation: ContinuationState(reason: .userStopped, provider: "OpenAI", model: "test-model"),
            running: true,
            blank: false,
            planGateActive: true,
            inFlightToolCalls: [write]
        )

        let recovered = NativeAgentHost.recover(conversation)

        XCTAssertFalse(recovered.running)
        XCTAssertEqual(recovered.continuation?.reason, .userStopped)
        XCTAssertTrue(recovered.canContinue)
        XCTAssertTrue(recovered.requiresToolOutcomeRecovery)
        XCTAssertNotNil(recovered.modelContext.first {
            $0.role == AgentMessage.Role.tool
                && $0.toolCallID == "write-1"
                && $0.content.contains("result of this tool call was durably known")
        })
    }

    func testPlanMessagesAndPendingIDPersist() throws {
        let plan = ChatMessage(id: "plan-1", kind: .plan, text: "# Plan\n\n- Read the project")
        let conversation = Conversation(
            id: "plan-chat",
            messages: [plan],
            blank: false,
            pendingPlanMessageID: plan.id,
            cwd: "/tmp/project"
        )

        let data = try JSONEncoder().encode(conversation)
        let restored = try JSONDecoder().decode(Conversation.self, from: data)

        XCTAssertEqual(restored.pendingPlanMessageID, "plan-1")
        XCTAssertEqual(restored.messages.first?.kind, .plan)
        XCTAssertEqual(restored.messages.first?.text, plan.text)
    }

    func testReadOnlyDefinitionsConstantStillBackstopsSubagent() {
        XCTAssertEqual(WorkspaceTools.readOnlyDefinitions.map(\.name), ["list_files", "read_file", "grep_files", "glob"])
        XCTAssertTrue(WorkspaceTools.isReadOnly("list_files"))
        XCTAssertTrue(WorkspaceTools.isReadOnly("read_file"))
        XCTAssertFalse(WorkspaceTools.isReadOnly("write_file"))
        XCTAssertFalse(WorkspaceTools.isReadOnly("run_command"))
    }

    func testAskUserParsesQuestionsAndDropsBrokenOnes() {
        let arguments = """
        {"questions":[
          {"header":"Scope","question":"Which surface first?","options":["macOS","Windows","Linux","All three"]},
          {"question":"  ","options":["ignored"]},
          {"question":"Migration?","options":["  ","Manual","Automatic","","Skip","Extra"]}
        ]}
        """
        let questions = AskUserTool.parse(arguments)
        XCTAssertEqual(questions.count, 2)
        XCTAssertEqual(questions[0].header, "Scope")
        XCTAssertEqual(questions[0].options, ["macOS", "Windows", "Linux", "All three"])
        // Blank options fall out and the list is capped at four suggestions.
        XCTAssertEqual(questions[1].options, ["Manual", "Automatic", "Skip", "Extra"])
        XCTAssertFalse(questions[1].header.isEmpty)
        XCTAssertTrue(AskUserTool.parse("{}").isEmpty)
        XCTAssertTrue(AskUserTool.parse("not json").isEmpty)
    }

    func testAskUserTranscriptPairsAnswersWithQuestions() {
        let questions = AskUserTool.parse(
            "{\"questions\":[{\"question\":\"Target?\",\"options\":[\"A\",\"B\",\"C\"]}]}"
        )
        let transcript = AskUserTool.transcript(questions: questions, answers: ["  Custom answer "])
        XCTAssertEqual(transcript, "Q: Target?\nA: Custom answer")
    }

    func testAskUserFingerprintIgnoresCaseSpacingAndPunctuation() {
        XCTAssertEqual(
            AskUserTool.fingerprint("Which target first?"),
            AskUserTool.fingerprint("  which   TARGET  first!! ")
        )
        XCTAssertNotEqual(
            AskUserTool.fingerprint("Which target first?"),
            AskUserTool.fingerprint("Which target last?")
        )
        // Follow-up rounds exist, but the budget is finite.
        XCTAssertEqual(AskUserTool.maxRounds, 3)
    }

    func testAskUserToolIsAdvertisedWithOptions() {
        XCTAssertEqual(AskUserTool.definition.name, "ask_user")
        guard case let .object(parameters) = AskUserTool.definition.parameters,
              case let .object(properties) = parameters["properties"],
              case let .object(questions) = properties["questions"] else {
            return XCTFail("ask_user parameters are not an object")
        }
        XCTAssertEqual(questions["type"], .string("array"))
    }

    func testAgentMessageAndToolsEncodeExpectedShape() {
        let call = AgentToolCall(id: "call-1", name: "read_file", arguments: "{\"path\":\"README.md\"}")
        let message = AgentMessage(role: .assistant, content: "", toolCalls: [call])
        let object = message.jsonObject()
        XCTAssertEqual(object["role"] as? String, "assistant")
        let toolCalls = object["tool_calls"] as? [[String: Any]]
        XCTAssertEqual(toolCalls?.first?["id"] as? String, "call-1")
        XCTAssertEqual(WorkspaceTools.definitions.map(\.name), ["list_files", "read_file", "write_file", "remove_file", "grep_files", "run_command", "wait_command", "edit_file", "glob", "copy_generated_media", "inspect_generated_media", "ios_simulator", "android_emulator"])
    }

    func testGrepFilesMatchesLinesAndRespectsFilters() throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("DotsHarnessGrep-\(UUID().uuidString)", isDirectory: true)
        let nested = workspace.appendingPathComponent("node_modules", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try "let alpha = 1\nlet beta = 2\n".write(
            to: workspace.appendingPathComponent("a.swift"), atomically: true, encoding: .utf8
        )
        try "alpha here\n".write(
            to: workspace.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8
        )
        try "alpha ignored\n".write(
            to: nested.appendingPathComponent("c.swift"), atomically: true, encoding: .utf8
        )

        let all = WorkspaceTools.execute(
            AgentToolCall(id: "g1", name: "grep_files", arguments: "{\"pattern\":\"alpha\"}"),
            workspace: workspace
        , conversationID: "test")
        XCTAssertTrue(all.contains("a.swift:1:let alpha = 1"))
        XCTAssertTrue(all.contains("b.txt:1:alpha here"))
        XCTAssertFalse(all.contains("node_modules"))

        let filtered = WorkspaceTools.execute(
            AgentToolCall(
                id: "g2",
                name: "grep_files",
                arguments: "{\"pattern\":\"alpha\",\"extensions\":\"swift\"}"
            ),
            workspace: workspace
        , conversationID: "test")
        XCTAssertTrue(filtered.contains("a.swift"))
        XCTAssertFalse(filtered.contains("b.txt"))

        let missing = WorkspaceTools.execute(
            AgentToolCall(id: "g3", name: "grep_files", arguments: "{\"pattern\":\"gamma\"}"),
            workspace: workspace
        , conversationID: "test")
        XCTAssertEqual(missing, AppCopy.text("tool.noMatches"))
        try? FileManager.default.removeItem(at: workspace)
    }

    func testExploreToolRejectsAnEmptyTaskWithoutCallingAProvider() async {
        let workspace = FileManager.default.temporaryDirectory
        let refuse: ExploreTool.Complete = { _, _ in
            XCTFail("an empty task must never reach a provider")
            throw NativeAgentError("unreachable")
        }
        let missing = await ExploreTool.run(
            AgentToolCall(id: "e1", name: "explore", arguments: "{}"),
            complete: refuse,
            workspace: workspace
        )
        XCTAssertEqual(missing.answer, AppCopy.text("explore.missingTask"))
        let blank = await ExploreTool.run(
            AgentToolCall(id: "e2", name: "explore", arguments: "{\"task\":\"   \"}"),
            complete: refuse,
            workspace: workspace
        )
        XCTAssertEqual(blank.answer, AppCopy.text("explore.missingTask"))
    }

    func testExploreKeepsALongAnswerInOneRequest() async {
        // A retry to shorten the answer resends the whole transcript: the answer is
        // kept as it came, whatever its length, and costs no second request.
        let counter = CallCounter()
        let long = String(repeating: "c", count: ExploreTool.answerTarget * 3) + "\nStatus: answered"
        let complete: ExploreTool.Complete = { _, _ in
            _ = await counter.next()
            return AgentResponse(message: AgentMessage(role: .assistant, content: long))
        }
        let outcome = await ExploreTool.run(
            AgentToolCall(id: "e6", name: "explore", arguments: "{\"task\":\"map the router\"}"),
            complete: complete,
            workspace: FileManager.default.temporaryDirectory
        )
        let calls = await counter.value
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(outcome.answer, long, "no ceiling means no silent loss")
    }

    func testExploreWrapUpKeepsTheToolsSoTheCachedPrefixHolds() async {
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }
        let toolCounts = ToolCountRecorder()
        let looping: ExploreTool.Complete = { messages, tools in
            await toolCounts.add(tools.count)
            return messages.last?.content == AppCopy.text("explore.wrapUp")
                ? AgentResponse(message: AgentMessage(role: .assistant, content: "wrapped\nStatus: partial"))
                : AgentResponse(message: AgentMessage(
                    role: .assistant, content: "",
                    toolCalls: [AgentToolCall(id: "l", name: "list_files", arguments: "{\"path\":\".\"}")]
                ))
        }
        let outcome = await ExploreTool.run(
            AgentToolCall(id: "e9", name: "explore", arguments: "{\"task\":\"wrap \(UUID().uuidString)\"}"),
            complete: looping,
            workspace: empty
        )
        XCTAssertEqual(outcome.answer, "wrapped\nStatus: partial")
        let counts = await toolCounts.values
        XCTAssertEqual(Set(counts).count, 1, "every request, the wrap-up included, sends the same tools")
    }

    func testEachExploreRunHasItsOwnRouteForAllItsSteps() async {
        let scopes = ScopeRecorder()
        let complete: ExploreTool.Complete = { messages, _ in
            let route = SubagentRoute.current
            await scopes.add(route?.scope)
            if messages.contains(where: { $0.role == .tool }) {
                return AgentResponse(message: AgentMessage(role: .assistant, content: "done\nStatus: answered"))
            }
            route?.pin("account-a")
            return AgentResponse(message: AgentMessage(
                role: .assistant, content: "",
                toolCalls: [AgentToolCall(id: "r", name: "list_files", arguments: "{\"path\":\".\"}")]
            ))
        }
        for id in ["ra", "rb"] {
            _ = await ExploreTool.run(
                AgentToolCall(id: id, name: "explore", arguments: "{\"task\":\"route \(UUID().uuidString)\"}"),
                complete: complete,
                workspace: FileManager.default.temporaryDirectory
            )
        }
        let seen = await scopes.values
        XCTAssertEqual(seen.count, 4)
        XCTAssertFalse(seen.contains(nil))
        XCTAssertEqual(seen[0], seen[1], "one run keeps one route")
        XCTAssertNotEqual(seen[1], seen[2], "a second run never shares the first one's route")
        XCTAssertNil(SubagentRoute.current)
        let route = SubagentRoute()
        route.pin("account-a")
        route.pin(nil)
        XCTAssertEqual(route.accountID, "account-a", "a response without an account keeps the pin")
        XCTAssertNotEqual(route.comparisonScope("explore:x"), SubagentRoute().comparisonScope("explore:x"))
    }

    func testExploreKeepsFindingsWhenTheProviderFails() async {
        let counter = CallCounter()
        let complete: ExploreTool.Complete = { _, _ in
            if await counter.next() == 1 {
                return AgentResponse(message: AgentMessage(
                    role: .assistant,
                    content: "Found the loop in Sources/AgentBridge.swift:1338",
                    toolCalls: [AgentToolCall(id: "t1", name: "list_files", arguments: "{\"path\":\".\"}")]
                ))
            }
            throw NativeAgentError("quota exhausted", isLimit: true)
        }
        let task = "locate the tool loop \(UUID().uuidString)"
        let outcome = await ExploreTool.run(
            AgentToolCall(id: "e4", name: "explore", arguments: "{\"task\":\"\(task)\"}"),
            complete: complete,
            workspace: FileManager.default.temporaryDirectory
        )
        XCTAssertTrue(
            outcome.answer.contains("Sources/AgentBridge.swift:1338"),
            "a failed run must still hand back what it already found"
        )
        let stored = await ExploreMemo.shared.note(for: ExploreMemo.key(for: task))
        XCTAssertNotNil(stored, "the partial findings must survive for the next attempt")
    }

    func testExploreStepBudgetIsATargetNotACeiling() async {
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }
        // Fresh calls past the budget keep going; the checkpoint is sent once.
        let counter = CallCounter()
        let progressing: ExploreTool.Complete = { messages, _ in
            let n = await counter.next()
            if n > 20 {
                let checkpoints = messages.filter { $0.content == ExploreTool.checkpoint }.count
                return AgentResponse(message: AgentMessage(role: .assistant, content: "checkpoints \(checkpoints)\nStatus: answered"))
            }
            return AgentResponse(message: AgentMessage(
                role: .assistant, content: "",
                toolCalls: [AgentToolCall(id: "p\(n)", name: "list_files", arguments: "{\"path\":\"d\(n)\"}")]
            ))
        }
        let long = await ExploreTool.run(
            AgentToolCall(id: "e7", name: "explore", arguments: "{\"task\":\"long \(UUID().uuidString)\"}"),
            complete: progressing,
            workspace: empty
        )
        XCTAssertEqual(long.steps, 21)
        XCTAssertFalse(long.hitStepLimit)
        XCTAssertTrue(long.answer.hasPrefix("checkpoints 1"))

        // Past the budget, a step that only repeats earlier calls ends the run.
        let looping: ExploreTool.Complete = { messages, _ in
            messages.last?.content == AppCopy.text("explore.wrapUp")
                ? AgentResponse(message: AgentMessage(role: .assistant, content: "wrapped\nStatus: partial"))
                : AgentResponse(message: AgentMessage(
                    role: .assistant, content: "",
                    toolCalls: [AgentToolCall(id: "l", name: "list_files", arguments: "{\"path\":\".\"}")]
                ))
        }
        let stuck = await ExploreTool.run(
            AgentToolCall(id: "e8", name: "explore", arguments: "{\"task\":\"loop \(UUID().uuidString)\"}"),
            complete: looping,
            workspace: empty
        )
        XCTAssertEqual(stuck.steps, ExploreTool.stepBudget)
        XCTAssertTrue(stuck.hitStepLimit)
    }

    func testExploreOutcomeSurfacesEveryReasonToDistrustIt() {
        let partial = ExploreTool.Outcome(
            answer: "## Findings\n- Sources/A.swift:4 the loop\n\nStatus: partial",
            readPaths: ["Sources/A.swift"],
            steps: 4,
            hitStepLimit: true,
            answered: false,
            searches: 1
        )
        let result = partial.toolResult
        XCTAssertTrue(result.contains(AppCopy.text("explore.partialStatus")))
        XCTAssertTrue(result.contains(AppCopy.text("explore.stepLimitNote")))
        XCTAssertTrue(result.contains("Sources/A.swift"))

        let unread = ExploreTool.Outcome(
            answer: "it is in the router", readPaths: [], steps: 2, hitStepLimit: false, answered: true, searches: 0
        )
        XCTAssertTrue(unread.unverified, "findings without a single read or search are not verified")
        XCTAssertTrue(unread.toolResult.contains(AppCopy.text("explore.unverified")))

        let clean = ExploreTool.Outcome(
            answer: "found it", readPaths: [], steps: 0, hitStepLimit: false, answered: true, searches: 0
        )
        XCTAssertEqual(clean.toolResult, "found it")

        func outcome(searches: Int, files: Int) -> ExploreTool.Outcome {
            .init(answer: "Status: answered", readPaths: (0..<files).map { "f\($0)" }, steps: 3,
                  hitStepLimit: false, answered: true, searches: searches)
        }
        XCTAssertTrue(outcome(searches: 1, files: 2).toolResult.contains(ExploreTool.Outcome.unneededNote),
                      "a lookup the caller could have done itself is called out")
        XCTAssertFalse(outcome(searches: 4, files: 6).toolResult.contains(ExploreTool.Outcome.unneededNote))
        XCTAssertFalse(outcome(searches: 0, files: 3).unneeded)
    }

    func testExploreStatusLineDecidesWhetherTheAnswerIsTrusted() {
        XCTAssertTrue(ExploreTool.answeredFully("## Findings\n- a\n\nStatus: answered"))
        XCTAssertFalse(ExploreTool.answeredFully("## Findings\n- a\n\nStatus: partial"))
        XCTAssertFalse(ExploreTool.answeredFully("## Findings\n- a"), "a missing status line is not a claim")
        XCTAssertTrue(ExploreTool.answeredFully("Status: partial\nlater\nStatus: answered"), "the last line wins")
    }

    /// What the subagent reads stays in its own transcript: the caller's context
    /// grows by the findings and the paths, never by the file contents.
    func testExploreReturnsFindingsNotWhatItRead() async throws {
        let workspace = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let body = (1...200).map { "line \($0) RAW-FILE-CONTENT" }.joined(separator: "\n")
        try body.write(to: workspace.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)

        let counter = CallCounter()
        let transcripts = Transcripts()
        let findings = "## Findings\n- a.txt:1 holds the marker\n\n## Unresolved\nNone\n\nStatus: answered"
        let complete: ExploreTool.Complete = { messages, _ in
            await transcripts.add(messages)
            func call(_ id: String, _ name: String, _ arguments: [String: String]) -> AgentResponse {
                let encoded = String(decoding: try! JSONSerialization.data(withJSONObject: arguments), as: UTF8.self)
                return AgentResponse(message: AgentMessage(role: .assistant, content: "",
                    toolCalls: [AgentToolCall(id: id, name: name, arguments: encoded)]))
            }
            switch await counter.next() {
            // The read-only tools go out with their schemas: no discover round.
            case 1: return call("r1", "read_file", ["path": "a.txt"])
            default: return AgentResponse(message: AgentMessage(role: .assistant, content: findings))
            }
        }
        let outcome = await ExploreTool.run(
            AgentToolCall(id: "e9", name: "explore", arguments: #"{"task":"where is the marker \#(UUID().uuidString)"}"#),
            complete: complete,
            workspace: workspace
        )
        let seen = await transcripts.all
        XCTAssertEqual(seen.first?.map(\.role), [.system, .user], "the subagent starts from its task alone")
        XCTAssertTrue(seen.last?.contains { $0.role == .tool && $0.content.contains("RAW-FILE-CONTENT") } == true,
                      "the file was read into the subagent's own transcript")
        XCTAssertEqual(outcome.readPaths, ["a.txt"])
        XCTAssertFalse(outcome.toolResult.contains("RAW-FILE-CONTENT"), "file contents must not reach the caller")
        XCTAssertLessThan(outcome.toolResult.count, 400)
    }

    private actor Transcripts {
        private(set) var all: [[AgentMessage]] = []
        func add(_ messages: [AgentMessage]) { all.append(messages) }
    }

    @MainActor
    func testExploreToolOfferedOnlyWithWorkspace() throws {
        let workspace = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let host = NativeAgentHost(paths: temporaryPaths(), endpoint: AgentEndpointController())
        host.setWorkspace(workspace.path)
        let tools = host.agentTools(workspace: workspace).defs.map(\.name)
        XCTAssertTrue(tools.contains("explore"), "explore tool must be available in a project with an open workspace")

        let noWorkspaceTools = host.agentTools(workspace: nil).defs.map(\.name)
        XCTAssertFalse(noWorkspaceTools.contains("explore"), "explore tool must not be offered without a workspace")
    }

    @MainActor
    func testExploreToolFollowsTheSubagentSwitch() throws {
        let workspace = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let router = RouterController(baseURL: "http://127.0.0.1:1")
        let host = NativeAgentHost(paths: temporaryPaths(), router: router)
        func offered() -> Bool { host.agentTools(workspace: workspace).defs.contains { $0.name == "explore" } }

        XCTAssertTrue(offered(), "an unset preference offers explore outside Economy")
        router.usageMode = .economy
        XCTAssertFalse(offered(), "an unset preference withholds explore in Economy")
        router.subagentsPreference = true
        XCTAssertTrue(offered(), "an explicit on outlives Economy")
        router.usageMode = .standard
        router.subagentsPreference = false
        XCTAssertFalse(offered(), "an explicit off outlives standard mode")
        // The map answers the layout; the prompt must not send the run sweeping for it.
        XCTAssertFalse(ProjectKnowledge.guidance(missing: ["architecture"]).contains("explore"))
        XCTAssertTrue(ProjectKnowledge.guidance(missing: ["architecture"]).contains("from the project map"))
    }

    func testPrefetchExploreCapsToMaxPerTurnAndRejectsExcess() async {
        let workspace = FileManager.default.temporaryDirectory
        let calls = (1...5).map { index in
            AgentToolCall(id: "call-\(index)", name: "explore", arguments: "{\"task\":\"find task \(index)\"}")
        }
        let complete: ExploreTool.Complete = { _, _ in
            AgentResponse(message: AgentMessage(role: .assistant, content: "## Findings\n- result\n\nStatus: answered"))
        }
        let outcomes = await NativeAgentHost.prefetchExplore(calls, complete: complete, workspace: workspace)
        XCTAssertEqual(outcomes.count, 5)
        for index in 1...ExploreTool.maxPerTurn {
            let outcome = outcomes["call-\(index)"]
            XCTAssertNotNil(outcome)
            XCTAssertTrue(outcome?.answered == true, "call-\(index) should have executed")
        }
        for index in (ExploreTool.maxPerTurn + 1)...5 {
            let outcome = outcomes["call-\(index)"]
            XCTAssertNotNil(outcome)
            XCTAssertFalse(outcome?.answered == true)
            XCTAssertTrue(outcome?.answer.contains("Tool error: maximum of \(ExploreTool.maxPerTurn) explore subagents per turn exceeded") == true)
        }
    }

    func testProviderLimitReadsWhenItWillServeAgain() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        func response(_ header: String, _ value: String) -> HTTPURLResponse? {
            HTTPURLResponse(
                url: URL(string: "https://example.invalid")!,
                statusCode: 429,
                httpVersion: nil,
                headerFields: [header: value]
            )
        }
        XCTAssertEqual(
            NativeAgentError.retryAt(from: response("Retry-After", "60"), now: now),
            now.addingTimeInterval(60)
        )
        XCTAssertEqual(
            NativeAgentError.retryAt(from: response("x-ratelimit-reset", "1700000600"), now: now),
            Date(timeIntervalSince1970: 1_700_000_600)
        )
        XCTAssertNotNil(
            NativeAgentError.retryAt(
                from: response("anthropic-ratelimit-unified-reset", "2033-11-14T22:16:40Z"),
                now: now
            )
        )
        XCTAssertNil(NativeAgentError.retryAt(from: response("Retry-After", "soon"), now: now))
        XCTAssertNil(
            NativeAgentError.retryAt(from: response("x-ratelimit-reset", "1600000000"), now: now),
            "a reset already in the past is no reset at all"
        )
        XCTAssertNil(NativeAgentError.retryAt(from: nil, now: now))
    }

    func testUpdatePlanRendersStepsAndRejectsBadStatus() {
        let good = PlanStepsTool.execute(AgentToolCall(
            id: "p1",
            name: "update_plan",
            arguments: "{\"steps\":[{\"title\":\"Read the loop\",\"status\":\"done\"},{\"title\":\"Add the tool\",\"status\":\"in_progress\"}]}"
        ))
        XCTAssertTrue(good.contains("☑ Read the loop"))
        XCTAssertTrue(good.contains("▸ Add the tool"))

        let bad = PlanStepsTool.execute(AgentToolCall(
            id: "p2",
            name: "update_plan",
            arguments: "{\"steps\":[{\"title\":\"x\",\"status\":\"maybe\"}]}"
        ))
        XCTAssertEqual(bad, AppCopy.text("plan.stepsInvalid"))
        XCTAssertEqual(
            PlanStepsTool.execute(AgentToolCall(id: "p3", name: "update_plan", arguments: "{}")),
            AppCopy.text("plan.stepsInvalid")
        )
    }

    func testWorkspaceToolsCannotEscapeWorkspace() throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("DotsHarnessTools-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let call = AgentToolCall(id: "call", name: "read_file", arguments: "{\"path\":\"../outside.txt\"}")
        let result = WorkspaceTools.execute(call, workspace: workspace, conversationID: "test")
        XCTAssertTrue(result.contains("outside the workspace"))
        let memoryCall = AgentToolCall(id: "memory", name: "read_file", arguments: "{\"path\":\".mem/state.json\"}")
        let memoryResult = WorkspaceTools.execute(memoryCall, workspace: workspace, conversationID: "test")
        XCTAssertFalse(memoryResult.contains(".mem"))
        XCTAssertFalse(memoryResult.contains("host-managed"))
        try? FileManager.default.removeItem(at: workspace)
    }

    func testGeneratedMediaSaveUsesContentHashAndSniffedExtension() throws {
        let paths = temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x01])
        let a = try MediaGenerationClient.save(jpeg, kind: .image, paths: paths)
        let b = try MediaGenerationClient.save(jpeg, kind: .image, paths: paths)
        XCTAssertEqual(a.path, b.path)
        XCTAssertTrue(a.path.hasSuffix(".jpg"))
        XCTAssertEqual(a.mimeType, "image/jpeg")
        XCTAssertTrue(a.path.hasPrefix(paths.root.appendingPathComponent("generated-media").path))
        XCTAssertThrowsError(try MediaGenerationClient.save(Data([1, 2, 3]), kind: .image, paths: paths))
    }

    func testGeneratedMediaCanBeCopiedIntoWorkspaceAndRejectsUnknownSource() throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("DotsHarnessMedia-\(UUID().uuidString)", isDirectory: true)
        let support = workspace.appendingPathComponent("support", isDirectory: true)
        let project = workspace.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let source = support.appendingPathComponent("generated.png")
        let destination = project.appendingPathComponent("assets/background.png")
        let bytes = Data([0x89, 0x50, 0x4E, 0x47, 0x01, 0x02, 0x03])
        try bytes.write(to: source)

        let copied = WorkspaceTools.copyGeneratedMedia(
            sourcePath: source.path,
            destinationPath: "assets/background.png",
            allowedSourcePaths: [source.path],
            workspace: project
        )
        XCTAssertTrue(copied.contains("assets/background.png"))
        XCTAssertEqual(try Data(contentsOf: destination), bytes)

        let rejected = WorkspaceTools.copyGeneratedMedia(
            sourcePath: source.path,
            destinationPath: "assets/second.png",
            allowedSourcePaths: [],
            workspace: project
        )
        XCTAssertTrue(rejected.contains("not available"))
    }

    func testSafeRemovalRequiresNoLiveReferenceAndProtectsState() throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("DotsHarnessCleanup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        try Data("struct OldArchitecture {}".utf8).write(to: workspace.appendingPathComponent("old.swift"))
        var result = WorkspaceTools.execute(
            AgentToolCall(id: "remove", name: "remove_file", arguments: "{\"path\":\"old.swift\",\"reason\":\"Replaced by the new architecture.\",\"referenceTerms\":\"OldArchitecture\"}"),
            workspace: workspace
        , conversationID: "test")
        XCTAssertTrue(result.hasPrefix("[cleanup:verified]"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("old.swift").path))

        try Data("struct OldTwo {}".utf8).write(to: workspace.appendingPathComponent("old2.swift"))
        try Data("let value = OldTwo()".utf8).write(to: workspace.appendingPathComponent("caller.swift"))
        result = WorkspaceTools.execute(
            AgentToolCall(id: "keep", name: "remove_file", arguments: "{\"path\":\"old2.swift\",\"reason\":\"Old flow removed.\",\"referenceTerms\":\"OldTwo\"}"),
            workspace: workspace
        , conversationID: "test")
        XCTAssertTrue(result.hasPrefix("[cleanup:preserved]"))

        try Data("state".utf8).write(to: workspace.appendingPathComponent("state.sqlite"))
        result = WorkspaceTools.execute(
            AgentToolCall(id: "state", name: "remove_file", arguments: "{\"path\":\"state.sqlite\",\"reason\":\"cleanup\",\"referenceTerms\":\"state\"}"),
            workspace: workspace
        , conversationID: "test")
        XCTAssertTrue(result.hasPrefix("[cleanup:preserved]"))
    }

    func testRunCommandDoesNotDeadlockOnLargeOutput() throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("DotsHarnessTools-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        // ~300KB, far past the ~64KB pipe buffer that used to wedge the child.
        let call = AgentToolCall(id: "big", name: "run_command", arguments: "{\"command\":\"for i in $(seq 1 30000); do echo 0123456789; done\"}")
        let result = WorkspaceTools.execute(call, workspace: workspace, conversationID: "test")
        XCTAssertFalse(result.contains("timed out"))
        XCTAssertTrue(result.contains("0123456789"))
    }

    func testSleepPollingIsRefused() {
        XCTAssertTrue(WorkspaceTools.isSleepPoll("sleep 30; if kill -0 18546; then echo RUNNING; fi"))
        XCTAssertTrue(WorkspaceTools.isSleepPoll("  sleep 10 && tail -n 12 test.log"))
        XCTAssertFalse(WorkspaceTools.isSleepPoll("swift test && sleep 1"))
        XCTAssertFalse(WorkspaceTools.isSleepPoll("sleepwatcher --help"))
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
        let result = WorkspaceTools.execute(call, workspace: workspace, conversationID: "test")
        XCTAssertTrue(result.contains("outside the workspace"))
    }

    func testNativeAgentConfigurationIsIndependentOfSessionIDs() {
        let configuration = AgentConfiguration(
            baseURL: "https://api.openai.com/v1",
            model: "gpt-5.6-luna",
            provider: "GPT"
        )
        XCTAssertEqual(configuration.model, "gpt-5.6-luna")
        let connection = AgentConnection(
            endpoint: URL(string: configuration.baseURL)!,
            provider: configuration.provider,
            model: configuration.model
        )
        XCTAssertEqual(connection.provider, "GPT")
        XCTAssertEqual(connection.endpoint.absoluteString, configuration.baseURL)
    }

    @MainActor
    func testSystemPromptMovesWorkspaceBoundariesOutOfStablePolicyPrefix() throws {
        let paths = temporaryPaths()
        let workspace = paths.root.appendingPathComponent("cache-project", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let host = NativeAgentHost(
            paths: paths,
            endpoint: AgentEndpointController(baseURL: "http://127.0.0.1:1", modelID: "test-model")
        )

        let sections = host.systemPromptSections(workspace: workspace)
        let core = try XCTUnwrap(sections.first(where: { $0.tag == "core_policy" }))
        let runtime = try XCTUnwrap(sections.first(where: { $0.tag == "runtime_context" }))
        XCTAssertFalse(core.text.contains(workspace.path))
        XCTAssertTrue(runtime.text.contains(workspace.path))
        XCTAssertTrue(core.text.contains("See <runtime_context>"))
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
                model: "gpt-5.6-luna",
                apiKey: "session-token",
                provider: "GPT",
                api: RouterAPIKind.chatGPT.rawValue,
                sessionAccountID: "account-1",
                specID: "gpt"
            ),
            session: URLSession(configuration: configuration)
        )

        let response = try await client.complete(messages: [AgentMessage(role: .user, content: "hello")])

        XCTAssertEqual(response.message.content, "ready")
        XCTAssertEqual(MockURLProtocol.lastRequest?.url?.path, "/backend-api/codex/responses")
        XCTAssertEqual(MockURLProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer session-token")
        XCTAssertEqual(MockURLProtocol.lastRequest?.value(forHTTPHeaderField: "ChatGPT-Account-ID"), "account-1")
        XCTAssertEqual(MockURLProtocol.lastRequest?.value(forHTTPHeaderField: "Accept"), "text/event-stream")
        XCTAssertNil(MockURLProtocol.lastRequest?.value(forHTTPHeaderField: "OpenAI-Beta"))
        XCTAssertNotNil(MockURLProtocol.lastRequest?.value(forHTTPHeaderField: "session-id"))
        XCTAssertNotNil(MockURLProtocol.lastRequest?.value(forHTTPHeaderField: "thread-id"))
        XCTAssertNotNil(MockURLProtocol.lastRequest?.value(forHTTPHeaderField: "x-client-request-id"))

        // Cache routing: turns of one conversation share the session id.
        _ = try await client.complete(
            messages: [AgentMessage(role: .user, content: "hello")],
            cachePolicy: AgentCachePolicy(promptCacheKey: "herness:area-v1:chat:abc")
        )
        XCTAssertEqual(MockURLProtocol.lastRequest?.value(forHTTPHeaderField: "session-id"), "herness:area-v1:chat:abc")
        XCTAssertEqual(MockURLProtocol.lastRequest?.value(forHTTPHeaderField: "thread-id"), "herness:area-v1:chat:abc")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(MockURLProtocol.lastBody)) as? [String: Any])
        XCTAssertNil(body["messages"])
        XCTAssertEqual(body["store"] as? Bool, false)
        XCTAssertEqual(body["stream"] as? Bool, true)
    }

    func testChatGPTImageGenerationUsesBuiltInResponsesTool() async throws {
        let pngBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let b64 = pngBytes.base64EncodedString()
        MockURLProtocol.response = Data("""
        data: {"type":"response.completed","response":{"output":[{"type":"image_generation_call","result":"\(b64)"}]}}

        data: [DONE]
        """.utf8)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let paths = temporaryPaths()
        let client = NativeAgentClient(
            configuration: AgentConfiguration(
                baseURL: "http://example.test/backend-api/codex",
                model: "gpt-5.6-luna",
                apiKey: "session-token",
                provider: "GPT",
                api: RouterAPIKind.chatGPT.rawValue,
                sessionAccountID: "account-1",
                specID: "gpt"
            ),
            session: URLSession(configuration: configuration)
        )

        let media = try await client.generateImage(prompt: "a red fox", paths: paths)

        XCTAssertEqual(media.kind, .image)
        XCTAssertEqual(try Data(contentsOf: media.url), pngBytes)
        XCTAssertEqual(MockURLProtocol.lastRequest?.url?.path, "/backend-api/codex/responses")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(MockURLProtocol.lastBody)) as? [String: Any])
        let tools = try XCTUnwrap(body["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.first?["type"] as? String, "image_generation")
        XCTAssertEqual(body["model"] as? String, "gpt-5.6-luna")
    }

    func testDirectImageAdapterParsesFallbackOutput() throws {
        MockURLProtocol.response = Data(#"{"data":[{"b64_json":"AQID"}]}"#.utf8)
        let adapter = DirectImageAPIAdapter()
        let route = ProviderImageRoute(
            accountID: "account",
            providerID: "openai",
            baseURL: "http://example.test/v1",
            api: RouterAPIKind.openAICompatible.rawValue,
            model: "gpt-5.6-luna"
        )
        let request = try adapter.prepareImageRequest(prompt: "a red fox", model: route.model, route: route)
        XCTAssertEqual(request.url.path, "/v1/images/generations")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "gpt-image-1.5")
        XCTAssertEqual(body["prompt"] as? String, "a red fox")
        let result = adapter.parseImageResponse(
            data: MockURLProtocol.response,
            status: 200,
            headers: [:]
        )
        guard case .generated(let output) = result else {
            return XCTFail("fallback adapter should parse b64_json output")
        }
        XCTAssertEqual(output.data, Data([1, 2, 3]))
    }

    func testSpeechGenerationUsesNaturalVoiceInstructionsAndStoresOutput() async throws {
        MockURLProtocol.response = Data([1, 2, 3])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let paths = temporaryPaths()
        let client = URLSession(configuration: configuration)
        let media = try await MediaGenerationClient.generate(
            kind: .audio,
            prompt: "Merhaba, bugün nasılsın?",
            configuration: AgentConfiguration(
                baseURL: "http://example.test/v1",
                model: "gpt-5.6-luna",
                apiKey: "key",
                specID: "openai"
            ),
            provider: try XCTUnwrap(ProviderRegistry.shared.spec("openai")?.media?.audio),
            paths: paths,
            session: client
        )

        XCTAssertEqual(media.kind, .audio)
        XCTAssertEqual(try Data(contentsOf: media.url), Data([1, 2, 3]))
        XCTAssertEqual(MockURLProtocol.lastRequest?.url?.path, "/v1/audio/speech")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(MockURLProtocol.lastBody)) as? [String: Any])
        XCTAssertEqual(body["voice"] as? String, "marin")
        XCTAssertTrue((body["instructions"] as? String)?.contains("natural") == true)
    }

    func testMusicRequestFollowsTheEndpointFormat() async throws {
        MockURLProtocol.response = Data(#"{"data":[{"b64_json":"AQID"}]}"#.utf8)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let client = URLSession(configuration: configuration)
        let paths = temporaryPaths()
        let drums = MusicStemRequest(instrument: "drums", bpm: 100, key: "A minor")
        func send(_ base: String, _ spec: ProviderMediaSpec, _ stem: MusicStemRequest) async throws -> [String: Any] {
            let media = try await MediaGenerationClient.generate(
                kind: .music, prompt: "funk groove",
                configuration: AgentConfiguration(baseURL: base, model: spec.model, apiKey: "key"),
                provider: spec, paths: paths, session: client, seconds: 2, stem: stem
            )
            XCTAssertEqual(try Data(contentsOf: media.url), Data([1, 2, 3]))
            return try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(MockURLProtocol.lastBody)) as? [String: Any])
        }

        var body = try await send("http://example.test/v1", ProviderMediaSpec(model: "musicgen-small"), drums)
        XCTAssertEqual(MockURLProtocol.lastRequest?.url?.path, "/v1/audio/generations")
        XCTAssertEqual(MockURLProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer key")
        XCTAssertEqual(body["model"] as? String, "musicgen-small")
        XCTAssertEqual(body["duration"] as? Int, 2)
        XCTAssertEqual(body["instrument"] as? String, "drums")
        XCTAssertEqual(body["bpm"] as? Int, 100)
        XCTAssertNil(body["lyrics"])

        let eleven = ProviderMediaSpec(model: "music_v1", format: "elevenlabs")
        body = try await send("https://api.elevenlabs.io/v1", eleven, drums)
        XCTAssertEqual(MockURLProtocol.lastRequest?.url?.path, "/v1/music")
        XCTAssertEqual(MockURLProtocol.lastRequest?.value(forHTTPHeaderField: "xi-api-key"), "key")
        XCTAssertNil(MockURLProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(body["model_id"] as? String, "music_v1")
        XCTAssertEqual(body["music_length_ms"] as? Int, 3000)
        XCTAssertEqual(body["force_instrumental"] as? Bool, true)
        XCTAssertNil(body["model"])

        body = try await send(
            "https://api.elevenlabs.io/v1", eleven,
            MusicStemRequest(instrument: "vocals", bpm: 100, key: "A minor", lyrics: "la")
        )
        XCTAssertNil(body["force_instrumental"])
    }

    /// Against a running `tools/music_server.py`; skipped when none answers on its default port.
    func testMusicServerRendersAStemAndRefusesVocals() async throws {
        let base = MusicEndpoint.Format.standard.defaultBaseURL
        let models = await MusicStudioAI.models(baseURL: base, apiKey: nil)
        guard let model = models.first else { throw XCTSkip("no music server at \(base)") }
        func render(_ stem: MusicStemRequest) async throws -> ChatMedia {
            try await MediaGenerationClient.generate(
                kind: .music, prompt: "Isolated \(stem.instrument) stem only. 100 BPM, A minor.",
                configuration: AgentConfiguration(baseURL: base, model: model),
                provider: ProviderMediaSpec(model: model), paths: temporaryPaths(), seconds: 2, stem: stem
            )
        }

        let media = try await render(MusicStemRequest(instrument: "drums", bpm: 100, key: "A minor"))
        XCTAssertEqual(media.url.pathExtension, "wav")
        XCTAssertEqual(media.mimeType, "audio/wav")
        // Two seconds of 16-bit mono at 32 kHz, plus the header.
        XCTAssertEqual(try Data(contentsOf: media.url).count, 2 * 32_000 * 2 + 44)

        do {
            _ = try await render(MusicStemRequest(instrument: "vocals", bpm: 100, key: "A minor", lyrics: "la la"))
            XCTFail("a model that cannot sing must refuse lyrics")
        } catch let error as NativeAgentError {
            XCTAssertTrue(error.message.contains("cannot sing"), error.message)
        }
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
        XCTAssertFalse(FileManager.default.fileExists(atPath: memoryRoot.appendingPathComponent("state.json").path), "the projection is derived, never committed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: memoryRoot.appendingPathComponent("map.md").path))
        XCTAssertTrue(memory.snapshot(for: "Package.swift").text.contains("Project map"))

        let second = WorkspaceMemory(paths: paths)
        second.setWorkspace(workspace)
        XCTAssertEqual(second.projectID, memory.projectID)
    }

    @MainActor
    func testExplicitLanguagePreferenceIsKeptInTheProfileNotTheRepository() async throws {
        let paths = temporaryPaths()
        let workspace = paths.root.appendingPathComponent("preference-project", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let memory = WorkspaceMemory(paths: paths)
        memory.setWorkspace(workspace)
        let runID = UUID()
        memory.prepareForPrompt(prompt: "Artık İngilizce cevap ver", runID: runID, provider: "Direct", model: "test/model")
        memory.finishTask(runID: runID, success: true, finalText: "Done")
        for _ in 0..<3 { await Task.yield() }
        XCTAssertEqual(memory.profile.preferences()["language"], "English")
        // The person's language is theirs in every project; nothing of it goes into .mem.
        let repository = workspace.appendingPathComponent(".mem", isDirectory: true)
        let leaked = (FileManager.default.enumerator(at: repository, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
            .filter { (try? String(contentsOf: $0, encoding: .utf8))?.contains("English") == true }
        XCTAssertTrue(leaked.isEmpty, "a preference reached the repository: \(leaked)")
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
        // Only a run that actually did work leaves a task note.
        memory.recordTool(
            runID: runID,
            call: AgentToolCall(id: "1", name: "read_file", arguments: #"{"path":"README.md"}"#),
            result: "ok",
            beforeFile: nil,
            beforeGit: [],
            afterGit: [],
            workspace: workspace
        )
        memory.finishTask(runID: runID, success: true, finalText: "done")

        // The repository keeps the project's notes; the task note is the person's and lives in their layer.
        let memoryRoot = workspace.appendingPathComponent(".mem")
        let taskNoteURL = try XCTUnwrap(memory.userMemoryDirectory).appendingPathComponent("tasks/\(runID.uuidString).md")
        for relative in ["map.md", "index.md"] {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: memoryRoot.appendingPathComponent(relative).path),
                "expected .mem/\(relative) to be written"
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: memoryRoot.appendingPathComponent("preferences.md").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: taskNoteURL.path), "expected the task note in the user layer")

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
        // The repository's index names the project's notes only, never the person's tasks.
        let indexBody = try String(contentsOf: memoryRoot.appendingPathComponent("index.md"), encoding: .utf8)
        XCTAssertFalse(indexBody.contains("task-"))
        XCTAssertTrue(indexBody.contains("[[map]]"))

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
        // Only a run that actually did work leaves a task note.
        memory.recordTool(
            runID: runID,
            call: AgentToolCall(id: "1", name: "read_file", arguments: #"{"path":"README.md"}"#),
            result: "ok",
            beforeFile: nil,
            beforeGit: [],
            afterGit: [],
            workspace: workspace
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

    @MainActor
    func testConversationLifecycleIsRecordedInMemory() throws {
        let paths = temporaryPaths()
        let workspace = paths.root.appendingPathComponent("conversation-lifecycle-project", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        let memory = WorkspaceMemory(paths: paths)
        memory.setWorkspace(workspace)
        memory.prepareForPrompt(prompt: "track this chat", runID: UUID(), provider: "Direct", model: "test/model")
        memory.recordConversationLifecycle(
            conversationID: "chat-1",
            title: "Fix login flow",
            state: .archived
        )

        let archived = try XCTUnwrap(memory.vault().notes.first { $0.kind == "conversation" })
        XCTAssertTrue(archived.body.contains("hidden from active conversations"))
        // The vault keeps the lifecycle; the prompt no longer carries the list.
        XCTAssertFalse(memory.snapshot(for: "next").text.contains("archived"))

        memory.recordConversationLifecycle(
            conversationID: "chat-1",
            title: "Fix login flow",
            state: .deleted
        )
        let deleted = try XCTUnwrap(memory.vault().notes.first { $0.kind == "conversation" })
        XCTAssertTrue(deleted.body.contains("deleted"))

        let reloaded = WorkspaceMemory(paths: paths)
        reloaded.setWorkspace(workspace)
        XCTAssertTrue(reloaded.vault().notes.contains { $0.kind == "conversation" && $0.body.contains("deleted") })
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

    func testAnthropicBodyPlacesCacheBreakpointsOnPrefix() {
        let client = NativeAgentClient(configuration: AgentConfiguration(
            baseURL: "https://example.test", model: "claude", apiKey: "k",
            api: RouterAPIKind.anthropic.rawValue
        ))
        let body = client.makeBody(
            messages: [
                AgentMessage(role: .system, content: "core policy"),
                AgentMessage(role: .user, content: "hello"),
            ],
            tools: [AgentToolDefinition(name: "read_file", description: "d", parameters: .object(["type": .string("object")]))],
            cachePolicy: AgentCachePolicy(promptCacheKey: "herness:stable")
        )
        let system = try? XCTUnwrap(body["system"] as? [[String: Any]])
        XCTAssertEqual((system?.last?["cache_control"] as? [String: String])?["type"], "ephemeral")
        let tools = try? XCTUnwrap(body["tools"] as? [[String: Any]])
        XCTAssertEqual((tools?.last?["cache_control"] as? [String: String])?["type"], "ephemeral")
        let messages = try? XCTUnwrap(body["messages"] as? [[String: Any]])
        let lastContent = messages?.last?["content"] as? [[String: Any]]
        XCTAssertEqual((lastContent?.last?["cache_control"] as? [String: String])?["type"], "ephemeral")
        // Anthropic has no `prompt_cache_key`; the key must not leak into the body.
        XCTAssertNil(body["prompt_cache_key"])
    }

    func testAnthropicUsageParsesCacheReadAndCreationTokens() async throws {
        MockURLProtocol.response = Data("""
        {"type":"message","role":"assistant","content":[{"type":"text","text":"ok"}],"usage":{"input_tokens":12,"output_tokens":3,"cache_read_input_tokens":9,"cache_creation_input_tokens":4}}
        """.utf8)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let client = NativeAgentClient(
            configuration: AgentConfiguration(
                baseURL: "http://example.test", model: "claude", apiKey: "k",
                api: RouterAPIKind.anthropic.rawValue
            ),
            session: URLSession(configuration: configuration)
        )
        let response = try await client.complete(messages: [AgentMessage(role: .user, content: "hi")])
        XCTAssertEqual(response.usage?.cachedTokens, 9)
        XCTAssertEqual(response.usage?.cacheWriteTokens, 4)
    }

    func testResponsesBodyCarriesPromptCacheKey() {
        let client = NativeAgentClient(configuration: AgentConfiguration(
            baseURL: "https://chatgpt.com/backend-api/codex", model: "gpt-5.6", apiKey: "k",
            api: RouterAPIKind.chatGPT.rawValue
        ))
        let body = client.makeBody(
            messages: [AgentMessage(role: .user, content: "hi")],
            tools: [],
            cachePolicy: AgentCachePolicy(promptCacheKey: "herness:stable")
        )
        XCTAssertEqual(body["prompt_cache_key"] as? String, "herness:stable")
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

    @MainActor
    private func waitForApproval(_ host: NativeAgentHost) async throws -> PendingApproval {
        for _ in 0..<100 {
            if let approval = host.pendingApproval { return approval }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw NSError(domain: "AgentBridgeTests", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Timed out waiting for approval"
        ])
    }

    private func installApprovalResponses() {
        ApprovalURLProtocol.responses = DeferredToolScript.replies(
            id: "write-1", name: "write_file", arguments: #"{"path":"created.txt","content":"changed"}"#
        )
        URLProtocol.registerClass(ApprovalURLProtocol.self)
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

private final class ApprovalURLProtocol: URLProtocol {
    nonisolated(unsafe) static var responses: [Data] = []
    nonisolated(unsafe) static var failure: URLError.Code?
    private static let lock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "approval.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if let failure = Self.failure {
            client?.urlProtocol(self, didFailWithError: URLError(failure))
            return
        }
        Self.lock.lock()
        let data = Self.responses.isEmpty
            ? Data(#"{"choices":[{"message":{"role":"assistant","content":"done"}}]}"#.utf8)
            : Self.responses.removeFirst()
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
        failure = nil
        lock.unlock()
    }
}

/// Counts provider calls across concurrency domains for the exploration tests.
actor CallCounter {
    private var count = 0
    var value: Int { count }
    func next() -> Int {
        count += 1
        return count
    }
}

private actor ToolCountRecorder {
    private(set) var values: [Int] = []
    func add(_ count: Int) { values.append(count) }
}

private actor ScopeRecorder {
    private(set) var values: [String?] = []
    func add(_ scope: String?) { values.append(scope) }
}

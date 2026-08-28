// Copyright (c) 2026 DOTS

import XCTest
import Foundation
import HarnessPluginKit
import PluginRuntime
@testable import DotsHarnessCore

final class AgentBridgeTests: XCTestCase {
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

        model.bridge.start(workspacePath: workspace.path)
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

    @MainActor
    func testProjectlessConversationsAreRecentAndPersistedSeparately() throws {
        let paths = temporaryPaths()
        let workspace = paths.root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        let store = ConversationStore(paths: paths)
        store.save([
            Conversation(id: "project-chat", title: "Project chat", blank: false, cwd: workspace.path),
            Conversation(id: "free-chat", title: "Free chat", blank: false),
        ])

        XCTAssertEqual(store.load(workspacePath: workspace.path).map(\.id), ["project-chat"])
        XCTAssertEqual(store.load(workspacePath: nil).map(\.id), ["free-chat"])

        let bridge = AgentBridge(paths: paths, router: RouterController(baseURL: "http://127.0.0.1:1"))
        bridge.start(workspacePath: workspace.path)
        XCTAssertEqual(bridge.projectlessConversations.map(\.id), ["free-chat"])
        bridge.setWorkspace("")
        bridge.newConversation()
        XCTAssertNil(bridge.selected?.cwd)

        let model = AppModel(paths: paths)
        model.setWorkspace(workspace.path)
        model.selectedConversationID = "free-chat"
        XCTAssertEqual(model.workspacePath, "")
        XCTAssertEqual(model.selectedConversationID, "free-chat")
    }

    @MainActor
    func testConversationPinAndArchiveStatesPersistAcrossScopes() throws {
        let paths = temporaryPaths()
        let workspace = paths.root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        let store = ConversationStore(paths: paths)
        store.save([
            Conversation(id: "project-chat", title: "Project chat", blank: false, cwd: workspace.path),
            Conversation(id: "free-chat", title: "Free chat", blank: false),
        ])

        let bridge = AgentBridge(paths: paths, router: RouterController(baseURL: "http://127.0.0.1:1"))
        bridge.start(workspacePath: workspace.path)
        bridge.togglePinned("project-chat")
        bridge.setArchived("project-chat", archived: true)
        bridge.togglePinned("free-chat")
        bridge.setArchived("free-chat", archived: true)

        XCTAssertTrue(store.load(workspacePath: workspace.path).first?.pinned == true)
        XCTAssertTrue(store.load(workspacePath: workspace.path).first?.archived == true)
        XCTAssertTrue(store.load(workspacePath: nil).first?.pinned == true)
        XCTAssertTrue(store.load(workspacePath: nil).first?.archived == true)
        XCTAssertEqual(Set(bridge.archivedConversations.map(\.id)), ["project-chat", "free-chat"])

        bridge.setArchived("free-chat", archived: false)
        XCTAssertFalse(store.load(workspacePath: nil).first?.archived == true)
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
        let legacy = Data(#"[{"id":"legacy-chat","title":"Legacy","messages":[{"id":"m","kind":"user","text":"hello"}],"blank":false,"cwd":""} ]"#.utf8)
        try legacy.write(to: paths.root.appendingPathComponent("sessions.json"))

        let conversation = try XCTUnwrap(ConversationStore(paths: paths).load(workspacePath: nil).first)
        XCTAssertEqual(conversation.id, "legacy-chat")
        XCTAssertNil(conversation.messages.first?.turnID)
        XCTAssertTrue(conversation.messages.first?.changedFiles.isEmpty == true)
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

    func testPlanModeOnlyExposesReadOnlyWorkspaceTools() {
        XCTAssertEqual(WorkspaceTools.readOnlyDefinitions.map(\.name), ["list_files", "read_file"])
        XCTAssertTrue(WorkspaceTools.isReadOnly("list_files"))
        XCTAssertTrue(WorkspaceTools.isReadOnly("read_file"))
        XCTAssertFalse(WorkspaceTools.isReadOnly("write_file"))
        XCTAssertFalse(WorkspaceTools.isReadOnly("run_command"))
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
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(MockURLProtocol.lastBody)) as? [String: Any])
        XCTAssertNil(body["messages"])
        XCTAssertEqual(body["store"] as? Bool, false)
        XCTAssertEqual(body["stream"] as? Bool, true)
    }

    func testChatGPTImageGenerationUsesBuiltInResponsesTool() async throws {
        MockURLProtocol.response = Data("""
        data: {"type":"response.completed","response":{"output":[{"type":"image_generation_call","result":"AQID"}]}}

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
        XCTAssertEqual(try Data(contentsOf: media.url), Data([1, 2, 3]))
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
            model: "gpt-4.1-mini"
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
                model: "gpt-4.1-mini",
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
        XCTAssertTrue(memory.snapshot(for: "next").text.contains("archived"))

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
        ApprovalURLProtocol.responses = [
            Data(#"{"choices":[{"message":{"role":"assistant","content":"","tool_calls":[{"id":"write-1","type":"function","function":{"name":"write_file","arguments":"{\"path\":\"created.txt\",\"content\":\"changed\"}"}}]}}]}"#.utf8),
            Data(#"{"choices":[{"message":{"role":"assistant","content":"done"}}]}"#.utf8),
        ]
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
    private static let lock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "approval.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
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
        lock.unlock()
    }
}

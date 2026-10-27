import Foundation
import XCTest
import HarnessPluginKit
import PluginRuntime
@testable import DotsHarnessCore

@MainActor
final class SandboxAppModelTests: XCTestCase {
    func testNetworkSettingPersistsAndAppliesToSandboxPolicy() throws {
        let paths = temporaryPaths()
        let repository = try makeRepository(paths.root.appendingPathComponent("repo", isDirectory: true))
        let model = AppModel(paths: paths)
        model.setSeedProjectRules(false)
        model.setWorkspace(repository.path)
        model.setSandboxNetworkAccess(false)
        model.enterSandbox(named: "network")
        defer {
            if model.activeSandbox != nil { model.exitSandbox(merge: false) }
            try? FileManager.default.removeItem(at: repository)
        }

        XCTAssertEqual(model.sandboxExecutionPolicy?.networkAccess, false)
        model.setSandboxNetworkAccess(true)
        XCTAssertEqual(model.sandboxExecutionPolicy?.networkAccess, true)

        let reloaded = AppModel(paths: paths)
        XCTAssertTrue(reloaded.sandboxNetworkAccess)
    }

    func testWorkspaceChangeIsRejectedWhileSandboxIsActive() throws {
        let paths = temporaryPaths()
        let repository = try makeRepository(paths.root.appendingPathComponent("repo", isDirectory: true))
        let other = try makeRepository(paths.root.appendingPathComponent("other", isDirectory: true))
        let model = AppModel(paths: paths)
        model.setSeedProjectRules(false)
        model.setWorkspace(repository.path)
        model.enterSandbox(named: "guard")
        defer {
            if model.activeSandbox != nil { model.exitSandbox(merge: false) }
            try? FileManager.default.removeItem(at: repository)
            try? FileManager.default.removeItem(at: other)
        }

        let sandboxPath = try XCTUnwrap(model.activeSandbox?.path)
        model.setWorkspace(other.path)
        XCTAssertEqual(model.workspacePath, sandboxPath)
        XCTAssertNotEqual(model.workspacePath, other.path)
    }

    func testInvalidPersistedSandboxIsKeptForRecoveryInsteadOfOpenedUnsandboxed() throws {
        let paths = temporaryPaths()
        let repository = try makeRepository(paths.root.appendingPathComponent("repo", isDirectory: true))
        let missing = paths.root.appendingPathComponent("missing-sandbox", isDirectory: true)
        let values: [String: JSONValue] = [
            "agent.workspace": .string(missing.path),
            "agent.sandbox.origin": .string(repository.path),
            "agent.sandbox.path": .string(missing.path),
            "agent.sandbox.name": .string("recovery"),
            "agent.sandbox.branch": .string("herness/sandbox-recovery"),
            "agent.sandbox.originBranch": .string("main"),
        ]
        try JSONEncoder().encode(values).write(to: paths.settings, options: .atomic)
        defer { try? FileManager.default.removeItem(at: repository) }

        let model = AppModel(paths: paths)
        XCTAssertNil(model.activeSandbox)
        XCTAssertEqual(model.workspacePath, repository.path)
        XCTAssertNotNil(model.sandboxNotice)

        let persisted = try JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: paths.settings))
        XCTAssertEqual(persisted["agent.sandbox.origin"]?.string, repository.path)
    }

    func testProjectMetadataRoundTripsAndRemoveKeepsFiles() throws {
        let paths = temporaryPaths()
        let repository = try makeRepository(paths.root.appendingPathComponent("repo", isDirectory: true))
        let extra = paths.root.appendingPathComponent("docs", isDirectory: true)
        try FileManager.default.createDirectory(at: extra, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repository); try? FileManager.default.removeItem(at: extra) }

        let model = AppModel(paths: paths)
        model.setSeedProjectRules(false)
        model.setWorkspace(repository.path)
        model.saveProjectMetadata(for: repository.path, title: "Docs", searchFolders: [repository.path, extra.path])
        model.toggleProjectPinned(repository.path)
        XCTAssertEqual(model.createProjectSection(named: "Work"), "Work")
        model.setProjectSection("Work", for: repository.path)

        let reloaded = AppModel(paths: paths)
        XCTAssertEqual(reloaded.projectTitle(for: repository.path), "Docs")
        XCTAssertEqual(
            reloaded.projectSearchFolders(for: repository.path),
            [SandboxProfile.canonicalURL(extra).path]
        )
        XCTAssertTrue(reloaded.isProjectPinned(repository.path))
        XCTAssertEqual(reloaded.projectSection(for: repository.path), "Work")

        reloaded.removeProject(repository.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: repository.path))
    }

    func testNewChatFromProjectRowActivatesTheRequestedProject() throws {
        let paths = temporaryPaths()
        let first = try makeRepository(paths.root.appendingPathComponent("first", isDirectory: true))
        let second = try makeRepository(paths.root.appendingPathComponent("second", isDirectory: true))
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }

        let model = AppModel(paths: paths)
        model.setSeedProjectRules(false)
        model.setWorkspace(second.path)
        model.setWorkspace(first.path)
        model.newConversation(in: second.path)

        let canonicalSecond = SandboxProfile.canonicalURL(second).path
        XCTAssertEqual(model.workspacePath, canonicalSecond)
        XCTAssertEqual(
            ConversationStore.normalizedPath(model.selected?.cwd),
            ConversationStore.normalizedPath(canonicalSecond)
        )
    }

    func testNewChatFromProjectRowResynchronizesAnOutOfDateBridge() throws {
        let paths = temporaryPaths()
        let repository = try makeRepository(paths.root.appendingPathComponent("repo", isDirectory: true))
        defer { try? FileManager.default.removeItem(at: repository) }

        let model = AppModel(paths: paths)
        model.setSeedProjectRules(false)
        model.setWorkspace(repository.path)
        model.bridge.setWorkspace("")

        model.newConversation(in: repository.path)

        let canonicalPath = SandboxProfile.canonicalURL(repository).path
        XCTAssertEqual(model.workspacePath, canonicalPath)
        XCTAssertEqual(
            ConversationStore.normalizedPath(model.bridge.workspacePath),
            ConversationStore.normalizedPath(canonicalPath)
        )
        XCTAssertEqual(
            ConversationStore.normalizedPath(model.selected?.cwd),
            ConversationStore.normalizedPath(canonicalPath)
        )
    }

    func testNewConversationWithoutProjectCreatesProjectlessConversation() throws {
        let model = AppModel(paths: temporaryPaths())

        model.newConversation()

        XCTAssertEqual(model.workspacePath, "")
        XCTAssertNotNil(model.selectedConversationID)
        XCTAssertNil(model.selected?.cwd)
        XCTAssertTrue(model.selected?.projectless ?? false)
    }

    func testPlanModeDoesNotLeakAcrossNewOrSelectedConversations() throws {
        let paths = temporaryPaths()
        let repository = try makeRepository(paths.root.appendingPathComponent("plan-state", isDirectory: true))
        defer { try? FileManager.default.removeItem(at: paths.root) }

        let model = AppModel(paths: paths)
        model.setSeedProjectRules(false)
        model.setWorkspace(repository.path)
        model.newConversation()
        let firstID = try XCTUnwrap(model.selectedConversationID)
        let firstIndex = try XCTUnwrap(model.bridge.conversations.firstIndex { $0.id == firstID })
        model.bridge.conversations[firstIndex].messages = [ChatMessage(kind: .user, text: "Existing turn")]
        model.bridge.conversations[firstIndex].blank = false

        model.isPlanMode = true
        model.newConversation()
        let secondID = try XCTUnwrap(model.selectedConversationID)
        XCTAssertNotEqual(firstID, secondID)
        XCTAssertFalse(model.isPlanMode)

        model.isPlanMode = true
        model.selectedConversationID = firstID
        XCTAssertFalse(model.isPlanMode)
        model.isPlanMode = true
        model.selectedConversationID = secondID
        XCTAssertFalse(model.isPlanMode)
    }

    func testNewConversationWithoutScopeUsesMostRecentProject() throws {
        let paths = temporaryPaths()
        let previous = try makeRepository(paths.root.appendingPathComponent("previous", isDirectory: true))
        let mostRecent = try makeRepository(paths.root.appendingPathComponent("most-recent", isDirectory: true))
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let values: [String: JSONValue] = [
            "agent.workspace": .null,
            "agent.projects": .array([.string(mostRecent.path), .string(previous.path)]),
        ]
        try JSONEncoder().encode(values).write(to: paths.settings, options: .atomic)

        let model = AppModel(paths: paths)
        model.setSeedProjectRules(false)
        model.newConversation()

        let expectedPath = SandboxProfile.canonicalURL(mostRecent).path
        XCTAssertEqual(model.workspacePath, expectedPath)
        XCTAssertEqual(ConversationStore.normalizedPath(model.selected?.cwd), expectedPath)
        XCTAssertFalse(model.selected?.projectless ?? true)
    }

    func testNoProjectScopeResumesLatestProjectlessChatInsteadOfProjectChat() throws {
        let paths = temporaryPaths()
        let project = try makeRepository(paths.root.appendingPathComponent("project", isDirectory: true))
        defer { try? FileManager.default.removeItem(at: paths.root) }

        let projectChat = Conversation(
            id: "project-chat",
            title: "Project chat",
            messages: [ChatMessage(kind: .user, text: "Project-only context", createdAt: Date(timeIntervalSince1970: 200))],
            blank: false,
            cwd: project.path
        )
        let standaloneChat = Conversation(
            id: "standalone-chat",
            title: "Standalone chat",
            messages: [ChatMessage(kind: .user, text: "No-project context", createdAt: Date(timeIntervalSince1970: 100))],
            blank: false,
            projectless: true
        )
        ConversationStore(paths: paths).save([projectChat, standaloneChat])

        let model = AppModel(paths: paths)
        model.setSeedProjectRules(false)
        model.setWorkspace(project.path)
        model.selectNoProject()

        XCTAssertEqual(model.selectedConversationID, standaloneChat.id)
        XCTAssertTrue(model.selected?.projectless ?? false)
        XCTAssertFalse(model.conversations.contains(where: { $0.id == projectChat.id }))
    }

    func testNoProjectSelectionCreatesStandaloneChatWithoutReusingProjectDraft() throws {
        let paths = temporaryPaths()
        let project = try makeRepository(paths.root.appendingPathComponent("project", isDirectory: true))
        defer { try? FileManager.default.removeItem(at: paths.root) }

        let model = AppModel(paths: paths)
        model.setSeedProjectRules(false)
        model.setWorkspace(project.path)
        let projectDraftID = try XCTUnwrap(model.selectedConversationID)
        XCTAssertFalse(model.selected?.projectless ?? true)

        model.selectNoProject()
        let standaloneDraftID = try XCTUnwrap(model.selectedConversationID)
        XCTAssertTrue(model.selected?.projectless ?? false)
        model.newConversation()

        let standalone = try XCTUnwrap(model.selected)
        XCTAssertNotEqual(standalone.id, projectDraftID)
        XCTAssertEqual(standalone.id, standaloneDraftID)
        XCTAssertNil(standalone.cwd)
        XCTAssertTrue(standalone.projectless)
        XCTAssertTrue(standalone.messages.isEmpty)
        XCTAssertEqual(ConversationStore(paths: paths).load(id: projectDraftID)?.cwd, project.path)
    }

    func testNewChatFromMissingProjectDoesNotFallBackToProjectlessChat() throws {
        let paths = temporaryPaths()
        let missing = paths.root.appendingPathComponent("moved-project", isDirectory: true)
        let values: [String: JSONValue] = [
            "agent.workspace": .null,
            "agent.projects": .array([.string(missing.path)]),
        ]
        try JSONEncoder().encode(values).write(to: paths.settings, options: .atomic)

        let model = AppModel(paths: paths)
        model.newConversation(in: missing.path)

        XCTAssertEqual(model.workspacePath, "")
        XCTAssertNil(model.selectedConversationID)
        XCTAssertTrue(model.conversations.isEmpty)
    }

    func testProjectLocationRemovalDimsProjectAndPreventsAnotherConversation() async throws {
        let paths = temporaryPaths()
        let project = paths.root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: paths.root) }

        let model = AppModel(paths: paths)
        model.setSeedProjectRules(false)
        model.setWorkspace(project.path)
        let registeredPath = model.workspacePath
        XCTAssertTrue(model.activeProjectLocationAvailable)
        model.refreshProjectLocationAvailability()
        XCTAssertFalse(model.unavailableProjectPaths.contains(registeredPath))

        model.newConversation()
        let initialConversationCount = model.conversations.count
        XCTAssertEqual(initialConversationCount, 1)

        try FileManager.default.removeItem(at: project)
        model.refreshProjectLocationAvailability()

        XCTAssertFalse(model.activeProjectLocationAvailable)
        XCTAssertTrue(model.unavailableProjectPaths.contains(registeredPath))
        XCTAssertFalse(model.canSend)

        model.send(text: "This must stay unsent")
        model.draft = "This draft must stay unsent"
        model.send()
        await model.bridge.send(text: "The shared bridge must refuse this too")
        XCTAssertEqual(model.draft, "This draft must stay unsent")
        XCTAssertTrue(model.selected?.messages.allSatisfy { $0.kind != .user } ?? true)

        model.newConversation()
        XCTAssertEqual(model.conversations.count, initialConversationCount)
        model.bridge.newConversation()
        XCTAssertEqual(model.conversations.count, initialConversationCount)

        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        model.refreshProjectLocationAvailability()
        XCTAssertTrue(model.activeProjectLocationAvailable)
        XCTAssertFalse(model.unavailableProjectPaths.contains(registeredPath))
    }

    func testMissingProjectRestoresItsConversationHistoryReadOnlyAfterRelaunch() async throws {
        let paths = temporaryPaths()
        let project = paths.root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: paths.root) }

        let firstLaunch = AppModel(paths: paths)
        firstLaunch.setSeedProjectRules(false)
        firstLaunch.setWorkspace(project.path)
        let registeredProjectPath = firstLaunch.workspacePath
        firstLaunch.newConversation()
        let oldConversationID = try XCTUnwrap(firstLaunch.selectedConversationID)
        ConversationStore(paths: paths).save([
            Conversation(
                id: oldConversationID,
                title: "Earlier project conversation",
                messages: [ChatMessage(kind: .user, text: "An earlier project message")],
                blank: false,
                cwd: registeredProjectPath
            ),
        ])

        try FileManager.default.removeItem(at: project)
        let relaunched = AppModel(paths: paths)
        relaunched.prepareForFirstFrame()

        XCTAssertEqual(relaunched.workspacePath, registeredProjectPath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: project.path))
        XCTAssertFalse(relaunched.activeProjectLocationAvailable)
        XCTAssertFalse(relaunched.canSend)
        XCTAssertTrue(relaunched.projectPaths.contains(registeredProjectPath))
        XCTAssertTrue(relaunched.conversations.contains(where: { $0.id == oldConversationID }))
        XCTAssertEqual(
            relaunched.conversations.first(where: { $0.id == oldConversationID })?.messages.first?.text,
            "An earlier project message"
        )

        relaunched.newConversation()
        await relaunched.bridge.send(text: "Must remain blocked")
        XCTAssertEqual(
            relaunched.conversations.first(where: { $0.id == oldConversationID })?.messages.map(\.text),
            ["An earlier project message"]
        )
    }

    func testRelocatingMissingProjectActivatesNewPathWithoutDuplicateAndKeepsPreferences() throws {
        let paths = temporaryPaths()
        let oldProject = paths.root.appendingPathComponent("old-project", isDirectory: true)
        let newProject = paths.root.appendingPathComponent("new-project", isDirectory: true)
        try FileManager.default.createDirectory(at: oldProject, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: newProject, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: paths.root) }

        let model = AppModel(paths: paths)
        model.setWorkspace(oldProject.path)
        let oldPath = model.workspacePath
        model.saveProjectMetadata(for: oldPath, title: "Workspace", searchFolders: [])
        model.setSortOrder(.manual, forProject: oldPath)
        model.moveConversation("first", before: nil, inProject: oldPath, currentOrder: ["first", "second"])
        model.setWorkspace(newProject.path)
        let newPath = model.workspacePath
        model.setWorkspace(oldPath)

        try FileManager.default.removeItem(at: oldProject)
        XCTAssertFalse(model.activeProjectLocationAvailable)

        XCTAssertEqual(model.relocateProject(missingPath: oldPath, to: newPath), newPath)

        XCTAssertEqual(model.workspacePath, newPath)
        XCTAssertEqual(model.projectPaths.filter { $0 == newPath }.count, 1)
        XCTAssertFalse(model.projectPaths.contains(oldPath))
        XCTAssertEqual(model.projectTitle(for: newPath), "Workspace")
        XCTAssertEqual(model.sortOrder(forProject: newPath), .manual)
        XCTAssertEqual(model.projectManualOrder[newPath], ["second", "first"])
        XCTAssertTrue(model.activeProjectLocationAvailable)
        XCTAssertTrue(model.unavailableProjectPaths.isEmpty)

        model.newConversation(in: newPath)
        XCTAssertEqual(
            ConversationStore.normalizedPath(model.selected?.cwd),
            ConversationStore.normalizedPath(newPath)
        )

        let reloaded = AppModel(paths: paths)
        XCTAssertEqual(reloaded.projectPaths.filter { $0 == newPath }.count, 1)
        XCTAssertEqual(reloaded.projectTitle(for: newPath), "Workspace")
        XCTAssertEqual(reloaded.projectManualOrder[newPath], ["second", "first"])
    }

    func testOtherProjectExpansionIsSessionOnlyAndSurvivesProjectSelection() throws {
        let paths = temporaryPaths()
        let first = paths.root.appendingPathComponent("first", isDirectory: true)
        let second = paths.root.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: paths.root) }

        let model = AppModel(paths: paths)
        XCTAssertFalse(model.showsAllOtherProjects)

        model.revealAllOtherProjects()
        model.setWorkspace(first.path)
        model.setWorkspace(second.path)
        XCTAssertTrue(model.showsAllOtherProjects)

        let reloaded = AppModel(paths: paths)
        XCTAssertFalse(reloaded.showsAllOtherProjects)

        let persisted = try JSONDecoder().decode(
            [String: JSONValue].self,
            from: Data(contentsOf: paths.settings)
        )
        XCTAssertNil(persisted["agent.showsAllOtherProjects"])
    }

    private func makeRepository(_ url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        XCTAssertEqual(SandboxWorkspaces.git(["init", "--initial-branch=main"], in: url).status, 0)
        XCTAssertEqual(SandboxWorkspaces.git(["config", "user.email", "test@example.com"], in: url).status, 0)
        XCTAssertEqual(SandboxWorkspaces.git(["config", "user.name", "Test"], in: url).status, 0)
        try "one\n".write(to: url.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        XCTAssertEqual(SandboxWorkspaces.git(["add", "-A"], in: url).status, 0)
        XCTAssertEqual(SandboxWorkspaces.git(["commit", "-m", "init"], in: url).status, 0)
        return url
    }

    private func temporaryPaths() -> SupportPaths {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DotsHarnessSandboxApp-\(UUID().uuidString)", isDirectory: true)
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

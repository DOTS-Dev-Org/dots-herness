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

    func testNewChatWithoutProjectCreatesAProjectlessConversation() throws {
        let model = AppModel(paths: temporaryPaths())

        model.newConversation()

        XCTAssertEqual(model.workspacePath, "")
        XCTAssertNotNil(model.selectedConversationID)
        XCTAssertNil(model.selected?.cwd)
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

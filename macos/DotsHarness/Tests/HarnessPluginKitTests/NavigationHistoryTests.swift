import Foundation
import PluginRuntime
import XCTest
@testable import DotsHarnessCore

final class NavigationHistoryTests: XCTestCase {
    @MainActor
    func testBackAndForwardWalkBetweenOpenedChats() throws {
        let (model, paths, workspace) = try makeModel()
        ConversationStore(paths: paths).save([
            chat("first", in: workspace.path),
            chat("second", in: workspace.path),
        ])
        model.setWorkspace(workspace.path)

        model.selectedConversationID = "first"
        XCTAssertFalse(model.canNavigateBack)
        XCTAssertFalse(model.canNavigateForward)

        model.selectedConversationID = "second"
        XCTAssertTrue(model.canNavigateBack)
        XCTAssertFalse(model.canNavigateForward)

        model.navigateBack()
        XCTAssertEqual(model.selectedConversationID, "first")
        XCTAssertTrue(model.canNavigateForward)

        model.navigateForward()
        XCTAssertEqual(model.selectedConversationID, "second")
        XCTAssertFalse(model.canNavigateForward)
    }

    /// A new chat after a "back" abandons the forward branch, like a browser.
    @MainActor
    func testNavigationAfterGoingBackDropsTheForwardBranch() throws {
        let (model, paths, workspace) = try makeModel()
        ConversationStore(paths: paths).save([
            chat("first", in: workspace.path),
            chat("second", in: workspace.path),
            chat("third", in: workspace.path),
        ])
        model.setWorkspace(workspace.path)
        model.selectedConversationID = "first"
        model.selectedConversationID = "second"
        model.selectedConversationID = "third"

        model.navigateBack()
        model.navigateBack()
        XCTAssertEqual(model.selectedConversationID, "first")
        XCTAssertTrue(model.canNavigateForward)

        model.selectedConversationID = "third"
        XCTAssertFalse(model.canNavigateForward)
    }

    @MainActor
    func testBackReturnsThroughTheTaskListAndOtherProjects() throws {
        let (model, paths, workspace) = try makeModel()
        let other = workspace.appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        ConversationStore(paths: paths).save([
            chat("mine", in: workspace.path),
            chat("theirs", in: other.path),
        ])
        model.setWorkspace(workspace.path)
        model.presentTasks()
        XCTAssertTrue(model.isTasksPresented)

        model.setWorkspace(other.path)
        XCTAssertEqual(model.selectedConversationID, "theirs")

        model.navigateBack()
        XCTAssertTrue(model.isTasksPresented)

        model.navigateBack()
        XCTAssertFalse(model.isTasksPresented)
        XCTAssertEqual(model.workspacePath, workspace.path)
        XCTAssertEqual(model.selectedConversationID, "mine")

        model.navigateForward()
        XCTAssertTrue(model.isTasksPresented)
    }

    /// A chat deleted since it was visited can never open again, so the step
    /// skips it instead of leaving the buttons dead.
    @MainActor
    func testBackSkipsDeletedChats() throws {
        let (model, paths, workspace) = try makeModel()
        ConversationStore(paths: paths).save([
            chat("first", in: workspace.path),
            chat("second", in: workspace.path),
            chat("third", in: workspace.path),
        ])
        model.setWorkspace(workspace.path)
        model.selectedConversationID = "first"
        model.selectedConversationID = "second"
        model.selectedConversationID = "third"

        model.bridge.deleteConversation("second")
        model.navigateBack()

        XCTAssertEqual(model.selectedConversationID, "first")
        XCTAssertFalse(model.canNavigateBack)
        XCTAssertTrue(model.canNavigateForward)
        model.navigateForward()
        XCTAssertEqual(model.selectedConversationID, "third")
    }

    @MainActor
    private func makeModel() throws -> (AppModel, SupportPaths, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DotsHarnessNavigationTests-\(UUID().uuidString)", isDirectory: true)
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
        let workspace = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let canonicalWorkspace = SandboxProfile.canonicalURL(workspace)
        return (AppModel(paths: paths), paths, canonicalWorkspace)
    }

    private func chat(_ id: String, in workspace: String) -> Conversation {
        Conversation(
            id: id,
            title: id,
            messages: [ChatMessage(kind: .user, text: "Prompt")],
            blank: false,
            cwd: workspace
        )
    }
}

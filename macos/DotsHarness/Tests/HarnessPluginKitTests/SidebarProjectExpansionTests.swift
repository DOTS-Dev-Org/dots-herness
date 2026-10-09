import Foundation
import XCTest
import PluginRuntime
@testable import DotsHarnessCore

/// Sidebar project sublists must come back exactly as the user left them.
final class SidebarProjectExpansionTests: XCTestCase {
    @MainActor
    func testOpenAndClosedSublistsSurviveRelaunch() throws {
        let paths = temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let active = try makeProject(paths, name: "active")
        let other = try makeProject(paths, name: "other")

        let model = AppModel(paths: paths)
        model.setWorkspace(active.path)
        model.setProjectChatsExpanded(true, for: active.path)
        model.setProjectChatsExpanded(true, for: other.path)
        model.setProjectChatsExpanded(false, for: other.path)

        let restored = AppModel(paths: paths)
        // Compare with the path the model actually selected; macOS temporary
        // directories can have distinct /var and /private/var spellings.
        XCTAssertEqual(restored.expandedProjectPaths, [model.workspacePath])
    }

    @MainActor
    func testRemovingAProjectDropsItsStoredExpansionState() throws {
        let paths = temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let kept = try makeProject(paths, name: "kept")
        let removed = try makeProject(paths, name: "removed")

        let model = AppModel(paths: paths)
        model.setWorkspace(removed.path)
        model.setWorkspace(kept.path)
        model.setProjectChatsExpanded(true, for: kept.path)
        model.setProjectChatsExpanded(true, for: removed.path)
        model.removeProject(removed.path)

        XCTAssertEqual(AppModel(paths: paths).expandedProjectPaths, [kept.path])
    }

    @MainActor
    func testFirstLaunchShowsTheActiveProjectChats() throws {
        let paths = temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let active = try makeProject(paths, name: "active")

        let model = AppModel(paths: paths)
        model.setWorkspace(active.path)

        XCTAssertEqual(AppModel(paths: paths).expandedProjectPaths, [active.path])
    }

    private func makeProject(_ paths: SupportPaths, name: String) throws -> URL {
        let url = paths.root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return SandboxProfile.canonicalURL(url)
    }

    private func temporaryPaths() -> SupportPaths {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SidebarProjectExpansionTests-\(UUID().uuidString)", isDirectory: true)
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

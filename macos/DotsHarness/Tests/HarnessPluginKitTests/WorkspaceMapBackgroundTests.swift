import XCTest
import PluginRuntime
@testable import DotsHarnessCore

@MainActor
final class WorkspaceMapBackgroundTests: XCTestCase {
    func testFirstPromptDefersMapScanAndRefreshesTheMap() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceMapBackgroundTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try "// swift package\n".write(
            to: workspace.appendingPathComponent("Package.swift"),
            atomically: true,
            encoding: .utf8
        )

        let support = root.appendingPathComponent("support", isDirectory: true)
        let paths = SupportPaths(
            root: support,
            plugins: support.appendingPathComponent("plugins", isDirectory: true),
            presets: support.appendingPathComponent("presets", isDirectory: true),
            settings: support.appendingPathComponent("settings.json"),
            hostPatch: support.appendingPathComponent("host.patch.yml"),
            trust: support.appendingPathComponent("trust.json"),
            models: support.appendingPathComponent("models", isDirectory: true),
            runtime: support.appendingPathComponent("runtime", isDirectory: true)
        )
        paths.ensure()

        let memory = WorkspaceMemory(paths: paths)
        memory.setWorkspace(workspace)
        let mapURL = workspace.appendingPathComponent(".mem/map.md")
        memory.prepareForPromptInBackground(prompt: "start", runID: UUID(), provider: "test", model: "test")

        XCTAssertFalse(FileManager.default.fileExists(atPath: mapURL.path))
        let deadline = Date().addingTimeInterval(10)
        while memory.mapRefreshInFlight.contains(workspace.path), Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertFalse(memory.mapRefreshInFlight.contains(workspace.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: mapURL.path))
        XCTAssertTrue(memory.projectText().contains("`Package.swift`"))
    }
}

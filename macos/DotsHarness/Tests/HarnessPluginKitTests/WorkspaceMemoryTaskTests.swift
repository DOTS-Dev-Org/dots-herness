import XCTest
@testable import DotsHarnessCore
import PluginRuntime

@MainActor
final class WorkspaceMemoryTaskTests: XCTestCase {
    func testChatOnlyRunLeavesNoTaskNote() throws {
        let (memory, workspace) = try makeMemory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        run(memory, workspace: workspace, prompt: "selam", usingTool: false)
        XCTAssertEqual(taskNoteCount(workspace), 0)
    }

    func testRunThatUsedAToolIsRecorded() throws {
        let (memory, workspace) = try makeMemory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        run(memory, workspace: workspace, prompt: "read the readme", usingTool: true)
        XCTAssertEqual(taskNoteCount(workspace), 1)
    }

    func testBacklogMarkerKeepsTaskOpenAndSurfacesInSnapshot() throws {
        let (memory, workspace) = try makeMemory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let runID = UUID()
        memory.prepareForPrompt(prompt: "add login", runID: runID, provider: "test", model: "test")
        memory.recordTool(
            runID: runID,
            call: AgentToolCall(id: "1", name: "read_file", arguments: #"{"path":"README.md"}"#),
            result: "ok",
            beforeFile: nil,
            beforeGit: [],
            workspace: workspace
        )
        memory.finishTask(runID: runID, success: true, finalText: "Did part one.\nBACKLOG: wire the logout route")
        XCTAssertTrue(memory.snapshot(for: "anything").text.contains("wire the logout route"))

        let done = UUID()
        memory.prepareForPrompt(prompt: "finish it", runID: done, provider: "test", model: "test")
        memory.finishTask(runID: done, success: true, finalText: "BACKLOG-DONE: \(runID.uuidString)")
        let note = try String(contentsOf: workspace.appendingPathComponent(".mem/tasks/\(runID.uuidString).md"), encoding: .utf8)
        XCTAssertTrue(note.contains("status: completed"))
        XCTAssertFalse(memory.snapshot(for: "anything").text.contains("## Unfinished work"))
    }

    func testProjectBriefRoundTrips() throws {
        let (memory, workspace) = try makeMemory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        memory.prepareForPrompt(prompt: "start", runID: UUID(), provider: "test", model: "test")

        XCTAssertFalse(memory.hasProjectBrief)
        try memory.setProjectDefault(key: "goal", value: "One harness, three platforms.")
        XCTAssertTrue(memory.hasProjectBrief)
        XCTAssertTrue(memory.snapshot(for: "anything").text.contains("One harness, three platforms."))
    }

    func testPreferenceRoundTrips() throws {
        let (memory, workspace) = try makeMemory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        memory.prepareForPrompt(prompt: "start", runID: UUID(), provider: "test", model: "test")

        try memory.setPreference(key: "language", value: "Turkish")
        XCTAssertTrue(memory.snapshot(for: "anything").text.contains("Turkish"))
        let note = try String(
            contentsOf: workspace.appendingPathComponent(".mem/preferences.md"),
            encoding: .utf8
        )
        XCTAssertTrue(note.contains("Turkish"))
    }

    private func makeMemory() throws -> (WorkspaceMemory, URL) {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceMemoryTaskTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let memory = WorkspaceMemory(paths: temporaryPaths())
        memory.setWorkspace(workspace)
        return (memory, workspace)
    }

    private func run(_ memory: WorkspaceMemory, workspace: URL, prompt: String, usingTool: Bool) {
        let runID = UUID()
        memory.prepareForPrompt(prompt: prompt, runID: runID, provider: "test", model: "test")
        if usingTool {
            memory.recordTool(
                runID: runID,
                call: AgentToolCall(id: "1", name: "read_file", arguments: #"{"path":"README.md"}"#),
                result: "ok",
                beforeFile: nil,
                beforeGit: [],
                workspace: workspace
            )
        }
        memory.finishTask(runID: runID, success: true)
    }

    private func taskNoteCount(_ workspace: URL) -> Int {
        let dir = workspace.appendingPathComponent(".mem/tasks", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "md" }.count
    }

    private func temporaryPaths() -> SupportPaths {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceMemoryTaskTests-support-\(UUID().uuidString)", isDirectory: true)
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

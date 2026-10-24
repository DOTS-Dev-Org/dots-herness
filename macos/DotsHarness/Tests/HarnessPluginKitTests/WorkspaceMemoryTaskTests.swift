import XCTest
@testable import DotsHarnessCore
import PluginRuntime

@MainActor
final class WorkspaceMemoryTaskTests: XCTestCase {
    func testChatOnlyRunLeavesNoTaskNote() throws {
        let (memory, workspace) = try makeMemory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        run(memory, workspace: workspace, prompt: "selam", usingTool: false)
        XCTAssertEqual(taskNoteCount(memory), 0)
    }

    func testRunThatUsedAToolIsRecorded() throws {
        let (memory, workspace) = try makeMemory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        run(memory, workspace: workspace, prompt: "read the readme", usingTool: true)
        XCTAssertEqual(taskNoteCount(memory), 1)
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
            afterGit: [],
            workspace: workspace
        )
        memory.finishTask(runID: runID, success: true, finalText: "Did part one.\nBACKLOG: wire the logout route")
        XCTAssertTrue(memory.snapshot(for: "anything").text.contains("wire the logout route"))

        let done = UUID()
        memory.prepareForPrompt(prompt: "finish it", runID: done, provider: "test", model: "test")
        memory.finishTask(runID: done, success: true, finalText: "BACKLOG-DONE: \(runID.uuidString)")
        // The task note is the person's: it lives in the user layer, not in the repository.
        let note = try String(contentsOf: memory.userMemoryDirectory!.appendingPathComponent("tasks/\(runID.uuidString).md"), encoding: .utf8)
        XCTAssertTrue(note.contains("status: completed"))
        XCTAssertFalse(memory.snapshot(for: "anything").text.contains("## Unfinished work"))
    }

    func testBacklogDirectivesAreHiddenFromPeopleButStillDriveTaskState() throws {
        let (memory, workspace) = try makeMemory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        XCTAssertEqual(
            memory.visibleText(in: "Did part one.\nBACKLOG: wire the logout route"),
            "Did part one."
        )
        XCTAssertEqual(
            memory.visibleText(in: "Finished it.\nBACKLOG-DONE: run-id"),
            "Finished it."
        )
        XCTAssertEqual(memory.visibleText(in: "Reply\nBACKLOG-D", hidePartialMarkerTail: true), "Reply")
        XCTAssertEqual(memory.visibleText(in: "Because this matters", hidePartialMarkerTail: true), "Because this matters")
        let rawMessage = ChatMessage(kind: .assistant, text: "Did part one.\nBACKLOG: hidden after reload")
        let restoredMessage = try JSONDecoder().decode(ChatMessage.self, from: JSONEncoder().encode(rawMessage))
        XCTAssertEqual(restoredMessage.text, "Did part one.", "saved assistant history must not reveal old directives")
        let userMessage = try JSONDecoder().decode(
            ChatMessage.self,
            from: JSONEncoder().encode(ChatMessage(kind: .user, text: "BACKLOG: my literal text"))
        )
        XCTAssertEqual(userMessage.text, "BACKLOG: my literal text", "the filter must not rewrite user input")

        let runID = UUID()
        memory.prepareForPrompt(prompt: "add login", runID: runID, provider: "test", model: "test")
        memory.recordTool(
            runID: runID,
            call: AgentToolCall(id: "1", name: "read_file", arguments: #"{"path":"README.md"}"#),
            result: "ok",
            beforeFile: nil,
            beforeGit: [],
            afterGit: [],
            workspace: workspace
        )
        let raw = "Did part one.\nBACKLOG: wire the logout route"
        memory.finishTask(runID: runID, success: true, finalText: memory.visibleText(in: raw), controlText: raw)
        XCTAssertTrue(memory.snapshot(for: "anything").text.contains("wire the logout route"))
        let note = try String(
            contentsOf: memory.userMemoryDirectory!.appendingPathComponent("tasks/\(runID.uuidString).md"),
            encoding: .utf8
        )
        XCTAssertFalse(note.contains("BACKLOG:"))
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

    func testPreferenceRoundTripsAndStaysOutOfTheRepository() throws {
        let (memory, workspace) = try makeMemory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        memory.prepareForPrompt(prompt: "start", runID: UUID(), provider: "test", model: "test")

        try memory.setProjectUserPreference(key: "language", value: "Turkish")
        XCTAssertTrue(memory.preferencesText().contains("Turkish"))
        XCTAssertTrue(memory.snapshot(for: "anything").text.contains("Turkish"))
        XCTAssertEqual(memory.profile.projectPreferences(projectID: try XCTUnwrap(memory.projectID))["language"], "Turkish")
        XCTAssertFalse(repositoryContains("Turkish", in: workspace), "a preference must never reach .mem")
    }

    /// A manifest that arrives after the workspace was opened (a checkout, a pull) is adopted,
    /// and one that cannot be read (a merge conflict) is left alone: neither gets a new id.
    func testPromptNeverReplacesAnExistingManifest() throws {
        let (memory, workspace) = try makeMemory()
        let manifestURL = workspace.appendingPathComponent(".mem/manifest.json")
        try FileManager.default.createDirectory(at: manifestURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let id = UUID().uuidString
        try Data(#"{"schemaVersion":1,"projectId":"\#(id)","createdAt":"2026-01-01T00:00:00Z"}"#.utf8).write(to: manifestURL)
        memory.prepareForPrompt(prompt: "hello", runID: UUID(), provider: "test", model: "test")
        XCTAssertEqual(memory.projectID, id)

        let (broken, brokenWorkspace) = try makeMemory()
        let brokenURL = brokenWorkspace.appendingPathComponent(".mem/manifest.json")
        try FileManager.default.createDirectory(at: brokenURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let conflicted = "<<<<<<< HEAD\n{\"projectId\":\"\(id)\"}\n=======\n"
        try Data(conflicted.utf8).write(to: brokenURL)
        broken.prepareForPrompt(prompt: "hello", runID: UUID(), provider: "test", model: "test")
        XCTAssertNil(broken.projectID)
        XCTAssertEqual(try String(contentsOf: brokenURL, encoding: .utf8), conflicted)
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
                afterGit: [],
                workspace: workspace
            )
        }
        memory.finishTask(runID: runID, success: true)
    }

    private func taskNoteCount(_ memory: WorkspaceMemory) -> Int {
        guard let dir = memory.userMemoryDirectory?.appendingPathComponent("tasks", isDirectory: true) else { return 0 }
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "md" }.count
    }

    /// Whether any file under the repository's `.mem` folder contains the text.
    private func repositoryContains(_ text: String, in workspace: URL) -> Bool {
        let root = workspace.appendingPathComponent(".mem", isDirectory: true)
        guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return false }
        for case let url as URL in files {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                  let body = try? String(contentsOf: url, encoding: .utf8) else { continue }
            if body.contains(text) { return true }
        }
        return false
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

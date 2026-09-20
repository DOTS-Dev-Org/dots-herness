// Copyright (c) 2026 DOTS

import Foundation
import PluginRuntime
import XCTest
@testable import DotsHarnessCore

@MainActor
final class WorkspaceSnapshotIncrementalTests: XCTestCase {
    private var root: URL!
    private var workspace: URL!
    private var paths: SupportPaths!
    private var memory: WorkspaceMemory!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnapshotIncremental-\(UUID().uuidString)", isDirectory: true)
        workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        paths = SupportPaths(
            root: root.appendingPathComponent("support", isDirectory: true),
            plugins: root.appendingPathComponent("plugins"),
            presets: root.appendingPathComponent("presets"),
            settings: root.appendingPathComponent("settings.json"),
            hostPatch: root.appendingPathComponent("host.patch.yml"),
            trust: root.appendingPathComponent("trust.json"),
            models: root.appendingPathComponent("models"),
            runtime: root.appendingPathComponent("runtime")
        )
        memory = WorkspaceMemory(paths: paths)
        memory.setWorkspace(workspace)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ name: String, _ text: String, age: TimeInterval? = 3600) throws {
        let url = workspace.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        if let age {
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: url.path)
        }
    }

    private func backup(turn: String, _ name: String) -> URL {
        paths.root.appendingPathComponent("rewind/chat/\(turn)/before/\(name)")
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    private func runTurn(_ id: String, changing edit: () throws -> Void = {}) throws -> [ChangedFile] {
        XCTAssertTrue(memory.beginTurn(conversationID: "chat", turnID: id, workspace: workspace))
        try edit()
        return memory.finishTurn(conversationID: "chat", turnID: id, workspace: workspace)
    }

    /// Files untouched since the last capture reference the existing backup instead of being
    /// copied, files the agent changed are copied afresh, and rewinding restores the right content.
    func testUnchangedFilesAreReferencedAndChangedFilesAreCopied() throws {
        try write("keep.txt", "keep")
        try write("edit.txt", "before one")
        _ = try runTurn("t1") {
            try write("edit.txt", "after one!", age: nil)     // agent edits it
        }

        let changed = try runTurn("t2") {
            try write("edit.txt", "after two!!", age: nil)
            try write("new.txt", "brand new", age: nil)
        }
        XCTAssertEqual(Set(changed.map(\.path)), ["edit.txt", "new.txt"])

        // keep.txt never changed: turn 2 holds no copy, it points at turn 1's.
        XCTAssertFalse(exists(backup(turn: "t2", "keep.txt")))
        XCTAssertTrue(exists(backup(turn: "t1", "keep.txt")))
        XCTAssertTrue(memory.hasCompleteTurnSnapshot(conversationID: "chat", turnID: "t2", workspace: workspace))
        // edit.txt changed during turn 1, so turn 2's backup is its own copy of "after one!".
        XCTAssertEqual(try String(contentsOf: backup(turn: "t2", "edit.txt")), "after one!")

        let result = try memory.restoreTurns(conversationID: "chat", turnIDs: ["t2"], workspace: workspace, abortOnConflict: false)
        XCTAssertEqual(Set(result.restoredPaths), ["edit.txt", "new.txt"])
        XCTAssertEqual(try String(contentsOf: workspace.appendingPathComponent("edit.txt")), "after one!")
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("new.txt").path))
    }

    /// A file modified just before the capture cannot be trusted by time alone.
    func testRecentlyModifiedFilesAreNotTrusted() throws {
        try write("hot.txt", "one", age: nil)
        _ = try runTurn("t1")
        _ = try runTurn("t2")
        XCTAssertTrue(exists(backup(turn: "t2", "hot.txt")), "a file modified within the racy window was referenced")
        XCTAssertEqual(try String(contentsOf: backup(turn: "t2", "hot.txt")), "one")
    }

    /// Same size, new content and a new modification time is still noticed at the end of a turn.
    func testSameSizeEditIsDetectedAtFinish() throws {
        try write("a.txt", "aaaa")
        try write("b.txt", "bbbb")
        let changed = try runTurn("t1") {
            try write("a.txt", "zzzz", age: nil)
        }
        XCTAssertEqual(changed.map(\.path), ["a.txt"])
    }

    /// Files deleted between turns and files that shrank are handled by the trust check.
    func testDeletedAndResizedFilesBetweenTurns() throws {
        try write("gone.txt", "will vanish")
        try write("size.txt", "long content here")
        _ = try runTurn("t1")
        try FileManager.default.removeItem(at: workspace.appendingPathComponent("gone.txt"))
        try write("size.txt", "short")                 // old timestamp, different size
        _ = try runTurn("t2")
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup(turn: "t2", "gone.txt").path))
        XCTAssertEqual(try String(contentsOf: backup(turn: "t2", "size.txt")), "short")
    }

    /// A file the agent deletes comes back from the earlier turn's backup it references.
    func testReferencedBackupRestoresADeletedFile() throws {
        try write("keep.txt", "keep me")
        _ = try runTurn("t1")
        _ = try runTurn("t2") {
            try FileManager.default.removeItem(at: workspace.appendingPathComponent("keep.txt"))
        }
        XCTAssertFalse(exists(backup(turn: "t2", "keep.txt")))
        _ = try memory.restoreTurns(conversationID: "chat", turnIDs: ["t2"], workspace: workspace, abortOnConflict: false)
        XCTAssertEqual(try String(contentsOf: workspace.appendingPathComponent("keep.txt")), "keep me")
    }

    /// Deleting the conversation that owns a referenced backup must not break other turns.
    func testDeletingTheOwningConversationKeepsReferencingTurnsRestorable() throws {
        try write("keep.txt", "keep me")
        XCTAssertTrue(memory.beginTurn(conversationID: "owner", turnID: "o1", workspace: workspace))
        _ = memory.finishTurn(conversationID: "owner", turnID: "o1", workspace: workspace)
        XCTAssertTrue(memory.beginTurn(conversationID: "other", turnID: "x1", workspace: workspace))
        let referenced = paths.root.appendingPathComponent("rewind/other/x1/before/keep.txt")
        XCTAssertFalse(exists(referenced))
        try FileManager.default.removeItem(at: workspace.appendingPathComponent("keep.txt"))
        _ = memory.finishTurn(conversationID: "other", turnID: "x1", workspace: workspace)

        memory.removeTurnSnapshots(conversationID: "owner")
        XCTAssertTrue(exists(referenced), "the backup was not handed to the turn that used it")
        XCTAssertTrue(memory.hasCompleteTurnSnapshot(conversationID: "other", turnID: "x1", workspace: workspace))
        _ = try memory.restoreTurns(conversationID: "other", turnIDs: ["x1"], workspace: workspace, abortOnConflict: false)
        XCTAssertEqual(try String(contentsOf: workspace.appendingPathComponent("keep.txt")), "keep me")

    }

    /// The capture runs beside the model request; the turn's tools wait for it.
    func testBackgroundBeginThenChangesAreTracked() async throws {
        try write("f.txt", "original")
        memory.beginTurnInBackground(conversationID: "chat", turnID: "bg", workspace: workspace)
        await memory.waitForTurnSnapshot(conversationID: "chat", turnID: "bg")
        try write("f.txt", "modified!", age: nil)
        let changed = memory.finishTurn(conversationID: "chat", turnID: "bg", workspace: workspace)
        XCTAssertEqual(changed.map(\.path), ["f.txt"])
        XCTAssertTrue(memory.hasCompleteTurnSnapshot(conversationID: "chat", turnID: "bg", workspace: workspace))
        XCTAssertEqual(try String(contentsOf: backup(turn: "bg", "f.txt")), "original")
    }

    /// A turn that ends at once (no tools) must not race its own capture.
    func testFinishWaitsForACaptureStillRunning() throws {
        for index in 0..<200 { try write("file\(index).txt", String(repeating: "x", count: 2000)) }
        memory.beginTurnInBackground(conversationID: "chat", turnID: "quick", workspace: workspace)
        let result = memory.finishTurnResult(conversationID: "chat", turnID: "quick", workspace: workspace)
        XCTAssertEqual(result.trackingStatus, "complete")
        XCTAssertTrue(result.changedFiles.isEmpty)
    }
}

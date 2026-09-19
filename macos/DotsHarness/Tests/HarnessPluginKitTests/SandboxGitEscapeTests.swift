import Foundation
import XCTest
@testable import DotsHarnessCore

/// Exercises `run_command` (the agent's real tool path) inside a live sandbox
/// worktree: git must work, and nothing must leak outside the worktree plus
/// the metadata roots git itself needs.
final class SandboxGitEscapeTests: XCTestCase {
    private var origin: URL!
    private var sandbox: SandboxWorkspace!

    override func setUpWithError() throws {
        origin = FileManager.default.temporaryDirectory
            .appendingPathComponent("sandbox-escape-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: origin, withIntermediateDirectories: true)
        run(["init", "--initial-branch=main"], in: origin)
        run(["config", "user.email", "t@example.com"], in: origin)
        run(["config", "user.name", "T"], in: origin)
        try "one\n".write(to: origin.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        run(["add", "-A"], in: origin)
        run(["commit", "-m", "init"], in: origin)
        sandbox = try SandboxWorkspaces.enter(origin: origin.path, name: "escape-\(UUID().uuidString.prefix(6))")
    }

    override func tearDownWithError() throws {
        if let sandbox { _ = try? SandboxWorkspaces.exit(sandbox, merge: false) }
        try? FileManager.default.removeItem(at: origin)
    }

    private func run(_ arguments: [String], in directory: URL) {
        SandboxWorkspaces.git(arguments, in: directory)
    }

    private var worktree: URL { URL(fileURLWithPath: sandbox.path, isDirectory: true) }

    private func policy() throws -> SandboxExecutionPolicy {
        SandboxExecutionPolicy(
            workspaceURL: worktree,
            additionalWritableRoots: try SandboxWorkspaces.agentWritableRoots(for: sandbox)
        )
    }

    private func runCommand(_ command: String) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: ["command": command])
        return WorkspaceTools.execute(
            AgentToolCall(id: UUID().uuidString, name: "run_command", arguments: String(decoding: data, as: UTF8.self)),
            workspace: worktree,
            sandboxPolicy: try policy()
        )
    }

    /// This is the bug the previous policy had: `additionalWritableRoots`
    /// defaulted to empty, so `git commit` inside the sandbox failed with
    /// "Operation not permitted" on the worktree's own metadata directory.
    func testGitCommitInsideSandboxSucceeds() throws {
        try "two\n".write(to: worktree.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let result = try runCommand("git add -A && git commit -m sandboxed && echo COMMIT_OK")
        // ~/.config is denied (see makeProfile), so git's optional read of
        // ~/.config/git/ignore prints a benign warning and continues — that's
        // not a real failure, so only the actual success signal is checked.
        XCTAssertTrue(result.contains("COMMIT_OK"), result)

        // The commit is real and lives on the sandbox branch only.
        let log = SandboxWorkspaces.git(["log", "--oneline", "-1"], in: worktree)
        XCTAssertTrue(log.text.contains("sandboxed"), log.text)
    }

    /// The metadata roots grant git's internals write access, not the
    /// origin's working tree: the file the user sees must stay exactly as it
    /// was, even after a sandboxed commit.
    func testOriginWorkingTreeStaysUntouched() throws {
        try "two\n".write(to: worktree.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        _ = try runCommand("git add -A && git commit -m sandboxed")
        XCTAssertEqual(try String(contentsOf: origin.appendingPathComponent("a.txt")), "one\n")
    }

    func testCannotWriteOriginWorkingTreeFileDirectly() throws {
        let result = try runCommand("printf escaped > \(quote(origin.appendingPathComponent("a.txt").path)) 2>&1; echo rc=$?")
        XCTAssertFalse(result.contains("rc=0"), result)
        XCTAssertEqual(try String(contentsOf: origin.appendingPathComponent("a.txt")), "one\n")
    }

    func testCannotReadSSHEvenWithGitRootsGranted() throws {
        let result = try runCommand("ls ~/.ssh 2>&1; echo rc=$?")
        XCTAssertFalse(result.contains("rc=0"), result)
    }

    func testCannotWriteOutsideWorktreeAndMetadataRoots() throws {
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("sandbox-escape-outside-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: outside) }
        let result = try runCommand("printf escaped > \(quote(outside.path)) 2>&1; echo rc=$?")
        XCTAssertFalse(result.contains("rc=0"), result)
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.path))
    }

    private func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

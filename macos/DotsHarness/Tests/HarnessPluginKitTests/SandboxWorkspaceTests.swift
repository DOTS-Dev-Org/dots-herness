import XCTest
@testable import DotsHarnessCore

final class SandboxWorkspaceTests: XCTestCase {
    private var origin: URL!

    override func setUpWithError() throws {
        origin = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SandboxTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: origin, withIntermediateDirectories: true)
        run(["init", "--initial-branch=main"])
        run(["config", "user.email", "test@example.com"])
        run(["config", "user.name", "Test"])
        try write("a.txt", "one\n")
        run(["add", "-A"])
        run(["commit", "-m", "init"])
    }

    override func tearDownWithError() throws {
        for sandbox in SandboxWorkspaces.list(origin: origin.path) {
            _ = try? SandboxWorkspaces.exit(sandbox, merge: false)
        }
        try? FileManager.default.removeItem(at: origin)
    }

    private func run(_ arguments: [String]) {
        SandboxWorkspaces.git(arguments, in: origin)
    }

    private func write(_ name: String, _ text: String, in directory: URL? = nil) throws {
        try text.write(to: (directory ?? origin).appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    func testEnterCreatesIsolatedWorktreeAndMergeAppliesIt() throws {
        let sandbox = try SandboxWorkspaces.enter(origin: origin.path, name: "Try A")
        XCTAssertEqual(sandbox.name, "try-a")
        XCTAssertNotEqual(sandbox.path, origin.path)

        // Edit inside the sandbox: the origin checkout must not see it yet.
        try write("a.txt", "two\n", in: URL(fileURLWithPath: sandbox.path))
        XCTAssertEqual(try String(contentsOf: origin.appendingPathComponent("a.txt")), "one\n")

        guard case .merged(let commits) = try SandboxWorkspaces.exit(sandbox, merge: true) else {
            return XCTFail("expected merge")
        }
        XCTAssertEqual(commits, 1)
        XCTAssertEqual(try String(contentsOf: origin.appendingPathComponent("a.txt")), "two\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: sandbox.path))
    }

    func testConflictAbortsAndKeepsSandbox() throws {
        let sandbox = try SandboxWorkspaces.enter(origin: origin.path, name: "clash")
        try write("a.txt", "sandbox\n", in: URL(fileURLWithPath: sandbox.path))

        // The origin moves on to a conflicting version, committed so the merge
        // is reached rather than refused for a dirty tree.
        try write("a.txt", "origin\n")
        run(["commit", "-am", "origin edit"])

        guard case .conflicted(let conflict) = try SandboxWorkspaces.exit(sandbox, merge: true) else {
            return XCTFail("expected conflict")
        }
        XCTAssertEqual(conflict.files, ["a.txt"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: sandbox.path))
        // Nothing half-applied: the abort restored the origin's own content.
        XCTAssertEqual(try String(contentsOf: origin.appendingPathComponent("a.txt")), "origin\n")
        XCTAssertTrue(SandboxWorkspaces.git(["status", "--porcelain"], in: origin).text.isEmpty)
    }

    func testMergeRefusedWhileOriginIsDirty() throws {
        let sandbox = try SandboxWorkspaces.enter(origin: origin.path, name: "dirty")
        try write("a.txt", "uncommitted\n")
        XCTAssertThrowsError(try SandboxWorkspaces.exit(sandbox, merge: true))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sandbox.path))
    }

    func testMergeRefusedWhileOriginHasUntrackedChanges() throws {
        let sandbox = try SandboxWorkspaces.enter(origin: origin.path, name: "untracked")
        try write("untracked.txt", "keep me\n")
        XCTAssertThrowsError(try SandboxWorkspaces.exit(sandbox, merge: true))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sandbox.path))
        XCTAssertTrue(SandboxWorkspaces.git(
            ["status", "--porcelain", "--untracked-files=all"],
            in: origin
        ).text.contains("untracked.txt"))
    }

    func testConflictCanBeResolvedInSandboxAndApproved() throws {
        let sandbox = try SandboxWorkspaces.enter(origin: origin.path, name: "resolve")
        try write("a.txt", "sandbox\n", in: URL(fileURLWithPath: sandbox.path))
        try write("a.txt", "origin\n")
        run(["commit", "-am", "origin edit"])

        guard case .conflicted(let conflict) = try SandboxWorkspaces.exit(sandbox, merge: true) else {
            return XCTFail("expected conflict")
        }
        try SandboxWorkspaces.prepareResolution(conflict)
        try write("a.txt", "resolved\n", in: URL(fileURLWithPath: sandbox.path))

        let preview = try SandboxWorkspaces.previewResolution(conflict)
        XCTAssertEqual(preview.files, ["a.txt"])
        XCTAssertTrue(preview.unresolvedFiles.isEmpty)
        XCTAssertTrue(preview.diff.contains("resolved"))

        guard case .merged = try SandboxWorkspaces.applyResolution(
            conflict,
            expectedFingerprint: preview.fingerprint
        ) else {
            return XCTFail("expected approved merge")
        }
        XCTAssertEqual(try String(contentsOf: origin.appendingPathComponent("a.txt")), "resolved\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: sandbox.path))
    }

    func testResolutionWithConflictMarkersCannotBeApproved() throws {
        let sandbox = try SandboxWorkspaces.enter(origin: origin.path, name: "markers")
        try write("a.txt", "sandbox\n", in: URL(fileURLWithPath: sandbox.path))
        try write("a.txt", "origin\n")
        run(["commit", "-am", "origin edit"])

        guard case .conflicted(let conflict) = try SandboxWorkspaces.exit(sandbox, merge: true) else {
            return XCTFail("expected conflict")
        }
        try SandboxWorkspaces.prepareResolution(conflict)
        try write("a.txt", "<<<<<<< HEAD\nbad\n=======\norigin\n>>>>>>> origin\n", in: URL(fileURLWithPath: sandbox.path))
        let preview = try SandboxWorkspaces.previewResolution(conflict)
        XCTAssertEqual(preview.unresolvedFiles, ["a.txt"])
        XCTAssertThrowsError(try SandboxWorkspaces.applyResolution(
            conflict,
            expectedFingerprint: preview.fingerprint
        ))
    }

    func testCancelResolutionAbortsOnlySandboxMerge() throws {
        let sandbox = try SandboxWorkspaces.enter(origin: origin.path, name: "cancel")
        try write("a.txt", "sandbox\n", in: URL(fileURLWithPath: sandbox.path))
        try write("a.txt", "origin\n")
        run(["commit", "-am", "origin edit"])
        let originHead = SandboxWorkspaces.git(["rev-parse", "HEAD"], in: origin).text

        guard case .conflicted(let conflict) = try SandboxWorkspaces.exit(sandbox, merge: true) else {
            return XCTFail("expected conflict")
        }
        try SandboxWorkspaces.prepareResolution(conflict)
        XCTAssertEqual(SandboxWorkspaces.git(["rev-parse", "--verify", "MERGE_HEAD"], in: URL(fileURLWithPath: sandbox.path)).status, 0)
        try SandboxWorkspaces.cancelResolution(conflict)

        XCTAssertEqual(SandboxWorkspaces.git(["rev-parse", "HEAD"], in: origin).text, originHead)
        XCTAssertNotEqual(SandboxWorkspaces.git(["rev-parse", "--verify", "MERGE_HEAD"], in: URL(fileURLWithPath: sandbox.path)).status, 0)
        XCTAssertTrue(SandboxWorkspaces.git(["status", "--porcelain"], in: URL(fileURLWithPath: sandbox.path)).text.isEmpty)
    }

    func testDiscardRemovesWorktreeButKeepsBranch() throws {
        let sandbox = try SandboxWorkspaces.enter(origin: origin.path, name: "throwaway")
        try write("b.txt", "x\n", in: URL(fileURLWithPath: sandbox.path))
        XCTAssertEqual(try SandboxWorkspaces.exit(sandbox, merge: false), .discarded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sandbox.path))
        XCTAssertEqual(SandboxWorkspaces.git(["rev-parse", "--verify", sandbox.branch], in: origin).status, 0)
    }

    func testReenterReturnsTheExistingSandbox() throws {
        let first = try SandboxWorkspaces.enter(origin: origin.path, name: "again")
        let second = try SandboxWorkspaces.enter(origin: origin.path, name: "again")
        XCTAssertEqual(first, second)
        XCTAssertEqual(SandboxWorkspaces.list(origin: origin.path).map(\.name), ["again"])
    }

    func testNonRepositoryIsRefused() throws {
        let plain = origin.appendingPathComponent("plain", isDirectory: true)
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        // A subdirectory of a repo IS a repo, so test somewhere outside it.
        let outside = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SandboxPlain-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        XCTAssertThrowsError(try SandboxWorkspaces.enter(origin: outside.path, name: "x"))
    }
}

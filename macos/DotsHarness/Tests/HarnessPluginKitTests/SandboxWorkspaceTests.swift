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

        guard case .conflicted(let files) = try SandboxWorkspaces.exit(sandbox, merge: true) else {
            return XCTFail("expected conflict")
        }
        XCTAssertEqual(files, ["a.txt"])
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

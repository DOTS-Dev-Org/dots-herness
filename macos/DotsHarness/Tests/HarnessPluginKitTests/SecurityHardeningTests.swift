import Foundation
import XCTest
@testable import DotsHarnessCore

/// Regression tests for the security hardening: a sandboxed agent must not be
/// able to rewrite the git metadata that runs on the user's next command, an
/// update address must be a release address, and the remote gateway must not
/// listen to the network unless the user asked for it.
final class SecurityHardeningTests: XCTestCase {
    private func makeGitDirectory(_ name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("herness-security-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("ref: refs/heads/main\n".utf8).write(to: root.appendingPathComponent("HEAD"))
        try Data("[core]\n".utf8).write(to: root.appendingPathComponent("config"))
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("hooks", isDirectory: true),
            withIntermediateDirectories: true
        )
        return root
    }

    func testGitMetadataHooksAndConfigStayReadOnly() throws {
        let git = try makeGitDirectory("git")
        defer { try? FileManager.default.removeItem(at: git) }

        let protected = SandboxProfile.protectedWritePaths(in: [git])
        let paths = Set(protected.map(\.path))
        XCTAssertTrue(paths.contains(git.appendingPathComponent("hooks").path))
        XCTAssertTrue(paths.contains(git.appendingPathComponent("config").path))
    }

    func testAWorktreeIsNotTreatedAsGitMetadata() throws {
        // A linked worktree's own `.git` is a file pointing at the real
        // directory, so the workspace itself must not be locked down.
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("herness-security-worktree-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try Data("gitdir: /somewhere/.git/worktrees/name\n".utf8)
            .write(to: workspace.appendingPathComponent(".git"))
        defer { try? FileManager.default.removeItem(at: workspace) }

        XCTAssertTrue(SandboxProfile.protectedWritePaths(in: [workspace]).isEmpty)
    }

    func testUpdateAddressMustBeHTTPSOnAReleaseHost() {
        XCTAssertTrue(UpdateChecker.isAllowedDownloadURL(URL(string: "https://dots.net.tr/harness/app.dmg")!))
        XCTAssertTrue(UpdateChecker.isAllowedDownloadURL(URL(string: "https://github.com/DOTS-Dev-Org/dots-herness/releases/latest")!))
        // A hijacked update endpoint must not be able to hand the system a
        // scheme that runs something in the user's name.
        XCTAssertFalse(UpdateChecker.isAllowedDownloadURL(URL(string: "file:///tmp/evil.app")!))
        XCTAssertFalse(UpdateChecker.isAllowedDownloadURL(URL(string: "x-apple-data-detector://evil")!))
        XCTAssertFalse(UpdateChecker.isAllowedDownloadURL(URL(string: "http://dots.net.tr/app.dmg")!))
        XCTAssertFalse(UpdateChecker.isAllowedDownloadURL(URL(string: "https://evil.example/app.dmg")!))
        XCTAssertFalse(UpdateChecker.isAllowedDownloadURL(URL(string: "https://user@dots.net.tr/app.dmg")!))
    }

    func testSafeURLRefusesEverythingButWebAddresses() {
        XCTAssertFalse(SafeURL.canOpenWeb(URL(string: "file:///etc/passwd")!))
        XCTAssertFalse(SafeURL.canOpenWeb(URL(string: "x-apple-data-detector://evil")!))
        XCTAssertFalse(SafeURL.canOpenWeb(URL(string: "javascript:alert(1)")!))
        XCTAssertFalse(SafeURL.canOpenWeb(URL(string: "https://user:pass@example.com")!))
        XCTAssertTrue(SafeURL.canOpenWeb(URL(string: "https://dots.net.tr/harness")!))
    }

    func testSafeURLFileNeedsAnAllowedRoot() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("herness-security-root-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let inside = root.appendingPathComponent("inside.txt")
        try? Data("x".utf8).write(to: inside)
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("herness-security-outside-\(UUID().uuidString).txt")
        try? Data("x".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }

        XCTAssertTrue(SafeURL.canOpenFile(inside, allowedRoots: [root]))
        XCTAssertFalse(SafeURL.canOpenFile(outside, allowedRoots: [root]))
        XCTAssertFalse(SafeURL.canOpenFile(URL(string: "https://dots.net.tr/x")!, allowedRoots: [root]))
    }
}

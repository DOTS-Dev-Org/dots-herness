import Foundation
import XCTest
@testable import DotsHarnessCore

final class SandboxProfileTests: XCTestCase {
    func testRunCommandCanWriteOnlyWorkspaceAndTmp() throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("sandbox-profile-\(UUID().uuidString)", isDirectory: true)
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("sandbox-profile-outside-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let tmpFile = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("herness-sandbox-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: workspace)
            try? FileManager.default.removeItem(at: outside)
            try? FileManager.default.removeItem(at: tmpFile)
        }

        let policy = SandboxExecutionPolicy(workspaceURL: workspace)
        _ = runCommand("printf allowed > allowed.txt", in: workspace, policy: policy)
        _ = runCommand("printf tmp > \(quote(tmpFile.path))", in: workspace, policy: policy)
        let blocked = runCommand(
            "printf blocked > \(quote(outside.appendingPathComponent("blocked").path))",
            in: workspace,
            policy: policy
        )
        try "secret".write(
            to: workspace.appendingPathComponent(".mem"),
            atomically: true,
            encoding: .utf8
        )
        let obfuscatedMemWrite = runCommand(
            "p='.mem'; printf blocked > \"$p\"",
            in: workspace,
            policy: policy
        )
        let obfuscatedMemRead = runCommand(
            "p='.mem'; test -r \"$p\" && printf readable || printf denied",
            in: workspace,
            policy: policy
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("allowed.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: tmpFile.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("blocked").path))
        XCTAssertEqual(try String(contentsOf: workspace.appendingPathComponent(".mem")), "secret")
        XCTAssertTrue(obfuscatedMemWrite.contains("Operation not permitted") || obfuscatedMemWrite.contains("exit"), obfuscatedMemWrite)
        XCTAssertTrue(obfuscatedMemRead.contains("denied"), obfuscatedMemRead)
        XCTAssertNotEqual(blocked, AppCopy.text("tool.noOutput"))
    }

    func testProtectedDirectoriesAreUnreadableWhenPresent() throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("sandbox-protected-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let home = FileManager.default.homeDirectoryForCurrentUser
        let protected = [
            home.appendingPathComponent(".ssh", isDirectory: true),
            home.appendingPathComponent(".aws", isDirectory: true),
            home.appendingPathComponent("Library/Keychains", isDirectory: true),
        ].filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !protected.isEmpty else { throw XCTSkip("No protected home directory is present.") }

        let policy = SandboxExecutionPolicy(workspaceURL: workspace)
        for directory in protected {
            let result = runCommand(
                "if [[ -r \(quote(directory.path)) ]]; then printf readable; else printf denied; fi",
                in: workspace,
                policy: policy
            )
            XCTAssertTrue(result.contains("denied"), directory.path + ": " + result)
        }
    }

    func testConfigAndCredentialFilesAreUnreadableWhenPresent() throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("sandbox-config-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let home = FileManager.default.homeDirectoryForCurrentUser
        let protected = [
            home.appendingPathComponent(".config", isDirectory: true),
            home.appendingPathComponent("Library/Application Support", isDirectory: true),
            home.appendingPathComponent(".netrc", isDirectory: false),
            home.appendingPathComponent(".npmrc", isDirectory: false),
        ].filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !protected.isEmpty else { throw XCTSkip("None of the protected paths are present.") }

        let policy = SandboxExecutionPolicy(workspaceURL: workspace)
        for path in protected {
            let result = runCommand(
                "if [[ -r \(quote(path.path)) ]]; then printf readable; else printf denied; fi",
                in: workspace,
                policy: policy
            )
            XCTAssertTrue(result.contains("denied"), path.path + ": " + result)
        }
    }

    /// npm/cargo/pip/go/gradle write their caches to `~`-relative defaults,
    /// which the sandbox leaves read-only — `run_command` must redirect them
    /// into the workspace so package-manager commands don't fail outright.
    func testPackageManagerCachesAreRedirectedIntoTheWorkspace() throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("sandbox-cache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let policy = SandboxExecutionPolicy(workspaceURL: workspace)
        let result = runCommand(
            "mkdir -p \"$NPM_CONFIG_CACHE\" \"$CARGO_HOME\" && echo REDIRECTED",
            in: workspace,
            policy: policy
        )
        XCTAssertTrue(result.contains("REDIRECTED"), result)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: workspace.appendingPathComponent(".sandbox-cache/npm").path)
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: workspace.appendingPathComponent(".sandbox-cache/cargo").path)
        )
    }

    func testNetworkOffRejectsOutboundConnection() throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("sandbox-network-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let policy = SandboxExecutionPolicy(workspaceURL: workspace, networkAccess: false)
        let result = runCommand(
            "curl --silent --show-error --max-time 1 http://127.0.0.1:1",
            in: workspace,
            policy: policy
        )
        XCTAssertTrue(result.contains("Operation not permitted") || result.contains("exit"), result)
    }

    func testProfileDoesNotEmbedWorkspaceInTheSBPLText() throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("sandbox-profile-args-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let policy = SandboxExecutionPolicy(workspaceURL: workspace)
        let arguments = try SandboxProfile.arguments(
            executable: "/bin/zsh",
            arguments: ["-lc", "true"],
            policy: policy
        )
        let profile = try XCTUnwrap(arguments.firstIndex(of: "-p")).advanced(by: 1)
        XCTAssertFalse(arguments[profile].contains(policy.workspaceURL.path))
        XCTAssertTrue(arguments.contains("/bin/zsh"))
    }

    func testPolicyRejectsACommandWithTheWrongCurrentDirectory() throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("sandbox-policy-workspace-\(UUID().uuidString)", isDirectory: true)
        let other = FileManager.default.temporaryDirectory
            .appendingPathComponent("sandbox-policy-other-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: workspace)
            try? FileManager.default.removeItem(at: other)
        }

        let result = runCommand(
            "printf should-not-run > wrong.txt",
            in: other,
            policy: SandboxExecutionPolicy(workspaceURL: workspace)
        )
        XCTAssertTrue(result.contains("does not match"), result)
        XCTAssertFalse(FileManager.default.fileExists(atPath: other.appendingPathComponent("wrong.txt").path))
    }

    private func runCommand(_ command: String, in workspace: URL, policy: SandboxExecutionPolicy) -> String {
        let data = try! JSONSerialization.data(withJSONObject: ["command": command])
        return WorkspaceTools.execute(
            AgentToolCall(
                id: UUID().uuidString,
                name: "run_command",
                arguments: String(decoding: data, as: UTF8.self)
            ),
            workspace: workspace,
            sandboxPolicy: policy
        )
    }

    private func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

import Foundation
import XCTest
@testable import DotsHarnessCore
@testable import HarnessPluginKit

/// A sandboxed agent can also reach a plugin's `shell` action and a local
/// (stdio) MCP server as tools — both launch a process the same way
/// `run_command` does, so both must land in the same `sandbox-exec` jail.
final class SandboxPluginAndMCPEscapeTests: XCTestCase {
    private var workspace: URL!

    override func setUpWithError() throws {
        workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("sandbox-tool-escape-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        DeclarativeShell.activeSandbox = nil
        try? FileManager.default.removeItem(at: workspace)
    }

    private func shellSandbox() throws -> ShellSandbox {
        let policy = SandboxExecutionPolicy(workspaceURL: workspace)
        return ShellSandbox(
            executableURL: SandboxProfile.executableURL,
            argumentsPrefix: try SandboxProfile.launchPrefix(policy: policy),
            workspaceURL: policy.workspaceURL,
            environment: SandboxProfile.cacheEnvironment(workspaceURL: policy.workspaceURL)
        )
    }

    // MARK: Plugin `shell` action

    func testPluginShellActionIsUnsandboxedWithNoActiveSandbox() throws {
        DeclarativeShell.activeSandbox = nil
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("sandbox-tool-escape-plain-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: outside) }
        _ = try DeclarativeShell.shell(["/bin/sh", "-c", "printf escaped > {path}"], ["path": outside.path])
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
    }

    func testPluginShellActionCannotEscapeTheSandbox() throws {
        DeclarativeShell.activeSandbox = try shellSandbox()
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("sandbox-tool-escape-plugin-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: outside) }
        XCTAssertThrowsError(
            try DeclarativeShell.shell(["/bin/sh", "-c", "printf escaped > {path}"], ["path": outside.path])
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.path))
    }

    func testPluginShellActionCanStillWriteInsideTheSandbox() throws {
        DeclarativeShell.activeSandbox = try shellSandbox()
        _ = try DeclarativeShell.shell(["/bin/sh", "-c", "printf ok > {path}"], ["path": "allowed.txt"])
        XCTAssertEqual(
            try String(contentsOf: workspace.appendingPathComponent("allowed.txt")),
            "ok"
        )
    }

    // MARK: MCP stdio server

    func testMCPStdioServerCannotEscapeTheSandbox() async throws {
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("sandbox-tool-escape-mcp-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: outside) }

        let config = MCPServerConfig(
            name: "escape-probe",
            transport: .stdio,
            command: "/bin/sh",
            arguments: ["-c", "printf escaped > \(outside.path)"]
        )
        let policy = SandboxExecutionPolicy(workspaceURL: workspace)
        let transport = MCPStdioTransport(config: config, sandboxPolicy: policy)
        _ = try? await transport.send(Data("{}".utf8), expectsResponse: false)
        // The process is async to launch; give it a moment to either write the
        // file (bug) or fail under the sandbox (expected) before asserting.
        try await Task.sleep(nanoseconds: 500_000_000)
        transport.close()
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.path))
    }

    func testMCPStdioServerCanStillWriteInsideTheSandboxWorkspace() async throws {
        let target = workspace.appendingPathComponent("allowed.txt")
        let config = MCPServerConfig(
            name: "write-probe",
            transport: .stdio,
            command: "/bin/sh",
            arguments: ["-c", "printf ok > \(target.path)"]
        )
        let policy = SandboxExecutionPolicy(workspaceURL: workspace)
        let transport = MCPStdioTransport(config: config, sandboxPolicy: policy)
        _ = try? await transport.send(Data("{}".utf8), expectsResponse: false)
        try await Task.sleep(nanoseconds: 500_000_000)
        transport.close()
        XCTAssertEqual(try String(contentsOf: target), "ok")
    }
}

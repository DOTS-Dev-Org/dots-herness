// Copyright (c) 2026 DOTS

import XCTest
import Foundation
import HarnessPluginKit
import PluginRuntime
@testable import DotsHarnessCore

/// Canned JSON-RPC endpoint: answers initialize / tools/list / tools/call.
private final class StubMCPTransport: MCPRawTransport, @unchecked Sendable {
    var lastCallArguments: [String: Any]?
    var fail = false
    var emptyTools = false

    func send(_ request: Data, expectsResponse: Bool) async throws -> Data? {
        if fail { throw MCPError.notConnected }
        let object = try JSONSerialization.jsonObject(with: request) as? [String: Any] ?? [:]
        let method = object["method"] as? String ?? ""
        let id = object["id"] as? Int ?? 0
        if !expectsResponse { return nil }

        let result: [String: Any]
        switch method {
        case "initialize":
            result = ["serverInfo": ["name": "stub"], "capabilities": ["tools": [:]]]
        case "tools/list":
            result = ["tools": emptyTools ? [] : [
                ["name": "search", "description": "search docs",
                 "inputSchema": ["type": "object", "properties": ["q": ["type": "string"]]],
                 "annotations": ["readOnlyHint": true, "destructiveHint": false]],
                ["name": "wipe", "description": "delete everything",
                 "inputSchema": ["type": "object"],
                 "annotations": ["destructiveHint": true]],
            ]]
        case "tools/call":
            lastCallArguments = (object["params"] as? [String: Any])?["arguments"] as? [String: Any]
            result = ["content": [["type": "text", "text": "ok"]]]
        default:
            result = [:]
        }
        return try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "result": result])
    }

    func close() {}
}

final class MCPAndToolBridgeTests: XCTestCase {

    // MARK: Faz 2 — MCP

    func testMCPClientDiscoversAndCallsTools() async throws {
        let stub = StubMCPTransport()
        let client = MCPClient(config: MCPServerConfig(name: "stub")) { _ in stub }
        try await client.connect()

        let tools = await client.tools
        XCTAssertEqual(tools.map(\.name).sorted(), ["search", "wipe"])
        XCTAssertTrue(tools.first { $0.name == "search" }?.readOnlyHint == true)

        let output = try await client.callTool("search", arguments: .object(["q": .string("hi")]))
        XCTAssertEqual(output, "ok")
        XCTAssertEqual(stub.lastCallArguments?["q"] as? String, "hi")
    }

    @MainActor
    func testMCPRegistryNamespacesToolsAndGatesAutoRun() async {
        let store = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-\(UUID().uuidString).json")
        let registry = MCPRegistry(storeURL: store)
        registry.transportOverride = { _ in StubMCPTransport() }
        var config = MCPServerConfig(name: "Docs Server", autoRunReadOnly: true)
        registry.upsert(config)
        await registry.connect(config.id)

        let names = registry.toolDefinitions().map(\.name).sorted()
        XCTAssertEqual(names, ["mcp__Docs_Server__search", "mcp__Docs_Server__wipe"])

        // read-only + server opted in -> may skip approval
        XCTAssertTrue(registry.shouldAutoRun("mcp__Docs_Server__search"))
        // destructive hint -> never auto-run, even with opt-in
        XCTAssertFalse(registry.shouldAutoRun("mcp__Docs_Server__wipe"))

        config.autoRunReadOnly = false
        registry.upsert(config)
        await registry.connect(config.id)
        XCTAssertFalse(registry.shouldAutoRun("mcp__Docs_Server__search"))
    }

    /// `sandbox-exec` wraps process launch — it cannot wrap an HTTP MCP
    /// server, which is just a network call the app makes on its own. The
    /// sandbox's network toggle is the only real stop for that, so it must
    /// refuse HTTP tools immediately while preserving their cached definitions.
    @MainActor
    func testSandboxWithNetworkOffPreservesDefinitionsAndRefusesHTTPMCPTools() async throws {
        let store = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-\(UUID().uuidString).json")
        let registry = MCPRegistry(storeURL: store)
        registry.transportOverride = { _ in StubMCPTransport() }
        let config = MCPServerConfig(name: "Docs Server", transport: .http)
        registry.upsert(config)
        await registry.connect(config.id)
        XCTAssertEqual(registry.toolDefinitions().map(\.name).sorted(), ["mcp__Docs_Server__search", "mcp__Docs_Server__wipe"])

        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-sandbox-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        registry.setSandboxPolicy(SandboxExecutionPolicy(workspaceURL: workspace, networkAccess: false))

        XCTAssertEqual(registry.toolDefinitions().map(\.name).sorted(), ["mcp__Docs_Server__search", "mcp__Docs_Server__wipe"])
        XCTAssertFalse(registry.isAvailable("mcp__Docs_Server__search"))
        do {
            _ = try await registry.call("mcp__Docs_Server__search", arguments: .object(["q": .string("hi")]))
            XCTFail("expected the HTTP tool call to be refused")
        } catch {
            // Refused, as expected.
        }

        // Turning network back on restores it.
        registry.setSandboxPolicy(SandboxExecutionPolicy(workspaceURL: workspace, networkAccess: true))
        XCTAssertEqual(registry.toolDefinitions().map(\.name).sorted(), ["mcp__Docs_Server__search", "mcp__Docs_Server__wipe"])
    }

    @MainActor
    func testLastAcceptedCatalogSurvivesFailureDisconnectAndRestartButNotAuthoritativeRemoval() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = folder.appendingPathComponent("mcp.json")
        let registry = MCPRegistry(storeURL: store)
        let stub = StubMCPTransport()
        registry.transportOverride = { _ in stub }
        let config = MCPServerConfig(name: "Docs Server")
        registry.upsert(config)
        await registry.connect(config.id)
        let accepted = registry.toolDefinitions()
        XCTAssertEqual(accepted.count, 2)
        stub.fail = true
        await registry.connect(config.id)
        XCTAssertEqual(registry.toolDefinitions(), accepted)
        XCTAssertFalse(registry.isAvailable(accepted[0].name))
        await registry.disconnectAll()
        XCTAssertEqual(registry.toolDefinitions(), accepted)
        let restored = MCPRegistry(storeURL: store)
        XCTAssertEqual(restored.toolDefinitions(), accepted)
        XCTAssertFalse(restored.isAvailable(accepted[0].name))
        stub.fail = false
        stub.emptyTools = true
        await registry.connect(config.id)
        XCTAssertTrue(registry.toolDefinitions().isEmpty)
        registry.remove(config.id)
        XCTAssertTrue(registry.toolDefinitions().isEmpty)
    }

    func testMCPToolClassifiedAsSideEffect() {
        XCTAssertEqual(NativeAgentHost.risk("mcp__docs__search"), .sideEffect)
        XCTAssertTrue(NativeAgentHost.requiresApproval(mode: .safe, toolName: "mcp__docs__search"))
        XCTAssertFalse(NativeAgentHost.requiresApproval(mode: .full, toolName: "mcp__docs__search"))
    }

    // MARK: Faz 3 — plugin bridge helpers

    func testToolNameSanitizerAndArgumentFlattening() {
        XCTAssertEqual(NativeAgentHost.sanitizeToolName("weather.lookup now"), "weather_lookup_now")
        let flat = NativeAgentHost.stringArguments(#"{"a":"x","b":2,"c":{"d":1}}"#)
        XCTAssertEqual(flat["a"], "x")
        XCTAssertEqual(flat["b"], "2")
        XCTAssertEqual(flat["c"], #"{"d":1}"#)
    }

    // MARK: Faz 4 — agent terminal sessions

    @MainActor
    func testAgentTerminalSessionsAreScopedToTheirConversation() throws {
        let paths = temporaryPaths()
        let workspace = paths.root.appendingPathComponent("term-project", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        let host = NativeAgentHost(
            paths: paths,
            endpoint: AgentEndpointController(baseURL: "http://term.test", modelID: "test-model")
        )

        func call(_ args: String) -> AgentToolCall {
            AgentToolCall(id: UUID().uuidString, name: TerminalSessionTool.name, arguments: args)
        }

        let started = host.agentTerminal(call(#"{"action":"start"}"#), conversationID: "A", workspace: workspace)
        XCTAssertTrue(started.hasPrefix("Started session "))
        let sessionID = started
            .replacingOccurrences(of: "Started session ", with: "")
            .components(separatedBy: ".").first ?? ""

        // Conversation B cannot see or touch A's session.
        XCTAssertEqual(host.agentTerminal(call(#"{"action":"list"}"#), conversationID: "B", workspace: workspace),
                       "No agent terminal sessions.")
        let readFromB = host.agentTerminal(
            call(#"{"action":"read","session_id":"\#(sessionID)"}"#),
            conversationID: "B", workspace: workspace
        )
        XCTAssertTrue(readFromB.contains("unknown session_id"))

        // A sees its own.
        XCTAssertTrue(host.agentTerminal(call(#"{"action":"list"}"#), conversationID: "A", workspace: workspace)
            .contains(sessionID))

        host.stopAllAgentTerminals()
        XCTAssertTrue(host.agentTerminals.isEmpty)
    }

    @MainActor
    func testBackgroundTaskExitQueuesAWakeUpForItsConversation() async throws {
        let paths = temporaryPaths()
        let workspace = paths.root.appendingPathComponent("task-project", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let host = NativeAgentHost(
            paths: paths,
            endpoint: AgentEndpointController(baseURL: "http://term.test", modelID: "test-model")
        )
        // Not selected, so the wake-up stays queued instead of starting a run.
        host.conversations.append(Conversation(id: "A", cwd: workspace.path))

        let started = host.agentTerminal(
            AgentToolCall(
                id: "1", name: TerminalSessionTool.name,
                arguments: #"{"action":"start","command":"sh -c 'exit 3'","description":"failing build"}"#
            ),
            conversationID: "A", workspace: workspace
        )
        XCTAssertTrue(started.hasPrefix("Started background task "), started)
        let session = try XCTUnwrap(host.agentTerminals["A"]?.first)

        for _ in 0..<200 where session.isRunning { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(session.exitCode, 3)
        XCTAssertNotNil(session.endedAt)
        let queued = try XCTUnwrap(host.conversations.first { $0.id == "A" }?.pendingPrompts.first)
        XCTAssertTrue(queued.text.contains("failing build") && queued.text.contains(session.id.uuidString), queued.text)

        // A task the user stops does not wake the agent.
        host.conversations[0].pendingPrompts = []
        _ = host.agentTerminal(
            AgentToolCall(id: "2", name: TerminalSessionTool.name, arguments: #"{"action":"start","command":"sleep 30"}"#),
            conversationID: "A", workspace: workspace
        )
        let sleeper = try XCTUnwrap(host.agentTerminals["A"]?.last)
        sleeper.stop()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(sleeper.exitCode)
        XCTAssertTrue(host.conversations[0].pendingPrompts.isEmpty)
        host.stopAllAgentTerminals()
    }

    private func temporaryPaths() -> SupportPaths {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DotsHarnessTests-\(UUID().uuidString)", isDirectory: true)
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

    @MainActor
    func testTerminalSessionApprovalGating() {
        XCTAssertTrue(TerminalSessionTool.actionRequiresApproval("start"))
        XCTAssertTrue(TerminalSessionTool.actionRequiresApproval("send"))
        XCTAssertFalse(TerminalSessionTool.actionRequiresApproval("read"))
        XCTAssertFalse(TerminalSessionTool.actionRequiresApproval("list"))
        XCTAssertFalse(TerminalSessionTool.actionRequiresApproval("stop"))
    }
}

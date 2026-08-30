// Copyright (c) 2026 DOTS

import XCTest
import Foundation
import HarnessPluginKit
import PluginRuntime
@testable import DotsHarnessCore

/// Canned JSON-RPC endpoint: answers initialize / tools/list / tools/call.
private final class StubMCPTransport: MCPRawTransport, @unchecked Sendable {
    var lastCallArguments: [String: Any]?

    func send(_ request: Data, expectsResponse: Bool) async throws -> Data? {
        let object = try JSONSerialization.jsonObject(with: request) as? [String: Any] ?? [:]
        let method = object["method"] as? String ?? ""
        let id = object["id"] as? Int ?? 0
        if !expectsResponse { return nil }

        let result: [String: Any]
        switch method {
        case "initialize":
            result = ["serverInfo": ["name": "stub"], "capabilities": ["tools": [:]]]
        case "tools/list":
            result = ["tools": [
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

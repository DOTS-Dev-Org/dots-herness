// Copyright (c) 2026 DOTS
// Tracks configured MCP servers, their connection state, and the tools they
// expose to the agent loop. Non-secret config lives in a JSON file next to the
// other app state; bearer tokens live in the Keychain (see MCPKeychain).

import Foundation
import HarnessPluginKit
import PluginRuntime

@MainActor
public final class MCPRegistry: ObservableObject {
    public enum ServerState: Equatable, Sendable {
        case idle
        case connecting
        case connected(toolCount: Int)
        case failed(String)
    }

    public struct ServerStatus: Identifiable, Sendable {
        public var id: String
        public var name: String
        public var state: MCPRegistry.ServerState
    }

    @Published public private(set) var servers: [MCPServerConfig] = []
    @Published public private(set) var states: [String: ServerState] = [:]

    private let storeURL: URL
    private var clients: [String: MCPClient] = [:]
    /// Test seam: when set, `connect` builds clients with this transport.
    var transportOverride: (@Sendable (MCPServerConfig) -> MCPRawTransport)?
    /// exposed tool name -> routing info
    private var routes: [String: Route] = [:]

    private struct Route: Codable {
        var serverID: String
        var toolName: String
        var transport: MCPTransportKind
        var readOnlyHint: Bool
        var destructiveHint: Bool
        var autoRunReadOnly: Bool
        var schema: JSONValue
        var description: String
    }

    /// A sandboxed local (stdio) process is jailed by `sandbox-exec`, but an
    /// HTTP MCP server is a plain network call the app makes on its own — the
    /// process sandbox cannot wrap it. Turning the sandbox's network access
    /// off is the only way to actually stop it, so that toggle also hides
    /// (and refuses) HTTP-transport tools, not just stdio ones.
    private var networkBlocked: Bool { sandboxPolicy != nil && sandboxPolicy?.networkAccess == false }

    public init(storeURL: URL) {
        self.storeURL = storeURL
        load()
        loadCatalog()
    }

    public convenience init(paths: SupportPaths) {
        self.init(storeURL: paths.root.appendingPathComponent("mcp-servers.json"))
    }

    // MARK: Config

    public func upsert(_ config: MCPServerConfig, token: String? = nil) {
        if let index = servers.firstIndex(where: { $0.id == config.id }) {
            servers[index] = config
        } else {
            servers.append(config)
        }
        if let token { MCPKeychain.setToken(token, for: config.id) }
        persist()
    }

    public func remove(_ serverID: String) {
        servers.removeAll { $0.id == serverID }
        states[serverID] = nil
        MCPKeychain.setToken(nil, for: serverID)
        if let client = clients.removeValue(forKey: serverID) {
            Task { await client.disconnect() }
        }
        routes = routes.filter { $0.value.serverID != serverID }
        persistCatalog()
        persist()
    }

    public func token(for serverID: String) -> String? { MCPKeychain.token(for: serverID) }

    public var statuses: [ServerStatus] {
        servers.map { ServerStatus(id: $0.id, name: $0.name, state: states[$0.id] ?? .idle) }
    }

    // MARK: Connection

    /// Connects every enabled server. Failures are recorded per server and never
    /// throw; a server that will not connect simply contributes no tools.
    public func connectAll() async {
        await withTaskGroup(of: Void.self) { group in
            for config in servers where config.enabled {
                group.addTask { await self.connect(config.id) }
            }
        }
    }

    /// The agent's active sandbox, mirrored here so a stdio MCP server (a
    /// local process the agent can drive, same as `run_command`) launches
    /// inside the same jail. Set by `AgentBridge.setSandboxPolicy`.
    @Published public private(set) var sandboxPolicy: SandboxExecutionPolicy?

    /// `sandbox-exec` wraps process *launch*, so a server already running
    /// unsandboxed stays that way until restarted — reconnect every currently
    /// connected stdio server so the new policy actually takes effect.
    public func setSandboxPolicy(_ policy: SandboxExecutionPolicy?) {
        guard sandboxPolicy != policy else { return }
        sandboxPolicy = policy
        let stdioServerIDs = servers
            .filter { $0.transport == .stdio && clients[$0.id] != nil }
            .map(\.id)
        guard !stdioServerIDs.isEmpty else { return }
        Task {
            for id in stdioServerIDs {
                if let client = clients.removeValue(forKey: id) { await client.disconnect() }
                await connect(id)
            }
        }
    }

    public func connect(_ serverID: String) async {
        guard let config = servers.first(where: { $0.id == serverID }) else { return }
        states[serverID] = .connecting
        let client = MCPClient(config: config, transportFactory: transportOverride, sandboxPolicy: sandboxPolicy)
        do {
            try await client.connect()
            let tools = await client.tools
            clients[serverID] = client
            registerRoutes(for: config, tools: tools)
            states[serverID] = .connected(toolCount: tools.count)
        } catch {
            states[serverID] = .failed(String(describing: error))
            // A failed connection is not an authoritative empty tools/list.
            // Keep the last accepted definitions, but deny execution.
            if let old = clients.removeValue(forKey: serverID) { await old.disconnect() }
        }
    }

    public func disconnectAll() async {
        // Each client is its own actor, and closing a stdio transport waits on the
        // server process — so shutting them down one by one made a reload pay for
        // every server in turn.
        let closing = Array(clients.values)
        clients.removeAll()
        // Definitions survive a temporary disconnect; clients do not.
        for id in states.keys { states[id] = .idle }
        await withTaskGroup(of: Void.self) { group in
            for client in closing { group.addTask { await client.disconnect() } }
        }
    }

    /// Connect once, report tool count or the failure reason, then drop it.
    public func test(_ config: MCPServerConfig) async -> (toolCount: Int?, error: String?) {
        let client = MCPClient(config: config)
        do {
            try await client.connect()
            let count = await client.tools.count
            await client.disconnect()
            return (count, nil)
        } catch {
            await client.disconnect()
            return (nil, String(describing: error))
        }
    }

    private func registerRoutes(for config: MCPServerConfig, tools: [MCPToolInfo]) {
        routes = routes.filter { $0.value.serverID != config.id }
        let serverSlug = NativeAgentHost.sanitizeToolName(config.name.isEmpty ? config.id : config.name)
        for tool in tools {
            let exposed = "mcp__\(serverSlug)__\(NativeAgentHost.sanitizeToolName(tool.name))"
            routes[exposed] = Route(
                serverID: config.id,
                toolName: tool.name,
                transport: config.transport,
                readOnlyHint: tool.readOnlyHint,
                destructiveHint: tool.destructiveHint,
                autoRunReadOnly: config.autoRunReadOnly,
                schema: tool.inputSchema,
                description: tool.description
            )
        }
        persistCatalog()
    }

    // MARK: Agent integration

    public func toolDefinitions() -> [AgentToolDefinition] {
        routes
            .filter { route in servers.contains { $0.id == route.value.serverID } }
            .map { name, route in
                AgentToolDefinition(name: name, description: route.description, parameters: route.schema)
            }
            .sorted { $0.name < $1.name }
    }

    public func isMCPTool(_ name: String) -> Bool { routes[name] != nil }

    public func isAvailable(_ name: String) -> Bool {
        guard let route = routes[name],
              let config = servers.first(where: { $0.id == route.serverID }), config.enabled,
              clients[route.serverID] != nil,
              case .connected = states[route.serverID],
              !(networkBlocked && route.transport == .http) else { return false }
        return true
    }

    func bindingIdentity(_ name: String) -> String? {
        guard let route = routes[name], let config = servers.first(where: { $0.id == route.serverID }) else { return nil }
        // A fingerprint detects real rebinding without persisting endpoint secrets.
        return AgentCacheTrace.fingerprint([route.serverID, route.toolName, config.transport.rawValue,
            config.url, config.command, config.arguments.joined(separator: "\u{0}")].joined(separator: "\u{0}"))
    }

    /// A tool may skip the approval prompt only when its server opted in AND the
    /// server advertised the tool as read-only AND it is not flagged destructive.
    public func shouldAutoRun(_ name: String) -> Bool {
        guard isAvailable(name), let route = routes[name],
              let config = servers.first(where: { $0.id == route.serverID }) else { return false }
        return config.autoRunReadOnly && route.readOnlyHint && !route.destructiveHint
    }

    public func call(_ name: String, arguments: JSONValue) async throws -> String {
        guard let route = routes[name] else { throw MCPError.notConnected }
        // Same rule as `toolDefinitions`, enforced again here: the tool list
        // is a snapshot the model may still be holding from before the
        // network toggle changed.
        guard !(networkBlocked && route.transport == .http) else {
            throw MCPError.transport("Sandbox network access is off; HTTP MCP tools are unavailable.")
        }
        guard isAvailable(name), let client = clients[route.serverID] else { throw MCPError.notConnected }
        return try await client.callTool(route.toolName, arguments: arguments)
    }

    // MARK: Persistence

    private var catalogURL: URL { storeURL.deletingPathExtension().appendingPathExtension("catalog.json") }

    private func loadCatalog() {
        guard let data = try? Data(contentsOf: catalogURL),
              let saved = try? JSONDecoder().decode([String: Route].self, from: data) else { return }
        routes = saved.filter { entry in servers.contains { $0.id == entry.value.serverID } }
    }

    private func persistCatalog() {
        guard let data = try? JSONEncoder().encode(routes) else { return }
        try? FileManager.default.createDirectory(at: catalogURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: catalogURL, options: .atomic)
    }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let decoded = try? JSONDecoder().decode([MCPServerConfig].self, from: data) else { return }
        servers = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(servers) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }
}

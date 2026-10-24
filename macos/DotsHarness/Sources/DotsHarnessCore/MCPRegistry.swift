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
        /// HTTP 401 with no usable grant; `signIn` runs the OAuth flow.
        case needsAuthorization
    }

    /// A server-initiated request waiting for the user (sampling or elicitation).
    public struct Interaction: Identifiable, Sendable {
        public enum Kind: Sendable { case sampling, elicitation }
        public let id = UUID()
        public let serverName: String
        public let kind: Kind
        public let params: JSONValue
    }

    /// The user's answer to an `Interaction`.
    public enum InteractionAnswer: Sendable {
        case approve
        case decline
        case cancel
        /// Elicitation form values.
        case accept([String: JSONValue])
    }

    public struct ServerStatus: Identifiable, Sendable {
        public var id: String
        public var name: String
        public var state: MCPRegistry.ServerState
    }

    @Published public private(set) var servers: [MCPServerConfig] = []
    @Published public private(set) var states: [String: ServerState] = [:]
    /// Oldest first; the UI presents `interactions.first`.
    @Published public private(set) var interactions: [Interaction] = []
    /// Recent `notifications/message` log lines, newest last.
    @Published public private(set) var logLines: [String] = []
    /// Workspace roots answered to `roots/list`. Set by AppModel.
    public private(set) var roots: [URL] = []
    /// Runs an approved sampling request: (system prompt, messages, maxTokens)
    /// -> (text, model). Set by AppModel; nil leaves sampling unadvertised.
    public var sampler: (@MainActor (String, [AgentMessage], Int) async throws -> (text: String, model: String))?
    private var waiting: [UUID: CheckedContinuation<InteractionAnswer, Never>] = [:]
    private var challenges: [String: String] = [:]

    private let storeURL: URL
    private var clients: [String: MCPClient] = [:]
    /// Test seam: when set, `connect` builds clients with this transport.
    var transportOverride: (@Sendable (MCPServerConfig) -> MCPRawTransport)?
    /// exposed tool name -> routing info
    private var routes: [String: Route] = [:]
    private(set) var toolDefinitionsRevision: UInt64 = 0
    private var cachedToolDefinitions: [AgentToolDefinition]?
    private(set) var lastToolDefinitionsCacheHit = false

    private func invalidateToolDefinitions() {
        toolDefinitionsRevision &+= 1
        cachedToolDefinitions = nil
    }

    enum RouteKind: String, Codable { case tool, listResources, readResource, listPrompts, getPrompt }

    private struct Route: Codable {
        /// nil in catalogs written before resources/prompts existed = `.tool`.
        var kind: RouteKind?
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
        invalidateToolDefinitions()
        persist()
    }

    public func remove(_ serverID: String) {
        servers.removeAll { $0.id == serverID }
        states[serverID] = nil
        MCPKeychain.setToken(nil, for: serverID)
        MCPOAuth.save(nil, serverID: serverID)
        if let client = clients.removeValue(forKey: serverID) {
            Task { await client.disconnect() }
        }
        routes = routes.filter { $0.value.serverID != serverID }
        invalidateToolDefinitions()
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
        // ponytail: three at a time, so many servers do not all spawn at startup; raise if
        // a long list connects too slowly.
        let ids = servers.filter(\.enabled).map(\.id)
        await withTaskGroup(of: Void.self) { group in
            for (index, id) in ids.enumerated() {
                if index >= 3 { await group.next() }
                group.addTask { await self.connect(id) }
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
        let client = MCPClient(config: config, hooks: hooks(), transportFactory: transportOverride, sandboxPolicy: sandboxPolicy)
        do {
            try await client.connect()
            let tools = await client.tools
            clients[serverID] = client
            await registerRoutes(for: config, tools: tools, client: client)
            states[serverID] = .connected(toolCount: tools.count)
        } catch MCPError.unauthorized(let challenge) {
            challenges[serverID] = challenge ?? ""
            states[serverID] = .needsAuthorization
            await client.disconnect()
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

    private func registerRoutes(for config: MCPServerConfig, tools: [MCPToolInfo], client: MCPClient) async {
        routes = routes.filter { $0.value.serverID != config.id }
        let serverSlug = NativeAgentHost.sanitizeToolName(config.name.isEmpty ? config.id : config.name)
        func synthetic(_ name: String, _ kind: RouteKind, _ description: String, _ properties: [String: JSONValue], required: [String]) {
            routes["mcp__\(serverSlug)__\(name)"] = Route(
                kind: kind, serverID: config.id, toolName: name, transport: config.transport,
                readOnlyHint: true, destructiveHint: false, autoRunReadOnly: config.autoRunReadOnly,
                schema: .object(["type": .string("object"), "properties": .object(properties),
                                 "required": .array(required.map(JSONValue.string))]),
                description: "[\(config.name)] " + description
            )
        }
        let text: JSONValue = .object(["type": .string("string")])
        if await client.supportsResources {
            synthetic("mcp_list_resources", .listResources, "List the resources and resource templates this MCP server exposes.", [:], required: [])
            synthetic("mcp_read_resource", .readResource, "Read one resource from this MCP server by URI.", ["uri": text], required: ["uri"])
        }
        if await client.supportsPrompts {
            synthetic("mcp_list_prompts", .listPrompts, "List the prompt templates this MCP server offers.", [:], required: [])
            synthetic("mcp_get_prompt", .getPrompt, "Render one of this MCP server's prompt templates. `arguments` maps argument names to string values.",
                      ["name": text, "arguments": .object(["type": .string("object"), "additionalProperties": text])], required: ["name"])
        }
        // Real tools win over a synthetic name they happen to share.
        for tool in tools {
            let exposed = "mcp__\(serverSlug)__\(NativeAgentHost.sanitizeToolName(tool.name))"
            routes[exposed] = Route(
                kind: .tool,
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
        invalidateToolDefinitions()
        persistCatalog()
    }

    // MARK: Agent integration

    public func toolDefinitions() -> [AgentToolDefinition] {
        if let cachedToolDefinitions {
            lastToolDefinitionsCacheHit = true
            return cachedToolDefinitions
        }
        lastToolDefinitionsCacheHit = false
        let activeServerIDs = Set(servers.map(\.id))
        let definitions = routes
            .filter { activeServerIDs.contains($0.value.serverID) }
            .map { name, route in
                AgentToolDefinition(name: name, description: route.description, parameters: route.schema)
            }
            .sorted { $0.name < $1.name }
        cachedToolDefinitions = definitions
        return definitions
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
        switch route.kind ?? .tool {
        case .tool:
            return try await client.callTool(route.toolName, arguments: arguments)
        case .listResources:
            return try await client.listResources()
        case .readResource:
            guard let uri = arguments["uri"]?.string, !uri.isEmpty else { throw MCPError.rpc(code: -32602, message: "uri is required") }
            return try await client.readResource(uri)
        case .listPrompts:
            return try await client.listPrompts()
        case .getPrompt:
            guard let prompt = arguments["name"]?.string, !prompt.isEmpty else { throw MCPError.rpc(code: -32602, message: "name is required") }
            let values = (arguments["arguments"]?.object ?? [:]).compactMapValues { $0.string ?? $0.double.map { String($0) } }
            return try await client.getPrompt(prompt, arguments: values)
        }
    }

    // MARK: Authorization

    /// Interactive OAuth sign-in for a server that answered 401, then reconnect.
    public func signIn(_ serverID: String) async {
        guard let config = servers.first(where: { $0.id == serverID }) else { return }
        states[serverID] = .connecting
        do {
            try await MCPOAuth.signIn(config: config, challenge: challenges[serverID].flatMap { $0.isEmpty ? nil : $0 })
            await connect(serverID)
        } catch {
            states[serverID] = .failed(String(describing: error))
        }
    }

    public func hasOAuthGrant(_ serverID: String) -> Bool { MCPOAuth.grant(serverID: serverID) != nil }

    public func signOut(_ serverID: String) {
        MCPOAuth.save(nil, serverID: serverID)
    }

    // MARK: Server -> client

    /// Updates the roots servers see and tells connected servers they changed.
    public func setRoots(_ urls: [URL]) {
        guard urls != roots else { return }
        roots = urls
        let connected = Array(clients.values)
        Task { for client in connected { await client.notifyRootsChanged() } }
    }

    public func answer(_ interactionID: UUID, _ answer: InteractionAnswer) {
        interactions.removeAll { $0.id == interactionID }
        waiting.removeValue(forKey: interactionID)?.resume(returning: answer)
    }

    private func ask(_ kind: Interaction.Kind, server: String, params: JSONValue) async -> InteractionAnswer {
        let interaction = Interaction(serverName: server, kind: kind, params: params)
        return await withCheckedContinuation { continuation in
            waiting[interaction.id] = continuation
            interactions.append(interaction)
        }
    }

    private func hooks() -> MCPClientHooks {
        weak let registry = self
        let roots: @Sendable () async -> [URL] = { await registry?.roots ?? [] }
        var sample: (@Sendable (String, JSONValue) async throws -> JSONValue)?
        if sampler != nil {
            sample = { @Sendable server, params in
                guard let registry else { throw MCPError.notConnected }
                return try await registry.sample(server: server, params: params)
            }
        }
        let elicit: @Sendable (String, JSONValue) async throws -> JSONValue = { server, params in
            guard let registry else { throw MCPError.notConnected }
            return await registry.elicit(server: server, params: params)
        }
        let changed: @Sendable (String, String) async -> Void = { serverID, _ in
            await registry?.refreshRoutes(serverID)
        }
        let log: @Sendable (String, String, String) async -> Void = { server, level, message in
            await registry?.appendLog("[\(server)] \(level): \(message)")
        }
        return MCPClientHooks(roots: roots, sample: sample, elicit: elicit, changed: changed, log: log)
    }

    private func appendLog(_ line: String) {
        logLines.append(line)
        if logLines.count > 200 { logLines.removeFirst(logLines.count - 200) }
    }

    private func refreshRoutes(_ serverID: String) async {
        guard let client = clients[serverID], let config = servers.first(where: { $0.id == serverID }) else { return }
        let tools = await client.tools
        await registerRoutes(for: config, tools: tools, client: client)
        states[serverID] = .connected(toolCount: tools.count)
    }

    /// Human-in-the-loop sampling: the user sees the request and approves it
    /// before any model is called (spec: sampling SHOULD have human review).
    func sample(server: String, params: JSONValue) async throws -> JSONValue {
        guard let sampler else { throw MCPError.rpc(code: -32601, message: "Sampling is not available") }
        guard case .approve = await ask(.sampling, server: server, params: params) else {
            throw MCPError.rpc(code: -1, message: "User rejected sampling request")
        }
        let messages: [AgentMessage] = (params["messages"]?.array ?? []).compactMap { raw in
            let text = raw["content"].map { MCPClient.render(content: [$0.any]) } ?? ""
            return AgentMessage(role: raw["role"]?.string == "assistant" ? .assistant : .user, content: text)
        }
        let output = try await sampler(params["systemPrompt"]?.string ?? "", messages, params["maxTokens"]?.int ?? 1024)
        return .object([
            "role": .string("assistant"),
            "content": .object(["type": .string("text"), "text": .string(output.text)]),
            "model": .string(output.model),
            "stopReason": .string("endTurn"),
        ])
    }

    func elicit(server: String, params: JSONValue) async -> JSONValue {
        switch await ask(.elicitation, server: server, params: params) {
        case .accept(let values): return .object(["action": .string("accept"), "content": .object(values)])
        case .approve: return .object(["action": .string("accept"), "content": .object([:])])
        case .decline: return .object(["action": .string("decline")])
        case .cancel: return .object(["action": .string("cancel")])
        }
    }

    // MARK: Persistence

    private var catalogURL: URL { storeURL.deletingPathExtension().appendingPathExtension("catalog.json") }

    private func loadCatalog() {
        guard let data = try? Data(contentsOf: catalogURL),
              let saved = try? JSONDecoder().decode([String: Route].self, from: data) else { return }
        routes = saved.filter { entry in servers.contains { $0.id == entry.value.serverID } }
        invalidateToolDefinitions()
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

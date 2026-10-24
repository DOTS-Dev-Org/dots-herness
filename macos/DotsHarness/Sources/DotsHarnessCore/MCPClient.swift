// Copyright (c) 2026 DOTS
// Model Context Protocol client (revision 2025-06-18): HTTP + stdio transports.
//
// Client -> server: initialize, tools/list+call, resources/list+read,
// resources/templates/list, prompts/list+get (all paginated).
// Server -> client: ping, roots/list, sampling/createMessage and
// elicitation/create (both routed through `MCPClientHooks`, which put a human
// in the loop), plus list_changed / logging notifications.
// HTTP servers that answer 401 are authorized through `MCPOAuth`.
// `readOnlyHint` / `destructiveHint` are advisory only; they never grant
// automatic execution on their own.

import Foundation
import HarnessPluginKit

public enum MCPTransportKind: String, Sendable, Codable, CaseIterable {
    case http
    case stdio
}

public struct MCPServerConfig: Sendable, Codable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var transport: MCPTransportKind
    /// HTTP endpoint (transport == .http).
    public var url: String
    /// Executable + arguments (transport == .stdio).
    public var command: String
    public var arguments: [String]
    public var environment: [String: String]
    public var enabled: Bool
    /// When true, a tool whose `readOnlyHint` is set runs without an approval
    /// prompt. Off by default: the hint is advisory, not a guarantee.
    public var autoRunReadOnly: Bool

    public init(
        id: String = UUID().uuidString,
        name: String,
        transport: MCPTransportKind = .http,
        url: String = "",
        command: String = "",
        arguments: [String] = [],
        environment: [String: String] = [:],
        enabled: Bool = true,
        autoRunReadOnly: Bool = false
    ) {
        self.id = id
        self.name = name
        self.transport = transport
        self.url = url
        self.command = command
        self.arguments = arguments
        self.environment = environment
        self.enabled = enabled
        self.autoRunReadOnly = autoRunReadOnly
    }
}

public struct MCPToolInfo: Sendable, Equatable {
    public var name: String
    public var description: String
    public var inputSchema: JSONValue
    public var readOnlyHint: Bool
    public var destructiveHint: Bool
}

public enum MCPError: Error, CustomStringConvertible, Sendable {
    case notConnected
    case transport(String)
    case rpc(code: Int, message: String)
    case decode(String)
    /// HTTP 401. Carries the `WWW-Authenticate` header for OAuth discovery.
    case unauthorized(challenge: String?)

    public var description: String {
        switch self {
        case .notConnected: return "The MCP server is not connected."
        case .transport(let message): return "MCP transport error: \(message)"
        case .rpc(let code, let message): return "MCP error \(code): \(message)"
        case .decode(let message): return "Malformed MCP response: \(message)"
        case .unauthorized: return "The MCP server requires sign-in."
        }
    }
}

/// What a server may ask of the client. Every closure that reaches the user
/// or a model is optional; when nil the capability is not advertised and the
/// request is answered with "method not found".
public struct MCPClientHooks: Sendable {
    public var roots: @Sendable () async -> [URL]
    /// `sampling/createMessage` params -> CreateMessageResult.
    public var sample: (@Sendable (_ serverName: String, _ params: JSONValue) async throws -> JSONValue)?
    /// `elicitation/create` params -> ElicitResult.
    public var elicit: (@Sendable (_ serverName: String, _ params: JSONValue) async throws -> JSONValue)?
    /// A list_changed notification arrived; `kind` is "tools", "resources" or "prompts".
    public var changed: @Sendable (_ serverID: String, _ kind: String) async -> Void
    public var log: @Sendable (_ serverName: String, _ level: String, _ message: String) async -> Void

    public init(
        roots: @escaping @Sendable () async -> [URL] = { [] },
        sample: (@Sendable (String, JSONValue) async throws -> JSONValue)? = nil,
        elicit: (@Sendable (String, JSONValue) async throws -> JSONValue)? = nil,
        changed: @escaping @Sendable (String, String) async -> Void = { _, _ in },
        log: @escaping @Sendable (String, String, String) async -> Void = { _, _, _ in }
    ) {
        self.roots = roots
        self.sample = sample
        self.elicit = elicit
        self.changed = changed
        self.log = log
    }
}

/// One JSON-RPC channel to a server. Implementations own their own framing.
/// Messages cross as serialized `Data` so nothing non-Sendable escapes an actor.
protocol MCPRawTransport: AnyObject, Sendable {
    /// `request` is a complete JSON-RPC object (no trailing newline).
    /// Returns the response object bytes, or nil when `expectsResponse` is false.
    func send(_ request: Data, expectsResponse: Bool) async throws -> Data?
    /// Server-initiated requests and notifications are delivered here.
    func setIncomingHandler(_ handler: @escaping @Sendable (Data) -> Void)
    func close()
}

extension MCPRawTransport {
    func setIncomingHandler(_ handler: @escaping @Sendable (Data) -> Void) {}
}

// MARK: - Client

public actor MCPClient {
    public let config: MCPServerConfig
    private var transport: MCPRawTransport?
    private var nextID = 1
    private(set) var tools: [MCPToolInfo] = []
    private(set) var serverInfo: String = ""
    private(set) var supportsResources = false
    private(set) var supportsPrompts = false
    /// Server-provided usage notes from `initialize`.
    private(set) var instructions: String = ""

    private let hooks: MCPClientHooks
    private let makeTransport: @Sendable (MCPServerConfig) -> MCPRawTransport

    init(
        config: MCPServerConfig,
        hooks: MCPClientHooks = MCPClientHooks(),
        transportFactory: (@Sendable (MCPServerConfig) -> MCPRawTransport)? = nil,
        sandboxPolicy: SandboxExecutionPolicy? = nil
    ) {
        self.config = config
        self.hooks = hooks
        self.makeTransport = transportFactory ?? { cfg in
            switch cfg.transport {
            case .http: return MCPHTTPTransport(config: cfg)
            case .stdio: return MCPStdioTransport(config: cfg, sandboxPolicy: sandboxPolicy)
            }
        }
    }

    public func connect() async throws {
        let transport = makeTransport(config)
        self.transport = transport
        transport.setIncomingHandler { [weak self] data in
            Task { await self?.handleIncoming(data) }
        }
        var capabilities: [String: Any] = ["roots": ["listChanged": true]]
        if hooks.sample != nil { capabilities["sampling"] = [String: Any]() }
        if hooks.elicit != nil { capabilities["elicitation"] = [String: Any]() }
        let initResult = try await rpc("initialize", params: [
            "protocolVersion": "2025-06-18",
            "capabilities": capabilities,
            "clientInfo": ["name": "DotsHarness", "version": "1.0"],
        ])
        if let info = (initResult["serverInfo"] as? [String: Any])?["name"] as? String {
            serverInfo = info
        }
        instructions = initResult["instructions"] as? String ?? ""
        let serverCapabilities = initResult["capabilities"] as? [String: Any] ?? [:]
        supportsResources = serverCapabilities["resources"] != nil
        supportsPrompts = serverCapabilities["prompts"] != nil
        try await notify("notifications/initialized")
        if serverCapabilities["tools"] != nil || serverCapabilities.isEmpty {
            try await refreshTools()
        }
    }

    public func refreshTools() async throws {
        tools = try await paginated("tools/list", key: "tools").compactMap { raw in
            guard let name = raw["name"] as? String, !name.isEmpty else { return nil }
            let annotations = raw["annotations"] as? [String: Any] ?? [:]
            return MCPToolInfo(
                name: name,
                description: raw["description"] as? String ?? raw["title"] as? String ?? "",
                inputSchema: JSONCodec.value(from: raw["inputSchema"]),
                readOnlyHint: annotations["readOnlyHint"] as? Bool ?? false,
                destructiveHint: annotations["destructiveHint"] as? Bool ?? true
            )
        }
    }

    public func callTool(_ name: String, arguments: JSONValue) async throws -> String {
        let argumentObject = arguments.any as? [String: Any] ?? [:]
        let result = try await rpc("tools/call", params: [
            "name": name,
            "arguments": argumentObject,
        ])
        var text = Self.render(content: result["content"])
        if text.isEmpty, let structured = result["structuredContent"],
           let data = try? JSONSerialization.data(withJSONObject: structured, options: [.sortedKeys]) {
            text = String(decoding: data, as: UTF8.self)
        }
        if let isError = result["isError"] as? Bool, isError {
            throw MCPError.rpc(code: -1, message: text.isEmpty ? "tool reported an error" : text)
        }
        return text
    }

    // MARK: Resources & prompts

    public func listResources() async throws -> String {
        let resources = try await paginated("resources/list", key: "resources")
        // Templates are optional; a server without them answers -32601.
        let templates = (try? await paginated("resources/templates/list", key: "resourceTemplates")) ?? []
        var lines = resources.map { raw in
            let uri = raw["uri"] as? String ?? ""
            let name = raw["title"] as? String ?? raw["name"] as? String ?? uri
            let mime = (raw["mimeType"] as? String).map { " [\($0)]" } ?? ""
            let description = (raw["description"] as? String).map { " — \($0)" } ?? ""
            return "- \(name): \(uri)\(mime)\(description)"
        }
        if !templates.isEmpty {
            lines.append("Templates (fill the {placeholders}, then read the URI):")
            lines += templates.map { raw in
                let name = raw["title"] as? String ?? raw["name"] as? String ?? ""
                let description = (raw["description"] as? String).map { " — \($0)" } ?? ""
                return "- \(name): \(raw["uriTemplate"] as? String ?? "")\(description)"
            }
        }
        return lines.isEmpty ? "The server lists no resources." : lines.joined(separator: "\n")
    }

    public func readResource(_ uri: String) async throws -> String {
        let result = try await rpc("resources/read", params: ["uri": uri])
        let contents = result["contents"] as? [[String: Any]] ?? []
        return contents.map(Self.render(resource:)).joined(separator: "\n\n")
    }

    public func listPrompts() async throws -> String {
        let prompts = try await paginated("prompts/list", key: "prompts")
        guard !prompts.isEmpty else { return "The server lists no prompts." }
        return prompts.map { raw in
            let name = raw["name"] as? String ?? ""
            let description = (raw["description"] as? String).map { " — \($0)" } ?? ""
            let arguments = (raw["arguments"] as? [[String: Any]] ?? []).map { argument in
                let required = argument["required"] as? Bool == true ? " (required)" : ""
                return "\(argument["name"] as? String ?? "")\(required)"
            }
            let signature = arguments.isEmpty ? "" : " args: " + arguments.joined(separator: ", ")
            return "- \(name)\(description)\(signature)"
        }.joined(separator: "\n")
    }

    public func getPrompt(_ name: String, arguments: [String: String]) async throws -> String {
        var params: [String: Any] = ["name": name]
        if !arguments.isEmpty { params["arguments"] = arguments }
        let result = try await rpc("prompts/get", params: params)
        let messages = result["messages"] as? [[String: Any]] ?? []
        return messages.map { message in
            "\(message["role"] as? String ?? "user"): \(Self.render(content: [message["content"] as Any]))"
        }.joined(separator: "\n\n")
    }

    /// Tells the server the workspace roots changed; it re-asks with roots/list.
    public func notifyRootsChanged() async {
        try? await notify("notifications/roots/list_changed")
    }

    public func disconnect() {
        transport?.close()
        transport = nil
        tools = []
    }

    // MARK: Server -> client

    func handleIncoming(_ data: Data) async {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let method = object["method"] as? String else { return }
        let params = JSONCodec.value(from: object["params"])
        guard let id = object["id"], !(id is NSNull) else {
            switch method {
            case "notifications/tools/list_changed":
                try? await refreshTools()
                await hooks.changed(config.id, "tools")
            case "notifications/resources/list_changed":
                await hooks.changed(config.id, "resources")
            case "notifications/prompts/list_changed":
                await hooks.changed(config.id, "prompts")
            case "notifications/message":
                let message = params["data"].map { $0.string ?? String(describing: $0.any) } ?? ""
                await hooks.log(config.name, params["level"]?.string ?? "info", message)
            default:
                break // progress, cancelled, resources/updated: nothing to act on.
            }
            return
        }
        var reply: [String: Any] = ["jsonrpc": "2.0", "id": id]
        do {
            let result: JSONValue
            switch method {
            case "ping":
                result = .object([:])
            case "roots/list":
                let roots = await hooks.roots()
                result = .object(["roots": .array(roots.map {
                    .object(["uri": .string($0.absoluteString), "name": .string($0.lastPathComponent)])
                })])
            case "sampling/createMessage":
                guard let sample = hooks.sample else { throw MCPError.rpc(code: -32601, message: "Method not found: \(method)") }
                result = try await sample(config.name, params)
            case "elicitation/create":
                guard let elicit = hooks.elicit else { throw MCPError.rpc(code: -32601, message: "Method not found: \(method)") }
                result = try await elicit(config.name, params)
            default:
                throw MCPError.rpc(code: -32601, message: "Method not found: \(method)")
            }
            reply["result"] = result.any
        } catch MCPError.rpc(let code, let message) {
            reply["error"] = ["code": code, "message": message]
        } catch {
            reply["error"] = ["code": -32603, "message": String(describing: error)]
        }
        guard let transport, let body = try? JSONSerialization.data(withJSONObject: reply) else { return }
        _ = try? await transport.send(body, expectsResponse: false)
    }

    // MARK: JSON-RPC

    private func notify(_ method: String) async throws {
        guard let transport else { throw MCPError.notConnected }
        let body = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "method": method])
        _ = try await transport.send(body, expectsResponse: false)
    }

    /// Follows `nextCursor` until the server stops paging. Capped so a buggy
    /// server that always returns a cursor cannot spin forever.
    private func paginated(_ method: String, key: String) async throws -> [[String: Any]] {
        var items: [[String: Any]] = []
        var cursor: String?
        for _ in 0..<50 {
            let result = try await rpc(method, params: cursor.map { ["cursor": $0] } ?? [:])
            items += result[key] as? [[String: Any]] ?? []
            cursor = result["nextCursor"] as? String
            if cursor?.isEmpty != false { break }
        }
        return items
    }

    private func rpc(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        guard let transport else { throw MCPError.notConnected }
        let id = nextID
        nextID += 1
        var payload: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method]
        if !params.isEmpty { payload["params"] = params }
        let requestData = try JSONSerialization.data(withJSONObject: payload)
        guard let responseData = try await transport.send(requestData, expectsResponse: true) else {
            throw MCPError.decode("empty response")
        }
        guard let response = try JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
            throw MCPError.decode("response is not an object")
        }
        if let error = response["error"] as? [String: Any] {
            throw MCPError.rpc(
                code: error["code"] as? Int ?? -1,
                message: error["message"] as? String ?? "unknown error"
            )
        }
        return response["result"] as? [String: Any] ?? [:]
    }

    /// True when `object` is the response to request `id` (not a server request).
    static func isResponse(_ object: [String: Any], to id: Int?) -> Bool {
        guard object["method"] == nil, object["result"] != nil || object["error"] != nil else { return false }
        guard let id else { return true }
        return (object["id"] as? Int) == id || (object["id"] as? String) == String(id)
    }

    // MARK: Rendering

    /// Flattens MCP content blocks to text the model can read. Binary payloads
    /// are summarized rather than inlined as base64.
    static func render(content: Any?) -> String {
        (content as? [Any] ?? []).compactMap { item -> String? in
            guard let block = item as? [String: Any] else { return nil }
            switch block["type"] as? String {
            case "text":
                return block["text"] as? String
            case "image", "audio":
                let bytes = ((block["data"] as? String)?.count ?? 0) * 3 / 4
                return "[\(block["type"] as? String ?? "") \(block["mimeType"] as? String ?? ""), \(bytes) bytes]"
            case "resource":
                return (block["resource"] as? [String: Any]).map(render(resource:))
            case "resource_link":
                return "[resource \(block["name"] as? String ?? ""): \(block["uri"] as? String ?? "")]"
            default:
                return block["text"] as? String
            }
        }.joined(separator: "\n")
    }

    static func render(resource: [String: Any]) -> String {
        let uri = resource["uri"] as? String ?? ""
        if let text = resource["text"] as? String { return text.isEmpty ? "(\(uri) is empty)" : text }
        let bytes = ((resource["blob"] as? String)?.count ?? 0) * 3 / 4
        return "[binary \(resource["mimeType"] as? String ?? "data") \(uri), \(bytes) bytes]"
    }
}

// MARK: - HTTP transport

/// Streamable HTTP. A POST answers with JSON or an SSE stream; the stream may
/// carry server requests ahead of our response, and those must be answered
/// while the stream is still open, so it is read incrementally.
final class MCPHTTPTransport: MCPRawTransport, @unchecked Sendable {
    private let config: MCPServerConfig
    private let session: URLSession
    private let lock = NSLock()
    private var sessionID: String?
    private var incoming: (@Sendable (Data) -> Void)?

    init(config: MCPServerConfig) {
        self.config = config
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 300
        self.session = URLSession(configuration: configuration)
    }

    func setIncomingHandler(_ handler: @escaping @Sendable (Data) -> Void) {
        lock.withLock { incoming = handler }
    }

    func send(_ requestData: Data, expectsResponse: Bool) async throws -> Data? {
        do {
            return try await post(requestData, expectsResponse: expectsResponse, bearer: await bearer(forceRefresh: false))
        } catch MCPError.unauthorized(let challenge) {
            // An expired OAuth access token is refreshed once and retried.
            guard MCPKeychain.token(for: config.id)?.isEmpty != false,
                  let refreshed = await bearer(forceRefresh: true) else { throw MCPError.unauthorized(challenge: challenge) }
            return try await post(requestData, expectsResponse: expectsResponse, bearer: refreshed)
        }
    }

    /// A manually entered token wins; otherwise the stored OAuth grant.
    private func bearer(forceRefresh: Bool) async -> String? {
        if let token = MCPKeychain.token(for: config.id), !token.isEmpty { return token }
        return await MCPOAuth.accessToken(serverID: config.id, forceRefresh: forceRefresh)
    }

    /// HTTPS everywhere, plain HTTP only to a loopback address. The MCP
    /// bearer token travels with every request.
    static func isAllowedTransport(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), url.user == nil, url.password == nil,
              let host = url.host?.lowercased(), !host.isEmpty else { return false }
        if scheme == "https" { return true }
        guard scheme == "http" else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }

    private func post(_ requestData: Data, expectsResponse: Bool, bearer: String?) async throws -> Data? {
        guard let url = URL(string: config.url) else { throw MCPError.transport("invalid URL") }
        // The bearer token goes out with every request, so the transport has
        // to be one that keeps it off the wire in the clear. Plain HTTP is
        // only allowed to a loopback address.
        guard Self.isAllowedTransport(url) else {
            throw MCPError.transport("This MCP server must use HTTPS (plain HTTP is only allowed on localhost).")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("2025-06-18", forHTTPHeaderField: "MCP-Protocol-Version")
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        if let sessionID = lock.withLock({ sessionID }) { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
        request.httpBody = requestData

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw MCPError.transport("no HTTP response") }
        if let id = http.value(forHTTPHeaderField: "Mcp-Session-Id") { lock.withLock { sessionID = id } }
        if http.statusCode == 401 {
            throw MCPError.unauthorized(challenge: http.value(forHTTPHeaderField: "WWW-Authenticate"))
        }
        if http.statusCode == 404, lock.withLock({ sessionID }) != nil {
            // The server dropped our session; the next initialize starts fresh.
            lock.withLock { sessionID = nil }
        }
        guard (200..<300).contains(http.statusCode) else { throw MCPError.transport("HTTP \(http.statusCode)") }
        guard expectsResponse else { return nil }

        let requestID = (try? JSONSerialization.jsonObject(with: requestData) as? [String: Any])?["id"] as? Int
        let contentType = http.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        if !contentType.contains("text/event-stream") {
            var data = Data()
            for try await byte in bytes { data.append(byte) }
            return data
        }
        // ponytail: only the POST-scoped SSE stream is read. The optional
        // standalone GET stream is not opened, so an HTTP server's unsolicited
        // notifications arrive only alongside a request of ours.
        var pending = ""
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            pending += line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard let data = pending.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            pending = ""
            if MCPClient.isResponse(object, to: requestID) { return data }
            lock.withLock { incoming }?(data)
        }
        throw MCPError.decode("the event stream closed without a response")
    }

    func close() {
        session.invalidateAndCancel()
    }
}

// MARK: - stdio transport

/// Newline-delimited JSON-RPC over a child process's stdio, per the MCP stdio
/// transport. One reader fans responses out to callers by request id and
/// hands server requests/notifications to the incoming handler.
final class MCPStdioTransport: MCPRawTransport, @unchecked Sendable {
    private let config: MCPServerConfig
    private let sandboxPolicy: SandboxExecutionPolicy?
    private let process = Process()
    private let stdin = Pipe()
    private let stdout = Pipe()
    private let lock = NSLock()
    /// Serializes whole-line writes. Separate from `lock` so a blocked pipe
    /// write never stalls the reader that drains the server's stdout.
    private let writeLock = NSLock()
    private var pending: [Int: CheckedContinuation<Data, Error>] = [:]
    private var buffer = Data()
    private var started = false
    private var incoming: (@Sendable (Data) -> Void)?

    init(config: MCPServerConfig, sandboxPolicy: SandboxExecutionPolicy? = nil) {
        self.config = config
        self.sandboxPolicy = sandboxPolicy
    }

    func setIncomingHandler(_ handler: @escaping @Sendable (Data) -> Void) {
        lock.withLock { incoming = handler }
    }

    private func startIfNeeded() throws {
        lock.lock(); defer { lock.unlock() }
        guard !started else { return }
        var environment = config.environment.isEmpty
            ? ProcessInfo.processInfo.environment
            : ProcessInfo.processInfo.environment.merging(config.environment) { _, new in new }
        // A local MCP server is a process the agent's tools can drive, same
        // as `run_command` — while a sandbox is active it goes through the
        // same `sandbox-exec` jail rather than running with the app's full
        // access. HTTP-transport servers aren't a local process and can't be
        // wrapped this way; those are unaffected.
        if let sandboxPolicy {
            process.executableURL = SandboxProfile.executableURL
            process.arguments = try SandboxProfile.arguments(
                executable: config.command,
                arguments: config.arguments,
                policy: sandboxPolicy
            )
            environment = environment.merging(SandboxProfile.cacheEnvironment(workspaceURL: sandboxPolicy.workspaceURL)) { _, new in new }
        } else {
            process.executableURL = URL(fileURLWithPath: config.command)
            process.arguments = config.arguments
        }
        process.environment = environment
        process.qualityOfService = .utility
        process.standardInput = stdin
        process.standardOutput = stdout
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.ingest(handle.availableData)
        }
        do {
            try process.run()
        } catch {
            throw MCPError.transport("failed to launch \(config.command): \(error.localizedDescription)")
        }
        started = true
    }

    private func ingest(_ data: Data) {
        guard !data.isEmpty else { return }
        var forwarded: [Data] = []
        lock.lock()
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[buffer.startIndex..<newline])
            buffer.removeSubrange(buffer.startIndex...newline)
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            if object["method"] == nil, let id = object["id"] as? Int, let continuation = pending.removeValue(forKey: id) {
                continuation.resume(returning: line)
            } else if object["method"] != nil {
                forwarded.append(line)
            }
        }
        let handler = incoming
        lock.unlock()
        for line in forwarded { handler?(line) }
    }

    func send(_ requestData: Data, expectsResponse: Bool) async throws -> Data? {
        try startIfNeeded()
        var line = requestData
        line.append(0x0A)
        if !expectsResponse {
            writeLock.withLock { stdin.fileHandleForWriting.write(line) }
            return nil
        }
        let id = (try? JSONSerialization.jsonObject(with: requestData) as? [String: Any])?["id"] as? Int
        guard let id else { throw MCPError.decode("request without id") }
        return try await withCheckedThrowingContinuation { continuation in
            lock.withLock { pending[id] = continuation }
            writeLock.withLock { stdin.fileHandleForWriting.write(line) }
        }
    }

    func close() {
        stdout.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
        lock.lock()
        let waiting = pending
        pending.removeAll()
        lock.unlock()
        for continuation in waiting.values {
            continuation.resume(throwing: MCPError.notConnected)
        }
    }
}

// MARK: - Keychain

enum MCPKeychain {
    private static let service = "com.dots.herness.mcp"

    static func setToken(_ token: String?, for serverID: String, service: String = service) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: serverID,
        ]
        SecItemDelete(query as CFDictionary)
        guard let token, !token.isEmpty else { return }
        var item = query
        item[kSecValueData as String] = Data(token.utf8)
        item[kSecAttrAccessible as String] = KeychainAccess.whenUnlocked
        SecItemAdd(item as CFDictionary, nil)
    }

    static func token(for serverID: String, service: String = service) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: serverID,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

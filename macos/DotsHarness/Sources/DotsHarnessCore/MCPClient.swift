// Copyright (c) 2026 DOTS
// Minimal Model Context Protocol client: HTTP + stdio transports, tools only.
//
// First cut deliberately covers just what the agent loop needs:
//   initialize -> notifications/initialized -> tools/list -> tools/call
// Resources, prompts, subscriptions, sampling and interactive OAuth are out of
// scope. `readOnlyHint` / `destructiveHint` are surfaced as advisory signals
// only; they never grant automatic execution on their own.

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

    public var description: String {
        switch self {
        case .notConnected: return "The MCP server is not connected."
        case .transport(let message): return "MCP transport error: \(message)"
        case .rpc(let code, let message): return "MCP error \(code): \(message)"
        case .decode(let message): return "Malformed MCP response: \(message)"
        }
    }
}

/// One JSON-RPC channel to a server. Implementations own their own framing.
/// Messages cross as serialized `Data` so nothing non-Sendable escapes an actor.
protocol MCPRawTransport: AnyObject, Sendable {
    /// `request` is a complete JSON-RPC object (no trailing newline).
    /// Returns the response object bytes, or nil when `expectsResponse` is false.
    func send(_ request: Data, expectsResponse: Bool) async throws -> Data?
    func close()
}

// MARK: - Client

public actor MCPClient {
    public let config: MCPServerConfig
    private var transport: MCPRawTransport?
    private var nextID = 1
    private(set) var tools: [MCPToolInfo] = []
    private(set) var serverInfo: String = ""

    private let makeTransport: @Sendable (MCPServerConfig) -> MCPRawTransport

    init(
        config: MCPServerConfig,
        transportFactory: (@Sendable (MCPServerConfig) -> MCPRawTransport)? = nil
    ) {
        self.config = config
        self.makeTransport = transportFactory ?? { cfg in
            switch cfg.transport {
            case .http: return MCPHTTPTransport(config: cfg)
            case .stdio: return MCPStdioTransport(config: cfg)
            }
        }
    }

    public func connect() async throws {
        let transport = makeTransport(config)
        self.transport = transport
        let initResult = try await rpc("initialize", params: [
            "protocolVersion": "2025-06-18",
            "capabilities": ["tools": [:] as [String: Any]],
            "clientInfo": ["name": "DotsHarness", "version": "1.0"],
        ])
        if let info = (initResult["serverInfo"] as? [String: Any])?["name"] as? String {
            serverInfo = info
        }
        let initialized = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "method": "notifications/initialized"])
        _ = try? await transport.send(initialized, expectsResponse: false)
        try await refreshTools()
    }

    public func refreshTools() async throws {
        let result = try await rpc("tools/list", params: [:])
        let rawTools = result["tools"] as? [[String: Any]] ?? []
        tools = rawTools.map { raw in
            let annotations = raw["annotations"] as? [String: Any] ?? [:]
            return MCPToolInfo(
                name: raw["name"] as? String ?? "",
                description: raw["description"] as? String ?? "",
                inputSchema: JSONCodec.value(from: raw["inputSchema"]),
                readOnlyHint: annotations["readOnlyHint"] as? Bool ?? false,
                destructiveHint: annotations["destructiveHint"] as? Bool ?? true
            )
        }
        .filter { !$0.name.isEmpty }
    }

    public func callTool(_ name: String, arguments: JSONValue) async throws -> String {
        let argumentObject = arguments.any as? [String: Any] ?? [:]
        let result = try await rpc("tools/call", params: [
            "name": name,
            "arguments": argumentObject,
        ])
        if let isError = result["isError"] as? Bool, isError {
            let text = JSONCodec.value(from: result["content"]).textBlocks()
            throw MCPError.rpc(code: -1, message: text.isEmpty ? "tool reported an error" : text)
        }
        return JSONCodec.value(from: result["content"]).textBlocks()
    }

    public func disconnect() {
        transport?.close()
        transport = nil
        tools = []
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
        let response = try Self.decodeJSONRPC(responseData)
        if let error = response["error"] as? [String: Any] {
            throw MCPError.rpc(
                code: error["code"] as? Int ?? -1,
                message: error["message"] as? String ?? "unknown error"
            )
        }
        return response["result"] as? [String: Any] ?? [:]
    }

    /// Body is either a bare JSON-RPC object or an SSE stream whose `data:`
    /// lines carry the JSON-RPC messages. We take the first object that has an
    /// `id` (the response to our request).
    static func decodeJSONRPC(_ data: Data) throws -> [String: Any] {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return object
        }
        let text = String(decoding: data, as: UTF8.self)
        for line in text.split(whereSeparator: \.isNewline) {
            guard line.hasPrefix("data:") else { continue }
            let json = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
               object["id"] != nil {
                return object
            }
        }
        throw MCPError.decode("no JSON-RPC object in response body")
    }
}

// MARK: - HTTP transport

final class MCPHTTPTransport: MCPRawTransport, @unchecked Sendable {
    private let config: MCPServerConfig
    private let session: URLSession
    private var sessionID: String?

    init(config: MCPServerConfig) {
        self.config = config
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        self.session = URLSession(configuration: configuration)
    }

    func send(_ requestData: Data, expectsResponse: Bool) async throws -> Data? {
        guard let url = URL(string: config.url) else { throw MCPError.transport("invalid URL") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if let token = MCPKeychain.token(for: config.id), !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
        request.httpBody = requestData

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse {
            if let id = http.value(forHTTPHeaderField: "Mcp-Session-Id") { sessionID = id }
            guard (200..<300).contains(http.statusCode) else {
                throw MCPError.transport("HTTP \(http.statusCode)")
            }
        }
        return expectsResponse ? data : nil
    }

    func close() {
        session.invalidateAndCancel()
    }
}

// MARK: - stdio transport

/// Newline-delimited JSON-RPC over a child process's stdio, per the MCP stdio
/// transport. One reader task fans responses out to callers by request id.
final class MCPStdioTransport: MCPRawTransport, @unchecked Sendable {
    private let config: MCPServerConfig
    private let process = Process()
    private let stdin = Pipe()
    private let stdout = Pipe()
    private let lock = NSLock()
    private var pending: [Int: CheckedContinuation<Data, Error>] = [:]
    private var buffer = Data()
    private var started = false

    init(config: MCPServerConfig) {
        self.config = config
    }

    private func startIfNeeded() throws {
        lock.lock(); defer { lock.unlock() }
        guard !started else { return }
        process.executableURL = URL(fileURLWithPath: config.command)
        process.arguments = config.arguments
        if !config.environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(config.environment) { _, new in new }
        }
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
        lock.lock(); defer { lock.unlock() }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[buffer.startIndex..<newline])
            buffer.removeSubrange(buffer.startIndex...newline)
            guard
                let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                let id = object["id"] as? Int,
                let continuation = pending.removeValue(forKey: id)
            else { continue }
            continuation.resume(returning: line)
        }
    }

    func send(_ requestData: Data, expectsResponse: Bool) async throws -> Data? {
        try startIfNeeded()
        var line = requestData
        line.append(0x0A)
        if !expectsResponse {
            stdin.fileHandleForWriting.write(line)
            return nil
        }
        let id = (try? JSONSerialization.jsonObject(with: requestData) as? [String: Any])?["id"] as? Int
        guard let id else { throw MCPError.decode("request without id") }
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            pending[id] = continuation
            lock.unlock()
            stdin.fileHandleForWriting.write(line)
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

    static func setToken(_ token: String?, for serverID: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: serverID,
        ]
        SecItemDelete(query as CFDictionary)
        guard let token, !token.isEmpty else { return }
        var item = query
        item[kSecValueData as String] = Data(token.utf8)
        SecItemAdd(item as CFDictionary, nil)
    }

    static func token(for serverID: String) -> String? {
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

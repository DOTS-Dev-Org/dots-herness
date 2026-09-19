import Foundation

/// MCP over streamable HTTP. Only HTTPS transports are accepted from a phone:
/// stdio servers need a child process, which iOS does not allow, so a server has
/// to be something the phone can call over the network.
struct MCPServer: Codable, Identifiable, Equatable, Sendable {
    var id = UUID().uuidString
    var name: String
    var url: String
    /// Sent as `Authorization: Bearer …` when set. Stored in the keychain, not here.
    var usesToken = false

    var tokenKey: String { "mcp.\(id)" }
}

struct MCPTool: Sendable, Equatable {
    let name: String
    let description: String
    let schema: Data
}

actor MCPClient {
    private let server: MCPServer
    private let token: String
    private var sessionId: String?
    private var nextId = 0

    init(server: MCPServer, token: String) {
        self.server = server
        self.token = token
    }

    func listTools() async throws -> [MCPTool] {
        _ = try await call(method: "initialize", params: [
            "protocolVersion": "2025-06-18",
            "capabilities": [:],
            "clientInfo": ["name": "HerNess mobile", "version": "1.0"],
        ])
        try await notify(method: "notifications/initialized")
        let result = try await call(method: "tools/list", params: [:])
        let tools = (result["tools"] as? [[String: Any]]) ?? []
        return tools.compactMap { tool in
            guard let name = tool["name"] as? String else { return nil }
            let schema = tool["inputSchema"] as? [String: Any] ?? ["type": "object"]
            return MCPTool(
                name: name,
                description: tool["description"] as? String ?? "MCP tool \(name) from \(server.name).",
                schema: (try? JSONSerialization.data(withJSONObject: schema)) ?? Data("{\"type\":\"object\"}".utf8))
        }
    }

    func callTool(_ name: String, arguments: [String: Any]) async throws -> String {
        let result = try await call(method: "tools/call", params: ["name": name, "arguments": arguments])
        let content = result["content"] as? [[String: Any]] ?? []
        let text = content.compactMap { block -> String? in
            switch block["type"] as? String {
            case "text": return block["text"] as? String
            case "resource": return ((block["resource"] as? [String: Any])?["text"] as? String) ?? "[resource]"
            default: return "[\(block["type"] as? String ?? "content")]"
            }
        }.joined(separator: "\n")
        if result["isError"] as? Bool == true { throw MCPError.server(text.isEmpty ? "The MCP tool reported an error." : text) }
        return text.isEmpty ? "The MCP tool returned no content." : text
    }

    // MARK: - JSON-RPC

    private func call(method: String, params: [String: Any]) async throws -> [String: Any] {
        nextId += 1
        let body: [String: Any] = ["jsonrpc": "2.0", "id": nextId, "method": method, "params": params]
        let data = try await send(body: body)
        guard let object = decode(data) else { throw MCPError.server("\(server.name) returned a response that is not JSON-RPC.") }
        if let error = object["error"] as? [String: Any] {
            throw MCPError.server(error["message"] as? String ?? "The MCP server reported an error.")
        }
        return object["result"] as? [String: Any] ?? [:]
    }

    private func notify(method: String) async throws {
        _ = try? await send(body: ["jsonrpc": "2.0", "method": method, "params": [:]])
    }

    private func send(body: [String: Any]) async throws -> Data {
        guard let url = URL(string: server.url), url.scheme?.lowercased() == "https", url.user == nil, url.password == nil, url.host != nil else { throw MCPError.server("\(server.name) requires an HTTPS URL.") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let sessionId { request.setValue(sessionId, forHTTPHeaderField: "Mcp-Session-Id") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 120

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw MCPError.server("\(server.name) did not respond.") }
        if let value = http.value(forHTTPHeaderField: "Mcp-Session-Id") { sessionId = value }
        guard (200..<300).contains(http.statusCode) else {
            throw MCPError.server("\(server.name): \(http.statusCode) \(String(data: data, encoding: .utf8) ?? "")")
        }
        return data
    }

    /// A streamable-HTTP server may answer with a plain JSON body or with an SSE
    /// stream whose last `data:` frame carries the response.
    private func decode(_ data: Data) -> [String: Any]? {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { return object }
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n").reversed() where line.hasPrefix("data:") {
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if let object = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] { return object }
        }
        return nil
    }
}

enum MCPError: LocalizedError {
    case server(String)
    var errorDescription: String? { switch self { case .server(let message): return message } }
}

/// The servers the phone knows about, and the agent tools they expose.
@MainActor
final class MCPRegistry: ObservableObject {
    @Published private(set) var servers: [MCPServer] = []
    @Published private(set) var status: [String: String] = [:]

    private let secure = SecureStore()
    private static let storageKey = "herness.mcp.servers"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let value = try? JSONDecoder().decode([MCPServer].self, from: data) { servers = value }
    }

    func add(name: String, url: String, token: String) {
        var server = MCPServer(name: name.isEmpty ? url : name, url: url, usesToken: !token.isEmpty)
        if !token.isEmpty { secure.write(token, key: server.tokenKey) } else { server.usesToken = false }
        servers.append(server)
        save()
    }

    func remove(_ server: MCPServer) {
        secure.delete(server.tokenKey)
        servers.removeAll { $0.id == server.id }
        status[server.id] = nil
        save()
    }

    /// Connects to every server and hands the discovered tools to the agent,
    /// namespaced so two servers can expose the same tool name.
    func connectAll(into agent: MobileAgent) async {
        for server in servers {
            let client = MCPClient(server: server, token: server.usesToken ? (secure.read(server.tokenKey) ?? "") : "")
            do {
                let tools = try await client.listTools()
                let specs = tools.map { tool in
                    AgentToolSpec(
                        name: Self.toolName(server: server, tool: tool.name),
                        description: tool.description,
                        schema: (try? JSONSerialization.jsonObject(with: tool.schema)) as? [String: Any] ?? ["type": "object"]
                    ) { input in
                        let arguments = (try? JSONSerialization.jsonObject(with: input.data)) as? [String: Any] ?? [:]
                        return try await client.callTool(tool.name, arguments: arguments)
                    }
                }
                agent.register(specs)
                status[server.id] = "\(tools.count) tool(s)"
            } catch {
                status[server.id] = error.localizedDescription
            }
        }
    }

    static func toolName(server: MCPServer, tool: String) -> String {
        let slug = server.name.lowercased().replacingOccurrences(of: "[^a-z0-9_]", with: "_", options: .regularExpression)
        return "mcp__\(slug)__\(tool)"
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(servers) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
}

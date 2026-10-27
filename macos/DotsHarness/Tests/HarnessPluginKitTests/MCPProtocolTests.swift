// Copyright (c) 2026 DOTS

import XCTest
import Foundation
import HarnessPluginKit
@testable import DotsHarnessCore

/// Server with resources + prompts that also sends requests to the client.
private final class FullStubTransport: MCPRawTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (Data) -> Void)?
    private(set) var replies: [[String: Any]] = []
    var toolsVersion = 1

    func setIncomingHandler(_ handler: @escaping @Sendable (Data) -> Void) { lock.withLock { self.handler = handler } }

    func push(_ object: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: object)
        lock.withLock { handler }?(data)
    }

    func send(_ request: Data, expectsResponse: Bool) async throws -> Data? {
        let object = try JSONSerialization.jsonObject(with: request) as? [String: Any] ?? [:]
        guard expectsResponse else {
            if object["method"] == nil { lock.withLock { replies.append(object) } }
            return nil
        }
        let params = object["params"] as? [String: Any] ?? [:]
        let result: [String: Any]
        switch object["method"] as? String ?? "" {
        case "initialize":
            result = ["serverInfo": ["name": "full"], "capabilities": ["tools": [:], "resources": [:], "prompts": [:]]]
        case "tools/list":
            // Two pages, to exercise nextCursor.
            if params["cursor"] == nil {
                result = ["tools": [["name": "a", "inputSchema": ["type": "object"]]], "nextCursor": "p2"]
            } else {
                result = ["tools": toolsVersion == 1 ? [["name": "b", "inputSchema": ["type": "object"]]] : []]
            }
        case "resources/list":
            result = ["resources": [["uri": "file:///readme.md", "name": "readme", "mimeType": "text/markdown"]]]
        case "resources/templates/list":
            result = ["resourceTemplates": [["uriTemplate": "file:///{path}", "name": "files"]]]
        case "resources/read":
            result = ["contents": [["uri": params["uri"] as? String ?? "", "text": "# Hello"]]]
        case "prompts/list":
            result = ["prompts": [["name": "review", "arguments": [["name": "lang", "required": true]]]]]
        case "prompts/get":
            let lang = (params["arguments"] as? [String: String])?["lang"] ?? "?"
            result = ["messages": [["role": "user", "content": ["type": "text", "text": "Review \(lang)"]]]]
        default:
            result = [:]
        }
        return try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": object["id"] ?? 0, "result": result])
    }

    func close() {}

    func waitForReply(id: Int) async -> [String: Any]? {
        for _ in 0..<200 {
            if let reply = lock.withLock({ replies.first { ($0["id"] as? Int) == id } }) { return reply }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return nil
    }
}

final class MCPProtocolTests: XCTestCase {
    @MainActor
    private func registry(_ stub: FullStubTransport) -> (MCPRegistry, MCPServerConfig) {
        let registry = MCPRegistry(storeURL: FileManager.default.temporaryDirectory.appendingPathComponent("mcp-\(UUID().uuidString).json"))
        registry.transportOverride = { _ in stub }
        let config = MCPServerConfig(name: "Full")
        registry.upsert(config)
        return (registry, config)
    }

    @MainActor
    func testPaginationResourcesAndPromptsAreExposedAndCallable() async throws {
        let stub = FullStubTransport()
        let (registry, config) = registry(stub)
        await registry.connect(config.id)
        XCTAssertEqual(registry.toolDefinitions().map(\.name), [
            "mcp__Full__a", "mcp__Full__b",
            "mcp__Full__mcp_get_prompt", "mcp__Full__mcp_list_prompts",
            "mcp__Full__mcp_list_resources", "mcp__Full__mcp_read_resource",
        ])
        let listing = try await registry.call("mcp__Full__mcp_list_resources", arguments: .object([:]))
        XCTAssertTrue(listing.contains("file:///readme.md") && listing.contains("file:///{path}"), listing)
        let read = try await registry.call("mcp__Full__mcp_read_resource", arguments: .object(["uri": .string("file:///readme.md")]))
        XCTAssertEqual(read, "# Hello")
        let prompts = try await registry.call("mcp__Full__mcp_list_prompts", arguments: .object([:]))
        XCTAssertTrue(prompts.contains("review") && prompts.contains("lang (required)"), prompts)
        let prompt = try await registry.call("mcp__Full__mcp_get_prompt", arguments: .object([
            "name": .string("review"), "arguments": .object(["lang": .string("swift")]),
        ]))
        XCTAssertEqual(prompt, "user: Review swift")
        // Synthetic routes follow the same approval rule as tools.
        XCTAssertFalse(registry.shouldAutoRun("mcp__Full__mcp_read_resource"))
    }

    @MainActor
    func testServerRequestsAreAnswered() async throws {
        let stub = FullStubTransport()
        let (registry, config) = registry(stub)
        let root = URL(fileURLWithPath: "/tmp/project", isDirectory: true)
        registry.setRoots([root])
        await registry.connect(config.id)

        stub.push(["jsonrpc": "2.0", "id": 7, "method": "ping"])
        let ping = await stub.waitForReply(id: 7)
        XCTAssertNotNil(ping?["result"])

        stub.push(["jsonrpc": "2.0", "id": 8, "method": "roots/list"])
        let roots = (await stub.waitForReply(id: 8))?["result"] as? [String: Any]
        XCTAssertEqual(((roots?["roots"] as? [[String: Any]])?.first?["uri"] as? String), root.absoluteString)

        // No sampler configured -> not advertised -> method not found.
        stub.push(["jsonrpc": "2.0", "id": 9, "method": "sampling/createMessage", "params": [:]])
        let sampling = (await stub.waitForReply(id: 9))?["error"] as? [String: Any]
        XCTAssertEqual(sampling?["code"] as? Int, -32601)
    }

    @MainActor
    func testElicitationWaitsForTheUserAndListChangedRefreshes() async throws {
        let stub = FullStubTransport()
        let (registry, config) = registry(stub)
        await registry.connect(config.id)

        stub.push(["jsonrpc": "2.0", "id": 11, "method": "elicitation/create", "params": [
            "message": "Your name?", "requestedSchema": ["type": "object", "properties": ["name": ["type": "string"]]],
        ]])
        for _ in 0..<200 where registry.interactions.isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
        let interaction = try XCTUnwrap(registry.interactions.first)
        XCTAssertEqual(interaction.kind, .elicitation)
        registry.answer(interaction.id, .accept(["name": .string("Ada")]))
        let reply = (await stub.waitForReply(id: 11))?["result"] as? [String: Any]
        XCTAssertEqual(reply?["action"] as? String, "accept")
        XCTAssertEqual((reply?["content"] as? [String: Any])?["name"] as? String, "Ada")

        stub.toolsVersion = 2
        stub.push(["jsonrpc": "2.0", "method": "notifications/tools/list_changed"])
        for _ in 0..<200 where registry.toolDefinitions().contains(where: { $0.name == "mcp__Full__b" }) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(registry.toolDefinitions().contains { $0.name == "mcp__Full__b" })
    }

    @MainActor
    func testSamplingRequiresApprovalThenRunsTheSampler() async throws {
        let stub = FullStubTransport()
        let (registry, config) = registry(stub)
        registry.sampler = { system, messages, _ in ("echo \(system)|\(messages.map(\.content).joined())", "m1") }
        await registry.connect(config.id)

        let params: [String: Any] = ["systemPrompt": "sys", "maxTokens": 10,
                                     "messages": [["role": "user", "content": ["type": "text", "text": "hi"]]]]
        stub.push(["jsonrpc": "2.0", "id": 21, "method": "sampling/createMessage", "params": params])
        for _ in 0..<200 where registry.interactions.isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
        registry.answer(try XCTUnwrap(registry.interactions.first).id, .decline)
        let denied = (await stub.waitForReply(id: 21))?["error"] as? [String: Any]
        XCTAssertNotNil(denied)

        stub.push(["jsonrpc": "2.0", "id": 22, "method": "sampling/createMessage", "params": params])
        for _ in 0..<200 where registry.interactions.isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
        registry.answer(try XCTUnwrap(registry.interactions.first).id, .approve)
        let result = (await stub.waitForReply(id: 22))?["result"] as? [String: Any]
        XCTAssertEqual((result?["content"] as? [String: Any])?["text"] as? String, "echo sys|hi")
        XCTAssertEqual(result?["model"] as? String, "m1")
    }

    func testOAuthDiscoveryHelpers() {
        let parsed = MCPOAuth.parseChallenge(#"Bearer realm="mcp", resource_metadata="https://api.example.com/.well-known/oauth-protected-resource/mcp", scope="read write""#)
        XCTAssertEqual(parsed.resourceMetadata?.absoluteString, "https://api.example.com/.well-known/oauth-protected-resource/mcp")
        XCTAssertEqual(parsed.scope, "read write")

        XCTAssertEqual(MCPOAuth.authorizationServerMetadataURLs(issuer: URL(string: "https://auth.example.com/tenant1")!).map(\.absoluteString), [
            "https://auth.example.com/.well-known/oauth-authorization-server/tenant1",
            "https://auth.example.com/.well-known/openid-configuration/tenant1",
            "https://auth.example.com/tenant1/.well-known/openid-configuration",
        ])
        XCTAssertEqual(MCPOAuth.authorizationServerMetadataURLs(issuer: URL(string: "https://auth.example.com")!).map(\.absoluteString), [
            "https://auth.example.com/.well-known/oauth-authorization-server",
            "https://auth.example.com/.well-known/openid-configuration",
        ])
        XCTAssertEqual(MCPOAuth.protectedResourceMetadataURLs(server: URL(string: "https://api.example.com/mcp")!).map(\.absoluteString), [
            "https://api.example.com/.well-known/oauth-protected-resource/mcp",
            "https://api.example.com/.well-known/oauth-protected-resource",
        ])
        XCTAssertEqual(MCPOAuth.canonicalResource(URL(string: "HTTPS://API.Example.com/mcp/#x")!), "https://api.example.com/mcp")

        let server = URL(string: "https://api.example.com/mcp")!
        XCTAssertEqual(try MCPOAuth.validatedResource(nil, server: server), "https://api.example.com/mcp")
        XCTAssertEqual(try MCPOAuth.validatedResource("https://api.example.com/mcp/", server: server), "https://api.example.com/mcp")
        XCTAssertEqual(try MCPOAuth.validatedResource("https://api.example.com", server: server), "https://api.example.com")
        XCTAssertThrowsError(try MCPOAuth.validatedResource("https://victim.example.org/api", server: server))
        XCTAssertThrowsError(try MCPOAuth.validatedResource("https://api.example.com/mcpx", server: server))
        let issuer = URL(string: "https://auth.example.com/tenant1")!
        XCTAssertNoThrow(try MCPOAuth.validateIssuer(["issuer": "https://auth.example.com/tenant1/"], issuer: issuer))
        XCTAssertNoThrow(try MCPOAuth.validateIssuer([:], issuer: issuer))
        XCTAssertThrowsError(try MCPOAuth.validateIssuer(["issuer": "https://evil.example.com"], issuer: issuer))
        XCTAssertNoThrow(try MCPOAuth.requireWebURL(URL(string: "https://auth.example.com/authorize")))
        XCTAssertNoThrow(try MCPOAuth.requireWebURL(URL(string: "http://127.0.0.1:8080/authorize")))
        for bad in ["file:///Applications/Calculator.app", "http://auth.example.com/authorize", "x-app://open", "https:///nohost"] {
            XCTAssertThrowsError(try MCPOAuth.requireWebURL(URL(string: bad)), bad)
        }

        let metadata = MCPOAuthServerMetadata(
            authorizationEndpoint: URL(string: "https://auth.example.com/authorize")!,
            tokenEndpoint: URL(string: "https://auth.example.com/token")!,
            registrationEndpoint: nil, scope: "read", resource: "https://api.example.com/mcp")
        let url = MCPOAuth.authorizeURL(metadata, clientID: "c1", redirectURI: "http://127.0.0.1:5000/callback", verifier: "v", state: "s")!
        let items = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(items["resource"], "https://api.example.com/mcp")
        XCTAssertEqual(items["code_challenge_method"], "S256")
        XCTAssertEqual(items["scope"], "read")
        XCTAssertEqual(items["client_id"], "c1")
    }

    func testLoopbackReceiverDeliversCallback() async throws {
        let receiver = try await LoopbackReceiver.start()
        defer { receiver.stop() }
        XCTAssertNotEqual(receiver.port, 0)
        let url = URL(string: "http://127.0.0.1:\(receiver.port)/callback?code=abc&state=xyz")!
        async let callback = receiver.waitForCallback(timeout: 10)
        _ = try await URLSession.shared.data(from: url)
        let received = try await callback
        XCTAssertEqual(URLComponents(url: received, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "code" }?.value, "abc")
    }

    func testContentRendering() {
        let text = MCPClient.render(content: [
            ["type": "text", "text": "hello"],
            ["type": "image", "mimeType": "image/png", "data": "AAAA"],
            ["type": "resource_link", "name": "doc", "uri": "file:///doc"],
            ["type": "resource", "resource": ["uri": "file:///x", "text": "inline"]],
        ])
        XCTAssertEqual(text, "hello\n[image image/png, 3 bytes]\n[resource doc: file:///doc]\ninline")
    }
}

/// Plays the protected resource + authorization server for the OAuth flow.
private final class FakeAuthServer: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var tokenForms: [[String: String]] = []

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "mcp.test" || request.url?.host == "auth.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let url = request.url!
        var body: [String: Any] = [:]
        switch url.path {
        case "/.well-known/oauth-protected-resource/mcp":
            body = ["resource": "https://mcp.test/mcp", "authorization_servers": ["https://auth.test"], "scopes_supported": ["mcp"]]
        case "/.well-known/oauth-authorization-server":
            body = ["authorization_endpoint": "https://auth.test/authorize", "token_endpoint": "https://auth.test/token",
                    "registration_endpoint": "https://auth.test/register", "code_challenge_methods_supported": ["S256"]]
        case "/register":
            body = ["client_id": "dyn-client"]
        case "/token":
            let raw = String(decoding: Self.bodyData(request), as: UTF8.self)
            let form = Dictionary(uniqueKeysWithValues: raw.split(separator: "&").map {
                let pair = $0.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
                return (pair[0], pair.count > 1 ? pair[1] : "")
            })
            Self.tokenForms.append(form)
            body = form["grant_type"] == "refresh_token"
                ? ["access_token": "at-2", "expires_in": 3600]
                : ["access_token": "at-1", "refresh_token": "rt-1", "expires_in": 3600]
        default:
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: body))
        client?.urlProtocolDidFinishLoading(self)
    }

    static func bodyData(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

final class MCPOAuthFlowTests: XCTestCase {
    @MainActor
    func testSignInDiscoversRegistersExchangesAndRefreshes() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakeAuthServer.self]
        let session = URLSession(configuration: configuration)
        let config = MCPServerConfig(name: "OAuth", url: "https://mcp.test/mcp")
        defer { MCPOAuth.save(nil, serverID: config.id) }

        try await MCPOAuth.signIn(
            config: config,
            challenge: #"Bearer resource_metadata="https://mcp.test/.well-known/oauth-protected-resource/mcp""#,
            session: session,
            open: { authorize in
                // Play the browser: the authorization server redirects with code + state.
                let items = URLComponents(url: authorize, resolvingAgainstBaseURL: false)!.queryItems!
                let value = { (name: String) in items.first { $0.name == name }?.value ?? "" }
                XCTAssertEqual(value("resource"), "https://mcp.test/mcp")
                XCTAssertEqual(value("client_id"), "dyn-client")
                XCTAssertEqual(value("scope"), "mcp")
                var redirect = URLComponents(string: value("redirect_uri"))!
                redirect.queryItems = [URLQueryItem(name: "code", value: "c0de"), URLQueryItem(name: "state", value: value("state"))]
                Task { _ = try? await URLSession.shared.data(from: redirect.url!) }
            }
        )
        let exchange = try XCTUnwrap(FakeAuthServer.tokenForms.last)
        XCTAssertEqual(exchange["code"], "c0de")
        XCTAssertEqual(exchange["resource"], "https://mcp.test/mcp")
        XCTAssertFalse((exchange["code_verifier"] ?? "").isEmpty)
        XCTAssertEqual(MCPOAuth.grant(serverID: config.id)?.accessToken, "at-1")

        let refreshed = await MCPOAuth.accessToken(serverID: config.id, forceRefresh: true, session: session)
        XCTAssertEqual(refreshed, "at-2")
        XCTAssertEqual(FakeAuthServer.tokenForms.last?["refresh_token"], "rt-1")
        XCTAssertEqual(MCPOAuth.grant(serverID: config.id)?.refreshToken, "rt-1")
    }
}

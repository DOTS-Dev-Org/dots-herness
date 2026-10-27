// Copyright (c) 2026 DOTS
// MCP authorization (spec revision 2025-06-18) for HTTP servers that answer 401:
//   WWW-Authenticate resource_metadata -> RFC 9728 protected-resource metadata
//   -> RFC 8414 / OIDC authorization-server metadata
//   -> RFC 7591 dynamic client registration
//   -> authorization code + PKCE (S256) with RFC 8707 `resource`, loopback redirect
// Grants live in the Keychain and are refreshed transparently by the transport.

import AppKit
import CryptoKit
import Foundation
import Network
import os

struct MCPOAuthGrant: Codable, Equatable, Sendable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date?
    var clientID: String
    var clientSecret: String?
    var tokenEndpoint: String
    var resource: String
}

struct MCPOAuthServerMetadata: Equatable, Sendable {
    var authorizationEndpoint: URL
    var tokenEndpoint: URL
    var registrationEndpoint: URL?
    var scope: String?
    var resource: String
}

enum MCPOAuth {
    private static let keychainService = "com.dots.herness.mcp.oauth"

    // MARK: Storage

    static func grant(serverID: String) -> MCPOAuthGrant? {
        MCPKeychain.token(for: serverID, service: keychainService)
            .flatMap { try? JSONDecoder().decode(MCPOAuthGrant.self, from: Data($0.utf8)) }
    }

    static func save(_ grant: MCPOAuthGrant?, serverID: String) {
        let text = grant.flatMap { try? JSONEncoder().encode($0) }.map { String(decoding: $0, as: UTF8.self) }
        MCPKeychain.setToken(text, for: serverID, service: keychainService)
    }

    /// A usable access token, refreshed when it is about to expire (or when the
    /// server just rejected it). Nil when there is no grant or refresh failed.
    static func accessToken(serverID: String, forceRefresh: Bool, session: URLSession = .shared) async -> String? {
        guard var grant = grant(serverID: serverID) else { return nil }
        let expiring = grant.expiresAt.map { $0.timeIntervalSinceNow < 60 } ?? false
        guard forceRefresh || expiring else { return grant.accessToken }
        guard let refreshToken = grant.refreshToken, let url = URL(string: grant.tokenEndpoint) else { return nil }
        var fields = [("grant_type", "refresh_token"), ("refresh_token", refreshToken),
                      ("client_id", grant.clientID), ("resource", grant.resource)]
        if let secret = grant.clientSecret { fields.append(("client_secret", secret)) }
        guard let object = try? await postForm(url, fields: fields, session: session),
              let access = object["access_token"] as? String else { return nil }
        grant.accessToken = access
        grant.refreshToken = object["refresh_token"] as? String ?? refreshToken
        grant.expiresAt = (object["expires_in"] as? Double).map { Date().addingTimeInterval($0) }
        save(grant, serverID: serverID)
        return access
    }

    // MARK: Discovery

    /// Parses `Bearer resource_metadata="…", scope="…"` (RFC 9728 §5.1).
    static func parseChallenge(_ header: String?) -> (resourceMetadata: URL?, scope: String?) {
        guard let header else { return (nil, nil) }
        var values: [String: String] = [:]
        let pattern = #/([A-Za-z_]+)\s*=\s*(?:"([^"]*)"|([^\s,]+))/#
        for match in header.matches(of: pattern) {
            values[String(match.1).lowercased()] = String(match.2 ?? match.3 ?? "")
        }
        return (values["resource_metadata"].flatMap(URL.init(string:)), values["scope"])
    }

    /// RFC 8414 §3.1 + OIDC Discovery orderings for an issuer with or without a path.
    static func authorizationServerMetadataURLs(issuer: URL) -> [URL] {
        guard var components = URLComponents(url: issuer, resolvingAgainstBaseURL: false) else { return [] }
        let path = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        components.query = nil
        components.fragment = nil
        func at(_ newPath: String) -> URL? { components.path = newPath; return components.url }
        if path.isEmpty {
            return [at("/.well-known/oauth-authorization-server"), at("/.well-known/openid-configuration")].compactMap { $0 }
        }
        return [
            at("/.well-known/oauth-authorization-server" + path),
            at("/.well-known/openid-configuration" + path),
            at(path + "/.well-known/openid-configuration"),
        ].compactMap { $0 }
    }

    /// RFC 9728 §3 well-known locations when the 401 carried no metadata URL.
    static func protectedResourceMetadataURLs(server: URL) -> [URL] {
        guard var components = URLComponents(url: server, resolvingAgainstBaseURL: false) else { return [] }
        let path = components.path == "/" ? "" : components.path
        components.query = nil
        components.fragment = nil
        var urls: [URL] = []
        if !path.isEmpty { components.path = "/.well-known/oauth-protected-resource" + path; components.url.map { urls.append($0) } }
        components.path = "/.well-known/oauth-protected-resource"
        components.url.map { urls.append($0) }
        return urls
    }

    /// The RFC 8707 resource indicator for the server: no fragment, lowercase
    /// scheme and host, no trailing slash.
    static func canonicalResource(_ server: URL) -> String {
        guard var components = URLComponents(url: server, resolvingAgainstBaseURL: false) else { return server.absoluteString }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        components.fragment = nil
        if components.path.hasSuffix("/") { components.path.removeLast() }
        return components.string ?? server.absoluteString
    }

    /// RFC 9728 §3.3: the advertised resource must be this server (or a path
    /// prefix of it on the same origin), else the token would be minted for
    /// whatever audience a hostile server names (confused deputy).
    static func validatedResource(_ advertised: String?, server: URL) throws -> String {
        let own = canonicalResource(server)
        guard let advertised else { return own }
        guard let url = URL(string: advertised) else {
            throw MCPError.transport("Protected resource metadata does not match the server URL.")
        }
        let claimed = canonicalResource(url)
        if claimed == own || own.hasPrefix(claimed + "/") { return claimed }
        throw MCPError.transport("Protected resource metadata does not match the server URL.")
    }

    /// Server-supplied endpoints end up in NSWorkspace.open and URLSession, so a
    /// hostile server must not hand over file:, custom-scheme or plain-http URLs.
    static func requireWebURL(_ url: URL?) throws -> URL {
        guard let url, let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased(), !host.isEmpty,
              scheme == "https" || (scheme == "http" && ["127.0.0.1", "localhost", "::1"].contains(host)) else {
            throw MCPError.transport("Authorization server endpoints must be https URLs.")
        }
        return url
    }

    /// RFC 8414 §3.3: metadata must name the issuer it was fetched for.
    static func validateIssuer(_ metadata: [String: Any], issuer: URL) throws {
        guard let claimed = metadata["issuer"] as? String else { return }
        let trim = { (value: String) in value.hasSuffix("/") ? String(value.dropLast()) : value }
        guard trim(claimed) == trim(issuer.absoluteString) else {
            throw MCPError.transport("Authorization server metadata names a different issuer.")
        }
    }

    static func discover(server: URL, challenge: String?, session: URLSession = .shared) async throws -> MCPOAuthServerMetadata {
        let parsed = parseChallenge(challenge)
        let candidates = parsed.resourceMetadata.map { [$0] } ?? protectedResourceMetadataURLs(server: server)
        var resourceMetadata: [String: Any]?
        for url in candidates {
            if let object = try? await getJSON(url, session: session) { resourceMetadata = object; break }
        }
        // Servers predating RFC 9728 act as their own authorization server.
        let issuer = (resourceMetadata?["authorization_servers"] as? [String])?.first.flatMap(URL.init(string:))
            ?? URLComponents(url: server, resolvingAgainstBaseURL: false).flatMap { components -> URL? in
                var origin = components
                origin.path = ""; origin.query = nil; origin.fragment = nil
                return origin.url
            }
        guard let issuer = try issuer.map(requireWebURL) else { throw MCPError.transport("The server did not name an authorization server.") }
        var metadata: [String: Any]?
        for url in authorizationServerMetadataURLs(issuer: issuer) {
            if let object = try? await getJSON(url, session: session) { metadata = object; break }
        }
        let scope = parsed.scope ?? (resourceMetadata?["scopes_supported"] as? [String])?.joined(separator: " ")
        let resource = try validatedResource(resourceMetadata?["resource"] as? String, server: server)
        if let metadata {
            try validateIssuer(metadata, issuer: issuer)
            guard let authorize = (metadata["authorization_endpoint"] as? String).flatMap(URL.init(string:)),
                  let token = (metadata["token_endpoint"] as? String).flatMap(URL.init(string:)) else {
                throw MCPError.transport("Authorization server metadata is missing its endpoints.")
            }
            if let methods = metadata["code_challenge_methods_supported"] as? [String], !methods.contains("S256") {
                throw MCPError.transport("The authorization server does not support PKCE S256.")
            }
            return MCPOAuthServerMetadata(
                authorizationEndpoint: try requireWebURL(authorize),
                tokenEndpoint: try requireWebURL(token),
                registrationEndpoint: try (metadata["registration_endpoint"] as? String).flatMap(URL.init(string:)).map(requireWebURL),
                scope: scope,
                resource: resource
            )
        }
        // 2025-03-26 fallback: default endpoints at the issuer root.
        return MCPOAuthServerMetadata(
            authorizationEndpoint: issuer.appendingPathComponent("authorize"),
            tokenEndpoint: issuer.appendingPathComponent("token"),
            registrationEndpoint: issuer.appendingPathComponent("register"),
            scope: scope,
            resource: resource
        )
    }

    static func register(_ metadata: MCPOAuthServerMetadata, redirectURI: String, session: URLSession = .shared) async throws -> (id: String, secret: String?) {
        guard let endpoint = metadata.registrationEndpoint else {
            throw MCPError.transport("The server needs a pre-registered OAuth client and offers no dynamic registration.")
        }
        var request = URLRequest(url: endpoint, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = [
            "client_name": "DotsHarness",
            "redirect_uris": [redirectURI],
            "grant_types": ["authorization_code", "refresh_token"],
            "response_types": ["code"],
            "token_endpoint_auth_method": "none",
        ]
        if let scope = metadata.scope { body["scope"] = scope }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0),
              let id = object["client_id"] as? String else {
            throw MCPError.transport("Client registration failed: \(object["error_description"] as? String ?? object["error"] as? String ?? "HTTP error")")
        }
        return (id, object["client_secret"] as? String)
    }

    static func authorizeURL(_ metadata: MCPOAuthServerMetadata, clientID: String, redirectURI: String, verifier: String, state: String) -> URL? {
        guard var components = URLComponents(url: metadata.authorizationEndpoint, resolvingAgainstBaseURL: false) else { return nil }
        var items = components.queryItems ?? []
        items += [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "code_challenge", value: Data(SHA256.hash(data: Data(verifier.utf8))).base64URL),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "resource", value: metadata.resource),
        ]
        if let scope = metadata.scope, !scope.isEmpty { items.append(URLQueryItem(name: "scope", value: scope)) }
        components.queryItems = items
        return components.url
    }

    // MARK: Interactive sign-in

    /// Runs the whole browser sign-in and stores the grant. `open` defaults to
    /// the user's browser; tests pass a closure that plays the browser's part.
    @MainActor
    static func signIn(
        config: MCPServerConfig,
        challenge: String?,
        session: URLSession = .shared,
        open: @escaping @Sendable (URL) -> Void = { url in Task { @MainActor in NSWorkspace.shared.open(url) } }
    ) async throws {
        guard let server = URL(string: config.url) else { throw MCPError.transport("invalid URL") }
        let metadata = try await discover(server: server, challenge: challenge, session: session)
        let receiver = try await LoopbackReceiver.start()
        defer { receiver.stop() }
        let redirectURI = "http://127.0.0.1:\(receiver.port)/callback"
        let client = try await register(metadata, redirectURI: redirectURI, session: session)
        let verifier = OAuthFlow.randomToken()
        let state = OAuthFlow.randomToken()
        guard let url = authorizeURL(metadata, clientID: client.id, redirectURI: redirectURI, verifier: verifier, state: state),
              (try? requireWebURL(url)) != nil else {
            throw MCPError.transport("Could not build the authorization URL.")
        }
        open(url)
        let callback = try await receiver.waitForCallback(timeout: 300)
        let query = Dictionary(
            (URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") },
            uniquingKeysWith: { first, _ in first }
        )
        guard query["state"] == state else { throw MCPError.transport("Sign-in state mismatch; try again.") }
        guard let code = query["code"] else {
            throw MCPError.transport("Sign-in was not completed: \(query["error_description"] ?? query["error"] ?? "no code")")
        }
        var fields = [("grant_type", "authorization_code"), ("code", code), ("redirect_uri", redirectURI),
                      ("client_id", client.id), ("code_verifier", verifier), ("resource", metadata.resource)]
        if let secret = client.secret { fields.append(("client_secret", secret)) }
        let object = try await postForm(metadata.tokenEndpoint, fields: fields, session: session)
        guard let access = object["access_token"] as? String else {
            throw MCPError.transport("The token response did not include an access token.")
        }
        save(MCPOAuthGrant(
            accessToken: access,
            refreshToken: object["refresh_token"] as? String,
            expiresAt: (object["expires_in"] as? Double).map { Date().addingTimeInterval($0) },
            clientID: client.id,
            clientSecret: client.secret,
            tokenEndpoint: metadata.tokenEndpoint.absoluteString,
            resource: metadata.resource
        ), serverID: config.id)
    }

    // MARK: HTTP

    private static func getJSON(_ url: URL, session: URLSession) async throws -> [String: Any] {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("2025-06-18", forHTTPHeaderField: "MCP-Protocol-Version")
        let (data, response) = try await session.data(for: request)
        guard (200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MCPError.transport("no metadata at \(url)")
        }
        return object
    }

    private static func postForm(_ url: URL, fields: [(String, String)], session: URLSession) async throws -> [String: Any] {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        request.httpBody = Data(fields.map {
            "\($0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.1)"
        }.joined(separator: "&").utf8)
        let (data, response) = try await session.data(for: request)
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0) else {
            throw MCPError.transport("Token request failed: \(object["error_description"] as? String ?? object["error"] as? String ?? "HTTP error")")
        }
        return object
    }
}

// MARK: - Loopback redirect receiver

/// One-shot HTTP listener on 127.0.0.1 with an OS-assigned port (RFC 8252 §7.3).
final class LoopbackReceiver: @unchecked Sendable {
    private let listener: NWListener
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var received: URL?
    private(set) var port: UInt16 = 0

    private init(listener: NWListener) {
        self.listener = listener
    }

    static func start() async throws -> LoopbackReceiver {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let queue = DispatchQueue(label: "mcp.oauth.loopback")
        let receiver = LoopbackReceiver(listener: listener)
        // NWListener refuses to start without a connection handler.
        listener.newConnectionHandler = { [weak receiver] connection in receiver?.accept(connection, queue: queue) }
        receiver.port = try await withCheckedThrowingContinuation { continuation in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            listener.stateUpdateHandler = { state in
                let result: Result<UInt16, Error>
                switch state {
                case .ready: result = .success(listener.port?.rawValue ?? 0)
                case .failed(let error): result = .failure(error)
                default: return
                }
                guard resumed.withLock({ done in defer { done = true }; return !done }) else { return }
                continuation.resume(with: result)
            }
            listener.start(queue: queue)
        }
        return receiver
    }

    private func accept(_ connection: NWConnection, queue: DispatchQueue) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            let firstLine = data.flatMap { String(data: $0, encoding: .utf8) }?.components(separatedBy: "\r\n").first ?? ""
            let parts = firstLine.split(separator: " ")
            let path = parts.count > 1 ? String(parts[1]) : ""
            let body = "Sign-in received. You can close this tab and return to DotsHarness."
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nConnection: close\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            guard path.hasPrefix("/callback"), let url = URL(string: "http://127.0.0.1\(path)") else { return }
            self?.deliver(.success(url))
        }
    }

    private func deliver(_ result: Result<URL, Error>) {
        lock.lock()
        let waiting = continuation
        continuation = nil
        if waiting == nil, case .success(let url) = result { received = url }
        lock.unlock()
        waiting?.resume(with: result)
    }

    func waitForCallback(timeout: TimeInterval) async throws -> URL {
        let timer = Task { [weak self] in
            try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            self?.deliver(.failure(MCPError.transport("Sign-in timed out.")))
        }
        defer { timer.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let received {
                lock.unlock()
                continuation.resume(returning: received)
                return
            }
            self.continuation = continuation
            lock.unlock()
        }
    }

    func stop() {
        listener.cancel()
        deliver(.failure(MCPError.transport("Sign-in cancelled.")))
    }
}

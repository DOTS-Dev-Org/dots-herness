// Copyright (c) 2026 DOTS
// Generic OAuth 2.0 + PKCE engine. One implementation, parameterised entirely
// by a `ProviderSpec.OAuthSpec`, so Claude, Codex/GPT and any future OAuth
// provider are just registry entries rather than bespoke code paths.

import CryptoKit
import Foundation

public struct OAuthTokens: Sendable, Equatable {
    public var accessToken: String
    public var refreshToken: String?
    public var idToken: String?
    public var email: String?
    public var accountID: String?
}

public struct OAuthFlow: Sendable {
    public let spec: ProviderSpec.OAuthSpec
    public let session: URLSession

    public init(spec: ProviderSpec.OAuthSpec, session: URLSession = .shared) {
        self.spec = spec
        self.session = session
    }

    // MARK: PKCE material

    public static func randomToken() -> String {
        Data((0..<32).map { _ in UInt8.random(in: 0...255) }).base64URL
    }

    public func challenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
    }

    public func authorizeURL(verifier: String, state: String) -> URL? {
        guard var components = URLComponents(string: spec.authorizeURL) else { return nil }
        var items = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: spec.clientID),
            URLQueryItem(name: "redirect_uri", value: spec.redirectURI),
            URLQueryItem(name: "scope", value: spec.scopes),
            URLQueryItem(name: "code_challenge", value: challenge(for: verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]
        for (key, value) in spec.extraAuthorizeParams.sorted(by: { $0.key < $1.key }) {
            items.append(URLQueryItem(name: key, value: value))
        }
        components.queryItems = items
        return components.url
    }

    // MARK: Token exchange

    public func exchange(code rawCode: String, verifier: String, state: String? = nil) async throws -> OAuthTokens {
        // Claude hands back `code#state`; split it and keep both halves.
        let parts = spec.manualCodeSeparator.map { rawCode.components(separatedBy: $0) } ?? [rawCode]
        let code = parts.first ?? rawCode
        // Anthropic's token endpoint rejects the request (HTTP 400) unless `state`
        // is echoed back. Prefer the fragment from the code, fall back to the
        // state we generated for the authorize URL.
        let resolvedState = (parts.count > 1 ? parts.last : nil) ?? state
        var fields: [(String, String)] = [
            ("grant_type", "authorization_code"),
            ("code", code),
            ("redirect_uri", spec.redirectURI),
            ("client_id", spec.clientID),
            ("code_verifier", verifier),
        ] + Self.secretField(spec)
        if let resolvedState, !resolvedState.isEmpty { fields.append(("state", resolvedState)) }
        fields += spec.extraTokenParams.sorted(by: { $0.key < $1.key })
        return try await post(fields, encoding: spec.tokenEncoding)
    }

    // MARK: Device code

    public struct DeviceCode: Sendable, Equatable {
        public var deviceCode: String
        public var userCode: String
        public var verificationURL: String
        public var interval: Int
    }

    /// Starts an RFC 8628 device flow. The user types `userCode` at
    /// `verificationURL`; `pollDevice` then waits for them to finish.
    public func startDevice() async throws -> DeviceCode {
        guard let raw = spec.deviceCodeURL, let url = URL(string: raw) else {
            throw RouterTestError.message("This provider does not support device sign-in.")
        }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formBody([("client_id", spec.clientID), ("scope", spec.scopes)])
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(status),
              let deviceCode = object["device_code"] as? String,
              let userCode = object["user_code"] as? String else {
            throw RouterTestError.message(
                object["error_description"] as? String ?? object["error"] as? String ?? "HTTP \(status)"
            )
        }
        return DeviceCode(
            deviceCode: deviceCode,
            userCode: userCode,
            verificationURL: object["verification_uri_complete"] as? String
                ?? object["verification_uri"] as? String ?? "",
            interval: object["interval"] as? Int ?? 5
        )
    }

    /// Polls the token endpoint until the user approves, the code expires, or
    /// `deadline` passes. `authorization_pending` / `slow_down` are the flow's
    /// normal "keep waiting" answers, not failures.
    public func pollDevice(_ device: DeviceCode, timeout: TimeInterval = 300) async throws -> OAuthTokens {
        var wait = max(1, device.interval)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try await Task.sleep(nanoseconds: UInt64(wait) * 1_000_000_000)
            do {
                return try await post(
                    [
                        ("grant_type", "urn:ietf:params:oauth:grant-type:device_code"),
                        ("device_code", device.deviceCode),
                        ("client_id", spec.clientID),
                    ] + Self.secretField(spec),
                    encoding: spec.tokenEncoding
                )
            } catch let failure as RouterTestError {
                let message = failure.errorDescription ?? ""
                if message.contains("slow_down") { wait += 5; continue }
                if message.contains("authorization_pending") { continue }
                throw failure
            }
        }
        throw RouterTestError.message("The sign-in request timed out. Start it again.")
    }

    public func refresh(_ refreshToken: String) async throws -> OAuthTokens {
        let fields: [(String, String)] = [
            ("grant_type", "refresh_token"),
            ("refresh_token", refreshToken),
            ("client_id", spec.clientID),
        ] + Self.secretField(spec) + spec.extraTokenParams.sorted(by: { $0.key < $1.key })
        return try await post(fields, encoding: spec.refreshEncoding)
    }

    // MARK: Transport

    private func post(_ fields: [(String, String)], encoding: ProviderSpec.Encoding) async throws -> OAuthTokens {
        guard let url = URL(string: spec.tokenURL) else { throw RouterTestError.message("Invalid token endpoint") }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "POST"
        switch encoding {
        case .form:
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Self.formBody(fields)
        case .json:
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: Dictionary(fields, uniquingKeysWith: { _, last in last }))
        }

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(status) else {
            // Keep the raw `error` code in the text: the device flow branches on
            // `authorization_pending` / `slow_down`, which only appear there.
            let code = object["error"] as? String
            let message = [code, object["error_description"] as? String]
                .compactMap { $0 }
                .joined(separator: ": ")
            throw RouterTestError.message(message.isEmpty ? "HTTP \(status)" : message)
        }
        guard let access = object["access_token"] as? String else {
            throw RouterTestError.message("The token response did not include an access token.")
        }
        let idToken = object["id_token"] as? String
        let claims = idToken.map(Self.jwtClaims) ?? [:]
        return OAuthTokens(
            accessToken: access,
            refreshToken: object["refresh_token"] as? String,
            idToken: idToken,
            email: claims["email"] as? String,
            accountID: Self.chatGPTAccountID(claims) ?? object["account_id"] as? String
        )
    }

    /// OpenAI nests the account id under a namespaced claim in the id_token;
    /// older tokens carried it at the top level.
    public static func chatGPTAccountID(_ claims: [String: Any]) -> String? {
        if let auth = claims["https://api.openai.com/auth"] as? [String: Any],
           let id = auth["chatgpt_account_id"] as? String, !id.isEmpty {
            return id
        }
        return (claims["chatgpt_account_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Confidential clients (Google's CLI) must echo their client secret on every
    /// token call; public clients (Claude, Codex, xAI) send nothing.
    private static func secretField(_ spec: ProviderSpec.OAuthSpec) -> [(String, String)] {
        guard let secret = spec.clientSecret, !secret.isEmpty else { return [] }
        return [("client_secret", secret)]
    }

    static func formBody(_ fields: [(String, String)]) -> Data? {
        fields
            .map { "\($0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.1)" }
            .joined(separator: "&")
            .data(using: .utf8)
    }

    public static func jwtClaims(_ token: String) -> [String: Any] {
        let parts = token.split(separator: ".")
        guard parts.count > 1 else { return [:] }
        // JWT segments are base64url; translate back before decoding.
        let base64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padded = base64 + String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: padded, options: .ignoreUnknownCharacters),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return value
    }
}

extension Data {
    var base64URL: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

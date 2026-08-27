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

    public init(spec: ProviderSpec.OAuthSpec) {
        self.spec = spec
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

    public func exchange(code rawCode: String, verifier: String) async throws -> OAuthTokens {
        // Claude hands back `code#state`; keep only the code.
        let code = spec.manualCodeSeparator
            .flatMap { rawCode.components(separatedBy: $0).first }
            ?? rawCode
        let fields: [(String, String)] = [
            ("grant_type", "authorization_code"),
            ("code", code),
            ("redirect_uri", spec.redirectURI),
            ("client_id", spec.clientID),
            ("code_verifier", verifier),
        ] + spec.extraTokenParams.sorted(by: { $0.key < $1.key })
        return try await post(fields, encoding: spec.tokenEncoding)
    }

    public func refresh(_ refreshToken: String) async throws -> OAuthTokens {
        let fields: [(String, String)] = [
            ("grant_type", "refresh_token"),
            ("refresh_token", refreshToken),
            ("client_id", spec.clientID),
        ] + spec.extraTokenParams.sorted(by: { $0.key < $1.key })
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
            request.httpBody = fields
                .map { "\($0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.1)" }
                .joined(separator: "&")
                .data(using: .utf8)
        case .json:
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: Dictionary(fields, uniquingKeysWith: { _, last in last }))
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(status) else {
            let message = object["error_description"] as? String
                ?? object["error"] as? String
                ?? "HTTP \(status)"
            throw RouterTestError.message(message)
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
            accountID: claims["chatgpt_account_id"] as? String
        )
    }

    public static func jwtClaims(_ token: String) -> [String: Any] {
        let parts = token.split(separator: ".")
        guard parts.count > 1 else { return [:] }
        let padded = String(parts[1]) + String(repeating: "=", count: (4 - parts[1].count % 4) % 4)
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

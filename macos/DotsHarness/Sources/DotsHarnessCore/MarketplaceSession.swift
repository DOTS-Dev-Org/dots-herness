// Copyright (c) 2026 DOTS
// HerNess account session used by the native Marketplace publisher.

import AppKit
import CryptoKit
import Foundation
import Security

public struct MarketplaceUserProfile: Codable, Sendable, Equatable {
    public var id: String
    public var email: String
    public var name: String
    public var surname: String
    public var username: String?
    public var workspaceID: String?
    public var workspaceName: String?
    public var workspaceRole: String?

    enum CodingKeys: String, CodingKey {
        case id, email, name, surname, username
        case workspaceID = "workspace_id"
        case workspaceName = "workspace_name"
        case workspaceRole = "workspace_role"
    }
}

public enum MarketplaceProvider: String, CaseIterable, Identifiable, Sendable {
    case google
    case github

    public var id: String { rawValue }
    public var title: String { rawValue == "google" ? "Google" : "GitHub" }
}

public enum MarketplaceSessionError: LocalizedError, Sendable {
    case notSignedIn
    case invalidCallback
    case stateMismatch
    case requestFailed(Int, String)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .notSignedIn: return "Marketplace publishing requires a HerNess account."
        case .invalidCallback: return "The HerNess sign-in callback was invalid."
        case .stateMismatch: return "The HerNess sign-in state did not match."
        case let .requestFailed(status, message): return "Marketplace request failed (HTTP \(status)): \(message)"
        case .invalidResponse: return "The Marketplace returned an invalid response."
        }
    }
}

@MainActor
public final class MarketplaceSession: ObservableObject {
    public static let defaultAPIBase = URL(string: "https://dotsherness-unified-backend.dotsherness-unified-backend.workers.dev")!
    private static let keychainService = "com.dots.dotsharness.marketplace"
    private static let accessAccount = "access-token"
    private static let refreshAccount = "refresh-token"

    @Published public private(set) var profile: MarketplaceUserProfile?
    @Published public private(set) var isSignedIn: Bool
    @Published public private(set) var isLoading = false
    @Published public private(set) var lastError: String?

    public let apiBase: URL
    private var accessToken: String?
    private var refreshToken: String?
    private var pendingVerifier: String?
    private var pendingState: String?

    public init(apiBase: URL = MarketplaceSession.defaultAPIBase) {
        self.apiBase = apiBase
        accessToken = Self.keychainRead(Self.accessAccount)
        refreshToken = Self.keychainRead(Self.refreshAccount)
        isSignedIn = accessToken?.isEmpty == false
    }

    public func restore() async {
        guard isSignedIn else { return }
        do {
            try await fetchProfile()
        } catch {
            accessToken = nil
            profile = nil
            isSignedIn = false
            lastError = nil
        }
    }

    public func beginOAuth(_ provider: MarketplaceProvider) {
        let verifier = OAuthFlow.randomToken() + OAuthFlow.randomToken()
        let state = OAuthFlow.randomToken()
        pendingVerifier = verifier
        pendingState = state
        var components = URLComponents(
            url: apiBase.appendingPathComponent("api/auth/\(provider.rawValue)"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "client", value: "desktop"),
            URLQueryItem(name: "code_challenge", value: Data(SHA256.hash(data: Data(verifier.utf8))).base64URL),
            URLQueryItem(name: "client_state", value: state),
            URLQueryItem(name: "terms_version", value: "2026-08-26"),
            URLQueryItem(name: "privacy_notice_version", value: "2026-08-26"),
            URLQueryItem(name: "locale", value: "tr"),
        ]
        guard let url = components?.url else {
            lastError = MarketplaceSessionError.invalidCallback.localizedDescription
            return
        }
        NSWorkspace.shared.open(url)
    }

    public func signIn(email: String, password: String) async throws {
        let normalizedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedEmail.isEmpty, !password.isEmpty else {
            throw MarketplaceSessionError.requestFailed(400, "Email ve şifre gerekli.")
        }
        let payload = try JSONEncoder().encode([
            "email": normalizedEmail,
            "password": password,
        ])
        var request = URLRequest(url: apiBase.appendingPathComponent("api/auth/login"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = payload
        let (data, response) = try await URLSession.shared.data(for: request)
        try acceptTokenResponse(data, response: response)
        try await fetchProfile()
    }

    public func handleOAuthCallback(_ url: URL) async {
        guard url.scheme == "herness", url.host == "oauth", url.path == "/desktop",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let code = components.queryItems?.first(where: { $0.name == "code" })?.value,
              let state = components.queryItems?.first(where: { $0.name == "state" })?.value,
              let verifier = pendingVerifier else {
            lastError = MarketplaceSessionError.invalidCallback.localizedDescription
            return
        }
        guard state == pendingState else {
            lastError = MarketplaceSessionError.stateMismatch.localizedDescription
            return
        }
        pendingVerifier = nil
        pendingState = nil
        isLoading = true
        defer { isLoading = false }
        do {
            let payload: [String: String] = [
                "code": code,
                "code_verifier": verifier,
                "client": "desktop",
            ]
            let data = try JSONEncoder().encode(payload)
            var request = URLRequest(url: apiBase.appendingPathComponent("api/auth/desktop/exchange"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = data
            let (responseData, response) = try await URLSession.shared.data(for: request)
            try acceptTokenResponse(responseData, response: response)
            try await fetchProfile()
        } catch {
            lastError = error.localizedDescription
        }
    }

    public func signOut() async {
        if let refreshToken {
            var request = URLRequest(url: apiBase.appendingPathComponent("api/auth/logout"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONEncoder().encode(["refresh_token": refreshToken])
            _ = try? await URLSession.shared.data(for: request)
        }
        accessToken = nil
        refreshToken = nil
        profile = nil
        isSignedIn = false
        Self.keychainDelete(Self.accessAccount)
        Self.keychainDelete(Self.refreshAccount)
    }

    public func fetchProfile() async throws {
        let (data, response) = try await authorizedData(path: "api/user/profile")
        guard (200..<300).contains(response.statusCode) else {
            throw MarketplaceSessionError.requestFailed(response.statusCode, String(decoding: data, as: UTF8.self))
        }
        profile = try JSONDecoder().decode(MarketplaceUserProfile.self, from: data)
    }

    public func authorizedData(path: String, method: String = "GET", body: Data? = nil, contentType: String? = nil) async throws -> (Data, HTTPURLResponse) {
        guard accessToken != nil else { throw MarketplaceSessionError.notSignedIn }
        let url = apiBase.appendingPathComponent(path)
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("Bearer \(accessToken!)", forHTTPHeaderField: "Authorization")
        if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw MarketplaceSessionError.invalidResponse }
        if http.statusCode == 401, let refreshToken {
            do {
                try await refresh(refreshToken)
            } catch {
                accessToken = nil
                self.refreshToken = nil
                profile = nil
                isSignedIn = false
                Self.keychainDelete(Self.accessAccount)
                Self.keychainDelete(Self.refreshAccount)
                throw error
            }
            var retry = request
            retry.setValue("Bearer \(accessToken!)", forHTTPHeaderField: "Authorization")
            let (retryData, retryResponse) = try await URLSession.shared.data(for: retry)
            guard let retryHTTP = retryResponse as? HTTPURLResponse else { throw MarketplaceSessionError.invalidResponse }
            return (retryData, retryHTTP)
        }
        return (data, http)
    }

    private func refresh(_ token: String) async throws {
        let payload = try JSONEncoder().encode(["refresh_token": token])
        var request = URLRequest(url: apiBase.appendingPathComponent("api/auth/refresh"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = payload
        let (data, response) = try await URLSession.shared.data(for: request)
        try acceptTokenResponse(data, response: response)
    }

    private func acceptTokenResponse(_ data: Data, response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw MarketplaceSessionError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw MarketplaceSessionError.requestFailed(http.statusCode, String(decoding: data, as: UTF8.self))
        }
        struct TokenResponse: Decodable { var access_token: String; var refresh_token: String? }
        let tokens = try JSONDecoder().decode(TokenResponse.self, from: data)
        accessToken = tokens.access_token
        isSignedIn = true
        if let refresh = tokens.refresh_token { refreshToken = refresh }
        Self.keychainWrite(accessToken, Self.accessAccount)
        Self.keychainWrite(refreshToken, Self.refreshAccount)
    }

    private static func keychainQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
        ]
    }

    private static func keychainWrite(_ value: String?, _ account: String) {
        let query = keychainQuery(account)
        SecItemDelete(query as CFDictionary)
        guard let value, !value.isEmpty else { return }
        var item = query
        item[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(item as CFDictionary, nil)
    }

    private static func keychainRead(_ account: String) -> String? {
        var query = keychainQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func keychainDelete(_ account: String) {
        SecItemDelete(keychainQuery(account) as CFDictionary)
    }
}

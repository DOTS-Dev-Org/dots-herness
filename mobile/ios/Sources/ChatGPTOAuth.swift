import AuthenticationServices
import CryptoKit
import Foundation
import UIKit

struct ChatGPTAccountProfile: Codable, Identifiable, Equatable {
    let id: String
    var email: String
    var title: String { email.isEmpty ? "ChatGPT · …\(id.suffix(6))" : email }
}

/// The existing desktop GPT OAuth contract, adapted to a mobile callback. It is
/// a public PKCE client: no client secret is ever accepted or persisted.
@MainActor
final class ChatGPTOAuth: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    @Published private(set) var accessToken = ""
    @Published private(set) var accountID = ""
    @Published private(set) var accounts: [ChatGPTAccountProfile] = []
    @Published private(set) var status = ""
    @Published private(set) var isSigningIn = false

    private let secure = SecureStore()
    private var session: ASWebAuthenticationSession?
    private let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    private let callback = "herness://oauth/openai"

    override init() {
        super.init()
        migrateLegacyAccount()
        reloadAccounts()
    }

    func start() {
        let verifier = Self.randomToken()
        let state = Self.randomToken()
        secure.write(verifier, key: "oauth.openai.verifier")
        secure.write(state, key: "oauth.openai.state")
        guard var components = URLComponents(string: "https://auth.openai.com/oauth/authorize") else { return }
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: callback),
            URLQueryItem(name: "scope", value: "openid profile email offline_access"),
            URLQueryItem(name: "prompt", value: "select_account"),
            URLQueryItem(name: "code_challenge", value: Self.challenge(verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "id_token_add_organizations", value: "true"),
            URLQueryItem(name: "codex_cli_simplified_flow", value: "true"),
            URLQueryItem(name: "originator", value: "dots_harness"),
        ]
        guard let url = components.url else { return }
        isSigningIn = true
        status = "Waiting for ChatGPT authorization…"
        let auth = ASWebAuthenticationSession(url: url, callbackURLScheme: "herness") { [weak self] callbackURL, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.session = nil
                if let callbackURL { _ = self.handleCallback(callbackURL) }
                else if let error, (error as NSError).code != ASWebAuthenticationSessionError.canceledLogin.rawValue { self.status = error.localizedDescription; self.isSigningIn = false }
                else { self.status = "ChatGPT sign-in cancelled."; self.isSigningIn = false }
            }
        }
        auth.presentationContextProvider = self
        session = auth
        guard auth.start() else { session = nil; isSigningIn = false; status = "Could not open ChatGPT sign-in."; return }
    }

    @discardableResult
    func handleCallback(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "herness", url.host?.lowercased() == "oauth", url.path == "/openai" else { return false }
        let values = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).compactMap { item in item.value.map { (item.name, $0) } })
        if let error = values["error"] { status = values["error_description"] ?? error; isSigningIn = false; return true }
        // ponytail: explicit non-empty expected state; nil==nil must never pass.
        guard let expectedState = secure.read("oauth.openai.state"), !expectedState.isEmpty,
              let returnedState = values["state"], returnedState == expectedState,
              let code = values["code"], let verifier = secure.read("oauth.openai.verifier") else {
            status = "ChatGPT OAuth state mismatch. Start sign-in again."
            isSigningIn = false
            return true
        }
        secure.delete("oauth.openai.state")
        secure.delete("oauth.openai.verifier")
        isSigningIn = true
        Task { await exchange(code: code, verifier: verifier) }
        return true
    }

    func refreshIfNeeded() async {
        for profile in accounts {
            let token = Self.accessToken(for: profile.id)
            let expiry = (Self.jwtClaims(token)["exp"] as? NSNumber)?.doubleValue
            guard token.isEmpty || expiry.map({ $0 <= Date().timeIntervalSince1970 + 60 }) == true else { continue }
            guard let refreshToken = secure.read(Self.key("refresh", profile.id)), !refreshToken.isEmpty else { continue }
            await refresh(refreshToken, accountID: profile.id)
        }
        reloadAccounts()
    }

    func signOut() { removeAccount(accountID) }

    func selectAccount(_ id: String) {
        guard accounts.contains(where: { $0.id == id }) else { return }
        secure.write(id, key: "oauth.openai.active_account")
        reloadAccounts()
        persistActiveOAuthReference()
    }

    func removeAccount(_ id: String) {
        guard !id.isEmpty else { return }
        secure.delete(Self.key("access", id))
        secure.delete(Self.key("refresh", id))
        accounts.removeAll { $0.id == id }
        saveAccounts()
        if secure.read("oauth.openai.active_account") == id {
            secure.write(accounts.first?.id ?? "", key: "oauth.openai.active_account")
        }
        reloadAccounts()
        persistActiveOAuthReference()
        status = accounts.isEmpty ? "Signed out of ChatGPT on this device." : "ChatGPT account removed."
    }

    func accessToken(for id: String) -> String { Self.accessToken(for: id) }

    static func activeAccountID() -> String {
        let secure = SecureStore()
        if let id = secure.read("oauth.openai.active_account"), !id.isEmpty { return id }
        return secure.read("oauth.openai.account") ?? ""
    }

    static func accountIDs() -> [String] {
        let secure = SecureStore()
        if let data = secure.read("oauth.openai.accounts")?.data(using: .utf8),
           let values = try? JSONDecoder().decode([ChatGPTAccountProfile].self, from: data), !values.isEmpty {
            return values.map(\.id)
        }
        let legacy = secure.read("oauth.openai.account") ?? ""
        return legacy.isEmpty ? [] : [legacy]
    }

    static func accessToken(for id: String) -> String {
        guard !id.isEmpty else { return "" }
        let secure = SecureStore()
        return secure.read(key("access", id))
            ?? (secure.read("oauth.openai.account") == id ? secure.read("oauth.openai.access") : nil)
            ?? ""
    }

    static func activeCredentialReference() -> String {
        let id = activeAccountID()
        return id.isEmpty ? "keychain:oauth.openai.accounts" : "keychain:\(key("access", id))"
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first(where: \.isKeyWindow) ?? UIWindow()
    }

    private func exchange(code: String, verifier: String) async {
        await requestToken(fields: [("grant_type", "authorization_code"), ("code", code), ("redirect_uri", callback), ("client_id", clientID), ("code_verifier", verifier)])
    }

    private func refresh(_ token: String, accountID: String) async {
        await requestToken(fields: [("grant_type", "refresh_token"), ("refresh_token", token), ("client_id", clientID)], existingAccountID: accountID)
    }

    private func requestToken(fields: [(String, String)], existingAccountID: String? = nil) async {
        defer { isSigningIn = false }
        guard let url = URL(string: "https://auth.openai.com/oauth/token") else { return }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.form(fields)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            guard (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true, let value = object["access_token"] as? String, !value.isEmpty else {
                status = object["error_description"] as? String ?? "ChatGPT token exchange failed."
                return
            }
            let identityToken = object["id_token"] as? String ?? value
            let claims = Self.jwtClaims(identityToken)
            let auth = claims["https://api.openai.com/auth"] as? [String: Any]
            let resolvedID = auth?["chatgpt_account_id"] as? String
                ?? claims["chatgpt_account_id"] as? String
                ?? object["account_id"] as? String
                ?? existingAccountID
                ?? ""
            guard !resolvedID.isEmpty else {
                status = "ChatGPT did not return an account identity. The existing account was kept."
                return
            }
            if let existingAccountID {
                guard accounts.contains(where: { $0.id == existingAccountID }) else { return }
                guard resolvedID == existingAccountID else {
                    status = "The ChatGPT account identity changed during token refresh. The existing profile was kept."
                    return
                }
            }
            secure.write(value, key: Self.key("access", resolvedID))
            if let refresh = object["refresh_token"] as? String { secure.write(refresh, key: Self.key("refresh", resolvedID)) }
            let email = claims["email"] as? String ?? ""
            if let existing = accounts.firstIndex(where: { $0.id == resolvedID }) {
                accounts[existing] = ChatGPTAccountProfile(id: resolvedID, email: email.isEmpty ? accounts[existing].email : email)
            } else {
                accounts.append(ChatGPTAccountProfile(id: resolvedID, email: email))
            }
            saveAccounts()
            if existingAccountID == nil {
                secure.write(resolvedID, key: "oauth.openai.active_account")
            }
            reloadAccounts()
            if existingAccountID == nil || Self.activeAccountID() == resolvedID {
                persistActiveOAuthReference()
            }
            status = "Signed in to ChatGPT."
        } catch { status = error.localizedDescription }
    }

    private func migrateLegacyAccount() {
        guard let id = secure.read("oauth.openai.account"), !id.isEmpty,
              let token = secure.read("oauth.openai.access"), !token.isEmpty else { return }
        let accessKey = Self.key("access", id)
        if secure.read(accessKey) == nil { secure.write(token, key: accessKey) }
        if let refresh = secure.read("oauth.openai.refresh") {
            let refreshKey = Self.key("refresh", id)
            if secure.read(refreshKey) == nil { secure.write(refresh, key: refreshKey) }
        }
        var rows = decodeAccounts()
        if !rows.contains(where: { $0.id == id }) { rows.append(ChatGPTAccountProfile(id: id, email: "")) }
        accounts = rows
        saveAccounts()
        secure.write(id, key: "oauth.openai.active_account")
        secure.delete("oauth.openai.access")
        secure.delete("oauth.openai.refresh")
        secure.delete("oauth.openai.account")
    }

    private func decodeAccounts() -> [ChatGPTAccountProfile] {
        guard let data = secure.read("oauth.openai.accounts")?.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([ChatGPTAccountProfile].self, from: data)) ?? []
    }

    private func saveAccounts() {
        guard let data = try? JSONEncoder().encode(accounts), let value = String(data: data, encoding: .utf8) else { return }
        secure.write(value, key: "oauth.openai.accounts")
    }

    private func reloadAccounts() {
        accounts = decodeAccounts()
        let active = secure.read("oauth.openai.active_account") ?? ""
        let selected = accounts.contains(where: { $0.id == active }) ? active : accounts.first?.id ?? ""
        accountID = selected
        accessToken = Self.accessToken(for: selected)
        if !selected.isEmpty, selected != active { secure.write(selected, key: "oauth.openai.active_account") }
    }

    private func persistActiveOAuthReference() {
        let reference = accountID.isEmpty ? "keychain:oauth.openai.accounts" : "keychain:\(Self.key("access", accountID))"
        MobileStateStore().saveOAuth(provider: "gpt", accountReference: reference)
    }

    private static func key(_ kind: String, _ id: String) -> String {
        let digest = SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
        return "oauth.openai.profile.\(digest).\(kind)"
    }

    private static func randomToken() -> String { base64URL(Data((0..<32).map { _ in UInt8.random(in: 0...255) })) }
    private static func challenge(_ value: String) -> String { base64URL(Data(SHA256.hash(data: Data(value.utf8)))) }
    private static func base64URL(_ data: Data) -> String { data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").trimmingCharacters(in: CharacterSet(charactersIn: "=")) }
    private static func jwtClaims(_ token: String) -> [String: Any] {
        let parts = token.split(separator: ".")
        guard parts.count > 1 else { return [:] }
        let raw = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let padded = raw + String(repeating: "=", count: (4 - raw.count % 4) % 4)
        guard let data = Data(base64Encoded: padded, options: .ignoreUnknownCharacters) else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }
    private static func form(_ values: [(String, String)]) -> Data {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return Data(values.map { ($0.0.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.0) + "=" + ($0.1.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.1) }.joined(separator: "&").utf8)
    }
}

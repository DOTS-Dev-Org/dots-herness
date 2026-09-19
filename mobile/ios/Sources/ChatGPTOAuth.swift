import AuthenticationServices
import CryptoKit
import Foundation
import UIKit

/// The existing desktop GPT OAuth contract, adapted to a mobile callback. It is
/// a public PKCE client: no client secret is ever accepted or persisted.
@MainActor
final class ChatGPTOAuth: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    @Published private(set) var accessToken: String
    @Published private(set) var accountID: String
    @Published private(set) var status = ""
    @Published private(set) var isSigningIn = false

    private let secure = SecureStore()
    private var session: ASWebAuthenticationSession?
    private let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    private let callback = "herness://oauth/openai"

    override init() {
        accessToken = secure.read("oauth.openai.access") ?? ""
        accountID = secure.read("oauth.openai.account") ?? ""
        super.init()
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
        guard values["state"] == secure.read("oauth.openai.state"),
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
        let expiry = (Self.jwtClaims(accessToken)["exp"] as? NSNumber)?.doubleValue
        guard !accessToken.isEmpty, let expiry, expiry > Date().timeIntervalSince1970 + 60 else {
            if !accessToken.isEmpty && expiry == nil { return }
            guard let refreshToken = secure.read("oauth.openai.refresh"), !refreshToken.isEmpty else { return }
            await refresh(refreshToken)
            return
        }
    }

    func signOut() {
        secure.delete("oauth.openai.access")
        secure.delete("oauth.openai.refresh")
        secure.delete("oauth.openai.account")
        accessToken = ""; accountID = ""; status = "Signed out of ChatGPT on this device."
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first(where: \.isKeyWindow) ?? UIWindow()
    }

    private func exchange(code: String, verifier: String) async {
        await requestToken(fields: [("grant_type", "authorization_code"), ("code", code), ("redirect_uri", callback), ("client_id", clientID), ("code_verifier", verifier)])
    }

    private func refresh(_ token: String) async {
        await requestToken(fields: [("grant_type", "refresh_token"), ("refresh_token", token), ("client_id", clientID)])
    }

    private func requestToken(fields: [(String, String)]) async {
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
            accessToken = value
            if let refresh = object["refresh_token"] as? String { secure.write(refresh, key: "oauth.openai.refresh") }
            let claims = Self.jwtClaims(object["id_token"] as? String ?? value)
            let auth = claims["https://api.openai.com/auth"] as? [String: Any]
            accountID = auth?["chatgpt_account_id"] as? String ?? claims["chatgpt_account_id"] as? String ?? object["account_id"] as? String ?? accountID
            secure.write(value, key: "oauth.openai.access")
            if !accountID.isEmpty { secure.write(accountID, key: "oauth.openai.account") }
            MobileStateStore().saveOAuth(provider: "gpt", accountReference: "keychain:oauth.openai.access")
            status = "Signed in to ChatGPT."
        } catch { status = error.localizedDescription }
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

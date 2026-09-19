import AuthenticationServices
import CryptoKit
import Foundation
import UIKit

/// Public-client GitHub OAuth. The app never contains a client secret; the
/// verifier and state are short-lived Keychain entries and the access token is
/// stored under the same secure store used by provider credentials.
@MainActor
final class GitHubOAuth: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    @Published private(set) var accessToken: String
    @Published private(set) var status = ""
    @Published private(set) var isSigningIn = false

    private let secure = SecureStore()
    private var session: ASWebAuthenticationSession?
    private let clientID: String

    init(clientID: String? = nil) {
        self.clientID = clientID ?? (Bundle.main.object(forInfoDictionaryKey: "HERNESS_GITHUB_CLIENT_ID") as? String ?? "")
        self.accessToken = SecureStore().read("oauth.github.access") ?? ""
    }

    func start() {
        guard !clientID.isEmpty else {
            status = "Configure HERNESS_GITHUB_CLIENT_ID before signing in with GitHub."
            return
        }
        let verifier = Self.randomToken()
        let state = Self.randomToken()
        secure.write(verifier, key: "oauth.github.verifier")
        secure.write(state, key: "oauth.github.state")
        guard var components = URLComponents(string: "https://github.com/login/oauth/authorize") else { return }
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: "herness://oauth/github"),
            URLQueryItem(name: "scope", value: "read:user repo"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: Self.challenge(verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        guard let url = components.url else { return }
        isSigningIn = true
        status = "Waiting for GitHub authorization…"
        let auth = ASWebAuthenticationSession(url: url, callbackURLScheme: "herness") { [weak self] callback, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.session = nil
                if let callback { _ = self.handleCallback(callback) }
                else if let error, (error as NSError).code != ASWebAuthenticationSessionError.canceledLogin.rawValue { self.status = error.localizedDescription }
                else { self.status = "GitHub sign-in cancelled."; self.isSigningIn = false }
            }
        }
        auth.presentationContextProvider = self
        auth.prefersEphemeralWebBrowserSession = false
        session = auth
        guard auth.start() else { session = nil; isSigningIn = false; status = "Could not open GitHub sign-in."; return }
    }

    /// Handles both ASWebAuthenticationSession callbacks and cold-start/onOpenURL
    /// callbacks. Returns true only for the HerNess GitHub callback route.
    @discardableResult
    func handleCallback(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "herness", url.host?.lowercased() == "oauth", url.path == "/github" else { return false }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let values = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).compactMap { item in item.value.map { (item.name, $0) } })
        isSigningIn = false
        if let error = values["error"] { status = values["error_description"] ?? error; return true }
        guard let returnedState = values["state"], returnedState == secure.read("oauth.github.state") else {
            status = "GitHub OAuth state mismatch. Start sign-in again."
            return true
        }
        guard let code = values["code"], !code.isEmpty, let verifier = secure.read("oauth.github.verifier") else {
            status = "GitHub did not return an authorization code."
            return true
        }
        secure.delete("oauth.github.state")
        secure.delete("oauth.github.verifier")
        isSigningIn = true
        Task { await exchange(code: code, verifier: verifier) }
        return true
    }

    func signOut() {
        secure.delete("oauth.github.access")
        accessToken = ""
        status = "Signed out of GitHub on this device."
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    }

    private func exchange(code: String, verifier: String) async {
        defer { isSigningIn = false }
        guard let url = URL(string: "https://github.com/login/oauth/access_token") else { return }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.form([
            ("client_id", clientID),
            ("code", code),
            ("redirect_uri", "herness://oauth/github"),
            ("code_verifier", verifier),
        ])
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            guard (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true,
                  let token = object["access_token"] as? String, !token.isEmpty else {
                status = object["error_description"] as? String ?? "GitHub token exchange failed."
                return
            }
            secure.write(token, key: "oauth.github.access")
            accessToken = token
            MobileStateStore().saveOAuth(provider: "github", accountReference: "keychain:oauth.github.access")
            status = "Signed in to GitHub."
        } catch { status = error.localizedDescription }
    }

    private static func randomToken() -> String {
        Data((0..<32).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }

    private static func challenge(_ verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }

    private static func form(_ values: [(String, String)]) -> Data {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let text = values.map { key, value in
            let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return encodedKey + "=" + encodedValue
        }.joined(separator: "&")
        return Data(text.utf8)
    }
}

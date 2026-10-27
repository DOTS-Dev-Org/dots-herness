// Copyright (c) 2026 DOTS
// Provider account connect flows and credentials.

import AppKit
import CryptoKit
import Foundation
import HarnessPluginKit
import Network
import PluginRuntime

extension RouterController {
    func refreshCredential(for account: StoredProviderAccount) async -> Bool {
        guard let spec = RouterCatalog.spec(for: account.provider), let oauth = spec.oauth else { return false }
        guard let refresh = try? store.refreshCredential(for: account), !refresh.isEmpty else { return false }
        do {
            let tokens = try await OAuthFlow(spec: oauth, session: oauthSession).refresh(refresh)
            try store.replaceCredential(for: account, with: tokens.accessToken)
            if let accountID = tokens.accountID
                ?? tokens.idToken.flatMap({ OAuthFlow.chatGPTAccountID(OAuthFlow.jwtClaims($0)) }),
               !accountID.isEmpty {
                try store.updateSessionAccountID(for: account, with: accountID)
            }
            if let next = tokens.refreshToken { try store.replaceRefreshCredential(for: account, with: next) }
            return true
        } catch {
            return false
        }
    }

    public func startConnect() async {
        error = nil
        switch selectedKind.kind {
        case .apiKey:
            await createAPIKey()
        case .oauthBrowser:
            await startBrowser()
        case .passthrough:
            await connectPassthrough()
        case .oauthDevice:
            await startDevice()
        }
    }

    /// Providers that need no credential (e.g. OpenCode Free). Records a keyless
    /// account so routing picks it up like any other.
    public func connectPassthrough() async {
        do {
            let added = try store.addAccount(provider: selectedKind, name: selectedKind.name, secret: "", authType: "passthrough")
            onConnectionChanged?(ConnectionTransition(action: "added", currentConnectionLabel: added.name, cleanupStatus: "preserved"))
            status = AppCopy.format("router.connected", selectedKind.name)
            await refresh()
            await refreshModels(force: true)
        } catch {
            self.error = error.localizedDescription
        }
    }

    public func createAPIKey() async {
        let name = apiKeyName.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = apiKeyValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !key.isEmpty else {
            error = AppCopy.text("router.nameAndKeyRequired")
            return
        }
        guard !selectedKind.baseURL.isEmpty else {
            error = AppCopy.text("router.connect.needsEndpoint")
            return
        }
        do {
            let added = try store.addAccount(provider: selectedKind, name: name, secret: key)
            onConnectionChanged?(ConnectionTransition(action: "added", currentConnectionLabel: added.name, cleanupStatus: "preserved"))
            apiKeyValue = ""
            status = AppCopy.format("router.connected", selectedKind.name)
            await refresh()
            await refreshModels(force: true)
        } catch {
            self.error = error.localizedDescription
        }
    }

    public func startBrowser() async {
        guard let spec = RouterCatalog.spec(for: selectedKind.id), let oauth = spec.oauth else {
            error = AppCopy.text("router.connect.noBrowserSignIn")
            return
        }
        let engine = OAuthFlow(spec: oauth, session: oauthSession)
        let verifier = OAuthFlow.randomToken()
        let state = OAuthFlow.randomToken()
        guard let authURL = engine.authorizeURL(verifier: verifier, state: state)?.absoluteString else {
            error = AppCopy.text("router.connect.badURL")
            return
        }
        flow = .browser(provider: selectedKind.id, authURL: authURL, redirectURI: oauth.redirectURI, codeVerifier: verifier, state: state)
        do {
            callbackPort = oauth.callbackPort
            try startCallbackListener()
        } catch {
            self.error = error.localizedDescription
            flow = .idle
            return
        }
        if let url = URL(string: authURL) { SafeURL.openWeb(url) }
        let loginState = state
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000_000)
            guard let self,
                  case .browser(_, _, _, _, let currentState) = self.flow,
                  currentState == loginState else { return }
            self.error = AppCopy.text("router.connect.timeout")
            self.cancelFlow()
        }
        status = AppCopy.text("router.waitingAuthorization")
    }

    public func finishBrowser() async {
        let pasted = callbackPaste.trimmingCharacters(in: .whitespacesAndNewlines)
        await finishBrowser(callback: pasted)
    }

    func finishBrowser(callback: String) async {
        guard case .browser(let providerID, _, _, let verifier, let expectedState) = flow,
              let url = URL(string: callback),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let spec = RouterCatalog.spec(for: providerID), let oauth = spec.oauth else {
            if !callback.isEmpty { error = AppCopy.text("router.pasteCallbackURL") }
            return
        }
        let params = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in item.value.map { (item.name, $0) } })
        if let fail = params["error"] { error = params["error_description"] ?? fail; return }
        let rawCode = params["code"] ?? ""
        guard !rawCode.isEmpty else { error = AppCopy.text("router.noAuthorizationCode"); return }
        // Claude sends `code#state` and omits the `state` query item.
        let returnedState = params["state"]
            ?? oauth.manualCodeSeparator.flatMap { sep in
                rawCode.components(separatedBy: sep).count > 1 ? rawCode.components(separatedBy: sep).last : nil
            }
        if let returnedState, returnedState != expectedState { error = AppCopy.text("router.connect.stateMismatch"); return }
        do {
            let tokens = try await OAuthFlow(spec: oauth, session: oauthSession).exchange(code: rawCode, verifier: verifier, state: expectedState)
            let provider = RouterCatalog.kind(for: providerID) ?? selectedKind
            // Cloud Code Assist requires a project id on every later call, and it
            // is only obtainable once we hold the access token.
            let discovered = try await discoverProject(oauth: oauth, accessToken: tokens.accessToken)
            let isGPT = spec.transport.format == .responses
            let name = tokens.email ?? tokens.accountID ?? "\(provider.name) account"
            let added = try store.addAccount(
                provider: provider,
                name: name,
                secret: tokens.accessToken,
                model: provider.defaultModel,
                api: provider.api.rawValue,
                authType: isGPT ? "chatgpt" : "oauth",
                email: tokens.email,
                sessionAccountID: discovered ?? tokens.accountID,
                refreshSecret: tokens.refreshToken
            )
            onConnectionChanged?(ConnectionTransition(action: "added", currentConnectionLabel: added.name, cleanupStatus: "preserved"))
            callbackListener?.cancel(); callbackListener = nil; callbackConnection = nil
            flow = .idle; callbackPaste = ""
            status = AppCopy.format("router.connected", provider.name)
            await refresh(); await refreshModels(force: true)
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Device sign-in: show the user a short code, open the provider's page, then
    /// poll for approval. No local callback listener is involved.
    /// One-shot `loadCodeAssist` call: returns the Cloud Code Assist project id
    /// the provider will demand on every generate call. `nil` when the provider
    /// declares no discovery endpoint.
    private func discoverProject(oauth: ProviderSpec.OAuthSpec, accessToken: String) async throws -> String? {
        guard let raw = oauth.projectDiscoveryURL, let url = URL(string: raw) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let metadata: [String: Any] = ["ideType": 9, "platform": 2, "pluginType": 2]
        request.setValue(
            String(decoding: (try? JSONSerialization.data(withJSONObject: metadata)) ?? Data("{}".utf8), as: UTF8.self),
            forHTTPHeaderField: "Client-Metadata"
        )
        request.httpBody = try JSONSerialization.data(withJSONObject: ["metadata": metadata, "mode": 1])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true,
              let payload = try? JSONCodec.parse(data) else {
            throw RouterTestError.message(AppCopy.text("router.connect.googleProjectRead"))
        }
        // The field is a bare string on some accounts and an object on others.
        let project = payload["cloudaicompanionProject"]?.string
            ?? payload["cloudaicompanionProject"]?["id"]?.string
        guard let project, !project.isEmpty else {
            throw RouterTestError.message(AppCopy.text("router.connect.googleNoProject"))
        }
        return project
    }

    public func startDevice() async {
        guard let spec = RouterCatalog.spec(for: selectedKind.id), let oauth = spec.oauth,
              oauth.deviceCodeURL?.isEmpty == false else {
            error = AppCopy.text("router.connect.noDeviceLogin")
            return
        }
        let engine = OAuthFlow(spec: oauth, session: oauthSession)
        let device: OAuthFlow.DeviceCode
        do {
            device = try await engine.startDevice()
        } catch {
            self.error = error.localizedDescription
            return
        }
        flow = .device(
            provider: selectedKind.id,
            userCode: device.userCode,
            verificationURL: device.verificationURL,
            deviceCode: device.deviceCode,
            codeVerifier: nil,
            extra: [:]
        )
        status = AppCopy.text("router.waitingAuthorization")
        if let url = URL(string: device.verificationURL) { SafeURL.openWeb(url) }

        do {
            let tokens = try await engine.pollDevice(device)
            guard case .device(let providerID, _, _, _, _, _) = flow, providerID == selectedKind.id else { return }
            let provider = RouterCatalog.kind(for: providerID) ?? selectedKind
            let added = try store.addAccount(
                provider: provider,
                name: tokens.email ?? "\(provider.name) account",
                secret: tokens.accessToken,
                model: provider.defaultModel,
                api: provider.api.rawValue,
                authType: "oauth",
                email: tokens.email,
                refreshSecret: tokens.refreshToken
            )
            onConnectionChanged?(ConnectionTransition(action: "added", currentConnectionLabel: added.name, cleanupStatus: "preserved"))
            flow = .idle
            status = AppCopy.format("router.connected", provider.name)
            await refresh()
            await refreshModels(force: true)
        } catch {
            self.error = error.localizedDescription
            flow = .idle
        }
    }
    public func cancelFlow() { callbackListener?.cancel(); callbackListener = nil; callbackConnection = nil; flow = .idle; callbackPaste = "" }

    public func toggle(_ connection: RouterConnection) async {
        do {
            try store.setActive(connection.id, !connection.active)
            onConnectionChanged?(ConnectionTransition(action: "selected", previousConnectionLabel: connection.name, currentConnectionLabel: connection.name, cleanupStatus: "preserved"))
            await refresh()
        }
        catch { self.error = error.localizedDescription }
    }

    public func toggleImageFallback(_ connection: RouterConnection) async {
        do { try store.setImageFallback(connection.id, !connection.imageFallbackEnabled); await refresh() }
        catch { self.error = error.localizedDescription }
    }

    /// Claude OAuth does not expose a supported model-catalog endpoint. All
    /// other providers try their account catalog and keep the registry as fallback.
    func registryOnlyModels(_ account: StoredProviderAccount) -> Bool {
        (account.provider == "claude" && account.authType == "oauth") || account.provider == "claude-cli"
    }

    /// Where to list this account's models. A provider may host the listing off
    /// its chat base path, so the registry's `modelsURL` wins when present.
    func modelsURL(for account: StoredProviderAccount) -> URL? {
        let resolved: URL?
        if let declared = RouterCatalog.spec(for: account.provider)?.apiKey?.modelsURL, !declared.isEmpty {
            resolved = URL(string: declared)
        } else {
            let base = account.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            resolved = URL(string: base + "/models")
        }
        guard let resolved,
              var components = URLComponents(url: resolved, resolvingAgainstBaseURL: false) else { return resolved }
        var queryItems = components.queryItems ?? []
        if account.provider == "gpt" {
            // The Codex model catalog filters models by client compatibility. Keep
            // this in sync with the Codex-compatible user-agent in providers.json.
            let userAgent = RouterCatalog.spec(for: account.provider)?.transport.extraHeaders["user-agent"] ?? ""
            if let clientVersion = userAgent.split(separator: "/").last.map(String.init), !clientVersion.isEmpty {
                queryItems.removeAll { $0.name == "client_version" }
                queryItems.append(URLQueryItem(name: "client_version", value: clientVersion))
            }
        }
        if account.api == RouterAPIKind.anthropic.rawValue, account.authType != "oauth" {
            // Anthropic defaults to 20 models; request the documented maximum so
            // the live catalog does not omit still-available model IDs.
            queryItems.removeAll { $0.name == "limit" }
            queryItems.append(URLQueryItem(name: "limit", value: "1000"))
        }
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        return components.url ?? resolved
    }

    /// Google Code Assist exposes account-available models through its quota
    /// buckets. Antigravity has a separate account catalog response.
    func modelCatalogRequest(for account: StoredProviderAccount) -> URLRequest? {
        if account.api == RouterAPIKind.geminiCLI.rawValue,
           ["gemini-cli", "antigravity"].contains(account.provider) {
            guard let project = account.sessionAccountID, !project.isEmpty else { return nil }
            let base = account.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let method = account.provider == "antigravity" ? "fetchAvailableModels" : "retrieveUserQuota"
            guard let url = URL(string: base + ":" + method) else { return nil }
            var request = URLRequest(url: url, timeoutInterval: 8)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["project": project])
            authorize(&request, for: account)
            if account.provider == "gemini-cli" {
                request.setValue(
                    "GeminiCLI/0.34.0/\(account.model) (darwin; arm64; terminal)",
                    forHTTPHeaderField: "User-Agent"
                )
                request.setValue("google-genai-sdk/1.41.0 gl-node/v22.19.0", forHTTPHeaderField: "X-Goog-Api-Client")
            }
            return request
        }

        guard let url = modelsURL(for: account) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 8)
        authorize(&request, for: account)
        return request
    }

    /// Gemini's OpenAI-compatible `/models` response omits input token limits.
    /// Its native models endpoint publishes `inputTokenLimit`, so fetch that
    /// metadata separately while keeping the compatible listing authoritative
    /// for the model ids the app can actually call.
    func geminiModelMetadataRequest(for account: StoredProviderAccount) -> URLRequest? {
        guard account.provider == "gemini",
              var components = URLComponents(string: account.baseURL),
              components.host?.lowercased() == "generativelanguage.googleapis.com",
              let key = (try? store.credential(for: account)) ?? nil,
              !key.isEmpty else { return nil }
        var path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path.hasSuffix("/openai") { path.removeLast("/openai".count) }
        if path.isEmpty { path = "v1beta" }
        components.path = "/\(path)/models"
        components.queryItems = [URLQueryItem(name: "pageSize", value: "1000")]
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        return request
    }

    /// Applies the account's credential to `request`. An OAuth/subscription token
    /// is a bearer token even on Anthropic, whose API-key header is `x-api-key` —
    /// sending an OAuth token there is rejected with HTTP 401.
    func authorize(_ request: inout URLRequest, for account: StoredProviderAccount) {
        guard let key = (try? store.credential(for: account)) ?? nil, !key.isEmpty else { return }
        let isOAuth = account.authType == "oauth" || account.authType == "chatgpt"
        if account.api == RouterAPIKind.anthropic.rawValue, !isOAuth {
            request.setValue(key, forHTTPHeaderField: "x-api-key")
        } else {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        if account.api == RouterAPIKind.anthropic.rawValue {
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        }
        for (header, value) in RouterCatalog.spec(for: account.provider)?.transport.extraHeaders ?? [:] {
            request.setValue(value, forHTTPHeaderField: header)
        }
        if RouterCatalog.spec(for: account.provider)?.transport.quirks.requiresSessionAccountID == true,
           let accountID = account.sessionAccountID, !accountID.isEmpty {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-ID")
        }
    }

    public func test(_ connection: RouterConnection) async {
        guard let account = store.state.accounts.first(where: { $0.id == connection.id }) else { return }
        do {
            // A subscription token can't list `/models` on every provider, but it can
            // always complete — so probe the path the app actually uses.
            if account.authType == "oauth" || account.authType == "chatgpt" {
                let configuration = try configuration(for: account)
                _ = try await NativeAgentClient(configuration: configuration).complete(messages: [AgentMessage(role: .user, content: "ping")])
                status = AppCopy.format("router.connected", RouterCatalog.label(for: account.provider))
                return
            }
            guard let url = modelsURL(for: account) else { throw ProviderStoreError.invalidEndpoint }
            var request = URLRequest(url: url, timeoutInterval: 8)
            authorize(&request, for: account)
            let (_, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(code) else { throw RouterTestError.http(code) }
            status = AppCopy.format("router.connected", RouterCatalog.label(for: account.provider))
        } catch { self.error = error.localizedDescription }
    }

    public func remove(_ connection: RouterConnection) async {
        guard let account = store.state.accounts.first(where: { $0.id == connection.id }) else { return }
        do {
            try store.removeAccount(account)
            let verified = !store.state.accounts.contains(where: { $0.id == account.id })
                && credentialIsAbsent(account.credentialID)
                && credentialIsAbsent(account.refreshCredentialID)
            onConnectionChanged?(ConnectionTransition(action: "removed", previousConnectionLabel: account.name, cleanupStatus: verified ? "verified" : "failed", removedLocalArtifacts: verified ? ["connection record", "credential reference", "model metadata"] : []))
            await refresh()
        } catch {
            onConnectionChanged?(ConnectionTransition(action: "removed", previousConnectionLabel: account.name, cleanupStatus: "failed"))
            self.error = error.localizedDescription
        }
    }
}

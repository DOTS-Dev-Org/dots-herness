// Copyright (c) 2026 DOTS
// Native provider accounts, routing metadata, and the direct GPT login flow.

import AppKit
import CryptoKit
import Foundation
import HarnessPluginKit
import Network
import PluginRuntime

public enum RouterFlow: Equatable {
    case idle
    case browser(provider: String, authURL: String, redirectURI: String, codeVerifier: String, state: String)
    case device(provider: String, userCode: String, verificationURL: String, deviceCode: String, codeVerifier: String?, extra: JSONObject)
}

@MainActor
public final class RouterController: ObservableObject {
    @Published public var connections: [RouterConnection] = []
    @Published public var tunnel = RouterTunnel.idle
    @Published public var keys: [RouterKey] = []
    @Published public var nodes: [RouterNode] = []
    @Published public var models: [RouterModel] = []
    @Published public var selectedModelID: String = ""
    @Published public var status: String = AppCopy.text("common.idle")
    @Published public var error: String?
    @Published public var flow: RouterFlow = .idle
    @Published public var callbackPaste: String = ""
    @Published public var apiKeyName: String = ""
    @Published public var apiKeyValue: String = ""
    @Published public var selectedKind: RouterProviderKind = RouterCatalog.providers[0]
    @Published public var reachable = true
    @Published public var customName = "Local / Custom"
    @Published public var customPrefix = "custom"
    @Published public var customBaseURL = "http://127.0.0.1:11434/v1"
    @Published public var customAPIKey = ""
    @Published public var customKind: CustomAPIKind = .openai
    @Published public var customAPIType: CustomOpenAIAPIType = .chat
    @Published public var editingNodeID: String?

    public let store: NativeProviderStore
    private var gateway: ProviderGateway?
    private let cloudTunnel: CloudTunnelProcess
    private var callbackListener: NWListener?
    private var callbackConnection: NWConnection?
    private var callbackPort = 1455
    private var modelRefreshAttempted = false

    public init(baseURL: String = "", paths: SupportPaths = .default()) {
        _ = baseURL
        store = NativeProviderStore(paths: paths)
        cloudTunnel = CloudTunnelProcess(runtimeURL: paths.runtime)
        gateway = try? ProviderGateway { [weak self] request in
            await self?.gatewayResponse(request) ?? .json(["error": ["message": "Gateway is unavailable"]], status: 503)
        }
        refreshState()
    }

    public func refresh() async {
        refreshState()
        status = AppCopy.format("router.activeConnections", connections.filter(\.active).count, connections.count)
    }

    public func refreshModels(force: Bool = false) async {
        if !force, modelRefreshAttempted { return }
        guard force else { return }
        modelRefreshAttempted = true
        var next: [RouterModel] = []
        for account in store.state.accounts where account.active {
            if account.api == RouterAPIKind.chatGPT.rawValue {
                if !account.model.isEmpty { next.append(RouterModel(id: account.model, owner: RouterCatalog.label(for: account.provider))) }
                continue
            }
            if let url = URL(string: account.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/models") {
                var request = URLRequest(url: url, timeoutInterval: 8)
                if let key = try? store.credential(for: account), !key.isEmpty {
                    if account.api == RouterAPIKind.anthropic.rawValue { request.setValue(key, forHTTPHeaderField: "x-api-key") }
                    else { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
                }
                if account.api == RouterAPIKind.anthropic.rawValue { request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version") }
                if let (data, response) = try? await URLSession.shared.data(for: request),
                   (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true,
                   let payload = try? JSONCodec.parse(data),
                   case .array(let items) = payload["data"] {
                    next.append(contentsOf: items.compactMap { item in
                        guard let id = item["id"]?.string, !id.isEmpty else { return nil }
                        return RouterModel(id: id, owner: RouterCatalog.label(for: account.provider))
                    })
                }
            }
            if !account.model.isEmpty { next.append(RouterModel(id: account.model, owner: RouterCatalog.label(for: account.provider))) }
        }
        models = next.reduce(into: []) { result, model in
            if !result.contains(where: { $0.id == model.id }) { result.append(model) }
        }
        if models.contains(where: { $0.id == selectedModelID }) == false {
            selectedModelID = models.first?.id ?? ""
        }
    }

    public func refreshModelsIfNeeded() async { await refreshModels() }

    public func agentConfiguration() async -> AgentConfiguration? {
        let accounts = store.state.accounts.filter(\.active).sorted { $0.priority < $1.priority }
        for account in accounts where (selectedModelID.isEmpty || account.model == selectedModelID) {
            if let configuration = try? configuration(for: account) { return configuration }
        }
        return nil
    }

    public func complete(
        messages: [AgentMessage],
        tools: [AgentToolDefinition] = [],
        cachePolicy: AgentCachePolicy = AgentCachePolicy(),
        model: String? = nil
    ) async throws -> AgentResponse {
        let routes = store.state.accounts
            .filter(\.active)
            .filter { model?.isEmpty != false || $0.model == model }
            .sorted { $0.priority < $1.priority }
        guard !routes.isEmpty else { throw NativeAgentError(AppCopy.text("agent.configureEndpoint")) }
        var failures: [String] = []
        for account in routes {
            var refreshed = false
            while true {
                do {
                    let configuration = try configuration(for: account, model: model)
                    let response = try await NativeAgentClient(configuration: configuration).complete(messages: messages, tools: tools, cachePolicy: cachePolicy)
                    status = AppCopy.format("router.connected", configuration.provider)
                    return response
                } catch is CancellationError {
                    throw CancellationError()
                } catch let failure as NativeAgentError {
                    if failure.statusCode == 401, !refreshed {
                        refreshed = true
                        if await refreshCredential(for: account) { continue }
                    }
                    failures.append("\(RouterCatalog.label(for: account.provider)): \(failure.message)")
                    if !failure.retryable { throw failure }
                    break
                } catch {
                    failures.append("\(RouterCatalog.label(for: account.provider)): \(error.localizedDescription)")
                    break
                }
            }
        }
        throw NativeAgentError(failures.joined(separator: "\n"), retryable: false)
    }

    private func configuration(for account: StoredProviderAccount, model: String? = nil) throws -> AgentConfiguration {
        guard !account.baseURL.isEmpty, !account.model.isEmpty else { throw NativeAgentError("Provider endpoint is incomplete.") }
        let key = try store.credential(for: account)
        if account.api == RouterAPIKind.anthropic.rawValue || account.api == RouterAPIKind.chatGPT.rawValue {
            guard key != nil else { throw ProviderStoreError.credentialUnavailable }
        }
        return AgentConfiguration(
            baseURL: account.baseURL,
            model: model?.isEmpty == false ? model! : account.model,
            apiKey: key,
            provider: RouterCatalog.label(for: account.provider),
            api: account.api,
            sessionAccountID: account.sessionAccountID,
            specID: account.provider,
            authType: account.authType
        )
    }

    private func refreshCredential(for account: StoredProviderAccount) async -> Bool {
        guard let spec = RouterCatalog.spec(for: account.provider), let oauth = spec.oauth else { return false }
        guard let refresh = try? store.refreshCredential(for: account), !refresh.isEmpty else { return false }
        do {
            let tokens = try await OAuthFlow(spec: oauth).refresh(refresh)
            try store.replaceCredential(for: account, with: tokens.accessToken)
            if let idToken = tokens.idToken,
               let accountID = OAuthFlow.jwtClaims(idToken)["chatgpt_account_id"] as? String,
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
            error = "This provider does not expose a native device login yet. Use an API key or Custom API."
        }
    }

    /// Providers that need no credential (e.g. OpenCode Free). Records a keyless
    /// account so routing picks it up like any other.
    public func connectPassthrough() async {
        do {
            _ = try store.addAccount(provider: selectedKind, name: selectedKind.name, secret: "", authType: "passthrough")
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
            error = "This provider needs a Custom API endpoint."
            return
        }
        do {
            _ = try store.addAccount(provider: selectedKind, name: name, secret: key)
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
            error = "This provider does not support browser sign-in. Use an API key or Custom API."
            return
        }
        let engine = OAuthFlow(spec: oauth)
        let verifier = OAuthFlow.randomToken()
        let state = OAuthFlow.randomToken()
        guard let authURL = engine.authorizeURL(verifier: verifier, state: state)?.absoluteString else {
            error = "Could not build the sign-in URL."
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
        if let url = URL(string: authURL) { NSWorkspace.shared.open(url) }
        let loginState = state
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000_000)
            guard let self,
                  case .browser(_, _, _, _, let currentState) = self.flow,
                  currentState == loginState else { return }
            self.error = "The sign-in request timed out. Start it again."
            self.cancelFlow()
        }
        status = AppCopy.text("router.oauthWaiting")
    }

    public func finishBrowser() async {
        let pasted = callbackPaste.trimmingCharacters(in: .whitespacesAndNewlines)
        await finishBrowser(callback: pasted)
    }

    private func finishBrowser(callback: String) async {
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
        if let returnedState, returnedState != expectedState { error = "The login callback state did not match."; return }
        do {
            let tokens = try await OAuthFlow(spec: oauth).exchange(code: rawCode, verifier: verifier)
            let provider = RouterCatalog.kind(for: providerID) ?? selectedKind
            let isGPT = spec.transport.format == .responses
            let name = tokens.email ?? tokens.accountID ?? "\(provider.name) account"
            _ = try store.addAccount(
                provider: provider,
                name: name,
                secret: tokens.accessToken,
                model: provider.defaultModel,
                api: provider.api.rawValue,
                authType: isGPT ? "chatgpt" : "oauth",
                email: tokens.email,
                sessionAccountID: tokens.accountID,
                refreshSecret: tokens.refreshToken
            )
            callbackListener?.cancel(); callbackListener = nil; callbackConnection = nil
            flow = .idle; callbackPaste = ""
            status = AppCopy.format("router.connected", provider.name)
            await refresh(); await refreshModels(force: true)
        } catch {
            self.error = error.localizedDescription
        }
    }

    public func startDevice() async { error = "Native device login is not available for this provider yet. Use an API key or Custom API." }
    public func cancelFlow() { callbackListener?.cancel(); callbackListener = nil; callbackConnection = nil; flow = .idle; callbackPaste = "" }

    public func toggle(_ connection: RouterConnection) async {
        do { try store.setActive(connection.id, !connection.active); await refresh() }
        catch { self.error = error.localizedDescription }
    }

    public func test(_ connection: RouterConnection) async {
        guard let account = store.state.accounts.first(where: { $0.id == connection.id }) else { return }
        do {
            if account.api == RouterAPIKind.chatGPT.rawValue {
                let configuration = try configuration(for: account)
                _ = try await NativeAgentClient(configuration: configuration).complete(messages: [AgentMessage(role: .user, content: "ping")])
                status = AppCopy.format("router.connected", RouterCatalog.label(for: account.provider))
                return
            }
            guard let url = URL(string: account.baseURL + "/models") else { throw ProviderStoreError.invalidEndpoint }
            var request = URLRequest(url: url, timeoutInterval: 8)
            if let key = try store.credential(for: account), !key.isEmpty {
                if account.api == RouterAPIKind.anthropic.rawValue { request.setValue(key, forHTTPHeaderField: "x-api-key") }
                else { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
            }
            if account.api == RouterAPIKind.anthropic.rawValue { request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version") }
            let (_, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(code) else { throw RouterTestError.http(code) }
            status = AppCopy.format("router.connected", RouterCatalog.label(for: account.provider))
        } catch { self.error = error.localizedDescription }
    }

    public func remove(_ connection: RouterConnection) async {
        do { if let account = store.state.accounts.first(where: { $0.id == connection.id }) { try store.removeAccount(account) }; await refresh() }
        catch { self.error = error.localizedDescription }
    }

    public func testNode(_ node: RouterNode) async {
        guard let endpoint = store.state.endpoints.first(where: { $0.id == node.id }) else { return }
        do {
            let anthropic = endpoint.api == CustomAPIKind.anthropic.rawValue
            guard let url = URL(string: endpoint.baseURL + (anthropic ? "/messages" : "/models")) else { throw ProviderStoreError.invalidEndpoint }
            var request = URLRequest(url: url, timeoutInterval: 8)
            if let key = try store.credential(for: endpoint), !key.isEmpty {
                if anthropic { request.setValue(key, forHTTPHeaderField: "x-api-key") }
                else { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
            }
            if anthropic {
                request.httpMethod = "POST"
                request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONSerialization.data(withJSONObject: [
                    "model": "claude-3-5-haiku-latest",
                    "max_tokens": 1,
                    "messages": [["role": "user", "content": "ping"]],
                ])
            }
            let (_, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(code) else { throw RouterTestError.http(code) }
            status = AppCopy.format("router.connected", endpoint.name)
        } catch { self.error = error.localizedDescription }
    }

    public func enableTunnel() async {
        error = nil
        do {
            let shareKey = try store.shareKey() ?? store.createShareKey()
            try gateway?.start()
            guard let gateway else { throw RouterTestError.message("The local gateway could not start.") }
            tunnel = RouterTunnel(enabled: true, running: gateway.running, tunnelURL: gateway.url.absoluteString, publicURL: "", shortId: "", downloading: true, progress: 0)
            keys = [RouterKey(id: "share.key", name: "Share key", key: shareKey)]
            let publicURL = try await cloudTunnel.start(gatewayPort: gateway.url.port ?? 18_766) { [weak self] progress in
                Task { @MainActor in
                    guard let self else { return }
                    self.tunnel.progress = Int(progress.fraction * 100)
                }
            }
            let shortID = URL(string: publicURL)?.host?.split(separator: ".").first.map(String.init) ?? ""
            tunnel = RouterTunnel(enabled: true, running: gateway.running, tunnelURL: gateway.url.absoluteString, publicURL: publicURL, shortId: shortID, downloading: false, progress: 100)
            status = "Sharing is enabled."
        } catch {
            cloudTunnel.stop()
            gateway?.stop()
            self.error = error.localizedDescription
            tunnel = .idle
        }
    }

    public func disableTunnel() async { cloudTunnel.stop(); gateway?.stop(); tunnel = .idle }

    public func copyShareURL() {
        guard !tunnel.shareURL.isEmpty else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(tunnel.shareURL, forType: .string)
        status = AppCopy.text("common.copied")
    }

    public func createCustomNode(registerKey: Bool = true) async {
        let name = customName.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = sanitizedPrefix(customPrefix.isEmpty ? name : customPrefix)
        let base = customBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !prefix.isEmpty, !base.isEmpty else { error = AppCopy.text("router.customFieldsRequired"); return }
        do {
            let secret = customAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if let editingNodeID, let endpoint = store.state.endpoints.first(where: { $0.id == editingNodeID }) {
                try store.updateCustom(endpoint: endpoint, name: name, prefix: prefix, baseURL: base, api: customKind.rawValue, apiType: customAPIType.rawValue, secret: secret.isEmpty ? nil : secret)
                self.editingNodeID = nil
                status = "Custom API “\(name)” updated"
            } else {
                let endpoint = try store.addCustom(name: name, prefix: prefix, baseURL: base, api: customKind.rawValue, apiType: customAPIType.rawValue, secret: secret)
                if registerKey { _ = try store.addCustomAccount(endpoint: endpoint, secret: secret) }
                status = AppCopy.format("router.customAPIAdded", name)
            }
            customAPIKey = ""
            await refresh()
        } catch { self.error = error.localizedDescription }
    }

    public func beginEditNode(_ node: RouterNode) {
        guard let endpoint = store.state.endpoints.first(where: { $0.id == node.id }) else { return }
        editingNodeID = endpoint.id
        customName = endpoint.name
        customPrefix = endpoint.prefix
        customBaseURL = endpoint.baseURL
        customKind = endpoint.api == CustomAPIKind.anthropic.rawValue ? .anthropic : .openai
        customAPIType = endpoint.apiType == CustomOpenAIAPIType.responses.rawValue ? .responses : .chat
        customAPIKey = ""
        error = nil
    }

    public func cancelEditNode() {
        editingNodeID = nil
        customAPIKey = ""
    }

    public func deleteNode(_ node: RouterNode) async {
        do { if let endpoint = store.state.endpoints.first(where: { $0.id == node.id }) { try store.removeEndpoint(endpoint) }; await refresh() }
        catch { self.error = error.localizedDescription }
    }

    public func connectExistingNode(_ node: RouterNode) async {
        guard let endpoint = store.state.endpoints.first(where: { $0.id == node.id }) else { return }
        do { _ = try store.addCustomAccount(endpoint: endpoint, secret: customAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)); customAPIKey = ""; await refresh() }
        catch { self.error = error.localizedDescription }
    }

    public func sanitizedPrefix(_ raw: String) -> String {
        let kept = raw.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        return String(String(kept).split(separator: "-").joined(separator: "-").prefix(24))
    }

    public func createShareKey() async {
        do { let value = try store.createShareKey(); keys = [RouterKey(id: "share.key", name: "Share key", key: value)]; status = AppCopy.text("common.copied") }
        catch { self.error = error.localizedDescription }
    }

    private func refreshState() {
        connections = store.state.accounts.map(RouterConnection.init(from:))
        nodes = store.state.endpoints.map(RouterNode.init(from:))
        do {
            if let key = try store.shareKey() {
                keys = [RouterKey(id: "share.key", name: "Share key", key: key)]
            } else {
                keys = []
            }
        } catch {
            keys = []
        }
        selectedModelID = selectedModelID.isEmpty ? store.state.accounts.first(where: \.active)?.model ?? "" : selectedModelID
        reachable = true
    }

    private func gatewayResponse(_ request: GatewayRequest) async -> GatewayResponse {
        let expected = (try? store.shareKey()).flatMap { $0 }.map { "Bearer \($0)" }
        guard let expected, Self.constantTimeEquals(request.headers["authorization"], expected) else {
            return .json(["error": ["message": "A valid share key is required"]], status: 401)
        }
        if request.method == "GET", request.path == "/v1/models" {
            let data = store.state.accounts.filter(\.active).map { account in
                ["id": account.model, "object": "model", "owned_by": RouterCatalog.label(for: account.provider)]
            }
            return .json(["object": "list", "data": data])
        }
        guard request.method == "POST", request.path == "/v1/chat/completions" else {
            return .json(["error": ["message": "Not found"]], status: request.method == "GET" ? 404 : 405)
        }
        guard let body = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
              let rawMessages = body["messages"] as? [[String: Any]],
              !rawMessages.isEmpty else {
            return .json(["error": ["message": "The request body must contain messages"]], status: 400)
        }
        let messages = rawMessages.map(Self.agentMessage)
        let tools = (body["tools"] as? [[String: Any]] ?? []).compactMap(Self.toolDefinition)
        do {
            let response = try await complete(messages: messages, tools: tools, model: body["model"] as? String)
            var message: [String: Any] = ["role": "assistant", "content": response.message.content]
            if !response.message.toolCalls.isEmpty {
                message["tool_calls"] = response.message.toolCalls.map { ["id": $0.id, "type": "function", "function": ["name": $0.name, "arguments": $0.arguments]] }
            }
            var result: [String: Any] = [
                "id": "chatcmpl-\(UUID().uuidString)",
                "object": "chat.completion",
                "choices": [["index": 0, "message": message, "finish_reason": response.message.toolCalls.isEmpty ? "stop" : "tool_calls"]],
            ]
            if let usage = response.usage {
                result["usage"] = ["prompt_tokens": usage.inputTokens, "completion_tokens": usage.outputTokens, "total_tokens": usage.inputTokens + usage.outputTokens]
            }
            return .json(result)
        } catch let failure as NativeAgentError {
            return .json(["error": ["message": failure.message]], status: failure.statusCode ?? 502)
        } catch {
            return .json(["error": ["message": error.localizedDescription]], status: 500)
        }
    }

    /// Comparing SHA-256 digests removes any dependence of the compare time on how
    /// many leading bytes of the supplied key are correct.
    private static func constantTimeEquals(_ candidate: String?, _ expected: String) -> Bool {
        guard let candidate else { return false }
        return SHA256.hash(data: Data(candidate.utf8)) == SHA256.hash(data: Data(expected.utf8))
    }

    private static func agentMessage(_ raw: [String: Any]) -> AgentMessage {
        let role = AgentMessage.Role(rawValue: raw["role"] as? String ?? "user") ?? .user
        let content: String
        if let value = raw["content"] as? String { content = value }
        else if let blocks = raw["content"] as? [[String: Any]] { content = blocks.compactMap { $0["text"] as? String }.joined() }
        else { content = "" }
        let calls = (raw["tool_calls"] as? [[String: Any]] ?? []).compactMap { item -> AgentToolCall? in
            guard let function = item["function"] as? [String: Any], let name = function["name"] as? String else { return nil }
            return AgentToolCall(id: item["id"] as? String ?? UUID().uuidString, name: name, arguments: function["arguments"] as? String ?? "{}")
        }
        return AgentMessage(role: role, content: content, toolCallID: raw["tool_call_id"] as? String, toolCalls: calls)
    }

    private static func toolDefinition(_ raw: [String: Any]) -> AgentToolDefinition? {
        let function = raw["function"] as? [String: Any] ?? raw
        guard let name = function["name"] as? String else { return nil }
        let parameters = JSONCodec.value(from: function["parameters"] ?? ["type": "object"])
        return AgentToolDefinition(name: name, description: function["description"] as? String ?? "", parameters: parameters)
    }

    private func startCallbackListener() throws {
        callbackListener?.cancel()
        guard let port = NWEndpoint.Port(rawValue: UInt16(callbackPort)) else { throw RouterTestError.message("Invalid callback port") }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.callbackConnection = connection }
            connection.start(queue: .main)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
                guard let data, let request = String(data: data, encoding: .utf8) else { return }
                let firstLine = request.components(separatedBy: "\r\n").first ?? ""
                let parts = firstLine.split(separator: " ")
                let path = parts.count > 1 ? String(parts[1]) : ""
                let callback = URL(string: "http://localhost\(path)")
                let response = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nConnection: close\r\nContent-Length: 35\r\n\r\nLogin received. Return to the app."
                connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in connection.cancel() })
                guard let callback else { return }
                Task { @MainActor in
                    self?.callbackPaste = callback.absoluteString
                    await self?.finishBrowser(callback: callback.absoluteString)
                }
            }
        }
        listener.start(queue: .main)
        callbackListener = listener
    }

}

public enum RouterTestError: Error, LocalizedError, Sendable {
    case http(Int)
    case message(String)
    public var errorDescription: String? {
        switch self { case .http(let code): return "Provider returned HTTP \(code)."; case .message(let message): return message }
    }
}

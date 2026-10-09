// Copyright (c) 2026 DOTS
// Custom nodes, share keys, tunnels and the gateway.

import AppKit
import CryptoKit
import Foundation
import HarnessPluginKit
import Network
import PluginRuntime

extension RouterController {
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
                    "model": "claude-haiku-4-5",
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
        let modelName = customModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = modelName.isEmpty ? nil : modelName
        let contextText = customContextWindow.trimmingCharacters(in: .whitespacesAndNewlines)
        let contextWindow = Int(contextText).flatMap { $0 > 0 ? $0 : nil }
        guard contextText.isEmpty || contextWindow != nil else { error = AppCopy.text("custom.contextInvalid"); return }
        do {
            let secret = customAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if let editingNodeID, let endpoint = store.state.endpoints.first(where: { $0.id == editingNodeID }) {
                try store.updateCustom(endpoint: endpoint, name: name, prefix: prefix, baseURL: base, api: customKind.rawValue, apiType: customAPIType.rawValue, secret: secret.isEmpty ? nil : secret, model: model, contextWindow: contextWindow)
                onConnectionChanged?(ConnectionTransition(action: "replaced", previousConnectionLabel: endpoint.name, currentConnectionLabel: name, cleanupStatus: "preserved"))
                self.editingNodeID = nil
                status = "Custom API “\(name)” updated"
            } else {
                let endpoint = try store.addCustom(name: name, prefix: prefix, baseURL: base, api: customKind.rawValue, apiType: customAPIType.rawValue, secret: secret, model: model, contextWindow: contextWindow)
                if registerKey { _ = try store.addCustomAccount(endpoint: endpoint, secret: secret) }
                onConnectionChanged?(ConnectionTransition(action: "added", currentConnectionLabel: name, cleanupStatus: "preserved"))
                status = AppCopy.format("router.customAPIAdded", name)
            }
            customAPIKey = ""
            customModel = ""
            customContextWindow = ""
            await refresh()
            // The picker must show the endpoint's real models right away.
            await refreshModels(force: true)
            await detectLocalServers()
        } catch { self.error = error.localizedDescription }
    }

    /// Finds OpenAI-compatible servers the user already runs on this machine
    /// (Ollama, LM Studio, llama.cpp, …) that are not connected yet.
    public func detectLocalServers() async {
        let known = Set(store.state.endpoints.map(\.baseURL))
        detectedServers = await LocalServerDiscovery.scan().filter { !known.contains($0.baseURL) }
    }

    /// One-click connect for a detected server: no key, models listed live.
    public func connect(_ server: LocalServerDiscovery.Server) async {
        editingNodeID = nil
        customName = server.name
        customPrefix = server.name
        customBaseURL = server.baseURL
        customAPIKey = ""
        customModel = ""
        customContextWindow = ""
        customKind = .openai
        customAPIType = .chat
        await createCustomNode(registerKey: true)
    }

    /// Registers the bundled local server as one endpoint with one account,
    /// replacing whatever model it served before.
    public func publishLocalNode(name: String, prefix: String, baseURL: String, model: String, contextWindow: Int) async {
        do {
            let api = CustomAPIKind.openai.rawValue
            let apiType = CustomOpenAIAPIType.chat.rawValue
            let endpoint: StoredCustomEndpoint
            if let existing = store.state.endpoints.first(where: { $0.prefix == prefix }) {
                try store.updateCustom(endpoint: existing, name: name, prefix: prefix, baseURL: baseURL, api: api, apiType: apiType, secret: nil, model: model, contextWindow: contextWindow)
                endpoint = store.state.endpoints.first { $0.id == existing.id } ?? existing
            } else {
                endpoint = try store.addCustom(name: name, prefix: prefix, baseURL: baseURL, api: api, apiType: apiType, secret: "", model: model, contextWindow: contextWindow)
            }
            if !store.state.accounts.contains(where: { $0.provider == "custom:\(endpoint.id)" }) {
                try store.addCustomAccount(endpoint: endpoint, secret: "")
            }
            await refresh()
            await refreshModels(force: true)
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
        customModel = endpoint.model ?? ""
        customContextWindow = endpoint.contextWindow.map(String.init) ?? ""
        error = nil
    }

    public func cancelEditNode() {
        editingNodeID = nil
        customAPIKey = ""
        customModel = ""
        customContextWindow = ""
    }

    public func deleteNode(_ node: RouterNode) async {
        guard let endpoint = store.state.endpoints.first(where: { $0.id == node.id }) else { return }
        let accounts = store.state.accounts.filter { $0.provider == "custom:\(endpoint.id)" }
        do {
            try store.removeEndpoint(endpoint)
            let verified = !store.state.endpoints.contains(where: { $0.id == endpoint.id })
                && !store.state.accounts.contains(where: { $0.provider == "custom:\(endpoint.id)" })
                && credentialIsAbsent(endpoint.credentialID)
                && accounts.allSatisfy { credentialIsAbsent($0.credentialID) && credentialIsAbsent($0.refreshCredentialID) }
            onConnectionChanged?(ConnectionTransition(action: "removed", previousConnectionLabel: endpoint.name, cleanupStatus: verified ? "verified" : "failed", removedLocalArtifacts: verified ? ["endpoint record", "connection record", "credential references", "model metadata"] : []))
            await refresh()
        } catch {
            onConnectionChanged?(ConnectionTransition(action: "removed", previousConnectionLabel: endpoint.name, cleanupStatus: "failed"))
            self.error = error.localizedDescription
        }
    }

    public func connectExistingNode(_ node: RouterNode) async {
        guard let endpoint = store.state.endpoints.first(where: { $0.id == node.id }) else { return }
        do {
            let account = try store.addCustomAccount(endpoint: endpoint, secret: customAPIKey.trimmingCharacters(in: .whitespacesAndNewlines))
            onConnectionChanged?(ConnectionTransition(action: "added", currentConnectionLabel: account.name, cleanupStatus: "preserved"))
            customAPIKey = ""
            await refresh()
        }
        catch { self.error = error.localizedDescription }
    }

    public func sanitizedPrefix(_ raw: String) -> String {
        let kept = raw.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        return String(String(kept).split(separator: "-").joined(separator: "-").prefix(24))
    }

    func credentialIsAbsent(_ id: String?) -> Bool {
        guard let id else { return true }
        do { return try store.vault.get(id) == nil } catch { return false }
    }

    public func createShareKey() async {
        do { let value = try store.createShareKey(); keys = [RouterKey(id: "share.key", name: "Share key", key: value)]; status = AppCopy.text("common.copied") }
        catch { self.error = error.localizedDescription }
    }

    public func refreshShareKey() {
        do {
            keys = try store.shareKey().map { [RouterKey(id: "share.key", name: "Share key", key: $0)] } ?? []
        } catch {
            keys = []
        }
    }

    func refreshState() {
        connections = store.state.accounts.map(RouterConnection.init(from:))
        nodes = store.state.endpoints.map(RouterNode.init(from:))
        // Restore the last known account catalog before validating the saved
        // selection. Live-only models must survive launch without a network read.
        if models.isEmpty { models = cachedModelCatalog() ?? registryModels() }
        if selectedModelID.isEmpty { select(modelID: store.state.accounts.first(where: \.active)?.model ?? "") }
        reconcileSelection()
        reachable = true
    }

    /// Models known offline: every active account's registry entry, plus the model
    /// the account was stored with. No network, so it is safe during init.
    private func registryModels() -> [RouterModel] {
        var seeded: [RouterModel] = []
        for account in store.state.accounts where account.active {
            let owner = RouterCatalog.label(for: account.provider)
            let specModels = RouterCatalog.spec(for: account.provider)?.models ?? []
            for spec in specModels {
                seeded.append(RouterModel(
                    id: spec.id, owner: owner,
                    contextWindow: account.contextWindow
                        ?? RouterCatalog.documentedContextWindow(for: spec.id, provider: account.provider)
                        ?? spec.contextWindow,
                    efforts: spec.efforts,
                    displayName: spec.name, provider: account.provider, tier: spec.tier, fast: spec.fast
                ))
            }
            if !account.model.isEmpty, !account.hasPlaceholderModel, !seeded.contains(where: { $0.id == account.model }) {
                seeded.append(RouterModel(
                    id: account.model, owner: owner,
                    contextWindow: account.contextWindow
                        ?? RouterCatalog.documentedContextWindow(for: account.model, provider: account.provider),
                    provider: account.provider
                ))
            }
        }
        return seeded
    }

    func gatewayResponse(_ request: GatewayRequest) async -> GatewayResponse {
        let expected = (try? store.shareKey()).flatMap { $0 }.map { "Bearer \($0)" }
        guard let expected, Self.constantTimeEquals(request.headers["authorization"], expected) else {
            return .json(["error": ["message": "A valid share key is required"]], status: 401)
        }
        if request.method == "GET", request.path == "/v1/models" {
            let data = store.state.accounts.filter { $0.active && !$0.hasPlaceholderModel }.map { account in
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
            return .json(
                ["error": [
                    "message": failure.message,
                    "type": failure.isLimit ? "provider_limit" : "provider_error",
                ]],
                status: failure.statusCode ?? 502
            )
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

    func startCallbackListener() throws {
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

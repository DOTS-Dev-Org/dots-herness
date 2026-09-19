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

public struct ConnectionTransition: Equatable, Sendable {
    public let action: String
    public let previousConnectionLabel: String?
    public let currentConnectionLabel: String?
    public let cleanupStatus: String
    public let removedLocalArtifacts: [String]
    public let remoteDataTouched: Bool
    public let userDataPreserved: Bool

    public init(action: String, previousConnectionLabel: String? = nil, currentConnectionLabel: String? = nil, cleanupStatus: String, removedLocalArtifacts: [String] = [], remoteDataTouched: Bool = false, userDataPreserved: Bool = true) {
        self.action = action
        self.previousConnectionLabel = previousConnectionLabel
        self.currentConnectionLabel = currentConnectionLabel
        self.cleanupStatus = cleanupStatus
        self.removedLocalArtifacts = removedLocalArtifacts
        self.remoteDataTouched = remoteDataTouched
        self.userDataPreserved = userDataPreserved
    }
}

@MainActor
public final class RouterController: ObservableObject {
    @Published public var connections: [RouterConnection] = []
    @Published public var tunnel = RouterTunnel.idle
    @Published public var keys: [RouterKey] = []
    @Published public var nodes: [RouterNode] = []
    @Published public var models: [RouterModel] = []
    @Published public var selectedModelID: String = ""
    /// Reasoning effort for the selected model. Empty means "provider default".
    @Published public var selectedEffort: String = ""
    /// Fast response speed; only honoured when `supportsFast` for the model.
    @Published public var fastMode = false
    /// What automatic routing picked for the last request, for the picker to show.
    @Published public private(set) var lastAutoDecision: ModelDecision?
    /// Set when a request only succeeded after stepping past a provider that was out
    /// of quota, so the run can tell the user its model changed under it.
    @Published public private(set) var lastFailover: String?
    @Published public var status: String = AppCopy.text("common.idle")
    @Published public var error: String?
    /// Live Claude subscription rate-limit usage. In-memory only, no persistence.
    @Published public var claudeUsage: ClaudeUsageState = .idle
    /// Per-account rate-limit picture keyed by account id. In-memory only.
    @Published public var accountUsage: [String: AccountUsageSnapshot] = [:]
    /// The account and concrete model that actually served the most recent request.
    /// `AgentBridge` reads these to pin the conversation to that account.
    @Published public private(set) var lastServedAccountID: String?
    @Published public private(set) var lastServedModelID: String?
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
    public var onConnectionChanged: ((ConnectionTransition) -> Void)?

    public let store: NativeProviderStore
    public let imageAdapters: ProviderImageAdapterRegistry
    private var gateway: ProviderGateway?
    private let cloudTunnel: CloudTunnelProcess
    private let oauthSession: URLSession
    private var callbackListener: NWListener?
    private var callbackConnection: NWConnection?
    private var callbackPort = 1455
    private var modelRefreshAttempted = false
    private var modelRefreshTask: Task<Void, Never>?
    /// Effort chosen by automatic routing for the in-flight request.
    private var autoEffortOverride: String?

    public init(
        baseURL: String = "",
        paths: SupportPaths = .default(),
        imageAdapters: ProviderImageAdapterRegistry? = nil,
        oauthSession: URLSession = .shared,
        providerStore: NativeProviderStore? = nil
    ) {
        _ = baseURL
        store = providerStore ?? NativeProviderStore(paths: paths)
        self.imageAdapters = imageAdapters ?? ProviderImageAdapterRegistry()
        BuiltInProviderImageAdapters.register(on: self.imageAdapters)
        self.oauthSession = oauthSession
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

    /// Rewrites every account's `priority` so provider families sort in
    /// `orderedProviderIDs` order (`providerIndex * 100 + accountIndex`), keeping
    /// each family's own account order. Providers left out keep their current
    /// relative order after the listed ones.
    public func reorderProviders(_ orderedProviderIDs: [String]) {
        let present = store.state.accounts.reduce(into: [String]()) { seen, account in
            if !seen.contains(account.provider) { seen.append(account.provider) }
        }
        let ordered = orderedProviderIDs.filter(present.contains)
            + present.filter { !orderedProviderIDs.contains($0) }
        for (providerIndex, provider) in ordered.enumerated() {
            let accounts = store.state.accounts
                .filter { $0.provider == provider }
                .sorted { $0.priority < $1.priority }
            for (accountIndex, account) in accounts.enumerated() {
                try? store.setPriority(account.id, providerIndex * 100 + accountIndex)
            }
        }
        Task { await refresh() }
    }

    public func refreshModels(force: Bool = false) async {
        // A refresh already running (the startup prewarm) is joined, not repeated or
        // skipped: a send that arrives meanwhile must see the finished model list.
        if let inflight = modelRefreshTask {
            await inflight.value
            if !force { return }
        }
        if !force, modelRefreshAttempted { return }
        modelRefreshAttempted = true
        let task = Task { @MainActor [self] in await performModelRefresh() }
        modelRefreshTask = task
        await task.value
        if modelRefreshTask == task { modelRefreshTask = nil }
    }

    private func performModelRefresh() async {
        var next: [RouterModel] = []
        let activeAccounts = store.state.accounts.filter(\.active)

        // Every provider's `/models` request is in flight at once: the wait is the
        // slowest provider, not the sum. Requests are built here so Keychain reads
        // stay on the main actor.
        var requests: [String: URLRequest] = [:]
        for account in activeAccounts where account.api != RouterAPIKind.chatGPT.rawValue {
            guard let url = modelsURL(for: account) else { continue }
            var request = URLRequest(url: url, timeoutInterval: 8)
            authorize(&request, for: account)
            requests[account.id] = request
        }
        let payloads: [String: Data] = await withTaskGroup(of: (String, Data?).self) { group in
            for (id, request) in requests {
                group.addTask {
                    guard let (data, response) = try? await URLSession.shared.data(for: request),
                          (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true else {
                        return (id, nil)
                    }
                    return (id, data)
                }
            }
            var collected: [String: Data] = [:]
            for await (id, data) in group {
                if let data { collected[id] = data }
            }
            return collected
        }

        for account in activeAccounts {
            let owner = RouterCatalog.label(for: account.provider)
            let specModels = RouterCatalog.spec(for: account.provider)?.models ?? []
            // Effort levels are model-specific and no provider publishes them, so
            // they always come from the registry — matched by id against whatever
            // the live listing returns.
            func model(id: String, name: String? = nil) -> RouterModel {
                let spec = specModels.first { $0.id == id }
                return RouterModel(
                    id: id,
                    owner: owner,
                    contextWindow: spec?.contextWindow,
                    efforts: spec?.efforts ?? [],
                    displayName: name ?? spec?.name,
                    provider: account.provider,
                    tier: spec?.tier,
                    fast: spec?.fast ?? false
                )
            }

            // The Codex backend has no model listing (its `/models` 400s and the
            // ChatGPT web list carries different ids), so it stays registry-driven.
            if account.api == RouterAPIKind.chatGPT.rawValue {
                for spec in specModels { next.append(model(id: spec.id)) }
                if specModels.isEmpty, !account.model.isEmpty { next.append(model(id: account.model)) }
                continue
            }

            var live: [RouterModel] = []
            if let data = payloads[account.id],
               let payload = try? JSONCodec.parse(data),
               case .array(let items) = payload["data"] {
                live = items.compactMap { item in
                    guard let id = item["id"]?.string, !id.isEmpty else { return nil }
                    var discovered = model(id: id, name: item["display_name"]?.string)
                    discovered.contextWindow = item["context_length"]?.int
                        ?? item["contextWindow"]?.int
                        ?? discovered.contextWindow
                    return discovered
                }
            }
            next.append(contentsOf: live)
            // Registry entries the listing omits (aliases such as `claude-haiku-4-5`)
            // still route fine, so keep them as a floor rather than losing them.
            for spec in specModels where !live.contains(where: { $0.id == spec.id }) {
                next.append(model(id: spec.id))
            }
            if live.isEmpty,
               !account.model.isEmpty,
               !next.contains(where: { $0.id == account.model && $0.provider == account.provider }) {
                next.append(model(id: account.model))
            }
        }
        models = next.reduce(into: []) { result, model in
            if !result.contains(where: { $0.id == model.id }) { result.append(model) }
        }
        if selectedModelID.isEmpty {
            selectedModelID = models.first?.id ?? ""
        }
    }

    public func refreshModelsIfNeeded() async { await refreshModels() }

    public func contextWindow(for model: String? = nil) -> Int {
        if let model, let live = models.first(where: { $0.id == model })?.contextWindow, live > 0 { return live }
        if let model, let staticWindow = ProviderRegistry.shared.specs
            .flatMap(\.models)
            .first(where: { $0.id == model })?.contextWindow, staticWindow > 0 { return staticWindow }
        let account = store.state.accounts
            .filter(\.active)
            .sorted { $0.priority < $1.priority }
            .first { canServe($0, model: model ?? "") }
        switch account?.api {
        case RouterAPIKind.anthropic.rawValue: return 200_000
        case RouterAPIKind.chatGPT.rawValue: return 128_000
        default: return AgentContextCompaction.defaultContextWindow
        }
    }

    public func compactionModelID(avoiding model: String?) -> String? {
        let account = store.state.accounts
            .filter(\.active)
            .sorted { $0.priority < $1.priority }
            .first { canServe($0, model: selectedModelID) }
        guard let account else { return nil }
        let candidates = models
            .filter { canServe(account, model: $0.id) }
            .map(\.id)
            .filter { !$0.isEmpty }
            .sorted {
                let lhsAvoid = $0 == model ? 1 : 0
                let rhsAvoid = $1 == model ? 1 : 0
                if lhsAvoid != rhsAvoid { return lhsAvoid < rhsAvoid }
                return isCompactModel($0) && !isCompactModel($1)
            }
        return candidates.first ?? effectiveModel(for: account)
    }

    public func preserveProviderItems(for model: String? = nil) -> Bool {
        store.state.accounts.contains {
            $0.active && $0.api == RouterAPIKind.chatGPT.rawValue && canServe($0, model: model ?? selectedModelID)
        }
    }

    /// Whether `account` can serve `model`. A model may come from the static
    /// registry or from a provider's live `/models` listing, so both are checked.
    private func canServe(_ account: StoredProviderAccount, model: String) -> Bool {
        // The auto sentinel is not a real model: any active account qualifies, and
        // the concrete choice is made per request in `complete`.
        if model.isEmpty || model == ModelRouter.autoModelID || account.model == model { return true }
        if RouterCatalog.spec(for: account.provider)?.models.contains(where: { $0.id == model }) == true { return true }
        return models.contains { $0.id == model && $0.provider == account.provider }
    }

    public func agentConfiguration(
        model requestedModel: String? = nil,
        loadCredentials: Bool = true
    ) async -> AgentConfiguration? {
        let accounts = store.state.accounts.filter(\.active).sorted { $0.priority < $1.priority }
        var selected = (requestedModel ?? selectedModelID).trimmingCharacters(in: .whitespacesAndNewlines)
        // Report a concrete model in the ready banner rather than the sentinel.
        if selected == ModelRouter.autoModelID { selected = "" }
        for account in accounts where canServe(account, model: selected) {
            if let configuration = try? configuration(
                for: account,
                model: selected.isEmpty ? nil : selected,
                loadCredentials: loadCredentials
            ) {
                return configuration
            }
        }
        return nil
    }

    public func mediaConfiguration(for kind: MediaKind) async -> (configuration: AgentConfiguration, provider: ProviderMediaSpec)? {
        let accounts = store.state.accounts.filter(\.active).sorted { $0.priority < $1.priority }
        for account in accounts {
            guard let provider = RouterCatalog.spec(for: account.provider)?.media?.spec(for: kind),
                  let configuration = try? configuration(for: account) else { continue }
            return (configuration, provider)
        }
        return nil
    }

    public var hasImageFallback: Bool {
        store.state.accounts.contains { $0.active && $0.imageFallbackEnabled }
    }

    public var imageGenerationCommandVisible: Bool {
        // Keep the command discoverable for providers whose image capability is
        // not known yet. A missing adapter is an extension point, not a deny
        // decision: a later catalog entry or trusted plugin may add support.
        return imagePrimaryAccount != nil
    }

    public func generateImage(prompt: String, session: URLSession = .shared) async throws -> ProviderImageGeneration {
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { throw ProviderImageGenerationError.unsupported(AppCopy.text("media.promptMissing")) }
        guard let primary = imagePrimaryAccount else {
            throw ProviderImageGenerationError.unsupported(AppCopy.text("media.unsupportedStatus"))
        }
        let primaryModel = imageModel(for: primary)
        let primaryRoute = imageRoute(for: primary, model: primaryModel)
        let primaryAdapter = imageAdapters.adapter(for: primaryRoute)
        let primaryAdapterID = primaryAdapter?.id ?? "none"

        if imageAdapters.capability(for: primaryRoute, adapterID: primaryAdapterID) != .unsupported,
           let primaryAdapter {
            let result = try await imageAttemptWithRefresh(
                account: primary,
                adapter: primaryAdapter,
                route: primaryRoute,
                model: primaryModel,
                prompt: prompt,
                session: session
            )
            switch result {
            case .generated(let output):
                imageAdapters.record(.supported, for: primaryRoute, adapterID: primaryAdapterID)
                return ProviderImageGeneration(output: output, provider: RouterCatalog.label(for: primary.provider), model: primaryModel)
            case .failed(let failure):
                throw ProviderImageGenerationError.failed(failure)
            case .unsupported:
                imageAdapters.record(.unsupported, for: primaryRoute, adapterID: primaryAdapterID)
            }
        }

        let fallbackSource = "\(RouterCatalog.label(for: primary.provider))/\(primaryModel)"
        let candidates = store.state.accounts
            .filter { $0.active && $0.imageFallbackEnabled }
            .sorted { $0.priority < $1.priority }
        for account in candidates {
            let model = effectiveModel(for: account)
            let route = imageRoute(for: account, model: model)
            let adapter = imageAdapters.adapter(for: route, includeFallbackOnly: true)
            let adapterID = adapter?.id ?? "none"
            if imageAdapters.capability(for: route, adapterID: adapterID) == .unsupported { continue }
            guard let adapter else {
                continue
            }
            let result = try await imageAttemptWithRefresh(
                account: account,
                adapter: adapter,
                route: route,
                model: model,
                prompt: prompt,
                session: session
            )
            switch result {
            case .generated(let output):
                imageAdapters.record(.supported, for: route, adapterID: adapterID)
                let generatedModel = adapterID == "openai.images.fallback" ? "gpt-image-1.5" : model
                return ProviderImageGeneration(
                    output: output,
                    provider: RouterCatalog.label(for: account.provider),
                    model: generatedModel,
                    fallbackFrom: fallbackSource
                )
            case .unsupported:
                imageAdapters.record(.unsupported, for: route, adapterID: adapterID)
            case .failed(let failure):
                throw ProviderImageGenerationError.failed(failure)
            }
        }
        throw ProviderImageGenerationError.unsupported(
            "\(fallbackSource) does not support image generation. Enable an image fallback connection in Settings."
        )
    }

    private var imagePrimaryAccount: StoredProviderAccount? {
        let selected = selectedModelID == ModelRouter.autoModelID ? "" : selectedModelID
        let active = store.state.accounts.filter(\.active).sorted { $0.priority < $1.priority }
        return active.first(where: { canServe($0, model: selected) }) ?? active.first
    }

    private func imageModel(for account: StoredProviderAccount) -> String {
        let selected = selectedModelID == ModelRouter.autoModelID ? "" : selectedModelID
        return selected.isEmpty ? effectiveModel(for: account) : selected
    }

    private func imageRoute(for account: StoredProviderAccount, model: String) -> ProviderImageRoute {
        ProviderImageRoute(
            accountID: account.id,
            providerID: account.provider,
            baseURL: account.baseURL,
            api: account.api,
            model: model,
            authType: account.authType,
            sessionAccountID: account.sessionAccountID
        )
    }

    private func imageConfiguration(for account: StoredProviderAccount, model: String) throws -> AgentConfiguration {
        try configuration(for: account, model: model)
    }

    private func imageAttemptWithRefresh(
        account: StoredProviderAccount,
        adapter: any ProviderImageAdapter,
        route: ProviderImageRoute,
        model: String,
        prompt: String,
        session: URLSession
    ) async throws -> ProviderImageResult {
        var refreshed = false
        while true {
            let result = try await imageAttempt(
                adapter: adapter,
                route: route,
                configuration: try imageConfiguration(for: account, model: model),
                prompt: prompt,
                session: session
            )
            guard case .failed(let failure) = result,
                  failure.kind == .auth,
                  !refreshed else { return result }
            guard await refreshCredential(for: account) else { return result }
            refreshed = true
        }
    }

    private func imageAttempt(
        adapter: any ProviderImageAdapter,
        route: ProviderImageRoute,
        configuration: AgentConfiguration,
        prompt: String,
        session: URLSession
    ) async throws -> ProviderImageResult {
        do {
            let prepared = try adapter.prepareImageRequest(prompt: prompt, model: route.model, route: route)
            var request = URLRequest(url: prepared.url, timeoutInterval: 180)
            request.httpMethod = "POST"
            request.httpBody = prepared.body
            for (header, value) in prepared.headers { request.setValue(value, forHTTPHeaderField: header) }
            if let key = configuration.apiKey, !key.isEmpty {
                switch prepared.authentication {
                case .none: break
                case .bearer: request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
                case .rawHeader(let header): request.setValue(key, forHTTPHeaderField: header)
                }
            }
            if configuration.api == RouterAPIKind.chatGPT.rawValue {
                if configuration.transportSpec?.quirks.requiresSessionAccountID == true,
                   let accountID = configuration.sessionAccountID, !accountID.isEmpty {
                    request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-ID")
                    request.setValue("codex", forHTTPHeaderField: "OAI-Product-Sku")
                    request.setValue("codex_cli_rs", forHTTPHeaderField: "originator")
                }
                request.setValue(UUID().uuidString, forHTTPHeaderField: "session-id")
                let threadID = UUID().uuidString
                request.setValue(threadID, forHTTPHeaderField: "thread-id")
                request.setValue(threadID, forHTTPHeaderField: "x-client-request-id")
            }
            for (header, value) in configuration.transportSpec?.extraHeaders ?? [:] {
                request.setValue(value, forHTTPHeaderField: header)
            }
            let (data, response) = try await session.data(for: request)
            let http = response as? HTTPURLResponse
            var headers: [String: String] = [:]
            for (key, value) in http?.allHeaderFields ?? [:] {
                headers[String(describing: key)] = String(describing: value)
            }
            return adapter.parseImageResponse(data: data, status: http?.statusCode ?? 0, headers: headers)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError {
            return .failed(ProviderImageFailure(kind: .network, message: error.localizedDescription))
        } catch let error as NativeAgentError {
            return .failed(ProviderImageFailure(kind: .other, message: error.message))
        } catch {
            return .failed(ProviderImageFailure(kind: .other, message: error.localizedDescription))
        }
    }

    public func complete(
        messages: [AgentMessage],
        tools: [AgentToolDefinition] = [],
        cachePolicy: AgentCachePolicy = AgentCachePolicy(),
        model: String? = nil,
        preferredAccountID: String? = nil
    ) async throws -> AgentResponse {
        let requestedModel = (model ?? selectedModelID).trimmingCharacters(in: .whitespacesAndNewlines)
        guard requestedModel == ModelRouter.autoModelID else {
            autoEffortOverride = nil
            return try await send(
                messages: messages,
                tools: tools,
                cachePolicy: cachePolicy,
                model: requestedModel.isEmpty ? nil : requestedModel,
                preferredAccountID: preferredAccountID
            )
        }

        // Auto picked the model, so auto may pick another one when the first runs out
        // of quota: pausing is only the right answer once no route is left. A pinned
        // model is the user's own choice and is never swapped behind their back.
        return try await sendAcrossProviders(
            messages: messages,
            tools: tools,
            cachePolicy: cachePolicy,
            recordDecision: true,
            preferredAccountID: preferredAccountID
        )
    }

    /// Sends `messages`, stepping to the next provider whenever one reports that it
    /// is out of quota. Only when every route is exhausted does the limit surface,
    /// which is where pausing the conversation is the honest answer.
    private func sendAcrossProviders(
        messages: [AgentMessage],
        tools: [AgentToolDefinition],
        cachePolicy: AgentCachePolicy,
        recordDecision: Bool,
        preferredAccountID: String? = nil
    ) async throws -> AgentResponse {
        var excluded: Set<String> = []
        var dropped: [String] = []
        while true {
            guard let decision = ModelRouter.decide(
                messages: messages,
                available: routableModels,
                excluding: excluded
            ) else { throw NativeAgentError(AppCopy.text("agent.configureEndpoint")) }
            if recordDecision {
                lastAutoDecision = decision
                autoEffortOverride = decision.effort
                status = decision.reason
            }
            do {
                let response = try await send(
                    messages: messages,
                    tools: tools,
                    cachePolicy: cachePolicy,
                    model: decision.model,
                    preferredAccountID: preferredAccountID
                )
                if recordDecision {
                    let name = routableModels.first { $0.id == decision.model }?.displayName ?? decision.model
                    lastFailover = dropped.isEmpty
                        ? nil
                        : AppCopy.format("router.failedOver", dropped.joined(separator: ", "), name)
                }
                return response
            } catch let failure as NativeAgentError where failure.isLimit {
                guard let provider = routableModels.first(where: { $0.id == decision.model })?.provider,
                      !excluded.contains(provider) else { throw failure }
                excluded.insert(provider)
                dropped.append(RouterCatalog.label(for: provider))
            }
        }
    }

    /// Like `complete`, but never records the routing decision as the conversation's
    /// own. Side runs - the exploration subagent - use it so their model choice does
    /// not overwrite what the picker shows for the main run.
    public func completeWithFailover(
        messages: [AgentMessage],
        tools: [AgentToolDefinition] = []
    ) async throws -> AgentResponse {
        try await sendAcrossProviders(
            messages: messages,
            tools: tools,
            cachePolicy: AgentCachePolicy(),
            recordDecision: false
        )
    }

    /// Active accounts that can serve `model`, ordered best-first:
    /// 1. a live `preferred` account (conversation affinity) that is not cooling
    ///    down comes first, so follow-up turns keep the provider's prompt cache;
    /// 2. otherwise accounts not in cooldown, most remaining quota first
    ///    (unknown usage sorts below known-healthy but above known-exhausted),
    ///    `priority` (provider order) breaking ties;
    /// 3. cooling-down accounts last, as a final fallback.
    /// Pure and side-effect free so it can be unit tested without the network.
    func orderedRoutes(
        _ accounts: [StoredProviderAccount],
        model: String,
        preferred: String?,
        usage: [String: AccountUsageSnapshot],
        now: Date
    ) -> [StoredProviderAccount] {
        let serving = accounts
            .filter { $0.active && canServe($0, model: model) }

        func coolingDown(_ account: StoredProviderAccount) -> Bool {
            guard let until = account.cooldownUntil else { return false }
            return until > now
        }
        // nil usage -> 0 so it sorts between healthy (>0) and exhausted (<0).
        func remainingRank(_ account: StoredProviderAccount) -> Double {
            guard let fraction = usage[account.id]?.remainingFraction else { return 0 }
            return fraction <= 0 ? -1 : fraction
        }

        let ranked = serving.sorted { lhs, rhs in
            let lc = coolingDown(lhs), rc = coolingDown(rhs)
            if lc != rc { return !lc }
            let lr = remainingRank(lhs), rr = remainingRank(rhs)
            if lr != rr { return lr > rr }
            if lhs.priority != rhs.priority { return lhs.priority < rhs.priority }
            return lhs.id < rhs.id
        }

        if let preferred,
           let pinned = ranked.first(where: { $0.id == preferred }),
           !coolingDown(pinned) {
            return [pinned] + ranked.filter { $0.id != preferred }
        }
        return ranked
    }

    /// Validates a conversation's pinned account against the turn about to run.
    /// Returns `sticky` when the pin still holds, `nil` when it must be dropped
    /// and the account re-selected (model changed, provider can no longer serve
    /// it, account gone/inactive, or the account is cooling down).
    public func affinityAccountID(sticky: String, stickyModelID: String?, targetModel: String) -> String? {
        let resolved = targetModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let isAuto = resolved.isEmpty || resolved == ModelRouter.autoModelID
        if let stickyModelID, !stickyModelID.isEmpty, !isAuto, resolved != stickyModelID {
            return nil
        }
        guard let account = store.state.accounts.first(where: { $0.id == sticky }), account.active else {
            return nil
        }
        if let until = account.cooldownUntil, until > Date() { return nil }
        let probeModel = isAuto ? (stickyModelID ?? "") : resolved
        guard canServe(account, model: probeModel) else { return nil }
        return sticky
    }

    private func send(
        messages: [AgentMessage],
        tools: [AgentToolDefinition],
        cachePolicy: AgentCachePolicy,
        model requestedModel: String?,
        preferredAccountID: String? = nil
    ) async throws -> AgentResponse {
        let routes = orderedRoutes(
            store.state.accounts,
            model: requestedModel ?? "",
            preferred: preferredAccountID,
            usage: accountUsage,
            now: Date()
        )
        guard !routes.isEmpty else { throw NativeAgentError(AppCopy.text("agent.configureEndpoint")) }
        var failures: [String] = []
        for account in routes {
            var refreshed = false
            while true {
                do {
                    let configuration = try configuration(for: account, model: requestedModel)
                    let routeKey = Self.routeCacheKey(cachePolicy.promptCacheKey, accountID: account.id, provider: account.provider, api: account.api)
                    let response = try await NativeAgentClient(configuration: configuration).complete(
                        messages: messages,
                        tools: tools,
                        cachePolicy: AgentCachePolicy(promptCacheKey: routeKey)
                    )
                    status = AppCopy.format("router.connected", configuration.provider)
                    lastServedAccountID = account.id
                    lastServedModelID = configuration.model
                    try? store.setCooldown(account.id, until: nil)
                    return response
                } catch is CancellationError {
                    throw CancellationError()
                } catch let failure as NativeAgentError {
                    if failure.isLimit {
                        try? store.setCooldown(
                            account.id,
                            until: failure.retryAt ?? Date().addingTimeInterval(900)
                        )
                        throw failure
                    }
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

    private func configuration(
        for account: StoredProviderAccount,
        model: String? = nil,
        loadCredentials: Bool = true
    ) throws -> AgentConfiguration {
        guard !account.baseURL.isEmpty, !account.model.isEmpty else { throw NativeAgentError("Provider endpoint is incomplete.") }
        let key = loadCredentials ? try store.credential(for: account) : nil
        if loadCredentials && (account.api == RouterAPIKind.anthropic.rawValue || account.api == RouterAPIKind.chatGPT.rawValue) {
            guard key != nil else { throw ProviderStoreError.credentialUnavailable }
        }
        var config = AgentConfiguration(
            baseURL: account.baseURL,
            model: model?.isEmpty == false ? model! : effectiveModel(for: account),
            apiKey: key,
            provider: RouterCatalog.label(for: account.provider),
            api: account.api,
            accountID: account.id,
            sessionAccountID: account.sessionAccountID,
            specID: account.provider,
            authType: account.authType,
            effort: effort(for: model?.isEmpty == false ? model! : effectiveModel(for: account)),
            contextWindow: contextWindow(for: model?.isEmpty == false ? model : effectiveModel(for: account)),
            supportsNativeCompaction: RouterCatalog.spec(for: account.provider)?.transport.quirks.supportsNativeCompaction ?? false,
            compactionPolicy: AgentContextCompactionPolicy.current()
        )
        config.fast = fastMode && supportsFast(config.model)
        return config
    }

    private static func routeCacheKey(_ base: String?, accountID: String, provider: String, api: String) -> String? {
        guard let base, !base.isEmpty else { return nil }
        let identity = "\(base)|\(provider)|\(api)|\(accountID)"
        let digest = SHA256.hash(data: Data(identity.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return base + ":route-" + String(digest.prefix(24))
    }

    /// Effort levels the picker offers for `model`, low to high. Empty means the
    /// model rejects the parameter, so the control is hidden.
    public func efforts(for model: String) -> [String] {
        if let resolved = models.first(where: { $0.id == model }) { return resolved.efforts }
        return ProviderRegistry.shared.specs.flatMap(\.models).first { $0.id == model }?.efforts ?? []
    }

    /// Whether `model` offers a fast (priority) mode, per the provider registry.
    public func supportsFast(_ model: String) -> Bool {
        if let resolved = models.first(where: { $0.id == model }) { return resolved.fast }
        return ProviderRegistry.shared.specs.flatMap(\.models).first { $0.id == model }?.fast ?? false
    }

    /// The selected effort, but only when the target model actually accepts it.
    /// Automatic routing chooses its own level, which wins for that request.
    private func effort(for model: String) -> String {
        let supported = efforts(for: model)
        if let override = autoEffortOverride {
            return supported.contains(override) ? override : ""
        }
        return effectiveEffort(for: model)
    }

    /// Selected effort, falling back to "low" (or the lowest level) when none is set.
    public func effectiveEffort(for model: String) -> String {
        let supported = efforts(for: model)
        if supported.contains(selectedEffort) { return selectedEffort }
        return supported.contains("low") ? "low" : (supported.first ?? "")
    }

    /// True when the user picked "Auto" rather than a specific model.
    public var isAutoSelected: Bool { selectedModelID == ModelRouter.autoModelID }

    /// Models automatic routing may choose from: everything a connected account
    /// can actually serve.
    public var routableModels: [RouterModel] {
        models.filter { candidate in
            store.state.accounts.contains { $0.active && canServe($0, model: candidate.id) }
        }
    }

    /// Preview of what automatic routing would do for `messages`, without sending.
    public func previewAutoDecision(for messages: [AgentMessage]) -> ModelDecision? {
        ModelRouter.decide(messages: messages, available: routableModels)
    }

    private func effectiveModel(for account: StoredProviderAccount) -> String {
        guard account.api == RouterAPIKind.chatGPT.rawValue
            || account.authType == "oauth"
            || account.authType == "chatgpt" else { return account.model }
        let registered = RouterCatalog.spec(for: account.provider)?.models.map(\.id) ?? []
        return registered.contains(account.model) || registered.isEmpty ? account.model : registered[0]
    }

    private func isCompactModel(_ model: String) -> Bool {
        let id = model.lowercased()
        return id.contains("mini") || id.contains("nano") || id.contains("haiku")
            || id.contains("flash") || id.contains("lite") || id.contains("small")
    }

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
            error = "This provider needs a Custom API endpoint."
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
            error = "This provider does not support browser sign-in. Use an API key or Custom API."
            return
        }
        let engine = OAuthFlow(spec: oauth, session: oauthSession)
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
        status = AppCopy.text("router.waitingAuthorization")
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
            throw RouterTestError.message("Could not read the Google Code Assist project for this account.")
        }
        // The field is a bare string on some accounts and an object on others.
        let project = payload["cloudaicompanionProject"]?.string
            ?? payload["cloudaicompanionProject"]?["id"]?.string
        guard let project, !project.isEmpty else {
            throw RouterTestError.message("This Google account has no Gemini Code Assist project.")
        }
        return project
    }

    public func startDevice() async {
        guard let spec = RouterCatalog.spec(for: selectedKind.id), let oauth = spec.oauth,
              oauth.deviceCodeURL?.isEmpty == false else {
            error = "This provider does not expose a native device login yet. Use an API key or Custom API."
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
        if let url = URL(string: device.verificationURL) { NSWorkspace.shared.open(url) }

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

    /// Where to list this account's models. A provider may host the listing off
    /// its chat base path, so the registry's `modelsURL` wins when present.
    private func modelsURL(for account: StoredProviderAccount) -> URL? {
        if let declared = RouterCatalog.spec(for: account.provider)?.apiKey?.modelsURL, !declared.isEmpty {
            return URL(string: declared)
        }
        let base = account.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return URL(string: base + "/models")
    }

    /// Applies the account's credential to `request`. An OAuth/subscription token
    /// is a bearer token even on Anthropic, whose API-key header is `x-api-key` —
    /// sending an OAuth token there is rejected with HTTP 401.
    private func authorize(_ request: inout URLRequest, for account: StoredProviderAccount) {
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
        do {
            let secret = customAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if let editingNodeID, let endpoint = store.state.endpoints.first(where: { $0.id == editingNodeID }) {
                try store.updateCustom(endpoint: endpoint, name: name, prefix: prefix, baseURL: base, api: customKind.rawValue, apiType: customAPIType.rawValue, secret: secret.isEmpty ? nil : secret)
                onConnectionChanged?(ConnectionTransition(action: "replaced", previousConnectionLabel: endpoint.name, currentConnectionLabel: name, cleanupStatus: "preserved"))
                self.editingNodeID = nil
                status = "Custom API “\(name)” updated"
            } else {
                let endpoint = try store.addCustom(name: name, prefix: prefix, baseURL: base, api: customKind.rawValue, apiType: customAPIType.rawValue, secret: secret)
                if registerKey { _ = try store.addCustomAccount(endpoint: endpoint, secret: secret) }
                onConnectionChanged?(ConnectionTransition(action: "added", currentConnectionLabel: name, cleanupStatus: "preserved"))
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

    private func credentialIsAbsent(_ id: String?) -> Bool {
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

    private func refreshState() {
        connections = store.state.accounts.map(RouterConnection.init(from:))
        nodes = store.state.endpoints.map(RouterNode.init(from:))
        // Seed from the registry so the picker has the connected accounts' models
        // on launch, without waiting on (or requiring) a live listing.
        if models.isEmpty { models = registryModels() }
        selectedModelID = selectedModelID.isEmpty ? store.state.accounts.first(where: \.active)?.model ?? "" : selectedModelID
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
                    id: spec.id, owner: owner, contextWindow: spec.contextWindow, efforts: spec.efforts,
                    displayName: spec.name, provider: account.provider, tier: spec.tier, fast: spec.fast
                ))
            }
            if !account.model.isEmpty, !seeded.contains(where: { $0.id == account.model }) {
                seeded.append(RouterModel(id: account.model, owner: owner, provider: account.provider))
            }
        }
        return seeded
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

// Copyright (c) 2026 DOTS
// Provider model refresh, context windows and agent/media configuration.

import AppKit
import CryptoKit
import Foundation
import HarnessPluginKit
import Network
import PluginRuntime

extension RouterController {
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
        if !force, let last = lastModelRefresh, Date().timeIntervalSince(last) < Self.modelRefreshInterval { return }
        lastModelRefresh = Date()
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
        for account in activeAccounts where !registryOnlyModels(account) {
            guard let url = modelsURL(for: account) else { continue }
            var request = URLRequest(url: url, timeoutInterval: 8)
            authorize(&request, for: account)
            requests[account.id] = request
        }
        let results: [String: Result<Data, Error>] = await withTaskGroup(of: (String, Result<Data, Error>).self) { group in
            for (id, request) in requests {
                group.addTask {
                    do {
                        let (data, response) = try await URLSession.shared.data(for: request)
                        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                        guard (200..<300).contains(code) else { throw RouterTestError.http(code) }
                        return (id, .success(data))
                    } catch { return (id, .failure(error)) }
                }
            }
            var collected: [String: Result<Data, Error>] = [:]
            for await (id, result) in group { collected[id] = result }
            return collected
        }
        var issues: [String] = []

        for account in activeAccounts {
            let owner = RouterCatalog.label(for: account.provider)
            let specModels = RouterCatalog.spec(for: account.provider)?.models ?? []
            // Effort levels are model-specific and no provider publishes them, so
            // they always come from the registry — matched by id against whatever
            // the live listing returns.
            func model(id: String, name: String? = nil) -> RouterModel {
                let spec = specModels.first { $0.id == id }
                let efforts: [String] = {
                    if let explicit = spec?.efforts, !explicit.isEmpty { return explicit }
                    return RouterCatalog.inferredEfforts(for: id, provider: account.provider)
                }()
                return RouterModel(
                    id: id,
                    owner: owner,
                    contextWindow: spec?.contextWindow,
                    efforts: efforts,
                    displayName: name ?? spec?.name,
                    provider: account.provider,
                    tier: spec?.tier,
                    fast: spec?.fast ?? false
                )
            }

            // The Codex backend has no model listing (its `/models` 400s and the
            // ChatGPT web list carries different ids), so it stays registry-driven.
            if registryOnlyModels(account) {
                for spec in specModels { next.append(model(id: spec.id)) }
                if specModels.isEmpty, !account.model.isEmpty { next.append(model(id: account.model)) }
                continue
            }

            var live: [RouterModel] = []
            switch results[account.id] {
            case .failure(let failure):
                issues.append("\(owner): \(failure.localizedDescription)")
            case .success(let data):
                if let payload = try? JSONCodec.parse(data), case .array(let items) = payload["data"] {
                    live = items.compactMap { item in
                        // Gemini's OpenAI-compatible listing prefixes ids with `models/`.
                        guard var id = item["id"]?.string, !id.isEmpty else { return nil }
                        if id.hasPrefix("models/") { id.removeFirst("models/".count) }
                        var discovered = model(id: id, name: item["display_name"]?.string)
                        discovered.contextWindow = item["context_length"]?.int
                            ?? item["contextWindow"]?.int
                            ?? discovered.contextWindow
                        return discovered
                    }
                } else {
                    issues.append("\(owner): unrecognized model list")
                }
            case nil: break
            }
            next.append(contentsOf: live)
            // Registry entries the listing omits are a floor for when the listing is
            // unavailable. Once it succeeds it is authoritative — retired models drop
            // out — except on Anthropic, whose listing omits aliases like `claude-haiku-4-5`.
            let listingIsAuthoritative = !live.isEmpty && account.api != RouterAPIKind.anthropic.rawValue
            for spec in specModels where !listingIsAuthoritative && !live.contains(where: { $0.id == spec.id }) {
                next.append(model(id: spec.id))
            }
            if live.isEmpty,
               !account.model.isEmpty,
               !next.contains(where: { $0.id == account.model && $0.provider == account.provider }) {
                next.append(model(id: account.model))
            }
        }
        modelListIssues = issues
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
    func canServe(_ account: StoredProviderAccount, model: String) -> Bool {
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
}

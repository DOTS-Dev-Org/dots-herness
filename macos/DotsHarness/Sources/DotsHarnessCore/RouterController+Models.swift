// Copyright (c) 2026 DOTS
// Provider model refresh, context windows and agent/media configuration.

import AppKit
import CoreFoundation
import CryptoKit
import Foundation
import HarnessPluginKit
import Network
import PluginRuntime

private struct CodexModelCatalogPayload: Decodable {
    struct Model: Decodable {
        struct ReasoningLevel: Decodable {
            let effort: String
        }

        struct ServiceTier: Decodable {
            let id: String
        }

        let slug: String
        let displayName: String?
        let visibility: String?
        let contextWindow: Int?
        let supportedReasoningLevels: [ReasoningLevel]?
        let serviceTiers: [ServiceTier]?
        let additionalSpeedTiers: [String]?
        let priority: Int?

        private enum CodingKeys: String, CodingKey {
            case slug, visibility, priority
            case displayName = "display_name"
            case contextWindow = "context_window"
            case supportedReasoningLevels = "supported_reasoning_levels"
            case serviceTiers = "service_tiers"
            case additionalSpeedTiers = "additional_speed_tiers"
        }

        var supportsFast: Bool {
            additionalSpeedTiers?.contains("fast") == true
                || serviceTiers?.contains(where: { ["fast", "priority"].contains($0.id.lowercased()) }) == true
        }
    }

    let models: [Model]
}

/// Normalizes the common model-catalog shapes used by OpenAI-compatible APIs,
/// Anthropic, and Google's OpenAI-compatible Gemini endpoint.
private enum ProviderModelCatalogDecoder {
    struct Model {
        let id: String
        let name: String?
        let contextWindow: Int?
        let efforts: [String]?
        let fast: Bool
        let tools: Bool?
    }

    private static let effortOrder = ["none", "low", "medium", "high", "xhigh", "max"]

    static func decode(_ data: Data) -> [Model]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return nil }
        let rows: [[String: Any]]?
        if let object = root as? [String: Any] {
            if let dataRows = object["data"] as? [[String: Any]] {
                rows = dataRows
            } else if let modelRows = object["models"] as? [[String: Any]] {
                rows = modelRows
            } else if let modelMap = object["models"] as? [String: Any] {
                rows = modelMap.keys.sorted().compactMap { id in
                    guard var row = modelMap[id] as? [String: Any] else { return nil }
                    row["id"] = id
                    return row
                }
            } else {
                rows = object["modelList"] as? [[String: Any]]
                    ?? object["buckets"] as? [[String: Any]]
            }
        } else {
            rows = root as? [[String: Any]]
        }
        guard let rows else { return nil }

        return rows.compactMap { row in
            guard var id = firstString(in: row, keys: ["id", "slug", "name", "model", "modelId"]), !id.isEmpty else { return nil }
            if id.hasPrefix("models/") { id.removeFirst("models/".count) }
            guard !id.isEmpty else { return nil }
            return Model(
                id: id,
                name: firstString(in: row, keys: ["display_name", "displayName", "label"]),
            contextWindow: contextWindow(in: row),
                efforts: reasoningEfforts(in: row),
                fast: supportsFast(in: row),
                tools: toolSupport(in: row)
            )
        }
    }

    private static func toolSupport(in row: [String: Any]) -> Bool? {
        if let value = row["tools"] as? Bool { return value }
        if let capabilities = row["capabilities"] as? [String: Any],
           let value = capabilities["tools"] as? Bool {
            return value
        }
        return nil
    }

    private static func firstString(in row: [String: Any], keys: [String]) -> String? {
        for key in keys {
            guard let value = row[key] as? String else { continue }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    private static func firstPositiveInteger(in row: [String: Any], keys: [String]) -> Int? {
        for key in keys {
            guard let actualKey = row.keys.first(where: { $0.caseInsensitiveCompare(key) == .orderedSame }),
                  let value = row[actualKey] as? NSNumber,
                  CFGetTypeID(value) != CFBooleanGetTypeID(),
                  value.doubleValue.rounded(.towardZero) == value.doubleValue,
                  value.doubleValue > 0,
                  value.doubleValue <= Double(Int.max) else { continue }
            return value.intValue
        }
        return nil
    }

    private static let contextWindowKeys = [
        "context_length", "context_window", "max_context_length", "context_size",
        "contextLength", "contextWindow", "maxContextLength", "contextSize",
        "input_token_limit", "inputTokenLimit", "max_input_tokens", "maxInputTokens",
        "input_token_count", "max_input_token_count", "maxInputTokenCount"
    ]

    /// Reads only input/context limits. Output-token limits are deliberately
    /// excluded because they are not the model's full context capacity.
    private static func contextWindow(in row: [String: Any], depth: Int = 0) -> Int? {
        if let direct = firstPositiveInteger(in: row, keys: contextWindowKeys) { return direct }
        if depth < 4 {
            for key in ["limits", "limit", "metadata", "model_info", "modelInfo", "top_provider", "details", "config"] {
                guard let actualKey = row.keys.first(where: { $0.caseInsensitiveCompare(key) == .orderedSame }),
                      let nested = row[actualKey] as? [String: Any],
                      let context = contextWindow(in: nested, depth: depth + 1) else { continue }
                return context
            }
        }
        // Ollama exposes the architecture-specific field as e.g.
        // `general.context_length` inside model_info.
        for (key, value) in row where key.lowercased().hasSuffix(".context_length") {
            if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
               number.doubleValue > 0, number.doubleValue <= Double(Int.max) {
                return number.intValue
            }
        }
        return nil
    }

    private static func reasoningEfforts(in row: [String: Any]) -> [String]? {
        if let levels = row["supported_reasoning_levels"] as? [Any] {
            let values = levels.compactMap { value -> String? in
                if let string = value as? String { return string }
                return (value as? [String: Any])?["effort"] as? String
            }
            if !values.isEmpty { return orderedEfforts(values) }
        }
        guard let capabilities = row["capabilities"] as? [String: Any],
              let effort = capabilities["effort"] as? [String: Any] else { return nil }
        let supported = effortOrder.filter { level in
            (effort[level] as? [String: Any])?["supported"] as? Bool == true
        }
        return supported.isEmpty ? nil : supported
    }

    private static func orderedEfforts(_ values: [String]) -> [String] {
        let present = Set(values.map { $0.lowercased() })
        return effortOrder.filter(present.contains)
    }

    private static func supportsFast(in row: [String: Any]) -> Bool {
        if let tiers = row["additional_speed_tiers"] as? [String], tiers.contains(where: { $0.lowercased() == "fast" }) {
            return true
        }
        if let tiers = row["service_tiers"] as? [Any] {
            return tiers.contains { tier in
                let id = (tier as? String) ?? (tier as? [String: Any])?["id"] as? String
                return ["fast", "priority"].contains(id?.lowercased() ?? "")
            }
        }
        return false
    }
}

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

    /// The last good listing of one provider, kept while its catalog cannot be read.
    static func carriedListing(provider: String, from known: [RouterModel]) -> [RouterModel] {
        known.filter { $0.provider == provider }
    }

    private func performModelRefresh() async {
        await ProviderRegistry.shared.refreshRemote()
        // Read before the listing is replaced: a failed account keeps this snapshot.
        let known = models
        var next: [RouterModel] = []
        let activeAccounts = store.state.accounts.filter(\.active)

        // Each supported provider catalog is requested concurrently. Requests are
        // built here so Keychain reads stay on the main actor.
        var requests: [String: URLRequest] = [:]
        for account in activeAccounts where !registryOnlyModels(account) {
            if let request = modelCatalogRequest(for: account) {
                requests[account.id] = request
            }
        }
        var results: [String: Result<Data, Error>] = await withTaskGroup(of: (String, Result<Data, Error>).self) { group in
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
        for account in activeAccounts where account.authType == "oauth" || account.authType == "chatgpt" {
            guard let result = results[account.id],
                  case .failure(let error) = result,
                  let routerError = error as? RouterTestError,
                  isUnauthorized(routerError),
                  await refreshCredential(for: account),
                  let request = modelCatalogRequest(for: account) else { continue }
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard (200..<300).contains(code) else { throw RouterTestError.http(code) }
                results[account.id] = .success(data)
            } catch {
                results[account.id] = .failure(error)
            }
        }
        var issues: [String] = []
        var geminiContexts: [String: [String: Int]] = [:]
        for account in activeAccounts where account.provider == "gemini" {
            guard let request = geminiModelMetadataRequest(for: account) else { continue }
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200,
                      let metadata = ProviderModelCatalogDecoder.decode(data) else { continue }
                geminiContexts[account.id] = Dictionary(
                    metadata.compactMap { item in item.contextWindow.map { (item.id, $0) } },
                    uniquingKeysWith: { first, _ in first }
                )
            } catch {
                // The OpenAI-compatible catalog remains usable when Gemini's
                // supplemental metadata endpoint is unavailable.
            }
        }
        // Local servers report the context they actually serve through their own
        // endpoints, not `/models`. An account the user sized by hand is left alone.
        var servedContexts: [String: [String: Int]] = [:]
        for account in activeAccounts where account.authType == "custom" && account.contextWindow == nil {
            guard case .success(let data) = results[account.id] else { continue }
            let listedIDs = ProviderModelCatalogDecoder.decode(data)?.map(\.id) ?? []
            let modelIDs = listedIDs.isEmpty ? [account.model] : listedIDs
            servedContexts[account.id] = await LocalServerProbe.contextWindows(
                baseURL: account.baseURL,
                modelIDs: modelIDs
            )
        }

        for account in activeAccounts {
            let owner = RouterCatalog.label(for: account.provider)
            let specModels = RouterCatalog.spec(for: account.provider)?.models ?? []
            let specsByID = Dictionary(specModels.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            // Prefer model-specific effort levels from live catalogs when present;
            // the registry and id-based inference keep older providers covered.
            func model(
                id: String,
                name: String? = nil,
                discoveredEfforts: [String]? = nil,
                contextWindow: Int? = nil,
                fast: Bool? = nil,
                tools: Bool? = nil
            ) -> RouterModel {
                let spec = specsByID[id]
                let efforts: [String] = {
                    if let discoveredEfforts, !discoveredEfforts.isEmpty { return discoveredEfforts }
                    if let explicit = spec?.efforts, !explicit.isEmpty { return explicit }
                    return RouterCatalog.inferredEfforts(for: id, provider: account.provider)
                }()
                return RouterModel(
                    id: id,
                    owner: owner,
                    contextWindow: RouterCatalog.documentedContextWindow(for: id, provider: account.provider)
                    ?? servedContexts[account.id]?[id] ?? servedContexts[account.id]?[LocalServerProbe.anyModel]
                    ?? geminiContexts[account.id]?[id] ?? contextWindow ?? spec?.contextWindow,
                    tools: RouterCatalog.supportsToolCalling(for: account.provider, reported: tools),
                    efforts: efforts,
                    displayName: name ?? spec?.name,
                    provider: account.provider,
                    tier: spec?.tier,
                    fast: fast ?? spec?.fast ?? false,
                    supportsLegacyThinkingBudget: spec?.supportsLegacyThinkingBudget ?? false
                )
            }

            // Claude subscription auth does not expose a supported public catalog.
            // Google Code Assist adapters provide their own account model data;
            // ChatGPT uses the Codex model-catalog payload below.
            if registryOnlyModels(account) {
                for spec in specModels { next.append(model(id: spec.id)) }
                if specModels.isEmpty, !account.model.isEmpty { next.append(model(id: account.model)) }
                continue
            }

            var live: [RouterModel] = []
            switch results[account.id] {
            case .failure(let failure):
                issues.append("\(owner): \(failure.localizedDescription)")
                // The registry knows neither windows nor models the listing added; a
                // failed refresh keeps the last good listing for this provider instead.
                live = Self.carriedListing(provider: account.provider, from: known)
            case .success(let data):
                if account.provider == "gpt" {
                    if let catalog = try? JSONDecoder().decode(CodexModelCatalogPayload.self, from: data) {
                        let visible = catalog.models.enumerated()
                            .filter { $0.element.visibility == "list" }
                            .sorted {
                                let lhs = $0.element.priority ?? Int.max
                                let rhs = $1.element.priority ?? Int.max
                                return lhs == rhs ? $0.offset < $1.offset : lhs < rhs
                            }
                            .map(\.element)
                        live = visible.compactMap { item in
                            guard !item.slug.isEmpty else { return nil }
                            return model(
                                id: item.slug,
                                name: item.displayName,
                                discoveredEfforts: item.supportedReasoningLevels?.map(\.effort),
                                contextWindow: item.contextWindow,
                                fast: item.supportsFast
                            )
                        }
                    } else {
                        issues.append("\(owner): unrecognized model list")
                    }
                } else if let catalogModels = ProviderModelCatalogDecoder.decode(data) {
                    live = catalogModels.map { item in
                        model(
                            id: item.id,
                            name: item.name,
                            discoveredEfforts: item.efforts,
                            contextWindow: item.contextWindow,
                            fast: item.fast,
                            tools: item.tools
                        )
                    }
                    // A local server with a declared model may list nothing.
                    if live.isEmpty, account.authType != "custom" || account.hasPlaceholderModel {
                        issues.append("\(owner): model list was empty")
                    }
                } else {
                    issues.append("\(owner): unrecognized model list")
                }
            case nil: break
            }
            next.append(contentsOf: live)
            // A non-empty provider response is authoritative so retired models
            // disappear automatically. The registry is an offline/error fallback.
            let listingIsAuthoritative = !live.isEmpty
            for spec in specModels where !listingIsAuthoritative && !live.contains(where: { $0.id == spec.id }) {
                next.append(model(id: spec.id))
            }
            if live.isEmpty,
               !account.model.isEmpty, !account.hasPlaceholderModel,
               !next.contains(where: { $0.id == account.model && $0.provider == account.provider }) {
                next.append(model(id: account.model))
            }
        }
        modelListIssues = issues
        var seenModels = Set<String>()
        models = next.filter { seenModels.insert($0.provider + "\0" + $0.id).inserted }
        if selectedModelID.isEmpty {
            select(modelID: models.first?.id ?? "")
        }
        // The listing is authoritative now, so a selection it no longer contains
        // was retired and must not keep being requested.
        reconcileSelection()
        persistModelCatalog()
    }

    public func refreshModelsIfNeeded() async { await refreshModels() }

    /// Models available from accounts the user has configured, including
    /// disconnected accounts and registry entries not returned by a live API.
    public var modelContextSettings: [RouterModel] {
        var result = models
        var seen = Set(models.map { $0.provider + "\0" + $0.id })
        for account in store.state.accounts {
            let specs = RouterCatalog.spec(for: account.provider)?.models ?? []
            var candidates = specs
            if !account.hasPlaceholderModel,
               !account.model.isEmpty,
               !candidates.contains(where: { $0.id == account.model }) {
                candidates.append(ProviderSpec.ModelSpec(
                    id: account.model,
                    name: nil,
                    efforts: [],
                    tier: nil,
                    contextWindow: account.contextWindow,
                    fast: false,
                    supportsLegacyThinkingBudget: false
                ))
            }
            for spec in candidates where seen.insert(account.provider + "\0" + spec.id).inserted {
                result.append(RouterModel(
                    id: spec.id,
                    owner: RouterCatalog.label(for: account.provider),
                    contextWindow: RouterCatalog.documentedContextWindow(for: spec.id, provider: account.provider) ?? spec.contextWindow ?? account.contextWindow,
                    efforts: spec.efforts,
                    displayName: spec.name,
                    provider: account.provider,
                    tier: spec.tier,
                    fast: spec.fast,
                    supportsLegacyThinkingBudget: spec.supportsLegacyThinkingBudget
                ))
            }
        }
        return result.sorted {
            let leftProvider = RouterCatalog.label(for: $0.provider)
            let rightProvider = RouterCatalog.label(for: $1.provider)
            if leftProvider != rightProvider { return leftProvider.localizedCaseInsensitiveCompare(rightProvider) == .orderedAscending }
            return $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending
        }
    }

    private func isUnauthorized(_ error: RouterTestError) -> Bool {
        if case .http(401) = error { return true }
        return false
    }

    public func modelContextWindowOverride(for model: String, provider: String) -> Int? {
        store.state.modelContextWindowOverrides[
            RouterCatalog.modelContextOverrideKey(provider: provider, model: model)
        ]
    }

    /// Highest-priority active account that can serve the model, on the preferred provider when there is one.
    private func servingAccount(for model: String?, provider preferredProvider: String?) -> StoredProviderAccount? {
        let accounts = store.state.accounts
            .filter(\.active)
            .sorted { $0.priority < $1.priority }
        return accounts.first {
            (preferredProvider == nil || $0.provider == preferredProvider) && canServe($0, model: model ?? "")
        } ?? accounts.first { canServe($0, model: model ?? "") }
    }

    /// Automatically reported or documented context size, before applying a
    /// user override or the conservative runtime fallback.
    public func detectedContextWindow(for model: String? = nil, provider preferredProvider: String? = nil) -> Int? {
        let account = servingAccount(for: model, provider: preferredProvider)
        let provider = preferredProvider ?? account?.provider
        if let model, let provider,
           let documented = RouterCatalog.documentedContextWindow(for: model, provider: provider) { return documented }
        if let model,
           let live = models.first(where: {
               $0.id == model && (provider == nil || $0.provider == provider)
           })?.contextWindow, live > 0 { return live }
        if let model, let provider,
           let staticWindow = RouterCatalog.spec(for: provider)?.models.first(where: { $0.id == model })?.contextWindow,
           staticWindow > 0 { return staticWindow }
        if let model, provider == nil,
           let staticWindow = ProviderRegistry.shared.specs.flatMap(\.models)
            .first(where: { $0.id == model })?.contextWindow, staticWindow > 0 { return staticWindow }
        if let declared = account?.contextWindow, declared > 0 { return declared }
        return nil
    }

    public func setModelContextWindowOverride(_ contextWindow: Int?, for model: String, provider: String) throws {
        if let contextWindow, contextWindow <= 0 {
            throw RouterTestError.message(AppCopy.text("custom.contextInvalid"))
        }
        try store.setModelContextWindowOverride(provider: provider, model: model, contextWindow: contextWindow)
        objectWillChange.send()
    }

    public func contextWindow(for model: String? = nil, provider preferredProvider: String? = nil) -> Int {
        let account = servingAccount(for: model, provider: preferredProvider)
        let provider = preferredProvider ?? account?.provider
        if let model, let provider,
           let override = modelContextWindowOverride(for: model, provider: provider), override > 0 {
            return override
        }
        if let detected = detectedContextWindow(for: model, provider: preferredProvider) { return detected }
        if account?.provider == "openai" { return 128_000 }
        switch account?.api {
        case RouterAPIKind.anthropic.rawValue: return 200_000
        case RouterAPIKind.chatGPT.rawValue: return 128_000
        default: return AgentContextCompaction.defaultContextWindow
        }
    }

    /// Which model should write a compaction summary after the conversation moved
    /// to a different route. The prompt cache the same-model summary call used to
    /// earn is gone with the route, so this becomes a cost decision: the smallest
    /// model of the account that just served the conversation comes first (it is
    /// still reading its own transcript), then the destination account's. `nil`
    /// means neither has a model that can hold the archive, so the caller has to
    /// compact deterministically without asking anyone.
    public func contextSummarizer(
        previousAccountID: String?,
        targetAccountID: String?,
        archiveTokens: Int
    ) -> (accountID: String, model: String)? {
        for accountID in [previousAccountID, targetAccountID] {
            guard let account = usableAccount(accountID) else { continue }
            if let model = cheapestModel(for: account, holding: archiveTokens) {
                return (account.id, model)
            }
        }
        return nil
    }

    /// Active, not cooling, and with quota left. Unknown quota counts as usable:
    /// API-key providers never report a limit, and treating them as exhausted
    /// would leave most setups without a summarizer.
    func usableAccount(_ accountID: String?) -> StoredProviderAccount? {
        guard let accountID,
              let account = store.state.accounts.first(where: { $0.id == accountID }),
              account.active else { return nil }
        if let until = account.cooldownUntil, until > Date() { return nil }
        guard accountUsage[account.id]?.remainingFraction.map({ $0 > 0 }) ?? true else { return nil }
        return account
    }

    /// Lowest-tier model `account` serves that can still read `tokens`. Registry
    /// order breaks ties, matching automatic routing. A hand-configured endpoint
    /// with no listing falls back to the account's own model.
    func cheapestModel(for account: StoredProviderAccount, holding tokens: Int) -> String? {
        let listed = models.filter { $0.provider == account.provider && canServe(account, model: $0.id) }
        let candidates = listed.isEmpty ? [RouterModel(id: effectiveModel(for: account), provider: account.provider)] : listed
        let fitting = candidates.filter { candidate in
            guard !candidate.id.isEmpty, candidate.id != ModelRouter.autoModelID else { return false }
            let budget = AgentContextCompaction.budget(
                contextWindow: RouterCatalog.documentedContextWindow(for: candidate.id, provider: candidate.provider)
                    ?? candidate.contextWindow ?? contextWindow(for: candidate.id, provider: candidate.provider)
            )
            return budget.fits(tokens)
        }
        for tier in ModelTier.allCases {
            if let match = fitting.first(where: { ModelRouter.tier(of: $0) == tier }) { return match.id }
        }
        return nil
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

    public var imageGenerationCommandVisible: Bool {
        // Keep the command discoverable for providers whose image capability is
        // not known yet. A missing adapter is an extension point, not a deny
        // decision: a later catalog entry or trusted plugin may add support.
        return imagePrimaryAccount != nil
    }
}

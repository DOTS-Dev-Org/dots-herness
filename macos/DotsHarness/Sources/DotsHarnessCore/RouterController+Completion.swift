// Copyright (c) 2026 DOTS
// Completion routing, failover and effort/model selection.

import AppKit
import CryptoKit
import Foundation
import HarnessPluginKit
import Network
import PluginRuntime

extension RouterController {
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

    /// One-shot side task (translation): the lightest connected model at its lowest
    /// effort, whatever the user picked for the conversation. Leaves routing state alone.
    public func completeCheapest(messages: [AgentMessage]) async throws -> AgentResponse {
        let cheapest = routableModels.min { ModelRouter.tier(of: $0) < ModelRouter.tier(of: $1) }
        guard let cheapest else { throw NativeAgentError(AppCopy.text("agent.configureEndpoint")) }
        let lowest = cheapest.efforts.first ?? ""
        return try await send(messages: messages, tools: [], cachePolicy: AgentCachePolicy(), model: cheapest.id, effortOverride: lowest)
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

    func send(
        messages: [AgentMessage],
        tools: [AgentToolDefinition],
        cachePolicy: AgentCachePolicy,
        model requestedModel: String?,
        preferredAccountID: String? = nil,
        effortOverride: String? = nil
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
                    let configuration = try configuration(for: account, model: requestedModel, effortOverride: effortOverride)
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

    func configuration(
        for account: StoredProviderAccount,
        model: String? = nil,
        loadCredentials: Bool = true,
        effortOverride: String? = nil
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
            effort: effortOverride ?? effort(for: model?.isEmpty == false ? model! : effectiveModel(for: account)),
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
    func effort(for model: String) -> String {
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

    func effectiveModel(for account: StoredProviderAccount) -> String {
        guard account.api == RouterAPIKind.chatGPT.rawValue
            || account.authType == "oauth"
            || account.authType == "chatgpt" else { return account.model }
        let registered = RouterCatalog.spec(for: account.provider)?.models.map(\.id) ?? []
        return registered.contains(account.model) || registered.isEmpty ? account.model : registered[0]
    }

    func isCompactModel(_ model: String) -> Bool {
        let id = model.lowercased()
        return id.contains("mini") || id.contains("nano") || id.contains("haiku")
            || id.contains("flash") || id.contains("lite") || id.contains("small")
    }
}

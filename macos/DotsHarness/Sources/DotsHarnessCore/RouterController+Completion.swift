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
        preferredAccountID: String? = nil,
        preferredModelID: String? = nil,
        disableNativeCompactionForRequest: Bool = false,
        onDelta: NativeAgentClient.StreamDeltaHandler? = nil
    ) async throws -> AgentResponse {
        let requestedModel = (model ?? selectedModelID).trimmingCharacters(in: .whitespacesAndNewlines)
        guard requestedModel == ModelRouter.autoModelID else {
            autoEffortOverride = nil
            return try await send(
                messages: messages,
                tools: tools,
                cachePolicy: cachePolicy,
                model: requestedModel.isEmpty ? nil : requestedModel,
                preferredAccountID: preferredAccountID,
                disableNativeCompactionForRequest: disableNativeCompactionForRequest,
                onDelta: onDelta
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
            preferredAccountID: preferredAccountID,
            preferredModelID: preferredModelID,
            disableNativeCompactionForRequest: disableNativeCompactionForRequest,
            onDelta: onDelta
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
        preferredAccountID: String? = nil,
        preferredModelID: String? = nil,
        disableNativeCompactionForRequest: Bool = false,
        onDelta: NativeAgentClient.StreamDeltaHandler? = nil
    ) async throws -> AgentResponse {
        var excluded: Set<String> = []
        var dropped: [String] = []
        while true {
            let routedDecision = ModelRouter.decide(
                messages: messages,
                available: routableModels,
                excluding: excluded,
                economy: usageMode == .economy,
                // The tool catalog is present on most agent requests even when
                // this turn will not call a tool. Economy's none/minimal path
                // must look at the active transcript, not catalog availability.
                hasTools: messages.last?.role == .tool || !(messages.last?.toolCalls.isEmpty ?? true),
                effortOverride: selectedEffort
            )
            let decision: ModelDecision?
            if let preferredModelID,
               let sticky = routableModels.first(where: { $0.id == preferredModelID && !excluded.contains($0.provider) }),
               let routedDecision {
                let role = ModelRouter.role(for: messages)
                let mechanical = !(messages.last?.role == .tool || !(messages.last?.toolCalls.isEmpty ?? true))
                    && role == .worker
                decision = ModelDecision(
                    model: sticky.id,
                    effort: ModelRouter.requestedEffort(selectedEffort, supported: sticky.efforts)
                        ?? ModelRouter.effort(
                            for: role,
                            supported: sticky.efforts,
                            mechanical: mechanical,
                            economy: usageMode == .economy
                        ),
                    role: routedDecision.role,
                    reason: "Auto: continuing (sticky.displayName ?? sticky.id)"
                )
            } else {
                decision = routedDecision
            }
            guard let decision else { throw NativeAgentError(AppCopy.text("agent.configureEndpoint")) }
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
                    preferredAccountID: preferredAccountID,
                    disableNativeCompactionForRequest: disableNativeCompactionForRequest,
                    onDelta: onDelta
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

    /// Models the exploration subagent can run on: it works through tools.
    public var explorationModels: [RouterModel] { routableModels.filter(\.tools) }

    /// What a sweep of the project runs on: the model the user picked, else the
    /// lightest one a subscription already pays for, else the lightest one behind
    /// an API key. Reading files and reporting where things are does not need the
    /// model the conversation runs on.
    public var explorationModel: RouterModel? {
        Self.explorationChoice(among: explorationModels, picked: explorationModelID)
    }

    static func explorationChoice(among usable: [RouterModel], picked: String) -> RouterModel? {
        if let chosen = usable.first(where: { $0.id == picked }) { return chosen }
        func lightest(_ models: [RouterModel]) -> RouterModel? {
            models.min { ModelRouter.tier(of: $0) < ModelRouter.tier(of: $1) }
        }
        let subscribed = usable.filter {
            [.oauth, .oauthDevice].contains(RouterCatalog.spec(for: $0.provider)?.category)
        }
        return lightest(subscribed) ?? lightest(usable)
    }

    /// One step of the exploration subagent, at low effort. When that model's
    /// quota is spent the sweep goes on wherever routing would send it, since a
    /// stopped side run costs the main one its answer.
    public func completeExploration(
        messages: [AgentMessage],
        tools: [AgentToolDefinition] = []
    ) async throws -> AgentResponse {
        guard let model = explorationModel else {
            return try await completeWithFailover(messages: messages, tools: tools)
        }
        do {
            return try await send(
                messages: messages,
                tools: tools,
                cachePolicy: AgentCachePolicy(),
                model: model.id,
                effortOverride: model.efforts.contains("low") ? "low" : (model.efforts.first ?? "")
            )
        } catch let failure as NativeAgentError where failure.isLimit {
            return try await completeWithFailover(messages: messages, tools: tools)
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
            // Keep conversation affinity as the first choice, while retaining
            // every other compatible account as a quota fallback.
            return [pinned] + ranked.filter { $0.id != pinned.id }
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
        effortOverride: String? = nil,
        disableNativeCompactionForRequest: Bool = false,
        onDelta: NativeAgentClient.StreamDeltaHandler? = nil
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
        var limitFailures: [(account: String, error: NativeAgentError)] = []
        for account in routes {
            var refreshed = false
            while true {
                do {
                    var configuration = try configuration(for: account, model: requestedModel, effortOverride: effortOverride)
                    configuration.disableNativeCompactionForRequest = disableNativeCompactionForRequest
                    let routeKey = Self.routeCacheKey(
                        cachePolicy.promptCacheKey,
                        accountID: account.id,
                        provider: account.provider,
                        api: account.api,
                        model: configuration.model
                    )
                    var response = try await NativeAgentClient(configuration: configuration).complete(
                        messages: messages,
                        tools: tools,
                        cachePolicy: AgentCachePolicy(promptCacheKey: routeKey,
                            comparisonResponseID: cachePolicy.comparisonResponseID,
                            comparisonScope: cachePolicy.comparisonScope,
                            priorBoundary: cachePolicy.priorBoundary),
                        onDelta: onDelta
                    )
                    response.servedAccountID = account.id
                    response.servedModelID = configuration.model
                    response.servedCacheKey = routeKey
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
                        limitFailures.append((account.name, failure))
                        break
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
        if !limitFailures.isEmpty {
            let limitMessages = limitFailures.map { "\($0.account): \($0.error.message)" }
            let retryAt = limitFailures.compactMap { $0.error.retryAt }.min()
            throw NativeAgentError(
                (limitMessages + failures).joined(separator: "\n"),
                retryable: false,
                isLimit: true,
                retryAt: retryAt
            )
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
        // No model was requested and the endpoint never named one: its server is
        // down or lists nothing. Sending the `prefix/` placeholder would only fail later.
        if model?.isEmpty != false, account.hasPlaceholderModel {
            throw NativeAgentError(AppCopy.format("custom.noModelAvailable", account.name))
        }
        let key = loadCredentials ? try store.credential(for: account) : nil
        if loadCredentials && (account.api == RouterAPIKind.anthropic.rawValue || account.api == RouterAPIKind.chatGPT.rawValue) {
            guard key != nil else { throw ProviderStoreError.credentialUnavailable }
        }
        var config = AgentConfiguration(
            baseURL: account.baseURL,
            model: model?.isEmpty == false ? model! : effectiveModel(for: account),
            apiKey: key,
            provider: RouterCatalog.label(for: account.provider),
            // Existing OpenAI API-key accounts were stored as Chat Completions.
            // The built-in OpenAI route now uses Responses so native compaction
            // is available without requiring users to reconnect their account.
            api: account.provider == "openai"
                ? RouterAPIKind.chatGPT.rawValue
                : account.api,
            accountID: account.id,
            sessionAccountID: account.sessionAccountID,
            specID: account.provider,
            authType: account.authType,
            effort: effortOverride ?? effort(for: model?.isEmpty == false ? model! : effectiveModel(for: account)),
            contextWindow: contextWindow(for: model?.isEmpty == false ? model : effectiveModel(for: account)),
            supportsNativeCompaction: RouterCatalog.spec(for: account.provider)?.transport.quirks.supportsNativeCompaction ?? false,
            compactionPolicy: usageMode == .economy ? .economy : AgentContextCompactionPolicy.current(),
            usageMode: usageMode,
            responseStylePreference: responseStylePreference,
            supportsLegacyThinkingBudget: supportsLegacyThinkingBudget(for: model?.isEmpty == false ? model! : effectiveModel(for: account))
        )
        config.fast = fastMode && usageMode != .economy && supportsFast(config.model)
        return config
    }

    private func supportsLegacyThinkingBudget(for model: String) -> Bool {
        if let resolved = models.first(where: { $0.id == model }) {
            return resolved.supportsLegacyThinkingBudget
        }
        return ProviderRegistry.shared.specs
            .flatMap(\.models)
            .first(where: { $0.id == model })?.supportsLegacyThinkingBudget ?? false
    }

    static func routeCacheKey(_ base: String?, accountID: String, provider: String, api: String, model: String) -> String? {
        guard let base, !base.isEmpty else { return nil }
        let identity = "\(base)|\(provider)|\(api)|\(accountID)|\(model)"
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

    /// The selected effort when the target model accepts it. Otherwise automatic
    /// routing chooses a level the model supports.
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
        ModelRouter.decide(
            messages: messages,
            available: routableModels,
            economy: usageMode == .economy,
            hasTools: messages.last?.role == .tool || !(messages.last?.toolCalls.isEmpty ?? true),
            effortOverride: selectedEffort
        )
    }

    /// Effort levels exposed while the model is automatic. The model may vary
    /// per message, so offer the levels accepted by any currently routable model.
    public var automaticEffortOptions: [String] {
        let available = Set(routableModels.flatMap(\.efforts))
        return ["none", "low", "medium", "high", "xhigh", "max"].filter(available.contains)
    }

    /// Resolves the expected route without loading credentials or sending a
    /// request. Context admission uses this so Auto switches are measured
    /// against the destination model before deciding whether to compact.
    func contextConfiguration(
        for messages: [AgentMessage],
        requestedModel: String?,
        preferredAccountID: String?,
        preferredModelID: String?
    ) -> AgentConfiguration? {
        let requested = (requestedModel ?? selectedModelID).trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedModel: String
        if requested == ModelRouter.autoModelID {
            resolvedModel = preferredModelID ?? previewAutoDecision(for: messages)?.model ?? ""
        } else {
            resolvedModel = requested
        }
        guard !resolvedModel.isEmpty else { return nil }
        let routes = orderedRoutes(
            store.state.accounts,
            model: resolvedModel,
            preferred: preferredAccountID,
            usage: accountUsage,
            now: Date()
        )
        guard let account = routes.first else { return nil }
        return try? configuration(for: account, model: resolvedModel, loadCredentials: false)
    }

    func effectiveModel(for account: StoredProviderAccount) -> String {
        guard account.api == RouterAPIKind.chatGPT.rawValue
            || account.authType == "oauth"
            || account.authType == "chatgpt" else { return account.model }
        let registered = RouterCatalog.spec(for: account.provider)?.models.map(\.id) ?? []
        return registered.contains(account.model) || registered.isEmpty ? account.model : registered[0]
    }
}

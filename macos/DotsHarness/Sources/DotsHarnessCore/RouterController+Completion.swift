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
        effort: String? = nil,
        allowAccountFailoverAfterLimit: Bool = false,
        disableNativeCompactionForRequest: Bool = false,
        onDelta: NativeAgentClient.StreamDeltaHandler? = nil
    ) async throws -> AgentResponse {
        // An unpinned turn picks the roomiest account, so read quotas first;
        // a reading under a minute old is reused.
        if preferredAccountID == nil { await refreshAccountUsage() }
        let requestedModel = (model ?? selectedModelID).trimmingCharacters(in: .whitespacesAndNewlines)
        guard requestedModel == ModelRouter.autoModelID else {
            autoEffortOverride = nil
            return try await send(
                messages: messages,
                tools: tools,
                cachePolicy: cachePolicy,
                model: requestedModel.isEmpty ? nil : requestedModel,
                preferredAccountID: preferredAccountID,
                allowAccountFailoverAfterLimit: allowAccountFailoverAfterLimit,
                // A caller's own level (a bot's) wins when the model accepts it.
                effortOverride: ModelRouter.requestedEffort(effort, supported: efforts(for: requestedModel)),
                disableNativeCompactionForRequest: disableNativeCompactionForRequest,
                onDelta: onDelta
            )
        }

        // Auto may pick another provider only when automatic failover is enabled
        // or the user explicitly resumed a limit-paused conversation.
        return try await sendAcrossProviders(
            messages: messages,
            tools: tools,
            cachePolicy: cachePolicy,
            recordDecision: true,
            preferredAccountID: preferredAccountID,
            preferredModelID: preferredModelID,
            effort: effort,
            allowAccountFailoverAfterLimit: allowAccountFailoverAfterLimit,
            disableNativeCompactionForRequest: disableNativeCompactionForRequest,
            onDelta: onDelta
        )
    }

    /// Sends `messages` across providers only when failover is enabled or the user
    /// explicitly resumed a limit-paused conversation.
    private func sendAcrossProviders(
        messages: [AgentMessage],
        tools: [AgentToolDefinition],
        cachePolicy: AgentCachePolicy,
        recordDecision: Bool,
        preferredAccountID: String? = nil,
        preferredModelID: String? = nil,
        availableModels: [RouterModel]? = nil,
        effort: String? = nil,
        allowAccountFailoverAfterLimit: Bool = false,
        continueAfterProviderError: Bool = false,
        disableNativeCompactionForRequest: Bool = false,
        onDelta: NativeAgentClient.StreamDeltaHandler? = nil
    ) async throws -> AgentResponse {
        let selectedEffort = effort ?? self.selectedEffort
        let candidates = availableModels ?? routableModels
        var excluded: Set<String> = []
        var excludedModels: Set<String> = []
        var failedModelsByProvider: [String: Int] = [:]
        var dropped: [String] = []
        var providerFailures: [(provider: String, model: String, error: NativeAgentError)] = []
        while true {
            let available = candidates.filter {
                !excluded.contains($0.provider) && !excludedModels.contains($0.id)
            }
            let routedDecision = ModelRouter.decide(
                messages: messages,
                available: available,
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
               let sticky = available.first(where: { $0.id == preferredModelID }),
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
            guard let decision else {
                guard !providerFailures.isEmpty else {
                    throw NativeAgentError(AppCopy.text("agent.configureEndpoint"))
                }
                let detail = providerFailures.map {
                    "\($0.provider) (\($0.model)): \($0.error.message)"
                }.joined(separator: "\n")
                let onlyLimits = providerFailures.allSatisfy { $0.error.isLimit }
                let retryAt = providerFailures.compactMap { $0.error.retryAt }.min()
                let statusCode = providerFailures.compactMap { $0.error.statusCode }.first
                throw NativeAgentError(detail, statusCode: statusCode, retryable: false, isLimit: onlyLimits, retryAt: retryAt)
            }
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
                    allowAccountFailoverAfterLimit: allowAccountFailoverAfterLimit,
                    continueAfterProviderError: continueAfterProviderError,
                    excludeKnownExhaustedAccounts: continueAfterProviderError,
                    effortOverride: decision.effort,
                    recordRouteState: recordDecision,
                    disableNativeCompactionForRequest: disableNativeCompactionForRequest,
                    onDelta: onDelta
                )
                if recordDecision {
                    let name = candidates.first { $0.id == decision.model }?.displayName ?? decision.model
                    lastFailover = dropped.isEmpty
                        ? nil
                        : AppCopy.format("router.failedOver", dropped.joined(separator: ", "), name)
                }
                return response
            } catch let failure as NativeAgentError where failure.isLimit {
                guard allowAccountFailoverAfterLimit || autoAccountFailoverAfterLimit else { throw failure }
                guard let provider = available.first(where: { $0.id == decision.model })?.provider,
                      !excluded.contains(provider) else { throw failure }
                excluded.insert(provider)
                dropped.append(RouterCatalog.label(for: provider))
                providerFailures.append((RouterCatalog.label(for: provider), decision.model, failure))
            } catch let failure as NativeAgentError where continueAfterProviderError {
                guard let provider = available.first(where: { $0.id == decision.model })?.provider else { throw failure }
                providerFailures.append((RouterCatalog.label(for: provider), decision.model, failure))
                if failure.statusCode == 400 || failure.statusCode == 404 {
                    excludedModels.insert(decision.model)
                    failedModelsByProvider[provider, default: 0] += 1
                    if failedModelsByProvider[provider, default: 0] >= 2 {
                        excluded.insert(provider)
                        dropped.append(RouterCatalog.label(for: provider))
                    }
                } else {
                    excluded.insert(provider)
                    dropped.append(RouterCatalog.label(for: provider))
                }
            }
        }
    }

    /// One-shot side task (translation): the lightest connected model at its lowest
    /// effort. Leaves routing state alone. The picked model's provider is tried first
    /// (in auto, the one with the most quota left), so project text reaches another
    /// provider only when that one has no model left.
    /// `effort` asks for more where the model offers it (the memory scan reads at medium).
    public func completeCheapest(messages: [AgentMessage], effort: String? = nil) async throws -> AgentResponse {
        let models = routableModels
        let provider: String?
        if isAutoSelected {
            // Auto: the provider with the most quota left; unknown quota counts as full.
            let now = Date()
            func room(_ model: RouterModel) -> Double {
                store.state.accounts
                    .filter { $0.active && canServe($0, model: model.id) && ($0.cooldownUntil ?? now) <= now }
                    .map { accountUsage[$0.id]?.remainingFraction ?? 1 }
                    .max() ?? 0
            }
            provider = models.max { room($0) < room($1) }?.provider
        } else {
            provider = models.first { $0.id == selectedModelID }?.provider
        }
        let sameProvider = models.filter { $0.provider == provider }
        let cheapest = (sameProvider.isEmpty ? models : sameProvider)
            .min { ModelRouter.tier(of: $0) < ModelRouter.tier(of: $1) }
        guard let cheapest else {
            return try await send(
                messages: messages, tools: [], cachePolicy: AgentCachePolicy(), model: nil,
                effortOverride: effort ?? "low", recordRouteState: false
            )
        }
        let lowest = effort.flatMap { cheapest.efforts.contains($0) ? $0 : nil } ?? cheapest.efforts.first ?? ""
        return try await send(
            messages: messages, tools: [], cachePolicy: AgentCachePolicy(), model: cheapest.id,
            effortOverride: lowest, recordRouteState: false
        )
    }

    /// Models the exploration subagent can run on: it works through tools.
    public var explorationModels: [RouterModel] { routableModels.filter(\.tools) }

    /// What a sweep of the project runs on: the model the user picked, else the
    /// lightest one a subscription already pays for, else the lightest one behind
    /// an API key. Reading files and reporting where things are does not need the
    /// model the conversation runs on. A subscription close to its limit is passed
    /// over while another still has room.
    public var explorationModel: RouterModel? {
        let now = Date()
        return Self.explorationChoice(
            among: eligibleExplorationModels(at: now),
            picked: explorationModelID,
            remaining: { model in
                let accounts = store.state.accounts.filter {
                    $0.active && canServe($0, model: model.id) && ($0.cooldownUntil ?? now) <= now
                }
                let known = accounts.compactMap { accountUsage[$0.id]?.remainingFraction }
                if let positive = known.filter({ $0 > 0 }).max() { return positive }
                if accounts.contains(where: { accountUsage[$0.id]?.remainingFraction == nil }) { return nil }
                return known.max()
            }
        )
    }

    private func eligibleExplorationModels(at now: Date) -> [RouterModel] {
        explorationModels.filter { model in
            store.state.accounts.contains { account in
                guard account.active, canServe(account, model: model.id), (account.cooldownUntil ?? now) <= now else { return false }
                return (accountUsage[account.id]?.remainingFraction ?? 1) > 0
            }
        }
    }

    /// Below this share of quota left, a subscription is kept for the conversation itself.
    static let explorationReserve = 0.2

    /// `remaining` is the best quota share left among the accounts serving a model, nil when unknown.
    static func explorationChoice(
        among usable: [RouterModel],
        picked: String,
        remaining: (RouterModel) -> Double? = { _ in nil },
        eligible: (RouterModel) -> Bool = { _ in true }
    ) -> RouterModel? {
        let candidates = usable.filter { eligible($0) && (remaining($0) ?? 1) > 0 }
        if let chosen = candidates.first(where: { $0.id == picked }) { return chosen }
        func lightest(_ models: [RouterModel]) -> RouterModel? {
            models.min { ModelRouter.tier(of: $0) < ModelRouter.tier(of: $1) }
        }
        let subscribed = candidates.filter {
            [.oauth, .oauthDevice].contains(RouterCatalog.spec(for: $0.provider)?.category)
        }
        // Unknown quota counts as roomy, as it does when routing the conversation.
        let roomy = subscribed.filter { (remaining($0) ?? 1) >= explorationReserve }
        let most = subscribed.map { remaining($0) ?? 1 }.max()
        return lightest(roomy)
            ?? lightest(subscribed.filter { (remaining($0) ?? 1) == most })
            ?? lightest(candidates)
    }

    /// One step of the exploration subagent, at low effort. When that model's
    /// quota is spent, or the provider refuses the model outright, the sweep goes
    /// on wherever routing would send it, since a stopped side run costs the main
    /// one its answer.
    public func completeExploration(
        messages: [AgentMessage],
        tools: [AgentToolDefinition] = [],
        cacheKey: String? = nil
    ) async throws -> AgentResponse {
        await refreshAccountUsage()
        let now = Date()
        let candidates = eligibleExplorationModels(at: now)
        let model = explorationModel
        if explorationRouteFallback?.preference != explorationModelID
            || (explorationRouteFallback?.until ?? .distantPast) <= now {
            explorationRouteFallback = nil
        }
        let preferredModelID = explorationRouteFallback.flatMap { fallback in
            candidates.contains(where: { $0.id == fallback.model }) ? fallback.model : nil
        } ?? model?.id
        let route = SubagentRoute.current
        let response = try await sendAcrossProviders(
            messages: messages,
            tools: tools,
            cachePolicy: AgentCachePolicy(promptCacheKey: cacheKey, comparisonScope: route?.comparisonScope(cacheKey)),
            recordDecision: false,
            preferredAccountID: route?.accountID,
            preferredModelID: preferredModelID,
            availableModels: candidates,
            effort: model?.efforts.contains("low") == true ? "low" : model?.efforts.first,
            allowAccountFailoverAfterLimit: true,
            continueAfterProviderError: true
        )
        route?.pin(response.servedAccountID)
        if let servedModel = response.servedModelID,
           let requestedModel = preferredModelID,
           servedModel != requestedModel {
            explorationRouteFallback = (
                preference: explorationModelID,
                model: servedModel,
                until: now.addingTimeInterval(15 * 60)
            )
        } else if response.servedModelID == preferredModelID {
            explorationRouteFallback = nil
        }
        return response
    }

    /// Like `complete`, but never records the routing decision as the conversation's
    /// own. Side runs - the exploration subagent - use it so their model choice does
    /// not overwrite what the picker shows for the main run.
    public func completeWithFailover(
        messages: [AgentMessage],
        tools: [AgentToolDefinition] = [],
        cacheKey: String? = nil,
        preferredModelID: String? = nil,
        effort: String? = nil
    ) async throws -> AgentResponse {
        let route = SubagentRoute.current
        let response = try await sendAcrossProviders(
            messages: messages,
            tools: tools,
            cachePolicy: AgentCachePolicy(promptCacheKey: cacheKey, comparisonScope: route?.comparisonScope(cacheKey)),
            recordDecision: false,
            preferredAccountID: route?.accountID,
            preferredModelID: preferredModelID,
            effort: effort,
            allowAccountFailoverAfterLimit: true
        )
        route?.pin(response.servedAccountID)
        return response
    }

    /// Active accounts that can serve `model`, ordered best-first:
    /// 1. a live `preferred` account (conversation affinity) that is not cooling
    ///    down comes first, so follow-up turns keep the provider's prompt cache;
    /// 2. otherwise accounts not in cooldown, with the most five-hour quota left
    ///    first and weekly quota breaking ties; unknown usage sorts below known-
    ///    healthy but above known-exhausted, then `priority` breaks ties; equal-
    ///    quota accounts within a provider rotate across unpinned conversations;
    /// 3. cooling-down accounts last, as a final fallback.
    /// Pure and side-effect free so it can be unit tested without the network.
    func orderedRoutes(
        _ accounts: [StoredProviderAccount],
        model: String,
        preferred: String?,
        usage: [String: AccountUsageSnapshot],
        now: Date,
        roundRobinAfterByProvider: [String: String] = [:]
    ) -> [StoredProviderAccount] {
        let serving = accounts
            .filter { $0.active && canServe($0, model: model) }

        func coolingDown(_ account: StoredProviderAccount) -> Bool {
            guard let until = account.cooldownUntil else { return false }
            return until > now
        }
        // Unknown usage ranks between a positive remaining quota and exhaustion.
        func remainingRank(_ fraction: Double?) -> Double {
            guard let fraction else { return 0 }
            let clamped = min(max(fraction, 0), 1)
            return clamped <= 0 ? -1 : clamped
        }
        func fiveHourRank(_ account: StoredProviderAccount) -> Double {
            guard let snapshot = usage[account.id] else { return 0 }
            // Code Assist meters each model apart; that model's own share decides.
            if let share = snapshot.models[model] { return remainingRank(share) }
            if let used = snapshot.windows.first(where: { $0.kind == .fiveHour })?.usedPercent {
                return remainingRank(1 - min(max(used, 0), 1))
            }
            // Preserve routing for providers that report only an aggregate quota.
            return remainingRank(snapshot.remainingFraction)
        }
        func weeklyRank(_ account: StoredProviderAccount) -> Double {
            guard let used = usage[account.id]?.windows.first(where: { $0.kind == .week })?.usedPercent else {
                return 0
            }
            return remainingRank(1 - min(max(used, 0), 1))
        }

        var ranked = serving.sorted { lhs, rhs in
            let lc = coolingDown(lhs), rc = coolingDown(rhs)
            if lc != rc { return !lc }
            let l5h = fiveHourRank(lhs), r5h = fiveHourRank(rhs)
            if l5h != r5h { return l5h > r5h }
            let lWeek = weeklyRank(lhs), rWeek = weeklyRank(rhs)
            if lWeek != rWeek { return lWeek > rWeek }
            if lhs.priority != rhs.priority { return lhs.priority < rhs.priority }
            return lhs.id < rhs.id
        }

        // Rotate only accounts tied on both quota windows; rotation must not
        // undo the weekly tie-breaker.
        for (provider, previousID) in roundRobinAfterByProvider {
            guard let previous = ranked.first(where: { $0.id == previousID }),
                  previous.provider == provider,
                  !coolingDown(previous) else { continue }
            let peerIndices = ranked.indices.filter {
                let account = ranked[$0]
                return account.provider == provider
                    && !coolingDown(account)
                    && fiveHourRank(account) == fiveHourRank(previous)
                    && weeklyRank(account) == weeklyRank(previous)
            }
            guard let previousPeerIndex = peerIndices.firstIndex(where: { ranked[$0].id == previousID }),
                  peerIndices.count > 1 else { continue }
            let peerAccounts = peerIndices.map { ranked[$0] }
            let rotated = Array(peerAccounts.dropFirst(previousPeerIndex + 1))
                + Array(peerAccounts.prefix(previousPeerIndex + 1))
            for (index, account) in zip(peerIndices, rotated) {
                ranked[index] = account
            }
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
        allowAccountFailoverAfterLimit: Bool = false,
        continueAfterProviderError: Bool = false,
        excludeKnownExhaustedAccounts: Bool = false,
        effortOverride: String? = nil,
        recordRouteState: Bool = true,
        disableNativeCompactionForRequest: Bool = false,
        onDelta: NativeAgentClient.StreamDeltaHandler? = nil
    ) async throws -> AgentResponse {
        var routes = orderedRoutes(
            store.state.accounts,
            model: requestedModel ?? "",
            preferred: preferredAccountID,
            usage: accountUsage,
            now: Date(),
            roundRobinAfterByProvider: lastRoundRobinAccountIDByProvider
        )
        if excludeKnownExhaustedAccounts {
            routes.removeAll { account in
                guard let remaining = accountUsage[account.id]?.remainingFraction else { return false }
                return remaining <= 0
            }
        }
        guard !routes.isEmpty else { throw NativeAgentError(AppCopy.text("agent.configureEndpoint")) }
        var failures: [NativeAgentError] = []
        var limitFailures: [NativeAgentError] = []
        routeLoop: for account in routes {
            if preferredAccountID == nil, recordRouteState {
                // Reserve the route before awaiting the provider so concurrent new
                // conversations receive different equal-quota accounts.
                lastRoundRobinAccountIDByProvider[account.provider] = account.id
            }
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
                    recordHeaderUsage(response.rateLimitRemaining, resetsAt: response.rateLimitResetsAt, for: account)
                    response.servedCacheKey = routeKey
                    if recordRouteState {
                        status = AppCopy.format("router.connected", configuration.provider)
                        lastServedAccountID = account.id
                        lastServedModelID = configuration.model
                    }
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
                        limitFailures.append(failure)
                        guard allowAccountFailoverAfterLimit || autoAccountFailoverAfterLimit else { break routeLoop }
                        break
                    }
                    if failure.statusCode == 401, !refreshed {
                        refreshed = true
                        if await refreshCredential(for: account) { continue }
                    }
                    failures.append(failure)
                    if !failure.retryable {
                        if !continueAfterProviderError { throw failure }
                        if failure.statusCode == 401 || failure.statusCode == 403 {
                            break
                        }
                        break routeLoop
                    }
                    break
                } catch {
                    failures.append(NativeAgentError(error.localizedDescription, retryable: true))
                    break
                }
            }
        }
        if !limitFailures.isEmpty {
            let limitMessages = limitFailures.map(\.message)
            let retryAt = limitFailures.compactMap(\.retryAt).min()
            let onlyLimits = failures.isEmpty
            throw NativeAgentError(
                (limitMessages + failures.map(\.message)).joined(separator: "\n"),
                statusCode: onlyLimits ? 429 : failures.compactMap(\.statusCode).first,
                retryable: false,
                isLimit: onlyLimits,
                retryAt: retryAt
            )
        }
        let message = failures.map(\.message).joined(separator: "\n")
        throw NativeAgentError(
            message.isEmpty ? AppCopy.text("agent.configureEndpoint") : message,
            statusCode: failures.compactMap(\.statusCode).first,
            retryable: !failures.isEmpty && failures.allSatisfy(\.retryable),
            isNetworkFailure: !failures.isEmpty && failures.allSatisfy(\.isNetworkFailure)
        )
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
            api: account.routeAPI,
            accountID: account.id,
            sessionAccountID: account.sessionAccountID,
            specID: account.provider,
            authType: account.authType,
            effort: effortOverride ?? effort(for: model?.isEmpty == false ? model! : effectiveModel(for: account)),
            // The route's own provider names the window: a catalog that does not list
            // the model must not fall back to the generic default and shrink the budget.
            contextWindow: contextWindow(for: model?.isEmpty == false ? model : effectiveModel(for: account), provider: account.provider),
            supportsNativeCompaction: RouterCatalog.spec(for: account.provider)?.transport.quirks.supportsNativeCompaction ?? false,
            compactionPolicy: .baseline,
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
            now: Date(),
            roundRobinAfterByProvider: lastRoundRobinAccountIDByProvider
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

// Copyright (c) 2026 DOTS
// Model context persistence, usage and compaction.

import Foundation
import HarnessPluginKit
import Observation
import PluginRuntime

extension NativeAgentHost {
    func saveModelContext(_ messages: [AgentMessage], in conversationID: String) {
        let durable = Self.durableContext(messages)
        activeContext = durable
        if let index = conversations.firstIndex(where: { $0.id == conversationID }) {
            conversations[index].modelContext = durable.filter { $0.responseContinuationID == nil }
        }
        persistSoon()
    }

    public func contextUsageEvents() -> [AgentContextUsageEvent] {
        _ = listTick
        return contextTelemetry.events()
    }

    @discardableResult
    func recordContextUsage(
        _ response: AgentResponse?,
        conversationID: String,
        configuration: AgentConfiguration,
        cacheKey: String?,
        requestKind: AgentContextRequestKind,
        strategy: AgentCompactionStrategy,
        contextTokensBefore: Int,
        contextTokensAfter: Int,
        startedAt: Date,
        modelOverride: String? = nil,
        inputComposition: AgentContextInputComposition? = nil,
        effectiveOutputBudget: AgentOutputBudget? = nil,
        requestedEffort: String? = nil,
        responseStyle: AgentResponseStyle? = nil,
        retryCount: Int? = nil,
        retryUsage: AgentUsage? = nil,
        errorKind: String? = nil,
        tools: [AgentToolDefinition]? = nil,
        requestContextSegment: Int? = nil,
        prepareMilliseconds: Int? = nil,
        cpu: AgentStepCPUTrace? = nil,
        compaction: AgentCompactionTrace? = nil
    ) -> UUID? {
        guard response?.usage != nil || errorKind != nil || inputComposition != nil || requestKind == .compactionSummary else { return nil }
        let servedConfiguration = response?.servedAccountID.flatMap { id in
            router?.store.state.accounts.first(where: { $0.id == id })
        }.flatMap { account in
            try? router?.configuration(for: account, model: response?.servedModelID, loadCredentials: false)
        } ?? configuration
        var reuseEvidence = response?.cacheReuseEvidence
        let epochReason = conversations.first(where: { $0.id == conversationID })?.cacheEpoch?.lastChangeReason
        if requestKind == .main, reuseEvidence?.classification == "cold", let epochReason {
            reuseEvidence?.classification = "changed"
            reuseEvidence?.reason = epochReason
        }
        let event = AgentContextUsageEvent(
            conversationID: conversationID,
            turnID: activeTurnID,
            provider: servedConfiguration.provider,
            api: servedConfiguration.api,
            model: response?.servedModelID ?? modelOverride ?? router?.lastServedModelID ?? configuration.model,
            cacheKey: cacheKey,
            requestKind: requestKind,
            strategy: strategy,
            policyID: configuration.compactionPolicy.id,
            selectedEffort: servedConfiguration.effort,
            requestedEffort: requestedEffort,
            usageMode: configuration.usageMode,
            responseStyle: responseStyle,
            retryCount: retryCount,
            retryUsage: retryUsage,
            effectiveOutputBudget: effectiveOutputBudget,
            usage: response?.usage,
            contextWindowTokens: compaction?.contextWindow ?? router?.contextWindow(
                for: response?.servedModelID ?? modelOverride ?? configuration.model,
                provider: servedConfiguration.specID.isEmpty ? nil : servedConfiguration.specID
            ) ?? configuration.contextWindow,
            inputComposition: inputComposition,
            contextTokensBefore: contextTokensBefore,
            contextTokensAfter: contextTokensAfter,
            latencyMilliseconds: Int(max(0, Date().timeIntervalSince(startedAt) * 1_000)),
            firstTokenMilliseconds: response?.firstTokenMilliseconds,
            prepareMilliseconds: prepareMilliseconds,
            cpu: cpu,
            nativeCompactionFallback: response?.nativeCompactionFallback ?? false,
            errorKind: errorKind,
            cacheTrace: tools.map { definitions in
                AgentCacheTrace(
                    toolFingerprint: AgentCacheNamespace.toolFingerprint(definitions),
                    policyRevision: AgentCacheNamespace.promptContextRevision(
                        [corePolicySection(workspace: workspaceURL)]),
                    contextSegment: requestContextSegment ?? conversations.first(where: { $0.id == conversationID })?.contextCompactionCount ?? 0,
                    ttlSeconds: response?.effectiveCacheTTLSeconds,
                    requestStartedAt: startedAt,
                    fast: servedConfiguration.fast,
                    accountFingerprint: servedConfiguration.accountID.map(AgentCacheTrace.fingerprint),
                    endpointFingerprint: AgentCacheTrace.fingerprint(servedConfiguration.baseURL.lowercased()),
                    local: AgentCacheTrace.isLoopback(servedConfiguration.baseURL))
            },
            providerCacheDiagnostics: response?.cacheDiagnostics,
            cacheReuseEvidence: reuseEvidence,
            compactionTrace: compaction
        )
        contextTelemetry.append(event)
        // A subagent's boundary belongs to its own transcript, never the parent's.
        if !requestKind.isSubagent, var boundary = response?.proposedCacheBoundary,
           let index = conversations.firstIndex(where: { $0.id == conversationID }) {
            boundary.baselineEventID = event.id.uuidString
            // A successful request without a proven terminal counter is still
            // a continuation baseline for coverage; it never becomes a marker
            // or a token denominator. Preserve an older proven checkpoint.
            if boundary.accepted || conversations[index].cacheEpoch?.priorBoundary?.accepted != true {
                conversations[index].cacheEpoch?.priorBoundary = boundary
            }
            if requestKind == .main { conversations[index].cacheEpoch?.lastChangeReason = nil }
        }
        if conversationID == activeConversationID {
            let usage = response?.usage
            let estimatedInputTokens = inputComposition?.estimatedTotalTokens ?? 0
            let measuredInputTokens = usage.map {
                $0.breakdown(forAPI: servedConfiguration.api).freshInputTokens
            } ?? estimatedInputTokens
            let estimatedOutputTokens = response.map { AgentContextCompaction.estimateTokens($0.message) } ?? 0
            let measuredOutputTokens = event.outputTokens > 0
                ? event.outputTokens
                : estimatedOutputTokens
            let retryTokens = retryUsage.map {
                let breakdown = $0.breakdown(forAPI: servedConfiguration.api)
                return breakdown.freshInputTokens + max(0, $0.outputTokens)
            } ?? 0
            activeRunTokens += measuredInputTokens + measuredOutputTokens + retryTokens
            let hasCacheAccounting = [usage?.cachedTokens, usage?.cacheWriteTokens, usage?.cacheMissTokens]
                .contains { $0 != nil }
            let retryHasCacheAccounting = [retryUsage?.cachedTokens, retryUsage?.cacheWriteTokens, retryUsage?.cacheMissTokens]
                .contains { $0 != nil }
            if (usage == nil && estimatedInputTokens > 0)
                || (usage?.inputTokens ?? 0) > 0 && !hasCacheAccounting
                || event.outputTokens == 0 && estimatedOutputTokens > 0
                || retryUsage != nil && (retryUsage?.inputTokens ?? 0) > 0 && !retryHasCacheAccounting {
                activeRunTokenCountHasEstimate = true
            }
        }
        touchLists()
        return event.id
    }

    /// One subagent step, recorded apart from the conversation's own requests so
    /// its cost and cache reuse are measurable.
    func recordSubagentUsage(
        _ response: AgentResponse,
        kind: AgentContextRequestKind,
        conversationID: String,
        configuration: AgentConfiguration,
        cacheKey: String?,
        messages: [AgentMessage],
        startedAt: Date
    ) {
        let tokens = AgentContextCompaction.estimateTokens(messages)
        recordContextUsage(
            response, conversationID: conversationID, configuration: configuration, cacheKey: cacheKey,
            requestKind: kind, strategy: .none, contextTokensBefore: tokens, contextTokensAfter: tokens,
            startedAt: startedAt
        )
    }

    func compactIfNeeded(
        messages: [AgentMessage],
        conversationID: String,
        configuration: AgentConfiguration,
        tools: [AgentToolDefinition],
        modelOverride: String?,
        client: NativeAgentClient,
        nativeCompactionDisabled: Bool,
        force: Bool = false,
        forceDeterministic: Bool = false,
        contextConfiguration: AgentConfiguration? = nil,
        routeIdentityOverride: String? = nil,
        router: RouterController? = nil
    ) async throws -> ContextCompactionOutcome {
        let admission = contextAdmission(
            messages: messages,
            configuration: configuration,
            tools: tools,
            contextConfiguration: contextConfiguration
        )
        let budgetConfiguration = admission.configuration
        let budget = admission.budget
        let estimated = admission.promptTokens
        let previousConversation = conversations.first(where: { $0.id == conversationID })
        let routeIdentity = routeIdentityOverride ?? contextRouteIdentity(
            configuration: budgetConfiguration,
            modelOverride: modelOverride,
            router: router,
            conversationID: conversationID
        )
        let routeChanged = previousConversation?.contextRouteIdentity != routeIdentity
        let normalized = EconomyToolOutputPolicy.normalizeMessages(messages)
        let previousInput = routeChanged ? 0 : (previousConversation?.lastContextInputTokens ?? 0)
        let normalizedEstimate = admission.normalizedTokens
        // Provider-reported input already includes the system prompt and tool
        // schemas; both sides of the delta include the same tool estimate.
        let observedInput = AgentContextCompaction.observedInputTokens(
            estimate: normalizedEstimate + budget.toolDefinitionTokens,
            lastInput: previousInput,
            lastEstimate: previousConversation?.lastContextEstimatedTokens ?? 0
        )
        let admissionFits = admission.fits
        let nativeCanCompact = budgetConfiguration.supportsNativeCompaction
            && !nativeCompactionDisabled
            && !EndpointCapabilityMemory.nativeCompaction.isUnsupported(for: budgetConfiguration)
            && budgetConfiguration.api == RouterAPIKind.chatGPT.rawValue
        let shouldPrune = force
            || !admissionFits
            || (!routeChanged && observedInput >= budget.triggerTokens)
        let compactDeterministically = forceDeterministic
            || admission.deterministic
            || (nativeCanCompact && !routeChanged)
        let trace = AgentCompactionTrace(
            contextWindow: budget.contextWindow,
            reservedOutputTokens: budget.reservedOutputTokens,
            toolDefinitionTokens: budget.toolDefinitionTokens,
            usableInputTokens: budget.usableInputTokens,
            triggerTokens: budget.triggerTokens,
            targetTokens: budget.targetTokens,
            policyID: budget.policy.id,
            promptTokens: estimated,
            normalizedTokens: normalizedEstimate,
            previousInputTokens: previousInput,
            routeChanged: routeChanged,
            admissionFits: admissionFits,
            nativeCanCompact: nativeCanCompact,
            compactDeterministically: compactDeterministically,
            shouldPrune: shouldPrune,
            forced: force,
            toolCount: tools.count
        )
        let unchanged = ContextCompactionOutcome(
            messages: messages,
            strategy: .none,
            contextTokensBefore: estimated,
            contextTokensAfter: estimated,
            trace: trace
        )
        if nativeCanCompact, !force, admissionFits {
            // The selected Responses route owns threshold compaction. Do not
            // rewrite its cached prefix locally while the request still fits.
            return unchanged
        }
        if compactDeterministically {
            guard shouldPrune else { return unchanged }
            let economyMessages = AgentContextCompaction.economyPrune(normalized, targetTokens: budget.targetTokens)
            let after = AgentContextCompaction.estimateTokens(economyMessages)
            let changed = economyMessages != messages
            if changed, let index = conversations.firstIndex(where: { $0.id == conversationID }) {
                conversations[index].contextCompactionCount += 1
                // Compaction drops read_file bodies; reads must not vouch for them.
                ReadLedger.shared.forgetConversation(conversationID)
                conversations[index].lastContextInputTokens = after
                conversations[index].lastContextEstimatedTokens = 0
                conversations[index].contextWindow = budget.contextWindow
            }
            if changed { saveModelContext(economyMessages, in: conversationID) }
            return ContextCompactionOutcome(
                messages: economyMessages,
                strategy: changed ? .deterministic : .none,
                contextTokensBefore: estimated,
                contextTokensAfter: after,
                trace: trace
            )
        }
        guard force
            || !admissionFits
            || (!routeChanged && observedInput >= budget.triggerTokens) else {
            return unchanged
        }
        if nativeCanCompact {
            // Let the documented Responses route own the compaction item. The
            // opaque item is returned in the provider transcript and must not be
            // replaced with a local summary before the provider sees it.
            return unchanged
        }
        let previousSummary = conversations.first(where: { $0.id == conversationID })?.contextSummary
        let durableMessages = Self.durableContext(messages)
        // Moving to another model throws away the cache the forked summary earns
        // on, so the summary turns into a cost decision: the smallest model that
        // can still read the archive writes it. No such model means the archive
        // would overflow both ends, and the deterministic prune below handles it.
        let summarizer = routeChanged && !admissionFits
            ? previousConversation.flatMap {
                routeSummarizer(
                    conversation: $0,
                    targetConfiguration: budgetConfiguration,
                    routeIdentity: routeIdentity
                )
            }
            : nil
        guard let selection = AgentContextCompaction.select(
            durableMessages,
            previousSummary: previousSummary,
            budget: budget,
            archiveCharacters: contextArchiveCharacters(summarizer: summarizer, destination: budget)
        ) else {
            var trimmed = durableMessages
            if AgentContextCompaction.trimToolResults(&trimmed, targetTokens: budget.targetTokens) {
                if let index = conversations.firstIndex(where: { $0.id == conversationID }) {
                    conversations[index].contextCompactionCount += 1
                    // Compaction drops read_file bodies; reads must not vouch for them.
                    ReadLedger.shared.forgetConversation(conversationID)
                    conversations[index].lastContextInputTokens = AgentContextCompaction.estimateTokens(trimmed)
                    conversations[index].lastContextEstimatedTokens = 0
                    conversations[index].contextWindow = budget.contextWindow
                }
                saveModelContext(trimmed, in: conversationID)
                return ContextCompactionOutcome(
                    messages: trimmed,
                    strategy: .fallback,
                    contextTokensBefore: estimated,
                    contextTokensAfter: AgentContextCompaction.estimateTokens(trimmed),
                    trace: trace
                )
            }
            return unchanged
        }

        status = "Context automatically compacting…"
        let summary: String
        let summaryStartedAt = Date()
        // A fork replays the whole transcript. Only use it while this route has
        // room for that transcript; if a changed route overflows and no connected
        // summarizer can read the archive, go straight to the local fallback.
        let forked: (
            response: AgentResponse,
            cacheKey: String?,
            inputComposition: AgentContextInputComposition
        )? = summarizer == nil
            && !(routeChanged && !admissionFits)
            ? try await forkedSummary(
                messages: messages,
                tools: tools,
                configuration: configuration,
                modelOverride: modelOverride,
                conversationID: conversationID,
                client: client
            )
            : nil
        if let forked {
            let normalized = AgentContextCompaction.normalizeSummary(forked.response.message.content)
            let summaryIsValid = AgentContextCompaction.isValidSummary(normalized)
            recordContextUsage(
                forked.response,
                conversationID: conversationID,
                configuration: configuration,
                cacheKey: forked.cacheKey,
                requestKind: .compactionSummary,
                strategy: summaryIsValid ? .aiSummary : .fallback,
                contextTokensBefore: estimated,
                contextTokensAfter: AgentContextCompaction.estimateTokens(durableMessages),
                startedAt: summaryStartedAt,
                modelOverride: modelOverride,
                inputComposition: forked.inputComposition,
                errorKind: summaryIsValid ? nil : "summary_invalid"
            )
            summary = normalized
        } else if routeChanged && !admissionFits && summarizer == nil {
            // The destination cannot hold the transcript and no connected model
            // can hold the archive request. Use the deterministic local summary
            // below instead of retrying either shape against the same routes.
            summary = ""
        } else {
            let summaryMessages = [
                AgentMessage(role: .system, content: AgentContextCompaction.summarySystemPrompt),
                AgentMessage(role: .user, content: selection.archiveText),
            ]
            // Without a route change this is the chat's own model: the cache
            // belongs to it and it reads the result back. After one it is the
            // smallest model that can still hold the archive.
            let summaryModel = summarizer?.model ?? modelOverride
            do {
                let response: AgentResponse
                if let router {
                    response = try await router.complete(
                        messages: summaryMessages,
                        tools: [],
                        cachePolicy: AgentCachePolicy(),
                        model: summaryModel,
                        preferredAccountID: summarizer?.accountID
                    )
                } else {
                    response = try await client.complete(messages: summaryMessages)
                }
                let normalized = AgentContextCompaction.normalizeSummary(response.message.content)
                let summaryIsValid = AgentContextCompaction.isValidSummary(normalized)
                recordContextUsage(
                    response,
                    conversationID: conversationID,
                    configuration: configuration,
                    cacheKey: nil,
                    requestKind: .compactionSummary,
                    strategy: summaryIsValid ? .aiSummary : .fallback,
                    contextTokensBefore: estimated,
                    contextTokensAfter: AgentContextCompaction.estimateTokens(durableMessages),
                    startedAt: summaryStartedAt,
                    modelOverride: summaryModel,
                    inputComposition: AgentContextInputComposition(messages: summaryMessages, tools: []),
                    errorKind: summaryIsValid ? nil : "summary_invalid"
                )
                summary = normalized
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                recordContextUsage(
                    nil,
                    conversationID: conversationID,
                    configuration: configuration,
                    cacheKey: nil,
                    requestKind: .compactionSummary,
                    strategy: .fallback,
                    contextTokensBefore: estimated,
                    contextTokensAfter: AgentContextCompaction.estimateTokens(durableMessages),
                    startedAt: summaryStartedAt,
                    modelOverride: summaryModel,
                    inputComposition: AgentContextInputComposition(messages: summaryMessages, tools: []),
                    errorKind: "summary_failed"
                )
                summary = ""
            }
        }

        let validSummary = selection.attachFileLists(to: AgentContextCompaction.isValidSummary(summary)
            ? summary
            : AgentContextCompaction.fallbackSummary(previousSummary: previousSummary, archiveText: selection.archiveText))
        let strategy: AgentCompactionStrategy = AgentContextCompaction.isValidSummary(summary) ? .aiSummary : .fallback
        let preserveProviderItems = (router?.preserveProviderItems(for: contextConfiguration?.model ?? modelOverride ?? configuration.model))
            ?? (budgetConfiguration.api == RouterAPIKind.chatGPT.rawValue)
        let compacted = selection.compose(summary: validSummary, preserveProviderItems: preserveProviderItems)
        if let index = conversations.firstIndex(where: { $0.id == conversationID }) {
            conversations[index].contextSummary = validSummary
            conversations[index].contextCompactionCount += 1
            // Compaction drops read_file bodies; reads must not vouch for them.
            ReadLedger.shared.forgetConversation(conversationID)
            conversations[index].lastContextInputTokens = AgentContextCompaction.estimateTokens(compacted)
            conversations[index].lastContextEstimatedTokens = 0
            conversations[index].contextWindow = budget.contextWindow
        }
        saveModelContext(compacted, in: conversationID)
        status = "Context compacted."
        return ContextCompactionOutcome(
            messages: compacted,
            strategy: strategy,
            contextTokensBefore: estimated,
            contextTokensAfter: AgentContextCompaction.estimateTokens(compacted),
            trace: trace
        )
    }

    func contextRouteIdentity(
        configuration: AgentConfiguration,
        modelOverride: String?,
        router: RouterController?,
        conversationID: String? = nil
    ) -> String {
        let requestedModel = modelOverride?.isEmpty == false ? modelOverride! : configuration.model
        if let router,
           let conversation = conversationID.flatMap({ id in conversations.first(where: { $0.id == id }) }),
           let stickyAccountID = conversation.stickyAccountID {
            let targetModel = requestedModel == ModelRouter.autoModelID
                ? (conversation.stickyModelID ?? requestedModel)
                : requestedModel
            guard router.affinityAccountID(
                sticky: stickyAccountID,
                stickyModelID: conversation.stickyModelID,
                targetModel: targetModel
            ) != nil else {
                // A cooldown or model change means the next request may use a
                // different account; force route-aware compaction before it.
                return "unresolved|\(stickyAccountID)|\(targetModel)"
            }
            if let account = router.store.state.accounts.first(where: { $0.id == stickyAccountID }) {
                return account.routeIdentity(model: targetModel)
            }
        }
        return configuration.routeIdentity(model: requestedModel)
    }

    func preferredAccountID(_ router: RouterController, conversationID: String, modelOverride: String?) -> String? {
        conversations.first(where: { $0.id == conversationID }).flatMap { conversation -> String? in
            guard let sticky = conversation.stickyAccountID else { return nil }
            return router.affinityAccountID(
                sticky: sticky,
                stickyModelID: conversation.stickyModelID,
                targetModel: modelOverride ?? router.selectedModelID
            )
        }
    }

    func preferredModelID(_ router: RouterController, conversationID: String, modelOverride: String?) -> String? {
        let requested = modelOverride ?? router.selectedModelID
        guard requested == ModelRouter.autoModelID || requested.isEmpty else { return nil }
        guard let conversation = conversations.first(where: { $0.id == conversationID }),
              let model = conversation.stickyModelID,
              preferredAccountID(router, conversationID: conversationID, modelOverride: model) != nil else { return nil }
        return model
    }

    /// Cache-preserving summary: the exact request the chat just sent (same
    /// model, account, tools, cache key) plus one instruction, so nearly all of
    /// the input is a cache hit. Nil when the request failed or the model
    /// answered with a tool call; the caller then summarizes the archive alone.
    private func forkedSummary(
        messages: [AgentMessage],
        tools: [AgentToolDefinition],
        configuration: AgentConfiguration,
        modelOverride: String?,
        conversationID: String,
        client: NativeAgentClient
    ) async throws -> (
        response: AgentResponse,
        cacheKey: String?,
        inputComposition: AgentContextInputComposition
    )? {
        let request = messages + [AgentMessage(role: .user, content: AgentContextCompaction.summaryForkInstruction)]
        let inputComposition = AgentContextInputComposition(messages: request, tools: tools)
        let key = cacheKey(for: configuration, planMode: false, model: modelOverride, tools: tools, router: router)
        let policy = AgentCachePolicy(promptCacheKey: key,
            comparisonScope: AgentCacheTrace.fingerprint("conversation|" + conversationID))
        do {
            let response: AgentResponse
            if let router {
                response = try await router.complete(
                    messages: request,
                    tools: tools,
                    cachePolicy: policy,
                    model: modelOverride,
                    preferredAccountID: preferredAccountID(router, conversationID: conversationID, modelOverride: modelOverride),
                    preferredModelID: preferredModelID(router, conversationID: conversationID, modelOverride: modelOverride)
                )
            } else {
                response = try await client.complete(
                    messages: request,
                    tools: tools,
                    cachePolicy: policy
                )
            }
            return response.message.toolCalls.isEmpty ? (response, key, inputComposition) : nil
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return nil
        }
    }

    /// `/compact`: summarize this chat now instead of waiting for the threshold.
    /// While a run is active it is queued for that run's next model request;
    /// otherwise it happens now.
    func compactCurrentConversation(modelOverride: String? = nil) async {
        guard let id = selectedID,
              conversations.contains(where: { $0.id == id && $0.messages.contains { $0.kind == .user } }) else {
            status = "Nothing to compact."
            return
        }
        if isBusy {
            compactRequested.insert(id)
            status = "Context will be compacted before the next model request."
            return
        }
        guard let configuration = await currentConfiguration() else {
            status = AppCopy.text("agent.configureEndpoint")
            return
        }
        guard !isBusy, let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        let workspace = workspaceURL
        let conversation = conversations[index]
        let prompt = conversationPrompt(conversation)
        let context = conversation.modelContext.isEmpty
            ? NativeAgentClient.foldingDynamicPrompt(into: makeAgentContext(
                for: conversation, workspace: workspace, memoryPrompt: prompt, planMode: false))
            : contextWithSystemPrompt(conversation.modelContext, workspace: workspace, planMode: false, prompt: prompt)
        let tools = agentTools(workspace: workspace).defs.sorted { $0.name < $1.name }
        do {
            let outcome = try await compactIfNeeded(
                messages: context,
                conversationID: id,
                configuration: configuration,
                tools: tools,
                modelOverride: modelOverride,
                client: NativeAgentClient(configuration: configuration),
                nativeCompactionDisabled: false,
                force: true
            )
            if outcome.strategy == .none { status = "Nothing to compact." }
            announceCompaction(outcome, in: id)
        } catch {
            status = error.localizedDescription
        }
    }

    func announceCompaction(
        _ outcome: ContextCompactionOutcome,
        in conversationID: String,
        automatic: Bool = false
    ) {
        guard outcome.strategy != .none else { return }
        append(
            ChatMessage(
                kind: .system,
                text: "\(outcome.contextTokensBefore) → \(outcome.contextTokensAfter) tokens",
                activityCode: automatic ? "context_compacted_auto" : "context_compacted"
            ),
            to: conversationID
        )
    }

    /// `/compact` alone, or `/compact <message>`; returns the message (possibly empty).
    nonisolated static func compactCommand(_ text: String) -> String? {
        guard text == "/compact" || text.hasPrefix("/compact ") || text.hasPrefix("/compact\n") else { return nil }
        return String(text.dropFirst("/compact".count)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func appendStopEventIfNeeded(to conversationID: String) {
        guard activeConversationID == conversationID,
              conversations.contains(where: { $0.id == conversationID }),
              !activeStopEventRecorded else { return }
        activeStopEventRecorded = true
        let message = ChatMessage(kind: .system, text: AppCopy.text("conversation.generationStopped"))
        activeStopEventID = message.id
        append(message, to: conversationID, turnID: activeTurnID)
    }

    func attachTurnMetadata(
        toStopEvent messageID: String?,
        in conversationID: String,
        turn: FinishedTurn
    ) {
        guard let messageID,
              let conversationIndex = conversations.firstIndex(where: { $0.id == conversationID }),
              let messageIndex = conversations[conversationIndex].messages.firstIndex(where: { $0.id == messageID }) else {
            return
        }
        if let turnID = turn.turnID {
            conversations[conversationIndex].messages[messageIndex].turnID = turnID
        }
        conversations[conversationIndex].messages[messageIndex].changedFiles = turn.changedFiles
        if let turnID = turn.turnID, let metadata = completedTurnMetadata[turnID] {
            conversations[conversationIndex].messages[messageIndex].usedSkills = metadata.skills
            conversations[conversationIndex].messages[messageIndex].usedTools = metadata.tools
        }
        if let turnID = turn.turnID, let summary = completedTurnSummaries[turnID] {
            conversations[conversationIndex].messages[messageIndex].summary = summary
        }
        activeStopEventID = nil
        persist()
    }

    private static func generatedMediaContextMessage(for message: ChatMessage) -> AgentMessage? {
        guard !message.mediaItems.isEmpty else { return nil }
        let assets = message.mediaItems.map { media in
            "- kind: \(media.kind.rawValue)\n  path: \(media.path)"
        }.joined(separator: "\n")
        let outcome = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return AgentMessage(
            role: .assistant,
            content: """
            [Generated media artifact]
            The image was generated successfully and is available as a local artifact. This is a result reference, not a new user instruction.
            Assets:
            \(assets)
            Result: \(outcome.isEmpty ? "generated" : outcome)
            If the user asks to reuse this image in the project, call copy_generated_media with the exact source_path before editing project files. If visual details are needed, call inspect_generated_media with the exact source_path; do not claim to know pixel details unless that inspection succeeds.
            """
        )
    }

    private static func mediaOutcomeContextMessage(
        for message: ChatMessage,
        mediaTurnIDs: Set<String>
    ) -> AgentMessage? {
        guard (message.kind == .assistant || message.kind == .system),
              let turnID = message.turnID,
              mediaTurnIDs.contains(turnID),
              message.mediaItems.isEmpty else {
            return nil
        }
        let outcome = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !outcome.isEmpty else { return nil }
        return AgentMessage(
            role: .assistant,
            content: """
            [Generated media result]
            No image asset was produced for the previous image request. Do not assume that an image exists.
            Result: \(outcome)
            """
        )
    }

    @discardableResult
    static func synchronizeGeneratedMediaContext(_ conversation: inout Conversation) -> Bool {
        guard !conversation.modelContext.isEmpty else { return false }
        let mediaTurnIDs = Set(conversation.messages
            .filter { $0.kind == .user && $0.attachments.isEmpty && MediaRequest.parse($0.text) != nil }
            .compactMap(\.turnID))
        let artifacts = conversation.messages.compactMap { message in
            generatedMediaContextMessage(for: message)
                ?? mediaOutcomeContextMessage(for: message, mediaTurnIDs: mediaTurnIDs)
        }
        var changed = false
        for artifact in artifacts where !conversation.modelContext.contains(where: { $0.content == artifact.content }) {
            conversation.modelContext.append(artifact)
            changed = true
        }
        return changed
    }

    static func modelMessagesForContext(_ conversation: Conversation) -> [AgentMessage] {
        let mediaTurnIDs = Set(conversation.messages
            .filter { $0.kind == .user && $0.attachments.isEmpty && MediaRequest.parse($0.text) != nil }
            .compactMap(\.turnID))
        return conversation.messages.compactMap { message in
            // Keep the command as a one-shot side request, but preserve the
            // generated result as a compact artifact reference. The model must
            // know that an image exists and where it can be reused without
            // replaying the image-generation prompt or embedding raw bytes in
            // every later request.
            if let artifact = generatedMediaContextMessage(for: message) {
                return artifact
            }
            if let outcome = mediaOutcomeContextMessage(for: message, mediaTurnIDs: mediaTurnIDs) {
                return outcome
            }
            if (message.kind == .user && message.attachments.isEmpty && MediaRequest.parse(message.text) != nil)
                || (message.turnID.map { mediaTurnIDs.contains($0) } ?? false) {
                return nil
            }
            switch message.kind {
            case .user:
                return AgentMessage(role: .user, content: message.text, attachments: message.attachments)
            case .assistant:
                return AgentMessage(role: .assistant, content: message.text)
            case .plan:
                return AgentMessage(role: .assistant, content: message.text)
            case .tool, .system:
                return nil
            }
        }
    }

    func makeAgentMessages(for conversation: Conversation) -> [AgentMessage] {
        Self.modelMessagesForContext(conversation)
    }
}

// Copyright (c) 2026 DOTS
// The model/tool run loop.

import Foundation
import HarnessPluginKit
import Observation
import PluginRuntime

private struct ToolOutputSnapshot: Sendable {
    let revision: Int
    let text: String
}

private struct PendingAssistantContinuation {
    static let maximumContinuationRequests = 8
    static let maximumContextExcerptCharacters = 12_000

    let id: String
    let originalPrompt: String
    var content = ""
    var thinking: String?
    var continuationCount = 0

    init(id: String, originalPrompt: String) {
        self.id = id
        self.originalPrompt = originalPrompt
    }

    mutating func append(_ message: AgentMessage) {
        content += message.content
        if let nextThinking = message.thinking?.trimmingCharacters(in: .whitespacesAndNewlines), !nextThinking.isEmpty {
            thinking = [thinking, nextThinking].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n")
        }
    }

    func continuationPrompt() -> String {
        """
        Continue the assistant response from exactly where it stopped. Do not repeat text already written. Preserve the original request, language, formatting, and structure. Output only the continuation.

        Original user request (verbatim):
        \(originalPrompt)

        The assistant message immediately following this instruction is the already delivered response, or its most recent ending excerpt if earlier text is omitted. Continue directly after its ending without repeating it.
        """
    }

    func contextExcerpt() -> String {
        guard content.count > Self.maximumContextExcerptCharacters else { return content }
        return "[Earlier response text is already displayed in this answer. The excerpt below is its ending.]\n"
            + content.suffix(Self.maximumContextExcerptCharacters)
    }
}

private final class ToolOutputPreviewBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var output = ""
    private var lastPublishedAt = Date.distantPast
    private var lastPublishedText = ""
    private var revision = 0
    private var lastAppliedRevision = 0

    func append(_ chunk: String) -> ToolOutputSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        output.append(chunk.replacingOccurrences(of: "\r", with: "\n"))
        if output.count > 4_000 { output = String(output.suffix(4_000)) }
        return makeSnapshot(force: false)
    }

    func flush() -> ToolOutputSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        return makeSnapshot(force: true)
    }

    func markApplied(_ revision: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard revision > lastAppliedRevision else { return false }
        lastAppliedRevision = revision
        return true
    }

    private func makeSnapshot(force: Bool) -> ToolOutputSnapshot? {
        let now = Date()
        guard force || now.timeIntervalSince(lastPublishedAt) >= 0.8 else { return nil }
        let lines = output.split(whereSeparator: \.isNewline).suffix(2)
        let text = String(lines.joined(separator: "\n").suffix(720))
        guard !text.isEmpty, text != lastPublishedText else { return nil }
        revision += 1
        lastPublishedAt = now
        lastPublishedText = text
        return ToolOutputSnapshot(revision: revision, text: text)
    }
}

extension NativeAgentHost {
    func run(
        runID: UUID,
        conversationID: String,
        configuration: AgentConfiguration,
        workspace: URL?,
        context: [AgentMessage],
        planMode: Bool,
        approvedPlanID: String?,
        planGateOverride: Bool = false,
        modelOverride: String?,
        allowAccountFailoverAfterLimit: Bool = false,
        promptCPUMilliseconds: Int = 0,
        promptPreparationMetrics: PromptPreparationMetrics? = nil
    ) async {
        // Whatever ends this run - a finished turn, a stop, a thrown error - its
        // write leases and its question to the user end with it, so no abandoned
        // run can hold a file hostage.
        defer {
            dropWorkspaceLeases(conversationID: conversationID)
            WorkspaceLeases.shared.clearDeferredWrites(conversationID: conversationID)
            clearLiveReply(in: conversationID)
        }
        // The first step's preparation includes the run setup below; later
        // steps start their own clock at the top of the loop.
        var runStartedAt: Date? = Date()
        var runStartedCPU: UInt64? = AgentStepCPUTrace.thread()
        let preparationMetrics = promptPreparationMetrics ?? PromptPreparationMetrics()
        let client = NativeAgentClient(configuration: configuration)
        var deferredTools = DeferredToolSession()
        let initialCatalogStarted = AgentStepCPUTrace.thread()
        let (rawTools, initialPluginNameMap) = agentTools(workspace: workspace, metrics: preparationMetrics)
        preparationMetrics.record("tool_catalog_initial", since: initialCatalogStarted)
        // Tool order is part of the prompt prefix. Keep it deterministic across
        // plugin/MCP discovery order and across all provider transports.
        var pluginNameMap = initialPluginNameMap
        let initialCacheEpochStarted = AgentStepCPUTrace.thread()
        var tools = prepareCacheEpoch(conversationID: conversationID, tools: rawTools + DeferredToolSession.definitions,
            pluginNames: pluginNameMap, messages: context)
        preparationMetrics.record("cache_epoch_initial", since: initialCacheEpochStarted)
        var messages = context
        var attachmentLedger = Self.latestAttachments(in: messages)
        saveModelContext(messages, in: conversationID)
        var restartContext: [AgentMessage]?
        var restartPlanMode: Bool?
        var restartApprovedPlanID: String?
        var restartPlanGateOverride = false
        var restartSubagentsOverride: Bool?
        var succeeded = true
        var failureMessage: String?
        var stoppedByUser = false
        var backlogControlText = ""
        // A provider limit or a thrown error ended the run, not the agent's own work.
        var interruptedByError = false
        var visionFallbackAttempted = false
        var nativeCompactionDisabled = false
        var contextOverflowRetryUsed = false
        var forceDeterministicOverflowCompaction = false
        var pendingAssistantContinuation: PendingAssistantContinuation?

        func settlePendingAssistantContinuation() -> AgentMessage? {
            guard let pending = pendingAssistantContinuation else { return nil }
            let liveText = currentLiveReplyText(in: conversationID) ?? pending.content
            let mergedText = liveText.hasPrefix(pending.content) ? liveText : pending.content + liveText
            let assistant = AgentMessage(role: .assistant, content: mergedText, thinking: pending.thinking)
            messages.removeAll { $0.responseContinuationID == pending.id }
            messages.append(assistant)
            pendingAssistantContinuation = nil
            saveModelContext(messages, in: conversationID)
            replaceLiveReply(mergedText, thinking: pending.thinking, in: conversationID)
            return assistant
        }
        func appendPartialAnswer(_ partial: AgentMessage?, turn: FinishedTurn) {
            guard let partial else { return }
            backlogControlText = partial.content
            append(
                ChatMessage(kind: .assistant, text: partial.content, thinking: partial.thinking),
                to: conversationID,
                turnID: turn.turnID,
                changedFiles: turn.changedFiles
            )
        }
        let resumesPlanExecution = !planMode && !planGateOverride
            && conversations.first(where: { $0.id == conversationID }).map {
                $0.planGateActive && $0.continuation != nil
            } == true
        let browserScope = BrowserScope(
            scope: "project",
            conversationID: conversationID,
            runID: runID.uuidString
        )
        // No explicit setting and no browser named in the request: the in-app WebKit
        // browser. It needs no download and no second browser process.
        let requestedBackend = browserBackendSetting ?? BrowserBackendPolicy.resolveUserRule(promptFromContext(context))
        let browserBackend: BrowserBackend = requestedBackend == .unknown ? .native : requestedBackend

        do {
            var toolSteps = 0
            var wrapUpRequested = false
            var toolSignatures: [String: Int] = [:]
            var fileEdits: [String: Int] = [:]

            /// Takes a queued prompt into this run. False means it changes the
            /// plan mode, so the run has to restart with it.
            func absorb(_ next: PendingPrompt) -> Bool {
                deferredTools.resetPlan()
                let user = accept(next, in: conversationID, history: messages)
                let nextSubagentsOverride = next.subagentsOverride
                    ?? (next.notice != nil || next.approvedPlanID != nil
                        ? subagentsEnabled
                        : subagentsEnabledForNewPrompt)
                if next.planMode == planMode,
                   next.approvedPlanID == nil,
                   nextSubagentsOverride == subagentsEnabled {
                    messages.append(user)
                    saveModelContext(messages, in: conversationID)
                    toolSteps = 0
                    wrapUpRequested = false
                    return true
                }
                let nextContext = messages + [user]
                saveModelContext(nextContext, in: conversationID)
                restartContext = nextContext
                restartPlanMode = next.planMode
                restartApprovedPlanID = next.approvedPlanID
                restartPlanGateOverride = next.bypassesPlanGate
                restartSubagentsOverride = nextSubagentsOverride
                return false
            }
            while true {
                try Task.checkCancellation()
                let stepStartedAt = runStartedAt ?? Date()
                runStartedAt = nil
                var cpuStages = preparationMetrics.takeStages()
                let initialCatalogMilliseconds = cpuStages.removeValue(forKey: "tool_catalog_initial") ?? 0
                let initialCacheEpochMilliseconds = cpuStages.removeValue(forKey: "cache_epoch_initial") ?? 0
                var cpuMark = AgentStepCPUTrace.thread()
                if let runStartedCPU {
                    // Built by the caller before the run starts, so it reaches this step by value.
                    let promptStages = ["prompt_guidance", "prompt_activity", "prompt_rules", "prompt_memory",
                        "prompt_sections", "prompt_assembly", "prompt_context"]
                    let promptSubstages = promptStages.compactMap { cpuStages[$0] }.reduce(0, +)
                    cpuStages["prompt_other"] = max(0, promptCPUMilliseconds - promptSubstages)
                    let setupElapsed = AgentStepCPUTrace.milliseconds(since: runStartedCPU, to: cpuMark)
                    cpuStages["setup"] = max(0, setupElapsed - initialCatalogMilliseconds - initialCacheEpochMilliseconds)
                    cpuStages["tool_catalog", default: 0] += initialCatalogMilliseconds
                    cpuStages["cache_epoch", default: 0] += initialCacheEpochMilliseconds
                }
                runStartedCPU = nil
                func cpuLap(_ stage: String) {
                    let now = AgentStepCPUTrace.thread()
                    cpuStages[stage, default: 0] += AgentStepCPUTrace.milliseconds(since: cpuMark, to: now)
                    cpuMark = now
                }
                if toolSteps >= Self.maxToolSteps, !wrapUpRequested {
                    // One request without tool work, so the turn reports what it
                    // found instead of ending silently.
                    wrapUpRequested = true
                    var notice = AgentMessage(role: .user, content: Self.toolStepLimitNotice)
                    notice.promptContextCaptured = true
                    messages.append(notice)
                } else if toolSteps >= Self.maxToolSteps {
                    if let next = takeNextPrompt(in: conversationID, allowQueue: true) {
                        _ = await finishActiveTurn(conversationID: conversationID, workspace: workspace)
                        if absorb(next) { continue }
                        break
                    }
                    succeeded = false
                    failureMessage = AppCopy.text("agent.toolStepLimit")
                    let turn = await finishActiveTurn(conversationID: conversationID, workspace: workspace, status: "paused")
                    updateConversation(conversationID) {
                        $0.continuation = ContinuationState(
                            reason: .toolStepLimit,
                            provider: configuration.provider,
                            model: configuration.model,
                            message: failureMessage!,
                            subagentsOverride: AgentRunScope.subagentsOverride
                        )
                    }
                    queuePausedAfterStop = true
                    append(
                        ChatMessage(kind: .system, text: failureMessage!),
                        to: conversationID,
                        turnID: turn.turnID,
                        changedFiles: turn.changedFiles
                    )
                    break
                }
                cpuLap("setup")
                let overflowCompaction = forceDeterministicOverflowCompaction
                forceDeterministicOverflowCompaction = false
                let forcedCompaction = overflowCompaction || compactRequested.remove(conversationID) != nil
                let requestedModel = modelOverride ?? router?.selectedModelID ?? configuration.model
                let targetPreferredAccountID = router.flatMap {
                    preferredAccountID($0, conversationID: conversationID, modelOverride: modelOverride)
                }
                let targetPreferredModelID = router.flatMap {
                    preferredModelID($0, conversationID: conversationID, modelOverride: modelOverride)
                }
                let targetContextConfiguration = router?.contextConfiguration(
                    for: messages,
                    requestedModel: requestedModel,
                    preferredAccountID: targetPreferredAccountID,
                    preferredModelID: targetPreferredModelID
                )
                let targetRouteIdentity = targetContextConfiguration.map {
                    contextRouteIdentity(configuration: $0, modelOverride: $0.model, router: nil)
                } ?? contextRouteIdentity(
                    configuration: configuration,
                    modelOverride: modelOverride,
                    router: router,
                    conversationID: conversationID
                )
                let targetRouteChanged = conversations.first(where: { $0.id == conversationID })?.contextRouteIdentity != targetRouteIdentity
                // A model change that no longer fits is compacted without asking:
                // pruning and summaries both keep the visible chat history.
                let compactionOutcome = try await compactIfNeeded(
                    messages: messages,
                    conversationID: conversationID,
                    configuration: configuration,
                    tools: DeferredToolSession.requestTools(tools),
                    modelOverride: modelOverride,
                    client: client,
                    nativeCompactionDisabled: nativeCompactionDisabled,
                    force: forcedCompaction,
                    forceDeterministic: overflowCompaction,
                    contextConfiguration: targetContextConfiguration,
                    routeIdentityOverride: targetRouteIdentity,
                    router: router
                )
                if compactionOutcome.strategy != .none {
                    announceCompaction(compactionOutcome, in: conversationID, automatic: true)
                }
                messages = compactionOutcome.messages
                // Compaction may remove an old transcript segment, but it must
                // not make an active attachment disappear from revision
                // tracking. Merge the current canonical messages into the
                // ledger instead of deriving it from only the compacted list.
                Self.mergeLatestAttachments(messages, into: &attachmentLedger)
                cpuLap("compaction")
                let liveCatalog = agentTools(workspace: workspace, metrics: preparationMetrics)
                pluginNameMap = liveCatalog.pluginNames
                cpuLap("tool_catalog")
                tools = prepareCacheEpoch(conversationID: conversationID, tools: liveCatalog.defs + DeferredToolSession.definitions,
                    pluginNames: pluginNameMap, messages: messages)
                cpuLap("cache_epoch")
                appendCacheNotices(messages: &messages, conversationID: conversationID,
                    attachments: Array(attachmentLedger.values), tools: tools, planMode: planMode)
                saveModelContext(messages, in: conversationID)
                cpuLap("save")
                if let pendingAssistantContinuation {
                    // Compaction and cache notices can clear the live bubble.
                    // Restore the accumulated prefix before the next request.
                    replaceLiveReply(
                        pendingAssistantContinuation.content,
                        thinking: pendingAssistantContinuation.thinking,
                        in: conversationID
                    )
                }
                let requestStartedAt = Date()
                let prepareMilliseconds = Int(requestStartedAt.timeIntervalSince(stepStartedAt) * 1_000)
                let requestContextSegment = conversations.first(where: { $0.id == conversationID })?.contextCompactionCount ?? 0
                deferredTools.restoreDiscovery(messages)
                let requestTools = DeferredToolSession.requestTools(tools)
                let selectedEffort = effortOverride ?? configuration.effort
                let executionEffort = deferredTools.effort(selected: selectedEffort, planMode: planMode)
                let request = messages
                let requestCacheKey = cacheKey(
                    for: configuration,
                    planMode: planMode,
                    model: modelOverride,
                    tools: requestTools,
                    router: router
                )
                var response: AgentResponse
                let advertisedBindings = cacheBindingIDs(tools: tools, pluginNames: pluginNameMap)
                let priorStickyAccountID = conversations.first(where: { $0.id == conversationID })?.stickyAccountID
                let requestCachePolicy = AgentCachePolicy(promptCacheKey: requestCacheKey,
                    comparisonScope: AgentCacheTrace.fingerprint("conversation|" + conversationID),
                    priorBoundary: conversations.first(where: { $0.id == conversationID })?.cacheEpoch?.priorBoundary)
                if pendingAssistantContinuation == nil {
                    clearLiveReply(in: conversationID)
                }
                cpuLap("build")
                let requestMainCPU = AgentStepCPUTrace.thread()
                let requestProcessCPU = AgentStepCPUTrace.process()
                // ponytail: an account that fails over after it already wrote prose
                // leaves that prose in front of the next account's; reset per attempt if seen.
                let onDelta: NativeAgentClient.StreamDeltaHandler = { [weak self] delta in
                    await self?.appendLiveReply(delta, in: conversationID)
                }
                do {
                    if let router {
                        response = try await router.complete(
                            messages: request,
                            tools: requestTools,
                            cachePolicy: requestCachePolicy,
                            model: modelOverride,
                            preferredAccountID: targetPreferredAccountID,
                            preferredModelID: targetPreferredModelID,
                            effort: executionEffort,
                            allowAccountFailoverAfterLimit: allowAccountFailoverAfterLimit,
                            disableNativeCompactionForRequest: targetRouteChanged || nativeCompactionDisabled,
                            onDelta: onDelta
                        )
                        if let served = response.servedAccountID,
                           let index = conversations.firstIndex(where: { $0.id == conversationID }),
                           conversations[index].stickyAccountID != served
                            || conversations[index].stickyModelID != response.servedModelID {
                            conversations[index].stickyAccountID = served
                            conversations[index].stickyModelID = response.servedModelID
                            persist()
                        }
                        Task { await router.refreshAccountUsage() }
                    } else {
                        var requestConfiguration = configuration
                        requestConfiguration.effort = executionEffort
                        if targetRouteChanged || nativeCompactionDisabled {
                            requestConfiguration.disableNativeCompactionForRequest = true
                        }
                        let requestClient = NativeAgentClient(configuration: requestConfiguration, session: client.session)
                        response = try await requestClient.complete(
                            messages: request,
                            tools: requestTools,
                            cachePolicy: requestCachePolicy,
                            onDelta: onDelta
                        )
                    }
                } catch let error as NativeAgentError
                    where error.isImageInputUnsupported && !visionFallbackAttempted {
                    visionFallbackAttempted = true
                    messages = try await applyVisionFallback(
                        conversationID: conversationID,
                        messages: messages,
                        configuration: configuration,
                        providerError: error
                    )
                    continue
                } catch let error as NativeAgentError
                    where error.isContextWindowExceeded && !contextOverflowRetryUsed {
                    contextOverflowRetryUsed = true
                    nativeCompactionDisabled = true
                    forceDeterministicOverflowCompaction = true
                    clearLiveReply(in: conversationID)
                    continue
                }
                // The request fit again, so a later overflow in this long run
                // earns its own compaction retry; two in a row still fail.
                contextOverflowRetryUsed = false
                if response.incompleteReason?.lowercased() == "max_output_tokens" {
                    let style = ResponseStyleResolver.resolve(
                        preference: configuration.responseStylePreference,
                        prompt: AgentMessage.responseStylePrompt(in: request)
                    )
                    let hasPlainPartialAnswer = response.message.toolCalls.isEmpty
                        && response.media.isEmpty
                        && !response.message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    let existingContinuationRequests = pendingAssistantContinuation?.continuationCount ?? 0
                    let willContinue = hasPlainPartialAnswer
                        && !style.isHardLimit
                        && existingContinuationRequests < PendingAssistantContinuation.maximumContinuationRequests
                    recordContextUsage(
                        response,
                        conversationID: conversationID,
                        configuration: configuration,
                        cacheKey: response.servedCacheKey ?? requestCacheKey,
                        requestKind: .main,
                        strategy: compactionOutcome.strategy,
                        contextTokensBefore: compactionOutcome.contextTokensAfter,
                        contextTokensAfter: AgentContextCompaction.estimateTokens(messages),
                        startedAt: requestStartedAt,
                        inputComposition: AgentContextInputComposition(messages: request, tools: requestTools, api: configuration.api),
                        effectiveOutputBudget: response.effectiveOutputBudget,
                    requestedEffort: executionEffort,
                        responseStyle: style.style,
                        retryCount: response.retryCount,
                        retryUsage: response.retryUsage,
                        errorKind: willContinue
                            ? "output_limit_continuing"
                            : response.retryCount > 0 ? "output_limit_after_retry" : "output_limit",
                        tools: requestTools,
                        requestContextSegment: requestContextSegment,
                        compaction: compactionOutcome.trace
                    )
                    if let index = conversations.firstIndex(where: { $0.id == conversationID }) {
                        // The next continuation is still the same route. Record
                        // its input so the next preflight applies that route's
                        // trigger instead of treating it as a model switch.
                        if let router,
                           let servedAccountID = response.servedAccountID,
                           let servedModelID = response.servedModelID,
                           let servedAccount = router.store.state.accounts.first(where: { $0.id == servedAccountID }) {
                            conversations[index].stickyAccountID = servedAccountID
                            conversations[index].stickyModelID = servedModelID
                            conversations[index].contextRouteIdentity = servedAccount.routeIdentity(model: servedModelID)
                        } else {
                            conversations[index].contextRouteIdentity = targetRouteIdentity
                        }
                        conversations[index].lastContextInputTokens = response.usage.map {
                            $0.breakdown(forAPI: configuration.api).totalInputTokens
                        }
                            ?? AgentContextCompaction.estimateTokens(request)
                        conversations[index].lastContextEstimatedTokens = response.usage == nil ? 0
                            : requestEstimate(request, tools: requestTools, configuration: configuration, contextConfiguration: targetContextConfiguration)
                        conversations[index].contextWindow = targetContextConfiguration?.contextWindow
                            ?? configuration.contextWindow
                    }
                    var partialAnswer: AgentMessage?
                    if hasPlainPartialAnswer {
                        var pending = pendingAssistantContinuation ?? PendingAssistantContinuation(
                            id: UUID().uuidString,
                            originalPrompt: AgentMessage.responseStylePrompt(in: request) ?? ""
                        )
                        pending.append(response.message)
                        if willContinue {
                            pending.continuationCount += 1
                            pendingAssistantContinuation = pending
                            messages.removeAll { $0.responseContinuationID == pending.id }
                            // Keep the continuation prompt and complete assistant
                            // prefix in the same turn group. Context compaction
                            // therefore retains the exact boundary and original
                            // request together when it archives older turns.
                            messages.append(AgentMessage(
                                role: .user,
                                content: pending.continuationPrompt(),
                                responseContinuationID: pending.id
                            ))
                            messages.append(AgentMessage(
                                role: .assistant,
                                content: pending.contextExcerpt(),
                                responseContinuationID: pending.id
                            ))
                            saveModelContext(messages, in: conversationID)
                            replaceLiveReply(pending.content, thinking: pending.thinking, in: conversationID)
                            continue
                        }
                        pendingAssistantContinuation = pending
                        partialAnswer = settlePendingAssistantContinuation()
                    } else {
                        partialAnswer = settlePendingAssistantContinuation()
                    }
                    succeeded = false
                    failureMessage = style.isHardLimit
                        ? "The response reached the requested output limit."
                        : partialAnswer != nil
                            ? "The response reached its output limit after the maximum number of automatic continuations. The partial answer is shown above."
                            : response.retryCount > 0
                                ? "The provider stopped before completing the response after one bounded output-budget retry."
                                : "The provider stopped before completing the response at its output limit."
                    let turn = await finishActiveTurn(conversationID: conversationID, workspace: workspace, status: "failed")
                    appendPartialAnswer(partialAnswer, turn: turn)
                    append(
                        ChatMessage(kind: .system, text: failureMessage!),
                        to: conversationID,
                        turnID: turn.turnID,
                        changedFiles: turn.changedFiles
                    )
                    break
                }
                if let pending = pendingAssistantContinuation {
                    response.message.content = pending.content + response.message.content
                    response.message.thinking = [pending.thinking, response.message.thinking]
                        .compactMap { $0 }
                        .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                        .joined(separator: "\n\n")
                    // Provider-native items belong to only the final chunk;
                    // the merged transcript must replay the complete answer.
                    response.message.providerItems = []
                    messages.removeAll { $0.responseContinuationID == pending.id }
                    pendingAssistantContinuation = nil
                    replaceLiveReply(response.message.content, thinking: response.message.thinking, in: conversationID)
                }
                // The provider call completed successfully. Only now is a
                // snapshotted payload considered delivered; a failed request
                // leaves deliveredHash unset so a retry still has a truthful
                // source/revision state.
                Self.markDelivered(&messages)
                // Keep a completed provider response in the steer snapshot before
                // observing cancellation. This preserves the output that arrived
                // just as the higher-priority instruction was submitted.
                // Natural language accompanying a tool batch is visible
                // progress. Its prose can be omitted on the next request;
                // provider-native items and the tool-call structure stay intact.
                response.message.markTransientProgressForToolCall()
                messages.append(response.message)
                let historyRewritten = historyRewrittenConversations.remove(conversationID) != nil
                if let priorStickyAccountID,
                   let servedAccountID = response.servedAccountID,
                   let servedModelID = response.servedModelID,
                   let index = conversations.firstIndex(where: { $0.id == conversationID }),
                   priorStickyAccountID != servedAccountID,
                   conversations[index].stickyModelID == servedModelID,
                   !historyRewritten {
                    accountSwitchedConversations.insert(conversationID)
                }
                if let note = router?.lastFailover, note != lastFailoverNotice {
                    lastFailoverNotice = note
                    append(ChatMessage(kind: .system, text: note), to: conversationID, turnID: activeTurnID)
                }
                if let index = conversations.firstIndex(where: { $0.id == conversationID }) {
                    if let router,
                       let servedAccountID = response.servedAccountID,
                       let servedModelID = response.servedModelID,
                       let servedAccount = router.store.state.accounts.first(where: { $0.id == servedAccountID }) {
                        conversations[index].contextRouteIdentity = servedAccount.routeIdentity(model: servedModelID)
                    } else {
                        conversations[index].contextRouteIdentity = targetRouteIdentity
                    }
                    conversations[index].lastContextInputTokens = response.usage.map { $0.breakdown(forAPI: configuration.api).totalInputTokens }
                        ?? AgentContextCompaction.estimateTokens(messages)
                    conversations[index].lastContextEstimatedTokens = response.usage == nil ? 0
                        : requestEstimate(request, tools: requestTools, configuration: configuration, contextConfiguration: targetContextConfiguration)
                    if response.nativeCompactionApplied {
                        // Native Responses compaction changes the serialized
                        // prefix even when the provider keeps the opaque item.
                        conversations[index].contextCompactionCount += 1
                        conversations[index].lastContextEstimatedTokens = 0
                        // Compaction drops read_file bodies; reads must not vouch for them.
                        ReadLedger.shared.forgetConversation(conversationID)
                        append(
                            ChatMessage(
                                kind: .system,
                                text: "",
                                activityCode: "context_compacted_auto"
                            ),
                            to: conversationID,
                            turnID: activeTurnID
                        )
                    }
                }
                let strategy: AgentCompactionStrategy = response.nativeCompactionApplied
                    ? .native
                    : response.nativeCompactionFallback
                        ? .fallback
                        : compactionOutcome.strategy
                if response.nativeCompactionFallback {
                    nativeCompactionDisabled = true
                }
                recordContextUsage(
                    response,
                    conversationID: conversationID,
                    configuration: configuration,
                    cacheKey: response.servedCacheKey ?? requestCacheKey,
                    requestKind: .main,
                    strategy: strategy,
                    contextTokensBefore: compactionOutcome.contextTokensAfter,
                    contextTokensAfter: AgentContextCompaction.estimateTokens(messages),
                    startedAt: requestStartedAt,
                    inputComposition: AgentContextInputComposition(messages: request, tools: requestTools, api: configuration.api),
                    effectiveOutputBudget: response.effectiveOutputBudget,
                    requestedEffort: executionEffort,
                    responseStyle: ResponseStyleResolver.resolve(
                        preference: configuration.responseStylePreference,
                        prompt: AgentMessage.responseStylePrompt(in: request)
                    ).style,
                    retryCount: response.retryCount,
                    retryUsage: response.retryUsage,
                    tools: requestTools,
                    requestContextSegment: requestContextSegment,
                    prepareMilliseconds: prepareMilliseconds,
                    cpu: AgentStepCPUTrace(
                        prepareStages: cpuStages,
                        requestMainThread: AgentStepCPUTrace.milliseconds(since: requestMainCPU, to: AgentStepCPUTrace.thread()),
                        requestProcess: AgentStepCPUTrace.milliseconds(since: requestProcessCPU, to: AgentStepCPUTrace.process()),
                        prepareCacheHits: preparationMetrics.takeCacheHits(),
                        prepareCacheMisses: preparationMetrics.takeCacheMisses()
                    ),
                    compaction: compactionOutcome.trace
                )
                saveModelContext(messages, in: conversationID)

                if response.message.toolCalls.isEmpty,
                   response.message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   !response.message.providerItems.isEmpty,
                   response.media.isEmpty {
                    // Some Responses backends emit a provider-only item before
                    // the actual answer.
                    continue
                }
                if response.message.toolCalls.isEmpty {
                    let deferredPaths = WorkspaceLeases.shared.scheduleFinalChecks(conversationID: conversationID)
                    if !deferredPaths.isEmpty {
                        messages.append(AgentMessage(
                            role: .user,
                            content: "Before finishing, retry these deferred writes now. Their earlier writes were not run because another chat held the files. Finish independent work first, reread each file, and retry the intended change once. If a file is still held, the app will ask the user. Do not finish without attempting these rechecks:\n\(deferredPaths.map { "- \($0)" }.joined(separator: "\n"))"
                        ))
                        saveModelContext(messages, in: conversationID)
                        continue
                    }
                    backlogControlText = response.message.content
                    let text = response.message.content.trimmingCharacters(in: .whitespacesAndNewlines)
                    let mediaItems = await materializeMedia(response.media)
                    let turn = await finishActiveTurn(conversationID: conversationID, workspace: workspace)
                    if planMode {
                        append(
                            ChatMessage(kind: .plan, text: text, thinking: response.message.thinking, mediaItems: mediaItems),
                            to: conversationID,
                            turnID: turn.turnID,
                            changedFiles: turn.changedFiles
                        )
                        if let planID = conversations.first(where: { $0.id == conversationID })?.messages.last?.id {
                            updateConversation(conversationID) { $0.pendingPlanMessageID = planID }
                            if autoApprovePlans && !text.isEmpty {
                                onPlanAutoApproved?()
                                enqueue(
                                    PendingPrompt(
                                        text: AppCopy.text("plan.apply"),
                                        mode: .queue,
                                        planMode: false,
                                        approvedPlanID: planID,
                                        subagentsOverride: AgentRunScope.subagentsOverride
                                    ),
                                    in: conversationID
                                )
                            }
                        }
                    } else if !text.isEmpty || !mediaItems.isEmpty || !(response.message.thinking?.isEmpty ?? true) {
                        append(
                            ChatMessage(kind: .assistant, text: text, thinking: response.message.thinking, mediaItems: mediaItems),
                            to: conversationID,
                            turnID: turn.turnID,
                            changedFiles: turn.changedFiles
                        )
                        if let approvedPlanID {
                            clearPendingPlan(approvedPlanID, in: conversationID)
                        }
                    } else {
                        append(
                            ChatMessage(kind: .system, text: AppCopy.text("agent.emptyResponse")),
                            to: conversationID,
                            turnID: turn.turnID,
                            changedFiles: turn.changedFiles
                        )
                    }
                    if resumesPlanExecution {
                        // A resumed execution has no new approval prompt,
                        // but its final response still finishes the plan.
                        updateConversation(conversationID) {
                            $0.pendingPlanMessageID = nil
                            $0.planGateActive = false
                        }
                    }
                    try Task.checkCancellation()

                    if let next = takeNextPrompt(in: conversationID, allowQueue: true) {
                        if absorb(next) { continue }
                        break
                    }
                    status = AppCopy.format("agent.ready", configuration.model)
                    break
                }

                if Task.isCancelled {
                    for call in response.message.toolCalls {
                        messages.append(AgentMessage(
                            role: .tool,
                            content: "Tool call interrupted before it started.",
                            name: call.name,
                            toolCallID: call.id
                        ))
                    }
                    saveModelContext(messages, in: conversationID)
                    try Task.checkCancellation()
                }

                if wrapUpRequested, toolSteps >= Self.maxToolSteps {
                    // The wrap-up request asked for more tools anyway. Drop it and
                    // its notice: a resumed turn must not be told to stop.
                    if let last = messages.lastIndex(where: { $0.role == .assistant }) { messages.remove(at: last) }
                    messages.removeAll { $0.role == .user && $0.content == Self.toolStepLimitNotice }
                    saveModelContext(messages, in: conversationID)
                    continue
                }
                let toolCalls = response.message.toolCalls.map { deferredTools.resolve($0, catalog: tools) }
                var scopedRulesNeedReview: Set<String> = []
                if let workspace {
                    // Resolve every path in the batch against the context the model
                    // actually saw. A write that introduces new scoped rules is held
                    // until the next request, after those rules have reached the model.
                    let contextBeforeScopedRules = messages
                    for call in toolCalls {
                        guard let scope = ProjectRulePromptContext.scope(for: call, workspace: workspace) else { continue }
                        let alreadyLoaded = ProjectRulePromptContext.contains(scope, in: contextBeforeScopedRules)
                        ProjectRulePromptContext.apply(scope, to: &messages)
                        if !planMode, ProjectRulePromptContext.isMutation(call), !alreadyLoaded {
                            scopedRulesNeedReview.insert(call.id)
                        }
                    }
                    if messages != contextBeforeScopedRules {
                        saveModelContext(messages, in: conversationID)
                    }
                }
                let preText = response.message.content.trimmingCharacters(in: .whitespacesAndNewlines)
                let thinking = response.message.thinking
                let hasThinking = !(thinking?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                if !preText.isEmpty || hasThinking {
                    append(
                        ChatMessage(kind: .assistant, text: preText, thinking: thinking),
                        to: conversationID,
                        turnID: activeTurnID
                    )
                }

                toolSteps += 1
                // The pre-turn snapshot is being captured beside the model request. Nothing
                // may touch the workspace before it is complete (usually it long is).
                if let turnID = activeTurnID {
                    await memory.waitForTurnSnapshot(conversationID: conversationID, turnID: turnID)
                }
                // Journal the complete batch before even the parallel read-only
                // prefetch starts. A shutdown during prefetch is therefore
                // conservative too: every call is treated as possibly started.
                journalToolBatch(toolCalls, in: conversationID)
                // The model already decided these calls are independent by emitting them
                // together; only the read-only ones can run at once, since writes carry
                // approval prompts and ordered workspace side effects.
                let prefetched = await Self.prefetchReadOnly(
                    toolCalls,
                    workspace: remoteTarget == nil ? workspace : nil,
                    conversationID: conversationID,
                    readRoots: searchFolders,
                    planMode: planMode
                )
                // Explore subagents asked for in one turn are independent side runs:
                // they start together, each in its own context, and only their
                // findings come back into this conversation.
                // One cache key per workspace: every explore run shares its system prompt and tools.
                let exploreCacheKey = workspace.map { "explore:" + AgentCacheTrace.fingerprint($0.standardizedFileURL.path) }
                // A side run pays the quota cost of a pause twice over, so it
                // fails over between providers instead of stopping to ask.
                let exploreComplete: ExploreTool.Complete = { [router, weak self] messages, tools in
                    let startedAt = Date()
                    let response = if let router {
                        try await router.completeExploration(messages: messages, tools: tools, cacheKey: exploreCacheKey)
                    } else {
                        try await client.complete(messages: messages, tools: tools)
                    }
                    await self?.recordSubagentUsage(response, kind: .explore, conversationID: conversationID,
                        configuration: configuration, cacheKey: exploreCacheKey, messages: messages, startedAt: startedAt)
                    return response
                }
                let exploreOutcomes = Self.startExplore(
                    toolCalls.filter { cacheToolContractMatches($0.name, tools: tools, workspace: workspace, pluginNames: pluginNameMap, bindings: advertisedBindings) },
                    complete: exploreComplete,
                    workspace: workspace,
                    hints: exploreHints(toolCalls, workspace: workspace)
                )
                // These are unstructured tasks, so an interrupted run does not
                // reach them: cancel whatever the loop below never joins.
                defer { for task in exploreOutcomes.values { task.cancel() } }
                // Editing subagents start at the first delegate call of the turn,
                // once their assignments are checked and approved.
                var workers: [String: Task<DelegateTool.Outcome, Never>]?
                defer { workers?.values.forEach { $0.cancel() } }
                for call in toolCalls {
                    if !activeUsedTools.contains(call.name) { activeUsedTools.append(call.name) }
                    recordAttribution(call, workspace: workspace)
                    defer { closeAttributionWindow(call) }
                    onRemoteEvent?("tool.started", [
                        "runId": runID.uuidString,
                        "callId": call.id,
                        "name": call.name,
                    ])
                    let runningToolMessageID = UUID().uuidString
                    let runningToolText = Self.runningToolText(call)
                    let outputPreview = ToolOutputPreviewBuffer()
                    let onToolOutput: (@Sendable (String) -> Void)?
                    if call.name == "run_command" {
                        onToolOutput = { [weak self, outputPreview] chunk in
                            guard let snapshot = outputPreview.append(chunk) else { return }
                            Task { @MainActor [weak self] in
                                self?.updateToolProgress(
                                    snapshot,
                                    buffer: outputPreview,
                                    messageID: runningToolMessageID,
                                    conversationID: conversationID,
                                    baseText: runningToolText
                                )
                            }
                        }
                    } else {
                        onToolOutput = nil
                    }
                    append(
                        ChatMessage(id: runningToolMessageID, kind: .tool, text: runningToolText),
                        to: conversationID,
                        turnID: activeTurnID
                    )
                    let signature = Self.toolSignature(call)
                    let repeats = (toolSignatures[signature] ?? 0) + 1
                    toolSignatures[signature] = repeats

                    // Nothing of this run may change the workspace while its own
                    // subagents are still writing: join them first.
                    if let running = workers, call.name != DelegateTool.name, Self.risk(call.name) != .readOnly {
                        for task in running.values { _ = await task.value }
                    }
                    var result: String
                    var resultAttachment: ChatAttachment?
                    if !cacheToolContractMatches(call.name, tools: tools, workspace: workspace, pluginNames: pluginNameMap, bindings: advertisedBindings) {
                        result = "Tool error: the tool is unavailable or its advertised contract changed. Request the current catalog before trying again."
                    } else if let control = deferredTools.control(call, catalog: tools, planMode: planMode) {
                        result = control
                    } else if repeats > Self.maxIdenticalToolCalls {
                        result = AppCopy.text("agent.repeatedTool")
                    } else if planMode && Self.planWithholds(call.name) {
                        result = AppCopy.text("plan.toolBlocked")
                    } else if scopedRulesNeedReview.contains(call.id) {
                        result = "Tool error: no file change was made. HerNess has added the applicable directory rules to context. Review them, then retry the operation."
                    } else if call.name == Self.latestAttachmentName {
                        let outcome = latestAttachmentResult(for: call, in: attachmentLedger)
                        result = outcome.message
                        resultAttachment = outcome.attachment
                        if let resultAttachment {
                            attachmentLedger[Self.attachmentKey(resultAttachment)] = resultAttachment
                        }
                    } else if call.name == PlanStepsTool.name {
                        result = PlanStepsTool.execute(call)
                    } else if call.name == ExploreTool.name, let workspace {
                        let outcome: ExploreTool.Outcome
                        if let started = exploreOutcomes[call.id] {
                            outcome = await started.value
                        } else {
                            outcome = await ExploreTool.run(call, complete: exploreComplete, workspace: workspace,
                                hints: exploreHints([call], workspace: workspace)[call.id] ?? "")
                        }
                        result = outcome.toolResult
                        append(
                            ChatMessage(
                                kind: .tool,
                                text: AppCopy.format(
                                    "explore.summary",
                                    outcome.steps,
                                    outcome.readPaths.count,
                                    AppCopy.text(outcome.answered ? "explore.answered" : "explore.partialLabel")
                                ),
                                rawToolOutput: outcome.toolResult
                            ),
                            to: conversationID,
                            turnID: activeTurnID
                        )
                    } else if call.name == DelegateTool.name, let workspace, remoteTarget == nil {
                        if workers == nil {
                            let delegateCacheKey = "delegate:" + AgentCacheTrace.fingerprint(workspace.standardizedFileURL.path)
                            // The conversation's own model: the one the user picked, else
                            // the one Auto is already holding for this chat. Left to routing,
                            // the subagent's opening step would count as planning.
                            let delegateModel: String? = router.flatMap { router in
                                let requested = modelOverride ?? router.selectedModelID
                                return requested.isEmpty || requested == ModelRouter.autoModelID
                                    ? preferredModelID(router, conversationID: conversationID, modelOverride: modelOverride)
                                    : requested
                            }
                            let complete: DelegateTool.Complete = { [router, weak self] messages, tools, effort, light in
                                let startedAt = Date()
                                let response = if let router {
                                    try await router.completeWithFailover(
                                        messages: messages,
                                        tools: tools,
                                        cacheKey: delegateCacheKey,
                                        // The sweep's model is the lightest one routing offers.
                                        preferredModelID: light ? await router.explorationModel?.id ?? delegateModel : delegateModel,
                                        effort: effort
                                    )
                                } else {
                                    try await client.complete(
                                        messages: messages,
                                        tools: tools,
                                        cachePolicy: AgentCachePolicy(promptCacheKey: delegateCacheKey)
                                    )
                                }
                                await self?.recordSubagentUsage(response, kind: .delegate, conversationID: conversationID,
                                    configuration: configuration, cacheKey: delegateCacheKey, messages: messages, startedAt: startedAt)
                                return response
                            }
                            workers = await startWorkers(
                                toolCalls.filter { cacheToolContractMatches($0.name, tools: tools, workspace: workspace, pluginNames: pluginNameMap, bindings: advertisedBindings) },
                                workspace: workspace,
                                conversationID: conversationID,
                                runID: runID,
                                selectedEffort: router?.selectedEffort ?? "",
                                economy: router?.usageMode == .economy,
                                complete: complete
                            )
                        }
                        let started = workers?[call.id]
                        // A stop must reach a subagent that is mid-edit, not wait for it.
                        let outcome = await withTaskCancellationHandler {
                            await started?.value ?? .refused("Tool error: the subagent could not be started.")
                        } onCancel: {
                            started?.cancel()
                        }
                        result = outcome.toolResult
                    } else if call.name == AskUserTool.name {
                        result = await askUser(call, conversationID: conversationID)
                    } else if BrowserTools.names.contains(call.name) {
                        if planMode {
                            result = AppCopy.text("plan.toolBlocked")
                        } else if await requestApprovalIfNeeded(for: call, conversationID: conversationID) {
                            result = await browserSessions.execute(
                                call,
                                scope: browserScope,
                                backend: browserBackend,
                                workspace: workspace
                            )
                        } else {
                            result = AppCopy.text("permission.rejected")
                        }
                    } else if call.name == Self.sandboxStatusName {
                        result = sandboxStatus()
                    } else if call.name == RecallTool.name {
                        result = recall(call, workspace: workspace)
                    } else if call.name == RememberTool.name {
                        if planMode {
                            result = AppCopy.text("plan.toolBlocked")
                        } else {
                            result = remember(call)
                        }
                    } else if call.name == InstallPluginTool.name {
                        if planMode {
                            result = AppCopy.text("plan.toolBlocked")
                        } else if await requestApprovalIfNeeded(for: call, conversationID: conversationID) {
                            result = installPlugin(call)
                        } else {
                            result = AppCopy.text("permission.rejected")
                        }
                    } else if call.name == ComputerUseTools.toolName {
                        if planMode {
                            result = AppCopy.text("plan.toolBlocked")
                        } else if !isComputerUseEnabled {
                            result = "Tool error: Computer Use is disabled in Settings. Enable it under Settings to allow desktop automation."
                        } else if await requestApprovalIfNeeded(for: call, conversationID: conversationID),
                                  cacheToolContractMatches(call.name, tools: tools, workspace: workspace, pluginNames: pluginNameMap, bindings: advertisedBindings) {
                            let object = (try? JSONSerialization.jsonObject(with: Data(call.arguments.utf8)) as? [String: Any]) ?? [:]
                            do {
                                let outcome = try await ComputerUseService.executeWithResult(arguments: object, workspace: workspace)
                                result = outcome.text
                                resultAttachment = outcome.attachment
                            } catch {
                                result = "Computer Use error: \(error.localizedDescription)"
                            }
                        } else {
                            result = AppCopy.text("permission.rejected")
                        }
                    } else if call.name == NativeBrowserTools.toolName {
                        if planMode {
                            result = AppCopy.text("plan.toolBlocked")
                        } else if await requestApprovalIfNeeded(for: call, conversationID: conversationID) {
                            let object = (try? JSONSerialization.jsonObject(with: Data(call.arguments.utf8)) as? [String: Any]) ?? [:]
                            do {
                                result = try await NativeBrowserService.shared.execute(arguments: object, workspace: workspace)
                            } catch {
                                result = "Native browser error: \(error.localizedDescription)"
                            }
                        } else {
                            result = AppCopy.text("permission.rejected")
                        }
                    } else if planMode && Self.risk(call.name) == .workspaceMutation {
                        result = AppCopy.text("plan.toolBlocked")
                    } else if call.name.hasPrefix("skill.") {
                        result = SkillTools.execute(call, catalog: skillCatalog, suggestions: skillSuggestionMonitor)
                        if call.name == "skill.read",
                           let id = skillID(from: call),
                           let descriptor = skillCatalog.descriptor(for: id),
                           (try? skillCatalog.read(id: descriptor.id)) != nil {
                            activeUsedSkills.append(contentsOf: activeUsedSkills.contains(descriptor.id) ? [] : [descriptor.id])
                            memory.recordSkill(runID: runID, skill: descriptor.id)
                        }
                    } else if call.name == TerminalSessionTool.name, let refusal = sandboxDeployRefusal(for: call) {
                        result = refusal
                    } else if call.name == TerminalSessionTool.name {
                        let action = Self.argument(call, key: "action") ?? ""
                        var proceed = true
                        if TerminalSessionTool.actionRequiresApproval(action) {
                            proceed = await requestApprovalIfNeeded(for: call, conversationID: conversationID)
                        }
                        result = proceed
                            ? agentTerminal(
                                call,
                                conversationID: conversationID,
                                workspace: workspace
                            )
                            : AppCopy.text("permission.rejected")
                    } else if let realName = pluginNameMap[call.name] {
                        if await requestApprovalIfNeeded(for: call, conversationID: conversationID),
                           cacheToolContractMatches(call.name, tools: tools, workspace: workspace, pluginNames: pluginNameMap, bindings: advertisedBindings) {
                            result = await runPluginTool(realName, call: call)
                        } else {
                            result = AppCopy.text("permission.rejected")
                        }
                    } else if let mcp = mcpRegistry, mcp.isMCPTool(call.name) {
                        var proceed = mcp.shouldAutoRun(call.name)
                        if !proceed {
                            proceed = await requestApprovalIfNeeded(for: call, conversationID: conversationID)
                        }
                        if proceed && cacheToolContractMatches(call.name, tools: tools, workspace: workspace, pluginNames: pluginNameMap, bindings: advertisedBindings) {
                            result = await runMCPTool(call.name, call: call, registry: mcp)
                        } else {
                            result = AppCopy.text("permission.rejected")
                        }
                    } else if let cached = prefetched[call.id] {
                        result = cached
                    } else if call.name == WorkspaceTools.generatedMediaInspectionName {
                        if remoteTarget == nil {
                            let outcome = conversations.first(where: { $0.id == conversationID })
                                .map { inspectGeneratedMedia(call, conversation: $0) }
                            result = outcome?.message ?? "Tool error: conversation not found."
                            resultAttachment = outcome?.attachment
                        } else {
                            result = "Tool error: generated media is local to this host and cannot be inspected from a remote workspace."
                        }
                    } else if call.name == WorkspaceTools.generatedMediaName {
                        if let workspace, remoteTarget == nil,
                           await requestApprovalIfNeeded(for: call, conversationID: conversationID) {
                            result = conversations.first(where: { $0.id == conversationID })
                                .map { copyGeneratedMedia(call, conversation: $0, workspace: workspace) }
                                ?? "Tool error: conversation not found."
                        } else {
                            result = remoteTarget == nil
                                ? AppCopy.text("permission.rejected")
                                : "Tool error: generated media can only be copied into a local workspace."
                        }
                    } else if WebTools.isWebTool(call.name) {
                        // Web access is the same whether the workspace is local or
                        // on another host, so it never falls into the SSH branch —
                        // and it must not be gated on having a workspace at all.
                        if await requestApprovalIfNeeded(for: call, conversationID: conversationID) {
                            result = await WebTools.execute(call)
                        } else {
                            result = AppCopy.text("permission.rejected")
                        }
                    } else if let remote = remoteTarget {
                        if await requestApprovalIfNeeded(for: call, conversationID: conversationID) {
                            result = await Task.detached(priority: .userInitiated) {
                                WorkspaceTools.executeRemote(call, target: remote, onOutput: onToolOutput)
                            }.value
                        } else {
                            result = AppCopy.text("permission.rejected")
                        }
                    } else if let refusal = sandboxDeployRefusal(for: call) {
                        result = refusal
                    } else if let workspace {
                        if await requestApprovalIfNeeded(for: call, conversationID: conversationID) {
                            let lease = await acquireWorkspaceLease(
                                for: call,
                                workspace: workspace,
                                conversationID: conversationID,
                                runID: runID
                            )
                            if case .refused(let refusal) = lease {
                                result = refusal
                            } else {
                                if call.name == "run_command" && WorkspaceTools.mayDeleteFiles(Self.argument(call, key: "command")) {
                                    activeUnverifiedDeletion = true
                                }
                                // Reads, searches and globs cannot change the tree,
                                // and each `git status` here is a child process
                                // round-trip — so capture only for tools that can.
                                let tracksChanges = !WorkspaceTools.isReadOnly(call.name)
                                let beforeFile = tracksChanges
                                    ? await memory.fileHash(for: call, workspace: workspace) : nil
                                let beforeGit = tracksChanges
                                    ? await memory.changedGitPaths(workspace: workspace) : []
                                // Only a sandbox worktree jails commands. In the
                                // user's own checkout they run as the user, so
                                // builds, package installs and dev servers work.
                                let policy = sandboxPolicy?.agentCommandPolicy()
                                let readRoots = searchFolders
                                // `Task.detached` does not inherit cancellation, and
                                // `run_command` blocks a runloop rather than
                                // suspending — so a user interrupt would otherwise
                                // leave the child (and its process tree) running to
                                // completion. Relay the cancel through an explicit
                                // latch the tool polls.
                                let cancel = ToolCancel()
                                let work = Task.detached(priority: .userInitiated) {
                                    WorkspaceTools.execute(
                                        call,
                                        workspace: workspace,
                                        conversationID: conversationID,
                                        sandboxPolicy: policy,
                                        readRoots: readRoots,
                                        isCancelled: { cancel.isCancelled },
                                        onOutput: onToolOutput
                                    )
                                }
                                result = await withTaskCancellationHandler {
                                    await work.value
                                } onCancel: {
                                    cancel.cancel()
                                }
                                let afterGit = tracksChanges
                                    ? await memory.changedGitPaths(workspace: workspace) : beforeGit
                                memory.recordTool(
                                    runID: runID,
                                    call: call,
                                    result: result,
                                    beforeFile: beforeFile,
                                    beforeGit: beforeGit,
                                    afterGit: afterGit,
                                    workspace: workspace
                                )
                                releaseWorkspaceLease(lease)
                                if case .held(_, _, let notice) = lease, let notice {
                                    result += "\n" + notice
                                }
                                result += fileLessonNotice(for: call, conversationID: conversationID)
                                if call.name == "remove_file" {
                                    if WorkspaceTools.isVerifiedRemovalResult(result) { activeVerifiedRemovals += 1 }
                                    else if WorkspaceTools.isPreservedRemovalResult(result) { activePreservedRemoval = true }
                                    else { activeCleanupFailure = true }
                                }
                                if call.name == "run_command", Self.isTestCommand(Self.argument(call, key: "command")) {
                                    let testStatus = result.localizedCaseInsensitiveContains("status 0")
                                        ? "passed"
                                        : result.localizedCaseInsensitiveContains("status") || result.hasPrefix("Tool error")
                                            ? "failed"
                                            : "not_reported"
                                    if testStatus != "not_reported" { activeRunTestStatus = testStatus }
                                }
                            }
                        } else {
                            result = AppCopy.text("permission.rejected")
                        }
                    } else {
                        result = AppCopy.text("agent.projectToolsUnavailable")
                    }
                    if call.name == "edit_file" || call.name == "write_file", let path = Self.argument(call, key: "path") {
                        let edits = (fileEdits[path] ?? 0) + 1
                        fileEdits[path] = edits
                        if edits > Self.maxEditsPerFile { result += String(format: Self.editChurnNotice, edits) }
                    }
                    if call.name == "run_command", let snapshot = outputPreview.flush() {
                        updateToolProgress(
                            snapshot,
                            buffer: outputPreview,
                            messageID: runningToolMessageID,
                            conversationID: conversationID,
                            baseText: runningToolText
                        )
                    }
                    let preview = call.name == "skill.read"
                        ? Self.skillReadHistoryMarker
                        : Self.toolPreview(result)
                    append(
                        ChatMessage(
                            kind: .tool,
                            text: "✓ \(call.name)\n\(preview)",
                            rawToolOutput: result,
                            attachments: resultAttachment.map { [$0] } ?? []
                        ),
                        to: conversationID,
                        turnID: activeTurnID
                    )
                    if call.name == AskUserTool.name,
                       result.hasPrefix("Q: "),
                       result.contains("\nA: ") {
                        append(
                            ChatMessage(kind: .system, text: result),
                            to: conversationID,
                            turnID: activeTurnID
                        )
                    }
                    onRemoteEvent?("tool.output", [
                        "runId": runID.uuidString,
                        "callId": call.id,
                        "name": call.name,
                    ])
                    onRemoteEvent?("tool.completed", [
                        "runId": runID.uuidString,
                        "callId": call.id,
                        "name": call.name,
                    ])
                    let repeatedRead = call.name == "read_file" ? deferredTools.repeatedRead(result, arguments: call.arguments) : nil
                    deferredTools.record(result, callID: call.id, toolName: call.name, arguments: call.arguments)
                    var modelToolResult = EconomyToolOutputPolicy.normalize(
                        result,
                        toolName: call.name,
                        arguments: call.arguments
                    )
                    if call.name == DeferredToolSession.searchName || call.name == DeferredToolSession.outputName { modelToolResult = result }
                    else if modelToolResult != result { modelToolResult += "\nOriginal result: read_tool_output call_id=\(call.id)" }
                    if call.name == AskUserTool.name, AskUserTool.isAnsweredTranscript(result) {
                        modelToolResult += "\n\n" + AskUserTool.answeredDirective
                    }
                    if call.name == "read_file",
                       modelToolResult != result {
                        // The provider-facing truncation means the model did not
                        // receive the whole file; a full-read ledger entry would
                        // make a later write_file unsafe.
                        if let workspace {
                            WorkspaceTools.forgetRead(
                                call,
                                workspace: workspace,
                                conversationID: conversationID,
                                readRoots: searchFolders
                            )
                        }
                    }
                    // After the ledger check: the model already holds these exact lines.
                    if let repeatedRead { modelToolResult = repeatedRead }
                    messages.append(AgentMessage(
                        role: .tool,
                        content: modelToolResult,
                        name: call.name,
                        toolCallID: call.id,
                        attachments: resultAttachment.map { [$0] } ?? []
                    ))
                    saveModelContext(messages, in: conversationID)
                    try Task.checkCancellation()
                }
                // Every result in the batch is now in the durable model context.
                // Clearing the journal is deliberately the final operation; a
                // crash before this point will require explicit reconciliation.
                finishJournaledTools(in: conversationID)
            }
        } catch let error as NativeAgentError where error.isLimit {
            succeeded = false
            interruptedByError = true
            let partialAnswer = settlePendingAssistantContinuation()
            let turn = await finishActiveTurn(conversationID: conversationID, workspace: workspace, status: "paused")
            appendPartialAnswer(partialAnswer, turn: turn)
            let autoDecision = router?.isAutoSelected == true ? router?.lastAutoDecision : nil
            let selectedModel = autoDecision?.model ?? configuration.model
            let selectedProvider = autoDecision
                .flatMap { decision in router?.routableModels.first(where: { $0.id == decision.model })?.provider }
                .map { RouterCatalog.label(for: $0) }
                ?? configuration.provider
            var summary = AppCopy.format(
                "agent.providerLimit",
                selectedProvider,
                selectedModel,
                error.message
            )
            if router?.autoAccountFailoverAfterLimit == true, let retryAt = error.retryAt {
                summary += "\n" + AppCopy.format("agent.limitResumesAt", Self.clock.string(from: retryAt))
            }
            if let index = conversations.firstIndex(where: { $0.id == conversationID }) {
                conversations[index].continuation = ContinuationState(
                    reason: .providerLimit,
                    provider: selectedProvider,
                    model: selectedModel,
                    message: summary,
                    retryAt: error.retryAt,
                    subagentsOverride: AgentRunScope.subagentsOverride
                )
                append(
                    ChatMessage(kind: .system, text: summary),
                    to: conversationID,
                    turnID: turn.turnID,
                    changedFiles: turn.changedFiles
                )
            }
            queuePausedAfterStop = true
            status = summary
            failureMessage = summary
            persist()
            if router?.autoAccountFailoverAfterLimit == true {
                scheduleLimitResume(for: conversationID, at: error.retryAt)
            }
        } catch {
            if Task.isCancelled {
                let partialAnswer = settlePendingAssistantContinuation()
                let turn = await finishActiveTurn(conversationID: conversationID, workspace: workspace, status: "cancelled")
                appendPartialAnswer(partialAnswer, turn: turn)
                attachTurnMetadata(toStopEvent: activeStopEventID, in: conversationID, turn: turn)
                if !queuePausedAfterStop,
                   let steer = takeNextPrompt(in: conversationID, allowQueue: false) {
                    var nextContext = activeContext.isEmpty ? messages : activeContext
                    nextContext.append(accept(steer, in: conversationID, history: nextContext))
                    activeContext = nextContext
                    restartContext = nextContext
                    restartPlanMode = steer.planMode
                    restartApprovedPlanID = steer.approvedPlanID
                    restartPlanGateOverride = steer.bypassesPlanGate
                    restartSubagentsOverride = steer.subagentsOverride ?? subagentsEnabledForNewPrompt
                } else {
                    succeeded = false
                    stoppedByUser = true
                }
            } else {
                succeeded = false
                interruptedByError = true
                failureMessage = error.localizedDescription
                let partialAnswer = settlePendingAssistantContinuation()
                let turn = await finishActiveTurn(conversationID: conversationID, workspace: workspace, status: "failed")
                appendPartialAnswer(partialAnswer, turn: turn)
                if let approvedPlanID,
                   let conversationIndex = conversations.firstIndex(where: { $0.id == conversationID }),
                   let planIndex = conversations[conversationIndex].messages.firstIndex(where: { $0.id == approvedPlanID && $0.kind == .plan }) {
                    conversations[conversationIndex].messages[planIndex].planError = error.localizedDescription
                }
                append(
                    ChatMessage(kind: .system, text: error.localizedDescription),
                    to: conversationID,
                    turnID: turn.turnID,
                    changedFiles: turn.changedFiles
                )
                if (error as? NativeAgentError)?.isNetworkFailure == true,
                   let index = conversations.firstIndex(where: { $0.id == conversationID }) {
                    conversations[index].continuation = ContinuationState(
                        reason: .networkLost,
                        provider: configuration.provider,
                        model: configuration.model,
                        message: AppCopy.text("agent.networkLost"),
                        subagentsOverride: AgentRunScope.subagentsOverride
                    )
                    persist()
                }
                if conversations.first(where: { $0.id == conversationID })?.continuation != nil {
                    queuePausedAfterStop = true
                }
                status = error.localizedDescription
            }
        }

        guard activeRunID == runID else { return }
        if let restartContext {
            // A cancelled Task remains cancelled, so steering always starts a
            // fresh Task. The new run inherits the old run's full model context.
            let nextSubagentsOverride = restartSubagentsOverride ?? subagentsEnabledForNewPrompt
            _ = AgentRunScope.$subagentsOverride.withValue(nextSubagentsOverride) {
                startRun(
                    runID: runID,
                    conversationID: conversationID,
                    configuration: configuration,
                    workspace: workspace,
                    context: restartContext,
                    planMode: restartPlanMode ?? planMode,
                    approvedPlanID: restartApprovedPlanID,
                    planGateOverride: restartPlanGateOverride,
                    modelOverride: modelOverride
                )
            }
            return
        }

        let browserSummary = await browserSessions.closeRun(
            scope: browserScope,
            backend: browserBackend
        )
        activeTask = nil
        activeConversationID = nil
        isBusy = false
        let summary = WorkspaceRunSummary(
            runID: runID.uuidString,
            turnID: activeRunLastTurnID,
            status: succeeded ? "completed" : "failed",
            trackingStatus: activeRunTrackingStatus,
            cleanupStatus: activeRunCleanupStatus,
            cleanupNote: cleanupNote(status: activeRunCleanupStatus, trackingStatus: activeRunTrackingStatus),
            addedCount: activeRunChangedFiles.filter { $0.operation == .added }.count,
            modifiedCount: activeRunChangedFiles.filter { $0.operation == .modified }.count,
            deletedCount: activeRunChangedFiles.filter { $0.operation == .deleted }.count,
            testStatus: activeRunTestStatus,
            browser: browserSummary,
            undoAvailable: !activeRunChangedFiles.isEmpty && activeRunTrackingStatus == "complete",
            attributionKnown: completedTurnSummaries[activeRunLastTurnID]?.attributionKnown
        )
        if let index = conversations.firstIndex(where: { $0.id == conversationID }),
           let messageIndex = conversations[index].messages.lastIndex(where: { $0.turnID == activeRunLastTurnID }) {
            conversations[index].messages[messageIndex].summary = summary
        }
        onRemoteEvent?("run.summary", summaryPayload(summary, conversationID: conversationID))
        if succeeded {
            onRemoteEvent?("run.completed", [
                "runId": runID.uuidString,
                "status": "completed",
                "conversationId": conversationID,
            ])
        } else {
            onRemoteEvent?("run.failed", [
                "runId": runID.uuidString,
                "status": "failed",
                "conversationId": conversationID,
            ])
        }
        // A run the user stopped is their choice, and one a provider limit or an
        // error cut short has nothing to teach: neither is the agent's mistake. The
        // answer must belong to this run: a run that failed before answering has
        // none, and the previous turn's answer is not to blame for it.
        if !stoppedByUser, !interruptedByError,
           let conversation = conversations.first(where: { $0.id == conversationID }),
           let answerIndex = conversation.messages.lastIndex(where: {
               ($0.kind == .assistant || $0.kind == .plan) && $0.turnID == activeRunLastTurnID
           }),
           !succeeded || activeRunTestStatus == "failed"
               || !memory.openItems(in: backlogControlText).isEmpty {
            learnFromSignal(.failure, in: conversation, assistantIndex: answerIndex)
        }
        memory.finishTask(
            runID: runID,
            success: succeeded,
            finalText: conversations.first(where: { $0.id == conversationID })?.messages.last(where: { $0.kind == .assistant || $0.kind == .plan })?.text ?? "",
            controlText: backlogControlText
        )
        if let index = conversations.firstIndex(where: { $0.id == conversationID }) {
            conversations[index].running = false
            conversations[index].runStartedAt = nil
            // A promoted prompt can finish while a separate plan stays paused.
            // A normal completion (including Continue) consumes the pause.
            if succeeded && (!planGateOverride
                || (conversations[index].pendingPlanMessageID == nil && !conversations[index].planGateActive)) {
                conversations[index].continuation = nil
            }
            conversations[index].modelContext = activeContext
        }
        continuationQueued = false
        activeProvider = ""
        activeModel = ""
        persist()
        onRunSummary?(RunSummaryEvent(
            conversationTitle: conversations.first(where: { $0.id == conversationID })?.title ?? "",
            summary: summary,
            conversationID: conversationID,
            outcome: succeeded ? .completed : (stoppedByUser ? .stopped : .failed),
            failureMessage: failureMessage
        ))
        if succeeded {
            maybeGenerateFollowUp(
                conversationID: conversationID,
                runID: runID,
                workspace: workspace
            )
        }
        // The durable copy now lives on the conversation (and disk). Do not keep
        // a second provider-context array in the run-state table after completion.
        state(for: conversationID).activeContext = []
    }

    private func updateToolProgress(
        _ snapshot: ToolOutputSnapshot,
        buffer: ToolOutputPreviewBuffer,
        messageID: String,
        conversationID: String,
        baseText: String
    ) {
        guard buffer.markApplied(snapshot.revision),
              let conversationIndex = conversations.firstIndex(where: { $0.id == conversationID }),
              let messageIndex = conversations[conversationIndex].messages.firstIndex(where: { $0.id == messageID })
        else { return }
        conversations[conversationIndex].messages[messageIndex].text = baseText + "\n\n" + snapshot.text
    }
}

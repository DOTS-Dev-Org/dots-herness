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
        modelOverride: String?
    ) async {
        // Whatever ends this run - a finished turn, a stop, a thrown error - its
        // write leases and its question to the user end with it, so no abandoned
        // run can hold a file hostage.
        defer {
            dropWorkspaceLeases(conversationID: conversationID)
            clearLiveReply(in: conversationID)
        }
        // The first step's preparation includes the run setup below; later
        // steps start their own clock at the top of the loop.
        var runStartedAt: Date? = Date()
        let client = NativeAgentClient(configuration: configuration)
        let (rawTools, initialPluginNameMap) = agentTools(workspace: workspace)
        // Tool order is part of the prompt prefix. Keep it deterministic across
        // plugin/MCP discovery order and across all provider transports.
        var pluginNameMap = initialPluginNameMap
        var tools = prepareCacheEpoch(conversationID: conversationID, tools: rawTools,
            pluginNames: pluginNameMap, messages: context)
        var messages = context
        var attachmentLedger = Self.latestAttachments(in: messages)
        saveModelContext(messages, in: conversationID)
        var restartContext: [AgentMessage]?
        var restartPlanMode: Bool?
        var restartApprovedPlanID: String?
        var restartPlanGateOverride = false
        var succeeded = true
        var failureMessage: String?
        var stoppedByUser = false
        var visionFallbackAttempted = false
        var nativeCompactionDisabled = false
        let resumesPlanExecution = !planMode && !planGateOverride
            && conversations.first(where: { $0.id == conversationID }).map {
                $0.planGateActive && $0.continuation != nil
            } == true
        let browserScope = BrowserScope(
            scope: "project",
            conversationID: conversationID,
            runID: runID.uuidString
        )
        var browserBackend: BrowserBackend = browserBackendSetting
            ?? (nonInteractive ? .managed : BrowserBackendPolicy.resolveUserRule(promptFromContext(context)))

        do {
            var toolSteps = 0
            var toolSignatures: [String: Int] = [:]
            while true {
                try Task.checkCancellation()
                let stepStartedAt = runStartedAt ?? Date()
                runStartedAt = nil
                if toolSteps >= Self.maxToolSteps {
                    if let next = takeNextPrompt(in: conversationID, allowQueue: true) {
                        _ = await finishActiveTurn(conversationID: conversationID, workspace: workspace)
                        let user = accept(next, in: conversationID, history: messages)
                        if next.planMode == planMode && next.approvedPlanID == nil {
                            messages.append(user)
                            saveModelContext(messages, in: conversationID)
                            toolSteps = 0
                            continue
                        }
                        var nextContext = messages
                        nextContext.append(user)
                        saveModelContext(nextContext, in: conversationID)
                        restartContext = nextContext
                        restartPlanMode = next.planMode
                        restartApprovedPlanID = next.approvedPlanID
                        restartPlanGateOverride = next.bypassesPlanGate
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
                            message: failureMessage!
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
                let forcedCompaction = compactRequested.remove(conversationID) != nil
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
                // Context overflow is handled by compactIfNeeded below. Do not
                // park the user's turn on a confirmation banner: local pruning
                // and model-written summaries both preserve the visible chat
                // history and let the requested work continue automatically.
                let compactionOutcome = try await compactIfNeeded(
                    messages: messages,
                    conversationID: conversationID,
                    configuration: configuration,
                    tools: tools,
                    modelOverride: modelOverride,
                    client: client,
                    nativeCompactionDisabled: nativeCompactionDisabled,
                    force: forcedCompaction,
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
                let liveCatalog = agentTools(workspace: workspace)
                pluginNameMap = liveCatalog.pluginNames
                tools = prepareCacheEpoch(conversationID: conversationID, tools: liveCatalog.defs,
                    pluginNames: pluginNameMap, messages: messages)
                appendCacheNotices(messages: &messages, conversationID: conversationID,
                    attachments: Array(attachmentLedger.values), tools: tools, planMode: planMode)
                saveModelContext(messages, in: conversationID)
                let requestStartedAt = Date()
                let prepareMilliseconds = Int(requestStartedAt.timeIntervalSince(stepStartedAt) * 1_000)
                let requestContextSegment = conversations.first(where: { $0.id == conversationID })?.contextCompactionCount ?? 0
                let requestTools = tools
                let request = messages
                let requestCacheKey = cacheKey(
                    for: configuration,
                    planMode: planMode,
                    model: modelOverride,
                    tools: requestTools,
                    router: router
                )
                let response: AgentResponse
                let advertisedBindings = cacheBindingIDs(tools: requestTools, pluginNames: pluginNameMap)
                let priorStickyAccountID = conversations.first(where: { $0.id == conversationID })?.stickyAccountID
                let requestCachePolicy = AgentCachePolicy(promptCacheKey: requestCacheKey,
                    comparisonScope: AgentCacheTrace.fingerprint("conversation|" + conversationID),
                    priorBoundary: conversations.first(where: { $0.id == conversationID })?.cacheEpoch?.priorBoundary)
                clearLiveReply(in: conversationID)
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
                            disableNativeCompactionForRequest: targetRouteChanged,
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
                        if targetRouteChanged {
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
                }
                if response.incompleteReason?.lowercased() == "max_output_tokens" {
                    succeeded = false
                    let style = ResponseStyleResolver.resolve(
                        preference: configuration.responseStylePreference,
                        prompt: request.last(where: { $0.role == .user })?.content
                    )
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
                        responseStyle: style.style,
                        retryCount: response.retryCount,
                        retryUsage: response.retryUsage,
                        errorKind: response.retryCount > 0
                            ? "output_limit_after_retry"
                            : "output_limit",
                        tools: requestTools,
                        requestContextSegment: requestContextSegment
                    )
                    failureMessage = style.isHardLimit
                        ? "The response reached the requested output limit."
                        : response.retryCount > 0
                            ? "The provider stopped before completing the response after one bounded output-budget retry."
                            : "The provider stopped before completing the response at its output limit."
                    let turn = await finishActiveTurn(conversationID: conversationID, workspace: workspace, status: "failed")
                    append(
                        ChatMessage(kind: .system, text: failureMessage!),
                        to: conversationID,
                        turnID: turn.turnID,
                        changedFiles: turn.changedFiles
                    )
                    break
                }
                // The provider call completed successfully. Only now is a
                // snapshotted payload considered delivered; a failed request
                // leaves deliveredHash unset so a retry still has a truthful
                // source/revision state.
                Self.markDelivered(&messages)
                // Keep a completed provider response in the steer snapshot before
                // observing cancellation. This preserves the output that arrived
                // just as the higher-priority instruction was submitted.
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
                        conversations[index].contextRouteIdentity = [
                            servedAccount.api,
                            servedAccount.provider,
                            servedAccount.id,
                            servedAccount.baseURL.lowercased(),
                            servedModelID,
                        ].joined(separator: "|")
                    } else {
                        conversations[index].contextRouteIdentity = targetRouteIdentity
                    }
                    conversations[index].lastContextInputTokens = response.usage.map { $0.breakdown(forAPI: configuration.api).totalInputTokens }
                        ?? AgentContextCompaction.estimateTokens(messages)
                    if response.nativeCompactionApplied {
                        // Native Responses compaction changes the serialized
                        // prefix even when the provider keeps the opaque item.
                        conversations[index].contextCompactionCount += 1
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
                    responseStyle: ResponseStyleResolver.resolve(
                        preference: configuration.responseStylePreference,
                        prompt: request.last(where: { $0.role == .user })?.content
                    ).style,
                    retryCount: response.retryCount,
                    retryUsage: response.retryUsage,
                    tools: requestTools,
                    requestContextSegment: requestContextSegment,
                    prepareMilliseconds: prepareMilliseconds
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
                                        approvedPlanID: planID
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
                        let user = accept(next, in: conversationID, history: messages)
                        if next.planMode == planMode && next.approvedPlanID == nil {
                            messages.append(user)
                            saveModelContext(messages, in: conversationID)
                            toolSteps = 0
                            continue
                        }
                        var nextContext = messages
                        nextContext.append(user)
                        saveModelContext(nextContext, in: conversationID)
                        restartContext = nextContext
                        restartPlanMode = next.planMode
                        restartApprovedPlanID = next.approvedPlanID
                        restartPlanGateOverride = next.bypassesPlanGate
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

                let toolCalls = response.message.toolCalls
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
                let exploreComplete: ExploreTool.Complete = { [router] messages, tools in
                    if let router {
                        return try await router.completeExploration(messages: messages, tools: tools)
                    }
                    return try await client.complete(messages: messages, tools: tools)
                }
                let exploreOutcomes = Self.startExplore(
                    toolCalls.filter { cacheToolContractMatches($0.name, tools: tools, workspace: workspace, pluginNames: pluginNameMap, bindings: advertisedBindings) },
                    complete: exploreComplete,
                    workspace: workspace
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
                    let signature = call.name + "|" + call.arguments
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
                    } else if repeats > Self.maxIdenticalToolCalls {
                        result = AppCopy.text("agent.repeatedTool")
                    } else if planMode && Self.planWithholds(call.name) {
                        result = AppCopy.text("plan.toolBlocked")
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
                        // A side run pays the quota cost of a pause twice over, so it
                        // fails over between providers instead of stopping to ask.
                        let complete: ExploreTool.Complete = { [router] messages, tools in
                            if let router {
                                return try await router.completeExploration(messages: messages, tools: tools)
                            }
                            return try await client.complete(messages: messages, tools: tools)
                        }
                        let outcome: ExploreTool.Outcome
                        if let started = exploreOutcomes[call.id] {
                            outcome = await started.value
                        } else {
                            outcome = await ExploreTool.run(call, complete: complete, workspace: workspace)
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
                            let complete: ExploreTool.Complete = { [router] messages, tools in
                                if let router {
                                    return try await router.completeWithFailover(messages: messages, tools: tools)
                                }
                                return try await client.complete(messages: messages, tools: tools)
                            }
                            workers = await startWorkers(
                                toolCalls.filter { cacheToolContractMatches($0.name, tools: tools, workspace: workspace, pluginNames: pluginNameMap, bindings: advertisedBindings) },
                                workspace: workspace,
                                conversationID: conversationID,
                                runID: runID,
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
                    } else if [BrowserTools.openName, BrowserTools.navigateName, BrowserTools.closeName, BrowserTools.screenshotName].contains(call.name) {
                        if planMode {
                            result = AppCopy.text("plan.toolBlocked")
                        } else if await requestApprovalIfNeeded(for: call, conversationID: conversationID) {
                            if browserBackend == .unknown {
                                let answer = await askUser(
                                    BrowserTools.backendQuestionCall(call.id),
                                    conversationID: conversationID
                                )
                                browserBackend = BrowserBackendPolicy.parseConfirmation(answer)
                            }
                            result = browserBackend == .unknown
                                ? "Tool error: browser backend was not selected by the user."
                                : await browserSessions.execute(
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
                        }
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
                                let policy = (sandboxPolicy
                                    ?? SandboxExecutionPolicy(workspaceURL: workspace)).strictAgentPolicy()
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
                    var modelToolResult = EconomyToolOutputPolicy.normalize(
                        result,
                        toolName: call.name,
                        arguments: call.arguments
                    )
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
            let turn = await finishActiveTurn(conversationID: conversationID, workspace: workspace, status: "paused")
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
            if let retryAt = error.retryAt {
                summary += "\n" + AppCopy.format("agent.limitResumesAt", Self.clock.string(from: retryAt))
            }
            if let index = conversations.firstIndex(where: { $0.id == conversationID }) {
                conversations[index].continuation = ContinuationState(
                    reason: .providerLimit,
                    provider: selectedProvider,
                    model: selectedModel,
                    message: summary,
                    retryAt: error.retryAt
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
            scheduleLimitResume(for: conversationID, at: error.retryAt)
        } catch {
            if Task.isCancelled {
                let turn = await finishActiveTurn(conversationID: conversationID, workspace: workspace, status: "cancelled")
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
                } else {
                    succeeded = false
                    stoppedByUser = true
                }
            } else {
                succeeded = false
                failureMessage = error.localizedDescription
                let turn = await finishActiveTurn(conversationID: conversationID, workspace: workspace, status: "failed")
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
            _ = startRun(
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
            undoAvailable: !activeRunChangedFiles.isEmpty && activeRunTrackingStatus == "complete"
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
        if activeRunTestStatus == "failed",
           let conversation = conversations.first(where: { $0.id == conversationID }) {
            learnFromSignal(
                .failure,
                in: conversation,
                assistantIndex: conversation.messages.lastIndex { $0.kind == .assistant || $0.kind == .plan }
            )
        }
        memory.finishTask(
            runID: runID,
            success: succeeded,
            finalText: conversations.first(where: { $0.id == conversationID })?.messages.last(where: { $0.kind == .assistant || $0.kind == .plan })?.text ?? ""
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

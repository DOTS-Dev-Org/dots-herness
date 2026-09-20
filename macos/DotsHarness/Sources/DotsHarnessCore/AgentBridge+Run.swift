// Copyright (c) 2026 DOTS
// The model/tool run loop.

import Foundation
import HarnessPluginKit
import Observation
import PluginRuntime

extension NativeAgentHost {
    func run(
        runID: UUID,
        conversationID: String,
        configuration: AgentConfiguration,
        workspace: URL?,
        context: [AgentMessage],
        planMode: Bool,
        approvedPlanID: String?,
        modelOverride: String?
    ) async {
        let client = NativeAgentClient(configuration: configuration)
        let (rawTools, pluginNameMap) = agentTools(workspace: workspace)
        // Tool order is part of the prompt prefix. Keep it deterministic across
        // plugin/MCP discovery order and across all provider transports.
        let tools = rawTools.sorted { $0.name < $1.name }
        var messages = context
        var attachmentLedger = Self.latestAttachments(in: messages)
        saveModelContext(messages, in: conversationID)
        var restartContext: [AgentMessage]?
        var restartPlanMode: Bool?
        var restartApprovedPlanID: String?
        var succeeded = true
        var failureMessage: String?
        var stoppedByUser = false
        var visionFallbackAttempted = false
        var nativeCompactionDisabled = false
        let browserScope = BrowserScope(
            area: area.rawValue,
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
                if toolSteps >= Self.maxToolSteps {
                    if let next = takeNextPrompt(in: conversationID, allowQueue: true) {
                        _ = finishActiveTurn(conversationID: conversationID, workspace: workspace)
                        let user = accept(next, in: conversationID)
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
                        break
                    }
                    succeeded = false
                    failureMessage = AppCopy.text("agent.toolStepLimit")
                    let turn = finishActiveTurn(conversationID: conversationID, workspace: workspace, status: "failed")
                    append(
                        ChatMessage(kind: .system, text: AppCopy.text("agent.toolStepLimit")),
                        to: conversationID,
                        turnID: turn.turnID,
                        changedFiles: turn.changedFiles
                    )
                    break
                }
                let forcedCompaction = compactRequested.remove(conversationID) != nil
                let compactionOutcome = try await compactIfNeeded(
                    messages: messages,
                    conversationID: conversationID,
                    configuration: configuration,
                    tools: tools,
                    modelOverride: modelOverride,
                    client: client,
                    nativeCompactionDisabled: nativeCompactionDisabled,
                    force: forcedCompaction
                )
                if forcedCompaction { announceCompaction(compactionOutcome, in: conversationID) }
                messages = compactionOutcome.messages
                // Compaction may remove an old transcript segment, but it must
                // not make an active attachment disappear from revision
                // tracking. Merge the current canonical messages into the
                // ledger instead of deriving it from only the compacted list.
                Self.mergeLatestAttachments(messages, into: &attachmentLedger)
                saveModelContext(messages, in: conversationID)
                let requestStartedAt = Date()
                let requestCacheKey = cacheKey(
                    for: configuration,
                    planMode: planMode,
                    model: modelOverride,
                    tools: tools
                )
                let response: AgentResponse
                let request = Self.requestMessages(
                    messages,
                    attachmentRevisionNotice: Self.attachmentRevisionNotice(
                        for: attachmentLedger.values.sorted { Self.attachmentKey($0) < Self.attachmentKey($1) }
                    )
                )
                do {
                    if let router {
                        response = try await router.complete(
                            messages: request,
                            tools: tools,
                            cachePolicy: AgentCachePolicy(promptCacheKey: requestCacheKey),
                            model: modelOverride,
                            preferredAccountID: preferredAccountID(router, conversationID: conversationID, modelOverride: modelOverride)
                        )
                        if let served = router.lastServedAccountID,
                           let index = conversations.firstIndex(where: { $0.id == conversationID }),
                           conversations[index].stickyAccountID != served
                            || conversations[index].stickyModelID != router.lastServedModelID {
                            conversations[index].stickyAccountID = served
                            conversations[index].stickyModelID = router.lastServedModelID
                            persist()
                        }
                        Task { await router.refreshAccountUsage() }
                    } else {
                        response = try await client.complete(
                            messages: request,
                            tools: tools,
                            cachePolicy: AgentCachePolicy(promptCacheKey: requestCacheKey)
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
                // The provider call completed successfully. Only now is a
                // snapshotted payload considered delivered; a failed request
                // leaves deliveredHash unset so a retry still has a truthful
                // source/revision state.
                Self.markDelivered(&messages)
                // Keep a completed provider response in the steer snapshot before
                // observing cancellation. This preserves the output that arrived
                // just as the higher-priority instruction was submitted.
                messages.append(response.message)
                if let note = router?.lastFailover, note != lastFailoverNotice {
                    lastFailoverNotice = note
                    append(ChatMessage(kind: .system, text: note), to: conversationID, turnID: activeTurnID)
                }
                if let index = conversations.firstIndex(where: { $0.id == conversationID }) {
                    conversations[index].lastContextInputTokens = response.usage.map { $0.breakdown(forAPI: configuration.api).totalInputTokens }
                        ?? AgentContextCompaction.estimateTokens(messages)
                    if response.nativeCompactionApplied {
                        // Native Responses compaction changes the serialized
                        // prefix even when the provider keeps the opaque item.
                        conversations[index].contextCompactionCount += 1
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
                    cacheKey: requestCacheKey,
                    requestKind: .main,
                    strategy: strategy,
                    contextTokensBefore: compactionOutcome.contextTokensAfter,
                    contextTokensAfter: AgentContextCompaction.estimateTokens(messages),
                    startedAt: requestStartedAt
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
                    let turn = finishActiveTurn(conversationID: conversationID, workspace: workspace)
                    if planMode {
                        append(
                            ChatMessage(kind: .plan, text: text, thinking: response.message.thinking, mediaItems: mediaItems),
                            to: conversationID,
                            turnID: turn.turnID,
                            changedFiles: turn.changedFiles
                        )
                        if let planID = conversations.first(where: { $0.id == conversationID })?.messages.last?.id {
                            updateConversation(conversationID) { $0.pendingPlanMessageID = planID }
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
                    try Task.checkCancellation()

                    if let next = takeNextPrompt(in: conversationID, allowQueue: true) {
                        let user = accept(next, in: conversationID)
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

                toolSteps += 1
                // The pre-turn snapshot is being captured beside the model request. Nothing
                // may touch the workspace before it is complete (usually it long is).
                if let turnID = activeTurnID {
                    await memory.waitForTurnSnapshot(conversationID: conversationID, turnID: turnID)
                }
                // The model already decided these calls are independent by emitting them
                // together; only the read-only ones can run at once, since writes carry
                // approval prompts and ordered workspace side effects.
                let prefetched = await Self.prefetchReadOnly(
                    response.message.toolCalls,
                    workspace: remoteTarget == nil ? workspace : nil,
                    readRoots: searchFolders,
                    contextRoots: area == .chat ? activeChatRoots : [],
                    planMode: planMode
                )
                // Explore subagents asked for in one turn are independent side runs:
                // they start together, each in its own context, and only their
                // findings come back into this conversation.
                let exploreComplete: ExploreTool.Complete = { [router] messages, tools in
                    if let router {
                        return try await router.completeWithFailover(messages: messages, tools: tools)
                    }
                    return try await client.complete(messages: messages, tools: tools)
                }
                let exploreOutcomes = await Self.prefetchExplore(
                    response.message.toolCalls,
                    complete: exploreComplete,
                    workspace: workspace
                )
                if let thinking = response.message.thinking, !thinking.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let preText = response.message.content.trimmingCharacters(in: .whitespacesAndNewlines)
                    append(
                        ChatMessage(kind: .assistant, text: preText, thinking: thinking),
                        to: conversationID,
                        turnID: activeTurnID
                    )
                }
                for call in response.message.toolCalls {
                    if !activeUsedTools.contains(call.name) { activeUsedTools.append(call.name) }
                    recordAttribution(call, workspace: workspace)
                    onRemoteEvent?("tool.started", [
                        "runId": runID.uuidString,
                        "callId": call.id,
                        "name": call.name,
                    ])
                    append(
                        ChatMessage(kind: .tool, text: AppCopy.format("agent.runningTool", call.name)),
                        to: conversationID,
                        turnID: activeTurnID
                    )
                    let signature = call.name + "|" + call.arguments
                    let repeats = (toolSignatures[signature] ?? 0) + 1
                    toolSignatures[signature] = repeats

                    var result: String
                    var resultAttachment: ChatAttachment?
                    if repeats > Self.maxIdenticalToolCalls {
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
                                return try await router.completeWithFailover(messages: messages, tools: tools)
                            }
                            return try await client.complete(messages: messages, tools: tools)
                        }
                        let outcome: ExploreTool.Outcome
                        if let ready = exploreOutcomes[call.id] {
                            outcome = ready
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
                                )
                            ),
                            to: conversationID,
                            turnID: activeTurnID
                        )
                    } else if call.name == OtherChatsTool.name {
                        if area == .chat {
                            result = "Chat transcript isolation is active. Shared roots, notes, and change summaries are available in the Chat context ledger; another Chat transcript is not exposed."
                        } else {
                            // The store, not `conversations`: another app process may have
                            // written turns this one has not merged yet.
                            let otherConversations: [Conversation]
                            if let path = workspaceURL?.path {
                                otherConversations = store.load(workspacePath: path)
                            } else {
                                otherConversations = []
                            }
                            result = OtherChatsTool.execute(call, conversations: otherConversations, mine: conversationID)
                        }
                    } else if call.name == AskUserTool.name {
                        result = await askUser(call, conversationID: conversationID)
                    } else if [BrowserTools.openName, BrowserTools.navigateName, BrowserTools.closeName].contains(call.name) {
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
                                    backend: browserBackend
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
                                workspace: workspace,
                                contextRoots: area == .chat ? activeChatRoots : []
                            )
                            : AppCopy.text("permission.rejected")
                    } else if let realName = pluginNameMap[call.name] {
                        if await requestApprovalIfNeeded(for: call, conversationID: conversationID) {
                            result = await runPluginTool(realName, call: call)
                        } else {
                            result = AppCopy.text("permission.rejected")
                        }
                    } else if let mcp = mcpRegistry, mcp.isMCPTool(call.name) {
                        var proceed = mcp.shouldAutoRun(call.name)
                        if !proceed {
                            proceed = await requestApprovalIfNeeded(for: call, conversationID: conversationID)
                        }
                        if proceed {
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
                    } else if area == .chat {
                        if await requestApprovalIfNeeded(for: call, conversationID: conversationID) {
                            let roots = activeChatRoots
                            let cancel = ToolCancel()
                            let work = Task.detached(priority: .userInitiated) {
                                WorkspaceTools.execute(
                                    call,
                                    contextRoots: roots,
                                    isCancelled: { cancel.isCancelled }
                                )
                            }
                            result = await withTaskCancellationHandler {
                                await work.value
                            } onCancel: {
                                cancel.cancel()
                            }
                        } else {
                            result = AppCopy.text("permission.rejected")
                        }
                    } else if let remote = remoteTarget {
                        if await requestApprovalIfNeeded(for: call, conversationID: conversationID) {
                            result = await Task.detached(priority: .userInitiated) {
                                WorkspaceTools.executeRemote(call, target: remote)
                            }.value
                        } else {
                            result = AppCopy.text("permission.rejected")
                        }
                    } else if let workspace {
                        if await requestApprovalIfNeeded(for: call, conversationID: conversationID) {
                            if call.name == "run_command" && WorkspaceTools.mayDeleteFiles(Self.argument(call, key: "command")) {
                                activeUnverifiedDeletion = true
                            }
                            let beforeFile = memory.fileHash(for: call, workspace: workspace)
                            let beforeGit = memory.changedGitPaths(workspace: workspace)
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
                                    sandboxPolicy: policy,
                                    readRoots: readRoots,
                                    isCancelled: { cancel.isCancelled }
                                )
                            }
                            result = await withTaskCancellationHandler {
                                await work.value
                            } onCancel: {
                                cancel.cancel()
                            }
                            memory.recordTool(
                                runID: runID,
                                call: call,
                                result: result,
                                beforeFile: beforeFile,
                                beforeGit: beforeGit,
                                workspace: workspace
                            )
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
                        } else {
                            result = AppCopy.text("permission.rejected")
                        }
                    } else {
                        result = AppCopy.text("agent.projectToolsUnavailable")
                    }
                    let preview = call.name == "skill.read"
                        ? Self.skillReadHistoryMarker
                        : Self.toolPreview(result)
                    append(
                        ChatMessage(kind: .tool, text: "✓ \(call.name)\n\(preview)"),
                        to: conversationID,
                        turnID: activeTurnID
                    )
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
                    messages.append(AgentMessage(
                        role: .tool,
                        content: result,
                        name: call.name,
                        toolCallID: call.id,
                        attachments: resultAttachment.map { [$0] } ?? []
                    ))
                    saveModelContext(messages, in: conversationID)
                    try Task.checkCancellation()
                }
            }
        } catch let error as NativeAgentError where error.isLimit {
            succeeded = false
            let turn = finishActiveTurn(conversationID: conversationID, workspace: workspace, status: "paused")
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
                let turn = finishActiveTurn(conversationID: conversationID, workspace: workspace, status: "cancelled")
                attachTurnMetadata(toStopEvent: activeStopEventID, in: conversationID, turn: turn)
                if !queuePausedAfterStop,
                   let steer = takeNextPrompt(in: conversationID, allowQueue: false) {
                    var nextContext = activeContext.isEmpty ? messages : activeContext
                    nextContext.append(accept(steer, in: conversationID))
                    activeContext = nextContext
                    restartContext = nextContext
                    restartPlanMode = steer.planMode
                    restartApprovedPlanID = steer.approvedPlanID
                } else {
                    succeeded = false
                    stoppedByUser = true
                }
            } else {
                succeeded = false
                failureMessage = error.localizedDescription
                let turn = finishActiveTurn(conversationID: conversationID, workspace: workspace, status: "failed")
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
            browser: browserSummary
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
        memory.finishTask(
            runID: runID,
            success: succeeded,
            finalText: conversations.first(where: { $0.id == conversationID })?.messages.last(where: { $0.kind == .assistant || $0.kind == .plan })?.text ?? ""
        )
        if let index = conversations.firstIndex(where: { $0.id == conversationID }) {
            conversations[index].running = false
            conversations[index].runStartedAt = nil
            if succeeded { conversations[index].continuation = nil }
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
}

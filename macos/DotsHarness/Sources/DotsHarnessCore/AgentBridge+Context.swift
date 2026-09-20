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
            conversations[index].modelContext = durable
        }
        persist()
    }

    public func contextUsageEvents() -> [AgentContextUsageEvent] {
        _ = listTick
        return contextTelemetry.events()
    }

    public func contextCacheSummary() -> AgentContextCacheSummary {
        _ = listTick
        return contextTelemetry.summary()
    }

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
        errorKind: String? = nil
    ) {
        guard response?.usage != nil || errorKind != nil || requestKind == .compactionSummary else { return }
        let event = AgentContextUsageEvent(
            conversationID: conversationID,
            provider: configuration.provider,
            api: configuration.api,
            model: modelOverride ?? router?.lastServedModelID ?? configuration.model,
            cacheKey: cacheKey,
            requestKind: requestKind,
            strategy: strategy,
            policyID: configuration.compactionPolicy.id,
            usage: response?.usage,
            contextTokensBefore: contextTokensBefore,
            contextTokensAfter: contextTokensAfter,
            latencyMilliseconds: Int(max(0, Date().timeIntervalSince(startedAt) * 1_000)),
            nativeCompactionFallback: response?.nativeCompactionFallback ?? false,
            errorKind: errorKind
        )
        contextTelemetry.append(event)
        touchLists()
    }

    func compactIfNeeded(
        messages: [AgentMessage],
        conversationID: String,
        configuration: AgentConfiguration,
        tools: [AgentToolDefinition],
        modelOverride: String?,
        client: NativeAgentClient,
        nativeCompactionDisabled: Bool,
        force: Bool = false
    ) async throws -> ContextCompactionOutcome {
        let budget = AgentContextCompaction.budget(
            contextWindow: configuration.contextWindow,
            reservedOutputTokens: configuration.api == RouterAPIKind.anthropic.rawValue
                ? NativeAgentClient.maxTokens(forEffort: configuration.effort)
                : 4_096,
            toolDefinitionTokens: AgentContextCompaction.estimateTokens(tools),
            policy: configuration.compactionPolicy
        )
        let estimated = AgentContextCompaction.estimateTokens(messages)
        if configuration.supportsNativeCompaction,
           !nativeCompactionDisabled,
           configuration.api == RouterAPIKind.chatGPT.rawValue {
            // Let the documented Responses route own the compaction item. The
            // opaque item is returned in the provider transcript and must not be
            // replaced with a local summary before the provider sees it.
            return ContextCompactionOutcome(
                messages: messages,
                strategy: .none,
                contextTokensBefore: estimated,
                contextTokensAfter: estimated
            )
        }
        let previousInput = conversations.first(where: { $0.id == conversationID })?.lastContextInputTokens ?? 0
        guard force || max(estimated, previousInput) >= budget.triggerTokens else {
            return ContextCompactionOutcome(
                messages: messages,
                strategy: .none,
                contextTokensBefore: estimated,
                contextTokensAfter: estimated
            )
        }

        let previousSummary = conversations.first(where: { $0.id == conversationID })?.contextSummary
        let durableMessages = Self.durableContext(messages)
        guard let selection = AgentContextCompaction.select(durableMessages, previousSummary: previousSummary, budget: budget) else {
            var trimmed = durableMessages
            if AgentContextCompaction.trimToolResults(&trimmed, targetTokens: budget.targetTokens) {
                if let index = conversations.firstIndex(where: { $0.id == conversationID }) {
                    conversations[index].contextCompactionCount += 1
                    conversations[index].lastContextInputTokens = AgentContextCompaction.estimateTokens(trimmed)
                    conversations[index].contextWindow = budget.contextWindow
                }
                saveModelContext(trimmed, in: conversationID)
                return ContextCompactionOutcome(
                    messages: trimmed,
                    strategy: .fallback,
                    contextTokensBefore: estimated,
                    contextTokensAfter: AgentContextCompaction.estimateTokens(trimmed)
                )
            }
            return ContextCompactionOutcome(
                messages: messages,
                strategy: .none,
                contextTokensBefore: estimated,
                contextTokensAfter: estimated
            )
        }

        status = "Context automatically compacting…"
        let summary: String
        let summaryStartedAt = Date()
        if let forked = try await forkedSummary(
            messages: messages,
            tools: tools,
            configuration: configuration,
            modelOverride: modelOverride,
            conversationID: conversationID,
            client: client
        ) {
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
                errorKind: summaryIsValid ? nil : "summary_invalid"
            )
            summary = normalized
        } else {
            let summaryMessages = [
                AgentMessage(role: .system, content: AgentContextCompaction.summarySystemPrompt),
                AgentMessage(role: .user, content: selection.archiveText),
            ]
            // Same model as the chat: the cache belongs to it, and the summary is
            // read back by it.
            let summaryModel = modelOverride
            do {
                let response: AgentResponse
                if let router {
                    response = try await router.complete(
                        messages: summaryMessages,
                        tools: [],
                        cachePolicy: AgentCachePolicy(),
                        model: summaryModel
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
                    errorKind: "summary_failed"
                )
                summary = ""
            }
        }

        let validSummary = AgentContextCompaction.isValidSummary(summary)
            ? summary
            : AgentContextCompaction.fallbackSummary(previousSummary: previousSummary, archiveText: selection.archiveText)
        let strategy: AgentCompactionStrategy = AgentContextCompaction.isValidSummary(summary) ? .aiSummary : .fallback
        let preserveProviderItems = (router?.preserveProviderItems(for: modelOverride ?? configuration.model))
            ?? (configuration.api == RouterAPIKind.chatGPT.rawValue)
        let compacted = selection.compose(summary: validSummary, preserveProviderItems: preserveProviderItems)
        if let index = conversations.firstIndex(where: { $0.id == conversationID }) {
            conversations[index].contextSummary = validSummary
            conversations[index].contextCompactionCount += 1
            conversations[index].lastContextInputTokens = AgentContextCompaction.estimateTokens(compacted)
            conversations[index].contextWindow = budget.contextWindow
        }
        saveModelContext(compacted, in: conversationID)
        status = "Context compacted."
        return ContextCompactionOutcome(
            messages: compacted,
            strategy: strategy,
            contextTokensBefore: estimated,
            contextTokensAfter: AgentContextCompaction.estimateTokens(compacted)
        )
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
    ) async throws -> (response: AgentResponse, cacheKey: String?)? {
        let request = messages + [AgentMessage(role: .user, content: AgentContextCompaction.summaryForkInstruction)]
        let key = cacheKey(for: configuration, planMode: false, model: modelOverride, tools: tools)
        do {
            let response: AgentResponse
            if let router {
                response = try await router.complete(
                    messages: request,
                    tools: tools,
                    cachePolicy: AgentCachePolicy(promptCacheKey: key),
                    model: modelOverride,
                    preferredAccountID: preferredAccountID(router, conversationID: conversationID, modelOverride: modelOverride)
                )
            } else {
                response = try await client.complete(
                    messages: request,
                    tools: tools,
                    cachePolicy: AgentCachePolicy(promptCacheKey: key)
                )
            }
            return response.message.toolCalls.isEmpty ? (response, key) : nil
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
        let workspace = area == .chat ? nil : workspaceURL
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

    func announceCompaction(_ outcome: ContextCompactionOutcome, in conversationID: String) {
        guard outcome.strategy != .none else { return }
        append(
            ChatMessage(
                kind: .system,
                text: "Context compacted: \(outcome.contextTokensBefore) → \(outcome.contextTokensAfter) tokens."
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

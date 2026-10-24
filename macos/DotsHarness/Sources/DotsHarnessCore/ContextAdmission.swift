// Copyright (c) 2026 DOTS
// Asking before a newly selected model has to compress the conversation to fit.

import Foundation

/// What the conversation would look like to the route that is about to serve it.
/// Derived once and shared by the pre-flight warning and the compaction that
/// follows, so the promise made in the banner and the work actually done cannot
/// disagree about the budget.
struct ContextAdmission {
    let configuration: AgentConfiguration
    let budget: AgentContextBudget
    /// Estimate of the transcript exactly as it will be sent.
    let promptTokens: Int
    /// Estimate after tool output has been normalised, i.e. the size admission
    /// is really judged against.
    let normalizedTokens: Int
    let responseStyle: ResponseStyleDecision
    /// Whether compaction on this route is a local prune rather than a summary.
    let deterministic: Bool

    var fits: Bool { budget.fits(normalizedTokens) }
}

extension NativeAgentHost {
    /// The admission estimate of a sent request, on the same basis
    /// `compactIfNeeded` compares against the provider's count.
    func requestEstimate(
        _ messages: [AgentMessage],
        tools: [AgentToolDefinition],
        configuration: AgentConfiguration,
        contextConfiguration: AgentConfiguration?
    ) -> Int {
        let admission = contextAdmission(messages: messages, configuration: configuration, tools: tools, contextConfiguration: contextConfiguration)
        return admission.normalizedTokens + admission.budget.toolDefinitionTokens
    }

    func contextAdmission(
        messages: [AgentMessage],
        configuration: AgentConfiguration,
        tools: [AgentToolDefinition],
        contextConfiguration: AgentConfiguration?
    ) -> ContextAdmission {
        let budgetConfiguration = contextConfiguration ?? configuration
        let responseStyle = ResponseStyleResolver.resolve(
            preference: configuration.responseStylePreference,
            prompt: AgentMessage.responseStylePrompt(in: messages)
        )
        // Admission must reserve the same bounded output ceiling every
        // transport request now sends, including Standard mode.
        let reservedOutputTokens = AgentOutputBudget.resolve(
            configuration: budgetConfiguration,
            messages: messages,
            tools: tools,
            decision: responseStyle
        ).maxOutputTokens
        let budget = AgentContextCompaction.budget(
            contextWindow: budgetConfiguration.contextWindow,
            reservedOutputTokens: reservedOutputTokens,
            toolDefinitionTokens: AgentContextCompaction.estimateTokens(tools),
            policy: budgetConfiguration.compactionPolicy
        )
        let replay = budgetConfiguration.api == RouterAPIKind.chatGPT.rawValue
            ? AgentContextCompaction.responsesReplayMessages(messages) : messages
        let codingContext = !tools.isEmpty || messages.contains {
            $0.role == .tool || !$0.toolCalls.isEmpty
        }
        return ContextAdmission(
            configuration: budgetConfiguration,
            budget: budget,
            promptTokens: AgentContextCompaction.estimateTokens(replay),
            normalizedTokens: AgentContextCompaction.estimateTokens(EconomyToolOutputPolicy.normalizeMessages(replay)),
            responseStyle: responseStyle,
            // A short final answer does not authorize dropping coding evidence.
            // Coding histories use a checkpoint or summary even in Economy.
            deterministic: !codingContext && (configuration.usageMode == .economy || responseStyle.isShort)
        )
    }

    /// The cheapest model that should write a compaction summary for a route
    /// change: the small model of the account that just served the conversation,
    /// then the destination account's, then nobody. `nil` keeps compaction
    /// deterministic, because the archive would overflow both.
    func routeSummarizer(
        conversation: Conversation,
        targetConfiguration: AgentConfiguration,
        routeIdentity: String
    ) -> (accountID: String, model: String)? {
        guard let router else { return nil }
        return router.contextSummarizer(
            previousAccountID: Self.previousRoute(conversation).accountID,
            targetAccountID: targetConfiguration.accountID ?? Self.parsedRoute(routeIdentity).accountID,
            archiveTokens: AgentContextCompaction.summarizerTokens
        )
    }

    /// Archive length the summarizing request can carry: capped by the model that
    /// writes the summary and by the one that has to receive the result.
    func contextArchiveCharacters(summarizer: (accountID: String, model: String)?, destination: AgentContextBudget) -> Int {
        var limit = AgentContextCompaction.archiveCharacters(fitting: destination)
        if let router, let summarizer {
            limit = min(limit, AgentContextCompaction.archiveCharacters(
                fitting: AgentContextCompaction.budget(contextWindow: router.contextWindow(for: summarizer.model))
            ))
        }
        return limit
    }

    /// `api|provider|account|baseURL|model` as `contextRouteIdentity` records it,
    /// plus the shorter `unresolved|account|model` variant. The model is always the
    /// last field, so a base URL that carries the separator cannot shift it.
    static func parsedRoute(_ identity: String) -> (accountID: String?, model: String?) {
        let fields = identity
            .split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard fields.count >= 3 else { return (nil, nil) }
        let account = fields.first == "unresolved" ? fields[1] : fields[2]
        let model = fields.last.flatMap { $0.isEmpty ? nil : $0 }
        return (account.isEmpty ? nil : account, model == ModelRouter.autoModelID ? nil : model)
    }

    /// Where the conversation actually ran last, which is what decides whose
    /// quota the summary should spend.
    static func previousRoute(_ conversation: Conversation) -> (accountID: String?, model: String?) {
        let parsed = parsedRoute(conversation.contextRouteIdentity)
        return (parsed.accountID ?? conversation.stickyAccountID, parsed.model ?? conversation.stickyModelID)
    }

    func contextModelLabel(_ modelID: String) -> String {
        router?.modelLabel(forID: modelID) ?? RouterCatalog.modelDisplayName(for: RouterModel(id: modelID))
    }
}

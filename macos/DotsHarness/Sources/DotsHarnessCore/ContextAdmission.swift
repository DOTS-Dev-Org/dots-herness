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

/// A model change that would not fit: the user decides whether the conversation
/// may be compressed to make it fit.
public struct PendingContextOverflow: Sendable, Equatable, Identifiable {
    public let conversationID: String
    /// Route the check was computed for, so a run asks once per route.
    public let routeIdentity: String
    public let targetModel: String
    /// Tokens the transcript needs, and the room the target model actually has.
    public let requiredTokens: Int
    public let usableTokens: Int
    /// Small model that will write the summary, or nil when no account can hold
    /// the transcript and the app trims it without calling anyone.
    public let summarizerModel: String?

    public var id: String { "\(conversationID)|\(routeIdentity)" }

    public init(
        conversationID: String,
        routeIdentity: String,
        targetModel: String,
        requiredTokens: Int,
        usableTokens: Int,
        summarizerModel: String?
    ) {
        self.conversationID = conversationID
        self.routeIdentity = routeIdentity
        self.targetModel = targetModel
        self.requiredTokens = requiredTokens
        self.usableTokens = usableTokens
        self.summarizerModel = summarizerModel
    }
}

extension NativeAgentHost {
    func contextAdmission(
        messages: [AgentMessage],
        configuration: AgentConfiguration,
        tools: [AgentToolDefinition],
        contextConfiguration: AgentConfiguration?
    ) -> ContextAdmission {
        let budgetConfiguration = contextConfiguration ?? configuration
        let responseStyle = ResponseStyleResolver.resolve(
            preference: configuration.responseStylePreference,
            prompt: messages.last(where: { $0.role == .user })?.content
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

    /// Whether the route about to serve this run would have to compress the
    /// conversation, and what it would use to do it.
    ///
    /// Only a route change is questioned: a long conversation on the model it has
    /// been using all along compacts on its own at the threshold, which is the
    /// behaviour the user already accepted when starting the chat.
    func contextOverflow(
        messages: [AgentMessage],
        conversationID: String,
        configuration: AgentConfiguration,
        tools: [AgentToolDefinition],
        contextConfiguration: AgentConfiguration?,
        routeIdentity: String
    ) -> PendingContextOverflow? {
        guard let conversation = conversations.first(where: { $0.id == conversationID }),
              !routeIdentity.isEmpty,
              conversation.contextRouteIdentity != routeIdentity else { return nil }
        let admission = contextAdmission(
            messages: messages,
            configuration: configuration,
            tools: tools,
            contextConfiguration: contextConfiguration
        )
        guard !admission.fits else { return nil }
        // Promising a summary that cannot be produced would be worse than saying
        // nothing: below two turn groups there is nothing to archive, and the
        // existing trim-only path handles it.
        guard AgentContextCompaction.select(
            Self.durableContext(messages),
            previousSummary: conversation.contextSummary,
            budget: admission.budget
        ) != nil else { return nil }
        // Economy and short-answer runs prune tool output locally and never pay
        // for a second model call, so the banner must not promise one.
        let summarizer = admission.deterministic ? nil : routeSummarizer(
            conversation: conversation,
            targetConfiguration: admission.configuration,
            routeIdentity: routeIdentity
        )
        return PendingContextOverflow(
            conversationID: conversationID,
            routeIdentity: routeIdentity,
            targetModel: contextModelLabel(admission.configuration.model),
            requiredTokens: admission.normalizedTokens,
            usableTokens: admission.budget.usableInputTokens,
            summarizerModel: summarizer.map { contextModelLabel($0.model) }
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

    /// Blocks on the composer banner. Declining stops the run before any request
    /// leaves the app, so an unattended run must not be able to stall: it gets the
    /// compression it would have got anyway.
    func requestContextCompaction(_ pending: PendingContextOverflow) async -> Bool {
        guard !nonInteractive else { return true }
        pendingContextOverflow = pending
        notifyAttention(
            .contextCompaction,
            in: pending.conversationID,
            detail: AppCopy.format("context.overflowReason", pending.targetModel, pending.requiredTokens, pending.usableTokens)
        )
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                guard !Task.isCancelled, pendingContextOverflow?.id == pending.id else {
                    continuation.resume(returning: false)
                    return
                }
                contextOverflowContinuation = continuation
            }
        }, onCancel: { [weak self] in
            Task { @MainActor [weak self] in self?.finishContextCompaction(false) }
        })
    }

    func finishContextCompaction(_ allow: Bool) {
        guard pendingContextOverflow != nil else { return }
        pendingContextOverflow = nil
        let continuation = contextOverflowContinuation
        contextOverflowContinuation = nil
        continuation?.resume(returning: allow)
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

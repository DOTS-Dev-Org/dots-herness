// Copyright (c) 2026 DOTS
// Privacy-safe usage telemetry for context compaction and prompt caching.

import Foundation
import PluginRuntime

public enum AgentContextRequestKind: String, Sendable, Codable, Equatable {
    case main
    case compactionSummary
}

public enum AgentCompactionStrategy: String, Sendable, Codable, Equatable {
    case none
    case native
    case aiSummary
    case deterministic
    case fallback
}

/// Provider-normalized input accounting. Anthropic reports uncached input
/// separately from cache read/write tokens; OpenAI-compatible routes report a
/// combined input count. Keeping this distinction prevents false cost totals.
public struct AgentUsageBreakdown: Sendable, Codable, Equatable {
    public let uncachedInputTokens: Int
    public let cachedInputTokens: Int
    public let cacheWriteTokens: Int
    public let totalInputTokens: Int
    /// Non-nil when the provider explicitly reported the miss side of the
    /// accounting (for example DeepSeek's prompt_cache_miss_tokens).
    public let cacheMissInputTokens: Int?
    public let reportedCacheAccounting: Bool?
    /// Tokens processed anew for this request. Cached reads are excluded;
    /// cache writes are included because the provider processes them now.
    public var freshInputTokens: Int {
        uncachedInputTokens + cacheWriteTokens
    }

    public init(
        uncachedInputTokens: Int,
        cachedInputTokens: Int,
        cacheWriteTokens: Int,
        totalInputTokens: Int,
        cacheMissInputTokens: Int? = nil,
        reportedCacheAccounting: Bool? = nil
    ) {
        self.uncachedInputTokens = max(0, uncachedInputTokens)
        self.cachedInputTokens = max(0, cachedInputTokens)
        self.cacheWriteTokens = max(0, cacheWriteTokens)
        self.totalInputTokens = max(0, totalInputTokens)
        self.cacheMissInputTokens = cacheMissInputTokens.map { max(0, $0) }
        self.reportedCacheAccounting = reportedCacheAccounting
    }

    public var cacheAccountingAvailable: Bool {
        reportedCacheAccounting ?? (cacheMissInputTokens != nil || cachedInputTokens > 0 || cacheWriteTokens > 0)
    }

    /// This is a measured ratio, never a claim that an absent provider field was
    /// zero. It is nil when the response did not expose cache accounting.
    public var cacheHitRate: Double? {
        guard cacheAccountingAvailable else { return nil }
        let denominator = totalInputTokens
        guard denominator > 0 else { return nil }
        return Double(cachedInputTokens) / Double(denominator)
    }
}

public extension AgentUsage {
    func breakdown(forAPI api: String) -> AgentUsageBreakdown {
        let cached = max(0, cachedTokens ?? 0)
        let written = max(0, cacheWriteTokens ?? 0)
        let reported = cachedTokens != nil || cacheWriteTokens != nil || cacheMissTokens != nil
        if api == RouterAPIKind.anthropic.rawValue {
            // Anthropic's `input_tokens` excludes cache read and cache creation
            // tokens; those fields are added to obtain the full input total.
            return AgentUsageBreakdown(
                uncachedInputTokens: inputTokens,
                cachedInputTokens: cached,
                cacheWriteTokens: written,
                totalInputTokens: inputTokens + cached + written,
                reportedCacheAccounting: reported
            )
        }

        if let miss = cacheMissTokens {
            return AgentUsageBreakdown(
                uncachedInputTokens: miss,
                cachedInputTokens: cached,
                cacheWriteTokens: written,
                totalInputTokens: max(inputTokens, cached + max(0, miss) + written),
                cacheMissInputTokens: miss,
                reportedCacheAccounting: reported
            )
        }

        // OpenAI-compatible and Gemini usage fields expose the combined prompt
        // count, so cache read/write tokens are subsets of `inputTokens`.
        let uncached = max(0, inputTokens - cached - written)
        return AgentUsageBreakdown(
            uncachedInputTokens: uncached,
            cachedInputTokens: cached,
            cacheWriteTokens: written,
            totalInputTokens: max(inputTokens, uncached + cached + written),
            reportedCacheAccounting: reported
        )
    }
}

/// Locally estimated parts of the provider request. Provider usage remains the
/// source of truth for total input tokens; these categories explain the payload
/// and intentionally contain no prompt text or tool arguments.
public struct AgentContextInputComposition: Sendable, Codable, Equatable {
    public let systemPromptTokens: Int
    public let conversationTokens: Int
    public let nativeToolDefinitionTokens: Int
    public let mcpToolDefinitionTokens: Int
    public let nativeToolCallTokens: Int
    public let mcpToolCallTokens: Int
    public let nativeToolResultTokens: Int
    public let mcpToolResultTokens: Int
    public let nativeToolDefinitionCount: Int
    public let mcpToolDefinitionCount: Int
    public let nativeToolCallCount: Int
    public let mcpToolCallCount: Int
    public let nativeToolResultCount: Int
    public let mcpToolResultCount: Int

    public var estimatedTotalTokens: Int {
        systemPromptTokens + conversationTokens
            + nativeToolDefinitionTokens + mcpToolDefinitionTokens
            + nativeToolCallTokens + mcpToolCallTokens
            + nativeToolResultTokens + mcpToolResultTokens
    }

    public init(messages: [AgentMessage], tools: [AgentToolDefinition], api: String? = nil) {
        let messages = api == RouterAPIKind.chatGPT.rawValue
            ? AgentContextCompaction.responsesReplayMessages(messages) : messages
        var systemTokens = 0
        var conversation = 0
        var nativeCalls = 0
        var mcpCalls = 0
        var nativeCallCount = 0
        var mcpCallCount = 0
        var nativeResults = 0
        var mcpResults = 0
        var nativeResultCount = 0
        var mcpResultCount = 0

        for message in messages {
            switch message.role {
            case .system:
                systemTokens += AgentContextCompaction.estimateTokens(message)
            case .tool:
                let tokens = AgentContextCompaction.estimateTokens(message)
                if Self.isMCP(message.name) {
                    mcpResults += tokens
                    mcpResultCount += 1
                } else {
                    nativeResults += tokens
                    nativeResultCount += 1
                }
            case .user, .assistant:
                var withoutCalls = message
                withoutCalls.toolCalls = []
                conversation += AgentContextCompaction.estimateTokens(withoutCalls)
                let calls = message.toolCalls
                let callTokens = max(0,
                    AgentContextCompaction.estimateTokens(message)
                        - AgentContextCompaction.estimateTokens(withoutCalls)
                )
                let mcpCallWeight = calls.filter { Self.isMCP($0.name) }.reduce(0) {
                    $0 + $1.id.utf8.count + $1.name.utf8.count + $1.arguments.utf8.count + 32
                }
                let allCallWeight = calls.reduce(0) {
                    $0 + $1.id.utf8.count + $1.name.utf8.count + $1.arguments.utf8.count + 32
                }
                let mcpTokens = allCallWeight > 0
                    ? Int((Double(callTokens) * Double(mcpCallWeight) / Double(allCallWeight)).rounded())
                    : 0
                mcpCalls += mcpTokens
                nativeCalls += callTokens - mcpTokens
                mcpCallCount += calls.filter { Self.isMCP($0.name) }.count
                nativeCallCount += calls.filter { !Self.isMCP($0.name) }.count
            }
        }

        let nativeDefinitions = tools.filter { !Self.isMCP($0.name) }
        let mcpDefinitions = tools.filter { Self.isMCP($0.name) }
        self.systemPromptTokens = systemTokens
        self.conversationTokens = conversation
        self.nativeToolDefinitionTokens = AgentContextCompaction.estimateTokens(nativeDefinitions)
        self.mcpToolDefinitionTokens = AgentContextCompaction.estimateTokens(mcpDefinitions)
        self.nativeToolCallTokens = nativeCalls
        self.mcpToolCallTokens = mcpCalls
        self.nativeToolResultTokens = nativeResults
        self.mcpToolResultTokens = mcpResults
        self.nativeToolDefinitionCount = nativeDefinitions.count
        self.mcpToolDefinitionCount = mcpDefinitions.count
        self.nativeToolCallCount = nativeCallCount
        self.mcpToolCallCount = mcpCallCount
        self.nativeToolResultCount = nativeResultCount
        self.mcpToolResultCount = mcpResultCount
    }

    private static func isMCP(_ name: String?) -> Bool {
        name?.hasPrefix("mcp__") == true
    }
}

/// Optional pricing supplied by a caller or a future provider-price catalog.
/// The app deliberately does not hard-code volatile provider prices.
public struct AgentTokenPricing: Sendable, Codable, Equatable {
    public var uncachedInputPerMillion: Double
    public var cachedInputPerMillion: Double
    public var cacheWritePerMillion: Double
    public var outputPerMillion: Double

    public init(
        uncachedInputPerMillion: Double,
        cachedInputPerMillion: Double,
        cacheWritePerMillion: Double,
        outputPerMillion: Double
    ) {
        self.uncachedInputPerMillion = max(0, uncachedInputPerMillion)
        self.cachedInputPerMillion = max(0, cachedInputPerMillion)
        self.cacheWritePerMillion = max(0, cacheWritePerMillion)
        self.outputPerMillion = max(0, outputPerMillion)
    }

    public func estimatedCost(usage: AgentUsage, api: String) -> Double {
        let breakdown = usage.breakdown(forAPI: api)
        let inputCost = Double(breakdown.uncachedInputTokens) * uncachedInputPerMillion
            + Double(breakdown.cachedInputTokens) * cachedInputPerMillion
            + Double(breakdown.cacheWriteTokens) * cacheWritePerMillion
        return (inputCost + Double(max(0, usage.outputTokens)) * outputPerMillion) / 1_000_000
    }
}

/// Contains counts and state labels only. It never stores prompt text, message
/// bodies, tool arguments, summaries, or attachments.
public struct AgentContextUsageEvent: Sendable, Codable, Equatable, Identifiable {
    public let id: UUID
    public let timestamp: Date
    public let conversationID: String?
    /// Connects every provider call in a user turn to its visible assistant reply.
    public let turnID: String?
    public let provider: String
    public let api: String
    public let model: String
    public let cacheKey: String?
    public let requestKind: AgentContextRequestKind
    public let strategy: AgentCompactionStrategy
    public let policyID: AgentContextCompactionPolicy.ID
    /// User-selected effort and transport-effective Economy sizing are kept as
    /// separate fields; Economy never rewrites the selected effort label.
    public let selectedEffort: String?
    public let usageMode: AgentUsageMode?
    public let responseStyle: AgentResponseStyle?
    public let retryCount: Int?
    public let retryInputTokens: Int?
    public let retryOutputTokens: Int?
    public let retryReasoningTokens: Int?
    public let reasoningTokens: Int?
    public let effectiveMaxOutputTokens: Int?
    public let effectiveVisibleReserve: Int?
    public let effectiveReasoningReserve: Int?
    public let inputTokens: Int
    public let outputTokens: Int
    public let cachedTokens: Int?
    public let cacheWriteTokens: Int?
    public let cacheMissTokens: Int?
    public let contextClearedInputTokens: Int?
    public let contextClearedToolUses: Int?
    public let uncachedInputTokens: Int
    public let totalInputTokens: Int
    public let contextTokensBefore: Int
    public let contextTokensAfter: Int
    public let contextWindowTokens: Int?
    public let inputComposition: AgentContextInputComposition?
    public let latencyMilliseconds: Int
    /// Nil for buffered (non-SSE) responses and events recorded before this field existed.
    public let firstTokenMilliseconds: Int?
    /// Local work between the start of a step and its request leaving: tool
    /// catalog, compaction check, context save. Nil for events recorded before
    /// this field existed and for requests outside the run loop.
    public let prepareMilliseconds: Int?
    public let nativeCompactionFallback: Bool
    /// Stable classification only; provider error text and prompt content are
    /// intentionally not persisted.
    public let errorKind: String?
    public let cacheTrace: AgentCacheTrace?
    public let providerCacheDiagnostics: AgentProviderCacheDiagnostics?
    public let cacheReuseEvidence: AgentCacheReuseEvidence?
    public var cacheChangeReasons: [String]?
    public var previousRequestGapSeconds: Double?

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        conversationID: String?,
        turnID: String? = nil,
        provider: String,
        api: String,
        model: String,
        cacheKey: String?,
        requestKind: AgentContextRequestKind,
        strategy: AgentCompactionStrategy,
        policyID: AgentContextCompactionPolicy.ID,
        selectedEffort: String? = nil,
        usageMode: AgentUsageMode? = nil,
        responseStyle: AgentResponseStyle? = nil,
        retryCount: Int? = nil,
        retryUsage: AgentUsage? = nil,
        effectiveOutputBudget: AgentOutputBudget? = nil,
        usage: AgentUsage? = nil,
        contextWindowTokens: Int? = nil,
        inputComposition: AgentContextInputComposition? = nil,
        contextTokensBefore: Int,
        contextTokensAfter: Int,
        latencyMilliseconds: Int,
        firstTokenMilliseconds: Int? = nil,
        prepareMilliseconds: Int? = nil,
        nativeCompactionFallback: Bool = false,
        errorKind: String? = nil,
        cacheTrace: AgentCacheTrace? = nil,
        providerCacheDiagnostics: AgentProviderCacheDiagnostics? = nil,
        cacheReuseEvidence: AgentCacheReuseEvidence? = nil
    ) {
        let breakdown = usage?.breakdown(forAPI: api)
        self.id = id
        self.timestamp = timestamp
        self.conversationID = conversationID
        self.turnID = turnID
        self.provider = provider
        self.api = api
        self.model = model
        self.cacheKey = cacheKey
        self.requestKind = requestKind
        self.strategy = strategy
        self.policyID = policyID
        self.selectedEffort = selectedEffort
        self.usageMode = usageMode
        self.responseStyle = responseStyle
        self.retryCount = retryCount.map { max(0, $0) }
        self.retryInputTokens = retryUsage.map { max(0, $0.inputTokens) }
        self.retryOutputTokens = retryUsage.map { max(0, $0.outputTokens) }
        self.retryReasoningTokens = retryUsage?.reasoningTokens.map { max(0, $0) }
        self.reasoningTokens = usage?.reasoningTokens
        self.effectiveMaxOutputTokens = effectiveOutputBudget?.maxOutputTokens
        self.effectiveVisibleReserve = effectiveOutputBudget?.visibleReserve
        self.effectiveReasoningReserve = effectiveOutputBudget?.reasoningReserve
        self.inputTokens = max(0, usage?.inputTokens ?? 0)
        self.outputTokens = max(0, usage?.outputTokens ?? 0)
        self.cachedTokens = usage?.cachedTokens
        self.cacheWriteTokens = usage?.cacheWriteTokens
        self.cacheMissTokens = usage?.cacheMissTokens
        self.contextClearedInputTokens = usage?.contextClearedInputTokens
        self.contextClearedToolUses = usage?.contextClearedToolUses
        self.uncachedInputTokens = breakdown?.uncachedInputTokens ?? 0
        self.totalInputTokens = breakdown?.totalInputTokens ?? 0
        self.contextTokensBefore = max(0, contextTokensBefore)
        self.contextTokensAfter = max(0, contextTokensAfter)
        self.contextWindowTokens = contextWindowTokens.map { max(0, $0) }
        self.inputComposition = inputComposition
        self.latencyMilliseconds = max(0, latencyMilliseconds)
        self.firstTokenMilliseconds = firstTokenMilliseconds.map { max(0, $0) }
        self.prepareMilliseconds = prepareMilliseconds.map { max(0, $0) }
        self.nativeCompactionFallback = nativeCompactionFallback
        self.errorKind = errorKind
        self.cacheTrace = cacheTrace
        self.providerCacheDiagnostics = providerCacheDiagnostics
        self.cacheReuseEvidence = cacheReuseEvidence
    }

    public var measuredCacheHitRate: Double? {
        guard cachedTokens != nil || cacheMissTokens != nil || cacheWriteTokens != nil else { return nil }
        let cached = max(0, cachedTokens ?? 0)
        let denominator = totalInputTokens
        guard denominator > 0 else { return nil }
        return Double(cached) / Double(denominator)
    }
}

/// Aggregate provider-reported cache accounting. Requests without cache fields
/// remain visible as unknown instead of silently turning into fake misses.
public struct AgentContextCacheSummary: Sendable, Codable, Equatable {
    public let requestCount: Int
    public let measuredRequestCount: Int
    public let unknownRequestCount: Int
    public let totalInputTokens: Int
    public let cachedInputTokens: Int
    public let uncachedInputTokens: Int
    public let cacheWriteTokens: Int

    public var measuredInputTokens: Int { totalInputTokens - unknownInputTokens }
    public let unknownInputTokens: Int

    public var cacheHitRate: Double? {
        let denominator = measuredInputTokens
        guard measuredRequestCount > 0, denominator > 0 else { return nil }
        return Double(cachedInputTokens) / Double(denominator)
    }

    public init(events: [AgentContextUsageEvent]) {
        let main = events.filter { $0.requestKind == .main }
        let measured = main.filter { $0.measuredCacheHitRate != nil }
        requestCount = main.count
        measuredRequestCount = measured.count
        unknownRequestCount = requestCount - measuredRequestCount
        totalInputTokens = main.reduce(0) { $0 + $1.totalInputTokens }
        unknownInputTokens = main.filter { $0.measuredCacheHitRate == nil }.reduce(0) { $0 + $1.totalInputTokens }
        cachedInputTokens = measured.reduce(0) { $0 + max(0, $1.cachedTokens ?? 0) }
        uncachedInputTokens = measured.reduce(0) { $0 + $1.uncachedInputTokens }
        cacheWriteTokens = measured.reduce(0) { $0 + max(0, $1.cacheWriteTokens ?? 0) }
    }
}

/// Small bounded local ledger used for tuning. Failed writes are intentionally
/// ignored: telemetry must never fail or delay an agent request.
public final class AgentContextTelemetryStore {
    public let fileURL: URL
    private let fileManager: FileManager
    private let maxEvents: Int

    public init(
        paths: SupportPaths,
        fileManager: FileManager = .default,
        maxEvents: Int = 2_000
    ) {
        self.fileURL = paths.root.appendingPathComponent("context-usage.json")
        self.fileManager = fileManager
        self.maxEvents = max(1, maxEvents)
    }

    public func events() -> [AgentContextUsageEvent] {
        guard let data = try? Data(contentsOf: fileURL),
              let events = try? JSONDecoder().decode([AgentContextUsageEvent].self, from: data) else {
            return []
        }
        return events
    }

    public func append(_ event: AgentContextUsageEvent) {
        var next = events()
        var annotated = event
        if event.requestKind == .main, let conversationID = event.conversationID,
           let previous = next.last(where: { $0.requestKind == .main && $0.conversationID == conversationID }) {
            annotated.previousRequestGapSeconds = max(0,
                (event.cacheTrace?.requestStartedAt ?? event.timestamp)
                .timeIntervalSince(previous.cacheTrace?.requestStartedAt ?? previous.timestamp))
            annotated.cacheChangeReasons = AgentCacheTrace.changes(from: previous, to: annotated)
        } else if event.requestKind == .main {
            annotated.cacheChangeReasons = ["first_observed_request"]
            if event.measuredCacheHitRate == nil { annotated.cacheChangeReasons?.append("cache_usage_not_reported") }
        }
        next.append(annotated)
        if next.count > maxEvents {
            next.removeFirst(next.count - maxEvents)
        }
        guard let data = try? JSONEncoder().encode(next) else { return }
        try? fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: fileURL, options: .atomic)
    }

    public func summary() -> AgentContextCacheSummary {
        AgentContextCacheSummary(events: events())
    }
}

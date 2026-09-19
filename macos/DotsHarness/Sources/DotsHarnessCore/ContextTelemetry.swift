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

    public init(
        uncachedInputTokens: Int,
        cachedInputTokens: Int,
        cacheWriteTokens: Int,
        totalInputTokens: Int,
        cacheMissInputTokens: Int? = nil
    ) {
        self.uncachedInputTokens = max(0, uncachedInputTokens)
        self.cachedInputTokens = max(0, cachedInputTokens)
        self.cacheWriteTokens = max(0, cacheWriteTokens)
        self.totalInputTokens = max(0, totalInputTokens)
        self.cacheMissInputTokens = cacheMissInputTokens.map { max(0, $0) }
    }

    public var cacheAccountingAvailable: Bool {
        cacheMissInputTokens != nil || cachedInputTokens > 0 || cacheWriteTokens > 0
    }

    /// This is a measured ratio, never a claim that an absent provider field was
    /// zero. It is nil when the response did not expose cache accounting.
    public var cacheHitRate: Double? {
        guard cacheAccountingAvailable else { return nil }
        let denominator = cacheMissInputTokens.map { cachedInputTokens + $0 }
            ?? totalInputTokens
        guard denominator > 0 else { return nil }
        return Double(cachedInputTokens) / Double(denominator)
    }
}

public extension AgentUsage {
    func breakdown(forAPI api: String) -> AgentUsageBreakdown {
        let cached = max(0, cachedTokens ?? 0)
        let written = max(0, cacheWriteTokens ?? 0)
        if api == RouterAPIKind.anthropic.rawValue {
            // Anthropic's `input_tokens` excludes cache read and cache creation
            // tokens; those fields are added to obtain the full input total.
            return AgentUsageBreakdown(
                uncachedInputTokens: inputTokens,
                cachedInputTokens: cached,
                cacheWriteTokens: written,
                totalInputTokens: inputTokens + cached + written
            )
        }

        if let miss = cacheMissTokens {
            return AgentUsageBreakdown(
                uncachedInputTokens: miss,
                cachedInputTokens: cached,
                cacheWriteTokens: written,
                totalInputTokens: max(inputTokens, cached + max(0, miss) + written),
                cacheMissInputTokens: miss
            )
        }

        // OpenAI-compatible and Gemini usage fields expose the combined prompt
        // count, so cache read/write tokens are subsets of `inputTokens`.
        let uncached = max(0, inputTokens - cached - written)
        return AgentUsageBreakdown(
            uncachedInputTokens: uncached,
            cachedInputTokens: cached,
            cacheWriteTokens: written,
            totalInputTokens: max(inputTokens, uncached + cached + written)
        )
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
    public let provider: String
    public let api: String
    public let model: String
    public let cacheKey: String?
    public let requestKind: AgentContextRequestKind
    public let strategy: AgentCompactionStrategy
    public let policyID: AgentContextCompactionPolicy.ID
    public let inputTokens: Int
    public let outputTokens: Int
    public let cachedTokens: Int?
    public let cacheWriteTokens: Int?
    public let cacheMissTokens: Int?
    public let uncachedInputTokens: Int
    public let totalInputTokens: Int
    public let contextTokensBefore: Int
    public let contextTokensAfter: Int
    public let latencyMilliseconds: Int
    public let nativeCompactionFallback: Bool
    /// Stable classification only; provider error text and prompt content are
    /// intentionally not persisted.
    public let errorKind: String?

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        conversationID: String?,
        provider: String,
        api: String,
        model: String,
        cacheKey: String?,
        requestKind: AgentContextRequestKind,
        strategy: AgentCompactionStrategy,
        policyID: AgentContextCompactionPolicy.ID,
        usage: AgentUsage? = nil,
        contextTokensBefore: Int,
        contextTokensAfter: Int,
        latencyMilliseconds: Int,
        nativeCompactionFallback: Bool = false,
        errorKind: String? = nil
    ) {
        let breakdown = usage?.breakdown(forAPI: api)
        self.id = id
        self.timestamp = timestamp
        self.conversationID = conversationID
        self.provider = provider
        self.api = api
        self.model = model
        self.cacheKey = cacheKey
        self.requestKind = requestKind
        self.strategy = strategy
        self.policyID = policyID
        self.inputTokens = max(0, usage?.inputTokens ?? 0)
        self.outputTokens = max(0, usage?.outputTokens ?? 0)
        self.cachedTokens = usage?.cachedTokens
        self.cacheWriteTokens = usage?.cacheWriteTokens
        self.cacheMissTokens = usage?.cacheMissTokens
        self.uncachedInputTokens = breakdown?.uncachedInputTokens ?? 0
        self.totalInputTokens = breakdown?.totalInputTokens ?? 0
        self.contextTokensBefore = max(0, contextTokensBefore)
        self.contextTokensAfter = max(0, contextTokensAfter)
        self.latencyMilliseconds = max(0, latencyMilliseconds)
        self.nativeCompactionFallback = nativeCompactionFallback
        self.errorKind = errorKind
    }

    public var measuredCacheHitRate: Double? {
        guard cachedTokens != nil || cacheMissTokens != nil || cacheWriteTokens != nil else { return nil }
        let cached = max(0, cachedTokens ?? 0)
        let denominator = cacheMissTokens.map { cached + max(0, $0) } ?? totalInputTokens
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

    public var cacheHitRate: Double? {
        let denominator = cachedInputTokens + uncachedInputTokens
        guard measuredRequestCount > 0, denominator > 0 else { return nil }
        return Double(cachedInputTokens) / Double(denominator)
    }

    public init(events: [AgentContextUsageEvent]) {
        let main = events.filter { $0.requestKind == .main }
        requestCount = main.count
        measuredRequestCount = main.filter { $0.measuredCacheHitRate != nil }.count
        unknownRequestCount = requestCount - measuredRequestCount
        totalInputTokens = main.reduce(0) { $0 + $1.totalInputTokens }
        cachedInputTokens = main.reduce(0) { $0 + max(0, $1.cachedTokens ?? 0) }
        uncachedInputTokens = main.reduce(0) { $0 + $1.uncachedInputTokens }
        cacheWriteTokens = main.reduce(0) { $0 + max(0, $1.cacheWriteTokens ?? 0) }
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
        next.append(event)
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

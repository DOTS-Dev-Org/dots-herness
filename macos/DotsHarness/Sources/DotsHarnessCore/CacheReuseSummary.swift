// Copyright (c) 2026 DOTS
import Foundation

/// Token-weighted, exact reuse is distinct from cached / all input. Unknown
/// continuations contribute to coverage, never a fabricated hit or miss.
public struct AgentCacheReuseSummary: Sendable, Equatable {
    public let measuredRequests: Int
    public let candidateRequests: Int
    public let unknownRequests: Int
    public let eligibleTokens: Int
    public let reusedTokens: Int
    public let coldRequests: Int
    public let expiredRequests: Int
    public let changedRequests: Int
    public let freshInputTokens: Int
    public let averageLatencyMilliseconds: Int?
    /// Averaged over the requests that reported them; nil when none did.
    public let averageFirstTokenMilliseconds: Int?
    public let averagePrepareMilliseconds: Int?
    public let lostTokensByReason: [String: Int]

    public var reuseRate: Double? {
        eligibleTokens > 0 ? Double(reusedTokens) / Double(eligibleTokens) : nil
    }
    public var coverage: Double? {
        candidateRequests > 0 ? Double(measuredRequests) / Double(candidateRequests) : nil
    }
    public var targetMet: Bool {
        (reuseRate ?? 0) >= 0.999 && (coverage ?? 0) >= 0.95
    }

    /// By default, keep provider diagnostics bounded to the last 100 candidates.
    /// Pass nil when the supplied events already represent a single conversation
    /// and the summary should cover its complete history.
    public init(events: [AgentContextUsageEvent], limit: Int? = 100) {
        let main = events.filter { $0.requestKind == .main }.sorted { $0.timestamp < $1.timestamp }
        coldRequests = main.filter { $0.cacheReuseEvidence?.classification == "cold" }.count
        expiredRequests = main.filter { $0.cacheReuseEvidence?.classification == "expired" }.count
        changedRequests = main.filter { $0.cacheReuseEvidence?.classification == "changed" }.count
        let allCandidates = main.filter {
            !["cold", "expired", "changed"].contains($0.cacheReuseEvidence?.classification ?? "inconclusive")
        }
        let candidates = limit.map { Array(allCandidates.suffix(max(1, $0))) } ?? allCandidates
        let measured = candidates.filter { event in
            guard let evidence = event.cacheReuseEvidence, evidence.classification == "eligible",
                  let eligible = evidence.eligibleTokens, let reused = evidence.reusedTokens,
                  eligible > 0, reused >= 0, reused <= eligible else { return false }
            return true
        }
        candidateRequests = candidates.count
        measuredRequests = measured.count
        unknownRequests = candidateRequests - measuredRequests
        eligibleTokens = measured.reduce(0) { $0 + ($1.cacheReuseEvidence?.eligibleTokens ?? 0) }
        reusedTokens = measured.reduce(0) { $0 + ($1.cacheReuseEvidence?.reusedTokens ?? 0) }
        freshInputTokens = measured.reduce(0) { total, event in
            total + max(0, event.totalInputTokens - (event.cacheReuseEvidence?.eligibleTokens ?? 0))
        }
        averageLatencyMilliseconds = candidates.isEmpty ? nil : candidates.reduce(0) { $0 + $1.latencyMilliseconds } / candidates.count
        func average(_ values: [Int]) -> Int? { values.isEmpty ? nil : values.reduce(0, +) / values.count }
        averageFirstTokenMilliseconds = average(candidates.compactMap(\.firstTokenMilliseconds))
        averagePrepareMilliseconds = average(candidates.compactMap(\.prepareMilliseconds))
        var losses: [String: Int] = [:]
        for event in measured {
            guard let evidence = event.cacheReuseEvidence else { continue }
            let lost = (evidence.eligibleTokens ?? 0) - (evidence.reusedTokens ?? 0)
            if lost > 0 { losses[evidence.reason ?? "cache_miss", default: 0] += lost }
        }
        lostTokensByReason = losses
    }

    /// Each account/endpoint/model keeps its own last 100 candidate requests.
    /// Pooling different routes would conceal a poorly performing provider.
    public static func byRoute(events: [AgentContextUsageEvent]) -> [String: AgentCacheReuseSummary] {
        let groups = Dictionary(grouping: events.filter { $0.requestKind == .main }) {
            [$0.provider, $0.api, $0.model, $0.cacheTrace?.accountFingerprint ?? "unknown",
             $0.cacheTrace?.endpointFingerprint ?? "unknown"].joined(separator: "|")
        }
        return groups.mapValues { AgentCacheReuseSummary(events: $0) }
    }
}

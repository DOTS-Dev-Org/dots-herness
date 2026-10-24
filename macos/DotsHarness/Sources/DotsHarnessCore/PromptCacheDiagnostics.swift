// Copyright (c) 2026 DOTS
// Cache state contains fingerprints and counters, never prompts or credentials.
import Foundation
import CryptoKit
import HarnessPluginKit

public enum AgentPromptCacheTTL: String, Sendable, Codable {
    case fiveMinutes = "5m"
    case oneHour = "1h"
    public var seconds: Int { self == .oneHour ? 3600 : 300 }
}

public struct AgentProviderCacheDiagnostics: Sendable, Codable, Equatable {
    public let type: String
    public let reason: String?
    public let missedTokens: Int?
    public let reusableTokens: Int?

    init?(value: JSONValue?) {
        guard let rawType = value?["type"]?.string else { return nil }
        type = ["cache_hit", "cache_miss", "unavailable", "comparison_response_not_found"].contains(rawType)
            ? rawType : "unavailable"
        let allowed = ["model_changed", "prompt_cache_key_changed", "tools_changed", "instructions_changed",
            "input_changed", "reasoning_changed", "reasoning_effort_changed", "service_tier_changed",
            "cache_expired", "cache_evicted", "cache_not_found", "settings_changed", "prefix_mismatch",
            "text_format_changed", "verbosity_changed", "context_compacted"]
        reason = value?["reason"]?.string.map { allowed.contains($0) ? $0 : "other" }
        // These provider diagnostics may be byte-based estimates. They explain
        // misses but are never usage counters or the exact reuse denominator.
        missedTokens = value?["cache_missed_tokens"]?.int.flatMap { $0 >= 0 ? $0 : nil }
        reusableTokens = value?["comparison_reusable_tokens"]?.int.flatMap { $0 >= 0 ? $0 : nil }
    }

    init?(anthropicValue value: JSONValue?) {
        guard let value else { return nil }
        let allowed = ["tools_changed", "system_changed", "messages_changed", "model_changed",
            "thinking_changed", "tool_choice_changed", "images_changed", "speed_changed",
            "cache_expired", "cache_evicted", "cache_not_found", "settings_changed"]
        let miss = value["cache_miss_reason"]
        if let raw = miss?["type"]?.string ?? miss?.string {
            type = ["previous_message_not_found", "unavailable"].contains(raw) ? "unavailable" : "cache_miss"
            reason = allowed.contains(raw) ? raw : "other"
        } else {
            // null diagnostics (first call) and a pending null reason are not
            // proof that all eligible input was read from a cache.
            type = "unavailable"
            reason = nil
        }
        missedTokens = (miss?["cache_missed_input_tokens"]?.int ?? value["cache_missed_input_tokens"]?.int)
            .flatMap { $0 >= 0 ? $0 : nil }
        reusableTokens = nil
    }
}

/// One exact cacheable prefix of the actual transport request. No prompt text,
/// schema, arguments, credentials or serialized request is persisted here.
public struct AgentPromptCacheBoundary: Sendable, Codable, Equatable {
    public var baselineEventID: String?
    public var prefixFingerprint: String
    public var settingsFingerprint: String
    public var scopeFingerprint: String
    public var requestStartedAt: Date
    public var effectiveTTLSeconds: Int?
    public var providerPrefixTokens: Int?
    public var messageCount: Int
    public var contentBlockCount: Int?
    public var boundaryKind: String
    public var evidenceSource: String
    public var accepted: Bool
    /// Opaque provider ID used only for the provider's normal-request diagnostic.
    public var providerResponseID: String?

    public init(baselineEventID: String? = nil, prefixFingerprint: String, settingsFingerprint: String,
                scopeFingerprint: String, requestStartedAt: Date, effectiveTTLSeconds: Int?,
                providerPrefixTokens: Int?, messageCount: Int, contentBlockCount: Int?,
                boundaryKind: String, evidenceSource: String, accepted: Bool,
                providerResponseID: String? = nil) {
        self.baselineEventID = baselineEventID
        self.prefixFingerprint = prefixFingerprint
        self.settingsFingerprint = settingsFingerprint
        self.scopeFingerprint = scopeFingerprint
        self.requestStartedAt = requestStartedAt
        self.effectiveTTLSeconds = effectiveTTLSeconds
        self.providerPrefixTokens = providerPrefixTokens
        self.messageCount = messageCount
        self.contentBlockCount = contentBlockCount
        self.boundaryKind = boundaryKind
        self.evidenceSource = evidenceSource
        self.accepted = accepted
        self.providerResponseID = providerResponseID
    }
}

public struct AgentCacheReuseEvidence: Sendable, Codable, Equatable {
    public var baselineEventID: String?
    public var prefixFingerprint: String
    public var settingsFingerprint: String
    /// "eligible", "cold", "expired", "changed", or "inconclusive". A genuine eligible miss
    /// remains measured with zero reused tokens instead of being filtered out.
    public var classification: String
    public var reason: String?
    public var evidenceSource: String
    public var eligibleTokens: Int?
    public var reusedTokens: Int?
    public var effectiveTTLSeconds: Int?

    public init(baselineEventID: String? = nil, prefixFingerprint: String, settingsFingerprint: String,
                classification: String, reason: String? = nil, evidenceSource: String,
                eligibleTokens: Int? = nil, reusedTokens: Int? = nil, effectiveTTLSeconds: Int? = nil) {
        self.baselineEventID = baselineEventID
        self.prefixFingerprint = prefixFingerprint
        self.settingsFingerprint = settingsFingerprint
        self.classification = classification
        self.reason = reason
        self.evidenceSource = evidenceSource
        self.eligibleTokens = eligibleTokens
        self.reusedTokens = reusedTokens
        self.effectiveTTLSeconds = effectiveTTLSeconds
    }
}

/// Captured from makeBody's final request, after normalization, OAuth cloaking,
/// budgets and optional-feature fallbacks. Local token estimates are not used.
struct AgentPromptCacheRequestSnapshot {
    let body: [String: Any]
    let configuration: AgentConfiguration
    let requestStartedAt: Date
    let prefixFingerprint: String
    let settingsFingerprint: String
    let scopeFingerprint: String
    let messageCount: Int
    let contentBlockCount: Int?
    let boundaryKind: String
    let effectiveTTLSeconds: Int?

    init(body: [String: Any], configuration: AgentConfiguration, requestStartedAt: Date) {
        self.body = body
        self.configuration = configuration
        self.requestStartedAt = requestStartedAt
        let anthropic = configuration.api == RouterAPIKind.anthropic.rawValue
        let items = (body[anthropic ? "messages" : "input"] as? [[String: Any]]) ?? []
        let index: Int?
        if anthropic {
            index = items.indices.reversed().first { i in
                Self.cacheableContentBlock(in: items[i]) != nil
            }
        } else {
            index = items.indices.reversed().first { i in
                items[i]["role"] as? String == "user"
                    || items[i]["type"] as? String == "function_call_output"
            }
        }
        messageCount = index.map { $0 + 1 } ?? 0
        contentBlockCount = anthropic ? index.flatMap { Self.cacheableContentBlock(in: items[$0]).map { $0 + 1 } } : nil
        boundaryKind = anthropic ? "anthropic_terminal" : "responses_implicit_terminal"
        prefixFingerprint = Self.prefixFingerprint(body: body, api: configuration.api,
            messageCount: messageCount, contentBlockCount: contentBlockCount) ?? ""
        var settings = body
        // Output ceilings are not part of the cached prompt; the economy budget
        // moves them every turn and must not look like a settings change.
        for key in ["tools", "system", "messages", "input", "instructions", "prompt_cache_key",
                    "prompt_cache_options", "diagnostics", "stream", "store",
                    "max_tokens", "max_output_tokens"] { settings.removeValue(forKey: key) }
        // Account, endpoint, model and auth type are scope; actual provider body
        // settings (including thinking/output configuration) are hashed intact.
        settingsFingerprint = Self.fingerprint(settings)
        scopeFingerprint = AgentCacheTrace.fingerprint(configuration.api + "|" + configuration.baseURL.lowercased()
            + "|" + configuration.model + "|" + (configuration.accountID ?? configuration.sessionAccountID ?? "unbound")
            + "|" + configuration.authType)
        effectiveTTLSeconds = anthropic ? configuration.anthropicCacheTTL.seconds
            : (AgentPromptCacheComparisons.shared.isPublicResponses(configuration) ? (AgentPromptCacheComparisons.shared.supportsImplicitOptions(configuration) ? 1800 : nil)
                : configuration.verifiedPromptCacheTTLSeconds)
    }

    static func fingerprint(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: .sortedKeys) else { return "" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func cacheableContentBlock(in message: [String: Any]) -> Int? {
        if let text = message["content"] as? String { return text.isEmpty ? nil : 0 }
        guard let blocks = message["content"] as? [[String: Any]] else { return nil }
        return blocks.indices.reversed().first { i in
            !["thinking", "redacted_thinking"].contains(blocks[i]["type"] as? String ?? "")
        }
    }

    private static func cleanBlock(_ block: [String: Any]) -> [String: Any] {
        var copy = block
        copy.removeValue(forKey: "cache_control")
        copy.removeValue(forKey: "prompt_cache_breakpoint")
        return copy
    }

    static func prefixFingerprint(body: [String: Any], api: String,
                                  messageCount: Int, contentBlockCount: Int?) -> String? {
        let anthropic = api == RouterAPIKind.anthropic.rawValue
        let key = anthropic ? "messages" : "input"
        guard let all = body[key] as? [[String: Any]], messageCount > 0, messageCount <= all.count else { return nil }
        var items = Array(all.prefix(messageCount)).map { original -> [String: Any] in
            var item = cleanBlock(original)
            for contentKey in ["content", "output"] {
                if let blocks = item[contentKey] as? [[String: Any]] {
                    item[contentKey] = blocks.map(cleanBlock)
                }
            }
            return item
        }
        if let count = contentBlockCount {
            guard var last = items.last else { return nil }
            if let blocks = last["content"] as? [[String: Any]] {
                guard count > 0, count <= blocks.count else { return nil }
                last["content"] = Array(blocks.prefix(count))
            } else if !(last["content"] is String && count == 1) { return nil }
            items[items.count - 1] = last
        }
        var prefix: [String: Any] = [key: items]
        // Remove generated markers only at actual provider block locations.
        // A user schema property named cache_control remains part of the hash.
        if let tools = body["tools"] as? [[String: Any]] { prefix["tools"] = tools.map(cleanBlock) }
        if let blocks = body["system"] as? [[String: Any]] { prefix["system"] = blocks.map(cleanBlock) }
        else if let system = body["system"] { prefix["system"] = system }
        if let instructions = body["instructions"] { prefix["instructions"] = instructions }
        return fingerprint(prefix)
    }

    func unchanged(_ prior: AgentPromptCacheBoundary) -> Bool {
        prior.scopeFingerprint == scopeFingerprint && prior.settingsFingerprint == settingsFingerprint
            && Self.prefixFingerprint(body: body, api: configuration.api, messageCount: prior.messageCount,
                                      contentBlockCount: prior.contentBlockCount) == prior.prefixFingerprint
    }

    func evaluate(response: AgentResponse, prior: AgentPromptCacheBoundary?)
        -> (AgentCacheReuseEvidence, AgentPromptCacheBoundary?) {
        let anthropic = configuration.api == RouterAPIKind.anthropic.rawValue
        let responses = configuration.api == RouterAPIKind.chatGPT.rawValue
        let usage = response.usage
        let readValid = usage.map { u in
            u.inputTokens >= 0 && (u.cachedTokens.map { $0 >= 0 } ?? false)
                && (anthropic || u.cachedTokens! <= u.inputTokens)
        } ?? false
        let countersValid = usage.map { u in
            u.inputTokens >= 0 && (u.cachedTokens.map { $0 >= 0 } ?? false)
                && (u.cacheWriteTokens.map { $0 >= 0 } ?? false)
                && !u.cachedTokens!.addingReportingOverflow(u.cacheWriteTokens!).overflow
                && (anthropic || (u.cachedTokens! <= u.inputTokens
                    && u.cacheWriteTokens! <= u.inputTokens - u.cachedTokens!))
        } ?? false
        let supported = anthropic || (responses && AgentPromptCacheComparisons.supportedModel(configuration.model))
        let inputItems = (body["input"] as? [[String: Any]])?.count
        let source = anthropic ? "anthropic_terminal_usage"
            : "responses_terminal_usage"
        let prefixTokens = countersValid ? usage.map { $0.cachedTokens! + $0.cacheWriteTokens! }
            : nil
        let publicContract = AgentPromptCacheComparisons.shared.isPublicResponses(configuration)
            && body["prompt_cache_options"] as? [String: Any] != nil
            && ((body["prompt_cache_options"] as? [String: Any])?["mode"] as? String) == "implicit"
        // A gateway does not inherit the public API breakpoint contract. It can
        // prove a whole-input boundary only when exact reported read+write
        // equals the entire input count, including any server-owned prefix.
        let wholeInputProof = !anthropic && countersValid && prefixTokens == usage?.inputTokens
            && messageCount == inputItems
        let terminalMarked: Bool = {
            guard anthropic, messageCount > 0, let count = contentBlockCount,
                  let messages = body["messages"] as? [[String: Any]], messages.indices.contains(messageCount - 1),
                  let blocks = messages[messageCount - 1]["content"] as? [[String: Any]], blocks.indices.contains(count - 1),
                  let marker = blocks[count - 1]["cache_control"] as? [String: Any] else { return false }
            return marker["type"] as? String == "ephemeral"
        }()
        let accountKnown = !(configuration.accountID ?? configuration.sessionAccountID ?? "").isEmpty
        let extentShrank = prior.map { previous in
            previous.accepted && unchanged(previous)
                && (prefixTokens ?? 0) < (previous.providerPrefixTokens ?? 0)
        } ?? false
        let accepted = supported && countersValid && messageCount > 0 && (prefixTokens ?? 0) > 0
            && accountKnown && ((anthropic && terminalMarked) || publicContract || wholeInputProof)
            && !extentShrank
            && !response.nativeCompactionApplied
        let candidate: AgentPromptCacheBoundary? = messageCount > 0 ? AgentPromptCacheBoundary(
            prefixFingerprint: prefixFingerprint, settingsFingerprint: settingsFingerprint,
            scopeFingerprint: scopeFingerprint, requestStartedAt: requestStartedAt,
            effectiveTTLSeconds: effectiveTTLSeconds, providerPrefixTokens: accepted ? prefixTokens : nil,
            messageCount: messageCount, contentBlockCount: contentBlockCount, boundaryKind: boundaryKind,
            evidenceSource: accepted ? source : "unverified_boundary", accepted: accepted,
            providerResponseID: response.providerResponseID) : nil
        func result(_ classification: String, _ reason: String?, eligible: Int? = nil, reused: Int? = nil)
            -> (AgentCacheReuseEvidence, AgentPromptCacheBoundary?) {
            (AgentCacheReuseEvidence(baselineEventID: prior?.baselineEventID,
                prefixFingerprint: prefixFingerprint, settingsFingerprint: settingsFingerprint,
                classification: classification, reason: reason, evidenceSource: source,
                eligibleTokens: eligible, reusedTokens: reused, effectiveTTLSeconds: effectiveTTLSeconds), candidate)
        }
        guard supported else { return result("inconclusive", "exact_counter_contract_unverified") }
        guard accountKnown else { return result("inconclusive", "account_identity_unavailable") }
        guard let prior else { return result("cold", "first_observed_prefix") }
        guard prior.scopeFingerprint == scopeFingerprint else { return result("changed", "route_changed") }
        guard prior.settingsFingerprint == settingsFingerprint else { return result("changed", "settings_changed") }
        guard prior.accepted, let p = prior.providerPrefixTokens, p > 0 else {
            return result("inconclusive", "previous_boundary_unverified")
        }
        guard let ttl = prior.effectiveTTLSeconds else { return result("inconclusive", "ttl_unverified", eligible: p) }
        let gap = requestStartedAt.timeIntervalSince(prior.requestStartedAt)
        guard gap >= 0 else { return result("inconclusive", "clock_changed", eligible: p) }
        guard gap < Double(ttl) else { return result("expired", "outside_ttl") }
        if !unchanged(prior) {
            // The caller passes a boundary from its intended cache epoch. A
            // preventable wire rewrite inside that epoch must count as a loss,
            // not disappear from the denominator. Unrelated cache reads cannot
            // safely be attributed to this previous prefix.
            return result("eligible", "prefix_changed", eligible: p, reused: 0)
        }
        guard anthropic ? countersValid : readValid else {
            return result("inconclusive", "usage_counters_unavailable_or_invalid", eligible: p)
        }
        guard !response.nativeCompactionApplied else { return result("inconclusive", "native_compaction", eligible: p) }
        // Rewrites/evictions are genuine losses in an otherwise eligible call.
        // Diagnostic estimates never change these actual provider counters.
        return result("eligible", nil, eligible: p, reused: min(p, usage!.cachedTokens!))
    }
}

public struct AgentCacheTrace: Sendable, Codable, Equatable {
    public let toolFingerprint: String
    public let policyRevision: Int
    public let contextSegment: Int
    public let ttlSeconds: Int?
    public let requestStartedAt: Date
    public let fast: Bool
    public let accountFingerprint: String?
    public let endpointFingerprint: String?
    /// Served from this machine (loopback): a RAM prompt cache with no
    /// lifetime and no cost, lost to another chat or a server unload.
    public let local: Bool?

    public init(toolFingerprint: String, policyRevision: Int, contextSegment: Int,
                ttlSeconds: Int?, requestStartedAt: Date, fast: Bool,
                accountFingerprint: String? = nil, endpointFingerprint: String? = nil, local: Bool? = nil) {
        self.toolFingerprint = toolFingerprint
        self.policyRevision = policyRevision
        self.contextSegment = contextSegment
        self.ttlSeconds = ttlSeconds
        self.requestStartedAt = requestStartedAt
        self.fast = fast
        self.accountFingerprint = accountFingerprint
        self.endpointFingerprint = endpointFingerprint
        self.local = local
    }

    static func isLoopback(_ baseURL: String) -> Bool {
        ["127.0.0.1", "localhost", "::1", "[::1]"].contains(URLComponents(string: baseURL)?.host?.lowercased() ?? "")
    }

    static func fingerprint(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    static func changes(from old: AgentContextUsageEvent, to new: AgentContextUsageEvent) -> [String] {
        var reasons: [String] = []
        if old.provider != new.provider || old.api != new.api { reasons.append("provider_changed") }
        if old.model != new.model { reasons.append("model_changed") }
        if old.cacheKey != new.cacheKey { reasons.append("cache_key_changed") }
        if old.selectedEffort != new.selectedEffort { reasons.append("effort_changed") }
        if let before = old.cacheTrace, let after = new.cacheTrace {
            if before.toolFingerprint != after.toolFingerprint { reasons.append("tools_changed") }
            if before.policyRevision != after.policyRevision { reasons.append("policy_changed") }
            if before.contextSegment != after.contextSegment { reasons.append("context_segment_changed") }
            if before.fast != after.fast { reasons.append("speed_changed") }
            if let oldAccount = before.accountFingerprint, let newAccount = after.accountFingerprint,
               oldAccount != newAccount { reasons.append("account_changed") }
            if let oldEndpoint = before.endpointFingerprint, let newEndpoint = after.endpointFingerprint,
               oldEndpoint != newEndpoint { reasons.append("endpoint_changed") }
            if before.ttlSeconds != after.ttlSeconds { reasons.append("ttl_changed") }
            // An elapsed TTL is a suspicion, not proof of a provider cache miss.
            if let ttl = before.ttlSeconds,
               after.requestStartedAt.timeIntervalSince(before.requestStartedAt) >= Double(ttl) {
                reasons.append("idle_beyond_requested_ttl")
            }
        }
        if new.measuredCacheHitRate == nil { reasons.append("cache_usage_not_reported") }
        return reasons
    }
}

/// Automatic recovery may send a large conversation again. Keep it automatic only
/// while recent provider usage supports a warm, working cache; an expired or lost
/// cache leaves continuation in the user's hands.
public enum AgentCacheResumePolicy {
    private static let minimumTrackedPrefixTokens = 8_192

    public static func isWarm(
        conversationID: String,
        events: [AgentContextUsageEvent],
        now: Date = Date()
    ) -> Bool {
        let mainEvents = events
            .filter { $0.conversationID == conversationID && $0.requestKind == .main && $0.errorKind == nil }
            .sorted { $0.timestamp < $1.timestamp }
        guard let latest = mainEvents.last else { return false }

        let previous = mainEvents.filter { $0.timestamp < latest.timestamp }
        guard droppedCachePrefixTokens(latest, previous: previous) == nil else { return false }
        // A local server exposes no reliable retention clock; its cache can be
        // evicted or cleared while the app is closed, so recovery stays manual.
        guard latest.cacheTrace?.local != true else { return false }
        if let evidence = latest.cacheReuseEvidence,
           evidence.classification == "eligible",
           let eligible = evidence.eligibleTokens,
           let reused = evidence.reusedTokens,
           eligible >= minimumTrackedPrefixTokens,
           Double(reused) <= Double(eligible) * 0.05 {
            return false
        }

        // A cache write only means a prefix was stored; it does not prove a hit.
        // Require a recent, measured read before resuming an interrupted turn.
        let confirmedHitTokens = max(latest.cachedTokens ?? 0, latest.cacheReuseEvidence?.reusedTokens ?? 0)
        guard confirmedHitTokens >= minimumTrackedPrefixTokens else { return false }

        let ttl: Double
        if let ttlSeconds = latest.cacheTrace?.ttlSeconds {
            guard ttlSeconds > 0 else { return false }
            ttl = Double(ttlSeconds)
        } else {
            // Providers without a reported retention get the conservative one-hour ceiling.
            ttl = 3_600
        }
        let startedAt = latest.cacheTrace?.requestStartedAt ?? latest.timestamp
        let age = now.timeIntervalSince(startedAt)
        return age >= 0 && age < min(ttl, 3_600)
    }

    /// A large prefix that was cached earlier came back almost entirely uncached.
    /// A known rewrite is intentional; it is handled as a new cache epoch.
    public static func droppedCachePrefixTokens(
        _ latest: AgentContextUsageEvent,
        previous: [AgentContextUsageEvent]
    ) -> Int? {
        guard let cached = latest.cachedTokens,
              latest.totalInputTokens >= minimumTrackedPrefixTokens,
              Double(cached) <= Double(latest.totalInputTokens) * 0.05,
              latest.cacheReuseEvidence?.classification != "changed",
              previous.contains(where: { ($0.cachedTokens ?? 0) >= minimumTrackedPrefixTokens })
        else { return nil }
        return latest.totalInputTokens
    }

    public static func localCachePrefixLost(
        _ latest: AgentContextUsageEvent,
        conversationID: String,
        events: [AgentContextUsageEvent]
    ) -> Int? {
        guard latest.totalInputTokens >= minimumTrackedPrefixTokens,
              let endpoint = latest.cacheTrace?.endpointFingerprint,
              events.contains(where: {
                  $0.timestamp > latest.timestamp && $0.cacheTrace?.endpointFingerprint == endpoint
                      && ($0.conversationID != conversationID || $0.requestKind != .main)
              })
        else { return nil }
        return latest.totalInputTokens
    }
}

/// Comparisons are process-local and isolated by endpoint/API/account/conversation.
/// Unsupported optional diagnostics must never stop the user's normal request.
final class AgentPromptCacheComparisons: @unchecked Sendable {
    static let shared = AgentPromptCacheComparisons()
    private let lock = NSLock()
    private var responses: [String: String] = [:]
    private var unsupported: Set<String> = []
    private var shortTTLEndpoints: Set<String> = []
    private var boundaries: [String: AgentPromptCacheBoundary] = [:]
    private var unsupportedBreakpoints: Set<String> = []
    private var unsupportedImplicitOptions: Set<String> = []
    private var unsupportedAnthropicDiagnostics: Set<String> = []

    func isPublicResponses(_ config: AgentConfiguration) -> Bool {
        config.api == RouterAPIKind.chatGPT.rawValue
            && URLComponents(string: config.baseURL)?.host?.lowercased() == "api.openai.com"
            && Self.supportedModel(config.model)
    }
    func supportsExplicitBreakpoint(_ config: AgentConfiguration) -> Bool {
        guard isPublicResponses(config) else { return false }
        lock.lock(); defer { lock.unlock() }
        return !unsupportedBreakpoints.contains(config.baseURL + "|" + config.model)
    }
    func rejectExplicitBreakpoint(_ config: AgentConfiguration) {
        lock.lock(); defer { lock.unlock() }
        unsupportedBreakpoints.insert(config.baseURL + "|" + config.model)
    }
    func supportsImplicitOptions(_ config: AgentConfiguration) -> Bool {
        guard isPublicResponses(config) else { return false }
        lock.lock(); defer { lock.unlock() }
        return !unsupportedImplicitOptions.contains(config.baseURL + "|" + config.model)
    }
    func rejectImplicitOptions(_ config: AgentConfiguration) {
        lock.lock(); defer { lock.unlock() }
        unsupportedImplicitOptions.insert(config.baseURL + "|" + config.model)
    }
    func supportsAnthropicDiagnostics(_ config: AgentConfiguration) -> Bool {
        guard config.api == RouterAPIKind.anthropic.rawValue else { return false }
        lock.lock(); defer { lock.unlock() }
        return !unsupportedAnthropicDiagnostics.contains(config.baseURL + "|" + config.model)
    }
    func rejectAnthropicDiagnostics(_ config: AgentConfiguration) {
        lock.lock(); defer { lock.unlock() }
        unsupportedAnthropicDiagnostics.insert(config.baseURL + "|" + config.model)
    }

    func previousBoundary(_ config: AgentConfiguration, key: String?) -> AgentPromptCacheBoundary? {
        guard let key else { return nil }
        lock.lock(); defer { lock.unlock() }
        return boundaries[route(config, key) + "|" + config.model]
    }
    func recordBoundary(_ config: AgentConfiguration, key: String?, boundary: AgentPromptCacheBoundary?) {
        guard let key, let boundary, boundary.accepted else { return }
        lock.lock(); defer { lock.unlock() }
        if boundaries.count >= 2000 { boundaries.removeAll() }
        boundaries[route(config, key) + "|" + config.model] = boundary
    }

    func supportsLongTTL(_ config: AgentConfiguration) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return !shortTTLEndpoints.contains(config.baseURL + "|" + config.model)
    }
    func rejectLongTTL(_ config: AgentConfiguration) {
        lock.lock(); defer { lock.unlock() }
        shortTTLEndpoints.insert(config.baseURL + "|" + config.model)
    }

    private func route(_ config: AgentConfiguration, _ key: String) -> String {
        config.baseURL + "|" + config.api + "|" + (config.accountID ?? "unbound") + "|" + key
    }
    func previous(_ config: AgentConfiguration, key: String?) -> String? {
        guard let key else { return nil }
        lock.lock(); defer { lock.unlock() }
        return responses[route(config, key)]
    }
    func record(_ config: AgentConfiguration, key: String?, id: String?) {
        guard let key, let id else { return }
        lock.lock(); defer { lock.unlock() }
        if responses.count >= 2000 { responses.removeAll() }
        responses[route(config, key)] = id
    }
    func supports(_ config: AgentConfiguration) -> Bool {
        // `comparison_response_id` and the surrounding prompt-cache options
        // are public OpenAI Responses diagnostics. The ChatGPT subscription
        // gateway uses the same transport shape but has rejected these fields
        // in live requests; treating every ChatGPT-shaped route as compatible
        // causes a needless 400/retry on the next turn.
        guard isPublicResponses(config) else { return false }
        lock.lock(); defer { lock.unlock() }
        return !unsupported.contains(config.baseURL + "|" + config.model)
    }
    func reject(_ config: AgentConfiguration) {
        lock.lock(); defer { lock.unlock() }
        unsupported.insert(config.baseURL + "|" + config.model)
    }
    static func supportedModel(_ model: String) -> Bool {
        let id = model.lowercased()
        if id.hasPrefix("gpt-6") { return true }
        guard id.hasPrefix("gpt-5."), let minor = Int(id.dropFirst(6).prefix(while: { $0.isNumber })) else { return false }
        return minor >= 6
    }
}

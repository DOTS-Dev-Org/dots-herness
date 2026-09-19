// Copyright (c) 2026 DOTS
// Live Claude subscription rate-limit usage. Fetched on demand, never stored.

import Foundation

public struct ClaudeUsageWindow: Equatable, Sendable {
    public enum Kind: String, Sendable, Hashable { case fiveHour, week }
    public let kind: Kind
    /// 0...1. Nil when only the reset time is known (ratelimit-header fallback).
    public let usedPercent: Double?
    public let resetsAt: Date?

    public init(kind: Kind, usedPercent: Double?, resetsAt: Date?) {
        self.kind = kind
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
    }
}

public struct ClaudeUsage: Equatable, Sendable {
    public var windows: [ClaudeUsageWindow]
    public var resetsAvailable: Int?
    /// True when built from `anthropic-ratelimit-*` headers, not the usage endpoint.
    public var degraded: Bool

    public init(windows: [ClaudeUsageWindow], resetsAvailable: Int? = nil, degraded: Bool = false) {
        self.windows = windows
        self.resetsAvailable = resetsAvailable
        self.degraded = degraded
    }
}

extension ClaudeUsage {
    /// Highest `usedPercent` across the known windows (the binding limit), or nil
    /// when no window reports a percentage (reset-only header fallback).
    public var worstUsedPercent: Double? {
        windows.compactMap(\.usedPercent).max()
    }
}

/// Per-account rate-limit picture used by routing to prefer the emptiest account.
/// In-memory only, like `ClaudeUsage`.
public struct AccountUsageSnapshot: Equatable, Sendable {
    /// 0...1, fraction of quota still available. Nil = unknown (API-key accounts,
    /// or a subscription provider with no usage endpoint yet).
    public var remainingFraction: Double?
    public var resetsAt: Date?
    public var fetchedAt: Date

    public init(remainingFraction: Double?, resetsAt: Date? = nil, fetchedAt: Date = Date()) {
        self.remainingFraction = remainingFraction
        self.resetsAt = resetsAt
        self.fetchedAt = fetchedAt
    }

    public var isFresh: Bool { Date().timeIntervalSince(fetchedAt) < 60 }
}

public enum ClaudeUsageState: Equatable, Sendable {
    case idle
    case loading
    case loaded(ClaudeUsage)
    case failed(Reason)

    public enum Reason: Equatable, Sendable { case needsLogin, network, noAccount }
}

enum ClaudeUsageError: Error { case unauthorized, badShape, http(Int) }

public enum ClaudeUsageService {

    // MARK: - Networking

    /// GET the Claude usage endpoint with the account's OAuth bearer token.
    /// Falls back to `/v1/oauth/usage`, then to reading `anthropic-ratelimit-*`
    /// headers off a 1-token message. Throws `ClaudeUsageError.unauthorized` on
    /// 401/403 so the caller can refresh the token and retry.
    public static func fetchUsage(token: String, extraHeaders: [String: String]) async throws -> ClaudeUsage {
        for path in ["https://api.anthropic.com/api/oauth/usage",
                     "https://api.anthropic.com/v1/oauth/usage"] {
            var request = URLRequest(url: URL(string: path)!)
            request.httpMethod = "GET"
            apply(token: token, extraHeaders: extraHeaders, to: &request)
            let (data, response) = try await URLSession.shared.data(for: request)
            switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
            case 200: return try parse(data)
            case 401, 403: throw ClaudeUsageError.unauthorized
            default: continue
            }
        }
        return try await headerFallback(token: token, extraHeaders: extraHeaders)
    }

    private static func headerFallback(token: String, extraHeaders: [String: String]) async throws -> ClaudeUsage {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        apply(token: token, extraHeaders: extraHeaders, to: &request)
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": "claude-haiku-4-5",
            "max_tokens": 1,
            "messages": [["role": "user", "content": "."]],
        ])
        let (_, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 || code == 403 { throw ClaudeUsageError.unauthorized }
        guard let reset = NativeAgentError.retryAt(from: response) else { throw ClaudeUsageError.http(code) }
        // ponytail: header fallback = reset-only, one window. Drop once the real
        // usage endpoint path/fields are confirmed against a live token.
        return ClaudeUsage(
            windows: [ClaudeUsageWindow(kind: .fiveHour, usedPercent: nil, resetsAt: reset)],
            degraded: true
        )
    }

    private static func apply(token: String, extraHeaders: [String: String], to request: inout URLRequest) {
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        for (header, value) in extraHeaders { request.setValue(value, forHTTPHeaderField: header) }
    }

    // MARK: - Parsing

    /// Tolerant of a few key spellings because the exact response shape is not
    /// pinned yet. Throws `.badShape` when no window block is present.
    public static func parse(_ data: Data) throws -> ClaudeUsage {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ClaudeUsageError.badShape
        }
        let windows = [
            window(in: root, keys: ["five_hour", "fiveHour", "5h"], kind: .fiveHour),
            window(in: root, keys: ["seven_day", "sevenDay", "week", "7d"], kind: .week),
        ].compactMap { $0 }
        guard !windows.isEmpty else { throw ClaudeUsageError.badShape }
        return ClaudeUsage(
            windows: windows,
            resetsAvailable: int(root["resets_available"] ?? root["resetsAvailable"]),
            degraded: false
        )
    }

    private static func window(in root: [String: Any], keys: [String], kind: ClaudeUsageWindow.Kind) -> ClaudeUsageWindow? {
        guard let block = keys.lazy.compactMap({ root[$0] as? [String: Any] }).first else { return nil }
        let raw = double(block["utilization"] ?? block["used_percent"] ?? block["percent"])
        return ClaudeUsageWindow(
            kind: kind,
            usedPercent: raw.map { $0 > 1 ? $0 / 100 : $0 },
            resetsAt: (block["resets_at"] ?? block["reset_at"] ?? block["resetsAt"]).flatMap(date(from:))
        )
    }

    private static func double(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        if let s = any as? String { return Double(s) }
        return nil
    }

    private static func int(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let d = any as? Double { return Int(d) }
        if let s = any as? String { return Int(s) }
        return nil
    }

    private static func date(from any: Any) -> Date? {
        if let string = any as? String {
            let iso = ISO8601DateFormatter()
            if let parsed = iso.date(from: string) { return parsed }
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let parsed = iso.date(from: string) { return parsed }
        }
        if let seconds = double(any) { return Date(timeIntervalSince1970: seconds) }
        return nil
    }

    // MARK: - Formatting

    /// 0: <25%, 1: <50%, 2: <75%, 3: otherwise. The UI maps the level to a colour.
    public static func heatLevel(_ percent: Double) -> Int {
        switch percent {
        case ..<0.25: return 0
        case ..<0.50: return 1
        case ..<0.75: return 2
        default: return 3
        }
    }

    public enum ResetText: Equatable, Sendable {
        case relative(String)   // "2h 14m", "40m"
        case weekday(String)    // "Tue"
    }

    public static func resetText(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> ResetText {
        let seconds = date.timeIntervalSince(now)
        if seconds < 24 * 3600 {
            let formatter = DateComponentsFormatter()
            formatter.allowedUnits = [.hour, .minute]
            formatter.unitsStyle = .abbreviated
            formatter.zeroFormattingBehavior = .dropAll
            return .relative(formatter.string(from: max(seconds, 60)) ?? "0m")
        }
        let formatter = DateFormatter()
        formatter.locale = AppLocalization.locale
        formatter.calendar = calendar
        formatter.setLocalizedDateFormatFromTemplate("EEE")
        return .weekday(formatter.string(from: date))
    }
}

extension RouterController {
    /// Live Claude rate-limit usage for the first active Claude OAuth account.
    /// In-memory only, no persistence. Safe to call on a repeating poll.
    public func refreshClaudeUsage() async {
        guard let account = store.state.accounts.first(where: {
            $0.active && $0.provider == "claude" && $0.authType == "oauth"
        }) else {
            claudeUsage = .failed(.noAccount)
            return
        }
        if case .loaded = claudeUsage {} else { claudeUsage = .loading }

        let headers = RouterCatalog.spec(for: "claude")?.transport.extraHeaders ?? [:]
        do {
            claudeUsage = .loaded(try await loadClaudeUsage(account: account, headers: headers, allowRefresh: true))
        } catch is CancellationError {
            // View disappeared mid-flight; keep whatever state we had.
        } catch ClaudeUsageError.unauthorized {
            claudeUsage = .failed(.needsLogin)
        } catch {
            claudeUsage = .failed(.network)
        }
    }

    private func loadClaudeUsage(
        account: StoredProviderAccount,
        headers: [String: String],
        allowRefresh: Bool
    ) async throws -> ClaudeUsage {
        guard let token = try store.credential(for: account), !token.isEmpty else {
            throw ClaudeUsageError.unauthorized
        }
        do {
            return try await ClaudeUsageService.fetchUsage(token: token, extraHeaders: headers)
        } catch ClaudeUsageError.unauthorized where allowRefresh {
            guard await refreshCredential(for: account) else { throw ClaudeUsageError.unauthorized }
            return try await loadClaudeUsage(account: account, headers: headers, allowRefresh: false)
        }
    }

    /// Refreshes `accountUsage` for every active subscription (OAuth/ChatGPT)
    /// account so routing can pick the emptiest one. TTL-guarded and best-effort:
    /// a fetch failure just leaves that account's remaining fraction unknown.
    ///
    /// ponytail: only the Claude provider has a real usage endpoint today. Other
    /// subscription providers stay `nil` (unknown) until their endpoints are
    /// wired — routing then orders them by `priority` and the 429 cooldown still
    /// protects them. Upgrade path: capture `x-ratelimit-*` response headers off
    /// the normal completion in `NativeAgentClient` and feed them here.
    public func refreshAccountUsage(force: Bool = false) async {
        let subscription = store.state.accounts.filter {
            $0.active && ($0.authType == "oauth" || $0.authType == "chatgpt")
        }
        for account in subscription {
            if !force, let snapshot = accountUsage[account.id], snapshot.isFresh { continue }
            guard account.provider == "claude" else {
                if accountUsage[account.id] == nil {
                    accountUsage[account.id] = AccountUsageSnapshot(remainingFraction: nil)
                }
                continue
            }
            let headers = RouterCatalog.spec(for: account.provider)?.transport.extraHeaders ?? [:]
            do {
                let usage = try await loadClaudeUsage(account: account, headers: headers, allowRefresh: true)
                accountUsage[account.id] = AccountUsageSnapshot(
                    remainingFraction: usage.worstUsedPercent.map { max(0, 1 - $0) },
                    resetsAt: usage.windows.compactMap(\.resetsAt).min()
                )
            } catch is CancellationError {
                return
            } catch {
                accountUsage[account.id] = AccountUsageSnapshot(remainingFraction: nil)
            }
        }
    }
}

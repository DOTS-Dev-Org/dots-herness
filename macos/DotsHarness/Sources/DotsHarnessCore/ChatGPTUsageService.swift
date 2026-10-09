// Copyright (c) 2026 DOTS
// ChatGPT (Codex) subscription rate-limit usage. GET the wham/usage endpoint
// with the account's OAuth token; fetched on demand, never stored.

import Foundation

public enum ChatGPTUsageService {
    public struct Usage: Equatable, Sendable {
        /// Primary (5h) and secondary (weekly) windows, worst first.
        public var windows: [ClaudeUsageWindow]

        public init(windows: [ClaudeUsageWindow]) { self.windows = windows }

        public var worstUsedPercent: Double? { windows.compactMap(\.usedPercent).max() }
    }

    /// `…/backend-api/codex` serves chat; usage hangs off the same backend as
    /// `…/backend-api/wham/usage` (Codex CLI's own endpoint).
    public static func usageURL(baseURL: String) -> URL? {
        var base = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        for suffix in ["/codex", "/api/codex"] where base.hasSuffix(suffix) {
            base = String(base.dropLast(suffix.count))
        }
        return URL(string: base + "/wham/usage")
    }

    /// Headers mirror the Codex CLI so the backend treats the poll like any
    /// other Codex request: bearer token plus the ChatGPT account id.
    public static func fetchUsage(token: String, accountID: String?, baseURL: String) async throws -> Usage {
        guard let url = usageURL(baseURL: baseURL) else { throw ClaudeUsageError.badShape }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let accountID, !accountID.isEmpty {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        request.setValue("codex_cli_rs", forHTTPHeaderField: "originator")
        request.setValue("codex_cli_rs/0.155.0", forHTTPHeaderField: "user-agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 || code == 403 { throw ClaudeUsageError.unauthorized }
        guard (200..<300).contains(code) else { throw ClaudeUsageError.http(code) }
        return try parse(data)
    }

    static func parse(_ data: Data) throws -> Usage {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rateLimit = root["rate_limit"] as? [String: Any] else {
            throw ClaudeUsageError.badShape
        }
        let windows = [
            window(in: rateLimit["primary_window"]),
            window(in: rateLimit["secondary_window"]),
        ].compactMap { $0 }
        guard !windows.isEmpty else { throw ClaudeUsageError.badShape }
        return Usage(windows: windows)
    }

    private static func window(in block: Any?) -> ClaudeUsageWindow? {
        guard let block = block as? [String: Any],
              let raw = number(block["used_percent"]) else { return nil }
        let seconds = number(block["limit_window_seconds"])
        return ClaudeUsageWindow(
            kind: seconds.map { $0 <= 6 * 3600 ? .fiveHour : .week } ?? .fiveHour,
            usedPercent: min(max(raw / 100, 0), 1),
            resetsAt: number(block["reset_at"]).map { Date(timeIntervalSince1970: $0) }
        )
    }

    private static func number(_ any: Any?) -> Double? {
        if let value = any as? Double { return value }
        if let value = any as? Int { return Double(value) }
        if let value = any as? String { return Double(value) }
        return nil
    }
}

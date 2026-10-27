// Copyright (c) 2026 DOTS
// Small, transient follow-up draft helpers shared by the native host and tests.

import Foundation

func normalizeFollowUpSuggestion(_ raw: String) -> String? {
    let normalized = raw
        .split(whereSeparator: \.isWhitespace)
        .joined(separator: " ")
    guard !normalized.isEmpty else { return nil }
    return String(normalized.prefix(500))
}

func normalizeFollowUpSuggestions(_ raw: String) -> [String] {
    let lines = raw.components(separatedBy: .newlines).compactMap { line -> String? in
        let withoutListMarker = line.replacingOccurrences(
            of: "^[[:space:]]*([-*]|[0-9]+[.)])[[:space:]]*",
            with: "",
            options: .regularExpression
        )
        let normalized = withoutListMarker
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !normalized.isEmpty else { return nil }
        return String(normalized.prefix(200))
    }

    var unique: [String] = []
    for line in lines where !unique.contains(where: { $0.caseInsensitiveCompare(line) == .orderedSame }) {
        unique.append(line)
        if unique.count == 2 { break }
    }
    if !unique.isEmpty { return unique }
    guard let fallback = normalizeFollowUpSuggestion(raw) else { return [] }
    return [String(fallback.prefix(200))]
}

func shouldGenerateFollowUp(
    succeeded: Bool,
    cancelled: Bool,
    paused: Bool,
    pendingQueue: Bool,
    economy: Bool = false
) -> Bool {
    succeeded && !cancelled && !paused && !pendingQueue && !economy
}

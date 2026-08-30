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

func shouldGenerateFollowUp(
    succeeded: Bool,
    cancelled: Bool,
    paused: Bool,
    pendingQueue: Bool
) -> Bool {
    succeeded && !cancelled && !paused && !pendingQueue
}

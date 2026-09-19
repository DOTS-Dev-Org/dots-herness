// Copyright (c) 2026 DOTS
// Detects repeated tool-call and prompt patterns and proposes turning them into a
// workspace skill. Detection only ever produces a suggestion; nothing is written
// to disk until the user explicitly accepts it (see SkillSuggestionMonitor.acceptCurrent).

import CryptoKit
import Foundation

public enum SkillSuggestionSignal: String, Sendable {
    case toolSequence
    case promptSimilarity
    /// The agent itself noticed a pattern mid-conversation and proposed it via the skill.suggest tool.
    case agentProposed
}

public struct SkillSuggestion: Identifiable, Sendable, Equatable {
    public let id: String
    public let signal: SkillSuggestionSignal
    public let title: String
    public let draftName: String
    public let draftDescription: String
    public let samples: [String]
    public let occurrences: Int
    public let firstSeen: Date
    public let lastSeen: Date
    public let suggestedBody: String?

    public init(
        id: String,
        signal: SkillSuggestionSignal,
        title: String,
        draftName: String,
        draftDescription: String,
        samples: [String],
        occurrences: Int,
        firstSeen: Date,
        lastSeen: Date,
        suggestedBody: String? = nil
    ) {
        self.id = id
        self.signal = signal
        self.title = title
        self.draftName = draftName
        self.draftDescription = draftDescription
        self.samples = samples
        self.occurrences = occurrences
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
        self.suggestedBody = suggestedBody
    }

    public func draftBody() -> String {
        if let suggestedBody { return suggestedBody }
        switch signal {
        case .toolSequence:
            return """
            ## Steps

            Run the following when asked to \(draftName.lowercased()):

            ```
            \(samples.first ?? "")
            ```

            """
        default:
            let examples = samples.prefix(3).map { "- \($0)" }.joined(separator: "\n")
            return """
            ## Example requests this covers

            \(examples)

            ## Approach

            <!-- fill in how to handle these requests -->

            """
        }
    }
}

public enum SkillSuggestionEngine {
    private static let uuidPattern = try! NSRegularExpression(
        pattern: "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}",
        options: [.caseInsensitive]
    )
    private static let tempPathPattern = try! NSRegularExpression(pattern: "/tmp/[^\\s\"']+|/var/folders/[^\\s\"']+")
    private static let timestampPattern = try! NSRegularExpression(
        pattern: "\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}(\\.\\d+)?(Z|[+-]\\d{2}:\\d{2})?"
    )
    private static let whitespacePattern = try! NSRegularExpression(pattern: "\\s+")

    public static func detectToolSequencePatterns(events: [MemEvent], minOccurrences: Int) -> [SkillSuggestion] {
        var groups: [String: [(normalized: String, raw: String, createdAt: Date)]] = [:]
        for event in events {
            guard let raw = event.commandSummary, !raw.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            let normalized = normalizeCommand(raw)
            guard !normalized.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            groups[normalized, default: []].append((normalized, raw, event.createdAt))
        }

        var results: [SkillSuggestion] = []
        for (key, items) in groups {
            guard items.count >= minOccurrences else { continue }
            let id = shortHash("tool:" + key)
            results.append(SkillSuggestion(
                id: id,
                signal: .toolSequence,
                title: truncate(key, 60),
                draftName: "Repeat: " + truncate(key, 40),
                draftDescription: "Runs `\(truncate(key, 160))` — observed \(items.count) times in this workspace.",
                samples: [items[0].raw],
                occurrences: items.count,
                firstSeen: items.map { $0.createdAt }.min() ?? Date(),
                lastSeen: items.map { $0.createdAt }.max() ?? Date()
            ))
        }
        return results.sorted { $0.occurrences > $1.occurrences }
    }

    public static func detectPromptSimilarityPatterns(
        userPrompts: [String],
        minOccurrences: Int,
        similarityThreshold: Double
    ) -> [SkillSuggestion] {
        let prompts = userPrompts.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        var clusters: [[String]] = []

        for prompt in prompts {
            let tokens = tokenize(prompt)
            var bestIndex: Int?
            var bestScore = 0.0
            for (index, cluster) in clusters.enumerated() {
                let score = jaccard(tokens, tokenize(cluster[0]))
                if score >= similarityThreshold && score > bestScore {
                    bestIndex = index
                    bestScore = score
                }
            }
            if let bestIndex {
                clusters[bestIndex].append(prompt)
            } else {
                clusters.append([prompt])
            }
        }

        var results: [SkillSuggestion] = []
        for cluster in clusters {
            guard cluster.count >= minOccurrences else { continue }
            let representative = cluster.min(by: { $0.count < $1.count }) ?? cluster[0]
            let id = shortHash("prompt:" + cluster.sorted().joined())
            results.append(SkillSuggestion(
                id: id,
                signal: .promptSimilarity,
                title: truncate(representative, 60),
                draftName: "Handle: " + truncate(representative, 40),
                draftDescription: "Handles requests like: '\(truncate(representative, 120))' — asked \(cluster.count) times.",
                samples: Array(cluster.prefix(3)),
                occurrences: cluster.count,
                firstSeen: Date(),
                lastSeen: Date()
            ))
        }
        return results.sorted { $0.occurrences > $1.occurrences }
    }

    private static func normalizeCommand(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        text = replace(uuidPattern, in: text, with: "<uuid>")
        text = replace(tempPathPattern, in: text, with: "<tmp>")
        text = replace(timestampPattern, in: text, with: "<timestamp>")
        text = replace(whitespacePattern, in: text, with: " ")
        return text
    }

    private static func tokenize(_ text: String) -> Set<String> {
        let lowered = text.lowercased()
        let cleaned: [Character] = lowered.map { character in
            character.isLetter || character.isNumber || character.isWhitespace ? character : " "
        }
        let joined = String(cleaned)
        return Set(joined.split(whereSeparator: \.isWhitespace).map(String.init).filter { !$0.isEmpty })
    }

    private static func jaccard(_ a: Set<String>, _ b: Set<String>) -> Double {
        if a.isEmpty && b.isEmpty { return 1.0 }
        let union = a.union(b).count
        guard union > 0 else { return 0.0 }
        return Double(a.intersection(b).count) / Double(union)
    }

    private static func truncate(_ text: String, _ max: Int) -> String {
        text.count <= max ? text : String(text.prefix(max))
    }

    private static func shortHash(_ key: String) -> String {
        let digest = SHA256.hash(data: Data(key.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(12).lowercased()
    }

    private static func replace(_ pattern: NSRegularExpression, in text: String, with template: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        return pattern.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }
}

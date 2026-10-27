// Copyright (c) 2026 DOTS
// What keeps the project's decisions in .mem/facts.md useful as they pile up: which
// platforms each one is about, when two say the same thing, which leave first when the
// file is full, and which a light model suggests are no longer true. Suggestions are the
// person's to accept, so they are kept in their folder for the project, never in the
// repository.
//
// Mirrors shared/ProjectDecisions.cs. shared/memory-contract/decisions.json holds the
// cases both must agree on.

import Foundation

public struct DecisionProposal: Codable, Equatable, Sendable {
    public var key: String
    public var reason: String
    public var createdAt: String?
}

public enum ProjectDecisions {
    /// The platforms a decision can be about, in the order a tag lists them.
    public static let platforms = ["macos", "windows", "linux", "ios", "android"]

    /// A decision's own sentence when its reason is given apart.
    static let statementLength = 240
    static let reasonLength = 200
    static let reasonMarker = "Reason: "

    /// Decisions are reviewed once there are this many, and again after this many more.
    static let consolidationMinimum = 12
    static let consolidationStep = 8

    static let currentPlatform = "macos"

    /// One text holding a decision and its reason may run to this; a decision recorded with
    /// its reason and platforms apart is stored as up to `decisionLimit`.
    static let decisionTextLimit = 360
    static let decisionLimit = 500

    static func factLimit(kind: String, key: String) -> Int {
        switch kind {
        case "project": return ProjectKnowledge.limit(forKey: key)
        case "decision": return decisionLimit
        default: return 240
        }
    }

    nonisolated(unsafe) private static let tagPattern = try! NSRegularExpression(pattern: #"^\[([a-z, ]+)\]\s+"#)

    // A decision written before tags existed names its platforms in its words.
    nonisolated(unsafe) private static let mentions: [(NSRegularExpression, [String])] = [
        (#"\bmac\s?os\b"#, ["macos"]),
        (#"\bwindows\b"#, ["windows"]),
        (#"\blinux\b|\bavalonia\b"#, ["linux"]),
        (#"\bios\b"#, ["ios"]),
        (#"\bandroid\b"#, ["android"]),
        (#"\bdesktop\b|\bmasaüstü"#, ["macos", "windows", "linux"]),
        (#"\bmobile\b|\bmobil"#, ["ios", "android"]),
    ].map { (try! NSRegularExpression(pattern: $0.0, options: [.caseInsensitive]), $0.1) }

    private static func tagMatch(_ text: String) -> NSTextCheckingResult? {
        tagPattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
    }

    /// The platforms a leading "[macos, windows] " names. Empty when there is no such tag,
    /// or when it names something that is not a platform: then it is part of the sentence.
    static func taggedPlatforms(_ text: String) -> [String] {
        guard let match = tagMatch(text), let range = Range(match.range(at: 1), in: text) else { return [] }
        let names = text[range].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return !names.isEmpty && names.allSatisfy(platforms.contains) ? ordered(names) : []
    }

    /// The decision without its platform tag.
    static func body(_ text: String) -> String {
        guard !taggedPlatforms(text).isEmpty, let match = tagMatch(text), let range = Range(match.range, in: text) else { return text }
        return String(text[range.upperBound...])
    }

    /// What a decision is about: its tag, else the platforms its words name. Empty means
    /// every platform, and so does a decision that names them all.
    static func platforms(of text: String) -> [String] {
        let tagged = taggedPlatforms(text)
        let found = !tagged.isEmpty ? tagged : ordered(mentions.filter { pattern, _ in
            pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        }.flatMap(\.1))
        return found.count == platforms.count ? [] : found
    }

    static func applies(_ text: String, platform: String) -> Bool {
        let found = platforms(of: text)
        return found.isEmpty || found.contains(platform)
    }

    /// The names the remember tool accepts, as platforms: "desktop" and "mobile" stand for
    /// their platforms, "all" for none in particular. Anything else is dropped.
    static func normalizePlatforms(_ names: [String]) -> [String] {
        var expanded: [String] = []
        for raw in names {
            let name = raw.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: " ", with: "")
            switch name {
            case "all", "every", "everywhere": return []
            case "mac", "macos", "osx": expanded.append("macos")
            case "desktop": expanded += ["macos", "windows", "linux"]
            case "mobile": expanded += ["ios", "android"]
            default: if platforms.contains(name) { expanded.append(name) }
            }
        }
        let result = ordered(expanded)
        return result.count == platforms.count ? [] : result
    }

    /// One decision line from its parts. The statement and the reason are clipped apart, so
    /// a long statement can no longer cut its reason off.
    static func compose(statement: String, reason: String, platforms names: [String]) -> String {
        var body = SecretRedaction.clipped(SecretRedaction.sanitize(statement, limit: .max), limit: statementLength)
        var why = SecretRedaction.clipped(SecretRedaction.sanitize(reason, limit: .max), limit: reasonLength)
        if why.lowercased().hasPrefix(reasonMarker.lowercased()) {
            why = String(why.dropFirst(reasonMarker.count)).trimmingCharacters(in: .whitespaces)
        }
        guard let last = body.last else { return "" }
        if !why.isEmpty { body += (".!?…".contains(last) ? " " : ". ") + reasonMarker + why }
        let tag = normalizePlatforms(names)
        return (tag.isEmpty ? "" : "[" + tag.joined(separator: ", ") + "] ") + body
    }

    /// The vault's id for a decision; keys written here already carry the prefix.
    static func noteID(_ key: String) -> String { key.hasPrefix("decision-") ? key : "decision-" + key }

    /// Two decisions sharing most of their words say the same thing.
    /// ponytail: word overlap, not meaning; a reworded twin with few shared words stays.
    static func same(_ left: String, _ right: String) -> Bool {
        let a = FeedbackStore.tokens(body(left)), b = FeedbackStore.tokens(body(right))
        guard min(a.count, b.count) >= 5 else { return FeedbackStore.folded(body(left)) == FeedbackStore.folded(body(right)) }
        return Double(a.intersection(b).count) / Double(a.union(b).count) >= 0.7
    }

    /// Facts as a prompt should read them. Older builds cut decisions at 240 or 360 characters
    /// in the middle of a word: such a text ends at its last whole sentence instead. A decision
    /// stated twice in other words is kept once, in its fuller wording, where it first stood.
    static func tidied(_ facts: [MemoryTransferFact]) -> [MemoryTransferFact] {
        var kept: [MemoryTransferFact] = []
        for var fact in facts {
            let count = fact.text.count
            let cut = count >= factLimit(kind: fact.kind, key: fact.key)
                || fact.kind == "decision" && (count == 240 || count == decisionTextLimit)
            if cut, count > 1, let last = fact.text.last, !".!?)…".contains(last) {
                fact.text = SecretRedaction.clipped(fact.text, limit: count - 1)
            }
            guard fact.kind == "decision",
                  let twin = kept.firstIndex(where: { $0.kind == "decision" && same($0.text, fact.text) }) else {
                kept.append(fact)
                continue
            }
            if FeedbackStore.tokens(fact.text).count > FeedbackStore.tokens(kept[twin].text).count { kept[twin] = fact }
        }
        return kept
    }

    /// Records one fact over the one with its kind and key, and over a decision that says
    /// the same thing in other words. The new wording goes last, as the newest.
    static func upsert(_ facts: inout [MemoryTransferFact], _ fact: MemoryTransferFact) {
        facts.removeAll { $0.kind == fact.kind && ($0.key == fact.key || fact.kind == "decision" && same($0.text, fact.text)) }
        facts.append(fact)
    }

    /// Brings a full file back under `max`: the oldest decision leaves first, then the oldest
    /// other fact. What was learned of the code's architecture, conventions and design system
    /// never leaves this way: losing it made every later task study the project again.
    static func evict(_ facts: inout [MemoryTransferFact], max: Int) {
        while facts.count > max {
            guard let index = facts.firstIndex(where: { $0.kind == "decision" })
                ?? facts.firstIndex(where: { !($0.kind == "project" && ProjectKnowledge.keys.contains($0.key)) }) else { return }
            facts.remove(at: index)
        }
    }

    private static func ordered(_ names: [String]) -> [String] {
        let set = Set(names)
        return platforms.filter(set.contains)
    }

    // MARK: - Review

    static let consolidationSystemPrompt = """
    You review the settled decisions of one software project, kept in its repository. Each line is \
    `key: text`; a leading [..] names the platforms a decision is about, and none means every platform.
    - Decisions that say the same thing, or where one only restates part of another, become one: return it \
    under the key you keep, its text rewritten to hold both, and list the other keys under "drop". Keep every \
    reason they gave, and keep a leading platform tag listing the platforms of all of them.
    - Never merge decisions about different things because they share words. Never invent a reason, a file or \
    a fact. A decision that stands alone is left out of your reply: it stays exactly as it is.
    - A decision that a later one contradicts or replaces is stale: list it under "stale" with one short \
    sentence naming what replaced it. It is only suggested to the person, never removed by you.
    - Write in the language of the decision you keep, at most 440 characters per text.
    Reply with JSON only:
    {"merge":[{"keep":"<key>","drop":["<key>"],"text":"..."}],"stale":[{"key":"<key>","reason":"..."}]}
    """

    struct Review: Codable, Equatable {
        var consolidatedCount = 0
        var proposals: [DecisionProposal] = []
    }

    struct Merge: Equatable {
        var keep: String
        var drop: Set<String>
        var text: String
    }

    static func reviewURL(in directory: URL?) -> URL? { directory?.appendingPathComponent("decision-review.json") }

    static func loadReview(_ url: URL?) -> Review {
        guard let url, let data = try? Data(contentsOf: url) else { return Review() }
        return (try? JSONDecoder().decode(Review.self, from: data)) ?? Review()
    }

    static func saveReview(_ review: Review, to url: URL?) {
        guard let url else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(review) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// Every decision, for a light model to review, once enough have been added since the
    /// last review; nil otherwise.
    static func consolidationPayload(_ decisions: [MemoryTransferFact], reviewed: Int) -> String? {
        guard decisions.count >= consolidationMinimum, decisions.count >= reviewed + consolidationStep else { return nil }
        return "## Decisions\n" + decisions.map { "- \($0.key): \($0.text)" }.joined(separator: "\n")
    }

    /// What a reply asks for, kept to known decisions. Nothing is added; a reply that would
    /// drop more than half of them is not believed, and its merges are left out.
    static func parseReview(_ reply: String, decisions: [MemoryTransferFact], now: String) -> (merges: [Merge], stale: [DecisionProposal]) {
        let known = Set(decisions.map(\.key))
        guard let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}"), start < end,
              let object = (try? JSONSerialization.jsonObject(with: Data(reply[start...end].utf8))) as? [String: Any] else { return ([], []) }
        var claimed = Set<String>()
        var merges: [Merge] = []
        for row in object["merge"] as? [[String: Any]] ?? [] {
            let keep = (row["keep"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            let drop = Set((row["drop"] as? [String] ?? []).map { $0.trimmingCharacters(in: .whitespaces) }.filter { known.contains($0) && $0 != keep })
            let text = SecretRedaction.clipped(SecretRedaction.sanitize(row["text"] as? String ?? "", limit: .max), limit: decisionLimit)
            guard known.contains(keep), !drop.isEmpty, !text.isEmpty, !claimed.contains(keep), claimed.isDisjoint(with: drop),
                  !RememberTool.looksLikeSecret(.init(kind: "decision", key: keep, text: text)) else { continue }
            claimed.insert(keep)
            claimed.formUnion(drop)
            merges.append(Merge(keep: keep, drop: drop, text: text))
        }
        var stale: [DecisionProposal] = []
        for row in object["stale"] as? [[String: Any]] ?? [] {
            let key = (row["key"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            let reason = String(SecretRedaction.sanitize(row["reason"] as? String ?? "", limit: reasonLength))
            if known.contains(key), !claimed.contains(key), !reason.isEmpty, !stale.contains(where: { $0.key == key }) {
                stale.append(DecisionProposal(key: key, reason: reason, createdAt: now))
            }
        }
        if merges.reduce(0, { $0 + $1.drop.count }) * 2 > decisions.count { merges = [] }
        return (merges, stale)
    }

    /// The decisions with `merges` applied in place: the kept one takes the merged text,
    /// the others leave.
    static func applying(_ merges: [Merge], to facts: [MemoryTransferFact]) -> [MemoryTransferFact] {
        var result = facts
        for merge in merges {
            guard let index = result.firstIndex(where: { $0.kind == "decision" && $0.key == merge.keep }) else { continue }
            result[index].text = merge.text
            result.removeAll { $0.kind == "decision" && merge.drop.contains($0.key) }
        }
        return result
    }
}

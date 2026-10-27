// Copyright (c) 2026 DOTS
// What the work in this project taught, kept as short findings instead of chat text:
// what was decided, what went wrong and what was learned. A scan on a light model indexes
// finished tasks into findings while their compact notes remain as source evidence; a later
// scan that meets the same thing again strengthens the finding it already has. They are the person's, so
// they live in the user layer under this project's id and never reach another project's prompt.

import Foundation

public struct MemoryInsight: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        /// What was chosen for this project, and why.
        case decision
        /// Where it went wrong, and what fixed it.
        case error
        /// What the work taught that the code does not show: a command, a constraint, a way of working.
        case lesson
        /// Where one concern of the project lives and what was last done there: the map a
        /// request such as "the app lags" is answered from, since it names no file.
        case area

        /// Earlier builds also kept what was done, how, with what and what was run.
        /// Those findings read as lessons until a scan drops the ones that only retell.
        static func parse(_ raw: String) -> Kind? {
            Kind(rawValue: raw) ?? (["did", "how", "with", "ran"].contains(raw) ? .lesson : nil)
        }

        public init(from decoder: Decoder) throws {
            // One unknown kind must not cost the whole findings file.
            self = Self.parse(try decoder.singleValueContainer().decode(String.self)) ?? .lesson
        }
    }

    public var id: String
    public var kind: Kind
    public var text: String
    public var files: [String]
    public var tools: [String]
    /// Words a request about it would use, in English and the requests' language: what recall
    /// matches when a request names the same thing in other words. Absent in older files.
    public var keywords: [String]?
    /// The tasks it was learned from.
    public var runs: [String]
    /// How many scans found it. A finding met again counts for more when recalled.
    public var strength: Int
    public var updatedAt: String
    /// "user" when the person wrote or corrected it; absent when a scan drew it.
    public var source: String? = nil

    /// A decision, or what the person wrote, is a rule: no scan, consolidation or cap
    /// rewrites or removes it. Only the person forgets one.
    public var isRule: Bool { kind == .decision || source == Self.userSource }
    public static let userSource = "user"
}

/// How often finished tasks are turned into findings.
public enum MemoryScanInterval: String, CaseIterable, Sendable, Identifiable {
    case off, hourly, daily, weekly

    public static let settingsKey = "memory.scanInterval"
    public var id: String { rawValue }

    var seconds: TimeInterval? {
        switch self {
        case .off: return nil
        case .hourly: return 3_600
        case .daily: return 86_400
        case .weekly: return 604_800
        }
    }
}

extension WorkspaceMemory {
    struct InsightFile: Codable {
        var insights: [MemoryInsight] = []
        /// Tasks a scan has already read, whether or not they taught anything.
        var scannedRuns: [String] = []
        var lastScan: String?
        /// Parts of the project a study has read; see WorkspaceMemory+Study.
        var studied: [String]?
        /// How many findings the last consolidation left; see WorkspaceMemory+Compaction.
        var consolidatedCount: Int?
        /// The last consolidation shrank the findings but left them over the target: ask again.
        var compactAgain: Bool?
    }

    static let maxInsights = 300
    static let maxKeywords = 12
    /// Findings one `recall` call returns.
    static let recallLimit = 12
    static let scanBatch = 12

    static let scanSystemPrompt = """
    You maintain the long-term memory of one software project. You are given tasks that were finished in it - \
    the request, the outcome, the files changed and the tool calls made - and the findings already known.
    Their compact notes remain available as source evidence after a scan, including when the scan finds no lasting insight. \
    Keep only what a later task in this same project must \
    know and could not read from the code. Never retell the conversation or list what was built: a finished \
    change is in the code, not in memory.
    Each finding has a kind:
    - decision: a choice made for this project and the reason - an approach, a library, a convention, something ruled out.
      A decision not to make a requested change is still a decision when its lasting tradeoff is stated.
    - error: a mistake or failure - what went wrong, why, and what fixed it.
    - lesson: what the work taught - the exact command that builds, tests or deploys, a limit of the \
    environment, a way of working the user asked for.
    - area: where one concern of the project lives, so a later task opens it without searching - the concern \
    in the words the requests use for it, the files and functions that hold it, and in a few words what was \
    last changed there. One per concern: a task that worked in a known area returns that area's id with the \
    text brought up to date, never a second area.
    Rules:
    - One fact per finding, at most 200 characters, in the language of the requests.
    - Name real files and commands from the input. Never invent one. Never include a credential.
    - Capture every lasting decision stated in the task outcome, including a rejected change and its reason. \
      Do not replace it with an area summary. When the outcome does not state a lasting reason, do not invent one. \
    - When a task repeats a known finding, return that finding with its "id" instead of a new one; correct its \
    text if the new task shows more. Put a known finding's id under "drop" only when a task proves it wrong.
    - Also put under "drop" a known finding that is none of the four kinds: one that only says what was \
    built or how large it came out.
    - Most tasks teach nothing lasting. A task that changed files still yields its area, and no more than one.
    - Give each finding up to 8 "keywords": words a later request about it would use, in English and in the \
    language of the requests, with common synonyms - lowercase, one or two words each. Recall matches on them.
    Reply with JSON only:
    {"insights":[{"id":"<known id, or omit>","kind":"decision|error|lesson|area","text":"...","files":["path"],\
    "tools":["name"],"keywords":["word"],"runs":["<task id>"]}],"drop":["<known id>"]}
    """

    private var insightsURL: URL? { userMemoryDirectory?.appendingPathComponent("insights.json") }

    func insightFile() -> InsightFile {
        guard let url = insightsURL, let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(InsightFile.self, from: data) else { return InsightFile() }
        return file
    }

    func save(_ file: InsightFile) {
        guard let url = insightsURL else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? encoder.encode(file).write(to: url, options: .atomic)
    }

    public var insights: [MemoryInsight] { insightFile().insights }

    public var lastMemoryScan: Date? {
        insightFile().lastScan.flatMap { ISO8601DateFormatter().date(from: $0) }
    }

    /// Task notes no scan has read yet, oldest name first.
    private func unscannedTaskNotes(_ file: InsightFile) -> [URL] {
        guard let root = userMemoryDirectory else { return [] }
        let scanned = Set(file.scannedRuns)
        return ((try? fileManager.contentsOfDirectory(at: root.appendingPathComponent("tasks"), includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "md" && !scanned.contains($0.deletingPathExtension().lastPathComponent) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    public var unscannedTaskCount: Int { unscannedTaskNotes(insightFile()).count }

    /// True when the interval has passed and there is finished work no scan has read.
    /// With nothing new, no model is called however long it has been.
    public func memoryScanDue(interval: MemoryScanInterval, now: Date = Date()) -> Bool {
        guard let seconds = interval.seconds else { return false }
        let file = insightFile()
        guard !unscannedTaskNotes(file).isEmpty else { return false }
        guard let last = file.lastScan.flatMap({ ISO8601DateFormatter().date(from: $0) }) else { return true }
        return now.timeIntervalSince(last) >= seconds
    }

    /// The next batch for the model: the tasks' ids and the text describing them.
    func nextScanBatch() -> (runIDs: [String], payload: String)? {
        guard let root = userMemoryDirectory else { return nil }
        let file = insightFile()
        let notes = Array(unscannedTaskNotes(file).prefix(Self.scanBatch))
        guard !notes.isEmpty else { return nil }
        // What each task called, in order. A failed call is marked: that is where errors are found.
        var calls: [String: [String]] = [:]
        let activity = (try? String(contentsOf: root.appendingPathComponent("activity.jsonl"), encoding: .utf8)) ?? ""
        for line in activity.split(separator: "\n") {
            guard let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  object["type"] as? String == "tool.executed" || object["type"] as? String == "skill.used",
                  let payload = object["payload"] as? [String: Any],
                  let runID = payload["runId"] as? String else { continue }
            let name = payload["name"] as? String ?? "skill"
            let detail = payload["commandSummary"] as? String ?? payload["path"] as? String ?? payload["skill"] as? String ?? ""
            let entry = sanitize(name + (detail.isEmpty ? "" : " `\(detail)`"), limit: 200)
                + (payload["resultStatus"] as? String == "failed" ? " [FAILED]" : "")
            if calls[runID]?.last != entry { calls[runID, default: []].append(entry) }
        }
        let tasks = notes.compactMap { url -> String? in
            guard let note = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            let runID = url.deletingPathExtension().lastPathComponent
            let lines = note.split(whereSeparator: \.isNewline).map(String.init)
            func section(_ title: String) -> String {
                guard let start = lines.firstIndex(of: "## \(title)") else { return "" }
                return lines[(start + 1)...].prefix { !$0.hasPrefix("## ") }.joined(separator: "\n")
            }
            return [
                "### Task \(runID) [\(taskNoteField("status", in: lines))] \(taskNoteField("completed", in: lines).prefix(10))",
                "Request: \(section("Request summary"))",
                "Outcome: \(section("Result"))",
                "Changed files:\n\(section("Changed files"))",
                "Calls:\n" + (calls[runID] ?? []).prefix(30).map { "- \($0)" }.joined(separator: "\n"),
            ].joined(separator: "\n")
        }
        let known = file.insights.map { "- \($0.id) [\($0.kind.rawValue)] \($0.text)" }.joined(separator: "\n")
        return (
            notes.map { $0.deletingPathExtension().lastPathComponent },
            "## Known findings\n\(known.isEmpty ? "None" : known)\n\n## Finished tasks\n\n" + tasks.joined(separator: "\n\n")
        )
    }

    /// Folds the model's reply into the findings and marks the batch as read. A reply
    /// that is not the asked JSON changes nothing, so the same tasks are tried again
    /// at the next scan.
    @discardableResult
    func applyScan(reply: String, runIDs: [String], now: Date = Date()) -> Bool {
        guard let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}"), start < end,
              let object = (try? JSONSerialization.jsonObject(with: Data(reply[start...end].utf8))) as? [String: Any],
              let rows = object["insights"] as? [[String: Any]] else { return false }
        var file = insightFile()
        let stamp = ISO8601DateFormatter().string(from: now)
        let batch = Set(runIDs)
        func strings(_ value: Any?, limit: Int) -> [String] {
            Array((value as? [String] ?? []).map { sanitize($0, limit: limit) }.filter { !$0.isEmpty }.prefix(8))
        }
        func merged(_ old: [String], _ new: [String]) -> [String] { Array(NSOrderedSet(array: old + new)) as? [String] ?? old }
        for row in rows {
            let text = sanitize(row["text"] as? String ?? "", limit: 240)
            guard let kind = (row["kind"] as? String).flatMap(MemoryInsight.Kind.parse), !text.isEmpty else { continue }
            let files = strings(row["files"], limit: 300).map(safePath).filter { $0 != "<redacted>" }
            let tools = strings(row["tools"], limit: 80)
            let keywords = strings(row["keywords"], limit: 40).map { $0.lowercased() }
            // The model may only name tasks it was shown in this batch.
            let runs = strings(row["runs"], limit: 60).filter(batch.contains)
            // Met again: the known finding is strengthened, by its id or by saying the same thing.
            let known = (row["id"] as? String).flatMap { id in file.insights.firstIndex { $0.id == id } }
                ?? file.insights.firstIndex { $0.kind == kind && FeedbackStore.folded($0.text) == FeedbackStore.folded(text) }
            if let known {
                // A rule keeps its words; meeting it again only strengthens it.
                if !file.insights[known].isRule {
                    file.insights[known].text = text
                    file.insights[known].kind = kind
                }
                file.insights[known].files = merged(file.insights[known].files, files)
                file.insights[known].tools = merged(file.insights[known].tools, tools)
                file.insights[known].keywords = Array(merged(file.insights[known].keywords ?? [], keywords).prefix(Self.maxKeywords))
                file.insights[known].runs = merged(file.insights[known].runs, runs)
                file.insights[known].strength += 1
                file.insights[known].updatedAt = stamp
            } else {
                file.insights.append(MemoryInsight(
                    id: String(UUID().uuidString.prefix(8)).lowercased(), kind: kind, text: text,
                    files: files, tools: tools, keywords: keywords, runs: runs, strength: 1, updatedAt: stamp
                ))
            }
        }
        // A reply that would drop more than half is not believed, as in consolidation.
        let dropped = Set(object["drop"] as? [String] ?? [])
            .intersection(file.insights.filter { !$0.isRule }.map(\.id))
        if dropped.count * 2 <= file.insights.count {
            file.insights.removeAll { dropped.contains($0.id) }
        }
        // Past the cap the weakest go first, and among equals the ones not met for longest.
        // Rules are never counted out.
        if file.insights.count > Self.maxInsights {
            let ranked = file.insights
                .sorted { $0.strength != $1.strength ? $0.strength > $1.strength : $0.updatedAt > $1.updatedAt }
            let rules = ranked.filter(\.isRule)
            file.insights = rules + ranked.filter { !$0.isRule }.prefix(max(0, Self.maxInsights - rules.count))
        }
        // Keep the compact task note as source evidence. The scan is a helpful
        // index, not the only copy of the decision or its reason.
        file.scannedRuns = merged(file.scannedRuns, runIDs)
        file.lastScan = stamp
        save(file)
        return true
    }


    /// What the findings may take of a prompt, in characters: about 750 tokens. Past it the
    /// findings the request names go first; the rest stay reachable with `recall`.
    static let insightBudget = 3_000

    /// Consolidation is asked for once the findings take more than this, so the stored set stays
    /// small; see WorkspaceMemory+Compaction. Independent of the prompt budget: a smaller prompt
    /// share must not make consolidation (a model call) run more often.
    static let insightTarget = 6_000

    /// The characters the findings' own words take in a prompt: what consolidation can shrink.
    /// Their file lists come on top while they fit.
    var insightsSize: Int { insightFile().insights.reduce(0) { $0 + Self.shortLine($1).count + 1 } }

    /// The findings a request carries. They are few and short, so while they fit the budget
    /// all of them go, in an order the request does not change: a request in other words or
    /// another language than a finding still meets it, and the text is the same from one
    /// request to the next. When they do not fit with their files, the files the text already
    /// names and all but two go, then the rest: no finding is left out for a file list. Only past that - for as long as consolidation has
    /// not yet folded them back under the target - the findings the request names go first - scored
    /// by the words they share, in text, files, tools or keywords, a word few findings use counting
    /// for more and a word matching a longer form of itself ("hafıza" finds "hafızada") - then
    /// the decisions, then the strongest: whole lines until the budget is full. What is left out
    /// the model can still reach with `recall`, in words of its own.
    /// ponytail: recall is word overlap widened by the keywords a scan writes in two languages,
    /// not embeddings; add a vector index when findings are seen being missed even so.
    public func insightsText(for prompt: String) -> String {
        let all = sortedInsights()
        for render in [Self.line, Self.compactLine, Self.shortLine] where all.reduce(0, { $0 + render($1).count + 1 }) <= Self.insightBudget {
            return all.map(render).joined(separator: "\n")
        }
        let scored = rankedInsights(all, for: prompt)
        var used = 0
        let kept = (scored + all.filter { !scored.contains($0) }).map(Self.shortLine).prefix { text in
            used += text.count + 1
            return used <= Self.insightBudget
        }
        return (kept + ["[\(all.count - kept.count) weaker findings not shown; search them with \(RecallTool.name)]"]).joined(separator: "\n")
    }

    /// Findings and retained task outcomes that share a word with `query`, best first, for `recall`.
    public func recallText(query: String) -> String {
        let found = rankedInsights(sortedInsights(), for: query).prefix(Self.recallLimit)
        let decisions = rankedInsights(decisionInsights(), for: query).prefix(Self.recallLimit)
        let tasks = relevantTasks(for: query)
        return [
            decisions.isEmpty ? "" : "Project decisions:\n" + decisions.map { "- `\($0.id)`: \($0.text)" }.joined(separator: "\n"),
            found.isEmpty ? "" : "Findings:\n" + found.map(Self.line).joined(separator: "\n"),
            tasks.isEmpty ? "" : "Earlier task outcomes:\n" + tasks,
        ].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    /// What the project's decisions may take of the cached project memory, in characters:
    /// about 500 tokens. Past it they leave that section, and the ones a request names come
    /// with the request instead; see `decisionsText(for:)`.
    static let decisionBudget = 2_000

    /// The project's decisions, from `.mem/facts.md`, in the shape recall ranks. With a
    /// platform, only those about it; recall searches them all.
    func decisionInsights(platform: String? = nil) -> [MemoryInsight] {
        projectMemoryFacts().filter { fact in
            fact.kind == "decision" && (platform.map { ProjectDecisions.applies(fact.text, platform: $0) } ?? true)
        }.sorted { $0.key < $1.key }.map {
            MemoryInsight(id: $0.key, kind: .decision, text: $0.text, files: [], tools: [], keywords: nil,
                          runs: [], strength: 1, updatedAt: "")
        }
    }

    /// The decisions about other platforms, which leave the prompt to `recall`.
    func otherPlatformDecisionCount() -> Int {
        projectMemoryFacts().filter { $0.kind == "decision" && !ProjectDecisions.applies($0.text, platform: ProjectDecisions.currentPlatform) }.count
    }

    /// Every decision about this platform while they fit the budget, unchanged from one
    /// request to the next so the project memory stays cached; nil past it.
    func allDecisionsText() -> String? {
        let lines = decisionInsights(platform: ProjectDecisions.currentPlatform).map { "- `\($0.id)`: \($0.text)" }
        return lines.reduce(0, { $0 + $1.count + 1 }) <= Self.decisionBudget ? lines.joined(separator: "\n") : nil
    }

    /// Past the budget: this platform's decisions sharing words with the request, best first,
    /// whole lines until the budget is full. A decision the request does not name is left to `recall`.
    func decisionsText(for prompt: String) -> String {
        guard allDecisionsText() == nil else { return "" }
        var used = 0
        return rankedInsights(decisionInsights(platform: ProjectDecisions.currentPlatform), for: prompt).map { "- `\($0.id)`: \($0.text)" }.prefix { line in
            used += line.count + 1
            return used <= Self.decisionBudget
        }.joined(separator: "\n")
    }

    private func sortedInsights() -> [MemoryInsight] {
        insightFile().insights.sorted {
            if ($0.kind == .decision) != ($1.kind == .decision) { return $0.kind == .decision }
            return $0.strength != $1.strength ? $0.strength > $1.strength : $0.updatedAt > $1.updatedAt
        }
    }

    private static func line(_ insight: MemoryInsight) -> String {
        "- [\(insight.kind.rawValue)] \(insight.text)" + (insight.files.isEmpty ? "" : " (\(insight.files.prefix(4).joined(separator: ", ")))")
    }

    private static func compactLine(_ insight: MemoryInsight) -> String {
        let files = insight.files
            .filter { !insight.text.contains(($0 as NSString).lastPathComponent) }
            .prefix(2)
        return shortLine(insight) + (files.isEmpty ? "" : " (\(files.joined(separator: ", ")))")
    }

    static func shortLine(_ insight: MemoryInsight) -> String {
        "- [\(insight.kind.rawValue)] \(insight.text)"
    }

    /// The findings sharing a word with `text`, best first; the ones sharing none are left out.
    func rankedInsights(_ all: [MemoryInsight], for text: String) -> [MemoryInsight] {
        let terms = FeedbackStore.tokens(text)
        let indexed = all.map { ($0, FeedbackStore.tokens(([$0.text] + $0.files + $0.tools + ($0.keywords ?? [])).joined(separator: " "))) }
        func matches(_ term: String, _ token: String) -> Bool {
            term == token || (min(term.count, token.count) >= 5 && (term.hasPrefix(token) || token.hasPrefix(term)))
        }
        // How many findings each of the request's words is found in.
        let spread = Dictionary(uniqueKeysWithValues: terms.map { term in
            (term, indexed.filter { $0.1.contains { matches(term, $0) } }.count)
        })
        return indexed.compactMap { insight, tokens -> (score: Double, insight: MemoryInsight)? in
            let score = terms.reduce(0.0) { total, term in
                guard tokens.contains(where: { matches(term, $0) }) else { return total }
                return total + 1 + log(Double(all.count) / Double(max(1, spread[term] ?? 1)))
            }
            return score > 0 ? (score * 4 + Double(min(insight.strength, 5)), insight) : nil
        }
        .sorted { $0.score != $1.score ? $0.score > $1.score : $0.insight.updatedAt > $1.insight.updatedAt }
        .map(\.insight)
    }

    /// A finding the person wrote or corrected, by hand or through the memory chat.
    /// With an id it replaces that finding's text; without one it adds a finding.
    func writeInsight(id: String?, kind: MemoryInsight.Kind?, text: String) {
        var file = insightFile()
        let text = sanitize(text, limit: 240)
        let stamp = isoNow()
        guard !text.isEmpty else { return }
        if let index = file.insights.firstIndex(where: { $0.id == id }) {
            file.insights[index].text = text
            file.insights[index].updatedAt = stamp
            file.insights[index].source = MemoryInsight.userSource
        } else if id == nil, let kind {
            file.insights.append(MemoryInsight(
                id: String(UUID().uuidString.prefix(8)).lowercased(), kind: kind, text: text,
                files: [], tools: [], runs: [], strength: 1, updatedAt: stamp, source: MemoryInsight.userSource
            ))
        }
        save(file)
    }

    public func deleteInsight(id: String) {
        var file = insightFile()
        file.insights.removeAll { $0.id == id }
        save(file)
    }

    /// A deleted task leaves nothing behind: findings learned only from it go with it.
    func forgetInsights(ofRun runID: String) {
        var file = insightFile()
        guard file.scannedRuns.contains(runID) || file.insights.contains(where: { $0.runs.contains(runID) }) else { return }
        file.insights = file.insights.compactMap { insight in
            guard insight.runs.contains(runID) else { return insight }
            var insight = insight
            insight.runs.removeAll { $0 == runID }
            return insight.runs.isEmpty ? nil : insight
        }
        file.scannedRuns.removeAll { $0 == runID }
        save(file)
    }
}

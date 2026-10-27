// Copyright (c) 2026 DOTS
// Memory that stays small the way a long conversation does: it is compacted, not cut.
// Nothing is dropped for being old. The activity log folds the calls of finished work
// into one count per tool, which is all that is ever read of them, and the findings are
// consolidated by a light model once enough new ones have piled up: the ones saying the
// same thing become one, a superseded one goes, and what has not changed is left alone.

import Foundation

extension WorkspaceMemory {
    public static let enabledSettingsKey = "memory.enabled"
    static let toolSummaryType = "tool.summary"
    /// Findings are consolidated each time this many have been added since the last time.
    static let consolidationStep = 60
    /// Past the size target, this many new findings are enough to ask again.
    static let consolidationSizeStep = 5
    /// The length the longest findings are asked to come down to when the findings are over size.
    static let shortFinding = 110

    static let consolidationSystemPrompt = """
    You compact the long-term memory of one software project, the way a long conversation is compacted: \
    nothing still true is lost, it only takes less room. You are given every finding, with how often it was \
    met and when it was last met.
    - Findings that say the same thing, or parts of one thing, become one: return it under the id of the one \
    you keep, its text rewritten to hold what the others added, and put the other ids under "drop".
    - Where two findings contradict each other, keep the one met last and drop the other.
    - Drop a finding that only says what was built or how large it came out. An area - where a concern \
    lives - is kept, one per concern.
    - A finding that stands alone and still holds is left out of your reply: it stays exactly as it is. \
    Never reword one for style.
    - One fact per finding, at most 200 characters, in the language it is written in. Never invent a file, \
    a command or a fact.
    - When a size is given, the findings must come under it: shorten the findings it names, and merge \
    those that are about the same thing. Only words go: every command, flag, path, name and number stays \
    exactly as written, and the sentence still reads as a sentence. Findings about different things are \
    never merged to save room. That is not rewording for style.
    - A finding you keep for others takes over their keywords: list them under "keywords". A finding with \
    none yet is returned with up to 8, its text unchanged - words a request about it would use, in English and \
    in its own language.
    Reply with JSON only:
    {"insights":[{"id":"<the id kept>","kind":"decision|error|lesson|area","text":"...","keywords":["word"]}],"drop":["<id>"]}
    """

    /// Every finding, for the model to consolidate, once enough new ones have been added or
    /// they have grown past the share of a prompt they may take. Past that share the model is
    /// told how far to bring them down. Asked again while each pass shrinks them by a twentieth,
    /// otherwise only after a few findings are added, so a model that cannot is not asked in a loop.
    /// Rules are not shown: they are never merged, reworded or dropped.
    func consolidationPayload() -> String? {
        let file = insightFile()
        let size = insightsSize
        let oversized = size > Self.insightTarget
            && (file.compactAgain == true || file.insights.count >= (file.consolidatedCount ?? 0) + Self.consolidationSizeStep)
        guard oversized || file.insights.count >= (file.consolidatedCount ?? 0) + Self.consolidationStep else { return nil }
        let open = file.insights.filter { !$0.isRule }
        guard !open.isEmpty else { return nil }
        // A size alone is not acted on; the longest findings, named, are. Enough of them that
        // cutting each to the short length frees what is over, plus a margin.
        var target = ""
        if size > Self.insightTarget {
            var freed = 0
            let longest = open.sorted { $0.text.count > $1.text.count }.prefix { insight in
                guard freed < size - Self.insightTarget + 200, insight.text.count > Self.shortFinding else { return false }
                freed += insight.text.count - Self.shortFinding
                return true
            }
            target = "## Size\nTheir text takes \(size) characters of every prompt; bring it under \(Self.insightTarget).\n"
                + "Return each of these at most \(Self.shortFinding) characters long, every fact kept: "
                + longest.map(\.id).joined(separator: ", ") + "\n\n"
        }
        return target + "## Findings\n" + open
            .map { "- \($0.id) [\($0.kind.rawValue)] met \($0.strength)x, last \($0.updatedAt.prefix(10)): \($0.text)"
                + " {keywords: \(($0.keywords ?? []).joined(separator: ", "))}" }
            .joined(separator: "\n")
    }

    /// Folds the model's reply into the findings. Only a known finding can be rewritten and
    /// nothing is added. A reply that would drop more than half is not believed. The count
    /// is noted whatever the reply says, so the model is asked again only after more is learned.
    func applyConsolidation(reply: String) {
        var file = insightFile()
        let before = insightsSize
        defer {
            file.consolidatedCount = file.insights.count
            let after = file.insights.reduce(0) { $0 + Self.shortLine($1).count + 1 }
            file.compactAgain = after > Self.insightTarget && after * 20 < before * 19
            save(file)
        }
        guard let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}"), start < end,
              let object = (try? JSONSerialization.jsonObject(with: Data(reply[start...end].utf8))) as? [String: Any] else { return }
        let rewritten = (object["insights"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
        let open = file.insights.filter { !$0.isRule }
        let dropped = Set(object["drop"] as? [String] ?? []).subtracting(rewritten).intersection(open.map(\.id))
        guard dropped.count * 2 <= open.count else { return }
        for row in object["insights"] as? [[String: Any]] ?? [] {
            let text = sanitize(row["text"] as? String ?? "", limit: 240)
            guard !text.isEmpty, let index = file.insights.firstIndex(where: { $0.id == row["id"] as? String && !$0.isRule }) else { continue }
            file.insights[index].text = text
            if let kind = (row["kind"] as? String).flatMap(MemoryInsight.Kind.parse) { file.insights[index].kind = kind }
            let keywords = (row["keywords"] as? [String] ?? []).map { sanitize($0, limit: 40).lowercased() }.filter { !$0.isEmpty }
            if !keywords.isEmpty {
                let union = NSOrderedSet(array: (file.insights[index].keywords ?? []) + keywords).array as? [String] ?? keywords
                file.insights[index].keywords = Array(union.prefix(Self.maxKeywords))
            }
        }
        file.insights.removeAll { dropped.contains($0.id) }
    }

    /// Compacts the activity log, with no model. A task that is running, or whose note is
    /// still kept, keeps its calls in full: a scan reads them in order. The calls of every
    /// other task become one count per tool, and the rest of what was logged about it,
    /// which nothing reads, goes. Returns whether the log got smaller.
    @discardableResult
    func compactActivity() -> Bool {
        guard let root = userMemoryDirectory else { return false }
        let log = root.appendingPathComponent("activity.jsonl")
        let identity = activityFileIdentity(at: log)
        let notes = (try? fileManager.contentsOfDirectory(at: root.appendingPathComponent("tasks"), includingPropertiesForKeys: nil)) ?? []
        let live = Set(tasks.keys).union(notes.map { $0.deletingPathExtension().lastPathComponent })
        let cursor = activityCompactionCursor
        let canResume = cursor.flatMap { cursor in
            identity.map { identity in
                cursor.path == log.path
                    && cursor.deviceNumber == identity.deviceNumber
                    && cursor.fileNumber == identity.fileNumber
                    && identity.size >= cursor.offset
                    && cursor.liveRunIDs.isSubset(of: live)
            }
        } ?? false
        if canResume, let cursor, let identity, identity.size == cursor.offset {
            activityCompactionCursor?.liveRunIDs = live
            return false
        }

        let startOffset = canResume ? cursor?.offset ?? 0 : 0
        guard let data = readActivityData(from: log, offset: startOffset),
              let text = String(data: data, encoding: .utf8) else { return false }

        var kept: [String] = []
        var counts: [String: [String: Int]] = [:]
        var counted = Set<String>()
        var folded = false
        for line in text.split(separator: "\n") {
            guard let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  let payload = object["payload"] as? [String: Any] else { kept.append(String(line)); continue }
            let run = payload["runId"] as? String ?? ""
            if live.contains(run) { kept.append(String(line)); continue }
            func add(_ id: String, calls: Int, failed: Int, runs: Int) {
                counts[id, default: [:]].merge(["calls": calls, "failed": failed, "runs": runs]) { $0 + $1 }
            }
            switch object["type"] as? String {
            case Self.toolSummaryType:
                add(payload["id"] as? String ?? "", calls: payload["calls"] as? Int ?? 0, failed: payload["failed"] as? Int ?? 0, runs: payload["runs"] as? Int ?? 0)
                continue
            case "tool.executed", "skill.used":
                let id = payload["skill"].map { Self.skillNotePrefix + "\($0)" } ?? Self.toolNotePrefix + (payload["name"] as? String ?? "")
                add(id, calls: 1, failed: payload["resultStatus"] as? String == "failed" ? 1 : 0, runs: counted.insert(run + id).inserted ? 1 : 0)
            default:
                break
            }
            folded = true
        }
        let summaries = counts.keys.sorted().compactMap { id -> String? in
            var payload: [String: Any] = counts[id] ?? [:]
            payload["id"] = id
            let object: [String: Any] = ["schemaVersion": 1, "type": Self.toolSummaryType, "payload": payload]
            return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])).flatMap { String(data: $0, encoding: .utf8) }
        }
        var offset = startOffset + UInt64(data.count)
        if folded {
            let replacement = (summaries + kept).map { $0 + "\n" }.joined()
            guard let replacementData = replacement.data(using: .utf8) else { return false }
            if canResume {
                // The prefix was already scanned. Replace only the newly appended suffix,
                // preserving the compacted records without rereading or rewriting them.
                guard replaceActivitySuffix(at: log, offset: startOffset, original: data, with: replacementData) else {
                    activityCompactionCursor = nil
                    return false
                }
                offset = startOffset + UInt64(replacementData.count)
            } else {
                guard (try? replacement.write(to: log, atomically: true, encoding: .utf8)) != nil else { return false }
                offset = UInt64(replacementData.count)
            }
        }

        if let updatedIdentity = activityFileIdentity(at: log) {
            activityCompactionCursor = ActivityCompactionCursor(
                path: log.path,
                deviceNumber: updatedIdentity.deviceNumber,
                fileNumber: updatedIdentity.fileNumber,
                offset: offset,
                liveRunIDs: live
            )
        } else {
            activityCompactionCursor = nil
        }
        return folded
    }

    private func activityFileIdentity(at log: URL) -> (size: UInt64, deviceNumber: UInt64, fileNumber: UInt64)? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: log.path),
              let size = (attributes[.size] as? NSNumber)?.uint64Value,
              let deviceNumber = (attributes[.systemNumber] as? NSNumber)?.uint64Value,
              let fileNumber = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value else { return nil }
        return (size, deviceNumber, fileNumber)
    }

    private func readActivityData(from log: URL, offset: UInt64) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: log) else { return nil }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: offset)
            return try handle.readToEnd() ?? Data()
        } catch {
            return nil
        }
    }

    private func replaceActivitySuffix(at log: URL, offset: UInt64, original: Data, with replacement: Data) -> Bool {
        guard let handle = try? FileHandle(forUpdating: log) else { return false }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: offset)
            try handle.truncate(atOffset: offset)
            try handle.write(contentsOf: replacement)
            try handle.synchronize()
            return true
        } catch {
            // Restore the bytes we just replaced if the update fails partway through.
            do {
                try handle.seek(toOffset: offset)
                try handle.truncate(atOffset: offset)
                try handle.write(contentsOf: original)
                try handle.synchronize()
            } catch { }
            return false
        }
    }
}

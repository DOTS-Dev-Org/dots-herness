// Copyright (c) 2026 DOTS
// Task, decision and chat notes. Task and chat notes are the person's and live in
// the user layer; decision notes are project memory and live in the repository.

import CryptoKit
import Foundation
import PluginRuntime

public enum WorkspaceBacklogText {
    public static func visibleText(_ text: String, hidePartialMarkerTail: Bool = false) -> String {
        // Runs on the whole live reply ten times a second. Without "backlog" anywhere no
        // line is a marker, and only a last line that may be starting one can be hidden.
        if text.range(of: "backlog", options: .caseInsensitive) == nil {
            guard hidePartialMarkerTail else { return text }
            // Scalars, not Characters: "\r\n" is one Character and would hide the newline.
            let scalars = text.unicodeScalars
            let newline = scalars.lastIndex(of: "\n")
            let tail = String(scalars[(newline.map(scalars.index(after:)) ?? scalars.startIndex)...])
            let value = tail.trimmingCharacters(in: CharacterSet(charactersIn: " \t\r")).lowercased()
            guard !value.isEmpty, "backlog:".hasPrefix(value) || "backlog-done:".hasPrefix(value) else { return text }
            return newline.map { String(scalars[..<$0]) } ?? ""
        }
        let lines = text.components(separatedBy: "\n")
        let visible = lines.enumerated().compactMap { index, line -> String? in
            let value = line.trimmingCharacters(in: CharacterSet(charactersIn: " \t\r"))
            let lower = value.lowercased()
            if lower.hasPrefix("backlog:") || lower.hasPrefix("backlog-done:") { return nil }
            if hidePartialMarkerTail, index == lines.count - 1, !value.isEmpty,
               ("backlog:".hasPrefix(lower) || "backlog-done:".hasPrefix(lower)) { return nil }
            return line
        }
        return visible.joined(separator: "\n")
    }
}

extension WorkspaceMemory {
    func beginTask(runID: UUID, prompt: String, provider: String, model: String) {
        let summary = sanitize(prompt, limit: 240)
        let task = TaskRecord(
            runID: runID.uuidString,
            promptSummary: summary,
            promptHash: digest(Data(prompt.utf8)),
            startedAt: isoNow(),
            provider: provider,
            model: model
        )
        tasks[runID.uuidString] = task
        recordActivity(type: "task.started", payload: [
            "runId": task.runID,
            "startedAt": task.startedAt,
            "provider": sanitize(provider, limit: 80),
            "model": sanitize(model, limit: 120),
            "memoryRevision": revision,
        ])
    }

    func writeTaskNote(_ task: TaskRecord, status: String, finalText: String, openItems: [String] = []) {
        guard let root = userMemoryDirectory else { return }
        let changedPaths = task.changedFiles.compactMap { $0["path"] as? String }
        let fileLinks = changedPaths.map { "file:\($0)" }
        let decisionLinks = (state["acceptedDecisions"] as? [[String: Any]] ?? [])
            .filter { decisionRunID($0) == task.runID }
            .compactMap { $0["eventId"] as? String }
            .map { "decision-\($0)" }
        let links = ["index"] + decisionLinks + fileLinks
        let front = frontmatter([
            "id": "task-\(task.runID)",
            "type": "task",
            "title": quoted(task.promptSummary, limit: 120),
            "created": task.startedAt,
            "completed": isoNow(),
            "revision": String(revision),
            "actor": identity?.personID ?? "unknown",
            "status": status,
        ], tags: ["task", status], links: links)
        let filesBlock = changedPaths.isEmpty
            ? "- None recorded"
            : changedPaths.map { "- [[file:\($0)]] — modified" }.joined(separator: "\n")
        let decisionsBlock = decisionLinks.isEmpty
            ? "- Decisions remain event-backed and are not edited by the model."
            : decisionLinks.map { "- [[\($0)]]" }.joined(separator: "\n")
        let note = [
            front,
            "# Task: \(task.runID)",
            "",
            "Back to [[index]] · [[map]]",
            "",
            "- Actor: \(identity?.personID ?? "unknown")",
            "- Device: \(identity?.deviceID ?? "unknown")",
            "- Started: \(task.startedAt)",
            "- Completed: \(isoNow())",
            "- Status: \(status)",
            "",
            "## Request summary",
            "",
            task.promptSummary,
            "",
            "## Changed files",
            "",
            filesBlock,
            "",
            "## Result",
            "",
            sanitize(finalText, limit: 600),
            "",
            "## Open items",
            "",
            openItems.isEmpty ? "- None" : openItems.map { "- [ ] \($0)" }.joined(separator: "\n"),
            "",
            "## Decisions",
            "",
            decisionsBlock,
        ].joined(separator: "\n")
        try? fileManager.createDirectory(at: root.appendingPathComponent("tasks"), withIntermediateDirectories: true)
        try? note.write(to: root.appendingPathComponent("tasks").appendingPathComponent("\(task.runID).md"), atomically: true, encoding: .utf8)
        // The files this task changed are now found by its words; see `taskFileTerms()`.
        // Marked stale, not dropped: dropping it rebuilt the index on the main actor at the
        // next prompt. The symbol cache is keyed by file date, so it stays valid.
        fileIndex?.stamp = .distantPast
    }

    func writeDecisionNotes() {
        for decision in state["acceptedDecisions"] as? [[String: Any]] ?? [] {
            writeDecisionNote(decision)
        }
        writeIndexNote()
    }

    /// One accepted decision note. Writing the whole set per event rewrote every
    /// decision file for a single append, so the append path calls this for the
    /// decision it just folded in.
    func writeDecisionNote(_ decision: [String: Any]) {
        guard let root = memoryDirectory,
              let eventID = decision["eventId"] as? String else { return }
        let payload = decision["payload"] as? [String: Any] ?? [:]
        let summary = payload["summary"] as? String ?? payload["value"] as? String ?? "Accepted project decision"
        let supersedes = (decision["supersedes"] as? [String] ?? []).map { "decision-\($0)" }
        // No link to the task that proposed it: that note is the person's, and a
        // repository file must not name one. The run id stays in the event payload.
        let links = ["index"] + supersedes
        let front = frontmatter([
            "id": "decision-\(eventID)",
            "type": "decision",
            "title": quoted(summary, limit: 120),
            "status": "accepted",
            "revision": String(decision["lamport"] as? Int ?? 0),
            "actor": (decision["actor"] as? [String: Any])?["personId"] as? String ?? "unknown",
        ], tags: ["decision", "accepted"], links: links)
        let related = supersedes.isEmpty ? "" : "\n## Supersedes\n\n" + supersedes.map { "- [[\($0)]]" }.joined(separator: "\n") + "\n"
        let note = [
            front,
            "# Decision: \(eventID)",
            "",
            "Back to [[index]]",
            "",
            "- Status: accepted",
            "- Actor: \((decision["actor"] as? [String: Any])?["personId"] as? String ?? "unknown")",
            "- Revision: \(decision["lamport"] as? Int ?? 0)",
            "",
            "## Summary",
            "",
            sanitize(summary, limit: 600),
            related,
        ].joined(separator: "\n")
        let directory = root.appendingPathComponent("decisions", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try? note.write(to: directory.appendingPathComponent("\(eventID).md"), atomically: true, encoding: .utf8)
    }

    /// Writes the lifecycle note of one chat. Chats are the person's, so the note goes
    /// to the user layer; the repository never learns which chats exist.
    func writeConversationNote(conversationID: String, record: [String: Any]) {
        guard let root = userMemoryDirectory else { return }
        let directory = root.appendingPathComponent("conversations", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let title = sanitize(record["title"] as? String ?? conversationID, limit: 120)
        let lifecycle = record["state"] as? String ?? "unknown"
        let updated = record["updatedAt"] as? String ?? ""
        let noteID = conversationNoteID(conversationID)
        let meaning: String
        switch lifecycle {
        case ConversationLifecycleState.archived.rawValue:
            meaning = "The chat is hidden from active conversations. Its task result is unchanged."
        case ConversationLifecycleState.restored.rawValue:
            meaning = "The chat was returned to active conversations. Its task result is unchanged."
        case ConversationLifecycleState.deleted.rawValue:
            meaning = "The chat was deleted. This memory record is retained as an audit trail."
        default:
            meaning = "The chat lifecycle was updated."
        }
        let front = frontmatter([
            "id": noteID,
            "type": "conversation",
            "title": quoted(title, limit: 120),
            "state": lifecycle,
            "updated": updated,
            "revision": String(record["revision"] as? Int ?? 0),
            "actor": identity?.personID ?? "unknown",
        ], tags: ["conversation", lifecycle], links: ["index"])
        let note = [
            front,
            "# Conversation: \(title)",
            "",
            "Back to [[index]]",
            "",
            "- Lifecycle: \(lifecycle.capitalized)",
            "- Updated: \(updated)",
            "- Conversation ID: `\(sanitize(conversationID, limit: 120))`",
            "",
            "## What this means",
            "",
            meaning,
            "",
            "Task success or failure is recorded separately in the related task note.",
        ].joined(separator: "\n")
        try? note.write(
            to: directory.appendingPathComponent("\(noteID).md"),
            atomically: true,
            encoding: .utf8
        )
    }

    private func conversationNoteID(_ conversationID: String) -> String {
        "conversation-\(String(digest(Data(conversationID.utf8)).prefix(16)))"
    }

    private func decisionRunID(_ event: [String: Any]) -> String? {
        let payload = event["payload"] as? [String: Any] ?? [:]
        return payload["runId"] as? String ?? payload["runID"] as? String
    }

    /// Backlog directives are internal control text, so never show their lines to people.
    func visibleText(in text: String, hidePartialMarkerTail: Bool = false) -> String {
        WorkspaceBacklogText.visibleText(text, hidePartialMarkerTail: hidePartialMarkerTail)
    }

    /// Backlog markers the model writes into its final reply. Frees the note
    /// format from guessing which runs left work open.
    func openItems(in finalText: String) -> [String] {
        finalText.split(whereSeparator: \.isNewline).compactMap { line in
            let value = line.trimmingCharacters(in: .whitespaces)
            guard value.lowercased().hasPrefix("backlog:") else { return nil }
            let item = sanitize(String(value.dropFirst("backlog:".count)), limit: 200)
            return item.isEmpty ? nil : item
        }
    }

    private func taskNoteURLs() -> [URL] {
        guard let root = userMemoryDirectory,
              let files = try? fileManager.contentsOfDirectory(at: root.appendingPathComponent("tasks"), includingPropertiesForKeys: nil)
        else { return [] }
        return files.filter { $0.pathExtension == "md" }
    }

    /// Deletes one task note and every activity record of that task, for good. The
    /// person asked for it to be gone, so nothing of it is kept here.
    public func deleteTaskNote(runID: String) throws {
        guard let root = userMemoryDirectory else { throw WorkspaceMemoryError.noWorkspace }
        try? fileManager.removeItem(at: root.appendingPathComponent("tasks", isDirectory: true).appendingPathComponent("\(runID).md"))
        purgeActivity { ($0["payload"] as? [String: Any])?["runId"] as? String == runID }
        forgetInsights(ofRun: runID)
    }

    /// Deletes one chat's lifecycle note, and the activity records of that chat.
    /// `noteID` is the note's id, which is also its file name.
    public func deleteConversationNote(noteID: String) throws {
        guard let root = userMemoryDirectory else { throw WorkspaceMemoryError.noWorkspace }
        try? fileManager.removeItem(at: root.appendingPathComponent("conversations", isDirectory: true).appendingPathComponent("\(noteID).md"))
        purgeActivity { object in
            guard let conversationID = (object["payload"] as? [String: Any])?["conversationId"] as? String else { return false }
            return conversationNoteID(conversationID) == noteID
        }
    }

    /// Rewrites the activity log without the records that match.
    func purgeActivity(where matches: ([String: Any]) -> Bool) {
        guard let url = userMemoryDirectory?.appendingPathComponent("activity.jsonl"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let kept = text.split(separator: "\n").filter { line in
            guard let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { return true }
            return !matches(object)
        }
        try? kept.map { $0 + "\n" }.joined().write(to: url, atomically: true, encoding: .utf8)
    }

    /// `BACKLOG-DONE: <run id>` in a reply flips that note out of the backlog.
    func closeBacklog(mentionedIn finalText: String) {
        let text = finalText.lowercased()
        guard text.contains("backlog-done:") else { return }
        for url in taskNoteURLs() {
            let runID = url.deletingPathExtension().lastPathComponent
            guard text.contains(runID.lowercased()),
                  var note = try? String(contentsOf: url, encoding: .utf8) else { continue }
            note = note.replacingOccurrences(of: "status: unfinished", with: "status: completed")
                .replacingOccurrences(of: "status: failed", with: "status: completed")
                .replacingOccurrences(of: "- [ ] ", with: "- [x] ")
            try? note.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    func backlogText() -> String {
        taskNoteURLs().sorted { $0.lastPathComponent > $1.lastPathComponent }.compactMap { url -> String? in
            guard let note = MemoryFileCache.text(at: url),
                  note.contains("status: unfinished") || note.contains("status: failed") else { return nil }
            let title = note.split(whereSeparator: \.isNewline)
                .first { $0.hasPrefix("title:") }
                .map { String($0.dropFirst("title:".count)).trimmingCharacters(in: CharacterSet(charactersIn: " \"")) } ?? "untitled"
            let items = note.split(whereSeparator: \.isNewline)
                .filter { $0.hasPrefix("- [ ] ") }
                .map { "  " + $0 }
                .joined(separator: "\n")
            let id = url.deletingPathExtension().lastPathComponent
            return "- `\(id)` — \(title)" + (items.isEmpty ? "" : "\n\(items)")
        }.prefix(5).joined(separator: "\n")
    }

    /// Up to three earlier tasks, best term overlap first and newest first among
    /// equals. Only tasks sharing a word are included. Each is one compact entry - the
    /// request, the files and the outcome - not the whole note: this text is
    /// captured again whenever the selection changes.
    func relevantTasks(for prompt: String) -> String {
        let terms = FeedbackStore.tokens(prompt)
        let scored = taskNoteURLs().compactMap { url -> (score: Int, completed: String, entry: String)? in
            // Score first: only the few notes sharing a word need their sections parsed.
            guard let noteTerms = MemoryFileCache.tokens(at: url),
                  !terms.isDisjoint(with: noteTerms),
                  let note = MemoryFileCache.text(at: url) else { return nil }
            let lines = note.split(whereSeparator: \.isNewline).map(String.init)
            func section(_ title: String) -> [String] {
                guard let start = lines.firstIndex(of: "## \(title)") else { return [] }
                return Array(lines[(start + 1)...].prefix { !$0.hasPrefix("## ") })
            }
            let files = section("Changed files")
                .compactMap { $0.firstMatch(of: #/\[\[file:(.+?)\]\]/#).map { String($0.1) } }
            let result = sanitize(section("Result").joined(separator: " "), limit: 600)
            let completed = taskNoteField("completed", in: lines)
            let runID = url.deletingPathExtension().lastPathComponent
            var entry = "- \(completed.prefix(10)) [\(taskNoteField("status", in: lines))] \(taskNoteField("title", in: lines)) (task \(runID))"
            if !files.isEmpty { entry += "\n  Files: \(files.prefix(8).joined(separator: ", "))" }
            if !result.isEmpty { entry += "\n  Result: \(result)" }
            let score = terms.intersection(noteTerms).count
            return (score, completed, entry)
        }
        let matched = scored.filter { $0.score > 0 }
        return matched
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.completed > $1.completed }
            .prefix(3)
            .map(\.entry)
            .joined(separator: "\n")
    }

    /// The repository's files named like the request, so the agent opens them instead
    /// of sweeping the workspace for where to start.
    /// ponytail: the list follows git's index, so a workspace that is not a repository
    /// root gets none and a file not yet added is missed until the index moves.
    func relevantFiles(for prompt: String) -> String {
        guard let workspaceURL,
              let stamp = (try? fileManager.attributesOfItem(atPath: workspaceURL.appendingPathComponent(".git/index").path))?[.modificationDate] as? Date
        else { return "" }
        if fileIndex?.workspace != workspaceURL {
            // First request in this workspace: it needs an index now.
            let paths = Self.gitLines(["ls-files", "--cached", "--others", "--exclude-standard"], workspace: workspaceURL)
            let learned = Self.taskFileTerms(taskNoteURLs())
            let changes = Self.lastChanges(workspace: workspaceURL)
            fileIndex = (workspaceURL, stamp, FileIndex(paths: paths, learned: learned, symbols: symbolCache.mapValues(\.names)), changes)
            scheduleFileIndexRebuild(workspaceURL, stamp: stamp, paths: paths, learned: learned, changes: changes)
        } else if fileIndex?.stamp != stamp, fileIndexRebuildStamp != stamp {
            // Git's index moves on nearly every turn: answer from the previous index and
            // rebuild off the main actor (two git runs, every task note, 20k paths).
            scheduleFileIndexRebuild(workspaceURL, stamp: stamp, paths: nil, learned: nil, changes: nil)
        }
        guard let fileIndex else { return "" }
        return fileIndex.index.hits(prompt).map { hit in
            var line = "- `\(hit.path)`"
            if !hit.symbols.isEmpty { line += " (\(hit.symbols.joined(separator: ", ")))" }
            if let change = fileIndex.changes[hit.path] { line += " - last changed \(sanitize(change, limit: 100))" }
            return line
        }.joined(separator: "\n")
    }

    /// Replaces `fileIndex` with one built off the main actor, symbols included. Reading
    /// every source file would hold a request up, so the current index answers until then.
    private func scheduleFileIndexRebuild(
        _ workspaceURL: URL, stamp: Date,
        paths: [String]?, learned: [String: Set<String>]?, changes: [String: String]?
    ) {
        fileIndexRebuildStamp = stamp
        let known = symbolCache
        let noteURLs = taskNoteURLs()
        symbolScan?.cancel()
        symbolScan = Task.detached(priority: .utility) { [weak self] in
            let paths = paths ?? Self.gitLines(["ls-files", "--cached", "--others", "--exclude-standard"], workspace: workspaceURL)
            let learned = learned ?? Self.taskFileTerms(noteURLs)
            let changes = changes ?? Self.lastChanges(workspace: workspaceURL)
            let scanned = FileIndex.scanSymbols(paths: paths, workspace: workspaceURL, known: known)
            let index = FileIndex(paths: paths, learned: learned, symbols: scanned.mapValues(\.names))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.workspaceURL == workspaceURL else { return }
                self.symbolCache = scanned
                if self.fileIndexRebuildStamp == stamp { self.fileIndexRebuildStamp = nil }
                self.fileIndex = (workspaceURL, stamp, index, changes)
            }
        }
    }

    /// Each file's latest commit, as "date subject", so the agent knows when and why a
    /// file last moved without running `git log` itself.
    /// ponytail: the last 300 commits, read when git's index moves; an older file has
    /// no line, and uncommitted work shows only in the task history beside this list.
    nonisolated static func lastChanges(workspace: URL) -> [String: String] {
        var changes: [String: String] = [:]
        var commit = ""
        for line in gitLines(["log", "-n", "300", "--name-only", "--format=%x01%cs %s"], workspace: workspace) {
            if line.hasPrefix("\u{1}") { commit = String(line.dropFirst()) } else if changes[line] == nil { changes[line] = commit }
        }
        return changes
    }

    /// The words of each earlier request, by the files that request changed: "the payment
    /// flow" then finds `paytr.ts`, which its name alone never would.
    func taskFileTerms() -> [String: Set<String>] { Self.taskFileTerms(taskNoteURLs()) }

    nonisolated static func taskFileTerms(_ noteURLs: [URL]) -> [String: Set<String>] {
        var terms: [String: Set<String>] = [:]
        for url in noteURLs {
            guard let note = MemoryFileCache.text(at: url),
                  let summary = note.components(separatedBy: "\n## Request summary\n").dropFirst().first?
                      .components(separatedBy: "\n## Changed files\n").first else { continue }
            let words = FeedbackStore.tokens(summary)
            for match in note.matches(of: #/\[\[file:(.+?)\]\]/#) {
                terms[String(match.1), default: []].formUnion(words)
            }
        }
        return terms
    }

    /// The person's preferences for this project. Preferences that hold everywhere
    /// are in `UserProfile.text`, so they are not repeated here.
    public func preferencesText() -> String {
        guard let projectID else { return "" }
        let projectKeys = Set(projectMemoryFacts().map { $0.key.lowercased() })
        let preferences = profile.projectPreferences(projectID: projectID)
            .filter { !projectKeys.contains($0.key.lowercased()) }
        return markdownDictionary(preferences.mapValues { $0 as Any })
    }

    func markdownList(_ list: [[String: Any]], prefix: String = "Decision") -> String {
        list.map { item in
            let id = item["eventId"] as? String ?? "unknown"
            let payload = item["payload"] as? [String: Any] ?? item
            let summary = payload["summary"] as? String ?? payload["key"] as? String ?? payload["value"] as? String ?? id
            return "- \(prefix) `\(id)`: \(sanitize(summary, limit: 240))"
        }.joined(separator: "\n")
    }

    func decisionKey(_ event: [String: Any]) -> String {
        let payload = event["payload"] as? [String: Any] ?? [:]
        return payload["key"] as? String ?? payload["summary"] as? String ?? event["eventId"] as? String ?? "unknown"
    }

    func eventWins(_ candidate: [String: Any], over current: [String: Any]) -> Bool {
        let left = (candidate["lamport"] as? Int ?? 0, candidate["eventId"] as? String ?? "")
        let right = (current["lamport"] as? Int ?? 0, current["eventId"] as? String ?? "")
        return left.0 == right.0 ? left.1 > right.1 : left.0 > right.0
    }

    func markdownDictionary(_ dictionary: [String: Any]) -> String {
        dictionary.keys.sorted().map { key in
            "- `\(key)`: \(sanitize(String(describing: dictionary[key] ?? ""), limit: ProjectKnowledge.limit(forKey: key)))"
        }.joined(separator: "\n")
    }

    func trimSnapshot(_ text: String) -> String {
        let limit = 32_000
        guard text.utf8.count > limit else { return text }
        return String(text.prefix(limit)) + "\n[older memory trimmed]"
    }

    func explicitLanguage(in text: String) -> String? {
        // Needles are written already folded: the text loses its diacritics below,
        // so "türkçe" or "konuş" could never match it.
        let lower = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX")).lowercased()
        let markers = ["artık", "artik", "bundan sonra", "from now", "i want", "istiyorum", "tercih",
                       "cevap ver", "yanit ver", "konus", "always", "her zaman", "output"]
        guard markers.contains(where: { lower.contains($0) }) else { return nil }
        if lower.contains("ingilizce") || lower.contains("english") { return "English" }
        if lower.contains("turkce") || lower.contains("turkish") { return "Turkish" }
        return nil
    }

    func explicitDecision(in text: String) -> String? {
        let lower = text.lowercased()
        let markers = ["karar:", "decision:", "kullanalım", "we will use", "let's use"]
        guard markers.contains(where: { lower.contains($0) }) else { return nil }
        let value = text.replacingOccurrences(of: "\n", with: " ")
        return sanitize(value, limit: 240)
    }
}

/// File paths by the words of their names and of what they declare.
/// ponytail: declarations are found by keyword, not parsed, and word overlap, not
/// embeddings; a request in other words than the code's own ("hafıza penceresi" for
/// MemoryVaultView) finds nothing. Add embeddings when that is seen sending the agent
/// searching.
/// Task notes, facts and decisions are re-read for every prompt and grow without
/// limit. Keyed by date and size, so an edit (ours or the person's) is seen at once.
/// ponytail: one process-wide table, cleared past 4,000 files.
enum MemoryFileCache {
    private struct Entry {
        let stamp: FeedbackStore.FileStamp
        let text: String
        var tokens: Set<String>?
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var entries: [String: Entry] = [:]

    static func text(at url: URL) -> String? {
        entry(at: url)?.text
    }

    /// `FeedbackStore.tokens` of the whole file, computed once per version.
    static func tokens(at url: URL) -> Set<String>? {
        guard let entry = entry(at: url) else { return nil }
        if let tokens = entry.tokens { return tokens }
        let tokens = FeedbackStore.tokens(entry.text)
        lock.lock()
        if entries[url.path]?.stamp == entry.stamp { entries[url.path]?.tokens = tokens }
        lock.unlock()
        return tokens
    }

    private static func entry(at url: URL) -> Entry? {
        let stamp = FeedbackStore.FileStamp(url, fileManager: .default)
        guard stamp.modified != nil else { return nil }
        lock.lock()
        if let entry = entries[url.path], entry.stamp == stamp {
            lock.unlock()
            return entry
        }
        lock.unlock()
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let entry = Entry(stamp: stamp, text: text)
        lock.lock()
        if entries.count > 4_000 { entries.removeAll() }
        entries[url.path] = entry
        lock.unlock()
        return entry
    }
}

struct FileIndex {
    typealias Symbols = (modified: Date, names: [String])

    /// ponytail: the first 20,000 files; a larger repository is indexed in part.
    static let limit = 20_000
    let names: [(path: String, tokens: Set<String>, symbols: [String], symbolTokens: Set<String>)]
    let frequency: [String: Int]
    let symbolFrequency: [String: Int]

    /// `learned` adds, per path, the words of the requests that changed that file;
    /// `symbols`, per path, the names it declares.
    /// ponytail: a word counts the same from a request as from the name, and a request
    /// that changed more than 30 files teaches none of them (the frequency cut below).
    init(paths: [String], learned: [String: Set<String>] = [:], symbols: [String: [String]] = [:]) {
        // Git quotes a path it had to escape; such a name is not worth showing a model.
        names = paths.lazy.filter { !$0.hasPrefix("\"") && $0.count <= 200 }.prefix(Self.limit).map { path in
            let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            let declared = symbols[path] ?? []
            return (path, Self.words(name).union(learned[path] ?? []), declared, declared.reduce(into: []) { $0.formUnion(Self.words($1)) })
        }
        frequency = names.reduce(into: [:]) { counts, entry in entry.tokens.forEach { counts[$0, default: 0] += 1 } }
        symbolFrequency = names.reduce(into: [:]) { counts, entry in entry.symbolTokens.forEach { counts[$0, default: 0] += 1 } }
    }

    /// "MemoryVaultView" is found by "memory", "vault" and by its whole name.
    static func words(_ name: String) -> Set<String> {
        var spaced = ""
        var previous: Character = " "
        for character in name {
            if character.isUppercase, previous.isLowercase || previous.isNumber { spaced.append(" ") }
            spaced.append(character)
            previous = character
        }
        return FeedbackStore.tokens(name).union(FeedbackStore.tokens(spaced))
    }

    func matching(_ prompt: String, limit: Int = 12) -> [String] {
        hits(prompt, limit: limit).map(\.path)
    }

    /// The best files for a request, each with the declarations the request names.
    func hits(_ prompt: String, limit: Int = 12) -> [(path: String, symbols: [String])] {
        let terms = FeedbackStore.tokens(prompt)
        guard !terms.isEmpty else { return [] }
        return names.compactMap { entry -> (score: Double, path: String, symbols: [String])? in
            // A word many files are named after ("view", "tests") points nowhere.
            var score = entry.tokens.intersection(terms).reduce(0.0) { total, token in
                let count = frequency[token] ?? 1
                return count > 30 ? total : total + 1 + 1 / Double(count)
            }
            // A declaration says less about a file than its name does: half the weight.
            score += entry.symbolTokens.intersection(terms).subtracting(entry.tokens).reduce(0.0) { total, token in
                let count = symbolFrequency[token] ?? 1
                return count > 30 ? total : total + 0.5 + 1 / Double(count)
            }
            return score > 0 ? (score, entry.path, entry.symbols) : nil
        }
        .sorted { $0.score != $1.score ? $0.score > $1.score : $0.path < $1.path }
        .prefix(limit)
        .map { hit in (hit.path, Array(hit.symbols.filter { !Self.words($0).isDisjoint(with: terms) }.prefix(4))) }
    }

    static let sourceExtensions: Set<String> = [
        "swift", "ts", "tsx", "js", "jsx", "cs", "py", "go", "rs", "kt", "java", "dart", "c", "h", "cpp", "m", "mm", "rb", "php",
    ]
    private static let declaration = try! NSRegularExpression(
        pattern: #"\b(?:class|struct|enum|protocol|extension|interface|trait|actor|func|fun|fn|def|function|type|record|namespace)\s+([A-Za-z_]\w{2,})"#
    )

    /// The names a source text declares, in order, each once.
    /// ponytail: a keyword followed by a name; a C# or Java method has no keyword and is
    /// missed, and a keyword inside a comment or a string is taken. Parse when it matters.
    static func symbols(in text: String) -> [String] {
        var seen = Set<String>()
        let source = text as NSString
        return declaration.matches(in: text, range: NSRange(location: 0, length: source.length))
            .map { source.substring(with: $0.range(at: 1)) }
            .filter { seen.insert($0).inserted }
            .prefix(200).map { $0 }
    }

    /// Reads what each source file declares; a file whose date has not moved keeps what
    /// was read before.
    /// ponytail: the first 5,000 source files, none over 300 KB.
    static func scanSymbols(paths: [String], workspace: URL, known: [String: Symbols]) -> [String: Symbols] {
        var result: [String: Symbols] = [:]
        for path in paths.lazy.filter({ sourceExtensions.contains(($0 as NSString).pathExtension.lowercased()) }).prefix(5_000) {
            if Task.isCancelled { break }
            let url = workspace.appendingPathComponent(path)
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let modified = attributes[.modificationDate] as? Date,
                  (attributes[.size] as? Int ?? .max) <= 300_000 else { continue }
            if let kept = known[path], kept.modified == modified {
                result[path] = kept
            } else if let text = try? String(contentsOf: url, encoding: .utf8) {
                result[path] = (modified, symbols(in: text))
            }
        }
        return result
    }
}

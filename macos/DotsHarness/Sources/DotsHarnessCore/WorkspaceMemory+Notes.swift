// Copyright (c) 2026 DOTS
// Task, decision and conversation notes.

import CryptoKit
import Foundation
import PluginRuntime

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
        _ = try? writeEvent(type: "task.started", scope: "task", payload: [
            "runId": task.runID,
            "promptSummary": task.promptSummary,
            "promptHash": task.promptHash,
            "startedAt": task.startedAt,
            "provider": sanitize(provider, limit: 80),
            "model": sanitize(model, limit: 120),
            "memoryRevision": revision,
        ])
    }

    func writeTaskNote(_ task: TaskRecord, status: String, finalText: String, openItems: [String] = []) {
        guard let root = memoryDirectory else { return }
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
        writeIndexNote()
        writePreferencesNote()
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
        let runID = decisionRunID(decision)
        let taskLink = runID.map { "task-\($0)" }
        let links = ["index"] + supersedes + (taskLink.map { [$0] } ?? [])
        let front = frontmatter([
            "id": "decision-\(eventID)",
            "type": "decision",
            "title": quoted(summary, limit: 120),
            "status": "accepted",
            "revision": String(decision["lamport"] as? Int ?? 0),
            "actor": (decision["actor"] as? [String: Any])?["personId"] as? String ?? "unknown",
        ], tags: ["decision", "accepted"], links: links)
        let related = supersedes.isEmpty ? "" : "\n## Supersedes\n\n" + supersedes.map { "- [[\($0)]]" }.joined(separator: "\n") + "\n"
        let origin = taskLink.map { "\n## Origin\n\n- [[\($0)]]\n" } ?? ""
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
            origin,
        ].joined(separator: "\n")
        let directory = root.appendingPathComponent("decisions", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try? note.write(to: directory.appendingPathComponent("\(eventID).md"), atomically: true, encoding: .utf8)
    }

    func writeConversationNotes() {
        guard memoryDirectory != nil else { return }
        let conversations = state["conversationStates"] as? [String: Any] ?? [:]
        for conversationID in conversations.keys.sorted() {
            guard let record = conversations[conversationID] as? [String: Any] else { continue }
            writeConversationNote(conversationID: conversationID, record: record)
        }
    }

    func writeConversationNote(conversationID: String, record: [String: Any]) {
        guard let root = memoryDirectory else { return }
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

    /// Refreshes just the conversation a lifecycle event touched.
    func writeConversationNote(for event: [String: Any]) {
        guard let conversationID = (event["payload"] as? [String: Any])?["conversationId"] as? String,
              let record = (state["conversationStates"] as? [String: Any])?[conversationID] as? [String: Any]
        else { return }
        writeConversationNote(conversationID: conversationID, record: record)
    }

    private func conversationNoteID(_ conversationID: String) -> String {
        "conversation-\(String(digest(Data(conversationID.utf8)).prefix(16)))"
    }

    private func decisionRunID(_ event: [String: Any]) -> String? {
        let payload = event["payload"] as? [String: Any] ?? [:]
        return payload["runId"] as? String ?? payload["runID"] as? String
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
        guard let root = memoryDirectory,
              let files = try? fileManager.contentsOfDirectory(at: root.appendingPathComponent("tasks"), includingPropertiesForKeys: nil)
        else { return [] }
        return files.filter { $0.pathExtension == "md" }
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
            guard let note = try? String(contentsOf: url, encoding: .utf8),
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
    /// equals; with no overlap, the three newest. Each is one compact entry - the
    /// request, the files and the outcome - not the whole note: this text is
    /// captured again whenever the selection changes.
    func relevantTasks(for prompt: String) -> String {
        let terms = FeedbackStore.tokens(prompt)
        let scored = taskNoteURLs().compactMap { url -> (score: Int, completed: String, entry: String)? in
            guard let note = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            let lines = note.split(whereSeparator: \.isNewline).map(String.init)
            func field(_ name: String) -> String {
                lines.first { $0.hasPrefix("\(name):") }
                    .map { String($0.dropFirst(name.count + 1)).trimmingCharacters(in: CharacterSet(charactersIn: " \"")) } ?? ""
            }
            func section(_ title: String) -> [String] {
                guard let start = lines.firstIndex(of: "## \(title)") else { return [] }
                return Array(lines[(start + 1)...].prefix { !$0.hasPrefix("## ") })
            }
            let files = section("Changed files")
                .compactMap { $0.firstMatch(of: #/\[\[file:(.+?)\]\]/#).map { String($0.1) } }
            let result = sanitize(section("Result").joined(separator: " "), limit: 300)
            let completed = field("completed")
            var entry = "- \(completed.prefix(10)) [\(field("status"))] \(field("title"))"
            if !files.isEmpty { entry += "\n  Files: \(files.prefix(8).joined(separator: ", "))" }
            if !result.isEmpty { entry += "\n  Result: \(result)" }
            let score = terms.intersection(FeedbackStore.tokens(note)).count
            return (score, completed, entry)
        }
        let matched = scored.filter { $0.score > 0 }
        return (matched.isEmpty ? scored : matched)
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.completed > $1.completed }
            .prefix(3)
            .map(\.entry)
            .joined(separator: "\n")
    }

    public func preferencesText() -> String {
        let own = identity.flatMap { (state["activePreferences"] as? [String: Any])?[$0.personID] as? [String: Any] } ?? [:]
        // What another client recorded in the facts file counts too.
        return markdownDictionary(own.merging(foreignFacts("preference", knownKeys: Set(own.keys))) { own, _ in own })
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
        func authority(_ event: [String: Any]) -> (Int, Int, Int, String) {
            let deviceID = (event["actor"] as? [String: Any])?["deviceId"] as? String ?? ""
            let member = member(deviceID: deviceID)
            let role = MemoryRole(rawValue: member?["role"] as? String ?? "observer")?.rank ?? 0
            let score = member?["score"] as? Int ?? 0
            return (role, score, event["lamport"] as? Int ?? 0, event["eventId"] as? String ?? "")
        }
        let left = authority(candidate)
        let right = authority(current)
        if left.0 != right.0 { return left.0 > right.0 }
        if left.1 != right.1 { return left.1 > right.1 }
        if left.2 != right.2 { return left.2 > right.2 }
        return left.3 > right.3
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

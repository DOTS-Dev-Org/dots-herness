// Copyright (c) 2026 DOTS
// Obsidian-style vault: index, preferences note and vault graph.

import CryptoKit
import Foundation
import PluginRuntime

extension WorkspaceMemory {
    // MARK: - Obsidian-style vault

    /// Regenerates `.mem/index.md`, the map-of-content note that links every
    /// task, decision, and conversation note. Cheap; called after any note write.
    func writeIndexNote() {
        guard let root = memoryDirectory else { return }
        func notes(in folder: String) -> [(id: String, title: String, created: String)] {
            let dir = root.appendingPathComponent(folder)
            let files = (try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            return files.filter { $0.pathExtension == "md" }.compactMap { url in
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                let front = parseFrontmatter(text)
                let stem = url.deletingPathExtension().lastPathComponent
                let prefix = folder == "tasks" ? "task" : folder == "decisions" ? "decision" : "conversation"
                let id = front["id"] ?? "\(prefix)-\(stem)"
                let title = unquoted(front["title"] ?? stem)
                let created = front["created"] ?? front["updated"] ?? front["revision"] ?? ""
                return (id, title, created)
            }.sorted { $0.created > $1.created }
        }
        let taskLines = notes(in: "tasks").map { "- [[\($0.id)]] — \($0.title)" }
        let decisionLines = notes(in: "decisions").map { "- [[\($0.id)]] — \($0.title)" }
        let conversationLines = notes(in: "conversations").map { "- [[\($0.id)]] — \($0.title)" }
        let front = frontmatter([
            "id": "index",
            "type": "index",
            "title": "Memory index",
            "updated": isoNow(),
            "revision": String(revision),
        ], tags: ["index", "moc"], links: ["map", "preferences"])
        let body = [
            front,
            "# Memory index",
            "",
            "Revision \(revision) · [[map]] · [[preferences]]"
                + (fileManager.fileExists(atPath: root.appendingPathComponent("learned_rules.md").path) ? " · [[learned_rules]]" : ""),
            "",
            "## Tasks",
            "",
            taskLines.isEmpty ? "- None yet" : taskLines.joined(separator: "\n"),
            "",
            "## Decisions",
            "",
            decisionLines.isEmpty ? "- None yet" : decisionLines.joined(separator: "\n"),
            "",
            "## Conversations",
            "",
            conversationLines.isEmpty ? "- None yet" : conversationLines.joined(separator: "\n"),
        ].joined(separator: "\n")
        try? body.write(to: root.appendingPathComponent("index.md"), atomically: true, encoding: .utf8)
    }

    /// Writes `.mem/preferences.md` from current-actor active preferences.
    func writePreferencesNote() {
        guard let root = memoryDirectory else { return }
        let text = preferencesText()
        let front = frontmatter([
            "id": "preferences",
            "type": "preference",
            "title": "Actor preferences",
            "actor": identity?.personID ?? "unknown",
            "updated": isoNow(),
        ], tags: ["preference"], links: ["index"])
        let body = [
            front,
            "# Actor preferences",
            "",
            "Back to [[index]]",
            "",
            text.isEmpty ? "- None recorded" : text,
        ].joined(separator: "\n")
        try? body.write(to: root.appendingPathComponent("preferences.md"), atomically: true, encoding: .utf8)
    }

    public static let projectNotePrefix = "project:"

    /// Parses the `.mem` vault into linked notes for the Memory settings view.
    public func vault() -> MemoryVault {
        guard let root = memoryDirectory,
              fileManager.fileExists(atPath: root.path) else { return MemoryVault() }
        var byID: [String: MemoryNote] = [:]
        var order: [String] = []
        func ingest(_ url: URL, fallbackKind: String) {
            guard url.pathExtension == "md",
                  let text = try? String(contentsOf: url, encoding: .utf8) else { return }
            let front = parseFrontmatter(text)
            let stem = url.deletingPathExtension().lastPathComponent
            let id = front["id"] ?? "\(fallbackKind)-\(stem)"
            let rel = url.path.hasPrefix(root.path)
                ? String(url.path.dropFirst(root.path.count + 1))
                : url.lastPathComponent
            let note = MemoryNote(
                id: id,
                kind: front["type"] ?? fallbackKind,
                title: unquoted(front["title"] ?? stem),
                path: rel,
                body: stripFrontmatter(text),
                tags: parseList(front["tags"]),
                links: extractWikilinks(text),
                revision: Int(front["revision"] ?? "") ?? 0
            )
            if byID[id] == nil { order.append(id) }
            byID[id] = note
        }
        for name in ["map.md", "index.md", "preferences.md"] {
            ingest(root.appendingPathComponent(name), fallbackKind: "note")
        }
        // What was learned is part of the vault too. The rules file is authored by
        // the feedback store and has no frontmatter. The profile is not a file here
        // at all: it describes the user across projects, and this vault is committed
        // with one repository, so it is shown as a note without being written to it.
        func learned(id: String, kind: String, title: String, path: String, body: String) {
            guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            byID[id] = MemoryNote(id: id, kind: kind, title: title, path: path, body: body, tags: [kind], links: ["index"])
            order.append(id)
            if byID["index"]?.links.contains(id) == false { byID["index"]?.links.append(id) }
        }
        // Shown even when empty: it is where the user writes a rule of their own.
        learned(
            id: "learned_rules", kind: "rule", title: "Learned rules", path: "learned_rules.md",
            body: (try? String(contentsOf: root.appendingPathComponent("learned_rules.md"), encoding: .utf8))
                ?? "# Learned rules"
        )
        // The brief and what was learned from the code live in the event log, not
        // in a file; each is a note so it can be read, corrected and taken back.
        for (key, value) in projectDefaults.sorted(by: { $0.key < $1.key }) {
            learned(id: Self.projectNotePrefix + key, kind: "project", title: key, path: "", body: value)
        }
        learned(id: "user-profile", kind: "profile", title: "User profile", path: "", body: profile.text(projectID: projectID, stack: stack))
        for folder in ["tasks", "decisions", "conversations"] {
            let dir = root.appendingPathComponent(folder)
            let files = (try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            for file in files.sorted(by: { $0.lastPathComponent > $1.lastPathComponent }) {
                let kind = folder == "tasks" ? "task" : folder == "decisions" ? "decision" : "conversation"
                ingest(file, fallbackKind: kind)
            }
        }
        // Synthetic nodes for wikilinked workspace files that have no note.
        for id in order {
            for link in byID[id]?.links ?? [] where byID[link] == nil {
                let isFile = link.hasPrefix("file:")
                byID[link] = MemoryNote(
                    id: link,
                    kind: isFile ? "file" : "missing",
                    title: isFile ? String(link.dropFirst(5)) : link,
                    path: "",
                    resolved: isFile
                )
                order.append(link)
            }
        }
        // Backlinks + edges.
        var backlinks: [String: [String]] = [:]
        var edges: [MemoryVaultEdge] = []
        for id in order {
            for link in byID[id]?.links ?? [] {
                backlinks[link, default: []].append(id)
                edges.append(MemoryVaultEdge(from: id, to: link))
            }
        }
        for (target, sources) in backlinks {
            byID[target]?.backlinks = sources.sorted()
        }
        return MemoryVault(notes: order.compactMap { byID[$0] }, edges: edges)
    }
}

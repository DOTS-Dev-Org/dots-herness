// Copyright (c) 2026 DOTS
// Obsidian-style vault: the index note and the graph the Memory settings view draws.
// Project notes come from the repository; the person's notes come from the user layer.

import CryptoKit
import Foundation
import PluginRuntime

extension WorkspaceMemory {
    // MARK: - Obsidian-style vault

    /// Regenerates `.mem/index.md`, the project's map of content. It links the map and
    /// the decisions only: tasks and chats belong to the person, and the repository
    /// never names them. Cheap; called after any decision write.
    /// The tag of a decision a review suggested removing; see `decisionProposals`.
    public static let decisionReviewTag = "review"

    /// The index lists the decisions `.mem/facts.md` holds, which is where they have lived
    /// since the signed event log; the `decisions/` notes were a projection of that log.
    func writeIndexNote() {
        guard let root = memoryDirectory else { return }
        let decisionLines = projectMemoryFacts().filter { $0.kind == "decision" }.map { fact in
            "- [[\(ProjectDecisions.noteID(fact.key))]] — \(sanitize(ProjectDecisions.body(fact.text), limit: 120))"
        }
        let front = frontmatter([
            "id": "index",
            "type": "index",
            "title": "Memory index",
            "revision": String(revision),
        ], tags: ["index", "moc"], links: ["map"])
        let body = [
            front,
            "# Memory index",
            "",
            "\(decisionLines.count) decisions · [[map]]",
            "",
            "## Decisions",
            "",
            decisionLines.isEmpty ? "- None yet" : decisionLines.joined(separator: "\n"),
        ].joined(separator: "\n")
        try? body.write(to: root.appendingPathComponent("index.md"), atomically: true, encoding: .utf8)
    }

    public static let projectNotePrefix = "project:"
    /// The root note of a project that is not the open one; the open project's root is `index`.
    public static let otherProjectPrefix = "other-project:"
    public static let otherProjectTag = "other-project"
    /// ponytail: the strongest findings of each other project only; the graph's layout is O(n²).
    static let otherProjectFindings = 30

    /// Parses the memory into linked notes for the Memory settings view. A link may
    /// point from a user note to a project note, never from a project note to a user
    /// note: the repository must not name anything that lives on this Mac.
    public func vault() -> MemoryVault {
        guard let root = memoryDirectory,
              fileManager.fileExists(atPath: root.path) else { return MemoryVault() }
        var byID: [String: MemoryNote] = [:]
        var order: [String] = []
        func add(_ note: MemoryNote) {
            if byID[note.id] == nil { order.append(note.id) }
            byID[note.id] = note
        }
        func ingest(_ url: URL, base: URL, fallbackKind: String, layer: MemoryLayer) {
            guard url.pathExtension == "md",
                  let text = try? String(contentsOf: url, encoding: .utf8) else { return }
            let front = parseFrontmatter(text)
            let stem = url.deletingPathExtension().lastPathComponent
            let id = front["id"] ?? "\(fallbackKind)-\(stem)"
            let rel = url.path.hasPrefix(base.path)
                ? String(url.path.dropFirst(base.path.count + 1))
                : url.lastPathComponent
            add(MemoryNote(
                id: id,
                kind: front["type"] ?? fallbackKind,
                title: unquoted(front["title"] ?? stem),
                path: rel,
                body: stripFrontmatter(text),
                tags: parseList(front["tags"]),
                links: extractWikilinks(text),
                revision: Int(front["revision"] ?? "") ?? 0,
                layer: layer
            ))
        }
        // What is learned or written down is a note too, so it can be read, corrected
        // and taken back. These are synthesized from state, not files.
        func learned(
            id: String, kind: String, title: String, path: String, body: String, layer: MemoryLayer,
            tags: [String] = [], links: [String] = ["index"]
        ) {
            guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            add(MemoryNote(id: id, kind: kind, title: title, path: path, body: body, tags: [kind] + tags, links: links, layer: layer))
        }

        // Project layer: repository notes and portable project facts.
        for name in ["map.md", "index.md"] {
            ingest(root.appendingPathComponent(name), base: root, fallbackKind: "note", layer: .project)
        }
        // The index is the project's root in the graph, so it carries the project's name.
        if let name = workspaceURL?.lastPathComponent, !name.isEmpty { byID["index"]?.title = name }
        for file in sortedNotes(in: root.appendingPathComponent("decisions")) {
            ingest(file, base: root, fallbackKind: "decision", layer: .project)
        }
        for (key, value) in projectDefaults.sorted(by: { $0.key < $1.key }) {
            learned(id: Self.projectNotePrefix + key, kind: "project", title: key, path: "", body: value, layer: .project)
        }
        let review = Set(decisionProposals.map(\.key))
        for fact in projectMemoryFacts().filter({ $0.kind == "decision" }) {
            learned(id: ProjectDecisions.noteID(fact.key), kind: "decision", title: fact.key, path: ".mem/facts.md", body: fact.text, layer: .project,
                    tags: ProjectDecisions.platforms(of: fact.text) + (review.contains(fact.key) ? [Self.decisionReviewTag] : []))
        }

        // The stack is the project's own knowledge: its manifests say it, the map names it.
        for technology in stack {
            learned(
                id: Self.technologyNotePrefix + technology, kind: "technology", title: technology, path: "",
                body: "This project is built with \(technology).", layer: .project, links: ["map"]
            )
        }

        // User layer: this Mac's records for the project, and the person's own preferences.
        // The profile is the centre of it. What holds everywhere hangs off the profile; what
        // holds here hangs off the project, and points at the everywhere value it replaces.
        var weights: [String: Int] = [:]
        if let userRoot = userMemoryDirectory {
            // Shown even when empty: it is where the person writes rules of their own.
            let rules = (try? String(contentsOf: userRoot.appendingPathComponent("learned_rules.md"), encoding: .utf8))
                ?? "# Learned rules"
            learned(
                id: "learned_rules", kind: "rule", title: "Learned rules", path: "learned_rules.md", body: rules, layer: .user,
                links: ["index", "user-profile"]
            )
            let everywhere = profile.preferences()
            let projectKeys = Set(projectMemoryFacts().map { $0.key })
            let overridden = profile.overriddenPreferences(projectID: projectID, projectKeys: projectKeys)
            for (key, value) in everywhere.sorted(by: { $0.key < $1.key }) {
                // A project entry of the same name replaces it too; that one is linked from here,
                // because a repository note must not name anything on this Mac.
                learned(
                    id: Self.preferenceNotePrefix + "everywhere:" + key, kind: "preference", title: key, path: "", body: value, layer: .user,
                    tags: overridden.contains(key) ? ["overridden"] : [],
                    links: ["user-profile"] + (projectKeys.contains(key) ? [Self.projectNotePrefix + key] : [])
                )
            }
            if let projectID {
                for (key, value) in profile.projectPreferences(projectID: projectID).sorted(by: { $0.key < $1.key }) {
                    learned(
                        id: Self.preferenceNotePrefix + "project:" + key, kind: "preference", title: key, path: "", body: value, layer: .user,
                        tags: everywhere[key] == nil ? [] : ["overrides"],
                        links: ["index"] + (everywhere[key] == nil ? [] : [Self.preferenceNotePrefix + "everywhere:" + key])
                    )
                }
            }
            // Technologies the person's other projects use, by name and count.
            let known = profile.technologies()
            for (technology, projects) in known.sorted(by: { $0.key < $1.key }) where !stack.contains(technology) {
                learned(
                    id: Self.technologyNotePrefix + technology, kind: "technology", title: technology, path: "",
                    body: "Used in \(projects.count) of your other projects, not in this one.", layer: .user, links: []
                )
            }
            // The person's other projects, each a root of its own with what was learned in it
            // hanging off it. They are drawn for the person and never reach a prompt: see
            // `insightsText` and `memoryChatContext`, which read this project only.
            let names = profile.projectNames()
            var otherRoots: [String] = []
            for folder in sortedNotes(in: userRoot.deletingLastPathComponent()) {
                let id = folder.lastPathComponent
                guard id != projectID, UUID(uuidString: id) != nil else { continue }
                let found = ((try? Data(contentsOf: folder.appendingPathComponent("insights.json")))
                    .flatMap { try? JSONDecoder().decode(InsightFile.self, from: $0) })?.insights ?? []
                let rootID = Self.otherProjectPrefix + id
                otherRoots.append(rootID)
                add(MemoryNote(
                    id: rootID, kind: "index", title: names[id] ?? String(id.prefix(8)), path: "",
                    body: "Another project on this Mac, with \(found.count) findings. Open it to change its memory.",
                    tags: ["index", Self.otherProjectTag],
                    links: known.filter { $0.value.contains(id) }.keys.sorted().map { Self.technologyNotePrefix + $0 }, layer: .user
                ))
                for insight in found.sorted(by: { $0.strength > $1.strength }).prefix(Self.otherProjectFindings) {
                    learned(
                        id: rootID + "/" + insight.id, kind: "insight", title: Self.noteTitle(insight.text), path: "",
                        body: insight.text, layer: .user, tags: [insight.kind.rawValue, Self.otherProjectTag], links: [rootID]
                    )
                }
            }
            // Always there, like the rules note: every other note of the person leads back to it.
            let profileText = profile.text(projectID: projectID, stack: stack, projectKeys: projectKeys)
            add(MemoryNote(
                id: "user-profile", kind: "profile", title: "User profile", path: "",
                body: profileText.isEmpty ? "# User profile" : profileText, tags: ["profile"],
                links: ["index"] + otherRoots + Set(known.keys).union(stack).sorted().map { Self.technologyNotePrefix + $0 }, layer: .user
            ))
            for file in sortedNotes(in: userRoot.appendingPathComponent("tasks")) {
                ingest(file, base: userRoot, fallbackKind: "task", layer: .user)
            }
            for file in sortedNotes(in: userRoot.appendingPathComponent("conversations")) {
                ingest(file, base: userRoot, fallbackKind: "conversation", layer: .user)
            }
            // Tools and skills, as this project's tasks actually used them.
            let usage = toolUsage(in: userRoot)
            for (id, use) in usage.total.sorted(by: { $0.key < $1.key }) {
                let isSkill = id.hasPrefix(Self.skillNotePrefix)
                let name = String(id.dropFirst((isSkill ? Self.skillNotePrefix : Self.toolNotePrefix).count))
                learned(
                    id: id, kind: isSkill ? "skill" : "tool", title: name, path: "",
                    body: "Used \(use.calls) times in \(use.runs) tasks of this project" + (use.failed > 0 ? ", \(use.failed) ending in an error." : "."),
                    layer: .user
                )
            }
            // Findings hang off the project's root, and link to what they were learned from and
            // what they are about. A finding met by more scans pulls harder on each of those.
            for insight in insights {
                let id = Self.insightNotePrefix + insight.id
                let links = insight.runs.map { "task-" + $0 }.filter { byID[$0] != nil }
                    + insight.tools.map { Self.toolNotePrefix + $0 }.filter { byID[$0] != nil }
                    + insight.files.map { "file:" + $0 }
                learned(
                    id: id, kind: "insight", title: Self.noteTitle(insight.text), path: "",
                    body: insight.text + "\n\nMet by \(insight.strength) scans, last on \(insight.updatedAt.prefix(10)).",
                    layer: .user, tags: [insight.kind.rawValue], links: ["index"] + links
                )
                for link in links { weights["\(id)->\(link)"] = insight.strength }
            }
            for (runID, counts) in usage.byRun {
                let taskID = "task-" + runID
                guard byID[taskID] != nil else { continue }
                for (id, count) in counts.sorted(by: { $0.key < $1.key }) {
                    byID[taskID]?.links.append(id)
                    weights["\(taskID)->\(id)"] = count
                }
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
                edges.append(MemoryVaultEdge(from: id, to: link, weight: weights["\(id)->\(link)"] ?? 1))
            }
        }
        for (target, sources) in backlinks {
            byID[target]?.backlinks = sources.sorted()
        }
        return MemoryVault(notes: order.compactMap { byID[$0] }, edges: edges)
    }

    /// A finding's title: its first sentence, or its first words when that runs long.
    static func noteTitle(_ text: String, limit: Int = 60) -> String {
        let sentence = text.split(separator: "\n").first.map(String.init) ?? text
        let first = sentence.range(of: #"[.;:](\s|$)"#, options: .regularExpression).map { String(sentence[..<$0.lowerBound]) } ?? sentence
        guard first.count > limit else { return first }
        let cut = first.prefix(limit)
        return (cut.lastIndex(of: " ").map { String(cut[..<$0]) } ?? String(cut)) + "…"
    }

    /// Files in a note folder, newest name first.
    private func sortedNotes(in directory: URL) -> [URL] {
        ((try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    public static let preferenceNotePrefix = "user-pref:"
    public static let technologyNotePrefix = "tech:"
    public static let toolNotePrefix = "tool:"
    public static let skillNotePrefix = "skill:"
    public static let insightNotePrefix = "insight:"

    /// Tool and skill use from this Mac's activity log for the project: totals, and per task.
    /// ponytail: reads the whole log on every call; cache by file size if it grows past a few MB.
    private func toolUsage(in userRoot: URL) -> (total: [String: (calls: Int, failed: Int, runs: Int)], byRun: [String: [String: Int]]) {
        var total: [String: (calls: Int, failed: Int, runs: Int)] = [:]
        var byRun: [String: [String: Int]] = [:]
        let text = (try? String(contentsOf: userRoot.appendingPathComponent("activity.jsonl"), encoding: .utf8)) ?? ""
        for line in text.split(separator: "\n") {
            guard let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  let payload = object["payload"] as? [String: Any] else { continue }
            let id: String
            if object["type"] as? String == Self.toolSummaryType, let name = payload["id"] as? String {
                var use = total[name] ?? (0, 0, 0)
                use.calls += payload["calls"] as? Int ?? 0
                use.failed += payload["failed"] as? Int ?? 0
                use.runs += payload["runs"] as? Int ?? 0
                total[name] = use
                continue
            }
            switch object["type"] as? String {
            case "tool.executed": id = Self.toolNotePrefix + (payload["name"] as? String ?? "")
            case "skill.used": id = Self.skillNotePrefix + (payload["skill"] as? String ?? "")
            default: continue
            }
            guard !id.hasSuffix(":") else { continue }
            let runID = payload["runId"] as? String ?? ""
            let firstInRun = byRun[runID]?[id] == nil
            byRun[runID, default: [:]][id, default: 0] += 1
            var use = total[id] ?? (0, 0, 0)
            use.calls += 1
            use.failed += payload["resultStatus"] as? String == "failed" ? 1 : 0
            use.runs += firstInRun ? 1 : 0
            total[id] = use
        }
        return (total, byRun)
    }
}

// Copyright (c) 2026 DOTS
// Explicit portable transfer for project facts and the person's own profile.

import Foundation

public enum MemoryTransferScope: String, Codable, Sendable, Equatable {
    case project
    case personal
}

struct MemoryTransferFact: Codable, Equatable, Sendable {
    var kind: String
    var key: String
    var text: String
}

private struct MemoryTransferBundle: Codable {
    var format: String
    var version: Int
    var scope: MemoryTransferScope
    var facts: [MemoryTransferFact]
    var profile: UserProfile.Stored?
}

extension WorkspaceMemory {
    private static var maxTransferFacts: Int { 60 }
    /// A decision carries its reason, which is what lets a later task tell whether it still
    /// applies; other facts are one sentence. One text holding both may run to
    /// `decisionTextLimit`; a decision recorded with its reason and platforms apart is
    /// stored as up to `decisionLimit`. Mirrors WorkspaceFacts.cs.
    static let decisionTextLimit = ProjectDecisions.decisionTextLimit
    static let decisionLimit = ProjectDecisions.decisionLimit

    static func factLimit(kind: String, key: String) -> Int {
        ProjectDecisions.factLimit(kind: kind, key: key)
    }

    public func exportMemory(_ scope: MemoryTransferScope) throws -> Data {
        let bundle: MemoryTransferBundle
        switch scope {
        case .project:
            guard workspaceURL != nil else { throw WorkspaceMemoryError.noWorkspace }
            bundle = MemoryTransferBundle(format: "dots-memory-transfer", version: 1, scope: .project,
                facts: projectMemoryFacts(), profile: nil)
        case .personal:
            let facts = personalFacts()
            bundle = MemoryTransferBundle(format: "dots-memory-transfer", version: 1, scope: .personal,
                facts: facts, profile: profile.load())
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(bundle)
    }

    @discardableResult
    public func importMemory(_ data: Data, scope: MemoryTransferScope) throws -> Int {
        guard data.count <= 5_000_000 else { throw WorkspaceMemoryError.invalidTransfer }
        let bundle = try JSONDecoder().decode(MemoryTransferBundle.self, from: data)
        guard bundle.format == "dots-memory-transfer", bundle.version == 1, bundle.scope == scope else {
            throw WorkspaceMemoryError.invalidTransfer
        }
        let facts = try validated(bundle.facts, scope: scope)
        switch scope {
        case .project:
            guard workspaceURL != nil else { throw WorkspaceMemoryError.noWorkspace }
            try writeProjectMemoryFacts(merging: facts)
            reload()
        case .personal:
            try mergePersonalFacts(facts)
            if let imported = bundle.profile {
                try profile.merge(imported)
                return facts.count + profileEntryCount(imported)
            }
        }
        return facts.count
    }

    private func profileEntryCount(_ stored: UserProfile.Stored) -> Int {
        stored.preferences.count
            + stored.technologies.count
            + (stored.lessons?.count ?? 0)
            + (stored.projectPreferences?.values.reduce(0) { $0 + $1.count } ?? 0)
            + (stored.projectNames?.count ?? 0)
    }

    var projectMemoryFactsURL: URL? { memoryDirectory?.appendingPathComponent("facts.md") }

    func projectMemoryFacts() -> [MemoryTransferFact] {
        let hasFactsFile = projectMemoryFactsURL.map { fileManager.fileExists(atPath: $0.path) } ?? false
        var facts: [MemoryTransferFact] = []
        if let url = projectMemoryFactsURL,
           hasFactsFile,
           let body = MemoryFileCache.text(at: url) {
            facts = parseFacts(body).filter { $0.kind == "project" || $0.kind == "decision" }
        } else {
            let legacy = state["projectDefaults"] as? [String: Any] ?? [:]
            facts = legacy.keys.sorted().compactMap { key in
                guard let value = legacy[key] as? String else { return nil }
                return MemoryTransferFact(kind: "project", key: key, text: value)
            }
        }
        for event in state["acceptedDecisions"] as? [[String: Any]] ?? [] {
            let payload = event["payload"] as? [String: Any] ?? [:]
            guard let eventID = event["eventId"] as? String else { continue }
            let summary = sanitize(payload["summary"] as? String ?? payload["value"] as? String ?? "Accepted project decision", limit: .max)
            appendDecision(key: eventID, summary: summary, to: &facts)
        }
        if let directory = memoryDirectory?.appendingPathComponent("decisions", isDirectory: true),
           let urls = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            for url in urls.filter({ $0.pathExtension == "md" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                guard let contents = MemoryFileCache.text(at: url) else { continue }
                let front = parseFrontmatter(contents)
                let rawID = front["id"] ?? url.deletingPathExtension().lastPathComponent
                let key = rawID.hasPrefix("decision-") ? String(rawID.dropFirst("decision-".count)) : rawID
                let body = stripFrontmatter(contents)
                let summary: String
                if let marker = body.range(of: "## Summary") {
                    summary = String(body[marker.upperBound...]).components(separatedBy: "\n## ").first ?? ""
                } else {
                    summary = front["title"]?.trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) ?? ""
                }
                appendDecision(key: key, summary: summary, to: &facts)
            }
        }
        var kept = Self.tidied(facts)
        ProjectDecisions.evict(&kept, max: Self.maxTransferFacts)
        return kept
    }

    /// Facts as a prompt should read them; see `ProjectDecisions.tidied`. The file itself is
    /// rewritten tidy the next time a fact is recorded.
    static func tidied(_ facts: [MemoryTransferFact]) -> [MemoryTransferFact] {
        ProjectDecisions.tidied(facts)
    }

    /// Two decisions sharing most of their words say the same thing; see `ProjectDecisions.same`.
    static func sameDecision(_ left: String, _ right: String) -> Bool {
        ProjectDecisions.same(left, right)
    }

    private func appendDecision(key: String, summary: String, to facts: inout [MemoryTransferFact]) {
        let key = sanitize(key, limit: 60)
        let text = sanitizeSentence(summary, limit: Self.decisionLimit)
        guard !key.isEmpty, !text.isEmpty,
              !facts.contains(where: { $0.kind == "decision" && ($0.key == key || $0.text == text) }) else { return }
        facts.append(MemoryTransferFact(kind: "decision", key: key, text: text))
    }

    func projectFactsByKind() -> [String: [String: String]] {
        Dictionary(grouping: projectMemoryFacts(), by: \.kind).mapValues { facts in
            Dictionary(facts.map { ($0.key, $0.text) }, uniquingKeysWith: { _, latest in latest })
        }
    }

    private func personalFacts() -> [MemoryTransferFact] {
        let url = paths.root.appendingPathComponent("user-facts.md")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return Array(parseFacts(text).filter { $0.kind == "preference" }.suffix(Self.maxTransferFacts))
    }

    private func validated(_ incoming: [MemoryTransferFact], scope: MemoryTransferScope) throws -> [MemoryTransferFact] {
        guard incoming.count <= Self.maxTransferFacts else { throw WorkspaceMemoryError.invalidTransfer }
        return try incoming.map { fact in
            let allowed = scope == .project
                ? fact.kind == "project" || fact.kind == "decision"
                : fact.kind == "preference"
            let key = sanitize(fact.key, limit: 60)
            let limit = Self.factLimit(kind: fact.kind, key: key)
            let text = sanitizeSentence(fact.text, limit: limit)
            let entry = RememberTool.Entry(kind: fact.kind, key: key, text: text)
            guard allowed, !key.isEmpty, !text.isEmpty, !RememberTool.looksLikeSecret(entry) else {
                throw WorkspaceMemoryError.invalidTransfer
            }
            return MemoryTransferFact(kind: fact.kind, key: key, text: text)
        }
    }

    private func writeProjectMemoryFacts(merging incoming: [MemoryTransferFact]) throws {
        guard let url = projectMemoryFactsURL else { throw WorkspaceMemoryError.noWorkspace }
        var facts = projectMemoryFacts()
        // A decision restated in other words replaces the old wording.
        for item in incoming { ProjectDecisions.upsert(&facts, item) }
        // The oldest decision leaves first; what was learned of the code never does.
        ProjectDecisions.evict(&facts, max: Self.maxTransferFacts)
        try writeFacts(facts, to: url)
        writeIndexNote()
    }

    /// Rewrites the project's facts through `update`, as every other write does.
    func updateProjectMemoryFacts(_ update: ([MemoryTransferFact]) -> [MemoryTransferFact]) throws {
        guard let url = projectMemoryFactsURL else { throw WorkspaceMemoryError.noWorkspace }
        var facts = update(projectMemoryFacts())
        ProjectDecisions.evict(&facts, max: Self.maxTransferFacts)
        try writeFacts(facts, to: url)
        writeIndexNote()
    }

    func setProjectMemoryFact(kind: String, key: String, text: String) throws {
        let normalized = MemoryTransferFact(kind: kind, key: sanitize(key, limit: 60), text: sanitizeSentence(text, limit: Self.factLimit(kind: kind, key: key)))
        let facts = try validated([normalized], scope: .project)
        // The first fact HerNess writes starts this checkout's memory: it is ours.
        let startsMemory = projectMemoryTrust == nil && projectMemoryFacts().isEmpty
        try writeProjectMemoryFacts(merging: facts)
        if startsMemory { try? setProjectMemoryTrust(true) }
    }

    func removeProjectMemoryFact(kind: String, key: String) throws {
        guard let url = projectMemoryFactsURL else { throw WorkspaceMemoryError.noWorkspace }
        var facts = projectMemoryFacts()
        facts.removeAll { $0.kind == kind && $0.key == key }
        try writeFacts(facts, to: url)
        writeIndexNote()
    }

    private func writeFacts(_ facts: [MemoryTransferFact], to url: URL) throws {
        let sections = ["project", "preference", "decision"].compactMap { kind -> String? in
            // In the order they were recorded: the oldest decision is the first to leave.
            let rows = facts.filter { $0.kind == kind }
            guard !rows.isEmpty else { return nil }
            return "## \(kind)\n" + rows.map { "- \($0.key) — \($0.text)" }.joined(separator: "\n")
        }
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try sections.joined(separator: "\n\n").appending(sections.isEmpty ? "" : "\n")
            .write(to: url, atomically: true, encoding: .utf8)
    }

    private func parseFacts(_ body: String) -> [MemoryTransferFact] {
        var kind = ""
        var facts: [MemoryTransferFact] = []
        for raw in body.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("## ") { kind = String(line.dropFirst(3)).lowercased(); continue }
            guard line.hasPrefix("- "), let separator = line.range(of: " — ") else { continue }
            let key = String(line[line.index(line.startIndex, offsetBy: 2)..<separator.lowerBound]).trimmingCharacters(in: .whitespaces)
            let text = String(line[separator.upperBound...]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, !text.isEmpty else { continue }
            facts.append(MemoryTransferFact(kind: kind, key: key, text: text))
        }
        return facts
    }

    private func mergePersonalFacts(_ incoming: [MemoryTransferFact]) throws {
        let url = paths.root.appendingPathComponent("user-facts.md")
        let existing = personalFacts()
        var facts = existing
        for item in incoming { ProjectDecisions.upsert(&facts, item) }
        ProjectDecisions.evict(&facts, max: Self.maxTransferFacts)
        try fileManager.createDirectory(at: paths.root, withIntermediateDirectories: true)
        try writeFacts(facts, to: url)
    }
}

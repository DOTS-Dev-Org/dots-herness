// Copyright (c) 2026 DOTS
// What the project's memory holds, on the phone: the lessons the desktops
// learned (`.mem/lessons.json`, read only - the phone has no evaluator) and the
// facts file every client shares (`.mem/facts.md`, read and written here through
// the `remember` tool).
//
// Mirrors the read side of macos/DotsHarness/Sources/DotsHarnessCore/Lessons.swift
// and the file format of shared/WorkspaceFacts.cs.

import Foundation

enum MobileLessons {
    struct Lesson: Decodable {
        var when: String
        var rule: String
        var why: String
        var paths: [String]
        var sources: [String]
        var lastSeen: Date

        /// Distinct events behind the lesson; a feedback record and the inference
        /// drawn from it count once.
        var hits: Int {
            Set(sources.map { $0.hasSuffix(":inferred") ? String($0.dropLast(9)) : $0 }).count
        }

        /// What the user said stays; what was only inferred stays while recent or
        /// learned more than once.
        func isActive(at now: Date) -> Bool {
            sources.contains { !$0.hasPrefix("signal:") } || hits >= 2
                || now.timeIntervalSince(lastSeen) < 90 * 24 * 60 * 60
        }

        var line: String {
            let situation = when.trimmingCharacters(in: CharacterSet(charactersIn: " .:"))
            return (situation.isEmpty ? "" : "When \(situation): ") + rule + (why.isEmpty ? "" : " Why: \(why)")
        }

        var id: String { sources.min() ?? "" }

        /// The line as the model reads it: a short id it can cite, and whether
        /// the user said it or it was drawn from what they did.
        var cited: String {
            let key = id.hasPrefix("signal:") ? String(id.dropFirst(7)) : id
            let explicit = sources.contains { !$0.hasPrefix("signal:") }
            return "[\(key.prefix(6)) \(explicit ? "user" : "inferred")] " + line
        }

        func applies(to path: String) -> Bool {
            paths.contains { scope in
                let scope = scope.hasSuffix("/") ? String(scope.dropLast()) : scope
                return path == scope || path.hasPrefix(scope + "/")
            }
        }
    }

    private static func load(root: URL) -> [Lesson] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: root.appendingPathComponent(".mem/lessons.json")),
              let lessons = try? decoder.decode([Lesson].self, from: data) else { return [] }
        return lessons
    }

    /// Lessons tied to a file, handed over with the file the first time it is
    /// read or written.
    /// ponytail: once per app session, not per conversation; key it by
    /// conversation if a second chat is seen missing a lesson.
    @MainActor private static var delivered = Set<String>()

    @MainActor
    static func fileNotice(root: URL, path: String, now: Date = Date()) -> String {
        let fresh = load(root: root).filter {
            $0.isActive(at: now) && $0.applies(to: path) && !delivered.contains(root.path + "\n" + $0.id)
        }
        guard !fresh.isEmpty else { return "" }
        delivered.formUnion(fresh.map { root.path + "\n" + $0.id })
        return "\n\nLearned earlier about this file (apply it):\n" + fresh.map { "- " + $0.cited }.joined(separator: "\n")
    }

    static let maximumCharacters = 4_000

    /// The notice for a conversation: project-wide lessons still in force,
    /// strongest first, within a fixed budget. Empty when there are none. The
    /// text carries no date or counter, so it is appended once and again only
    /// when a lesson changes.
    static func rulesText(root: URL, now: Date = Date()) -> String {
        let lessons = load(root: root)
        var lines: [String] = []
        var used = 0
        let ranked = lessons
            .filter { $0.paths.isEmpty && $0.isActive(at: now) }
            .sorted {
                if $0.hits != $1.hits { return $0.hits > $1.hits }
                if $0.lastSeen != $1.lastSeen { return $0.lastSeen > $1.lastSeen }
                return ($0.sources.min() ?? "") < ($1.sources.min() ?? "")
            }
        for lesson in ranked {
            let line = "- " + lesson.cited
            guard used + line.count <= maximumCharacters else { break }
            used += line.count
            lines.append(line)
        }
        let rules = lines.isEmpty
            ? ""
            : "[Learned rules]\nWhat this user already taught HerNess in this project. Follow it without asking again; "
                + "the user's current message wins. Each rule opens with its id and whether the user said it or it was "
                + "inferred from what they corrected.\n" + lines.joined(separator: "\n")
        return [rules, MobileFacts.text(root: root)].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
}

/// The facts file: project facts, preferences and decisions as keyed lines under
/// a heading per kind, shared with the desktops.
enum MobileFacts {
    static let kinds = ["project", "preference", "decision"]
    static let knowledgeKeys = ["architecture", "conventions", "design-system"]
    static let maximumCharacters = 6_000

    private struct Fact: Equatable {
        var kind: String
        var key: String
        var text: String
    }

    private static func url(_ root: URL) -> URL { root.appendingPathComponent(".mem/facts.md") }

    private static func read(_ root: URL) -> [Fact] {
        guard let body = try? String(contentsOf: url(root), encoding: .utf8) else { return [] }
        var facts: [Fact] = []
        var kind = ""
        for raw in body.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("## ") {
                kind = line.dropFirst(3).trimmingCharacters(in: .whitespaces).lowercased()
            } else if line.hasPrefix("- "), !kind.isEmpty, let separator = line.range(of: " — ") {
                let key = line[line.index(line.startIndex, offsetBy: 2)..<separator.lowerBound]
                    .trimmingCharacters(in: CharacterSet(charactersIn: " `"))
                let text = line[separator.upperBound...].trimmingCharacters(in: .whitespaces)
                if !key.isEmpty, !text.isEmpty { facts.append(Fact(kind: kind, key: key, text: text)) }
            }
        }
        return facts
    }

    private static func render(_ facts: [Fact]) -> String {
        (kinds + Set(facts.map(\.kind)).subtracting(kinds).sorted()).compactMap { kind -> String? in
            let lines = facts.filter { $0.kind == kind }.map { "- \($0.key) — \($0.text)" }
            return lines.isEmpty ? nil : "## \(kind)\n" + lines.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    /// The notice for a conversation; empty until something is recorded.
    static func text(root: URL) -> String {
        let facts = read(root)
        guard !facts.isEmpty else { return "" }
        return "[Project facts]\nWhat is already known about this project and how the user wants work done in it. "
            + "Follow it without asking again; interface work reuses the colors, type and components the "
            + "design-system fact names. Record a new lasting fact with remember.\n"
            + String(render(facts).prefix(maximumCharacters))
    }

    /// Credential shapes, by key name and by value. The file is committed with
    /// the repository, so a refused fact costs a sentence and a recorded key a rotation.
    static func looksLikeSecret(key: String, text: String) -> Bool {
        if key.range(of: #"(?i)(api[_-]?key|apikey|secret|token|password|passwd|credential|private[_-]?key)"#, options: .regularExpression) != nil {
            return true
        }
        return [
            #"(?i)\b(sk|pk|rk)[_-][A-Za-z0-9_\-]{16,}"#,
            #"\b(gh[pousr]|github_pat)_[A-Za-z0-9_]{16,}"#,
            #"(?i)\bAKIA[0-9A-Z]{12,}"#,
            #"(?i)\bxox[abposr]-[A-Za-z0-9-]{10,}"#,
            #"-----BEGIN [A-Z ]*PRIVATE KEY-----"#,
            #"(?i)(api[_-]?key|token|password|secret)\s*[:=]\s*\S+"#,
        ].contains { text.range(of: $0, options: .regularExpression) != nil }
    }

    /// Writes one fact, replacing an earlier one with the same kind and key.
    static func record(root: URL, kind: String, key: String, text: String) -> String {
        func collapse(_ value: String, _ limit: Int) -> String {
            String(value.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ").prefix(limit))
        }
        let kind = kind.trimmingCharacters(in: .whitespaces).lowercased()
        var key = collapse(key, 60).lowercased()
        if key.isEmpty { key = kind == "decision" ? "decision" : "note" }
        let text = collapse(text, kind == "project" && knowledgeKeys.contains(key) ? 1_200 : 240)
        guard kinds.contains(kind), !text.isEmpty else {
            return "That call was not usable. Send kind (\"project\", \"preference\" or \"decision\"), a short key naming the subject, and a one-sentence text. Continue with the work either way."
        }
        guard !looksLikeSecret(key: key, text: text) else {
            return "Not recorded: that looks like a credential, and this store is a file committed with the repository. Record where the secret lives instead. Continue with the work."
        }
        var facts = read(root).filter { $0.kind != kind || $0.key != key }
        facts.append(Fact(kind: kind, key: key, text: text))
        do {
            try FileManager.default.createDirectory(at: url(root).deletingLastPathComponent(), withIntermediateDirectories: true)
            try (render(facts) + "\n").write(to: url(root), atomically: true, encoding: .utf8)
        } catch {
            return "Durable memory is not available here, so nothing was recorded. Continue with the work; do not retry."
        }
        return "Recorded \(kind) \(key): \(text)"
    }
}

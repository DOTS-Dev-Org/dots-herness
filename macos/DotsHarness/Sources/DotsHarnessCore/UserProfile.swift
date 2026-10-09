// Copyright (c) 2026 DOTS
// Cross-project memory: what HerNess knows about the user rather than about one
// repository - lasting preferences and the technologies their projects use. It
// lives in the app's support folder, so a brand new project starts already
// knowing them.

import Foundation

public final class UserProfile {
    struct Stored: Codable {
        var preferences: [String: String] = [:]
        /// Technology name to the ids of the projects that use it.
        var technologies: [String: [String]] = [:]
        var lessons: [SharedLesson]? = nil
    }

    /// A project-wide lesson and the projects it was learned in, each with the
    /// stack it had then.
    struct SharedLesson: Codable, Equatable {
        var when: String
        var rule: String
        var why: String
        var projects: [String: [String]]

        /// What every project that taught it has in common; empty means it is
        /// not about a technology.
        var technologies: Set<String> {
            let stacks = projects.values.map { Set($0) }
            return stacks.dropFirst().reduce(stacks.first ?? []) { $0.intersection($1) }
        }
    }

    static let maxSharedLessons = 10
    static let maxStoredLessons = 200

    static let maxPreferences = 40
    static let maxTechnologies = 12

    let url: URL

    public init(root: URL) {
        url = root.appendingPathComponent("user_profile.json")
    }

    func load() -> Stored {
        guard let data = try? Data(contentsOf: url),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return Stored() }
        return stored
    }

    private func save(_ stored: Stored) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(stored).write(to: url, options: .atomic)
    }

    /// A later value under the same key replaces the earlier one.
    public func setPreference(key: String, value: String) throws {
        var stored = load()
        guard stored.preferences[key] != nil || stored.preferences.count < Self.maxPreferences else { return }
        stored.preferences[key] = value
        try save(stored)
    }

    /// Replaces what this project contributes: a project that moved off a
    /// technology stops counting toward it.
    public func recordTechnologies(_ technologies: [String], projectID: String) {
        var stored = load()
        var next = stored.technologies.mapValues { $0.filter { $0 != projectID } }
        for technology in technologies { next[technology, default: []].append(projectID) }
        next = next.filter { !$0.value.isEmpty }.mapValues { $0.sorted() }
        guard next != stored.technologies else { return }
        stored.technologies = next
        try? save(stored)
    }

    /// Replaces what this project contributes to the shared lessons. A lesson
    /// becomes the user's own once two projects have taught it.
    public func syncLessons(_ lessons: [Lesson], projectID: String, stack: [String]) {
        var stored = load()
        var shared = (stored.lessons ?? []).map { lesson -> SharedLesson in
            var lesson = lesson
            lesson.projects.removeValue(forKey: projectID)
            return lesson
        }
        for lesson in lessons {
            if let index = shared.firstIndex(where: { Lesson.similar($0.rule, lesson.rule) }) {
                shared[index].projects[projectID] = stack
            } else {
                shared.append(SharedLesson(when: lesson.when, rule: lesson.rule, why: lesson.why, projects: [projectID: stack]))
            }
        }
        shared = Array(shared.filter { !$0.projects.isEmpty }.sorted { $0.rule < $1.rule }.prefix(Self.maxStoredLessons))
        guard shared != (stored.lessons ?? []) else { return }
        stored.lessons = shared
        try? save(stored)
    }

    /// Prompt text. It carries no dates or counters that move on their own, so it
    /// is captured into a conversation once and again only when a fact changes.
    /// With a project, the lessons shown are the ones learned in at least two
    /// other places that fit this project's stack; its own are already in its
    /// learned rules.
    public func text(projectID: String? = nil, stack: [String] = []) -> String {
        let stored = load()
        var parts: [String] = []
        if !stored.preferences.isEmpty {
            parts.append("## Preferences\n" + stored.preferences.keys.sorted()
                .map { "- \($0): \(stored.preferences[$0] ?? "")" }.joined(separator: "\n"))
        }
        let ranked = stored.technologies
            .sorted { $0.value.count != $1.value.count ? $0.value.count > $1.value.count : $0.key < $1.key }
            .prefix(Self.maxTechnologies)
        if !ranked.isEmpty {
            parts.append("## Technologies the user's projects use (project count)\n"
                + ranked.map { "- \($0.key) (\($0.value.count))" }.joined(separator: "\n")
                + "\nWhen a new project leaves the stack open, use the most used one that fits instead of asking.")
        }
        let lessons = (stored.lessons ?? [])
            .filter { lesson in
                let technologies = lesson.technologies
                return lesson.projects.count >= 2
                    && projectID.map { lesson.projects[$0] == nil } ?? true
                    && (technologies.isEmpty || stack.isEmpty || !technologies.isDisjoint(with: stack))
            }
            .sorted { $0.projects.count != $1.projects.count ? $0.projects.count > $1.projects.count : $0.rule < $1.rule }
            .prefix(Self.maxSharedLessons)
        if !lessons.isEmpty {
            parts.append("## Lessons from the user's other projects\n" + lessons.map { lesson in
                let technologies = lesson.technologies.sorted().joined(separator: ", ")
                return "- " + (technologies.isEmpty ? "" : "[\(technologies)] ")
                    + Lesson(when: lesson.when, rule: lesson.rule, why: lesson.why).line
            }.joined(separator: "\n"))
        }
        guard !parts.isEmpty else { return "" }
        return (["What HerNess has learned about this user across all their projects. Apply it without "
            + "asking again; the user's current message and this project's own rules win over it."] + parts)
            .joined(separator: "\n\n")
    }
}

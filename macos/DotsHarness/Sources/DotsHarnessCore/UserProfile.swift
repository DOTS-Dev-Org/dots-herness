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
        /// Project id to that project's preferences. Optional so a profile written
        /// before it existed still decodes; a missing key would otherwise drop the whole file.
        var projectPreferences: [String: [String: String]]? = nil
        /// Project id to its folder's name, so the memory graph can name a project that is not open.
        var projectNames: [String: String]? = nil
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

    /// Preferences that hold in every project.
    public func preferences() -> [String: String] { load().preferences }

    /// Technology name to the ids of the projects that use it.
    public func technologies() -> [String: [String]] { load().technologies }

    /// The keys of the everywhere preferences that this project replaces.
    public func overriddenPreferences(projectID: String?, projectKeys: Set<String> = []) -> Set<String> {
        overridden(projectID: projectID, projectKeys: projectKeys, stored: load())
    }

    private func overridden(projectID: String?, projectKeys: Set<String>, stored: Stored) -> Set<String> {
        let own = projectID.flatMap { stored.projectPreferences?[$0] } ?? [:]
        let replaced = Set(projectKeys.map { $0.lowercased() }).union(own.keys.map { $0.lowercased() })
        return Set(stored.preferences.keys.filter { replaced.contains($0.lowercased()) })
    }

    /// Preferences that hold in one project only, keyed by the project's id.
    public func projectPreferences(projectID: String) -> [String: String] {
        load().projectPreferences?[projectID] ?? [:]
    }

    public func setProjectPreference(projectID: String, key: String, value: String) throws {
        var stored = load()
        var all = stored.projectPreferences ?? [:]
        var own = all[projectID] ?? [:]
        guard own[key] != nil || own.count < Self.maxPreferences else { return }
        own[key] = value
        all[projectID] = own
        stored.projectPreferences = all
        try save(stored)
    }

    /// Imports personal memory without discarding profile entries that are not in the archive.
    func merge(_ imported: Stored) throws {
        var stored = load()
        for (key, value) in imported.preferences.sorted(by: { $0.key < $1.key }) {
            guard stored.preferences[key] != nil || stored.preferences.count < Self.maxPreferences else { continue }
            stored.preferences[key] = value
        }
        var technologies = stored.technologies
        for (technology, projects) in imported.technologies {
            technologies[technology] = Array(Set(technologies[technology, default: []]).union(projects)).sorted()
        }
        stored.technologies = technologies

        var projectPreferences = stored.projectPreferences ?? [:]
        for (projectID, importedValues) in imported.projectPreferences ?? [:] {
            var values = projectPreferences[projectID] ?? [:]
            for (key, value) in importedValues.sorted(by: { $0.key < $1.key }) {
                guard values[key] != nil || values.count < Self.maxPreferences else { continue }
                values[key] = value
            }
            projectPreferences[projectID] = values
        }
        stored.projectPreferences = projectPreferences

        stored.projectNames = (stored.projectNames ?? [:]).merging(imported.projectNames ?? [:]) { _, imported in imported }
        var lessons = stored.lessons ?? []
        for incoming in imported.lessons ?? [] {
            if let index = lessons.firstIndex(where: { Lesson.similar($0.rule, incoming.rule) }) {
                var known = lessons[index]
                for (projectID, stack) in incoming.projects { known.projects[projectID] = stack }
                if known.when.isEmpty { known.when = incoming.when }
                if known.why.isEmpty { known.why = incoming.why }
                lessons[index] = known
            } else {
                lessons.append(incoming)
            }
        }
        stored.lessons = Array(lessons.prefix(Self.maxStoredLessons))
        try save(stored)
    }

    /// Removes one preference for good; nothing is kept of it here.
    public func removePreference(key: String, projectID: String?) throws {
        var stored = load()
        if let projectID {
            stored.projectPreferences?[projectID]?.removeValue(forKey: key)
        } else {
            stored.preferences.removeValue(forKey: key)
        }
        try save(stored)
    }

    public func projectNames() -> [String: String] { load().projectNames ?? [:] }

    public func recordProject(name: String, projectID: String) {
        var stored = load()
        guard !name.isEmpty, stored.projectNames?[projectID] != name else { return }
        stored.projectNames = (stored.projectNames ?? [:]).merging([projectID: name]) { $1 }
        try? save(stored)
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
        // Past the cap the lessons fewest projects taught go first.
        shared = Array(shared.filter { !$0.projects.isEmpty }
            .sorted { $0.projects.count != $1.projects.count ? $0.projects.count > $1.projects.count : $0.rule < $1.rule }
            .prefix(Self.maxStoredLessons))
        guard shared != (stored.lessons ?? []) else { return }
        stored.lessons = shared
        try? save(stored)
    }

    /// Prompt text. It carries no dates or counters that move on their own, so it
    /// is captured into a conversation once and again only when a fact changes.
    /// With a project, the lessons shown are the ones learned in at least two
    /// other places that fit this project's stack; its own are already in its
    /// learned rules.
    /// A preference the project also sets - in the person's own preferences for it, or under
    /// `projectKeys`, the entries of its repository memory - is left out: the project's value is
    /// the one in force there, and showing both would hand the model a contradiction.
    public func text(projectID: String? = nil, stack: [String] = [], projectKeys: Set<String> = []) -> String {
        let stored = load()
        var parts: [String] = []
        let preferences = stored.preferences.filter { !overridden(projectID: projectID, projectKeys: projectKeys, stored: stored).contains($0.key) }
        if !preferences.isEmpty {
            parts.append("## Preferences\n" + preferences.keys.sorted()
                .map { "- \($0): \(preferences[$0] ?? "")" }.joined(separator: "\n"))
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

// Copyright (c) 2026 DOTS
// Owns the one pending skill suggestion and how often one may appear. Never creates
// a skill on its own — acceptCurrent is only ever called from an explicit user
// action (a click on the suggestion banner), never from agent tool calls.
//
// A card is rare by design: at most one per cooldown, whatever its source, and after
// pauseAfterDismissals dismissals in a row none at all for pause.
// Mirrors shared/SkillSuggestionMonitor.cs.

import Combine
import Foundation
import PluginRuntime

@MainActor
public final class SkillSuggestionMonitor: ObservableObject {
    public static let cooldown: TimeInterval = 7 * 24 * 60 * 60
    public static let pause: TimeInterval = 30 * 24 * 60 * 60
    public static let pauseAfterDismissals = 2

    private struct State: Codable {
        var seenIDs: [String] = []
        var lastShownAt: Date?
        var pausedUntil: Date?
        var dismissStreak: Int?
    }

    private let paths: SupportPaths
    private let skills: SkillCatalog
    private var seenIDs = Set<String>()
    private var workspaceURL: URL?
    private var lastShownAt = Date.distantPast
    private var pausedUntil = Date.distantPast
    private var dismissStreak = 0

    public var enabled = true {
        didSet { if !enabled { pending = nil } }
    }

    /// Injectable for tests.
    public var now: () -> Date = Date.init

    @Published public private(set) var pending: SkillSuggestion?

    /// False while a card is showing, one was shown within cooldown, or suggestions are paused.
    public var canSuggest: Bool {
        let now = now()
        return enabled && pending == nil && now.timeIntervalSince(lastShownAt) >= Self.cooldown && now >= pausedUntil
    }

    public init(paths: SupportPaths, skills: SkillCatalog) {
        self.paths = paths
        self.skills = skills
        loadState()
    }

    public func setWorkspace(_ path: String?) {
        workspaceURL = path.flatMap { URL(fileURLWithPath: $0, isDirectory: true) }
        pending = nil
    }

    public func scan(lessons: [Lesson]) {
        guard workspaceURL != nil, canSuggest else { return }
        if let candidate = SkillSuggestionEngine.fromLessons(lessons).first(where: { !seenIDs.contains($0.id) }) {
            show(candidate)
        }
    }

    @discardableResult
    public func acceptCurrent(name: String, description: String, body: String? = nil) throws -> String {
        guard let suggestion = pending else {
            throw SkillCatalogError.invalid("No pending skill suggestion.")
        }
        let id = try skills.create(name: name, description: description, body: body ?? suggestion.body)
        seenIDs.insert(suggestion.id)
        dismissStreak = 0
        pending = nil
        saveState()
        return id
    }

    public func dismissCurrent() {
        guard let suggestion = pending else { return }
        seenIDs.insert(suggestion.id)
        dismissStreak += 1
        if dismissStreak >= Self.pauseAfterDismissals {
            pausedUntil = now().addingTimeInterval(Self.pause)
            dismissStreak = 0
        }
        pending = nil
        saveState()
    }

    /// Lets the agent propose a skill (via the skill.suggest tool). This only ever
    /// surfaces a suggestion card — it never writes anything; returns nil when no
    /// card may show now or a skill of this name was already suggested.
    @discardableResult
    public func proposeFromAgent(name: String, description: String, body: String) -> SkillSuggestion? {
        guard canSuggest else { return nil }
        let name = name.trimmingCharacters(in: .whitespaces)
        // ponytail: keyed on the name alone so a reworded description does not resurface it; a renamed one still can, the cooldown caps that.
        let id = SkillSuggestionEngine.shortHash("agent:" + name.lowercased())
        guard !seenIDs.contains(id) else { return nil }
        let suggestion = SkillSuggestion(
            id: id,
            signal: .agentProposed,
            draftName: name,
            draftDescription: description.trimmingCharacters(in: .whitespaces),
            body: body
        )
        show(suggestion)
        return suggestion
    }

    private func show(_ suggestion: SkillSuggestion) {
        pending = suggestion
        lastShownAt = now()
        saveState()
    }

    private var stateURL: URL { paths.root.appendingPathComponent("skill-suggestions-state.json") }

    private func loadState() {
        guard let data = try? Data(contentsOf: stateURL),
              let state = try? JSONDecoder().decode(State.self, from: data) else { return }
        seenIDs = Set(state.seenIDs)
        lastShownAt = state.lastShownAt ?? .distantPast
        pausedUntil = state.pausedUntil ?? .distantPast
        dismissStreak = state.dismissStreak ?? 0
    }

    private func saveState() {
        let state = State(
            seenIDs: seenIDs.sorted(),
            lastShownAt: lastShownAt == .distantPast ? nil : lastShownAt,
            pausedUntil: pausedUntil == .distantPast ? nil : pausedUntil,
            dismissStreak: dismissStreak
        )
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: stateURL, options: .atomic)
    }
}

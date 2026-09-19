// Copyright (c) 2026 DOTS
// Coordinates the two skill-suggestion detectors and owns accept/dismiss state.
// Never creates a skill on its own — acceptCurrent is only ever called from an
// explicit user action (a click on the suggestion banner), never from agent tool calls.

import Combine
import CryptoKit
import Foundation
import PluginRuntime

@MainActor
public final class SkillSuggestionMonitor: ObservableObject {
    private struct State: Codable {
        var seenIDs: [String] = []
    }

    private static let scanDebounce: TimeInterval = 120

    private let paths: SupportPaths
    private let skills: SkillCatalog
    private var seenIDs = Set<String>()
    private var workspaceURL: URL?
    private var lastScanAt = Date.distantPast

    public var enabled = true
    public var toolRepeatThreshold = 3
    public var promptRepeatThreshold = 3
    public var promptSimilarityThreshold = 0.75

    @Published public private(set) var pending: SkillSuggestion?

    public init(paths: SupportPaths, skills: SkillCatalog) {
        self.paths = paths
        self.skills = skills
        loadState()
    }

    public func setWorkspace(_ path: String?) {
        workspaceURL = path.flatMap { URL(fileURLWithPath: $0, isDirectory: true) }
        pending = nil
        lastScanAt = .distantPast
    }

    public func scan(recentUserPrompts: [String]) {
        guard enabled, let workspaceURL else { return }
        let now = Date()
        guard now.timeIntervalSince(lastScanAt) >= Self.scanDebounce else { return }
        lastScanAt = now

        let toolSuggestions = SkillSuggestionEngine.detectToolSequencePatterns(
            events: MemEventStore.readToolExecutedEvents(workspace: workspaceURL),
            minOccurrences: toolRepeatThreshold
        )
        let promptSuggestions = SkillSuggestionEngine.detectPromptSimilarityPatterns(
            userPrompts: recentUserPrompts,
            minOccurrences: promptRepeatThreshold,
            similarityThreshold: promptSimilarityThreshold
        )

        let candidate = (toolSuggestions + promptSuggestions)
            .filter { !seenIDs.contains($0.id) }
            .sorted { lhs, rhs in
                if lhs.occurrences != rhs.occurrences { return lhs.occurrences > rhs.occurrences }
                return (lhs.signal == .toolSequence ? 0 : 1) < (rhs.signal == .toolSequence ? 0 : 1)
            }
            .first

        if let candidate { pending = candidate }
    }

    @discardableResult
    public func acceptCurrent(name: String, description: String, body: String? = nil) throws -> String {
        guard let suggestion = pending else {
            throw SkillCatalogError.invalid("No pending skill suggestion.")
        }
        let id = try skills.create(name: name, description: description, body: body ?? suggestion.draftBody())
        seenIDs.insert(suggestion.id)
        pending = nil
        saveState()
        return id
    }

    public func dismissCurrent() {
        if let suggestion = pending { seenIDs.insert(suggestion.id) }
        pending = nil
        saveState()
    }

    /// Lets the agent itself propose a skill mid-conversation (via the skill.suggest tool)
    /// when it notices a pattern the background scanners wouldn't catch on their own.
    /// This only ever surfaces a suggestion card — it never writes anything; returns nil
    /// if this exact proposal was already suggested and accepted or dismissed before.
    @discardableResult
    public func proposeFromAgent(name: String, description: String, body: String) -> SkillSuggestion? {
        let id = Self.shortHash(name.trimmingCharacters(in: .whitespaces) + "|" + description.trimmingCharacters(in: .whitespaces))
        guard !seenIDs.contains(id) else { return nil }

        let suggestion = SkillSuggestion(
            id: id,
            signal: .agentProposed,
            title: name,
            draftName: name,
            draftDescription: description,
            samples: [],
            occurrences: 1,
            firstSeen: Date(),
            lastSeen: Date(),
            suggestedBody: body
        )
        pending = suggestion
        return suggestion
    }

    private static func shortHash(_ key: String) -> String {
        let digest = SHA256.hash(data: Data(key.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(12).lowercased()
    }

    private func loadState() {
        guard let data = try? Data(contentsOf: paths.root.appendingPathComponent("skill-suggestions-state.json")),
              let state = try? JSONDecoder().decode(State.self, from: data) else { return }
        seenIDs = Set(state.seenIDs)
    }

    private func saveState() {
        let state = State(seenIDs: seenIDs.sorted())
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: paths.root.appendingPathComponent("skill-suggestions-state.json"), options: .atomic)
    }
}

// Copyright (c) 2026 DOTS
// Project facts and private user preferences. Repository permissions are managed by Git.

import Foundation
import PluginRuntime

extension WorkspaceMemory {
    /// Records a durable fact about this project in `.mem/facts.md`.
    public func setProjectDefault(key: String, value: String) throws {
        try setProjectMemoryFact(kind: "project", key: key, text: value)
    }

    public func forgetProjectDefault(key: String) throws {
        try removeProjectMemoryFact(kind: "project", key: sanitize(key, limit: 60))
    }

    /// Settled project decisions are project facts too; the repository's Git history records who changed them.
    public func recordProjectDecision(summary: String) throws {
        let text = sanitize(summary, limit: 240)
        guard !text.isEmpty else { return }
        let key = "decision-" + String(digest(Data(text.utf8)).prefix(12))
        try setProjectMemoryFact(kind: "decision", key: key, text: text)
    }

    public var projectDefaults: [String: String] {
        projectFactsByKind()["project"] ?? [:]
    }

    public var hasProjectBrief: Bool {
        projectDefaults.keys.contains { !ProjectKnowledge.keys.contains($0) }
    }

    public var missingKnowledge: [String] {
        let defaults = projectDefaults
        return ProjectKnowledge.keys.filter { defaults[$0] == nil }
    }

    /// A preference that belongs to the person and follows them to every project.
    public func setUserPreference(key: String, value: String) throws {
        try profile.setPreference(key: sanitize(key, limit: 60), value: sanitize(value, limit: 240))
    }

    /// A preference for this project only. It remains in the user's app support folder.
    public func setProjectUserPreference(key: String, value: String) throws {
        guard let projectID else { throw WorkspaceMemoryError.noWorkspace }
        try profile.setProjectPreference(projectID: projectID, key: sanitize(key, limit: 60), value: sanitize(value, limit: 240))
    }

    public func removeUserPreference(key: String, scope: MemoryPreferenceScope) throws {
        switch scope {
        case .everywhere:
            try profile.removePreference(key: key, projectID: nil)
        case .thisProject:
            guard let projectID else { throw WorkspaceMemoryError.noWorkspace }
            try profile.removePreference(key: key, projectID: projectID)
        }
    }

    // MARK: - Trust in project memory that came with the repository

    /// Project memory HerNess started in this checkout is trusted. Memory that was
    /// already there - cloned or pulled in - stays plain data until the user trusts it.
    /// Keyed by the checkout's path: the project id is read from the repository and can be copied.
    public var projectMemoryTrust: Bool? {
        guard let key = workspaceURL?.standardizedFileURL.path else { return nil }
        return trustDecisions()[key]
    }

    public var projectMemoryTrusted: Bool { projectMemoryTrust == true }

    /// The repository brought memory the user has not decided about yet.
    public var needsProjectMemoryTrust: Bool {
        enabled && manifest != nil && projectMemoryTrust == nil && !projectMemoryFacts().isEmpty
    }

    public func setProjectMemoryTrust(_ trusted: Bool) throws {
        guard let key = workspaceURL?.standardizedFileURL.path else { throw WorkspaceMemoryError.noWorkspace }
        var decisions = trustDecisions()
        decisions[key] = trusted
        try fileManager.createDirectory(at: paths.root, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: decisions, options: [.sortedKeys]).write(to: trustURL, options: .atomic)
    }

    private var trustURL: URL { paths.root.appendingPathComponent("project-memory-trust.json") }

    private func trustDecisions() -> [String: Bool] {
        (try? Data(contentsOf: trustURL)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Bool] } ?? [:]
    }
}

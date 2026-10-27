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
    /// A reason and platforms given apart are kept whole beside the sentence; see `ProjectDecisions.compose`.
    public func recordProjectDecision(summary: String, reason: String = "", platforms: [String] = []) throws {
        let structured = !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !platforms.isEmpty
        let text = structured
            ? ProjectDecisions.compose(statement: summary, reason: reason, platforms: platforms)
            : sanitizeSentence(summary, limit: Self.decisionTextLimit)
        guard !text.isEmpty else { return }
        let key = "decision-" + String(digest(Data(ProjectDecisions.body(text).utf8)).prefix(12))
        try setProjectMemoryFact(kind: "decision", key: key, text: text)
    }

    /// Takes a decision out of the project's memory, and out of any review that suggested it.
    public func forgetProjectDecision(key: String) throws {
        try removeProjectMemoryFact(kind: "decision", key: key)
        keepProjectDecision(key: key)
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
    /// Keyed by the checkout's path, and by the project's identity so a checkout that moves,
    /// or a second clone of the same repository, keeps the answer. An answer for this very
    /// checkout wins over one for its project.
    public var projectMemoryTrust: Bool? {
        guard let key = workspaceURL?.standardizedFileURL.path else { return nil }
        let decisions = trustDecisions()
        if let trusted = decisions[key] { return trusted }
        return repositoryIdentity.flatMap { decisions[$0] }
    }

    /// The project id from the manifest joined to the address the checkout was cloned from.
    /// The id alone is read from the repository and can be copied into any other one; the
    /// remote is this Mac's own record of where the code came from, so a repository that
    /// copies a trusted project's id still does not share its trust. Mirrors WorkspaceFacts.cs.
    var repositoryIdentity: String? {
        guard let projectID, UUID(uuidString: projectID) != nil, let workspaceURL,
              let origin = Self.gitOrigin(of: workspaceURL) else { return nil }
        return "project:\(projectID.uppercased())@\(origin)"
    }

    /// The origin remote of a checkout, without scheme, user, credentials or ".git".
    nonisolated static func gitOrigin(of workspace: URL) -> String? {
        let fileManager = FileManager.default
        let dotGit = workspace.appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) else { return nil }
        var gitDir = dotGit
        if !isDirectory.boolValue {
            // A worktree or submodule: ".git" is a file naming the real folder.
            guard let pointer = try? String(contentsOf: dotGit, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
                  pointer.hasPrefix("gitdir:") else { return nil }
            let target = pointer.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
            gitDir = target.hasPrefix("/") ? URL(fileURLWithPath: target) : workspace.appendingPathComponent(target)
            if let common = try? String(contentsOf: gitDir.appendingPathComponent("commondir"), encoding: .utf8) {
                let path = common.trimmingCharacters(in: .whitespacesAndNewlines)
                gitDir = path.hasPrefix("/") ? URL(fileURLWithPath: path) : gitDir.appendingPathComponent(path)
            }
        }
        guard let config = try? String(contentsOf: gitDir.appendingPathComponent("config"), encoding: .utf8) else { return nil }
        var inOrigin = false
        for raw in config.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inOrigin = line.range(of: #"^\[remote\s+"origin"\]$"#, options: .regularExpression) != nil
                continue
            }
            guard inOrigin, let match = line.range(of: #"^url\s*=\s*"#, options: .regularExpression) else { continue }
            return normalizeRemote(String(line[match.upperBound...]))
        }
        return nil
    }

    /// "git@github.com:owner/repo.git" and "https://github.com/owner/repo" are one repository:
    /// "github.com/owner/repo". Nil for a remote that names no host and path.
    nonisolated static func normalizeRemote(_ url: String) -> String? {
        var value = url.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        if !value.contains("://"),
           let scp = value.range(of: #"^(?:[^@/\s]+@)?[^:/\s]+:"#, options: .regularExpression) {
            let prefix = value[scp].dropLast()
            let host = prefix.split(separator: "@").last.map(String.init) ?? String(prefix)
            value = host + "/" + value[scp.upperBound...]
        } else {
            if let scheme = value.range(of: #"^[a-zA-Z][a-zA-Z0-9+.-]*://"#, options: .regularExpression) { value.removeSubrange(scheme) }
            if let user = value.range(of: #"^[^@/]*@"#, options: .regularExpression) { value.removeSubrange(user) }
        }
        while value.hasSuffix("/") { value.removeLast() }
        if value.lowercased().hasSuffix(".git") { value.removeLast(4) }
        guard let slash = value.firstIndex(of: "/"), slash != value.startIndex, value.index(after: slash) != value.endIndex else { return nil }
        // Host names are not case-sensitive; a path may be.
        var host = value[..<slash].lowercased()
        if let port = host.range(of: #":(22|443)$"#, options: .regularExpression) { host.removeSubrange(port) }
        return host + value[slash...]
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
        if let identity = repositoryIdentity { decisions[identity] = trusted }
        try fileManager.createDirectory(at: paths.root, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: decisions, options: [.sortedKeys]).write(to: trustURL, options: .atomic)
    }

    private var trustURL: URL { paths.root.appendingPathComponent("project-memory-trust.json") }

    private func trustDecisions() -> [String: Bool] {
        (try? Data(contentsOf: trustURL)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Bool] } ?? [:]
    }
}

// Copyright (c) 2026 DOTS
// Reads the rules files an agent-aware repository already ships - AGENTS.md,
// CLAUDE.md, .cursor/rules - so HerNess honours the conventions a project has
// already written down for other tools. The text is project context, never
// policy: it is emitted under `trust="data"`.
//
// Mirrors shared/ProjectRules.cs.

import Foundation

public enum ProjectRules {
    /// Read in this order; the first entries carry the most weight because a
    /// repository that has both usually keeps AGENTS.md as the general file.
    static let fileNames = ["AGENTS.md", "CLAUDE.md", ".cursorrules"]
    static let cursorRulesDirectory = ".cursor/rules"

    /// Per-file and total ceilings. A rules file is meant to be short; a repo
    /// that pastes a novel into AGENTS.md must not evict the conversation.
    static let maxBytesPerFile = 16_000
    static let maxTotalBytes = 32_000
    static let maxCursorRuleFiles = 10

    /// The workspace's rules text, already labelled by source file. Empty when
    /// the project ships none.
    public static func text(workspace: URL?) -> String {
        guard let workspace else { return "" }
        sync(workspace: workspace)
        var blocks: [String] = []
        var bodies: Set<String> = []
        var total = 0

        for name in fileNames {
            guard let block = read(workspace.appendingPathComponent(name), label: name, workspace: workspace) else { continue }
            // After sync AGENTS.md and CLAUDE.md hold the same text; emit it once.
            let body = String(block.drop(while: { $0 != "\n" }))
            guard bodies.insert(body).inserted else { continue }
            guard total + block.utf8.count <= maxTotalBytes else { break }
            total += block.utf8.count
            blocks.append(block)
        }

        for url in cursorRuleFiles(workspace: workspace) {
            let label = relativeLabel(url, workspace: workspace)
            guard let block = read(url, label: label, workspace: workspace) else { continue }
            guard total + block.utf8.count <= maxTotalBytes else { break }
            total += block.utf8.count
            blocks.append(block)
        }

        return blocks.joined(separator: "\n\n")
    }

    /// Written to both files when a project ships neither, so every workspace
    /// starts with a rules file the user can edit.
    static let seed = """
    # Project rules
    
    Conventions for any agent working in this repository.
    AGENTS.md and CLAUDE.md are kept byte-identical by HerNess: edit either one.
    
    - (add project conventions here)
    """

    /// Creates AGENTS.md and CLAUDE.md when the project ships neither. Called
    /// once when a workspace opens, before the first turn - never per message -
    /// and skipped entirely when the user turns the setting off. A project that
    /// already has either file is left alone.
    @discardableResult
    public static func seedIfMissing(workspace: URL?) -> Bool {
        guard let workspace else { return false }
        let agents = workspace.appendingPathComponent("AGENTS.md")
        let claude = workspace.appendingPathComponent("CLAUDE.md")
        guard contains(workspace: workspace, url: agents), contains(workspace: workspace, url: claude) else { return false }
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: agents.path), !fileManager.fileExists(atPath: claude.path) else { return false }
        do {
            try Data(seed.utf8).write(to: agents, options: .atomic)
            try Data(seed.utf8).write(to: claude, options: .atomic)
            return true
        } catch { return false }
    }

    /// Keeps AGENTS.md and CLAUDE.md identical: whichever was written last wins
    /// and is mirrored onto the other, so a rule the user records in one tool's
    /// file is honoured by the other. Missing counterpart is created.
    public static func sync(workspace: URL?) {
        guard let workspace else { return }
        let agents = workspace.appendingPathComponent("AGENTS.md")
        let claude = workspace.appendingPathComponent("CLAUDE.md")
        guard contains(workspace: workspace, url: agents), contains(workspace: workspace, url: claude) else { return }

        let a = try? Data(contentsOf: agents)
        let c = try? Data(contentsOf: claude)
        guard a != c else { return }

        let source: URL, target: URL
        switch (a, c) {
        case (.some, .none): (source, target) = (agents, claude)
        case (.none, .some): (source, target) = (claude, agents)
        case (.some, .some):
            (source, target) = modified(agents) >= modified(claude) ? (agents, claude) : (claude, agents)
        case (.none, .none): return
        }
        guard let data = try? Data(contentsOf: source) else { return }
        try? data.write(to: target, options: .atomic)
    }

    private static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    private static func cursorRuleFiles(workspace: URL) -> [URL] {
        let directory = workspace.appendingPathComponent(cursorRulesDirectory, isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return [] }
        return entries
            .filter { ["md", "mdc"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .prefix(maxCursorRuleFiles)
            .map { $0 }
    }

    private static func read(_ url: URL, label: String, workspace: URL) -> String? {
        // Same symlink rule the file tools use: a rules file that resolves
        // outside the workspace is not this project's rules file.
        guard contains(workspace: workspace, url: url) else { return nil }
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        let limited = data.prefix(maxBytesPerFile)
        guard let raw = String(data: limited, encoding: .utf8) else { return nil }
        let body = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return nil }
        let suffix = data.count > limited.count ? "\n… truncated" : ""
        return "# \(label)\n\(body)\(suffix)"
    }

    private static func contains(workspace: URL, url: URL) -> Bool {
        let root = workspace.standardizedFileURL.resolvingSymlinksInPath()
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return resolved.path.hasPrefix(rootPath)
    }

    private static func relativeLabel(_ url: URL, workspace: URL) -> String {
        let root = workspace.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(root + "/") else { return url.lastPathComponent }
        return String(path.dropFirst(root.count + 1))
    }
}

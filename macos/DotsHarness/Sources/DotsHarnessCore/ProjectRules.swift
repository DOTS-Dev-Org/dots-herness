// Copyright (c) 2026 DOTS
// Reads the rules files an agent-aware repository already ships - AGENTS.md,
// CLAUDE.md, AGENTS.override.md, .claude/rules, .cursor/rules and their
// siblings - so HerNess honours the conventions a project has already written
// down for other tools.
//
// Mirrors root-level loading in shared/ProjectRules.cs; scoped prompt context is
// resolved by the macOS agent host when a workspace tool targets a subdirectory.

import Foundation

public enum ProjectRules {
    /// Read in this order; the first entries carry the most weight because a
    /// repository that has both usually keeps AGENTS.md as the general file.
    static let fileNames = [
        "AGENTS.md",
        "CLAUDE.md",
        "CLAUDE.local.md",
        ".claude/CLAUDE.md",
        "GEMINI.md",
        ".github/copilot-instructions.md",
        ".cursorrules",
    ]
    static let overrideFileName = "AGENTS.override.md"
    private static let scopedFileNames = [overrideFileName, "AGENTS.md", "CLAUDE.md"]
    static let rulesDirectories = [".claude/rules", ".cursor/rules"]

    /// Per-file and total ceilings. A rules file is meant to be short; a repo
    /// that pastes a novel into AGENTS.md must not evict the conversation.
    static let maxBytesPerFile = 16_000
    static let maxTotalBytes = 32_000
    static let maxRuleFilesPerDirectory = 10

    public struct ScopedContext: Sendable, Equatable {
        public let relativePath: String
        public let text: String

        public init(relativePath: String, text: String) {
            self.relativePath = relativePath
            self.text = text
        }
    }

    private final class Snapshot: @unchecked Sendable {
        let signature: String
        let text: String

        init(signature: String, text: String) {
            self.signature = signature
            self.text = text
        }
    }

    private final class SnapshotStore: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: Snapshot] = [:]
        private var insertionOrder: [String] = []

        func value(for key: String, signature: String) -> Snapshot? {
            lock.lock()
            defer { lock.unlock() }
            guard let snapshot = values[key], snapshot.signature == signature else { return nil }
            return snapshot
        }

        func store(_ snapshot: Snapshot, for key: String) {
            lock.lock()
            defer { lock.unlock() }
            if values[key] == nil { insertionOrder.append(key) }
            values[key] = snapshot
            while insertionOrder.count > 16 {
                values.removeValue(forKey: insertionOrder.removeFirst())
            }
        }

        func remove(_ key: String) {
            lock.lock()
            defer { lock.unlock() }
            values.removeValue(forKey: key)
            insertionOrder.removeAll { $0 == key }
        }
    }

    private static let snapshots = SnapshotStore()

    /// The workspace's rules text, already labelled by source file. Empty when
    /// the project ships none.
    public static func text(workspace: URL?) -> String {
        snapshot(workspace: workspace).text
    }

    /// Returns whether the rule text came from the metadata-validated cache.
    /// Prompt telemetry records this without retaining any rule contents.
    static func snapshot(workspace: URL?) -> (text: String, cacheHit: Bool) {
        guard let workspace else { return ("", false) }
        let root = workspace.standardizedFileURL.resolvingSymlinksInPath()
        let key = root.path
        let before = signature(workspace: root)
        if let cached = snapshots.value(for: key, signature: before) {
            return (cached.text, true)
        }

        let rendered = loadTextAndSync(workspace: root)
        let after = signature(workspace: root)
        // If another process changed a rules file while it was read (or sync
        // mirrored a newer file), return the coherent read but let the next
        // prompt rebuild against the new signature.
        if before == after {
            snapshots.store(Snapshot(signature: after, text: rendered), for: key)
        } else {
            snapshots.remove(key)
        }
        return (rendered, false)
    }

    /// Explicit invalidation for in-app writes. External edits are detected by
    /// the metadata signature on the next prompt.
    public static func invalidate(workspace: URL?) {
        guard let workspace else { return }
        let root = workspace.standardizedFileURL.resolvingSymlinksInPath()
        snapshots.remove(root.path)
    }

    private static func loadTextAndSync(workspace: URL) -> String {
        var files: [String: Data] = [:]
        for name in fileNames + [overrideFileName] {
            let url = workspace.appendingPathComponent(name)
            if let data = readData(url, workspace: workspace) { files[name] = data }
        }

        let agents = workspace.appendingPathComponent("AGENTS.md")
        let claude = workspace.appendingPathComponent("CLAUDE.md")
        if contains(workspace: workspace, url: agents), contains(workspace: workspace, url: claude),
           let (source, target) = syncPair(agents: agents, claude: claude, files: files) {
            if let data = files[source.lastPathComponent], (try? data.write(to: target, options: .atomic)) != nil {
                files[target.lastPathComponent] = data
            }
        }

        var blocks: [String] = []
        var bodies: Set<String> = []
        var total = 0

        // AGENTS.override.md replaces AGENTS.md/CLAUDE.md, not the other tools' files.
        let rootRuleNames = files[overrideFileName] == nil
            ? fileNames
            : [overrideFileName] + fileNames.filter { $0 != "AGENTS.md" && $0 != "CLAUDE.md" }
        for name in rootRuleNames {
            guard let data = files[name], let block = render(data, label: name) else { continue }
            // After sync AGENTS.md and CLAUDE.md hold the same text; emit it once.
            let body = String(block.drop(while: { $0 != "\n" }))
            guard bodies.insert(body).inserted else { continue }
            guard total + block.utf8.count <= maxTotalBytes else { break }
            total += block.utf8.count
            blocks.append(block)
        }

        for url in ruleFiles(workspace: workspace) {
            let label = relativeLabel(url, workspace: workspace)
            guard let data = readData(url, workspace: workspace), let block = render(data, label: label) else { continue }
            guard total + block.utf8.count <= maxTotalBytes else { break }
            total += block.utf8.count
            blocks.append(block)
        }

        return blocks.joined(separator: "\n\n")
    }

    /// The nested instructions that apply to a target path. Root instructions
    /// remain in `text(workspace:)`; this returns only descendant directory rules.
    public static func scopedContext(
        workspace: URL?,
        target: URL,
        targetIsDirectory: Bool
    ) -> ScopedContext? {
        guard let workspace else { return nil }
        let root = workspace.standardizedFileURL.resolvingSymlinksInPath()
        let resolvedTarget = target.standardizedFileURL.resolvingSymlinksInPath()
        guard isInside(resolvedTarget, root: root) else { return nil }

        let scopeDirectory = (targetIsDirectory ? resolvedTarget : resolvedTarget.deletingLastPathComponent())
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard isInside(scopeDirectory, root: root), scopeDirectory.path != root.path else { return nil }
        let relativePath = relativeLabel(scopeDirectory, workspace: root)
        guard !relativePath.isEmpty, relativePath != "." else { return nil }

        var directories: [URL] = []
        var directory = root
        for component in relativePath.split(separator: "/") {
            directory.appendPathComponent(String(component), isDirectory: true)
            directories.append(directory)
        }

        let cacheKey = "\u{0}scope:\(root.path):\(scopeDirectory.path)"
        let before = scopedSignature(workspace: root, directories: directories)
        if let cached = snapshots.value(for: cacheKey, signature: before) {
            return ScopedContext(relativePath: relativePath, text: cached.text)
        }

        let rendered = loadScopedText(workspace: root, directories: directories)
        let after = scopedSignature(workspace: root, directories: directories)
        if before == after {
            snapshots.store(Snapshot(signature: after, text: rendered), for: cacheKey)
        } else {
            snapshots.remove(cacheKey)
        }
        return ScopedContext(relativePath: relativePath, text: rendered)
    }

    private static func loadScopedText(workspace: URL, directories: [URL]) -> String {
        var candidates: [String] = []
        var bodies: Set<String> = []

        for directory in directories {
            let override = directory.appendingPathComponent(overrideFileName)
            if let data = readData(override, workspace: workspace) {
                if let block = render(data, label: relativeLabel(override, workspace: workspace)) {
                    let body = String(block.drop(while: { $0 != "\n" }))
                    if bodies.insert(body).inserted { candidates.append(block) }
                }
                // An empty override still replaces this directory's regular rules.
                continue
            }

            for name in ["AGENTS.md", "CLAUDE.md"] {
                let url = directory.appendingPathComponent(name)
                guard let data = readData(url, workspace: workspace),
                      let block = render(data, label: relativeLabel(url, workspace: workspace)) else { continue }
                let body = String(block.drop(while: { $0 != "\n" }))
                if bodies.insert(body).inserted { candidates.append(block) }
            }
        }

        // Keep the closest rules when a deep hierarchy exceeds the total budget,
        // then restore parent-to-child order so deeper instructions come later.
        var selected: [String] = []
        var total = 0
        for block in candidates.reversed() where total + block.utf8.count <= maxTotalBytes {
            selected.append(block)
            total += block.utf8.count
        }
        return selected.reversed().joined(separator: "\n\n")
    }

    private static func scopedSignature(workspace: URL, directories: [URL]) -> String {
        var parts = [workspace.path]
        for directory in directories {
            parts.append(directory.path)
            for name in scopedFileNames {
                parts.append(fileStamp(directory.appendingPathComponent(name), workspace: workspace))
            }
        }
        return parts.joined(separator: "\u{1}")
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
        let override = workspace.appendingPathComponent(overrideFileName)
        guard !fileManager.fileExists(atPath: agents.path),
              !fileManager.fileExists(atPath: claude.path),
              !fileManager.fileExists(atPath: override.path) else { return false }
        do {
            try Data(seed.utf8).write(to: agents, options: .atomic)
            try Data(seed.utf8).write(to: claude, options: .atomic)
            invalidate(workspace: workspace)
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

        let root = workspace.standardizedFileURL.resolvingSymlinksInPath()
        var files: [String: Data] = [:]
        if let data = readData(agents, workspace: root) { files[agents.lastPathComponent] = data }
        if let data = readData(claude, workspace: root) { files[claude.lastPathComponent] = data }
        guard let (source, target) = syncPair(agents: agents, claude: claude, files: files),
              let data = files[source.lastPathComponent] else { return }
        if (try? data.write(to: target, options: .atomic)) != nil {
            invalidate(workspace: root)
        }
    }

    private static func syncPair(agents: URL, claude: URL, files: [String: Data]) -> (URL, URL)? {
        let a = files[agents.lastPathComponent]
        let c = files[claude.lastPathComponent]
        guard a != c else { return nil }
        switch (a, c) {
        case (.some, .none): return (agents, claude)
        case (.none, .some): return (claude, agents)
        case (.some, .some): return modified(agents) >= modified(claude) ? (agents, claude) : (claude, agents)
        case (.none, .none): return nil
        }
    }

    private static func signature(workspace: URL) -> String {
        var parts = [workspace.path]
        for name in fileNames + [overrideFileName] {
            parts.append(fileStamp(workspace.appendingPathComponent(name), workspace: workspace))
        }
        let rules = ruleFiles(workspace: workspace)
        parts.append("rules:" + rules.map { relativeLabel($0, workspace: workspace) }.joined(separator: "\u{0}"))
        for url in rules {
            parts.append(fileStamp(url, workspace: workspace))
        }
        return parts.joined(separator: "\u{1}")
    }

    private static func fileStamp(_ url: URL, workspace: URL) -> String {
        guard contains(workspace: workspace, url: url) else { return "\(url.path)|outside" }
        let resolved = url.resolvingSymlinksInPath()
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: resolved.path) else {
            return "\(url.path)|missing"
        }
        let size = (attributes[.size] as? NSNumber)?.stringValue ?? "?"
        let number = (attributes[.systemFileNumber] as? NSNumber)?.stringValue ?? "?"
        let volume = (attributes[.systemNumber] as? NSNumber)?.stringValue ?? "?"
        let modified = stampDate(attributes[.modificationDate] as? Date)
        let created = stampDate(attributes[.creationDate] as? Date)
        return [url.path, resolved.path, size, number, volume, modified, created].joined(separator: "|")
    }

    private static func stampDate(_ date: Date?) -> String {
        guard let date else { return "?" }
        return String(format: "%.9f", date.timeIntervalSince1970)
    }

    private static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    private static func ruleFiles(workspace: URL) -> [URL] {
        rulesDirectories.flatMap { relative -> [URL] in
            let directory = workspace.appendingPathComponent(relative, isDirectory: true)
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            ) else { return [] }
            return entries
                .filter { ["md", "mdc"].contains($0.pathExtension.lowercased()) }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
                .prefix(maxRuleFilesPerDirectory)
                .map { $0 }
        }
    }

    /// Largest prefix of `data`, at most `limit` bytes, that does not end inside a
    /// multi-byte character. Decoding a mid-character cut fails, which would drop
    /// the whole file instead of truncating it.
    private static func utf8Prefix(_ data: Data, limit: Int) -> Data {
        guard data.count > limit else { return data }
        var cut = limit
        while cut > 0, data[data.startIndex + cut] & 0xC0 == 0x80 { cut -= 1 }
        return data.prefix(cut)
    }

    private static func readData(_ url: URL, workspace: URL) -> Data? {
        // Same symlink rule the file tools use: a rules file that resolves
        // outside the workspace is not this project's rules file.
        guard contains(workspace: workspace, url: url) else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return data
    }

    private static func render(_ data: Data, label: String) -> String? {
        guard !data.isEmpty else { return nil }
        let limited = utf8Prefix(data, limit: maxBytesPerFile)
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

    private static func isInside(_ url: URL, root: URL) -> Bool {
        guard url.path != root.path else { return true }
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return url.path.hasPrefix(rootPath)
    }

    private static func relativeLabel(_ url: URL, workspace: URL) -> String {
        let root = workspace.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(root + "/") else { return url.lastPathComponent }
        return String(path.dropFirst(root.count + 1))
    }
}

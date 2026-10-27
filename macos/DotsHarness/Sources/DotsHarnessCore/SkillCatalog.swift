// Copyright (c) 2026 DOTS
// Workspace-scoped Markdown skills. Skill files are guidance, never executable code.

import Combine
import CryptoKit
import Foundation
import HarnessPluginKit
import PluginRuntime

public enum SkillSource: String, Codable, Sendable, CaseIterable {
    case workspace
    case app
    case bundled
}

public struct SkillDescriptor: Identifiable, Codable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let description: String
    public let source: SkillSource
    public let path: String
    public let githubURL: String?
    public let skillURL: String?
    public let downloadURL: String?
    public let enabled: Bool

    public var isInstalled: Bool { source == .app }

    public init(
        id: String,
        name: String,
        description: String,
        source: SkillSource,
        path: String,
        githubURL: String? = nil,
        skillURL: String? = nil,
        downloadURL: String? = nil,
        enabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.source = source
        self.path = path
        self.githubURL = githubURL
        self.skillURL = skillURL
        self.downloadURL = downloadURL
        self.enabled = enabled
    }
}

public struct SkillMarketplaceEntry: Identifiable, Codable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let description: String
    public let githubURL: String?
    public let skillURL: String?
    public let downloadURL: String?
    public let revision: String?
    public let sha256: String?
    public let snapshotDate: String
    /// Listing metadata; absent in older manifests.
    public var category: String?
    public var publisher: String?
    /// "official" or "verified".
    public var publisherBadge: String?
    public var downloads: Int?
    public var likes: Int?
    public var featured: Bool?

    public init(
        id: String,
        name: String,
        description: String,
        githubURL: String? = nil,
        skillURL: String? = nil,
        downloadURL: String? = nil,
        revision: String? = nil,
        sha256: String? = nil,
        snapshotDate: String
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.githubURL = githubURL
        self.skillURL = skillURL
        self.downloadURL = downloadURL
        self.revision = revision
        self.sha256 = sha256
        self.snapshotDate = snapshotDate
    }
}

public enum SkillCatalogError: Error, LocalizedError, Sendable {
    case unavailable(String)
    case invalid(String)
    case download(String)
    case notFound(String)
    case notRemovable(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let message), .invalid(let message), .download(let message),
             .notFound(let message), .notRemovable(let message):
            return message
        }
    }
}

@MainActor
public final class SkillCatalog: ObservableObject {
    private struct State: Codable {
        var disabled: [String] = []
        var known: [String: Known]?
    }

    private struct Known: Codable, Equatable {
        let path: String
        let name: String
        var identity: String?
    }

    private struct Candidate {
        /// Carries the id derived from the frontmatter or folder name; `refresh` pins the final one.
        let descriptor: SkillDescriptor
        /// The skill folder on disk (inode and creation date); survives a rename.
        let identity: String?
    }

    public static let maximumSkillBytes = 200_000
    private static let maximumSkillResourceBytes = 1_000_000
    private static let maximumSkillResources = 200
    private static let workspaceDirectoriesCheckedDirectly: Set<String> = [
        ".dotsherness", ".codex", ".agent", ".claude",
    ]
    private static let workspaceTraversalPrunedDirectories: Set<String> = [
        ".git", ".mem", ".build", ".swiftpm", ".gradle", ".venv",
        "node_modules", "build", "dist", "target", "Pods", "Carthage",
        "DerivedData", "coverage", "venv",
    ]

    @Published public private(set) var entries: [SkillDescriptor] = []
    @Published public private(set) var marketplaceEntries: [SkillMarketplaceEntry] = []

    public let paths: SupportPaths
    private let fileManager: FileManager
    private var workspaceURL: URL?
    private var workspaceSkillRootsCache: (workspacePath: String, roots: [URL])?
    private var disabled = Set<String>()
    /// Last seen location of every skill id. See `pinnedIDs`.
    private var known: [String: Known] = [:]

    public init(
        paths: SupportPaths,
        workspaceURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.paths = paths
        self.workspaceURL = workspaceURL
        self.fileManager = fileManager
        loadState()
        loadMarketplaceManifest()
        refresh()
    }

    public var appDirectory: URL {
        paths.root.appendingPathComponent("skills", isDirectory: true)
    }

    public func setWorkspace(_ path: String?) {
        let nextWorkspace = path.flatMap { URL(fileURLWithPath: $0, isDirectory: true) }
            .map { $0.standardizedFileURL.resolvingSymlinksInPath() }
        let workspaceChanged = nextWorkspace?.path != workspaceURL?.path
        if workspaceChanged {
            workspaceSkillRootsCache = nil
        }
        workspaceURL = nextWorkspace
        if let workspaceURL {
            // Per-workspace project folder, vault style: skills/plugins/notes for this workspace.
            try? FileManager.default.createDirectory(
                at: workspaceURL.appendingPathComponent(".dotsherness/skills", isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        guard workspaceChanged else { return }
        refreshCached()
    }

    public func refresh() {
        refresh(discoverWorkspaceRoots: true)
    }

    /// Refreshes catalog contents without walking the workspace tree again.
    /// Workspace root discovery is repeated by `refresh()` and when the workspace changes.
    func refreshCached() {
        refresh(discoverWorkspaceRoots: false)
    }

    private func refresh(discoverWorkspaceRoots: Bool) {
        var candidates: [Candidate] = []
        var seenRoots = Set<String>()

        if let workspaceURL {
            let preferred = workspaceURL.appendingPathComponent(".dotsherness/skills", isDirectory: true)
            appendRoot(preferred, source: .workspace, to: &candidates, seenRoots: &seenRoots)

            for name in [".codex", ".agent", ".claude"] {
                appendRoot(
                    workspaceURL.appendingPathComponent("\(name)/skills", isDirectory: true),
                    source: .workspace,
                    to: &candidates,
                    seenRoots: &seenRoots
                )
            }

            for root in workspaceSkillRoots(workspaceURL, refreshCache: discoverWorkspaceRoots) {
                appendRoot(root, source: .workspace, to: &candidates, seenRoots: &seenRoots)
            }
        }

        appendRoot(appDirectory, source: .app, to: &candidates, seenRoots: &seenRoots)
        if let bundled = Bundle.module.url(forResource: "skills", withExtension: nil) {
            appendRoot(bundled, source: .bundled, to: &candidates, seenRoots: &seenRoots)
        }

        let pins = pinnedIDs(for: candidates)
        // An id held by a renamed skill is not free for a newcomer that derives the same one.
        let reserved = Set(zip(candidates, pins).compactMap { $1 == $0.descriptor.id ? nil : $1 })
        var taken = reserved.union(known.keys).union(candidates.map(\.descriptor.id))
        var selected: [SkillDescriptor] = []
        var located: [String: Known] = [:]
        for (candidate, pin) in zip(candidates, pins) {
            let derived = candidate.descriptor
            var id = pin ?? derived.id
            if pin == nil, reserved.contains(id) {
                id = (2...).lazy.map { "\(derived.id)-\($0)" }.first { !taken.contains($0) } ?? id
                taken.insert(id)
            }
            guard located[id] == nil else { continue }
            located[id] = Known(path: derived.path, name: derived.name, identity: candidate.identity)
            selected.append(SkillDescriptor(
                id: id,
                name: derived.name,
                description: derived.description,
                source: derived.source,
                path: derived.path,
                enabled: !disabled.contains(id)
            ))
        }
        entries = selected

        // A deleted skill gives its id up; one that is merely out of sight (another
        // workspace, a shadowed duplicate) keeps it.
        // ponytail: an unmounted workspace volume counts as deleted, its renamed skills fall back to derived ids.
        let remembered = known
            .filter { located[$0.key] == nil && fileManager.fileExists(atPath: $0.value.path) }
            .merging(located) { $1 }
        if remembered != known {
            known = remembered
            saveState()
        }
    }

    /// A skill keeps the id it was first seen under. A conversation captures that id and
    /// earlier messages are never rewritten (the prompt cache prefix survives), so renaming
    /// the folder, the display name or the frontmatter id must not change it.
    private func pinnedIDs(for candidates: [Candidate]) -> [String?] {
        // Strongest evidence first: the same folder on disk, the same SKILL.md path, then a
        // display name under the same root (a rename that recreated the folder, e.g. via git).
        // An ambiguous match is not a rename.
        let evidence: [(Candidate, Known) -> Bool] = [
            { $0.identity != nil && $0.identity == $1.identity },
            { $0.descriptor.path == $1.path },
            { Self.skillRoot($0.descriptor.path) == Self.skillRoot($1.path) && $0.descriptor.name == $1.name },
        ]
        var pins = [String?](repeating: nil, count: candidates.count)
        var claimed = Set<String>()
        for matches in evidence {
            for (index, candidate) in candidates.enumerated() where pins[index] == nil {
                let hits = known.filter { !claimed.contains($0.key) && matches(candidate, $0.value) }
                guard hits.count == 1, let id = hits.keys.first else { continue }
                pins[index] = id
                claimed.insert(id)
            }
        }
        return pins
    }

    private static func skillRoot(_ skillFile: String) -> String {
        URL(fileURLWithPath: skillFile).deletingLastPathComponent().deletingLastPathComponent().path
    }

    public func descriptor(for id: String, includeDisabled: Bool = false) -> SkillDescriptor? {
        let normalized = Self.normalizeID(id)
        guard let entry = entries.first(where: { $0.id == normalized }) else { return nil }
        return includeDisabled || entry.enabled ? entry : nil
    }

    public func read(id: String, includeDisabled: Bool = false) throws -> String {
        guard let entry = descriptor(for: id, includeDisabled: includeDisabled) else {
            throw SkillCatalogError.notFound(id)
        }
        let url = URL(fileURLWithPath: entry.path)
        guard isInsideSkillRoot(url, source: entry.source), !isSymbolicLink(url) else {
            throw SkillCatalogError.invalid("Skill path is outside an allowed skill root.")
        }
        return try Self.readAndValidate(url: url)
    }

    public func resources(id: String) throws -> [String] {
        guard let entry = descriptor(for: id) else { throw SkillCatalogError.notFound(id) }
        let directory = URL(fileURLWithPath: entry.path).deletingLastPathComponent().standardizedFileURL
        guard isInsideSkillRoot(directory, source: entry.source) else {
            throw SkillCatalogError.invalid("Skill path is outside an allowed skill root.")
        }
        var result: [String] = []
        walk(directory, relative: "")
        return result.sorted()

        func walk(_ parent: URL, relative: String) {
            guard result.count < Self.maximumSkillResources,
                  let children = try? FileManager.default.contentsOfDirectory(
                    at: parent,
                    includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                    options: [.skipsHiddenFiles]
                  ) else { return }
            for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                guard result.count < Self.maximumSkillResources,
                      let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                      values.isSymbolicLink != true else { continue }
                let path = relative.isEmpty ? child.lastPathComponent : relative + "/" + child.lastPathComponent
                if values.isDirectory == true { walk(child, relative: path); continue }
                guard child.path != URL(fileURLWithPath: entry.path).standardizedFileURL.path,
                      let size = try? child.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                      size <= Self.maximumSkillResourceBytes else { continue }
                result.append(path)
            }
        }
    }

    public func readResource(id: String, path: String) throws -> String {
        guard let entry = descriptor(for: id) else { throw SkillCatalogError.notFound(id) }
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), path.utf8.count <= 500 else {
            throw SkillCatalogError.invalid("A safe skill-relative resource path is required.")
        }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.hasPrefix(".") }) else {
            throw SkillCatalogError.invalid("Skill resource path is not allowed.")
        }
        let directory = URL(fileURLWithPath: entry.path).deletingLastPathComponent().standardizedFileURL
        let file = parts.reduce(directory) { $0.appendingPathComponent(String($1)) }.standardizedFileURL
        guard isInsideSkillRoot(directory, source: entry.source),
              file.path.hasPrefix(directory.path + "/"),
              !hasSymbolicLinkBetween(file, and: directory),
              FileManager.default.fileExists(atPath: file.path) else {
            throw SkillCatalogError.invalid("Skill resource is unavailable.")
        }
        let data = try Data(contentsOf: file)
        guard data.count <= Self.maximumSkillResourceBytes else {
            throw SkillCatalogError.invalid("Skill resource is larger than the supported limit.")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw SkillCatalogError.invalid("Skill resource is not valid UTF-8.")
        }
        return text
    }

    public func setEnabled(_ id: String, _ enabled: Bool) {
        let normalized = Self.normalizeID(id)
        guard entries.contains(where: { $0.id == normalized }) else { return }
        if enabled { disabled.remove(normalized) } else { disabled.insert(normalized) }
        saveState()
        refreshCached()
    }

    public func remove(_ id: String) throws {
        guard let entry = descriptor(for: id, includeDisabled: true) else {
            throw SkillCatalogError.notFound(id)
        }
        guard entry.source == .app else {
            throw SkillCatalogError.notRemovable("Only app-owned downloaded skills can be removed.")
        }
        let url = URL(fileURLWithPath: entry.path).deletingLastPathComponent()
        guard isInsideSkillRoot(url, source: .app), !isSymbolicLink(url), url.path != appDirectory.path else {
            throw SkillCatalogError.invalid("Skill path is outside the app skill directory.")
        }
        try fileManager.removeItem(at: url)
        disabled.remove(entry.id)
        saveState()
        refreshCached()
    }

    public func isInstalled(_ entry: SkillMarketplaceEntry) -> Bool {
        entries.contains { $0.id == Self.normalizeID(entry.id) && $0.source == .app }
    }

    public func install(_ entry: SkillMarketplaceEntry) async throws {
        guard let rawURL = entry.downloadURL, let url = URL(string: rawURL), url.scheme?.lowercased() == "https" else {
            throw SkillCatalogError.download("This skill does not have a valid HTTPS SKILL.md download URL.")
        }
        guard let host = url.host, !host.isEmpty else {
            throw SkillCatalogError.download("This skill download URL has no host.")
        }

        let (data, response): (Data, URLResponse)
        do {
            var request = URLRequest(url: url, timeoutInterval: 30)
            request.setValue("DotsHarness", forHTTPHeaderField: "User-Agent")
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw SkillCatalogError.download(error.localizedDescription)
        }
        guard (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true else {
            throw SkillCatalogError.download("Skill download returned an unsuccessful HTTP response.")
        }
        guard data.count <= Self.maximumSkillBytes else {
            throw SkillCatalogError.invalid("SKILL.md is larger than the supported limit.")
        }
        // A skill's SKILL.md goes straight into the system prompt, so an
        // unverified download is a prompt injection channel. The marketplace
        // publishes a checksum for every skill: without one, refuse it.
        guard let expected = entry.sha256?.lowercased(), !expected.isEmpty else {
            throw SkillCatalogError.invalid("This skill has no published checksum and cannot be installed.")
        }
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard actual == expected else { throw SkillCatalogError.invalid("SKILL.md checksum did not match.") }

        guard let text = String(data: data, encoding: .utf8) else {
            throw SkillCatalogError.invalid("SKILL.md is not valid UTF-8.")
        }
        let parsed = try Self.parse(text: text, fallbackID: entry.id)
        let id = Self.normalizeID(parsed.id)
        guard id == Self.normalizeID(entry.id) else {
            throw SkillCatalogError.invalid("SKILL.md name does not match the marketplace skill ID.")
        }

        guard !isSymbolicLink(appDirectory) else {
            throw SkillCatalogError.invalid("The app skill directory is a symbolic link.")
        }
        let directory = appDirectory.appendingPathComponent(id, isDirectory: true)
        guard !isSymbolicLink(directory) else {
            throw SkillCatalogError.invalid("The app skill directory is a symbolic link.")
        }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent("SKILL.md.\(UUID().uuidString).part")
        try data.write(to: temporary, options: .atomic)
        let destination = directory.appendingPathComponent("SKILL.md")
        do {
            guard !isSymbolicLink(destination) else {
                throw SkillCatalogError.invalid("The destination SKILL.md is a symbolic link.")
            }
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try fileManager.moveItem(at: temporary, to: destination)
            }
        } catch {
            try? fileManager.removeItem(at: temporary)
            if let error = error as? SkillCatalogError { throw error }
            throw SkillCatalogError.download(error.localizedDescription)
        }
        disabled.remove(id)
        saveState()
        refreshCached()
    }

    @discardableResult
    public func create(name: String, description: String, body: String, preferredID: String? = nil) throws -> String {
        guard let workspaceURL else {
            throw SkillCatalogError.unavailable("The workspace folder is unavailable.")
        }
        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: workspaceURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw SkillCatalogError.unavailable("The workspace folder is unavailable.")
        }
        let id = Self.normalizeID((preferredID?.isEmpty == false ? preferredID! : name))
        guard !id.isEmpty else { throw SkillCatalogError.invalid("A valid skill id could not be derived from the name.") }
        guard descriptor(for: id, includeDisabled: true) == nil else {
            throw SkillCatalogError.invalid("A skill named '\(id)' already exists.")
        }

        let root = workspaceURL.appendingPathComponent(".dotsherness/skills", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        guard !isSymbolicLink(root) else {
            throw SkillCatalogError.invalid("The workspace skill directory is a symbolic link.")
        }
        let directory = root.appendingPathComponent(id, isDirectory: true)
        if fileManager.fileExists(atPath: directory.path) {
            if isSymbolicLink(directory) {
                throw SkillCatalogError.invalid("The skill directory is a symbolic link.")
            }
            throw SkillCatalogError.invalid("A directory named '\(id)' already exists.")
        }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let frontmatter = """
        ---
        id: "\(id)"
        name: "\(Self.escapeYAMLString(name))"
        description: "\(Self.escapeYAMLString(description))"
        ---

        \(body.trimmingCharacters(in: .whitespacesAndNewlines))

        """
        guard let bytes = frontmatter.data(using: .utf8) else {
            throw SkillCatalogError.invalid("SKILL.md is not valid UTF-8.")
        }
        guard bytes.count <= Self.maximumSkillBytes else {
            throw SkillCatalogError.invalid("SKILL.md is larger than the supported limit.")
        }

        let destination = directory.appendingPathComponent("SKILL.md")
        let temporary = directory.appendingPathComponent("SKILL.md.\(UUID().uuidString).part")
        try bytes.write(to: temporary, options: .atomic)
        do {
            try fileManager.moveItem(at: temporary, to: destination)
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }

        // Round-trip through the same parser every other read path uses, so a
        // malformed write can never silently produce an unreadable skill.
        _ = try Self.readAndValidate(url: destination)

        disabled.remove(id)
        refreshCached()
        return id
    }

    private static func escapeYAMLString(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: "")
    }

    public func compactPrompt() -> String {
        let lines = entries.filter(\.enabled).map { entry in
            let description = String(entry.description.prefix(240)).replacingOccurrences(of: "\n", with: " ")
            return "- \(entry.id): \(description)"
        }
        guard !lines.isEmpty else { return "" }
        return """
        Available workspace skills (metadata only; read a relevant SKILL.md with skill.read):
        \(lines.joined(separator: "\n"))
        """
    }

    public func explicitSelection(in text: String) -> (descriptor: SkillDescriptor, prompt: String)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.first == "/" else { return nil }
        let token = trimmed.dropFirst().split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        guard !token.isEmpty, let entry = descriptor(for: token) else { return nil }
        let prefix = "/\(token)"
        let rest = String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        return (entry, rest)
    }

    public static func normalizeID(_ raw: String) -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let slug = value.map { character -> Character in
            if character.isLetter || character.isNumber || character == "-" || character == "_" { return character }
            return "-"
        }
        return String(slug).split(separator: "-").joined(separator: "-")
    }

    private func appendRoot(
        _ root: URL,
        source: SkillSource,
        to candidates: inout [Candidate],
        seenRoots: inout Set<String>
    ) {
        guard !isSymbolicLink(root) else { return }
        let normalized = root.standardizedFileURL
        guard seenRoots.insert(normalized.path).inserted else { return }
        guard fileManager.fileExists(atPath: normalized.path) else { return }
        guard let children = try? fileManager.contentsOfDirectory(
            at: normalized,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard child.lastPathComponent != ".mem",
                  let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true,
                  values.isSymbolicLink != true else { continue }
            let skillFile = child.appendingPathComponent("SKILL.md")
            guard !isSymbolicLink(skillFile),
                  let data = try? Data(contentsOf: skillFile),
                  data.count <= Self.maximumSkillBytes,
                  let text = String(data: data, encoding: .utf8),
                  let parsed = try? Self.parse(text: text, fallbackID: child.lastPathComponent) else { continue }
            let id = Self.normalizeID(parsed.id)
            guard !id.isEmpty else { continue }
            let attributes = try? fileManager.attributesOfItem(atPath: child.path)
            let identity = (attributes?[.systemFileNumber] as? NSNumber).flatMap { inode in
                (attributes?[.creationDate] as? Date).map { "\(inode)-\($0.timeIntervalSince1970)" }
            }
            candidates.append(Candidate(
                descriptor: SkillDescriptor(
                    id: id,
                    name: parsed.name,
                    description: parsed.description,
                    source: source,
                    path: skillFile.path
                ),
                identity: identity
            ))
        }
    }

    private func workspaceSkillRoots(_ workspace: URL, refreshCache: Bool = false) -> [URL] {
        let workspacePath = workspace.standardizedFileURL.path
        if !refreshCache,
           let cached = workspaceSkillRootsCache,
           cached.workspacePath == workspacePath {
            return cached.roots
        }

        // Canonical hidden roots (.dotsherness, .codex, .agent and .claude) are
        // checked directly by refresh(). Skip their duplicate traversal and
        // large generated/dependency trees during nested-root discovery.
        guard let enumerator = fileManager.enumerator(
            at: workspace,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsPackageDescendants]
        ) else { return [] }
        var roots: [URL] = []
        var count = 0
        while let url = enumerator.nextObject() as? URL, count < 2_000 {
            count += 1
            if enumerator.level > 6 { enumerator.skipDescendants(); continue }
            if let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]), values.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            let name = url.lastPathComponent
            if Self.workspaceDirectoriesCheckedDirectly.contains(name)
                || Self.workspaceTraversalPrunedDirectories.contains(name) {
                enumerator.skipDescendants()
                continue
            }
            guard name == "skills",
                  let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true,
                  values.isSymbolicLink != true else { continue }
            roots.append(url)
        }
        let sortedRoots = roots.sorted { $0.path < $1.path }
        workspaceSkillRootsCache = (workspacePath, sortedRoots)
        return sortedRoots
    }

    private func isInsideSkillRoot(_ url: URL, source: SkillSource) -> Bool {
        let normalized = url.standardizedFileURL
        let roots: [URL]
        switch source {
        case .workspace:
            roots = workspaceURL.map {
                workspaceSkillRoots($0) + [
                    $0.appendingPathComponent(".dotsherness/skills"),
                    $0.appendingPathComponent(".codex/skills"),
                    $0.appendingPathComponent(".agent/skills"),
                    $0.appendingPathComponent(".claude/skills"),
                ]
            } ?? []
        case .app:
            roots = [appDirectory]
        case .bundled:
            roots = Bundle.module.url(forResource: "skills", withExtension: nil).map { [$0] } ?? []
        }
        return roots.contains { root in
            let normalizedRoot = root.standardizedFileURL
            let rootPath = normalizedRoot.path
            guard normalized.path == rootPath || normalized.path.hasPrefix(rootPath + "/") else { return false }
            return !hasSymbolicLinkBetween(normalized, and: normalizedRoot)
        }
    }

    private func hasSymbolicLinkBetween(_ url: URL, and root: URL) -> Bool {
        let rootPath = root.path
        var current = url
        while true {
            if let values = try? current.resourceValues(forKeys: [.isSymbolicLinkKey]), values.isSymbolicLink == true {
                return true
            }
            if current.path == rootPath { return false }
            let parent = current.deletingLastPathComponent()
            guard parent.path != current.path, parent.path == rootPath || parent.path.hasPrefix(rootPath + "/") else {
                return true
            }
            current = parent
        }
    }

    private func loadState() {
        guard let data = try? Data(contentsOf: paths.root.appendingPathComponent("skills-state.json")),
              let state = try? JSONDecoder().decode(State.self, from: data) else { return }
        disabled = Set(state.disabled.map(Self.normalizeID))
        known = state.known ?? [:]
    }

    private func saveState() {
        let state = State(disabled: disabled.sorted(), known: known)
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: paths.root.appendingPathComponent("skills-state.json"), options: .atomic)
    }

    /// Replaces the catalog with the server's copy and keeps it for offline launches.
    public func updateMarketplace(_ data: Data) {
        guard let entries = try? JSONDecoder().decode([SkillMarketplaceEntry].self, from: data) else { return }
        marketplaceEntries = entries
        try? data.write(to: paths.root.appendingPathComponent("skillsmp-popular-200.json"), options: .atomic)
    }

    /// Applies a count the server just returned, so the listing does not wait for the next fetch.
    public func setMetrics(id: String, downloads: Int? = nil, likes: Int? = nil) {
        guard let index = marketplaceEntries.firstIndex(where: { $0.id == id }) else { return }
        if let downloads { marketplaceEntries[index].downloads = downloads }
        if let likes { marketplaceEntries[index].likes = likes }
    }

    private func loadMarketplaceManifest() {
        let url = paths.root.appendingPathComponent("skillsmp-popular-200.json")
        let data = (try? Data(contentsOf: url))
            ?? Bundle.module.url(forResource: "skillsmp-popular-200", withExtension: "json").flatMap { try? Data(contentsOf: $0) }
        guard let data, let entries = try? JSONDecoder().decode([SkillMarketplaceEntry].self, from: data) else { return }
        marketplaceEntries = entries
    }

    private struct Parsed {
        let id: String
        let name: String
        let description: String
    }

    private static func parse(text: String, fallbackID: String) throws -> Parsed {
        let lines = text.components(separatedBy: .newlines)
        guard lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) == "---" else {
            throw SkillCatalogError.invalid("SKILL.md must begin with frontmatter.")
        }
        guard let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines) == "---" }) else {
            throw SkillCatalogError.invalid("SKILL.md frontmatter is not closed.")
        }
        var values: [String: String] = [:]
        for line in lines[1..<end] {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            var value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            if value.count >= 2, value.first == "\"", value.last == "\"" { value = String(value.dropFirst().dropLast()) }
            values[key] = value
        }
        let id = normalizeID(values["id"] ?? fallbackID)
        let name = values["name"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let description = values["description"] ?? ""
        guard !id.isEmpty, !name.isEmpty, !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SkillCatalogError.invalid("SKILL.md needs name and description frontmatter.")
        }
        return Parsed(id: id, name: name, description: description)
    }

    private static func readAndValidate(url: URL) throws -> String {
        if let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]), values.isSymbolicLink == true {
            throw SkillCatalogError.invalid("SKILL.md cannot be a symbolic link.")
        }
        let data = try Data(contentsOf: url)
        guard data.count <= maximumSkillBytes else { throw SkillCatalogError.invalid("SKILL.md is larger than the supported limit.") }
        guard let text = String(data: data, encoding: .utf8) else { throw SkillCatalogError.invalid("SKILL.md is not valid UTF-8.") }
        _ = try parse(text: text, fallbackID: url.deletingLastPathComponent().lastPathComponent)
        return text
    }

    private func isSymbolicLink(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]) else { return true }
        return values.isSymbolicLink == true
    }
}

@MainActor
public enum SkillTools {
    private static func stringParameter(_ name: String, description: String) -> JSONValue {
        .object(["type": .string("string"), "description": .string(description)])
    }

    public static let definitions: [AgentToolDefinition] = [
        AgentToolDefinition(
            name: "skill.list",
            description: "Search available skill metadata by query, with offset/limit paging (default 10, maximum 20). Read only the selected SKILL.md.",
            parameters: .object(["type": .string("object"), "properties": .object(["query": stringParameter("query", description: "Filter skill id/name/description."), "offset": .object(["type": .string("integer")]), "limit": .object(["type": .string("integer")])])])
        ),
        AgentToolDefinition(
            name: "skill.read",
            description: "Read one enabled skill's SKILL.md by canonical skill id. Follow relevant selected procedures within user authorization and higher-priority rules. Reading a skill does not authorize its scripts or external actions.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object(["id": stringParameter("id", description: "Canonical skill id.")]),
                "required": .array([.string("id")]),
            ])
        ),
        AgentToolDefinition(
            name: "skill.resources",
            description: "List text companion files inside one enabled skill folder. Use this when SKILL.md references files in references/, scripts/, or assets/. Files are never executed by this tool.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object(["id": stringParameter("id", description: "Canonical skill id.")]),
                "required": .array([.string("id")]),
            ])
        ),
        AgentToolDefinition(
            name: "skill.read_resource",
            description: "Read one UTF-8 companion file from an enabled skill folder by canonical skill id and skill-relative path. This only returns text; it never executes scripts.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": stringParameter("id", description: "Canonical skill id."),
                    "path": stringParameter("path", description: "Skill-relative path such as references/guide.md."),
                ]),
                "required": .array([.string("id"), .string("path")]),
            ])
        ),
        AgentToolDefinition(
            name: "skill.suggest",
            description: "Propose saving a reusable procedure as a workspace skill. Use only when the user asks to save a workflow as a skill, or after you finished a multi-step workflow (several tool steps, a non-obvious order or gotcha) that the user said they will need again. Never for a single command, a one-off task, routine work such as building, testing, committing or answering a question, or something a project rule or lesson already covers. At most once per conversation; if it returns that no card was shown, do not retry or rephrase. This only shows the user a card; nothing is written unless they accept it.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "name": stringParameter("name", description: "Short, human-readable skill name."),
                    "description": stringParameter("description", description: "One-sentence description of when this skill applies."),
                    "body": stringParameter("body", description: "Markdown body: the steps or approach for this skill, written below the frontmatter."),
                ]),
                "required": .array([.string("name"), .string("description"), .string("body")]),
            ])
        ),
    ]

    public static func isReadOnly(_ name: String) -> Bool {
        name == "skill.list" || name == "skill.read" || name == "skill.resources" || name == "skill.read_resource" || name == "skill.suggest"
    }

    public static func execute(_ call: AgentToolCall, catalog: SkillCatalog, suggestions: SkillSuggestionMonitor? = nil) -> String {
        guard let data = call.arguments.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return AppCopy.format("tool.invalidArguments", call.name)
        }
        switch call.name {
        case "skill.list":
            let query = (object["query"] as? String ?? "").lowercased()
            let matches = catalog.entries.filter { $0.enabled && (query.isEmpty || ($0.id + " " + $0.name + " " + $0.description).lowercased().contains(query)) }
            let offset = max(0, object["offset"] as? Int ?? 0)
            let limit = max(1, min(20, object["limit"] as? Int ?? 10))
            let page = matches.dropFirst(offset).prefix(limit).map { "\($0.id)\t\($0.name)\t\($0.description.prefix(200))\t\($0.source.rawValue)" }.joined(separator: "\n")
            return page + (offset + limit < matches.count ? "\n[More skills: offset=\(offset + limit)]" : "")
        case "skill.read":
            guard let id = object["id"] as? String, !id.isEmpty else { return "A skill id is required." }
            do { return try catalog.read(id: id) }
            catch { return error.localizedDescription }
        case "skill.resources":
            guard let id = object["id"] as? String, !id.isEmpty else { return "A skill id is required." }
            do { return try catalog.resources(id: id).joined(separator: "\n") }
            catch { return error.localizedDescription }
        case "skill.read_resource":
            guard let id = object["id"] as? String, !id.isEmpty,
                  let path = object["path"] as? String, !path.isEmpty else { return "A skill id and resource path are required." }
            do { return try catalog.readResource(id: id, path: path) }
            catch { return error.localizedDescription }
        case "skill.suggest":
            guard let suggestions else { return "Skill suggestions are not available in this context." }
            guard suggestions.enabled else { return "Skill suggestions are turned off by the user; do not propose skills." }
            guard let name = object["name"] as? String, !name.isEmpty else { return "A skill name is required." }
            guard let description = object["description"] as? String, !description.isEmpty else { return "A description is required." }
            guard let body = object["body"] as? String, !body.isEmpty else { return "A skill body is required." }
            guard suggestions.canSuggest else { return "No card shown: a skill was suggested recently or the user dismissed suggestions. Do not propose skills in this conversation." }
            let proposed = suggestions.proposeFromAgent(name: name, description: description, body: body)
            return proposed == nil
                ? "No card shown: this skill was already suggested before. Do not propose it again."
                : "Suggestion card shown to the user for '\(name)'. They must accept it before anything is created; do not assume it will be."
        default:
            return AppCopy.format("tool.unknown", call.name)
        }
    }
}

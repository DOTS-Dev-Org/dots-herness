// Copyright (c) 2026 DOTS
// Shared area, Chat project, and message-derived filesystem context contracts.

import CryptoKit
import Foundation
import HarnessPluginKit
import PluginRuntime

public enum AgentArea: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case chat
    case coding

    public var id: String { rawValue }

    public var systemImage: String {
        switch self {
        case .chat: return "bubble.left.and.bubble.right"
        case .coding: return "chevron.left.forwardslash.chevron.right"
        }
    }

    public var title: String {
        switch self {
        case .chat: return AppCopy.text("assistantMode.chat")
        case .coding: return AppCopy.text("assistantMode.coding")
        }
    }

    public var sessionFileName: String {
        switch self {
        case .chat: return "chat-sessions.json"
        case .coding: return "coding-sessions.json"
        }
    }

    public var promptGuidance: String {
        switch self {
        case .chat:
            return "Chat area is active. Prioritize the conversation, but fulfill explicit file, terminal, web, plugin, MCP, and coding requests. Inspect local files only through verified user-provided context roots; never infer a workspace or process cwd."
        case .coding:
            return "Coding area is active. Use the selected workspace, project rules, build/test workflow, and coding safety behavior for implementation requests."
        }
    }
}

public enum ChatContextRootKind: String, Codable, Sendable {
    case file
    case directory
}

public struct ChatContextRoot: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let path: String
    public let kind: ChatContextRootKind
    public var sourceMessageIDs: [String]
    public let createdAt: Date
    public var lastUsedAt: Date

    public init(
        path: String,
        kind: ChatContextRootKind,
        sourceMessageIDs: [String] = [],
        createdAt: Date = Date(),
        lastUsedAt: Date = Date()
    ) {
        self.path = path
        self.kind = kind
        self.sourceMessageIDs = sourceMessageIDs
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.id = Self.id(for: path)
    }

    public static func id(for path: String) -> String {
        let digest = SHA256.hash(data: Data(path.utf8))
        return "context-" + String(digest.map { String(format: "%02x", $0) }.joined().prefix(24))
    }
}

public struct ChatContextLedger: Codable, Equatable, Sendable {
    public var roots: [ChatContextRoot]
    public var projectNotes: [String]
    public var changeSummaries: [String]
    public private(set) var revision: Int
    public var updatedAt: Date

    public init(
        roots: [ChatContextRoot] = [],
        projectNotes: [String] = [],
        changeSummaries: [String] = [],
        revision: Int = 0,
        updatedAt: Date = Date()
    ) {
        self.roots = roots
        self.projectNotes = projectNotes
        self.changeSummaries = changeSummaries
        self.revision = revision
        self.updatedAt = updatedAt
    }

    @discardableResult
    public mutating func attach(
        roots incoming: [ChatContextRoot],
        to messageID: String
    ) -> [ChatContextRoot] {
        var attached: [ChatContextRoot] = []
        for root in incoming {
            if let index = roots.firstIndex(where: { $0.id == root.id }) {
                if !roots[index].sourceMessageIDs.contains(messageID) {
                    roots[index].sourceMessageIDs.append(messageID)
                }
                roots[index].lastUsedAt = Date()
                attached.append(roots[index])
            } else {
                var value = root
                if !value.sourceMessageIDs.contains(messageID) {
                    value.sourceMessageIDs.append(messageID)
                }
                value.lastUsedAt = Date()
                roots.append(value)
                attached.append(value)
            }
        }
        if !incoming.isEmpty {
            revision += 1
            updatedAt = Date()
        }
        return attached
    }

    public mutating func addProjectNote(_ note: String) {
        let value = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !projectNotes.contains(value) else { return }
        projectNotes.append(value)
        revision += 1
        updatedAt = Date()
    }

    public mutating func addChangeSummary(_ summary: String) {
        let value = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        changeSummaries.append(value)
        if changeSummaries.count > 100 {
            changeSummaries.removeFirst(changeSummaries.count - 100)
        }
        revision += 1
        updatedAt = Date()
    }
}

public struct ChatProject: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var description: String
    public var pinned: Bool
    public var section: String?
    public var archived: Bool
    public var sortOrder: Int
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        name: String = "New chat project",
        description: String = "",
        pinned: Bool = false,
        section: String? = nil,
        archived: Bool = false,
        sortOrder: Int = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.pinned = pinned
        self.section = section
        self.archived = archived
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// Chat context is stored outside user workspaces. A missing project gets a
/// conversation-local ledger, while a named Chat project shares one ledger.
public final class ChatContextStore: @unchecked Sendable {
    private let directory: URL
    private let fileManager: FileManager

    public init(paths: SupportPaths, fileManager: FileManager = .default) {
        self.directory = paths.root.appendingPathComponent("chat-context", isDirectory: true)
        self.fileManager = fileManager
    }

    public func load(scopeID: String) -> ChatContextLedger {
        guard let url = fileURL(scopeID: scopeID),
              let data = try? Data(contentsOf: url),
              let ledger = try? JSONDecoder().decode(ChatContextLedger.self, from: data) else {
            return ChatContextLedger()
        }
        return ledger
    }

    public func save(_ ledger: ChatContextLedger, scopeID: String) {
        guard let url = fileURL(scopeID: scopeID),
              let data = try? JSONEncoder().encode(ledger) else { return }
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    public func remove(scopeID: String) {
        guard let url = fileURL(scopeID: scopeID) else { return }
        try? fileManager.removeItem(at: url)
    }

    private func fileURL(scopeID: String) -> URL? {
        let safe = scopeID.unicodeScalars.map { scalar -> Character in
            scalar.value < 128 && (CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_")
                ? Character(String(scalar))
                : "_"
        }
        let name = String(safe)
        guard !name.isEmpty else { return nil }
        return directory.appendingPathComponent(name + ".json")
    }
}

public final class ChatProjectStore: @unchecked Sendable {
    private let fileURL: URL
    private let fileManager: FileManager

    public init(paths: SupportPaths, fileManager: FileManager = .default) {
        self.fileURL = paths.root.appendingPathComponent("chat-projects.json")
        self.fileManager = fileManager
    }

    public func load() -> [ChatProject] {
        guard let data = try? Data(contentsOf: fileURL),
              let projects = try? JSONDecoder().decode([ChatProject].self, from: data) else { return [] }
        return projects.sorted {
            if $0.pinned != $1.pinned { return $0.pinned }
            if $0.sortOrder != $1.sortOrder { return $0.sortOrder < $1.sortOrder }
            return $0.updatedAt > $1.updatedAt
        }
    }

    public func save(_ projects: [ChatProject]) {
        guard let data = try? JSONEncoder().encode(projects) else { return }
        try? fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}

public enum ChatPathParser {
    private static let pattern = #"(?:"([^"]+)"|'([^']+)'|`([^`]+)`|((?:[A-Za-z]:[\\/][^\s"'`]+)|(?:\\\\[^\s"'`]+)|(?:/(?:[^\s"'`]|\\ )+))|((?:(?:\./|\.\./)?[A-Za-z0-9_.-]+(?:[\\/][A-Za-z0-9_.-]+)+)|(?:(?:\./|\.\./)[A-Za-z0-9_.-]+)|(?:[A-Za-z0-9_.-]+\.[A-Za-z0-9_-]+)))"#

    /// Returns textual candidates even when the path belongs to another OS.
    /// Verification is deliberately separate so Windows/UNC parser tests can
    /// run on macOS and an unverified path is never granted tool access.
    public static func extractPaths(from text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var result: [String] = []
        for match in regex.matches(in: text, range: range) {
            for index in 1...5 where match.range(at: index).location != NSNotFound {
                let value = (text as NSString).substring(with: match.range(at: index))
                let trimmed = trimPunctuation(value)
                guard !trimmed.isEmpty, !result.contains(trimmed) else { continue }
                result.append(trimmed)
                break
            }
        }
        return result
    }

    public static func roots(
        from text: String,
        knownRoots: [ChatContextRoot] = [],
        sourceMessageID: String
    ) -> [ChatContextRoot] {
        var result: [ChatContextRoot] = []
        for candidate in extractPaths(from: text) {
            if isAbsolute(candidate), let root = verifiedRoot(for: candidate, sourceMessageID: sourceMessageID) {
                if !result.contains(where: { $0.id == root.id }) { result.append(root) }
                continue
            }
            guard !isAbsolute(candidate) else { continue }
            for known in knownRoots {
                let baseURL = known.kind == .directory
                    ? URL(fileURLWithPath: known.path, isDirectory: true)
                    : URL(fileURLWithPath: known.path).deletingLastPathComponent()
                let resolved = URL(fileURLWithPath: candidate, relativeTo: baseURL).standardizedFileURL.path
                if let root = verifiedRoot(for: resolved, sourceMessageID: sourceMessageID),
                   !result.contains(where: { $0.id == root.id }) {
                    result.append(root)
                }
            }
        }
        return result
    }

    public static func isAbsolute(_ path: String) -> Bool {
        path.hasPrefix("/")
            || path.hasPrefix("\\\\")
            || path.range(of: #"^[A-Za-z]:[\\/]"#, options: .regularExpression) != nil
    }

    private static func verifiedRoot(for candidate: String, sourceMessageID: String) -> ChatContextRoot? {
        let expanded = candidate.hasPrefix("~/")
            ? (NSHomeDirectory() as NSString).appendingPathComponent(String(candidate.dropFirst(2)))
            : candidate
        let url = URL(fileURLWithPath: expanded).standardizedFileURL
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return nil }
        return ChatContextRoot(
            path: url.resolvingSymlinksInPath().path,
            kind: isDirectory.boolValue ? .directory : .file,
            sourceMessageIDs: [sourceMessageID]
        )
    }

    private static func trimPunctuation(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?)]}"))
    }
}

public enum AgentCacheNamespace {
    public static func key(
        area: AgentArea,
        conversationID: String,
        chatProjectID: String?,
        codingProjectID: String?,
        model: String,
        planMode: Bool,
        contextRevision: Int,
        rootIDs: [String] = [],
        provider: String? = nil,
        api: String? = nil,
        accountID: String? = nil,
        toolFingerprint: String? = nil,
        contextSegment: String? = nil
    ) -> String {
        let identity = [
            area.rawValue,
            conversationID,
            chatProjectID ?? "none",
            codingProjectID ?? "none",
            model,
            planMode ? "plan" : "normal",
            String(contextRevision),
            rootIDs.sorted().joined(separator: ","),
            provider ?? "unknown-provider",
            api ?? "unknown-api",
            accountID ?? "unknown-account",
            toolFingerprint ?? "unknown-tools",
            contextSegment ?? "segment-0",
        ].joined(separator: "|")
        let digest = SHA256.hash(data: Data(identity.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "herness:area-v1:" + area.rawValue + ":" + digest
    }

    /// Tool arrays are part of the provider prompt prefix. The fingerprint is
    /// canonical so plugin discovery order cannot create a false cache miss.
    public static func toolFingerprint(_ tools: [AgentToolDefinition]) -> String {
        let canonical = tools.sorted { $0.name < $1.name }.map {
            $0.name + "\n" + $0.description + "\n" + canonicalJSON($0.parameters)
        }.joined(separator: "\n---\n")
        let digest = SHA256.hash(data: Data(canonical.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return String(digest.prefix(32))
    }

    private static func canonicalJSON(_ value: JSONValue) -> String {
        switch value {
        case .null: return "null"
        case .bool(let value): return value ? "true" : "false"
        case .number(let value): return String(value)
        case .string(let value):
            return "\"" + value
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"") + "\""
        case .array(let values): return "[" + values.map(canonicalJSON).joined(separator: ",") + "]"
        case .object(let values):
            return "{" + values.keys.sorted().map { key in
                let escaped = key
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                return "\"" + escaped + "\":" + canonicalJSON(values[key]!)
            }.joined(separator: ",") + "}"
        }
    }
}

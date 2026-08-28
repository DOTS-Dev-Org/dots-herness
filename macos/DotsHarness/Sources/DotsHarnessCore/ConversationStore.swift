// Copyright (c) 2026 DOTS
// Durable conversations owned by the native harness.

import Foundation
import UniformTypeIdentifiers
import PluginRuntime

public struct ChatAttachment: Identifiable, Hashable, Sendable, Codable {
    public enum Kind: String, Sendable, Codable {
        case image
        case audio
        case video
        case file
    }

    public let path: String
    public let kind: Kind
    public let mimeType: String

    public var id: String { path }
    public var name: String { URL(fileURLWithPath: path).lastPathComponent }
    public var url: URL { URL(fileURLWithPath: path) }

    public init?(url: URL) {
        var isDirectory = ObjCBool(false)
        guard url.isFileURL,
              FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else { return nil }
        let type = UTType(filenameExtension: url.pathExtension)
        path = url.standardizedFileURL.path
        if type?.conforms(to: .image) == true {
            kind = .image
        } else if type?.conforms(to: .audio) == true {
            kind = .audio
        } else if type?.conforms(to: .movie) == true {
            kind = .video
        } else {
            kind = .file
        }
        mimeType = type?.preferredMIMEType ?? "application/octet-stream"
    }

    public init(path: String, kind: Kind, mimeType: String) {
        self.path = path
        self.kind = kind
        self.mimeType = mimeType
    }
}

public struct ChangedFile: Identifiable, Hashable, Sendable, Codable, Equatable {
    public enum Operation: String, Hashable, Sendable, Codable {
        case added
        case modified
        case deleted
    }

    public let path: String
    public let operation: Operation

    public var id: String { "\(operation.rawValue):\(path)" }

    public init(path: String, operation: Operation) {
        self.path = path
        self.operation = operation
    }
}

public struct RewindResult: Sendable, Equatable {
    public let restoredPaths: [String]
    public let conflictPaths: [String]

    public init(restoredPaths: [String] = [], conflictPaths: [String] = []) {
        self.restoredPaths = restoredPaths
        self.conflictPaths = conflictPaths
    }
}

public enum ConversationMutationError: Error, LocalizedError, Sendable, Equatable {
    case busy
    case notReady
    case messageNotFound
    case notLatestUserMessage
    case snapshotUnavailable
    case conflict([String])
    case restoreFailed(String)
    case invalidMessage

    public var errorDescription: String? {
        switch self {
        case .busy:
            return AppCopy.text("conversation.historyBusy")
        case .notReady:
            return AppCopy.text("agent.configureEndpoint")
        case .messageNotFound:
            return AppCopy.text("conversation.messageNotFound")
        case .notLatestUserMessage:
            return AppCopy.text("conversation.editOnlyLatest")
        case .snapshotUnavailable:
            return AppCopy.text("conversation.historyUnavailable")
        case .conflict(let paths):
            return AppCopy.format("conversation.historyConflict", paths.joined(separator: ", "))
        case .restoreFailed(let path):
            return AppCopy.format("conversation.historyRestoreFailed", path)
        case .invalidMessage:
            return AppCopy.text("conversation.messageRequired")
        }
    }
}

public struct ChatMessage: Identifiable, Sendable, Equatable, Codable {
    public enum Kind: String, Sendable, Codable {
        case user
        case assistant
        case plan
        case tool
        case system
    }

    public var id: String
    public var kind: Kind
    public var text: String
    public var createdAt: Date
    public var streaming: Bool
    public var media: ChatMedia?
    public var attachments: [ChatAttachment]
    /// Transient error from the last attempt to apply this plan. The durable
    /// plan and its pending ID remain available for retry.
    public var planError: String?
    /// A stable user-turn identifier shared by its visible and hidden messages.
    /// It is optional so sessions written before rewind support remain readable.
    public var turnID: String?
    public var changedFiles: [ChangedFile]
    public var usedSkills: [String]
    public var usedTools: [String]

    public init(
        id: String = UUID().uuidString,
        kind: Kind,
        text: String,
        createdAt: Date = Date(),
        streaming: Bool = false,
        media: ChatMedia? = nil,
        attachments: [ChatAttachment] = [],
        planError: String? = nil,
        turnID: String? = nil,
        changedFiles: [ChangedFile] = [],
        usedSkills: [String] = [],
        usedTools: [String] = []
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.createdAt = createdAt
        self.streaming = streaming
        self.media = media
        self.attachments = attachments
        self.planError = planError
        self.turnID = turnID
        self.changedFiles = changedFiles
        self.usedSkills = usedSkills
        self.usedTools = usedTools
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, text, createdAt, streaming, media, attachments, turnID, changedFiles, usedSkills, usedTools
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        kind = try container.decodeIfPresent(Kind.self, forKey: .kind) ?? .system
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        streaming = try container.decodeIfPresent(Bool.self, forKey: .streaming) ?? false
        media = try container.decodeIfPresent(ChatMedia.self, forKey: .media)
        attachments = try container.decodeIfPresent([ChatAttachment].self, forKey: .attachments) ?? []
        planError = nil
        turnID = try container.decodeIfPresent(String.self, forKey: .turnID)
        changedFiles = try container.decodeIfPresent([ChangedFile].self, forKey: .changedFiles) ?? []
        usedSkills = try container.decodeIfPresent([String].self, forKey: .usedSkills) ?? []
        usedTools = try container.decodeIfPresent([String].self, forKey: .usedTools) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind, forKey: .kind)
        try container.encode(text, forKey: .text)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(streaming, forKey: .streaming)
        try container.encodeIfPresent(media, forKey: .media)
        try container.encode(attachments, forKey: .attachments)
        try container.encodeIfPresent(turnID, forKey: .turnID)
        try container.encode(changedFiles, forKey: .changedFiles)
        try container.encode(usedSkills, forKey: .usedSkills)
        try container.encode(usedTools, forKey: .usedTools)
    }
}

public enum PromptMode: String, Sendable, Equatable {
    case queue
    case steer
}

public enum PlanApproval {
    private static let phrases: Set<String> = [
        "onaylıyorum",
        "onayliyorum",
        "onayla",
        "planı uygula",
        "plani uygula",
        "planı onayla",
        "plani onayla",
        "uygula",
        "devam et",
        "approve",
        "approve plan",
        "apply plan",
        "proceed",
        "go ahead",
    ]

    public static func matches(_ text: String) -> Bool {
        let normalized = text
            .lowercased()
            .map { $0.isPunctuation ? Character(" ") : $0 }
        let value = String(normalized)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return phrases.contains(value)
    }
}

public struct PendingPrompt: Identifiable, Sendable, Equatable {
    public enum Placement: String, Sendable, Equatable {
        case queued
        case steering
    }

    public var id: String
    public var text: String
    public var mode: PromptMode
    public var placement: Placement
    public var planMode: Bool
    public var approvedPlanID: String?
    public var attachments: [ChatAttachment]

    public init(
        id: String = UUID().uuidString,
        text: String,
        mode: PromptMode,
        placement: Placement? = nil,
        planMode: Bool = false,
        approvedPlanID: String? = nil,
        attachments: [ChatAttachment] = []
    ) {
        self.id = id
        self.text = text
        self.mode = mode
        self.placement = placement ?? (mode == .steer ? .steering : .queued)
        self.planMode = planMode
        self.approvedPlanID = approvedPlanID
        self.attachments = attachments
    }
}

public enum ContinuationPauseReason: String, Sendable, Equatable, Codable {
    case providerLimit
    case userStopped
}

public struct ContinuationState: Sendable, Equatable, Codable {
    public var reason: ContinuationPauseReason
    public var provider: String
    public var model: String
    public var message: String

    public init(reason: ContinuationPauseReason, provider: String = "", model: String = "", message: String = "") {
        self.reason = reason
        self.provider = provider
        self.model = model
        self.message = message
    }
}

public struct Conversation: Identifiable, Sendable, Equatable, Codable {
    public var id: String
    public var title: String
    public var messages: [ChatMessage]
    /// Provider transcript used to resume a run. Skill bodies are available only
    /// in the active in-memory request and are redacted before persistence.
    public var modelContext: [AgentMessage]
    /// Compaction metadata applies to modelContext only; the visible transcript
    /// remains complete and is never replaced by this summary.
    public var contextSummary: String
    public var contextCompactionCount: Int
    public var lastContextInputTokens: Int
    public var contextWindow: Int
    public var continuation: ContinuationState?
    /// Prompts accepted by the composer but not yet folded into the durable transcript.
    /// These are deliberately excluded from persistence; a restarted native loop must
    /// never replay a prompt whose delivery outcome is unknown.
    public var pendingPrompts: [PendingPrompt]
    public var running: Bool
    /// Live-only timestamp; deliberately excluded from persisted sessions.
    public var runStartedAt: Date?
    public var pinned: Bool
    public var archived: Bool
    public var blank: Bool
    public var pendingPlanMessageID: String?
    public var cwd: String?
    public var agentPreset: String?

    public init(
        id: String = UUID().uuidString,
        title: String = "New chat",
        messages: [ChatMessage] = [],
        modelContext: [AgentMessage] = [],
        contextSummary: String = "",
        contextCompactionCount: Int = 0,
        lastContextInputTokens: Int = 0,
        contextWindow: Int = 0,
        continuation: ContinuationState? = nil,
        pendingPrompts: [PendingPrompt] = [],
        running: Bool = false,
        runStartedAt: Date? = nil,
        pinned: Bool = false,
        archived: Bool = false,
        blank: Bool = true,
        pendingPlanMessageID: String? = nil,
        cwd: String? = nil,
        agentPreset: String? = nil
    ) {
        self.id = id
        self.title = title
        self.messages = messages
        self.modelContext = modelContext
        self.contextSummary = contextSummary
        self.contextCompactionCount = contextCompactionCount
        self.lastContextInputTokens = lastContextInputTokens
        self.contextWindow = contextWindow
        self.continuation = continuation
        self.pendingPrompts = pendingPrompts
        self.running = running
        self.runStartedAt = runStartedAt
        self.pinned = pinned
        self.archived = archived
        self.blank = blank
        self.pendingPlanMessageID = pendingPlanMessageID
        self.cwd = cwd
        self.agentPreset = agentPreset
    }

    public var canContinue: Bool { !running && continuation != nil }

    private enum CodingKeys: String, CodingKey {
        case id, title, messages, modelContext, contextSummary, contextCompactionCount, lastContextInputTokens, contextWindow
        case continuation, running, pinned, archived, blank, pendingPlanMessageID, cwd, agentPreset
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? "New chat"
        messages = try container.decodeIfPresent([ChatMessage].self, forKey: .messages) ?? []
        modelContext = try container.decodeIfPresent([AgentMessage].self, forKey: .modelContext) ?? []
        contextSummary = try container.decodeIfPresent(String.self, forKey: .contextSummary) ?? ""
        contextCompactionCount = try container.decodeIfPresent(Int.self, forKey: .contextCompactionCount) ?? 0
        lastContextInputTokens = try container.decodeIfPresent(Int.self, forKey: .lastContextInputTokens) ?? 0
        contextWindow = try container.decodeIfPresent(Int.self, forKey: .contextWindow) ?? 0
        continuation = try container.decodeIfPresent(ContinuationState.self, forKey: .continuation)
        pendingPrompts = []
        running = try container.decodeIfPresent(Bool.self, forKey: .running) ?? false
        runStartedAt = nil
        pinned = try container.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        archived = try container.decodeIfPresent(Bool.self, forKey: .archived) ?? false
        blank = try container.decodeIfPresent(Bool.self, forKey: .blank) ?? true
        pendingPlanMessageID = try container.decodeIfPresent(String.self, forKey: .pendingPlanMessageID)
        cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
        agentPreset = try container.decodeIfPresent(String.self, forKey: .agentPreset)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(messages, forKey: .messages)
        try container.encode(modelContext, forKey: .modelContext)
        try container.encode(contextSummary, forKey: .contextSummary)
        try container.encode(contextCompactionCount, forKey: .contextCompactionCount)
        try container.encode(lastContextInputTokens, forKey: .lastContextInputTokens)
        try container.encode(contextWindow, forKey: .contextWindow)
        try container.encodeIfPresent(continuation, forKey: .continuation)
        try container.encode(running, forKey: .running)
        try container.encode(pinned, forKey: .pinned)
        try container.encode(archived, forKey: .archived)
        try container.encode(blank, forKey: .blank)
        try container.encodeIfPresent(pendingPlanMessageID, forKey: .pendingPlanMessageID)
        try container.encodeIfPresent(cwd, forKey: .cwd)
        try container.encodeIfPresent(agentPreset, forKey: .agentPreset)
    }
}

/// Small, transparent JSON store. A first install has no file and therefore no
/// imported or synthetic chats.
public final class ConversationStore: @unchecked Sendable {
    private let fileURL: URL
    private let fileManager: FileManager

    public init(paths: SupportPaths, fileManager: FileManager = .default) {
        self.fileURL = paths.root.appendingPathComponent("sessions.json")
        self.fileManager = fileManager
    }

    public func load(workspacePath: String?) -> [Conversation] {
        let workspacePath = Self.normalizedPath(workspacePath)
        guard let data = try? Data(contentsOf: fileURL),
              let all = try? JSONDecoder().decode([Conversation].self, from: data) else {
            return []
        }
        return all
            .filter { Self.normalizedPath($0.cwd) == workspacePath }
            .sorted { $0.id < $1.id }
    }

    public func save(_ conversations: [Conversation]) {
        var existing: [Conversation] = []
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([Conversation].self, from: data) {
            existing = decoded
        }

        let ids = Set(conversations.map(\.id))
        existing.removeAll { ids.contains($0.id) }
        let merged = existing + conversations
        guard let data = try? JSONEncoder().encode(merged) else { return }
        try? fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: fileURL, options: .atomic)
    }

    public func delete(_ conversationID: String) {
        guard let data = try? Data(contentsOf: fileURL),
              var all = try? JSONDecoder().decode([Conversation].self, from: data) else {
            return
        }
        all.removeAll { $0.id == conversationID }
        guard let data = try? JSONEncoder().encode(all) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    public static func normalizedPath(_ raw: String?) -> String? {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: raw).standardizedFileURL.path
    }
}

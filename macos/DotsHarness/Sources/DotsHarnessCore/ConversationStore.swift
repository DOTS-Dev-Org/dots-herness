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

public struct WorkspaceRunSummary: Hashable, Sendable, Codable, Equatable {
    public let runID: String
    public let turnID: String
    public let status: String
    public let trackingStatus: String
    public let cleanupStatus: String
    public let cleanupNote: String
    public let addedCount: Int
    public let modifiedCount: Int
    public let deletedCount: Int
    public let testStatus: String
    public let browser: BrowserRunSummary?

    public init(
        runID: String,
        turnID: String,
        status: String,
        trackingStatus: String,
        cleanupStatus: String,
        cleanupNote: String,
        addedCount: Int,
        modifiedCount: Int,
        deletedCount: Int,
        testStatus: String,
        browser: BrowserRunSummary? = nil
    ) {
        self.runID = runID
        self.turnID = turnID
        self.status = status
        self.trackingStatus = trackingStatus
        self.cleanupStatus = cleanupStatus
        self.cleanupNote = cleanupNote
        self.addedCount = addedCount
        self.modifiedCount = modifiedCount
        self.deletedCount = deletedCount
        self.testStatus = testStatus
        self.browser = browser
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
    public var thinking: String?
    public var createdAt: Date
    public var streaming: Bool
    /// All media emitted by this message. The legacy media accessor below
    /// keeps older callers and saved sessions source-compatible.
    public var mediaItems: [ChatMedia]
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
    public var summary: WorkspaceRunSummary?
    /// Filesystem context roots explicitly discovered in the user's message.
    /// The roots are references into the Chat project's durable ledger; the
    /// message never grants access to an unverified path by itself.
    public var contextRootIDs: [String]

    public init(
        id: String = UUID().uuidString,
        kind: Kind,
        text: String,
        thinking: String? = nil,
        createdAt: Date = Date(),
        streaming: Bool = false,
        media: ChatMedia? = nil,
        mediaItems: [ChatMedia] = [],
        attachments: [ChatAttachment] = [],
        planError: String? = nil,
        turnID: String? = nil,
        changedFiles: [ChangedFile] = [],
        usedSkills: [String] = [],
        usedTools: [String] = [],
        summary: WorkspaceRunSummary? = nil,
        contextRootIDs: [String] = []
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.thinking = thinking
        self.createdAt = createdAt
        self.streaming = streaming
        self.mediaItems = mediaItems.isEmpty ? media.map { [$0] } ?? [] : mediaItems
        self.attachments = attachments
        self.planError = planError
        self.turnID = turnID
        self.changedFiles = changedFiles
        self.usedSkills = usedSkills
        self.usedTools = usedTools
        self.summary = summary
        self.contextRootIDs = contextRootIDs
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, text, thinking, createdAt, streaming, media, mediaItems, attachments, turnID, changedFiles, usedSkills, usedTools, summary, contextRootIDs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        kind = try container.decodeIfPresent(Kind.self, forKey: .kind) ?? .system
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        thinking = try container.decodeIfPresent(String.self, forKey: .thinking)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        streaming = try container.decodeIfPresent(Bool.self, forKey: .streaming) ?? false
        let decodedItems = try container.decodeIfPresent([ChatMedia].self, forKey: .mediaItems) ?? []
        let legacyMedia = try container.decodeIfPresent(ChatMedia.self, forKey: .media)
        mediaItems = decodedItems.isEmpty ? legacyMedia.map { [$0] } ?? [] : decodedItems
        attachments = try container.decodeIfPresent([ChatAttachment].self, forKey: .attachments) ?? []
        planError = nil
        turnID = try container.decodeIfPresent(String.self, forKey: .turnID)
        changedFiles = try container.decodeIfPresent([ChangedFile].self, forKey: .changedFiles) ?? []
        usedSkills = try container.decodeIfPresent([String].self, forKey: .usedSkills) ?? []
        usedTools = try container.decodeIfPresent([String].self, forKey: .usedTools) ?? []
        summary = try container.decodeIfPresent(WorkspaceRunSummary.self, forKey: .summary)
        contextRootIDs = try container.decodeIfPresent([String].self, forKey: .contextRootIDs) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind, forKey: .kind)
        try container.encode(text, forKey: .text)
        try container.encodeIfPresent(thinking, forKey: .thinking)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(streaming, forKey: .streaming)
        try container.encode(mediaItems, forKey: .mediaItems)
        // Keep the old key for one-media sessions so older app builds can still
        // display a generated result. New readers prefer mediaItems.
        try container.encodeIfPresent(mediaItems.first, forKey: .media)
        try container.encode(attachments, forKey: .attachments)
        try container.encodeIfPresent(turnID, forKey: .turnID)
        try container.encode(changedFiles, forKey: .changedFiles)
        try container.encode(usedSkills, forKey: .usedSkills)
        try container.encode(usedTools, forKey: .usedTools)
        try container.encodeIfPresent(summary, forKey: .summary)
        try container.encode(contextRootIDs, forKey: .contextRootIDs)
    }

    /// Compatibility accessor for the pre-multi-media message model.
    public var media: ChatMedia? {
        get { mediaItems.first }
        set { mediaItems = newValue.map { [$0] } ?? [] }
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
    public var contextRootIDs: [String]

    public init(
        id: String = UUID().uuidString,
        text: String,
        mode: PromptMode,
        placement: Placement? = nil,
        planMode: Bool = false,
        approvedPlanID: String? = nil,
        attachments: [ChatAttachment] = [],
        contextRootIDs: [String] = []
    ) {
        self.id = id
        self.text = text
        self.mode = mode
        self.placement = placement ?? (mode == .steer ? .steering : .queued)
        self.planMode = planMode
        self.approvedPlanID = approvedPlanID
        self.attachments = attachments
        self.contextRootIDs = contextRootIDs
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
    /// When the provider said its limit resets. The run resumes itself then, so a
    /// pinned model waits out its quota instead of needing the user back at the app.
    public var retryAt: Date?

    public init(
        reason: ContinuationPauseReason,
        provider: String = "",
        model: String = "",
        message: String = "",
        retryAt: Date? = nil
    ) {
        self.reason = reason
        self.provider = provider
        self.model = model
        self.message = message
        self.retryAt = retryAt
    }

    enum CodingKeys: String, CodingKey { case reason, provider, model, message, retryAt }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        reason = try c.decode(ContinuationPauseReason.self, forKey: .reason)
        provider = try c.decodeIfPresent(String.self, forKey: .provider) ?? ""
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? ""
        message = try c.decodeIfPresent(String.self, forKey: .message) ?? ""
        retryAt = try c.decodeIfPresent(Date.self, forKey: .retryAt)
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
    /// A completed response the user has not opened yet.
    public var unread: Bool
    public var pendingPlanMessageID: String?
    public var cwd: String?
    public var agentPreset: String?
    /// Provider account id this conversation is pinned to, so follow-up turns hit
    /// the same account/API key and keep the provider's prompt cache warm.
    public var stickyAccountID: String?
    /// Concrete model id served on the last turn. When the resolved target model
    /// no longer matches this, the account affinity is dropped and re-selected.
    public var stickyModelID: String?
    /// Area ownership is persisted so Chat and Coding stores can be migrated
    /// without inferring ownership from the currently selected UI state.
    public var area: AgentArea
    /// Optional logical Chat project. Coding conversations leave this nil.
    public var chatProjectID: String?
    /// False for a sidebar header decoded without its transcript (see
    /// `ConversationStore.loadHeaders`). Headers are never written over full records.
    public var contentLoaded = true
    /// Newest message time for a header, read from the stored `lastActivityAt`.
    public var headerActivityAt: Date?

    /// Newest message time; drives sidebar ordering without decoding transcripts.
    public var activityDate: Date {
        guard contentLoaded else { return headerActivityAt ?? .distantPast }
        return messages.max { $0.createdAt < $1.createdAt }?.createdAt ?? .distantPast
    }

    /// Copies the fields a user can change from the sidebar (header) onto a full record.
    public mutating func applyMetadata(from header: Conversation) {
        title = header.title
        pinned = header.pinned
        archived = header.archived
        unread = header.unread
        chatProjectID = header.chatProjectID
        agentPreset = header.agentPreset
    }

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
        unread: Bool = false,
        pendingPlanMessageID: String? = nil,
        cwd: String? = nil,
        agentPreset: String? = nil,
        stickyAccountID: String? = nil,
        stickyModelID: String? = nil,
        area: AgentArea = .coding,
        chatProjectID: String? = nil
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
        self.unread = unread
        self.pendingPlanMessageID = pendingPlanMessageID
        self.cwd = cwd
        self.agentPreset = agentPreset
        self.stickyAccountID = stickyAccountID
        self.stickyModelID = stickyModelID
        self.area = area
        self.chatProjectID = chatProjectID
    }

    public var canContinue: Bool { !running && continuation != nil }

    private enum CodingKeys: String, CodingKey {
        case id, title, messages, modelContext, contextSummary, contextCompactionCount, lastContextInputTokens, contextWindow
        case continuation, running, pinned, archived, blank, unread, pendingPlanMessageID, cwd, agentPreset
        case stickyAccountID, stickyModelID, area, chatProjectID, lastActivityAt
    }

    private struct ActivityStamp: Decodable {
        let createdAt: Date?
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? "New chat"
        if decoder.userInfo[ConversationStore.headersOnlyKey] as? Bool == true {
            // Sidebar header: skip the transcript and provider context entirely.
            messages = []
            modelContext = []
            contentLoaded = false
            headerActivityAt = try container.decodeIfPresent(Date.self, forKey: .lastActivityAt)
                ?? (try container.decodeIfPresent([ActivityStamp].self, forKey: .messages))?
                    .compactMap(\.createdAt).max()
        } else {
            messages = try container.decodeIfPresent([ChatMessage].self, forKey: .messages) ?? []
            modelContext = try container.decodeIfPresent([AgentMessage].self, forKey: .modelContext) ?? []
        }
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
        unread = try container.decodeIfPresent(Bool.self, forKey: .unread) ?? false
        pendingPlanMessageID = try container.decodeIfPresent(String.self, forKey: .pendingPlanMessageID)
        cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
        agentPreset = try container.decodeIfPresent(String.self, forKey: .agentPreset)
        stickyAccountID = try container.decodeIfPresent(String.self, forKey: .stickyAccountID)
        stickyModelID = try container.decodeIfPresent(String.self, forKey: .stickyModelID)
        area = try container.decodeIfPresent(AgentArea.self, forKey: .area)
            ?? (cwd == nil || cwd?.isEmpty == true ? .chat : .coding)
        chatProjectID = try container.decodeIfPresent(String.self, forKey: .chatProjectID)
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
        try container.encode(unread, forKey: .unread)
        try container.encodeIfPresent(pendingPlanMessageID, forKey: .pendingPlanMessageID)
        try container.encodeIfPresent(cwd, forKey: .cwd)
        try container.encodeIfPresent(agentPreset, forKey: .agentPreset)
        try container.encodeIfPresent(stickyAccountID, forKey: .stickyAccountID)
        try container.encodeIfPresent(stickyModelID, forKey: .stickyModelID)
        try container.encode(area, forKey: .area)
        try container.encodeIfPresent(chatProjectID, forKey: .chatProjectID)
        try container.encodeIfPresent(messages.map(\.createdAt).max(), forKey: .lastActivityAt)
    }

}

/// Small, transparent JSON store. A first install has no file and therefore no
/// imported or synthetic chats.
public final class ConversationStore: @unchecked Sendable {
    private struct FileStamp: Equatable {
        let modified: Date?
        let size: Int?
    }

    private let fileURL: URL
    private let fileManager: FileManager
    /// When set, records stamped for another area are hidden: Chat and Coding
    /// keep separate lists even if a stray record landed in the wrong file.
    private let area: AgentArea?
    private let cacheLock = NSLock()
    private var cache: (stamp: FileStamp, conversations: [Conversation])?
    private var headerCache: (stamp: FileStamp, conversations: [Conversation])?
    static let headersOnlyKey = CodingUserInfoKey(rawValue: "dots.conversationHeadersOnly")!
    private var revisionValue = 0

    /// Bumped whenever the decoded file changes. Callers that derive expensive
    /// values from `loadAll()` memoise them against this.
    public var revision: Int {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return revisionValue
    }

    public init(
        paths: SupportPaths,
        fileManager: FileManager = .default,
        fileName: String = "sessions.json",
        area: AgentArea? = nil
    ) {
        self.fileURL = paths.root.appendingPathComponent(fileName)
        self.fileManager = fileManager
        self.area = area
    }

    public func load(workspacePath: String?) -> [Conversation] {
        let workspacePath = Self.normalizedPath(workspacePath)
        return loadAll().filter { Self.normalizedPath($0.cwd) == workspacePath }
    }

    /// Every stored chat, whatever workspace it belongs to. Used by the sidebar
    /// to surface chats whose project is no longer listed. The sidebar re-reads
    /// this on every redraw, so the decoded file is cached until it changes.
    public func loadAll() -> [Conversation] {
        let stamp = fileStamp()
        cacheLock.lock()
        if let cache, cache.stamp == stamp {
            let cached = cache.conversations
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        guard let data = try? Data(contentsOf: fileURL),
              let all = try? JSONDecoder().decode([Conversation].self, from: data) else {
            return []
        }
        let sorted = all.filter { area == nil || $0.area == area }.sorted { $0.id < $1.id }
        cacheLock.lock()
        cache = (stamp, sorted)
        revisionValue += 1
        cacheLock.unlock()
        return sorted
    }

    /// Titles and sidebar metadata only: transcripts are skipped, so listing every
    /// project's chats does not decode every project's messages. Returns the full
    /// records when they are already cached for the same file state.
    public func loadHeaders() -> [Conversation] {
        let stamp = fileStamp()
        cacheLock.lock()
        if let cache, cache.stamp == stamp {
            let cached = cache.conversations
            cacheLock.unlock()
            return cached
        }
        if let headerCache, headerCache.stamp == stamp {
            let cached = headerCache.conversations
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        let decoder = JSONDecoder()
        decoder.userInfo[Self.headersOnlyKey] = true
        guard let data = try? Data(contentsOf: fileURL),
              let all = try? decoder.decode([Conversation].self, from: data) else {
            return []
        }
        let sorted = all.filter { area == nil || $0.area == area }.sorted { $0.id < $1.id }
        cacheLock.lock()
        headerCache = (stamp, sorted)
        revisionValue += 1
        cacheLock.unlock()
        return sorted
    }

    public func loadHeaders(workspacePath: String?) -> [Conversation] {
        let workspacePath = Self.normalizedPath(workspacePath)
        return loadHeaders().filter { Self.normalizedPath($0.cwd) == workspacePath }
    }

    /// Bytes on disk; decides whether a staged (headers first) load is worth it.
    public var fileSize: Int { fileStamp().size ?? 0 }

    /// Modification date + size: cheap to read and enough to notice a rewrite.
    private func fileStamp() -> FileStamp {
        // FileManager, not URL.resourceValues: URL caches its values, which would
        // hide a rewrite made through another store instance.
        let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path)
        return FileStamp(
            modified: attributes?[.modificationDate] as? Date,
            size: attributes?[.size] as? Int
        )
    }

    public func save(_ conversations: [Conversation]) {
        var existing: [Conversation] = []
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([Conversation].self, from: data) {
            existing = decoded
        }

        // A header carries no transcript: keep the stored record, update its metadata.
        let stored = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let incoming = conversations.compactMap { conversation -> Conversation? in
            guard !conversation.contentLoaded else { return conversation }
            guard var full = stored[conversation.id] else { return nil }
            full.applyMetadata(from: conversation)
            return full
        }
        let ids = Set(incoming.map(\.id))
        existing.removeAll { ids.contains($0.id) }
        let merged = existing + incoming
        guard let data = try? JSONEncoder().encode(merged) else { return }
        try? fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: fileURL, options: .atomic)
        cacheLock.lock()
        cache = nil
        headerCache = nil
        revisionValue += 1
        cacheLock.unlock()
    }

    public func delete(_ conversationID: String) {
        guard let data = try? Data(contentsOf: fileURL),
              var all = try? JSONDecoder().decode([Conversation].self, from: data) else {
            return
        }
        all.removeAll { $0.id == conversationID }
        guard let data = try? JSONEncoder().encode(all) else { return }
        try? data.write(to: fileURL, options: .atomic)
        cacheLock.lock()
        cache = nil
        headerCache = nil
        revisionValue += 1
        cacheLock.unlock()
    }

    public static func normalizedPath(_ raw: String?) -> String? {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: raw).standardizedFileURL.path
    }
}

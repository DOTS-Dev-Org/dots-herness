// Copyright (c) 2026 DOTS
// Durable conversations owned by the native harness.

import Foundation
import CryptoKit
import UniformTypeIdentifiers
import PluginRuntime

public struct ChatAttachment: Identifiable, Hashable, Sendable, Codable {
    public enum Kind: String, Sendable, Codable {
        case image
        case audio
        case video
        case file
    }

    public enum SourceStatus: String, Sendable, Codable, Equatable {
        case current
        case changed
        case missing
        case unreadable
    }

    public struct SourceObservation: Sendable, Equatable {
        public let status: SourceStatus
        public let currentHash: String?

        public init(status: SourceStatus, currentHash: String? = nil) {
            self.status = status
            self.currentHash = currentHash
        }
    }

    /// Stable identity for the logical attachment across source-file revisions.
    /// It is optional only so path-only sessions written by older builds remain
    /// decodable; new attachments always receive a UUID.
    public let attachmentID: String?
    public let path: String
    public let kind: Kind
    public let mimeType: String
    /// Immutable provider payload for image attachments. `path` remains the
    /// user-visible source path; this is only used when constructing a request.
    public let snapshotPath: String?
    public let contentHash: String?
    public let revision: Int
    /// The hash most recently accepted into a provider request. Historical
    /// attachments keep this equal to `contentHash`; a changed source does not
    /// mutate the historical object.
    public let deliveredHash: String?

    public var id: String { attachmentID ?? path }
    public var name: String { URL(fileURLWithPath: path).lastPathComponent }
    public var url: URL { URL(fileURLWithPath: path) }
    public var providerURL: URL? {
        guard let snapshotPath else { return url }
        let snapshot = URL(fileURLWithPath: snapshotPath)
        return FileManager.default.fileExists(atPath: snapshot.path) ? snapshot : nil
    }

    public init?(url: URL) {
        var isDirectory = ObjCBool(false)
        guard url.isFileURL,
              FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else { return nil }
        let type = UTType(filenameExtension: url.pathExtension)
        attachmentID = UUID().uuidString
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
        snapshotPath = nil
        contentHash = nil
        revision = 0
        deliveredHash = nil
    }

    public init(
        path: String,
        kind: Kind,
        mimeType: String,
        snapshotPath: String? = nil,
        contentHash: String? = nil,
        attachmentID: String? = UUID().uuidString,
        revision: Int = 0,
        deliveredHash: String? = nil
    ) {
        self.attachmentID = attachmentID
        self.path = path
        self.kind = kind
        self.mimeType = mimeType
        self.snapshotPath = snapshotPath
        self.contentHash = contentHash
        self.revision = revision
        self.deliveredHash = deliveredHash
    }

    private enum CodingKeys: String, CodingKey {
        case attachmentID, path, kind, mimeType, snapshotPath, contentHash, revision, deliveredHash
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        attachmentID = try container.decodeIfPresent(String.self, forKey: .attachmentID)
        path = try container.decode(String.self, forKey: .path)
        kind = try container.decode(Kind.self, forKey: .kind)
        mimeType = try container.decode(String.self, forKey: .mimeType)
        snapshotPath = try container.decodeIfPresent(String.self, forKey: .snapshotPath)
        contentHash = try container.decodeIfPresent(String.self, forKey: .contentHash)
        revision = try container.decodeIfPresent(Int.self, forKey: .revision) ?? (contentHash == nil ? 0 : 1)
        deliveredHash = try container.decodeIfPresent(String.self, forKey: .deliveredHash) ?? contentHash
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(attachmentID, forKey: .attachmentID)
        try container.encode(path, forKey: .path)
        try container.encode(kind, forKey: .kind)
        try container.encode(mimeType, forKey: .mimeType)
        try container.encodeIfPresent(snapshotPath, forKey: .snapshotPath)
        try container.encodeIfPresent(contentHash, forKey: .contentHash)
        try container.encode(revision, forKey: .revision)
        try container.encodeIfPresent(deliveredHash, forKey: .deliveredHash)
    }

    /// Copies the bytes used by the provider into a content-addressed store.
    /// The source path is intentionally retained for display and recovery, but
    /// never re-read for an already snapshotted historical message.
    public func snapshot(
        in directory: URL,
        revision requestedRevision: Int? = nil,
        fileManager: FileManager = .default
    ) -> ChatAttachment {
        if let snapshotPath {
            // Older records may already have a snapshot but no logical ID.  Adding
            // the ID is metadata-only; the historical bytes remain untouched.
            guard attachmentID == nil else { return self }
            return ChatAttachment(
                path: path,
                kind: kind,
                mimeType: mimeType,
                snapshotPath: snapshotPath,
                contentHash: contentHash,
                attachmentID: UUID().uuidString,
                revision: max(revision, 1),
                deliveredHash: deliveredHash ?? contentHash
            )
        }
        let folder = directory.standardizedFileURL
        let temporary = folder.appendingPathComponent("." + UUID().uuidString + ".tmp")
        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            var result: (hash: String, bytes: Int64)?
            for _ in 0..<3 {
                let before = try Self.sourceSignature(url)
                let attempt = try Self.copyAndHash(source: url, temporary: temporary, fileManager: fileManager)
                let after = try Self.sourceSignature(url)
                if before == after {
                    result = attempt
                    break
                }
                try? fileManager.removeItem(at: temporary)
            }
            guard let result else { throw SourceError.changedDuringRead }
            let hash = result.hash
            let extensionName = url.pathExtension.isEmpty ? "bin" : url.pathExtension.lowercased()
            let destination = folder.appendingPathComponent(hash + "." + extensionName)
            if !fileManager.fileExists(atPath: destination.path) {
                try fileManager.moveItem(at: temporary, to: destination)
            } else {
                try? fileManager.removeItem(at: temporary)
            }
            return ChatAttachment(
                path: path,
                kind: kind,
                mimeType: mimeType,
                snapshotPath: destination.path,
                contentHash: hash,
                attachmentID: attachmentID ?? UUID().uuidString,
                revision: max(requestedRevision ?? max(revision, 1), 1),
                deliveredHash: deliveredHash
            )
        } catch {
            try? fileManager.removeItem(at: temporary)
            return self
        }
    }

    /// Creates a new immutable revision from the current source path without
    /// touching the snapshot referenced by a historical message.
    public func refreshedSnapshot(in directory: URL, fileManager: FileManager = .default) -> ChatAttachment {
        let source = ChatAttachment(
            path: path,
            kind: kind,
            mimeType: mimeType,
            attachmentID: attachmentID,
            revision: max(revision, 1) + 1
        )
        return source.snapshot(in: directory, revision: source.revision, fileManager: fileManager)
    }

    public func observeSource(fileManager: FileManager = .default) -> SourceObservation {
        let baseline = deliveredHash ?? contentHash
        // A path-only legacy record has no trustworthy historical bytes.  It is
        // deliberately silent until the first successful baseline snapshot; a
        // missing/unreadable legacy path must not be reported as a revision of
        // bytes we never captured.
        guard baseline != nil else {
            guard fileManager.fileExists(atPath: path) else { return SourceObservation(status: .current) }
            return (try? Self.hash(source: url)).map {
                SourceObservation(status: .current, currentHash: $0)
            } ?? SourceObservation(status: .current)
        }
        guard fileManager.fileExists(atPath: path) else {
            return SourceObservation(status: .missing)
        }
        do {
            let hash = try Self.hash(source: url)
            return SourceObservation(status: baseline == hash ? .current : .changed, currentHash: hash)
        } catch {
            return SourceObservation(status: .unreadable)
        }
    }

    private static func hash(source: URL) throws -> String {
        for _ in 0..<3 {
            let before = try sourceSignature(source)
            let handle = try FileHandle(forReadingFrom: source)
            var hasher = SHA256()
            defer { try? handle.close() }
            while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
            let hash = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            let after = try sourceSignature(source)
            if before == after { return hash }
        }
        throw SourceError.changedDuringRead
    }

    private static func copyAndHash(source: URL, temporary: URL, fileManager: FileManager) throws -> (hash: String, bytes: Int64) {
        guard fileManager.fileExists(atPath: source.path) else { throw CocoaError(.fileNoSuchFile) }
        fileManager.createFile(atPath: temporary.path, contents: nil)
        let input = try FileHandle(forReadingFrom: source)
        let output = try FileHandle(forWritingTo: temporary)
        var hasher = SHA256()
        var bytes: Int64 = 0
        defer {
            try? input.close()
            try? output.close()
        }
        while let chunk = try input.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
            try output.write(contentsOf: chunk)
            bytes += Int64(chunk.count)
        }
        try output.close()
        let hash = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return (hash, bytes)
    }

    private struct SourceSignature: Equatable {
        let size: Int64
        let modificationDate: Date?
    }

    private enum SourceError: Error {
        case changedDuringRead
    }

    private static func sourceSignature(_ source: URL) throws -> SourceSignature {
        let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? -1
        let modificationDate = attributes[.modificationDate] as? Date
        return SourceSignature(size: size, modificationDate: modificationDate)
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

    /// The sidebar form of this record: everything but the transcript and provider context,
    /// equal to what decoding it in headers-only mode would produce.
    func headerCopy() -> Conversation {
        var header = self
        header.headerActivityAt = activityDate
        header.messages = []
        header.modelContext = []
        header.pendingPrompts = []
        header.runStartedAt = nil
        header.contentLoaded = false
        return header
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
        let sorted = all.filter(belongsToConfiguredArea).sorted { $0.id < $1.id }
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
        let sorted = all.filter(belongsToConfiguredArea).sorted { $0.id < $1.id }
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

    /// One stored conversation as its own JSON object. The file is kept in this form so a
    /// save re-encodes only what changed instead of decoding and encoding every chat.
    private struct RawEntry {
        let id: String
        let data: Data
    }

    /// The file as it stood after our last write (or last read), valid while its stamp matches.
    private var rawCache: (stamp: FileStamp, entries: [RawEntry])?
    /// Last encoding of each conversation, reused while it compares equal.
    private var encodedCache: [String: (value: Conversation, data: Data)] = [:]
    private let writeLock = NSLock()

    private func encodedData(for conversation: Conversation) -> Data? {
        if let cached = encodedCache[conversation.id], cached.value == conversation { return cached.data }
        guard let data = try? JSONEncoder().encode(conversation) else { return nil }
        encodedCache[conversation.id] = (conversation, data)
        return data
    }

    /// The stored conversations as raw entries; from memory when the file is unchanged since
    /// we last saw it, otherwise decoded from disk (another process may have written).
    private func currentEntries(stamp: FileStamp) -> [RawEntry] {
        cacheLock.lock()
        let cached = rawCache
        cacheLock.unlock()
        if let cached, cached.stamp == stamp { return cached.entries }
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        guard let decoded = try? JSONDecoder().decode([Conversation].self, from: data) else {
            // The save that follows rewrites the file from what is known now: keep the
            // unreadable original instead of silently dropping it.
            if !data.isEmpty {
                try? data.write(to: fileURL.appendingPathExtension("corrupt"), options: .atomic)
            }
            return []
        }
        return decoded.filter(belongsToConfiguredArea).compactMap { conversation in
            encodedData(for: conversation).map { RawEntry(id: conversation.id, data: $0) }
        }
    }

    public func save(_ conversations: [Conversation]) {
        writeLock.lock()
        defer { writeLock.unlock() }

        let stampBefore = fileStamp()
        let existing = currentEntries(stamp: stampBefore)

        // A header carries no transcript: keep the stored record, update its metadata.
        var incoming: [(conversation: Conversation, data: Data)] = []
        for conversation in conversations where belongsToConfiguredArea(conversation) {
            if conversation.contentLoaded {
                guard let data = encodedData(for: conversation) else { return }
                incoming.append((conversation, data))
            } else {
                guard let entry = existing.first(where: { $0.id == conversation.id }),
                      var full = try? JSONDecoder().decode(Conversation.self, from: entry.data) else { continue }
                full.applyMetadata(from: conversation)
                guard let data = encodedData(for: full) else { return }
                incoming.append((full, data))
            }
        }
        let ids = Set(incoming.map { $0.conversation.id })
        let merged = existing.filter { !ids.contains($0.id) }
            + incoming.map { RawEntry(id: $0.conversation.id, data: $0.data) }

        var body = Data()
        body.reserveCapacity(merged.reduce(2) { $0 + $1.data.count + 1 })
        body.append(UInt8(ascii: "["))
        for (index, entry) in merged.enumerated() {
            if index > 0 { body.append(UInt8(ascii: ",")) }
            body.append(entry.data)
        }
        body.append(UInt8(ascii: "]"))

        try? fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard (try? body.write(to: fileURL, options: .atomic)) != nil else {
            cacheLock.lock()
            rawCache = nil
            cache = nil
            headerCache = nil
            revisionValue += 1
            cacheLock.unlock()
            return
        }

        let stampAfter = fileStamp()
        cacheLock.lock()
        rawCache = (stampAfter, merged)
        cache = nil
        // The header list follows the write instead of being decoded again on the next
        // sidebar redraw (which happens on every change while a run is in progress).
        if let headers = headerCache, headers.stamp == stampBefore {
            var byID = Dictionary(headers.conversations.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for (conversation, _) in incoming where belongsToConfiguredArea(conversation) {
                byID[conversation.id] = conversation.headerCopy()
            }
            headerCache = (stampAfter, byID.values.sorted { $0.id < $1.id })
        } else {
            headerCache = nil
        }
        revisionValue += 1
        cacheLock.unlock()
    }

    public func delete(_ conversationID: String) {
        writeLock.lock()
        defer { writeLock.unlock() }
        guard let data = try? Data(contentsOf: fileURL),
              var all = try? JSONDecoder().decode([Conversation].self, from: data) else {
            return
        }
        all = all.filter(belongsToConfiguredArea)
        all.removeAll { $0.id == conversationID }
        guard let data = try? JSONEncoder().encode(all) else { return }
        try? data.write(to: fileURL, options: .atomic)
        cacheLock.lock()
        rawCache = nil
        encodedCache[conversationID] = nil
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

    /// An area store is authoritative only for records that satisfy both parts
    /// of the persisted ownership contract. The cwd check repairs the older
    /// records that were written with the default `area = coding` while being
    /// projectless Chat conversations.
    private func belongsToConfiguredArea(_ conversation: Conversation) -> Bool {
        guard let area else { return true }
        guard conversation.area == area else { return false }
        let hasWorkspace = Self.normalizedPath(conversation.cwd) != nil
        return area == .chat ? !hasWorkspace : hasWorkspace
    }
}

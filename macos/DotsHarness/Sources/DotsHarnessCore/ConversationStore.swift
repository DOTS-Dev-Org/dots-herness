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
    /// Security-scoped locator for sandboxed file providers. Older records only
    /// have `path`; new records retain both the display path and this bookmark.
    public let bookmarkData: Data?
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
    /// Last observed source state. This is metadata only; it never changes the
    /// immutable bytes referenced by `snapshotPath`.
    public var sourceStatus: SourceStatus

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
        let scoped = url.startAccessingSecurityScopedResource()
        bookmarkData = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        if scoped { url.stopAccessingSecurityScopedResource() }
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
        sourceStatus = .current
    }

    public init(
        path: String,
        kind: Kind,
        mimeType: String,
        bookmarkData: Data? = nil,
        snapshotPath: String? = nil,
        contentHash: String? = nil,
        attachmentID: String? = UUID().uuidString,
        revision: Int = 0,
        deliveredHash: String? = nil,
        sourceStatus: SourceStatus = .current
    ) {
        self.attachmentID = attachmentID
        self.path = path
        self.bookmarkData = bookmarkData
        self.kind = kind
        self.mimeType = mimeType
        self.snapshotPath = snapshotPath
        self.contentHash = contentHash
        self.revision = revision
        self.deliveredHash = deliveredHash
        self.sourceStatus = sourceStatus
    }

    private enum CodingKeys: String, CodingKey {
        case attachmentID, path, bookmarkData, kind, mimeType, snapshotPath, contentHash, revision, deliveredHash, sourceStatus
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        attachmentID = try container.decodeIfPresent(String.self, forKey: .attachmentID)
        path = try container.decode(String.self, forKey: .path)
        bookmarkData = try container.decodeIfPresent(Data.self, forKey: .bookmarkData)
        kind = try container.decode(Kind.self, forKey: .kind)
        mimeType = try container.decode(String.self, forKey: .mimeType)
        snapshotPath = try container.decodeIfPresent(String.self, forKey: .snapshotPath)
        contentHash = try container.decodeIfPresent(String.self, forKey: .contentHash)
        revision = try container.decodeIfPresent(Int.self, forKey: .revision) ?? (contentHash == nil ? 0 : 1)
        deliveredHash = try container.decodeIfPresent(String.self, forKey: .deliveredHash) ?? contentHash
        sourceStatus = try container.decodeIfPresent(SourceStatus.self, forKey: .sourceStatus) ?? .current
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(attachmentID, forKey: .attachmentID)
        try container.encode(path, forKey: .path)
        try container.encodeIfPresent(bookmarkData, forKey: .bookmarkData)
        try container.encode(kind, forKey: .kind)
        try container.encode(mimeType, forKey: .mimeType)
        try container.encodeIfPresent(snapshotPath, forKey: .snapshotPath)
        try container.encodeIfPresent(contentHash, forKey: .contentHash)
        try container.encode(revision, forKey: .revision)
        try container.encodeIfPresent(deliveredHash, forKey: .deliveredHash)
        try container.encode(sourceStatus, forKey: .sourceStatus)
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
                bookmarkData: bookmarkData,
                snapshotPath: snapshotPath,
                contentHash: contentHash,
                attachmentID: UUID().uuidString,
                revision: max(revision, 1),
                deliveredHash: deliveredHash ?? contentHash,
                sourceStatus: sourceStatus
            )
        }
        let folder = directory.standardizedFileURL
        let temporary = folder.appendingPathComponent("." + UUID().uuidString + ".tmp")
        let source = resolvedSourceURL
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            var result: (hash: String, bytes: Int64)?
            for _ in 0..<3 {
                let before = try Self.sourceSignature(source)
                let attempt = try Self.copyAndHash(source: source, temporary: temporary, fileManager: fileManager)
                let after = try Self.sourceSignature(source)
                if before == after {
                    result = attempt
                    break
                }
                try? fileManager.removeItem(at: temporary)
            }
            guard let result else { throw SourceError.changedDuringRead }
            let hash = result.hash
            let extensionName = source.pathExtension.isEmpty ? "bin" : source.pathExtension.lowercased()
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
                bookmarkData: bookmarkData,
                snapshotPath: destination.path,
                contentHash: hash,
                attachmentID: attachmentID ?? UUID().uuidString,
                revision: max(requestedRevision ?? max(revision, 1), 1),
                deliveredHash: deliveredHash,
                sourceStatus: .current
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
            bookmarkData: bookmarkData,
            attachmentID: attachmentID,
            revision: max(revision, 1) + 1,
            sourceStatus: .current
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
            let source = resolvedSourceURL
            let scoped = source.startAccessingSecurityScopedResource()
            defer { if scoped { source.stopAccessingSecurityScopedResource() } }
            guard fileManager.fileExists(atPath: source.path) else { return SourceObservation(status: .current) }
            return (try? Self.hash(source: source)).map {
                SourceObservation(status: .current, currentHash: $0)
            } ?? SourceObservation(status: .current)
        }
        let source = resolvedSourceURL
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        guard fileManager.fileExists(atPath: source.path) else {
            return SourceObservation(status: .missing)
        }
        do {
            let hash = try Self.hash(source: source)
            return SourceObservation(status: baseline == hash ? .current : .changed, currentHash: hash)
        } catch {
            return SourceObservation(status: .unreadable)
        }
    }

    private static func hash(source: URL) throws -> String {
        for _ in 0..<3 {
            let before = try sourceSignature(source)
            let hash = try hashOnce(source: source)
            let after = try sourceSignature(source)
            if before == after { return hash }
        }
        throw SourceError.changedDuringRead
    }

    private var resolvedSourceURL: URL {
        guard let bookmarkData else { return url }
        var stale = false
        return (try? URL(
            resolvingBookmarkData: bookmarkData,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )) ?? url
    }

    private static func hashOnce(source: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: source)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
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
    public let addedLines: Int
    public let deletedLines: Int
    /// Bounded diff captured when this turn finished so history previews never reread the workspace.
    public let preview: String?

    public var id: String { "\(operation.rawValue):\(path)" }

    public init(path: String, operation: Operation, addedLines: Int = -1, deletedLines: Int = -1, preview: String? = nil) {
        self.path = path
        self.operation = operation
        self.addedLines = addedLines
        self.deletedLines = deletedLines
        self.preview = preview
    }

    private enum CodingKeys: String, CodingKey { case path, operation, addedLines, deletedLines, preview }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decode(String.self, forKey: .path)
        operation = try container.decode(Operation.self, forKey: .operation)
        addedLines = try container.decodeIfPresent(Int.self, forKey: .addedLines) ?? -1
        deletedLines = try container.decodeIfPresent(Int.self, forKey: .deletedLines) ?? -1
        preview = try container.decodeIfPresent(String.self, forKey: .preview)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(path, forKey: .path)
        try container.encode(operation, forKey: .operation)
        try container.encode(addedLines, forKey: .addedLines)
        try container.encode(deletedLines, forKey: .deletedLines)
        try container.encodeIfPresent(preview, forKey: .preview)
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
    public var undoAvailable: Bool?
    /// False when the turn ran something whose writes could not be traced to paths,
    /// so its changed files are the whole workspace diff. Nil on older records.
    public let attributionKnown: Bool?

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
        browser: BrowserRunSummary? = nil,
        undoAvailable: Bool? = nil,
        attributionKnown: Bool? = nil
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
        self.undoAvailable = undoAvailable
        self.attributionKnown = attributionKnown
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
    case forkUnavailable
    case forkSaveFailed
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
        case .forkUnavailable:
            return AppCopy.text("conversation.forkUnavailable")
        case .forkSaveFailed:
            return AppCopy.text("conversation.forkSaveFailed")
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
    /// Complete tool result kept for the visible transcript. `text` may be a
    /// short preview, while the provider receives a reversible reduced view.
    public var rawToolOutput: String?
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
    /// UI-only event metadata. Activity rows stay out of the provider transcript.
    public var activityCode: String?

    public init(
        id: String = UUID().uuidString,
        kind: Kind,
        text: String,
        rawToolOutput: String? = nil,
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
        activityCode: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.rawToolOutput = rawToolOutput
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
        self.activityCode = activityCode
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, text, rawToolOutput, thinking, createdAt, streaming, media, mediaItems, attachments, turnID, changedFiles, usedSkills, usedTools, summary, activityCode
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        kind = try container.decodeIfPresent(Kind.self, forKey: .kind) ?? .system
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        if kind == .assistant || kind == .plan {
            text = WorkspaceBacklogText.visibleText(text)
        }
        rawToolOutput = try container.decodeIfPresent(String.self, forKey: .rawToolOutput)
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
        activityCode = try container.decodeIfPresent(String.self, forKey: .activityCode)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind, forKey: .kind)
        let persistedText = kind == .assistant || kind == .plan
            ? WorkspaceBacklogText.visibleText(text)
            : text
        try container.encode(persistedText, forKey: .text)
        try container.encodeIfPresent(rawToolOutput, forKey: .rawToolOutput)
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
        try container.encodeIfPresent(activityCode, forKey: .activityCode)
    }

    /// Compatibility accessor for the pre-multi-media message model.
    public var media: ChatMedia? {
        get { mediaItems.first }
        set { mediaItems = newValue.map { [$0] } ?? [] }
    }
}

public enum PromptMode: String, Codable, Sendable, Equatable {
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

public struct PendingPrompt: Identifiable, Codable, Sendable, Equatable {
    public enum Placement: String, Codable, Sendable, Equatable {
        case queued
        case steering
        case waitingForPlan
    }

    public var id: String
    public var text: String
    public var mode: PromptMode
    public var placement: Placement
    public var planMode: Bool
    /// False while the classifier decides whether this accepted prompt owns the plan gate.
    /// Optional for backward-compatible decoding; nil means resolved.
    public var planIntentResolved: Bool?
    public var approvedPlanID: String?
    /// Set only by an explicit user action on this queue item. It permits one
    /// prompt to run while the plan gate remains active; it is never inferred
    /// from a normal queue or steer mode.
    public var bypassesPlanGate: Bool
    public var attachments: [ChatAttachment]
    /// Prompt-scoped subagent permission. Nil in older/system prompts means use
    /// the current preference when the prompt starts.
    public var subagentsOverride: Bool?
    /// Set on a prompt the app wrote itself (a finished background task): the transcript
    /// shows this line as a notice, while `text` is what the model reads.
    public var notice: String?

    public init(
        id: String = UUID().uuidString,
        text: String,
        mode: PromptMode,
        placement: Placement? = nil,
        planMode: Bool = false,
        planIntentResolved: Bool = true,
        approvedPlanID: String? = nil,
        bypassesPlanGate: Bool = false,
        attachments: [ChatAttachment] = [],
        subagentsOverride: Bool? = nil,
        notice: String? = nil
    ) {
        self.id = id
        self.text = text
        self.mode = mode
        self.placement = placement ?? (mode == .steer ? .steering : .queued)
        self.planMode = planMode
        self.planIntentResolved = planIntentResolved ? nil : false
        self.approvedPlanID = approvedPlanID
        self.bypassesPlanGate = bypassesPlanGate
        self.attachments = attachments
        self.subagentsOverride = subagentsOverride
        self.notice = notice
    }

    public var isPlanIntentResolved: Bool { planIntentResolved != false }
}

public enum ContinuationPauseReason: String, Sendable, Equatable, Codable {
    case providerLimit
    case toolStepLimit
    case userStopped
    /// The host stopped while a tool could still have had an external side effect.
    case applicationClosed
    /// The network dropped mid-run; it resumes by itself once the connection is back.
    case networkLost
}

/// A tool call journaled before it runs, so a crash mid-batch is recoverable.
public typealias InFlightToolCall = AgentToolCall

public struct ContinuationState: Sendable, Equatable, Codable {
    public var reason: ContinuationPauseReason
    public var provider: String
    public var model: String
    public var message: String
    /// When the provider said its limit resets. The run resumes itself then, so a
    /// pinned model waits out its quota instead of needing the user back at the app.
    public var retryAt: Date?
    /// Keeps a one-prompt override when the run pauses and resumes later.
    public var subagentsOverride: Bool?

    public init(
        reason: ContinuationPauseReason,
        provider: String = "",
        model: String = "",
        message: String = "",
        retryAt: Date? = nil,
        subagentsOverride: Bool? = nil
    ) {
        self.reason = reason
        self.provider = provider
        self.model = model
        self.message = message
        self.retryAt = retryAt
        self.subagentsOverride = subagentsOverride
    }

    enum CodingKeys: String, CodingKey { case reason, provider, model, message, retryAt, subagentsOverride }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        reason = try c.decode(ContinuationPauseReason.self, forKey: .reason)
        provider = try c.decodeIfPresent(String.self, forKey: .provider) ?? ""
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? ""
        message = try c.decodeIfPresent(String.self, forKey: .message) ?? ""
        retryAt = try c.decodeIfPresent(Date.self, forKey: .retryAt)
        subagentsOverride = try c.decodeIfPresent(Bool.self, forKey: .subagentsOverride)
    }
}

public struct ConversationTranscriptPage: Sendable {
    public let messages: [ChatMessage]
    public let startIndex: Int
    public let totalCount: Int

    public init(messages: [ChatMessage], startIndex: Int, totalCount: Int) {
        self.messages = messages
        self.startIndex = startIndex
        self.totalCount = totalCount
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
    /// Local estimate of the request `lastContextInputTokens` counted; 0 when
    /// that count is itself an estimate.
    public var lastContextEstimatedTokens: Int
    public var contextWindow: Int
    public var contextRouteIdentity: String
    public var cacheEpoch: AgentConversationCacheEpoch?
    public var continuation: ContinuationState?
    /// Accepted prompts that have not yet been sent to the provider. Persisting this
    /// queue lets a restarted plan release the messages only after it completes.
    public var pendingPrompts: [PendingPrompt]
    public var running: Bool
    /// Live-only timestamp; deliberately excluded from persisted sessions.
    public var runStartedAt: Date?
    public var pinned: Bool
    /// User-set sidebar priority: 0 none, 1 low, 2 medium, 3 high.
    public var priority: Int = 0
    public var archived: Bool
    /// When the conversation entered the archive. Nil for conversations archived
    /// before this metadata was introduced.
    public var archivedAt: Date?
    public var blank: Bool
    /// A completed response the user has not opened yet.
    public var unread: Bool
    /// The plan lifecycle owns this barrier from the first plan request until
    /// execution completes or the user explicitly cancels the plan.
    public var planGateActive: Bool
    public var pendingPlanMessageID: String?
    /// Durable journal written before a tool is invoked. It remains until the
    /// complete tool result is persisted, so a restart cannot blindly replay it.
    public var inFlightToolCalls: [InFlightToolCall]
    /// A restart with an in-flight tool requires reconciliation before any
    /// continuation; approved plans may continue automatically, but the
    /// journaled tool call is never replayed.
    public var requiresToolOutcomeRecovery: Bool
    public var cwd: String?
    /// True only for conversations explicitly created in the No project scope.
    /// Legacy Chat records without a cwd stay excluded unless they carry this flag.
    public var projectless: Bool
    public var agentPreset: String?
    /// Provider account id this conversation is pinned to, so follow-up turns hit
    /// the same account/API key and keep the provider's prompt cache warm.
    public var stickyAccountID: String?
    /// Concrete model id served on the last turn. When the resolved target model
    /// no longer matches this, the account affinity is dropped and re-selected.
    public var stickyModelID: String?
    /// Model explicitly selected for this conversation. Nil inherits the app default.
    public var modelPreferenceID: String?
    /// False for a sidebar header decoded without its transcript (see
    /// `ConversationStore.loadHeaders`). Headers are never written over full records.
    public var contentLoaded = true
    /// False while only a window of the visible transcript is resident. The
    /// provider modelContext remains fully loaded for the selected conversation.
    public var transcriptComplete = true
    /// Absolute index of the first visible message currently loaded from disk.
    public var messageStartIndex = 0
    /// IDs loaded from disk pages, used to merge edits back without decoding the
    /// rest of the transcript into memory.
    public var loadedTranscriptMessageIDs = Set<String>()
    /// Newest message time for a header, read from the stored `lastActivityAt`.
    public var headerActivityAt: Date?

    public var hasOlderTranscriptMessages: Bool {
        contentLoaded && !transcriptComplete && messageStartIndex > 0
    }

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
        header.transcriptComplete = false
        header.messageStartIndex = 0
        header.loadedTranscriptMessageIDs = []
        header.cacheEpoch = nil
        header.pendingPrompts = []
        header.runStartedAt = nil
        header.contentLoaded = false
        return header
    }

    /// Copies the fields a user can change from the sidebar (header) onto a full record.
    public mutating func applyMetadata(from header: Conversation) {
        title = header.title
        cwd = header.cwd
        projectless = header.projectless
        pinned = header.pinned
        priority = header.priority
        archived = header.archived
        archivedAt = header.archivedAt
        unread = header.unread
        agentPreset = header.agentPreset
        modelPreferenceID = header.modelPreferenceID
    }

    /// The stored default titles are English sentinels; show them in the app language.
    public var displayTitle: String {
        title == "New conversation" || title == "New chat" ? AppCopy.text("sidebar.newChat") : title
    }

    public init(
        id: String = UUID().uuidString,
        title: String = "New conversation",

        messages: [ChatMessage] = [],
        modelContext: [AgentMessage] = [],
        contextSummary: String = "",
        contextCompactionCount: Int = 0,
        lastContextInputTokens: Int = 0,
        lastContextEstimatedTokens: Int = 0,
        contextWindow: Int = 0,
        contextRouteIdentity: String = "",
        cacheEpoch: AgentConversationCacheEpoch? = nil,
        continuation: ContinuationState? = nil,
        pendingPrompts: [PendingPrompt] = [],
        running: Bool = false,
        runStartedAt: Date? = nil,
        pinned: Bool = false,
        archived: Bool = false,
        archivedAt: Date? = nil,
        blank: Bool = true,
        unread: Bool = false,
        planGateActive: Bool = false,
        pendingPlanMessageID: String? = nil,
        inFlightToolCalls: [InFlightToolCall] = [],
        requiresToolOutcomeRecovery: Bool = false,
        cwd: String? = nil,
        projectless: Bool = false,
        agentPreset: String? = nil,
        stickyAccountID: String? = nil,
        stickyModelID: String? = nil,
        modelPreferenceID: String? = nil
    ) {
        self.id = id
        self.title = title
        self.messages = messages
        self.modelContext = modelContext
        self.contextSummary = contextSummary
        self.contextCompactionCount = contextCompactionCount
        self.lastContextInputTokens = lastContextInputTokens
        self.lastContextEstimatedTokens = lastContextEstimatedTokens
        self.contextWindow = contextWindow
        self.contextRouteIdentity = contextRouteIdentity
        self.cacheEpoch = cacheEpoch
        self.continuation = continuation
        self.pendingPrompts = pendingPrompts
        self.running = running
        self.runStartedAt = runStartedAt
        self.pinned = pinned
        self.archived = archived
        self.archivedAt = archivedAt
        self.blank = blank
        self.unread = unread
        self.planGateActive = planGateActive || pendingPlanMessageID != nil
        self.pendingPlanMessageID = pendingPlanMessageID
        self.inFlightToolCalls = inFlightToolCalls
        self.requiresToolOutcomeRecovery = requiresToolOutcomeRecovery
        self.cwd = cwd
        self.projectless = projectless
        self.agentPreset = agentPreset
        self.stickyAccountID = stickyAccountID
        self.stickyModelID = stickyModelID
        self.modelPreferenceID = modelPreferenceID
    }

    public var canContinue: Bool { !running && continuation != nil && !turnFinished }

    /// The model already gave its final answer (no pending tool calls), so a
    /// stop or shutdown that landed after it left nothing to continue. A paused
    /// plan stays resumable even after a separate promoted request finishes.
    public var turnFinished: Bool {
        guard inFlightToolCalls.isEmpty, !planGateActive, pendingPlanMessageID == nil,
              let last = modelContext.last(where: { $0.role != .system }) else { return false }
        return last.role == .assistant && last.toolCalls.isEmpty
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, messages, modelContext, contextSummary, contextCompactionCount, lastContextInputTokens, lastContextEstimatedTokens, contextWindow, contextRouteIdentity
        case continuation, pendingPrompts, running, pinned, priority, archived, archivedAt, blank, unread, planGateActive, pendingPlanMessageID, cwd, projectless, agentPreset
        case inFlightToolCalls, requiresToolOutcomeRecovery, stickyAccountID, stickyModelID, modelPreferenceID, lastActivityAt, cacheEpoch
    }

    private struct ActivityStamp: Decodable {
        let createdAt: Date?
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? "New conversation"
        let headersOnly = decoder.userInfo[ConversationStore.headersOnlyKey] as? Bool == true
        if headersOnly {
            // Sidebar header: skip the transcript and provider context entirely.
            messages = []
            modelContext = []
            contentLoaded = false
            transcriptComplete = false
            headerActivityAt = try container.decodeIfPresent(Date.self, forKey: .lastActivityAt)
                ?? (try container.decodeIfPresent([ActivityStamp].self, forKey: .messages))?
                    .compactMap(\.createdAt).max()
        } else {
            messages = try container.decodeIfPresent([ChatMessage].self, forKey: .messages) ?? []
            modelContext = try container.decodeIfPresent([AgentMessage].self, forKey: .modelContext) ?? []
            contentLoaded = true
            transcriptComplete = true
            messageStartIndex = 0
            loadedTranscriptMessageIDs = []
            headerActivityAt = nil
        }
        contextSummary = try container.decodeIfPresent(String.self, forKey: .contextSummary) ?? ""
        contextCompactionCount = try container.decodeIfPresent(Int.self, forKey: .contextCompactionCount) ?? 0
        lastContextInputTokens = try container.decodeIfPresent(Int.self, forKey: .lastContextInputTokens) ?? 0
        lastContextEstimatedTokens = try container.decodeIfPresent(Int.self, forKey: .lastContextEstimatedTokens) ?? 0
        contextWindow = try container.decodeIfPresent(Int.self, forKey: .contextWindow) ?? 0
        contextRouteIdentity = try container.decodeIfPresent(String.self, forKey: .contextRouteIdentity) ?? ""
        cacheEpoch = decoder.userInfo[ConversationStore.headersOnlyKey] as? Bool == true
            ? nil : try container.decodeIfPresent(AgentConversationCacheEpoch.self, forKey: .cacheEpoch)
        continuation = try container.decodeIfPresent(ContinuationState.self, forKey: .continuation)
        pendingPrompts = decoder.userInfo[ConversationStore.headersOnlyKey] as? Bool == true
            ? []
            : try container.decodeIfPresent([PendingPrompt].self, forKey: .pendingPrompts) ?? []
        running = try container.decodeIfPresent(Bool.self, forKey: .running) ?? false
        runStartedAt = nil
        pinned = try container.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        priority = try container.decodeIfPresent(Int.self, forKey: .priority) ?? 0
        archived = try container.decodeIfPresent(Bool.self, forKey: .archived) ?? false
        archivedAt = try container.decodeIfPresent(Date.self, forKey: .archivedAt)
        blank = try container.decodeIfPresent(Bool.self, forKey: .blank) ?? true
        unread = try container.decodeIfPresent(Bool.self, forKey: .unread) ?? false
        planGateActive = try container.decodeIfPresent(Bool.self, forKey: .planGateActive) ?? false
        pendingPlanMessageID = try container.decodeIfPresent(String.self, forKey: .pendingPlanMessageID)
        planGateActive = planGateActive || pendingPlanMessageID != nil
        inFlightToolCalls = try container.decodeIfPresent([InFlightToolCall].self, forKey: .inFlightToolCalls) ?? []
        requiresToolOutcomeRecovery = try container.decodeIfPresent(Bool.self, forKey: .requiresToolOutcomeRecovery) ?? false
        cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
        projectless = try container.decodeIfPresent(Bool.self, forKey: .projectless) ?? false
        agentPreset = try container.decodeIfPresent(String.self, forKey: .agentPreset)
        stickyAccountID = try container.decodeIfPresent(String.self, forKey: .stickyAccountID)
        stickyModelID = try container.decodeIfPresent(String.self, forKey: .stickyModelID)
        modelPreferenceID = try container.decodeIfPresent(String.self, forKey: .modelPreferenceID)
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
        try container.encode(lastContextEstimatedTokens, forKey: .lastContextEstimatedTokens)
        try container.encode(contextWindow, forKey: .contextWindow)
        try container.encode(contextRouteIdentity, forKey: .contextRouteIdentity)
        try container.encodeIfPresent(cacheEpoch, forKey: .cacheEpoch)
        try container.encodeIfPresent(continuation, forKey: .continuation)
        try container.encode(pendingPrompts, forKey: .pendingPrompts)
        try container.encode(running, forKey: .running)
        try container.encode(pinned, forKey: .pinned)
        if priority != 0 { try container.encode(priority, forKey: .priority) }
        try container.encode(archived, forKey: .archived)
        try container.encodeIfPresent(archivedAt, forKey: .archivedAt)
        try container.encode(blank, forKey: .blank)
        try container.encode(unread, forKey: .unread)
        try container.encode(planGateActive, forKey: .planGateActive)
        try container.encodeIfPresent(pendingPlanMessageID, forKey: .pendingPlanMessageID)
        try container.encode(inFlightToolCalls, forKey: .inFlightToolCalls)
        try container.encode(requiresToolOutcomeRecovery, forKey: .requiresToolOutcomeRecovery)
        try container.encodeIfPresent(cwd, forKey: .cwd)
        try container.encode(projectless, forKey: .projectless)
        try container.encodeIfPresent(agentPreset, forKey: .agentPreset)
        try container.encodeIfPresent(stickyAccountID, forKey: .stickyAccountID)
        try container.encodeIfPresent(stickyModelID, forKey: .stickyModelID)
        try container.encodeIfPresent(modelPreferenceID, forKey: .modelPreferenceID)
        try container.encodeIfPresent(messages.map(\.createdAt).max(), forKey: .lastActivityAt)
    }

}

/// SQLite-backed conversation store. A first install creates an empty database;
/// an existing sessions.json archive is imported once and kept as a backup.
public final class ConversationStore: @unchecked Sendable {
    private struct JSONMemberSlice {
        let keyRange: Range<Int>
        let valueRange: Range<Int>
        let key: String
    }

    private let fileURL: URL
    private let fileManager: FileManager
    private var database: ConversationSQLiteDatabase?
    private var databaseReady = false
    private let cacheLock = NSLock()
    static let headersOnlyKey = CodingUserInfoKey(rawValue: "dots.conversationHeadersOnly")!
    private var revisionValue = 0
    private var headersCache: (revision: Int, headers: [Conversation])?

    /// Bumped whenever the stored database changes. Sidebar-derived lists use this
    /// to invalidate their small metadata-only cache.
    public var revision: Int {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return revisionValue
    }

    public init(
        paths: SupportPaths,
        fileManager: FileManager = .default,
        fileName: String = "sessions.json"
    ) {
        self.fileURL = paths.root.appendingPathComponent(fileName)
        self.fileManager = fileManager
        if let database = try? ConversationSQLiteDatabase(url: paths.root.appendingPathComponent("sessions.sqlite")) {
            self.database = database
            migrateLegacyJSONIfNeeded(database)
        }
    }

    private func migrateLegacyJSONIfNeeded(_ database: ConversationSQLiteDatabase) {
        if database.legacyImportCompleted {
            databaseReady = true
            return
        }
        guard fileManager.fileExists(atPath: fileURL.path) else {
            do {
                try database.markLegacyImportCompleted()
                databaseReady = true
            } catch {
                databaseReady = false
            }
            return
        }
        guard let snapshot = readEntries() else {
            preserveCorruptFile()
            do {
                try database.markLegacyImportCompleted()
                databaseReady = true
            } catch {
                databaseReady = false
            }
            return
        }
        do {
            try database.importLegacy(records: snapshot.entries.map(\.data)) { [self] data in
                decodeConversation(from: data)
            }
            databaseReady = true
        } catch {
            databaseReady = false
        }
    }

    public func load(workspacePath: String?) -> [Conversation] {
        let workspacePath = Self.normalizedPath(workspacePath)
        guard databaseReady, let database else { return [] }
        return database.headers(workspacePath: workspacePath).compactMap { database.load(id: $0.id, allMessages: true) }
    }

    /// Explicit full-history read. Normal app startup and sidebar access should
    /// use `loadHeaders()` or `load(id:)` so inactive transcripts stay on disk.
    public func loadAll() -> [Conversation] {
        guard databaseReady else { return [] }
        return database?.loadAll() ?? []
    }

    /// Reads only unresolved queue prompts for plan-intent recovery. Transcript
    /// messages and provider context are skipped by the projection decoder.
    public func forEachPendingPlanIntent(ids: [String], _ visit: (String, String, String) -> Void) {
        guard databaseReady else { return }
        database?.forEachPendingPlanIntent(ids: ids, visit)
    }

    /// Reads only timestamps and file-change summaries for workspace activity.
    /// Message text and raw tool results are skipped by the projection decoder.
    public func forEachRecentChangedFiles(
        ids: [String],
        since cutoff: Date,
        _ visit: (String, String, [ChangedFile]) -> Void
    ) {
        guard databaseReady else { return }
        database?.forEachRecentChangedFiles(ids: ids, since: cutoff, visit)
    }

    /// Titles and sidebar metadata only. The cache contains headers, never message
    /// bodies, tool output, or provider context.
    public func loadHeaders() -> [Conversation] {
        guard databaseReady else { return [] }
        // The sidebar asks on every redraw; decoding every row's state_json each time
        // was a main-thread hot spot. Only save/delete change rows, and both bump revision.
        let revision = self.revision
        cacheLock.lock()
        if let cached = headersCache, cached.revision == revision {
            cacheLock.unlock()
            return cached.headers
        }
        cacheLock.unlock()
        let headers = database?.headers() ?? []
        cacheLock.lock()
        headersCache = (revision, headers)
        cacheLock.unlock()
        return headers
    }

    /// Loads one transcript from disk. No transcript cache is kept after return.
    public func load(id: String) -> Conversation? {
        guard databaseReady else { return nil }
        return database?.load(id: id, allMessages: true)
    }

    /// Loads the provider context and only the newest visible transcript page.
    /// Message bodies outside that page are never decoded into model objects.
    func loadRecentConversation(
        id: String,
        limit: Int = 10,
        includeModelContext: Bool = true
    ) -> Conversation? {
        guard databaseReady, limit > 0 else { return nil }
        return database?.load(id: id, limit: limit, includeModelContext: includeModelContext)
    }

    /// Reads a complete transcript for explicit summaries without loading the
    /// provider context or retaining the result in the store.
    func loadTranscript(id: String) -> [ChatMessage]? {
        guard databaseReady else { return nil }
        return database?.transcript(id: id)
    }

    /// Reads one older message page. The offset is an exclusive index into the
    /// stored transcript, so newly appended messages do not shift older pages.
    func loadMessagePage(
        id: String,
        endingBefore offset: Int,
        limit: Int = 10
    ) -> ConversationTranscriptPage? {
        guard databaseReady else { return nil }
        return database?.messagePage(id: id, endingBefore: offset, limit: limit)
    }

    /// Loads only the requested records from SQLite without retaining unrelated
    /// projects or message bodies in the store's cache.
    public func load(ids: [String]) -> [Conversation] {
        guard databaseReady else { return [] }
        return database?.load(ids: ids) ?? []
    }

    public func loadHeaders(workspacePath: String?) -> [Conversation] {
        guard databaseReady else { return [] }
        return database?.loadHeaders(workspacePath: workspacePath) ?? []
    }

    /// Bytes on disk, for storage diagnostics and UI thresholds.
    public var fileSize: Int { databaseReady ? (database?.fileSize ?? 0) : 0 }

    /// A view of one raw JSON object. Slices share the mapped source data for the
    /// duration of a read or write; they are never kept between store operations.
    private struct RawEntry {
        let id: String
        let data: Data
        let header: Conversation
    }

    private struct EntrySnapshot {
        let entries: [RawEntry]
        let filteredOutAny: Bool
    }

    private struct PlanIntentPrompt: Decodable {
        let id: String
        let text: String
        let planIntentResolved: Bool?
    }

    private struct PlanIntentRecord: Decodable {
        let id: String
        let pendingPrompts: [PlanIntentPrompt]?
    }

    private struct ActivityMessage: Decodable {
        let createdAt: Date?
        let changedFiles: [ChangedFile]?
    }

    private struct ActivityRecord: Decodable {
        let id: String
        let title: String
        let messages: [ActivityMessage]?
    }

    private struct MessageIdentity: Decodable {
        let id: String
    }

    private let writeLock = NSLock()

    private func decodeHeader(from data: Data) -> Conversation? {
        let decoder = JSONDecoder()
        decoder.userInfo[Self.headersOnlyKey] = true
        return try? decoder.decode(Conversation.self, from: data)
    }

    private func decodeConversation(
        from data: Data,
        skippingMessages: Bool = false,
        skippingModelContext: Bool = false
    ) -> Conversation? {
        let decoder = JSONDecoder()
        guard skippingMessages || skippingModelContext else {
            return try? decoder.decode(Conversation.self, from: data)
        }

        // Decode small record metadata separately from the two potentially large
        // arrays. JSONDecoder can otherwise parse skipped values while building
        // its container, briefly materializing the whole visible transcript.
        guard let members = Self.topLevelObjectMembers(in: data) else { return nil }
        let excluded: Set<String> = ["messages", "modelContext"]
        var metadata = Data()
        metadata.append(UInt8(ascii: "{"))
        var memberCount = 0
        for member in members where !excluded.contains(member.key) {
            if memberCount > 0 { metadata.append(UInt8(ascii: ",")) }
            metadata.append(Data(data[member.keyRange]))
            metadata.append(UInt8(ascii: ":"))
            metadata.append(Data(data[member.valueRange]))
            memberCount += 1
        }
        metadata.append(UInt8(ascii: "}"))

        guard var conversation = try? decoder.decode(Conversation.self, from: metadata) else { return nil }
        if !skippingMessages,
           let member = members.first(where: { $0.key == "messages" }) {
            guard let messages = try? decoder.decode([ChatMessage].self, from: Data(data[member.valueRange])) else {
                return nil
            }
            conversation.messages = messages
        }
        if !skippingModelContext,
           let member = members.first(where: { $0.key == "modelContext" }) {
            guard let context = try? decoder.decode([AgentMessage].self, from: Data(data[member.valueRange])) else {
                return nil
            }
            conversation.modelContext = context
        }
        return conversation
    }

    private func messageElements(in record: Data) -> (Data, [Range<Int>])? {
        guard let members = Self.topLevelObjectMembers(in: record),
              let member = members.first(where: { $0.key == "messages" }) else { return nil }
        let array = Data(record[member.valueRange])
        guard let ranges = Self.topLevelObjectRanges(in: array) else { return nil }
        return (array, ranges)
    }

    private func decodeMessage(in data: Data, at range: Range<Int>) -> ChatMessage? {
        try? JSONDecoder().decode(ChatMessage.self, from: Data(data[range]))
    }

    private func decodeMessages(
        in data: Data,
        ranges: [Range<Int>],
        range: Range<Int>
    ) -> [ChatMessage] {
        let lower = min(max(0, range.lowerBound), ranges.count)
        let upper = min(max(lower, range.upperBound), ranges.count)
        var messages: [ChatMessage] = []
        messages.reserveCapacity(upper - lower)
        for index in lower..<upper {
            if let message = decodeMessage(in: data, at: ranges[index]) {
                messages.append(message)
            }
        }
        return messages
    }

    private static func topLevelObjectMembers(in data: Data) -> [JSONMemberSlice]? {
        let baseIndex = data.startIndex
        let rawMembers = data.withUnsafeBytes { rawBuffer -> [(Range<Int>, Range<Int>)]? in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            guard !bytes.isEmpty else { return nil }

            func skipWhitespace(_ index: inout Int) {
                while index < bytes.count {
                    switch bytes[index] {
                    case 0x20, 0x09, 0x0A, 0x0D: index += 1
                    default: return
                    }
                }
            }

            func stringEnd(from start: Int) -> Int? {
                guard start < bytes.count, bytes[start] == 0x22 else { return nil }
                var index = start + 1
                var escaped = false
                while index < bytes.count {
                    let byte = bytes[index]
                    if escaped {
                        escaped = false
                    } else if byte == 0x5C {
                        escaped = true
                    } else if byte == 0x22 {
                        return index + 1
                    }
                    index += 1
                }
                return nil
            }

            func valueEnd(from start: Int) -> Int? {
                guard start < bytes.count else { return nil }
                if bytes[start] == 0x22 { return stringEnd(from: start) }
                if bytes[start] == 0x7B || bytes[start] == 0x5B {
                    var closers: [UInt8] = [bytes[start] == 0x7B ? 0x7D : 0x5D]
                    var index = start + 1
                    var inString = false
                    var escaped = false
                    while index < bytes.count {
                        let byte = bytes[index]
                        if inString {
                            if escaped {
                                escaped = false
                            } else if byte == 0x5C {
                                escaped = true
                            } else if byte == 0x22 {
                                inString = false
                            }
                        } else {
                            switch byte {
                            case 0x22: inString = true
                            case 0x7B: closers.append(0x7D)
                            case 0x5B: closers.append(0x5D)
                            case 0x7D, 0x5D:
                                guard closers.last == byte else { return nil }
                                closers.removeLast()
                                if closers.isEmpty { return index + 1 }
                            default: break
                            }
                        }
                        index += 1
                    }
                    return nil
                }
                var index = start
                while index < bytes.count {
                    switch bytes[index] {
                    case 0x2C, 0x5D, 0x7D, 0x20, 0x09, 0x0A, 0x0D: return index > start ? index : nil
                    default: index += 1
                    }
                }
                return index > start ? index : nil
            }

            var index = 0
            skipWhitespace(&index)
            guard index < bytes.count, bytes[index] == 0x7B else { return nil }
            index += 1
            var result: [(Range<Int>, Range<Int>)] = []
            while true {
                skipWhitespace(&index)
                guard index < bytes.count else { return nil }
                if bytes[index] == 0x7D {
                    index += 1
                    skipWhitespace(&index)
                    return index == bytes.count ? result : nil
                }
                let keyStart = index
                guard let keyEnd = stringEnd(from: keyStart) else { return nil }
                index = keyEnd
                skipWhitespace(&index)
                guard index < bytes.count, bytes[index] == 0x3A else { return nil }
                index += 1
                skipWhitespace(&index)
                let valueStart = index
                guard let end = valueEnd(from: valueStart) else { return nil }
                result.append((keyStart..<keyEnd, valueStart..<end))
                index = end
                skipWhitespace(&index)
                guard index < bytes.count else { return nil }
                if bytes[index] == 0x2C {
                    index += 1
                    continue
                }
                if bytes[index] == 0x7D { continue }
                return nil
            }
        }
        guard let rawMembers else { return nil }
        let decoder = JSONDecoder()
        return rawMembers.compactMap { relativeKeyRange, relativeValueRange in
            let keyRange = (baseIndex + relativeKeyRange.lowerBound)..<(baseIndex + relativeKeyRange.upperBound)
            let valueRange = (baseIndex + relativeValueRange.lowerBound)..<(baseIndex + relativeValueRange.upperBound)
            guard let key = try? decoder.decode(String.self, from: Data(data[keyRange])) else { return nil }
            return JSONMemberSlice(keyRange: keyRange, valueRange: valueRange, key: key)
        }
    }

    private static func hasSameMetadata(_ lhs: Conversation, as rhs: Conversation) -> Bool {
        lhs.title == rhs.title
            && lhs.cwd == rhs.cwd
            && lhs.projectless == rhs.projectless
            && lhs.pinned == rhs.pinned
            && lhs.priority == rhs.priority
            && lhs.archived == rhs.archived
            && lhs.archivedAt == rhs.archivedAt
            && lhs.unread == rhs.unread
            && lhs.agentPreset == rhs.agentPreset
            && lhs.modelPreferenceID == rhs.modelPreferenceID
    }

    /// Scans the top-level JSON array without materializing its message objects.
    /// Only a small header is decoded for each record; full decode happens for a
    /// selected ID or an explicit full-history operation.
    private func readEntries() -> EntrySnapshot? {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return EntrySnapshot(entries: [], filteredOutAny: false)
        }
        guard let data = try? Data(contentsOf: fileURL, options: [.mappedIfSafe]),
              let ranges = Self.topLevelObjectRanges(in: data) else { return nil }

        var entries: [RawEntry] = []
        var filteredOutAny = false
        entries.reserveCapacity(ranges.count)
        for range in ranges {
            let objectData = data[range]
            guard let header = decodeHeader(from: objectData) else { return nil }
            guard isSupportedConversation(header) else {
                filteredOutAny = true
                continue
            }
            entries.append(RawEntry(id: header.id, data: objectData, header: header))
        }
        return EntrySnapshot(entries: entries, filteredOutAny: filteredOutAny)
    }

    private static func topLevelObjectRanges(in data: Data) -> [Range<Int>]? {
        let baseIndex = data.startIndex
        return data.withUnsafeBytes { rawBuffer -> [Range<Int>]? in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            guard !bytes.isEmpty else { return nil }

            func skipWhitespace(_ index: inout Int) {
                while index < bytes.count {
                    switch bytes[index] {
                    case 0x20, 0x09, 0x0A, 0x0D: index += 1
                    default: return
                    }
                }
            }

            var index = 0
            skipWhitespace(&index)
            guard index < bytes.count, bytes[index] == 0x5B else { return nil } // [
            index += 1
            var ranges: [Range<Int>] = []
            var afterComma = false

            while true {
                skipWhitespace(&index)
                guard index < bytes.count else { return nil }
                if bytes[index] == 0x5D { // ]
                    guard !afterComma else { return nil }
                    index += 1
                    skipWhitespace(&index)
                    return index == bytes.count ? ranges : nil
                }
                guard bytes[index] == 0x7B else { return nil } // {
                let start = index
                var depth = 0
                var inString = false
                var escaped = false
                var closed = false

                while index < bytes.count {
                    let byte = bytes[index]
                    if inString {
                        if escaped {
                            escaped = false
                        } else if byte == 0x5C {
                            escaped = true
                        } else if byte == 0x22 {
                            inString = false
                        }
                    } else {
                        switch byte {
                        case 0x22: inString = true
                        case 0x7B: depth += 1
                        case 0x7D:
                            depth -= 1
                            if depth == 0 {
                                index += 1
                                ranges.append((baseIndex + start)..<(baseIndex + index))
                                afterComma = false
                                closed = true
                            }
                        default: break
                        }
                    }
                    if closed { break }
                    index += 1
                }
                guard closed else { return nil }
                skipWhitespace(&index)
                guard index < bytes.count else { return nil }
                if bytes[index] == 0x2C { // ,
                    afterComma = true
                    index += 1
                    continue
                }
                if bytes[index] == 0x5D { continue } // handled at loop top
                return nil
            }
        }
    }

    /// Encodes only the resident transcript window and splices it into the raw
    /// stored record, preserving message JSON outside the loaded pages.
    private func encodePagedConversation(_ conversation: Conversation, preserving existingData: Data) -> Data? {
        guard let existingMembers = Self.topLevelObjectMembers(in: existingData),
              let existingMessagesMember = existingMembers.first(where: { $0.key == "messages" }) else { return nil }
        let existingMessagesData = Data(existingData[existingMessagesMember.valueRange])
        guard let existingRanges = Self.topLevelObjectRanges(in: existingMessagesData) else { return nil }

        let encoder = JSONEncoder()
        var encodedCurrent: [String: Data] = [:]
        for message in conversation.messages {
            guard let data = try? encoder.encode(message) else { return nil }
            encodedCurrent[message.id] = data
        }

        var existingIDs = Set<String>()
        var mergedMessages = Data()
        mergedMessages.append(UInt8(ascii: "["))
        var emittedCount = 0
        func appendMessage(_ data: Data) {
            if emittedCount > 0 { mergedMessages.append(UInt8(ascii: ",")) }
            mergedMessages.append(data)
            emittedCount += 1
        }
        for range in existingRanges {
            let rawMessage = Data(existingMessagesData[range])
            guard let identity = try? JSONDecoder().decode(MessageIdentity.self, from: rawMessage) else { return nil }
            existingIDs.insert(identity.id)
            if conversation.loadedTranscriptMessageIDs.contains(identity.id) {
                if let updated = encodedCurrent[identity.id] {
                    appendMessage(updated)
                }
            } else {
                appendMessage(rawMessage)
            }
        }
        for message in conversation.messages where !existingIDs.contains(message.id) {
            guard let encoded = encodedCurrent[message.id] else { return nil }
            appendMessage(encoded)
        }
        mergedMessages.append(UInt8(ascii: "]"))

        guard let partialData = try? encoder.encode(conversation),
              let partialMembers = Self.topLevelObjectMembers(in: partialData),
              partialMembers.contains(where: { $0.key == "messages" }) else { return nil }
        var result = Data()
        result.append(UInt8(ascii: "{"))
        for (index, member) in partialMembers.enumerated() {
            if index > 0 { result.append(UInt8(ascii: ",")) }
            result.append(Data(partialData[member.keyRange]))
            result.append(UInt8(ascii: ":"))
            result.append(member.key == "messages"
                ? mergedMessages
                : Data(partialData[member.valueRange]))
        }
        result.append(UInt8(ascii: "}"))
        return result
    }

    /// Changes sidebar fields without decoding or re-encoding message history or
    /// provider context from the stored record.
    private func encodeMetadataUpdate(_ conversation: Conversation, preserving existingData: Data) -> Data? {
        let metadataKeys: Set<String> = [
            "title", "cwd", "projectless", "pinned", "priority", "archived",
            "archivedAt", "unread", "agentPreset", "modelPreferenceID",
        ]
        guard let existingMembers = Self.topLevelObjectMembers(in: existingData),
              let updateData = try? JSONEncoder().encode(conversation),
              let updateMembers = Self.topLevelObjectMembers(in: updateData) else { return nil }

        let updates = Dictionary(
            updateMembers.filter { metadataKeys.contains($0.key) }.map { ($0.key, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        let existingKeys = Set(existingMembers.map(\.key))
        var result = Data()
        result.append(UInt8(ascii: "{"))
        var memberCount = 0
        func appendMember(keyRange: Range<Int>, valueRange: Range<Int>, source: Data) {
            if memberCount > 0 { result.append(UInt8(ascii: ",")) }
            result.append(Data(source[keyRange]))
            result.append(UInt8(ascii: ":"))
            result.append(Data(source[valueRange]))
            memberCount += 1
        }
        for member in existingMembers {
            if metadataKeys.contains(member.key) {
                if let update = updates[member.key] {
                    appendMember(keyRange: update.keyRange, valueRange: update.valueRange, source: updateData)
                }
            } else {
                appendMember(keyRange: member.keyRange, valueRange: member.valueRange, source: existingData)
            }
        }
        for update in updateMembers where metadataKeys.contains(update.key) && !existingKeys.contains(update.key) {
            appendMember(keyRange: update.keyRange, valueRange: update.valueRange, source: updateData)
        }
        result.append(UInt8(ascii: "}"))
        return result
    }

    private func preserveCorruptFile() {
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else { return }
        try? data.write(to: fileURL.appendingPathExtension("corrupt"), options: .atomic)
    }

    private var saveTicket = 0
    private var lastSavedTicket = 0

    private func nextSaveTicket() -> Int {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        saveTicket += 1
        return saveTicket
    }

    /// For an edit that must not block the click that made it (picking a model),
    /// persist on a background queue. Save tickets prevent an older snapshot from
    /// reaching SQLite after a newer one.
    public func saveInBackground(_ conversations: [Conversation]) {
        let ticket = nextSaveTicket()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            _ = save(conversations, ticket: ticket)
        }
    }

    /// `previous`: what the caller last saved per conversation, valid at store
    /// `revision`; only what differs from it is written. Another write since
    /// that revision falls back to a full save.
    @discardableResult
    public func save(_ conversations: [Conversation], previous: [String: Conversation] = [:], revision: Int = -1) -> Bool {
        save(conversations, ticket: nextSaveTicket(), previous: previous, revision: revision)
    }

    private func save(_ conversations: [Conversation], ticket: Int, previous: [String: Conversation] = [:], revision: Int = -1) -> Bool {
        writeLock.lock()
        defer { writeLock.unlock() }
        guard ticket > lastSavedTicket else { return true }
        lastSavedTicket = ticket
        guard databaseReady, let database else { return false }
        let previous = revision == self.revision ? previous : [:]
        guard database.save(conversations.filter(isSupportedConversation), previous: previous) else { return false }
        cacheLock.lock()
        revisionValue += 1
        cacheLock.unlock()
        return true
    }

    public func delete(_ conversationID: String) {
        delete([conversationID])
    }

    /// Removes multiple conversations while invalidating the list cache once.
    public func delete(_ conversationIDs: [String]) {
        let uniqueIDs = Array(Set(conversationIDs))
        guard !uniqueIDs.isEmpty else { return }

        writeLock.lock()
        defer { writeLock.unlock() }
        guard databaseReady, let database, database.delete(uniqueIDs) > 0 else { return }
        cacheLock.lock()
        revisionValue += 1
        cacheLock.unlock()
    }

    public static func normalizedPath(_ raw: String?) -> String? {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: raw).standardizedFileURL.path
    }

    /// Keep project sessions and conversations explicitly created in No project
    /// mode. Legacy Chat records without a workspace are not silently re-imported.
    private func isSupportedConversation(_ conversation: Conversation) -> Bool {
        Self.normalizedPath(conversation.cwd) != nil || conversation.projectless
    }
}

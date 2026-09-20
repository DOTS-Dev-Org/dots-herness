import CryptoKit
import Foundation
import UniformTypeIdentifiers

enum MobileAttachmentKind: String, Codable, Sendable {
    case image
    case audio
    case video
    case file
}

enum MobileAttachmentSourceStatus: String, Codable, Sendable {
    case current
    case changed
    case missing
    case unreadable
}

/// The mobile equivalent of the desktop immutable attachment record. `sourceLocator`
/// is only for re-reading a source revision; provider requests use `snapshotPath`.
struct MobileAttachment: Identifiable, Codable, Equatable, Sendable {
    let attachmentID: String
    let displayName: String
    let kind: MobileAttachmentKind
    let mimeType: String
    let sourceLocator: String
    let bookmarkData: Data?
    let snapshotPath: String?
    let contentHash: String?
    let revision: Int
    let deliveredHash: String?
    let sourceStatus: MobileAttachmentSourceStatus

    var id: String { attachmentID }

    init?(url: URL) {
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else { return nil }
        let type = UTType(filenameExtension: url.pathExtension)
        let kind: MobileAttachmentKind = type?.conforms(to: .image) == true
            ? .image
            : type?.conforms(to: .audio) == true
                ? .audio
                : type?.conforms(to: .movie) == true
                    ? .video
                    : .file
        let scoped = url.startAccessingSecurityScopedResource()
        let bookmark = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        if scoped { url.stopAccessingSecurityScopedResource() }
        self.init(
            attachmentID: UUID().uuidString,
            displayName: url.lastPathComponent,
            kind: kind,
            mimeType: type?.preferredMIMEType ?? "application/octet-stream",
            sourceLocator: url.standardizedFileURL.path,
            bookmarkData: bookmark,
            snapshotPath: nil,
            contentHash: nil,
            revision: 0,
            deliveredHash: nil,
            sourceStatus: .current
        )
    }

    init(
        attachmentID: String,
        displayName: String,
        kind: MobileAttachmentKind,
        mimeType: String,
        sourceLocator: String,
        bookmarkData: Data? = nil,
        snapshotPath: String? = nil,
        contentHash: String? = nil,
        revision: Int = 0,
        deliveredHash: String? = nil,
        sourceStatus: MobileAttachmentSourceStatus = .current
    ) {
        self.attachmentID = attachmentID
        self.displayName = displayName
        self.kind = kind
        self.mimeType = mimeType
        self.sourceLocator = sourceLocator
        self.bookmarkData = bookmarkData
        self.snapshotPath = snapshotPath
        self.contentHash = contentHash
        self.revision = revision
        self.deliveredHash = deliveredHash
        self.sourceStatus = sourceStatus
    }

    func sourceURL() -> URL {
        guard let bookmarkData else { return URL(fileURLWithPath: sourceLocator) }
        var stale = false
        return (try? URL(
            resolvingBookmarkData: bookmarkData,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )) ?? URL(fileURLWithPath: sourceLocator)
    }

    func withSource<T>(_ body: (URL) throws -> T) rethrows -> T {
        let source = sourceURL()
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        return try body(source)
    }

    func observeSource() -> (status: MobileAttachmentSourceStatus, currentHash: String?) {
        let baseline = deliveredHash ?? contentHash
        guard baseline != nil else { return (.current, nil) }
        do {
            return try withSource { source in
                guard FileManager.default.fileExists(atPath: source.path) else { return (.missing, nil) }
                let hash = try Self.stableHash(source)
                return (hash == baseline ? .current : .changed, hash)
            }
        } catch {
            return (FileManager.default.fileExists(atPath: sourceURL().path) ? .unreadable : .missing, nil)
        }
    }

    func stabilized(in directory: URL, fileManager: FileManager = .default) -> MobileAttachment {
        if let snapshotPath, fileManager.fileExists(atPath: snapshotPath) { return self }
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            return try withSource { source in
                for _ in 0..<3 {
                    let before = try Self.signature(source)
                    let temporary = directory.appendingPathComponent("." + UUID().uuidString + ".tmp")
                    do {
                        let result = try Self.copyAndHash(source: source, temporary: temporary, fileManager: fileManager)
                        let after = try Self.signature(source)
                        guard before == after else {
                            try? fileManager.removeItem(at: temporary)
                            continue
                        }
                        let destination = directory.appendingPathComponent(result.hash + "." + (source.pathExtension.isEmpty ? "bin" : source.pathExtension.lowercased()))
                        if !fileManager.fileExists(atPath: destination.path) {
                            try fileManager.moveItem(at: temporary, to: destination)
                        } else {
                            try? fileManager.removeItem(at: temporary)
                        }
                        return MobileAttachment(
                            attachmentID: attachmentID,
                            displayName: displayName,
                            kind: kind,
                            mimeType: mimeType,
                            sourceLocator: sourceLocator,
                            bookmarkData: bookmarkData,
                            snapshotPath: destination.path,
                            contentHash: result.hash,
                            revision: max(revision, 1),
                            deliveredHash: deliveredHash,
                            sourceStatus: .current
                        )
                    } catch {
                        try? fileManager.removeItem(at: temporary)
                    }
                }
                return self
            }
        } catch {
            return self
        }
    }

    func refreshed(in directory: URL) -> MobileAttachment {
        let source = MobileAttachment(
            attachmentID: attachmentID,
            displayName: displayName,
            kind: kind,
            mimeType: mimeType,
            sourceLocator: sourceLocator,
            bookmarkData: bookmarkData,
            revision: max(revision, 1) + 1
        )
        return source.stabilized(in: directory)
    }

    func providerData() -> Data? {
        guard let snapshotPath, FileManager.default.fileExists(atPath: snapshotPath) else { return nil }
        return try? Data(contentsOf: URL(fileURLWithPath: snapshotPath))
    }

    func canonicalBlock() -> [String: Any] {
        var block: [String: Any] = [
            "type": "attachment",
            "attachment_id": attachmentID,
            "name": displayName,
            "kind": kind.rawValue,
            "mime_type": mimeType,
            "revision": revision,
        ]
        if let snapshotPath { block["snapshot_path"] = snapshotPath }
        if let contentHash { block["content_hash"] = contentHash }
        if let deliveredHash { block["delivered_hash"] = deliveredHash }
        return block
    }

    private struct Signature: Equatable {
        let size: Int64
        let modificationDate: Date?
    }

    private static func signature(_ url: URL) throws -> Signature {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return Signature(size: Int64(values.fileSize ?? -1), modificationDate: values.contentModificationDate)
    }

    private static func stableHash(_ url: URL) throws -> String {
        for _ in 0..<3 {
            let before = try signature(url)
            let handle = try FileHandle(forReadingFrom: url)
            var hasher = SHA256()
            while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty { hasher.update(data: chunk) }
            try handle.close()
            let hash = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            if before == try signature(url) { return hash }
        }
        throw CocoaError(.fileReadCorruptFile)
    }

    private static func copyAndHash(source: URL, temporary: URL, fileManager: FileManager) throws -> (hash: String, bytes: Int64) {
        fileManager.createFile(atPath: temporary.path, contents: nil)
        let input = try FileHandle(forReadingFrom: source)
        let output = try FileHandle(forWritingTo: temporary)
        var hasher = SHA256()
        var bytes: Int64 = 0
        while let chunk = try input.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
            try output.write(contentsOf: chunk)
            bytes += Int64(chunk.count)
        }
        try input.close()
        try output.close()
        return (hasher.finalize().map { String(format: "%02x", $0) }.joined(), bytes)
    }
}

enum MobileAttachmentStore {
    static var snapshotDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HerNess/attachment-snapshots", isDirectory: true)
    }
}

import XCTest
@testable import HerNessMobile

final class MobileAttachmentTests: XCTestCase {
    func testHistoricalSnapshotDoesNotSwitchToLatestRevision() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let oldURL = directory.appendingPathComponent("v1.txt")
        let newURL = directory.appendingPathComponent("v2.txt")
        try Data("old".utf8).write(to: oldURL)
        try Data("new".utf8).write(to: newURL)
        let old = MobileAttachment(attachmentID: "one", displayName: "one.txt", kind: .file, mimeType: "text/plain", sourceLocator: oldURL.absoluteString, snapshotPath: oldURL.path, contentHash: "v1", revision: 1)
        let latest = MobileAttachment(attachmentID: "one", displayName: "one.txt", kind: .file, mimeType: "text/plain", sourceLocator: newURL.absoluteString, snapshotPath: newURL.path, contentHash: "v2", revision: 2)
        let historical = try XCTUnwrap(MobilePromptCache.historicalAttachment(old.canonicalBlock(), latest: latest))
        XCTAssertEqual(historical.providerData(), Data("old".utf8))
        try FileManager.default.removeItem(at: oldURL)
        XCTAssertNil(MobilePromptCache.historicalAttachment(old.canonicalBlock(), latest: latest)?.providerData())
    }
    func testCanonicalAttachmentPreservesRevisionLocatorAndDeliveredHash() throws {
        let original = MobileAttachment(
            attachmentID: "attachment-1",
            displayName: "brief.pdf",
            kind: .file,
            mimeType: "application/pdf",
            sourceLocator: "file:///example/brief.pdf",
            snapshotPath: "/snapshots/v1.pdf",
            contentHash: "hash-v1",
            revision: 1,
            deliveredHash: "hash-v1"
        )

        let restored = try XCTUnwrap(MobileAttachment(canonicalBlock: original.canonicalBlock()))

        XCTAssertEqual(restored, original)
        XCTAssertEqual(restored.canonicalBlock()["source_locator"] as? String, original.sourceLocator)
    }
}

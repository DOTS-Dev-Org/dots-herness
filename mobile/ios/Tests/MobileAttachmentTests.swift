import XCTest
@testable import HerNessMobile

final class MobileAttachmentTests: XCTestCase {
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

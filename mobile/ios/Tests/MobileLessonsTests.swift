import XCTest
@testable import HerNessMobile

final class MobileLessonsTests: XCTestCase {
    @MainActor
    func testReadsWhatADesktopLearnedAndAppendsItOnce() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MobileLessonsTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".mem"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(MobileLessons.rulesText(root: root), "")

        try """
        [
          {"lastSeen":"2020-01-01T00:00:00Z","paths":[],"rule":"Inferred once, long ago.","sources":["signal:stale"],"when":"","why":""},
          {"lastSeen":"2020-01-01T00:00:00Z","paths":[],"rule":"Do not skip the loading state.","sources":["3f2a9c0d1b7e4a55"],"when":"adding a screen","why":"Users saw a blank page."},
          {"lastSeen":"2020-01-01T00:00:00Z","paths":["Sources/App"],"rule":"Only for one folder.","sources":["3f2a9c0d1b7e4a56"],"when":"","why":""}
        ]
        """.write(to: root.appendingPathComponent(".mem/lessons.json"), atomically: true, encoding: .utf8)
        let text = MobileLessons.rulesText(root: root)
        XCTAssertTrue(text.contains("- [3f2a9c user] When adding a screen: Do not skip the loading state. Why: Users saw a blank page."))
        XCTAssertFalse(text.contains("Inferred once, long ago."))
        XCTAssertFalse(text.contains("Only for one folder."))

        // A lesson tied to a folder comes with the first file read there, once.
        XCTAssertTrue(MobileLessons.fileNotice(root: root, path: "Sources/App/Login.swift").contains("Only for one folder."))
        XCTAssertEqual(MobileLessons.fileNotice(root: root, path: "Sources/App/Login.swift"), "")
        XCTAssertEqual(MobileLessons.fileNotice(root: root, path: "Sources/Other.swift"), "")

        // The facts file is shared with the desktops: read their lines, add ours.
        try "## project\n- backend — https://api.example.test\n".write(
            to: root.appendingPathComponent(".mem/facts.md"), atomically: true, encoding: .utf8
        )
        XCTAssertEqual(
            MobileFacts.record(root: root, kind: "preference", key: "Language", text: "Reply in  Turkish."),
            "Recorded preference language: Reply in Turkish."
        )
        XCTAssertTrue(MobileFacts.record(root: root, kind: "project", key: "api-key", text: "x").hasPrefix("Not recorded"))
        XCTAssertEqual(
            try String(contentsOf: root.appendingPathComponent(".mem/facts.md"), encoding: .utf8),
            "## project\n- backend — https://api.example.test\n\n## preference\n- language — Reply in Turkish.\n"
        )
        XCTAssertTrue(MobileLessons.rulesText(root: root).contains("- backend — https://api.example.test"))

        var state = MobileCacheState()
        XCTAssertTrue(state.captureNotices(attachmentNotice: nil, plan: false, lessons: text).contains(text))
        // Unchanged rules are not appended to the transcript again.
        XCTAssertFalse(state.captureNotices(attachmentNotice: nil, plan: false, lessons: text).contains(text))
        XCTAssertTrue(state.captureNotices(attachmentNotice: nil, plan: false, lessons: text + "\n- New.").contains(text + "\n- New."))
    }
}

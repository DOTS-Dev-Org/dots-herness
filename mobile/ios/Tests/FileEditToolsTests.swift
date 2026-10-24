import Foundation
import XCTest
@testable import HerNessMobile

/// `edit_file` and `glob` against a scratch directory, with the workspace path
/// resolver injected. Nothing here opens a project mirror or a socket: the point is
/// the pattern compiler, the rejection table, and the fact that a refused batch
/// leaves the bytes alone.
final class FileEditToolsTests: XCTestCase {
    private var base: URL!

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("herness-edit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: base)
        ReadLedger.shared.reset()
    }

    // MARK: - glob pattern compilation

    func testGlobPatternsCompileToTheDocumentedExpression() throws {
        let table: [(String, String)] = [
            ("*.swift", #"^[^/]*\.swift$"#),
            ("src/*.swift", #"^src/[^/]*\.swift$"#),
            ("?", #"^[^/]$"#),
            ("a?c", #"^a[^/]c$"#),
            ("**", #"^.*$"#),
            ("**/*.swift", #"^(?:[^/]*/)*[^/]*\.swift$"#),
            ("src/**/*.ts", #"^src/(?:[^/]*/)*[^/]*\.ts$"#),
            ("docs/**", #"^docs/.*$"#),
            ("Sources/**/*Test*.swift", #"^Sources/(?:[^/]*/)*[^/]*Test[^/]*\.swift$"#),
            ("config.{json,yml}", #"^config\.(?:json|yml)$"#),
            ("a{b,{c,d}}", #"^a(?:b|(?:c|d))$"#),
            ("[abc]", "^[abc]$"),
            ("a+b.c", #"^a\+b\.c$"#),
            ("we(ird).txt", #"^we\(ird\)\.txt$"#),
            ("a,b", "^a,b$"),
        ]
        for (pattern, expected) in table {
            XCTAssertEqual(FileEditTools.globPattern(pattern) ?? "<nil>", expected, pattern)
            XCTAssertNotNil(FileEditTools.globRegex(pattern), pattern)
        }
    }

    func testBrokenGlobGroupsAreReportedNotGuessed() {
        for pattern in ["{a", "a}", "a[", "{a,b", "*.{js"] {
            XCTAssertNil(FileEditTools.globPattern(pattern), pattern)
            XCTAssertNil(FileEditTools.globRegex(pattern), pattern)
        }
    }

    func testSingleStarStaysInsideOneSegmentWhileBarePatternReachesDepth() throws {
        let expression = try XCTUnwrap(FileEditTools.globRegex("*.swift"))
        // A pattern with a slash is anchored to the searched directory...
        XCTAssertTrue(FileEditTools.isMatch(
            expression: expression, relative: "a.swift", patternHasSlash: true, lastComponent: "a.swift"
        ))
        XCTAssertFalse(FileEditTools.isMatch(
            expression: expression, relative: "Sources/a.swift", patternHasSlash: true, lastComponent: "a.swift"
        ))
        // ...and one without still matches nested files by their name.
        XCTAssertTrue(FileEditTools.isMatch(
            expression: expression, relative: "Sources/a.swift", patternHasSlash: false, lastComponent: "a.swift"
        ))
        let crossing = try XCTUnwrap(FileEditTools.globRegex("Sources/**/*.swift"))
        XCTAssertTrue(FileEditTools.isMatch(
            expression: crossing, relative: "Sources/a.swift", patternHasSlash: true, lastComponent: "a.swift"
        ), "**/ must also stand for zero directories")
    }

    // MARK: - glob against a directory

    func testGlobReturnsNewestFirstAndSkipsBuildAndLinkArtifacts() async throws {
        try seed([
            "a.swift": "older",
            "Sources/b.swift": "newer",
            "node_modules/c.swift": "dependency",
            "notes.txt": "text",
        ])
        // A symlink inside the mirror must not be listed, nor followed.
        try FileManager.default.createSymbolicLink(
            at: base.appendingPathComponent("link.swift"),
            withDestinationURL: base.appendingPathComponent("a.swift")
        )
        try touch("a.swift", at: 1_600)
        try touch("Sources/b.swift", at: 2_000)

        let nested = try await lines("**/*.swift", path: "")
        XCTAssertEqual(nested, [
            "glob **/*.swift under .: 2 files",
            "Sources/b.swift",
            "a.swift",
        ])

        let bare = try await lines("*.swift", path: "")
        XCTAssertEqual(try XCTUnwrap(bare.first), "glob *.swift under .: 2 files")
        XCTAssertEqual(Array(bare.dropFirst()), ["Sources/b.swift", "a.swift"])

        let scoped = try await lines("*.swift", path: "Sources")
        XCTAssertEqual(scoped, ["glob *.swift under Sources: 1 file", "b.swift"])

        let none = try await lines("*.kt", path: "")
        XCTAssertEqual(none, ["glob *.kt: no files found."])
    }

    func testGlobSkipsIgnoredDirectoriesEvenWhenThePatternNamesThem() async throws {
        try seed(["node_modules/inner/deep.js": "x", "index.js": "y"])
        let found = try await lines("**/*.js", path: "")
        XCTAssertEqual(found, ["glob **/*.js under .: 1 file", "index.js"])
        let named = try await lines("node_modules/**", path: "")
        XCTAssertEqual(named, ["glob node_modules/**: no files found."])
    }

    func testGlobCapsTheListAndSaysSo() async throws {
        var files: [String: String] = [:]
        for index in 0..<250 { files["generated/f\(index).txt"] = "x" }
        try seed(files)
        let found = try await lines("f*.txt", path: "")
        XCTAssertEqual(found.count, FileEditTools.globResultCap + 1)
        XCTAssertEqual(
            try XCTUnwrap(found.first),
            "glob f*.txt under .: \(FileEditTools.globResultCap) newest of 250 matches — narrow the pattern"
        )
    }

    func testGlobRefusesPatternsAndRootsThatLeaveTheWorkspace() async throws {
        for pattern in ["/etc/*.conf", "../secret.txt", "a/../../b/*.txt", "   "] {
            let answer = await FileEditTools.glob(pattern: pattern, path: "", resolve: resolver())
            XCTAssertTrue(
                answer == "Tool error: pattern is required." || answer == "Tool error: pattern must stay inside the workspace.",
                "\(pattern) answered: \(answer)"
            )
        }
        let uncompiled = await FileEditTools.glob(pattern: "bad{group", path: "", resolve: resolver())
        XCTAssertEqual(uncompiled, "Tool error: the pattern could not be compiled — check for an unclosed { or [.")
        try seed(["plain.txt": "x"])
        let notDirectory = await FileEditTools.glob(pattern: "*", path: "plain.txt", resolve: resolver())
        XCTAssertEqual(notDirectory, "Tool error: plain.txt is not a directory.")
    }

    // MARK: - edit_file

    func testEditReplacesOnlyTheMatchedText() async throws {
        let written = try await edit("README.md", [
            ["old_text": "# Old title", "new_text": "# New title"],
        ], body: "# Old title\n\nBody stays.\n")
        XCTAssertTrue(written.hasPrefix("Edited README.md (replaced 1 occurrence)."), written)
        XCTAssertEqual(try text("README.md"), "# New title\n\nBody stays.\n")
        // The write is recorded, so a follow-up edit needs no fresh read.
        let second = await FileEditTools.edit(path: "README.md", edits: [
            ["old_text": "Body stays", "new_text": "Body moved"],
        ], resolve: resolver())
        XCTAssertTrue(second.hasPrefix("Edited README.md (replaced 1 occurrence)."), second)
        XCTAssertEqual(try text("README.md"), "# New title\n\nBody moved.\n")
    }

    func testEmptyNewTextDeletesTheMatch() async throws {
        let answer = try await edit("keep.txt", [["old_text": "drop-me ", "new_text": ""]], body: "drop-me keep\n")
        XCTAssertTrue(answer.hasPrefix("Edited keep.txt (replaced 1 occurrence)."), answer)
        XCTAssertEqual(try text("keep.txt"), "keep\n")
    }

    func testReplaceAllIsExplicitAndReportsEveryOccurrence() async throws {
        let answer = try await edit("count.txt", [
            ["old_text": "cat", "new_text": "dog", "replace_all": true],
        ], body: "cat and cat and cat\n")
        XCTAssertTrue(answer.hasPrefix("Edited count.txt (replaced 3 occurrences)."), answer)
        XCTAssertEqual(try text("count.txt"), "dog and dog and dog\n")
    }

    /// Replacements run against the running text, not the bytes on disk, so a
    /// second edit can name what the first one produced.
    func testEditsApplyInOrderAgainstTheAccumulatingText() async throws {
        let answer = try await edit("order.txt", [
            ["old_text": "alpha", "new_text": "beta"],
            ["old_text": "beta beta", "new_text": "gamma"],
        ], body: "alpha beta\n")
        XCTAssertTrue(answer.hasPrefix("Edited order.txt (replaced 1 occurrence; replaced 1 occurrence)."), answer)
        XCTAssertEqual(try text("order.txt"), "gamma\n")
    }

    func testEveryRejectionSaysNothingWasWrittenAndLeavesTheBytesAlone() async throws {
        let body = "alpha\nbeta\nbeta\ngamma\n"
        let cases: [(edits: [[String: Any]], expected: String)] = [
            ([], "Tool error: edits is empty; at least one replacement is required."),
            ([["old_text": "alpha"]],
             "Tool error: edit 1 needs both old_text and new_text. Nothing was written."),
            ([["new_text": "alpha"]],
             "Tool error: edit 1 needs both old_text and new_text. Nothing was written."),
            ([["old_text": "", "new_text": "alpha"]],
             "Tool error: edit 1 has an empty old_text, which would match everywhere. Nothing was written."),
            ([["old_text": "alpha", "new_text": "x"], ["old_text": "absent", "new_text": "y"]],
             "Tool error: edit 2 matched nothing in strict.txt. Nothing was written — check the exact text and whitespace with read_file."),
            ([["old_text": "beta", "new_text": "x"]],
             "Tool error: edit 1 matched 2 places in strict.txt (around lines 2, 3). Nothing was written. Widen old_text with surrounding lines, or set replace_all."),
            ([["old_text": "beta", "new_text": "x", "replace_all": false]],
             "Tool error: edit 1 matched 2 places in strict.txt (around lines 2, 3). Nothing was written. Widen old_text with surrounding lines, or set replace_all."),
        ]
        for case let (edits, expected) in cases {
            try seed(["strict.txt": body])
            await prepare("strict.txt", body: body)
            let answer = await FileEditTools.edit(path: "strict.txt", edits: edits, resolve: resolver())
            XCTAssertEqual(answer, expected, "\(edits)")
            XCTAssertEqual(try text("strict.txt"), body, "a rejected batch must not touch the file: \(edits)")
        }
    }

    func testAmbiguousMatchListsAtMostFiveLineNumbers() async throws {
        let body = "one\nx\nx\nx\nx\nx\nx\n"
        try seed(["many.txt": body])
        await prepare("many.txt", body: body)
        let answer = await FileEditTools.edit(path: "many.txt", edits: [["old_text": "x", "new_text": "y"]], resolve: resolver())
        XCTAssertEqual(answer, "Tool error: edit 1 matched 6 places in many.txt (around lines 2, 3, 4, 5, 6). Nothing was written. Widen old_text with surrounding lines, or set replace_all.")
    }

    func testUnreadStaleAbsentAndBinaryFilesAreRefused() async throws {
        try seed(["unread.txt": "content\n"])
        let unread = await FileEditTools.edit(path: "unread.txt", edits: [["old_text": "content", "new_text": "x"]], resolve: resolver())
        XCTAssertEqual(unread, "Tool error: unread.txt has not been read in this conversation. Read it before editing.")

        try seed(["stale.txt": "content\n"])
        await prepare("stale.txt", body: "content\n")
        try seed(["stale.txt": "content changed by the user\n"])
        let stale = await FileEditTools.edit(path: "stale.txt", edits: [["old_text": "content", "new_text": "x"]], resolve: resolver())
        XCTAssertEqual(stale, "Tool error: stale.txt changed since it was read. Read it again before editing.")

        let absent = await FileEditTools.edit(path: "missing.txt", edits: [["old_text": "a", "new_text": "b"]], resolve: resolver())
        XCTAssertEqual(absent, "Tool error: missing.txt does not exist. write_file creates a new file; edit_file only changes an existing one.")

        try Data([0xff, 0xfe, 0xff]).write(to: base.appendingPathComponent("binary.bin"))
        let binary = await FileEditTools.edit(path: "binary.bin", edits: [["old_text": "a", "new_text": "b"]], resolve: resolver())
        XCTAssertEqual(binary, "Tool error: binary.bin is not valid UTF-8 text.")
    }

    func testOnePageAuthorizesAnEditButNeverAWholeFileRewrite() async throws {
        try seed(["part.txt": "one\ntwo\nthree\nfour"])
        let url = base.appendingPathComponent("part.txt")
        _ = try AgentTools.readFile(at: url, offset: 2, limit: 1)
        let first = await FileEditTools.edit(path: "part.txt", edits: [["old_text": "two", "new_text": "2"]], resolve: resolver())
        XCTAssertTrue(first.hasPrefix("Edited"), first)
        let second = await FileEditTools.edit(path: "part.txt", edits: [["old_text": "2", "new_text": "zwei"]], resolve: resolver())
        XCTAssertTrue(second.hasPrefix("Edited"), second)
        XCTAssertEqual(ReadLedger.shared.state(for: url, data: try Data(contentsOf: url)), .unread)
        try Data("changed outside".utf8).write(to: url)
        let stale = await FileEditTools.edit(path: "part.txt", edits: [["old_text": "changed", "new_text": "bad"]], resolve: resolver())
        XCTAssertEqual(stale, "Tool error: part.txt changed since it was read. Read it again before editing.")
    }

    func testTooManyEditsInOneCallAreRefusedBeforeTheFileIsOpened() async {
        let batch = Array(repeating: ["old_text": "a", "new_text": "b"], count: FileEditTools.maximumEdits + 1)
        let answer = await FileEditTools.edit(path: "never-created.txt", edits: batch, resolve: resolver())
        XCTAssertEqual(answer, "Tool error: too many edits in one call (max 50). Split them into separate calls.")
    }

    func testPathResolutionFailuresSurfaceAsToolErrors() async {
        let failing: FileEditTools.PathResolver = { _ in
            throw NSError(domain: "HerNess.Workspace", code: 7, userInfo: [NSLocalizedDescriptionKey: "The path escapes the workspace"])
        }
        let editAnswer = await FileEditTools.edit(path: "../escape.txt", edits: [["old_text": "a", "new_text": "b"]], resolve: failing)
        XCTAssertEqual(editAnswer, "Tool error: The path escapes the workspace")
        let globAnswer = await FileEditTools.glob(pattern: "*.txt", path: "../escape", resolve: failing)
        XCTAssertTrue(globAnswer.hasPrefix("Tool error: The path escapes the workspace"))
    }

    /// The ledger, not the tool, is what authorizes the write: a truncated read
    /// forgets the file, so an edit after it reports `unread`.
    func testTruncatedReadDoesNotAuthorizeAnEdit() async throws {
        try seed(["long.txt": "content\n"])
        let url = base.appendingPathComponent("long.txt")
        ReadLedger.shared.record(url, data: try Data(contentsOf: url))
        ReadLedger.shared.forget(url)
        let answer = await FileEditTools.edit(path: "long.txt", edits: [["old_text": "content", "new_text": "x"]], resolve: resolver())
        XCTAssertEqual(answer, "Tool error: long.txt has not been read in this conversation. Read it before editing.")
    }

    func testPartialReadAllowsEditsInsideItAndCarriesTheRangeOver() async throws {
        let text = (1...600).map { "line-\($0)" }.joined(separator: "\n")
        try seed(["long.txt": text])
        let url = base.appendingPathComponent("long.txt")
        ReadLedger.shared.forget(url)
        // One default page: lines 1-250.
        ReadLedger.shared.recordLines(url, data: Data(text.utf8), lines: 1..<251, totalLines: 600)

        var answer = await FileEditTools.edit(path: "long.txt", edits: [["old_text": "line-10\n", "new_text": "line-10\nadded-a\nadded-b\n"]], resolve: resolver())
        XCTAssertTrue(answer.hasPrefix("Edited"), answer)
        // The read lines moved two down with the edit: line-250 still counts as read,
        // line-251 still does not.
        answer = await FileEditTools.edit(path: "long.txt", edits: [["old_text": "line-250\n", "new_text": "line-250!\n"]], resolve: resolver())
        XCTAssertTrue(answer.hasPrefix("Edited"), answer)
        answer = await FileEditTools.edit(path: "long.txt", edits: [["old_text": "line-251\n", "new_text": "nope\n"]], resolve: resolver())
        XCTAssertTrue(answer.contains("which were not read"), answer)
        // write_file still needs the whole file.
        XCTAssertEqual(ReadLedger.shared.state(for: url, data: try Data(contentsOf: url)), .unread)
    }

    // MARK: - Helpers

    private func resolver() -> FileEditTools.PathResolver {
        let root = try! XCTUnwrap(base)
        return { relative in root.appendingPathComponent(relative) }
    }

    private func seed(_ files: [String: String]) throws {
        for (path, body) in files {
            let url = base.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(body.utf8).write(to: url)
        }
    }

    private func touch(_ path: String, at seconds: TimeInterval) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: seconds)],
            ofItemAtPath: base.appendingPathComponent(path).path
        )
    }

    /// Mirrors `read_file`: a full read is what records the hash `edit_file` checks.
    private func prepare(_ path: String, body: String) async {
        ReadLedger.shared.record(base.appendingPathComponent(path), data: Data(body.utf8))
    }

    private func edit(_ path: String, _ edits: [[String: Any]], body: String) async throws -> String {
        try seed([path: body])
        await prepare(path, body: body)
        return await FileEditTools.edit(path: path, edits: edits, resolve: resolver())
    }

    private func lines(_ pattern: String, path: String) async -> [String] {
        await FileEditTools.glob(pattern: pattern, path: path, resolve: resolver())
            .components(separatedBy: "\n")
    }

    private func text(_ path: String) throws -> String {
        try String(contentsOf: base.appendingPathComponent(path), encoding: .utf8)
    }
}

// Copyright (c) 2026 DOTS
// edit_file and glob behaviour tests.

import XCTest
import Foundation
import HarnessPluginKit
@testable import DotsHarnessCore

/// edit_file and glob: the rejection paths matter more than the success path,
/// because a wrong edit is silent data loss while a wrong rejection is only a
/// wasted turn.
final class FileEditToolsTests: XCTestCase {
    private var workspace: URL!
    private let conversation = "test-conversation"

    override func setUp() {
        super.setUp()
        ReadLedger.shared.reset()
        workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileEditToolsTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: workspace)
        ReadLedger.shared.reset()
        super.tearDown()
    }

    @discardableResult
    private func seed(_ path: String, _ text: String, read: Bool = true) throws -> URL {
        let url = workspace.appendingPathComponent(path, isDirectory: false)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = Data(text.utf8)
        try data.write(to: url)
        if read { ReadLedger.shared.record(url, data: data, conversationID: conversation) }
        return url
    }

    private func contents(_ path: String) throws -> String {
        try String(contentsOf: workspace.appendingPathComponent(path), encoding: .utf8)
    }

    private func edit(_ path: String, _ edits: [[String: Any]]) -> String {
        FileEditTools.edit(path: path, edits: edits, workspace: workspace, conversationID: conversation)
    }

    // MARK: - edit_file

    func testAppliesUniqueMatchAndLeavesRestOfFileIntact() throws {
        try seed("a.swift", "let one = 1\nlet two = 2\nlet three = 3\n")
        let result = edit("a.swift", [["old_text": "let two = 2", "new_text": "let two = 22"]])
        XCTAssertTrue(result.hasPrefix("Edited a.swift"), result)
        XCTAssertEqual(
            try contents("a.swift"),
            "let one = 1\nlet two = 22\nlet three = 3\n"
        )
    }

    func testAppliesSeveralEditsInOrder() throws {
        try seed("b.swift", "alpha\nbeta\n")
        let result = edit("b.swift", [
            ["old_text": "alpha", "new_text": "ALPHA"],
            ["old_text": "beta", "new_text": "ALPHA\nomega"],
        ])
        XCTAssertTrue(result.contains("replaced 1 occurrence; replaced 1 occurrence"), result)
        XCTAssertEqual(try contents("b.swift"), "ALPHA\nALPHA\nomega\n")
    }

    func testAmbiguousMatchWritesNothing() throws {
        try seed("c.swift", "same\nsame\nsame\n")
        let result = edit("c.swift", [["old_text": "same", "new_text": "other"]])
        XCTAssertTrue(result.contains("matched 3 places"), result)
        XCTAssertTrue(result.contains("Nothing was written"), result)
        XCTAssertEqual(try contents("c.swift"), "same\nsame\nsame\n")
    }

    func testAmbiguousMatchNamesTheCandidateLines() throws {
        try seed("d.swift", "one\nmatch\nthree\nfour\nmatch\nsix\n")
        let result = edit("d.swift", [["old_text": "match", "new_text": "x"]])
        XCTAssertTrue(result.contains("around lines 2, 5"), result)
    }

    func testReplaceAllHandlesEveryOccurrence() throws {
        try seed("e.swift", "foo foo bar\n")
        let result = edit("e.swift", [["old_text": "foo", "new_text": "baz", "replace_all": true]])
        XCTAssertTrue(result.contains("replaced 2 occurrences"), result)
        XCTAssertEqual(try contents("e.swift"), "baz baz bar\n")
    }

    func testEmptyNewTextDeletesTheMatch() throws {
        try seed("f.swift", "keep\ndrop\nkeep again\n")
        _ = edit("f.swift", [["old_text": "drop\n", "new_text": ""]])
        XCTAssertEqual(try contents("f.swift"), "keep\nkeep again\n")
    }

    func testMissingMatchWritesNothingAndSaysWhichEdit() throws {
        try seed("g.swift", "hello\n")
        let result = edit("g.swift", [["old_text": "goodbye", "new_text": "hello there"]])
        XCTAssertTrue(result.contains("edit 1 matched nothing"), result)
        XCTAssertEqual(try contents("g.swift"), "hello\n")
    }

    func testEmptyOldTextIsRejected() throws {
        try seed("h.swift", "x\n")
        let result = edit("h.swift", [["old_text": "", "new_text": "y"]])
        XCTAssertTrue(result.contains("empty old_text"), result)
        XCTAssertEqual(try contents("h.swift"), "x\n")
    }

    func testPartialReadAllowsEditsInsideItAndCarriesTheRangeOver() throws {
        let text = (1...600).map { "line-\($0)" }.joined(separator: "\n")
        let url = try seed("long.swift", text, read: false)
        // One default page: lines 1-250.
        ReadLedger.shared.recordLines(url, data: Data(text.utf8), lines: 1..<251, totalLines: 600, conversationID: conversation)

        XCTAssertTrue(edit("long.swift", [["old_text": "line-10\n", "new_text": "line-10\nadded-a\nadded-b\n"]]).hasPrefix("Edited"))
        // The read lines moved two down with the edit: line-250 is now line 252 and
        // still counts as read; line-251 (now 253) still does not.
        XCTAssertTrue(edit("long.swift", [["old_text": "line-250\n", "new_text": "line-250!\n"]]).hasPrefix("Edited"))
        let refused = edit("long.swift", [["old_text": "line-251\n", "new_text": "nope\n"]])
        XCTAssertTrue(refused.contains("which were not read"), refused)
        XCTAssertFalse(try contents("long.swift").contains("nope"))
        // write_file still needs the whole file.
        XCTAssertEqual(
            ReadLedger.shared.state(for: url, data: try Data(contentsOf: url), conversationID: conversation),
            .unread
        )
    }

    func testReplaceAllOnAPartialReadNeedsEveryOccurrenceRead() throws {
        let text = (1...400).map { $0 == 5 || $0 == 300 ? "same" : "l\($0)" }.joined(separator: "\n")
        let url = try seed("dup.swift", text, read: false)
        ReadLedger.shared.recordLines(url, data: Data(text.utf8), lines: 1..<251, totalLines: 400, conversationID: conversation)
        let result = edit("dup.swift", [["old_text": "same", "new_text": "other", "replace_all": true]])
        XCTAssertTrue(result.contains("lines 300-300"), result)
        XCTAssertFalse(try contents("dup.swift").contains("other"))
    }

    func testUnreadFileCannotBeEdited() throws {
        try seed("i.swift", "value = 1\n", read: false)
        let result = edit("i.swift", [["old_text": "value = 1", "new_text": "value = 2"]])
        XCTAssertTrue(result.contains("has not been read"), result)
        XCTAssertEqual(try contents("i.swift"), "value = 1\n")
    }

    func testFileChangedAfterReadIsRejectedAsStale() throws {
        let url = try seed("j.swift", "one\n")
        // An external write leaves the ledger holding the old hash.
        try Data("one\ntwo\n".utf8).write(to: url)
        let result = edit("j.swift", [["old_text": "one", "new_text": "1"]])
        XCTAssertTrue(result.contains("changed since it was read"), result)
        XCTAssertEqual(try contents("j.swift"), "one\ntwo\n")
    }

    func testEditCannotCreateAFile() throws {
        let result = edit("new.swift", [["old_text": "a", "new_text": "b"]])
        XCTAssertTrue(result.contains("does not exist"), result)
        XCTAssertTrue(result.contains("write_file creates a new file"), result)
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("new.swift").path))
    }

    func testEditsAreBoundedPerCall() throws {
        try seed("k.swift", "x\n")
        let flood = Array(repeating: ["old_text": "x", "new_text": "y"], count: 51)
        let result = edit("k.swift", flood)
        XCTAssertTrue(result.contains("too many edits"), result)
    }

    func testEditRefusesPathsOutsideTheWorkspace() {
        let result = edit("../elsewhere.swift", [["old_text": "a", "new_text": "b"]])
        XCTAssertTrue(result.contains("outside"), result)
    }

    func testSuccessfulEditKeepsTheLedgerFresh() throws {
        try seed("l.swift", "a1\n")
        _ = edit("l.swift", [["old_text": "a1", "new_text": "a2"]])
        let result = edit("l.swift", [["old_text": "a2", "new_text": "a3"]])
        XCTAssertTrue(result.hasPrefix("Edited"), "a second edit must not be told to re-read: \(result)")
        XCTAssertEqual(try contents("l.swift"), "a3\n")
    }

    func testOverlappingTextCountsNonOverlappingOccurrences() {
        // "aaa" with needle "aa" has one non-overlapping match, which is what the
        // replacement will actually consume.
        XCTAssertEqual(FileEditTools.occurrences(of: "aa", in: "aaa").count, 1)
        XCTAssertEqual(FileEditTools.occurrences(of: "ab", in: "ababab").count, 3)
    }

    // MARK: - glob pattern compilation

    func testDoubleStarCrossesDirectoriesAndMatchesZeroOfThem() throws {
        XCTAssertNotNil(try regexPattern("**/*.swift"))
        XCTAssertTrue(matches("**/*.swift", "a.swift"))
        XCTAssertTrue(matches("**/*.swift", "Sources/App/Deep.swift"))
        XCTAssertFalse(matches("**/*.swift", "Sources/App/main.js"))
    }

    func testSingleStarStopsAtSeparators() {
        XCTAssertTrue(matches("Sources/*.swift", "Sources/App.swift"))
        XCTAssertFalse(matches("Sources/*.swift", "Sources/Nested/App.swift"))
    }

    func testQuestionMarkMatchesOneCharacter() {
        XCTAssertTrue(matches("f?le.txt", "file.txt"))
        XCTAssertFalse(matches("f?le.txt", "fle.txt"))
    }

    func testBraceGroupsAlternate() {
        XCTAssertTrue(matches("config.{json,yml}", "config.yml"))
        XCTAssertTrue(matches("config.{json,yml}", "config.json"))
        XCTAssertFalse(matches("config.{json,yml}", "config.toml"))
    }

    func testCharacterClassesWork() {
        XCTAssertTrue(matches("v[0-9].ts", "v3.ts"))
        XCTAssertFalse(matches("v[0-9].ts", "vx.ts"))
    }

    func testDotIsLiteralNotAWildcard() {
        XCTAssertFalse(matches("app.config.ts", "appXconfigXts"))
        XCTAssertTrue(matches("app.config.ts", "app.config.ts"))
    }

    func testBrokenPatternsAreRejectedRatherThanMatchingEverything() {
        // A pattern that cannot be compiled must answer nil, never a regex that
        // matches everything by accident.
        XCTAssertNil(FileEditTools.globRegex("a{b"))
        XCTAssertNil(FileEditTools.globRegex("a[b"))
    }

    func testEscapedRegexMetacharactersStayLiteral() throws {
        let expression = try regexPattern("a+b.ts")
        let text = "a+b.ts"
        XCTAssertNotNil(expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)))
        XCTAssertNil(try regexPattern("a+b.ts").firstMatch(
            in: "aab.ts", range: NSRange("aab.ts".startIndex..., in: "aab.ts")
        ))
    }

    private func regexPattern(_ glob: String) throws -> NSRegularExpression {
        guard let expression = FileEditTools.globRegex(glob) else {
            throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "no regex for \(glob)"])
        }
        return expression
    }

    private func matches(_ glob: String, _ path: String) -> Bool {
        guard let expression = FileEditTools.globRegex(glob) else { return false }
        return expression.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)) != nil
    }

    // MARK: - glob against a real tree

    func testGlobReturnsMatchesAndADescriptiveHeader() throws {
        try seed("Sources/Alpha.swift", "1")
        try seed("Sources/Nested/Beta.swift", "2")
        try seed("Sources/Gamma.js", "3")
        let output = FileEditTools.glob(pattern: "**/*.swift", path: ".", workspace: workspace)
        XCTAssertTrue(output.contains("Sources/Alpha.swift"), output)
        XCTAssertTrue(output.contains("Sources/Nested/Beta.swift"), output)
        XCTAssertFalse(output.contains("Gamma.js"), output)
        XCTAssertTrue(output.hasPrefix("glob **/*.swift"), output)
    }

    func testBarePatternReachesNestedFiles() throws {
        try seed("Deep/Deeper/Needle.swift", "1")
        let output = FileEditTools.glob(pattern: "Needle.swift", path: ".", workspace: workspace)
        XCTAssertTrue(output.contains("Deep/Deeper/Needle.swift"), output)
    }

    func testGlobSkipsBuildAndDependencyDirectories() throws {
        try seed("node_modules/left-pad/index.js", "1")
        try seed("build/Generated.swift", "2")
        try seed("Real.swift", "3")
        let output = FileEditTools.glob(pattern: "**/*.swift", path: ".", workspace: workspace)
        XCTAssertTrue(output.contains("Real.swift"), output)
        XCTAssertFalse(output.contains("Generated.swift"), output)
        XCTAssertFalse(output.contains("node_modules"), output)
    }

    func testNewestFileComesFirst() throws {
        try seed("old.swift", "1")
        try seed("new.swift", "2")
        let older = workspace.appendingPathComponent("old.swift")
        let newer = workspace.appendingPathComponent("new.swift")
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: older.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date()], ofItemAtPath: newer.path
        )
        let output = FileEditTools.glob(pattern: "*.swift", path: ".", workspace: workspace)
        let lines = output.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.dropFirst().first, "new.swift", output)
    }

    func testNoMatchSaysSoInsteadOfReturningAnEmptyBody() throws {
        try seed("only.swift", "1")
        let output = FileEditTools.glob(pattern: "**/*.kt", path: ".", workspace: workspace)
        XCTAssertTrue(output.contains("no files found"), output)
    }

    func testGlobRefusesPatternsThatLeaveTheWorkspace() {
        XCTAssertTrue(FileEditTools.glob(pattern: "../**/*.swift", path: ".", workspace: workspace).contains("inside the workspace"))
        XCTAssertTrue(FileEditTools.glob(pattern: "/etc/**", path: ".", workspace: workspace).contains("inside the workspace"))
    }

    // MARK: - wiring

    func testBothToolsAreOfferedThroughWorkspaceTools() {
        let names = Set(WorkspaceTools.definitions.map(\.name))
        XCTAssertTrue(names.contains("edit_file"))
        XCTAssertTrue(names.contains("glob"))
    }

    func testGlobIsReadOnlyAndEditFileIsNot() {
        XCTAssertTrue(WorkspaceTools.isReadOnly("glob"))
        XCTAssertFalse(WorkspaceTools.isReadOnly("edit_file"))
        XCTAssertEqual(NativeAgentHost.risk("edit_file"), .workspaceMutation)
        XCTAssertEqual(NativeAgentHost.risk("glob"), .readOnly)
    }

    func testPlanModeWithholdsEditFileButNotGlob() {
        XCTAssertTrue(NativeAgentHost.planWithholds("edit_file"))
        XCTAssertFalse(NativeAgentHost.planWithholds("glob"))
    }
}

import XCTest
@testable import DotsHarnessCore

/// read_file paging and the write_file guard that keeps a blind rewrite from
/// dropping content the model never saw.
final class WorkspaceReadWriteTests: XCTestCase {
    private var workspace: URL!

    override func setUp() {
        super.setUp()
        ReadLedger.shared.reset()
        workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceReadWriteTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: workspace)
        ReadLedger.shared.reset()
        super.tearDown()
    }

    private func read(_ arguments: String) -> String {
        WorkspaceTools.execute(
            AgentToolCall(id: "r", name: "read_file", arguments: arguments),
            workspace: workspace
        , conversationID: "test")
    }

    private func write(_ path: String, _ content: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: ["path": path, "content": content])
        return WorkspaceTools.execute(
            AgentToolCall(id: "w", name: "write_file", arguments: String(data: data, encoding: .utf8)!),
            workspace: workspace
        , conversationID: "test")
    }

    private func grep(_ pattern: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: ["pattern": pattern, "extensions": "txt"])
        return WorkspaceTools.execute(
            AgentToolCall(id: "g", name: "grep_files", arguments: String(data: data, encoding: .utf8)!),
            workspace: workspace,
            conversationID: "test"
        )
    }

    func testCommandTimeoutIsClampedAndATimeoutKeepsItsOutput() {
        XCTAssertEqual(WorkspaceTools.commandTimeout([:]), 120)
        XCTAssertEqual(WorkspaceTools.commandTimeout(["timeout_seconds": 900]), 600)
        XCTAssertEqual(WorkspaceTools.commandTimeout(["timeout_seconds": -5]), 120)
        let result = WorkspaceTools.execute(
            AgentToolCall(id: "c", name: "run_command", arguments: #"{"command":"echo started; sleep 5","timeout_seconds":1}"#),
            workspace: workspace,
            conversationID: "test"
        )
        XCTAssertTrue(result.contains(AppCopy.format("tool.timedOut", 1)), result)
        XCTAssertTrue(result.contains("started"), result)
        XCTAssertFalse(WorkspaceTools.lockNotice("Another instance of SwiftPM is already running using '.build'").isEmpty)
    }

    func testLockNoticeNamesTheHolderAndWaitCommandSeesItExit() throws {
        let notice = WorkspaceTools.lockNotice("Another instance of SwiftPM (PID: 37990) is already running using '.build', waiting")
        XCTAssertTrue(notice.contains("PID 37990"), notice)
        XCTAssertTrue(notice.contains("wait_command"), notice)

        let log = workspace.appendingPathComponent("job.log")
        try "build done".write(to: log, atomically: true, encoding: .utf8)
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["1"]
        try sleeper.run()
        let result = WorkspaceTools.execute(
            AgentToolCall(id: "w", name: "wait_command", arguments: #"{"pid":\#(sleeper.processIdentifier),"log_path":"job.log","timeout_seconds":10}"#),
            workspace: workspace,
            conversationID: "test"
        )
        sleeper.waitUntilExit()
        XCTAssertTrue(result.contains("exited after"), result)
        XCTAssertTrue(result.contains("build done"), result)
    }

    func testPagedProjectFileCanBeEditedAndReread() throws {
        let original = (1...240).map { "line-\($0):" + String(repeating: "x", count: 1_000) }.joined(separator: "\n")
        let file = workspace.appendingPathComponent("project.swift")
        try original.write(to: file, atomically: true, encoding: .utf8)
        var start = 1
        while start <= 240 {
            let args = "{\"path\":\"project.swift\",\"offset\":\(start),\"limit\":20}"
            let page = read(args)
            XCTAssertEqual(EconomyToolOutputPolicy.normalize(page, toolName: "read_file", arguments: args), page)
            if start == 1 { XCTAssertTrue(write("project.swift", "blind overwrite").lowercased().contains("read")) }
            if let marker = page.range(of: "[truncated] Continue with offset: "),
               let next = Int(page[marker.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)) {
                XCTAssertGreaterThan(next, start)
                start = next
            } else { start += 20 }
        }
        let args = #"{"path":"project.swift","edits":[{"old_text":"line-180:","new_text":"fixed-180:"}]}"#
        let result = WorkspaceTools.execute(AgentToolCall(id: "edit", name: "edit_file", arguments: args), workspace: workspace, conversationID: "test")
        XCTAssertTrue(result.hasPrefix("Edited"), result)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), original.replacingOccurrences(of: "line-180:", with: "fixed-180:"))
        XCTAssertTrue(read(#"{"path":"project.swift","offset":180,"limit":1}"#).hasPrefix("fixed-180:"))
    }

    func testNarrowReadDoesNotEraseAnEarlierCompleteRead() throws {
        try "one\ntwo\nthree".write(to: workspace.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        _ = read(#"{"path":"a.txt"}"#)
        _ = read(#"{"path":"a.txt","offset":2,"limit":1}"#)
        XCTAssertTrue(write("a.txt", "updated").contains("a.txt"))
    }

    func testPagesFromDifferentVersionsCannotAuthorizeAnEdit() throws {
        let file = workspace.appendingPathComponent("a.txt")
        try "one\ntwo\nthree\nfour".write(to: file, atomically: true, encoding: .utf8)
        _ = read(#"{"path":"a.txt","limit":2}"#)
        try "changed\ntwo\nthree\nfour".write(to: file, atomically: true, encoding: .utf8)
        _ = read(#"{"path":"a.txt","offset":3}"#)
        XCTAssertTrue(write("a.txt", "blind overwrite").lowercased().contains("read"))
        _ = read(#"{"path":"a.txt","limit":2}"#)
        XCTAssertTrue(write("a.txt", "updated").contains("a.txt"))
    }

    func testOffsetAndLimitPageThroughAFile() throws {
        let lines = (1...10).map { "line \($0)" }.joined(separator: "\n")
        try lines.write(to: workspace.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)

        XCTAssertEqual(read(#"{"path":"a.txt","offset":3,"limit":2}"#), "line 3\nline 4")
        XCTAssertEqual(read(#"{"path":"a.txt","limit":1}"#), "line 1")
        XCTAssertTrue(read(#"{"path":"a.txt","offset":99}"#).contains("10"))
    }

    func testALongFileIsCutOnALineAndNamesTheNextOffset() throws {
        let line = String(repeating: "x", count: 1_000)
        let lines = (1...200).map { _ in line }.joined(separator: "\n")
        try lines.write(to: workspace.appendingPathComponent("big.txt"), atomically: true, encoding: .utf8)

        let first = read(#"{"path":"big.txt"}"#)
        XCTAssertLessThanOrEqual(first.utf8.count, WorkspaceTools.readMaxBytes + 200)
        // Every emitted line is whole.
        XCTAssertTrue(first.components(separatedBy: "\n").allSatisfy { $0.isEmpty || $0.count == 1_000 || $0.hasPrefix("[") })
        XCTAssertTrue(first.contains("offset"), "a cut read must name the line to continue from")

        // A partial read is not a licence to rewrite the file.
        XCTAssertTrue(write("big.txt", "short").lowercased().contains("read"))
    }

    func testWriteRequiresAReadOfAnExistingFile() throws {
        let file = workspace.appendingPathComponent("b.txt")
        try "original".write(to: file, atomically: true, encoding: .utf8)

        XCTAssertTrue(write("b.txt", "replaced").lowercased().contains("read"))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "original")

        _ = read(#"{"path":"b.txt"}"#)
        XCTAssertTrue(write("b.txt", "replaced").contains("b.txt"))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "replaced")
    }

    func testGrepBudgetRejectsOversizedAndExhaustedInputs() {
        XCTAssertEqual(
            WorkspaceTools.grepBudgetDecision(fileBytes: WorkspaceTools.grepMaxFileBytes, remainingBytes: WorkspaceTools.grepMaxTotalBytes),
            .read(WorkspaceTools.grepMaxFileBytes)
        )
        XCTAssertEqual(
            WorkspaceTools.grepBudgetDecision(fileBytes: WorkspaceTools.grepMaxFileBytes + 1, remainingBytes: WorkspaceTools.grepMaxTotalBytes),
            .skip
        )
        XCTAssertEqual(WorkspaceTools.grepBudgetDecision(fileBytes: 1, remainingBytes: 0), .stop)
        XCTAssertEqual(WorkspaceTools.grepBudgetDecision(fileBytes: nil, remainingBytes: 10), .skip)
    }

    func testGrepReportsTruncationWhenOversizedFilesAreSkipped() throws {
        let large = workspace.appendingPathComponent("a-large.txt")
        try String(repeating: "x", count: WorkspaceTools.grepMaxFileBytes + 1)
            .write(to: large, atomically: true, encoding: .utf8)
        try "needle".write(to: workspace.appendingPathComponent("b-match.txt"), atomically: true, encoding: .utf8)

        let result = grep("needle")
        XCTAssertTrue(result.contains("b-match.txt:1:needle"), result)
        XCTAssertTrue(result.contains(AppCopy.text("tool.truncated")), result)
    }

    func testGrepNoMatchesStillReportsWhenTheScanWasTruncated() throws {
        let large = workspace.appendingPathComponent("a-large.txt")
        try String(repeating: "x", count: WorkspaceTools.grepMaxFileBytes + 1)
            .write(to: large, atomically: true, encoding: .utf8)

        let result = grep("needle")
        XCTAssertTrue(result.contains(AppCopy.text("tool.noMatches")), result)
        XCTAssertTrue(result.contains(AppCopy.text("tool.truncated")), result)
    }

    func testWriteIsRefusedWhenTheFileChangedOnDiskSinceTheRead() throws {
        let file = workspace.appendingPathComponent("c.txt")
        try "one".write(to: file, atomically: true, encoding: .utf8)
        _ = read(#"{"path":"c.txt"}"#)
        try "changed by someone else".write(to: file, atomically: true, encoding: .utf8)

        XCTAssertTrue(write("c.txt", "mine").lowercased().contains("changed"))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "changed by someone else")
    }

    func testANewFileNeedsNoRead() {
        XCTAssertTrue(write("new.txt", "hello").contains("new.txt"))
        XCTAssertEqual(read(#"{"path":"new.txt"}"#), "hello")
        // A write refreshes the ledger, so consecutive writes do not need a re-read.
        XCTAssertTrue(write("new.txt", "hello again").contains("new.txt"))
    }

    func testAdditionalReadRootIsReadableButNotWritable() throws {
        let extra = workspace.deletingLastPathComponent()
            .appendingPathComponent("WorkspaceReadRoot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: extra, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: extra) }
        let file = extra.appendingPathComponent("notes.txt")
        try "extra root".write(to: file, atomically: true, encoding: .utf8)

        let list = WorkspaceTools.execute(
            AgentToolCall(id: "list", name: "list_files", arguments: "{\"path\":\"\(extra.path)\"}"),
            workspace: workspace, conversationID: "test",
            readRoots: [extra]
        )
        XCTAssertTrue(list.contains("notes.txt"))

        let contents = WorkspaceTools.execute(
            AgentToolCall(id: "read", name: "read_file", arguments: "{\"path\":\"\(file.path)\"}"),
            workspace: workspace, conversationID: "test",
            readRoots: [extra]
        )
        XCTAssertEqual(contents, "extra root")

        let write = WorkspaceTools.execute(
            AgentToolCall(
                id: "write",
                name: "write_file",
                arguments: "{\"path\":\"\(file.path)\",\"content\":\"changed\"}"
            ),
            workspace: workspace, conversationID: "test",
            readRoots: [extra]
        )
        XCTAssertTrue(write.lowercased().contains("outside"))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "extra root")
    }
}

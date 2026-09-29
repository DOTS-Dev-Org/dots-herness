// Copyright (c) 2026 DOTS
// Scope, planning and run loop of the delegated subagent. Pure logic, no network.

import XCTest
import Foundation
import HarnessPluginKit
@testable import DotsHarnessCore

final class DelegateTests: XCTestCase {
    private func scope(_ paths: String...) throws -> DelegateScope {
        try XCTUnwrap(DelegateScope(paths: paths))
    }

    private func request(_ paths: [String], mode: DelegateMode = .write) throws -> DelegateRequest {
        DelegateRequest(task: "do it", mode: mode, scope: try XCTUnwrap(DelegateScope(paths: paths)))
    }

    private func call(_ arguments: String) -> AgentToolCall {
        AgentToolCall(id: "d1", name: "delegate", arguments: arguments)
    }

    // MARK: Scope

    func testScopeAllowsOnlyThePathsItNames() throws {
        let scope = try scope("src/auth", "docs/readme.md")
        XCTAssertTrue(scope.allows("src/auth/login.swift"))
        XCTAssertTrue(scope.allows("./src/auth/deep/file.swift"))
        XCTAssertTrue(scope.allows("docs/readme.md"))
        XCTAssertFalse(scope.allows("src/authors.swift"), "a prefix is not a path component")
        XCTAssertFalse(scope.allows("src/other/file.swift"))
        XCTAssertFalse(scope.allows("../outside.swift"))
        XCTAssertFalse(scope.allows("/etc/passwd"))
        XCTAssertFalse(scope.allows("src/auth/../other/file.swift"))
    }

    func testScopeRejectsPathsThatCouldLeaveTheWorkspaceOrTouchToolState() {
        for bad in ["/abs", "~/x", "../up", "a/../b", ".git", ".git/config", ".mem/x", "  "] {
            XCTAssertNil(DelegateScope(paths: [bad]), bad)
        }
        XCTAssertNil(DelegateScope(paths: []))
    }

    func testWholeWorkspaceScopeStillProtectsGitAndMem() throws {
        let scope = try scope(".")
        XCTAssertTrue(scope.coversWorkspace)
        XCTAssertTrue(scope.allows("any/file.swift"))
        XCTAssertFalse(scope.allows(".git/config"))
        XCTAssertFalse(scope.allows(".mem/state.json"))
    }

    func testOverlapIsComponentWiseAndCaseInsensitive() throws {
        XCTAssertTrue(try scope("src").overlaps(scope("src/a")))
        XCTAssertTrue(try scope("src/a").overlaps(scope("src")))
        XCTAssertTrue(try scope("Src").overlaps(scope("src/a")), "one directory on a case-insensitive volume")
        XCTAssertTrue(try scope(".").overlaps(scope("docs")))
        XCTAssertFalse(try scope("src/a").overlaps(scope("src/b")))
        XCTAssertFalse(try scope("src").overlaps(scope("srcs")))
    }

    // MARK: Request

    func testParseRequiresATaskAndPaths() {
        func message(_ arguments: String) -> String? {
            if case .failure(let error) = DelegateRequest.parse(call(arguments)) { return error.message }
            return nil
        }
        XCTAssertNotNil(message("not json"))
        XCTAssertNotNil(message("{\"paths\":[\"a\"]}"))
        XCTAssertNotNil(message("{\"task\":\"x\"}"))
        XCTAssertNotNil(message("{\"task\":\"x\",\"paths\":[]}"))
        XCTAssertNotNil(message("{\"task\":\"x\",\"paths\":[\"../a\"]}"))
        XCTAssertNotNil(message("{\"task\":\"x\",\"paths\":[\"a\"],\"mode\":\"root\"}"))
    }

    func testParseDefaultsToWriteAndFullIsExclusive() throws {
        guard case .success(let write) = DelegateRequest.parse(call("{\"task\":\"x\",\"paths\":[\"a\"]}")) else {
            return XCTFail("expected success")
        }
        XCTAssertEqual(write.mode, .write)
        XCTAssertFalse(write.isExclusive)
        guard case .success(let full) = DelegateRequest.parse(call("{\"task\":\"x\",\"paths\":[\"a\"],\"mode\":\"full\"}")) else {
            return XCTFail("expected success")
        }
        XCTAssertTrue(full.isExclusive)
        XCTAssertTrue(try request(["."]).isExclusive)
    }

    // MARK: Planner

    func testDisjointScopesRunTogether() throws {
        let batches = DelegatePlanner.batches([try request(["a"]), try request(["b"]), try request(["c"])])
        XCTAssertEqual(batches, [[0, 1, 2]])
    }

    func testOverlappingScopesRunOneAfterAnother() throws {
        let batches = DelegatePlanner.batches([try request(["src"]), try request(["src/a"]), try request(["docs"])])
        XCTAssertEqual(batches, [[0], [1, 2]], "the overlapping one waits; a disjoint one may join the next batch")
    }

    func testExclusiveDelegateRunsAlone() throws {
        let batches = DelegatePlanner.batches([
            try request(["a"]), try request(["b"], mode: .full), try request(["c"]), try request(["d"]),
        ])
        XCTAssertEqual(batches, [[0], [1], [2, 3]])
    }

    func testEveryRequestLandsInExactlyOneBatch() throws {
        let requests = [try request(["a"]), try request(["a/x"]), try request(["b"], mode: .full), try request(["."])]
        let flat = DelegatePlanner.batches(requests).flatMap { $0 }
        XCTAssertEqual(flat.sorted(), [0, 1, 2, 3])
    }

    // MARK: Tools and gate

    func testSubagentToolsNeverIncludeDelegationOrExplore() {
        let names = WorkspaceTools.readOnlyDefinitions.map(\.name)
        XCTAssertFalse(names.contains("delegate"))
        XCTAssertFalse(names.contains("explore"))
    }

    func testGateServesOneHolderAtATime() async {
        let gate = DelegateGate()
        let order = Order()
        await gate.acquire()
        let waiter = Task {
            await gate.acquire()
            order.add("second")
            await gate.release()
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        order.add("first")
        await gate.release()
        await waiter.value
        XCTAssertEqual(order.values, ["first", "second"])
    }

    // MARK: Run loop

    private final class Order: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String] = []
        func add(_ value: String) { lock.withLock { stored.append(value) } }
        var values: [String] { lock.withLock { stored } }
    }

    private final class Script: @unchecked Sendable {
        private let lock = NSLock()
        private var responses: [AgentResponse]
        private(set) var requests = 0
        init(_ responses: [AgentResponse]) { self.responses = responses }
        func next() -> AgentResponse {
            lock.withLock {
                requests += 1
                return responses.isEmpty ? AgentResponse(message: AgentMessage(role: .assistant, content: "Status: partial")) : responses.removeFirst()
            }
        }
    }

    private func reply(_ text: String, calls: [AgentToolCall] = []) -> AgentResponse {
        AgentResponse(message: AgentMessage(role: .assistant, content: text, toolCalls: calls))
    }

    func testRunExecutesToolCallsAndReportsWhatTheLedgerSaw() async throws {
        let request = try request(["src"])
        let ledger = DelegateLedger()
        let script = Script([
            reply("", calls: [AgentToolCall(id: "1", name: "write_file", arguments: "{}")]),
            reply("## Done\n- src/a.swift\n\n## Unresolved\nNone\n\nStatus: answered"),
        ])
        let outcome = await DelegateTool.run(
            request,
            tools: [],
            complete: { _, _ in script.next() },
            ledger: ledger,
            execute: { _ in
                ledger.noteWrite("src/a.swift")
                return "wrote"
            }
        )
        XCTAssertEqual(outcome.steps, 2)
        XCTAssertTrue(outcome.answered)
        XCTAssertEqual(outcome.written, ["src/a.swift"])
        XCTAssertTrue(outcome.toolResult.contains("Files written by the subagent: src/a.swift"))
    }

    func testRunWithoutStatusLineIsTreatedAsPartial() async throws {
        let script = Script([reply("finished, trust me")])
        let outcome = await DelegateTool.run(
            try request(["src"]), tools: [], complete: { _, _ in script.next() },
            ledger: DelegateLedger(), execute: { _ in "" }
        )
        XCTAssertFalse(outcome.answered)
        XCTAssertTrue(outcome.toolResult.contains("unfinished"))
    }

    func testRunStopsAtTheStepLimitAndAsksForAReport() async throws {
        let looping = reply("", calls: [AgentToolCall(id: "1", name: "read_file", arguments: "{}")])
        let script = Script(Array(repeating: looping, count: DelegateTool.maxSteps) + [reply("Status: partial")])
        let outcome = await DelegateTool.run(
            try request(["src"]), tools: [], complete: { _, _ in script.next() },
            ledger: DelegateLedger(), execute: { _ in "ok" }
        )
        XCTAssertTrue(outcome.hitStepLimit)
        XCTAssertFalse(outcome.answered)
        XCTAssertEqual(script.requests, DelegateTool.maxSteps + 1)
    }

    func testBlockedWritesAreSurfacedToTheParent() async throws {
        let ledger = DelegateLedger()
        ledger.noteBlocked()
        let script = Script([reply("Status: answered")])
        let outcome = await DelegateTool.run(
            try request(["src"]), tools: [], complete: { _, _ in script.next() },
            ledger: ledger, execute: { _ in "" }
        )
        XCTAssertTrue(outcome.toolResult.contains("outside its paths"))
    }

    func testRefusedRequestReturnsItsMessageUnchanged() {
        let refused = DelegateTool.Outcome.refused("Tool error: nope")
        XCTAssertEqual(refused.toolResult, "Tool error: nope")
    }
}

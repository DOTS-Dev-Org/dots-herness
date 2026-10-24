// Copyright (c) 2026 DOTS

import XCTest
import Foundation
import HarnessPluginKit
import PluginRuntime
@testable import DotsHarnessCore

final class DelegateToolTests: XCTestCase {
    private var workspace: URL!

    override func setUpWithError() throws {
        workspace = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("delegate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace.appendingPathComponent("ui"), withIntermediateDirectories: true)
        try "old".write(to: workspace.appendingPathComponent("ui/a.txt"), atomically: true, encoding: .utf8)
        try "keep".write(to: workspace.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: workspace) }

    private func call(_ name: String, _ arguments: [String: Any], id: String = UUID().uuidString) -> AgentToolCall {
        let data = try! JSONSerialization.data(withJSONObject: arguments)
        return AgentToolCall(id: id, name: name, arguments: String(decoding: data, as: UTF8.self))
    }

    /// A provider that plays back one scripted assistant turn per step.
    private func script(_ turns: [[AgentToolCall]], final: String, efforts: Efforts? = nil) -> DelegateTool.Complete {
        let steps = Steps()
        return { _, _, effort, light in
            await efforts?.append(light ? "light:" + effort : effort)
            let index = await steps.next()
            return AgentResponse(message: AgentMessage(
                role: .assistant,
                content: index < turns.count ? "" : final,
                toolCalls: index < turns.count ? Self.gateway(turns[index]) : []
            ))
        }
    }

    private static func gateway(_ calls: [AgentToolCall]) -> [AgentToolCall] {
        calls.flatMap { call -> [AgentToolCall] in
            let query = try! JSONSerialization.data(withJSONObject: ["query": call.name])
            let args = try! JSONSerialization.data(withJSONObject: ["name": call.name, "arguments": call.arguments])
            return [AgentToolCall(id: "discover-" + call.id, name: "discover_tools", arguments: String(decoding: query, as: UTF8.self)), AgentToolCall(id: call.id, name: "invoke_tool", arguments: String(decoding: args, as: UTF8.self))]
        }
    }

    private func execute(scope: String) -> DelegateTool.Execute {
        let workspace = workspace!
        return { call in WorkspaceTools.execute(call, workspace: workspace, conversationID: scope) }
    }

    func testAssignmentsAreNormalizedAndOverlapIsFound() throws {
        let assignment = try DelegateTool.assignment(
            from: call("delegate", ["plan": "p", "task": "do it", "files": ["./ui/../ui/a.txt", "ui/a.txt", "docs/"]]),
            workspace: workspace
        ).get()
        XCTAssertEqual(assignment.claims, ["ui/a.txt", "docs"], "one file named two ways is one claim")

        XCTAssertNotNil(DelegateTool.overlap(["ui"], ["ui/a.txt"]), "a directory owns the files under it")
        XCTAssertNotNil(DelegateTool.overlap(["ui/a.txt"], ["ui/a.txt"]))
        XCTAssertNotNil(DelegateTool.overlap(["."], ["b.txt"]), "the workspace root owns everything")
        XCTAssertNil(DelegateTool.overlap(["ui"], ["ui2/a.txt", "b.txt"]), "a shared name prefix is not a shared directory")

        for bad in [["task": "x", "files": [String]()], ["task": "", "files": ["a"]], ["task": "x", "files": ["../outside.txt"]]] as [[String: Any]] {
            guard case .failure = DelegateTool.assignment(from: call("delegate", bad), workspace: workspace) else {
                return XCTFail("\(bad) must be refused")
            }
        }
    }

    func testSubagentEditsItsOwnFilesAndNothingElse() async throws {
        let complete = script([
            [call("read_file", ["path": "ui/a.txt"]), call("read_file", ["path": "b.txt"])],
            [
                call("edit_file", ["path": "ui/a.txt", "edits": [["old_text": "old", "new_text": "new"]]]),
                call("write_file", ["path": "b.txt", "content": "stolen"]),
                call("write_file", ["path": "ui/new.txt", "content": "made"]),
                call("run_command", ["command": "rm -rf ."]),
                call("remove_file", ["path": "ui/a.txt", "reason": "x", "referenceTerms": "x"]),
            ],
        ], final: "## Changes\n- ui/a.txt: updated\n\n## Unresolved\nb.txt is not mine\n\nStatus: done")
        let outcome = await DelegateTool.run(
            DelegateTool.Assignment(task: "update the ui", claims: ["ui"]),
            complete: complete, execute: execute(scope: "delegate-1"), workspace: workspace
        )

        XCTAssertEqual(try String(contentsOf: workspace.appendingPathComponent("ui/a.txt"), encoding: .utf8), "new")
        XCTAssertEqual(try String(contentsOf: workspace.appendingPathComponent("ui/new.txt"), encoding: .utf8), "made")
        XCTAssertEqual(
            try String(contentsOf: workspace.appendingPathComponent("b.txt"), encoding: .utf8), "keep",
            "a file outside the assignment must stay untouched even after the subagent read it"
        )
        XCTAssertEqual(outcome.written, ["ui/a.txt", "ui/new.txt"], "written is what changed on disk")
        XCTAssertTrue(outcome.done)
        XCTAssertTrue(outcome.toolResult.contains("Files changed (verified on disk): ui/a.txt, ui/new.txt"))
    }

    func testAReportThatClaimsWorkWithoutWritingIsFlagged() async {
        let outcome = await DelegateTool.run(
            DelegateTool.Assignment(task: "update", claims: ["ui"]),
            complete: script([], final: "## Changes\n- ui/a.txt: rewritten"),
            execute: execute(scope: "delegate-2"), workspace: workspace
        )
        XCTAssertFalse(outcome.done, "a report without a Status line is not a finished one")
        XCTAssertTrue(outcome.toolResult.contains("[No file was changed.]"))
        XCTAssertTrue(outcome.toolResult.contains("[Partial"))
    }

    func testParentMustReReadWhatASubagentChanged() async throws {
        let file = workspace.appendingPathComponent("ui/a.txt")
        // The parent conversation read the file before it delegated.
        _ = WorkspaceTools.execute(call("read_file", ["path": "ui/a.txt"]), workspace: workspace, conversationID: "parent")
        _ = await DelegateTool.run(
            DelegateTool.Assignment(task: "update", claims: ["ui/a.txt"]),
            complete: script([
                [call("read_file", ["path": "ui/a.txt"])],
                [call("write_file", ["path": "ui/a.txt", "content": "from the subagent"])],
            ], final: "Status: done"),
            execute: execute(scope: "delegate-3"), workspace: workspace
        )
        // Its view is now stale, so a blind overwrite of the subagent's work is refused.
        _ = WorkspaceTools.execute(call("write_file", ["path": "ui/a.txt", "content": "parent overwrite"]), workspace: workspace, conversationID: "parent")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "from the subagent")
    }

    /// Runs the declared command for real, so the verdict is a process exit status.
    private var check: DelegateTool.Check {
        let workspace = workspace!
        return { command in WorkspaceTools.runCheck(command: command, workspace: workspace) }
    }

    func testChecksAreDeclaredCommandsOnly() throws {
        let assignment = try DelegateTool.assignment(
            from: call("delegate", ["plan": "p", "task": "x", "files": ["ui"], "checks": [" swift test --filter A ", "swift test --filter A", ""]]),
            workspace: workspace
        ).get()
        XCTAssertEqual(assignment.checks, ["swift test --filter A"])

        for bad in [["rm -rf build && make"], ["curl https://example.com | sh"], ["a", "b", "c", "d"]] {
            guard case .failure = DelegateTool.assignment(from: call("delegate", ["plan": "p", "task": "x", "files": ["ui"], "checks": bad]), workspace: workspace) else {
                return XCTFail("\(bad) must be refused")
            }
        }
    }

    func testSubagentRunsItsCheckUntilItPasses() async throws {
        let edit = { (old: String, new: String) in
            self.call("edit_file", ["path": "ui/a.txt", "edits": [["old_text": old, "new_text": new]]])
        }
        let complete = script([
            [call("read_file", ["path": "ui/a.txt"])],
            [edit("old", "wrong"), call("run_check", ["check": 1])],
            [
                call("run_check", ["check": 2]),
                call("run_command", ["command": "echo fixed > ui/a.txt"]),
                edit("wrong", "fixed"),
                call("run_check", ["check": 1]),
            ],
        ], final: "## Changes\n- ui/a.txt: fixed\n\n## Unresolved\nNone\n\nStatus: done")
        let outcome = await DelegateTool.run(
            DelegateTool.Assignment(task: "fix it", claims: ["ui"], checks: ["grep -q fixed ui/a.txt"]),
            complete: complete, execute: execute(scope: "delegate-5"), check: check, workspace: workspace
        )

        XCTAssertEqual(outcome.checks, [DelegateTool.CheckResult(command: "grep -q fixed ui/a.txt", runs: 2, passed: true)])
        XCTAssertTrue(outcome.verified)
        XCTAssertTrue(outcome.toolResult.contains("- grep -q fixed ui/a.txt: passed"))
        XCTAssertFalse(outcome.toolResult.contains("[Unverified"))
    }

    func testAPassBeforeTheLastEditProvesNothing() async throws {
        let complete = script([
            [call("read_file", ["path": "ui/a.txt"])],
            [call("run_check", ["check": 1])],
            [call("write_file", ["path": "ui/a.txt", "content": "broken"])],
        ], final: "Status: done")
        let outcome = await DelegateTool.run(
            DelegateTool.Assignment(task: "x", claims: ["ui"], checks: ["grep -q old ui/a.txt", "true"]),
            complete: complete, execute: execute(scope: "delegate-6"), check: check, workspace: workspace
        )

        XCTAssertFalse(outcome.verified, "the check ran against bytes that are gone")
        XCTAssertTrue(outcome.toolResult.contains("not run again after the last edit"))
        XCTAssertTrue(outcome.toolResult.contains("- true: never run"))
        XCTAssertTrue(outcome.toolResult.contains("[Unverified"))
    }

    func testWithoutAHostCheckRunnerNothingIsOffered() async {
        let outcome = await DelegateTool.run(
            DelegateTool.Assignment(task: "x", claims: ["ui"], checks: ["true"]),
            complete: script([[call("run_check", ["check": 1])]], final: "Status: done"),
            execute: execute(scope: "delegate-7"), workspace: workspace
        )
        XCTAssertTrue(outcome.checks.isEmpty)
        XCTAssertFalse(outcome.verified)
    }

    func testChecksOfOneTurnRunOneAtATime() async {
        let queue = CheckQueue()
        let running = Steps()
        let overlapped = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<4 {
                group.addTask {
                    await queue.acquire()
                    let alone = await running.next() == 0
                    try? await Task.sleep(nanoseconds: 20_000_000)
                    await running.reset()
                    await queue.release()
                    return !alone
                }
            }
            return await group.contains(true)
        }
        XCTAssertFalse(overlapped)
    }

    @MainActor
    func testDelegateFollowsTheSubagentSwitchAndPlanMode() {
        let router = RouterController(baseURL: "http://127.0.0.1:1")
        let root = workspace.appendingPathComponent("support", isDirectory: true)
        let host = NativeAgentHost(paths: SupportPaths(
            root: root,
            plugins: root.appendingPathComponent("plugins", isDirectory: true),
            presets: root.appendingPathComponent("presets", isDirectory: true),
            settings: root.appendingPathComponent("settings.json"),
            hostPatch: root.appendingPathComponent("host.patch.yml"),
            trust: root.appendingPathComponent("trust.json"),
            models: root.appendingPathComponent("models", isDirectory: true),
            runtime: root.appendingPathComponent("runtime", isDirectory: true)
        ), router: router)
        XCTAssertTrue(host.agentTools(workspace: workspace).defs.contains { $0.name == "delegate" }, "on until the user chooses")
        router.usageMode = .economy
        XCTAssertTrue(host.agentTools(workspace: workspace).defs.contains { $0.name == "delegate" }, "on in Economy too")
        router.subagentsPreference = false
        XCTAssertFalse(host.agentTools(workspace: workspace).defs.contains { $0.name == "delegate" })
        XCTAssertTrue(NativeAgentHost.planWithholds("delegate"), "plan mode must not hand out edits")
        XCTAssertEqual(NativeAgentHost.risk("delegate"), .workspaceMutation, "delegating edits asks like an edit")
    }

    func testEffortCapsAutomaticAndHighLevels() {
        XCTAssertEqual(DelegateTool.effort(selected: "", economy: false), "medium", "Auto must not become the highest level")
        XCTAssertEqual(DelegateTool.effort(selected: "max", economy: false), "medium")
        XCTAssertEqual(DelegateTool.effort(selected: "low", economy: false), "low")
        XCTAssertEqual(DelegateTool.effort(selected: "", economy: true), "low")
    }

    func testParentChoosesEffortWithinTheUsersLevel() throws {
        XCTAssertEqual(DelegateTool.effort(selected: "max", economy: false, requested: "high"), "high")
        XCTAssertEqual(DelegateTool.effort(selected: "", economy: false, requested: "high"), "high", "Auto allows high")
        XCTAssertEqual(DelegateTool.effort(selected: "medium", economy: false, requested: "high"), "medium", "never above the user")
        XCTAssertEqual(DelegateTool.effort(selected: "high", economy: false, requested: "low"), "low")
        XCTAssertEqual(DelegateTool.effort(selected: "max", economy: true, requested: "high"), "medium", "Economy caps at medium")
        XCTAssertEqual(DelegateTool.raised("medium", ceiling: "max"), "high")
        XCTAssertEqual(DelegateTool.raised("medium", ceiling: "medium"), "medium")

        let parsed = try DelegateTool.assignment(from: call("delegate", ["plan": "p", "task": "x", "files": ["ui"], "effort": "High"]), workspace: workspace).get()
        XCTAssertEqual(parsed.effort, "high")
        guard case .failure = DelegateTool.assignment(from: call("delegate", ["plan": "p", "task": "x", "files": ["ui"], "effort": "max"]), workspace: workspace) else {
            return XCTFail("the parent may ask for low, medium or high only")
        }
    }

    func testRepeatedCheckFailuresRaiseEffortOnce() async {
        let efforts = Efforts()
        let complete = script([
            [call("read_file", ["path": "ui/a.txt"])],
            [call("run_check", ["check": 1])],
            [call("run_check", ["check": 1])],
            [call("run_check", ["check": 1])],
            [call("run_check", ["check": 1])],
        ], final: "Status: partial", efforts: efforts)
        let outcome = await DelegateTool.run(
            DelegateTool.Assignment(task: "x", claims: ["ui"], checks: ["false"]),
            complete: complete, execute: execute(scope: "delegate-8"), check: check,
            effort: "low", ceiling: "high", workspace: workspace
        )
        let seen = await efforts.values
        XCTAssertEqual(seen, ["low", "low", "low", "medium", "medium", "medium"], "one level up after two failures, once")
        XCTAssertTrue(outcome.raisedEffort)
        XCTAssertTrue(outcome.toolResult.contains("Effort was raised"))
    }

    func testLightModelNeedsACheck() throws {
        let args: [String: Any] = ["plan": "p", "task": "x", "files": ["ui"], "model": "light"]
        guard case .failure = DelegateTool.assignment(from: call("delegate", args), workspace: workspace) else {
            return XCTFail("light without a check is an unproven edit on a cheaper model")
        }
        var checked = args
        checked["checks"] = ["swift build"]
        XCTAssertTrue(try DelegateTool.assignment(from: call("delegate", checked), workspace: workspace).get().light)
        XCTAssertFalse(try DelegateTool.assignment(from: call("delegate", ["plan": "p", "task": "x", "files": ["ui"]]), workspace: workspace).get().light)
    }

    func testFailingChecksMoveALightPartToTheConversationModelFirst() async {
        let efforts = Efforts()
        let complete = script([
            [call("read_file", ["path": "ui/a.txt"])],
            [call("run_check", ["check": 1])],
            [call("run_check", ["check": 1])],
            [call("run_check", ["check": 1])],
            [call("run_check", ["check": 1])],
        ], final: "Status: partial", efforts: efforts)
        let outcome = await DelegateTool.run(
            DelegateTool.Assignment(task: "x", claims: ["ui"], checks: ["false"], light: true),
            complete: complete, execute: execute(scope: "delegate-9"), check: check,
            effort: "low", ceiling: "high", workspace: workspace
        )
        let seen = await efforts.values
        XCTAssertEqual(seen, ["light:low", "light:low", "light:low", "low", "low", "medium"],
                       "two failures leave the light model, two more raise effort")
        XCTAssertTrue(outcome.ranLight)
        XCTAssertTrue(outcome.leftLight)
        XCTAssertTrue(outcome.toolResult.contains("light model failed"))
    }

    @MainActor
    func testALoneDelegateCallIsRefusedWithoutRunning() async {
        let root = workspace.appendingPathComponent("support", isDirectory: true)
        let host = NativeAgentHost(paths: SupportPaths(
            root: root,
            plugins: root.appendingPathComponent("plugins", isDirectory: true),
            presets: root.appendingPathComponent("presets", isDirectory: true),
            settings: root.appendingPathComponent("settings.json"),
            hostPatch: root.appendingPathComponent("host.patch.yml"),
            trust: root.appendingPathComponent("trust.json"),
            models: root.appendingPathComponent("models", isDirectory: true),
            runtime: root.appendingPathComponent("runtime", isDirectory: true)
        ), router: RouterController(baseURL: "http://127.0.0.1:1"))
        let lone = call("delegate", ["plan": "p", "task": "edit", "files": ["ui/a.txt"]], id: "lone")
        let tasks = await host.startWorkers([lone], workspace: workspace, conversationID: "c", runID: UUID()) { _, _, _, _ in
            XCTFail("a lone part must not reach the model")
            return AgentResponse(message: AgentMessage(role: .assistant, content: ""))
        }
        let outcome = await tasks["lone"]?.value
        XCTAssertEqual(outcome?.steps, 0)
        XCTAssertTrue(outcome?.answer.contains("at least 2") == true)
    }

    func testChangedLinesCountAsReadForTheParent() throws {
        let file = workspace.appendingPathComponent("ui/a.txt")
        let old = (1...20).map { "line \($0)" }.joined(separator: "\n")
        var lines = old.components(separatedBy: "\n")
        lines[9] = "changed"
        try lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(DelegateTool.changedLines(old: old, new: lines.joined(separator: "\n")), 8..<13)

        var outcome = DelegateTool.Outcome(answer: "Status: done")
        outcome.steps = 1
        outcome.done = true
        outcome.written = ["ui/a.txt"]
        outcome.originals = ["ui/a.txt": old]
        DelegateTool.shareChanges(&outcome, workspace: workspace, conversationID: "parent")
        XCTAssertTrue(outcome.toolResult.contains("ui/a.txt lines 8-12 of 20"))
        XCTAssertTrue(outcome.toolResult.contains("changed"))

        let edit = { (old: String, new: String) in
            WorkspaceTools.execute(self.call(FileEditTools.editName, ["path": "ui/a.txt", "edits": [["old_text": old, "new_text": new]]]),
                                   workspace: self.workspace, conversationID: "parent")
        }
        XCTAssertFalse(edit("changed", "edited").contains("Tool error"), "a shown line needs no re-read")
        XCTAssertTrue(try String(contentsOf: file, encoding: .utf8).contains("edited"))
    }
}

private actor Efforts {
    private(set) var values: [String] = []
    func append(_ value: String) { values.append(value) }
}

private actor Steps {
    private var count = 0
    func next() -> Int { defer { count += 1 }; return count }
    func reset() { count = 0 }
}

import XCTest
@testable import HerNessMobile

@MainActor
final class MobileExploreTests: XCTestCase {
    private var catalog: [AgentToolSpec] {
        ["read_file", "list_files", "grep_files", "edit_file", "write_file"].map {
            AgentToolSpec(name: $0, description: $0, schema: ["type": "object", "properties": [:]]) { _ in "" }
        }
    }
    private func reply(_ text: String) -> [String: Any] { ["content": [["type": "text", "text": text]]] }
    private func call(_ name: String, _ input: [String: Any]) -> [String: Any] {
        ["content": [
            ["type": "tool_use", "id": UUID().uuidString, "name": "discover_tools", "input": ["query": name]],
            ["type": "tool_use", "id": UUID().uuidString, "name": "invoke_tool", "input": ["name": name, "arguments": String(decoding: try! JSONSerialization.data(withJSONObject: input), as: UTF8.self)]]
        ]]
    }

    func testReturnsOnlyTheFindingsAndNamesWhatWasRead() async {
        var step = 0
        var invoked: [String] = []
        let result = await MobileExplore.run(task: "where is the loop", catalog: catalog, complete: { messages in
            step += 1
            if step == 1 { return self.call("read_file", ["path": "Sources/Loop.swift"]) }
            // The file body reached the subagent's own transcript, not the caller.
            XCTAssertTrue(String(describing: messages.last).contains("BODY"))
            return self.reply("## Findings\n- Sources/Loop.swift:3 the loop\n\n## Unresolved\nNone\n\nStatus: answered")
        }, invoke: { name, _ in invoked.append(name); return "BODY of the file" })

        XCTAssertEqual(invoked, ["read_file"])
        XCTAssertFalse(result.contains("BODY"))
        XCTAssertTrue(result.contains("Status: answered"))
        XCTAssertTrue(result.contains("Files read: Sources/Loop.swift"))
        XCTAssertFalse(result.contains("[Partial"))
    }

    func testRefusesWriteToolsAndFlagsAnUnverifiedAnswer() async {
        var step = 0
        var invoked = 0
        let result = await MobileExplore.run(task: "change it", catalog: catalog, complete: { _ in
            step += 1
            return step == 1 ? self.call("write_file", ["path": "a", "content": "b"]) : self.reply("done")
        }, invoke: { _, _ in invoked += 1; return "" })

        XCTAssertEqual(invoked, 0, "a read-only subagent must never reach a mutating tool")
        XCTAssertTrue(result.contains("[Partial"))
        XCTAssertTrue(result.contains("[Unverified"))
    }

    func testKeepsALongAnswerInOneRequestAndWrapsUpAtTheStepLimit() async {
        let long = String(repeating: "b", count: MobileExplore.answerTarget * 3)
        var requests = 0
        let kept = await MobileExplore.run(task: "map it", catalog: catalog, complete: { _ in
            requests += 1
            return self.reply(long)
        }, invoke: { _, _ in "" })
        XCTAssertEqual(requests, 1, "a retry to shorten resends the whole transcript")
        XCTAssertTrue(kept.hasPrefix(long))

        var steps = 0
        let limited = await MobileExplore.run(task: "never ends", catalog: catalog, complete: { messages in
            if String(describing: messages.last).contains("step budget is spent") { return self.reply("what was found\nStatus: partial") }
            steps += 1
            return self.call("search_files", ["pattern": "x"])
        }, invoke: { _, _ in "hit" })
        XCTAssertEqual(steps, MobileExplore.maxSteps)
        XCTAssertTrue(limited.contains("what was found"))
        XCTAssertTrue(limited.contains("step limit"))
    }

    func testUsageAddsUpARunsRequestsAndCacheReuse() {
        let usage = SubagentUsage()
        usage.add(["usage": ["input_tokens": 10, "cache_read_input_tokens": 90, "cache_creation_input_tokens": 0]], anthropic: true)
        usage.add(["usage": ["input_tokens": 100, "input_tokens_details": ["cached_tokens": 80]]], anthropic: false)
        XCTAssertEqual(usage.payload, ["requests": "2", "inputTokens": "200", "cachedTokens": "170", "cacheWriteTokens": "0"])
    }

    func testEmptyTaskNeverCallsAProviderAndLightModelFallsBack() async {
        let result = await MobileExplore.run(task: "  ", catalog: catalog, complete: { _ in XCTFail("no provider call"); return [:] }, invoke: { _, _ in "" })
        XCTAssertTrue(result.hasPrefix("Tool error"))
        XCTAssertEqual(MobileExplore.lightModel(among: ["claude-sonnet-4-5", "claude-haiku-4-5"], current: "claude-sonnet-4-5"), "claude-haiku-4-5")
        XCTAssertEqual(MobileExplore.lightModel(among: ["gpt-5.6-luna"], current: "gpt-5.6-luna"), "gpt-5.6-luna")
    }

    func testDelegateWritesOnlyInsideItsAssignment() async {
        XCTAssertEqual(MobileDelegate.claims(from: ["./ui/../ui/a.swift", "ui/a.swift", "docs/"]), ["ui/a.swift", "docs"])
        XCTAssertNil(MobileDelegate.claims(from: ["../outside.swift"]))
        XCTAssertNil(MobileDelegate.claims(from: ["/etc/hosts"]))
        XCTAssertNil(MobileDelegate.claims(from: []))
        XCTAssertFalse(MobileDelegate.covers(["ui"], "ui2/a.swift"), "a shared name prefix is not a shared directory")

        var step = 0
        var invoked: [String] = []
        let result = await MobileDelegate.run(task: "update the ui", claims: ["ui"], catalog: catalog, complete: { _ in
            step += 1
            switch step {
            case 1: return ["content": [
                self.call("write_file", ["path": "ui/a.swift", "content": "new"]),
                self.call("write_file", ["path": "ui/../b.swift", "content": "stolen"]),
                self.call("run_command", ["command": "rm -rf ."]),
            ].flatMap { $0["content"] as? [[String: Any]] ?? [] }]
            default: return self.reply("## Changes\n- ui/a.swift: updated\n\nStatus: done")
            }
        }, invoke: { name, input in
            invoked.append(name + ":" + (input.string("path") ?? ""))
            return "Wrote 3 bytes to ui/a.swift."
        })

        XCTAssertEqual(invoked, ["write_file:ui/a.swift"], "nothing outside the assignment and no command may reach a tool")
        XCTAssertTrue(result.contains("Files changed: ui/a.swift"))
        XCTAssertFalse(result.contains("[Partial"))
    }

    func testSubagentReadsDoNotAuthorizeParentWrites() {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let data = Data("x".utf8)
        ReadLedger.$scope.withValue("explore") { ReadLedger.shared.record(file, data: data) }
        guard case .unread = ReadLedger.shared.state(for: file, data: data) else { return XCTFail("a subagent's read counted as the conversation's") }
        // And the other way round: the subagent cannot write on the conversation's read.
        ReadLedger.shared.record(file, data: data)
        ReadLedger.$scope.withValue("delegate-1") {
            guard case .unread = ReadLedger.shared.state(for: file, data: data) else { return XCTFail("the conversation's read counted as a subagent's") }
        }
    }
}

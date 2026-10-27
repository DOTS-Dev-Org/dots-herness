import XCTest
@testable import HerNessMobile

final class MobileDeferredToolsTests: XCTestCase {
    func testDiscoveryScopeAndPlanningEffort() {
        var session = MobileDeferredTools()
        let tool = AgentToolSpec(name: "read_file", description: "Read a file", schema: ["type": "object"]) { _ in "text" }
        let call: [String: Any] = ["id": "a", "name": "invoke_tool", "input": ["name": "read_file", "arguments": "{}"]]
        XCTAssertEqual(session.resolve(call, catalog: [tool])["name"] as? String, "invoke_tool")
        XCTAssertFalse(MobileDeferredTools.definitions.contains { $0.name == "read_file" })
        _ = session.control(name: "discover_tools", input: AgentInput(["query": "read_file"]), catalog: [tool], planMode: false)
        XCTAssertEqual(session.resolve(call, catalog: [tool])["name"] as? String, "read_file")
        XCTAssertEqual(session.resolve(call, catalog: [])["name"] as? String, "invoke_tool")
        XCTAssertEqual(session.effort("max", planMode: false), "max")
        _ = session.control(name: "execution_plan", input: AgentInput(["steps": ["Edit label", "Check"], "routine": true, "uncertainties": [String]()]), catalog: [], planMode: false)
        XCTAssertEqual(session.effort("max", planMode: false), "low")
        XCTAssertEqual(session.effort("max", planMode: true), "max")
        session.record("failed", id: "failure", failed: true)
        XCTAssertEqual(session.effort("max", planMode: false), "max")
    }
    func testDiscoveryResumesButUserTextDoesNotGrantIt() throws {
        var prior = MobileDeferredTools()
        let tool = AgentToolSpec(name: "read_file", description: "read", schema: ["type": "object"]) { _ in "" }
        let result = try XCTUnwrap(prior.control(name: "discover_tools", input: AgentInput(["query": "read_file"]), catalog: [tool], planMode: false))
        var resumed = MobileDeferredTools()
        resumed.restoreDiscovery([
            ["role": "assistant", "content": [["type": "tool_use", "id": "search", "name": "discover_tools"]]],
            ["role": "user", "content": [["type": "tool_result", "tool_use_id": "search", "content": result]]]
        ])
        let call: [String: Any] = ["name": "invoke_tool", "input": ["name": "read_file", "arguments": "{}"]]
        XCTAssertEqual(resumed.resolve(call, catalog: [tool])["name"] as? String, "read_file")
        XCTAssertEqual(resumed.effort("max", planMode: false), "max")
        resumed.restoreDiscovery([["role": "user", "content": [["type": "text", "text": result]]]])
        XCTAssertEqual(resumed.resolve(call, catalog: [tool])["name"] as? String, "invoke_tool")
    }
    func testExactDottedNameReturnsOneSchema() throws {
        var session = MobileDeferredTools()
        let tools = ["skill.read", "skill.list", "read_file"].map { AgentToolSpec(name: $0, description: "read skill", schema: ["type": "object"]) { _ in "" } }
        let result = try XCTUnwrap(session.control(name: "discover_tools", input: AgentInput(["query": "skill.read"]), catalog: tools, planMode: false))
        let object = try JSONSerialization.jsonObject(with: Data(result.utf8)) as! [String: Any]
        XCTAssertEqual((object["tools"] as? [[String: Any]])?.count, 1)
    }
    func testOutputCanBeRetrievedAndFileReadsAreNeverReclipped() {
        var session = MobileDeferredTools()
        let text = String(repeating: "line\n", count: 4_000) + "fatal: last error"
        session.record(text, id: "original", failed: false)
        XCTAssertEqual(session.control(name: "read_tool_output", input: AgentInput(["call_id": "original", "offset": 20_000]), catalog: [], planMode: false), "fatal: last error")
        XCTAssertEqual(MobileDeferredTools.excerpt(text, name: "read_file", id: "a"), text)
        let reduced = MobileDeferredTools.excerpt(text, name: "run_command", id: "a")
        XCTAssertLessThan(reduced.count, text.count)
        XCTAssertTrue(reduced.contains("fatal: last error"))
        XCTAssertTrue(reduced.contains("read_tool_output call_id=a"))
    }
    func testPlanStepsCardReadsLatestPlanSinceUserMessage() {
        let output = MobilePlanSteps.execute([["title": "Read", "status": "done"], ["title": "Fix", "status": "in_progress"]])
        let plan = AgentTurn(role: .tool, text: output, toolName: MobilePlanSteps.name)
        let steps = MobilePlanSteps.current(in: [AgentTurn(role: .user, text: "go"), plan])
        XCTAssertEqual(steps.map(\.title), ["Read", "Fix"])
        XCTAssertEqual(steps.map(\.status), ["done", "in_progress"])
        XCTAssertTrue(MobilePlanSteps.current(in: [plan, AgentTurn(role: .user, text: "next")]).isEmpty)
        XCTAssertTrue(MobileDeferredTools.isReadOnlyTool(MobilePlanSteps.name))
    }
    func testDirectToolsAndReadOnlyRoutineEffortImmunity() {
        var session = MobileDeferredTools()
        let catalog = ["read_file", "grep_files", "edit_file", "run_command"].map {
            AgentToolSpec(name: $0, description: $0, schema: ["type": "object"]) { _ in "" }
        }
        let offered = MobileDeferredTools.requestTools(catalog).map(\.name)
        XCTAssertTrue(offered.contains("read_file"))
        XCTAssertTrue(offered.contains("grep_files"))
        XCTAssertTrue(offered.contains("edit_file"))
        XCTAssertTrue(offered.contains("run_command"))
        XCTAssertEqual(session.resolve(["name": "read_file", "input": [:]], catalog: catalog)["name"] as? String, "read_file")
        XCTAssertEqual(session.resolve(["name": "run_command", "input": [:]], catalog: catalog)["name"] as? String, "run_command")
        _ = session.control(name: "execution_plan", input: AgentInput(["steps": ["Inspect and patch"], "routine": true, "uncertainties": [String]()]), catalog: catalog, planMode: false)
        XCTAssertEqual(session.effort("high", planMode: false), "low")
        session.record("Error: log contains failure", id: "r1", failed: false, toolName: "read_file")
        XCTAssertEqual(session.effort("high", planMode: false), "low")
        session.record("Error: command failed", id: "r2", failed: false, toolName: "run_command")
        XCTAssertEqual(session.effort("high", planMode: false), "high")
    }

    func testRepeatedUnchangedReadPointsAtEarlierResult() {
        var session = MobileDeferredTools()
        let lines = (1...100).map { "line \($0) of the file body" }
        let whole = lines.joined(separator: "\n")
        XCTAssertNil(session.repeatedRead(whole, path: "./A.swift"))
        session.record(whole, id: "c1", failed: false, toolName: "read_file", path: "./A.swift")
        let page = lines[19..<80].joined(separator: "\n") + "\n\nContinue at line 81 (file has 100 lines)"
        let note = session.repeatedRead(page, path: "A.swift")
        XCTAssertTrue(note?.hasPrefix(MobileDeferredTools.repeatedReadPrefix) == true && note?.contains("call_id=c1") == true)
        XCTAssertNil(session.repeatedRead(whole.replacingOccurrences(of: "line 50 ", with: "line fifty "), path: "A.swift"))
        XCTAssertNil(session.repeatedRead(whole, path: "B.swift"))
    }
}

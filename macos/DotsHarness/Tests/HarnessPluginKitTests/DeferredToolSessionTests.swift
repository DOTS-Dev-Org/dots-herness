import Foundation
import XCTest
import HarnessPluginKit
import PluginRuntime
@testable import DotsHarnessCore

final class DeferredToolSessionTests: XCTestCase {
    private let catalog = [AgentToolDefinition(name: "read_file", description: "Read a workspace file", parameters: .object(["type": .string("object"), "properties": .object(["path": .object(["type": .string("string")])])]))]
    private func call(_ name: String, _ arguments: String, id: String = "call-1") -> AgentToolCall { .init(id: id, name: name, arguments: arguments) }
    func testOnlyGatewayIsAdvertisedAndDiscoveryIsRequired() throws {
        var session = DeferredToolSession()
        let invoke = call("invoke_tool", #"{"name":"read_file","arguments":"{\"path\":\"README.md\"}"}"#)
        XCTAssertFalse(DeferredToolSession.definitions.contains { $0.name == "read_file" })
        // A direct tool wrapped in invoke_tool runs without a discovery round.
        XCTAssertEqual(session.resolve(invoke, catalog: catalog).name, "read_file")
        let deferred = AgentToolDefinition(name: "remove_file", description: "remove", parameters: .object(["type": .string("object")]))
        let invokeDeferred = call("invoke_tool", #"{"name":"remove_file","arguments":"{}"}"#)
        XCTAssertEqual(session.resolve(invokeDeferred, catalog: [deferred]).name, "invoke_tool")
        _ = session.control(call("discover_tools", #"{"query":"remove_file"}"#), catalog: [deferred], planMode: false)
        XCTAssertEqual(session.resolve(invokeDeferred, catalog: [deferred]).name, "remove_file")
        let changedDeferred = AgentToolDefinition(name: "remove_file", description: "changed", parameters: .object(["type": .string("array")]))
        XCTAssertEqual(session.resolve(invokeDeferred, catalog: [changedDeferred]).name, "invoke_tool")
        // A core tool is sent with its schema and called directly, but only while the catalog offers it.
        XCTAssertEqual(session.resolve(call("read_file", "{}"), catalog: catalog).name, "read_file")
        XCTAssertEqual(session.resolve(call("read_file", "{}"), catalog: []).name, "invoke_tool")
        let command = AgentToolDefinition(name: "run_command", description: "run", parameters: .object(["type": .string("object")]))
        XCTAssertEqual(session.resolve(call("run_command", "{}"), catalog: [command]).name, "run_command")
        let removal = AgentToolDefinition(name: "remove_file", description: "remove", parameters: .object(["type": .string("object")]))
        XCTAssertEqual(session.resolve(call("remove_file", "{}"), catalog: [removal]).name, "invoke_tool")
        let result = try XCTUnwrap(session.control(call("discover_tools", #"{"query":"read_file"}"#), catalog: catalog, planMode: false))
        XCTAssertTrue(result.contains("parameters"))
        let resolved = session.resolve(invoke, catalog: catalog)
        XCTAssertEqual(resolved.name, "read_file")
        XCTAssertEqual(resolved.id, invoke.id)
        XCTAssertEqual(resolved.arguments, #"{"path":"README.md"}"#)
        XCTAssertEqual(session.resolve(invoke, catalog: []).name, "invoke_tool")
        let changed = [AgentToolDefinition(name: "read_file", description: "changed", parameters: .object(["type": .string("array")]))]
        // Direct tools always carry their current schema, so a changed one still resolves.
        XCTAssertEqual(session.resolve(invoke, catalog: changed).name, "read_file")
    }
    func testSelectedEffortPlansBeforeRoutineExecutionAndReturnsOnFailure() {
        var session = DeferredToolSession()
        XCTAssertEqual(session.effort(selected: "max", planMode: false), "max")
        _ = session.control(call("execution_plan", #"{"steps":["Edit the known label","Run its check"],"routine":true,"uncertainties":[]}"#), catalog: [], planMode: false)
        XCTAssertEqual(session.effort(selected: "max", planMode: false), "low")
        XCTAssertEqual(session.effort(selected: "none", planMode: false), "none")
        XCTAssertEqual(session.effort(selected: "max", planMode: true), "max")
        session.record("Process exited with status 2", callID: "failed")
        XCTAssertEqual(session.effort(selected: "max", planMode: false), "max")
        _ = session.control(call("execution_plan", #"{"steps":["Investigate"],"routine":true,"uncertainties":["Unknown failing path"]}"#), catalog: [], planMode: false)
        XCTAssertEqual(session.effort(selected: "high", planMode: false), "high")
    }
    func testKnownSchemasResumeFromRealDiscoveryResultsOnly() throws {
        let fetch = [AgentToolDefinition(name: "web_fetch", description: "Fetch a URL", parameters: .object(["type": .string("object")]))]
        var prior = DeferredToolSession()
        let search = call("discover_tools", #"{"query":"web_fetch"}"#, id: "search")
        let result = try XCTUnwrap(prior.control(search, catalog: fetch, planMode: false))
        let history = [AgentMessage(role: .assistant, content: "", toolCalls: [search]), AgentMessage(role: .tool, content: result, toolCallID: "search")]
        var resumed = DeferredToolSession()
        resumed.restoreDiscovery(history)
        XCTAssertEqual(resumed.resolve(call("invoke_tool", #"{"name":"web_fetch","arguments":"{}"}"#), catalog: fetch).name, "web_fetch")
        XCTAssertEqual(resumed.effort(selected: "max", planMode: false), "max")
        resumed.restoreDiscovery([AgentMessage(role: .user, content: result)])
        XCTAssertEqual(resumed.resolve(call("invoke_tool", #"{"name":"web_fetch","arguments":"{}"}"#), catalog: fetch).name, "invoke_tool")
    }
    func testExactDottedToolNameDoesNotLoadOtherSchemas() throws {
        var session = DeferredToolSession()
        let tools = ["skill.read", "skill.list", "read_file"].map { AgentToolDefinition(name: $0, description: "read skill", parameters: .object([:])) }
        let result = try XCTUnwrap(session.control(call("discover_tools", #"{"query":"skill.read"}"#), catalog: tools, planMode: false))
        let object = try JSONSerialization.jsonObject(with: Data(result.utf8)) as! [String: Any]
        XCTAssertEqual((object["tools"] as? [[String: Any]])?.count, 1)
        XCTAssertTrue(DeferredToolSession.failed("exit_code: -1"))
        XCTAssertTrue(DeferredToolSession.failed("[check 1 FAILED]"))
    }
    @MainActor
    func testRegisteredCatalogStaysLocalAndProviderFootprintIsBounded() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let paths = SupportPaths(root: root, plugins: root.appendingPathComponent("plugins"), presets: root.appendingPathComponent("presets"), settings: root.appendingPathComponent("settings"), hostPatch: root.appendingPathComponent("host"), trust: root.appendingPathComponent("trust"), models: root.appendingPathComponent("models"), runtime: root.appendingPathComponent("runtime"))
        let host = NativeAgentHost(paths: paths, endpoint: AgentEndpointController(baseURL: "http://127.0.0.1:1", modelID: "test"))
        let catalog = host.agentTools(workspace: root).defs
        let before = AgentContextCompaction.estimateTokens(catalog)
        let after = AgentContextCompaction.estimateTokens(DeferredToolSession.definitions)
        XCTAssertEqual(DeferredToolSession.definitions.count, 5)
        XCTAssertGreaterThan(before, after)
        print("TOOL_CATALOG local_count=\(catalog.count) provider_count=5 estimated_full=\(before) estimated_gateway=\(after)")
        try? FileManager.default.removeItem(at: root)
    }
    func testFullOutputCanBePagedWithoutReexecutingAndSchemasAreNotClipped() throws {
        var session = DeferredToolSession()
        let raw = String(repeating: "line\n", count: 4_000) + "fatal: decisive failure"
        session.record(raw, callID: "original")
        let page = try XCTUnwrap(session.control(call("read_tool_output", #"{"call_id":"original","offset":20000,"limit":100}"#), catalog: [], planMode: false))
        XCTAssertEqual(page, "fatal: decisive failure")
        XCTAssertEqual(EconomyToolOutputPolicy.normalize(raw, toolName: "discover_tools"), raw)
        XCTAssertEqual(EconomyToolOutputPolicy.normalize(raw, toolName: "read_file"), raw)
        let reduced = EconomyToolOutputPolicy.normalize(raw, toolName: "run_command")
        XCTAssertLessThan(reduced.utf8.count, raw.utf8.count)
        XCTAssertTrue(reduced.contains("fatal: decisive failure"))
    }

    func testRepeatedUnchangedReadPointsAtEarlierResult() {
        var session = DeferredToolSession()
        let lines = (1...100).map { "line \($0) of the file body" }
        let whole = lines.joined(separator: "\n")
        let args = #"{"path":"./A.swift"}"#
        XCTAssertNil(session.repeatedRead(whole, arguments: args))
        session.record(whole, callID: "c1", toolName: "read_file", arguments: args)
        let page = lines[19..<80].joined(separator: "\n") + "\n\nContinue at line 81 (file has 100 lines)"
        let note = session.repeatedRead(page, arguments: #"{"path":"A.swift","offset":20}"#)
        XCTAssertTrue(note?.hasPrefix(DeferredToolSession.repeatedReadPrefix) == true)
        XCTAssertTrue(note?.contains("call_id=c1") == true)
        // Changed bytes or another path read normally.
        XCTAssertNil(session.repeatedRead(whole.replacingOccurrences(of: "line 50 ", with: "line fifty "), arguments: args))
        XCTAssertNil(session.repeatedRead(whole, arguments: #"{"path":"B.swift"}"#))
    }

    func testReplyFileLinksResolveToPathsAndWebLinksDoNot() {
        func path(_ link: String) -> String? { AppModel.fileLinkPath(URL(string: link)!) }
        XCTAssertEqual(path("mobile/README.md"), "mobile/README.md")
        XCTAssertEqual(path("mobile/README.md:14"), "mobile/README.md")
        XCTAssertEqual(path("README.md:42:5"), "README.md")
        XCTAssertEqual(path("src/app.ts#L10"), "src/app.ts")
        XCTAssertEqual(path("file:///tmp/a%20b.swift"), "/tmp/a b.swift")
        XCTAssertNil(path("https://example.com/README.md"))
        XCTAssertNil(path("mailto:a@example.com"))
    }
}

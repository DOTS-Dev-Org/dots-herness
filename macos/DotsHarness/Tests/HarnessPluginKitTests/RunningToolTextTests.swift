import XCTest
@testable import DotsHarnessCore

@MainActor
final class RunningToolTextTests: XCTestCase {
    func testRunningToolTextCarriesWhatRan() {
        let command = AgentToolCall(id: "1", name: "run_command", arguments: #"{"command":"ls locales"}"#)
        XCTAssertTrue(NativeAgentHost.runningToolText(command).hasSuffix("\nls locales"))
        let path = AgentToolCall(id: "2", name: "read_file", arguments: #"{"path":"locales/tr.json"}"#)
        XCTAssertTrue(NativeAgentHost.runningToolText(path).hasSuffix("\nlocales/tr.json"))
        let bare = AgentToolCall(id: "3", name: "list_files", arguments: "{}")
        XCTAssertFalse(NativeAgentHost.runningToolText(bare).contains("\n"))
        let search = AgentToolCall(id: "4", name: "grep_files", arguments: #"{"pattern":"activity","path":"Sources"}"#)
        XCTAssertTrue(NativeAgentHost.runningToolText(search).contains(#""pattern":"activity""#))
        let invoke = AgentToolCall(id: "5", name: "invoke_tool", arguments: #"{"arguments":"{\"task\":\"x\"}","name":"explore"}"#)
        XCTAssertTrue(NativeAgentHost.runningToolText(invoke).hasSuffix("\nexplore {\"task\":\"x\"}"))
    }

    func testOnlyPluginAndMCPToolsCountAsExtensions() {
        XCTAssertTrue(NativeAgentHost.isExtensionTool("mcp__github__search"))
        XCTAssertTrue(NativeAgentHost.isExtensionTool("plugin__deploy"))
        XCTAssertFalse(NativeAgentHost.isExtensionTool("run_command"))
    }
}

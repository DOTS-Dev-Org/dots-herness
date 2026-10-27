import Foundation
import XCTest
@testable import HerNessMobile

/// Compaction drops read_file bodies, so the reads it drops must stop authorizing
/// edits and rewrites until the file is read again.
@MainActor
final class MobileCompactionReadsTests: XCTestCase {
    private var base: URL!

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("herness-compaction-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        ReadLedger.shared.reset()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: base)
        ReadLedger.shared.reset()
    }

    private func text(_ role: String, _ value: String) -> [String: Any] {
        ["role": role, "content": [["type": "text", "text": value]]]
    }

    private func context() -> [[String: Any]] {
        let body = String(repeating: "source line\n", count: 20_000)
        return (0..<4).flatMap { turn -> [[String: Any]] in [
            text("user", "turn \(turn)"),
            ["role": "assistant", "content": [["type": "tool_use", "id": "r\(turn)", "name": "read_file", "input": ["path": "kept.txt"]]]],
            ["role": "user", "content": [["type": "tool_result", "tool_use_id": "r\(turn)", "content": body]]],
            text("assistant", "done \(turn)"),
        ] }
    }

    func testCompactionMakesTheAgentReadFilesAgainBeforeEditingThem() async throws {
        let file = base.appendingPathComponent("kept.txt")
        try Data("alpha\nbeta\n".utf8).write(to: file)
        let root = try XCTUnwrap(base)
        let resolve: FileEditTools.PathResolver = { root.appendingPathComponent($0) }
        let replace = [["old_text": "alpha", "new_text": "omega"]]
        _ = try AgentTools.readFile(at: file)
        XCTAssertEqual(ReadLedger.shared.state(for: file, data: try Data(contentsOf: file)), .fresh)

        // No key and no ChatGPT session: the summary request fails before any network
        // call and compaction falls back to its local summary, like an offline device.
        let agent = MobileHarnessRuntime(
            apiKey: { "" }, systemPrompt: { "" },
            stateStore: MobileStateStore(url: base.appendingPathComponent("state.sqlite"))
        )
        agent.provider = "gpt"
        try await agent.compactForTesting(context())

        XCTAssertTrue(agent.transcript.contains { $0.toolName == "context_compacted" })
        XCTAssertEqual(ReadLedger.shared.state(for: file, data: try Data(contentsOf: file)), .unread)
        let refused = await FileEditTools.edit(path: "kept.txt", edits: replace, resolve: resolve)
        XCTAssertTrue(refused.contains("has not been read"), refused)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "alpha\nbeta\n")

        _ = try AgentTools.readFile(at: file)
        let edited = await FileEditTools.edit(path: "kept.txt", edits: replace, resolve: resolve)
        XCTAssertTrue(edited.hasPrefix("Edited"), edited)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "omega\nbeta\n")
    }
}

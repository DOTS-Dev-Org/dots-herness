import XCTest
@testable import DotsHarnessCore

final class CodeGraphEdgeInferenceTests: XCTestCase {
    func testCallsPreferTheSameFileThenAUniqueNamesakeElseNothing() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("graph-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = [
            "A.swift": "func helper() {}\nfunc runA() { helper() }\n",
            "B.swift": "func helper() {}\nfunc runB() { lonely() }\n",
            "C.swift": "func lonely() {}\nfunc runC() { helper() }\n",
        ]
        for (name, source) in files {
            try source.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }

        let graph = ProjectCodeGraph.rebuild(in: root, reusing: nil)
        let nodes = Dictionary(graph.nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let calls = graph.edges.filter { $0.provenance == "INFERRED" && $0.relation != "RESOLVES_TO" }
            .compactMap { edge -> String? in
                guard let from = nodes[edge.from], let to = nodes[edge.to] else { return nil }
                return "\(from.name)@\(from.path)->\(to.name)@\(to.path)"
            }
        XCTAssertTrue(calls.contains("runA@A.swift->helper@A.swift"), "\(calls)")
        XCTAssertTrue(calls.contains("runB@B.swift->lonely@C.swift"), "\(calls)")
        // Two `helper`s elsewhere and none in C.swift: ambiguous, so no edge.
        XCTAssertFalse(calls.contains { $0.hasPrefix("runC@") }, "\(calls)")
    }
}

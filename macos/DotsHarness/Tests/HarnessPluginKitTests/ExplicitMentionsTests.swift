import XCTest
@testable import DotsHarnessCore

final class ExplicitMentionsTests: XCTestCase {
    func testMatchesWholeWordsCaseInsensitively() {
        let mentions = ExplicitMentions("Fixed AgentBridge+Run.swift: runLoop çalışma hatası in Sources/Core/ProjectCodeGraph.swift")
        XCTAssertTrue(mentions.contains("agentbridge"))
        XCTAssertTrue(mentions.contains("RunLoop"))
        XCTAssertTrue(mentions.contains("çalışma"))
        XCTAssertTrue(mentions.contains("AgentBridge+Run.swift"))
        XCTAssertTrue(mentions.contains("Sources/Core/ProjectCodeGraph.swift"))
        XCTAssertFalse(mentions.contains("Agent"))
        XCTAssertFalse(mentions.contains("run.swif"))
        XCTAssertFalse(mentions.contains("Core/ProjectCode"))
        XCTAssertFalse(mentions.contains(""))
    }

    func testUnderscoreAndDigitsArePartOfAWord() {
        let mentions = ExplicitMentions("call load_index2 then x")
        XCTAssertTrue(mentions.contains("load_index2"))
        XCTAssertFalse(mentions.contains("load"))
        XCTAssertFalse(mentions.contains("index2"))
    }

    // The regex this replaced took ~8 s for one insight against a 17k-node graph.
    func testThousandsOfNamesStayFast() {
        let mentions = ExplicitMentions(String(repeating: "AgentBridge reads Package.swift and lists targets. ", count: 8))
        let names = (0..<17_000).map { $0.isMultiple(of: 10) ? "Dir\($0)/File\($0).swift" : "Symbol\($0)" }
        let started = Date()
        XCTAssertFalse(names.contains(where: mentions.contains))
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
    }
}

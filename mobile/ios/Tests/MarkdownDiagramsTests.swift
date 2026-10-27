import XCTest
@testable import HerNessMobile

final class MarkdownDiagramsTests: XCTestCase {
    func testFenceLanguageIsKept() {
        XCTAssertEqual(
            MarkdownSegments.split("a\n```diagram\nA | B\n```")[1],
            MarkdownSegment(isCode: true, text: "A | B", language: "diagram")
        )
    }

    func testFlowRowsCarryNumberNoteAndBadge() {
        let steps = FlowStep.parse("Harita: şema 4 `## x` [warn: Eski şema]\n\nBilgi: sırada [Sırada]")
        XCTAssertEqual(steps[0], FlowStep(number: 1, title: "Harita", note: "şema 4 `## x`", badge: DiagramTag(tone: "warn", label: "Eski şema"), isLast: false))
        XCTAssertEqual(steps[1], FlowStep(number: 2, title: "Bilgi", note: "sırada", badge: DiagramTag(tone: nil, label: "Sırada"), isLast: true))
    }

    func testDiagramParsesLayersCaptionsLegendAndColors() {
        let spec = DiagramSpec(source: "Kural: AGENTS.md [repo] | Kişisel: Mac [local] | Git index\n> System prompt\nModel çalışır\nlegend: repo = Repo | local = Bu Mac")
        XCTAssertEqual(spec.layers.map(\.nodes.count), [3, 1])
        XCTAssertEqual(spec.layers[1].caption, "System prompt")
        XCTAssertEqual(spec.layers[0].nodes[1], DiagramSpec.Node(title: "Kişisel", note: "Mac", group: "local"))
        XCTAssertNil(spec.layers[0].nodes[2].group)
        XCTAssertEqual(spec.legend.map(\.group), ["repo", "local"])
        XCTAssertNotEqual(spec.color(for: "repo"), spec.color(for: "local"))
    }

    func testChartScalesToPeak() {
        let bars = ChartBar.parse("macOS: 40\nnot a row\nLinux: 10 ms")
        XCTAssertEqual(bars.map(\.fraction), [1, 0.25])
        XCTAssertEqual(bars[1].text, "10 ms")
    }
}

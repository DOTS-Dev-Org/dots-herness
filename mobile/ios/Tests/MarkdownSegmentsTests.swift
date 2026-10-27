import XCTest
@testable import HerNessMobile

final class MarkdownSegmentsTests: XCTestCase {
    func testFencedBlockSplitsFromProseAndKeepsItsColumns() {
        XCTAssertEqual(
            MarkdownSegments.split("Akış:\n```\n┌─┐\n└─┘\n```\nSon"),
            [
                MarkdownSegment(isCode: false, text: "Akış:"),
                MarkdownSegment(isCode: true, text: "┌─┐\n└─┘"),
                MarkdownSegment(isCode: false, text: "Son"),
            ]
        )
    }

    func testUnclosedFenceStaysCodeWhileAReplyStreams() {
        XCTAssertEqual(MarkdownSegments.split("```\n┌─┐"), [MarkdownSegment(isCode: true, text: "┌─┐")])
    }

    func testPlainTextIsOneProseSegment() {
        XCTAssertEqual(MarkdownSegments.split("merhaba"), [MarkdownSegment(isCode: false, text: "merhaba")])
    }

    func testPipeTableBecomesItsOwnSegment() {
        let segments = MarkdownSegments.split("Fark:\n| Özellik | `actor` | x |\n|---|:---:|--:|\n| Tür | a \\| b | 1 |\n| Kalıtım | yok |\nSon")
        XCTAssertEqual(segments.count, 3)
        XCTAssertEqual(segments[1].language, "table")
        let table = MarkdownTable(segments[1].text)
        XCTAssertEqual(table.header, ["Özellik", "`actor`", "x"])
        XCTAssertEqual(table.alignments, [.leading, .center, .trailing])
        XCTAssertEqual(table.rows, [["Tür", "a | b", "1"], ["Kalıtım", "yok"]])
        XCTAssertEqual(segments[2], MarkdownSegment(isCode: false, text: "Son"))
    }

    func testTableHeaderWithoutSeparatorStaysProse() {
        XCTAssertEqual(MarkdownSegments.split("| a | b |"), [MarkdownSegment(isCode: false, text: "| a | b |")])
    }
}

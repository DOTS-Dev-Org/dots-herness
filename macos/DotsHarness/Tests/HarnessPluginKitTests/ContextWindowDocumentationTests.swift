import XCTest
import DotsHarnessCore

final class ContextWindowDocumentationTests: XCTestCase {
    func testClaudeHaiku55UsesDocumentedMillionTokenWindow() {
        XCTAssertEqual(
            RouterCatalog.documentedContextWindow(for: "claude-haiku-5-5", provider: "claude"),
            1_000_000
        )
        XCTAssertEqual(
            RouterCatalog.documentedContextWindow(for: "claude-haiku-5-5", provider: "anthropic"),
            1_000_000
        )
        XCTAssertNil(
            RouterCatalog.documentedContextWindow(for: "claude-haiku-4-5", provider: "claude")
        )
    }

    func testGPT6WindowRecognizesChatGPTProviderDisplayName() {
        XCTAssertEqual(
            RouterCatalog.documentedContextWindow(for: "gpt-6-luna", provider: "ChatGPT"),
            1_050_000
        )
    }
}

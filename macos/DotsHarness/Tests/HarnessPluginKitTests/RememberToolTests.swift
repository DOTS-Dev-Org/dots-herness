import XCTest
@testable import DotsHarnessCore

final class RememberToolTests: XCTestCase {
    func testParsesPreference() throws {
        let entry = try XCTUnwrap(RememberTool.parse(#"{"kind":"preference","key":"Language","text":"Reply in Turkish."}"#))
        XCTAssertEqual(entry.kind, "preference")
        XCTAssertEqual(entry.key, "language")
        XCTAssertEqual(entry.text, "Reply in Turkish.")
    }

    func testPreferenceWithoutKeyFallsBackToNote() throws {
        let entry = try XCTUnwrap(RememberTool.parse(#"{"kind":"preference","text":"Prefers tabs."}"#))
        XCTAssertEqual(entry.key, "note")
    }

    func testDecisionKeepsTextAndDropsKey() throws {
        let entry = try XCTUnwrap(RememberTool.parse(#"{"kind":"decision","text":"Ship SQLite, not Postgres."}"#))
        XCTAssertEqual(entry.kind, "decision")
        XCTAssertTrue(entry.key.isEmpty)
    }

    func testRejectsUnusableCalls() {
        XCTAssertNil(RememberTool.parse(#"{"kind":"preference","text":"   "}"#))
        XCTAssertNil(RememberTool.parse(#"{"kind":"whatever","text":"x"}"#))
        XCTAssertNil(RememberTool.parse("not json"))
    }

    func testSecretShapedFactsAreRefused() throws {
        func entry(_ json: String) throws -> RememberTool.Entry { try XCTUnwrap(RememberTool.parse(json)) }
        XCTAssertTrue(RememberTool.looksLikeSecret(try entry(#"{"kind":"project","key":"api-key","text":"the one we use"}"#)))
        XCTAssertTrue(RememberTool.looksLikeSecret(try entry(#"{"kind":"project","key":"backend","text":"sk-ant-0123456789abcdefghij"}"#)))
        XCTAssertTrue(RememberTool.looksLikeSecret(try entry(#"{"kind":"project","key":"deploy","text":"token = ghp_0123456789abcdefghij"}"#)))
        XCTAssertFalse(RememberTool.looksLikeSecret(try entry(#"{"kind":"project","key":"backend-url","text":"https://api.dots.net.tr"}"#)))
        XCTAssertFalse(RememberTool.looksLikeSecret(try entry(#"{"kind":"project","key":"vps","text":"Deploys to 10.0.0.4, Hetzner fsn1."}"#)))
    }
}

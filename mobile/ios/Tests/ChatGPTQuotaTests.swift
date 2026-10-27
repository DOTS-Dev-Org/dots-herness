import XCTest
@testable import HerNessMobile

final class ChatGPTQuotaTests: XCTestCase {
    func testNewConversationTakesRoomiestAccount() {
        let ids = ["a", "b", "c"]
        XCTAssertEqual(ChatGPTQuota.pick(ids, active: "a", remaining: ["a": 0.1, "b": 0.8, "c": 0.5]), "b")
        // Unknown beats spent; the Settings pick breaks a tie.
        XCTAssertEqual(ChatGPTQuota.pick(ids, active: "c", remaining: ["a": 0]), "c")
        XCTAssertEqual(ChatGPTQuota.pick(["a"], active: "a", remaining: ["a": 0]), "a")
        XCTAssertEqual(ChatGPTQuota.pick([], active: "x", remaining: [:]), "x")
    }

    func testUsageTakesTighterWindow() {
        let body = Data(#"{"rate_limit":{"primary_window":{"used_percent":30},"secondary_window":{"used_percent":"75"}}}"#.utf8)
        XCTAssertEqual(ChatGPTQuota.remaining(body)!, 0.25, accuracy: 0.0001)
        XCTAssertNil(ChatGPTQuota.remaining(Data("{}".utf8)))
    }
}

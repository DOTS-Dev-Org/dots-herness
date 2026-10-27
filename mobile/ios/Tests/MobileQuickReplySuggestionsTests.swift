import XCTest
@testable import HerNessMobile

final class MobileQuickReplySuggestionsTests: XCTestCase {
    func testTurkishConfirmationProducesActionAndDeclineReplies() {
        let replies = MobileQuickReplySuggestions.choices(
            in: "main'i origin'e push edeyim mi?",
            continueReply: "Devam et",
            declineReply: "Reddet"
        ).map(\.text)

        XCTAssertEqual(replies, ["Main'i origin'e push et.", "Reddet"])
    }

    func testNumberedRecommendationsBecomeReplies() {
        let replies = MobileQuickReplySuggestions.choices(
            in: "1. Update the route\n2) Keep the existing route\nShould I apply one?",
            continueReply: "Continue",
            declineReply: "Reject"
        ).map(\.text)

        XCTAssertEqual(replies, ["Update the route", "Keep the existing route"])
    }

    func testOnlyActionConfirmationQuestionsOfferReplies() {
        XCTAssertTrue(MobileQuickReplySuggestions.choices(
            in: "Does this look correct?",
            continueReply: "Continue",
            declineReply: "Reject"
        ).isEmpty)
    }
}

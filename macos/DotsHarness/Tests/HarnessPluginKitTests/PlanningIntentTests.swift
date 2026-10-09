import XCTest
@testable import DotsHarnessCore

final class PlanningIntentTests: XCTestCase {
    func testFileAndChatPlanningRequestsEnterPlanMode() {
        XCTAssertTrue(PlanningIntent.shouldEnterPlanMode("Bu dosya için bir plan hazırla"))
        XCTAssertTrue(PlanningIntent.shouldEnterPlanMode("I need a plan for this file"))
        XCTAssertTrue(PlanningIntent.shouldEnterPlanMode("Write the plan to plan.md"))
        XCTAssertTrue(PlanningIntent.shouldEnterPlanMode("Sadece sohbette plan yap"))
        XCTAssertTrue(PlanningIntent.shouldEnterPlanMode("Plan moduna geç"))
        XCTAssertTrue(PlanningIntent.shouldEnterPlanMode("Switch to plan mode"))
        XCTAssertTrue(PlanningIntent.shouldEnterPlanMode("/plan add OAuth"))
    }

    func testApprovalAndPlanReferencesDoNotEnterPlanMode() {
        XCTAssertFalse(PlanningIntent.shouldEnterPlanMode("Planı uygula"))
        XCTAssertFalse(PlanningIntent.shouldEnterPlanMode("Read plan.md"))
        XCTAssertFalse(PlanningIntent.shouldEnterPlanMode("Explain what plan mode is"))
    }

    func testWordsThatOnlyMentionAPlanAreAmbiguous() {
        XCTAssertEqual(PlanningIntent.verdict("Bu dosyanın planını çıkar"), .ambiguous)
        XCTAssertEqual(PlanningIntent.verdict("Make a planet texture"), .ambiguous)
        XCTAssertEqual(PlanningIntent.verdict("Read plan.md"), .ambiguous)
        XCTAssertEqual(PlanningIntent.verdict("Fix the login bug"), .no)
        XCTAssertFalse(PlanningIntent.shouldEnterPlanMode("Make a planet texture"))
    }

    func testResolveAsksTheModelOnlyForAmbiguousText() async {
        var asked: [String] = []
        let ask: (String) async -> Bool = { text in asked.append(text); return text.contains("planını") }
        let explicit = await PlanningIntent.resolve("Make a plan for auth", ask: ask)
        let plain = await PlanningIntent.resolve("Fix the login bug", ask: ask)
        let yes = await PlanningIntent.resolve("Bu dosyanın planını çıkar", ask: ask)
        let no = await PlanningIntent.resolve("Make a planet texture", ask: ask)
        XCTAssertTrue(explicit)
        XCTAssertFalse(plain)
        XCTAssertTrue(yes)
        XCTAssertFalse(no)
        XCTAssertEqual(asked, ["Bu dosyanın planını çıkar", "Make a planet texture"])
    }
}

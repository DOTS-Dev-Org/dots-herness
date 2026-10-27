import XCTest
import HarnessPluginKit
@testable import DotsHarnessCore

final class PlanStepsToolTests: XCTestCase {
    func testCurrentStepsReadsLatestPlanSinceUserMessage() {
        let call = AgentToolCall(id: "1", name: PlanStepsTool.name, arguments: #"{"steps":[{"title":"Read code","status":"done"},{"title":"Fix bug","status":"in_progress"},{"title":"Test","status":"pending"}]}"#)
        let output = PlanStepsTool.execute(call)
        let plan = ChatMessage(kind: .tool, text: "✓ update_plan\n…", rawToolOutput: output)
        XCTAssertEqual(PlanStepsTool.currentSteps(in: [ChatMessage(kind: .user, text: "go"), plan]), [
            .init(title: "Read code", status: "done"),
            .init(title: "Fix bug", status: "in_progress"),
            .init(title: "Test", status: "pending"),
        ])
        XCTAssertEqual(PlanStepsTool.currentSteps(in: [plan, ChatMessage(kind: .user, text: "next")]), [])
        XCTAssertTrue(PlanStepsTool.unfinishedReminder(in: [plan])?.contains("- Fix bug\n- Test") == true)
        let finished = ChatMessage(kind: .tool, text: "✓ update_plan", rawToolOutput: PlanStepsTool.execute(AgentToolCall(id: "2", name: PlanStepsTool.name, arguments: #"{"steps":[{"title":"Read code","status":"done"}]}"#)))
        XCTAssertNil(PlanStepsTool.unfinishedReminder(in: [finished]))
    }
}

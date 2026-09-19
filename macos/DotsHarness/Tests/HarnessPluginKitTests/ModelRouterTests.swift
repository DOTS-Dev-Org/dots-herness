// Copyright (c) 2026 DOTS
// Automatic model selection. Pure logic, so it is covered without network.

import XCTest
@testable import DotsHarnessCore

final class ModelRouterTests: XCTestCase {
    private let premium = RouterModel(
        id: "claude-opus-5", owner: "Claude",
        efforts: ["low", "medium", "high", "xhigh", "max"],
        displayName: "Claude Opus 5", provider: "claude", tier: .premium
    )
    private let standard = RouterModel(
        id: "claude-sonnet-5", owner: "Claude",
        efforts: ["low", "medium", "high", "xhigh", "max"],
        displayName: "Claude Sonnet 5", provider: "claude", tier: .standard
    )
    private let light = RouterModel(
        id: "claude-haiku-4-5", owner: "Claude",
        displayName: "Claude Haiku 4.5", provider: "claude", tier: .light
    )
    private var all: [RouterModel] { [premium, standard, light] }

    private func user(_ text: String) -> AgentMessage { AgentMessage(role: .user, content: text) }
    private func assistant(_ text: String = "ok") -> AgentMessage { AgentMessage(role: .assistant, content: text) }

    // MARK: Role

    func testOpeningTurnPlansOnThePremiumModel() throws {
        let decision = try XCTUnwrap(ModelRouter.decide(messages: [user("Add OAuth to the app")], available: all))
        XCTAssertEqual(decision.role, "planner")
        XCTAssertEqual(decision.model, premium.id)
        XCTAssertEqual(decision.effort, "max", "a planner should use the deepest level the model allows")
    }

    func testTurnAfterAToolResultIsWork() throws {
        let messages = [
            user("Add OAuth"), assistant(),
            AgentMessage(role: .tool, content: "file contents", toolCallID: "1"),
        ]
        let decision = try XCTUnwrap(ModelRouter.decide(messages: messages, available: all))
        XCTAssertEqual(decision.role, "worker")
        XCTAssertEqual(decision.model, light.id, "mechanical continuation must not burn a premium call")
    }

    func testShortFollowUpStaysOnTheCheapModel() throws {
        let messages = [user("Add OAuth"), assistant(), user("now rename that helper")]
        let decision = try XCTUnwrap(ModelRouter.decide(messages: messages, available: all))
        XCTAssertEqual(decision.role, "worker")
        XCTAssertEqual(decision.model, light.id)
        // Haiku takes no effort parameter, so the level must come out empty.
        XCTAssertEqual(decision.effort, "")
    }

    func testMechanicalWorkerTurnUsesTheLowestLevel() throws {
        let messages = [
            user("Add OAuth"), assistant(),
            AgentMessage(role: .tool, content: "file contents", toolCallID: "1"),
        ]
        // Only tiers with effort support connected: the worker lands on standard.
        let decision = try XCTUnwrap(ModelRouter.decide(messages: messages, available: [premium, standard]))
        XCTAssertEqual(decision.model, standard.id)
        XCTAssertEqual(decision.effort, "low")
    }

    func testWorkerTurnThatStillHasToWriteCodeKeepsTheMiddleLevel() throws {
        let messages = [user("Add OAuth"), assistant(), user("now rename that helper")]
        let decision = try XCTUnwrap(ModelRouter.decide(messages: messages, available: [premium, standard]))
        XCTAssertEqual(decision.role, "worker")
        XCTAssertEqual(decision.model, standard.id, "the light model stays the saving; the effort does not stack on it")
        XCTAssertEqual(decision.effort, "medium")
    }

    func testWorkerFallsBackToTheOnlyLevelAModelOffers() {
        XCTAssertEqual(ModelRouter.effort(for: .worker, supported: ["low"], mechanical: false), "low")
        XCTAssertEqual(ModelRouter.effort(for: .worker, supported: [], mechanical: false), "")
    }

    func testMidConversationDesignRequestGoesBackToPremium() throws {
        let messages = [user("Add OAuth"), assistant(), user("review the token refresh design")]
        let decision = try XCTUnwrap(ModelRouter.decide(messages: messages, available: all))
        XCTAssertEqual(decision.role, "planner")
        XCTAssertEqual(decision.model, premium.id)
    }

    func testTurkishPlanningWordAlsoTriggersPlanning() throws {
        let messages = [user("ekle"), assistant(), user("bunun mimarisini gözden geçir")]
        XCTAssertEqual(ModelRouter.decide(messages: messages, available: all)?.role, "planner")
    }

    func testLongMidConversationAskIsTreatedAsANewSubTask() throws {
        let messages = [user("hi"), assistant(), user(String(repeating: "detail ", count: 120))]
        XCTAssertEqual(ModelRouter.decide(messages: messages, available: all)?.role, "planner")
    }

    // MARK: Availability

    func testFallsBackDownWhenNoPremiumIsConnected() throws {
        let decision = try XCTUnwrap(ModelRouter.decide(messages: [user("design this")], available: [standard, light]))
        XCTAssertEqual(decision.model, standard.id, "best connected model stands in for a missing premium tier")
    }

    func testFallsBackUpWhenOnlyPremiumIsConnected() throws {
        let messages = [user("x"), assistant(), AgentMessage(role: .tool, content: "r", toolCallID: "1")]
        let decision = try XCTUnwrap(ModelRouter.decide(messages: messages, available: [premium]))
        XCTAssertEqual(decision.model, premium.id, "a worker still has to run when nothing cheaper exists")
    }

    func testNoConnectedModelsYieldsNoDecision() {
        XCTAssertNil(ModelRouter.decide(messages: [user("hi")], available: []))
    }

    // MARK: Effort

    func testEffortNeverSelectsNone() {
        // "none" disables reasoning outright — only acceptable if nothing else exists.
        XCTAssertEqual(ModelRouter.effort(for: .worker, supported: ["none", "low", "medium"]), "low")
        XCTAssertEqual(ModelRouter.effort(for: .planner, supported: ["none", "low", "medium"]), "medium")
        XCTAssertEqual(ModelRouter.effort(for: .worker, supported: []), "")
    }

    func testEffortStaysWithinWhatTheModelSupports() throws {
        // Haiku takes no effort parameter at all.
        let messages = [user("x"), assistant(), AgentMessage(role: .tool, content: "r", toolCallID: "1")]
        let decision = try XCTUnwrap(ModelRouter.decide(messages: messages, available: all))
        XCTAssertEqual(decision.model, light.id)
        XCTAssertEqual(decision.effort, "", "a model that rejects effort must be sent none")
    }

    // MARK: Tier inference for live-discovered models

    func testTierIsInferredForModelsTheRegistryDoesNotDescribe() {
        XCTAssertEqual(ModelTier.inferred(from: "claude-opus-4-9"), .premium)
        XCTAssertEqual(ModelTier.inferred(from: "gemini-9-flash"), .light)
        XCTAssertEqual(ModelTier.inferred(from: "gpt-9.9-mini"), .light)
        XCTAssertEqual(ModelTier.inferred(from: "some-new-model"), .standard)
    }

    func testRegistryTierWinsOverInference() {
        // "gpt-5.6-luna" contains none of the inference keywords; the registry says standard.
        let model = RouterModel(id: "gpt-5.6-luna", provider: "gpt", tier: .standard)
        XCTAssertEqual(ModelRouter.tier(of: model), .standard)
        XCTAssertEqual(ModelRouter.tier(of: RouterModel(id: "gpt-5.6-luna", provider: "gpt")), .standard)
    }

    /// Every tiered registry model must map to a real tier band, and each provider
    /// that offers more than one model must not be entirely premium — otherwise
    /// automatic routing has nothing cheap to delegate to.
    func testRegistryTiersLeaveRoomForWorkers() throws {
        for spec in ProviderRegistry.shared.specs where spec.models.count > 2 {
            let tiers = spec.models.map { $0.tier ?? ModelTier.inferred(from: $0.id) }
            XCTAssertTrue(tiers.contains { $0 < .premium }, "\(spec.id) has no non-premium model to delegate work to")
        }
    }

    // MARK: Model picker presentation

    func testModelDisplayNameRemovesProviderPrefix() {
        XCTAssertEqual(
            RouterCatalog.modelDisplayName(for: RouterModel(id: "claude-sonnet-5", provider: "claude")),
            "Sonnet 5"
        )
        XCTAssertEqual(RouterCatalog.modelDisplayName(for: standard), "Sonnet 5")
        XCTAssertEqual(RouterCatalog.modelDisplayName(for: premium), "Opus 5")
        XCTAssertEqual(
            RouterCatalog.modelDisplayName(for: RouterModel(
                id: "gpt-5.6-terra", displayName: "GPT 5.6 Terra", provider: "gpt"
            )),
            "5.6 Terra"
        )
    }

    func testModelDisplayNameMakesUnknownIDsReadable() {
        XCTAssertEqual(
            RouterCatalog.modelDisplayName(for: RouterModel(id: "openai/gpt-4.1-mini", provider: "openrouter")),
            "4.1 Mini"
        )
    }

    func testModelGroupsPreserveOrderAndKeepUnknownProviders() {
        let local = RouterModel(id: "local-model", owner: "Local", provider: "custom:local")
        let groups = RouterCatalog.modelGroups(for: [standard, premium, local])

        XCTAssertEqual(groups.map(\.provider), ["claude", "custom:local"])
        XCTAssertEqual(groups[0].models.map(\.id), [standard.id, premium.id])
        XCTAssertEqual(groups[1].name, "Local")
        XCTAssertEqual(groups[1].logoSymbol, "sparkles")
    }
}

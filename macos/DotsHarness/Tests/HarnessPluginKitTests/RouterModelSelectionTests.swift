// Copyright (c) 2026 DOTS
// Catalog-validated model selection: a model no catalog lists must never be
// the chosen model, and no surface may rename one into something else.

import XCTest
@testable import DotsHarnessCore

@MainActor
final class RouterModelSelectionTests: XCTestCase {
    private let phantomID = "gpt-9.9-phantom"

    private func makeRouter(_ models: [RouterModel] = []) -> RouterController {
        let router = RouterController()
        router.models = models
        return router
    }

    private func catalogModel(id: String, name: String? = nil) -> RouterModel {
        RouterModel(id: id, displayName: name, provider: "gpt")
    }

    func testSelectAdoptsOnlyModelsTheCatalogLists() {
        let router = makeRouter([catalogModel(id: "gpt-6-luna", name: "GPT-6-Luna")])

        XCTAssertEqual(router.select(modelID: "gpt-6-luna"), "gpt-6-luna")
        XCTAssertEqual(router.selectedModelID, "gpt-6-luna")

        XCTAssertEqual(router.select(modelID: phantomID), ModelRouter.autoModelID)
        XCTAssertEqual(router.selectedModelID, ModelRouter.autoModelID)
    }

    func testPhantomSelectionReturnsOnceTheCatalogLearnsIt() {
        let model = catalogModel(id: "gpt-6-luna", name: "GPT-6-Luna")
        let router = makeRouter([])

        router.select(modelID: "gpt-6-luna")
        XCTAssertEqual(router.selectedModelID, ModelRouter.autoModelID)
        XCTAssertEqual(router.pendingModelID, "gpt-6-luna")

        router.models = [model]
        router.reconcileSelection()
        XCTAssertEqual(router.selectedModelID, "gpt-6-luna")
        XCTAssertNil(router.pendingModelID)
    }

    func testRetiredModelDropsToAutomaticRouting() {
        let router = makeRouter([catalogModel(id: "gpt-6-luna", name: "GPT-6-Luna")])
        router.select(modelID: "gpt-6-luna")

        // An authoritative listing that no longer contains the model retired it.
        router.models = [catalogModel(id: "gpt-6-sol", name: "GPT-6-Sol")]
        router.reconcileSelection()

        XCTAssertEqual(router.selectedModelID, ModelRouter.autoModelID)
        XCTAssertEqual(router.pendingModelID, "gpt-6-luna")
    }

    func testChoosingAutomaticRoutingForgetsAPendingModel() {
        let router = makeRouter([])
        router.select(modelID: "gpt-6-luna")
        XCTAssertEqual(router.pendingModelID, "gpt-6-luna")

        router.select(modelID: ModelRouter.autoModelID)
        XCTAssertNil(router.pendingModelID)

        router.models = [catalogModel(id: "gpt-6-luna", name: "GPT-6-Luna")]
        router.reconcileSelection()
        XCTAssertEqual(router.selectedModelID, ModelRouter.autoModelID)
    }

    func testStoredModelIDsAreSanitizedToTheCatalog() {
        let router = makeRouter([catalogModel(id: "gpt-6-luna", name: "GPT-6-Luna")])
        XCTAssertEqual(router.usableModelID("  gpt-6-luna "), "gpt-6-luna")
        XCTAssertEqual(router.usableModelID(phantomID), "")
        XCTAssertEqual(router.usableModelID(ModelRouter.autoModelID), "")
    }

    func testModelLabelUsesTheNameTheProviderPublishes() {
        let router = makeRouter([catalogModel(id: "gpt-6-luna", name: "GPT-6-Luna")])
        XCTAssertEqual(router.modelLabel(forID: "gpt-6-luna"), "GPT-6-Luna")
    }

    /// Without a published name the id is read out in full. Dropping the family
    /// token would present "6 Luna" as if it were a model anyone could pick.
    func testModelLabelKeepsEveryTokenOfAnUnlistedID() {
        let router = makeRouter([])
        let label = router.modelLabel(forID: "gpt-6-luna")
        XCTAssertEqual(label, "GPT 6 Luna")
        XCTAssertTrue(label.localizedCaseInsensitiveContains("gpt"))
    }

    func testModelLabelWithoutASelectionAsksForOne() {
        let router = makeRouter([])
        XCTAssertEqual(router.modelLabel(forID: ""), AppCopy.text("modelPicker.selectModel"))
    }
}

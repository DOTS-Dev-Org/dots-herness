import Foundation
import XCTest
import HarnessPluginKit
import PluginRuntime
@testable import DotsHarnessCore

@MainActor
final class ModelSelectionPersistenceTests: XCTestCase {
    private let luna = RouterModel(
        id: "gpt-6-luna", contextWindow: 1_048_576, efforts: ["low", "high", "max"],
        displayName: "GPT-6-Luna", provider: "gpt", fast: true
    )
    private let sol = RouterModel(id: "gpt-6-sol", contextWindow: 1_048_576, efforts: ["low", "high", "max"], provider: "gpt")
    private let astra = RouterModel(id: "gpt-6-astra", contextWindow: 1_048_576, efforts: ["low", "high", "max"], provider: "gpt")

    func testModelPreferenceStaysWithConversationAcrossRelaunch() throws {
        let paths = try temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }

        let firstID = "conversation-model-sol"
        let secondID = "conversation-model-luna"
        let defaultID = "conversation-model-default"
        let selectionKey = NativeAgentHost.lastSelectedKey(nil)
        UserDefaults.standard.set(firstID, forKey: selectionKey)
        defer { UserDefaults.standard.removeObject(forKey: selectionKey) }

        let store = ConversationStore(paths: paths)
        XCTAssertTrue(store.save([
            Conversation(id: firstID, title: "Sol chat", blank: false, projectless: true, modelPreferenceID: sol.id),
            Conversation(id: secondID, title: "Luna chat", blank: false, projectless: true, modelPreferenceID: luna.id),
            Conversation(id: defaultID, title: "Default chat", blank: false, projectless: true),
        ]))

        let model = AppModel(paths: paths)
        model.router.models = [luna, sol, astra]
        model.setModel(luna.id) // App default for conversations without an override.
        model.bridge.setWorkspace("")

        XCTAssertEqual(model.bridge.selectedID, firstID)
        XCTAssertEqual(model.selectedModelID, sol.id)

        model.bridge.select(secondID)
        XCTAssertEqual(model.selectedModelID, luna.id)
        model.setModel(astra.id)
        XCTAssertEqual(store.loadAll().first(where: { $0.id == secondID })?.modelPreferenceID, astra.id)
        XCTAssertEqual(store.loadAll().first(where: { $0.id == firstID })?.modelPreferenceID, sol.id)
        model.bridge.select(defaultID)
        XCTAssertEqual(model.selectedModelID, astra.id)
        model.bridge.select(secondID)

        let reloaded = AppModel(paths: paths)
        reloaded.router.models = [luna, sol, astra]
        reloaded.bridge.setWorkspace("")

        XCTAssertEqual(reloaded.bridge.selectedID, secondID)
        XCTAssertEqual(reloaded.selectedModelID, astra.id)
        reloaded.bridge.select(firstID)
        XCTAssertEqual(reloaded.selectedModelID, sol.id)
        reloaded.bridge.select(defaultID)
        XCTAssertEqual(reloaded.selectedModelID, astra.id)
        XCTAssertEqual(try savedSettings(paths)["agent.model"]?.string, astra.id)
    }

    func testManualSelectionSurvivesRelaunchBeforeTheCatalogArrives() throws {
        let paths = try temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        try writeAccount(to: paths)
        let model = AppModel(paths: paths)
        model.router.models = [luna]
        model.setModel(luna.id)
        model.setEffort("max")

        let saved = try savedSettings(paths)
        XCTAssertEqual(saved["agent.model"]?.string, luna.id)
        XCTAssertEqual(saved["agent.model.coding"]?.string, luna.id)

        // Cold start must restore a live-only model and its capabilities before
        // any network listing, credential read, or model-picker interaction.
        let reloaded = AppModel(paths: paths)
        XCTAssertEqual(reloaded.selectedModelID, luna.id)
        XCTAssertFalse(reloaded.router.isAutoSelected)
        XCTAssertNil(reloaded.router.pendingModelID)
        XCTAssertNil(reloaded.router.lastModelRefresh)
        XCTAssertEqual(reloaded.router.catalogModel(forID: luna.id), luna)
        XCTAssertEqual(reloaded.router.selectedEffort, "max")
    }

    func testUncachedLegacyModelIsRetainedUntilTheCatalogArrives() throws {
        let paths = try temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let settings: [String: JSONValue] = ["agent.model": .string(luna.id)]
        try JSONEncoder().encode(settings).write(to: paths.settings, options: .atomic)

        let reloaded = AppModel(paths: paths)
        XCTAssertEqual(reloaded.router.pendingModelID, luna.id)
        reloaded.persistSettings()
        XCTAssertEqual(try savedSettings(paths)["agent.model"]?.string, luna.id)

        reloaded.router.models = [luna]
        reloaded.router.reconcileSelection()
        XCTAssertEqual(reloaded.selectedModelID, luna.id)
        XCTAssertFalse(reloaded.router.isAutoSelected)
    }

    func testCachedModelsAreDiscardedWhenTheAccountChanges() throws {
        let paths = try temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        try writeAccount(to: paths)
        let accountOnly = RouterModel(id: "gpt-fixture-account-only", provider: "gpt")
        let model = AppModel(paths: paths)
        model.router.models = [accountOnly]
        model.setModel(accountOnly.id)

        try writeAccount(to: paths, id: "another-fixture-account")
        let reloaded = AppModel(paths: paths)

        XCTAssertNil(reloaded.router.catalogModel(forID: accountOnly.id))
        XCTAssertEqual(reloaded.router.pendingModelID, accountOnly.id)
        XCTAssertTrue(reloaded.router.isAutoSelected)
    }

    func testRetiredCachedModelDoesNotReturnAtNextLaunch() throws {
        let paths = try temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        try writeAccount(to: paths)
        let model = AppModel(paths: paths)
        model.router.models = [luna]
        model.setModel(luna.id)

        model.router.models = [RouterModel(id: "gpt-6-sol", provider: "gpt")]
        model.router.reconcileSelection()
        model.router.persistModelCatalog()
        let reloaded = AppModel(paths: paths)

        XCTAssertNil(reloaded.router.catalogModel(forID: luna.id))
        XCTAssertEqual(reloaded.router.pendingModelID, luna.id)
        XCTAssertTrue(reloaded.router.isAutoSelected)
    }

    func testCanonicalSelectionWinsOverStaleCodingPreference() throws {
        let paths = try temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let settings: [String: JSONValue] = [
            "agent.model": .string(luna.id),
            "agent.model.coding": .string(ModelRouter.autoModelID),
        ]
        try JSONEncoder().encode(settings).write(to: paths.settings, options: .atomic)

        let model = AppModel(paths: paths)
        model.router.models = [luna]
        model.router.reconcileSelection()

        XCTAssertEqual(model.selectedModelID, luna.id)
        XCTAssertFalse(model.router.isAutoSelected)
    }

    func testLegacySelectionIsRestoredWhenCanonicalPreferenceIsAbsent() throws {
        let paths = try temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let settings: [String: JSONValue] = ["agent.model.coding": .string(luna.id)]
        try JSONEncoder().encode(settings).write(to: paths.settings, options: .atomic)

        let model = AppModel(paths: paths)
        model.router.models = [luna]
        model.router.reconcileSelection()

        XCTAssertEqual(model.selectedModelID, luna.id)
    }

    func testExplicitAutomaticSelectionSurvivesRelaunchAndCatalogArrival() throws {
        let paths = try temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let model = AppModel(paths: paths)
        model.router.models = [luna]
        model.setModel(luna.id)
        model.setModel(ModelRouter.autoModelID)

        let reloaded = AppModel(paths: paths)
        reloaded.router.models = [luna]
        reloaded.router.reconcileSelection()

        XCTAssertTrue(reloaded.router.isAutoSelected)
        XCTAssertNil(reloaded.router.pendingModelID)
        XCTAssertEqual(try savedSettings(paths)["agent.model"]?.string, ModelRouter.autoModelID)
    }

    private func savedSettings(_ paths: SupportPaths) throws -> [String: JSONValue] {
        try JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: paths.settings))
    }

    private func writeAccount(to paths: SupportPaths, id: String = "fixture-account") throws {
        let account = StoredProviderAccount(
            id: id, provider: "gpt", name: "Fixture", authType: "chatgpt",
            model: "gpt-fixture-default", baseURL: "https://chatgpt.com/backend-api",
            api: RouterAPIKind.chatGPT.rawValue, credentialID: "fixture-credential"
        )
        let state = StoredProviderState(accounts: [account])
        try JSONEncoder().encode(state).write(
            to: paths.root.appendingPathComponent("provider-state.json"), options: .atomic
        )
    }

    private func temporaryPaths() throws -> SupportPaths {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("model-selection-tests-" + UUID().uuidString, isDirectory: true)
        let paths = SupportPaths(
            root: root,
            plugins: root.appendingPathComponent("plugins", isDirectory: true),
            presets: root.appendingPathComponent("presets", isDirectory: true),
            settings: root.appendingPathComponent("settings.json"),
            hostPatch: root.appendingPathComponent("host.patch.yml"),
            trust: root.appendingPathComponent("trust.json"),
            models: root.appendingPathComponent("models", isDirectory: true),
            runtime: root.appendingPathComponent("runtime", isDirectory: true)
        )
        paths.ensure()
        return paths
    }
}

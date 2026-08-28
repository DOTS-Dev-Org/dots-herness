// Copyright (c) 2026 DOTS
// Native provider catalog and gateway contract tests.

import XCTest
import Foundation
import PluginRuntime
import DotsHarnessCore

final class RouterAPITests: XCTestCase {
    func testCatalogUsesCanonicalNamesAndBroadCoverage() {
        let ids = Set(RouterCatalog.providers.map(\.id))
        XCTAssertTrue(ids.isSuperset(of: ["gpt", "openai", "claude", "gemini", "deepseek"]))
        for provider in RouterCatalog.providers {
            XCTAssertFalse(provider.name.contains("·"))
            XCTAssertFalse(provider.name.contains("CLI"))
            XCTAssertFalse(provider.name.contains("/") && provider.id == "gpt")
            XCTAssertFalse(provider.logoSymbol.isEmpty)
        }
        XCTAssertEqual(RouterCatalog.kind(for: "gpt")?.name, "GPT")
        XCTAssertEqual(RouterCatalog.kind(for: "openai")?.name, "OpenAI")
        XCTAssertEqual(RouterCatalog.kind(for: "gpt")?.kind, .oauthBrowser)
        XCTAssertEqual(RouterCatalog.kind(for: "gpt")?.api, .chatGPT)
        XCTAssertEqual(RouterCatalog.kind(for: "openai")?.kind, .apiKey)
    }

    func testProviderAccountsStaySeparate() {
        let first = RouterConnection(from: [
            "id": .string("a"), "provider": .string("gpt"), "name": .string("one@example.com"), "isActive": .bool(true),
        ])
        let second = RouterConnection(from: [
            "id": .string("b"), "provider": .string("gpt"), "name": .string("two@example.com"), "isActive": .bool(true),
        ])
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(first.provider, "gpt")
        XCTAssertEqual(RouterCatalog.label(for: first.provider), "GPT")
        XCTAssertEqual(RouterCatalog.label(for: "custom:endpoint"), "Custom API")
    }

    func testTunnelShareUrlUsesLocalGateway() {
        let tunnel = RouterTunnel(enabled: true, running: true, tunnelURL: "http://127.0.0.1:18766/v1", publicURL: "", shortId: "", downloading: false, progress: 100)
        XCTAssertEqual(tunnel.shareURL, "http://127.0.0.1:18766/v1")
        XCTAssertTrue(tunnel.running)
    }

    @MainActor
    func testMetadataConfigurationDoesNotRequireKeychainCredential() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DotsHarnessTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
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

        let account = StoredProviderAccount(
            provider: "gpt",
            name: "Test GPT",
            authType: "chatgpt",
            model: "gpt-5.6-luna",
            baseURL: "https://chatgpt.com/backend-api/codex",
            api: "chatgpt",
            credentialID: "missing.\(UUID().uuidString)"
        )
        let stateURL = root.appendingPathComponent("provider-state.json")
        try JSONEncoder().encode(StoredProviderState(accounts: [account])).write(to: stateURL)

        let router = RouterController(paths: paths)
        let configuration = await router.agentConfiguration(loadCredentials: false)
        XCTAssertEqual(configuration?.baseURL, account.baseURL)
        XCTAssertEqual(configuration?.model, account.model)
        XCTAssertNil(configuration?.apiKey)
    }
}

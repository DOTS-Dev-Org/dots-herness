// Copyright (c) 2026 DOTS
// Native provider catalog and gateway contract tests.

import XCTest
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
}

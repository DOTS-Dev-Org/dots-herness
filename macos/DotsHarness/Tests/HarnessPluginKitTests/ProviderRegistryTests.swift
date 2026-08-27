// Copyright (c) 2026 DOTS
// Data-driven provider registry + OAuth engine + tool cloaking contract tests.

import XCTest
@testable import DotsHarnessCore

final class ProviderRegistryTests: XCTestCase {
    func testBundledRegistryLoadsCoreProviders() {
        let ids = Set(ProviderRegistry.shared.specs.map(\.id))
        XCTAssertTrue(ids.isSuperset(of: ["gpt", "claude", "anthropic", "openai", "deepseek", "opencode"]))

        let claude = ProviderRegistry.shared.spec("claude")
        XCTAssertEqual(claude?.category, .oauth)
        XCTAssertNotNil(claude?.oauth)
        XCTAssertEqual(claude?.transport.format, .anthropic)
        XCTAssertEqual(claude?.transport.quirks.cloakToolsOnOAuth, true)
        XCTAssertEqual(claude?.oauth?.tokenEncoding, .json)
        XCTAssertEqual(claude?.oauth?.manualCodeSeparator, "#")

        XCTAssertEqual(ProviderRegistry.shared.spec("gpt")?.category, .oauth)
        XCTAssertEqual(ProviderRegistry.shared.spec("gpt")?.oauth?.tokenEncoding, .form)
        XCTAssertEqual(ProviderRegistry.shared.spec("deepseek")?.category, .apiKey)
        XCTAssertEqual(ProviderRegistry.shared.spec("opencode")?.category, .passthrough)
    }

    func testCatalogMirrorsRegistry() {
        XCTAssertEqual(RouterCatalog.kind(for: "gpt")?.kind, .oauthBrowser)
        XCTAssertEqual(RouterCatalog.kind(for: "gpt")?.api, .chatGPT)
        XCTAssertEqual(RouterCatalog.kind(for: "claude")?.kind, .oauthBrowser)
        XCTAssertEqual(RouterCatalog.kind(for: "claude")?.api, .anthropic)
        XCTAssertEqual(RouterCatalog.kind(for: "openai")?.kind, .apiKey)
        XCTAssertEqual(RouterCatalog.kind(for: "opencode")?.kind, .passthrough)
    }

    func testOAuthAuthorizeURLCarriesPKCEAndExtraParams() throws {
        let gpt = try XCTUnwrap(ProviderRegistry.shared.spec("gpt")?.oauth)
        let url = try XCTUnwrap(OAuthFlow(spec: gpt).authorizeURL(verifier: "v", state: "s"))
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let map = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(map["code_challenge_method"], "S256")
        XCTAssertEqual(map["client_id"], gpt.clientID)
        XCTAssertEqual(map["state"], "s")
        XCTAssertEqual(map["codex_cli_simplified_flow"], "true")
    }

    func testToolCloakRoundTrips() {
        var body: [String: Any] = [
            "tools": [["name": "search_web", "description": "d", "input_schema": ["type": "object"]]],
            "messages": [["role": "assistant", "content": [["type": "tool_use", "name": "search_web", "id": "1"]]]],
        ]
        XCTAssertTrue(ToolCloak.apply(to: &body))
        let tools = body["tools"] as? [[String: Any]] ?? []
        XCTAssertTrue(tools.contains { ($0["name"] as? String) == "search_web_cc" })
        XCTAssertTrue(tools.count > 1) // decoys appended
        let block = ((body["messages"] as? [[String: Any]])?.first?["content"] as? [[String: Any]])?.first
        XCTAssertEqual(block?["name"] as? String, "search_web_cc")
        XCTAssertEqual(ToolCloak.restore("search_web_cc"), "search_web")
        XCTAssertEqual(ToolCloak.restore("plain"), "plain")
    }
}

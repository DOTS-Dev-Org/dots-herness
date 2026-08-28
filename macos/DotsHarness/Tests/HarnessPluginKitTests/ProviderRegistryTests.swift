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
        XCTAssertEqual(ProviderRegistry.shared.spec("opencode")?.category, .apiKey)
    }

    func testNonImageMediaCapabilitiesRemainProviderSpecific() throws {
        let openAI = try XCTUnwrap(ProviderRegistry.shared.spec("openai"))
        XCTAssertNil(openAI.media?.spec(for: .image))
        XCTAssertEqual(openAI.media?.spec(for: .video)?.model, "sora-2")
        XCTAssertEqual(openAI.media?.spec(for: .audio)?.model, "gpt-4o-mini-tts")
        XCTAssertNil(ProviderRegistry.shared.spec("gpt")?.media)
        XCTAssertNil(ProviderRegistry.shared.spec("claude")?.media)
    }

    func testMediaCommandsParseAliasesAndPrompt() {
        XCTAssertEqual(MediaRequest.parse("/imagegen a red fox")?.kind, .image)
        XCTAssertEqual(MediaRequest.parse("/video a quiet lake")?.kind, .video)
        XCTAssertEqual(MediaRequest.parse("/speech hello world")?.prompt, "hello world")
        XCTAssertNil(MediaRequest.parse("make an image"))
    }

    func testCatalogMirrorsRegistry() {
        XCTAssertEqual(RouterCatalog.kind(for: "gpt")?.kind, .oauthBrowser)
        XCTAssertEqual(RouterCatalog.kind(for: "gpt")?.api, .chatGPT)
        XCTAssertEqual(RouterCatalog.kind(for: "claude")?.kind, .oauthBrowser)
        XCTAssertEqual(RouterCatalog.kind(for: "claude")?.api, .anthropic)
        XCTAssertEqual(RouterCatalog.kind(for: "openai")?.kind, .apiKey)
        XCTAssertEqual(RouterCatalog.kind(for: "opencode")?.kind, .apiKey)
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

    func testJWTClaimsDecodeBase64URLAndNestedChatGPTAccountID() {
        // Payload uses base64url chars (-, _) and nests the account id under the
        // OpenAI namespace claim, matching a real Codex id_token.
        let payload = #"{"email":"a@b.co","https://api.openai.com/auth":{"chatgpt_account_id":"acct_123"}}"#
        let b64url = Data(payload.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let claims = OAuthFlow.jwtClaims("h.\(b64url).sig")
        XCTAssertEqual(claims["email"] as? String, "a@b.co")
        XCTAssertEqual(OAuthFlow.chatGPTAccountID(claims), "acct_123")
        XCTAssertEqual(OAuthFlow.chatGPTAccountID(["chatgpt_account_id": "top"]), "top")
        XCTAssertNil(OAuthFlow.chatGPTAccountID(["chatgpt_account_id": ""]))
    }

    func testCodexSSEReassemblesTextToolCallsAndUsage() throws {
        let sse = """
        data: {"type":"response.output_text.delta","delta":"Hel"}

        data: {"type":"response.output_text.delta","delta":"lo"}

        data: {"type":"response.output_item.done","item":{"type":"function_call","call_id":"c1","name":"ping","arguments":"{\\"x\\":1}"}}

        data: {"type":"response.completed","response":{"output":[{"type":"message","content":[{"type":"output_text","text":"Hello"}]},{"type":"function_call","call_id":"c1","name":"ping","arguments":"{\\"x\\":1}"}],"usage":{"input_tokens":11,"output_tokens":3}}}

        data: [DONE]
        """
        let result = try NativeAgentClient.responseFromSSE(Data(sse.utf8))
        XCTAssertEqual(result.message.content, "Hello")
        XCTAssertEqual(result.message.toolCalls.first?.name, "ping")
        XCTAssertEqual(result.usage?.inputTokens, 11)
        XCTAssertEqual(result.usage?.outputTokens, 3)
    }

    /// Regression: the live Codex backend sends `response.completed` with an
    /// EMPTY `output` array, so the deltas are the only carrier of the answer.
    func testCodexSSEWithEmptyCompletedOutputStillYieldsText() throws {
        let sse = """
        data: {"type":"response.output_text.delta","delta":"pong"}

        data: {"type":"response.completed","response":{"output":[],"usage":{"input_tokens":7,"output_tokens":2,"input_tokens_details":{"cached_tokens":5}}}}
        """
        let result = try NativeAgentClient.responseFromSSE(Data(sse.utf8))
        XCTAssertEqual(result.message.content, "pong")
        XCTAssertEqual(result.usage?.inputTokens, 7)
        XCTAssertEqual(result.usage?.cachedTokens, 5)
    }

    func testCodexSSESurfacesStreamError() {
        let sse = #"data: {"type":"response.failed","response":{"error":{"message":"boom"}}}"#
        XCTAssertThrowsError(try NativeAgentClient.responseFromSSE(Data(sse.utf8))) { error in
            XCTAssertEqual((error as? NativeAgentError)?.message, "boom")
        }
    }

    /// Effort levels are per-model and provider-verified; an entry that claims a
    /// level the model rejects turns every request into an HTTP 400.
    func testRegistryEffortLevelsMatchProviderRules() throws {
        func efforts(_ provider: String, _ model: String) throws -> [String] {
            let spec = try XCTUnwrap(ProviderRegistry.shared.spec(provider))
            return try XCTUnwrap(spec.models.first { $0.id == model }).efforts
        }
        // Codex accepts "none"; Anthropic rejects it.
        XCTAssertEqual(try efforts("gpt", "gpt-5.6-terra"), ["none", "low", "medium", "high", "xhigh", "max"])
        XCTAssertFalse(try efforts("gpt", "gpt-5.5").contains("max"))
        XCTAssertEqual(try efforts("claude", "claude-opus-5"), ["low", "medium", "high", "xhigh", "max"])
        XCTAssertFalse(try efforts("claude", "claude-sonnet-4-6").contains("xhigh"))
        XCTAssertFalse(try efforts("claude", "claude-opus-4-5-20251101").contains("max"))
        // Models that reject the parameter entirely advertise no levels.
        XCTAssertTrue(try efforts("claude", "claude-haiku-4-5").isEmpty)
        XCTAssertTrue(try efforts("claude", "claude-sonnet-4-5-20250929").isEmpty)
        for spec in ProviderRegistry.shared.specs where spec.id == "claude" {
            for model in spec.models {
                XCTAssertFalse(model.efforts.contains("none"), "\(model.id) must not offer 'none'")
            }
        }
    }

    func testEffortOnlyReachesTheBodyWhenSet() throws {
        func body(effort: String, api: String) throws -> [String: Any] {
            let client = NativeAgentClient(configuration: AgentConfiguration(
                baseURL: "https://example.test/v1", model: "m", apiKey: "k",
                api: api, authType: "oauth", effort: effort
            ))
            return client.makeBody(messages: [AgentMessage(role: .user, content: "hi")], tools: [], cachePolicy: AgentCachePolicy())
        }
        XCTAssertNil(try body(effort: "", api: "anthropic")["output_config"])
        XCTAssertNil(try body(effort: "", api: "chatgpt")["reasoning"])
        XCTAssertEqual((try body(effort: "max", api: "anthropic")["output_config"] as? [String: String])?["effort"], "max")
        XCTAssertEqual((try body(effort: "high", api: "chatgpt")["reasoning"] as? [String: String])?["effort"], "high")
    }

    func testAttachmentsRoundTripAndBecomeProviderContent() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DotsHarnessAttachments-(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let imageURL = root.appendingPathComponent("reference.png")
        let fileURL = root.appendingPathComponent("notes.txt")
        try Data([1, 2, 3]).write(to: imageURL)
        try Data("notes".utf8).write(to: fileURL)
        let image = try XCTUnwrap(ChatAttachment(url: imageURL))
        let file = try XCTUnwrap(ChatAttachment(url: fileURL))
        XCTAssertEqual(image.kind, .image)
        XCTAssertEqual(file.kind, .file)

        let message = ChatMessage(kind: .user, text: "Inspect these", attachments: [image, file])
        let decoded = try JSONDecoder().decode(ChatMessage.self, from: JSONEncoder().encode(message))
        XCTAssertEqual(decoded.attachments, [image, file])

        let client = NativeAgentClient(configuration: AgentConfiguration(baseURL: "https://example.test/v1", model: "m"))
        let body = client.makeBody(
            messages: [AgentMessage(role: .user, content: message.text, attachments: message.attachments)],
            tools: [],
            cachePolicy: AgentCachePolicy()
        )
        let content = try XCTUnwrap((body["messages"] as? [[String: Any]])?.first?["content"] as? [[String: Any]])
        XCTAssertEqual(content.first?["type"] as? String, "text")
        XCTAssertTrue((content[1]["image_url"] as? [String: String])?["url"]?.hasPrefix("data:image/png;base64,") == true)
        XCTAssertTrue((content[2]["text"] as? String)?.contains("Attached file: notes.txt") == true)
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

    /// Cloud Code Assist wraps a Gemini payload in `{project, model, request}`.
    /// A wrong envelope is a 400 from Google, so pin the shape here.
    func testGeminiCLIBodyUsesCodeAssistEnvelope() throws {
        let client = NativeAgentClient(configuration: AgentConfiguration(
            baseURL: "https://cloudcode-pa.googleapis.com/v1internal",
            model: "gemini-2.5-pro", apiKey: "t",
            api: RouterAPIKind.geminiCLI.rawValue,
            sessionAccountID: "proj-123",
            specID: "gemini-cli", authType: "oauth", effort: "high"
        ))
        let body = client.makeBody(
            messages: [
                AgentMessage(role: .system, content: "be terse"),
                AgentMessage(role: .user, content: "hi"),
            ],
            tools: [AgentToolDefinition(name: "t", description: "d", parameters: .object(["type": .string("object")]))],
            cachePolicy: AgentCachePolicy()
        )
        XCTAssertEqual(body["project"] as? String, "proj-123")
        XCTAssertEqual(body["model"] as? String, "gemini-2.5-pro")
        let request = try XCTUnwrap(body["request"] as? [String: Any])
        // The system prompt is a sibling of contents, not a turn inside it.
        let contents = try XCTUnwrap(request["contents"] as? [[String: Any]])
        XCTAssertEqual(contents.count, 1)
        XCTAssertEqual(contents.first?["role"] as? String, "user")
        XCTAssertNotNil(request["systemInstruction"])
        XCTAssertNotNil(request["tools"])
        let thinking = (request["generationConfig"] as? [String: Any])?["thinkingConfig"] as? [String: String]
        XCTAssertEqual(thinking?["thinkingLevel"], "high")
    }

    func testGeminiCLIResponseParsesTextToolCallsAndUsage() throws {
        let json = """
        {"response":{"candidates":[{"content":{"parts":[
          {"text":"pong"},
          {"functionCall":{"name":"get_weather","args":{"city":"Istanbul"}}}
        ]}}],"usageMetadata":{"promptTokenCount":9,"candidatesTokenCount":4}}}
        """
        let result = try NativeAgentClient.geminiResponse(from: try JSONCodec.parse(Data(json.utf8)))
        XCTAssertEqual(result.message.content, "pong")
        XCTAssertEqual(result.message.toolCalls.first?.name, "get_weather")
        XCTAssertTrue(try XCTUnwrap(result.message.toolCalls.first?.arguments).contains("Istanbul"))
        XCTAssertEqual(result.usage?.inputTokens, 9)
        XCTAssertEqual(result.usage?.outputTokens, 4)
    }

    /// Google's CLI client is confidential: without the secret every token call
    /// fails with `invalid_client`.
    func testGeminiCLISpecCarriesConfidentialClientAndDiscovery() throws {
        let spec = try XCTUnwrap(ProviderRegistry.shared.spec("gemini-cli"))
        XCTAssertEqual(spec.transport.format, .geminiCLI)
        let oauth = try XCTUnwrap(spec.oauth)
        XCTAssertFalse(try XCTUnwrap(oauth.clientSecret).isEmpty)
        XCTAssertEqual(oauth.projectDiscoveryURL, "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist")
        XCTAssertEqual(oauth.extraAuthorizeParams["access_type"], "offline")
    }

    /// The two OpenCode plans are separate products on separate endpoints.
    func testOpenCodePlansAreDistinctProviders() throws {
        let zen = try XCTUnwrap(ProviderRegistry.shared.spec("opencode"))
        let go = try XCTUnwrap(ProviderRegistry.shared.spec("opencode-go"))
        XCTAssertEqual(zen.transport.baseURL, "https://opencode.ai/zen/v1")
        XCTAssertEqual(go.transport.baseURL, "https://opencode.ai/zen/go/v1")
        XCTAssertNotEqual(zen.apiKey?.modelsURL, go.apiKey?.modelsURL)
        XCTAssertEqual(zen.category, .apiKey)
        XCTAssertEqual(go.category, .apiKey)
    }
}

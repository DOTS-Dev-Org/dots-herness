import XCTest
@testable import DotsHarnessCore

final class EconomyPolicyTests: XCTestCase {
    func testHighCodingBudgetHasVisibleReserveAnd512StepCap() {
        let configuration = AgentConfiguration(
            baseURL: "https://example.test",
            model: "gpt-6-astra",
            provider: "GPT",
            api: RouterAPIKind.chatGPT.rawValue,
            effort: "high",
            usageMode: .economy
        )
        let budget = AgentOutputBudget.resolve(
            configuration: configuration,
            messages: [AgentMessage(role: .user, content: "edit the project")],
            tools: [AgentToolDefinition(name: "write_file", description: "write", parameters: .object([:]))]
        )

        XCTAssertGreaterThanOrEqual(budget.visibleReserve, 12_288)
        XCTAssertGreaterThanOrEqual(budget.maxOutputTokens, 25_600)
        XCTAssertEqual(budget.maxOutputTokens % 512, 0)
    }

    func testStrictTokenLimitCapsOnlyProseTurns() {
        let configuration = AgentConfiguration(
            baseURL: "https://example.test",
            model: "gpt-6-astra",
            provider: "GPT",
            api: RouterAPIKind.chatGPT.rawValue,
            effort: "low"
        )
        let limit = ResponseStyleDecision(style: .strict, maxOutputTokens: 200)
        let prose = AgentOutputBudget.resolve(
            configuration: configuration,
            messages: [AgentMessage(role: .user, content: "explain a mutex")],
            tools: [],
            decision: limit
        )
        let coding = AgentOutputBudget.resolve(
            configuration: configuration,
            messages: [AgentMessage(role: .user, content: "edit the project")],
            tools: [AgentToolDefinition(name: "write_file", description: "write", parameters: .object([:]))],
            decision: limit
        )

        XCTAssertEqual(prose.maxOutputTokens, 200)
        XCTAssertGreaterThan(coding.maxOutputTokens, 200)
    }

    func testReadOutputIsNotClippedAgain() {
        let output = (1...500).map { "line-\($0)" }.joined(separator: "\n")
        let result = EconomyToolOutputPolicy.normalize(
            output,
            toolName: "read_file",
            arguments: #"{"offset":20}"#
        )

        XCTAssertEqual(result, output)
    }

    func testLongReadLinesReachTheModelIntact() {
        let output = (1...40).map { "line-\($0)-" + String(repeating: "x", count: 400) }.joined(separator: "\n")
        let result = EconomyToolOutputPolicy.normalize(
            output,
            toolName: "read_file",
            arguments: #"{"offset":100}"#
        )

        XCTAssertEqual(result, output)
    }

    func testEconomyPruningIsDeterministicAndHasNoSummaryMarker() {
        var messages = [AgentMessage(role: .system, content: "stable rules")]
        for index in 1...20 {
            messages.append(AgentMessage(role: .user, content: "request \(index)"))
            messages.append(AgentMessage(role: .assistant, content: "answer \(index)"))
        }

        let result = AgentContextCompaction.economyPrune(messages, targetTokens: 80)

        XCTAssertLessThan(result.count, messages.count)
        XCTAssertFalse(result.contains { $0.content.contains(AgentContextCompaction.summaryMarker) })
        XCTAssertEqual(result.first?.content, "stable rules")
    }

    func testShortPromptKeepsResponsesCacheSettingsAndSavedShortStyleSetsVerbosity() {
        var configuration = AgentConfiguration(baseURL: "https://example.test", model: "gpt-6-astra",
            api: RouterAPIKind.chatGPT.rawValue, effort: "high")
        func request(_ prompt: String) -> [String: Any] {
            NativeAgentClient(configuration: configuration).makeBody(
                messages: [AgentMessage(role: .user, content: prompt)], tools: [], cachePolicy: AgentCachePolicy())
        }
        func settings(_ body: [String: Any]) -> String {
            AgentPromptCacheRequestSnapshot(body: body, configuration: configuration, requestStartedAt: Date()).settingsFingerprint
        }
        let normal = request("explain the project structure")
        let short = request("en fazla 200 token kullan")
        XCTAssertEqual((normal["text"] as? [String: String])?["verbosity"], "low")
        XCTAssertEqual((short["text"] as? [String: String])?["verbosity"], "low")
        XCTAssertNotNil(short["max_output_tokens"])
        XCTAssertEqual(settings(normal), settings(short))
        configuration.responseStylePreference = .detailed
        XCTAssertNil(request("explain")["text"])
        configuration.responseStylePreference = .concise
        XCTAssertEqual((request("explain")["text"] as? [String: String])?["verbosity"], "low")
    }

    func testResponsesEconomyUsesLowVerbosityWithoutChangingHighEffort() throws {
        var configuration = AgentConfiguration(
            baseURL: "https://example.test",
            model: "gpt-6-astra",
            api: RouterAPIKind.chatGPT.rawValue,
            effort: "high",
            usageMode: .economy
        )
        configuration.fast = true
        let client = NativeAgentClient(configuration: configuration)

        let body = client.makeBody(
            messages: [AgentMessage(role: .user, content: "edit the project")],
            tools: [],
            cachePolicy: AgentCachePolicy()
        )

        let text = try XCTUnwrap(body["text"] as? [String: Any])
        XCTAssertEqual(text["verbosity"] as? String, "low")
        XCTAssertEqual((body["reasoning"] as? [String: Any])?["effort"] as? String, "high")
        XCTAssertGreaterThanOrEqual(body["max_output_tokens"] as? Int ?? 0, 13_312)
        XCTAssertNil(body["service_tier"])
    }

    func testStrictOutputLimitIsNotExpandedAndCanDisableReasoningReserve() throws {
        let configuration = AgentConfiguration(
            baseURL: "https://example.test",
            model: "claude-3-7-sonnet",
            api: RouterAPIKind.anthropic.rawValue,
            effort: "high",
            usageMode: .standard
        )
        let messages = [AgentMessage(role: .user, content: "En fazla 200 token kullan")]
        let budget = AgentOutputBudget.resolve(
            configuration: configuration,
            messages: messages,
            tools: []
        )
        let client = NativeAgentClient(configuration: configuration)
        let body = client.makeBody(messages: messages, tools: [], cachePolicy: AgentCachePolicy())

        XCTAssertEqual(budget.maxOutputTokens, 200)
        XCTAssertNil(budget.providerReasoningBudgetTokens)
        XCTAssertEqual(body["max_tokens"] as? Int, 200)
        XCTAssertNil(body["thinking"])
    }

    func testAdaptiveAnthropicDoesNotReceiveLegacyThinkingBudget() throws {
        let adaptive = NativeAgentClient(configuration: AgentConfiguration(
            baseURL: "https://example.test",
            model: "claude-sonnet-5",
            api: RouterAPIKind.anthropic.rawValue,
            effort: "high",
            usageMode: .economy,
            supportsLegacyThinkingBudget: false
        ))
        let adaptiveBody = adaptive.makeBody(
            messages: [AgentMessage(role: .user, content: "answer briefly")],
            tools: [],
            cachePolicy: AgentCachePolicy()
        )
        XCTAssertNil(adaptiveBody["thinking"])
        XCTAssertEqual((adaptiveBody["output_config"] as? [String: Any])?["effort"] as? String, "high")

        let legacy = NativeAgentClient(configuration: AgentConfiguration(
            baseURL: "https://example.test",
            model: "claude-opus-4-5-20251101",
            api: RouterAPIKind.anthropic.rawValue,
            effort: "high",
            usageMode: .economy,
            supportsLegacyThinkingBudget: true
        ))
        let legacyBody = legacy.makeBody(
            messages: [AgentMessage(role: .user, content: "answer briefly")],
            tools: [],
            cachePolicy: AgentCachePolicy()
        )
        XCTAssertNotNil(legacyBody["thinking"])
        XCTAssertNil(legacyBody["output_config"])
    }

    func testResponsesToolOutputItemsAreNormalizedWithTheMessage() {
        let original = String(repeating: "output ", count: 2_000)
        let message = AgentMessage(
            role: .tool,
            content: original,
            toolCallID: "call-1",
            providerItems: [[
                "type": .string("function_call_output"),
                "output": .string(original),
            ]]
        )
        let normalized = EconomyToolOutputPolicy.normalizeMessages([message]).first
        XCTAssertNotEqual(normalized?.content, original)
        XCTAssertEqual(normalized?.providerItems.first?["output"]?.string, normalized?.content)
    }

    func testToolNormalizationKeepsAnAlreadySentPrefixStableAcrossTurns() {
        var firstTurn = [AgentMessage(role: .user, content: "inspect the project")]
        for index in 0..<3 {
            let callID = "call-\(index)"
            firstTurn.append(AgentMessage(
                role: .assistant,
                content: "",
                toolCalls: [AgentToolCall(id: callID, name: "run_command", arguments: "{}")]
            ))
            firstTurn.append(AgentMessage(
                role: .tool,
                content: String(repeating: "line \(index)\n", count: 2_000),
                name: "run_command",
                toolCallID: callID
            ))
        }
        let laterTurn = firstTurn + [
            AgentMessage(role: .assistant, content: "done"),
            AgentMessage(role: .user, content: "continue")
        ]

        let normalizedFirst = EconomyToolOutputPolicy.normalizeMessages(firstTurn)
        let normalizedLater = EconomyToolOutputPolicy.normalizeMessages(laterTurn)

        XCTAssertEqual(
            Array(normalizedLater.prefix(normalizedFirst.count)),
            normalizedFirst,
            "Appending a turn must not rewrite the provider-facing prefix"
        )
    }

    func testProviderToolOrderIsCanonical() {
        let client = NativeAgentClient(configuration: AgentConfiguration(
            baseURL: "https://example.test",
            model: "model",
            api: RouterAPIKind.openAICompatible.rawValue
        ))
        let body = client.makeBody(
            messages: [AgentMessage(role: .user, content: "use a tool")],
            tools: [
                AgentToolDefinition(name: "z_tool", description: "z", parameters: .object([:])),
                AgentToolDefinition(name: "a_tool", description: "a", parameters: .object([:])),
            ],
            cachePolicy: AgentCachePolicy()
        )

        let tools = (body["tools"] as? [[String: Any]]) ?? []
        let names = tools.compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
        XCTAssertEqual(names, ["a_tool", "z_tool"])
    }
}

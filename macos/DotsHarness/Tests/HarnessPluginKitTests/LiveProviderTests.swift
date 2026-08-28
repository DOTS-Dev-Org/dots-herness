// Copyright (c) 2026 DOTS
// Live end-to-end probe of the real provider transports, driven through the same
// NativeAgentClient the app uses. Opt-in: needs connected accounts + network, so
// it only runs when DOTS_LIVE=1 is set.
//
//   DOTS_LIVE=1 swift test --filter LiveProviderTests
//
// Every model the account's provider spec advertises is exercised, so a retired
// upstream model id shows up here instead of as an HTTP 400 in the UI.

import XCTest
@testable import DotsHarnessCore

final class LiveProviderTests: XCTestCase {
    private var enabled: Bool { ProcessInfo.processInfo.environment["DOTS_LIVE"] == "1" }

    /// Quota / credit / rate-limit refusals say the account is out of budget, not
    /// that the transport is wrong. They must not fail the suite.
    private func isAccountLimit(_ message: String) -> Bool {
        ["credits", "usage limit", "rate limit", "quota", "insufficient balance"]
            .contains { message.localizedCaseInsensitiveContains($0) }
    }

    @MainActor
    func testEveryAdvertisedModelAnswers() async throws {
        try XCTSkipUnless(enabled, "Set DOTS_LIVE=1 to run the live provider probe.")
        let store = NativeProviderStore(paths: .default())
        let accounts = store.state.accounts.filter(\.active)
        try XCTSkipIf(accounts.isEmpty, "No active provider accounts are connected.")

        var failures: [String] = []
        for account in accounts {
            let key = try store.credential(for: account)
            let models = RouterCatalog.spec(for: account.provider)?.models.map(\.id) ?? [account.model]
            for model in models {
                let configuration = AgentConfiguration(
                    baseURL: account.baseURL,
                    model: model,
                    apiKey: key,
                    provider: RouterCatalog.label(for: account.provider),
                    api: account.api,
                    sessionAccountID: account.sessionAccountID,
                    specID: account.provider,
                    authType: account.authType
                )
                do {
                    let response = try await NativeAgentClient(configuration: configuration)
                        .complete(messages: [AgentMessage(role: .user, content: "Reply with the single word: pong")])
                    let text = response.message.content.trimmingCharacters(in: .whitespacesAndNewlines)
                    print("OK   \(account.provider)/\(model) -> \"\(text.prefix(40))\"")
                    if text.isEmpty { failures.append("\(account.provider)/\(model): empty reply") }
                } catch {
                    let message = (error as? NativeAgentError)?.message ?? error.localizedDescription
                    if isAccountLimit(message) {
                        print("SKIP \(account.provider)/\(model) -> \(message)")
                        continue
                    }
                    print("FAIL \(account.provider)/\(model) -> \(message)")
                    failures.append("\(account.provider)/\(model): \(message)")
                }
            }
        }
        XCTAssertTrue(failures.isEmpty, "Live provider failures:\n" + failures.joined(separator: "\n"))
    }

    /// The picker must list models straight after launch. Before, models only
    /// appeared after a forced refresh, so a restart left the composer empty
    /// until the user re-connected an account in Settings.
    @MainActor
    func testModelsAreAvailableWithoutAForcedRefresh() async throws {
        try XCTSkipUnless(enabled, "Set DOTS_LIVE=1 to run the live provider probe.")
        let cold = RouterController()
        try XCTSkipIf(cold.store.state.accounts.filter(\.active).isEmpty, "No active accounts connected.")
        XCTAssertFalse(cold.models.isEmpty, "models must be seeded from the registry at init")

        // The lazy path the app uses on launch must also populate.
        let lazy = RouterController()
        await lazy.refreshModelsIfNeeded()
        XCTAssertFalse(lazy.models.isEmpty, "refreshModelsIfNeeded must populate models")
        print("seeded=\(cold.models.map(\.id)) lazy=\(lazy.models.count)")
    }

    /// Drives the full app path — RouterController picks the account, resolves the
    /// model and builds the configuration — so a routing regression fails here
    /// even when the raw transport is fine.
    @MainActor
    func testRouterCompletesForEveryAdvertisedModel() async throws {
        try XCTSkipUnless(enabled, "Set DOTS_LIVE=1 to run the live provider probe.")
        let router = RouterController()
        await router.refreshModels(force: true)
        try XCTSkipIf(router.models.isEmpty, "No models resolved — connect a provider account first.")
        print("router models: \(router.models.map(\.id))")

        var failures: [String] = []
        for model in router.models {
            do {
                let response = try await router.complete(
                    messages: [AgentMessage(role: .user, content: "Reply with the single word: pong")],
                    model: model.id
                )
                let text = response.message.content.trimmingCharacters(in: .whitespacesAndNewlines)
                print("OK   router/\(model.id) -> \"\(text.prefix(40))\"")
                if text.isEmpty { failures.append("\(model.id): empty reply") }
            } catch {
                let message = (error as? NativeAgentError)?.message ?? error.localizedDescription
                // A plan/entitlement gate is an account fact, not a routing bug.
                if isAccountLimit(message) {
                    print("SKIP router/\(model.id) -> \(message)")
                    continue
                }
                print("FAIL router/\(model.id) -> \(message)")
                failures.append("\(model.id): \(message)")
            }
        }
        XCTAssertTrue(failures.isEmpty, "Router routing failures:\n" + failures.joined(separator: "\n"))
    }

    /// Every effort level the registry advertises must be accepted by the real
    /// provider — an unsupported level is an HTTP 400, so a wrong entry in
    /// providers.json breaks the picker for that model.
    @MainActor
    func testAdvertisedEffortLevelsAreAccepted() async throws {
        try XCTSkipUnless(enabled, "Set DOTS_LIVE=1 to run the live provider probe.")
        let router = RouterController()
        await router.refreshModels(force: true)
        try XCTSkipIf(router.models.isEmpty, "No models resolved — connect a provider account first.")

        var failures: [String] = []
        for model in router.models where !model.efforts.isEmpty {
            router.selectedModelID = model.id
            for level in model.efforts {
                router.selectedEffort = level
                do {
                    _ = try await router.complete(
                        messages: [AgentMessage(role: .user, content: "hi")],
                        model: model.id
                    )
                    print("OK   \(model.id) effort=\(level)")
                } catch {
                    let message = (error as? NativeAgentError)?.message ?? error.localizedDescription
                    if isAccountLimit(message) {
                        print("SKIP \(model.id) effort=\(level) -> \(message)")
                        continue
                    }
                    print("FAIL \(model.id) effort=\(level) -> \(message)")
                    failures.append("\(model.id)/\(level): \(message)")
                }
            }
        }
        router.selectedEffort = ""
        XCTAssertTrue(failures.isEmpty, "Effort level failures:\n" + failures.joined(separator: "\n"))
    }

    @MainActor
    func testToolCallRoundTrip() async throws {
        try XCTSkipUnless(enabled, "Set DOTS_LIVE=1 to run the live provider probe.")
        let store = NativeProviderStore(paths: .default())
        guard let account = store.state.accounts.first(where: \.active) else {
            throw XCTSkip("No active provider accounts are connected.")
        }
        let configuration = AgentConfiguration(
            baseURL: account.baseURL,
            model: account.model,
            apiKey: try store.credential(for: account),
            provider: RouterCatalog.label(for: account.provider),
            api: account.api,
            sessionAccountID: account.sessionAccountID,
            specID: account.provider,
            authType: account.authType
        )
        let tool = AgentToolDefinition(
            name: "get_weather",
            description: "Get the current weather for a city.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object(["city": .object(["type": .string("string")])]),
                "required": .array([.string("city")]),
            ])
        )
        do {
            let response = try await NativeAgentClient(configuration: configuration).complete(
                messages: [AgentMessage(role: .user, content: "What is the weather in Istanbul? Use the tool.")],
                tools: [tool]
            )
            print("tool calls: \(response.message.toolCalls.map(\.name))")
            XCTAssertEqual(response.message.toolCalls.first?.name, "get_weather")
        } catch {
            let message = (error as? NativeAgentError)?.message ?? error.localizedDescription
            try XCTSkipIf(isAccountLimit(message), "account out of budget: \(message)")
            throw error
        }
    }

    /// API-key providers, driven through the real transport. The key comes from
    /// the environment so no credential is ever written into the repo:
    ///   DOTS_TEST_OPENCODE_KEY=sk-… DOTS_LIVE=1 swift test --filter LiveProviderTests
    @MainActor
    func testAPIKeyProvidersAnswerThroughTheRealTransport() async throws {
        try XCTSkipUnless(enabled, "Set DOTS_LIVE=1 to run the live provider probe.")
        let environment = ProcessInfo.processInfo.environment
        // provider spec id -> (env var holding its key, model to ping)
        let cases: [(spec: String, variable: String, model: String)] = [
            ("opencode", "DOTS_TEST_OPENCODE_KEY", "nemotron-3-ultra-free"),
            ("opencode-go", "DOTS_TEST_OPENCODE_KEY", "glm-5.1"),
            ("nvidia", "DOTS_TEST_NVIDIA_KEY", "deepseek-ai/deepseek-v4-flash-0731"),
            ("zai", "DOTS_TEST_ZAI_KEY", "glm-4.6"),
        ]
        var ran = 0
        var failures: [String] = []
        for probe in cases {
            guard let key = environment[probe.variable], !key.isEmpty else {
                print("SKIP \(probe.spec) — \(probe.variable) not set")
                continue
            }
            let spec = try XCTUnwrap(ProviderRegistry.shared.spec(probe.spec))
            let configuration = AgentConfiguration(
                baseURL: spec.transport.baseURL,
                model: probe.model,
                apiKey: key,
                provider: spec.name,
                api: RouterCatalog.apiKind(for: spec.transport.format).rawValue,
                specID: spec.id,
                authType: "apiKey"
            )
            ran += 1
            do {
                let response = try await NativeAgentClient(configuration: configuration)
                    .complete(messages: [AgentMessage(role: .user, content: "Reply with the single word: pong")])
                let text = response.message.content.trimmingCharacters(in: .whitespacesAndNewlines)
                print("OK   \(probe.spec)/\(probe.model) -> \"\(text.prefix(40))\"")
                if text.isEmpty { failures.append("\(probe.spec): empty reply") }
            } catch {
                let message = (error as? NativeAgentError)?.message ?? error.localizedDescription
                print("FAIL \(probe.spec)/\(probe.model) -> \(message)")
                failures.append("\(probe.spec): \(message)")
            }
        }
        try XCTSkipIf(ran == 0, "No provider keys supplied in the environment.")
        XCTAssertTrue(failures.isEmpty, "API-key provider failures:\n" + failures.joined(separator: "\n"))
    }

    /// Model listings must resolve for a key-gated provider too.
    @MainActor
    func testAPIKeyProviderListsModels() async throws {
        try XCTSkipUnless(enabled, "Set DOTS_LIVE=1 to run the live provider probe.")
        let key = ProcessInfo.processInfo.environment["DOTS_TEST_OPENCODE_KEY"] ?? ""
        try XCTSkipIf(key.isEmpty, "DOTS_TEST_OPENCODE_KEY not set.")
        for id in ["opencode", "opencode-go"] {
            let spec = try XCTUnwrap(ProviderRegistry.shared.spec(id))
            let url = try XCTUnwrap(URL(string: try XCTUnwrap(spec.apiKey?.modelsURL)))
            var request = URLRequest(url: url, timeoutInterval: 20)
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await URLSession.shared.data(for: request)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200, id)
            let payload = try JSONCodec.parse(data)
            guard case .array(let items) = payload["data"] else { return XCTFail("\(id): no model list") }
            print("\(id): \(items.count) models")
            XCTAssertFalse(items.isEmpty, id)
        }
    }

    /// Automatic routing, end to end: the planner turn and the worker turn must
    /// each land on a model the connected accounts can actually serve, and both
    /// must complete.
    @MainActor
    func testAutomaticRoutingPicksAndCompletes() async throws {
        try XCTSkipUnless(enabled, "Set DOTS_LIVE=1 to run the live provider probe.")
        let router = RouterController()
        await router.refreshModels(force: true)
        try XCTSkipIf(router.models.isEmpty, "No models resolved — connect a provider account first.")
        router.selectedModelID = ModelRouter.autoModelID

        let opening = [AgentMessage(role: .user, content: "Design a retry policy for our HTTP client.")]
        // A tool result is only valid when the preceding assistant turn actually
        // made the call it answers.
        let continuation = [
            AgentMessage(role: .user, content: "Design a retry policy."),
            AgentMessage(
                role: .assistant, content: "Reading the client.",
                toolCalls: [AgentToolCall(id: "call_1", name: "read_file", arguments: "{\"path\":\"a.swift\"}")]
            ),
            AgentMessage(role: .tool, content: "file read ok", toolCallID: "call_1"),
        ]
        let plan = try XCTUnwrap(router.previewAutoDecision(for: opening))
        let work = try XCTUnwrap(router.previewAutoDecision(for: continuation))
        print("planner -> \(plan.model) effort=\(plan.effort)")
        print("worker  -> \(work.model) effort=\(work.effort)")
        XCTAssertEqual(plan.role, "planner")
        XCTAssertEqual(work.role, "worker")
        XCTAssertTrue(router.models.contains { $0.id == plan.model })
        XCTAssertTrue(router.models.contains { $0.id == work.model })
        // The planner must be at least as capable as the worker.
        let planTier = ModelRouter.tier(of: try XCTUnwrap(router.models.first { $0.id == plan.model }))
        let workTier = ModelRouter.tier(of: try XCTUnwrap(router.models.first { $0.id == work.model }))
        XCTAssertTrue(planTier >= workTier, "planner (\(planTier)) must not be weaker than worker (\(workTier))")

        for (label, messages) in [("planner", opening), ("worker", continuation)] {
            do {
                let response = try await router.complete(messages: messages)
                let text = response.message.content.trimmingCharacters(in: .whitespacesAndNewlines)
                print("OK   auto/\(label) via \(router.lastAutoDecision?.model ?? "?") -> \"\(text.prefix(50))\"")
                XCTAssertFalse(text.isEmpty, "\(label) produced no text")
            } catch {
                let message = (error as? NativeAgentError)?.message ?? error.localizedDescription
                // Quota exhaustion across every connected account is an account
                // fact; routing already tried each provider before giving up.
                if isAccountLimit(message) {
                    print("SKIP auto/\(label) -> \(message)")
                    continue
                }
                XCTFail("auto/\(label): \(message)")
            }
        }
    }
}

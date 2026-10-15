import XCTest
@testable import HerNessMobile

final class MobilePromptHistoryTests: XCTestCase {
    func testOnlyTheLatestReadOfTheSameLinesKeepsItsBody() {
        func call(_ id: String, _ input: [String: Any]) -> [String: Any] {
            ["role": "assistant", "content": [["type": "tool_use", "id": id, "name": "read_file", "input": input]]]
        }
        func result(_ id: String, _ content: String) -> [String: Any] {
            ["role": "user", "content": [["type": "tool_result", "tool_use_id": id, "content": content]]]
        }
        let wire: [[String: Any]] = [
            ["role": "user", "content": [["type": "text", "text": "look"]]],
            call("a", ["path": "src/app.swift"]), result("a", "old body"),
            call("b", ["path": "src/app.swift", "offset": 251]), result("b", "second page"),
            ["role": "assistant", "content": [], "responses_output_items": [
                ["type": "function_call", "call_id": "c", "name": "read_file", "arguments": #"{"path":"./src/app.swift","offset":1}"#],
            ]],
            result("c", "new body"),
        ]
        func body(_ wire: [[String: Any]], _ index: Int) -> String? {
            ((wire[index]["content"] as? [[String: Any]])?.first)?["content"] as? String
        }

        let reduced = MobilePromptHistory.supersedeRepeatedReads(wire)

        XCTAssertEqual(body(reduced, 2), MobilePromptHistory.supersededReadMarker)
        XCTAssertEqual(body(reduced, 4), "second page")
        XCTAssertEqual(body(reduced, 6), "new body")
        let again = MobilePromptHistory.supersedeRepeatedReads(reduced)
        XCTAssertEqual((0..<again.count).map { body(again, $0) }, (0..<reduced.count).map { body(reduced, $0) })
    }

    func testUnchangedContextAndPolicyUpdateAreNotRepeatedAndReversionIsExplicit() {
        var history = MobilePromptHistory()
        XCTAssertEqual(history.capture(prompt: "one", policy: "policy one", context: "plugin"), "plugin\n\none")
        XCTAssertEqual(history.capture(prompt: "two", policy: "policy one", context: "plugin"), "two")
        XCTAssertTrue(history.capture(prompt: "three", policy: "policy two", context: "plugin").contains("policy two"))
        XCTAssertEqual(history.capture(prompt: "four", policy: "policy two", context: "plugin"), "four")
        XCTAssertTrue(history.capture(prompt: "five", policy: "policy one", context: "plugin").contains("policy one"))
        XCTAssertTrue(history.capture(prompt: "six", policy: "policy one", context: "").contains("No longer applies."))
        history.resetCapturedContext()
        XCTAssertEqual(history.capture(prompt: "seven", policy: "policy one", context: "plugin"), "plugin\n\nseven")
    }

    func testThresholdIsThePercentageOfTheProviderWindow() {
        XCTAssertEqual(MobilePromptHistory.compactionThreshold(window: 272_000, percent: 90), 244_800)
        XCTAssertEqual(MobilePromptHistory.compactionThreshold(window: 1_000_000, percent: 90), 900_000)
        XCTAssertEqual(MobilePromptHistory.compactionThreshold(window: 32_768, percent: 70), 22_937)
        XCTAssertEqual(MobilePromptHistory.compactionThreshold(window: 1_000_000, percent: 0), 1)
    }

    func testReloadRetainsCapturedContextAndLegacyHistoryStillDecodes() throws {
        var history = MobilePromptHistory()
        _ = history.capture(prompt: "one", policy: "policy", context: "plugin")
        _ = history.capture(prompt: "two", policy: "updated policy", context: "plugin")
        history = try JSONDecoder().decode(MobilePromptHistory.self, from: JSONEncoder().encode(history))
        XCTAssertEqual(history.capture(prompt: "three", policy: "updated policy", context: "plugin"), "three")
        let legacy = try JSONDecoder().decode(MobilePromptHistory.self, from: Data("{\"policy\":\"policy\"}".utf8))
        XCTAssertEqual(legacy.policy, "policy")
    }

    func testRetentionRejectionPreservesComparisonAndStaticBreakpoint() {
        var state = MobileCacheState()
        state.responseIDs["scope"] = "prior"
        state.unsupported.insert("cap|openai_retention")
        var body: [String: Any] = ["instructions": "policy", "input": [["role": "user", "content": "hello"]]]
        MobilePromptCache.configureResponsesCache(to: &body, endpoint: "https://api.openai.com/v1/responses", model: "gpt-5.6-luna", state: state, scope: "scope", capability: "cap")
        let options = body["prompt_cache_options"] as? [String: Any]
        XCTAssertEqual(options?["comparison_response_id"] as? String, "prior")
        XCTAssertNil(options?["ttl"])
        XCTAssertTrue(MobilePromptCache.canonicalJSON(body).contains("prompt_cache_breakpoint"))
        XCTAssertEqual(MobilePromptCache.rejectedFeature(status: 422, message: "prompt_cache_options.ttl rejected"), "openai_retention")
    }
    func testSchemaCacheControlPropertyRemainsPartOfWireFingerprint() {
        var body = cacheBody(1)
        body["tools"] = [["name": "read", "input_schema": ["properties": ["cache_control": ["type": "string"]]]]]
        let original = MobileCacheState.prefix(body)
        body["tools"] = [["name": "read", "input_schema": ["properties": ["cache_control": ["type": "number"]]]]]
        XCTAssertNotEqual(original, MobileCacheState.prefix(body))
    }

    func testAttachmentRestorationAddsOneNewNotice() {
        var state = MobileCacheState()
        _ = state.captureNotices(attachmentNotice: "source missing", plan: false)
        XCTAssertEqual(state.captureNotices(attachmentNotice: nil, plan: false).count, 1)
        XCTAssertTrue(state.captureNotices(attachmentNotice: nil, plan: false).isEmpty)
    }

    func testInvalidReadDoesNotRefreshAcceptedBoundary() {
        var state = MobileCacheState()
        let write: [String: Any] = ["usage": ["input_tokens": 0, "cache_read_input_tokens": 0, "cache_creation_input_tokens": 4096]]
        let accepted = state.accept(body: cacheBody(1), response: write, scope: "a", anthropic: true, ttl: 3600, terminal: true, now: 0)
        let invalid: [String: Any] = ["usage": ["input_tokens": 0, "cache_read_input_tokens": -1, "cache_creation_input_tokens": 0]]
        let unknown = state.accept(body: cacheBody(2), response: invalid, scope: "a", anthropic: true, ttl: 3600, terminal: true, now: 1)
        XCTAssertNil(unknown.reusedTokens)
        XCTAssertEqual(state.baselines["a"]?.eventID, accepted.eventID)
    }

    func testUsageRoutesRemainSeparateAfterAccountChangeAndReload() throws {
        var state = MobileCacheState()
        _ = state.accept(body: cacheBody(1), response: [:], scope: "account-one", anthropic: true, ttl: 3600, terminal: false)
        _ = state.accept(body: cacheBody(1), response: [:], scope: "account-two", anthropic: true, ttl: 3600, terminal: false)
        let restored = try JSONDecoder().decode(MobileCacheState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(restored.evidence.count, 2)
        XCTAssertEqual(restored.currentRouteEvidence.count, 1)
    }
    private func cacheBody(_ count: Int) -> [String: Any] {
        var body: [String: Any] = ["model": "claude-sonnet-4-5", "system": "policy", "tools": [["name": "read", "input_schema": ["type": "object"]]], "messages": (0..<count).map { ["role": "user", "content": [["type": "text", "text": "turn \($0)"]]] }]
        MobilePromptCache.applyAnthropicCacheBreakpoints(to: &body)
        return body
    }

    func testFourCheckpointsPreservePreviousBoundaryBeyondTwentyPositions() throws {
        var first = cacheBody(1)
        var state = MobileCacheState()
        let response: [String: Any] = ["id": "msg_first", "usage": ["input_tokens": 0, "cache_read_input_tokens": 0, "cache_creation_input_tokens": 4096]]
        _ = state.accept(body: first, response: response, scope: "account", anthropic: true, ttl: 3600, terminal: true, now: 0)
        let before = MobilePromptCache.canonicalJSON(first)
        var next = cacheBody(30)
        let previous = state.previousBoundary(body: next, scope: "account")
        XCTAssertEqual(previous, 1)
        MobilePromptCache.applyAnthropicCacheBreakpoints(to: &next, previousMessageCount: previous)
        let messages = try XCTUnwrap(next["messages"] as? [[String: Any]])
        XCTAssertNotNil((messages[0]["content"] as? [[String: Any]])?.last?["cache_control"])
        XCTAssertNotNil((messages[29]["content"] as? [[String: Any]])?.last?["cache_control"])
        XCTAssertEqual(MobilePromptCache.canonicalJSON(first), before)
        MobilePromptCache.applyAnthropicCacheBreakpoints(to: &first, previousMessageCount: 1)
        let sameMessages = try XCTUnwrap(first["messages"] as? [[String: Any]])
        XCTAssertEqual(sameMessages.count, 1)
    }

    func testExactReuseKeepsExpiredMissesAndUnknownSeparate() throws {
        var state = MobileCacheState()
        let cold: [String: Any] = ["id": "one", "usage": ["input_tokens": 0, "cache_read_input_tokens": 0, "cache_creation_input_tokens": 4096]]
        let first = state.accept(body: cacheBody(1), response: cold, scope: "a", anthropic: true, ttl: 3600, terminal: true, now: 0)
        XCTAssertNil(first.eligibleTokens)
        let expired: [String: Any] = ["id": "two", "usage": ["input_tokens": 3, "cache_read_input_tokens": 0, "cache_creation_input_tokens": 4200]]
        let miss = state.accept(body: cacheBody(2), response: expired, scope: "a", anthropic: true, ttl: 3600, terminal: true, now: 3601)
        XCTAssertEqual(miss.classification, "expired")
        XCTAssertNil(miss.eligibleTokens)
        XCTAssertEqual(miss.reason, "ttl_elapsed")
        XCTAssertEqual(miss.usage.inputTokens, 4203)
        XCTAssertNil(MobileCacheSummary(events: [miss]).reuseRate)
        let unknown = state.accept(body: cacheBody(3), response: ["id": "three", "usage": ["input_tokens": 4400]], scope: "a", anthropic: true, ttl: 3600, terminal: true, now: 3602)
        XCTAssertNil(unknown.reusedTokens)
        XCTAssertNil(unknown.usage.rawHitRate)
        XCTAssertEqual(state.baselines["a"]?.exactTokens, 4200)
        XCTAssertEqual(MobileCacheSummary(events: [miss, unknown]).coverage, 0)
    }

    func testRewrittenPrefixInsideTTLIsAMeasuredMissAndSettingsChangeIsNot() {
        var state = MobileCacheState()
        let write: [String: Any] = ["id": "one", "usage": ["input_tokens": 0, "cache_read_input_tokens": 0, "cache_creation_input_tokens": 4096]]
        _ = state.accept(body: cacheBody(1), response: write, scope: "a", anthropic: true, ttl: 3600, terminal: true, now: 0)
        var rewritten = cacheBody(2)
        var messages = rewritten["messages"] as! [[String: Any]]
        messages[0]["content"] = [["type": "text", "text": "rewritten"]]
        rewritten["messages"] = messages
        let lost = state.accept(body: rewritten, response: write, scope: "a", anthropic: true, ttl: 3600, terminal: true, now: 1)
        XCTAssertEqual(lost.classification, "eligible")
        XCTAssertEqual(lost.reason, "messages_changed")
        XCTAssertEqual(lost.eligibleTokens, 4096)
        XCTAssertEqual(lost.reusedTokens, 0)
        rewritten["model"] = "claude-opus-5"
        let changed = state.accept(body: rewritten, response: write, scope: "a", anthropic: true, ttl: 3600, terminal: true, now: 2)
        XCTAssertEqual(changed.classification, "changed")
        XCTAssertNil(changed.eligibleTokens)
        XCTAssertEqual(MobileCacheSummary(events: [lost, changed]).coverage, 1)
    }

    func testGatewayReadOnlyCountersDoNotProvePreviousWrittenInput() {
        var state = MobileCacheState()
        let body: [String: Any] = ["model": "gpt-5.6-luna", "input": [["role": "user", "content": "one"]]]
        func usage(_ input: Int, _ cached: Int) -> [String: Any] { ["usage": ["input_tokens": input, "input_tokens_details": ["cached_tokens": cached]]] }
        _ = state.accept(body: body, response: usage(5000, 0), scope: "codex", anthropic: false, ttl: 300, terminal: true, now: 0)
        let hit = state.accept(body: body, response: usage(5100, 4900), scope: "codex", anthropic: false, ttl: 300, terminal: true, now: 1)
        XCTAssertNil(hit.eligibleTokens)
        XCTAssertNil(hit.reusedTokens)
        let late = state.accept(body: body, response: usage(5100, 0), scope: "codex", anthropic: false, ttl: 300, terminal: true, now: 301)
        XCTAssertEqual(late.classification, "expired")
    }

    func testReadOnlyOpenAICountersRemainUnknownAndAccountsAreIsolated() {
        var state = MobileCacheState()
        let body: [String: Any] = ["model": "gpt-5.6-luna", "input": [["role": "user", "content": "one"]]]
        let response: [String: Any] = ["id": "resp_one", "usage": ["input_tokens": 5000, "input_tokens_details": ["cached_tokens": 4096]], "prompt_cache_diagnostics": ["cache_missed_tokens": 1000, "comparison_reusable_tokens": 4096]]
        _ = state.accept(body: body, response: response, scope: "one", anthropic: false, ttl: 1800, terminal: true)
        XCTAssertNil(state.baselines["one"]?.exactTokens)
        XCTAssertNil(state.previousBoundary(body: body, scope: "two"))
        XCTAssertEqual(state.responseIDs["one"], "resp_one")
        XCTAssertNil(state.responseIDs["two"])
    }

    func testCatalogEpochAndPersistedEvidenceSurviveReload() throws {
        var state = MobileCacheState()
        _ = state.catalog([["name": "read", "input_schema": ["type": "object", "properties": ["b": ["type": "string"], "a": ["type": "string"]]]]])
        _ = state.catalog([["input_schema": ["properties": ["a": ["type": "string"], "b": ["type": "string"]], "type": "object"], "name": "read"]])
        XCTAssertEqual(state.epoch, 1)
        _ = state.catalog([])
        XCTAssertEqual(state.epoch, 2)
        for _ in 0..<105 { _ = state.accept(body: cacheBody(1), response: [:], scope: "a", anthropic: true, ttl: 3600, terminal: false) }
        let restored = try JSONDecoder().decode(MobileCacheState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(restored.epoch, 2)
        XCTAssertEqual(restored.evidence.count, 101)
        XCTAssertEqual(MobileCacheSummary(events: restored.currentRouteEvidence).candidates.count, 100)
        XCTAssertEqual(restored.catalogJSON, "[]")
    }

    func testStreamDiagnosticsAndFeatureRejectionsAreSafe() throws {
        let stream = "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_one\",\"diagnostics\":{\"cache_miss_reason\":{\"type\":\"tools_changed\"}},\"usage\":{\"input_tokens\":0,\"cache_read_input_tokens\":4096,\"cache_creation_input_tokens\":0}}}\n\ndata: {\"type\":\"message_delta\",\"usage\":{\"output_tokens\":1}}\n\n"
        let object = try XCTUnwrap(MobilePromptCache.responseObject(Data(stream.utf8)))
        XCTAssertEqual(object["id"] as? String, "msg_one")
        XCTAssertEqual(MobileCacheUsage.parse(object, anthropic: true).cachedTokens, 4096)
        XCTAssertEqual(((object["diagnostics"] as? [String: Any])?["cache_miss_reason"] as? [String: Any])?["type"] as? String, "tools_changed")
        XCTAssertNil(MobilePromptCache.rejectedFeature(status: 500, message: "diagnostics"))
        XCTAssertNil(MobilePromptCache.rejectedFeature(status: 400, message: "invalid unrelated setting"))
        XCTAssertEqual(MobilePromptCache.rejectedFeature(status: 422, message: "previous_message_id not supported"), "claude_diagnostics")
        XCTAssertTrue(MobilePromptCache.supportsDiagnostics(model: "gpt-5.6-luna"))
        XCTAssertFalse(MobilePromptCache.supportsDiagnostics(model: "gpt-4.1"))
    }

    func testResponsesCacheFieldsAreGatedByActualRouteAndModel() throws {
        var state = MobileCacheState()
        state.responseIDs["a"] = "resp_previous"
        let original: [String: Any] = ["model": "gpt-5.6-luna", "instructions": "policy", "input": [["role": "user", "content": "question"]]]
        var direct = original
        MobilePromptCache.configureResponsesCache(to: &direct, endpoint: "https://api.openai.com/v1/responses", model: "gpt-5.6-luna", state: state, scope: "a", capability: "api")
        XCTAssertNil(direct["instructions"])
        let first = try XCTUnwrap((direct["input"] as? [[String: Any]])?.first)
        XCTAssertEqual(first["role"] as? String, "developer")
        XCTAssertNotNil((first["content"] as? [[String: Any]])?.first?["prompt_cache_breakpoint"])
        XCTAssertEqual((direct["prompt_cache_options"] as? [String: Any])?["ttl"] as? String, "30m")
        var codex = original
        MobilePromptCache.configureResponsesCache(to: &codex, endpoint: "https://chatgpt.com/backend-api/codex/responses", model: "gpt-5.6-luna", state: state, scope: "a", capability: "codex")
        XCTAssertEqual(codex["instructions"] as? String, "policy")
        XCTAssertNil((codex["prompt_cache_options"] as? [String: Any])?["ttl"])
        XCTAssertEqual((codex["prompt_cache_options"] as? [String: Any])?["comparison_response_id"] as? String, "resp_previous")
        var legacy = original
        MobilePromptCache.configureResponsesCache(to: &legacy, endpoint: "https://api.openai.com/v1/responses", model: "gpt-4.1", state: state, scope: "a", capability: "api")
        XCTAssertEqual(MobilePromptCache.canonicalJSON(legacy), MobilePromptCache.canonicalJSON(original))
        var proxy = original
        MobilePromptCache.configureResponsesCache(to: &proxy, endpoint: "https://proxy.example/responses", model: "gpt-5.6-luna", state: state, scope: "a", capability: "api")
        XCTAssertEqual(MobilePromptCache.canonicalJSON(proxy), MobilePromptCache.canonicalJSON(original))
    }

    func testNoticesAppendOnceAndDoNotRewritePreviousHistory() {
        var state = MobileCacheState()
        var history = ["question", "answer"]
        let oldHistory = history
        history.append(contentsOf: state.captureNotices(attachmentNotice: "V2 changed", plan: true))
        XCTAssertEqual(Array(history.prefix(2)), oldHistory)
        XCTAssertTrue(state.captureNotices(attachmentNotice: "V2 changed", plan: true).isEmpty)
        let execution = state.captureNotices(attachmentNotice: "V3 changed", plan: false)
        XCTAssertEqual(execution.count, 2)
        XCTAssertTrue(execution.last!.contains("execution"))
    }

    func testCodexRetentionIsUnverifiedEvenWhenEntireInputWasReadCached() {
        var state = MobileCacheState()
        let body: [String: Any] = ["model": "gpt-5.6-luna", "input": [["role": "user", "content": "one"]]]
        let response: [String: Any] = ["usage": ["input_tokens": 4096, "input_tokens_details": ["cached_tokens": 4096]]]
        _ = state.accept(body: body, response: response, scope: "codex", anthropic: false, ttl: nil, terminal: true)
        let next = state.accept(body: body, response: response, scope: "codex", anthropic: false, ttl: nil, terminal: true)
        XCTAssertNil(next.eligibleTokens)
        XCTAssertEqual(next.reason, "ttl_unverified")
        XCTAssertEqual(next.usage.rawHitRate, 1)
    }

    func testRegressedTerminalUsageDoesNotAdvanceAcceptedCheckpoint() {
        var state = MobileCacheState()
        let cold: [String: Any] = ["id": "first", "usage": ["input_tokens": 0, "cache_read_input_tokens": 0, "cache_creation_input_tokens": 4096]]
        let first = state.accept(body: cacheBody(1), response: cold, scope: "a", anthropic: true, ttl: 3600, terminal: true)
        let smaller: [String: Any] = ["id": "second", "usage": ["input_tokens": 100, "cache_read_input_tokens": 500, "cache_creation_input_tokens": 0]]
        let result = state.accept(body: cacheBody(2), response: smaller, scope: "a", anthropic: true, ttl: 3600, terminal: true)
        XCTAssertEqual(result.eligibleTokens, 4096)
        XCTAssertEqual(result.reusedTokens, 500)
        XCTAssertEqual(state.baselines["a"]?.eventID, first.eventID)
        XCTAssertEqual(state.baselines["a"]?.count, 1)
        XCTAssertEqual(state.responseIDs["a"], "second")
    }
    func testCacheTTLAndCanonicalToolJSONDoNotAlterHistory() throws {
        var body: [String: Any] = ["system": "policy", "messages": [["role": "user", "content": "question"]]]
        MobilePromptCache.applyAnthropicCacheBreakpoints(to: &body)
        var system = try XCTUnwrap(body["system"] as? [[String: Any]])
        XCTAssertEqual((system[0]["cache_control"] as? [String: String])?["ttl"], "1h")
        MobilePromptCache.applyAnthropicCacheBreakpoints(to: &body, ttl: "5m")
        system = try XCTUnwrap(body["system"] as? [[String: Any]])
        XCTAssertEqual((system[0]["cache_control"] as? [String: String])?["ttl"], "5m")
        XCTAssertEqual(system[0]["text"] as? String, "policy")
        let one = AgentToolSpec(name: "read", description: "read", schema: ["type": "object", "properties": ["b": ["type": "string"], "a": ["type": "string"]]]) { _ in "" }
        let two = AgentToolSpec(name: "read", description: "read", schema: ["properties": ["a": ["type": "string"], "b": ["type": "string"]], "type": "object"]) { _ in "" }
        XCTAssertEqual(MobilePromptCache.toolFingerprint([one]), MobilePromptCache.toolFingerprint([two]))
    }
    func testNewContextDoesNotRewritePreviousTurnOrPolicy() throws {
        var history = MobilePromptHistory()
        let first = history.capture(prompt: "one", policy: "policy one", context: "plugin one")
        var messages = [first, "tool result", "answer"]
        let previous = messages
        history = try JSONDecoder().decode(MobilePromptHistory.self, from: JSONEncoder().encode(history))
        messages.append(history.capture(prompt: "two", policy: "policy two", context: "plugin two"))
        XCTAssertEqual(history.policy, "policy one")
        XCTAssertEqual(Array(messages.prefix(previous.count)), previous)
        XCTAssertTrue(messages.last!.contains("policy two"))
        XCTAssertTrue(messages.last!.contains("plugin two"))
        XCTAssertFalse(messages.last!.contains("plugin one"))
    }

    func testEmptyContextAndResetStartCleanly() {
        var history = MobilePromptHistory()
        XCTAssertEqual(history.capture(prompt: "one", policy: "policy", context: ""), "one")
        XCTAssertEqual(history.capture(prompt: "two", policy: "policy", context: ""), "two")
        history = MobilePromptHistory()
        XCTAssertEqual(history.capture(prompt: "new", policy: "new policy", context: ""), "new")
        XCTAssertEqual(history.policy, "new policy")
    }

    func testPromptCacheKeyIsSharedByConversationsAndSeparatesAccountsAndTools() {
        func key(account: String = "openai", tools: String = "tools") -> String {
            MobilePromptCache.key(provider: "openai", route: "openai-chat", model: "gpt-4.1", accountScope: account, toolFingerprint: tools)
        }
        // No conversation or compaction input: a new chat reuses the stable prefix.
        XCTAssertEqual(key(), key())
        XCTAssertNotEqual(key(), key(account: "other"))
        XCTAssertNotEqual(key(), key(tools: "changed"))
        XCTAssertTrue(key().hasPrefix("herness:mobile-v1:"))
    }

    func testContextCompactionKeepsWholeToolExchangeAndNewestTurnWithoutFileBodies() throws {
        let messages: [[String: Any]] = [
            ["role": "system", "content": "stable policy"],
            ["role": "user", "content": [["type": "text", "text": "Inspect the project files."]]],
            ["role": "assistant", "content": [["type": "tool_use", "id": "read-1", "name": "read_file", "input": ["path": "Sources/App.swift"]]]],
            ["role": "user", "content": [["type": "tool_result", "tool_use_id": "read-1", "content": "PRIVATE_FILE_BODY_SHOULD_NOT_BE_REPLAYED"]]],
            ["role": "assistant", "content": [["type": "text", "text": "The file defines the app entry point."]]],
            ["role": "user", "content": [["type": "text", "text": "Now update the launch screen."]]],
            ["role": "assistant", "content": [["type": "text", "text": "I will inspect the launch view."]], "responses_output_items": [["type": "message"]]],
        ]

        let selection = try XCTUnwrap(MobileContextCompaction.select(messages: messages, targetTokens: 1_024) { _ in 100 })
        XCTAssertEqual(selection.recentMessages.count, 2)
        XCTAssertTrue(selection.archiveText.contains("Inspect the project files."))
        XCTAssertTrue(selection.archiveText.contains("Sources/App.swift"))
        XCTAssertTrue(selection.archiveText.contains("file body omitted"))
        XCTAssertFalse(selection.archiveText.contains("PRIVATE_FILE_BODY_SHOULD_NOT_BE_REPLAYED"))

        let summary = """
        1. KULLANICI HEDEFİ: Update the launch screen.
        2. YAPILAN DEĞİŞİKLİKLER: Sources/App.swift was inspected.
        3. ALINAN KARARLAR VE KISITLAR: Preserve the current app architecture.
        4. MEVCUT DURUM VE SON KANITLAR: The latest turn is still active.
        """
        XCTAssertTrue(MobileContextCompaction.isValidSummary(summary))
        let compacted = selection.compose(summary: summary, preserveProviderItems: true)
        XCTAssertEqual(compacted.count, 4)
        XCTAssertEqual((compacted.last?["responses_output_items"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual((compacted[1]["content"] as? [[String: Any]])?.first?["text"] as? String, MobileContextCompaction.summaryMarker + "\n" + summary)
    }

    func testOversizedArchiveKeepsNewestEvidenceAndMarksOmittedMiddle() throws {
        func text(_ role: String, _ value: String) -> [String: Any] {
            ["role": role, "content": [["type": "text", "text": value]]]
        }
        var messages: [[String: Any]] = []
        for index in 0..<20 {
            messages.append(text("user", String(repeating: "u", count: 5_900) + "USER_\(String(format: "%02d", index))"))
            messages.append(text("assistant", String(repeating: "x", count: 5_900) + "ARCHIVE_TAIL_\(String(format: "%02d", index))"))
        }

        let selection = try XCTUnwrap(MobileContextCompaction.select(messages: messages, targetTokens: 1_024) { _ in 100 })

        XCTAssertEqual(selection.recentMessages.count, 10)
        XCTAssertTrue(selection.archiveText.contains("[… compacted …]"))
        XCTAssertTrue(selection.archiveText.contains("ARCHIVE_TAIL_14"))
        XCTAssertFalse(selection.archiveText.contains("ARCHIVE_TAIL_15"))
        XCTAssertLessThanOrEqual(selection.archiveText.utf8.count, MobileContextCompaction.maximumArchiveCharacters)
        XCTAssertTrue(MobileContextCompaction.fallbackSummary(previousSummary: nil, archiveText: selection.archiveText).contains("atlandı"))
    }
}

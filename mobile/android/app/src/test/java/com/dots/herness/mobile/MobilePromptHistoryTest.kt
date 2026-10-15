package com.dots.herness.mobile

import org.junit.Assert.*
import org.junit.Test
import org.json.JSONObject
import org.json.JSONArray

class MobilePromptHistoryTest {
    @Test fun `only the latest read of the same lines keeps its body`() {
        fun call(id: String, input: JSONObject) = JSONObject().put("role", "assistant").put("content", JSONArray().put(
            JSONObject().put("type", "tool_use").put("id", id).put("name", "read_file").put("input", input)))
        fun result(id: String, content: String) = JSONObject().put("role", "user").put("content", JSONArray().put(
            JSONObject().put("type", "tool_result").put("tool_use_id", id).put("content", content)))
        val wire = listOf(
            JSONObject().put("role", "user").put("content", JSONArray().put(JSONObject().put("type", "text").put("text", "look"))),
            call("a", JSONObject().put("path", "src/app.kt")), result("a", "old body"),
            call("b", JSONObject().put("path", "src/app.kt").put("offset", 251)), result("b", "second page"),
            JSONObject().put("role", "assistant").put("content", JSONArray()).put("responses_output_items", JSONArray().put(
                JSONObject().put("type", "function_call").put("call_id", "c").put("name", "read_file")
                    .put("arguments", "{\"path\":\"./src/app.kt\",\"offset\":1}"))),
            result("c", "new body"),
        )
        fun body(index: Int) = wire[index].getJSONArray("content").getJSONObject(0).getString("content")

        assertTrue(MobilePromptHistory.supersedeRepeatedReads(wire))
        assertEquals(MobilePromptHistory.SUPERSEDED_READ_MARKER, body(2))
        assertEquals("second page", body(4))
        assertEquals("new body", body(6))
        // Running it again changes nothing, so the persisted prefix stays stable.
        assertFalse(MobilePromptHistory.supersedeRepeatedReads(wire))
    }

    @Test fun `unchanged context and policy updates are sent once and reversion is explicit`() {
        val history = MobilePromptHistory()
        assertEquals("plugin\n\none", history.capture("one", "policy one", "plugin"))
        assertEquals("two", history.capture("two", "policy one", "plugin"))
        assertTrue(history.capture("three", "policy two", "plugin").contains("policy two"))
        assertEquals("four", history.capture("four", "policy two", "plugin"))
        assertTrue(history.capture("five", "policy one", "plugin").contains("policy one"))
        assertTrue(history.capture("six", "policy one", "").contains("No longer applies."))
        history.resetCapturedContext()
        assertEquals("plugin\n\nseven", history.capture("seven", "policy one", "plugin"))
    }

    @Test fun `threshold is the percentage of the provider window`() {
        assertEquals(244_800, MobilePromptHistory.compactionThreshold(272_000, 90))
        assertEquals(900_000, MobilePromptHistory.compactionThreshold(1_000_000, 90))
        assertEquals(22_937, MobilePromptHistory.compactionThreshold(32_768, 70))
        assertEquals(1, MobilePromptHistory.compactionThreshold(1_000_000, 0))
    }

    @Test fun `reload retains captured context and legacy history still restores`() {
        var history = MobilePromptHistory()
        history.capture("one", "policy", "plugin")
        history.capture("two", "updated policy", "plugin")
        history = MobilePromptHistory.restore(history.json())
        assertEquals("three", history.capture("three", "updated policy", "plugin"))
        assertEquals("policy", MobilePromptHistory.restore(null, "policy").policy)
    }

    @Test fun `retention rejection preserves comparison and static breakpoint`() {
        val state = MobileCacheState()
        state.responseIDs["scope"] = "prior"
        state.unsupported += "cap|openai_retention"
        val body = JSONObject("""{"instructions":"policy","input":[{"role":"user","content":"hello"}]}""")
        MobilePromptCache.configureResponsesCache(body, "https://api.openai.com/v1/responses", "gpt-5.6-luna", state, "scope", "cap")
        assertEquals("prior", body.getJSONObject("prompt_cache_options").getString("comparison_response_id"))
        assertFalse(body.getJSONObject("prompt_cache_options").has("ttl"))
        assertTrue(body.toString().contains("prompt_cache_breakpoint"))
        assertEquals("openai_retention", MobilePromptCache.rejectedFeature(422, "prompt_cache_options.ttl rejected"))
    }
    @Test fun `schema cache control property remains part of wire fingerprint`() {
        val body = cacheBody(1).put("tools", JSONArray("""[{"name":"read","input_schema":{"properties":{"cache_control":{"type":"string"}}}}]"""))
        val original = MobileCacheState.prefix(body)
        body.put("tools", JSONArray("""[{"name":"read","input_schema":{"properties":{"cache_control":{"type":"number"}}}}]"""))
        assertNotEquals(original, MobileCacheState.prefix(body))
    }

    @Test fun `attachment restoration appends one new notice`() {
        val state = MobileCacheState()
        state.captureNotices("source missing", false)
        assertEquals(1, state.captureNotices(null, false).size)
        assertTrue(state.captureNotices(null, false).isEmpty())
    }

    @Test fun `invalid read does not refresh accepted boundary`() {
        val state = MobileCacheState()
        val write = JSONObject("""{"usage":{"input_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":4096}}""")
        val accepted = state.accept(cacheBody(1), write, "a", true, 3600, true, 0)
        val invalid = JSONObject("""{"usage":{"input_tokens":0,"cache_read_input_tokens":-1,"cache_creation_input_tokens":0}}""")
        val unknown = state.accept(cacheBody(2), invalid, "a", true, 3600, true, 1000)
        assertNull(unknown.reusedTokens)
        assertEquals(accepted.eventID, state.baselines["a"]?.eventID)
    }

    @Test fun `usage routes remain separate after account change and reload`() {
        val state = MobileCacheState()
        state.accept(cacheBody(1), JSONObject(), "account-one", true, 3600, false)
        state.accept(cacheBody(1), JSONObject(), "account-two", true, 3600, false)
        val restored = MobileCacheState.restore(state.json())
        assertEquals(2, restored.evidence.size)
        assertEquals(1, restored.currentRouteEvidence.size)
    }
    private fun cacheBody(count: Int) = JSONObject().put("model", "claude-sonnet-4-5").put("system", "policy")
        .put("tools", JSONArray().put(JSONObject().put("name", "read").put("input_schema", JSONObject().put("type", "object"))))
        .put("messages", JSONArray().apply { (0 until count).forEach { put(JSONObject().put("role", "user").put("content", JSONArray().put(JSONObject().put("type", "text").put("text", "turn $it")))) } })
        .also { MobilePromptCache.applyAnthropicCacheBreakpoints(it) }

    @Test fun `four checkpoints retain prior boundary beyond twenty positions`() {
        val first = cacheBody(1)
        val state = MobileCacheState()
        state.accept(first, JSONObject("""{"id":"one","usage":{"input_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":4096}}"""), "a", true, 3600, true, 0)
        val previous = MobilePromptCache.wireJson(first)
        val next = cacheBody(30)
        assertEquals(1, state.previousBoundary(next, "a"))
        MobilePromptCache.applyAnthropicCacheBreakpoints(next, "1h", state.previousBoundary(next, "a"))
        assertNotNull(next.getJSONArray("messages").getJSONObject(0).getJSONArray("content").getJSONObject(0).optJSONObject("cache_control"))
        assertNotNull(next.getJSONArray("messages").getJSONObject(29).getJSONArray("content").getJSONObject(0).optJSONObject("cache_control"))
        assertEquals(previous, MobilePromptCache.wireJson(first))
    }

    @Test fun `exact reuse retains ttl misses and unknown counters`() {
        val state = MobileCacheState()
        val cold = state.accept(cacheBody(1), JSONObject("""{"id":"one","usage":{"input_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":4096}}"""), "a", true, 3600, true, 0)
        assertNull(cold.eligibleTokens)
        val miss = state.accept(cacheBody(2), JSONObject("""{"id":"two","usage":{"input_tokens":3,"cache_read_input_tokens":0,"cache_creation_input_tokens":4200}}"""), "a", true, 3600, true, 3601000)
        assertEquals("expired", miss.classification); assertNull(miss.eligibleTokens)
        assertEquals("ttl_elapsed", miss.reason); assertEquals(4203, miss.usage.inputTokens)
        assertNull(MobileCacheSummary(listOf(miss)).reuseRate)
        val unknown = state.accept(cacheBody(3), JSONObject("""{"id":"three","usage":{"input_tokens":4400}}"""), "a", true, 3600, true, 3602000)
        assertNull(unknown.reusedTokens); assertNull(unknown.usage.rawHitRate); assertEquals(4200, state.baselines["a"]?.exactTokens)
        assertEquals(0.0, MobileCacheSummary(listOf(miss, unknown)).coverage)
    }

    @Test fun `rewritten prefix inside ttl is a measured miss and settings change is not`() {
        val state = MobileCacheState()
        val write = JSONObject("""{"id":"one","usage":{"input_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":4096}}""")
        state.accept(cacheBody(1), write, "a", true, 3600, true, 0)
        val rewritten = cacheBody(2)
        rewritten.getJSONArray("messages").getJSONObject(0).getJSONArray("content").getJSONObject(0).put("text", "rewritten")
        val lost = state.accept(rewritten, write, "a", true, 3600, true, 1000)
        assertEquals("eligible", lost.classification); assertEquals("messages_changed", lost.reason)
        assertEquals(4096, lost.eligibleTokens); assertEquals(0, lost.reusedTokens)
        val changed = state.accept(rewritten.put("model", "claude-opus-5"), write, "a", true, 3600, true, 2000)
        assertEquals("changed", changed.classification); assertNull(changed.eligibleTokens)
        assertEquals(1.0, MobileCacheSummary(listOf(lost, changed)).coverage)
    }

    @Test fun `gateway read only counters do not prove previous written input`() {
        val state = MobileCacheState()
        val body = JSONObject("""{"model":"gpt-5.6-luna","input":[{"role":"user","content":"one"}]}""")
        state.accept(body, JSONObject("""{"usage":{"input_tokens":5000,"input_tokens_details":{"cached_tokens":0}}}"""), "codex", false, 300, true, 0)
        val hit = state.accept(body, JSONObject("""{"usage":{"input_tokens":5100,"input_tokens_details":{"cached_tokens":4900}}}"""), "codex", false, 300, true, 1000)
        assertNull(hit.eligibleTokens); assertNull(hit.reusedTokens)
        val late = state.accept(body, JSONObject("""{"usage":{"input_tokens":5100,"input_tokens_details":{"cached_tokens":0}}}"""), "codex", false, 300, true, 301000)
        assertEquals("expired", late.classification)
    }

    @Test fun `read only OpenAI usage stays unknown and accounts remain isolated`() {
        val state = MobileCacheState()
        val body = JSONObject("""{"model":"gpt-5.6-luna","input":[{"role":"user","content":"one"}]}""")
        val response = JSONObject("""{"id":"resp_one","usage":{"input_tokens":5000,"input_tokens_details":{"cached_tokens":4096}},"prompt_cache_diagnostics":{"cache_missed_tokens":1000,"comparison_reusable_tokens":4096}}""")
        state.accept(body, response, "one", false, 1800, true)
        assertNull(state.baselines["one"]?.exactTokens); assertNull(state.previousBoundary(body, "two"))
        assertEquals("resp_one", state.responseIDs["one"]); assertNull(state.responseIDs["two"])
    }

    @Test fun `catalog epoch and rolling evidence survive reload`() {
        val state = MobileCacheState()
        state.catalog(JSONArray("""[{"name":"read","input_schema":{"type":"object","properties":{"b":{"type":"string"},"a":{"type":"string"}}}}]"""))
        state.catalog(JSONArray("""[{"input_schema":{"properties":{"a":{"type":"string"},"b":{"type":"string"}},"type":"object"},"name":"read"}]"""))
        assertEquals(1, state.epoch)
        state.catalog(JSONArray()); assertEquals(2, state.epoch)
        repeat(105) { state.accept(cacheBody(1), JSONObject(), "a", true, 3600, false) }
        val restored = MobileCacheState.restore(state.json())
        assertEquals(2, restored.epoch); assertEquals(101, restored.evidence.size); assertEquals("[]", restored.catalogJSON)
    }

    @Test fun `stream diagnostics and rejected feature parsing are safe`() {
        val stream = "data: {\"type\":\"message_start\",\"message\":{\"id\":\"one\",\"diagnostics\":{\"cache_miss_reason\":{\"type\":\"tools_changed\"}},\"usage\":{\"input_tokens\":0,\"cache_read_input_tokens\":4096,\"cache_creation_input_tokens\":0}}}\n\ndata: {\"type\":\"message_delta\",\"usage\":{\"output_tokens\":1}}\n"
        val response = MobilePromptCache.responseObject(stream)!!
        assertEquals("one", response.optString("id")); assertEquals(4096, MobileCacheUsage.parse(response, true).cachedTokens)
        assertEquals("tools_changed", response.getJSONObject("diagnostics").getJSONObject("cache_miss_reason").optString("type"))
        assertNull(MobilePromptCache.rejectedFeature(500, "diagnostics")); assertNull(MobilePromptCache.rejectedFeature(400, "invalid unrelated setting"))
        assertEquals("claude_diagnostics", MobilePromptCache.rejectedFeature(422, "previous_message_id not supported"))
        assertTrue(MobilePromptCache.supportsDiagnostics("gpt-5.6-luna")); assertFalse(MobilePromptCache.supportsDiagnostics("gpt-4.1"))
    }

    @Test fun `responses caching fields match only actual supported route`() {
        val state = MobileCacheState().apply { responseIDs["a"] = "resp_previous" }
        val original = """{"model":"gpt-5.6-luna","instructions":"policy","input":[{"role":"user","content":"question"}]}"""
        val direct = JSONObject(original)
        MobilePromptCache.configureResponsesCache(direct, "https://api.openai.com/v1/responses", "gpt-5.6-luna", state, "a", "api")
        assertFalse(direct.has("instructions")); assertEquals("developer", direct.getJSONArray("input").getJSONObject(0).optString("role"))
        assertNotNull(direct.getJSONArray("input").getJSONObject(0).getJSONArray("content").getJSONObject(0).optJSONObject("prompt_cache_breakpoint"))
        assertEquals("30m", direct.getJSONObject("prompt_cache_options").optString("ttl"))
        val codex = JSONObject(original)
        MobilePromptCache.configureResponsesCache(codex, "https://chatgpt.com/backend-api/codex/responses", "gpt-5.6-luna", state, "a", "codex")
        assertEquals("policy", codex.optString("instructions")); assertFalse(codex.getJSONObject("prompt_cache_options").has("ttl"))
        assertEquals("resp_previous", codex.getJSONObject("prompt_cache_options").optString("comparison_response_id"))
        val legacy = JSONObject(original)
        MobilePromptCache.configureResponsesCache(legacy, "https://api.openai.com/v1/responses", "gpt-4.1", state, "a", "api")
        assertEquals(MobilePromptCache.wireJson(JSONObject(original)), MobilePromptCache.wireJson(legacy))
        val proxy = JSONObject(original)
        MobilePromptCache.configureResponsesCache(proxy, "https://proxy.example/responses", "gpt-5.6-luna", state, "a", "api")
        assertEquals(MobilePromptCache.wireJson(JSONObject(original)), MobilePromptCache.wireJson(proxy))
    }

    @Test fun `notices append once and preserve previous history`() {
        val state = MobileCacheState()
        val history = mutableListOf("question", "answer")
        val before = history.toList()
        history += state.captureNotices("V2 changed", true)
        assertEquals(before, history.take(2)); assertTrue(state.captureNotices("V2 changed", true).isEmpty())
        val execution = state.captureNotices("V3 changed", false)
        assertEquals(2, execution.size); assertTrue(execution.last().contains("execution"))
    }

    @Test fun `codex ttl remains unverified even for fully cached input`() {
        val state = MobileCacheState()
        val body = JSONObject("""{"model":"gpt-5.6-luna","input":[{"role":"user","content":"one"}]}""")
        val response = JSONObject("""{"usage":{"input_tokens":4096,"input_tokens_details":{"cached_tokens":4096}}}""")
        state.accept(body, response, "codex", false, null, true)
        val next = state.accept(body, response, "codex", false, null, true)
        assertNull(next.eligibleTokens); assertEquals("ttl_unverified", next.reason); assertEquals(1.0, next.usage.rawHitRate)
    }

    @Test fun `regressed terminal usage does not advance accepted checkpoint`() {
        val state = MobileCacheState()
        val first = state.accept(cacheBody(1), JSONObject("""{"id":"first","usage":{"input_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":4096}}"""), "a", true, 3600, true)
        val result = state.accept(cacheBody(2), JSONObject("""{"id":"second","usage":{"input_tokens":100,"cache_read_input_tokens":500,"cache_creation_input_tokens":0}}"""), "a", true, 3600, true)
        assertEquals(4096, result.eligibleTokens); assertEquals(500, result.reusedTokens)
        assertEquals(first.eventID, state.baselines["a"]?.eventID); assertEquals(1, state.baselines["a"]?.count)
        assertEquals("second", state.responseIDs["a"])
    }
    @Test fun `cache ttl and canonical json preserve request content`() {
        val body = JSONObject().put("system", "policy").put("messages", JSONArray().put(JSONObject().put("role", "user").put("content", "question")))
        MobilePromptCache.applyAnthropicCacheBreakpoints(body)
        assertEquals("1h", body.getJSONArray("system").getJSONObject(0).getJSONObject("cache_control").getString("ttl"))
        MobilePromptCache.applyAnthropicCacheBreakpoints(body, "5m")
        assertEquals("5m", body.getJSONArray("system").getJSONObject(0).getJSONObject("cache_control").getString("ttl"))
        assertEquals("policy", body.getJSONArray("system").getJSONObject(0).getString("text"))
        val first = JSONObject("""{"type":"object","properties":{"b":{"type":"string"},"a":{"type":"string"}}}""")
        val second = JSONObject("""{"properties":{"a":{"type":"string"},"b":{"type":"string"}},"type":"object"}""")
        assertEquals(MobilePromptCache.wireJson(first), MobilePromptCache.wireJson(second))
    }
    @Test fun `new context retains previous turns and initial policy`() {
        var history = MobilePromptHistory()
        val first = history.capture("one", "policy one", "plugin one")
        val messages = mutableListOf(first, "tool result", "answer")
        val previous = messages.toList()
        history = MobilePromptHistory(history.policy)
        messages += history.capture("two", "policy two", "plugin two")
        assertEquals("policy one", history.policy)
        assertEquals(previous, messages.take(previous.size))
        assertTrue(messages.last().contains("policy two"))
        assertTrue(messages.last().contains("plugin two"))
        assertFalse(messages.last().contains("plugin one"))
    }

    @Test fun `empty context and reset start cleanly`() {
        var history = MobilePromptHistory()
        assertEquals("one", history.capture("one", "policy", ""))
        assertEquals("two", history.capture("two", "policy", ""))
        history = MobilePromptHistory()
        assertEquals("new", history.capture("new", "new policy", ""))
        assertEquals("new policy", history.policy)
    }

    @Test fun `prompt cache key is shared by conversations and separates accounts and tools`() {
        fun key(account: String = "openai", tools: String = "tools") = MobilePromptCache.key("openai", "openai-chat", "gpt-4.1", account, tools)
        // No conversation or compaction input: a new chat reuses the stable prefix.
        assertEquals(key(), key())
        assertNotEquals(key(), key(account = "other"))
        assertNotEquals(key(), key(tools = "changed"))
        assertTrue(key().startsWith("herness:mobile-v1:"))
    }

    @Test fun `context compaction keeps a whole tool exchange and newest turn without file bodies`() {
        fun text(role: String, value: String) = JSONObject()
            .put("role", role)
            .put("content", JSONArray().put(JSONObject().put("type", "text").put("text", value)))
        val messages = listOf(
            JSONObject().put("role", "system").put("content", "stable policy"),
            text("user", "Inspect the project files."),
            JSONObject().put("role", "assistant").put("content", JSONArray().put(JSONObject()
                .put("type", "tool_use").put("id", "read-1").put("name", "read_file")
                .put("input", JSONObject().put("path", "Sources/App.kt")))),
            JSONObject().put("role", "user").put("content", JSONArray().put(JSONObject()
                .put("type", "tool_result").put("tool_use_id", "read-1")
                .put("content", "PRIVATE_FILE_BODY_SHOULD_NOT_BE_REPLAYED"))),
            text("assistant", "The file defines the app entry point."),
            text("user", "Now update the launch screen."),
            JSONObject().put("role", "assistant")
                .put("content", JSONArray().put(JSONObject().put("type", "text").put("text", "I will inspect the launch view.")))
                .put("responses_output_items", JSONArray().put(JSONObject().put("type", "message"))),
        )

        val selection = MobileContextCompaction.select(messages, 1_024) { 100 }!!
        assertEquals(2, selection.recentMessages.size)
        assertTrue(selection.archiveText.contains("Inspect the project files."))
        assertTrue(selection.archiveText.contains("Sources/App.kt"))
        assertTrue(selection.archiveText.contains("file body omitted"))
        assertFalse(selection.archiveText.contains("PRIVATE_FILE_BODY_SHOULD_NOT_BE_REPLAYED"))

        val summary = """
            1. KULLANICI HEDEFİ: Update the launch screen.
            2. YAPILAN DEĞİŞİKLİKLER: Sources/App.kt was inspected.
            3. ALINAN KARARLAR VE KISITLAR: Preserve the current app architecture.
            4. MEVCUT DURUM VE SON KANITLAR: The latest turn is still active.
        """.trimIndent()
        assertTrue(MobileContextCompaction.isValidSummary(summary))
        val compacted = selection.compose(summary, preserveProviderItems = true)
        assertEquals(4, compacted.size)
        assertEquals(1, compacted.last().optJSONArray("responses_output_items")?.length())
        assertEquals(MobileContextCompaction.SUMMARY_MARKER + "\n" + summary,
            compacted[1].getJSONArray("content").getJSONObject(0).optString("text"))
    }

    @Test fun `oversized archive keeps newest evidence and marks omitted middle`() {
        fun text(role: String, value: String) = JSONObject()
            .put("role", role)
            .put("content", JSONArray().put(JSONObject().put("type", "text").put("text", value)))
        val messages = buildList {
            repeat(20) { index ->
                add(text("user", "u".repeat(5_900) + "USER_%02d".format(index)))
                add(text("assistant", "x".repeat(5_900) + "ARCHIVE_TAIL_%02d".format(index)))
            }
        }

        val selection = MobileContextCompaction.select(messages, 1_024) { 100 }!!

        assertEquals(10, selection.recentMessages.size)
        assertTrue(selection.archiveText.contains("[… compacted …]"))
        assertTrue(selection.archiveText.contains("ARCHIVE_TAIL_14"))
        assertFalse(selection.archiveText.contains("ARCHIVE_TAIL_15"))
        assertTrue(selection.archiveText.length <= MobileContextCompaction.MAXIMUM_ARCHIVE_CHARACTERS)
        assertTrue(MobileContextCompaction.fallbackSummary(null, selection.archiveText).contains("atlandı"))
    }
}

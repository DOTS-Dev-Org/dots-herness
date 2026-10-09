package com.dots.herness.mobile

import java.nio.charset.StandardCharsets
import java.security.MessageDigest
import org.json.JSONArray
import org.json.JSONObject

/**
 * Provider-facing cache identity for the on-device agent.
 *
 * The identity describes the stable request shape, not the current turn or a
 * raw file path.  History is append-only, so a new turn can reuse the
 * unchanged prefix.  Compaction, route/model/account changes, and tool-schema
 * changes deliberately move the request to a new cache segment.
 */
internal object MobilePromptCache {
    // Conversations of one account, model and tool set share the key, so a new
    // chat reads the stable tools+policy prefix instead of rewriting it.
    fun key(
        provider: String,
        route: String,
        model: String,
        accountScope: String,
        toolFingerprint: String,
    ): String {
        val identity = listOf(
            "mobile-v1",
            provider,
            route,
            model,
            accountScope,
            toolFingerprint,
        ).joinToString("\u001f")
        return "herness:mobile-v1:" + digest(identity)
    }

    fun toolFingerprint(tools: List<AgentToolSpec>): String {
        val canonical = tools.sortedBy { it.name }
            .joinToString(separator = ",", prefix = "[", postfix = "]") { canonicalJson(it.wire()) }
        return digest(canonical)
    }

    /** Cache identity for an API credential without persisting or transmitting the secret. */
    fun secretScope(provider: String, credential: String): String = digest("$provider|$credential")

    fun digest(value: String): String =
        MessageDigest.getInstance("SHA-256")
            .digest(value.toByteArray(StandardCharsets.UTF_8))
            .joinToString("") { byte -> "%02x".format(byte.toInt() and 0xff) }

    /** Add provider metadata to the wire body, keeping the durable transcript intact. */
    fun applyAnthropicCacheBreakpoints(body: JSONObject, ttl: String = "1h", previousMessageCount: Int? = null) {
        val ephemeral = JSONObject().put("type", "ephemeral").put("ttl", if (ttl == "5m") "5m" else "1h")
        val policy = body.opt("system") as? String
        if (!policy.isNullOrEmpty()) {
            body.put("system", JSONArray().put(JSONObject()
                .put("type", "text")
                .put("text", policy)
                .put("cache_control", JSONObject(ephemeral.toString()))))
        } else {
            body.optJSONArray("system")?.let { blocks ->
                if (blocks.length() > 0) {
                    val last = blocks.optJSONObject(blocks.length() - 1)
                    last?.put("cache_control", JSONObject(ephemeral.toString()))
                }
            }
        }

        body.optJSONArray("tools")?.let { tools ->
            if (tools.length() > 0) {
                val copy = JSONArray()
                for (index in 0 until tools.length()) {
                    val tool = JSONObject(tools.optJSONObject(index)?.toString() ?: "{}")
                    if (index == tools.length() - 1) tool.put("cache_control", JSONObject(ephemeral.toString()))
                    copy.put(tool)
                }
                body.put("tools", copy)
            }
        }

        body.optJSONArray("messages")?.let { messages ->
            val copy = JSONArray()
            for (index in 0 until messages.length()) {
                val message = JSONObject(messages.optJSONObject(index)?.toString() ?: "{}")
                if (index == messages.length() - 1 || index == previousMessageCount?.minus(1)) {
                    val content = message.optJSONArray("content")
                    if (content != null && content.length() > 0) {
                        val blocks = JSONArray()
                        for (blockIndex in 0 until content.length()) {
                            val block = JSONObject(content.optJSONObject(blockIndex)?.toString() ?: "{}")
                            if (blockIndex == content.length() - 1) block.put("cache_control", JSONObject(ephemeral.toString()))
                            blocks.put(block)
                        }
                        message.put("content", blocks)
                    } else {
                        val text = message.optString("content")
                        if (text.isNotEmpty()) message.put("content", JSONArray().put(JSONObject()
                            .put("type", "text")
                            .put("text", text)
                            .put("cache_control", JSONObject(ephemeral.toString()))))
                    }
                }
                copy.put(message)
            }
            body.put("messages", copy)
        }
    }

    fun wireJson(value: JSONObject): String = canonicalJson(value)

    fun historicalAttachment(block: JSONObject, latest: MobileAttachment?): MobileAttachment? {
        if (block.optString("snapshot_path").isNotEmpty()) return MobileAttachment.fromCanonicalBlock(block)
        return latest?.takeIf { block.optInt("revision", 1) == it.revision && (!block.has("content_hash") || block.optString("content_hash") == it.contentHash) }
    }

    fun supportsDiagnostics(model: String): Boolean = model.startsWith("gpt-6") || Regex("^gpt-5\\.[6-9](?:\\D|$)").containsMatchIn(model)

    fun configureResponsesCache(body: JSONObject, endpoint: String, model: String, state: MobileCacheState, scope: String, capability: String) {
        if (!supportsDiagnostics(model) || endpoint !in setOf("https://api.openai.com/v1/responses", "https://chatgpt.com/backend-api/codex/responses")) return
        val publicAPI = endpoint == "https://api.openai.com/v1/responses"
        if (publicAPI && "$capability|breakpoint" !in state.unsupported && body.optString("instructions").isNotEmpty()) {
            val policy = body.optString("instructions"); body.remove("instructions")
            val original = body.optJSONArray("input") ?: JSONArray()
            body.put("input", JSONArray().put(JSONObject().put("role", "developer").put("content", JSONArray().put(JSONObject().put("type", "input_text").put("text", policy).put("prompt_cache_breakpoint", JSONObject().put("mode", "explicit"))))).apply { (0 until original.length()).forEach { put(original.opt(it)) } })
        }
        if ("$capability|openai_options" !in state.unsupported) {
            val options = JSONObject()
            if (publicAPI && "$capability|openai_retention" !in state.unsupported) options.put("mode", "implicit").put("ttl", "30m")
            if ("$capability|openai_diagnostics" !in state.unsupported) state.responseIDs[scope]?.let { options.put("comparison_response_id", it) }
            if (options.length() > 0) body.put("prompt_cache_options", options)
        }
    }

    fun rejectedFeature(status: Int, message: String): String? {
        if (status !in setOf(400, 422)) return null
        val text = message.lowercase()
        return when {
            "prompt_cache_breakpoint" in text -> "breakpoint"
            "comparison_response_id" in text -> "openai_diagnostics"
            "prompt_cache_options" in text -> if ("ttl" in text || "mode" in text) "openai_retention" else "openai_options"
            "diagnostics" in text || "previous_message_id" in text -> "claude_diagnostics"
            "ttl" in text -> "ttl"
            else -> null
        }
    }

    fun responseObject(text: String): JSONObject? {
        runCatching { JSONObject(text) }.getOrNull()?.let { return it }
        var response: JSONObject? = null
        val usage = JSONObject()
        val blocks = JSONArray()
        val arguments = mutableMapOf<Int, String>()
        text.lineSequence().filter { it.startsWith("data:") }.forEach { line ->
            val event = runCatching { JSONObject(line.removePrefix("data:").trim()) }.getOrNull() ?: return@forEach
            when (event.optString("type")) {
                "response.completed", "response.done" -> response = event.optJSONObject("response")
                "message_start" -> { response = event.optJSONObject("message"); response?.optJSONObject("usage")?.let { u -> u.keys().forEach { usage.put(it, u.opt(it)) } } }
                "message_delta" -> event.optJSONObject("usage")?.let { u -> u.keys().forEach { usage.put(it, u.opt(it)) } }
                "content_block_start" -> event.optJSONObject("content_block")?.let { block ->
                    val index = event.optInt("index", blocks.length())
                    if (index in 0..999) blocks.put(index, block)
                }
                "content_block_delta" -> event.optJSONObject("delta")?.let { delta ->
                    val index = event.optInt("index", blocks.length() - 1)
                    blocks.optJSONObject(index)?.let { block ->
                        listOf("text", "thinking", "signature").forEach { field -> if (delta.has(field)) block.put(field, block.optString(field) + delta.optString(field)) }
                        if (delta.has("partial_json")) arguments[index] = arguments[index].orEmpty() + delta.optString("partial_json")
                    }
                }
            }
        }
        arguments.forEach { (index, json) -> runCatching { JSONObject(json) }.getOrNull()?.let { blocks.optJSONObject(index)?.put("input", it) } }
        if (response?.has("output") == false) { response?.put("usage", usage); response?.put("content", blocks) }
        return response
    }

    fun diagnosticReason(value: String?): String? {
        if (value == null) return null
        val known = setOf("model_changed", "system_changed", "tools_changed", "messages_changed", "instructions_changed", "input_changed", "reasoning_changed", "reasoning_effort_changed", "service_tier_changed", "cache_expired", "cache_evicted", "cache_not_found", "settings_changed", "prefix_mismatch", "text_format_changed", "verbosity_changed", "context_compacted", "previous_message_not_found", "comparison_response_not_found", "unavailable", "prompt_cache_key_changed")
        return if (value in known) value else "other"
    }

    fun canonicalJson(value: Any?): String = when (value) {
        null, JSONObject.NULL -> "null"
        is JSONObject -> value.keys().asSequence().toList().sorted().joinToString(separator = ",", prefix = "{", postfix = "}") { key ->
            JSONObject.quote(key) + ":" + canonicalJson(value.opt(key))
        }
        is JSONArray -> (0 until value.length()).joinToString(separator = ",", prefix = "[", postfix = "]") { index ->
            canonicalJson(value.opt(index))
        }
        is String -> JSONObject.quote(value)
        is Number, is Boolean -> value.toString()
        else -> JSONObject.quote(value.toString())
    }
}

internal data class MobileCacheUsage(val inputTokens: Int?, val cachedTokens: Int?, val writeTokens: Int?) {
    val rawHitRate: Double? get() = if (inputTokens != null && inputTokens > 0 && cachedTokens != null) cachedTokens.toDouble() / inputTokens else null
    fun json() = JSONObject().put("inputTokens", inputTokens ?: JSONObject.NULL).put("cachedTokens", cachedTokens ?: JSONObject.NULL).put("writeTokens", writeTokens ?: JSONObject.NULL)
    companion object {
        fun integer(o: JSONObject?, name: String): Int? = if (o?.has(name) == true && !o.isNull(name)) (o.opt(name) as? Number)?.toInt()?.takeIf { it >= 0 } else null
        fun parse(response: JSONObject, anthropic: Boolean): MobileCacheUsage {
            val u = response.optJSONObject("usage")
            val read = integer(u, "cache_read_input_tokens") ?: integer(u?.optJSONObject("input_tokens_details"), "cached_tokens") ?: integer(u?.optJSONObject("prompt_tokens_details"), "cached_tokens")
            val write = integer(u, "cache_creation_input_tokens") ?: integer(u?.optJSONObject("input_tokens_details"), "cache_write_tokens")
            val input = integer(u, "input_tokens") ?: integer(u, "prompt_tokens")
            return MobileCacheUsage(if (anthropic) input?.plus(read ?: 0)?.plus(write ?: 0) else input, read, write)
        }
        fun restore(o: JSONObject) = MobileCacheUsage(integer(o, "inputTokens"), integer(o, "cachedTokens"), integer(o, "writeTokens"))
    }
}

internal data class MobileCacheReuseEvidence(
    val eventID: String,
    val baselineEventID: String?,
    val prefixFingerprint: String,
    val settingsFingerprint: String,
    val classification: String,
    val reason: String?,
    val evidenceSource: String,
    val eligibleTokens: Int?,
    val reusedTokens: Int?,
    val effectiveTTLSeconds: Int?,
    val usage: MobileCacheUsage,
    val routeFingerprint: String? = null,
    val latencyMilliseconds: Int? = null,
) {
    fun json() = JSONObject().put("eventID", eventID).put("baselineEventID", baselineEventID ?: JSONObject.NULL)
        .put("prefixFingerprint", prefixFingerprint).put("settingsFingerprint", settingsFingerprint).put("classification", classification)
        .put("reason", reason ?: JSONObject.NULL).put("evidenceSource", evidenceSource).put("eligibleTokens", eligibleTokens ?: JSONObject.NULL)
        .put("reusedTokens", reusedTokens ?: JSONObject.NULL).put("effectiveTTLSeconds", effectiveTTLSeconds ?: JSONObject.NULL).put("usage", usage.json())
        .put("routeFingerprint", routeFingerprint ?: JSONObject.NULL).put("latencyMilliseconds", latencyMilliseconds ?: JSONObject.NULL)
    companion object {
        fun restore(o: JSONObject) = MobileCacheReuseEvidence(o.optString("eventID"), o.optString("baselineEventID").takeUnless { it.isBlank() || it == "null" },
            o.optString("prefixFingerprint"), o.optString("settingsFingerprint"), o.optString("classification"), o.optString("reason").takeUnless { it.isBlank() || it == "null" },
            o.optString("evidenceSource"), MobileCacheUsage.integer(o, "eligibleTokens"), MobileCacheUsage.integer(o, "reusedTokens"), MobileCacheUsage.integer(o, "effectiveTTLSeconds"), MobileCacheUsage.restore(o.optJSONObject("usage") ?: JSONObject()), o.optString("routeFingerprint").takeUnless { it.isBlank() || it == "null" }, MobileCacheUsage.integer(o, "latencyMilliseconds"))
    }
}

internal data class MobileCacheSummary(val events: List<MobileCacheReuseEvidence>) {
    private val measured get() = events.filter { it.eligibleTokens != null && it.eligibleTokens > 0 && it.reusedTokens != null && it.reusedTokens >= 0 && it.reusedTokens <= it.eligibleTokens }
    // Cold, expired and intentionally changed requests are reported apart; they are neither candidates nor misses.
    private val candidates get() = events.filter { it.classification !in setOf("cold", "expired", "changed") }
    val coverage get() = if (candidates.isEmpty()) null else measured.size.toDouble() / candidates.size
    val reuseRate: Double? get() { val p = measured.sumOf { it.eligibleTokens ?: 0 }; return if (p > 0) measured.sumOf { it.reusedTokens ?: 0 }.toDouble() / p else null }
    val rawHitRate: Double? get() {
        val known = events.filter { it.usage.inputTokens != null && it.usage.cachedTokens != null }
        val total = known.sumOf { it.usage.inputTokens ?: 0 }
        return if (total > 0) known.sumOf { it.usage.cachedTokens ?: 0 }.toDouble() / total else null
    }
    val label: String get() {
        fun percent(value: Double?) = value?.let { String.format(java.util.Locale.ROOT, "%.1f%%", it * 100) } ?: "—"
        return "Reuse ${percent(reuseRate)} · Hit ${percent(rawHitRate)} · Coverage ${percent(coverage)}"
    }
    val details: String get() {
        val loss = measured.sumOf { ((it.eligibleTokens ?: 0) - (it.reusedTokens ?: 0)).coerceAtLeast(0) }
        val delays = events.mapNotNull { it.latencyMilliseconds }
        val latency = if (delays.isEmpty()) "—" else "${delays.sumOf { it.toLong() } / delays.size} ms"
        val losses = measured.groupBy { it.reason ?: "cache_miss" }.mapValues { (_, values) -> values.sumOf { (it.eligibleTokens ?: 0) - (it.reusedTokens ?: 0) } }
            .filterValues { it > 0 }.entries.sortedByDescending { it.value }.joinToString("\n") { "${it.key}: ${it.value} lost tokens" }
        return "$label\n${events.size} requests; ${measured.size} measured reuse samples\nCold: ${events.count { it.classification == "cold" }} · Expired: ${events.count { it.classification == "expired" }} · Changed: ${events.count { it.classification == "changed" }}\nLatency: $latency · Cost: —\nCache loss: $loss tokens\n$losses\nLatest: ${events.lastOrNull()?.reason ?: "—"}\nReuse is measured only for a previously cached, unchanged prefix. Missing provider token evidence is shown as unknown."
    }
}

/** Provider counters only: neither byte estimates nor diagnostics estimates prove eligible tokens. */
internal class MobileCacheState {
    data class Baseline(val eventID: String, val count: Int, val prefixFingerprint: String, val settingsFingerprint: String, val exactTokens: Int?, val acceptedAt: Long, val ttlSeconds: Int?, val toolFingerprint: String? = null, val policyFingerprint: String? = null, val model: String? = null, val proofVersion: Int? = 2) {
        fun json() = JSONObject().put("eventID", eventID).put("count", count).put("prefixFingerprint", prefixFingerprint).put("settingsFingerprint", settingsFingerprint)
            .put("exactTokens", exactTokens ?: JSONObject.NULL).put("acceptedAt", acceptedAt).put("ttlSeconds", ttlSeconds ?: JSONObject.NULL)
            .put("toolFingerprint", toolFingerprint ?: JSONObject.NULL).put("policyFingerprint", policyFingerprint ?: JSONObject.NULL).put("model", model ?: JSONObject.NULL).put("proofVersion", proofVersion ?: JSONObject.NULL)
    }
    var catalogJSON = "[]"
    var catalogDigest = ""
    var epoch = 0
    val baselines = mutableMapOf<String, Baseline>()
    val responseIDs = mutableMapOf<String, String>()
    val unsupported = mutableSetOf<String>()
    var evidence = emptyList<MobileCacheReuseEvidence>()
    val currentRouteEvidence get() = evidence.lastOrNull()?.routeFingerprint?.let { route -> evidence.filter { it.routeFingerprint == route } } ?: evidence
    fun expiredLargePrefixTokens(model: String, now: Long = System.currentTimeMillis()): Int? {
        val baseline = baselines.values
            .filter { it.proofVersion == 2 && it.model == model && (it.exactTokens ?: 0) >= 8_192 && (it.ttlSeconds ?: 0) > 0 }
            .maxByOrNull { it.acceptedAt } ?: return null
        val ttl = baseline.ttlSeconds ?: return null
        val tokens = baseline.exactTokens ?: return null
        return tokens.takeIf { now - baseline.acceptedAt >= ttl * 1_000L }
    }
    var noticeFingerprint: String? = null
    var mode: String? = null
    var lessonsFingerprint: String? = null
    fun captureNotices(attachmentNotice: String?, plan: Boolean, lessons: String = ""): List<String> {
        val notices = mutableListOf<String>()
        // Learned rules ride the same rail as the other notices: appended to the
        // transcript once, and again only when their text changes.
        if (lessons.isNotEmpty()) {
            val fingerprint = MobilePromptCache.digest(lessons)
            if (fingerprint != lessonsFingerprint) { notices += lessons; lessonsFingerprint = fingerprint }
        }
        if (attachmentNotice != null) {
            val fingerprint = MobilePromptCache.digest(attachmentNotice)
            if (fingerprint != noticeFingerprint) { notices += attachmentNotice; noticeFingerprint = fingerprint }
        } else {
            if (noticeFingerprint != null) notices += "[Attachment source status]\nPreviously reported sources are current or no longer attached. Historical bytes remain unchanged."
            noticeFingerprint = null
        }
        val currentMode = if (plan) "plan" else "execution"
        if (mode != currentMode) {
            notices += if (plan) "Current mode: plan. Draft the plan; do not perform workspace mutations." else "Current mode: execution. Follow the user's authorized task; tool approvals remain required."
            mode = currentMode
        }
        return notices
    }
    fun catalog(tools: JSONArray): JSONArray {
        val json = MobilePromptCache.canonicalJson(tools)
        val fingerprint = MobilePromptCache.digest(json)
        if (fingerprint != catalogDigest) { catalogDigest = fingerprint; catalogJSON = json; epoch += 1 }
        return JSONArray(catalogJSON)
    }
    fun accept(body: JSONObject, response: JSONObject, scope: String, anthropic: Boolean, ttl: Int?, terminal: Boolean, now: Long = System.currentTimeMillis()): MobileCacheReuseEvidence {
        val prior = baselines[scope]
        val usage = MobileCacheUsage.parse(response, anthropic)
        val prefix = prefix(body)
        val settings = settings(body)
        val toolFingerprint = MobilePromptCache.digest(MobilePromptCache.canonicalJson(clean(body.opt("tools") ?: JSONArray())))
        val policyFingerprint = MobilePromptCache.digest(MobilePromptCache.canonicalJson(clean(body.opt("system") ?: body.opt("instructions") ?: "")))
        val priorMatches = prior?.let { prefix(body, it.count) == it.prefixFingerprint && settings == it.settingsFingerprint } == true
        // A real model/settings/catalog/policy change starts a new baseline. A rewritten
        // message prefix inside the same baseline is a preventable loss and stays measured.
        val changed = prior != null && (prior.proofVersion != 2 || prior.settingsFingerprint != settings
            || (prior.toolFingerprint != null && prior.toolFingerprint != toolFingerprint)
            || (prior.policyFingerprint != null && prior.policyFingerprint != policyFingerprint))
        val diag = response.optJSONObject(if (anthropic) "diagnostics" else "prompt_cache_diagnostics")
        val miss = diag?.optJSONObject("cache_miss_reason")
        val providerReason = MobilePromptCache.diagnosticReason((miss?.optString("type") ?: miss?.optString("reason") ?: diag?.optString("reason"))?.takeUnless { it.isBlank() || it == "null" })
        val expired = prior?.let { p -> p.ttlSeconds?.let { now - p.acceptedAt >= it * 1000L } } == true
        val eligible = if (prior?.ttlSeconds != null && !changed && !expired) prior.exactTokens else null
        val readValid = usage.cachedTokens?.let { it >= 0 && usage.inputTokens != null && it <= usage.inputTokens } == true
        val reused = eligible?.let { p -> if (!priorMatches) 0 else if (readValid) usage.cachedTokens?.let { minOf(p, it) } else null }
        val classification = when {
            prior == null -> "cold"
            changed -> "changed"
            expired -> "expired"
            eligible != null && reused != null -> "eligible"
            else -> "unknown"
        }
        val reason = providerReason ?: when {
            prior == null -> if (baselines.isEmpty()) "first_request" else "account_or_endpoint_changed"
            !priorMatches && prior.model != null && prior.model != body.optString("model") -> "model_changed"
            !priorMatches && prior.settingsFingerprint != settings -> "settings_changed"
            !priorMatches && prior.toolFingerprint != null && prior.toolFingerprint != toolFingerprint -> "tools_changed"
            !priorMatches && prior.policyFingerprint != null && prior.policyFingerprint != policyFingerprint -> if (anthropic) "system_changed" else "instructions_changed"
            !priorMatches -> if (anthropic) "messages_changed" else "input_changed"
            prior.ttlSeconds == null -> "ttl_unverified"
            expired -> "ttl_elapsed"
            eligible == null -> "terminal_tokens_unavailable"
            else -> null
        }
        val route = MobilePromptCache.digest(scope + "|" + body.optString("model"))
        val entry = MobileCacheReuseEvidence(java.util.UUID.randomUUID().toString(), prior?.eventID, prefix, settings, classification, reason,
            if (eligible != null && reused != null) "provider_usage_terminal_checkpoint" else "unknown", eligible, reused, ttl, usage, route)
        val candidate = entry.classification !in setOf("cold", "expired", "changed")
        fun sameGroup(value: MobileCacheReuseEvidence) = value.routeFingerprint == route && (value.classification !in setOf("cold", "expired", "changed")) == candidate
        evidence = evidence.filterNot(::sameGroup) + (evidence.filter(::sameGroup) + entry).takeLast(100)
        val read = usage.cachedTokens
        val lastMessages = body.optJSONArray("messages")
        val lastBlocks = lastMessages?.optJSONObject(lastMessages.length() - 1)?.optJSONArray("content")
        val terminalProven = terminal && (!anthropic || lastBlocks?.optJSONObject(lastBlocks.length() - 1)?.has("cache_control") == true)
        val exact = if (terminalProven && readValid && read != null && usage.writeTokens != null && usage.inputTokens != null && usage.writeTokens <= usage.inputTokens - read) read + usage.writeTokens else null
        val regressed = priorMatches && prior?.exactTokens != null && (exact ?: 0) < prior.exactTokens
        if (!regressed) baselines[scope] = Baseline(entry.eventID, body.optJSONArray(if (anthropic) "messages" else "input")?.length() ?: 0, prefix, settings, exact?.takeIf { it > 0 }, now, ttl, toolFingerprint, policyFingerprint, body.optString("model"))
        response.optString("id").takeIf { it.isNotBlank() }?.let { responseIDs[scope] = it }
        return entry
    }
    fun previousBoundary(body: JSONObject, scope: String): Int? = baselines[scope]?.takeIf { prefix(body, it.count) == it.prefixFingerprint && settings(body) == it.settingsFingerprint }?.count
    fun json() = JSONObject().put("catalogJSON", catalogJSON).put("catalogDigest", catalogDigest).put("epoch", epoch)
        .put("baselines", JSONObject().apply { baselines.forEach { (k, v) -> put(k, v.json()) } }).put("responseIDs", JSONObject(responseIDs.toMap()))
        .put("unsupported", JSONArray(unsupported.toList())).put("evidence", JSONArray(evidence.map { it.json() })).put("noticeFingerprint", noticeFingerprint ?: JSONObject.NULL).put("mode", mode ?: JSONObject.NULL).put("lessonsFingerprint", lessonsFingerprint ?: JSONObject.NULL)
    companion object {
        private fun clean(value: Any?): Any? = when (value) {
            is JSONObject -> JSONObject().apply { value.keys().forEach {
                if (it !in setOf("cache_control", "prompt_cache_breakpoint")) {
                    val userData = it in setOf("input_schema", "parameters") || (it == "input" && value.optString("type") == "tool_use")
                    put(it, if (userData) value.opt(it) else clean(value.opt(it)))
                }
            } }
            is JSONArray -> JSONArray().apply { (0 until value.length()).forEach { put(clean(value.opt(it))) } }
            else -> value
        }
        fun prefix(body: JSONObject, count: Int? = null): String {
            val field = if (body.has("messages")) "messages" else "input"
            val messages = body.optJSONArray(field) ?: JSONArray()
            val selected = JSONArray().apply { (0 until minOf(count ?: messages.length(), messages.length()).coerceAtLeast(0)).forEach { put(messages.opt(it)) } }
            val content = JSONObject().put("policy", body.opt("system") ?: body.opt("instructions") ?: "").put("tools", body.opt("tools") ?: JSONArray()).put(field, selected)
            return MobilePromptCache.digest(MobilePromptCache.canonicalJson(clean(content)))
        }
        fun settings(body: JSONObject): String = MobilePromptCache.digest(MobilePromptCache.canonicalJson(JSONObject().apply {
            listOf("model", "reasoning", "thinking", "service_tier", "text", "tool_choice").forEach { if (body.has(it)) put(it, body.opt(it)) }
        }))
        fun restore(o: JSONObject?): MobileCacheState = MobileCacheState().apply {
            if (o == null) return@apply
            catalogJSON = o.optString("catalogJSON", "[]"); catalogDigest = o.optString("catalogDigest"); epoch = o.optInt("epoch")
            o.optJSONObject("baselines")?.let { values -> values.keys().forEach { key -> values.optJSONObject(key)?.let { v ->
                fun optional(name: String) = v.optString(name).takeUnless { it.isBlank() || it == "null" }
                baselines[key] = Baseline(v.optString("eventID"), v.optInt("count"), v.optString("prefixFingerprint"), v.optString("settingsFingerprint"), MobileCacheUsage.integer(v, "exactTokens"), v.optLong("acceptedAt"), MobileCacheUsage.integer(v, "ttlSeconds"), optional("toolFingerprint"), optional("policyFingerprint"), optional("model"), MobileCacheUsage.integer(v, "proofVersion"))
            } } }
            o.optJSONObject("responseIDs")?.let { values -> values.keys().forEach { responseIDs[it] = values.optString(it) } }
            o.optJSONArray("unsupported")?.let { values -> (0 until values.length()).forEach { unsupported += values.optString(it) } }
            o.optJSONArray("evidence")?.let { values -> evidence = (0 until values.length()).mapNotNull { values.optJSONObject(it)?.let(MobileCacheReuseEvidence::restore) } }
            noticeFingerprint = o.optString("noticeFingerprint").takeUnless { it.isBlank() || it == "null" }; mode = o.optString("mode").takeUnless { it.isBlank() || it == "null" }; lessonsFingerprint = o.optString("lessonsFingerprint").takeUnless { it.isBlank() || it == "null" }
        }
    }
}

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
    fun key(
        conversationId: String?,
        provider: String,
        route: String,
        model: String,
        accountScope: String,
        toolFingerprint: String,
        contextSegment: Int,
    ): String {
        val identity = listOf(
            "mobile-v1",
            conversationId?.takeIf { it.isNotEmpty() } ?: "unbound",
            provider,
            route,
            model,
            accountScope,
            toolFingerprint,
            "context-$contextSegment",
        ).joinToString("\u001f")
        return "herness:mobile-v1:" + digest(identity)
    }

    fun toolFingerprint(tools: List<AgentToolSpec>): String {
        val canonical = tools.sortedBy { it.name }
            .joinToString(prefix = "[", postfix = "]") { canonicalJson(it.wire()) }
        return digest(canonical)
    }

    private fun digest(value: String): String =
        MessageDigest.getInstance("SHA-256")
            .digest(value.toByteArray(StandardCharsets.UTF_8))
            .joinToString("") { byte -> "%02x".format(byte.toInt() and 0xff) }

    private fun canonicalJson(value: Any?): String = when (value) {
        null, JSONObject.NULL -> "null"
        is JSONObject -> value.keys().asSequence().toList().sorted().joinToString(prefix = "{", postfix = "}") { key ->
            JSONObject.quote(key) + ":" + canonicalJson(value.opt(key))
        }
        is JSONArray -> (0 until value.length()).joinToString(prefix = "[", postfix = "]") { index ->
            canonicalJson(value.opt(index))
        }
        is String -> JSONObject.quote(value)
        is Number, is Boolean -> value.toString()
        else -> JSONObject.quote(value.toString())
    }
}

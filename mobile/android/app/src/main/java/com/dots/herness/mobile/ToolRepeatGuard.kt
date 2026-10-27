package com.dots.herness.mobile

import org.json.JSONArray
import org.json.JSONObject

/** Stops a tool loop that has stopped making progress (parity with desktop ToolRepeatGuard). One instance per user turn. */
class ToolRepeatGuard {
    private val signatures = HashMap<String, Int>()
    private val edits = HashMap<String, Int>()

    /** True once the same call (key order ignored) exceeds the limit. */
    fun isRepeat(name: String, input: JSONObject): Boolean {
        val count = (signatures[signature(name, input)] ?: 0) + 1
        signatures[signature(name, input)] = count
        return count > MAX_IDENTICAL_CALLS
    }

    /** Appended to an edit result once one file has been edited too often this turn. */
    fun editNotice(name: String, input: JSONObject): String {
        val path = input.optString("path")
        if ((name != "edit_file" && name != "write_file") || path.isEmpty()) return ""
        val count = (edits[path] ?: 0) + 1
        edits[path] = count
        return if (count > MAX_EDITS_PER_FILE) "\n\n[Repeated edits] This file was edited $count times this turn. Reread it and the diff, confirm the change is not already present, and stop rewriting the same region." else ""
    }

    companion object {
        const val MAX_IDENTICAL_CALLS = 3
        const val MAX_EDITS_PER_FILE = 5
        const val REPEATED_NOTICE = "This exact tool call was already made and returned the same result. Change the approach instead of repeating it."

        fun signature(name: String, input: JSONObject): String = "$name|${canonical(input)}"

        private fun canonical(value: Any?): String = when (value) {
            is JSONObject -> value.keys().asSequence().sorted().joinToString(",", "{", "}") { JSONObject.quote(it) + ":" + canonical(value.opt(it)) }
            is JSONArray -> (0 until value.length()).joinToString(",", "[", "]") { canonical(value.opt(it)) }
            is String -> JSONObject.quote(value)
            else -> value.toString()
        }
    }
}

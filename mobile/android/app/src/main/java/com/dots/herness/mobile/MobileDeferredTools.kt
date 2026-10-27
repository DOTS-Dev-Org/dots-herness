package com.dots.herness.mobile

import org.json.JSONArray
import org.json.JSONObject

class MobileDeferredTools {
    companion object {
        const val SEARCH = "discover_tools"
        const val INVOKE = "invoke_tool"
        const val PLAN = "execution_plan"
        const val OUTPUT = "read_tool_output"
        private fun spec(name: String, description: String, properties: String, required: List<String>) = AgentToolSpec(name, description,
            JSONObject().put("type", "object").put("properties", JSONObject(properties)).put("required", JSONArray(required)).put("additionalProperties", false)) { "Tool error: control tools run in the main session only." }
        val definitions = listOf(
            spec(SEARCH, "Find tools by exact name or short English capability query. Returns up to 5 schemas. Empty query lists names; offset pages them.", """{"query":{"type":"string"},"offset":{"type":"integer"}}""", listOf("query")),
            spec(INVOKE, "Call a discovered tool with its JSON input encoded in the arguments string. Existing approvals apply.", """{"name":{"type":"string"},"arguments":{"type":"string"}}""", listOf("name", "arguments")),
            spec(PLAN, "Record concrete steps before implementation. Mark routine only for bounded known work; include all uncertainties.", """{"steps":{"type":"array","items":{"type":"string"},"minItems":1,"maxItems":12},"routine":{"type":"boolean"},"uncertainties":{"type":"array","items":{"type":"string"}}}""", listOf("steps", "routine", "uncertainties")),
            spec(OUTPUT, "Read a stored tool result without rerunning it. Character offset; default limit 4000, maximum 8000.", """{"call_id":{"type":"string"},"offset":{"type":"integer"},"limit":{"type":"integer"}}""", listOf("call_id")))
        val directNames = listOf("read_file", "search_files", "grep_files", "edit_file", "run_command", "wait_command", MobilePlanSteps.NAME)
        fun requestTools(catalog: List<AgentToolSpec>): List<AgentToolSpec> =
            definitions + directNames.mapNotNull { name -> catalog.firstOrNull { it.name == name } }
        private val readOnlyToolNames = setOf(
            "read_file", "search_files", "grep_files", "list_files", "glob", "wait_command",
            "web_search", "web_fetch", "skill.list", "skill.read", "skill.resources", "skill.read_resource",
            SEARCH, PLAN, OUTPUT, MobilePlanSteps.NAME,
        )
        fun isReadOnlyTool(name: String?): Boolean =
            !name.isNullOrEmpty() && name.lowercase() in readOnlyToolNames
        fun isFailure(text: String): Boolean =
            text.startsWith("Tool error", ignoreCase = true)
                || text.startsWith("Error:", ignoreCase = true)
                || text.contains("blocked_in_plan_mode", ignoreCase = true)
                || text.contains("permission rejected", ignoreCase = true)
                || Regex("(?:exit[ _]?code|status)\\s*[:=]?\\s*-?[1-9][0-9]*\\b", RegexOption.IGNORE_CASE).containsMatchIn(text)
                || Regex("(?:^|\\n)\\s*(?:fatal|error|exception|blocked|refused|failed)(?:[:\\s])|\\b[1-9][0-9]* (?:tests? )?failed\\b|\\[check [0-9]+ failed\\]", RegexOption.IGNORE_CASE).containsMatchIn(text)
        const val REPEATED_READ_PREFIX = "[read_file unchanged:"
        fun excerpt(text: String, name: String, id: String): String {
            if (name in setOf("read_file", SEARCH, OUTPUT) || text.toByteArray().size <= 4096) return text
            val decisive = text.lineSequence().filter { Regex("error|fatal|exception|failed|exit code|status|denied", RegexOption.IGNORE_CASE).containsMatchIn(it) }.take(6).map { it.take(240) }.joinToString("\n")
            return text.take(1000) + "\n[… tool output excerpt …]\n" + decisive + "\n" + text.takeLast(400) + "\nOriginal result: read_tool_output call_id=$id"
        }
    }
    private val discovered = mutableMapOf<String, String>()
    private val outputs = mutableMapOf<String, String>()
    var routine = false; private set
    fun resetPlan() { routine = false }
    fun restoreDiscovery(messages: List<JSONObject>) {
        discovered.clear()
        val blocks = messages.flatMap { message ->
            val content = message.optJSONArray("content") ?: JSONArray()
            (0 until content.length()).mapNotNull { content.optJSONObject(it) }
        }
        val ids = messages.filter { it.optString("role") == "assistant" }.flatMap { message ->
            val content = message.optJSONArray("content") ?: JSONArray()
            (0 until content.length()).mapNotNull { content.optJSONObject(it) }
        }.filter { it.optString("type") == "tool_use" && it.optString("name") == SEARCH }.map { it.optString("id") }.toSet()
        for (block in blocks.filter { it.optString("type") == "tool_result" && it.optString("tool_use_id") in ids }) {
            val tools = runCatching { JSONObject(block.optString("content")).optJSONArray("tools") }.getOrNull() ?: continue
            for (index in 0 until tools.length()) {
                val tool = tools.optJSONObject(index) ?: continue
                val schema = tool.optJSONObject("input_schema") ?: continue
                discovered[tool.optString("name")] = schema.toString()
            }
        }
    }
    fun effort(selected: String, planMode: Boolean) = if (routine && !planMode && selected.lowercase() in setOf("medium", "high", "xhigh", "max", "ultra")) "low" else selected
    fun resolve(call: JSONObject, catalog: List<AgentToolSpec>): JSONObject {
        val callName = call.optString("name")
        if (callName != INVOKE) {
            val direct = callName in directNames && catalog.any { it.name == callName }
            return if (direct || definitions.any { it.name == callName }) call else JSONObject(call.toString()).put("name", INVOKE)
        }
        val input = call.optJSONObject("input") ?: return call
        val name = input.optString("name")
        val args = input.opt("arguments") as? String ?: return call
        val parsed = runCatching { JSONObject(args) }.getOrNull() ?: return call
        if (name !in discovered || catalog.none { it.name == name && it.schema.toString() == discovered[name] } || definitions.any { it.name == name }) return call
        return JSONObject(call.toString()).put("name", name).put("input", parsed)
    }
    fun control(name: String, input: JSONObject, catalog: List<AgentToolSpec>, planMode: Boolean): String? {
        if (name == SEARCH) {
            val query = input.optString("query").lowercase()
            val candidates = catalog.filter { tool -> definitions.none { it.name == tool.name } }.sortedBy { it.name }
            if (query.isEmpty()) {
                val offset = input.optInt("offset").coerceAtLeast(0)
                return JSONObject().put("names", JSONArray(candidates.drop(offset).take(20).map { it.name })).put("next_offset", offset + 20).put("total", candidates.size).toString()
            }
            val terms = query.split(Regex("[^\\p{L}\\p{N}_]+")).filter { it.isNotEmpty() }
            val ranked = candidates.map { it to if (it.name.lowercase() == query) 10000 else terms.count { term -> (it.name + " " + it.description).contains(term, true) } }.filter { it.second > 0 }.sortedWith(compareByDescending<Pair<AgentToolSpec, Int>> { it.second }.thenBy { it.first.name }).take(5).map { it.first }
            val exact = candidates.filter { it.name.equals(query, true) }
            val named = exact.ifEmpty { candidates.filter { it.name.lowercase() in terms }.take(5) }
            val matches = named.ifEmpty { ranked }
            matches.forEach { discovered[it.name] = it.schema.toString() }
            return JSONObject().put("tools", JSONArray(matches.map { it.wire() })).put("instruction", "Use invoke_tool for these names. Discover more when needed.").toString()
        }
        if (name == PLAN) {
            routine = false
            val steps = input.optJSONArray("steps") ?: return "Tool error: steps are required."
            val uncertainties = input.optJSONArray("uncertainties") ?: return "Tool error: uncertainties are required."
            if (steps.length() !in 1..12 || (0 until steps.length()).any { steps.opt(it) !is String || steps.optString(it).isBlank() } || (0 until uncertainties.length()).any { uncertainties.opt(it) !is String } || input.opt("routine") !is Boolean) return "Tool error: invalid plan."
            routine = input.getBoolean("routine") && steps.length() <= 5 && uncertainties.length() == 0 && !planMode
            val summary = mutableListOf("Plan recorded:")
            for (index in 0 until steps.length()) summary.add((index + 1).toString() + ". " + steps.getString(index))
            if (uncertainties.length() == 0) {
                summary.add("Unresolved uncertainties: none.")
            } else {
                summary.add("Unresolved uncertainties:")
                for (index in 0 until uncertainties.length()) summary.add("- " + uncertainties.getString(index))
            }
            val effortReasons = mutableListOf<String>()
            if (!input.getBoolean("routine")) effortReasons.add("not marked routine")
            if (steps.length() > 5) effortReasons.add("more than five steps")
            if (uncertainties.length() > 0) effortReasons.add("open uncertainties")
            if (planMode) effortReasons.add("plan mode is active")
            summary.add(if (routine)
                "Execution effort: routine work uses low effort; failures restore the selected effort."
            else
                "Execution effort: selected level retained (" + effortReasons.joinToString(", ") + ").")
            return summary.joinToString("\n")
        }
        if (name == OUTPUT) {
            val value = outputs[input.optString("call_id")] ?: return "Tool error: no stored result for this call_id."
            val offset = input.optInt("offset").coerceIn(0, value.length)
            val limit = input.optInt("limit", 4000).coerceIn(1, 8000)
            val page = value.drop(offset).take(limit)
            return page + if (offset + page.length < value.length) "\n[More output: offset=${offset + page.length}]" else ""
        }
        return if (name == INVOKE) "Tool error: discover the tool first and use a valid JSON arguments string." else null
    }
    private val reads = mutableListOf<Pair<String, String>>()
    /** A read_file whose lines already arrived verbatim in an earlier read of the same path in
     *  this run gets a pointer instead of the same bytes again. The verbatim check doubles as the
     *  unchanged-file proof; read_tool_output can always reach the earlier result. */
    fun repeatedRead(text: String, path: String?): String? {
        val normalized = normalizePath(path) ?: return null
        // Drop the "continue at line N (file has M lines)" footer of a cut page.
        val body = if (text.endsWith(" lines)") && text.contains("\n\n")) text.substringBeforeLast("\n\n") else text
        if (body.toByteArray().size < 512 || body.startsWith("Tool error")) return null
        val earlier = reads.lastOrNull { it.second == normalized && outputs[it.first]?.contains(body) == true }?.first ?: return null
        return "$REPEATED_READ_PREFIX these lines of $normalized are identical to what call_id=$earlier returned earlier in this run. Use that result, or read_tool_output call_id=$earlier if it is no longer visible.]"
    }
    private fun normalizePath(path: String?): String? {
        var value = path?.trim()?.replace('\\', '/') ?: return null
        while (value.startsWith("./")) value = value.drop(2)
        return value.ifEmpty { null }
    }
    fun record(text: String, id: String, failed: Boolean, toolName: String? = null, path: String? = null) {
        outputs[id] = text
        if (toolName == "read_file") normalizePath(path)?.let { reads += id to it }
        if ((failed || isFailure(text)) && !isReadOnlyTool(toolName)) resetPlan()
    }
}

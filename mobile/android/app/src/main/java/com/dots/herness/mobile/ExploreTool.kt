package com.dots.herness.mobile

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.isActive
import org.json.JSONArray
import org.json.JSONObject

/**
 * Read-only exploration subagent for the on-phone agent.
 *
 * A sweep of the workspace run inline leaves every listing and file body in the
 * conversation, resent on each later turn. This runs the sweep in its own context
 * and hands back only the findings. Ported from the desktop `shared/ExploreTool.cs`.
 */
// ponytail: no resume memo for interrupted sweeps; the desktop keeps one. Add it if
// phone sweeps are cut off often enough that re-asking costs real quota.
object MobileExplore {
    const val NAME = "explore"
    /** A sweep that needs more than this was the wrong question to delegate. */
    const val MAX_STEPS = 20
    /**
     * A target, not a ceiling: findings that need the room keep it. The rule lives in
     * the prompt only; a retry to shorten the answer resends the whole transcript to
     * save a few hundred tokens the parent reads from cache, so it never pays for itself.
     */
    const val ANSWER_TARGET = 2_000
    /** Concurrent subagents per assistant turn, to protect quota. */
    const val MAX_PER_TURN = 3
    const val MAXIMUM_TOOL_RESULT_CHARACTERS = 20_000
    const val SETTINGS_KEY = "herness.agent.subagentsEnabled"
    val READ_ONLY_TOOLS = setOf("list_files", "read_file", "search_files", "glob")

    const val DESCRIPTION =
        "Delegate a read-only search of the workspace to a separate agent and get back only its findings. " +
            "Use it when answering needs sweeping many files or directories and you want the conclusion rather " +
            "than the file contents - locating where something is defined, what calls it, how a pattern is used " +
            "across the project. It cannot edit anything, so verify and change code yourself afterwards. Do not " +
            "use it for a file you already know the path of, or when one search_files call or reading fewer than " +
            "three files answers the question: do that directly, since a subagent costs a whole extra run. Use it " +
            "only when the search is broad and the edit is narrow. When the files you would search are the files " +
            "you will change, read them yourself: an explore read does not count as yours, so you would read them " +
            "twice. State " +
            "the question in full, including the naming conventions and paths worth trying, since the subagent " +
            "sees nothing of this conversation. For a broad investigation, split it into independent questions " +
            "and call explore several times in the same turn (maximum $MAX_PER_TURN subagents per turn): those " +
            "subagents run in parallel and only their findings enter this conversation."

    fun schema(): JSONObject = JSONObject()
        .put("type", "object")
        .put("properties", JSONObject().put("task", JSONObject()
            .put("type", "string")
            .put("description", "The self-contained question to answer, with the context the subagent needs.")))
        .put("required", JSONArray().put("task"))

    val SYSTEM_PROMPT = """
        You are a read-only exploration agent working inside one workspace. Answer the question you are
        given by searching the project with search_files, glob, list_files, and read_file. You cannot edit
        anything and must never claim that you did. Search before you read: search_files answers most
        questions in one call. Stop as soon as the question is answered.
        Reply with the findings only - no plan, no preamble, no suggested fixes - in exactly this shape:

        ## Findings
        One bullet per place that matters, each opening with its path:line, then what is there in one
        sentence. Quote only the line that carries the answer, never a whole block.

        ## Unresolved
        What you could not determine and why. Write "None" when nothing is open.

        Status: answered | partial

        Say "partial" whenever any part of the question is still open, whenever you stopped early, and
        whenever a finding rests on a file you did not actually read. The caller acts on this line, so a
        wrong "answered" is worse than an honest "partial".
        Keep the answer under $ANSWER_TARGET characters. Go past it only when the findings genuinely
        need the room - every extra paragraph is context the caller loses for its real work - and never
        to restate a finding or paste code a path:line already points at.
    """.trimIndent()

    /**
     * The lightest model of the provider the conversation already runs on: locating
     * code does not need the conversation's model.
     */
    // ponytail: name heuristic, the phone has no model tiers. Add a picker if it misfires.
    fun lightModel(models: List<String>, current: String): String {
        for (marker in listOf("haiku", "nano", "mini", "flash-lite", "flash", "lite")) {
            models.firstOrNull { it.lowercase().contains(marker) }?.let { return it }
        }
        return current
    }

    /**
     * Runs the sweep and returns the text the parent model sees: the findings plus
     * every reason it has to distrust them. [complete] takes the subagent's own
     * transcript and always offers the same tools, the wrap-up included: the provider
     * caches the prefix from the tool list on, so dropping them would resend it uncached.
     */
    suspend fun run(
        rawTask: String,
        catalog: List<AgentToolSpec>,
        complete: suspend (messages: List<JSONObject>) -> JSONObject,
        invoke: suspend (name: String, input: JSONObject) -> String,
    ): String {
        val task = rawTask.trim()
        if (task.isEmpty()) return "Tool error: explore needs a task - the full question to answer."

        val deferred = MobileDeferredTools()
        val messages = mutableListOf(userText(task))
        val readPaths = mutableListOf<String>()
        var searches = 0
        var steps = 0

        fun finish(answer: String, hitStepLimit: Boolean = false): String {
            val parts = mutableListOf(answer)
            if (hitStepLimit || !answeredFully(answer)) parts += "[Partial: the subagent did not fully answer. Verify before relying on it.]"
            if (hitStepLimit) parts += "[The subagent reached its step limit.]"
            if (steps > 0 && readPaths.isEmpty() && searches == 0) parts += "[Unverified: the subagent answered without searching or reading any file.]"
            if (readPaths.isNotEmpty()) parts += "Files read: " + readPaths.joinToString(", ")
            return parts.joinToString("\n\n")
        }
        fun partialFindings(): String = messages
            .filter { it.optString("role") == "assistant" }
            .map { textOf(it.optJSONArray("content")) }
            .filter { it.isNotEmpty() }
            .joinToString("\n")

        repeat(MAX_STEPS) {
            if (!currentCoroutineContext().isActive) return finish("The exploration was cancelled.")
            if (steps > 0) MobilePromptHistory.supersedeRepeatedReads(messages)
            steps += 1
            val response = try {
                complete(messages)
            } catch (t: CancellationException) {
                throw t
            } catch (t: Throwable) {
                val partial = partialFindings()
                val message = "The exploration failed: ${t.message ?: "provider error"}"
                return finish(if (partial.isEmpty()) message else "$message\n\nPartial findings:\n$partial")
            }
            val blocks = response.optJSONArray("content") ?: JSONArray()
            val assistant = JSONObject().put("role", "assistant").put("content", blocks)
            response.optJSONArray("responses_output_items")?.let { assistant.put("responses_output_items", it) }
            messages += assistant

            val calls = (0 until blocks.length()).mapNotNull { blocks.optJSONObject(it)?.takeIf { block -> block.optString("type") == "tool_use" } }
            if (calls.isEmpty()) {
                val answer = textOf(blocks)
                if (answer.isEmpty()) return finish("The subagent returned no findings.")
                return finish(answer)
            }

            val results = JSONArray()
            for (wireCall in calls) {
                val call = deferred.resolve(wireCall, catalog)
                val name = call.optString("name")
                val input = call.optJSONObject("input") ?: JSONObject()
                val path = input.optString("path")
                if (name == "read_file" && path.isNotEmpty() && path !in readPaths) readPaths += path
                if (name != "read_file" && name in READ_ONLY_TOOLS) searches += 1
                val output = deferred.control(name, input, catalog, false) ?: if (name in READ_ONLY_TOOLS) invoke(name, input)
                else "blocked: the exploration agent is read-only and has no $name tool."
                deferred.record(output, call.optString("id", "tool"), output.startsWith("Tool error", true), name)
                results.put(JSONObject()
                    .put("type", "tool_result")
                    .put("tool_use_id", call.optString("id", "tool"))
                    .put("content", MobileDeferredTools.excerpt(output, name, call.optString("id", "tool"))))
            }
            messages += JSONObject().put("role", "user").put("content", results)
        }

        // The step budget is spent, but the transcript still holds what was found:
        // one last call turns it into an answer instead of discarding it.
        messages += userText("Your step budget is spent. Do not call any tool. Answer now from what you already found, in the required shape, with Status: partial.")
        var answer = runCatching { textOf(complete(messages).optJSONArray("content")) }
            .onFailure { if (it is CancellationException) throw it }
            .getOrDefault("")
        if (answer.isEmpty()) {
            val partial = partialFindings()
            answer = "The subagent reached its step limit without an answer." + if (partial.isEmpty()) "" else "\n\nPartial findings:\n$partial"
        }
        return finish(answer, hitStepLimit = true)
    }

    /** Reads the subagent's own `Status:` line. Missing or malformed counts as partial. */
    fun answeredFully(answer: String): Boolean {
        val status = answer.lines().lastOrNull { it.trim().lowercase().startsWith("status:") } ?: return false
        return status.trim().lowercase().removePrefix("status:").trim().startsWith("answered")
    }

    private fun userText(value: String): JSONObject = JSONObject()
        .put("role", "user")
        .put("content", JSONArray().put(JSONObject().put("type", "text").put("text", value)))

    private fun textOf(blocks: JSONArray?): String = (0 until (blocks?.length() ?: 0))
        .mapNotNull { blocks?.optJSONObject(it)?.takeIf { block -> block.optString("type") == "text" }?.optString("text") }
        .joinToString("\n")
        .trim()
}

/**
 * Editing subagent with a declared file assignment.
 *
 * Two agents writing the same file is what makes delegated edits unusable, so it
 * is ruled out by construction: the subagent names the files it owns before it
 * starts and a write outside that assignment is refused. Ported from the desktop
 * `shared/DelegateTool.cs`.
 */
// ponytail: one at a time. Each delegate call waits for its own approval, and the
// phone's run loop answers one approval per turn, so there is no parallel start and
// no overlap check between siblings. Add both if approvals are ever batched.
object MobileDelegate {
    const val NAME = "delegate"
    /** Editing takes more steps than locating: read, edit, re-read, fix. */
    const val MAX_STEPS = 40
    val WRITE_TOOLS = setOf("write_file", "edit_file")

    /** The parent plans at the selected effort; a part it hands out runs at medium at most. */
    fun effort(selected: String): String =
        if (selected.lowercase() in setOf("high", "xhigh", "max", "ultra")) "medium" else selected

    const val DESCRIPTION =
        "Hand one self-contained implementation assignment to a separate agent that reads and edits files, then " +
            "get back its report. The parent must inspect relevant code and plan the change first. Do not " +
            "delegate a small or single-file edit: make it yourself with edit_file, since a subagent re-reads the " +
            "files and costs a whole extra run. On this device subagents run one at a time, so delegate only one " +
            "large part spanning many files you have not read. The parent owns design, integration, review and whole-change verification. " +
            "Do not use explore to read implementation files on the parent's behalf. `files` is the subagent's assignment: " +
            "the only paths it may create or change. A directory covers everything under it. The subagent cannot " +
            "run commands, delete files or write elsewhere, and it sees nothing of this conversation. Pass the " +
            "parent's implementation plan in `plan`; include findings, interfaces, constraints, exact paths and " +
            "acceptance criteria in `task`. Review changed files and run the whole relevant build/check yourself; " +
            "fix small issues yourself."

    fun schema(): JSONObject = JSONObject()
        .put("type", "object")
        .put("properties", JSONObject()
            .put("plan", JSONObject().put("type", "string").put("description", "The implementation plan the parent formed after inspecting relevant code. Passed to the subagent as design context."))
            .put("task", JSONObject().put("type", "string").put("description", "The complete instructions for this part of the change."))
            .put("files", JSONObject()
                .put("type", "array")
                .put("items", JSONObject().put("type", "string"))
                .put("description", "Workspace-relative files or directories this subagent may create or change.")))
        .put("required", JSONArray().put("plan").put("task").put("files"))

    fun systemPrompt(plan: String, claims: List<String>): String = """
        You are an editing agent working inside one workspace on one assigned part of a larger change.
        Follow the parent's plan as the design source. Keep the assignment within that plan; do not
        independently redesign the architecture or broaden the work. If it conflicts with the code
        or leaves a necessary decision open, report that under Unresolved.
        Parent plan:
        $plan
        You may create or change only these paths (a directory covers everything under it):
        ${claims.joinToString("\n        ") { "- $it" }}
        Use the parent's findings and assigned paths. Read those files and only directly referenced code
        needed to implement the assignment; do not conduct a broad workspace search. If another file
        is necessary, report its exact path and why under Unresolved instead of widening the assignment.
        A write outside the assignment is refused: do not look for another way, report it under Unresolved.
        You cannot run commands or delete files.
        Read a file before you change it. Prefer edit_file for an existing file and write_file for a
        new one. Keep to the task: no unrelated refactors, no new files beyond what it needs.
        When you are done, reply with the report only, in exactly this shape:

        ## Changes
        One bullet per file you changed, opening with its path, then what changed in one sentence.

        ## Unresolved
        What you could not do and why, including anything needed outside your assignment. Write "None"
        when nothing is open.

        Status: done | partial

        Say "partial" whenever any part of the task is unfinished. The caller acts on this line, so a
        wrong "done" is worse than an honest "partial". Never paste file contents into the report.
    """.trimIndent()

    /**
     * The canonical workspace-relative form shared by claims and write targets, so
     * `./a/../b.kt` and `b.kt` are one path. Null when it leaves the workspace.
     */
    fun normalize(path: String): String? {
        val trimmed = path.trim()
        if (trimmed.isEmpty() || trimmed.startsWith("/")) return null
        val parts = mutableListOf<String>()
        for (part in trimmed.split("/")) {
            when (part) {
                "", "." -> Unit
                ".." -> if (parts.isEmpty()) return null else parts.removeAt(parts.lastIndex)
                else -> parts += part
            }
        }
        return if (parts.isEmpty()) "." else parts.joinToString("/")
    }

    /** Null when the assignment is empty or names a path outside the workspace. */
    fun claims(files: List<String>): List<String>? {
        val claims = mutableListOf<String>()
        for (file in files.filter { it.isNotBlank() }) {
            val claim = normalize(file) ?: return null
            if (claim !in claims) claims += claim
        }
        return claims.ifEmpty { null }
    }

    fun covers(claims: List<String>, path: String): Boolean =
        claims.any { it == "." || it == path || path.startsWith("$it/") }

    /**
     * Runs the subagent and returns the text the parent model sees: its report, the
     * files it really changed, and every reason to distrust the report.
     */
    suspend fun run(
        rawTask: String,
        claims: List<String>,
        catalog: List<AgentToolSpec>,
        complete: suspend (messages: List<JSONObject>) -> JSONObject,
        invoke: suspend (name: String, input: JSONObject) -> String,
    ): String = run(
        rawPlan = "Parent plan not supplied by caller.",
        rawTask = rawTask,
        claims = claims,
        catalog = catalog,
        complete = complete,
        invoke = invoke,
    )

    suspend fun run(
        rawPlan: String,
        rawTask: String,
        claims: List<String>,
        catalog: List<AgentToolSpec>,
        complete: suspend (messages: List<JSONObject>) -> JSONObject,
        invoke: suspend (name: String, input: JSONObject) -> String,
    ): String {
        val plan = rawPlan.trim()
        if (plan.isEmpty()) return "Tool error: delegate needs the parent's implementation plan formed after code inspection."
        val task = rawTask.trim()
        if (task.isEmpty()) return "Tool error: delegate needs a task - the complete instructions for the subagent."

        fun userText(value: String) = JSONObject().put("role", "user")
            .put("content", JSONArray().put(JSONObject().put("type", "text").put("text", value)))
        fun textOf(blocks: JSONArray?): String = (0 until (blocks?.length() ?: 0))
            .mapNotNull { blocks?.optJSONObject(it)?.takeIf { block -> block.optString("type") == "text" }?.optString("text") }
            .joinToString("\n").trim()

        val deferred = MobileDeferredTools()
        val messages = mutableListOf(userText("Parent plan:\n$plan\n\nAssigned task:\n$task"))
        val written = mutableListOf<String>()
        fun finish(answer: String, done: Boolean, hitStepLimit: Boolean = false): String {
            val parts = mutableListOf(answer)
            if (!done) parts += "[Partial: the subagent did not finish. Check the files before relying on it.]"
            if (hitStepLimit) parts += "[The subagent reached its step limit.]"
            parts += if (written.isEmpty()) "[No file was changed.]"
            else "Files changed: " + written.joinToString(", ") + "\nReview these files; fix small issues yourself."
            return parts.joinToString("\n\n")
        }

        repeat(MAX_STEPS) { step ->
            if (!currentCoroutineContext().isActive) return finish("The subagent was stopped before it finished.", done = false)
            if (step > 0) MobilePromptHistory.supersedeRepeatedReads(messages)
            val response = try {
                complete(messages)
            } catch (t: CancellationException) {
                throw t
            } catch (t: Throwable) {
                return finish("The subagent failed: ${t.message ?: "provider error"}", done = false)
            }
            val blocks = response.optJSONArray("content") ?: JSONArray()
            val assistant = JSONObject().put("role", "assistant").put("content", blocks)
            response.optJSONArray("responses_output_items")?.let { assistant.put("responses_output_items", it) }
            messages += assistant

            val calls = (0 until blocks.length()).mapNotNull { blocks.optJSONObject(it)?.takeIf { block -> block.optString("type") == "tool_use" } }
            if (calls.isEmpty()) {
                val answer = textOf(blocks)
                return finish(answer.ifEmpty { "The subagent returned no report." }, done = finished(answer))
            }

            val results = JSONArray()
            for (wireCall in calls) {
                val call = deferred.resolve(wireCall, catalog)
                val name = call.optString("name")
                val input = call.optJSONObject("input") ?: JSONObject()
                val output = deferred.control(name, input, catalog, false) ?: when (name) {
                    in MobileExplore.READ_ONLY_TOOLS -> invoke(name, input)
                    in WRITE_TOOLS -> {
                        val path = normalize(input.optString("path"))
                        if (path != null && covers(claims, path)) {
                            // Both tools answer in fixed English, so a success is recognisable.
                            invoke(name, input).also { if ((it.startsWith("Wrote ") || it.startsWith("Edited ")) && path !in written) written += path }
                        } else {
                            "refused: ${input.optString("path").ifEmpty { "that path" }} is not in your assignment (${claims.joinToString(", ")}). Do not work around this; report it under Unresolved."
                        }
                    }
                    else -> "blocked: this subagent can only read and edit files; it has no $name tool."
                }
                deferred.record(output, call.optString("id", "tool"), output.startsWith("Tool error", true), name)
                results.put(JSONObject()
                    .put("type", "tool_result")
                    .put("tool_use_id", call.optString("id", "tool"))
                    .put("content", MobileDeferredTools.excerpt(output, name, call.optString("id", "tool"))))
            }
            messages += JSONObject().put("role", "user").put("content", results)
        }

        // Out of steps with edits possibly half done: one last call for an honest report
        // beats leaving the parent to guess what state the files are in. It keeps the
        // same tools so the cached prefix still matches.
        messages += userText("Your step budget is spent. Do not call any tool. Report now in the required shape, with Status: partial, naming exactly what is finished and what is not.")
        val answer = runCatching { textOf(complete(messages).optJSONArray("content")) }
            .onFailure { if (it is CancellationException) throw it }
            .getOrDefault("")
        return finish(answer.ifEmpty { "The subagent reached its step limit without a report." }, done = false, hitStepLimit = true)
    }

    /** Reads the subagent's own `Status:` line. Missing or malformed counts as partial. */
    fun finished(answer: String): Boolean {
        val status = answer.lines().lastOrNull { it.trim().lowercase().startsWith("status:") } ?: return false
        return status.trim().lowercase().removePrefix("status:").trim().startsWith("done")
    }
}

/**
 * One subagent run's provider usage, reported with its finished event so the cost
 * and cache reuse of side runs is measurable apart from the conversation's requests.
 */
internal class SubagentUsage {
    private var requests = 0
    private var input = 0
    private var cached = 0
    private var written = 0

    fun add(response: JSONObject, anthropic: Boolean) {
        val usage = MobileCacheUsage.parse(response, anthropic)
        requests += 1
        input += usage.inputTokens ?: 0
        cached += usage.cachedTokens ?: 0
        written += usage.writeTokens ?: 0
    }

    fun payload(): Map<String, String> = mapOf(
        "requests" to "$requests", "inputTokens" to "$input", "cachedTokens" to "$cached", "cacheWriteTokens" to "$written",
    )
}

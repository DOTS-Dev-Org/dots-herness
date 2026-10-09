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
    /** A target, not a ceiling: findings that need the room keep it. */
    const val CONDENSE_THRESHOLD = 2_000
    /** Where the one condense retry fires; below it the round-trip costs more than it saves. */
    const val CONDENSE_TRIGGER = 3_500
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
            "three files answers the question: do that directly, since a subagent costs a whole extra run. State " +
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
        Keep the answer under $CONDENSE_THRESHOLD characters. Go past it only when the findings genuinely
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
     * transcript and whether tools are offered; the condense retry and the wrap-up
     * pass false because they must produce text.
     */
    suspend fun run(
        rawTask: String,
        complete: suspend (messages: List<JSONObject>, offerTools: Boolean) -> JSONObject,
        invoke: suspend (name: String, input: JSONObject) -> String,
    ): String {
        val task = rawTask.trim()
        if (task.isEmpty()) return "Tool error: explore needs a task - the full question to answer."

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
            steps += 1
            val response = try {
                complete(messages, true)
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
                var answer = textOf(blocks)
                if (answer.isEmpty()) return finish("The subagent returned no findings.")
                // Nothing is ever cut: a half fact reads exactly like a whole one. Past
                // the trigger the subagent is asked once to tighten its own answer.
                if (answer.length > CONDENSE_TRIGGER) {
                    messages += userText("Your answer is too long for the caller's context. Rewrite it under $CONDENSE_THRESHOLD characters in the same shape, keeping every path:line and the Status line. Drop restated findings and quoted code.")
                    val shorter = runCatching { textOf(complete(messages, false).optJSONArray("content")) }
                        .onFailure { if (it is CancellationException) throw it }
                        .getOrDefault("")
                    if (shorter.isNotEmpty() && shorter.length < answer.length) answer = shorter
                }
                return finish(answer)
            }

            val results = JSONArray()
            for (call in calls) {
                val name = call.optString("name")
                val input = call.optJSONObject("input") ?: JSONObject()
                val path = input.optString("path")
                if (name == "read_file" && path.isNotEmpty() && path !in readPaths) readPaths += path
                if (name != "read_file" && name in READ_ONLY_TOOLS) searches += 1
                val output = if (name in READ_ONLY_TOOLS) invoke(name, input)
                else "blocked: the exploration agent is read-only and has no $name tool."
                results.put(JSONObject()
                    .put("type", "tool_result")
                    .put("tool_use_id", call.optString("id", "tool"))
                    .put("content", output.take(MAXIMUM_TOOL_RESULT_CHARACTERS)))
            }
            messages += JSONObject().put("role", "user").put("content", results)
        }

        // The step budget is spent, but the transcript still holds what was found:
        // one last tool-free call turns it into an answer instead of discarding it.
        messages += userText("Your step budget is spent. Answer now from what you already found, in the required shape, with Status: partial.")
        var answer = runCatching { textOf(complete(messages, false).optJSONArray("content")) }
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

    const val DESCRIPTION =
        "Hand one self-contained part of a change to a separate agent that reads and edits files, and get back " +
            "only its report. Use it for a large part of a task that touches its own set of files, so those file " +
            "bodies stay out of this conversation. Do not use it for a change that fits in a few edits: do that " +
            "yourself, since a subagent costs a whole extra run on this conversation's model. On this device " +
            "subagents run one at a time, so call delegate once per turn. `files` is the subagent's assignment: " +
            "the only paths it may create or change. A directory covers everything under it. The subagent cannot " +
            "run commands, delete files or write elsewhere, and it sees nothing of this conversation, so state " +
            "the task in full: what to change, the interfaces it must keep, and the conventions to follow. Test " +
            "the result yourself afterwards, and re-read a file the subagent changed before editing it."

    fun schema(): JSONObject = JSONObject()
        .put("type", "object")
        .put("properties", JSONObject()
            .put("task", JSONObject().put("type", "string").put("description", "The complete instructions for this part of the change."))
            .put("files", JSONObject()
                .put("type", "array")
                .put("items", JSONObject().put("type", "string"))
                .put("description", "Workspace-relative files or directories this subagent may create or change.")))
        .put("required", JSONArray().put("task").put("files"))

    fun systemPrompt(claims: List<String>): String = """
        You are an editing agent working inside one workspace on one assigned part of a larger change.
        You may create or change only these paths (a directory covers everything under it):
        ${claims.joinToString("\n        ") { "- $it" }}
        You may read any file. A write outside the assignment is refused: do not look for another way,
        report what was needed under Unresolved instead. You cannot run commands or delete files.
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
        complete: suspend (messages: List<JSONObject>, offerTools: Boolean) -> JSONObject,
        invoke: suspend (name: String, input: JSONObject) -> String,
    ): String {
        val task = rawTask.trim()
        if (task.isEmpty()) return "Tool error: delegate needs a task - the complete instructions for the subagent."

        fun userText(value: String) = JSONObject().put("role", "user")
            .put("content", JSONArray().put(JSONObject().put("type", "text").put("text", value)))
        fun textOf(blocks: JSONArray?): String = (0 until (blocks?.length() ?: 0))
            .mapNotNull { blocks?.optJSONObject(it)?.takeIf { block -> block.optString("type") == "text" }?.optString("text") }
            .joinToString("\n").trim()

        val messages = mutableListOf(userText(task))
        val written = mutableListOf<String>()
        fun finish(answer: String, done: Boolean, hitStepLimit: Boolean = false): String {
            val parts = mutableListOf(answer)
            if (!done) parts += "[Partial: the subagent did not finish. Check the files before relying on it.]"
            if (hitStepLimit) parts += "[The subagent reached its step limit.]"
            parts += if (written.isEmpty()) "[No file was changed.]"
            else "Files changed: " + written.joinToString(", ") + "\nRe-read any of these before editing it yourself."
            return parts.joinToString("\n\n")
        }

        repeat(MAX_STEPS) {
            if (!currentCoroutineContext().isActive) return finish("The subagent was stopped before it finished.", done = false)
            val response = try {
                complete(messages, true)
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
            for (call in calls) {
                val name = call.optString("name")
                val input = call.optJSONObject("input") ?: JSONObject()
                val output = when (name) {
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
                results.put(JSONObject()
                    .put("type", "tool_result")
                    .put("tool_use_id", call.optString("id", "tool"))
                    .put("content", output.take(MobileExplore.MAXIMUM_TOOL_RESULT_CHARACTERS)))
            }
            messages += JSONObject().put("role", "user").put("content", results)
        }

        // Out of steps with edits possibly half done: one tool-free call for an honest
        // report beats leaving the parent to guess what state the files are in.
        messages += userText("Your step budget is spent. Report now in the required shape, with Status: partial, naming exactly what is finished and what is not.")
        val answer = runCatching { textOf(complete(messages, false).optJSONArray("content")) }
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

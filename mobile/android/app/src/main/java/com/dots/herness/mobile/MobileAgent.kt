package com.dots.herness.mobile

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.util.UUID

/**
 * The agent loop that runs *on the phone*, used when no desktop is reachable.
 * Speaks provider wire formats directly and normalizes every response into the
 * same internal tool-call shape.
 */
class AgentToolSpec(
    val name: String,
    val description: String,
    val schema: JSONObject,
    val run: suspend (JSONObject) -> String,
) {
    fun wire(): JSONObject = JSONObject().put("name", name).put("description", description).put("input_schema", schema)
}

data class AgentTurn(val role: String, val text: String, val toolName: String? = null)
data class MobileApprovalRequest(val id: String, val toolName: String)
data class MobileQuestionRequest(val id: String, val question: String)

class MobileHarnessRuntime(
    private val apiKey: () -> String,
    private val systemPrompt: () -> String,
    private val stateStore: MobileStateStore? = null,
    private val oauthToken: () -> String = { "" },
    private val sessionAccountId: () -> String = { "" },
    private val workspaceSnapshotProvider: (() -> Map<String, String>)? = null,
    private val gitClient: MobileGitClient? = null,
) {
    var transcript by mutableStateOf<List<AgentTurn>>(emptyList()); private set
    var running by mutableStateOf(false); private set
    var provider by mutableStateOf(stateStore?.setting("herness.agent.provider") ?: "anthropic"); private set
    var model by mutableStateOf(stateStore?.setting("herness.agent.model") ?: MODELS.first()); private set
    var error by mutableStateOf<String?>(null)
    var runtimeState by mutableStateOf("idle"); private set
    var events by mutableStateOf(stateStore?.recentEvents() ?: emptyList()); private set
    var planMode by mutableStateOf(false)
    var approvalRequest by mutableStateOf<MobileApprovalRequest?>(null); private set
    var questionRequest by mutableStateOf<MobileQuestionRequest?>(null); private set
    /** Prompt text contributed by loaded plugins, appended to the system prompt. */
    var pluginPrompt by mutableStateOf("")

    private val tools = linkedMapOf<String, AgentToolSpec>()
    private val wire = mutableListOf<JSONObject>()
    private var promptHistory = MobilePromptHistory()
    private val orderedTools get() = tools.values.sortedBy { it.name }
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private var job: Job? = null
    private data class QueuedPrompt(val text: String, val mode: String, val planMode: Boolean)
    private data class PendingTool(val id: String, val name: String, val input: JSONObject)
    private val queuedPrompts = ArrayDeque<QueuedPrompt>()
    private var pendingTool: PendingTool? = null
    private var pendingQuestion: PendingTool? = null
    private var activePlanMode = false
    private var activeBeforeFiles: Map<String, String>? = null
    private var activeRunId = UUID.randomUUID().toString()
    private var activeTurnId = UUID.randomUUID().toString()
    private var activeTrackingStatus = "not_applicable"
    private var activeVerifiedRemovals = 0
    private var activePreservedRemoval = false
    private var activeUnverifiedDeletion = false
    private var activeCleanupFailure = false
    private var activeTestStatus = "not_reported"

    init {
        // Every run can read what the other chats on this device did, so a shared
        // workspace mirror never gets one chat blaming another chat's edit on itself.
        stateStore?.let { store -> register(AgentTools.chats(store) { conversationId }) }
    }

    fun register(specs: List<AgentToolSpec>) { specs.forEach { tools[it.name] = it } }
    fun selectModel(value: String) {
        if (value !in MODELS) return
        model = value
        stateStore?.saveSetting("herness.agent.model", value)
        stateStore?.saveProvider(provider, value, "keystore:phone.provider")
    }
    fun selectProvider(value: String) {
        val previous = provider
        provider = value
        stateStore?.saveSetting("herness.agent.provider", value)
        if (value == "anthropic" && !model.startsWith("claude")) selectModel("claude-sonnet-4-5")
        if (value == "gpt" && !model.startsWith("gpt-")) selectModel("gpt-5.6-luna")
        if (value != "anthropic" && value != "gpt" && model.startsWith("claude")) selectModel("gpt-4.1-mini")
        stateStore?.saveProvider(value, model, "keystore:phone.provider")
        if (previous != value) emit("connection.changed", mapOf(
            "action" to "selected",
            "previousConnectionLabel" to providerLabel(previous),
            "currentConnectionLabel" to providerLabel(value),
            "cleanupStatus" to "preserved",
            "removedLocalArtifacts" to "[]",
            "remoteDataTouched" to "false",
            "userDataPreserved" to "true",
        ))
    }
    fun start() { runtimeState = "ready" }
    fun cancel() {
        job?.cancel(); job = null; running = false; runtimeState = "cancelled"
        queuedPrompts.clear(); pendingTool = null; pendingQuestion = null
        approvalRequest = null; questionRequest = null
        stateStore?.finishRun(conversationId, "cancelled")
        emit("run.cancelled", mapOf("reason" to "user"))
    }
    fun reset() { cancel(); wire.clear(); promptHistory = MobilePromptHistory(); transcript = emptyList(); conversationId = null; runtimeState = "idle" }

    fun send(text: String, mode: String = "queue", planMode: Boolean = false) {
        val prompt = text.trim()
        if (prompt.isEmpty()) return
        if (running) {
            queuedPrompts.addLast(QueuedPrompt(prompt, mode, planMode))
            emit("prompt.queued", mapOf("mode" to mode, "planMode" to planMode.toString(), "text" to prompt))
            return
        }
        if ((if (provider == "gpt") oauthToken() else apiKey()).isBlank()) {
            error = if (provider == "gpt") "Sign in with ChatGPT in Settings to run GPT on this phone." else "Add a provider API key in Settings to run the agent on this phone."
            return
        }
        beginRun(prompt, mode, planMode)
    }

    private fun beginRun(prompt: String, mode: String, planMode: Boolean) {
        activeRunId = UUID.randomUUID().toString()
        activeTurnId = UUID.randomUUID().toString()
        activePlanMode = planMode
        activeVerifiedRemovals = 0
        activePreservedRemoval = false
        activeUnverifiedDeletion = false
        activeCleanupFailure = false
        activeTestStatus = "not_reported"
        val snapshotProvider = workspaceSnapshotProvider
        if (snapshotProvider != null) {
            val before = runCatching { snapshotProvider.invoke() }.getOrNull()
            activeBeforeFiles = before
            activeTrackingStatus = if (before == null) "incomplete" else "complete"
        } else {
            activeBeforeFiles = null
            activeTrackingStatus = "not_applicable"
        }
        if (conversationId == null) conversationId = stateStore?.startRun(mode, planMode, prompt)
        else stateStore?.appendMessage(conversationId, "user", prompt)
        runtimeState = "running"
        emit("run.started", mapOf("mode" to mode, "planMode" to planMode.toString()))
        transcript = transcript + AgentTurn("user", prompt)
        emit("message.user", mapOf("text" to prompt))
        val captured = promptHistory.capture(prompt, systemPrompt(), HerNessPrompt.pluginGuidance(pluginPrompt))
        wire += JSONObject().put("role", "user").put("content", JSONArray().put(JSONObject().put("type", "text").put("text", captured)))
        persistModelContext()
        running = true
        job = scope.launch { runLoop() }
    }

    fun continueRun() {
        if (running || conversationId == null || pendingTool != null || pendingQuestion != null) return
        running = true; runtimeState = "running"
        emit("run.continued", emptyMap())
        job = scope.launch { runLoop() }
    }

    fun `continue`() = continueRun()

    fun answerApproval(approvalId: String, accepted: Boolean) {
        val pending = pendingTool?.takeIf { it.id == approvalId } ?: return
        pendingTool = null
        approvalRequest = null
        val answer = if (accepted) "allowed-once" else "rejected"
        stateStore?.resolvePendingAction(approvalId, if (accepted) "approved" else "rejected")
        emit("approval.answered", mapOf("approvalId" to approvalId, "answer" to answer))
        if (pending.name == "run_command" && AgentTools.mayDeleteFiles(pending.input.optString("command"))) activeUnverifiedDeletion = true
        scope.launch {
            val output = if (accepted) invoke(pending.name, pending.input) else "Tool rejected by the user." to true
            appendToolResult(pending.id, pending.name, output)
            continueRun()
        }
    }

    fun answerQuestion(questionId: String, answers: List<String>) {
        val pending = pendingQuestion?.takeIf { it.id == questionId } ?: return
        pendingQuestion = null
        questionRequest = null
        stateStore?.resolvePendingAction(questionId, "answered")
        emit("question.answered", mapOf("questionId" to questionId, "answers" to answers.joinToString("\n")))
        val answer = answers.joinToString("\n").trim()
        appendToolResult(pending.id, pending.name, (if (answer.isBlank()) "No answer was provided." else answer) to answer.isBlank())
        continueRun()
    }

    fun selectRepository(repository: RepoCoordinates) {
        stateStore?.saveRepository(repository)
        stateStore?.saveSetting("repository", repository.slug)
        stateStore?.saveSetting("repository.branch", repository.branch)
        emit("repository.selected", mapOf("repository" to repository.slug, "branch" to repository.branch))
    }

    fun refreshWorkspace() { emit("workspace.refreshed", mapOf("source" to "local")) }

    suspend fun executeGit(operation: String): String {
        val gitClient = gitClient ?: run {
            val message = "unsupported_on_mobile: " + operation + " requires the native MobileGitClient backend."
            emit("git.unsupported", mapOf("operation" to operation, "reason" to message))
            return message
        }
        val result = gitClient.execute(operation)
        if (result.unavailable) emit("git.unsupported", mapOf("operation" to operation, "reason" to result.output))
        return result.output
    }

    private suspend fun runLoop() {
        try {
            for (step in 0 until MAXIMUM_TOOL_ITERATIONS) {
                val response = complete()
                val blocks = response.optJSONArray("content") ?: JSONArray()
                wire += JSONObject().put("role", "assistant").put("content", blocks)

                val said = (0 until blocks.length()).mapNotNull { index ->
                    blocks.optJSONObject(index)?.takeIf { it.optString("type") == "text" }?.optString("text")
                }.joinToString("\n")
                if (said.isNotBlank()) {
                    transcript = transcript + AgentTurn("assistant", said)
                    stateStore?.appendMessage(conversationId, "assistant", said)
                    emit("message.assistant", mapOf("text" to said))
                }

                val calls = (0 until blocks.length()).mapNotNull { index ->
                    blocks.optJSONObject(index)?.takeIf { it.optString("type") == "tool_use" }
                }
                if (calls.isEmpty()) return

                val results = JSONArray()
                for (call in calls) {
                    val name = call.optString("name")
                    val callId = call.optString("id")
                    val input = call.optJSONObject("input") ?: JSONObject()
                    emit("tool.started", mapOf("name" to name, "callId" to callId))
                    if (activePlanMode && blockedInPlanMode(name)) {
                        results.put(recordToolResult(callId, name, "blocked_in_plan_mode: $name is read-only in plan mode." to true))
                        continue
                    }
                    if (name == "run_command" && AgentTools.isTestCommand(input.optString("command"))) activeTestStatus = "requested"
                    if (name == "ask_user") {
                        if (results.length() > 0) wire += JSONObject().put("role", "user").put("content", results)
                        pendingQuestion = PendingTool(callId, name, input)
                        questionRequest = MobileQuestionRequest(callId, input.optString("question").ifBlank { input.optString("questions").ifBlank { "The agent needs more information." } })
                        stateStore?.savePendingAction(callId, conversationId, "question", mapOf("toolName" to name), "waiting")
                        runtimeState = "waiting_question"
                        running = false
                        emit("question.required", mapOf("questionId" to callId, "questions" to (questionRequest?.question ?: "")))
                        return
                    }
                    if (requiresApproval(name)) {
                        if (results.length() > 0) wire += JSONObject().put("role", "user").put("content", results)
                        pendingTool = PendingTool(callId, name, input)
                        approvalRequest = MobileApprovalRequest(callId, name)
                        stateStore?.savePendingAction(callId, conversationId, "approval", mapOf("toolName" to name), "waiting")
                        runtimeState = "waiting_approval"
                        running = false
                        emit("approval.required", mapOf("approvalId" to callId, "toolName" to name))
                        return
                    }
                    if (name == "run_command") {
                        if (AgentTools.mayDeleteFiles(input.optString("command"))) activeUnverifiedDeletion = true
                    }
                    results.put(recordToolResult(callId, name, invoke(name, input)))
                }
                wire += JSONObject().put("role", "user").put("content", results)
            }
            transcript = transcript + AgentTurn("error", "Stopped after $MAXIMUM_TOOL_ITERATIONS tool steps.")
            runtimeState = "failed"
            stateStore?.finishRun(conversationId, "failed")
            emit("run.failed", mapOf("reason" to "maximum_tool_steps"))
        } catch (t: Throwable) {
            if (t is kotlinx.coroutines.CancellationException) {
                runtimeState = "cancelled"
                stateStore?.finishRun(conversationId, "cancelled")
            } else {
                transcript = transcript + AgentTurn("error", t.message ?: "The agent request failed.")
                error = t.message
                runtimeState = "failed"
                stateStore?.finishRun(conversationId, "failed")
                emit("run.failed", mapOf("reason" to (t.message ?: "provider_error")))
            }
        } finally {
            persistModelContext()
            if (!runtimeState.startsWith("waiting_")) {
                if (runtimeState == "running") runtimeState = "completed"
                val finalStatus = runtimeState
                stateStore?.finishRun(conversationId, finalStatus)
                val diff = finishWorkspaceTracking()
                val cleanupStatus = cleanupStatus(diff.trackingStatus)
                val note = cleanupNote(cleanupStatus, diff.trackingStatus)
                val summary = "Files: +${diff.added.size} added, ${diff.modified.size} changed, ${diff.deleted.size} removed. $note"
                transcript = transcript + AgentTurn("system", summary)
                stateStore?.appendMessage(conversationId, "system", summary)
                diff.added.forEach { path -> emit("file.changed", mapOf("runId" to activeRunId, "turnId" to activeTurnId, "path" to path, "operation" to "added")) }
                diff.modified.forEach { path -> emit("file.changed", mapOf("runId" to activeRunId, "turnId" to activeTurnId, "path" to path, "operation" to "modified")) }
                diff.deleted.forEach { path -> emit("file.deleted", mapOf("runId" to activeRunId, "turnId" to activeTurnId, "path" to path, "operation" to "deleted")) }
                emit("run.summary", mapOf(
                    "runId" to activeRunId,
                    "turnId" to activeTurnId,
                    "status" to finalStatus,
                    "trackingStatus" to diff.trackingStatus,
                    "cleanupStatus" to cleanupStatus,
                    "cleanupNote" to note,
                    "addedCount" to diff.added.size.toString(),
                    "modifiedCount" to diff.modified.size.toString(),
                    "deletedCount" to diff.deleted.size.toString(),
                    "testStatus" to activeTestStatus,
                ))
                if (finalStatus == "completed") emit("run.completed", emptyMap())
            }
            running = false
            if (runtimeState == "completed" && queuedPrompts.isNotEmpty()) {
                val next = queuedPrompts.removeFirst()
                beginRun(next.text, next.mode, next.planMode)
            }
        }
    }

    private fun appendToolResult(id: String, name: String, output: Pair<String, Boolean>) {
        wire += JSONObject().put("role", "user").put("content", JSONArray().put(recordToolResult(id, name, output)))
    }

    private fun recordToolResult(id: String, name: String, output: Pair<String, Boolean>): JSONObject {
        if (name == "remove_file") {
            if (output.second) activeCleanupFailure = true
            if (output.first.contains(AgentTools.VERIFIED_MARKER)) activeVerifiedRemovals++
            if (output.first.contains(AgentTools.PRESERVED_MARKER)) activePreservedRemoval = true
            if (output.first.contains(AgentTools.FAILED_MARKER)) activeCleanupFailure = true
        }
        if (name == "run_command" && activeTestStatus == "requested") activeTestStatus = if (output.second) "failed" else "passed"
        transcript = transcript + AgentTurn("tool", output.first, name)
        stateStore?.appendMessage(conversationId, "tool", output.first, name)
        emit("tool.finished", mapOf("name" to name, "callId" to id, "isError" to output.second.toString()))
        return JSONObject()
            .put("type", "tool_result")
            .put("tool_use_id", id)
            .put("content", output.first.take(MAXIMUM_TOOL_RESULT_CHARACTERS))
            .put("is_error", output.second)
    }

    private fun blockedInPlanMode(name: String): Boolean =
        name == "write_file" || name == "remove_file" || name == "run_command" || name == "sql" || name.startsWith("git")

    private fun requiresApproval(name: String): Boolean =
        name == "write_file" || name == "remove_file" || name == "run_command" || name == "sql" || name.startsWith("git")

    private data class WorkspaceDiff(val added: List<String>, val modified: List<String>, val deleted: List<String>, val trackingStatus: String)

    private fun finishWorkspaceTracking(): WorkspaceDiff {
        val provider = workspaceSnapshotProvider ?: return WorkspaceDiff(emptyList(), emptyList(), emptyList(), "not_applicable")
        val before = activeBeforeFiles ?: return WorkspaceDiff(emptyList(), emptyList(), emptyList(), "incomplete")
        return runCatching {
            val after = provider.invoke()
            WorkspaceDiff(
                after.keys.filter { it !in before }.sorted(),
                after.keys.filter { it in before && before[it] != after[it] }.sorted(),
                before.keys.filter { it !in after }.sorted(),
                "complete",
            )
        }.getOrElse { WorkspaceDiff(emptyList(), emptyList(), emptyList(), "incomplete") }
    }

    private fun cleanupStatus(trackingStatus: String? = null): String = when {
        activePlanMode -> "not_applicable"
        activeCleanupFailure -> "failed"
        activeUnverifiedDeletion -> "not_verified"
        trackingStatus == "incomplete" -> "not_verified"
        activeVerifiedRemovals > 0 -> "verified"
        activePreservedRemoval -> "preserved"
        else -> "not_applicable"
    }

    private fun cleanupNote(status: String, trackingStatus: String): String = when {
        trackingStatus == "incomplete" -> "Workspace changes could not be fully verified; uncertain artifacts were kept."
        status == "verified" -> "Proven-unused cleanup was verified."
        status == "preserved" -> "An old artifact was preserved because cleanup could not be proven safe."
        status == "not_verified" -> "A deletion command was detected outside the safe removal flow; cleanup was not verified."
        status == "failed" -> "Cleanup did not finish; the result needs review."
        else -> "No cleanup was requested."
    }

    private fun providerLabel(value: String): String = when (value) {
        "anthropic" -> "Anthropic"
        "openai" -> "OpenAI"
        "openai-responses" -> "OpenAI Responses"
        "gpt" -> "ChatGPT"
        else -> "Provider"
    }

    private suspend fun invoke(name: String, input: JSONObject): Pair<String, Boolean> {
        val tool = tools[name] ?: return "No tool named $name is available on this phone." to true
        return try { tool.run(input) to false } catch (t: Throwable) { (t.message ?: "$name failed.") to true }
    }

    private suspend fun complete(): JSONObject {
        compactContextIfNeeded()
        emit("provider.request", mapOf("provider" to provider, "model" to model))
        return when (provider) {
            "anthropic" -> completeAnthropic()
            "openai-responses" -> completeOpenAIResponses()
            "gpt" -> completeChatGPT()
            else -> completeOpenAI()
        }
    }

    private suspend fun completeAnthropic(): JSONObject = withContext(Dispatchers.IO) {
        val body = JSONObject()
            .put("model", model)
            .put("max_tokens", 8192)
            .put("system", promptHistory.policy.orEmpty())
            .put("messages", JSONArray(wire))
        if (tools.isNotEmpty()) body.put("tools", JSONArray(orderedTools.map { it.wire() }))

        val response = providerRequest("https://api.anthropic.com/v1/messages", body, apiKey(), mapOf("x-api-key" to apiKey(), "anthropic-version" to "2023-06-01"))
        val status = response.status
        val text = response.body
        if (status !in 200..299) error(providerError(text, status))
        JSONObject(text).also { emit("provider.response", mapOf("provider" to "anthropic", "status" to status.toString(), "usage" to it.optJSONObject("usage")?.toString().orEmpty())) }
    }

    private suspend fun completeOpenAI(): JSONObject = withContext(Dispatchers.IO) {
        val definitions = JSONArray(orderedTools.map { tool ->
            JSONObject().put("type", "function").put("function", JSONObject()
                .put("name", tool.name).put("description", tool.description).put("parameters", tool.schema))
        })
        val body = JSONObject()
            .put("model", model)
            .put("max_completion_tokens", 8192)
            .put("messages", openAiMessages())
        if (definitions.length() > 0) body.put("tools", definitions)
        val response = providerRequest("https://api.openai.com/v1/chat/completions", body, apiKey(), emptyMap())
        val status = response.status
        val text = response.body
        if (status !in 200..299) error(providerError(text, status))
        val root = JSONObject(text)
        val message = root.optJSONArray("choices")?.optJSONObject(0)?.optJSONObject("message")
            ?: error("The provider returned an unexpected response.")
        val blocks = JSONArray()
        message.optString("content").takeIf { it.isNotEmpty() }?.let { blocks.put(JSONObject().put("type", "text").put("text", it)) }
        val calls = message.optJSONArray("tool_calls") ?: JSONArray()
        for (index in 0 until calls.length()) {
            val call = calls.optJSONObject(index) ?: continue
            val function = call.optJSONObject("function") ?: continue
            val input = runCatching { JSONObject(function.optString("arguments", "{}")) }.getOrElse { JSONObject() }
            blocks.put(JSONObject().put("type", "tool_use").put("id", call.optString("id", UUID.randomUUID().toString())).put("name", function.optString("name")).put("input", input))
        }
        emit("provider.response", mapOf("provider" to provider, "status" to status.toString(), "usage" to root.optJSONObject("usage")?.toString().orEmpty()))
        JSONObject().put("content", blocks)
    }

    private suspend fun completeOpenAIResponses(): JSONObject =
        completeResponses("https://api.openai.com/v1/responses", apiKey(), emptyMap(), "openai-responses")

    private suspend fun completeChatGPT(): JSONObject {
        val account = sessionAccountId()
        if (account.isBlank()) error("The ChatGPT session account is unavailable. Sign in again in Settings.")
        return completeResponses(
            "https://chatgpt.com/backend-api/codex/responses",
            oauthToken(),
            mapOf(
                "ChatGPT-Account-ID" to account,
                "OAI-Product-Sku" to "codex",
                "OpenAI-Beta" to "responses=v1",
                "originator" to "dots_harness",
                "session_id" to UUID.randomUUID().toString(),
            ),
            "gpt",
        )
    }

    private suspend fun completeResponses(endpoint: String, token: String, headers: Map<String, String>, providerName: String): JSONObject = withContext(Dispatchers.IO) {
        val body = JSONObject()
            .put("model", model)
            .put("instructions", promptHistory.policy.orEmpty())
            .put("input", responsesInput())
            .put("store", false)
            .put("stream", false)
        if (tools.isNotEmpty()) {
            body.put("tools", JSONArray(orderedTools.map { JSONObject().put("type", "function").put("name", it.name).put("description", it.description).put("parameters", it.schema) }))
        }
        val response = providerRequest(endpoint, body, token, headers)
        if (response.status !in 200..299) error(providerError(response.body, response.status))
        val root = JSONObject(response.body)
        val output = root.optJSONArray("output") ?: error("The provider returned an unexpected Responses payload.")
        val blocks = JSONArray()
        for (index in 0 until output.length()) {
            val item = output.optJSONObject(index) ?: continue
            when (item.optString("type")) {
                "message" -> {
                    val content = item.optJSONArray("content") ?: JSONArray()
                    for (partIndex in 0 until content.length()) {
                        val text = content.optJSONObject(partIndex)?.optString("text").orEmpty()
                        if (text.isNotEmpty()) blocks.put(JSONObject().put("type", "text").put("text", text))
                    }
                }
                "function_call" -> {
                    val arguments = runCatching { JSONObject(item.optString("arguments", "{}")) }.getOrElse { JSONObject() }
                    blocks.put(JSONObject().put("type", "tool_use").put("id", item.optString("call_id", item.optString("id", UUID.randomUUID().toString()))).put("name", item.optString("name")).put("input", arguments))
                }
            }
        }
        emit("provider.response", mapOf("provider" to providerName, "status" to response.status.toString(), "usage" to root.optJSONObject("usage")?.toString().orEmpty()))
        JSONObject().put("content", blocks)
    }

    private fun responsesInput(): JSONArray {
        val result = JSONArray()
        wire.forEach { message ->
            val role = message.optString("role")
            val content = message.optJSONArray("content") ?: JSONArray()
            if (role == "user") {
                val results = (0 until content.length()).mapNotNull { content.optJSONObject(it)?.takeIf { item -> item.optString("type") == "tool_result" } }
                if (results.isEmpty()) {
                    val text = JSONArray()
                    for (index in 0 until content.length()) content.optJSONObject(index)?.optString("text")?.takeIf(String::isNotEmpty)?.let { text.put(JSONObject().put("type", "input_text").put("text", it)) }
                    result.put(JSONObject().put("role", "user").put("content", text))
                } else {
                    results.forEach { item -> result.put(JSONObject().put("type", "function_call_output").put("call_id", item.optString("tool_use_id", "tool")).put("output", item.optString("content"))) }
                }
            } else if (role == "assistant") {
                val text = (0 until content.length()).mapNotNull { content.optJSONObject(it)?.takeIf { item -> item.optString("type") == "text" }?.optString("text") }.joinToString("\n")
                if (text.isNotEmpty()) result.put(JSONObject().put("role", "assistant").put("content", JSONArray().put(JSONObject().put("type", "output_text").put("text", text))))
                for (index in 0 until content.length()) {
                    val item = content.optJSONObject(index) ?: continue
                    if (item.optString("type") == "tool_use") result.put(JSONObject().put("type", "function_call").put("call_id", item.optString("id", UUID.randomUUID().toString())).put("name", item.optString("name")).put("arguments", item.optJSONObject("input")?.toString() ?: "{}"))
                }
            }
        }
        return result
    }

    private data class ProviderResponse(val status: Int, val body: String)

    private suspend fun providerRequest(endpoint: String, body: JSONObject, token: String, headers: Map<String, String>): ProviderResponse = withContext(Dispatchers.IO) {
        var result = ProviderResponse(0, "")
        for (attempt in 0..2) {
            val connection = (URL(endpoint).openConnection() as HttpURLConnection).apply {
                requestMethod = "POST"
                connectTimeout = 15_000
                readTimeout = 300_000
                doOutput = true
                setRequestProperty("Authorization", "Bearer " + token)
                setRequestProperty("Content-Type", "application/json")
                headers.forEach { (key, value) -> setRequestProperty(key, value) }
                outputStream.use { it.write(body.toString().toByteArray()) }
            }
            val status = connection.responseCode
            val text = (if (status in 200..299) connection.inputStream else connection.errorStream)?.use { String(it.readBytes()) } ?: ""
            result = ProviderResponse(status, text)
            if ((status != 429 && status < 500) || attempt == 2) return@withContext result
            delay((attempt + 1) * 1_000L)
        }
        result
    }

    private fun openAiMessages(): JSONArray {
        val result = JSONArray().put(JSONObject().put("role", "system").put("content", promptHistory.policy.orEmpty()))
        wire.forEach { message ->
            val role = message.optString("role")
            val blocks = message.optJSONArray("content") ?: JSONArray()
            when (role) {
                "assistant" -> {
                    val text = (0 until blocks.length()).mapNotNull { blocks.optJSONObject(it)?.takeIf { block -> block.optString("type") == "text" }?.optString("text") }.joinToString("\n")
                    val item = JSONObject().put("role", "assistant").put("content", text.ifEmpty { JSONObject.NULL })
                    val calls = JSONArray()
                    for (index in 0 until blocks.length()) {
                        val block = blocks.optJSONObject(index) ?: continue
                        if (block.optString("type") != "tool_use") continue
                        calls.put(JSONObject().put("id", block.optString("id")).put("type", "function").put("function", JSONObject().put("name", block.optString("name")).put("arguments", block.optJSONObject("input")?.toString() ?: "{}")))
                    }
                    if (calls.length() > 0) item.put("tool_calls", calls)
                    result.put(item)
                }
                "user" -> {
                    val toolResults = (0 until blocks.length()).mapNotNull { blocks.optJSONObject(it)?.takeIf { block -> block.optString("type") == "tool_result" } }
                    if (toolResults.isEmpty()) {
                        result.put(JSONObject().put("role", "user").put("content", (0 until blocks.length()).mapNotNull { blocks.optJSONObject(it)?.optString("text") }.joinToString("\n")))
                    } else {
                        toolResults.forEach { block -> result.put(JSONObject().put("role", "tool").put("tool_call_id", block.optString("tool_use_id")).put("content", block.optString("content"))) }
                    }
                }
            }
        }
        return result
    }

    private fun providerError(text: String, status: Int): String {
        val message = runCatching { JSONObject(text).getJSONObject("error").getString("message") }.getOrElse { text }
        return status.toString() + ": " + message.ifBlank { "The provider request failed." }
    }

    private fun compactContextIfNeeded() {
        val encoded = JSONArray(wire).toString()
        if (encoded.toByteArray().size <= MAXIMUM_CONTEXT_BYTES || wire.isEmpty()) return
        val first = wire.first()
        val kept = mutableListOf(first)
        kept += wire.drop(1).takeLast(12)
        wire.clear()
        wire.addAll(kept)
        val compacted = JSONArray(wire).toString()
        persistModelContext()
        emit("context.compacted", mapOf("bytes" to encoded.toByteArray().size.toString(), "keptBytes" to compacted.toByteArray().size.toString()))
    }

    private fun persistModelContext() {
        val snapshot = JSONObject().put("version", 1).put("policy", promptHistory.policy.orEmpty()).put("messages", JSONArray(wire))
        stateStore?.saveModelContext(conversationId, snapshot.toString())
    }

    private fun emit(kind: String, payload: Map<String, String>) {
        val event = stateStore?.appendEvent(conversationId, kind, payload)
            ?: MobileRuntimeEvent(UUID.randomUUID().toString(), conversationId, kind, payload, System.currentTimeMillis())
        events = (events + event).takeLast(500)
    }

    companion object {
        val MODELS = listOf("claude-sonnet-4-5", "claude-opus-4-1", "claude-haiku-4-5", "gpt-4.1-mini", "gpt-4.1", "o4-mini", "gpt-5.6-luna", "gpt-5.6-terra")
        const val MAXIMUM_TOOL_ITERATIONS = 24
        const val MAXIMUM_TOOL_RESULT_CHARACTERS = 20_000
        const val MAXIMUM_CONTEXT_BYTES = 100_000
    }

    private var conversationId: String? = null
}

typealias MobileAgent = MobileHarnessRuntime

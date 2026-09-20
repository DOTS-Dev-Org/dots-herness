package com.dots.herness.mobile

import android.content.Context
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
    private val appContext: Context? = null,
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
    /** A compaction replaces the serialized prefix and starts a new cache segment. */
    private var contextSegment = 0
    private val orderedTools get() = tools.values.sortedBy { it.name }
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private var job: Job? = null
    private data class QueuedPrompt(val text: String, val attachments: List<MobileAttachment>, val mode: String, val planMode: Boolean)
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
    private val attachments = linkedMapOf<String, MobileAttachment>()
    private var pendingLatestAttachment: MobileAttachment? = null

    init {
        // Every run can read what the other chats on this device did, so a shared
        // workspace mirror never gets one chat blaming another chat's edit on itself.
        stateStore?.let { store -> register(AgentTools.chats(store) { conversationId }) }
        register(listOf(
            AgentToolSpec(
                "get_latest_attachment",
                "Read the latest immutable source revision for an attachment after a revision notice. Call only when current bytes are needed.",
                JSONObject()
                    .put("type", "object")
                    .put("properties", JSONObject().put("attachment_id", JSONObject().put("type", "string").put("description", "The stable attachment_id from the revision notice.")))
                    .put("required", JSONArray().put("attachment_id"))
                    .put("additionalProperties", false),
            ) { input -> latestAttachmentResult(input) },
        ))
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
    fun reset() {
        cancel()
        wire.clear()
        attachments.clear()
        pendingLatestAttachment = null
        promptHistory = MobilePromptHistory()
        contextSegment = 0
        transcript = emptyList()
        conversationId = null
        runtimeState = "idle"
    }

    fun send(text: String, attachments: List<MobileAttachment> = emptyList(), mode: String = "queue", planMode: Boolean = false) {
        val prompt = text.trim()
        if (prompt.isEmpty() && attachments.isEmpty()) return
        val stableAttachments = appContext?.let { context -> attachments.map { it.stabilized(context) } } ?: attachments
        stableAttachments.forEach { this.attachments[it.attachmentId] = it }
        if (running) {
            queuedPrompts.addLast(QueuedPrompt(prompt, stableAttachments, mode, planMode))
            emit("prompt.queued", mapOf("mode" to mode, "planMode" to planMode.toString(), "text" to prompt))
            return
        }
        if ((if (provider == "gpt") oauthToken() else apiKey()).isBlank()) {
            error = if (provider == "gpt") "Sign in with ChatGPT in Settings to run GPT on this phone." else "Add a provider API key in Settings to run the agent on this phone."
            return
        }
        beginRun(prompt, stableAttachments, mode, planMode)
    }

    private fun beginRun(prompt: String, attachments: List<MobileAttachment> = emptyList(), mode: String, planMode: Boolean) {
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
        val attachmentLabel = attachments.joinToString(", ") { it.displayName }
        transcript = transcript + AgentTurn("user", listOf(prompt, attachmentLabel.takeIf { it.isNotEmpty() }?.let { "[Attachments: $it]" }).filterNotNull().filter { it.isNotEmpty() }.joinToString("\n"))
        emit("message.user", mapOf("text" to prompt, "attachments" to attachments.size.toString()))
        val captured = promptHistory.capture(prompt, systemPrompt(), HerNessPrompt.pluginGuidance(pluginPrompt))
        wire += canonicalUserMessage(captured, attachments)
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
                beginRun(next.text, next.attachments, next.mode, next.planMode)
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
        val result = JSONObject()
            .put("type", "tool_result")
            .put("tool_use_id", id)
            .put("content", output.first.take(MAXIMUM_TOOL_RESULT_CHARACTERS))
            .put("is_error", output.second)
        pendingLatestAttachment?.let {
            result.put("attachment", it.canonicalBlock())
            pendingLatestAttachment = null
        }
        return result
    }

    private fun canonicalUserMessage(text: String, attachments: List<MobileAttachment>): JSONObject = JSONObject().apply {
        put("role", "user")
        val content = JSONArray().put(JSONObject().put("type", "text").put("text", text))
        attachments.forEach { content.put(it.canonicalBlock()) }
        put("content", content)
    }

    private suspend fun latestAttachmentResult(input: JSONObject): String {
        val id = input.optString("attachment_id").takeIf { it.isNotBlank() }
            ?: return "attachment_not_found\nhistorical_revision_preserved\nlatest_revision_unavailable"
        val current = attachments[id]
            ?: return "attachment_not_found\nhistorical_revision_preserved\nlatest_revision_unavailable"
        val context = appContext
            ?: return "source_unreadable\nhistorical_revision_preserved\nlatest_revision_unavailable\nattachment_id: $id"
        val observation = current.observe(context)
        when (observation.status) {
            MobileAttachmentSourceStatus.MISSING -> return "source_missing\nhistorical_revision_preserved\nlatest_revision_unavailable\nattachment_id: $id"
            MobileAttachmentSourceStatus.UNREADABLE -> return "source_unreadable\nhistorical_revision_preserved\nlatest_revision_unavailable\nattachment_id: $id"
            MobileAttachmentSourceStatus.CURRENT -> if (current.snapshotPath != null && current.contentHash == observation.currentHash) {
                pendingLatestAttachment = current
                return "latest_revision_current\nattachment_id: $id\nrevision: V${maxOf(current.revision, 1)}\ncontent_hash: ${current.contentHash.orEmpty()}"
            }
            MobileAttachmentSourceStatus.CHANGED -> Unit
        }
        val latest = current.refreshed(context)
        if (latest.snapshotPath == null || latest.contentHash == null || latest.contentHash != observation.currentHash || latest.providerData() == null) {
            return "source_unreadable\nhistorical_revision_preserved\nlatest_revision_unavailable\nattachment_id: $id"
        }
        attachments[id] = latest
        pendingLatestAttachment = latest
        return "latest_revision_created\nattachment_id: $id\nrevision: V${latest.revision}\ncontent_hash: ${latest.contentHash}"
    }

    private fun attachmentRevisionNotice(): String? {
        val notices = attachments.values.sortedBy { it.attachmentId }.mapNotNull { attachment ->
            val context = appContext ?: return@mapNotNull null
            val observation = attachment.observe(context)
            val status = when (observation.status) {
                MobileAttachmentSourceStatus.CURRENT -> return@mapNotNull null
                MobileAttachmentSourceStatus.CHANGED -> "changed"
                MobileAttachmentSourceStatus.MISSING -> "missing"
                MobileAttachmentSourceStatus.UNREADABLE -> "unreadable"
            }
            val detail = when (observation.status) {
                MobileAttachmentSourceStatus.MISSING -> "source_missing\nhistorical_revision_preserved\nlatest_revision_unavailable"
                MobileAttachmentSourceStatus.UNREADABLE -> "source_unreadable\nhistorical_revision_preserved\nlatest_revision_unavailable"
                else -> "The source file changed. The historical V1 bytes remain immutable and must not be treated as current."
            }
            "[Attachment revision notice]\nattachment_id: ${attachment.attachmentId}\nname: ${attachment.displayName}\nrevision: V${maxOf(attachment.revision, 1) + 1}\nstatus: $status\n$detail\nIf current content is needed, call get_latest_attachment with {\"attachment_id\":\"${attachment.attachmentId}\"}. Do not infer missing or unreadable bytes."
        }
        return notices.takeIf { it.isNotEmpty() }?.joinToString("\n\n")
    }

    private fun wireForRequest(): List<JSONObject> {
        val copies = wire.map { JSONObject(it.toString()) }.toMutableList()
        val notice = attachmentRevisionNotice() ?: return copies
        val index = copies.indexOfLast { message ->
            if (message.optString("role") != "user") return@indexOfLast false
            val content = message.optJSONArray("content") ?: return@indexOfLast false
            (0 until content.length()).any { content.optJSONObject(it)?.optString("type") != "tool_result" }
        }
        if (index < 0) return copies
        val content = copies[index].optJSONArray("content") ?: JSONArray()
        content.put(0, JSONObject().put("type", "text").put("text", notice))
        copies[index].put("content", content)
        return copies
    }

    private fun markDelivered() {
        attachments.toMap().forEach { (id, attachment) ->
            val hash = attachment.contentHash ?: return@forEach
            if (attachment.snapshotPath == null || attachment.deliveredHash == hash) return@forEach
            attachments[id] = attachment.copy(deliveredHash = hash, sourceStatus = MobileAttachmentSourceStatus.CURRENT)
        }
        wire.forEach { message ->
            val content = message.optJSONArray("content") ?: return@forEach
            for (index in 0 until content.length()) {
                val block = content.optJSONObject(index) ?: continue
                val attachment = if (block.optString("type") == "attachment") block else block.optJSONObject("attachment")
                val id = attachment?.optString("attachment_id").orEmpty()
                val hash = attachments[id]?.deliveredHash
                if (attachment != null && id.isNotEmpty() && hash != null) attachment.put("delivered_hash", hash)
            }
        }
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
        val response = when (provider) {
            "anthropic" -> completeAnthropic()
            "openai-responses" -> completeOpenAIResponses()
            "gpt" -> completeChatGPT()
            else -> completeOpenAI()
        }
        markDelivered()
        return response
    }

    private fun attachmentBlock(block: JSONObject, format: String): JSONObject {
        val id = block.optString("attachment_id", "unknown")
        val attachment = attachments[id]
        val data = attachment?.providerData()
        if (attachment == null || data == null) {
            return JSONObject().put("type", if (format == "responses") "input_text" else "text")
                .put("text", "source_missing: attachment_id $id; historical_revision_preserved; latest_revision_unavailable")
        }
        val base64 = android.util.Base64.encodeToString(data, android.util.Base64.NO_WRAP)
        val document = attachment.kind == MobileAttachmentKind.FILE &&
            (attachment.mimeType == "application/pdf" || attachment.mimeType.startsWith("text/") || attachment.mimeType == "application/json")
        return when (format) {
            "anthropic" -> when {
                attachment.kind == MobileAttachmentKind.IMAGE -> JSONObject().put("type", "image").put("source", JSONObject().put("type", "base64").put("media_type", attachment.mimeType).put("data", base64))
                document && attachment.mimeType == "application/pdf" -> JSONObject().put("type", "document").put("source", JSONObject().put("type", "base64").put("media_type", attachment.mimeType).put("data", base64))
                else -> unsupportedAttachmentBlock(attachment, format)
            }
            "responses" -> when {
                attachment.kind == MobileAttachmentKind.IMAGE -> JSONObject().put("type", "input_image").put("image_url", "data:${attachment.mimeType};base64,$base64")
                document -> JSONObject().put("type", "input_file").put("filename", attachment.displayName).put("file_data", "data:${attachment.mimeType};base64,$base64")
                else -> unsupportedAttachmentBlock(attachment, format)
            }
            else -> when {
                attachment.kind == MobileAttachmentKind.IMAGE -> JSONObject().put("type", "image_url").put("image_url", JSONObject().put("url", "data:${attachment.mimeType};base64,$base64"))
                document -> JSONObject().put("type", "file").put("file", JSONObject().put("filename", attachment.displayName).put("file_data", "data:${attachment.mimeType};base64,$base64"))
                else -> unsupportedAttachmentBlock(attachment, format)
            }
        }
    }

    private fun unsupportedAttachmentBlock(attachment: MobileAttachment, format: String): JSONObject = JSONObject()
        .put("type", if (format == "responses") "input_text" else "text")
        .put("text", "unsupported_attachment_kind: ${attachment.kind.name.lowercase()}; attachment_id: ${attachment.attachmentId}; name: ${attachment.displayName}. The host did not silently drop this attachment, but this provider route does not support its wire format.")

    private fun anthropicMessages(): JSONArray {
        val result = JSONArray()
        wireForRequest().forEach { message ->
            val role = message.optString("role")
            val content = message.optJSONArray("content") ?: JSONArray()
            if (role == "assistant") {
                val blocks = JSONArray()
                for (index in 0 until content.length()) {
                    val block = content.optJSONObject(index) ?: continue
                    if (block.optString("type") == "text" || block.optString("type") == "tool_use") blocks.put(block)
                }
                result.put(JSONObject().put("role", "assistant").put("content", blocks))
            } else {
                val results = (0 until content.length()).mapNotNull { content.optJSONObject(it)?.takeIf { block -> block.optString("type") == "tool_result" } }
                if (results.isNotEmpty()) {
                    val blocks = JSONArray()
                    results.forEach { item ->
                        val tool = JSONObject()
                            .put("type", "tool_result")
                            .put("tool_use_id", item.optString("tool_use_id", "tool"))
                            .put("content", item.optString("content"))
                        item.optJSONObject("attachment")?.let { attachment ->
                            tool.put("content", JSONArray().put(JSONObject().put("type", "text").put("text", item.optString("content"))).put(attachmentBlock(attachment, "anthropic")))
                        }
                        blocks.put(tool)
                    }
                    result.put(JSONObject().put("role", "user").put("content", blocks))
                } else {
                    val blocks = JSONArray()
                    for (index in 0 until content.length()) {
                        val block = content.optJSONObject(index) ?: continue
                        when (block.optString("type")) {
                            "text" -> blocks.put(block)
                            "attachment" -> blocks.put(attachmentBlock(block, "anthropic"))
                        }
                    }
                    result.put(JSONObject().put("role", "user").put("content", blocks))
                }
            }
        }
        return result
    }

    private suspend fun completeAnthropic(): JSONObject = withContext(Dispatchers.IO) {
        val body = JSONObject()
            .put("model", model)
            .put("max_tokens", 8192)
            .put("system", promptHistory.policy.orEmpty())
            .put("messages", anthropicMessages())
        if (tools.isNotEmpty()) body.put("tools", JSONArray(orderedTools.map { it.wire() }))
        applyAnthropicCacheBreakpoints(body)

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
            .put("prompt_cache_key", promptCacheKey("openai-chat"))
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
            .put("prompt_cache_key", promptCacheKey(if (providerName == "gpt") "chatgpt-responses" else "openai-responses"))
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

    private fun promptCacheKey(route: String): String {
        val account = sessionAccountId().trim()
        return MobilePromptCache.key(
            conversationId = conversationId,
            provider = provider,
            route = route,
            model = model,
            accountScope = account.ifBlank { provider },
            toolFingerprint = MobilePromptCache.toolFingerprint(orderedTools),
            contextSegment = contextSegment,
        )
    }

    /**
     * Anthropic caches the prefix ending at explicit cache_control breakpoints.
     * Work on cloned JSON objects so provider metadata never enters the
     * durable append-only transcript.
     */
    private fun applyAnthropicCacheBreakpoints(body: JSONObject) {
        val ephemeral = JSONObject().put("type", "ephemeral")
        val policy = body.optString("system")
        if (policy.isNotEmpty()) {
            body.put("system", JSONArray().put(JSONObject()
                .put("type", "text")
                .put("text", policy)
                .put("cache_control", JSONObject(ephemeral.toString()))))
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
                if (index == messages.length() - 1) {
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

    private fun responsesInput(): JSONArray {
        val result = JSONArray()
        wireForRequest().forEach { message ->
            val role = message.optString("role")
            val content = message.optJSONArray("content") ?: JSONArray()
            if (role == "user") {
                val results = (0 until content.length()).mapNotNull { content.optJSONObject(it)?.takeIf { item -> item.optString("type") == "tool_result" } }
                if (results.isEmpty()) {
                    val blocks = JSONArray()
                    for (index in 0 until content.length()) {
                        val block = content.optJSONObject(index) ?: continue
                        blocks.put(if (block.optString("type") == "attachment") attachmentBlock(block, "responses") else JSONObject().put("type", "input_text").put("text", block.optString("text")))
                    }
                    result.put(JSONObject().put("role", "user").put("content", blocks))
                } else {
                    results.forEach { item ->
                        result.put(JSONObject().put("type", "function_call_output").put("call_id", item.optString("tool_use_id", "tool")).put("output", item.optString("content")))
                        item.optJSONObject("attachment")?.let { attachment -> result.put(JSONObject().put("role", "user").put("content", JSONArray().put(attachmentBlock(attachment, "responses")))) }
                    }
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
        wireForRequest().forEach { message ->
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
                        val providerBlocks = JSONArray()
                        for (index in 0 until blocks.length()) {
                            val block = blocks.optJSONObject(index) ?: continue
                            providerBlocks.put(if (block.optString("type") == "attachment") attachmentBlock(block, "openai") else JSONObject().put("type", "text").put("text", block.optString("text")))
                        }
                        result.put(JSONObject().put("role", "user").put("content", providerBlocks))
                    } else {
                        toolResults.forEach { block ->
                            result.put(JSONObject().put("role", "tool").put("tool_call_id", block.optString("tool_use_id")).put("content", block.optString("content")))
                            block.optJSONObject("attachment")?.let { attachment -> result.put(JSONObject().put("role", "user").put("content", JSONArray().put(attachmentBlock(attachment, "openai")))) }
                        }
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
        contextSegment += 1
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

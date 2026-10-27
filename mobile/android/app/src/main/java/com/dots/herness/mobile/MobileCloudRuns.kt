// Copyright (c) 2026 DOTS
// Cloud runs on the phone: start, follow and cancel GitHub Actions runs of the
// HerNess agent in the selected project's repository (parity with the desktop
// Cloud work location, see docs/cloud-runs.md).
//
// The phone creates the run record with the HerNess account session, then
// dispatches herness-cloud.yml with the GitHub token from Settings. The runner
// streams its transcript back to the HerNess API and pushes its changes to a
// herness/cloud-* branch.

package com.dots.herness.mobile

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.util.Base64
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject

data class CloudRepository(val owner: String, val name: String) {
    val fullName get() = "$owner/$name"
    val webUrl get() = "https://github.com/$fullName"
    val actionsSecretsUrl get() = "$webUrl/settings/secrets/actions"
    fun branchUrl(branch: String) = "$webUrl/tree/$branch"

    companion object {
        fun parse(fullName: String?): CloudRepository? {
            val parts = fullName.orEmpty().split("/")
            if (parts.size != 2 || parts.any { part -> part.isEmpty() || !part.all { it.isLetterOrDigit() || it in "-_." } }) return null
            return CloudRepository(parts[0], parts[1])
        }
    }
}

data class CloudRun(
    val id: String,
    val repository: String,
    val baseRef: String,
    val prompt: String,
    val status: String,
    val cancelRequested: Boolean,
    val gitHubRunId: String?,
    val gitHubRunUrl: String?,
    val resultBranch: String?,
    val error: String?,
    val createdAt: String,
) {
    val isActive get() = status == "queued" || status == "running"

    companion object {
        fun from(json: JSONObject) = CloudRun(
            id = json.getString("id"),
            repository = json.getString("repository"),
            baseRef = json.getString("base_ref"),
            prompt = json.getString("prompt"),
            status = json.getString("status"),
            cancelRequested = json.optBoolean("cancel_requested"),
            gitHubRunId = json.nullableString("github_run_id"),
            gitHubRunUrl = json.nullableString("github_run_url"),
            resultBranch = json.nullableString("result_branch"),
            error = json.nullableString("error"),
            createdAt = json.optString("created_at"),
        )

        private fun JSONObject.nullableString(name: String): String? = if (isNull(name)) null else optString(name).ifBlank { null }
    }
}

data class CloudRunEvent(val seq: Int, val kind: String, val text: String) {
    companion object {
        fun list(array: JSONArray?): List<CloudRunEvent> = (0 until (array?.length() ?: 0)).map { index ->
            val item = array!!.getJSONObject(index)
            CloudRunEvent(item.getInt("seq"), item.getString("kind"), item.getString("text"))
        }
    }
}

/** A failure whose message is already localized. */
class CloudRunException(message: String) : Exception(message)

/** The api.github.com calls a cloud run needs, made with the phone's GitHub sign-in. */
class CloudGitHubActions(private val token: String, private val apiBase: String = "https://api.github.com") {
    data class Reply(val status: Int, val json: JSONObject?) {
        val message: String? get() = json?.optString("message")?.ifBlank { null }
    }

    fun defaultBranch(repository: CloudRepository): Reply = send("GET", "repos/${repository.fullName}")

    /** 204 is success; 404 means the workflow is missing on [ref]. */
    fun dispatch(repository: CloudRepository, ref: String, inputs: Map<String, String>): Reply =
        send("POST", "repos/${repository.fullName}/actions/workflows/$WORKFLOW_FILE/dispatches", JSONObject().put("ref", ref).put("inputs", JSONObject(inputs)))

    fun install(repository: CloudRepository, branch: String, content: String): Reply {
        val path = "repos/${repository.fullName}/contents/$WORKFLOW_PATH"
        val existing = send("GET", "$path?ref=${URLEncoder.encode(branch, "UTF-8")}")
        val body = JSONObject()
            .put("message", "Add HerNess cloud workflow")
            .put("content", Base64.encodeToString(content.toByteArray(), Base64.NO_WRAP))
            .put("branch", branch)
        existing.json?.optString("sha")?.takeIf { existing.status == 200 && it.isNotBlank() }?.let { body.put("sha", it) }
        return send("PUT", path, body)
    }

    fun cancel(repository: CloudRepository, runId: String): Reply = send("POST", "repos/${repository.fullName}/actions/runs/$runId/cancel")

    private fun send(method: String, path: String, body: JSONObject? = null): Reply {
        val connection = (URL("$apiBase/$path").openConnection() as HttpURLConnection).apply {
            requestMethod = method
            connectTimeout = 30_000
            readTimeout = 30_000
            setRequestProperty("Authorization", "Bearer $token")
            setRequestProperty("Accept", "application/vnd.github+json")
            setRequestProperty("X-GitHub-Api-Version", "2022-11-28")
            setRequestProperty("User-Agent", "HerNessMobile")
            if (body != null) { doOutput = true; setRequestProperty("Content-Type", "application/json") }
        }
        try {
            if (body != null) connection.outputStream.use { it.write(body.toString().toByteArray()) }
            val status = connection.responseCode
            val text = (if (status in 200..299) connection.inputStream else connection.errorStream)?.use { String(it.readBytes()) }.orEmpty()
            return Reply(status, runCatching { JSONObject(text) }.getOrNull())
        } finally {
            connection.disconnect()
        }
    }

    companion object {
        const val WORKFLOW_FILE = "herness-cloud.yml"
        const val WORKFLOW_PATH = ".github/workflows/$WORKFLOW_FILE"
    }
}

/** Cloud run state for the Cloud screen. Call from the main thread. */
class MobileCloudStore(private val context: Context, private val client: RemoteClient, private val scope: CoroutineScope) {
    private val session = MobileMarketplaceSession.shared(client)
    var runs by mutableStateOf(emptyList<CloudRun>()); private set
    val events = mutableStateMapOf<String, List<CloudRunEvent>>()
    var notice by mutableStateOf<String?>(null)
    var busy by mutableStateOf(false); private set
    private var polling = false

    val isSignedIn get() = session.isSignedIn

    private fun text(id: Int, vararg arguments: Any): String = context.getString(id, *arguments)

    private fun githubClient(): CloudGitHubActions {
        val token = SecureStore(context).read("oauth.github.access").orEmpty()
        if (token.isBlank()) throw CloudRunException(text(R.string.cloud_error_no_token))
        return CloudGitHubActions(token)
    }

    suspend fun signIn(email: String, password: String) {
        runCatching { session.signIn(email, password) }.onFailure { notice = it.message }
    }

    suspend fun start(prompt: String, repository: CloudRepository?, branch: String?): Boolean {
        if (busy) return false
        busy = true
        notice = null
        try {
            repository ?: throw CloudRunException(text(R.string.cloud_error_not_git_hub))
            if (!session.isSignedIn) throw CloudRunException(text(R.string.cloud_error_not_signed_in))
            val github = githubClient()
            val baseRef = branch?.trim()?.ifBlank { null } ?: withContext(Dispatchers.IO) { github.defaultBranch(repository) }.let { reply ->
                reply.json?.optString("default_branch")?.ifBlank { null } ?: throw githubFailure(reply)
            }
            val run = CloudRun.from(request("api/cloud-runs", "POST", JSONObject().put("repository", repository.fullName).put("base_ref", baseRef).put("prompt", prompt)).getJSONObject("run"))
            upsert(run)
            val inputs = mapOf("run_id" to run.id, "prompt" to prompt, "api_url" to session.base)
            val dispatch = withContext(Dispatchers.IO) { github.dispatch(repository, baseRef, inputs) }
            if (dispatch.status != 204 && dispatch.status != 200) {
                val error = if (dispatch.status == 404) CloudRunException(text(R.string.cloud_error_workflow_missing, repository.fullName, baseRef)) else githubFailure(dispatch)
                // Close the record so a failed dispatch does not hold an active-run slot.
                runCatching { upsert(cancelRecord(run.id, error.message)) }
                throw error
            }
            startPolling()
            return true
        } catch (error: Exception) {
            notice = error.message
            return false
        } finally {
            busy = false
        }
    }

    suspend fun refresh() {
        if (!session.isSignedIn) return
        runCatching {
            val array = request("api/cloud-runs").optJSONArray("runs") ?: JSONArray()
            runs = (0 until array.length()).map { CloudRun.from(array.getJSONObject(it)) }
            startPolling()
        }.onFailure { notice = it.message }
    }

    suspend fun refreshRun(id: String) {
        runCatching {
            while (true) {
                val after = events[id]?.lastOrNull()?.seq ?: 0
                val json = request("api/cloud-runs/$id?after=$after")
                upsert(CloudRun.from(json.getJSONObject("run")))
                val page = CloudRunEvent.list(json.optJSONArray("events"))
                // A poll and a manual refresh can both ask from the same seq.
                val fresh = page.filter { it.seq > (events[id]?.lastOrNull()?.seq ?: 0) }
                if (fresh.isNotEmpty()) events[id] = events[id].orEmpty() + fresh
                if (page.size < 200) break
            }
        }.onFailure { notice = it.message }
    }

    suspend fun cancel(run: CloudRun) {
        runCatching {
            upsert(cancelRecord(run.id, null))
            val repository = CloudRepository.parse(run.repository)
            val runId = run.gitHubRunId
            if (repository != null && runId != null) runCatching { withContext(Dispatchers.IO) { githubClient().cancel(repository, runId) } }
        }.onFailure { notice = it.message }
    }

    /** Commits herness-cloud.yml to the default branch. The GitHub sign-in needs the workflow scope. */
    suspend fun installWorkflow(repository: CloudRepository?) {
        if (busy) return
        busy = true
        notice = null
        try {
            repository ?: throw CloudRunException(text(R.string.cloud_error_not_git_hub))
            val template = context.assets.open(CloudGitHubActions.WORKFLOW_FILE).use { String(it.readBytes()) }
            val github = githubClient()
            val branch = withContext(Dispatchers.IO) { github.defaultBranch(repository) }.let { reply ->
                reply.json?.optString("default_branch")?.ifBlank { null } ?: throw githubFailure(reply)
            }
            val install = withContext(Dispatchers.IO) { github.install(repository, branch, template) }
            if (install.status == 403 || install.status == 404) throw CloudRunException(text(R.string.cloud_error_install_forbidden))
            if (install.status != 200 && install.status != 201) throw githubFailure(install)
            notice = text(R.string.cloud_installed, repository.fullName, branch)
        } catch (error: Exception) {
            notice = error.message
        } finally {
            busy = false
        }
    }

    private suspend fun cancelRecord(id: String, error: String?): CloudRun {
        val body = JSONObject()
        if (!error.isNullOrBlank()) body.put("error", error.take(500))
        return CloudRun.from(request("api/cloud-runs/$id/cancel", "POST", body).getJSONObject("run"))
    }

    private suspend fun request(path: String, method: String = "GET", body: JSONObject? = null): JSONObject {
        val (bytes, status) = session.authorizedData(path, method, body?.toString())
        val json = runCatching { JSONObject(String(bytes)) }.getOrNull()
        if (status in 200..299 && json != null) return json
        val error = json?.optString("error")?.ifBlank { null } ?: String(bytes).take(300)
        throw when {
            status == 429 && error == "cloud_run_limit" -> CloudRunException(text(R.string.cloud_error_limit, json?.optInt("limit", 3) ?: 3))
            status == 401 -> CloudRunException(text(R.string.cloud_error_not_signed_in))
            else -> CloudRunException(text(R.string.cloud_error_api, status, error))
        }
    }

    private fun githubFailure(reply: CloudGitHubActions.Reply) =
        CloudRunException(text(R.string.cloud_error_github, reply.status, reply.message ?: "HTTP ${reply.status}"))

    private fun upsert(run: CloudRun) {
        val index = runs.indexOfFirst { it.id == run.id }
        runs = if (index >= 0) runs.toMutableList().also { it[index] = run } else listOf(run) + runs
    }

    /** Polls while any run is queued or running, then stops. */
    private fun startPolling() {
        if (polling || runs.none { it.isActive }) return
        polling = true
        scope.launch {
            try {
                while (true) {
                    val active = runs.filter { it.isActive }
                    if (active.isEmpty()) break
                    active.forEach { refreshRun(it.id) }
                    delay(4_000)
                }
            } finally {
                polling = false
            }
        }
    }
}

@Composable
fun MobileCloudScreen(client: RemoteClient, onBack: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val store = remember(client) { MobileCloudStore(context.applicationContext, client, scope) }
    val repository = CloudRepository.parse(client.selectedProject.repository)
    val branch = client.selectedProject.branch
    var prompt by remember { mutableStateOf("") }
    var email by remember { mutableStateOf("") }
    var password by remember { mutableStateOf("") }
    var selected by remember { mutableStateOf<String?>(null) }
    var showSetup by remember { mutableStateOf(false) }
    val open: (String) -> Unit = { url -> runCatching { context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url))) } }

    LaunchedEffect(store.isSignedIn) {
        store.refresh()
        showSetup = store.runs.isEmpty()
    }

    LazyColumn(Modifier.fillMaxSize().padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        item {
            Column {
                Text(repository?.fullName ?: stringResource(R.string.cloud_no_repository), style = MaterialTheme.typography.titleMedium)
                Text(stringResource(R.string.cloud_subtitle), style = MaterialTheme.typography.bodySmall)
                store.notice?.let { SelectionContainer { Text(it, style = MaterialTheme.typography.bodySmall) } }
            }
        }
        if (!store.isSignedIn) {
            item {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(stringResource(R.string.cloud_error_not_signed_in))
                    OutlinedTextField(email, { email = it }, label = { Text(stringResource(R.string.market_email)) }, singleLine = true, modifier = Modifier.fillMaxWidth())
                    OutlinedTextField(password, { password = it }, label = { Text(stringResource(R.string.market_password)) }, singleLine = true, visualTransformation = PasswordVisualTransformation(), modifier = Modifier.fillMaxWidth())
                    Button(onClick = { scope.launch { store.signIn(email, password); password = "" } }, enabled = email.isNotBlank() && password.isNotBlank()) {
                        Text(stringResource(R.string.cloud_sign_in))
                    }
                }
            }
            return@LazyColumn
        }
        item {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                TextButton(onClick = { showSetup = !showSetup }) { Text(stringResource(R.string.cloud_setup_title)) }
                if (showSetup) {
                    Text(stringResource(R.string.cloud_setup_steps), style = MaterialTheme.typography.bodySmall)
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        OutlinedButton(onClick = { scope.launch { store.installWorkflow(repository) } }, enabled = repository != null && !store.busy) {
                            Text(stringResource(R.string.cloud_setup_install))
                        }
                        repository?.let { repo ->
                            OutlinedButton(onClick = { open(repo.actionsSecretsUrl) }) { Text(stringResource(R.string.cloud_setup_secrets)) }
                        }
                    }
                }
            }
        }
        item {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedTextField(prompt, { prompt = it }, label = { Text(stringResource(R.string.cloud_prompt)) }, minLines = 3, maxLines = 8, modifier = Modifier.fillMaxWidth())
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Button(
                        onClick = { scope.launch { if (store.start(prompt.trim(), repository, branch)) prompt = "" } },
                        enabled = prompt.isNotBlank() && !store.busy && repository != null,
                    ) { Text(stringResource(R.string.cloud_start)) }
                    if (store.busy) CircularProgressIndicator(Modifier.padding(4.dp))
                }
            }
        }
        if (store.runs.isEmpty()) item { Text(stringResource(R.string.cloud_empty), style = MaterialTheme.typography.bodySmall) }
        items(store.runs, key = { it.id }) { run ->
            CloudRunCard(
                run = run,
                events = store.events[run.id].orEmpty(),
                expanded = selected == run.id,
                onToggle = {
                    selected = if (selected == run.id) null else run.id
                    if (selected == run.id) scope.launch { store.refreshRun(run.id) }
                },
                onOpen = open,
                onStop = { scope.launch { store.cancel(run) } },
            )
        }
        item { TextButton(onClick = onBack) { Text(stringResource(R.string.intro_back)) } }
    }
}

@Composable
private fun CloudRunCard(
    run: CloudRun,
    events: List<CloudRunEvent>,
    expanded: Boolean,
    onToggle: () -> Unit,
    onOpen: (String) -> Unit,
    onStop: () -> Unit,
) {
    val status = when (run.status) {
        "queued" -> stringResource(R.string.cloud_status_queued)
        "running" -> stringResource(R.string.cloud_status_running)
        "succeeded" -> stringResource(R.string.cloud_status_succeeded)
        "failed" -> stringResource(R.string.cloud_status_failed)
        else -> stringResource(R.string.cloud_status_cancelled)
    }
    Card(Modifier.fillMaxWidth().clickable(onClick = onToggle)) {
        Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Text(run.prompt, style = MaterialTheme.typography.titleSmall, maxLines = if (expanded) Int.MAX_VALUE else 2)
            Text("$status · ${run.baseRef} · ${run.createdAt.take(16).replace('T', ' ')}", style = MaterialTheme.typography.bodySmall)
            if (expanded) {
                SelectionContainer {
                    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        events.forEach { event ->
                            Text(
                                event.text,
                                style = MaterialTheme.typography.bodySmall,
                                fontFamily = if (event.kind == "tool") FontFamily.Monospace else null,
                            )
                        }
                        run.error?.let { Text(it, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall) }
                    }
                }
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    run.gitHubRunUrl?.let { url -> TextButton(onClick = { onOpen(url) }) { Text(stringResource(R.string.cloud_open_run)) } }
                    val repository = CloudRepository.parse(run.repository)
                    run.resultBranch?.let { branch ->
                        if (repository != null) TextButton(onClick = { onOpen(repository.branchUrl(branch)) }) { Text(stringResource(R.string.cloud_open_branch, branch)) }
                    }
                    if (run.isActive) TextButton(onClick = onStop, enabled = !run.cancelRequested) { Text(stringResource(R.string.common_stop)) }
                }
            }
        }
    }
}

package com.dots.herness.mobile

import android.content.Context
import android.net.Uri
import android.os.Build
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.net.HttpURLConnection
import java.net.URI
import java.net.URL
import java.net.URLEncoder
import java.nio.charset.StandardCharsets
import java.security.KeyStore
import java.security.MessageDigest
import java.util.Base64
import java.util.UUID
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

data class RemoteFile(val path: String, val bytes: Long, val sha256: String, val mode: Int)
data class ExcludedFile(val path: String, val reason: String)
data class WorkspaceSnapshot(val workspaceId: String, val revision: Long, val files: List<RemoteFile>, val excluded: List<ExcludedFile>, val baseCommitSha: String? = null)
data class RemoteEvent(val id: String, val sequence: Long, val kind: String, val payload: Map<String, String>, val artifactId: String?)
data class RemoteArtifact(val id: String, val kind: String, val bytes: Long)
data class Bootstrap(val workspaceId: String, val revision: Long, val status: String, val isBusy: Boolean, val accessMode: String, val provider: String?, val model: String?, val capabilities: List<String>)
data class CommandResult(val commandId: String, val status: String, val approvalId: String?, val result: String?, val error: String?)

private data class PairingPayload(val endpoint: String, val code: String) {
    companion object {
        fun fromFields(endpoint: String, code: String): PairingPayload? {
            val normalized = endpoint.trim().trimEnd('/')
            val parsed = runCatching { URI(normalized) }.getOrNull()
            val scheme = parsed?.scheme?.lowercase()
            if (scheme != "https" || parsed?.host.isNullOrBlank() || parsed?.userInfo != null || code.length != 6 || !code.all { it in '0'..'9' }) return null
            return PairingPayload(normalized, code)
        }

        fun fromUri(uri: Uri): PairingPayload? {
            if (!uri.scheme.equals("herness", ignoreCase = true) || !uri.host.equals("pair", ignoreCase = true)) return null
            if (uri.queryParameterNames != setOf("endpoint", "code") || uri.getQueryParameters("endpoint").size != 1 || uri.getQueryParameters("code").size != 1) return null
            return fromFields(uri.getQueryParameter("endpoint").orEmpty(), uri.getQueryParameter("code").orEmpty())
        }
    }
}

class RemoteClient(private val context: Context) : ViewModel() {
    var endpoint by mutableStateOf(""); private set
    var token by mutableStateOf(""); private set
    var bootstrap by mutableStateOf<Bootstrap?>(null); private set
    var snapshot by mutableStateOf<WorkspaceSnapshot?>(null); private set
    var events by mutableStateOf<List<RemoteEvent>>(emptyList()); private set
    var pairingEndpoint by mutableStateOf("")
    var pairingCode by mutableStateOf("")
    var error by mutableStateOf<String?>(null); private set
    var connecting by mutableStateOf(false); private set
    var pairing by mutableStateOf(false); private set
    var isGuest by mutableStateOf(false); private set
    var cloneStatus by mutableStateOf(""); private set
    var repo by mutableStateOf(RepoCoordinates()); private set
    private val secure = SecureStore(context)
    private val preferences = context.getSharedPreferences("herness.preferences", Context.MODE_PRIVATE)
    private val eventLock = Any()
    private var eventJob: Job? = null

    init {
        endpoint = secure.read("endpoint") ?: ""
        token = secure.read("token") ?: ""
        isGuest = preferences.getBoolean("guest_mode", false) || preferences.getBoolean("works_offline", false)
        loadCachedSnapshot()
        loadRepo()
        if (endpoint.isNotBlank() && token.isNotBlank()) connect()
    }

    val paired get() = endpoint.isNotBlank() && token.isNotBlank()
    val workspaceId get() = bootstrap?.workspaceId ?: snapshot?.workspaceId ?: ""

    fun pair(onDone: () -> Unit = {}) {
        val payload = PairingPayload.fromFields(pairingEndpoint, pairingCode)
        if (payload == null) { error = "Enter a valid HTTPS endpoint and six-digit code."; return }
        if (pairing) return
        viewModelScope.launch(Dispatchers.IO) {
            pairing = true
            try {
                val body = JSONObject().put("code", payload.code).put("deviceName", Build.MODEL).toString().toByteArray()
                val response = http("/v1/control/pair/complete", "POST", body, auth = false, base = payload.endpoint)
                val result = JSONObject(String(response.body))
                endpoint = payload.endpoint; token = result.getString("token"); isGuest = false
                preferences.edit().putBoolean("guest_mode", false).putBoolean("works_offline", false).apply()
                secure.write("endpoint", endpoint); secure.write("token", token)
                connect(); onDone()
            } catch (t: Throwable) { error = t.message ?: "Pairing failed" }
            finally { pairing = false }
        }
    }

    fun consumePairUri(uri: Uri) {
        val payload = PairingPayload.fromUri(uri)
        if (payload == null) { error = "This QR code is not a valid HerNess pairing code."; return }
        pairingEndpoint = payload.endpoint
        pairingCode = payload.code
        pair()
    }

    fun consumePairValue(value: String) { consumePairUri(Uri.parse(value)) }

    fun continueAsGuest() {
        isGuest = true
        preferences.edit().putBoolean("guest_mode", true).putBoolean("works_offline", true).apply()
        error = null
    }

    fun leaveGuest() {
        isGuest = false
        preferences.edit().putBoolean("guest_mode", false).putBoolean("works_offline", false).apply()
    }

    fun connect() {
        viewModelScope.launch(Dispatchers.IO) {
            connecting = true
            try { bootstrap = parseBootstrap(http("/v1/control/bootstrap").body); error = null; startEvents() }
            catch (t: Throwable) { error = t.message ?: "Connection failed" }
            connecting = false
        }
    }

    fun requestSnapshot() {
        if (!paired) return
        viewModelScope.launch(Dispatchers.IO) {
            try {
                snapshot = parseSnapshot(http("/v1/control/snapshot/request", "POST").body)
                cacheSnapshot(snapshot!!)
                var conflictPath: String? = null
                snapshot!!.files.forEach { file ->
                    runCatching {
                        val target = localTarget(file.path)
                        val pendingBase = pendingBase(file.path)
                        val localHash = target.takeIf { it.exists() }?.let { sha256(it.readBytes()) }
                        if (pendingBase != null && localHash != null && localHash != pendingBase) {
                            if (file.sha256 != pendingBase) {
                                conflictPath = file.path
                            }
                            return@runCatching
                        }
                        target.parentFile?.mkdirs()
                        target.writeBytes(http("/v1/control/file?path=${URLEncoder.encode(file.path, "UTF-8")}").body)
                    }
                }
                error = conflictPath?.let { "Conflict: $it changed on both the phone and desktop. Your local edit was kept." }
            }
            catch (t: Throwable) { error = t.message ?: "Snapshot failed" }
        }
    }

    suspend fun readFile(path: String): String = withContext(Dispatchers.IO) {
        try { String(http("/v1/control/file?path=${URLEncoder.encode(path, "UTF-8")}").body, StandardCharsets.UTF_8) }
        catch (t: Throwable) { cachedFile(path) ?: throw t }
    }

    suspend fun artifactText(id: String): String = withContext(Dispatchers.IO) {
        String(http("/v1/control/artifact?id=${URLEncoder.encode(id, "UTF-8")}").body, StandardCharsets.UTF_8)
    }

    suspend fun downloadArtifact(id: String, fileName: String): File = withContext(Dispatchers.IO) {
        val safeName = fileName.substringAfterLast('/').replace(Regex("[^A-Za-z0-9._-]"), "_").ifBlank { "$id.artifact" }
        val directory = File(context.cacheDir, "herness-artifacts").apply { mkdirs() }
        val target = File(directory, safeName)
        val temporary = File(directory, ".$safeName.part-${UUID.randomUUID()}")
        temporary.writeBytes(http("/v1/control/artifact?id=${URLEncoder.encode(id, "UTF-8")}").body)
        if (!temporary.renameTo(target)) {
            temporary.copyTo(target, overwrite = true)
            temporary.delete()
        }
        target
    }

    suspend fun artifacts(): List<RemoteArtifact> = withContext(Dispatchers.IO) {
        val array = JSONArray(String(http("/v1/control/artifacts").body))
        (0 until array.length()).map { index ->
            val item = array.getJSONObject(index)
            RemoteArtifact(item.getString("id"), item.optString("kind", "artifact"), item.optLong("bytes"))
        }
    }

    suspend fun saveFile(file: RemoteFile, text: String): CommandResult = withContext(Dispatchers.IO) {
        val expectedSha = pendingBase(file.path) ?: file.sha256
        val remote = if (paired && bootstrap != null) runCatching {
            command("write_file", mapOf("path" to file.path, "content" to text, "expectedSha256" to expectedSha), snapshot?.revision)
        }.getOrNull() else null
        if (remote?.status == "conflict") return@withContext remote
        if (remote?.status == "completed") clearPending(file.path) else if (remote == null || remote.status == "approval-required" || remote.status == "offline") recordPending(file.path, expectedSha)
        cacheFile(file.path, text)
        if (remote?.status == "completed") updateCachedFile(file, text)
        remote ?: CommandResult("", "offline", null, null, "Saved to the local workspace mirror.")
    }


    // Clone straight from GitHub when no desktop is reachable. A linked libgit2
    // backend creates the real repository; REST remains an explicit degraded
    // mirror path for APKs built without the native artifact.
    fun cloneFromGitHub(target: RepoCoordinates, token: String) {
        viewModelScope.launch(Dispatchers.IO) {
            if (!target.complete) { error = "Enter an owner, repository, and branch."; return@launch }
            if (token.isBlank()) { error = "A GitHub token is required to clone."; return@launch }
            val nativeGit = MobileGitClient({ workspaceRoot() }, { token })
            if (nativeGit.available) {
                if (AgentTools.walk(workspaceRoot()).isNotEmpty()) { error = "The local workspace is not empty. Create a new workspace before cloning a Git repository."; return@launch }
                cloneStatus = "Cloning ${target.slug}…"
                runCatching {
                    nativeGit.clone("https://github.com/${target.slug}.git", workspaceRoot(), target.branch)
                    val files = AgentTools.snapshot(workspaceRoot()).map { (path, hash) ->
                        val file = AgentTools.resolve(workspaceRoot(), path)
                        RemoteFile(path, file.length(), hash, if (file.canExecute()) 493 else 420)
                    }
                    val value = WorkspaceSnapshot("github:${target.slug}", 0, files.toList().sortedBy { it.path }, emptyList(), null)
                    snapshot = value
                    cacheSnapshot(value)
                    repo = target
                    saveRepo(target)
                    cloneStatus = "Cloned ${files.size} files from ${target.slug}."
                }.onFailure { cloneStatus = ""; error = it.message ?: "GitHub clone failed." }
                return@launch
            }
            val client = GitHubClient(token)
            cloneStatus = "Reading ${target.slug} as a workspace mirror…"
            try {
                val tree = client.fullTree(target.owner, target.repository, target.branch)
                if (tree.truncated) error = "This repository is too large for the GitHub tree API; some files were skipped."
                val files = mutableListOf<RemoteFile>()
                val excluded = mutableListOf<ExcludedFile>()
                tree.blobs.forEachIndexed { index, blob ->
                    if (blob.size > MAXIMUM_CLONE_FILE_BYTES) {
                        excluded += ExcludedFile(blob.path, "Larger than ${MAXIMUM_CLONE_FILE_BYTES / 1_048_576} MB.")
                        return@forEachIndexed
                    }
                    val bytes = client.blob(target.owner, target.repository, blob.sha)
                    val file = localTarget(blob.path)
                    file.parentFile?.mkdirs()
                    file.writeBytes(bytes)
                    files += RemoteFile(blob.path, bytes.size.toLong(), sha256(bytes), if (blob.mode == "100755") 493 else 420)
                    if (index % 10 == 0) cloneStatus = "Downloaded ${index + 1} of ${tree.blobs.size} files…"
                }
                val value = WorkspaceSnapshot("github:${target.slug}", 0, files.sortedBy { it.path }, excluded, tree.commit)
                snapshot = value
                cacheSnapshot(value)
                repo = target
                saveRepo(target)
                cloneStatus = "Downloaded ${files.size} files to the workspace mirror. Native libgit2 is not linked in this build."
            } catch (t: Throwable) {
                cloneStatus = ""
                error = t.message ?: "GitHub clone failed."
            }
        }
    }

    fun saveRepo(value: RepoCoordinates) {
        repo = value
        metaFile("repo.json").apply {
            parentFile?.mkdirs()
            writeText(JSONObject().put("owner", value.owner).put("repository", value.repository).put("branch", value.branch).toString())
        }
    }

    private fun loadRepo() {
        val file = metaFile("repo.json")
        if (!file.exists()) return
        runCatching { JSONObject(file.readText()) }.getOrNull()?.let {
            repo = RepoCoordinates(it.optString("owner"), it.optString("repository"), it.optString("branch", "main"))
        }
    }

    fun savePhoneSecret(name: String, value: String) {
        if (value.isBlank()) secure.delete("phone.$name") else secure.write("phone.$name", value)
    }

    fun phoneSecret(name: String): String = secure.read("phone.$name").orEmpty()

    suspend fun command(kind: String, payload: Map<String, Any?>, expectedRevision: Long? = null): CommandResult = withContext(Dispatchers.IO) {
        val payloadJson = JSONObject(); payload.forEach { (key, value) -> payloadJson.put(key, value) }
        val json = JSONObject().put("id", UUID.randomUUID().toString()).put("workspaceId", workspaceId).put("kind", kind).put("expectedRevision", expectedRevision).put("payload", payloadJson).toString().toByteArray()
        val response = http("/v1/control/commands", "POST", json, allowError = true)
        val value = JSONObject(String(response.body))
        if (response.status !in 200..299 && value.optString("status") != "conflict") throw IllegalStateException(value.optString("error", "Remote command failed"))
        CommandResult(value.optString("commandId"), value.optString("status"), value.optString("approvalId").ifBlank { null }, value.opt("result")?.toString(), value.optString("error").ifBlank { null })
    }

    fun clearError() { error = null }
    fun reportError(message: String) { error = message }
    fun forget() { eventJob?.cancel(); secure.delete("endpoint"); secure.delete("token"); endpoint = ""; token = ""; bootstrap = null; leaveGuest() }
    fun cachedFiles() = snapshot?.files ?: emptyList()
    fun cachedText(path: String) = cachedFile(path)
    fun cachedChanges(): List<GitHubFileChange> = cachedFiles().mapNotNull { file ->
        val text = cachedText(file.path) ?: return@mapNotNull null
        if (sha256(text.toByteArray(StandardCharsets.UTF_8)) == file.sha256) null else GitHubFileChange(file.path, text)
    }

    private fun startEvents() {
        eventJob?.cancel()
        eventJob = viewModelScope.launch(Dispatchers.IO) {
            var after = events.maxOfOrNull { it.sequence } ?: 0L
            while (isActive) {
                try {
                    val connection = open("/v1/control/events?after=$after")
                    if (connection.responseCode != 200) throw IllegalStateException("Event stream refused")
                    connection.inputStream.bufferedReader().useLines { lines ->
                        var json = ""
                        lines.forEach { line ->
                            if (line.isBlank() && json.isNotBlank()) {
                                val event = parseEvent(json); after = maxOf(after, event.sequence)
                                synchronized(eventLock) { events = (events + event).takeLast(500) }; json = ""
                            } else if (line.startsWith("data: ")) json = line.removePrefix("data: ")
                        }
                    }
                } catch (_: Throwable) { delay(1000) }
            }
        }
    }

    private fun http(path: String, method: String = "GET", body: ByteArray? = null, auth: Boolean = true, base: String = endpoint, allowError: Boolean = false): HttpResponse {
        val connection = open(path, method, body, auth, base)
        val status = connection.responseCode
        val source = if (status in 200..299) connection.inputStream else connection.errorStream
        val bytes = source?.use { it.readBytes() } ?: ByteArray(0)
        if (!allowError && status !in 200..299) throw IllegalStateException(String(bytes))
        return HttpResponse(status, bytes)
    }
    private fun open(path: String, method: String = "GET", body: ByteArray? = null, auth: Boolean = true, base: String = endpoint): HttpURLConnection {
        val normalized = base.trimEnd('/')
        val parsed = runCatching { URI(normalized) }.getOrNull()
        check(parsed?.scheme?.lowercase() == "https" && !parsed.host.isNullOrBlank() && parsed.userInfo == null) { "HTTPS endpoint required" }
        val url = URL(normalized + path); val connection = url.openConnection() as HttpURLConnection; connection.requestMethod = method; connection.connectTimeout = 8000; connection.readTimeout = 30000; connection.doInput = true
        if (auth) connection.setRequestProperty("Authorization", "Bearer $token")
        if (body != null) { connection.doOutput = true; connection.setRequestProperty("Content-Type", "application/json"); connection.outputStream.use { it.write(body) } }
        return connection
    }

    private fun parseBootstrap(body: ByteArray) = JSONObject(String(body)).let { Bootstrap(it.getString("workspaceId"), it.getLong("revision"), it.optString("status"), it.optBoolean("isBusy"), it.optString("accessMode"), it.optString("provider").ifBlank { null }, it.optString("model").ifBlank { null }, it.optJSONArray("capabilities")?.strings() ?: emptyList()) }
    private fun parseSnapshot(body: ByteArray) = JSONObject(String(body)).let { root -> WorkspaceSnapshot(root.getString("workspaceId"), root.getLong("revision"), root.getJSONArray("files").objects { RemoteFile(it.getString("path"), it.getLong("bytes"), it.getString("sha256"), it.optInt("mode")) }, root.getJSONArray("excluded").objects { ExcludedFile(it.getString("path"), it.getString("reason")) }, root.optString("baseCommitSha").ifBlank { null }) }
    private fun parseEvent(body: String) = JSONObject(body).let { root -> val payload = root.optJSONObject("payload")?.keys()?.asSequence()?.associateWith { key -> root.getJSONObject("payload").opt(key)?.toString().orEmpty() } ?: emptyMap(); RemoteEvent(root.getString("id"), root.getLong("sequence"), root.getString("kind"), payload, root.optString("artifactId").ifBlank { null }) }
    private fun JSONArray.strings() = (0 until length()).map { getString(it) }
    private inline fun <T> JSONArray.objects(map: (JSONObject) -> T) = (0 until length()).map { map(getJSONObject(it)) }
    private fun cacheSnapshot(value: WorkspaceSnapshot) { metaFile("snapshot.json").apply { parentFile?.mkdirs(); writeText(JSONObject().put("workspaceId", value.workspaceId).put("revision", value.revision).put("baseCommitSha", value.baseCommitSha).put("files", JSONArray(value.files.map { JSONObject().put("path", it.path).put("bytes", it.bytes).put("sha256", it.sha256).put("mode", it.mode) })).put("excluded", JSONArray(value.excluded.map { JSONObject().put("path", it.path).put("reason", it.reason) })).toString()) } }
    private fun cacheFile(path: String, text: String) {
        val target = localTarget(path)
        target.parentFile?.mkdirs()
        val temporary = File(target.path + ".part-${UUID.randomUUID()}")
        temporary.writeText(text, StandardCharsets.UTF_8)
        check(temporary.renameTo(target)) { "The local workspace file could not be saved." }
    }

    /** The mirror root. Metadata lives in a sibling directory so the shell, the
     *  agent, and any GitHub push only ever see real user files. */
    fun workspaceRoot(): File = File(context.filesDir, "herness-workspace/files").apply { mkdirs() }.canonicalFile

    private fun metaFile(name: String) = File(context.filesDir, "herness-workspace/meta/$name").apply { parentFile?.mkdirs() }

    private fun localTarget(path: String): File {
        require(path.split('/').none { it == ".mem" || it.startsWith(".mem.") }) { "The .mem path is not available to mobile tools." }
        val root = workspaceRoot()
        val target = File(root, path).canonicalFile
        require(target.path.startsWith(root.path + File.separator)) { "Path is outside the local workspace." }
        return target
    }

    private fun pendingFile() = metaFile("pending.json")
    private fun pendingBase(path: String): String? = runCatching { JSONObject(pendingFile().readText()).optString(path).ifBlank { null } }.getOrNull()
    private fun recordPending(path: String, baseSha: String) {
        val file = pendingFile(); file.parentFile?.mkdirs(); val value = runCatching { JSONObject(file.readText()) }.getOrElse { JSONObject() }; value.put(path, baseSha); file.writeText(value.toString())
    }
    private fun clearPending(path: String) { val file = pendingFile(); if (!file.exists()) return; runCatching { val value = JSONObject(file.readText()); value.remove(path); file.writeText(value.toString()) } }
    private fun updateCachedFile(file: RemoteFile, text: String) {
        val current = snapshot ?: return
        snapshot = current.copy(files = current.files.map { if (it.path == file.path) it.copy(bytes = text.toByteArray(StandardCharsets.UTF_8).size.toLong(), sha256 = sha256(text.toByteArray(StandardCharsets.UTF_8))) else it })
        cacheSnapshot(snapshot!!)
    }
    private fun loadCachedSnapshot() { val file = metaFile("snapshot.json"); if (file.exists()) runCatching { snapshot = parseSnapshot(file.readBytes()) } }
    private fun cachedFile(path: String): String? = runCatching {
        localTarget(path).takeIf { it.exists() }?.readText()
    }.getOrNull()
    private fun sha256(bytes: ByteArray): String = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it.toInt() and 0xff) }
    private data class HttpResponse(val status: Int, val body: ByteArray)

    private companion object { const val MAXIMUM_CLONE_FILE_BYTES = 8L * 1_048_576 }
}

/** Keystore-backed secret store shared by the remote client, MCP, and the agent. */
class SecureStore(context: Context) {
    private val preferences = context.getSharedPreferences("secure", Context.MODE_PRIVATE)
    private val alias = "herness.mobile.aes"
    private fun key(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        if (!store.containsAlias(alias)) KeyGenerator.getInstance("AES", "AndroidKeyStore").apply { init(256); generateKey() }
        return (store.getEntry(alias, null) as KeyStore.SecretKeyEntry).secretKey
    }
    fun write(name: String, value: String) { val cipher = Cipher.getInstance("AES/GCM/NoPadding").apply { init(Cipher.ENCRYPT_MODE, key()) }; preferences.edit().putString(name, Base64.getEncoder().encodeToString(cipher.iv + cipher.doFinal(value.toByteArray()))).apply() }
    fun read(name: String): String? = runCatching { val bytes = Base64.getDecoder().decode(preferences.getString(name, null)); val cipher = Cipher.getInstance("AES/GCM/NoPadding"); cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, bytes.copyOfRange(0, 12))); String(cipher.doFinal(bytes.copyOfRange(12, bytes.size))) }.getOrNull()
    fun delete(name: String) { preferences.edit().remove(name).apply() }
}

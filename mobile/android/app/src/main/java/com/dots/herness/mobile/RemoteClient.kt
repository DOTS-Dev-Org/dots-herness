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
import java.io.BufferedReader
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URI
import java.net.URL
import java.net.URLEncoder
import java.nio.ByteBuffer
import java.nio.charset.StandardCharsets
import java.security.KeyStore
import java.security.MessageDigest
import java.security.SecureRandom
import java.security.cert.X509Certificate
import java.util.Base64
import java.util.UUID
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.net.ssl.HostnameVerifier
import javax.net.ssl.HttpsURLConnection
import javax.net.ssl.SSLContext
import javax.net.ssl.TrustManagerFactory
import javax.net.ssl.X509TrustManager
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

data class RemoteFile(val path: String, val bytes: Long, val sha256: String, val mode: Int)
data class ExcludedFile(val path: String, val reason: String)
data class WorkspaceSnapshot(val workspaceId: String, val revision: Long, val files: List<RemoteFile>, val excluded: List<ExcludedFile>, val baseCommitSha: String? = null)
data class RemoteEvent(val id: String, val sequence: Long, val kind: String, val payload: Map<String, String>, val artifactId: String?)
data class RemoteArtifact(val id: String, val kind: String, val bytes: Long)
data class RemoteProjectDescriptor(val id: String, val name: String, val workspaceId: String, val branch: String?)
data class Bootstrap(val workspaceId: String, val revision: Long, val status: String, val isBusy: Boolean, val accessMode: String, val provider: String?, val model: String?, val capabilities: List<String>, val projectId: String? = null, val endpoints: List<String> = emptyList())
data class CommandResult(val commandId: String, val status: String, val approvalId: String?, val result: String?, val error: String?)

/** HTTPS only, LAN included. The desktop's LAN certificate is self-signed and
 *  trusted by its pinned fingerprint (see [RemotePinning]); every exchange is
 *  sealed on top of that (see [RemoteSealed]). */
internal object RemoteEndpoint {
    fun isAllowed(uri: URI?): Boolean =
        uri != null && !uri.host.isNullOrBlank() && uri.userInfo == null && uri.scheme.equals("https", ignoreCase = true)

    /** SHA-256 of a DER certificate, lowercase hex, as the pairing QR carries it. */
    fun isFingerprint(value: String): Boolean = value.length == 64 && value.all { it in '0'..'9' || it in 'a'..'f' }
}

/** A server is trusted when its leaf certificate matches the paired desktop's
 *  fingerprint exactly, otherwise only through the normal CA check (the cloud
 *  tunnel) — a LAN impostor passes neither. */
internal object RemotePinning {
    fun sha256(der: ByteArray): String = MessageDigest.getInstance("SHA-256").digest(der).joinToString("") { "%02x".format(it) }

    fun apply(connection: HttpsURLConnection, pin: String) {
        if (pin.isEmpty()) return
        val system = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm())
            .apply { init(null as KeyStore?) }.trustManagers.filterIsInstance<X509TrustManager>().first()
        val pinned = object : X509TrustManager {
            override fun checkClientTrusted(chain: Array<X509Certificate>, authType: String) = system.checkClientTrusted(chain, authType)
            override fun checkServerTrusted(chain: Array<X509Certificate>, authType: String) {
                if (chain.isNotEmpty() && sha256(chain[0].encoded) == pin) return
                system.checkServerTrusted(chain, authType)
            }
            override fun getAcceptedIssuers(): Array<X509Certificate> = system.acceptedIssuers
        }
        connection.sslSocketFactory = SSLContext.getInstance("TLS").apply { init(null, arrayOf(pinned), null) }.socketFactory
        val standard = HttpsURLConnection.getDefaultHostnameVerifier()
        // The pinned certificate is the desktop itself, whatever name it was
        // reached under (mDNS, IP); anything else needs a matching hostname.
        connection.hostnameVerifier = HostnameVerifier { host, session ->
            runCatching { sha256(session.peerCertificates[0].encoded) == pin }.getOrDefault(false) || standard.verify(host, session)
        }
    }
}

/** Sealed channel v1, the only way to talk to the desktop, LAN and cloud tunnel
 *  alike: the tunnel ends TLS at Cloudflare, so the raw HTTP exchange is
 *  AES-256-GCM encrypted end to end. The format is specified on the desktop
 *  (`RemoteSealed` in macOS RemoteControl.swift and shared/RemoteControl.cs). */
internal object RemoteSealed {
    const val PATH = "/v3/sealed"
    const val PAIRING_DEVICE = "pair"

    fun key(secret: String) = SecretKeySpec(MessageDigest.getInstance("SHA-256").digest("herness.sealed.v1:$secret".toByteArray()), "AES")

    /** A pairing or device secret: 32 random bytes, base64url without padding. */
    fun isSecret(value: String) = value.length == 43 && value.all { it.isLetterOrDigit() || it == '-' || it == '_' }

    fun seal(key: SecretKeySpec, nonce: ByteArray, plain: ByteArray, aad: ByteArray): ByteArray {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding").apply { init(Cipher.ENCRYPT_MODE, key, GCMParameterSpec(128, nonce)); updateAAD(aad) }
        return nonce + cipher.doFinal(plain)
    }

    fun unseal(key: SecretKeySpec, sealed: ByteArray, aad: ByteArray): ByteArray {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding").apply { init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(128, sealed, 0, 12)); updateAAD(aad) }
        return cipher.doFinal(sealed, 12, sealed.size - 12)
    }

    fun frameAad(nonce: ByteArray, counter: Int) = nonce + ByteBuffer.allocate(4).putInt(counter).array()

    /** The request body: a fresh nonce, then the sealed timestamp and raw HTTP request. */
    fun request(key: SecretKeySpec, device: String, method: String, path: String, host: String, body: ByteArray?, now: Long = System.currentTimeMillis()): ByteArray {
        val head = "$method $path HTTP/1.1\r\nHost: $host\r\nContent-Length: ${body?.size ?: 0}\r\n" + (if (body != null) "Content-Type: application/json\r\n" else "") + "\r\n"
        val plain = ByteBuffer.allocate(8).putLong(now).array() + head.toByteArray() + (body ?: ByteArray(0))
        return seal(key, ByteArray(12).also { SecureRandom().nextBytes(it) }, plain, device.toByteArray())
    }
}

/** The decrypted reply: frames are opened as they are read, and a reply that
 *  stops before its end frame fails instead of passing for complete. */
internal class SealedInput(private val lines: BufferedReader, private val key: SecretKeySpec, private val nonce: ByteArray) : InputStream() {
    private var buffer = ByteArray(0)
    private var position = 0
    private var counter = 0
    private var ended = false

    override fun read(): Int = if (fill()) buffer[position++].toInt() and 0xff else -1

    override fun read(target: ByteArray, offset: Int, length: Int): Int {
        if (length == 0) return 0
        if (!fill()) return -1
        val count = minOf(length, buffer.size - position)
        System.arraycopy(buffer, position, target, offset, count)
        position += count
        return count
    }

    override fun close() = lines.close()

    private fun fill(): Boolean {
        while (position >= buffer.size) {
            if (ended) return false
            val line = lines.readLine() ?: throw IOException("The desktop reply was cut off.")
            buffer = RemoteSealed.unseal(key, Base64.getDecoder().decode(line), RemoteSealed.frameAad(nonce, counter++))
            position = 0
            ended = buffer.isEmpty()
        }
        return true
    }

    /** Reads the reply head and returns its status code; the body follows. */
    fun status(): Int {
        val head = StringBuilder()
        while (!head.endsWith("\r\n\r\n")) { val next = read(); if (next < 0) throw IOException("The desktop reply was cut off."); head.append(next.toChar()) }
        return head.split(' ', limit = 3).getOrNull(1)?.toIntOrNull() ?: throw IOException("The desktop reply is malformed.")
    }
}

/** A pairing request that arrived through a `herness://` link. Any web page can
 *  open that scheme, so the endpoint stays untrusted until the user confirms
 *  the host they are shown. */
data class PendingPairRequest(val endpoint: String, val code: String, val secret: String, val fingerprint: String? = null) {
    /** The host the device would talk to — what the user has to recognise. */
    val host: String
        get() = runCatching { URI(endpoint).host }.getOrNull()?.takeIf { it.isNotBlank() } ?: endpoint
}

/** [secret] seals the pairing exchange; [fingerprint] pins the desktop certificate
 *  and is required for its self-signed LAN address. Only the QR carries both. */
internal data class PairingPayload(val endpoint: String, val code: String, val secret: String, val fingerprint: String? = null) {
    companion object {
        fun fromFields(endpoint: String, code: String, secret: String, fingerprint: String? = null): PairingPayload? {
            val normalized = endpoint.trim().trimEnd('/')
            val parsed = runCatching { URI(normalized) }.getOrNull()
            val pin = fingerprint?.lowercase()
            if (!RemoteEndpoint.isAllowed(parsed) || code.length != 6 || !code.all { it in '0'..'9' } || !RemoteSealed.isSecret(secret)) return null
            if (pin != null && !RemoteEndpoint.isFingerprint(pin)) return null
            return PairingPayload(normalized, code, secret, pin)
        }

        fun fromQuery(names: Set<String>, value: (String) -> List<String>): PairingPayload? {
            if ((names != setOf("endpoint", "code", "k") && names != setOf("endpoint", "code", "k", "fp")) || names.any { value(it).size != 1 }) return null
            return fromFields(value("endpoint")[0], value("code")[0], value("k")[0], value("fp").firstOrNull())
        }

        fun fromUri(uri: Uri): PairingPayload? {
            if (!uri.scheme.equals("herness", ignoreCase = true) || !uri.host.equals("pair", ignoreCase = true)) return null
            return fromQuery(uri.queryParameterNames) { uri.getQueryParameters(it) }
        }
    }
}

class RemoteClient(private val context: Context) : ViewModel() {
    var endpoint by mutableStateOf(""); private set
    /** Other addresses of the paired desktop (LAN, tunnel), tried in turn when
     *  the current one stops answering, e.g. a restarted quick tunnel. */
    private var knownEndpoints: List<String> = emptyList()
    /** Paired desktop certificate fingerprint, see [RemotePinning]. */
    @Volatile private var pin = ""
    var token by mutableStateOf(""); private set
    /** The id the desktop knows this phone by; it names the sealing key. */
    private var deviceId = ""
    var bootstrap by mutableStateOf<Bootstrap?>(null); private set
    var snapshot by mutableStateOf<WorkspaceSnapshot?>(null); private set
    var events by mutableStateOf<List<RemoteEvent>>(emptyList()); private set
    /** Set when a `herness://pair` link arrives; the user has to confirm it. */
    var pendingPair by mutableStateOf<PendingPairRequest?>(null)
        private set
    var error by mutableStateOf<String?>(null); private set
    var connecting by mutableStateOf(false); private set
    var pairing by mutableStateOf(false); private set
    var isGuest by mutableStateOf(false); private set
    var cloneStatus by mutableStateOf(""); private set
    var repo by mutableStateOf(RepoCoordinates()); private set
    var projects by mutableStateOf<List<MobileProject>>(emptyList()); private set
    var selectedProjectLocationAvailable by mutableStateOf(false); private set
    var remoteProjects by mutableStateOf<List<RemoteProjectDescriptor>>(emptyList()); private set
    var remoteSelectedProjectId by mutableStateOf<String?>(null); private set
    private val secure = SecureStore(context)
    private val projectStore = MobileProjectStore(context)
    private val preferences = context.getSharedPreferences("herness.preferences", Context.MODE_PRIVATE)
    private val eventLock = Any()
    private var eventJob: Job? = null

    init {
        projects = projectStore.projects
        refreshProjectAvailability()
        endpoint = secure.read("endpoint") ?: ""
        knownEndpoints = secure.read("endpoints").orEmpty().split('\n').filter { it.isNotBlank() }
        token = secure.read("token") ?: ""
        deviceId = secure.read("device") ?: ""
        pin = secure.read("fingerprint").orEmpty()
        isGuest = preferences.getBoolean("guest_mode", false) || preferences.getBoolean("works_offline", false)
        loadCachedSnapshot()
        loadRepo()
        if (paired) connect()
    }

    /** A pairing from before the sealed channel has no device id: scan again. */
    val paired get() = endpoint.isNotBlank() && token.isNotBlank() && deviceId.isNotBlank()
    val workspaceId get() = remoteProjects.firstOrNull { it.id == remoteSelectedProjectId }?.workspaceId ?: bootstrap?.workspaceId ?: snapshot?.workspaceId ?: ""
    val selectedProjectId: String get() = projectStore.selectedProjectId
    val selectedProject: MobileProject get() = projectStore.selected
    val projectLocationAvailableNow: Boolean get() = File(selectedProject.localRoot).isDirectory
    val remoteProjectMatchesSelectedProject: Boolean
        get() = !remoteSelectedProjectId.isNullOrBlank() && projectStore.selected.remoteProjectId == remoteSelectedProjectId

    fun selectProject(id: String): Boolean {
        val changed = projectStore.select(id)
        if (!changed) return false
        projects = projectStore.projects
        refreshProjectAvailability()
        snapshot = null
        loadRepo()
        loadCachedSnapshot()
        if (paired && !projectStore.selected.remoteProjectId.isNullOrBlank()) {
            selectRemoteProject(projectStore.selected.remoteProjectId!!)
        } else if (paired) {
            clearRemoteProjectScope()
        }
        return true
    }

    fun addProject(name: String): MobileProject {
        val project = projectStore.add(name)
        projects = projectStore.projects
        refreshProjectAvailability()
        clearRemoteProjectScope()
        return project
    }

    fun renameProject(id: String, name: String) {
        projectStore.projects.firstOrNull { it.id == id }?.let {
            it.name = name.trim().ifBlank { it.name }
            projectStore.update(it)
            projects = projectStore.projects
        }
    }

    fun deleteProject(id: String) { projectStore.remove(id); projects = projectStore.projects; refreshProjectAvailability() }

    fun refreshProjectAvailability() {
        val available = projectLocationAvailableNow
        if (selectedProjectLocationAvailable != available) selectedProjectLocationAvailable = available
    }

    fun newRelocationDestination(): File = File(
        context.filesDir,
        "herness-projects/$selectedProjectId/files-relocated-${UUID.randomUUID()}",
    )

    fun relocateSelectedProject(destination: File): Boolean {
        if (!destination.isDirectory || !projectStore.updateLocalRoot(selectedProjectId, destination)) return false
        projects = projectStore.projects
        refreshProjectAvailability()
        return selectedProjectLocationAvailable
    }

    /** Keep a local/offline project from accidentally using the last desktop scope. */
    fun clearRemoteProjectScope() {
        eventJob?.cancel()
        remoteSelectedProjectId = null
        snapshot = null
        events = emptyList()
        bootstrap = bootstrap?.copy(projectId = null)
    }

    private fun pair(payload: PairingPayload, onDone: () -> Unit) {
        if (pairing) return
        viewModelScope.launch(Dispatchers.IO) {
            pairing = true
            val previousPin = pin
            pin = payload.fingerprint.orEmpty()
            try {
                val body = JSONObject().put("code", payload.code).put("deviceName", Build.MODEL).toString().toByteArray()
                val response = http("/v1/control/pair/complete", "POST", body, base = payload.endpoint, secret = payload.secret, device = RemoteSealed.PAIRING_DEVICE)
                val result = JSONObject(String(response.body))
                endpoint = payload.endpoint; token = result.getString("token"); deviceId = result.getString("deviceId"); isGuest = false
                preferences.edit().putBoolean("guest_mode", false).putBoolean("works_offline", false).apply()
                secure.write("token", token)
                secure.write("device", deviceId)
                if (payload.fingerprint != null) secure.write("fingerprint", payload.fingerprint) else secure.delete("fingerprint")
                knownEndpoints = emptyList(); useEndpoint(payload.endpoint)
                connect(); onDone()
            } catch (t: Throwable) { pin = previousPin; error = t.message ?: "Pairing failed" }
            finally { pairing = false }
        }
    }

    fun consumePairUri(uri: Uri) {
        val payload = PairingPayload.fromUri(uri)
        if (payload == null) { error = "This QR code is not a valid HerNess pairing code."; return }
        // A herness:// link can be opened by any web page, so never pair
        // straight from it: hold the request until the user confirms the host.
        pendingPair = PendingPairRequest(payload.endpoint, payload.code, payload.secret, payload.fingerprint)
    }

    /** Pairs with the host the user just confirmed. */
    fun confirmPendingPair(onDone: () -> Unit = {}) {
        val pending = pendingPair ?: return
        pendingPair = null
        val payload = PairingPayload.fromFields(pending.endpoint, pending.code, pending.secret, pending.fingerprint)
        if (payload == null) { error = "This pairing request is not valid."; return }
        pair(payload, onDone)
    }

    fun cancelPendingPair() {
        pendingPair = null
    }

    fun connect() {
        viewModelScope.launch(Dispatchers.IO) {
            connecting = true
            try {
                bootstrap = reachDesktop()
                runCatching { loadRemoteProjectsBlocking() }
                runCatching { loadTranscriptBlocking() }
                error = null
                if (remoteProjectMatchesSelectedProject) startEvents() else clearRemoteProjectScope()
            }
            catch (t: Throwable) { error = t.message ?: "Connection failed" }
            connecting = false
        }
    }

    /** Seeds the feed with the desktop conversation so far; the event stream
     *  only carries what happens after the phone connects. Sequence 0 marks
     *  these rows so a reconnect replaces rather than duplicates them. */
    private fun loadTranscriptBlocking() {
        if (bootstrap?.capabilities?.contains("transcript") != true) return
        val messages = JSONObject(String(http(controlPath("/v1/control/transcript")).body)).getJSONArray("messages")
        val history = (0 until messages.length()).map { index ->
            val item = messages.getJSONObject(index)
            RemoteEvent("transcript-${item.getString("id")}", 0L, "${item.getString("kind")}.message", mapOf("text" to item.optString("text")), null)
        }
        synchronized(eventLock) { events = history + events.filter { it.sequence != 0L } }
    }

    /** Bootstraps against the current endpoint, then every other known one,
     *  and keeps whichever answers. */
    private fun reachDesktop(): Bootstrap {
        var last: Throwable = IllegalStateException("No desktop endpoint")
        for (candidate in (listOf(endpoint) + knownEndpoints).filter { it.isNotBlank() }.distinct()) {
            try {
                val value = parseBootstrap(http("/v1/control/bootstrap", base = candidate).body)
                useEndpoint(candidate, value.endpoints)
                return value
            } catch (t: Throwable) { last = t }
        }
        throw last
    }

    private fun useEndpoint(value: String, learned: List<String> = emptyList()) {
        if (endpoint != value) { endpoint = value; secure.write("endpoint", value) }
        knownEndpoints = (knownEndpoints + learned + value).distinct().takeLast(6)
        secure.write("endpoints", knownEndpoints.joinToString("\n"))
    }

    suspend fun readFile(path: String): String = withContext(Dispatchers.IO) {
        try { String(http(controlPath("/v1/control/file?path=${URLEncoder.encode(path, "UTF-8")}")).body, StandardCharsets.UTF_8) }
        catch (t: Throwable) { cachedFile(path) ?: throw t }
    }

    suspend fun artifactText(id: String): String = withContext(Dispatchers.IO) {
        String(http(controlPath("/v1/control/artifact?id=${URLEncoder.encode(id, "UTF-8")}")).body, StandardCharsets.UTF_8)
    }

    suspend fun artifacts(): List<RemoteArtifact> = withContext(Dispatchers.IO) {
        val array = JSONArray(String(http(controlPath("/v1/control/artifacts")).body))
        (0 until array.length()).map { index ->
            val item = array.getJSONObject(index)
            RemoteArtifact(item.getString("id"), item.optString("kind", "artifact"), item.optLong("bytes"))
        }
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
        projectStore.projects.firstOrNull { it.id == selectedProjectId }?.let { project ->
            project.sourceKind = "github"
            project.repository = value.slug
            project.branch = value.branch
            projectStore.update(project)
            projects = projectStore.projects
        }
        metaFile("repo.json").apply {
            parentFile?.mkdirs()
            writeText(JSONObject().put("owner", value.owner).put("repository", value.repository).put("branch", value.branch).toString())
        }
    }

    private fun loadRepo() {
        val file = metaFile("repo.json")
        if (file.exists()) {
            runCatching { JSONObject(file.readText()) }.getOrNull()?.let {
                repo = RepoCoordinates(it.optString("owner"), it.optString("repository"), it.optString("branch", "main"))
            }
            return
        }
        projectStore.selected.repository?.let { slug ->
            RepoCoordinates.parse(slug, projectStore.selected.branch ?: "main")?.let { repo = it }
        }
    }

    fun savePhoneSecret(name: String, value: String) {
        if (value.isBlank()) secure.delete("phone.$name") else secure.write("phone.$name", value)
    }

    fun phoneSecret(name: String): String = secure.read("phone.$name").orEmpty()

    fun migrateLegacyProviderKey(provider: String) {
        secure.migrateLegacyProviderKey(provider)
    }

    suspend fun command(kind: String, payload: Map<String, Any?>, expectedRevision: Long? = null): CommandResult = withContext(Dispatchers.IO) {
        val payloadJson = JSONObject(); payload.forEach { (key, value) -> payloadJson.put(key, value) }
        val json = JSONObject().put("id", UUID.randomUUID().toString()).put("workspaceId", workspaceId).put("projectID", remoteSelectedProjectId ?: selectedProjectId).put("kind", kind).put("expectedRevision", expectedRevision).put("payload", payloadJson).toString().toByteArray()
        val response = http(controlPath("/v1/control/commands"), "POST", json, allowError = true)
        val value = JSONObject(String(response.body))
        if (response.status !in 200..299 && value.optString("status") != "conflict") throw IllegalStateException(value.optString("error", "Remote command failed"))
        CommandResult(value.optString("commandId"), value.optString("status"), value.optString("approvalId").ifBlank { null }, value.opt("result")?.toString(), value.optString("error").ifBlank { null })
    }

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
                    val reply = exchange(controlPath("/v1/control/events?after=$after"))
                    if (reply.status() != 200) { reply.close(); throw IllegalStateException("Event stream refused") }
                    reply.bufferedReader().useLines { lines ->
                        var json = ""
                        lines.forEach { line ->
                            if (line.isBlank() && json.isNotBlank()) {
                                val event = parseEvent(json); after = maxOf(after, event.sequence)
                                if (event.kind == "tunnel.ready") event.payload["endpoint"]?.let { useEndpoint(endpoint, listOf(it)) }
                                synchronized(eventLock) { events = (events + event).takeLast(500) }; json = ""
                            } else if (line.startsWith("data: ")) json = line.removePrefix("data: ")
                        }
                    }
                } catch (_: Throwable) {
                    delay(1000)
                    // The address may be gone (new tunnel URL, left the Wi-Fi):
                    // switch to whichever known endpoint answers before retrying.
                    if (isActive) runCatching { reachDesktop() }.onSuccess { bootstrap = it }
                }
            }
        }
    }

    private fun http(path: String, method: String = "GET", body: ByteArray? = null, base: String = endpoint, allowError: Boolean = false, secret: String = token, device: String = deviceId): HttpResponse {
        val reply = exchange(path, method, body, base, secret, device)
        val status = reply.status()
        val bytes = reply.use { it.readBytes() }
        if (!allowError && status !in 200..299) throw IllegalStateException(String(bytes))
        return HttpResponse(status, bytes)
    }

    /** Sends one sealed request (see [RemoteSealed]) and returns the reply to
     *  read. Redirects are refused outright: nothing but the paired desktop
     *  can answer a sealed request anyway. */
    private fun exchange(path: String, method: String = "GET", body: ByteArray? = null, base: String = endpoint, secret: String = token, device: String = deviceId): SealedInput {
        val normalized = base.trimEnd('/')
        val parsed = runCatching { URI(normalized) }.getOrNull()
        check(RemoteEndpoint.isAllowed(parsed)) { "HTTPS endpoint required" }
        val key = RemoteSealed.key(secret)
        val sealed = RemoteSealed.request(key, device, method, path, parsed!!.authority, body)
        val connection = URL(normalized + RemoteSealed.PATH).openConnection() as HttpURLConnection
        (connection as? HttpsURLConnection)?.let { RemotePinning.apply(it, pin) }
        connection.requestMethod = "POST"; connection.connectTimeout = 8000; connection.readTimeout = if (path.contains("/commands")) COMMAND_READ_TIMEOUT_MS else 30000
        connection.instanceFollowRedirects = false
        connection.setRequestProperty("X-Herness-Device", device)
        connection.setRequestProperty("Content-Type", "application/octet-stream")
        connection.doOutput = true
        connection.outputStream.use { it.write(sealed) }
        if (connection.responseCode != 200) {
            val message = connection.errorStream?.use { String(it.readBytes()) }
            connection.disconnect()
            throw IllegalStateException(runCatching { JSONObject(message!!).getString("error") }.getOrNull() ?: "The desktop refused the request.")
        }
        return SealedInput(connection.inputStream.bufferedReader(Charsets.US_ASCII), key, sealed.copyOfRange(0, 12))
    }

    fun selectRemoteProject(id: String) {
        if (!paired) return
        viewModelScope.launch(Dispatchers.IO) {
            try {
                val body = JSONObject().put("projectID", id).toString().toByteArray()
                val value = JSONObject(String(http("/v2/control/projects/select", "POST", body).body))
                remoteSelectedProjectId = value.optString("projectID").ifBlank { id }
                bootstrap = bootstrap?.copy(workspaceId = value.optString("workspaceId", bootstrap?.workspaceId.orEmpty()), projectId = remoteSelectedProjectId)
                snapshot = null
                remoteProjects.firstOrNull { it.id == remoteSelectedProjectId }?.let { descriptor ->
                    projectStore.bindRemoteProject(descriptor)
                    projects = projectStore.projects
                    loadRepo()
                    loadCachedSnapshot()
                }
                // The stream is workspace-scoped; reconnect after selection so
                // old-project events are not shown under the new project.
                eventJob?.cancel()
                events = emptyList()
                startEvents()
            } catch (t: Throwable) { error = t.message ?: "Project selection failed" }
        }
    }

    private fun loadRemoteProjectsBlocking() {
        if (!paired) return
        val value = JSONObject(String(http("/v2/control/projects").body))
        val array = value.optJSONArray("projects") ?: JSONArray()
                remoteProjects = (0 until array.length()).map { index ->
            val item = array.getJSONObject(index)
            RemoteProjectDescriptor(item.getString("id"), item.optString("name", "Project"), item.getString("workspaceId"), item.optString("branch").ifBlank { null })
        }
        val serverProjectId = value.optString("projectID").ifBlank { null }
        remoteSelectedProjectId = serverProjectId?.takeIf { it == projectStore.selected.remoteProjectId }
        if (remoteSelectedProjectId != null) loadCachedSnapshot()
    }

    private fun controlPath(v1Path: String): String = if (remoteSelectedProjectId.isNullOrBlank()) v1Path else v1Path.replaceFirst("/v1/", "/v2/")

    private fun parseBootstrap(body: ByteArray) = JSONObject(String(body)).let { Bootstrap(it.getString("workspaceId"), it.getLong("revision"), it.optString("status"), it.optBoolean("isBusy"), it.optString("accessMode"), it.optString("provider").ifBlank { null }, it.optString("model").ifBlank { null }, it.optJSONArray("capabilities")?.strings() ?: emptyList(), it.optString("projectID").ifBlank { null }, it.optJSONArray("endpoints")?.strings() ?: emptyList()) }
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
    fun workspaceRoot(): File = File(selectedProject.localRoot).canonicalFile

    private fun metaFile(name: String) = File(context.filesDir, "herness-projects/${selectedProjectId}/meta/$name").apply { parentFile?.mkdirs() }

    private fun localTarget(path: String): File {
        check(projectLocationAvailableNow) { "The local project folder is unavailable." }
        require(path.split('/').none { it == ".mem" || it.startsWith(".mem.") }) { "The .mem path is not available to mobile tools." }
        val root = workspaceRoot()
        val target = File(root, path).canonicalFile
        require(target.path.startsWith(root.path + File.separator)) { "Path is outside the local workspace." }
        return target
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

    /** Migrate the pre-account mobile key to the provider selected on upgrade. */
    fun migrateLegacyProviderKey(provider: String) {
        val legacyKey = "phone.provider"
        val value = read(legacyKey).orEmpty()
        if (value.isBlank()) return
        val scopedKey = MobileHarnessRuntime.credentialKey(provider)
        if (read(scopedKey).orEmpty().isBlank()) write(scopedKey, value)
        delete(legacyKey)
    }
}

/** Forwarded run_command and wait_command can each block for 600 seconds; allow 30 seconds for the reply. */
private const val COMMAND_READ_TIMEOUT_MS = 630_000

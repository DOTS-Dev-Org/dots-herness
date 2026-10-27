package com.dots.herness.mobile

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder
import java.security.MessageDigest
import java.util.Base64

data class ChatGPTAccountProfile(val id: String, val email: String) {
    val title: String get() = email.ifBlank { "ChatGPT · …${id.takeLast(6)}" }
}

/// Existing desktop GPT OAuth contract, adapted to a mobile PKCE callback.
class ChatGPTOAuth(context: Context) {
    private val appContext = context.applicationContext
    private val secure = SecureStore(appContext)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

    var accessToken by mutableStateOf(""); private set
    var accountId by mutableStateOf(""); private set
    var accounts by mutableStateOf<List<ChatGPTAccountProfile>>(emptyList()); private set
    var status by mutableStateOf(""); private set
    var signingIn by mutableStateOf(false); private set

    init {
        migrateLegacyAccount()
        reloadAccounts()
    }

    fun start(activity: Activity?) {
        val verifier = randomToken()
        val state = randomToken()
        secure.write("oauth.openai.verifier", verifier)
        secure.write("oauth.openai.state", state)
        val uri = Uri.parse("https://auth.openai.com/oauth/authorize").buildUpon()
            .appendQueryParameter("response_type", "code")
            .appendQueryParameter("client_id", CLIENT_ID)
            .appendQueryParameter("redirect_uri", CALLBACK)
            .appendQueryParameter("scope", "openid profile email offline_access")
            .appendQueryParameter("prompt", "select_account")
            .appendQueryParameter("code_challenge", challenge(verifier))
            .appendQueryParameter("code_challenge_method", "S256")
            .appendQueryParameter("state", state)
            .appendQueryParameter("id_token_add_organizations", "true")
            .appendQueryParameter("codex_cli_simplified_flow", "true")
            .appendQueryParameter("originator", "dots_harness")
            .build()
        signingIn = true
        status = "Waiting for ChatGPT authorization…"
        val intent = Intent(Intent.ACTION_VIEW, uri)
        activity?.startActivity(intent) ?: run {
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            appContext.startActivity(intent)
        }
    }

    fun handleCallback(uri: Uri): Boolean {
        if (!uri.scheme.equals("herness", true) || !uri.host.equals("oauth", true) || uri.path != "/openai") return false
        uri.getQueryParameter("error")?.let {
            status = uri.getQueryParameter("error_description") ?: it
            signingIn = false
            return true
        }
        val expected = secure.read("oauth.openai.state")
        if (expected.isNullOrBlank() || uri.getQueryParameter("state") != expected) {
            status = "ChatGPT OAuth state mismatch. Start sign-in again."
            signingIn = false
            return true
        }
        val code = uri.getQueryParameter("code").orEmpty()
        val verifier = secure.read("oauth.openai.verifier").orEmpty()
        if (code.isBlank() || verifier.isBlank()) {
            status = "ChatGPT did not return an authorization code."
            signingIn = false
            return true
        }
        secure.delete("oauth.openai.state")
        secure.delete("oauth.openai.verifier")
        signingIn = true
        scope.launch { requestToken(listOf("grant_type" to "authorization_code", "code" to code, "redirect_uri" to CALLBACK, "client_id" to CLIENT_ID, "code_verifier" to verifier)) }
        return true
    }

    suspend fun refreshIfNeeded() {
        for (profile in accounts.toList()) {
            val token = accessTokenFor(profile.id)
            val expiry = jwtClaims(token).optLong("exp", 0)
            if (token.isNotBlank() && (expiry == 0L || expiry > System.currentTimeMillis() / 1000 + 60)) continue
            val refresh = secure.read(profileKey("refresh", profile.id)).orEmpty()
            if (refresh.isNotBlank()) requestToken(listOf("grant_type" to "refresh_token", "refresh_token" to refresh, "client_id" to CLIENT_ID), profile.id)
        }
        reloadAccounts()
        refreshQuota()
    }

    fun signOut() = removeAccount(accountId)

    fun selectAccount(id: String) {
        if (accounts.none { it.id == id }) return
        secure.write("oauth.openai.active_account", id)
        reloadAccounts()
        persistActiveOAuthReference()
    }

    fun removeAccount(id: String) {
        if (id.isBlank()) return
        secure.delete(profileKey("access", id))
        secure.delete(profileKey("refresh", id))
        accounts = accounts.filterNot { it.id == id }
        saveAccounts()
        if (secure.read("oauth.openai.active_account") == id) secure.write("oauth.openai.active_account", accounts.firstOrNull()?.id.orEmpty())
        reloadAccounts()
        persistActiveOAuthReference()
        status = if (accounts.isEmpty()) "Signed out of ChatGPT on this device." else "ChatGPT account removed."
    }

    fun accountIDs(): List<String> = accounts.map { it.id }

    private val quota = java.util.concurrent.ConcurrentHashMap<String, Double>()
    private val quotaCheckedAt = java.util.concurrent.ConcurrentHashMap<String, Long>()

    /** Account for a conversation that has none yet: the one with the most
     *  `/wham/usage` quota left (desktop ChatGPTUsageService contract). A started
     *  conversation keeps its pinned account. Reads a minute-old figure at most;
     *  the refresh it starts serves the next conversation. */
    fun roomiestAccountId(): String {
        val ids = accountIDs()
        scope.launch { refreshQuota(ids) }
        return ChatGPTQuota.pick(ids, accountId, quota)
    }

    suspend fun refreshQuota(ids: List<String> = accountIDs()) {
        val now = System.currentTimeMillis()
        // Marked now so overlapping callers do not fetch the same account twice.
        val stale = ids.filter { id -> (quotaCheckedAt[id] ?: 0L) <= now - 60_000 }.onEach { quotaCheckedAt[it] = now }
        for (id in stale) {
            val token = accessTokenFor(id)
            val left = withContext(Dispatchers.IO) { ChatGPTQuota.read(id, token) }
            if (left == null) quota.remove(id) else quota[id] = left
        }
    }
    fun accessTokenFor(id: String): String {
        val scoped = secure.read(profileKey("access", id))
        val legacy = if (secure.read("oauth.openai.account") == id) secure.read("oauth.openai.access") else null
        return scoped ?: legacy ?: ""
    }

    private suspend fun requestToken(fields: List<Pair<String, String>>, existingAccountId: String? = null) {
        try {
            val result = withContext(Dispatchers.IO) {
                val connection = (URL("https://auth.openai.com/oauth/token").openConnection() as HttpURLConnection).apply {
                    requestMethod = "POST"
                    connectTimeout = 30_000
                    readTimeout = 30_000
                    doOutput = true
                    setRequestProperty("Content-Type", "application/x-www-form-urlencoded")
                    outputStream.use { it.write(fields.joinToString("&") { (key, value) -> URLEncoder.encode(key, "UTF-8") + "=" + URLEncoder.encode(value, "UTF-8") }.toByteArray()) }
                }
                val statusCode = connection.responseCode
                val bytes = (if (statusCode in 200..299) connection.inputStream else connection.errorStream)?.use { it.readBytes() } ?: ByteArray(0)
                statusCode to JSONObject(String(bytes))
            }
            val token = result.second.optString("access_token")
            if (result.first !in 200..299 || token.isBlank()) {
                status = result.second.optString("error_description").ifBlank { "ChatGPT token exchange failed." }
                return
            }
            val identityToken = result.second.optString("id_token").ifBlank { token }
            val claims = jwtClaims(identityToken)
            val resolvedID = claims.optJSONObject("https://api.openai.com/auth")?.optString("chatgpt_account_id").orEmpty()
                .ifBlank { claims.optString("chatgpt_account_id") }
                .ifBlank { result.second.optString("account_id") }
                .ifBlank { existingAccountId.orEmpty() }
            if (resolvedID.isBlank()) {
                status = "ChatGPT did not return an account identity. The existing account was kept."
                return
            }
            if (existingAccountId != null) {
                if (accounts.none { it.id == existingAccountId }) return
                if (resolvedID != existingAccountId) {
                    status = "The ChatGPT account identity changed during token refresh. The existing profile was kept."
                    return
                }
            }
            secure.write(profileKey("access", resolvedID), token)
            result.second.optString("refresh_token").takeIf(String::isNotBlank)?.let { secure.write(profileKey("refresh", resolvedID), it) }
            val email = claims.optString("email")
            val next = accounts.toMutableList()
            val index = next.indexOfFirst { it.id == resolvedID }
            val profile = ChatGPTAccountProfile(resolvedID, email.ifBlank { next.getOrNull(index)?.email.orEmpty() })
            if (index >= 0) next[index] = profile else next.add(profile)
            accounts = next
            saveAccounts()
            if (existingAccountId == null) secure.write("oauth.openai.active_account", resolvedID)
            reloadAccounts()
            if (existingAccountId == null || secure.read("oauth.openai.active_account") == resolvedID) persistActiveOAuthReference()
            status = "Signed in to ChatGPT."
        } catch (t: Throwable) {
            status = t.message ?: "ChatGPT token exchange failed."
        } finally {
            signingIn = false
        }
    }

    private fun migrateLegacyAccount() {
        val id = secure.read("oauth.openai.account").orEmpty()
        val token = secure.read("oauth.openai.access").orEmpty()
        if (id.isBlank() || token.isBlank()) return
        val accessKey = profileKey("access", id)
        if (secure.read(accessKey).isNullOrBlank()) secure.write(accessKey, token)
        secure.read("oauth.openai.refresh")?.let { refresh ->
            val refreshKey = profileKey("refresh", id)
            if (secure.read(refreshKey).isNullOrBlank()) secure.write(refreshKey, refresh)
        }
        val rows = readAccounts().toMutableList()
        if (rows.none { it.id == id }) rows.add(ChatGPTAccountProfile(id, ""))
        accounts = rows
        saveAccounts()
        secure.write("oauth.openai.active_account", id)
        secure.delete("oauth.openai.access")
        secure.delete("oauth.openai.refresh")
        secure.delete("oauth.openai.account")
    }

    private fun readAccounts(): List<ChatGPTAccountProfile> {
        val raw = secure.read("oauth.openai.accounts") ?: return emptyList()
        return runCatching {
            val array = org.json.JSONArray(raw)
            (0 until array.length()).mapNotNull { index ->
                val row = array.optJSONObject(index) ?: return@mapNotNull null
                row.optString("id").takeIf(String::isNotBlank)?.let { ChatGPTAccountProfile(it, row.optString("email")) }
            }
        }.getOrDefault(emptyList())
    }

    private fun saveAccounts() {
        val array = org.json.JSONArray()
        accounts.forEach { array.put(JSONObject().put("id", it.id).put("email", it.email)) }
        secure.write("oauth.openai.accounts", array.toString())
    }

    private fun reloadAccounts() {
        accounts = readAccounts()
        val active = secure.read("oauth.openai.active_account").orEmpty()
        val selected = accounts.firstOrNull { it.id == active }?.id ?: accounts.firstOrNull()?.id.orEmpty()
        accountId = selected
        accessToken = accessTokenFor(selected)
        if (selected.isNotBlank() && selected != active) secure.write("oauth.openai.active_account", selected)
    }

    private fun persistActiveOAuthReference() {
        val reference = accountId.takeIf(String::isNotBlank)?.let { "keystore:${profileKey("access", it)}" }
            ?: "keystore:oauth.openai.accounts"
        MobileStateStore(appContext).saveOAuth("gpt", reference)
    }

    private fun profileKey(kind: String, id: String): String {
        val digest = MessageDigest.getInstance("SHA-256").digest(id.toByteArray())
            .joinToString("") { "%02x".format(it) }
        return "oauth.openai.profile.$digest.$kind"
    }

    private fun randomToken(): String = Base64.getUrlEncoder().withoutPadding().encodeToString(ByteArray(32).also { java.security.SecureRandom().nextBytes(it) })
    private fun challenge(value: String): String = Base64.getUrlEncoder().withoutPadding().encodeToString(MessageDigest.getInstance("SHA-256").digest(value.toByteArray()))
    private fun jwtClaims(token: String): JSONObject {
        val segment = token.split(".").getOrNull(1) ?: return JSONObject()
        return runCatching { JSONObject(String(Base64.getUrlDecoder().decode(segment))) }.getOrElse { JSONObject() }
    }

    companion object {
        private const val CLIENT_ID = "app_EMoamEEZ73f0CkXaXp7hrann"
        private const val CALLBACK = "herness://oauth/openai"
    }
}

object ChatGPTQuota {
    /** Most quota left first; unknown sits between healthy and spent; the
     *  account picked in Settings breaks ties. */
    fun pick(ids: List<String>, active: String, remaining: Map<String, Double>): String {
        fun rank(id: String): Double = remaining[id]?.let { if (it <= 0) -1.0 else it } ?: 0.0
        return ids.maxWithOrNull(compareBy<String>({ rank(it) }, { it == active })) ?: active
    }

    /** The tighter of the 5-hour and weekly windows. */
    fun remaining(json: String): Double? = runCatching {
        val limit = JSONObject(json).optJSONObject("rate_limit") ?: return null
        val used = listOf("primary_window", "secondary_window").mapNotNull { name ->
            limit.optJSONObject(name)?.opt("used_percent")?.toString()?.toDoubleOrNull()
        }
        used.maxOrNull()?.let { maxOf(0.0, 1 - minOf(it, 100.0) / 100) }
    }.getOrNull()

    fun read(id: String, token: String): Double? {
        if (token.isBlank()) return null
        return runCatching {
            val connection = URL("https://chatgpt.com/backend-api/wham/usage").openConnection() as HttpURLConnection
            connection.connectTimeout = 20_000
            connection.readTimeout = 20_000
            connection.setRequestProperty("Authorization", "Bearer $token")
            connection.setRequestProperty("ChatGPT-Account-Id", id)
            connection.setRequestProperty("originator", "codex_cli_rs")
            connection.setRequestProperty("Accept", "application/json")
            try {
                if (connection.responseCode !in 200..299) null
                else remaining(connection.inputStream.bufferedReader().use { it.readText() })
            } finally { connection.disconnect() }
        }.getOrNull()
    }
}


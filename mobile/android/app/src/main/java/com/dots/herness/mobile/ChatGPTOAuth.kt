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

/// Existing desktop GPT OAuth contract, adapted to a mobile PKCE callback.
class ChatGPTOAuth(context: Context) {
    private val appContext = context.applicationContext
    private val secure = SecureStore(appContext)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

    var accessToken by mutableStateOf(secure.read("oauth.openai.access").orEmpty()); private set
    var accountId by mutableStateOf(secure.read("oauth.openai.account").orEmpty()); private set
    var status by mutableStateOf(""); private set
    var signingIn by mutableStateOf(false); private set

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
        val claims = jwtClaims(accessToken)
        val expiry = claims.optLong("exp", 0)
        if (accessToken.isNotBlank() && (expiry == 0L || expiry > System.currentTimeMillis() / 1000 + 60)) return
        val refresh = secure.read("oauth.openai.refresh").orEmpty()
        if (refresh.isNotBlank()) requestToken(listOf("grant_type" to "refresh_token", "refresh_token" to refresh, "client_id" to CLIENT_ID))
    }

    fun signOut() {
        secure.delete("oauth.openai.access")
        secure.delete("oauth.openai.refresh")
        secure.delete("oauth.openai.account")
        accessToken = ""; accountId = ""; status = "Signed out of ChatGPT on this device."
    }

    private suspend fun requestToken(fields: List<Pair<String, String>>) {
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
            accessToken = token
            result.second.optString("refresh_token").takeIf(String::isNotBlank)?.let { secure.write("oauth.openai.refresh", it) }
            val claims = jwtClaims(result.second.optString("id_token").ifBlank { token })
            accountId = claims.optJSONObject("https://api.openai.com/auth")?.optString("chatgpt_account_id").orEmpty()
                .ifBlank { claims.optString("chatgpt_account_id") }
                .ifBlank { result.second.optString("account_id") }
                .ifBlank { accountId }
            secure.write("oauth.openai.access", token)
            if (accountId.isNotBlank()) secure.write("oauth.openai.account", accountId)
            MobileStateStore(appContext).saveOAuth("gpt", "keystore:oauth.openai.access")
            status = "Signed in to ChatGPT."
        } catch (t: Throwable) {
            status = t.message ?: "ChatGPT token exchange failed."
        } finally {
            signingIn = false
        }
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

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

/// Public-client GitHub OAuth. No client secret is accepted or shipped in the
/// app; verifier/state are temporary encrypted entries and the token is kept in
/// the same Keystore-backed store used by provider credentials.
class GitHubOAuth(context: Context) {
    private val appContext = context.applicationContext
    private val secure = SecureStore(appContext)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val clientId = runCatching {
        appContext.packageManager
            .getApplicationInfo(appContext.packageName, android.content.pm.PackageManager.GET_META_DATA)
            .metaData?.getString("herness.github.client_id")
    }.getOrNull().orEmpty()

    var accessToken by mutableStateOf(secure.read("oauth.github.access").orEmpty()); private set
    var status by mutableStateOf(""); private set
    var signingIn by mutableStateOf(false); private set

    fun start(activity: Activity?) {
        if (clientId.isBlank()) {
            status = "Configure HERNESS_GITHUB_CLIENT_ID before signing in with GitHub."
            return
        }
        val verifier = randomToken()
        val state = randomToken()
        secure.write("oauth.github.verifier", verifier)
        secure.write("oauth.github.state", state)
        val uri = Uri.parse("https://github.com/login/oauth/authorize").buildUpon()
            .appendQueryParameter("client_id", clientId)
            .appendQueryParameter("redirect_uri", CALLBACK)
            .appendQueryParameter("scope", "read:user repo")
            .appendQueryParameter("state", state)
            .appendQueryParameter("code_challenge", challenge(verifier))
            .appendQueryParameter("code_challenge_method", "S256")
            .build()
        signingIn = true
        status = "Waiting for GitHub authorization…"
        val intent = Intent(Intent.ACTION_VIEW, uri)
        activity?.startActivity(intent) ?: run {
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            appContext.startActivity(intent)
        }
    }

    /// Handles cold-start and onNewIntent deep links. Returns true only for the
    /// GitHub callback route so the legacy pairing callback can coexist.
    fun handleCallback(uri: Uri): Boolean {
        if (!uri.scheme.equals("herness", true) || !uri.host.equals("oauth", true) || uri.path != "/github") return false
        signingIn = false
        uri.getQueryParameter("error")?.let {
            status = uri.getQueryParameter("error_description") ?: it
            return true
        }
        val expectedState = secure.read("oauth.github.state")
        if (expectedState.isNullOrBlank() || uri.getQueryParameter("state") != expectedState) {
            status = "GitHub OAuth state mismatch. Start sign-in again."
            return true
        }
        val code = uri.getQueryParameter("code").orEmpty()
        val verifier = secure.read("oauth.github.verifier").orEmpty()
        if (code.isBlank() || verifier.isBlank()) {
            status = "GitHub did not return an authorization code."
            return true
        }
        secure.delete("oauth.github.state")
        secure.delete("oauth.github.verifier")
        signingIn = true
        scope.launch { exchange(code, verifier) }
        return true
    }

    fun signOut() {
        secure.delete("oauth.github.access")
        accessToken = ""
        status = "Signed out of GitHub on this device."
    }

    private suspend fun exchange(code: String, verifier: String) {
        try {
            val body = form(
                "client_id" to clientId,
                "code" to code,
                "redirect_uri" to CALLBACK,
                "code_verifier" to verifier,
            )
            val result = withContext(Dispatchers.IO) {
                val connection = (URL("https://github.com/login/oauth/access_token").openConnection() as HttpURLConnection).apply {
                    requestMethod = "POST"
                    connectTimeout = 30_000
                    readTimeout = 30_000
                    doOutput = true
                    setRequestProperty("Accept", "application/json")
                    setRequestProperty("Content-Type", "application/x-www-form-urlencoded")
                    outputStream.use { it.write(body.toByteArray()) }
                }
                val statusCode = connection.responseCode
                val bytes = (if (statusCode in 200..299) connection.inputStream else connection.errorStream)?.use { it.readBytes() } ?: ByteArray(0)
                statusCode to JSONObject(String(bytes))
            }
            val token = result.second.optString("access_token")
            if (result.first !in 200..299 || token.isBlank()) {
                status = result.second.optString("error_description").ifBlank { "GitHub token exchange failed." }
                return
            }
            secure.write("oauth.github.access", token)
            accessToken = token
            MobileStateStore(appContext).saveOAuth("github", "keystore:oauth.github.access")
            status = "Signed in to GitHub."
        } catch (t: Throwable) {
            status = t.message ?: "GitHub token exchange failed."
        } finally {
            signingIn = false
        }
    }

    private fun randomToken(): String = Base64.getUrlEncoder().withoutPadding().encodeToString(ByteArray(32).also { java.security.SecureRandom().nextBytes(it) })
    private fun challenge(value: String): String = Base64.getUrlEncoder().withoutPadding().encodeToString(MessageDigest.getInstance("SHA-256").digest(value.toByteArray()))
    private fun form(vararg values: Pair<String, String>) = values.joinToString("&") { (key, value) -> URLEncoder.encode(key, "UTF-8") + "=" + URLEncoder.encode(value, "UTF-8") }

    companion object {
        private const val CALLBACK = "herness://oauth/github"
    }
}

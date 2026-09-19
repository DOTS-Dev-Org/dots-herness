package com.dots.herness.mobile

import android.content.Context
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Checkbox
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest

/**
 * Live-fetched legal documents + first-run acceptance gate. Canonical Markdown
 * is served by the versioned Herness Worker D1/R2 endpoint; see docs/legal/README.md.
 */
data class LegalDocuments(
    val version: String,
    val locale: String,
    val terms: String,
    val privacy: String,
    val termsHash: String,
    val privacyHash: String,
    val termsUrl: String?,
    val privacyUrl: String?,
    val hash: String,
) {
    val isEmpty: Boolean get() = terms.isEmpty() && privacy.isEmpty()
    val isComplete: Boolean get() = terms.isNotEmpty() && privacy.isNotEmpty()
}

enum class LegalConsent(val key: String) { AI_TRANSFER("aiTransfer"), GITHUB("github"), VOICE("voice"), MARKETING("marketing") }

class LegalModel(context: Context) {
    private val prefs = context.getSharedPreferences("herness.preferences", Context.MODE_PRIVATE)
    private val cacheDirectory = File(context.cacheDir, "legal")

    var documents by mutableStateOf<LegalDocuments?>(null)
        private set
    var needsAcceptance by mutableStateOf(prefs.getString(ACCEPTED_HASH, "").isNullOrEmpty())
        private set
    var loadFailed by mutableStateOf(false)
        private set

    private var lang: String = "en"

    fun setLanguage(language: String) {
        lang = language
    }

    val webLang: String get() = lang

    private fun cacheFile(): File = File(cacheDirectory, "legal-cache-v3-${lang.replace('-', '_')}.json")

    suspend fun load() {
        val docs = fetch()
        if (docs != null) {
            documents = docs
            needsAcceptance = prefs.getString(ACCEPTED_HASH, null) != docs.hash
            loadFailed = false
        } else {
            loadFailed = true
            needsAcceptance = prefs.getString(ACCEPTED_HASH, "").isNullOrEmpty()
        }
    }

    private suspend fun fetch(): LegalDocuments? = withContext(Dispatchers.IO) {
        try {
            val connection = (URL("$API_URL?locale=${java.net.URLEncoder.encode(lang, "UTF-8")}").openConnection() as HttpURLConnection).apply {
                connectTimeout = 20_000
                readTimeout = 20_000
                setRequestProperty("User-Agent", "HerNessAndroid")
            }
            connection.inputStream.bufferedReader().use { reader ->
                val body = reader.readText()
                val docs = parse(body, lang)
                if (docs?.isComplete == true) {
                    runCatching { cacheDirectory.mkdirs(); cacheFile().writeText(body) }
                    return@withContext docs
                }
            }
        } catch (_: Exception) {
            // fall through to cache
        }
        runCatching {
            if (!cacheFile().exists()) return@runCatching null
            parse(cacheFile().readText(), lang)?.takeIf { it.isComplete }
        }.getOrNull()
    }

    fun consent(item: LegalConsent): Boolean = prefs.getBoolean(CONSENT_PREFIX + item.key, false)

    fun setConsent(item: LegalConsent, value: Boolean) {
        prefs.edit().putBoolean(CONSENT_PREFIX + item.key, value).apply()
    }

    val aiTransferAllowed: Boolean get() = consent(LegalConsent.AI_TRANSFER)

    fun accept() {
        val docs = documents ?: return
        prefs.edit()
            .putString(ACCEPTED_HASH, docs.hash)
            .putString(ACCEPTED_AT, java.time.Instant.now().toString())
            .apply()
        needsAcceptance = false
    }

    companion object {
        private const val API_URL = "https://dotsherness-unified-backend.dotsherness-unified-backend.workers.dev/api/legal/documents"
        private const val ACCEPTED_HASH = "legal.acceptedHash"
        private const val ACCEPTED_AT = "legal.acceptedAt"
        private const val CONSENT_PREFIX = "legal.consent."

        private fun parse(json: String, lang: String): LegalDocuments? {
            val root = runCatching { JSONObject(json) }.getOrNull()
            val documents = root?.optJSONObject("documents") ?: return null
            val terms = root.optString("version", "").let { version ->
                documents.optJSONObject("terms")?.let { item -> ParsedDocument(version, root.optString("locale", ""), item) }
            } ?: return null
            val privacy = root.optString("version", "").let { version ->
                documents.optJSONObject("privacy_notice")?.let { item -> ParsedDocument(version, root.optString("locale", ""), item) }
            } ?: return null
            if (terms.locale != lang || privacy.locale != lang || terms.version != privacy.version) return null

            val termsHash = terms.json.optString("sha256", "")
            val privacyHash = privacy.json.optString("sha256", "")
            if (termsHash != sha256(terms.markdown) || privacyHash != sha256(privacy.markdown)) return null
            val hash = sha256("${terms.version}|${terms.locale}|$termsHash|$privacyHash")
            return LegalDocuments(
                version = terms.version,
                locale = terms.locale,
                terms = terms.markdown,
                privacy = privacy.markdown,
                termsHash = termsHash,
                privacyHash = privacyHash,
                termsUrl = terms.json.optString("r2_url", "").takeIf { it.isNotEmpty() },
                privacyUrl = privacy.json.optString("r2_url", "").takeIf { it.isNotEmpty() },
                hash = hash,
            )
        }

        private data class ParsedDocument(val version: String, val locale: String, val json: JSONObject) {
            val markdown: String get() = json.optString("markdown", "")
        }

        private fun sha256(value: String): String = MessageDigest.getInstance("SHA-256")
            .digest(value.toByteArray())
            .joinToString("") { "%02x".format(it) }
    }
}

@Composable
private fun consentLabel(item: LegalConsent): String = stringResource(
    when (item) {
        LegalConsent.AI_TRANSFER -> R.string.legal_consent_ai_transfer
        LegalConsent.GITHUB -> R.string.legal_consent_github
        LegalConsent.VOICE -> R.string.legal_consent_voice
        LegalConsent.MARKETING -> R.string.legal_consent_marketing
    }
)

@Composable
private fun LegalDocumentPanel(documents: LegalDocuments, initialTerms: Boolean = true) {
    var showTerms by remember(initialTerms) { mutableStateOf(initialTerms) }
    val uriHandler = LocalUriHandler.current
    val scroll = rememberScrollState()
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
            SegmentedButton(
                selected = showTerms,
                onClick = { showTerms = true },
                shape = SegmentedButtonDefaults.itemShape(0, 2),
            ) { Text(stringResource(R.string.legal_terms_tab)) }
            SegmentedButton(
                selected = !showTerms,
                onClick = { showTerms = false },
                shape = SegmentedButtonDefaults.itemShape(1, 2),
            ) { Text(stringResource(R.string.legal_privacy_tab)) }
        }
        Text(
            if (showTerms) documents.terms else documents.privacy,
            style = MaterialTheme.typography.bodySmall,
            modifier = Modifier
                .fillMaxWidth()
                .height(240.dp)
                .verticalScroll(scroll),
        )
        TextButton({
            val url = if (showTerms) documents.termsUrl else documents.privacyUrl
            if (!url.isNullOrBlank()) uriHandler.openUri(url)
        }) {
            Text(stringResource(R.string.legal_open_web))
        }
    }
}

@Composable
private fun LegalDocumentsDialog(documents: LegalDocuments, initialTerms: Boolean, onDismiss: () -> Unit) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.legal_title)) },
        text = { LegalDocumentPanel(documents, initialTerms) },
        confirmButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.app_ok)) } },
    )
}

@Composable
private fun ConsentChecks(legal: LegalModel) {
    for (item in LegalConsent.entries) {
        var checked by remember { mutableStateOf(legal.consent(item)) }
        androidx.compose.foundation.layout.Row(verticalAlignment = androidx.compose.ui.Alignment.CenterVertically) {
            Checkbox(checked = checked, onCheckedChange = { checked = it; legal.setConsent(item, it) })
            Text(consentLabel(item), style = MaterialTheme.typography.bodySmall, modifier = Modifier.weight(1f))
        }
    }
}

@Composable
private fun LegalAgreementContent(documents: LegalDocuments, legal: LegalModel) {
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text(stringResource(R.string.legal_terms_tab), style = MaterialTheme.typography.titleMedium)
        Text(documents.terms, style = MaterialTheme.typography.bodySmall)
        Text(stringResource(R.string.legal_consent_heading), style = MaterialTheme.typography.titleMedium)
        ConsentChecks(legal)
        HorizontalDivider()
        Text(stringResource(R.string.legal_privacy_tab), style = MaterialTheme.typography.titleMedium)
        Text(documents.privacy, style = MaterialTheme.typography.bodySmall)
    }
}

@Composable
fun LegalGate(legal: LegalModel) {
    val scroll = rememberScrollState()
    var reloading by remember { mutableStateOf(false) }
    val documents = legal.documents
    Column(
        Modifier.fillMaxSize().padding(16.dp),
    ) {
        Column(
            Modifier.weight(1f).verticalScroll(scroll),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text(stringResource(R.string.legal_gate_heading), style = MaterialTheme.typography.headlineSmall)
            Text(stringResource(R.string.legal_gate_intro), style = MaterialTheme.typography.bodyMedium)
            if (documents != null) {
                LegalAgreementContent(documents, legal)
            } else {
                Text(stringResource(R.string.legal_load_error), style = MaterialTheme.typography.bodyMedium)
                Button(onClick = { reloading = true }, enabled = !reloading) {
                    Text(stringResource(R.string.legal_retry))
                }
            }
        }
        if (documents != null) {
            Text(
                stringResource(R.string.legal_accept_hint),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Button(onClick = { legal.accept() }, modifier = Modifier.fillMaxWidth()) {
                Text(stringResource(R.string.legal_accept))
            }
        }
    }
    if (reloading) LaunchedEffect(Unit) { legal.load(); reloading = false }
}

@Composable
fun LegalSettingsSection(legal: LegalModel) {
    var documentToShow by remember { mutableStateOf<Boolean?>(null) }
    Text(stringResource(R.string.legal_title), style = MaterialTheme.typography.headlineSmall)
    val documents = legal.documents
    if (documents != null) {
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            TextButton(onClick = { documentToShow = true }) { Text(stringResource(R.string.legal_terms_tab)) }
            TextButton(onClick = { documentToShow = false }) { Text(stringResource(R.string.legal_privacy_tab)) }
        }
        Text(stringResource(R.string.legal_consent_prefs), style = MaterialTheme.typography.titleMedium)
        ConsentChecks(legal)
    } else {
        var reloading by remember { mutableStateOf(false) }
        Button(onClick = { reloading = true }, enabled = !reloading) {
            Text(stringResource(R.string.legal_retry))
        }
        if (reloading) LaunchedEffect(Unit) { legal.load(); reloading = false }
    }
    if (documentToShow != null && legal.documents != null) {
        LegalDocumentsDialog(legal.documents!!, documentToShow!!, onDismiss = { documentToShow = null })
    }
}

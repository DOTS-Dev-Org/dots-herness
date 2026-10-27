package com.dots.herness.mobile

import org.json.JSONObject
import java.io.File
import java.security.MessageDigest
import java.util.UUID

/** Device-local user preferences and operational task summaries. */
internal object MobilePersonalMemory {
    private data class Fact(val kind: String, val key: String, val text: String)

    fun recordPreference(workspace: File, userRoot: File, key: String, text: String, scope: String): String {
        val normalizedKey = collapse(key, 60).lowercase()
        val normalizedText = collapse(text, 240)
        if (normalizedKey.isEmpty() || normalizedText.isEmpty()) {
            return "That call was not usable. Send kind \"preference\", a short key, and a one-sentence text."
        }
        if (MobileFacts.looksLikeSecret(normalizedKey, normalizedText)) {
            return "Not recorded: that looks like a credential. Keep secrets in secure storage and record only the non-secret fact."
        }
        return runCatching {
            userRoot.mkdirs()
            if (scope == "user") {
                val path = File(userRoot, "user-facts.md")
                val facts = read(path).filter { it.kind != "preference" || it.key != normalizedKey } +
                    Fact("preference", normalizedKey, normalizedText)
                path.writeText(render(facts))
            } else {
                val path = File(userRoot, "user_profile.json")
                val profile = if (path.isFile) JSONObject(path.readText()) else JSONObject()
                val projectKey = projectIdentity(workspace)
                val all = profile.optJSONObject("projectPreferences") ?: JSONObject()
                val preferences = all.optJSONObject(projectKey) ?: JSONObject()
                if (!preferences.has(normalizedKey) && preferences.length() >= 40) {
                    return "This project already has the maximum number of saved preferences."
                }
                preferences.put(normalizedKey, normalizedText)
                all.put(projectKey, preferences)
                profile.put("projectPreferences", all)
                path.writeText(profile.toString(2))
            }
            "Recorded preference $normalizedKey: $normalizedText"
        }.getOrDefault("Device-local memory is not available here, so nothing was recorded. Continue with the work; do not retry.")
    }

    fun text(userRoot: File, workspace: File? = null): String {
        val projectKeys = workspace?.let { root ->
            MobileFacts.projectKeys(root, userRoot) + projectPreferenceKeys(userRoot, root)
        }.orEmpty()
        val facts = read(File(userRoot, "user-facts.md"))
            .filterNot { it.key.lowercase() in projectKeys }
        val global = if (facts.isEmpty()) "" else render(facts).trim()
        val pieces = listOf(global).filter(String::isNotEmpty)
        if (pieces.isEmpty()) return ""
        return "[Personal memory, stored on this device]\nUse these user preferences when the active project has no conflicting saved rule or fact. Project memory wins over any personal memory, including project-scoped preferences; the user's current request wins over both.\n" +
            pieces.joinToString("\n\n")
    }

    fun projectPreferenceText(userRoot: File, workspace: File): String {
        val path = File(userRoot, "user_profile.json")
        val preferences = runCatching {
            JSONObject(path.readText()).optJSONObject("projectPreferences")
                ?.optJSONObject(projectIdentity(workspace))
        }.getOrNull() ?: return ""
        if (preferences.length() == 0) return ""
        val projectKeys = MobileFacts.projectKeys(workspace, userRoot)
        val lines = preferences.keys().asSequence().filterNot { it.lowercase() in projectKeys }.sorted().mapNotNull { key ->
            preferences.optString(key).takeIf(String::isNotEmpty)?.let { "- $key: $it" }
        }.toList()
        return if (lines.isEmpty()) "" else "## Preferences for this project (device-local)\n" + lines.joinToString("\n")
    }

    private fun projectPreferenceKeys(userRoot: File, workspace: File): Set<String> {
        val path = File(userRoot, "user_profile.json")
        return runCatching {
            val preferences = JSONObject(path.readText()).optJSONObject("projectPreferences")
                ?.optJSONObject(projectIdentity(workspace)) ?: return emptySet()
            preferences.keys().asSequence().map { it.lowercase() }.toSet()
        }.getOrDefault(emptySet())
    }

    fun projectMemoryFolder(userRoot: File, workspace: File): File =
        File(File(userRoot, "user-memory"), projectMemoryIdentity(workspace))

    fun migrateLegacyProjectFile(name: String, workspace: File, userRoot: File) {
        val source = File(File(workspace, ".mem"), name)
        val destination = File(projectMemoryFolder(userRoot, workspace), name)
        if (destination.isFile || !source.isFile) return
        runCatching {
            destination.parentFile?.mkdirs()
            source.copyTo(destination, overwrite = false)
        }
    }

    /** Only operation summaries are injected; conversation text and tool output stay out. */
    fun activityText(events: List<MobileRuntimeEvent>): String {
        val summaries = events.filter { it.kind == "run.summary" }.takeLast(5)
        val lines = summaries.map { summary ->
            val runId = summary.payload["runId"].orEmpty()
            val status = summary.payload["status"] ?: "unknown"
            val paths = events.asSequence()
                .filter { (it.kind == "file.changed" || it.kind == "file.deleted") && it.payload["runId"] == runId }
                .mapNotNull { it.payload["path"] }
                .distinct()
                .take(8)
                .toList()
            val counts = listOf(
                count(summary.payload["addedCount"], "added"),
                count(summary.payload["modifiedCount"], "changed"),
                count(summary.payload["deletedCount"], "removed"),
            ).filter(String::isNotEmpty).joinToString(", ")
            val detail = listOf(counts, if (paths.isEmpty()) "" else "files: ${paths.joinToString(", ")}")
                .filter(String::isNotEmpty).joinToString("; ")
            "- Run ${runId.take(8)}: $status${if (detail.isEmpty()) "" else "; $detail"}"
        }
        if (lines.isEmpty()) return ""
        return "[Recent device-local project activity]\nThese are operation summaries, not conversation history.\n" + lines.joinToString("\n")
    }

    private fun projectIdentity(workspace: File): String {
        val manifest = File(workspace, ".mem/manifest.json")
        val id = runCatching { JSONObject(manifest.readText()).optString("projectId") }.getOrNull()
        return id?.takeIf(String::isNotBlank)
            ?: runCatching { workspace.canonicalPath }.getOrDefault(workspace.absolutePath)
    }

    private fun projectMemoryIdentity(workspace: File): String {
        val manifest = File(workspace, ".mem/manifest.json")
        val id = runCatching { JSONObject(manifest.readText()).optString("projectId") }.getOrNull()
        if (!id.isNullOrBlank() && runCatching { UUID.fromString(id) }.isSuccess) return id
        val path = runCatching { workspace.canonicalPath }.getOrDefault(workspace.absolutePath)
        return MessageDigest.getInstance("SHA-256").digest(path.toByteArray())
            .joinToString("") { "%02x".format(it) }.take(32)
    }

    private fun read(path: File): List<Fact> {
        val body = runCatching { path.readText() }.getOrNull() ?: return emptyList()
        val facts = mutableListOf<Fact>()
        var kind = ""
        for (raw in body.split('\n')) {
            val line = raw.trim()
            if (line.startsWith("## ")) {
                kind = line.drop(3).trim().lowercase()
                continue
            }
            val separator = line.indexOf(" — ")
            if (line.startsWith("- ") && kind.isNotEmpty() && separator >= 0) {
                val key = line.substring(2, separator).trim(' ', '`')
                val text = line.substring(separator + 3).trim()
                if (key.isNotEmpty() && text.isNotEmpty()) facts += Fact(kind, key, text)
            }
        }
        return facts
    }

    private fun render(facts: List<Fact>): String = facts.groupBy { it.kind }.toSortedMap().entries.joinToString("\n\n") { (kind, items) ->
        "## $kind\n" + items.sortedBy { it.key }.joinToString("\n") { "- ${it.key} — ${it.text}" }
    } + "\n"

    private fun collapse(value: String, limit: Int): String = value.trim().split(Regex("\\s+")).filter(String::isNotEmpty).joinToString(" ").take(limit)

    private fun count(value: String?, label: String): String {
        val number = value?.toIntOrNull() ?: return ""
        return if (number <= 0) "" else "$number $label"
    }
}

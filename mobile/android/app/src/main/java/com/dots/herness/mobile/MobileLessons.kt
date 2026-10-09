// Copyright (c) 2026 DOTS
// What the project's memory holds, on the phone: the lessons the desktops
// learned (`.mem/lessons.json`, read only - the phone has no evaluator) and the
// facts file every client shares (`.mem/facts.md`, read and written here through
// the `remember` tool).
//
// Mirrors mobile/ios/Sources/MobileLessons.swift.
package com.dots.herness.mobile

import org.json.JSONArray
import java.io.File
import java.time.Duration
import java.time.Instant

internal object MobileLessons {
    private const val MAXIMUM_CHARACTERS = 4_000
    private val implicitLifetime: Duration = Duration.ofDays(90)

    private class Lesson(val whenText: String, val rule: String, val why: String, val paths: List<String>, val sources: List<String>, val lastSeen: Instant) {
        val scoped get() = paths.isNotEmpty()

        /** The line as the model reads it: a short id it can cite, and whether the user said it or it was inferred. */
        val cited get() = "[${id.removePrefix("signal:").take(6)} ${if (sources.any { !it.startsWith("signal:") }) "user" else "inferred"}] $line"

        fun appliesTo(path: String) = paths.any { scope ->
            val folder = scope.removeSuffix("/")
            path == folder || path.startsWith("$folder/")
        }

        /** Distinct events; a feedback record and the inference drawn from it count once. */
        val hits get() = sources.map { it.removeSuffix(":inferred") }.toSet().size
        val id get() = sources.minOrNull().orEmpty()

        /** What the user said stays; what was only inferred stays while recent or learned more than once. */
        fun isActive(now: Instant) =
            sources.any { !it.startsWith("signal:") } || hits >= 2 || Duration.between(lastSeen, now) < implicitLifetime

        val line: String
            get() {
                val situation = whenText.trim(' ', '.', ':')
                return (if (situation.isEmpty()) "" else "When $situation: ") + rule + (if (why.isEmpty()) "" else " Why: $why")
            }
    }

    /**
     * The notice for a conversation: project-wide lessons still in force,
     * strongest first, within a fixed budget. Empty when there are none. The text
     * carries no date or counter, so it is appended once and again only when a
     * lesson changes.
     */
    private fun load(root: File): List<Lesson> =
        runCatching {
            val items = JSONArray(File(root, ".mem/lessons.json").readText())
            (0 until items.length()).mapNotNull { index ->
                val item = items.optJSONObject(index) ?: return@mapNotNull null
                val rule = item.optString("rule")
                if (rule.isBlank()) return@mapNotNull null
                val sources = item.optJSONArray("sources")?.let { list -> (0 until list.length()).map { list.optString(it) } }.orEmpty()
                Lesson(
                    item.optString("when"), rule, item.optString("why"),
                    item.optJSONArray("paths")?.let { list -> (0 until list.length()).map { list.optString(it) } }.orEmpty(),
                    sources,
                    runCatching { Instant.parse(item.optString("lastSeen")) }.getOrDefault(Instant.EPOCH),
                )
            }
        }.getOrDefault(emptyList())

    // ponytail: once per app session, not per conversation; key it by
    // conversation if a second chat is seen missing a lesson.
    private val delivered = java.util.Collections.synchronizedSet(mutableSetOf<String>())

    /** Lessons tied to a file, handed over with the file the first time it is read or written. */
    fun fileNotice(root: File, path: String, now: Instant = Instant.now()): String {
        val fresh = load(root).filter { it.isActive(now) && it.appliesTo(path) && delivered.add(root.path + "\n" + it.id) }
        if (fresh.isEmpty()) return ""
        return "\n\nLearned earlier about this file (apply it):\n" + fresh.joinToString("\n") { "- " + it.cited }
    }

    fun rulesText(root: File, now: Instant = Instant.now()): String {
        val lessons = load(root)
        val lines = mutableListOf<String>()
        var used = 0
        val ranked = lessons.filter { !it.scoped && it.isActive(now) }
            .sortedWith(compareByDescending<Lesson> { it.hits }.thenByDescending { it.lastSeen }.thenBy { it.id })
        for (lesson in ranked) {
            val line = "- " + lesson.cited
            if (used + line.length > MAXIMUM_CHARACTERS) break
            used += line.length
            lines += line
        }
        val rules = if (lines.isEmpty()) "" else
            "[Learned rules]\nWhat this user already taught HerNess in this project. Follow it without asking again; " +
                "the user's current message wins. Each rule opens with its id and whether the user said it or it was " +
                "inferred from what they corrected.\n" + lines.joinToString("\n")
        return listOf(rules, MobileFacts.text(root)).filter { it.isNotEmpty() }.joinToString("\n\n")
    }
}

/**
 * The facts file: project facts, preferences and decisions as keyed lines under
 * a heading per kind, shared with the desktops. Mirrors shared/WorkspaceFacts.cs.
 */
internal object MobileFacts {
    private val kinds = listOf("project", "preference", "decision")
    private val knowledgeKeys = listOf("architecture", "conventions", "design-system")
    private const val MAXIMUM_CHARACTERS = 6_000

    private data class Fact(val kind: String, val key: String, val text: String)

    private fun file(root: File) = File(root, ".mem/facts.md")

    private fun read(root: File): List<Fact> {
        val body = runCatching { file(root).readText() }.getOrNull() ?: return emptyList()
        val facts = mutableListOf<Fact>()
        var kind = ""
        for (raw in body.split('\n')) {
            val line = raw.trim()
            if (line.startsWith("## ")) {
                kind = line.drop(3).trim().lowercase()
                continue
            }
            val separator = line.indexOf(" — ")
            if (!line.startsWith("- ") || kind.isEmpty() || separator < 0) continue
            val key = line.substring(2, separator).trim(' ', '`')
            val text = line.substring(separator + 3).trim()
            if (key.isNotEmpty() && text.isNotEmpty()) facts += Fact(kind, key, text)
        }
        return facts
    }

    private fun render(facts: List<Fact>): String =
        (kinds + facts.map { it.kind }.filter { it !in kinds }.distinct().sorted()).mapNotNull { kind ->
            val lines = facts.filter { it.kind == kind }.map { "- ${it.key} — ${it.text}" }
            if (lines.isEmpty()) null else "## $kind\n" + lines.joinToString("\n")
        }.joinToString("\n\n")

    /** The notice for a conversation; empty until something is recorded. */
    fun text(root: File): String {
        val facts = read(root)
        if (facts.isEmpty()) return ""
        return "[Project facts]\nWhat is already known about this project and how the user wants work done in it. " +
            "Follow it without asking again; interface work reuses the colors, type and components the " +
            "design-system fact names. Record a new lasting fact with remember.\n" +
            render(facts).take(MAXIMUM_CHARACTERS)
    }

    /** Credential shapes, by key name and by value: the file is committed with the repository. */
    fun looksLikeSecret(key: String, text: String): Boolean {
        if (Regex("(?i)(api[_-]?key|apikey|secret|token|password|passwd|credential|private[_-]?key)").containsMatchIn(key)) return true
        return listOf(
            "(?i)\\b(sk|pk|rk)[_-][A-Za-z0-9_\\-]{16,}",
            "\\b(gh[pousr]|github_pat)_[A-Za-z0-9_]{16,}",
            "(?i)\\bAKIA[0-9A-Z]{12,}",
            "(?i)\\bxox[abposr]-[A-Za-z0-9-]{10,}",
            "-----BEGIN [A-Z ]*PRIVATE KEY-----",
            "(?i)(api[_-]?key|token|password|secret)\\s*[:=]\\s*\\S+",
        ).any { Regex(it).containsMatchIn(text) }
    }

    /** Writes one fact, replacing an earlier one with the same kind and key. */
    fun record(root: File, kind: String, key: String, text: String): String {
        fun collapse(value: String, limit: Int) = value.trim().split(Regex("\\s+")).filter { it.isNotEmpty() }.joinToString(" ").take(limit)
        val factKind = kind.trim().lowercase()
        val factKey = collapse(key, 60).lowercase().ifEmpty { if (factKind == "decision") "decision" else "note" }
        val factText = collapse(text, if (factKind == "project" && factKey in knowledgeKeys) 1_200 else 240)
        if (factKind !in kinds || factText.isEmpty()) {
            return "That call was not usable. Send kind (\"project\", \"preference\" or \"decision\"), a short key naming the subject, and a one-sentence text. Continue with the work either way."
        }
        if (looksLikeSecret(factKey, factText)) {
            return "Not recorded: that looks like a credential, and this store is a file committed with the repository. Record where the secret lives instead. Continue with the work."
        }
        val facts = read(root).filter { it.kind != factKind || it.key != factKey } + Fact(factKind, factKey, factText)
        return runCatching {
            file(root).parentFile?.mkdirs()
            file(root).writeText(render(facts) + "\n")
            "Recorded $factKind $factKey: $factText"
        }.getOrDefault("Durable memory is not available here, so nothing was recorded. Continue with the work; do not retry.")
    }
}

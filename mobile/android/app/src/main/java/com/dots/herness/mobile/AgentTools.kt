package com.dots.herness.mobile

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.nio.file.AtomicMoveNotSupportedException
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.security.MessageDigest
import java.util.concurrent.ConcurrentHashMap

/**
 * Tools the on-phone agent gets over the local workspace mirror. Everything that
 * touches the filesystem goes through [resolve], so a traversal in a model's tool
 * call fails the same way a bad snapshot path does.
 */
object AgentTools {
    const val MAXIMUM_READ_CHARACTERS = 60_000
    const val MAXIMUM_LISTED_FILES = 2_000
    const val ASK_USER_ANSWERED_DIRECTIVE = "The user answered your clarification. Continue the original request now in the current mode: perform the requested work in ordinary execution, or return the complete plan in plan mode. Do not send a status-only reply while tools can proceed. Preserve unrelated pre-existing edits automatically; do not mention them unless a specific inspected conflict blocks the requested change."
    const val MAXIMUM_EDIT_BATCH = 50
    const val MAXIMUM_GLOB_RESULTS = 200

    /** Directory walks stop here rather than reporting a partial list as if it
     * were complete. */
    const val MAXIMUM_GLOB_SCANNED_FILES = 20_000
    const val VERIFIED_MARKER = "[cleanup:verified]"
    const val PRESERVED_MARKER = "[cleanup:preserved]"
    const val FAILED_MARKER = "[cleanup:failed]"
    private val allowedExtensions = setOf("c", "cc", "cpp", "cs", "csproj", "gradle", "h", "hpp", "ini", "java", "js", "jsx", "json", "kt", "kts", "mm", "plist", "props", "py", "resx", "rs", "swift", "toml", "ts", "tsx", "xml", "xaml", "yaml", "yml")
    private val ignoredDirectories = setOf(".git", ".mem", ".build", "build", "bin", "obj", "dist", "node_modules", "Pods", "DerivedData")
    private val protectedExtensions = setOf("db", "sqlite", "sqlite3", "key", "pem", "p12", "pfx", "cer")
    private val protectedFragments = listOf(".env", "credential", "secret", "token", "password", "keychain", "keystore")

    /**
     * Which files the model has actually been shown. An edit assumes it, so
     * [edit] refuses a file that was never read or that moved underneath it;
     * [com.dots.herness.mobile.WebTools] and the read-only tools never consult it.
     */
    val reads = ReadLedger()

    fun readFile(root: File, path: String, offset: Int = 1, limit: Int = Int.MAX_VALUE): String {
        val target = resolve(root, path)
        val bytes = target.readBytes()
        val text = String(bytes, Charsets.UTF_8)
        if (!text.toByteArray(Charsets.UTF_8).contentEquals(bytes)) return "$path is not UTF-8 text (${bytes.size} bytes)."
        val lines = text.split('\n')
        val start = offset.coerceAtLeast(1)
        if (start > lines.size) return "Offset is past the end of the file; it has ${lines.size} lines."
        val count = limit.coerceAtLeast(0).coerceAtMost(lines.size - start + 1)
        val end = start + count
        val emitted = mutableListOf<String>()
        var size = 0
        var line = start
        while (line < end) {
            val candidate = lines[line - 1]
            val cost = candidate.toByteArray(Charsets.UTF_8).size + 1
            if (size + cost > MAXIMUM_READ_CHARACTERS && emitted.isNotEmpty()) break
            emitted += candidate
            size += cost
            line++
        }
        reads.recordLines(target, bytes, start, line, lines.size)
        val body = emitted.joinToString("\n")
        return if (line >= end) body else body + "\n\n[truncated] Continue with offset: $line"
    }

    fun resolve(root: File, path: String): File {
        require(path.split('/').none { it == ".mem" || it.startsWith(".mem.") }) { "The .mem path is not available to mobile tools." }
        // Both sides are canonicalised: on some platforms the root itself is a
        // symlink, and comparing a canonical child to a symlinked root never matches.
        val base = root.canonicalFile
        val target = File(base, path).canonicalFile
        require(target.path == base.path || target.path.startsWith(base.path + File.separator)) { "That path is outside the workspace." }
        return target
    }

    /** The workspace-relative form a tool result shows the model. */
    fun relativePath(root: File, file: File): String {
        val base = root.canonicalFile.path
        val path = file.absoluteFile.path
        return when {
            path == base -> "."
            path.startsWith(base + File.separator) -> path.substring(base.length + 1).replace(File.separatorChar, '/')
            else -> path
        }
    }

    fun walk(root: File): List<String> = runCatching {
        safeFiles(root).map { it.relativeTo(root.canonicalFile).invariantSeparatorsPath }.sorted()
    }.getOrDefault(emptyList())

    /** A failed traversal is intentionally visible to the cleanup caller. */
    fun snapshot(root: File): Map<String, String> = safeFiles(root).associate {
        it.relativeTo(root.canonicalFile).invariantSeparatorsPath to sha256(it.readBytes())
    }

    fun workspace(root: () -> File): List<AgentToolSpec> = listOf(
        AgentToolSpec(
            "list_files",
            "List files in the workspace. Optionally filter by a path prefix.",
            schema(mapOf("prefix" to "Only list paths starting with this prefix."))
        ) { input ->
            withContext(Dispatchers.IO) {
                val prefix = input.optString("prefix")
                val paths = walk(root()).filter { prefix.isBlank() || it.startsWith(prefix) }
                if (paths.isEmpty()) "No files matched." else paths.take(MAXIMUM_LISTED_FILES).joinToString("\n")
            }
        },

        AgentToolSpec(
            "read_file",
            "Read whole lines of a UTF-8 file. Use offset and limit to page through long files; all pages of the same version together authorize editing.",
            schema(mapOf("path" to "Workspace-relative file path."), listOf("path")).apply {
                getJSONObject("properties")
                    .put("offset", JSONObject().put("type", "integer").put("description", "First line, 1-based. Defaults to 1."))
                    .put("limit", JSONObject().put("type", "integer").put("description", "Maximum number of lines to read."))
            }
        ) { input ->
            withContext(Dispatchers.IO) {
                val path = input.required("path", "read_file")
                readFile(root(), path,
                    if (input.has("offset")) input.optInt("offset", 1) else 1,
                    if (input.has("limit")) input.optInt("limit", Int.MAX_VALUE) else Int.MAX_VALUE
                ) + MobileLessons.fileNotice(root(), path)
            }
        },

        AgentToolSpec(
            "write_file",
            "Create or overwrite a UTF-8 text file in the workspace.",
            schema(mapOf("path" to "Workspace-relative file path.", "content" to "Full new file contents."), listOf("path", "content"))
        ) { input ->
            withContext(Dispatchers.IO) {
                val path = input.required("path", "write_file")
                val content = input.optString("content")
                val target = resolve(root(), path)
                if (target.exists()) {
                    when (reads.state(target, target.readBytes())) {
                        ReadState.UNREAD -> return@withContext "write_file needs a complete prior read_file for $path. Read all pages first."
                        ReadState.STALE -> return@withContext "write_file: $path changed since you last read it. Read it again."
                        ReadState.FRESH -> Unit
                    }
                }
                target.parentFile?.mkdirs()
                target.writeText(content)
                reads.record(target, content.toByteArray())
                "Wrote ${content.toByteArray().size} bytes to $path." + MobileLessons.fileNotice(root(), path)
            }
        },

        AgentToolSpec(
            "remember",
            "Record something that must outlive this conversation: a lasting user preference, a settled project choice, or a standing fact about the project. One call per fact, with a short stable key so a later fact on the same subject replaces it. Never record a secret, a guess, or what only matters to the current request.",
            schema(mapOf(
                "kind" to "preference: how the user wants work done. decision: a settled project choice. project: a standing fact about the project.",
                "key" to "Short stable subject, e.g. \"language\", \"goal\", \"design-system\".",
                "text" to "The fact itself, one sentence, written so it stands alone months later. The project keys \"architecture\", \"conventions\" and \"design-system\" may run to 1,200 characters.",
            ), listOf("kind", "text"))
        ) { input ->
            withContext(Dispatchers.IO) {
                MobileFacts.record(root(), input.required("kind", "remember"), input.optString("key"), input.required("text", "remember"))
            }
        },

        AgentToolSpec(
            "edit_file",
            EDIT_DESCRIPTION,
            editSchema,
        ) { input ->
            withContext(Dispatchers.IO) {
                val path = input.required("path", "edit_file")
                edit(root(), path, jsonObjects(input.optJSONArray("edits")))
            }
        },

        AgentToolSpec(
            "glob",
            GLOB_DESCRIPTION,
            schema(
                mapOf(
                    "pattern" to "Glob pattern, relative to the searched directory.",
                    "path" to "Relative directory to search. Defaults to the workspace root.",
                ),
                listOf("pattern"),
            ),
        ) { input ->
            withContext(Dispatchers.IO) {
                glob(root(), input.required("pattern", "glob"), input.optString("path").ifBlank { "." })
            }
        },

        AgentToolSpec(
            "remove_file",
            "Remove one proven-unused source, config, test, or import artifact. Requires a reason and reference terms; credentials, state, user data, directories, and symlinks are never removable.",
            schema(mapOf("path" to "Workspace-relative file path.", "reason" to "Why the old artifact is no longer part of the active architecture.", "referenceTerms" to "Old symbols or paths to search for, separated by commas, semicolons, or new lines."), listOf("path", "reason", "referenceTerms"))
        ) { input ->
            withContext(Dispatchers.IO) {
                removeFile(root(), input.required("path", "remove_file"), input.required("reason", "remove_file"), input.required("referenceTerms", "remove_file"))
            }
        },

        AgentToolSpec(
            "search_files",
            "Search workspace text files for a regular expression.",
            schema(mapOf("pattern" to "Regular expression to match.", "prefix" to "Only search paths starting with this prefix."), listOf("pattern"))
        ) { input ->
            withContext(Dispatchers.IO) {
                val regex = Regex(input.required("pattern", "search_files"))
                val prefix = input.optString("prefix")
                val hits = mutableListOf<String>()
                for (path in walk(root()).filter { prefix.isBlank() || it.startsWith(prefix) }) {
                    val text = runCatching { resolve(root(), path).readText() }.getOrNull() ?: continue
                    text.lineSequence().forEachIndexed { index, line ->
                        if (hits.size < 200 && regex.containsMatchIn(line)) hits += "$path:${index + 1}: ${line.take(300)}"
                    }
                    if (hits.size >= 200) return@withContext hits.joinToString("\n") + "\n… more matches not listed"
                }
                if (hits.isEmpty()) "No matches." else hits.joinToString("\n")
            }
        },
    )

    /** Shell and SQL, so the agent reaches the same runtimes the user does from the Terminal tab. */
    fun runtime(shell: LocalShell, root: () -> File, git: MobileGitClient? = null, remote: RemoteClient? = null): List<AgentToolSpec> = listOf(
        AgentToolSpec(
            "run_command",
            "Run a supported virtual command in the mobile runtime. When a desktop is paired, build-like commands are forwarded to that selected desktop project; arbitrary mobile shell processes remain unavailable.",
            schema(mapOf("command" to "The command line to run."), listOf("command"))
        ) { input ->
            val command = input.required("command", "run_command")
            if (remote?.paired == true && remote.remoteProjectMatchesSelectedProject && shouldTryRemote(command)) {
                runRemote(command, remote)?.let { return@AgentToolSpec it.ifBlank { "(no output)" } }
            }
            shell.execute(command).ifBlank { "(no output)" }
        },

        AgentToolSpec(
            "ask_user",
            "Ask only for material information the workspace cannot answer. A pre-existing dirty or staged worktree is not a reason to ask; preserve it without mentioning it. After the user answers, immediately continue the original request in the current mode and do not send a status-only reply while tools can proceed.",
            schema(mapOf("question" to "The question to show the user."), listOf("question"))
        ) { "The user answer is pending." },

        AgentToolSpec(
            "computer_use",
            "Interact with the paired desktop's environment: capture a screenshot, move the mouse, click, type, press keys, or scroll. Requires a paired desktop with Computer Use enabled in its Settings; the desktop's approval policy applies (approval happens in Settings → Tools → Live events).",
            computerUseSchema,
        ) { input ->
            val action = input.required("action", "computer_use")
            val relay = remote
                ?: return@AgentToolSpec "unsupported_on_mobile: Computer Use requires a paired desktop (macOS, Windows, or Linux) with Computer Use enabled."
            if (!relay.paired) return@AgentToolSpec "unsupported_on_mobile: Computer Use requires a paired desktop (macOS, Windows, or Linux) with Computer Use enabled."
            val payload = mutableMapOf<String, Any?>("action" to action)
            for (key in listOf("button", "text", "key", "path")) {
                input.optString(key).takeIf { it.isNotBlank() }?.let { payload[key] = it }
            }
            for (key in listOf("x", "y", "dx", "dy")) {
                if (input.has(key)) payload[key] = input.optInt(key)
            }
            try {
                val response = relay.command("computer_use", payload)
                if (response.status == "approval-required") {
                    val id = response.approvalId.orEmpty()
                    return@AgentToolSpec "The paired desktop needs approval for this computer_use action (approval id $id). Open Settings → Tools → Live events to allow or reject it, then retry."
                }
                response.error?.takeIf { it.isNotBlank() }?.let { return@AgentToolSpec "computer_use failed: $it" }
                val result = response.result?.let { runCatching { JSONObject(it) }.getOrNull() }
                result?.optString("output")?.takeIf { it.isNotBlank() }?.let { return@AgentToolSpec it }
                result?.optString("outputPreview")?.takeIf { it.isNotBlank() }?.let { return@AgentToolSpec it }
                response.result?.takeIf { it.isNotBlank() }
                    ?: "computer_use $action completed on the paired desktop."
            } catch (t: Throwable) {
                "computer_use failed on the paired desktop: ${t.message ?: "remote command failed"}"
            }
        },

        AgentToolSpec(
            "native_browser",
            "Use the paired desktop's native in-app browser to open pages, read page text, inspect JavaScript, click, type, or navigate history. Requires the selected desktop project and desktop approval.",
            nativeBrowserSchema,
        ) { input ->
            val relay = remote
                ?: return@AgentToolSpec "unsupported_on_mobile: native_browser requires a paired desktop with the same project selected."
            if (!relay.paired || !relay.remoteProjectMatchesSelectedProject) {
                return@AgentToolSpec "unsupported_on_mobile: native_browser requires a paired desktop with the same project selected."
            }
            val action = input.required("action", "native_browser")
            val payload = mutableMapOf<String, Any?>("action" to action)
            for (key in listOf("url", "path", "script", "selector", "text")) {
                input.optString(key).takeIf { it.isNotBlank() }?.let { payload[key] = it }
            }
            for (key in listOf("x", "y")) if (input.has(key)) payload[key] = input.optInt(key)
            try {
                val response = relay.command("native_browser", payload)
                if (response.status == "approval-required") {
                    return@AgentToolSpec "The paired desktop needs approval for this browser action. Approve it in Settings → Tools → Live events, then retry."
                }
                response.error?.takeIf { it.isNotBlank() }?.let { return@AgentToolSpec "native_browser failed: $it" }
                val result = response.result?.let { runCatching { JSONObject(it) }.getOrNull() }
                result?.optString("output")?.takeIf { it.isNotBlank() }?.let { return@AgentToolSpec it }
                result?.optString("outputPreview")?.takeIf { it.isNotBlank() }?.let { return@AgentToolSpec it }
                response.result?.takeIf { it.isNotBlank() } ?: "native_browser $action completed on the paired desktop."
            } catch (t: Throwable) {
                "native_browser failed on the paired desktop: ${t.message ?: "remote command failed"}"
            }
        },

        AgentToolSpec(
            "sql",
            "Run SQL against a SQLite database file in the workspace.",
            schema(mapOf("database" to "Workspace-relative path to the .db file.", "statement" to "SQL to execute."), listOf("database", "statement"))
        ) { input ->
            withContext(Dispatchers.IO) {
                val database = resolve(root(), input.required("database", "sql"))
                LocalSql.run(database, input.required("statement", "sql")).ifBlank { "(no rows)" }
            }
        },

        AgentToolSpec(
            "git",
            "Run a real local Git operation through the native libgit2 backend. Supported operations: clone, fetch, checkout, create_branch, status, diff, commit, push.",
            schema(mapOf(
                "operation" to "Git operation to run.",
                "argument" to "URL, branch, or commit message, depending on the operation.",
                "second" to "Remote or branch, depending on the operation.",
                "authorName" to "Commit author name.",
                "authorEmail" to "Commit author email.",
            ), listOf("operation")),
        ) { input ->
            val client = git ?: return@AgentToolSpec "unsupported_on_mobile: the native MobileGitClient backend is not linked."
            val arguments = listOf("argument", "second", "authorName", "authorEmail")
                .associateWith { input.optString(it) }
                .filterValues(String::isNotBlank)
            val result = client.execute(input.required("operation", "git"), arguments)
            if (result.unavailable) "unsupported_on_mobile: ${result.output}" else result.output.ifBlank { "(no output)" }
        },
    )

    // MARK: - edit_file

    /**
     * Either every edit in the batch lands or none of them does, so a rejection
     * always answers "Nothing was written." and names which edit.
     */
    fun edit(root: File, path: String, edits: List<JSONObject>): String {
        if (edits.isEmpty()) return "Tool error: edits is empty; at least one replacement is required."
        if (edits.size > MAXIMUM_EDIT_BATCH) {
            return "Tool error: too many edits in one call (max $MAXIMUM_EDIT_BATCH). Split them into separate calls."
        }
        val file = runCatching { resolve(root, path) }
            .getOrElse { return "Tool error: ${it.message ?: "that path is not usable."}" }
        val current = runCatching { file.readBytes() }.getOrNull()
            ?: return "Tool error: $path does not exist. write_file creates a new file; edit_file only changes an existing one."
        // Strict, so a binary file is refused instead of arriving as replacement
        // characters the model then "matches" against.
        val text = WebTools.decodeUtf8(current) ?: return "Tool error: $path is not valid UTF-8 text."
        // Same authority rule as read_file: an edit assumes the model has seen the
        // bytes it is matching against.
        when (reads.state(file, current)) {
            ReadState.UNREAD -> return "Tool error: $path has not been read in this conversation. Read it before editing."
            ReadState.STALE -> return "Tool error: $path changed since it was read. Read it again before editing."
            ReadState.FRESH -> Unit
        }

        var updated = text
        val summary = mutableListOf<String>()
        for ((position, item) in edits.withIndex()) {
            val index = position + 1
            val oldText = item.opt("old_text") as? String
            val newText = item.opt("new_text") as? String
            if (oldText == null || newText == null) {
                return "Tool error: edit $index needs both old_text and new_text. Nothing was written."
            }
            if (oldText.isEmpty()) {
                return "Tool error: edit $index has an empty old_text, which would match everywhere. Nothing was written."
            }
            // A string "true" is accepted because some providers serialise booleans
            // that way; an absent flag stays false.
            val replaceAll = item.optBoolean("replace_all")
            val found = occurrencesOf(oldText, updated)
            when {
                found.isEmpty() -> return "Tool error: edit $index matched nothing in $path. " +
                    "Nothing was written — check the exact text and whitespace with read_file."

                found.size > 1 && !replaceAll -> {
                    val lines = found.take(5).map { lineNumber(updated, it) }
                    return "Tool error: edit $index matched ${found.size} places in $path " +
                        "(around ${if (lines.size == 1) "line" else "lines"} ${lines.joinToString(", ")}). " +
                        "Nothing was written. Widen old_text with surrounding lines, or set replace_all."
                }
            }
            if (replaceAll) {
                updated = updated.replace(oldText, newText)
                summary += "replaced ${found.size} occurrence${if (found.size == 1) "" else "s"}"
            } else {
                val at = found.first()
                updated = updated.substring(0, at) + newText + updated.substring(at + oldText.length)
                summary += "replaced 1 occurrence"
            }
        }

        val data = updated.toByteArray(Charsets.UTF_8)
        runCatching { writeAtomically(file, data) }.getOrElse { failure ->
            return "Tool error: could not write $path: ${failure.message ?: "the write failed."}"
        }
        reads.record(file, data)
        return "Edited ${relativePath(root, file)} (${summary.joinToString("; ")})."
    }

    /** Overlapping matches are counted left to right, the same way the subsequent
     * replacement consumes them — so a count of two never describes one rewrite. */
    fun occurrencesOf(needle: String, haystack: String): List<Int> {
        val positions = mutableListOf<Int>()
        var cursor = 0
        while (true) {
            val found = haystack.indexOf(needle, cursor)
            if (found < 0) break
            positions += found
            cursor = found + needle.length
        }
        return positions
    }

    fun lineNumber(text: String, position: Int): Int =
        1 + text.substring(0, position.coerceIn(0, text.length)).count { it == '\n' }

    /** Same directory, then a rename: a write that dies halfway must not leave a
     * truncated file where the text the model matched used to be. */
    private fun writeAtomically(target: File, bytes: ByteArray) {
        val temporary = File.createTempFile(".${target.name}.", ".herness", target.parentFile)
        try {
            temporary.writeBytes(bytes)
            val source = temporary.toPath()
            val destination = target.toPath()
            try {
                Files.move(source, destination, StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING)
            } catch (unsupported: AtomicMoveNotSupportedException) {
                Files.move(source, destination, StandardCopyOption.REPLACE_EXISTING)
            }
        } finally {
            runCatching { temporary.delete() }
        }
    }

    // MARK: - glob

    fun glob(root: File, pattern: String, path: String): String {
        val trimmed = pattern.trim()
        if (trimmed.isEmpty()) return "Tool error: pattern is required."
        if (trimmed.startsWith("/") || trimmed.contains("..")) {
            return "Tool error: pattern must stay inside the workspace."
        }
        val expression = globRegex(trimmed)
            ?: return "Tool error: the pattern could not be compiled — check for an unclosed { or [."
        val base = runCatching { resolve(root, path.ifBlank { "." }) }
            .getOrElse { return "Tool error: ${it.message ?: "that path is not usable."}" }
        if (!base.isDirectory) return "Tool error: $path is not a directory."

        val matches = globMatches(expression, trimmed.contains("/"), base)
        if (matches.isEmpty()) return "glob $trimmed: no files found."
        val shown = matches.take(MAXIMUM_GLOB_RESULTS).map { it.path }
        val header = if (matches.size > MAXIMUM_GLOB_RESULTS) {
            "glob $trimmed under ${relativePath(root, base)}: $MAXIMUM_GLOB_RESULTS newest of ${matches.size} matches — narrow the pattern"
        } else {
            "glob $trimmed under ${relativePath(root, base)}: ${matches.size} file${if (matches.size == 1) "" else "s"}"
        }
        return (listOf(header) + shown).joinToString("\n")
    }

    private class GlobMatch(val path: String, val modified: Long)

    /**
     * Newest first: when an agent is looking for "the file I just made", the
     * modification time carries more signal than alphabetical order.
     */
    private fun globMatches(expression: Regex, patternHasSlash: Boolean, base: File): List<GlobMatch> {
        val root = base.canonicalFile
        val prefix = root.path + File.separator
        val found = mutableListOf<GlobMatch>()
        var scanned = 0
        var stopped = false
        fun relative(entry: File): String = entry.absoluteFile.path.let { path ->
            if (path.startsWith(prefix)) path.substring(prefix.length).replace(File.separatorChar, '/') else path
        }
        fun visit(directory: File) {
            val entries = directory.listFiles()?.sortedBy { it.name } ?: return
            for (entry in entries) {
                if (stopped) return
                val path = relative(entry)
                val components = path.split('/')
                if (components.any { it in ignoredDirectories || it == ".mem" || it.startsWith(".mem.") }) continue
                // A symlink is neither followed nor reported: it can point outside
                // the workspace, and `walk` already treats it as absent.
                if (Files.isSymbolicLink(entry.toPath())) continue
                if (entry.isDirectory) {
                    visit(entry)
                    continue
                }
                if (!entry.isFile) continue
                scanned += 1
                // The walk stops rather than reporting a partial list as if it were
                // complete.
                if (scanned > MAXIMUM_GLOB_SCANNED_FILES) {
                    stopped = true
                    return
                }
                if (expression.matches(path) || (!patternHasSlash && expression.matches(entry.name))) {
                    found += GlobMatch(path, entry.lastModified())
                }
            }
        }
        visit(root)
        return found.sortedWith(compareByDescending<GlobMatch> { it.modified }.thenBy { it.path })
    }

    /**
     * Compiles a glob into an anchored regular expression. A bare double star spans
     * path separators, a double star in front of a slash also matches zero
     * directories, and a brace group becomes a non-capturing alternation.
     */
    fun globRegex(pattern: String): Regex? =
        globPattern(pattern)?.let { source -> runCatching { Regex(source) }.getOrNull() }

    fun globPattern(pattern: String): String? {
        val output = StringBuilder()
        var braceDepth = 0
        var index = 0
        while (index < pattern.length) {
            val character = pattern[index]
            val next = index + 1
            when (character) {
                '*' -> {
                    if (next < pattern.length && pattern[next] == '*') {
                        val after = next + 1
                        if (after < pattern.length && pattern[after] == '/') {
                            // `**/` may stand for zero directories as well as many, so
                            // "src/**/*.ts" has to keep matching "src/a.ts".
                            output.append("(?:[^/]*/)*")
                            index = after + 1
                            continue
                        }
                        output.append(".*")
                        index = after
                        continue
                    }
                    output.append("[^/]*")
                    index = next
                }

                '?' -> {
                    output.append("[^/]")
                    index = next
                }

                '{' -> {
                    braceDepth += 1
                    output.append("(?:")
                    index = next
                }

                '}' -> {
                    if (braceDepth == 0) return null
                    braceDepth -= 1
                    output.append(")")
                    index = next
                }

                ',' -> {
                    output.append(if (braceDepth > 0) "|" else ",")
                    index = next
                }

                '[' -> {
                    // Copy the class verbatim; an unterminated one is a broken pattern.
                    val close = pattern.indexOf(']', next)
                    if (close < 0 || close == next) return null
                    output.append('[').append(pattern, next, close).append(']')
                    index = close + 1
                }

                else -> {
                    output.append(if (character in globEscaped) "\\$character" else character.toString())
                    index = next
                }
            }
        }
        if (braceDepth != 0) return null
        return "^$output\$"
    }

    /** Only the metacharacters that can actually reach here are escaped: the
     * switch above has already consumed `*`, `?`, `{`, `}`, `,` and `[`. */
    private val globEscaped = setOf('.', '+', '^', '$', '(', ')', '|', '\\', ']', '[')

    fun jsonObjects(array: JSONArray?): List<JSONObject> {
        if (array == null) return emptyList()
        return (0 until array.length()).mapNotNull { index -> array.optJSONObject(index) }
    }

    private val editSchema: JSONObject = JSONObject()
        .put("type", "object")
        .put("properties", JSONObject()
            .put("path", JSONObject().put("type", "string").put("description", "Relative path to the existing file."))
            .put("edits", JSONObject()
                .put("type", "array")
                .put("description", "Replacements applied in order, all or none.")
                .put("items", JSONObject()
                    .put("type", "object")
                    .put("properties", JSONObject()
                        .put("old_text", JSONObject().put("type", "string").put("description", "Exact text to replace, copied from read_file."))
                        .put("new_text", JSONObject().put("type", "string").put("description", "Replacement text. Empty deletes the match."))
                        .put("replace_all", JSONObject().put("type", "boolean").put("description", "Replace every occurrence instead of requiring one unique match."))
                    )
                    .put("required", JSONArray().put("old_text").put("new_text"))
                    .put("additionalProperties", false)
                )
            )
        )
        .put("required", JSONArray().put("path").put("edits"))
        .put("additionalProperties", false)

    private const val EDIT_DESCRIPTION =
        "Replace exact text inside an existing file, without rewriting the rest of it. Prefer this " +
            "over write_file for any edit to a file you have already read. Each old_text must match " +
            "the file byte for byte and appear exactly once unless replace_all is set; a match that " +
            "is not unique is refused rather than guessed at, so widen it with surrounding lines. " +
            "Creating a new file still needs write_file."

    private const val GLOB_DESCRIPTION =
        "Find files by name pattern inside the workspace and get back paths newest-first. Supports * " +
            "and ? within one path segment, ** across segments, and {a,b} groups — so \"**/*.swift\", " +
            "\"Sources/**/*Test*.swift\", \"config.{json,yml}\". A pattern with no slash matches " +
            "filenames at any depth. Use search_files instead when the content, not the name, is what " +
            "you are looking for."

    fun mayDeleteFiles(command: String?): Boolean = command?.contains(Regex("(?i)(^|[\\s;&|])(rm|unlink|rmdir|del|erase|Remove-Item|git\\s+clean)([\\s]|$)")) == true

    fun isTestCommand(command: String?): Boolean = command?.contains(Regex("(?i)(^|[\\s;&|])(dotnet\\s+test|npm\\s+(run\\s+)?test|pnpm\\s+(run\\s+)?test|yarn\\s+test|pytest|swift\\s+test|gradle(w)?\\s+.*test|cargo\\s+test)([\\s;&|]|$)")) == true

    private val remoteHeavyPattern = Regex("(?i)(^|[\\s;&|])(npm|yarn|pnpm|swift|dotnet|cargo|pytest|gradle|xcodebuild|make|cmake|bundle|pod|fastlane)(\\s|$)")

    private fun shouldTryRemote(command: String): Boolean = remoteHeavyPattern.containsMatchIn(command)

    private suspend fun runRemote(command: String, remote: RemoteClient): String? {
        return try {
            val response = remote.command("run_command", mapOf("command" to command))
            if (response.status == "approval-required") {
                return "Remote desktop needs approval. Approve the command in desktop Access Mode before continuing."
            }
            if (response.status == "failed" || response.status == "offline") return null
            val result = response.result?.let { runCatching { JSONObject(it) }.getOrNull() }
            val artifactId = result?.optString("artifactId").orEmpty()
            if (artifactId.isNotBlank()) {
                runCatching { remote.artifactText(artifactId) }.getOrNull()
                    ?.takeIf { it.isNotBlank() }?.let { return it }
            }
            result?.optString("outputPreview")?.takeIf { it.isNotBlank() }
                ?: result?.optString("output")?.takeIf { it.isNotBlank() }
                ?: response.result?.takeIf { it.isNotBlank() }
        } catch (_: Throwable) {
            null
        }
    }

    private fun removeFile(root: File, path: String, reason: String, referenceTerms: String): String {
        val terms = referenceTerms.split(',', ';', '\n', '\r').map { it.trim() }.filter { it.isNotEmpty() }
        if (reason.isBlank() || terms.isEmpty() || terms.size > 20 || terms.any { it.length > 200 }) return "$PRESERVED_MARKER Removal needs a reason and bounded reference terms."
        return try {
            val base = root.canonicalFile
            require(!hasSymlinkComponent(base, path)) { "symlink" }
            val target = resolve(root, path)
            require(target.isFile && !Files.isSymbolicLink(target.toPath())) { "not a regular file" }
            val name = target.name.lowercase()
            val extension = target.extension.lowercase()
            require(name != "provider-state.json" && name != "conversations.json" && name != "state.sqlite" && protectedFragments.none { name.contains(it) } && extension !in protectedExtensions) { "protected" }
            require(extension in allowedExtensions) { "unsupported artifact" }
            val current = snapshot(root)
            require(current.size <= 5_000) { "workspace too large" }
            val targetPath = target.relativeTo(base).invariantSeparatorsPath
            for ((candidatePath, _) in current) {
                if (candidatePath == targetPath || File(candidatePath).extension.lowercase() !in allowedExtensions) continue
                val text = resolve(root, candidatePath).readText()
                if (terms.any { text.contains(it, ignoreCase = true) }) return "$PRESERVED_MARKER A live reference was found; the old artifact was kept."
            }
            try {
                require(target.delete() && !target.exists()) { "delete verification" }
            } catch (t: Throwable) {
                return "$FAILED_MARKER The artifact could not be removed: ${t.message ?: "delete failed"}"
            }
            "$VERIFIED_MARKER Removed proven-unused artifact $path."
        } catch (_: Throwable) {
            "$PRESERVED_MARKER Cleanup could not be verified; the artifact was kept."
        }
    }

    private fun hasSymlinkComponent(base: File, path: String): Boolean {
        val basePath = base.absoluteFile.path
        var current = File(base, path).absoluteFile
        while (true) {
            if (Files.isSymbolicLink(current.toPath())) return true
            if (current.path == basePath) return false
            val parent = current.parentFile ?: return true
            if (parent.path == current.path) return true
            current = parent
        }
    }

    private fun safeFiles(root: File): List<File> {
        val base = root.canonicalFile
        require(base.isDirectory) { "The workspace could not be enumerated." }
        val result = mutableListOf<File>()
        fun visit(directory: File) {
            val entries = directory.listFiles() ?: error("The workspace could not be enumerated.")
            entries.sortedBy { it.name }.forEach { file ->
                if (Files.isSymbolicLink(file.toPath())) return@forEach
                if (file.isDirectory) {
                    if (file.name == ".mem" || file.name.startsWith(".mem.") || file.name in ignoredDirectories) return@forEach
                    visit(file)
                } else if (file.isFile) {
                    result += file
                }
            }
        }
        visit(base)
        return result
    }

    internal fun sha256(bytes: ByteArray): String = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it.toInt() and 0xff) }

    fun schema(properties: Map<String, String>, required: List<String> = emptyList()): JSONObject {
        val fields = JSONObject()
        properties.forEach { (name, description) -> fields.put(name, JSONObject().put("type", "string").put("description", description)) }
        return JSONObject().put("type", "object").put("properties", fields).put("required", org.json.JSONArray(required))
    }

    /// Mirrors the desktop `ComputerUseTools` schema so the model passes the
    /// same arguments it would on a laptop; the relay forwards them untouched.
    private val computerUseSchema: JSONObject = run {
        val actions = org.json.JSONArray()
        listOf(
            "screenshot", "mouse_move", "left_click", "right_click", "middle_click", "double_click",
            "triple_click", "mouse_down", "mouse_up", "type", "key", "scroll",
        ).forEach { actions.put(it) }
        val buttons = org.json.JSONArray()
        listOf("left", "right", "middle").forEach { buttons.put(it) }
        val properties = JSONObject()
            .put("action", JSONObject().put("type", "string").put("enum", actions).put("description", "Action to perform on the paired desktop."))
            .put("x", JSONObject().put("type", "integer").put("description", "X screen coordinate for mouse actions."))
            .put("y", JSONObject().put("type", "integer").put("description", "Y screen coordinate for mouse actions."))
            .put("dx", JSONObject().put("type", "integer").put("description", "Horizontal scroll amount for the scroll action."))
            .put("dy", JSONObject().put("type", "integer").put("description", "Vertical scroll amount for the scroll action."))
            .put("button", JSONObject().put("type", "string").put("enum", buttons).put("description", "Mouse button for mouse_down and mouse_up."))
            .put("text", JSONObject().put("type", "string").put("description", "Text to type for the type action."))
            .put("key", JSONObject().put("type", "string").put("description", "Key combination (for example cmd+shift+s) for the key action."))
            .put("path", JSONObject().put("type", "string").put("description", "Destination path for screenshot, relative to the desktop workspace."))
        val required = org.json.JSONArray()
        required.put("action")
        JSONObject().put("type", "object").put("properties", properties).put("required", required)
    }

    private val nativeBrowserSchema: JSONObject = run {
        val actions = JSONArray().apply {
            listOf("open", "navigate", "get_content", "screenshot", "evaluate_js", "click", "type", "reload", "back", "forward").forEach(::put)
        }
        val properties = JSONObject()
            .put("action", JSONObject().put("type", "string").put("enum", actions).put("description", "Action to perform in the paired desktop browser."))
            .put("url", JSONObject().put("type", "string").put("description", "URL to open or navigate to."))
            .put("path", JSONObject().put("type", "string").put("description", "Optional screenshot path relative to the selected desktop project."))
            .put("script", JSONObject().put("type", "string").put("description", "JavaScript to evaluate in the desktop browser."))
            .put("selector", JSONObject().put("type", "string").put("description", "CSS selector for click or type."))
            .put("text", JSONObject().put("type", "string").put("description", "Text to type into the selected element."))
            .put("x", JSONObject().put("type", "integer").put("description", "Optional click coordinate."))
            .put("y", JSONObject().put("type", "integer").put("description", "Optional click coordinate."))
        JSONObject().put("type", "object").put("properties", properties).put("required", JSONArray().put("action"))
    }
}

fun JSONObject.required(key: String, tool: String): String {
    val value = optString(key)
    require(value.isNotBlank()) { "$tool needs a $key." }
    return value
}

enum class ReadState { FRESH, STALE, UNREAD }

/**
 * Which files the model has been shown, and the bytes it was shown.
 *
 * An edit names text to replace, so it is only honest when those bytes are the
 * ones behind the model's answer: a file that was never read, or that moved since,
 * would be matched blind. [com.dots.herness.mobile.read_file] and
 * [com.dots.herness.mobile.write_file] feed this, [AgentTools.edit] consults it.
 * The phone runs one conversation at a time, so the ledger is per app rather than
 * per conversation.
 */
class ReadLedger {
    private val hashes = ConcurrentHashMap<String, String>()
    private data class PageRead(val hash: String, val ranges: List<IntRange>)
    private val pages = mutableMapOf<String, PageRead>()

    /**
     * Set around a subagent's tool calls with `scope.asContextElement(...)`, which
     * carries it across dispatchers. A file the subagent read is not one the
     * conversation saw, and the other way round, so each keeps its own entries and
     * neither can edit a file on the strength of the other's read.
     */
    val scope = ThreadLocal<String?>()

    @Synchronized fun state(file: File, current: ByteArray): ReadState {
        val recorded = hashes[key(file)] ?: return ReadState.UNREAD
        return if (recorded == AgentTools.sha256(current)) ReadState.FRESH else ReadState.STALE
    }

    @Synchronized fun recordLines(file: File, bytes: ByteArray, start: Int, end: Int, totalLines: Int) {
        if (end <= start) return
        val path = key(file)
        val hash = AgentTools.sha256(bytes)
        if (hashes[path] == hash) return
        if (hashes.size + pages.size >= MAX_TRACKED_FILES && !hashes.containsKey(path) && !pages.containsKey(path)) reset()
        hashes.remove(path)
        val ranges = (pages[path]?.takeIf { it.hash == hash }?.ranges.orEmpty() + listOf(start until end)).sortedBy { it.first }
        val merged = mutableListOf<IntRange>()
        for (range in ranges) {
            if (merged.isNotEmpty() && range.first <= merged.last().last + 1)
                merged[merged.lastIndex] = merged.last().first..maxOf(merged.last().last, range.last)
            else merged += range
        }
        if (merged.size == 1 && merged[0].first == 1 && merged[0].last >= totalLines) {
            hashes[path] = hash
            pages.remove(path)
        } else pages[path] = PageRead(hash, merged)
    }

    @Synchronized fun record(file: File, bytes: ByteArray) {
        val path = key(file)
        if (hashes.size + pages.size >= MAX_TRACKED_FILES && !hashes.containsKey(path) && !pages.containsKey(path)) reset()
        hashes[path] = AgentTools.sha256(bytes)
        pages.remove(path)
    }

    @Synchronized fun reset() { hashes.clear(); pages.clear() }

    private fun key(file: File): String =
        (scope.get()?.let { "$it\n" } ?: "") + runCatching { file.canonicalFile.path }.getOrDefault(file.absolutePath)

    private companion object {
        /** A run that has read this many files has lost the thread anyway; the
         * ledger restarts rather than growing for the life of the process. */
        const val MAX_TRACKED_FILES = 512
    }
}

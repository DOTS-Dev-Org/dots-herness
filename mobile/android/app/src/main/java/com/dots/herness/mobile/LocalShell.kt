package com.dots.herness.mobile

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import java.security.MessageDigest

/**
 * A deliberately constrained terminal. Android can spawn processes, but a
 * mobile Harness must not expose an arbitrary shell or a build toolchain.
 */
class LocalShell(private val root: () -> File) {
    var lines by mutableStateOf<List<String>>(emptyList()); private set
    var directory by mutableStateOf(""); private set

    val prompt get() = "/$directory"

    suspend fun run(line: String): String {
        append("$prompt $line")
        val output = execute(line)
        if (output.isNotBlank()) append(output)
        return output
    }

    suspend fun execute(line: String): String = withContext(Dispatchers.IO) {
        val trimmed = line.trim()
        if (trimmed.isEmpty()) return@withContext ""
        if (trimmed == "clear") {
            lines = emptyList()
            return@withContext ""
        }
        if (trimmed.contains("|") || trimmed.contains(">") || trimmed.contains("&&") || trimmed.contains(";")) {
            return@withContext unsupported(trimmed.substringBefore(' ').ifBlank { trimmed })
        }

        val arguments = tokenize(trimmed)
        val name = arguments.firstOrNull() ?: return@withContext ""
        val values = arguments.drop(1)
        try {
            when (name) {
                "help" -> commands.joinToString(" ") + "\nThis is the mobile runtime. Native build tools and arbitrary processes are unavailable."
                "pwd" -> "/$directory"
                "cd" -> changeDirectory(values.firstOrNull().orEmpty())
                "ls" -> list(values)
                "cat" -> values.map { read(it) }.joinToString("")
                "head" -> slice(values, fromEnd = false)
                "tail" -> slice(values, fromEnd = true)
                "echo" -> values.joinToString(" ")
                "mkdir" -> {
                    values.forEach { AgentTools.resolve(root(), resolvePath(it)).mkdirs() }
                    ""
                }
                "touch" -> {
                    values.forEach {
                        val file = AgentTools.resolve(root(), resolvePath(it))
                        if (!file.exists()) {
                            file.parentFile?.mkdirs()
                            file.writeBytes(ByteArray(0))
                        }
                    }
                    ""
                }
                "rm" -> remove(values)
                "find" -> AgentTools.walk(root()).filter { values.firstOrNull()?.let { prefix -> it.startsWith(resolvePath(prefix)) } ?: true }.take(500).joinToString("\n")
                "grep" -> grep(values)
                "sha256" -> values.joinToString("\n") { file ->
                    val digest = MessageDigest.getInstance("SHA-256").digest(AgentTools.resolve(root(), resolvePath(file)).readBytes())
                        .joinToString("") { byte -> "%02x".format(byte.toInt() and 0xff) }
                    "$digest  $file"
                }
                "sqlite" -> {
                    require(values.size >= 2) { "sqlite: needs a database path and statement" }
                    LocalSql.run(AgentTools.resolve(root(), resolvePath(values.first())), values.drop(1).joinToString(" "))
                }
                "git" -> unsupported("git")
                else -> unsupported(name)
            }
        } catch (t: Throwable) {
            t.message ?: "$name failed."
        }
    }

    private fun changeDirectory(path: String): String {
        val target = resolvePath(path)
        val file = AgentTools.resolve(root(), target)
        require(file.isDirectory) { "cd: $path: no such directory" }
        directory = target
        return ""
    }

    private fun list(arguments: List<String>): String {
        val all = arguments.contains("-a")
        val path = arguments.firstOrNull { !it.startsWith("-") }?.let(::resolvePath) ?: directory
        val directoryFile = AgentTools.resolve(root(), path)
        require(directoryFile.isDirectory) { "ls: $path: not a directory" }
        return directoryFile.listFiles().orEmpty()
            .filter { all || !it.name.startsWith(".") }
            .filterNot { it.name == ".mem" }
            .sortedBy { it.name }
            .joinToString("\n") { if (it.isDirectory) it.name + "/" else it.name }
    }

    private fun read(path: String): String {
        val file = AgentTools.resolve(root(), resolvePath(path))
        val text = file.readText()
        return if (text.endsWith("\n")) text else "$text\n"
    }

    private fun slice(arguments: List<String>, fromEnd: Boolean): String {
        require(arguments.isNotEmpty()) { "head/tail: needs a file" }
        val option = arguments.firstOrNull()
        val count = option?.removePrefix("-n")?.toIntOrNull() ?: 10
        val path = if (option?.startsWith("-n") == true) arguments.getOrNull(1) else option
        require(path != null) { "head/tail: needs a file" }
        val lines = read(path).lineSequence().toList()
        return (if (fromEnd) lines.takeLast(count) else lines.take(count)).joinToString("\n")
    }

    private fun remove(arguments: List<String>): String {
        require(arguments.isNotEmpty()) { "rm: needs a file" }
        arguments.filterNot { it == "-f" }.forEach {
            val file = AgentTools.resolve(root(), resolvePath(it))
            require(file != root().canonicalFile) { "rm: refusing to remove the workspace root" }
            require(!file.isDirectory || file.listFiles().isNullOrEmpty()) { "rm: directories must be empty" }
            require(file.delete()) { "rm: could not remove $it" }
        }
        return ""
    }

    private fun grep(arguments: List<String>): String {
        require(arguments.isNotEmpty()) { "grep: needs a pattern" }
        val pattern = Regex(arguments.first())
        val paths = arguments.drop(1).ifEmpty { AgentTools.walk(root()) }
        return paths.flatMap { path ->
            val file = AgentTools.resolve(root(), resolvePath(path))
            if (!file.isFile) emptyList() else file.readLines().mapIndexedNotNull { index, line ->
                if (pattern.containsMatchIn(line)) path + ":" + (index + 1) + ": " + line else null
            }
        }.take(200).joinToString("\n").ifBlank { "No matches." }
    }

    private fun resolvePath(path: String): String {
        if (path.isBlank()) return directory
        val parts = if (path.startsWith("/")) mutableListOf() else directory.split("/").filter(String::isNotBlank).toMutableList()
        path.split("/").forEach { part ->
            when (part) {
                "", "." -> Unit
                ".." -> if (parts.isNotEmpty()) parts.removeAt(parts.lastIndex)
                else -> parts += part
            }
        }
        return parts.joinToString("/")
    }

    private fun tokenize(line: String): List<String> =
        Regex("""[^\s"']+|"[^"]*"|'[^']*'""").findAll(line).map { it.value.trim('"', '\'') }.toList()

    private fun unsupported(command: String): String =
        "unsupported_on_mobile: '$command' is not available in the mobile runtime; use Files, Git controls, or a supported virtual command."

    private fun append(text: String) {
        lines = (lines + text).takeLast(MAXIMUM_LINES)
    }

    companion object {
        val commands = listOf("cd", "pwd", "ls", "cat", "head", "tail", "echo", "mkdir", "rm", "touch", "grep", "find", "sha256", "sqlite", "git", "clear", "help")
        private const val MAXIMUM_LINES = 2_000
    }
}

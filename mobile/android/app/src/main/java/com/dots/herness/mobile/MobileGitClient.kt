package com.dots.herness.mobile

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File

data class MobileGitResult(val code: Int, val output: String) {
    val succeeded get() = code == 0
    val unavailable get() = code == 2
}

private object NativeGit {
    private val loaded = runCatching { System.loadLibrary("herness_git") }.isSuccess

    @JvmStatic external fun availableNative(): Boolean
    @JvmStatic external fun executeNative(operation: String, repoPath: String, argument: String, second: String, token: String, authorName: String, authorEmail: String): String

    fun available(): Boolean = loaded && runCatching { availableNative() }.getOrDefault(false)
    fun execute(operation: String, repoPath: String, argument: String, second: String, token: String, authorName: String, authorEmail: String): MobileGitResult {
        if (!loaded) return MobileGitResult(2, "libgit2_not_linked")
        val raw = runCatching { executeNative(operation, repoPath, argument, second, token, authorName, authorEmail) }.getOrElse { "2:libgit2_not_linked" }
        val separator = raw.indexOf(':')
        return MobileGitResult(raw.substring(0, separator.coerceAtLeast(0)).toIntOrNull() ?: 1, raw.substring((separator + 1).coerceAtMost(raw.length)))
    }
}

/// Kotlin boundary over the C ABI. GitHub credentials are supplied in memory
/// for each operation and are never written to the repository configuration.
class MobileGitClient(private val root: () -> File, private val token: () -> String) {
    val available get() = NativeGit.available()

    suspend fun execute(operation: String, arguments: Map<String, String> = emptyMap()): MobileGitResult = withContext(Dispatchers.IO) {
        val workspace = root().canonicalFile
        val requestedPath = arguments["repoPath"]
        val repoPath = if (requestedPath == null) {
            workspace.path
        } else {
            val value = requestedPath
            val candidate = File(value).let { if (it.isAbsolute) it else File(workspace, value) }.canonicalFile
            if (candidate.path != workspace.path && !candidate.path.startsWith(workspace.path + File.separator)) {
                return@withContext MobileGitResult(1, "Git path is outside the workspace.")
            }
            candidate.path
        }
        NativeGit.execute(
            operation,
            repoPath,
            arguments["argument"].orEmpty(),
            arguments["second"].orEmpty(),
            token(),
            arguments["authorName"] ?: "HerNess Mobile",
            arguments["authorEmail"] ?: "mobile@herness.local",
        )
    }

    suspend fun clone(repositoryUrl: String, destination: File, branch: String) {
        val result = execute("clone", mapOf("repoPath" to destination.path, "argument" to repositoryUrl, "second" to branch))
        if (!result.succeeded) throw MobileGitException(result)
    }
}

class MobileGitException(private val result: MobileGitResult) : IllegalStateException(
    if (result.unavailable) "The native libgit2 backend is not linked in this build." else result.output.ifBlank { "The Git operation failed." }
)

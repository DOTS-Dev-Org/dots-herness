package com.dots.herness.mobile

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder
import java.util.Base64

data class GitHubFileChange(val path: String, val content: String)
data class GitHubRepository(val id: Long, val fullName: String, val defaultBranch: String) {
    val owner get() = fullName.substringBefore('/', "")
    val name get() = fullName.substringAfterLast('/', fullName)
}
data class GitHubBlob(val path: String, val sha: String, val size: Long, val mode: String)
data class GitHubTree(val commit: String, val blobs: List<GitHubBlob>, val truncated: Boolean)

/** Repository coordinates the phone remembers so a clone can be pushed back later. */
data class RepoCoordinates(val owner: String = "", val repository: String = "", val branch: String = "main") {
    val complete get() = owner.isNotBlank() && repository.isNotBlank() && branch.isNotBlank()
    val slug get() = "$owner/$repository"

    companion object {
        /** Accepts `owner/repo`, an https clone URL, or an ssh remote. */
        fun parse(value: String, branch: String = "main"): RepoCoordinates? {
            val text = value.trim().removeSuffix(".git")
                .removePrefix("https://github.com/")
                .removePrefix("git@github.com:")
            val parts = text.split("/").filter { it.isNotBlank() }
            if (parts.size < 2) return null
            return RepoCoordinates(parts[parts.size - 2], parts[parts.size - 1], branch)
        }
    }
}

class GitHubClient(private val token: String) {
    suspend fun repositories(): List<GitHubRepository> = withContext(Dispatchers.IO) {
        val array = JSONArray(String(request("GET", "/user/repos?per_page=100&sort=updated")))
        (0 until array.length()).mapNotNull { index ->
            val item = array.optJSONObject(index) ?: return@mapNotNull null
            val fullName = item.optString("full_name")
            if (fullName.isBlank()) null else GitHubRepository(item.optLong("id"), fullName, item.optString("default_branch", "main"))
        }
    }

    suspend fun branches(owner: String, repository: String): List<String> = withContext(Dispatchers.IO) {
        val array = JSONArray(String(request("GET", "/repos/$owner/$repository/branches?per_page=100")))
        (0 until array.length()).mapNotNull { array.optJSONObject(it)?.optString("name")?.takeIf(String::isNotBlank) }
    }

    suspend fun tree(owner: String, repository: String, branch: String): List<String> = withContext(Dispatchers.IO) {
        val ref = request("GET", "/repos/$owner/$repository/git/ref/heads/${encode(branch)}")
        val commitSha = JSONObject(String(ref)).getJSONObject("object").getString("sha")
        val tree = JSONObject(String(request("GET", "/repos/$owner/$repository/git/trees/$commitSha?recursive=1")))
        val entries = tree.optJSONArray("tree") ?: JSONArray()
        (0 until entries.length()).mapNotNull { entries.optJSONObject(it)?.takeIf { item -> item.optString("type") == "blob" }?.optString("path") }
    }

    suspend fun read(owner: String, repository: String, path: String, reference: String): String = withContext(Dispatchers.IO) {
        val data = request("GET", "/repos/$owner/$repository/contents/${encode(path)}?ref=${encode(reference)}")
        val encoded = JSONObject(String(data)).optString("content").replace("\n", "")
        String(Base64.getDecoder().decode(encoded), Charsets.UTF_8)
    }

    suspend fun commitAndOpenPullRequest(
        owner: String,
        repository: String,
        base: String,
        branch: String,
        message: String,
        changes: List<GitHubFileChange>,
        title: String,
        body: String
    ): String = withContext(Dispatchers.IO) {
        require(changes.isNotEmpty()) { "There are no changes to commit." }
        val baseRef = JSONObject(String(request("GET", "/repos/$owner/$repository/git/ref/heads/${encode(base)}")))
        val baseSha = baseRef.getJSONObject("object").getString("sha")
        val baseCommit = JSONObject(String(request("GET", "/repos/$owner/$repository/git/commits/$baseSha")))
        val treeRequest = JSONObject().put("base_tree", baseCommit.getJSONObject("tree").getString("sha"))
        val entries = JSONArray()
        changes.forEach { change -> entries.put(JSONObject().put("path", change.path).put("mode", "100644").put("type", "blob").put("content", change.content)) }
        treeRequest.put("tree", entries)
        val treeSha = JSONObject(String(request("POST", "/repos/$owner/$repository/git/trees", treeRequest))).getString("sha")
        val commitSha = JSONObject(String(request("POST", "/repos/$owner/$repository/git/commits", JSONObject().put("message", message).put("tree", treeSha).put("parents", JSONArray().put(baseSha))))).getString("sha")
        request("POST", "/repos/$owner/$repository/git/refs", JSONObject().put("ref", "refs/heads/$branch").put("sha", commitSha))
        val pull = JSONObject(String(request("POST", "/repos/$owner/$repository/pulls", JSONObject().put("title", title).put("head", branch).put("base", base).put("body", body))))
        pull.getString("html_url")
    }

    /** Full recursive tree plus the commit it came from, so a clone can be recorded as a snapshot. */
    suspend fun fullTree(owner: String, repository: String, branch: String): GitHubTree = withContext(Dispatchers.IO) {
        val ref = JSONObject(String(request("GET", "/repos/$owner/$repository/git/ref/heads/${encode(branch)}")))
        val commit = ref.getJSONObject("object").getString("sha")
        val root = JSONObject(String(request("GET", "/repos/$owner/$repository/git/trees/$commit?recursive=1")))
        val entries = root.optJSONArray("tree") ?: JSONArray()
        val blobs = (0 until entries.length()).mapNotNull { index ->
            val item = entries.optJSONObject(index) ?: return@mapNotNull null
            if (item.optString("type") != "blob") return@mapNotNull null
            GitHubBlob(item.optString("path"), item.optString("sha"), item.optLong("size"), item.optString("mode", "100644"))
        }
        GitHubTree(commit, blobs, root.optBoolean("truncated"))
    }

    suspend fun blob(owner: String, repository: String, sha: String): ByteArray = withContext(Dispatchers.IO) {
        val encoded = JSONObject(String(request("GET", "/repos/$owner/$repository/git/blobs/$sha"))).optString("content").replace("\n", "")
        Base64.getDecoder().decode(encoded)
    }

    suspend fun defaultBranch(owner: String, repository: String): String = withContext(Dispatchers.IO) {
        JSONObject(String(request("GET", "/repos/$owner/$repository"))).optString("default_branch", "main")
    }

    private fun request(method: String, path: String, body: JSONObject? = null): ByteArray {
        val connection = (URL("https://api.github.com$path").openConnection() as HttpURLConnection).apply {
            requestMethod = method
            connectTimeout = 10_000
            readTimeout = 30_000
            setRequestProperty("Authorization", "Bearer $token")
            setRequestProperty("Accept", "application/vnd.github+json")
            setRequestProperty("X-GitHub-Api-Version", "2022-11-28")
            if (body != null) {
                doOutput = true
                setRequestProperty("Content-Type", "application/json")
                outputStream.use { it.write(body.toString().toByteArray()) }
            }
        }
        val status = connection.responseCode
        val bytes = (if (status in 200..299) connection.inputStream else connection.errorStream)?.use { it.readBytes() } ?: ByteArray(0)
        if (status !in 200..299) error(String(bytes, Charsets.UTF_8).ifBlank { "GitHub request failed ($status)." })
        return bytes
    }

    private fun encode(value: String) = URLEncoder.encode(value, "UTF-8").replace("+", "%20")
}

class PagesDeployClient(private val accountId: String, private val apiToken: String) {
    suspend fun deploy(project: String, files: Map<String, ByteArray>): String = withContext(Dispatchers.IO) {
        require(files.isNotEmpty()) { "There are no static files to deploy." }
        val boundary = "HerNess-${System.currentTimeMillis()}"
        val body = ByteArrayOutputStream()
        files.forEach { (path, content) ->
            body.write("--$boundary\r\n".toByteArray())
            body.write("Content-Disposition: form-data; name=\"files[$path]\"; filename=\"$path\"\r\n".toByteArray())
            body.write("Content-Type: application/octet-stream\r\n\r\n".toByteArray())
            body.write(content)
            body.write("\r\n".toByteArray())
        }
        body.write("--$boundary--\r\n".toByteArray())
        val connection = (URL("https://api.cloudflare.com/client/v4/accounts/$accountId/pages/projects/$project/deployments").openConnection() as HttpURLConnection).apply {
            requestMethod = "POST"
            connectTimeout = 10_000
            readTimeout = 60_000
            doOutput = true
            setRequestProperty("Authorization", "Bearer $apiToken")
            setRequestProperty("Content-Type", "multipart/form-data; boundary=$boundary")
            setFixedLengthStreamingMode(body.size())
            outputStream.use { it.write(body.toByteArray()) }
        }
        val status = connection.responseCode
        val bytes = (if (status in 200..299) connection.inputStream else connection.errorStream)?.use { it.readBytes() } ?: ByteArray(0)
        if (status !in 200..299) error(String(bytes, Charsets.UTF_8).ifBlank { "Cloudflare Pages deploy failed ($status)." })
        JSONObject(String(bytes)).getJSONObject("result").getString("url")
    }
}

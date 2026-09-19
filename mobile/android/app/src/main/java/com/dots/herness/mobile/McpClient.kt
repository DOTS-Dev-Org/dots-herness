package com.dots.herness.mobile

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.util.UUID

/**
 * MCP over streamable HTTP. Only HTTPS transports are accepted from a phone in
 * practice: a stdio server needs a child process and a binary to run, which an
 * installed app has no way to provide for arbitrary servers.
 */
/** The token is held in the keystore, never in this record or the servers file. */
data class McpServer(val id: String = UUID.randomUUID().toString(), val name: String, val url: String, val token: String = "")

class McpClient(private val server: McpServer) {
    private var sessionId: String? = null
    private var nextId = 0

    suspend fun listTools(): List<Triple<String, String, JSONObject>> {
        call("initialize", JSONObject()
            .put("protocolVersion", "2025-06-18")
            .put("capabilities", JSONObject())
            .put("clientInfo", JSONObject().put("name", "HerNess mobile").put("version", "1.0")))
        runCatching { notify("notifications/initialized") }
        val tools = call("tools/list", JSONObject()).optJSONArray("tools") ?: JSONArray()
        return (0 until tools.length()).mapNotNull { index ->
            val tool = tools.optJSONObject(index) ?: return@mapNotNull null
            val name = tool.optString("name").ifBlank { return@mapNotNull null }
            Triple(
                name,
                tool.optString("description").ifBlank { "MCP tool $name from ${server.name}." },
                tool.optJSONObject("inputSchema") ?: JSONObject().put("type", "object"),
            )
        }
    }

    suspend fun callTool(name: String, arguments: JSONObject): String {
        val result = call("tools/call", JSONObject().put("name", name).put("arguments", arguments))
        val content = result.optJSONArray("content") ?: JSONArray()
        val text = (0 until content.length()).mapNotNull { index ->
            val block = content.optJSONObject(index) ?: return@mapNotNull null
            when (block.optString("type")) {
                "text" -> block.optString("text")
                "resource" -> block.optJSONObject("resource")?.optString("text") ?: "[resource]"
                else -> "[${block.optString("type", "content")}]"
            }
        }.joinToString("\n")
        if (result.optBoolean("isError")) error(text.ifBlank { "The MCP tool reported an error." })
        return text.ifBlank { "The MCP tool returned no content." }
    }

    private suspend fun call(method: String, params: JSONObject): JSONObject {
        nextId += 1
        val body = JSONObject().put("jsonrpc", "2.0").put("id", nextId).put("method", method).put("params", params)
        val response = decode(send(body))
        response.optJSONObject("error")?.let { error(it.optString("message", "The MCP server reported an error.")) }
        return response.optJSONObject("result") ?: JSONObject()
    }

    private suspend fun notify(method: String) {
        send(JSONObject().put("jsonrpc", "2.0").put("method", method).put("params", JSONObject()))
    }

    private suspend fun send(body: JSONObject): String = withContext(Dispatchers.IO) {
        val parsed = runCatching { java.net.URI(server.url.trim()) }.getOrNull()
        check(parsed?.scheme?.lowercase() == "https" && !parsed.host.isNullOrBlank() && parsed.userInfo == null) { "HTTPS MCP endpoint required" }
        val connection = (URL(server.url).openConnection() as HttpURLConnection).apply {
            requestMethod = "POST"
            connectTimeout = 15_000
            readTimeout = 120_000
            doOutput = true
            setRequestProperty("Content-Type", "application/json")
            setRequestProperty("Accept", "application/json, text/event-stream")
            if (server.token.isNotBlank()) setRequestProperty("Authorization", "Bearer ${server.token}")
            sessionId?.let { setRequestProperty("Mcp-Session-Id", it) }
            outputStream.use { it.write(body.toString().toByteArray()) }
        }
        val status = connection.responseCode
        connection.getHeaderField("Mcp-Session-Id")?.let { sessionId = it }
        val text = (if (status in 200..299) connection.inputStream else connection.errorStream)?.use { String(it.readBytes()) } ?: ""
        if (status !in 200..299) error("${server.name}: $status $text")
        text
    }

    /** A streamable-HTTP server answers with plain JSON or an SSE stream whose last `data:` frame carries the response. */
    private fun decode(text: String): JSONObject {
        runCatching { return JSONObject(text) }
        text.lineSequence().filter { it.startsWith("data:") }.toList().reversed().forEach { line ->
            runCatching { return JSONObject(line.removePrefix("data:").trim()) }
        }
        error("${server.name} returned a response that is not JSON-RPC.")
    }
}

/** The servers the phone knows about, and the agent tools they expose. */
class McpRegistry(private val storage: File, private val secure: SecureStore) {
    var servers by mutableStateOf<List<McpServer>>(emptyList()); private set
    var status by mutableStateOf<Map<String, String>>(emptyMap()); private set

    init { load() }

    fun add(name: String, url: String, token: String) {
        val server = McpServer(name = name.ifBlank { url }, url = url)
        if (token.isNotBlank()) secure.write("mcp.${server.id}", token)
        servers = servers + server
        save()
    }

    fun remove(server: McpServer) {
        secure.delete("mcp.${server.id}")
        servers = servers.filterNot { it.id == server.id }
        status = status - server.id
        save()
    }

    /** Connects to every server and hands the discovered tools to the agent, namespaced by server. */
    suspend fun connectAll(agent: MobileAgent) {
        servers.forEach { server ->
            val client = McpClient(server.copy(token = secure.read("mcp.${server.id}").orEmpty()))
            try {
                val tools = client.listTools()
                agent.register(tools.map { (name, description, schema) ->
                    AgentToolSpec(toolName(server, name), description, schema) { input -> client.callTool(name, input) }
                })
                status = status + (server.id to "${tools.size} tool(s)")
            } catch (t: Throwable) {
                status = status + (server.id to (t.message ?: "Connection failed."))
            }
        }
    }

    private fun toolName(server: McpServer, tool: String) =
        "mcp__${server.name.lowercase().replace(Regex("[^a-z0-9_]"), "_")}__$tool"

    private fun save() {
        storage.parentFile?.mkdirs()
        storage.writeText(JSONArray(servers.map {
            JSONObject().put("id", it.id).put("name", it.name).put("url", it.url)
        }).toString())
    }

    private fun load() {
        if (!storage.exists()) return
        runCatching {
            val array = JSONArray(storage.readText())
            servers = (0 until array.length()).map { index ->
                val item = array.getJSONObject(index)
                McpServer(item.optString("id"), item.optString("name"), item.optString("url"))
            }
        }
    }
}

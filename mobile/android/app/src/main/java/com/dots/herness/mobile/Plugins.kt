package com.dots.herness.mobile

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import org.json.JSONObject
import org.mozilla.javascript.Context as RhinoContext
import org.mozilla.javascript.Function as RhinoFunction
import org.mozilla.javascript.NativeJSON
import org.mozilla.javascript.Scriptable
import org.mozilla.javascript.ScriptableObject
import java.io.File

/**
 * `runtime: js` plugins on the phone, mirroring the desktop's `JSPlugin`: a
 * sandboxed JS context with no filesystem, network, or timers — only the
 * `harness` bridge. Plugins live in the workspace under `.herness/plugins/<id>/`,
 * so cloning a repository brings its plugins with it.
 *
 * Rhino rather than a WebView: tool calls are synchronous, and a WebView would
 * mean bouncing every call through the main thread and an async callback.
 */
data class PluginManifest(val id: String, val name: String, val version: String, val main: String, val description: String)

class Plugins(private val root: () -> File) {
    var loaded by mutableStateOf<List<PluginManifest>>(emptyList()); private set
    var failures by mutableStateOf<Map<String, String>>(emptyMap()); private set
    var promptSections by mutableStateOf<List<String>>(emptyList()); private set
    var log by mutableStateOf<List<String>>(emptyList()); private set

    /** Reloads every plugin in the workspace and returns the tools they register. */
    fun reload(): List<AgentToolSpec> {
        loaded = emptyList()
        failures = emptyMap()
        promptSections = emptyList()
        val directory = File(root(), DIRECTORY)
        val entries = directory.listFiles()?.filter { it.isDirectory }?.sortedBy { it.name } ?: return emptyList()
        val specs = mutableListOf<AgentToolSpec>()
        entries.forEach { entry ->
            runCatching { specs += load(entry) }.onFailure { failures = failures + (entry.name to (it.message ?: "Plugin failed to load.")) }
        }
        return specs
    }

    private fun load(directory: File): List<AgentToolSpec> {
        val manifestJson = JSONObject(File(directory, "plugin.json").readText())
        val manifest = PluginManifest(
            manifestJson.getString("id"),
            manifestJson.optString("name", manifestJson.getString("id")),
            manifestJson.optString("version", "0.0.0"),
            manifestJson.optString("main", "plugin.js"),
            manifestJson.optString("description"),
        )
        val source = File(directory, manifest.main).readText()

        val context = RhinoContext.enter().apply {
            // Rhino cannot generate bytecode on Android; the interpreter is the only mode.
            optimizationLevel = -1
            languageVersion = RhinoContext.VERSION_ES6
        }
        val specs = mutableListOf<AgentToolSpec>()
        try {
            val scope = context.initSafeStandardObjects()
            val registered = mutableListOf<Triple<String, String, RhinoFunction>>()
            val bridge = context.newObject(scope)

            ScriptableObject.putProperty(bridge, "id", manifest.id)
            bridge.defineFunction("tool") { arguments ->
                val name = arguments.getOrNull(0)?.toString() ?: return@defineFunction null
                val description = arguments.getOrNull(1)?.toString().orEmpty()
                val function = arguments.getOrNull(3) as? RhinoFunction ?: return@defineFunction null
                registered += Triple(name, description, function)
                schemas[key(manifest, name)] = jsonOf(context, scope, arguments.getOrNull(2))
                null
            }
            bridge.defineFunction("prompt") { arguments ->
                arguments.getOrNull(0)?.toString()?.let { promptSections = promptSections + it }
                null
            }
            bridge.defineFunction("log") { arguments ->
                arguments.getOrNull(0)?.toString()?.let { log = (log + "${manifest.id}: $it").takeLast(500) }
                null
            }
            ScriptableObject.putProperty(scope, "harness", bridge)

            context.evaluateString(scope, source, manifest.main, 1, null)
            (ScriptableObject.getProperty(scope, "apply") as? RhinoFunction)?.call(context, scope, scope, arrayOf(bridge))

            registered.forEach { (name, description, function) ->
                val toolKey = key(manifest, name)
                functions[toolKey] = Registration(scope, function)
                specs += AgentToolSpec(
                    toolKey,
                    description.ifBlank { "$name from the ${manifest.name} plugin." },
                    schemas[toolKey] ?: JSONObject().put("type", "object"),
                ) { input -> invoke(toolKey, input) }
            }
            loaded = loaded + manifest
        } finally {
            RhinoContext.exit()
        }
        return specs
    }

    fun invoke(key: String, input: JSONObject): String {
        val registration = functions[key] ?: error("$key is not registered")
        val context = RhinoContext.enter().apply { optimizationLevel = -1; languageVersion = RhinoContext.VERSION_ES6 }
        try {
            val arguments = NativeJSON.parse(context, registration.scope, input.toString()) { _, _, _, value -> value }
            val result = registration.function.call(context, registration.scope, registration.scope, arrayOf(arguments))
            return if (result == null || result == RhinoContext.getUndefinedValue()) "" else RhinoContext.toString(result)
        } finally {
            RhinoContext.exit()
        }
    }

    private fun key(manifest: PluginManifest, tool: String) =
        "plugin__${manifest.id.replace(Regex("[^A-Za-z0-9_]"), "_")}__$tool"

    private fun jsonOf(context: RhinoContext, scope: Scriptable, value: Any?): JSONObject =
        runCatching { JSONObject(NativeJSON.stringify(context, scope, value, null, "").toString()) }
            .getOrElse { JSONObject().put("type", "object") }

    private data class Registration(val scope: Scriptable, val function: RhinoFunction)

    private val functions = mutableMapOf<String, Registration>()
    private val schemas = mutableMapOf<String, JSONObject>()

    companion object { const val DIRECTORY = ".herness/plugins" }
}

/** Small helper so the bridge reads like the Swift one rather than a Rhino ceremony. */
private fun Scriptable.defineFunction(name: String, body: (Array<out Any?>) -> Any?) {
    ScriptableObject.putProperty(this, name, object : org.mozilla.javascript.BaseFunction() {
        override fun call(context: RhinoContext, scope: Scriptable, thisObject: Scriptable, arguments: Array<out Any?>): Any? =
            body(arguments) ?: RhinoContext.getUndefinedValue()
    })
}

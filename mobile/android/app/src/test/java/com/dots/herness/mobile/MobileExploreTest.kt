package com.dots.herness.mobile

import kotlinx.coroutines.asContextElement
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/** The subagent's contract: only findings come back, and it can never mutate. */
class MobileExploreTest {
    private val catalog = listOf("read_file", "list_files", "grep_files", "edit_file", "write_file").map { name ->
        AgentToolSpec(name, name, JSONObject().put("type", "object").put("properties", JSONObject())) { "" }
    }
    private fun reply(text: String) = JSONObject().put("content", JSONArray().put(JSONObject().put("type", "text").put("text", text)))
    private fun call(name: String, input: JSONObject) = JSONObject().put("content", JSONArray().put(
        JSONObject().put("type", "tool_use").put("id", "d-${System.nanoTime()}").put("name", "discover_tools").put("input", JSONObject().put("query", name)))
        .put(JSONObject().put("type", "tool_use").put("id", "c-${System.nanoTime()}").put("name", "invoke_tool").put("input", JSONObject().put("name", name).put("arguments", input.toString()))))

    @Test
    fun `returns only the findings and names what was read`() = runBlocking {
        var step = 0
        val invoked = mutableListOf<String>()
        val result = MobileExplore.run("where is the loop", catalog = catalog, complete = { messages ->
            step += 1
            if (step == 1) call("read_file", JSONObject().put("path", "src/Loop.kt"))
            else {
                // The file body reached the subagent's own transcript, not the caller.
                assertTrue(messages.last().toString().contains("BODY"))
                reply("## Findings\n- src/Loop.kt:3 the loop\n\n## Unresolved\nNone\n\nStatus: answered")
            }
        }, invoke = { name, _ -> invoked += name; "BODY of the file" })

        assertEquals(listOf("read_file"), invoked)
        assertFalse(result.contains("BODY"))
        assertTrue(result.contains("Status: answered"))
        assertTrue(result.contains("Files read: src/Loop.kt"))
        assertFalse(result.contains("[Partial"))
    }

    @Test
    fun `refuses write tools and flags an unverified answer`() = runBlocking {
        var step = 0
        var invoked = 0
        val result = MobileExplore.run("change it", catalog = catalog, complete = { _ ->
            step += 1
            if (step == 1) call("write_file", JSONObject().put("path", "a").put("content", "b")) else reply("done")
        }, invoke = { _, _ -> invoked += 1; "" })

        assertEquals("a read-only subagent must never reach a mutating tool", 0, invoked)
        assertTrue(result.contains("[Partial"))
        assertTrue(result.contains("[Unverified"))
    }

    @Test
    fun `keeps a long answer in one request and wraps up at the step limit`() = runBlocking {
        val long = "b".repeat(MobileExplore.ANSWER_TARGET * 3)
        var requests = 0
        val kept = MobileExplore.run("map it", catalog = catalog, complete = { _ -> requests += 1; reply(long) }, invoke = { _, _ -> "" })
        assertEquals("a retry to shorten resends the whole transcript", 1, requests)
        assertTrue(kept.startsWith(long))

        var steps = 0
        val limited = MobileExplore.run("never ends", catalog = catalog, complete = { messages ->
            if (messages.last().toString().contains("step budget is spent")) reply("what was found\nStatus: partial")
            else { steps += 1; call("search_files", JSONObject().put("pattern", "x")) }
        }, invoke = { _, _ -> "hit" })
        assertEquals(MobileExplore.MAX_STEPS, steps)
        assertTrue(limited.contains("what was found"))
        assertTrue(limited.contains("step limit"))
    }

    @Test
    fun `empty task never calls a provider and the light model falls back`() = runBlocking {
        val result = MobileExplore.run("  ", catalog = catalog, complete = { _ -> error("no provider call") }, invoke = { _, _ -> "" })
        assertTrue(result.startsWith("Tool error"))
        assertEquals("claude-haiku-4-5", MobileExplore.lightModel(listOf("claude-sonnet-4-5", "claude-haiku-4-5"), "claude-sonnet-4-5"))
        assertEquals("gpt-5.6-luna", MobileExplore.lightModel(listOf("gpt-5.6-luna"), "gpt-5.6-luna"))
    }

    @Test
    fun `a subagent and the conversation never edit on each other's read`() = runBlocking {
        val root = File(System.getProperty("java.io.tmpdir"), "herness-explore-${System.nanoTime()}").apply { mkdirs() }
        val file = File(root, "a.txt").apply { writeText("x") }
        val tools = AgentTools.workspace(root = { root }).associateBy { it.name }
        val edit = JSONObject().put("path", "a.txt").put("edits", JSONArray().put(JSONObject().put("old_text", "x").put("new_text", "y")))
        val scope = AgentTools.reads.scope

        withContext(scope.asContextElement("explore")) { tools.getValue("read_file").run(JSONObject().put("path", "a.txt")) }
        assertEquals("a subagent's read is not the conversation's", ReadState.UNREAD, AgentTools.reads.state(file, file.readBytes()))
        tools.getValue("read_file").run(JSONObject().put("path", "a.txt"))
        assertTrue(withContext(scope.asContextElement("delegate-1")) { tools.getValue("edit_file").run(edit) }.startsWith("Tool error"))
        assertEquals("x", file.readText())

        // After its own read the subagent may edit, and the conversation's view goes stale.
        withContext(scope.asContextElement("delegate-1")) {
            tools.getValue("read_file").run(JSONObject().put("path", "a.txt"))
            assertTrue(tools.getValue("edit_file").run(edit).startsWith("Edited "))
        }
        assertEquals(ReadState.STALE, AgentTools.reads.state(file, file.readBytes()))
    }

    @Test
    fun `delegate writes only inside its assignment`() = runBlocking {
        assertEquals(listOf("ui/a.kt", "docs"), MobileDelegate.claims(listOf("./ui/../ui/a.kt", "ui/a.kt", "docs/")))
        assertEquals(null, MobileDelegate.claims(listOf("../outside.kt")))
        assertEquals(null, MobileDelegate.claims(listOf("/etc/hosts")))
        assertEquals(null, MobileDelegate.claims(emptyList()))
        assertFalse("a shared name prefix is not a shared directory", MobileDelegate.covers(listOf("ui"), "ui2/a.kt"))

        var step = 0
        val invoked = mutableListOf<String>()
        val result = MobileDelegate.run("update the ui", listOf("ui"), catalog = catalog, complete = { _ ->
            step += 1
            if (step == 1) JSONObject().put("content", JSONArray().also { blocks ->
                listOf(call("write_file", JSONObject().put("path", "ui/a.kt").put("content", "new")),
                    call("write_file", JSONObject().put("path", "ui/../b.kt").put("content", "stolen")),
                    call("run_command", JSONObject().put("command", "rm -rf ."))).forEach { response ->
                    val calls = response.getJSONArray("content")
                    for (index in 0 until calls.length()) blocks.put(calls.getJSONObject(index))
                }
            })
            else reply("## Changes\n- ui/a.kt: updated\n\nStatus: done")
        }, invoke = { name, input -> invoked += name + ":" + input.optString("path"); "Wrote 3 bytes to ui/a.kt." })

        assertEquals("nothing outside the assignment and no command may reach a tool", listOf("write_file:ui/a.kt"), invoked)
        assertTrue(result.contains("Files changed: ui/a.kt"))
        assertFalse(result.contains("[Partial"))
    }

    @Test
    fun `usage adds up a run's requests and cache reuse`() {
        val usage = SubagentUsage()
        usage.add(JSONObject().put("usage", JSONObject().put("input_tokens", 10).put("cache_read_input_tokens", 90).put("cache_creation_input_tokens", 0)), anthropic = true)
        usage.add(JSONObject().put("usage", JSONObject().put("input_tokens", 100).put("input_tokens_details", JSONObject().put("cached_tokens", 80))), anthropic = false)
        assertEquals(mapOf("requests" to "2", "inputTokens" to "200", "cachedTokens" to "170", "cacheWriteTokens" to "0"), usage.payload())
    }
}

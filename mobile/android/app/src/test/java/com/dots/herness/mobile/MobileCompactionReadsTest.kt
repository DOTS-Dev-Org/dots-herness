package com.dots.herness.mobile

import java.io.File
import kotlinx.coroutines.runBlocking
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/** Compaction drops read_file bodies, so the reads it drops must stop authorizing
 * edits and rewrites until the file is read again. */
class MobileCompactionReadsTest {
    private val root = File(System.getProperty("java.io.tmpdir"), "herness-compaction-${System.nanoTime()}").apply { mkdirs() }

    @Before
    fun clearLedger() = AgentTools.reads.reset()

    private fun text(role: String, value: String) = JSONObject().put("role", role)
        .put("content", JSONArray().put(JSONObject().put("type", "text").put("text", value)))

    private fun context(): List<JSONObject> {
        val body = "source line\n".repeat(20_000)
        val messages = mutableListOf<JSONObject>()
        for (turn in 0 until 4) {
            messages += text("user", "turn $turn")
            messages += JSONObject().put("role", "assistant").put("content", JSONArray().put(JSONObject()
                .put("type", "tool_use").put("id", "r$turn").put("name", "read_file")
                .put("input", JSONObject().put("path", "kept.txt"))))
            messages += JSONObject().put("role", "user").put("content", JSONArray().put(JSONObject()
                .put("type", "tool_result").put("tool_use_id", "r$turn").put("content", body)))
            messages += text("assistant", "done $turn")
        }
        return messages
    }

    @Test
    fun `compaction makes the agent read files again before editing them`() = runBlocking {
        val file = File(root, "kept.txt").apply { writeText("alpha\nbeta\n") }
        AgentTools.readFile(root, "kept.txt")
        assertEquals(ReadState.FRESH, AgentTools.reads.state(file, file.readBytes()))

        // No key and no ChatGPT session: the summary request fails before any network
        // call and compaction falls back to its local summary, like an offline device.
        val agent = MobileHarnessRuntime(apiKey = { "" }, systemPrompt = { "" })
        agent.provider = "gpt"
        agent.compactForTesting(context())

        assertTrue(agent.transcript.any { it.toolName == "context_compacted" })
        assertEquals(ReadState.UNREAD, AgentTools.reads.state(file, file.readBytes()))
        val refused = AgentTools.edit(root, "kept.txt", listOf(JSONObject().put("old_text", "alpha").put("new_text", "omega")))
        assertTrue(refused, refused.contains("has not been read"))
        assertEquals("alpha\nbeta\n", file.readText())

        AgentTools.readFile(root, "kept.txt")
        assertTrue(AgentTools.edit(root, "kept.txt", listOf(JSONObject().put("old_text", "alpha").put("new_text", "omega"))).startsWith("Edited"))
        assertEquals("omega\nbeta\n", file.readText())
    }
}

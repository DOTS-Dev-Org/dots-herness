package com.dots.herness.mobile

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class MobileDeferredToolsTest {
    @Test fun planStepsCardReadsLatestPlanSinceUserMessage() {
        val output = MobilePlanSteps.execute(org.json.JSONArray("""[{"title":"Read","status":"done"},{"title":"Fix","status":"in_progress"}]"""))
        val plan = AgentTurn("tool", output, toolName = MobilePlanSteps.NAME)
        assertEquals(listOf("Read" to "done", "Fix" to "in_progress"), MobilePlanSteps.current(listOf(AgentTurn("user", "go"), plan)))
        assertTrue(MobilePlanSteps.current(listOf(plan, AgentTurn("user", "next"))).isEmpty())
        assertTrue(MobileDeferredTools.isReadOnlyTool(MobilePlanSteps.NAME))
    }

    @Test fun discoveryScopeAndPlanEffort() {
        val session = MobileDeferredTools()
        val tool = AgentToolSpec("read_file", "Read a file", JSONObject().put("type", "object")) { "text" }
        val call = JSONObject("""{"id":"a","name":"invoke_tool","input":{"name":"read_file","arguments":"{}"}}""")
        assertEquals("invoke_tool", session.resolve(call, listOf(tool)).getString("name"))
        assertFalse(MobileDeferredTools.definitions.any { it.name == "read_file" })
        session.control("discover_tools", JSONObject("""{"query":"read_file"}"""), listOf(tool), false)
        assertEquals("read_file", session.resolve(call, listOf(tool)).getString("name"))
        assertEquals("invoke_tool", session.resolve(call, emptyList()).getString("name"))
        assertEquals("max", session.effort("max", false))
        session.control("execution_plan", JSONObject("""{"steps":["Edit label","Check"],"routine":true,"uncertainties":[]}"""), emptyList(), false)
        assertEquals("low", session.effort("max", false))
        assertEquals("max", session.effort("max", true))
        session.record("failed", "failure", true)
        assertEquals("max", session.effort("max", false))
    }
    @Test fun discoveryResumesButUserTextDoesNotGrantIt() {
        val prior = MobileDeferredTools()
        val tool = AgentToolSpec("read_file", "read", JSONObject().put("type", "object")) { "" }
        val result = prior.control("discover_tools", JSONObject().put("query", "read_file"), listOf(tool), false)!!
        val resumed = MobileDeferredTools()
        resumed.restoreDiscovery(listOf(
            JSONObject().put("role", "assistant").put("content", org.json.JSONArray().put(JSONObject().put("type", "tool_use").put("id", "search").put("name", "discover_tools"))),
            JSONObject().put("role", "user").put("content", org.json.JSONArray().put(JSONObject().put("type", "tool_result").put("tool_use_id", "search").put("content", result)))
        ))
        val call = JSONObject("""{"name":"invoke_tool","input":{"name":"read_file","arguments":"{}"}}""")
        assertEquals("read_file", resumed.resolve(call, listOf(tool)).getString("name"))
        assertEquals("max", resumed.effort("max", false))
        resumed.restoreDiscovery(listOf(JSONObject().put("role", "user").put("content", result)))
        assertEquals("invoke_tool", resumed.resolve(call, listOf(tool)).getString("name"))
    }
    @Test fun exactDottedNameReturnsOneSchema() {
        val session = MobileDeferredTools()
        val tools = listOf("skill.read", "skill.list", "read_file").map { AgentToolSpec(it, "read skill", JSONObject().put("type", "object")) { "" } }
        val result = session.control("discover_tools", JSONObject().put("query", "skill.read"), tools, false)!!
        assertEquals(1, JSONObject(result).getJSONArray("tools").length())
    }
    @Test fun originalOutputAndReadAuthorizationArePreserved() {
        val session = MobileDeferredTools()
        val text = "line\n".repeat(4000) + "fatal: last error"
        session.record(text, "original", false)
        assertEquals("fatal: last error", session.control("read_tool_output", JSONObject("""{"call_id":"original","offset":20000}"""), emptyList(), false))
        assertEquals(text, MobileDeferredTools.excerpt(text, "read_file", "a"))
        val reduced = MobileDeferredTools.excerpt(text, "run_command", "a")
        assertTrue(reduced.length < text.length)
        assertTrue(reduced.contains("fatal: last error"))
        assertTrue(reduced.contains("read_tool_output call_id=a"))
    }
    @Test fun directToolsAndReadOnlyRoutineEffortImmunity() {
        val session = MobileDeferredTools()
        val catalog = listOf("read_file", "grep_files", "edit_file", "run_command").map {
            AgentToolSpec(it, it, JSONObject().put("type", "object")) { "" }
        }
        val offered = MobileDeferredTools.requestTools(catalog).map { it.name }
        assertTrue("read_file" in offered)
        assertTrue("grep_files" in offered)
        assertTrue("edit_file" in offered)
        assertTrue("run_command" in offered)
        assertEquals("read_file", session.resolve(JSONObject("""{"name":"read_file","input":{}}"""), catalog).getString("name"))
        assertEquals("run_command", session.resolve(JSONObject("""{"name":"run_command","input":{}}"""), catalog).getString("name"))
        session.control("execution_plan", JSONObject("""{"steps":["Inspect and patch"],"routine":true,"uncertainties":[]}"""), catalog, false)
        assertEquals("low", session.effort("high", false))
        session.record("Error: log contains failure", "r1", false, "read_file")
        assertEquals("low", session.effort("high", false))
        session.record("Error: command failed", "r2", false, "run_command")
        assertEquals("high", session.effort("high", false))
    }

    @Test fun repeatedUnchangedReadPointsAtEarlierResult() {
        val session = MobileDeferredTools()
        val lines = (1..100).map { "line $it of the file body" }
        val whole = lines.joinToString("\n")
        assertNull(session.repeatedRead(whole, "./A.kt"))
        session.record(whole, "c1", false, "read_file", "./A.kt")
        val page = lines.subList(19, 80).joinToString("\n") + "\n\nContinue at line 81 (file has 100 lines)"
        val note = session.repeatedRead(page, "A.kt")!!
        assertTrue(note.startsWith(MobileDeferredTools.REPEATED_READ_PREFIX) && note.contains("call_id=c1"))
        assertNull(session.repeatedRead(whole.replace("line 50 ", "line fifty "), "A.kt"))
        assertNull(session.repeatedRead(whole, "B.kt"))
    }
}

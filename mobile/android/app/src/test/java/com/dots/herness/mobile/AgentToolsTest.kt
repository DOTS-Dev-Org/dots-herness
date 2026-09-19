package com.dots.herness.mobile

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * The path jail is the whole security story for the phone shell and the agent's
 * file tools: nothing may resolve outside the workspace root.
 */
class AgentToolsTest {
    private val root = File(System.getProperty("java.io.tmpdir"), "herness-test-${System.nanoTime()}").apply { mkdirs() }

    @Test
    fun `resolves paths inside the workspace`() {
        val target = AgentTools.resolve(root, "notes/todo.txt")
        assertTrue(target.path.startsWith(root.canonicalPath + File.separator))
    }

    @Test
    fun `refuses traversal outside the workspace`() {
        listOf("../escape.txt", "notes/../../escape.txt", "/etc/passwd/../../../../etc/passwd").forEach { path ->
            runCatching { AgentTools.resolve(root, path) }
                .onSuccess { resolved -> assertTrue("$path escaped to $resolved", resolved.path.startsWith(root.canonicalPath)) }
        }
    }

    @Test
    fun `walks only files`() {
        File(root, "a/b").mkdirs()
        File(root, "a/b/one.txt").writeText("one")
        File(root, "two.txt").writeText("two")
        assertEquals(listOf("a/b/one.txt", "two.txt"), AgentTools.walk(root))
    }
}

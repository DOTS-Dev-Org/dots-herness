package com.dots.herness.mobile

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.json.JSONObject
import kotlinx.coroutines.runBlocking
import java.io.File

/**
 * `edit_file` and `glob`: the rejection paths matter more than the success path,
 * because a wrong edit is silent data loss while a wrong rejection is only a
 * wasted turn.
 */
class FileEditToolsTest {
    private val root = File(System.getProperty("java.io.tmpdir"), "herness-edit-${System.nanoTime()}").apply { mkdirs() }

    @Before
    fun clearLedger() {
        // The read ledger is app-wide, so each run starts as a fresh conversation.
        AgentTools.reads.reset()
    }

    /** Seeds a file and, unless told otherwise, records the read `edit_file` expects. */
    private fun seed(path: String, text: String, read: Boolean = true): File {
        val file = File(root, path).apply { parentFile?.mkdirs() }
        file.writeText(text)
        if (read) AgentTools.reads.record(file, text.toByteArray())
        return file
    }

    private fun contents(path: String): String = File(root, path).readText()

    private fun edit(path: String, vararg edits: JSONObject) = AgentTools.edit(root, path, edits.toList())

    private fun replacement(oldText: String, newText: String, replaceAll: Boolean? = null): JSONObject =
        JSONObject().put("old_text", oldText).put("new_text", newText).also { if (replaceAll != null) it.put("replace_all", replaceAll) }

    @Test
    fun `paged project file can be edited and reread`() {
        val original = (1..240).joinToString("\n") { "line-$it:" + "x".repeat(1000) }
        val file = seed("project.swift", original, read = false)
        for (start in 1..240 step 20) {
            AgentTools.readFile(root, "project.swift", start, 20)
            if (start == 1) assertEquals(ReadState.UNREAD, AgentTools.reads.state(file, file.readBytes()))
            if (start == 1) assertTrue(edit("project.swift", replacement("line-180:", "fixed-180:")).contains("lines 180-180 of project.swift, which were not read"))
        }
        assertTrue(edit("project.swift", replacement("line-180:", "fixed-180:")).startsWith("Edited"))
        assertEquals(original.replace("line-180:", "fixed-180:"), file.readText())
        assertTrue(AgentTools.readFile(root, "project.swift", 180, 1).startsWith("fixed-180:"))
        assertEquals(ReadState.FRESH, AgentTools.reads.state(file, file.readBytes()))
    }

    @Test
    fun `a partial read allows edits inside it and carries the range over`() {
        val file = seed("long.txt", (1..600).joinToString("\n") { "line-$it" }, read = false)
        val page = AgentTools.readFile(root, "long.txt")
        assertTrue(page, page.endsWith("[truncated] Continue with offset: 251 (file has 600 lines)"))
        assertFalse(page.contains("line-251"))

        assertTrue(edit("long.txt", replacement("line-10\n", "line-10\nadded-a\nadded-b\n")).startsWith("Edited"))
        // The read range moved two lines down with the edit: line-250 still counts as
        // read, line-251 still does not.
        assertTrue(edit("long.txt", replacement("line-250\n", "line-250!\n")).startsWith("Edited"))
        assertTrue(edit("long.txt", replacement("line-251\n", "nope\n")).contains("which were not read"))
        assertFalse(file.readText().contains("nope"))
        // write_file still needs the whole file.
        assertEquals(ReadState.UNREAD, AgentTools.reads.state(file, file.readBytes()))
    }

    @Test
    fun `replace all on a partial read needs every occurrence read`() {
        seed("dup.txt", (1..400).joinToString("\n") { if (it == 5 || it == 300) "same" else "l$it" }, read = false)
        AgentTools.readFile(root, "dup.txt")
        val result = edit("dup.txt", replacement("same", "other", replaceAll = true))
        assertTrue(result, result.contains("lines 300-300"))
        assertFalse(contents("dup.txt").contains("other"))
    }

    @Test
    fun `pages from different file versions do not combine`() {
        val file = seed("pages.txt", "one\ntwo\nthree\nfour", read = false)
        AgentTools.readFile(root, "pages.txt", 1, 2)
        file.writeText("changed\ntwo\nthree\nfour")
        AgentTools.readFile(root, "pages.txt", 3)
        assertEquals(ReadState.UNREAD, AgentTools.reads.state(file, file.readBytes()))
        AgentTools.readFile(root, "pages.txt", 1, 2)
        assertEquals(ReadState.FRESH, AgentTools.reads.state(file, file.readBytes()))
    }

    @Test
    fun `write tool rejects unread and externally changed files`() = runBlocking {
        val file = seed("guard.txt", "original", read = false)
        val tool = AgentTools.workspace(root = { root }).first { it.name == "write_file" }
        val args = JSONObject().put("path", "guard.txt").put("content", "replacement")
        assertTrue(tool.run(args).contains("prior read_file"))
        assertEquals("original", file.readText())
        AgentTools.readFile(root, "guard.txt")
        file.writeText("external change")
        assertTrue(tool.run(args).contains("changed since"))
        assertEquals("external change", file.readText())
    }

    // MARK: - edit_file

    @Test
    fun `applies a unique match and leaves the rest of the file intact`() {
        seed("a.swift", "let one = 1\nlet two = 2\nlet three = 3\n")
        val result = edit("a.swift", replacement("let two = 2", "let two = 22"))
        assertTrue(result, result.startsWith("Edited a.swift"))
        assertEquals("let one = 1\nlet two = 22\nlet three = 3\n", contents("a.swift"))
    }

    @Test
    fun `applies several edits in order`() {
        seed("b.swift", "alpha\nbeta\n")
        val result = edit("b.swift", replacement("alpha", "ALPHA"), replacement("beta", "ALPHA\nomega"))
        assertTrue(result, result.contains("replaced 1 occurrence; replaced 1 occurrence"))
        assertEquals("ALPHA\nALPHA\nomega\n", contents("b.swift"))
    }

    @Test
    fun `an ambiguous match writes nothing`() {
        seed("c.swift", "same\nsame\nsame\n")
        val result = edit("c.swift", replacement("same", "other"))
        assertTrue(result, result.contains("matched 3 places"))
        assertTrue(result, result.contains("Nothing was written"))
        assertEquals("same\nsame\nsame\n", contents("c.swift"))
    }

    @Test
    fun `an ambiguous match names the candidate lines`() {
        seed("d.swift", "one\nmatch\nthree\nfour\nmatch\nsix\n")
        val result = edit("d.swift", replacement("match", "x"))
        assertTrue(result, result.contains("around lines 2, 5"))
    }

    @Test
    fun `replace all handles every occurrence`() {
        seed("e.swift", "foo foo bar\n")
        val result = edit("e.swift", replacement("foo", "baz", replaceAll = true))
        assertTrue(result, result.contains("replaced 2 occurrences"))
        assertEquals("baz baz bar\n", contents("e.swift"))
    }

    @Test
    fun `an empty new text deletes the match`() {
        seed("f.swift", "keep\ndrop\nkeep again\n")
        edit("f.swift", replacement("drop\n", ""))
        assertEquals("keep\nkeep again\n", contents("f.swift"))
    }

    @Test
    fun `a missing match writes nothing and says which edit`() {
        seed("g.swift", "hello\n")
        val result = edit("g.swift", replacement("goodbye", "hello there"))
        assertTrue(result, result.contains("edit 1 matched nothing"))
        assertTrue(result, result.contains("Nothing was written"))
        assertEquals("hello\n", contents("g.swift"))
    }

    @Test
    fun `an empty old text is rejected`() {
        seed("h.swift", "x\n")
        val result = edit("h.swift", replacement("", "y"))
        assertTrue(result, result.contains("edit 1 has an empty old_text"))
        assertTrue(result, result.contains("Nothing was written"))
        assertEquals("x\n", contents("h.swift"))
    }

    @Test
    fun `an edit missing either field is rejected`() {
        seed("m.swift", "x\n")
        val result = edit("m.swift", JSONObject().put("old_text", "x"))
        assertTrue(result, result.contains("needs both old_text and new_text"))
        assertEquals("x\n", contents("m.swift"))
    }

    @Test
    fun `one page authorizes an edit but never a whole file rewrite`() {
        val file = seed("part.txt", "one\ntwo\nthree\nfour", read = false)
        AgentTools.readFile(root, "part.txt", 2, 1)
        assertTrue(edit("part.txt", replacement("two", "2")).startsWith("Edited"))
        assertTrue(edit("part.txt", replacement("2", "zwei")).startsWith("Edited"))
        assertEquals(ReadState.UNREAD, AgentTools.reads.state(file, file.readBytes()))
        file.writeText("changed outside")
        assertTrue(edit("part.txt", replacement("changed", "bad")).contains("changed since it was read"))
    }

    @Test
    fun `an unread file cannot be edited`() {
        seed("i.swift", "value = 1\n", read = false)
        val result = edit("i.swift", replacement("value = 1", "value = 2"))
        assertTrue(result, result.contains("has not been read"))
        assertEquals("value = 1\n", contents("i.swift"))
    }

    @Test
    fun `a file changed after it was read is refused as stale`() {
        val file = seed("j.swift", "one\n")
        // An external write leaves the ledger holding the old hash.
        file.writeText("one\ntwo\n")
        val result = edit("j.swift", replacement("one", "1"))
        assertTrue(result, result.contains("changed since it was read"))
        assertEquals("one\ntwo\n", contents("j.swift"))
    }

    @Test
    fun `edit cannot create a file`() {
        val result = edit("new.swift", replacement("a", "b"))
        assertTrue(result, result.contains("does not exist"))
        assertTrue(result, result.contains("write_file creates a new file"))
        assertFalse(File(root, "new.swift").exists())
    }

    @Test
    fun `edits are bounded per call`() {
        seed("k.swift", "x\n")
        val flood = List(51) { replacement("x", "y") }
        assertTrue(AgentTools.edit(root, "k.swift", flood).contains("too many edits"))
    }

    @Test
    fun `an empty edit batch is rejected`() {
        seed("n.swift", "x\n")
        assertTrue(AgentTools.edit(root, "n.swift", emptyList()).contains("edits is empty"))
    }

    @Test
    fun `edit refuses paths outside the workspace`() {
        assertTrue(edit("../elsewhere.swift", replacement("a", "b")).contains("outside"))
    }

    @Test
    fun `a successful edit keeps the ledger fresh`() {
        seed("l.swift", "a1\n")
        edit("l.swift", replacement("a1", "a2"))
        val result = edit("l.swift", replacement("a2", "a3"))
        assertTrue(result, result.startsWith("Edited"))
        assertEquals("a3\n", contents("l.swift"))
    }

    @Test
    fun `overlapping text counts non-overlapping occurrences`() {
        // "aaa" with needle "aa" has one non-overlapping match, which is what the
        // replacement will actually consume.
        assertEquals(1, AgentTools.occurrencesOf("aa", "aaa").size)
        assertEquals(3, AgentTools.occurrencesOf("ab", "ababab").size)
    }

    // MARK: - glob pattern compilation

    private fun globPattern(pattern: String): String? = AgentTools.globPattern(pattern)

    private fun matches(pattern: String, path: String): Boolean = AgentTools.globRegex(pattern)?.matches(path) == true

    @Test
    fun `double star crosses directories and matches zero of them`() {
        assertNotNull(globPattern("**/*.swift"))
        assertTrue(matches("**/*.swift", "a.swift"))
        assertTrue(matches("**/*.swift", "Sources/App/Deep.swift"))
        assertFalse(matches("**/*.swift", "Sources/App/main.js"))
    }

    @Test
    fun `a single star stops at separators`() {
        assertTrue(matches("Sources/*.swift", "Sources/App.swift"))
        assertFalse(matches("Sources/*.swift", "Sources/Nested/App.swift"))
    }

    @Test
    fun `a question mark matches one character`() {
        assertTrue(matches("f?le.txt", "file.txt"))
        assertFalse(matches("f?le.txt", "fle.txt"))
    }

    @Test
    fun `brace groups alternate`() {
        assertTrue(matches("config.{json,yml}", "config.yml"))
        assertTrue(matches("config.{json,yml}", "config.json"))
        assertFalse(matches("config.{json,yml}", "config.toml"))
    }

    @Test
    fun `character classes work`() {
        assertTrue(matches("v[0-9].ts", "v3.ts"))
        assertFalse(matches("v[0-9].ts", "vx.ts"))
    }

    @Test
    fun `a dot is literal not a wildcard`() {
        assertFalse(matches("app.config.ts", "appXconfigXts"))
        assertTrue(matches("app.config.ts", "app.config.ts"))
    }

    @Test
    fun `broken patterns are rejected rather than matching everything`() {
        assertNull(globPattern("a{b"))
        assertNull(globPattern("a[b"))
        assertNull(globPattern("a}b"))
        assertNull(AgentTools.globRegex("a{b"))
    }

    // MARK: - glob against a real tree

    @Test
    fun `glob returns matches and a descriptive header`() {
        seed("Sources/Alpha.swift", "1")
        seed("Sources/Nested/Beta.swift", "2")
        seed("Sources/Gamma.js", "3")
        val output = AgentTools.glob(root, "**/*.swift", ".")
        assertTrue(output, output.contains("Sources/Alpha.swift"))
        assertTrue(output, output.contains("Sources/Nested/Beta.swift"))
        assertFalse(output, output.contains("Gamma.js"))
        assertTrue(output, output.startsWith("glob **/*.swift under ."))
    }

    @Test
    fun `a bare pattern reaches nested files`() {
        seed("Deep/Deeper/Needle.swift", "1")
        assertTrue(AgentTools.glob(root, "Needle.swift", ".").contains("Deep/Deeper/Needle.swift"))
    }

    @Test
    fun `glob skips build and dependency directories`() {
        seed("node_modules/left-pad/index.js", "1")
        seed("build/Generated.swift", "2")
        seed("Real.swift", "3")
        val output = AgentTools.glob(root, "**/*.swift", ".")
        assertTrue(output, output.contains("Real.swift"))
        assertFalse(output, output.contains("Generated.swift"))
        assertFalse(output, output.contains("node_modules"))
    }

    @Test
    fun `the newest file comes first`() {
        seed("old.swift", "1").setLastModified(System.currentTimeMillis() - 3_600_000L)
        seed("new.swift", "2")
        val lines = AgentTools.glob(root, "*.swift", ".").split("\n")
        assertEquals("new.swift", lines.getOrNull(1))
    }

    @Test
    fun `no match says so instead of returning an empty body`() {
        seed("only.swift", "1")
        assertTrue(AgentTools.glob(root, "**/*.kt", ".").contains("no files found"))
    }

    @Test
    fun `glob refuses patterns that leave the workspace`() {
        assertTrue(AgentTools.glob(root, "../**/*.swift", ".").contains("inside the workspace"))
        assertTrue(AgentTools.glob(root, "/etc/**", ".").contains("inside the workspace"))
        assertTrue(AgentTools.glob(root, "", ".").contains("pattern is required"))
    }

    @Test
    fun `glob refuses a file instead of a directory`() {
        seed("plain.txt", "1")
        assertTrue(AgentTools.glob(root, "*.txt", "plain.txt").contains("is not a directory"))
    }

    @Test
    fun `both tools are offered through the workspace list`() {
        val names = AgentTools.workspace(root = { root }).map { it.name }.toSet()
        assertTrue(names.contains("edit_file"))
        assertTrue(names.contains("glob"))
        assertFalse(names.contains("web_fetch"))
    }
}

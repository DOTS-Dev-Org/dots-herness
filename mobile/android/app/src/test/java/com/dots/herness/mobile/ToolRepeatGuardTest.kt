package com.dots.herness.mobile

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ToolRepeatGuardTest {
    @Test
    fun repeatIgnoresKeyOrder() {
        val guard = ToolRepeatGuard()
        val a = JSONObject("""{"path":"a.txt","offset":1}""")
        val b = JSONObject("""{ "offset": 1, "path": "a.txt" }""")
        assertEquals(ToolRepeatGuard.signature("read_file", a), ToolRepeatGuard.signature("read_file", b))
        assertFalse(guard.isRepeat("read_file", a))
        assertFalse(guard.isRepeat("read_file", b))
        assertFalse(guard.isRepeat("read_file", a))
        assertTrue(guard.isRepeat("read_file", b))
    }

    @Test
    fun editNoticeOnlyPastTheLimitPerFile() {
        val guard = ToolRepeatGuard()
        repeat(ToolRepeatGuard.MAX_EDITS_PER_FILE) { assertEquals("", guard.editNotice("edit_file", JSONObject().put("path", "a.txt").put("n", it))) }
        assertEquals("", guard.editNotice("edit_file", JSONObject().put("path", "b.txt")))
        assertTrue(guard.editNotice("write_file", JSONObject().put("path", "a.txt")).contains("Repeated edits"))
    }
}

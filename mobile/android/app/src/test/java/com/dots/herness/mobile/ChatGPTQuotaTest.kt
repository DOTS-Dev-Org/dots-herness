package com.dots.herness.mobile

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class ChatGPTQuotaTest {
    @Test
    fun newConversationTakesRoomiestAccount() {
        val ids = listOf("a", "b", "c")
        assertEquals("b", ChatGPTQuota.pick(ids, "a", mapOf("a" to 0.1, "b" to 0.8, "c" to 0.5)))
        // Unknown beats spent; the Settings pick breaks a tie.
        assertEquals("c", ChatGPTQuota.pick(ids, "c", mapOf("a" to 0.0)))
        assertEquals("a", ChatGPTQuota.pick(listOf("a"), "a", mapOf("a" to 0.0)))
        assertEquals("x", ChatGPTQuota.pick(emptyList(), "x", emptyMap()))
    }

    @Test
    fun usageTakesTighterWindow() {
        val left = ChatGPTQuota.remaining("""{"rate_limit":{"primary_window":{"used_percent":30},"secondary_window":{"used_percent":"75"}}}""")
        assertEquals(0.25, left!!, 0.0001)
        assertNull(ChatGPTQuota.remaining("{}"))
    }
}

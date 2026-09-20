package com.dots.herness.mobile

import org.junit.Assert.*
import org.junit.Test

class MobilePromptHistoryTest {
    @Test fun `new context retains previous turns and initial policy`() {
        var history = MobilePromptHistory()
        val first = history.capture("one", "policy one", "plugin one")
        val messages = mutableListOf(first, "tool result", "answer")
        val previous = messages.toList()
        history = MobilePromptHistory(history.policy)
        messages += history.capture("two", "policy two", "plugin two")
        assertEquals("policy one", history.policy)
        assertEquals(previous, messages.take(previous.size))
        assertTrue(messages.last().contains("policy two"))
        assertTrue(messages.last().contains("plugin two"))
        assertFalse(messages.last().contains("plugin one"))
    }

    @Test fun `empty context and reset start cleanly`() {
        var history = MobilePromptHistory()
        assertEquals("one", history.capture("one", "policy", ""))
        assertEquals("two", history.capture("two", "policy", ""))
        history = MobilePromptHistory()
        assertEquals("new", history.capture("new", "new policy", ""))
        assertEquals("new policy", history.policy)
    }

    @Test fun `prompt cache key is stable for same prefix and rotates for new segments`() {
        val fingerprint = "tool-fingerprint"
        val first = MobilePromptCache.key("conversation-1", "openai", "openai-chat", "gpt-4.1", "openai", fingerprint, 0)
        val same = MobilePromptCache.key("conversation-1", "openai", "openai-chat", "gpt-4.1", "openai", fingerprint, 0)
        val compacted = MobilePromptCache.key("conversation-1", "openai", "openai-chat", "gpt-4.1", "openai", fingerprint, 1)
        assertEquals(first, same)
        assertNotEquals(first, compacted)
        assertTrue(first.startsWith("herness:mobile-v1:"))
    }
}

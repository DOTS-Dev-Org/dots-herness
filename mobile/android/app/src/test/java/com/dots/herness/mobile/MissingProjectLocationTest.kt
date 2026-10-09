package com.dots.herness.mobile

import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class MissingProjectLocationTest {
    @Test
    fun missingProjectLocationBlocksSendAndNewConversation() {
        val agent = MobileHarnessRuntime(
            apiKey = { "" },
            systemPrompt = { "" },
            isProjectLocationAvailable = { false },
        )

        agent.send("This must not be added")
        agent.reset()

        assertNull(agent.activeConversationId)
        assertFalse(agent.running)
        assertTrue(agent.transcript.isEmpty())
    }
}

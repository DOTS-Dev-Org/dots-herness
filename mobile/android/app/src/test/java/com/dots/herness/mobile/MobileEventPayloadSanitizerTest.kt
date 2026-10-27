package com.dots.herness.mobile

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class MobileEventPayloadSanitizerTest {
    @Test
    fun secretInModelContextIsRedactedWithoutBreakingTheSnapshot() {
        val snapshot = JSONObject()
            .put("version", 3)
            .put("messages", JSONArray()
                .put(JSONObject().put("role", "tool").put("content", "DB_PASSWORD=hunter2secret\nAPI_KEY: \"quoted-value\"\nurl=https://x/y"))
                .put(JSONObject().put("role", "assistant").put("content", "Authorization: Bearer abc/def.ghi and ghp_1234567890123456")))
            .toString()

        val stored = MobileEventPayloadSanitizer.redact(snapshot)

        assertEquals(2, JSONObject(stored).getJSONArray("messages").length())
        for (secret in listOf("hunter2secret", "quoted-value", "abc", "def.ghi", "ghp_1234567890123456")) {
            assertFalse(secret, stored.contains(secret))
        }
        assertTrue(stored.contains("url=https"))
    }
}

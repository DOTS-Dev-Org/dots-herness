package com.dots.herness.mobile

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

class MobileAttachmentTest {
    @Test fun `canonical attachment preserves revision locator and delivered hash`() {
        val original = MobileAttachment(
            attachmentId = "attachment-1",
            displayName = "brief.pdf",
            kind = MobileAttachmentKind.FILE,
            mimeType = "application/pdf",
            sourceLocator = "content://example/brief",
            snapshotPath = "/snapshots/v1.pdf",
            contentHash = "hash-v1",
            revision = 1,
            deliveredHash = "hash-v1",
        )

        val restored = MobileAttachment.fromCanonicalBlock(JSONObject(original.canonicalBlock().toString()))

        assertNotNull(restored)
        assertEquals(original, restored)
        assertTrue(restored!!.canonicalBlock().has("source_locator"))
    }
}

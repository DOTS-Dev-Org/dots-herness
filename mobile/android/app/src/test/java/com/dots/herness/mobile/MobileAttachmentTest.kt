package com.dots.herness.mobile

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

class MobileAttachmentTest {
    @Test fun `historical snapshot never switches to latest revision`() {
        val directory = kotlin.io.path.createTempDirectory("MobileAttachmentHistory").toFile()
        try {
            val oldFile = java.io.File(directory, "v1.txt").apply { writeText("old") }
            val newFile = java.io.File(directory, "v2.txt").apply { writeText("new") }
            val old = MobileAttachment("one", "one.txt", MobileAttachmentKind.FILE, "text/plain", oldFile.toURI().toString(), oldFile.absolutePath, "v1", 1)
            val latest = MobileAttachment("one", "one.txt", MobileAttachmentKind.FILE, "text/plain", newFile.toURI().toString(), newFile.absolutePath, "v2", 2)
            val historical = MobilePromptCache.historicalAttachment(old.canonicalBlock(), latest)!!
            assertEquals("old", historical.providerData()?.toString(Charsets.UTF_8))
            oldFile.delete()
            org.junit.Assert.assertNull(MobilePromptCache.historicalAttachment(old.canonicalBlock(), latest)?.providerData())
        } finally { directory.deleteRecursively() }
    }
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

package com.dots.herness.mobile

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.nio.file.Files

class MobileLessonsTest {
    @Test
    fun readsWhatADesktopLearnedAndAppendsItOnce() {
        val root = Files.createTempDirectory("MobileLessonsTest").toFile()
        try {
            assertEquals("", MobileLessons.rulesText(root))
            File(root, ".mem").mkdirs()
            File(root, ".mem/lessons.json").writeText(
                """
                [
                  {"lastSeen":"2020-01-01T00:00:00Z","paths":[],"rule":"Inferred once, long ago.","sources":["signal:stale"],"when":"","why":""},
                  {"lastSeen":"2020-01-01T00:00:00Z","paths":[],"rule":"Do not skip the loading state.","sources":["3f2a9c0d1b7e4a55"],"when":"adding a screen","why":"Users saw a blank page."},
                  {"lastSeen":"2020-01-01T00:00:00Z","paths":["Sources/App"],"rule":"Only for one folder.","sources":["3f2a9c0d1b7e4a56"],"when":"","why":""}
                ]
                """.trimIndent()
            )
            val text = MobileLessons.rulesText(root)
            assertTrue(text.contains("- [3f2a9c user] When adding a screen: Do not skip the loading state. Why: Users saw a blank page."))
            assertFalse(text.contains("Inferred once, long ago."))
            assertFalse(text.contains("Only for one folder."))

            // A lesson tied to a folder comes with the first file read there, once.
            assertTrue(MobileLessons.fileNotice(root, "Sources/App/Login.kt").contains("Only for one folder."))
            assertEquals("", MobileLessons.fileNotice(root, "Sources/App/Login.kt"))
            assertEquals("", MobileLessons.fileNotice(root, "Sources/Other.kt"))

            // The facts file is shared with the desktops: read their lines, add ours.
            File(root, ".mem/facts.md").writeText("## project\n- backend — https://api.example.test\n")
            assertEquals(
                "Recorded preference language: Reply in Turkish.",
                MobileFacts.record(root, "preference", "Language", "Reply in  Turkish.")
            )
            assertTrue(MobileFacts.record(root, "project", "api-key", "x").startsWith("Not recorded"))
            assertEquals(
                "## project\n- backend — https://api.example.test\n\n## preference\n- language — Reply in Turkish.\n",
                File(root, ".mem/facts.md").readText()
            )
            assertTrue(MobileLessons.rulesText(root).contains("- backend — https://api.example.test"))

            val state = MobileCacheState()
            assertTrue(state.captureNotices(null, false, text).contains(text))
            // Unchanged rules are not appended to the transcript again.
            assertFalse(state.captureNotices(null, false, text).contains(text))
            assertTrue(state.captureNotices(null, false, "$text\n- New.").contains("$text\n- New."))
        } finally {
            root.deleteRecursively()
        }
    }
}

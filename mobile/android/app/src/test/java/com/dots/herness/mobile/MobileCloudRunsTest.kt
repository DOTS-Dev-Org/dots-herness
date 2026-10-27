package com.dots.herness.mobile

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class MobileCloudRunsTest {
    @Test
    fun onlyOwnerSlashRepositoryNamesAreCloudTargets() {
        assertEquals("octo/hello", CloudRepository.parse("octo/hello")?.fullName)
        assertEquals("https://github.com/octo/hello/tree/herness/cloud-1", CloudRepository.parse("octo/hello")?.branchUrl("herness/cloud-1"))
        assertNull(CloudRepository.parse(null))
        assertNull(CloudRepository.parse("hello"))
        assertNull(CloudRepository.parse("octo/hello/tree"))
        assertNull(CloudRepository.parse("octo/hel lo"))
    }

    @Test
    fun runAndEventsDecodeTheWorkerPayload() {
        val run = CloudRun.from(
            JSONObject(
                """{"id":"r1","repository":"octo/hello","base_ref":"main","prompt":"Fix the build","model":null,
                "status":"running","cancel_requested":false,"github_run_id":"42","github_run_url":null,
                "result_branch":null,"error":null,"created_at":"2026-10-27T17:13:19.444Z"}""",
            ),
        )
        assertTrue(run.isActive)
        assertEquals("42", run.gitHubRunId)
        assertNull(run.gitHubRunUrl)
        assertNull(run.resultBranch)
        assertFalse(run.copy(status = "succeeded").isActive)

        val events = CloudRunEvent.list(JSONArray("""[{"seq":1,"kind":"status","text":"Runner started.","tool":null}]"""))
        assertEquals(listOf(CloudRunEvent(1, "status", "Runner started.")), events)
        assertEquals(emptyList<CloudRunEvent>(), CloudRunEvent.list(null))
    }
}

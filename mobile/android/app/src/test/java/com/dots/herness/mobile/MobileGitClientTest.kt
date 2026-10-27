package com.dots.herness.mobile

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class MobileGitClientTest {
    @Test
    fun branchSnapshotParsesCurrentAndLocalBranches() {
        val snapshot = MobileGitBranchSnapshot.parse("current\tmain\nbranch\tmain\nbranch\tfeature/mobile\n")

        assertEquals("main", snapshot.currentBranch)
        assertEquals(listOf("main", "feature/mobile"), snapshot.branches)
    }

    @Test
    fun branchSnapshotKeepsUnbornHeadWithoutBranches() {
        val snapshot = MobileGitBranchSnapshot.parse("current\tmain\n")

        assertEquals("main", snapshot.currentBranch)
        assertTrue(snapshot.branches.isEmpty())
    }
}

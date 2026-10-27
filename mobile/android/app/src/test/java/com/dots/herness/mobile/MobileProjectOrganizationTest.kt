package com.dots.herness.mobile

import org.junit.Assert.assertEquals
import org.junit.Test

class MobileProjectOrganizationTest {
    @Test
    fun groupsProjectsBySourceAndKeepsSourceOrder() {
        val projects = listOf(
            project("g", "zeta", "github"),
            project("l1", "beta", "local"),
            project("d", "gamma", "remoteDesktop"),
            project("l2", "alpha", "local"),
        )

        val groups = organizeMobileProjects(projects, groupBySource = true, sortByName = false)

        assertEquals(listOf("local", "github", "remoteDesktop"), groups.map { it.key })
        assertEquals(listOf("l1", "l2"), groups.first().projects.map { it.id })
    }

    @Test
    fun sortsByNameAndCanUseAnUngroupedList() {
        val projects = listOf(project("b", "Beta"), project("a", "alpha"))

        val groups = organizeMobileProjects(projects, groupBySource = false, sortByName = true)

        assertEquals(1, groups.size)
        assertEquals("all", groups.single().key)
        assertEquals(listOf("a", "b"), groups.single().projects.map { it.id })
    }

    private fun project(id: String, name: String, source: String = "local") =
        MobileProject(id = id, name = name, sourceKind = source, localRoot = "/workspace/$id")
}

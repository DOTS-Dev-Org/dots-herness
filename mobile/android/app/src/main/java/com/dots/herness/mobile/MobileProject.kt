package com.dots.herness.mobile

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.UUID

data class MobileProject(
    val id: String,
    var name: String,
    var sourceKind: String = "local",
    var repository: String? = null,
    var branch: String? = null,
    var localRoot: String,
    var remoteProjectId: String? = null,
    var remoteWorkspaceId: String? = null,
)

internal data class MobileProjectGroup(val key: String, val projects: List<MobileProject>)

internal fun organizeMobileProjects(
    projects: List<MobileProject>,
    groupBySource: Boolean,
    sortByName: Boolean,
): List<MobileProjectGroup> {
    val ordered = if (sortByName) projects.sortedBy { it.name.lowercase(java.util.Locale.ROOT) } else projects
    if (!groupBySource) return listOf(MobileProjectGroup("all", ordered))

    val grouped = ordered.groupBy { it.sourceKind }
    val sourceOrder = listOf("local", "github", "remoteDesktop") + grouped.keys.filterNot {
        it in setOf("local", "github", "remoteDesktop")
    }
    return sourceOrder.mapNotNull { source -> grouped[source]?.let { MobileProjectGroup(source, it) } }
}

class MobileProjectStore(context: Context) {
    private val appContext = context.applicationContext
    private val preferences = appContext.getSharedPreferences("herness.preferences", Context.MODE_PRIVATE)
    private val legacyRoot = File(appContext.filesDir, "herness-workspace/files")
    private val file = File(appContext.filesDir, "herness-projects/projects.json")
    private val loadedProjects = load()
    var projects: List<MobileProject> = loadedProjects.ifEmpty {
        listOf(MobileProject("local-default", "Default project", localRoot = legacyRoot.absolutePath)).also { persist(it) }
    }
        private set
    var selectedProjectId: String = preferences.getString("projects.selected_id", null)
        ?.takeIf { id -> projects.any { it.id == id } }
        ?: projects.first().id
    private set

    init {
        // Only create a root for a genuinely new install. Existing roots may
        // have been removed or moved; recreating them would hide that fact.
        if (loadedProjects.isEmpty()) legacyRoot.mkdirs()
        persist(projects)
        preferences.edit().putString("projects.selected_id", selectedProjectId).apply()
    }

    val selected: MobileProject get() = projects.firstOrNull { it.id == selectedProjectId } ?: projects.first()

    fun select(id: String): Boolean {
        if (projects.none { it.id == id }) return false
        selectedProjectId = id
        preferences.edit().putString("projects.selected_id", id).apply()
        return true
    }

    fun add(name: String): MobileProject {
        return add(name, "local", null, null)
    }

    fun add(name: String, sourceKind: String, remoteProjectId: String?, remoteWorkspaceId: String?, branch: String? = null): MobileProject {
        val id = UUID.randomUUID().toString()
        val project = MobileProject(
            id = id,
            name = name.trim().ifEmpty { "New project" },
            sourceKind = sourceKind,
            branch = branch,
            localRoot = File(appContext.filesDir, "herness-projects/$id/files").absolutePath,
            remoteProjectId = remoteProjectId,
            remoteWorkspaceId = remoteWorkspaceId,
        )
        File(project.localRoot).mkdirs()
        projects = projects + project
        persist(projects)
        select(id)
        return project
    }

    fun bindRemoteProject(descriptor: RemoteProjectDescriptor): MobileProject {
        projects.firstOrNull { it.remoteProjectId == descriptor.id }?.let {
            select(it.id)
            return it
        }
        return add("${descriptor.name} (Desktop)", "remoteDesktop", descriptor.id, descriptor.workspaceId, descriptor.branch)
    }

    fun update(project: MobileProject) {
        projects = projects.map { if (it.id == project.id) project else it }
        persist(projects)
    }

    fun updateLocalRoot(id: String, root: File): Boolean {
        val project = projects.firstOrNull { it.id == id } ?: return false
        update(project.copy(localRoot = root.absolutePath))
        return true
    }

    fun remove(id: String) {
        if (projects.size <= 1 || id == selectedProjectId) return
        projects = projects.filterNot { it.id == id }
        persist(projects)
    }

    private fun load(): List<MobileProject> = runCatching {
        if (!file.exists()) return@runCatching emptyList()
        val array = JSONArray(file.readText())
        (0 until array.length()).map { index ->
            val item = array.getJSONObject(index)
            MobileProject(
                id = item.getString("id"),
                name = item.optString("name", "Project"),
                sourceKind = item.optString("sourceKind", "local"),
                repository = item.optString("repository").ifBlank { null },
                branch = item.optString("branch").ifBlank { null },
                localRoot = item.getString("localRoot"),
                remoteProjectId = item.optString("remoteProjectId").ifBlank { null },
                remoteWorkspaceId = item.optString("remoteWorkspaceId").ifBlank { null },
            )
        }
    }.getOrDefault(emptyList())

    private fun persist(value: List<MobileProject>) {
        file.parentFile?.mkdirs()
        val array = JSONArray()
        value.forEach { project ->
            array.put(JSONObject().apply {
                put("id", project.id); put("name", project.name); put("sourceKind", project.sourceKind)
                put("repository", project.repository ?: ""); put("branch", project.branch ?: "")
                put("localRoot", project.localRoot); put("remoteProjectId", project.remoteProjectId ?: "")
                put("remoteWorkspaceId", project.remoteWorkspaceId ?: "")
            })
        }
        runCatching { file.writeText(array.toString()) }
    }
}

package com.dots.herness.mobile

import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AccountTree
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material.icons.filled.Folder
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

@Composable
internal fun MobileProjectBranchBar(
    client: RemoteClient,
    agent: MobileAgent,
    canSwitchProject: Boolean,
    onProjectSelected: (String) -> Unit,
    onLocateMissing: () -> Unit,
) {
    var projectMenuExpanded by remember { mutableStateOf(false) }
    var branchMenuExpanded by remember { mutableStateOf(false) }
    var createBranchDialog by remember { mutableStateOf(false) }
    var branchName by remember { mutableStateOf("") }
    var gitBusy by remember { mutableStateOf(false) }
    var gitError by remember { mutableStateOf<String?>(null) }
    var branchSnapshot by remember(client.selectedProjectId) { mutableStateOf<MobileGitBranchSnapshot?>(null) }
    val scope = rememberCoroutineScope()
    val git = remember(client.selectedProjectId) {
        MobileGitClient({ client.workspaceRoot() }, { client.phoneSecret("oauth.github.access") })
    }

    fun runGitOperation(action: suspend () -> Unit) {
        if (gitBusy || !canSwitchProject) return
        scope.launch {
            gitBusy = true
            try {
                action()
                branchSnapshot = git.branchSnapshot()
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: Exception) {
                gitError = error.localizedMessage ?: error.toString()
            } finally {
                gitBusy = false
            }
        }
    }

    LaunchedEffect(client.selectedProjectId, client.selectedProjectLocationAvailable) {
        while (true) {
            branchSnapshot = if (client.selectedProjectLocationAvailable) git.branchSnapshot() else null
            delay(8_000)
        }
    }

    Surface(
        modifier = Modifier.fillMaxWidth().padding(horizontal = 8.dp, vertical = 2.dp),
        shape = androidx.compose.foundation.shape.RoundedCornerShape(18.dp),
        color = MaterialTheme.colorScheme.surfaceVariant,
        tonalElevation = 1.dp,
    ) {
        Row(
            Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(horizontal = 4.dp, vertical = 2.dp),
            horizontalArrangement = Arrangement.spacedBy(4.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            androidx.compose.foundation.layout.Box {
                TextButton(
                    onClick = { projectMenuExpanded = true },
                    enabled = canSwitchProject,
                    contentPadding = PaddingValues(horizontal = 10.dp, vertical = 6.dp),
                ) {
                    Icon(Icons.Filled.Folder, contentDescription = null)
                    Spacer(Modifier.width(6.dp))
                    Text(client.selectedProject.name, modifier = Modifier.widthIn(max = 180.dp), maxLines = 1)
                    Icon(Icons.Filled.ExpandMore, contentDescription = null)
                }
                DropdownMenu(expanded = projectMenuExpanded, onDismissRequest = { projectMenuExpanded = false }) {
                    client.projects.forEach { project ->
                        DropdownMenuItem(
                            text = { Text(project.name, maxLines = 1) },
                            leadingIcon = {
                                Icon(
                                    if (project.id == client.selectedProjectId) Icons.Filled.CheckCircle else Icons.Filled.Folder,
                                    contentDescription = null,
                                )
                            },
                            onClick = {
                                projectMenuExpanded = false
                                onProjectSelected(project.id)
                            },
                            enabled = canSwitchProject,
                        )
                    }
                    if (!client.selectedProjectLocationAvailable) {
                        DropdownMenuItem(
                            text = { Text(stringResource(R.string.project_missing_locate)) },
                            leadingIcon = { Icon(Icons.Filled.Folder, contentDescription = null) },
                            onClick = {
                                projectMenuExpanded = false
                                onLocateMissing()
                            },
                            enabled = canSwitchProject,
                        )
                    }
                }
            }

            androidx.compose.foundation.layout.Box {
                TextButton(
                    onClick = { branchMenuExpanded = true },
                    enabled = client.selectedProjectLocationAvailable && branchSnapshot != null && canSwitchProject && !gitBusy,
                    contentPadding = PaddingValues(horizontal = 10.dp, vertical = 6.dp),
                ) {
                    Icon(Icons.Filled.AccountTree, contentDescription = null)
                    Spacer(Modifier.width(6.dp))
                    Text(branchSnapshot?.currentBranch ?: stringResource(R.string.mobile_settings_branch), maxLines = 1)
                    Icon(Icons.Filled.ExpandMore, contentDescription = null)
                }
                DropdownMenu(expanded = branchMenuExpanded, onDismissRequest = { branchMenuExpanded = false }) {
                    branchSnapshot?.branches.orEmpty().forEach { branch ->
                        DropdownMenuItem(
                            text = { Text(branch, maxLines = 1) },
                            leadingIcon = {
                                if (branch == branchSnapshot?.currentBranch) {
                                    Icon(Icons.Filled.CheckCircle, contentDescription = null)
                                } else {
                                    Icon(Icons.Filled.AccountTree, contentDescription = null)
                                }
                            },
                            onClick = {
                                branchMenuExpanded = false
                                if (branch != branchSnapshot?.currentBranch) {
                                    runGitOperation { git.checkoutBranch(branch) }
                                }
                            },
                            enabled = canSwitchProject && !gitBusy,
                        )
                    }
                    DropdownMenuItem(
                        text = { Text(stringResource(R.string.mobile_settings_new_branch)) },
                        leadingIcon = { Icon(Icons.Filled.Add, contentDescription = null) },
                        onClick = {
                            branchMenuExpanded = false
                            branchName = ""
                            createBranchDialog = true
                        },
                        enabled = branchSnapshot?.branches?.isNotEmpty() == true && canSwitchProject && !gitBusy,
                    )
                }
            }
        }
    }

    if (createBranchDialog) {
        AlertDialog(
            onDismissRequest = { createBranchDialog = false },
            title = { Text(stringResource(R.string.mobile_settings_new_branch)) },
            text = {
                OutlinedTextField(
                    value = branchName,
                    onValueChange = { branchName = it },
                    singleLine = true,
                    label = { Text(stringResource(R.string.mobile_settings_new_branch)) },
                )
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        val name = branchName.trim()
                        createBranchDialog = false
                        if (name.isNotEmpty()) runGitOperation { git.createBranch(name) }
                    },
                    enabled = branchName.isNotBlank() && canSwitchProject && !gitBusy,
                ) { Text(stringResource(R.string.mobile_settings_new_branch)) }
            },
            dismissButton = {
                TextButton(onClick = { createBranchDialog = false }) {
                    Text(stringResource(R.string.common_cancel))
                }
            },
        )
    }

    gitError?.let { error ->
        AlertDialog(
            onDismissRequest = { gitError = null },
            title = { Text(stringResource(R.string.mobile_settings_branch)) },
            text = { Text(error) },
            confirmButton = {
                TextButton(onClick = { gitError = null }) { Text(stringResource(R.string.app_ok)) }
            },
        )
    }
}

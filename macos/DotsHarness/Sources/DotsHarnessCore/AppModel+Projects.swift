// Copyright (c) 2026 DOTS
// Workspace switching, project list, sections and sorting.

import AppKit
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import HarnessPluginKit

@MainActor
extension AppModel {
    public func setWorkspace(_ value: String) {
        setWorkspace(value, allowSandboxTransition: false)
    }

    func setWorkspace(_ value: String, allowSandboxTransition: Bool) {
        let normalized = Self.validWorkspacePath(value).map {
            SandboxProfile.canonicalURL(URL(fileURLWithPath: $0, isDirectory: true)).path
        } ?? ""
        if let sandbox = activeSandbox,
           !allowSandboxTransition,
           normalized != sandbox.path {
            sandboxNotice = "Leave the active sandbox before changing workspaces."
            return
        }
        if sandboxRecoveryRequired, !allowSandboxTransition {
            sandboxNotice = "Recover the saved sandbox before changing workspaces."
            return
        }
        commitNavigationDestination()
        cancelEditing()
        workspacePath = normalized
        if !normalized.isEmpty, !projectPaths.contains(normalized) {
            projectPaths.insert(normalized, at: 0)
            // The unsectioned group only lists five projects and a new entry lands
            // at the top, so reveal the group rather than push a visible project out.
            showsAllOtherProjects = true
            persistProjectPaths()
        }
        refreshProjectLocationAvailability()
        remoteControl.setWorkspacePath(normalized)
        host.settings.set("agent.workspace", normalized.isEmpty ? .null : .string(normalized))
        persistSettings()
        bridge.setWorkspace(normalized)
        bridge.setSandboxPolicy(
            normalized == activeSandbox?.path ? sandboxExecutionPolicy : nil,
            branch: normalized == activeSandbox?.path ? activeSandbox?.branch : nil
        )
        bridge.setSearchFolders(projectSearchFolders(for: normalized))
        skills.setWorkspace(normalized.isEmpty ? nil : normalized)
        skillSuggestions.setWorkspace(normalized.isEmpty ? nil : normalized)
        restoreDraftState()
        refreshAvailableSandboxes()
        commitNavigationDestination()
        Task { await bridge.refreshConnection() }
    }

    /// Looks for a lesson this project keeps relearning, worth turning into a skill.
    /// Only ever produces a suggestion for the user to review; nothing is written
    /// until acceptSkillSuggestion is called from an explicit click.
    public func scanSkillSuggestions() {
        activeSkillSuggestions.scan(lessons: bridge.lessons)
    }

    @discardableResult
    public func acceptSkillSuggestion(name: String, description: String, body: String? = nil) throws -> String {
        try activeSkillSuggestions.acceptCurrent(name: name, description: description, body: body)
    }

    public func dismissSkillSuggestion() {
        activeSkillSuggestions.dismissCurrent()
    }

    // MARK: - Project list

    /// Keeps the unsectioned project group expanded for the rest of this app
    /// session. This is intentionally independent of the current workspace so
    /// selecting another project never collapses the list.
    public func revealAllOtherProjects() {
        showsAllOtherProjects = true
    }

    /// Checks the saved local folder for a project without changing selection.
    public func isProjectLocationAvailable(_ path: String) -> Bool {
        Self.canonicalExistingWorkspacePath(path) != nil
    }

    /// Project paths still in settings but whose folders were deleted no longer
    /// own an active connection. Their retained chats belong in Recent instead.
    public var connectedProjectPaths: [String] {
        projectPaths.filter(isProjectLocationAvailable)
    }

    /// Rechecks every project row after filesystem changes. The published set
    /// only changes when a folder appears or disappears, avoiding redraw churn.
    public func refreshProjectLocationAvailability() {
        let unavailable = Set(projectPaths.filter { !isProjectLocationAvailable($0) })
        guard unavailable != unavailableProjectPaths else { return }
        unavailableProjectPaths = unavailable
    }

    /// Opens a folder picker and adds the chosen folder as a new project, making it active.
    public func addProject() { chooseWorkspace() }

    /// Prompts the user to locate a moved or missing project folder or remove it from the list.
    public func promptToRelocateProject(missingPath: String, onRelocated: ((String) -> Void)? = nil) {
        guard NSClassFromString("XCTest") == nil else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        let projectName = projectTitle(for: missingPath)
        let title = AppCopy.format("project.missing.title", projectName)
        alert.messageText = title
        let msg = AppCopy.format("project.missing.message", missingPath)
        alert.informativeText = msg
        let locateTitle = AppCopy.text("project.missing.locate")
        alert.addButton(withTitle: locateTitle)
        alert.addButton(withTitle: AppCopy.text("sidebar.removeProject"))
        alert.addButton(withTitle: AppCopy.text("common.cancel"))

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            let panel = Self.workspaceFolderPanel()
            if panel.runModal() == .OK, let url = panel.url {
                guard let newPath = relocateProject(missingPath: missingPath, to: url.path) else { return }
                onRelocated?(newPath)
            }
        } else if response == .alertSecondButtonReturn {
            removeProject(missingPath)
        }
    }

    /// Reattaches a missing project row to a real directory and activates it.
    /// Returns the canonical destination when the move is accepted.
    func relocateProject(missingPath: String, to selectedPath: String) -> String? {
        guard let newPath = Self.canonicalExistingWorkspacePath(selectedPath) else { return nil }
        guard newPath != missingPath else {
            setWorkspace(newPath)
            return newPath
        }

        let destinationAlreadyListed = projectPaths.contains(newPath)
        if destinationAlreadyListed {
            projectPaths.removeAll { $0 == missingPath }
        } else if let index = projectPaths.firstIndex(of: missingPath) {
            projectPaths[index] = newPath
        } else {
            projectPaths.append(newPath)
        }

        if let metadata = projectMetadata.removeValue(forKey: missingPath), projectMetadata[newPath] == nil {
            projectMetadata[newPath] = metadata
        }
        if let sort = projectSortOrders.removeValue(forKey: missingPath), projectSortOrders[newPath] == nil {
            projectSortOrders[newPath] = sort
        }
        if let manual = projectManualOrder.removeValue(forKey: missingPath), projectManualOrder[newPath] == nil {
            projectManualOrder[newPath] = manual
        }
        if expandedProjectPaths.remove(missingPath) != nil {
            expandedProjectPaths.insert(newPath)
        }

        bridge.relocateProjectHistory(from: missingPath, to: newPath)
        persistProjectPaths()
        persistProjectMetadata()
        persistProjectSortOrders()
        host.settings.set("agent.projectManualOrder", .object(
            projectManualOrder.mapValues { .array($0.map(JSONValue.string)) }
        ))
        persistSettings()
        persistExpandedProjectPaths()
        setWorkspace(newPath)
        refreshProjectLocationAvailability()
        return newPath
    }

    /// Switches the active project to an already-added one.
    public func selectProject(_ path: String) {
        guard let targetPath = Self.canonicalExistingWorkspacePath(path) else {
            promptToRelocateProject(missingPath: path) { [weak self] newPath in
                self?.selectProject(newPath)
            }
            return
        }
        setWorkspace(targetPath)
    }

    public func selectNoProject() {
        setWorkspace("")
    }

    /// Removes a project from the sidebar list (and its sort preference). If it was
    /// active, the next remaining project (or none) becomes active.
    public func removeProject(_ path: String) {
        let canonical = Self.canonicalExistingWorkspacePath(path) ?? (path as NSString).expandingTildeInPath
        guard let index = projectPaths.firstIndex(where: { $0 == path || $0 == canonical }) else { return }
        let removedPath = projectPaths.remove(at: index)
        unavailableProjectPaths.remove(path)
        unavailableProjectPaths.remove(removedPath)
        projectMetadata.removeValue(forKey: path)
        projectMetadata.removeValue(forKey: removedPath)
        projectSortOrders.removeValue(forKey: path)
        projectSortOrders.removeValue(forKey: removedPath)
        projectManualOrder.removeValue(forKey: path)
        projectManualOrder.removeValue(forKey: removedPath)
        let wasExpanded = expandedProjectPaths.remove(path) != nil || expandedProjectPaths.remove(removedPath) != nil
        persistProjectPaths()
        persistProjectMetadata()
        persistProjectSortOrders()
        if wasExpanded { persistExpandedProjectPaths() }
        if workspacePath == path || workspacePath == removedPath {
            setWorkspace(projectPaths.first ?? "")
        }
    }


    public func projectTitle(for path: String) -> String {
        let title = projectMetadata[path]?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? URL(fileURLWithPath: path).lastPathComponent : title
    }

    public func projectSearchFolders(for path: String) -> [String] {
        projectMetadata[path]?.searchFolders.compactMap { value in
            let url = SandboxProfile.canonicalURL(URL(fileURLWithPath: value, isDirectory: true))
            var isDirectory = ObjCBool(false)
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue,
                  !url.path.split(separator: "/").contains(".mem") else { return nil }
            return url.path
        } ?? []
    }

    /// Reads the cached result only. SwiftUI menu construction must not spawn
    /// processes or mutate model state while the view graph is being updated.
    public func isGitProject(_ path: String) -> Bool {
        gitProjectCache[path] ?? false
    }

    /// Resolves Git membership after the project row appears, away from the
    /// main actor so menu rendering never waits for a subprocess.
    public func loadGitProjectStatusIfNeeded(_ path: String) {
        guard gitProjectCache[path] == nil,
              !gitProjectStatusInFlight.contains(path) else { return }
        gitProjectStatusInFlight.insert(path)
        let directory = URL(fileURLWithPath: path, isDirectory: true)

        Task.detached(priority: .utility) { [weak self] in
            let isGitProject = SandboxWorkspaces.isGitRepository(directory)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.gitProjectStatusInFlight.remove(path)
                self.gitProjectCache[path] = isGitProject
            }
        }
    }

    public func isProjectPinned(_ path: String) -> Bool {
        projectMetadata[path]?.pinned ?? false
    }

    public func projectSection(for path: String) -> String? {
        projectMetadata[path]?.section
    }

    public func saveProjectMetadata(
        for path: String,
        title: String,
        searchFolders: [String]
    ) {
        var metadata = projectMetadata[path] ?? ProjectMetadata()
        metadata.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let canonicalPath = SandboxProfile.canonicalURL(URL(fileURLWithPath: path, isDirectory: true)).path
        metadata.searchFolders = searchFolders
            .map { SandboxProfile.canonicalURL(URL(fileURLWithPath: $0, isDirectory: true)).path }
            .filter { $0 != canonicalPath }
            .filter { value in
                var isDirectory = ObjCBool(false)
                return FileManager.default.fileExists(atPath: value, isDirectory: &isDirectory) && isDirectory.boolValue
            }
            .reduce(into: []) { result, item in
                if !result.contains(item) { result.append(item) }
            }
        projectMetadata[path] = metadata
        persistProjectMetadata()
        if workspacePath == path { bridge.setSearchFolders(metadata.searchFolders) }
        objectWillChange.send()
    }

    public func toggleProjectPinned(_ path: String) {
        var metadata = projectMetadata[path] ?? ProjectMetadata()
        metadata.pinned.toggle()
        projectMetadata[path] = metadata
        persistProjectMetadata()
        objectWillChange.send()
    }

    public func setProjectSection(_ section: String?, for path: String) {
        var metadata = projectMetadata[path] ?? ProjectMetadata()
        let value = section?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        metadata.section = value.isEmpty ? nil : value
        if let section = metadata.section, !projectSections.contains(section) {
            projectSections.append(section)
        }
        projectMetadata[path] = metadata
        persistProjectMetadata()
        persistProjectSections()
        objectWillChange.send()
    }

    @discardableResult
    public func createProjectSection(named rawName: String) -> String? {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        if !projectSections.contains(name) { projectSections.append(name) }
        persistProjectSections()
        return name
    }

    public func markAllChatsRead(forProject path: String) {
        bridge.markAllRead(forWorkspace: path)
    }

    public func archiveChats(forProject path: String) {
        bridge.archiveAll(forWorkspace: path)
    }

    public func createPermanentWorktree(from originPath: String, named name: String) {
        do {
            let worktree = try SandboxWorkspaces.enter(origin: originPath, name: name)
            let path = worktree.path
            if !projectPaths.contains(path) { projectPaths.insert(path, at: 0) }
            var metadata = projectMetadata[path] ?? ProjectMetadata()
            metadata.worktreeOrigin = worktree.originPath
            projectMetadata[path] = metadata
            persistProjectPaths()
            persistProjectMetadata()
            setWorkspace(path)
        } catch {
            sandboxNotice = error.localizedDescription
        }
    }

    public func sortOrder(forProject path: String) -> ConversationSortOrder {
        projectSortOrders[path] ?? .lastUpdate
    }

    public func setSortOrder(_ order: ConversationSortOrder, forProject path: String) {
        guard !path.isEmpty else { return }
        projectSortOrders[path] = order
        persistProjectSortOrders()
    }

    public func setSidebarLayoutMode(_ mode: SidebarLayoutMode) {
        sidebarLayoutMode = mode
        host.settings.set("agent.sidebarLayoutMode", .string(mode.rawValue))
        persistSettings()
    }

    /// Opens or closes one project's chat sublist and remembers the choice so a
    /// relaunch shows the same lists. No other project's state is touched.
    public func setProjectChatsExpanded(_ expanded: Bool, for path: String) {
        guard !path.isEmpty else { return }
        let canonical = Self.canonicalExistingWorkspacePath(path) ?? (path as NSString).expandingTildeInPath
        if expanded {
            guard !expandedProjectPaths.contains(path), !expandedProjectPaths.contains(canonical) else { return }
            expandedProjectPaths.insert(canonical)
        } else {
            let removed = expandedProjectPaths.remove(path) != nil || expandedProjectPaths.remove(canonical) != nil
            guard removed else { return }
        }
        persistExpandedProjectPaths()
    }

    /// Moves `id` to just before `targetID` in the given project's manual order
    /// (or to the end when `targetID` is nil). `currentOrder` seeds the array the
    /// first time a project is reordered, so unranked conversations keep their
    /// prior on-screen position instead of jumping to the top.
    public func moveConversation(
        _ id: String,
        before targetID: String?,
        inProject path: String,
        currentOrder: [String]
    ) {
        guard !path.isEmpty, id != targetID else { return }
        var order = projectManualOrder[path] ?? currentOrder
        for missing in currentOrder where !order.contains(missing) {
            order.append(missing)
        }
        order.removeAll { $0 == id }
        if let targetID, let targetIndex = order.firstIndex(of: targetID) {
            order.insert(id, at: targetIndex)
        } else {
            order.append(id)
        }
        projectManualOrder[path] = order
        host.settings.set("agent.projectManualOrder", .object(
            projectManualOrder.mapValues { .array($0.map(JSONValue.string)) }
        ))
        persistSettings()
    }

    private func persistProjectPaths() {
        host.settings.set("agent.projects", .array(projectPaths.map(JSONValue.string)))
        persistSettings()
    }

    private func persistProjectMetadata() {
        let values = projectMetadata.mapValues { metadata in
            JSONValue.object([
                "title": .string(metadata.title),
                "pinned": .bool(metadata.pinned),
                "section": metadata.section.map(JSONValue.string) ?? .null,
                "searchFolders": .array(metadata.searchFolders.map(JSONValue.string)),
                "worktreeOrigin": metadata.worktreeOrigin.map(JSONValue.string) ?? .null,
            ])
        }
        host.settings.set("agent.projectMetadata", .object(values))
        persistSettings()
    }

    private func persistProjectSections() {
        host.settings.set("agent.projectSections", .array(projectSections.map(JSONValue.string)))
        persistSettings()
    }

    private func persistProjectSortOrders() {
        let object = projectSortOrders.mapValues { JSONValue.string($0.rawValue) }
        host.settings.set("agent.projectSortOrders", .object(object))
        persistSettings()
    }

    private func persistExpandedProjectPaths() {
        host.settings.set(
            "agent.sidebarExpandedProjects",
            .array(expandedProjectPaths.sorted().map(JSONValue.string))
        )
        persistSettings()
    }
}

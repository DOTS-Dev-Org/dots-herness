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
        setActiveArea(.coding)
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
        cancelEditing()
        workspacePath = normalized
        if !normalized.isEmpty, !projectPaths.contains(normalized) {
            projectPaths.insert(normalized, at: 0)
            persistProjectPaths()
        }
        remoteControl.setWorkspacePath(normalized)
        host.settings.set("agent.workspace", normalized.isEmpty ? .null : .string(normalized))
        persistSettings()
        codingBridge.setWorkspace(normalized)
        codingBridge.setSandboxPolicy(
            normalized == activeSandbox?.path ? sandboxExecutionPolicy : nil,
            branch: normalized == activeSandbox?.path ? activeSandbox?.branch : nil
        )
        codingBridge.setSearchFolders(projectSearchFolders(for: normalized))
        skills.setWorkspace(normalized.isEmpty ? nil : normalized)
        skillSuggestions.setWorkspace(normalized.isEmpty ? nil : normalized)
        restoreDraftState()
        refreshAvailableSandboxes()
        Task { await codingBridge.refreshConnection() }
    }

    /// Re-scans recent tool-call and prompt history for a repeated pattern worth
    /// turning into a skill. Only ever produces a suggestion for the user to review;
    /// nothing is written until acceptSkillSuggestion is called from an explicit click.
    public func scanSkillSuggestions() {
        let prompts = bridge.selected?.messages
            .filter { $0.kind == .user }
            .map(\.text) ?? []
        activeSkillSuggestions.scan(recentUserPrompts: prompts)
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

    /// Opens a folder picker and adds the chosen folder as a new project, making it active.
    public func addProject() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = AppCopy.text("workspace.use")
        panel.message = AppCopy.text("workspace.chooseMessage")
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor [weak self] in
                self?.setWorkspace(url.path)
            }
        }
    }

    /// Prompts the user to locate a moved or missing project folder or remove it from the list.
    public func promptToRelocateProject(missingPath: String, onRelocated: ((String) -> Void)? = nil) {
        guard NSClassFromString("XCTest") == nil else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        let projectName = projectTitle(for: missingPath)
        let title = AppCopy.format("project.missing.title", projectName)
        alert.messageText = title == "project.missing.title" ? "Proje Klasörü Bulunamadı: \(projectName)" : title
        let msg = AppCopy.format("project.missing.message", missingPath)
        alert.informativeText = msg == "project.missing.message"
            ? "'\(missingPath)' konumundaki proje klasörü taşınmış veya silinmiş olabilir. Lütfen klasörün yeni konumunu seçin veya projeyi kaldırın."
            : msg
        let locateTitle = AppCopy.text("project.missing.locate")
        alert.addButton(withTitle: locateTitle == "project.missing.locate" ? "Konumu Bul..." : locateTitle)
        alert.addButton(withTitle: AppCopy.text("sidebar.removeProject"))
        alert.addButton(withTitle: AppCopy.text("common.cancel"))

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.allowsMultipleSelection = false
            panel.prompt = AppCopy.text("workspace.use")
            panel.message = AppCopy.text("workspace.chooseMessage")
            if panel.runModal() == .OK, let url = panel.url {
                let newPath = url.path
                if let idx = projectPaths.firstIndex(of: missingPath) {
                    projectPaths[idx] = newPath
                } else if !projectPaths.contains(newPath) {
                    projectPaths.append(newPath)
                }
                if let meta = projectMetadata.removeValue(forKey: missingPath) {
                    projectMetadata[newPath] = meta
                }
                if let sort = projectSortOrders.removeValue(forKey: missingPath) {
                    projectSortOrders[newPath] = sort
                }
                if let manual = projectManualOrder.removeValue(forKey: missingPath) {
                    projectManualOrder[newPath] = manual
                }
                persistProjectPaths()
                persistProjectMetadata()
                persistProjectSortOrders()
                setWorkspace(newPath)
                onRelocated?(newPath)
            }
        } else if response == .alertSecondButtonReturn {
            removeProject(missingPath)
        }
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

    /// Removes a project from the sidebar list (and its sort preference). If it was
    /// active, the next remaining project (or none) becomes active.
    public func removeProject(_ path: String) {
        guard let index = projectPaths.firstIndex(of: path) else { return }
        projectPaths.remove(at: index)
        projectMetadata.removeValue(forKey: path)
        projectSortOrders.removeValue(forKey: path)
        projectManualOrder.removeValue(forKey: path)
        persistProjectPaths()
        persistProjectMetadata()
        persistProjectSortOrders()
        if workspacePath == path {
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

    /// `SandboxWorkspaces.isGitRepository` spawns a `git` process. The sidebar
    /// asks once per project row while building menus, so the answer is cached
    /// for the session rather than shelling out on every redraw.
    public func isGitProject(_ path: String) -> Bool {
        if let cached = gitProjectCache[path] { return cached }
        let value = SandboxWorkspaces.isGitRepository(URL(fileURLWithPath: path))
        gitProjectCache[path] = value
        return value
    }

    public func isProjectPinned(_ path: String) -> Bool {
        projectMetadata[path]?.pinned ?? false
    }

    public func projectSection(for path: String) -> String? {
        projectMetadata[path]?.section
    }

    public func projectWorktreeOrigin(for path: String) -> String? {
        projectMetadata[path]?.worktreeOrigin
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
}

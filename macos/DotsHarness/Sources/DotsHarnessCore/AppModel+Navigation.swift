// Copyright (c) 2026 DOTS
// Back/forward history over the screens the detail pane shows.

import Foundation
import SwiftUI

/// One screen the back/forward buttons can revisit: the scheduled task list, or
/// a chat inside a project (`projectPath` non-empty) or as retained history
/// without one (empty).
public struct NavigationDestination: Equatable, Sendable {
    public var projectPath: String
    public var conversationID: String?
    public var showsTasks: Bool

    public init(projectPath: String, conversationID: String?, showsTasks: Bool) {
        self.projectPath = projectPath
        self.conversationID = conversationID
        self.showsTasks = showsTasks
    }
}

/// Screens live in the same list the toolbar walks, so a stale entry (deleted
/// chat, moved-away folder) is dropped the first time it fails to open.
private let navigationHistoryLimit = 50

@MainActor
extension AppModel {
    public var canNavigateBack: Bool { navigationIndex > 0 }

    public var canNavigateForward: Bool {
        navigationIndex >= 0 && navigationIndex < navigationEntries.count - 1
    }

    /// Notes the screen that is on display now. Callers run it both before and
    /// after a navigation; identical consecutive entries collapse, so the extra
    /// calls never invent empty steps.
    func commitNavigationDestination() {
        guard !isApplyingNavigation else { return }
        guard isTasksPresented || bridge.selectedID != nil else { return }
        let destination = NavigationDestination(
            projectPath: workspacePath,
            conversationID: isTasksPresented ? nil : bridge.selectedID,
            showsTasks: isTasksPresented
        )
        if navigationEntries.indices.contains(navigationIndex),
           navigationEntries[navigationIndex] == destination {
            return
        }
        // A new screen after a "back" abandons the forward branch, like a browser.
        if navigationIndex < navigationEntries.count - 1 {
            navigationEntries.removeSubrange((navigationIndex + 1)...)
        }
        navigationEntries.append(destination)
        if navigationEntries.count > navigationHistoryLimit {
            navigationEntries.removeFirst(navigationEntries.count - navigationHistoryLimit)
        }
        navigationIndex = navigationEntries.count - 1
    }

    public func navigateBack() {
        stepNavigationHistory(by: -1)
    }

    public func navigateForward() {
        stepNavigationHistory(by: 1)
    }

    private func stepNavigationHistory(by offset: Int) {
        guard navigationIndex >= 0 else { return }
        var current = navigationIndex
        while true {
            let candidate = current + offset
            guard candidate >= 0, candidate < navigationEntries.count else { return }
            isApplyingNavigation = true
            let opened = openNavigationDestination(navigationEntries[candidate])
            isApplyingNavigation = false
            if opened {
                navigationIndex = candidate
                return
            }
            navigationEntries.remove(at: candidate)
            // Removing ahead of the cursor shifts the screen on display left.
            if candidate < current { current -= 1 }
        }
    }

    private func openNavigationDestination(_ destination: NavigationDestination) -> Bool {
        if destination.showsTasks {
            isTasksPresented = true
            return true
        }
        isTasksPresented = false
        guard let conversationID = destination.conversationID else {
            return workspacePath == destination.projectPath
        }
        if destination.projectPath.isEmpty {
            guard let conversation = bridge
                .conversations(outsideProjects: connectedProjectPaths)
                .first(where: { $0.id == conversationID }) else { return false }
            return openRecentConversation(conversation)
        }
        // Never `selectProject` here: a folder that went missing raises the locate
        // prompt, and a history step must not block on a modal.
        guard let canonicalTarget = Self.canonicalExistingWorkspacePath(destination.projectPath) else {
            return false
        }
        if workspacePath != canonicalTarget && workspacePath != destination.projectPath {
            setWorkspace(destination.projectPath)
            guard workspacePath == canonicalTarget || workspacePath == destination.projectPath else { return false }
        }
        guard bridge.conversations.contains(where: { $0.id == conversationID }) else { return false }
        selectConversation(conversationID)
        return true
    }
}

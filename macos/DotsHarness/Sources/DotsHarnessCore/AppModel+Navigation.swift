// Copyright (c) 2026 DOTS
// Back/forward history over the screens the detail pane shows.

import Foundation
import SwiftUI

/// A top-level area of the window, picked from the rail on the leading edge.
public enum AppSection: String, CaseIterable, Identifiable, Sendable {
    case home, media, tasks, bots, marketplace, memory

    public var id: String { rawValue }
    public var title: String { AppCopy.text("rail.\(rawValue)") }

    public var systemImage: String {
        switch self {
        case .home: return "house"
        case .media: return "photo.on.rectangle.angled"
        case .tasks: return "clock"
        case .bots: return "bubble.left.and.bubble.right"
        case .marketplace: return "bag"
        case .memory: return "brain"
        }
    }

    /// Only Home keeps the project sidebar; the rest own the whole detail area.
    public var showsProjectSidebar: Bool { self == .home }
}

/// One screen the back/forward buttons can revisit: a rail section, or on Home
/// a chat inside a project (`projectPath` non-empty) or as retained history
/// without one (empty).
public struct NavigationDestination: Equatable, Sendable {
    public var projectPath: String
    public var conversationID: String?
    public var section: AppSection

    public init(projectPath: String, conversationID: String?, section: AppSection = .home) {
        self.projectPath = projectPath
        self.conversationID = conversationID
        self.section = section
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
        guard section != .home || bridge.selectedID != nil else { return }
        let destination = NavigationDestination(
            projectPath: workspacePath,
            conversationID: section == .home ? bridge.selectedID : nil,
            section: section
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

    /// Switches the rail section, recording the screen being left.
    public func open(_ target: AppSection) {
        guard section != target else { return }
        commitNavigationDestination()
        if target != .home { isSimulatorPresented = false }
        section = target
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
        if destination.section != .home {
            section = destination.section
            return true
        }
        section = .home
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

    /// Opens the conversation that produced a notification, even if it belongs
    /// to another configured project or to retained recent history.
    @discardableResult
    public func openNotificationConversation(_ notification: InboxNotification) -> Bool {
        guard let conversationID = notification.conversationID else { return false }
        section = .home

        if bridge.conversations.contains(where: { $0.id == conversationID }) {
            selectConversation(conversationID)
            return true
        }

        if let path = notification.conversationPath,
           let canonicalPath = Self.canonicalExistingWorkspacePath(path) {
            if workspacePath != canonicalPath && workspacePath != path {
                setWorkspace(path)
                guard workspacePath == canonicalPath || workspacePath == path else { return false }
            }
            guard bridge.conversations.contains(where: { $0.id == conversationID }) else { return false }
            selectConversation(conversationID)
            return true
        }

        if let conversation = bridge.conversations(outsideProjects: connectedProjectPaths)
            .first(where: { $0.id == conversationID }) {
            return openRecentConversation(conversation)
        }
        return false
    }
}

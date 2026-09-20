// Copyright (c) 2026 DOTS
// Sidebar navigation row and conversation drag-reorder modifier.

import AppKit
import SwiftUI
import DotsHarnessCore
import HarnessPluginKit
import PluginRuntime

struct SidebarNavigationRow: View {
    let title: String
    let systemImage: String
    var shortcut: String? = nil
    var trailingSystemImage: String? = nil
    var action: (() -> Void)? = nil
    @State private var isHovered = false

    var body: some View {
        if let action {
            Button(action: action) {
                content
            }
            .buttonStyle(.plain)
        } else {
            content
        }
    }

    private var content: some View {
        HStack(spacing: 9) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .regular))
                .frame(width: 22)

            Text(title)
                .font(.system(size: 14, weight: .regular))
                .lineLimit(1)

            Spacer(minLength: 0)

            if let shortcut {
                Text(shortcut)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.primary.opacity(0.075), in: Capsule())
            }

            if let trailingSystemImage {
                Image(systemName: trailingSystemImage)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.secondary)
                    .frame(width: 22)
            }
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 9)
        .frame(height: 32)
        .background(
            isHovered ? Color.primary.opacity(0.10) : Color.clear,
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }
}

/// Enables drag-to-reorder on a conversation row when its project's sort
/// order is set to Manual. A no-op when `project` is nil or sort isn't manual.
struct ConversationDragReorderModifier: ViewModifier {
    let conversationID: String
    let project: String?
    let model: AppModel
    let currentOrder: [String]

    func body(content: Content) -> some View {
        if let project, model.sortOrder(forProject: project) == .manual {
            content
                .draggable(conversationID)
                .dropDestination(for: String.self) { items, _ in
                    guard let draggedID = items.first, draggedID != conversationID else { return false }
                    model.moveConversation(
                        draggedID,
                        before: conversationID,
                        inProject: project,
                        currentOrder: currentOrder
                    )
                    return true
                }
        } else {
            content
        }
    }
}

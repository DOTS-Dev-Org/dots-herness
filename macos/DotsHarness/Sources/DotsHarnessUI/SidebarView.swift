// Copyright (c) 2026 DOTS
// Native workspace, account and conversation navigation.

import SwiftUI
import DotsHarnessCore
import HarnessPluginKit
import PluginRuntime

struct SidebarView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var bridge: AgentBridge
    let logo: Image?

    @State private var showSignOutConfirmation = false
    @State private var isSearchVisible = false
    @State private var searchText = ""
    @State private var isProjectsExpanded = false
    @State private var isRecentExpanded = false
    @State private var isWorkspaceExpanded = true
    @State private var isProjectHovered = false
    @State private var hoveredConversationID: String?
    @State private var showRemoveProjectConfirmation = false
    @State private var showAllProjectChats = false

    private let visibleConversationLimit = 7

    init(model: AppModel, logo: Image? = nil) {
        self.model = model
        self.bridge = model.bridge
        self.logo = logo
    }

    var body: some View {
        VStack(spacing: 0) {
            sidebarHeader

            if isSearchVisible {
                searchField
            }

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    primaryNavigation

                    sidebarSectionHeader(
                        title: AppCopy.text("sidebar.projects"),
                        isExpanded: $isProjectsExpanded,
                        showsStatusDot: !model.workspacePath.isEmpty
                    )

                    if isProjectsExpanded {
                        projectsSection
                    }

                    sidebarSectionHeader(
                        title: AppCopy.text("sidebar.recent"),
                        isExpanded: $isRecentExpanded,
                        showsStatusDot: bridge.isBusy
                    )

                    if isRecentExpanded {
                        recentSection
                    }

                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            accountFooter
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationSplitViewColumnWidth(min: 250, ideal: 280, max: 340)
        .alert(AppCopy.text("sidebar.signOutQuestion"), isPresented: $showSignOutConfirmation) {
            Button(AppCopy.text("common.cancel"), role: .cancel) {}
            Button(AppCopy.text("sidebar.signOut"), role: .destructive) {
                model.signOut()
            }
        } message: {
            Text(AppCopy.text("sidebar.signOutMessage"))
        }
        .confirmationDialog(
            AppCopy.text("sidebar.removeProjectQuestion"),
            isPresented: $showRemoveProjectConfirmation,
            titleVisibility: .visible
        ) {
            Button(AppCopy.text("sidebar.removeProject"), role: .destructive) {
                model.setWorkspace("")
            }
            Button(AppCopy.text("common.cancel"), role: .cancel) {}
        } message: {
            Text(AppCopy.text("sidebar.removeProjectMessage"))
        }
        .onChange(of: searchText) { _, value in
            if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                isProjectsExpanded = true
                isRecentExpanded = true
            }
        }
        .onChange(of: model.workspacePath) { _, value in
            if value.isEmpty {
                isProjectsExpanded = false
                isWorkspaceExpanded = false
            }
        }
    }

    private var sidebarHeader: some View {
        HStack(spacing: 10) {
            if let logo {
                logo
                    .resizable()
                    .scaledToFit()
                    .frame(width: 22, height: 22)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            }

            HStack(spacing: 5) {
                Text("Herness")
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(.primary)

            Spacer(minLength: 0)

            Button {
                withAnimation(.easeOut(duration: 0.16)) {
                    isSearchVisible.toggle()
                    if !isSearchVisible {
                        searchText = ""
                    }
                }
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
            .help(AppCopy.text("sidebar.search"))

            ZStack(alignment: .topTrailing) {
                Image(systemName: bridge.isBusy ? "bell.badge.fill" : "bell")
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 24, height: 24)

                if bridge.connection != nil {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 6, height: 6)
                        .offset(x: -2, y: 2)
                }
            }
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
            .help(AppCopy.text("sidebar.status"))
        }
        .padding(.horizontal, 15)
        .padding(.top, 12)
        .padding(.bottom, 9)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)

            TextField(AppCopy.text("sidebar.search"), text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 30)
        .background(
            Color.primary.opacity(0.075),
            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 5)
    }

    private var primaryNavigation: some View {
        VStack(spacing: 2) {
            SidebarNavigationRow(
                title: AppCopy.text("sidebar.newChat"),
                systemImage: "square.and.pencil",
                action: model.newConversation
            )
            .disabled(model.workspacePath.isEmpty || bridge.isBusy)

            SidebarNavigationRow(title: AppCopy.text("sidebar.pullRequests"), systemImage: "arrow.triangle.branch")
            SidebarNavigationRow(title: AppCopy.text("sidebar.sites"), systemImage: "square.grid.2x2")
            SidebarNavigationRow(title: AppCopy.text("sidebar.scheduled"), systemImage: "clock")
            SidebarNavigationRow(title: AppCopy.text("sidebar.plugins"), systemImage: "circle.dotted")
        }
        .padding(.bottom, 16)
    }

    private func sidebarSectionHeader(
        title: String,
        isExpanded: Binding<Bool>,
        showsStatusDot: Bool
    ) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.16)) {
                isExpanded.wrappedValue.toggle()
            }
        } label: {
            HStack(spacing: 7) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)

                Spacer(minLength: 0)

                if showsStatusDot {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 7, height: 7)
                }

                Image(systemName: isExpanded.wrappedValue ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 20)
            }
            .padding(.horizontal, 5)
            .frame(height: 29)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isExpanded.wrappedValue ? AppCopy.text("sidebar.hide") : AppCopy.text("sidebar.show"))
    }

    private var projectsSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            if model.workspacePath.isEmpty {
                Button(action: model.chooseWorkspace) {
                    HStack(spacing: 8) {
                        Image(systemName: "folder.badge.plus")
                            .font(.system(size: 13, weight: .medium))
                        Text(AppCopy.text("sidebar.selectProject"))
                            .font(.system(size: 13))
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 9)
                    .frame(height: 30)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                projectlessConversationRow
            } else {
                projectRow

                if isWorkspaceExpanded {
                    projectConversations
                }

                projectlessConversationRow
            }
        }
        .padding(.top, 3)
        .padding(.bottom, 13)
    }

    private var projectlessConversationRow: some View {
        Button(action: model.startWithoutProject) {
            HStack(spacing: 8) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.system(size: 13, weight: .medium))
                Text(AppCopy.text("sidebar.continueWithoutProject"))
                    .font(.system(size: 13))
                Spacer(minLength: 0)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 9)
            .frame(height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var projectRow: some View {
        HStack(spacing: 3) {
            Button {
                withAnimation(.easeOut(duration: 0.16)) {
                    isWorkspaceExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "folder")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)

                    Text(workspaceName)
                        .font(.system(size: 14))
                        .lineLimit(1)

                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isProjectHovered {
                Menu {
                    projectMenuItems
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 22, height: 24)
                }
                .menuStyle(.borderlessButton)
                .help(AppCopy.text("sidebar.projectOptions"))

                Button(action: model.chooseWorkspace) {
                    Image(systemName: "pencil")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 22, height: 24)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(AppCopy.text("sidebar.editProject"))
            }
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 8)
        .frame(minHeight: 30)
        .background(
            Color.primary.opacity(0.105),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .onHover { hovering in
            isProjectHovered = hovering
        }
        .contextMenu {
            projectMenuItems
        }
    }

    @ViewBuilder
    private var projectMenuItems: some View {
        Button(AppCopy.text("sidebar.edit"), systemImage: "pencil") {
            model.chooseWorkspace()
        }
        Button(AppCopy.text("sidebar.showInFinder"), systemImage: "folder") {
            model.revealWorkspace()
        }
        Divider()
        Button(AppCopy.text("sidebar.removeProject"), systemImage: "xmark", role: .destructive) {
            showRemoveProjectConfirmation = true
        }
    }

    private var projectConversations: some View {
        VStack(alignment: .leading, spacing: 1) {
            let conversations = orderedConversations(model.conversations)
            let visible = showAllProjectChats
                ? conversations
                : Array(conversations.prefix(visibleConversationLimit))

            if visible.isEmpty && !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(AppCopy.text("sidebar.noChats"))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 34)
                    .padding(.vertical, 6)
            } else if !visible.isEmpty {
                ForEach(visible) { conversation in
                    conversationRow(conversation)
                }

                if conversations.count > visibleConversationLimit {
                    Button {
                        withAnimation(.easeOut(duration: 0.16)) {
                            showAllProjectChats.toggle()
                        }
                    } label: {
                        Text(showAllProjectChats
                            ? AppCopy.text("sidebar.showLess")
                            : AppCopy.text("sidebar.showMore"))
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .padding(.leading, 34)
                            .frame(height: 28, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.top, 2)
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 1) {
            let conversations = recentConversations

            if conversations.isEmpty && !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(AppCopy.text("sidebar.noRecent"))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
            } else {
                ForEach(conversations) { conversation in
                    conversationRow(conversation, indented: false)
                }
            }
        }
        .padding(.top, 3)
        .padding(.bottom, 13)
    }

    private func conversationRow(
        _ conversation: Conversation,
        indented: Bool = true
    ) -> some View {
        HStack(spacing: 0) {
            Button {
                model.selectedConversationID = conversation.id
            } label: {
                Text(conversation.title)
                    .font(.system(size: 14))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)

            HStack(spacing: 2) {
                conversationStatus(conversation)

                if hoveredConversationID == conversation.id {
                    Button {
                        bridge.togglePinned(conversation.id)
                    } label: {
                        Image(systemName: conversation.pinned ? "pin.fill" : "pin")
                            .font(.system(size: 12, weight: .medium))
                            .frame(width: 22, height: 24)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(conversation.pinned ? Color.accentColor : .secondary)
                    .help(AppCopy.text(
                        conversation.pinned ? "sidebar.unpinChat" : "sidebar.pinChat"
                    ))
                    .accessibilityLabel(AppCopy.text(
                        conversation.pinned ? "sidebar.unpinChat" : "sidebar.pinChat"
                    ))

                    Button {
                        bridge.setArchived(conversation.id, archived: true)
                    } label: {
                        Image(systemName: "archivebox")
                            .font(.system(size: 12, weight: .medium))
                            .frame(width: 22, height: 24)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help(AppCopy.text("sidebar.archiveChat"))
                    .accessibilityLabel(AppCopy.text("sidebar.archiveChat"))
                }
            }
            .frame(width: 72, alignment: .trailing)
        }
        .foregroundStyle(.primary)
        .padding(.leading, indented ? 34 : 9)
        .padding(.trailing, 6)
        .frame(minHeight: 30)
        .background(
            model.selectedConversationID == conversation.id
                ? Color.primary.opacity(0.105)
                : Color.clear,
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering {
                hoveredConversationID = conversation.id
            } else if hoveredConversationID == conversation.id {
                hoveredConversationID = nil
            }
        }
        .contextMenu {
            Button(
                AppCopy.text(conversation.pinned ? "sidebar.unpinChat" : "sidebar.pinChat"),
                systemImage: conversation.pinned ? "pin.slash" : "pin"
            ) {
                bridge.togglePinned(conversation.id)
            }
            Button(AppCopy.text("sidebar.archiveChat"), systemImage: "archivebox") {
                bridge.setArchived(conversation.id, archived: true)
            }
            Divider()
            Button(AppCopy.text("sidebar.deleteChat"), systemImage: "trash", role: .destructive) {
                bridge.deleteConversation(conversation.id)
            }
        }
    }

    @ViewBuilder
    private func conversationStatus(_ conversation: Conversation) -> some View {
        if conversation.running {
            ProgressView()
                .controlSize(.mini)
                .tint(Color.secondary)
                .frame(width: 16, height: 16)
                .accessibilityLabel(AppCopy.text("sidebar.chatRunning"))
        } else if !conversation.blank {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.blue)
                .frame(width: 16, height: 16)
                .accessibilityLabel(AppCopy.text("sidebar.chatCompleted"))
        }
    }

    private var accountFooter: some View {
        VStack(spacing: 0) {
            Divider()

            HStack(spacing: 4) {
                Menu {
                    Button {
                        model.presentUsage()
                    } label: {
                        Label(AppCopy.text("sidebar.usage"), systemImage: "chart.bar.fill")
                    }

                    Button {
                        model.isPetVisible.toggle()
                    } label: {
                        Label(
                            model.isPetVisible
                                ? AppCopy.text("pet.hide")
                                : AppCopy.text("pet.show"),
                            systemImage: model.isPetVisible ? "eye.slash" : "pawprint.fill"
                        )
                    }

                    Button {
                        model.presentSettings()
                    } label: {
                        Label(AppCopy.text("sidebar.settings"), systemImage: "gearshape")
                    }

                    Divider()

                    Button(role: .destructive) {
                        showSignOutConfirmation = true
                    } label: {
                        Label(AppCopy.text("sidebar.signOut"), systemImage: "rectangle.portrait.and.arrow.right")
                    }
                } label: {
                    HStack(spacing: 9) {
                        AccountBadge(size: 20)
                        Text("DOTS YAZILIM")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.leading, 13)
                    .frame(height: 40)
                    .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .help(AppCopy.text("sidebar.accountOptions"))

                Button {
                    model.presentUsage()
                } label: {
                    Image(systemName: "questionmark.circle")
                        .font(.system(size: 14, weight: .medium))
                        .frame(width: 28, height: 28)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding(.trailing, 10)
                .help(AppCopy.text("sidebar.accountUsage"))
            }
        }
        .background(.bar)
    }

    private var workspaceName: String {
        URL(fileURLWithPath: model.workspacePath).lastPathComponent
    }

    private var recentConversations: [Conversation] {
        orderedConversations(projectlessConversations)
            .prefix(visibleConversationLimit)
            .map { $0 }
    }

    private var projectlessConversations: [Conversation] {
        model.workspacePath.isEmpty ? model.conversations : bridge.projectlessConversations
    }

    private func orderedConversations(_ conversations: [Conversation]) -> [Conversation] {
        filteredConversations(conversations)
            .sorted {
                if $0.pinned != $1.pinned { return $0.pinned }
                return latestActivity(of: $0) > latestActivity(of: $1)
            }
    }

    private func filteredConversations(_ conversations: [Conversation]) -> [Conversation] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let visible = conversations.filter { !$0.blank && !$0.archived }
        guard !query.isEmpty else { return visible }
        return visible.filter { conversation in
            conversation.title.localizedCaseInsensitiveContains(query)
                || conversation.messages.contains { $0.text.localizedCaseInsensitiveContains(query) }
        }
    }

    private func latestActivity(of conversation: Conversation) -> Date {
        conversation.messages.map(\.createdAt).max() ?? .distantPast
    }
}

private struct SidebarNavigationRow: View {
    let title: String
    let systemImage: String
    var action: (() -> Void)? = nil

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
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 16)

            Text(title)
                .font(.system(size: 14))
                .lineLimit(1)

            Spacer(minLength: 0)
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 9)
        .frame(height: 30)
        .contentShape(Rectangle())
    }
}

private struct AccountBadge: View {
    var size: CGFloat = 20

    var body: some View {
        Text("DY")
            .font(.system(size: max(8, size * 0.43), weight: .bold, design: .rounded))
            .foregroundStyle(Color.white.opacity(0.9))
            .frame(width: size, height: size)
            .background(Color(red: 1, green: 0.58, blue: 0.08), in: Circle())
    }
}

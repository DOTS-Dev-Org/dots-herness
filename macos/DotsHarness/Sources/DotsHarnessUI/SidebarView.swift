// Copyright (c) 2026 DOTS
// Native workspace, account and conversation navigation.

import AppKit
import SwiftUI
import DotsHarnessCore
import HarnessPluginKit
import PluginRuntime

struct SidebarView: View {
    @ObservedObject var model: AppModel
    let logo: Image?

    private var bridge: AgentBridge { model.bridge }

    @State private var showSignOutConfirmation = false
    @State private var isAccountMenuPresented = false
    @State private var isSearchVisible = false
    @State private var searchText = ""
    @State private var isProjectsExpanded = true
    @State private var isRecentExpanded = true
    /// Path of the project whose chat sublist is open. Chats are only ever
    /// loaded for the active project (`model.workspacePath`), so this is only
    /// meaningful when it matches the active project.
    @State private var expandedProjectPath: String?
    @State private var hoveredConversationID: String?
    @State private var projectPendingRemoval: String?
    @State private var projectEditorTarget: ProjectEditorTarget?
    @State private var hoveredProjectTitlePath: String?
    /// Section header the cursor is over; its chevron and actions only show then.
    @State private var hoveredSectionTitle: String?
    @State private var projectPreviewPath: String?
    @State private var showAllProjectChats = false

    private let visibleConversationLimit = 7

    /// Sidebar-owned voice session. No `onTranscript` closure, so a finished
    /// transcript is sent straight as a message (same as the floating pet).
    @StateObject private var voiceInput: PetVoiceInput

    init(model: AppModel, logo: Image? = nil) {
        self.model = model
        self.logo = logo
        _voiceInput = StateObject(wrappedValue: PetVoiceInput(model: model))
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            VStack(spacing: 0) {
                sidebarHeader

                if isSearchVisible {
                    searchField
                }

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        if model.activeArea == .chat {
                            chatSidebarContent
                        } else {
                            primaryNavigation

                            sectionHeader(
                                title: AppCopy.text("sidebar.projects"),
                                isExpanded: $isProjectsExpanded,
                                showsStatusDot: model.conversations.contains {
                                    $0.unread && !$0.running && !$0.blank && !$0.archived
                                }
                            ) {
                                projectsSectionActions
                            }

                            if isProjectsExpanded {
                                projectsSection
                            }

                            sectionHeader(
                                title: AppCopy.text("sidebar.recent"),
                                isExpanded: $isRecentExpanded,
                                showsStatusDot: bridge.anyRunBusy
                            ) {
                                EmptyView()
                            }

                            if isRecentExpanded {
                                recentSection
                            }
                        }

                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                accountFooter
            }

            if isAccountMenuPresented {
                Button(action: dismissAccountMenu) {
                    Color.black.opacity(0.08)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(AppCopy.text("common.cancel"))
                .zIndex(1)

                AccountMenuPopover(
                    account: model.account,
                    isPetVisible: model.isPetVisible,
                    onUsage: {
                        dismissAccountMenu()
                        model.presentUsage()
                    },
                    onTogglePet: {
                        dismissAccountMenu()
                        model.isPetVisible.toggle()
                    },
                    onSettings: {
                        dismissAccountMenu()
                        model.presentSettings()
                    },
                    onSignOut: {
                        dismissAccountMenu()
                        showSignOutConfirmation = true
                    }
                )
                .padding(.horizontal, 8)
                .padding(.bottom, 64)
                .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .bottomLeading)))
                .zIndex(2)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationSplitViewColumnWidth(min: 250, ideal: 280, max: 340)
        .onExitCommand {
            if isAccountMenuPresented {
                dismissAccountMenu()
            }
        }
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
            isPresented: Binding(
                get: { projectPendingRemoval != nil },
                set: { if !$0 { projectPendingRemoval = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(AppCopy.text("sidebar.removeProject"), role: .destructive) {
                if let path = projectPendingRemoval {
                    model.removeProject(path)
                }
                projectPendingRemoval = nil
            }
            Button(AppCopy.text("common.cancel"), role: .cancel) {
                projectPendingRemoval = nil
            }
        } message: {
            Text(AppCopy.text("sidebar.removeProjectMessage"))
        }
        .sheet(item: $projectEditorTarget) { target in
            ProjectEditorView(model: model, path: target.id)
        }
        .onChange(of: searchText) { _, value in
            if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                isProjectsExpanded = true
                isRecentExpanded = true
            }
        }
        .onChange(of: model.workspacePath) { _, value in
            if value.isEmpty {
                expandedProjectPath = nil
            }
        }
    }

    private func dismissAccountMenu() {
        withAnimation(.easeInOut(duration: 0.18)) {
            isAccountMenuPresented = false
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
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
            .help(AppCopy.text("sidebar.search"))

            ZStack(alignment: .topTrailing) {
                Image(systemName: bridge.anyRunBusy ? "bell.badge.fill" : "bell")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 22, height: 22)

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
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 7)
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
        VStack(spacing: 1) {
            SidebarNavigationRow(
                title: AppCopy.text("sidebar.newChat"),
                systemImage: "square.and.pencil",
                trailingSystemImage: "plus.circle",
                action: model.newConversation
            )

            SidebarNavigationRow(
                title: AppCopy.text("sidebar.pullRequests"),
                systemImage: "arrow.triangle.branch",
                shortcut: model.shortcut(for: .pullRequests).displayValue,
                action: model.openPullRequests
            )
            .disabled(model.activeProjectForgeURL == nil)

            SidebarNavigationRow(
                title: AppCopy.text("sidebar.sites"),
                systemImage: "square.grid.2x2",
                action: model.openSites
            )
            SidebarNavigationRow(
                title: AppCopy.text("sidebar.scheduled"),
                systemImage: "clock",
                shortcut: model.shortcut(for: .scheduled).displayValue,
                action: model.presentTasks
            )
            SidebarNavigationRow(
                title: AppCopy.text("sidebar.plugins"),
                systemImage: "circle.dotted",
                action: { model.presentSettings(tab: "plugins") }
            )
        }
        .padding(.bottom, 10)
    }

    private var chatSidebarContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            SidebarNavigationRow(
                title: AppCopy.text("sidebar.newChat"),
                systemImage: "square.and.pencil",
                trailingSystemImage: "plus.circle",
                action: { model.newChatConversation() }
            )
            .padding(.bottom, 10)

            sectionHeader(
                title: AppCopy.text("sidebar.projects"),
                isExpanded: $isProjectsExpanded,
                showsStatusDot: model.chatProjects.contains { project in
                    !project.archived && model.chatConversations(in: project.id).contains {
                        $0.unread && !$0.running && !$0.blank && !$0.archived
                    }
                }
            ) {
                Button {
                    promptForText(
                        title: AppCopy.text("sidebar.addProject"),
                        message: AppCopy.text("sidebar.projectTitle")
                    ) { name in
                        let project = model.createChatProject(name: name)
                        model.newChatConversation(in: project.id)
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(AppCopy.text("sidebar.addProject"))
            }

            if isProjectsExpanded {
                ForEach(model.chatProjects.filter { !$0.archived }) { project in
                    chatProjectRow(project)
                }
            }

            // Chats without a project sit outside the projects, as plain chats.
            VStack(alignment: .leading, spacing: 1) {
                ForEach(sortedByActivity(filteredConversations(model.unassignedChatConversations))) { conversation in
                    conversationRow(conversation, indented: false)
                }
            }
            .padding(.top, 8)
        }
    }

    private func chatProjectRow(_ project: ChatProject) -> some View {
        let conversations = filteredConversations(model.chatConversations(in: project.id))
        let isActive = model.selected?.chatProjectID == project.id
        return VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 3) {
                Button {
                    if let conversation = sortedByActivity(conversations).first {
                        model.selectedConversationID = conversation.id
                    } else {
                        model.newChatConversation(in: project.id)
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: project.pinned ? "pin.fill" : "bubble.left.and.bubble.right")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(project.pinned ? Color.accentColor : .secondary)
                        Text(project.name)
                            .font(.system(size: 14))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Menu {
                    Button(project.pinned
                        ? AppCopy.text("sidebar.unpinProject")
                        : AppCopy.text("sidebar.pinProject")) {
                        model.toggleChatProjectPinned(project.id)
                    }
                    Button(AppCopy.text("sidebar.archiveChats")) {
                        model.setChatProjectArchived(project.id, archived: true)
                    }
                    Divider()
                    Button(AppCopy.text("sidebar.deleteChat"), role: .destructive) {
                        model.deleteChatProject(project.id)
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 22, height: 24)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .foregroundStyle(.secondary)

                Button { model.newChatConversation(in: project.id) } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                }
            .padding(.horizontal, 8)
            .frame(minHeight: 30)

            if isActive {
                ForEach(sortedByActivity(conversations).prefix(visibleConversationLimit)) { conversation in
                    conversationRow(conversation)
                }
            }
        }
        .background(
            isActive ? Color.primary.opacity(0.105) : Color.clear,
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
    }

    /// Shared header for the "Projects" and "Recent" sections. Title and chevron
    /// are one toggle; the chevron and the trailing actions stay hidden until
    /// hover (opacity, not removal, so the row never reflows and keyboard and
    /// VoiceOver still reach them).
    private func sectionHeader<Trailing: View>(
        title: String,
        isExpanded: Binding<Bool>,
        showsStatusDot: Bool,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        let isHovered = hoveredSectionTitle == title
        return HStack(spacing: 2) {
            Button {
                withAnimation(.easeOut(duration: 0.16)) {
                    isExpanded.wrappedValue.toggle()
                }
            } label: {
                HStack(spacing: 2) {
                    Text(title)
                        .font(.system(size: 12, weight: .medium))

                    Image(systemName: isExpanded.wrappedValue ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 16, height: 20)
                        .opacity(isHovered ? 1 : 0)
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isExpanded.wrappedValue ? AppCopy.text("sidebar.hide") : AppCopy.text("sidebar.show"))

            Spacer(minLength: 0)

            if showsStatusDot {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 7, height: 7)
            }

            HStack(spacing: 2) {
                trailing()
            }
            .opacity(isHovered ? 1 : 0)
        }
        .padding(.horizontal, 5)
        .frame(height: 26)
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering {
                hoveredSectionTitle = title
            } else if hoveredSectionTitle == title {
                hoveredSectionTitle = nil
            }
        }
    }

    @ViewBuilder
    private var projectsSectionActions: some View {
        Menu {
            sidebarOptionsMenu
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 20, height: 20)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(AppCopy.text("sidebar.editSidebarLayout"))

        Button(action: model.addProject) {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 20, height: 20)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(AppCopy.text("sidebar.addProject"))
    }

    @ViewBuilder
    private var sidebarOptionsMenu: some View {
        Menu(AppCopy.text("sidebar.editSidebarLayout")) {
            Button {
                model.setSidebarLayoutMode(.groupedByProject)
            } label: {
                if model.sidebarLayoutMode == .groupedByProject {
                    Label(AppCopy.text("sidebar.layoutGroupedByProject"), systemImage: "checkmark")
                } else {
                    Text(AppCopy.text("sidebar.layoutGroupedByProject"))
                }
            }
            Button {
                model.setSidebarLayoutMode(.singleList)
            } label: {
                if model.sidebarLayoutMode == .singleList {
                    Label(AppCopy.text("sidebar.layoutSingleList"), systemImage: "checkmark")
                } else {
                    Text(AppCopy.text("sidebar.layoutSingleList"))
                }
            }
        }

        Menu(AppCopy.text("sidebar.sortCriteria")) {
            ForEach([
                ConversationSortOrder.priority,
                .lastUpdate,
                .manual,
            ], id: \.self) { order in
                Button {
                    model.setSortOrder(order, forProject: model.workspacePath)
                } label: {
                    if model.sortOrder(forProject: model.workspacePath) == order {
                        Label(sortOrderTitle(order), systemImage: "checkmark")
                    } else {
                        Text(sortOrderTitle(order))
                    }
                }
            }
        }
        .disabled(model.workspacePath.isEmpty)
    }

    private func sortOrderTitle(_ order: ConversationSortOrder) -> String {
        switch order {
        case .priority: return AppCopy.text("sidebar.sortPriority")
        case .lastUpdate: return AppCopy.text("sidebar.sortLastUpdate")
        case .manual: return AppCopy.text("sidebar.sortManual")
        }
    }

    private var projectsSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            if model.projectPaths.isEmpty {
                Button(action: model.addProject) {
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
            } else if model.sidebarLayoutMode == .singleList {
                ForEach(model.projectPaths, id: \.self) { path in
                    projectRow(path)
                }
                projectConversations
            } else {
                ForEach(projectGroups) { group in
                    if let title = group.title {
                        projectGroupTitle(title, group: group)
                    }
                    ForEach(visibleProjectPaths(for: group), id: \.self) { path in
                        projectRow(path)

                        if model.sidebarLayoutMode == .groupedByProject,
                           path == model.workspacePath,
                           expandedProjectPath == path {
                            projectConversations
                        }
                    }
                }
            }
        }
        .padding(.top, 3)
        .padding(.bottom, 13)
    }

    @ViewBuilder
    private func projectGroupTitle(_ title: String, group: ProjectGroup) -> some View {
        if group.kind == .other,
           OtherProjectVisibility.shouldShowRevealControl(
               group.paths,
               isExpanded: model.showsAllOtherProjects
           ) {
            Button {
                withAnimation(.easeOut(duration: 0.16)) {
                    model.revealAllOtherProjects()
                }
            } label: {
                projectGroupTitleLabel(title)
            }
            .buttonStyle(.plain)
            .help(AppCopy.text("sidebar.showMore"))
            .accessibilityHint(AppCopy.text("sidebar.showMore"))
        } else {
            projectGroupTitleLabel(title)
        }
    }

    private func projectGroupTitleLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.tertiary)
            .padding(.leading, 10)
            .padding(.top, 5)
            .padding(.bottom, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
    }

    private func visibleProjectPaths(for group: ProjectGroup) -> [String] {
        guard group.kind == .other else { return group.paths }
        return OtherProjectVisibility.visiblePaths(
            group.paths,
            isExpanded: model.showsAllOtherProjects
        )
    }

    private func projectRow(_ path: String) -> some View {
        let isActive = path == model.workspacePath
        return HStack(spacing: 3) {
            Button {
                if isActive {
                    withAnimation(.easeOut(duration: 0.16)) {
                        expandedProjectPath = expandedProjectPath == path ? nil : path
                    }
                } else {
                    model.selectProject(path)
                    expandedProjectPath = path
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "folder")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)

                    Text(projectName(path))
                        .font(.system(size: 14))
                        .lineLimit(1)

                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .popover(
                isPresented: Binding(
                    get: { projectPreviewPath == path },
                    set: { if !$0, projectPreviewPath == path { projectPreviewPath = nil } }
                ),
                arrowEdge: .leading
            ) {
                projectPreview(path)
            }
            .onHover { hovering in
                hoveredProjectTitlePath = hovering ? path : (hoveredProjectTitlePath == path ? nil : hoveredProjectTitlePath)
                if hovering {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        if hoveredProjectTitlePath == path { projectPreviewPath = path }
                    }
                } else if projectPreviewPath == path {
                    projectPreviewPath = nil
                }
            }

            Menu {
                projectMenuItems(path)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 22, height: 24)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .foregroundStyle(.secondary)
            .help(AppCopy.text("sidebar.projectOptions"))

            Button { model.newConversation(in: path) } label: {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(AppCopy.text("sidebar.newChat"))
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 8)
        .frame(minHeight: 30)
        .background(
            isActive ? Color.primary.opacity(0.105) : Color.clear,
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .contextMenu {
            projectMenuItems(path)
        }
    }

    @ViewBuilder
    private func projectMenuItems(_ path: String) -> some View {
        Button(
            model.isProjectPinned(path) ? AppCopy.text("sidebar.unpinProject") : AppCopy.text("sidebar.pinProject"),
            systemImage: model.isProjectPinned(path) ? "pin.slash" : "pin"
        ) {
            model.toggleProjectPinned(path)
        }
        Button(AppCopy.text("sidebar.editProject"), systemImage: "gearshape") {
            projectEditorTarget = ProjectEditorTarget(id: path)
        }
        Menu(AppCopy.text("sidebar.projectSection")) {
            Button {
                model.setProjectSection(nil, for: path)
            } label: {
                if model.projectSection(for: path) == nil {
                    Label(AppCopy.text("sidebar.noSection"), systemImage: "checkmark")
                } else {
                    Text(AppCopy.text("sidebar.noSection"))
                }
            }
            ForEach(model.projectSections, id: \.self) { section in
                Button {
                    model.setProjectSection(section, for: path)
                } label: {
                    if model.projectSection(for: path) == section {
                        Label(section, systemImage: "checkmark")
                    } else {
                        Text(section)
                    }
                }
            }
            Divider()
            Button(AppCopy.text("sidebar.newSection"), systemImage: "plus") {
                promptForText(
                    title: AppCopy.text("sidebar.newSection"),
                    message: AppCopy.text("sidebar.newSectionMessage")
                ) { value in
                    if let section = model.createProjectSection(named: value) {
                        model.setProjectSection(section, for: path)
                    }
                }
            }
        }
        Button(AppCopy.text("sidebar.showInFinder"), systemImage: "folder") {
            if path == model.workspacePath {
                model.revealWorkspace()
            } else {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }
        }
        Button(AppCopy.text("sidebar.createPermanentWorktree"), systemImage: "arrow.triangle.branch") {
            promptForText(
                title: AppCopy.text("sidebar.createPermanentWorktree"),
                message: AppCopy.text("sidebar.worktreeNameMessage"),
                defaultValue: "worktree"
            ) { value in
                model.createPermanentWorktree(from: path, named: value)
            }
        }
        .disabled(!model.isGitProject(path))
        Divider()
        Button(AppCopy.text("sidebar.markAllRead"), systemImage: "checkmark") {
            model.markAllChatsRead(forProject: path)
        }
        Button(AppCopy.text("sidebar.archiveChats"), systemImage: "archivebox") {
            model.archiveChats(forProject: path)
        }
        Divider()
        Button(AppCopy.text("sidebar.removeProject"), systemImage: "xmark", role: .destructive) {
            projectPendingRemoval = path
        }
    }

    private var projectConversations: some View {
        VStack(alignment: .leading, spacing: 1) {
            let conversations = orderedConversations(model.conversations, forProject: model.workspacePath)
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
                let order = conversations.map(\.id)
                ForEach(visible) { conversation in
                    conversationRow(
                        conversation,
                        manualReorderProject: model.workspacePath,
                        manualOrder: order
                    )
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

    /// `manualOrder` is the id list the drag-to-reorder modifier needs. It is
    /// passed in because the caller already sorted the list: deriving it per row
    /// re-sorted every chat on every redraw.
    private func conversationRow(
        _ conversation: Conversation,
        indented: Bool = true,
        manualReorderProject: String? = nil,
        manualOrder: [String] = []
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
        .modifier(ConversationDragReorderModifier(
            conversationID: conversation.id,
            project: manualReorderProject,
            model: model,
            currentOrder: manualOrder
        ))
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
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        isAccountMenuPresented.toggle()
                    }
                } label: {
                    HStack(spacing: 9) {
                        AccountBadge(initials: model.account.initials, size: 28)
                        Text(model.account.displayName)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 42)
                    .contentShape(Rectangle())
                    .background(
                        isAccountMenuPresented ? Color.primary.opacity(0.12) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                    )
                }
                .buttonStyle(.plain)
                .help(AppCopy.text("sidebar.accountOptions"))

                voiceControl

                Button {
                    model.presentUsage()
                } label: {
                    Image(systemName: "questionmark.circle")
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 26, height: 26)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding(.trailing, 10)
                .help(AppCopy.text("sidebar.accountUsage"))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
        }
        .background(.bar)
    }

    /// Footer voice control. Idle: a menu to pick the project the voice chat runs
    /// in. Listening: a stop button. No `onTranscript` on `voiceInput`, so a final
    /// transcript is sent straight into the new conversation.
    @ViewBuilder
    private var voiceControl: some View {
        if voiceInput.isListening {
            Button {
                voiceInput.cancelListening()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: voiceInput.state.icon)
                        .font(.system(size: 14, weight: .medium))
                    Text(AppCopy.text("sidebar.voice"))
                        .font(.system(size: 13, weight: .medium))
                }
                .frame(height: 34)
                .foregroundStyle(voiceInput.state.tint)
            }
            .buttonStyle(.plain)
            .help(AppCopy.text("sidebar.voice"))
        } else {
            Menu {
                if model.projectPaths.isEmpty {
                    Button(AppCopy.text("sidebar.addProject"), action: model.addProject)
                } else {
                    ForEach(model.projectPaths, id: \.self) { path in
                        Button(model.projectTitle(for: path)) {
                            model.newConversation(in: path)
                            voiceInput.startListening()
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "waveform")
                        .font(.system(size: 14, weight: .medium))
                    Text(AppCopy.text("sidebar.voice"))
                        .font(.system(size: 13, weight: .medium))
                }
                .padding(.horizontal, 6)
                .frame(height: 34)
                .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(AppCopy.text("sidebar.voice"))
        }
    }

    private func projectName(_ path: String) -> String {
        model.projectTitle(for: path)
    }

    private var projectGroups: [ProjectGroup] {
        let pinned = model.projectPaths.filter { model.isProjectPinned($0) }
        var groups: [ProjectGroup] = []
        if !pinned.isEmpty {
            groups.append(ProjectGroup(
                title: AppCopy.text("sidebar.pinned"),
                paths: pinned,
                kind: .pinned
            ))
        }

        for section in model.projectSections {
            let paths = model.projectPaths.filter {
                !model.isProjectPinned($0) && model.projectSection(for: $0) == section
            }
            if !paths.isEmpty {
                groups.append(ProjectGroup(title: section, paths: paths, kind: .named))
            }
        }

        let other = model.projectPaths.filter {
            !model.isProjectPinned($0) && model.projectSection(for: $0) == nil
        }
        if !other.isEmpty {
            groups.append(ProjectGroup(
                title: AppCopy.text("sidebar.other"),
                paths: other,
                kind: .other
            ))
        }
        return groups
    }

    @ViewBuilder
    private func projectPreview(_ path: String) -> some View {
        let conversations = path == model.workspacePath
            ? model.conversations
            : bridge.conversations(inProject: path)
        let tasks = conversations.filter { !$0.blank && !$0.archived }
        let active = tasks.filter(\.running).count
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .font(.system(size: 18, weight: .medium))
                Text(projectName(path))
                    .font(.system(size: 17, weight: .semibold))
                Spacer(minLength: 8)
                Image(systemName: model.isProjectPinned(path) ? "pin.fill" : "pin")
                    .foregroundStyle(model.isProjectPinned(path) ? Color.accentColor : .secondary)
            }
            Label("\(tasks.count) \(AppCopy.text("sidebar.tasks")) · \(active) \(AppCopy.text("sidebar.active"))", systemImage: "bubble.left.and.bubble.right")
                .foregroundStyle(.secondary)
            if let remote = projectRemote(path) {
                Label(remote, systemImage: "arrow.triangle.branch")
                    .lineLimit(1)
            }
            Label(path, systemImage: "folder")
                .lineLimit(2)
                .textSelection(.enabled)
        }
        .padding(16)
        .frame(width: 330, alignment: .leading)
    }

    private func projectRemote(_ path: String) -> String? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", path, "config", "--get", "remote.origin.url"]
        process.standardOutput = output
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        guard let value = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        let clean = value.hasSuffix(".git") ? String(value.dropLast(4)) : value
        if let scheme = clean.range(of: "://") {
            return String(clean[scheme.upperBound...]).split(separator: "/").suffix(2).joined(separator: "/")
        }
        if let colon = clean.firstIndex(of: ":") {
            return String(clean[clean.index(after: colon)...]).split(separator: "/").suffix(2).joined(separator: "/")
        }
        return clean.split(separator: "/").suffix(2).joined(separator: "/")
    }

    private func promptForText(
        title: String,
        message: String,
        defaultValue: String = "",
        onCommit: @escaping (String) -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        let field = NSTextField(string: defaultValue)
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: AppCopy.text("common.save"))
        alert.addButton(withTitle: AppCopy.text("common.cancel"))
        if alert.runModal() == .alertFirstButtonReturn {
            onCommit(field.stringValue)
        }
    }

    private var recentConversations: [Conversation] {
        orderedConversations(projectlessConversations, forProject: nil)
            .prefix(visibleConversationLimit)
            .map { $0 }
    }

    /// "Recent" holds every chat no listed project owns: chats started without a
    /// project, plus chats whose project was removed while they were kept.
    private var projectlessConversations: [Conversation] {
        // Coding "Recent" = chats whose project was removed: they keep a cwd.
        // Projectless chats belong to the Chat area and never show here.
        bridge.conversations(outsideProjects: model.projectPaths)
            .filter { ConversationStore.normalizedPath($0.cwd) != nil }
    }

    /// `forProject` picks the sort order to apply; pass `nil` for lists (like
    /// "Recent") that aren't scoped to one project's own preference.
    private func orderedConversations(_ conversations: [Conversation], forProject path: String?) -> [Conversation] {
        let visible = filteredConversations(conversations)
        let order = path.map(model.sortOrder(forProject:)) ?? .lastUpdate
        switch order {
        case .lastUpdate:
            return sortedByActivity(visible)
        case .priority:
            // ponytail: Conversation has no explicit priority field yet; approximate
            // priority as pinned-first, then title, until a real priority field exists.
            return visible.sorted {
                if $0.pinned != $1.pinned { return $0.pinned }
                return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
        case .manual:
            guard let path else { return sortedByActivity(visible) }
            let manualOrder = model.projectManualOrder[path] ?? []
            let rank = Dictionary(uniqueKeysWithValues: manualOrder.enumerated().map { ($1, $0) })
            return visible.sorted {
                if $0.pinned != $1.pinned { return $0.pinned }
                let lhs = rank[$0.id] ?? Int.max
                let rhs = rank[$1.id] ?? Int.max
                if lhs != rhs { return lhs < rhs }
                return latestActivity(of: $0) > latestActivity(of: $1)
            }
        }
    }

    private func filteredConversations(_ conversations: [Conversation]) -> [Conversation] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let visible = conversations.filter { !$0.blank && !$0.archived }
        guard !query.isEmpty else { return visible }
        return visible.filter { conversation in
            conversation.title.localizedCaseInsensitiveContains(query)
                || bridge.contentMatches(conversation, query: query)
        }
    }

    /// Pinned first, then most recent activity. The activity date is computed
    /// once per conversation instead of on every comparison: it walks the whole
    /// message list, and the sidebar sorts these lists on every redraw.
    private func sortedByActivity(_ conversations: [Conversation]) -> [Conversation] {
        conversations
            .map { (conversation: $0, activity: latestActivity(of: $0)) }
            .sorted {
                if $0.conversation.pinned != $1.conversation.pinned { return $0.conversation.pinned }
                return $0.activity > $1.activity
            }
            .map(\.conversation)
    }

    private func latestActivity(of conversation: Conversation) -> Date {
        conversation.activityDate
    }
}

private struct AccountMenuPopover: View {
    let account: AccountIdentity
    let isPetVisible: Bool
    let onUsage: () -> Void
    let onTogglePet: () -> Void
    let onSettings: () -> Void
    let onSignOut: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                AccountBadge(initials: account.initials, size: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(account.displayName)
                        .font(.system(size: 15, weight: .medium))
                        .lineLimit(1)

                    Text(account.isSignedIn ? "Plus" : AppCopy.text("sidebar.signOut"))
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 12)

            Divider()
                .opacity(0.7)

            VStack(spacing: 2) {
                AccountMenuRow(
                    title: AppCopy.text("sidebar.usage"),
                    systemImage: "chart.bar.fill",
                    trailingSystemImage: "chevron.right",
                    action: onUsage
                )
                AccountMenuRow(
                    title: isPetVisible ? AppCopy.text("pet.hide") : AppCopy.text("pet.show"),
                    systemImage: isPetVisible ? "eye.slash" : "eye",
                    shortcut: "⌥Space",
                    action: onTogglePet
                )
                AccountMenuRow(
                    title: AppCopy.text("sidebar.settings"),
                    systemImage: "gearshape",
                    shortcut: "⌘,",
                    action: onSettings
                )

                Divider()
                    .padding(.vertical, 2)

                AccountMenuRow(
                    title: AppCopy.text("sidebar.signOut"),
                    systemImage: "rectangle.portrait.and.arrow.right",
                    isDestructive: true,
                    role: .destructive,
                    action: onSignOut
                )
            }
            .padding(6)
        }
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.primary.opacity(0.16), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.24), radius: 24, y: 12)
    }
}

private struct AccountMenuRow: View {
    let title: String
    let systemImage: String
    var trailingSystemImage: String? = nil
    var shortcut: String? = nil
    var isDestructive = false
    var role: ButtonRole? = nil
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(role: role, action: action) {
            HStack(spacing: 13) {
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .regular))
                    .frame(width: 22)

                Text(title)
                    .font(.system(size: 13, weight: .regular))
                    .lineLimit(1)

                Spacer(minLength: 10)

                if let shortcut {
                    Text(shortcut)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }

                if let trailingSystemImage {
                    Image(systemName: trailingSystemImage)
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(isDestructive ? Color.red : Color.primary)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 32, maxHeight: 32)
            .background(
                isHovered ? Color.primary.opacity(0.10) : Color.clear,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

private enum ProjectGroupKind: Equatable {
    case pinned
    case named
    case other
}

private struct ProjectGroup: Identifiable {
    let title: String?
    let paths: [String]
    let kind: ProjectGroupKind
    var id: String { "\(title ?? "__other__"):\(paths.first ?? "")" }
}

/// Pure presentation rules for the unsectioned project group. Kept separate
/// from `SidebarView` state so the five-project boundary remains unit-testable.
enum OtherProjectVisibility {
    static let limit = 5

    static func visiblePaths(_ paths: [String], isExpanded: Bool) -> [String] {
        isExpanded ? paths : Array(paths.prefix(limit))
    }

    static func shouldShowRevealControl(_ paths: [String], isExpanded: Bool) -> Bool {
        !isExpanded && paths.count > limit
    }
}

private struct ProjectEditorTarget: Identifiable {
    let id: String
}

private struct ProjectEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: AppModel
    let path: String
    @State private var title: String
    @State private var searchFolders: [String]
    @State private var showRemoveConfirmation = false

    init(model: AppModel, path: String) {
        self.model = model
        self.path = path
        _title = State(initialValue: model.projectTitle(for: path))
        _searchFolders = State(initialValue: model.projectSearchFolders(for: path))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(AppCopy.text("sidebar.editProject"))
                .font(.title2.weight(.semibold))
                .padding(.bottom, 16)

            Form {
                TextField(AppCopy.text("sidebar.projectTitle"), text: $title)

                Section(AppCopy.text("sidebar.searchFolders")) {
                    folderRow(path, removable: false)
                    ForEach(searchFolders, id: \.self) { folder in
                        folderRow(folder, removable: true)
                    }
                    Button(AppCopy.text("sidebar.addExtraFolder"), systemImage: "plus") {
                        addFolder()
                    }
                }
            }

            Divider().padding(.top, 12)

            HStack {
                Button(AppCopy.text("sidebar.removeLocalProject"), role: .destructive) {
                    showRemoveConfirmation = true
                }
                Spacer()
                Button(AppCopy.text("common.cancel")) { dismiss() }
                Button(AppCopy.text("common.save")) {
                    model.saveProjectMetadata(for: path, title: title, searchFolders: searchFolders)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 14)
        }
        .padding(24)
        .frame(width: 520, height: 430)
        .confirmationDialog(
            AppCopy.text("sidebar.removeProjectQuestion"),
            isPresented: $showRemoveConfirmation,
            titleVisibility: .visible
        ) {
            Button(AppCopy.text("sidebar.removeLocalProject"), role: .destructive) {
                model.removeProject(path)
                dismiss()
            }
            Button(AppCopy.text("common.cancel"), role: .cancel) {}
        } message: {
            Text(AppCopy.text("sidebar.removeProjectMessage"))
        }
    }

    @ViewBuilder
    private func folderRow(_ folder: String, removable: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "folder")
                .foregroundStyle(.secondary)
            Text(folder)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            if removable {
                Button {
                    searchFolders.removeAll { $0 == folder }
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = AppCopy.text("sidebar.addExtraFolder")
        panel.begin { response in
            guard response == .OK else { return }
            let paths = panel.urls.map { $0.standardizedFileURL.resolvingSymlinksInPath().path }
            for value in paths where value != path && !searchFolders.contains(value) {
                searchFolders.append(value)
            }
        }
    }
}

private struct SidebarNavigationRow: View {
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

private struct AccountBadge: View {
    var initials: String
    var size: CGFloat = 22

    var body: some View {
        Text(initials)
            .font(.system(size: max(8, size * 0.43), weight: .bold, design: .rounded))
            .foregroundStyle(Color.white.opacity(0.95))
            .frame(width: size, height: size)
            .background(Color(red: 0.20, green: 0.72, blue: 0.55), in: Circle())
    }
}

/// Enables drag-to-reorder on a conversation row when its project's sort
/// order is set to Manual. A no-op when `project` is nil or sort isn't manual.
private struct ConversationDragReorderModifier: ViewModifier {
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

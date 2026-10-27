// Copyright (c) 2026 DOTS
// Native workspace, account and conversation navigation.

import AppKit
import SwiftUI
import DotsHarnessCore
import HarnessPluginKit
import PluginRuntime

private struct SidebarMetricsPreferenceKey: PreferenceKey {
    static let defaultValue: [String: CGFloat] = [:]

    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

struct SidebarView: View {
    @ObservedObject var model: AppModel
    let logo: Image?
    let notificationPopoverWidth: CGFloat

    private var bridge: AgentBridge { model.bridge }

    @State private var isSearchVisible = false
    @State private var isNotificationPopoverPresented = false
    @State private var searchText = ""
    @State private var searchedContentQuery = ""
    @State private var searchedConversationIDs = Set<String>()
    @State private var isSearchingConversationContent = false
    @State private var isProjectsExpanded = true
    @State private var isRecentExpanded = true
    @State private var sidebarMetrics: [String: CGFloat] = [:]
    @State private var hoveredConversationID: String?
    @State private var projectPendingRemoval: String?
    @State private var projectEditorTarget: ProjectEditorTarget?
    @State private var hoveredProjectTitlePath: String?
    @AppStorage("sidebar.projectGrouping") private var projectGroupingRaw = ProjectSidebarGrouping.sections.rawValue
    @AppStorage("sidebar.projectSort") private var projectSortRaw = ProjectSidebarSort.defaultOrder.rawValue
    /// Section header the cursor is over; its chevron and actions only show then.
    @State private var hoveredSectionTitle: String?
    @State private var projectPreviewPath: String?
    /// Projects whose chat list is showing past `visibleConversationLimit`.
    @State private var expandedChatLists: Set<String> = []
    private let visibleConversationLimit = 7

    /// Shown in the sidebar header; the window titlebar stays empty so the name
    /// reads once instead of twice.
    static let appDisplayName: String = {
        let info = Bundle.main.infoDictionary
        return (info?["CFBundleDisplayName"] as? String)
            ?? (info?["CFBundleName"] as? String)
            ?? ProcessInfo.processInfo.processName
    }()

    init(model: AppModel, logo: Image? = nil, notificationPopoverWidth: CGFloat = 340) {
        self.model = model
        self.logo = logo
        self.notificationPopoverWidth = notificationPopoverWidth
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
                        VStack(spacing: 0) {
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
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background {
                            GeometryReader { proxy in
                                Color.clear.preference(
                                    key: SidebarMetricsPreferenceKey.self,
                                    value: ["projectChrome": proxy.size.height]
                                )
                            }
                        }

                        if isProjectsExpanded {
                            projectsSection
                        }

                        sectionHeader(
                            title: AppCopy.text("sidebar.recent"),
                            isExpanded: $isRecentExpanded,
                            showsStatusDot: recentHasRunningConversation
                        ) {
                            EmptyView()
                        }
                        .background {
                            GeometryReader { proxy in
                                Color.clear.preference(
                                    key: SidebarMetricsPreferenceKey.self,
                                    value: ["recentHeader": proxy.size.height]
                                )
                            }
                        }

                        if isRecentExpanded {
                            recentSection
                        }

                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: SidebarMetricsPreferenceKey.self,
                            value: ["viewport": proxy.size.height]
                        )
                    }
                }
                .onPreferenceChange(SidebarMetricsPreferenceKey.self) { measurements in
                    for (key, value) in measurements {
                        guard abs((sidebarMetrics[key] ?? 0) - value) > 0.5 else { continue }
                        sidebarMetrics[key] = value
                    }
                }

            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
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
        .task(id: "\(searchText)-\(bridge.conversationListRevision)") {
            await updateContentSearch()
        }
        .onChange(of: model.workspacePath) { _, value in
            // Opening a project reveals its chats. Nothing is ever removed here:
            // switching or adding a project must leave the other open lists open.
            if !value.isEmpty { model.setProjectChatsExpanded(true, for: value) }
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

            Text(Self.appDisplayName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .allowsHitTesting(false)

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

            Button {
                isNotificationPopoverPresented.toggle()
            } label: {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: bridge.anyRunBusy ? "bell.badge.fill" : "bell")
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 22, height: 22)

                    if model.notificationInbox.unreadCount > 0 {
                        Text(model.notificationInbox.unreadCount > 9 ? "9+" : "\(model.notificationInbox.unreadCount)")
                            .font(.system(size: 7, weight: .bold).monospacedDigit())
                            .foregroundStyle(.white)
                            .frame(minWidth: 12, minHeight: 12)
                            .background(Color.accentColor, in: Capsule())
                            .offset(x: 4, y: -3)
                    } else if bridge.connection != nil {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 6, height: 6)
                            .offset(x: -2, y: 2)
                    }
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(AppCopy.text("notifications.title"))
            .accessibilityLabel(Text(model.notificationInbox.unreadCount > 0
                ? AppCopy.format("notifications.unreadCount", model.notificationInbox.unreadCount)
                : AppCopy.text("notifications.title")))
            .inWindowPopover(
                isPresented: $isNotificationPopoverPresented,
                alignment: .trailing,
                width: notificationPopoverWidth,
                cornerRadius: 18,
                verticalEdge: .bottom
            ) {
                NotificationInboxPopover(inbox: model.notificationInbox) { item in
                    model.notificationInbox.markRead(item.id)
                    if item.conversationID != nil {
                        _ = model.openNotificationConversation(item)
                    }
                    isNotificationPopoverPresented = false
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 7)
        .zIndex(isNotificationPopoverPresented ? 2 : 0)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)

            TextField(AppCopy.text("sidebar.search"), text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))

            if isSearchingConversationContent {
                ProgressView()
                    .controlSize(.mini)
                    .frame(width: 14, height: 14)
                    .accessibilityHidden(true)
            }

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
        }
        .padding(.bottom, 10)
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
        Menu(AppCopy.text("sidebar.groupBy")) {
            ForEach(ProjectSidebarGrouping.allCases, id: \.self) { grouping in
                Button {
                    projectGroupingRaw = grouping.rawValue
                } label: {
                    if currentProjectGrouping == grouping {
                        Label(groupingTitle(grouping), systemImage: "checkmark")
                    } else {
                        Text(groupingTitle(grouping))
                    }
                }
            }
        }

        Menu(AppCopy.text("sidebar.sortProjectsBy")) {
            ForEach(ProjectSidebarSort.allCases, id: \.self) { sort in
                Button {
                    projectSortRaw = sort.rawValue
                } label: {
                    if currentProjectSort == sort {
                        Label(sortTitle(sort), systemImage: "checkmark")
                    } else {
                        Text(sortTitle(sort))
                    }
                }
            }
        }

        Divider()

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

        Button(AppCopy.text("sidebar.newSection"), systemImage: "plus") {
            guard !model.workspacePath.isEmpty else { return }
            promptForText(
                title: AppCopy.text("sidebar.newSection"),
                message: AppCopy.text("sidebar.newSectionMessage")
            ) { value in
                if let section = model.createProjectSection(named: value) {
                    model.setProjectSection(section, for: model.workspacePath)
                }
            }
        }
        .disabled(model.workspacePath.isEmpty)

        Button(AppCopy.text("modelPicker.reset"), systemImage: "arrow.counterclockwise") {
            projectGroupingRaw = ProjectSidebarGrouping.sections.rawValue
            projectSortRaw = ProjectSidebarSort.defaultOrder.rawValue
            model.setSidebarLayoutMode(.groupedByProject)
        }

        Button(AppCopy.text("sidebar.showMore"), systemImage: "ellipsis") {
            model.revealAllOtherProjects()
        }
    }

    private var currentProjectGrouping: ProjectSidebarGrouping {
        ProjectSidebarGrouping(rawValue: projectGroupingRaw) ?? .sections
    }

    private var currentProjectSort: ProjectSidebarSort {
        ProjectSidebarSort(rawValue: projectSortRaw) ?? .defaultOrder
    }

    private func groupingTitle(_ grouping: ProjectSidebarGrouping) -> String {
        switch grouping {
        case .sections: return AppCopy.text("sidebar.projectSection")
        case .folder: return AppCopy.text("settings.folder")
        case .none: return AppCopy.text("sidebar.projectGroupingNone")
        }
    }

    private func sortTitle(_ sort: ProjectSidebarSort) -> String {
        switch sort {
        case .defaultOrder: return AppCopy.text("sidebar.projectSortDefault")
        case .name: return AppCopy.text("studio.home.sort.name")
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
                ForEach(organizedProjectPaths, id: \.self) { path in
                    projectRow(path)
                }
                projectConversations(for: model.workspacePath)
            } else {
                ForEach(projectGroups) { group in
                    if group.kind == .other {
                        // Unsectioned projects start as the recent, fitting prefix;
                        // the Other control belongs after that prefix, not above it.
                        ForEach(visibleProjectPaths(for: group), id: \.self) { path in
                            projectEntry(path)
                        }
                        if shouldRevealOtherProjects(for: group) {
                            otherProjectsRevealControl
                        }
                    } else {
                        if let title = group.title {
                            projectGroupTitle(title)
                        }
                        ForEach(group.paths, id: \.self) { path in
                            projectEntry(path)
                        }
                    }
                }
            }
        }
        .padding(.top, 3)
        .padding(.bottom, 13)
    }

    @ViewBuilder
    private func projectGroupTitle(_ title: String) -> some View {
        projectGroupTitleLabel(title)
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
            isExpanded: model.showsAllOtherProjects,
            limit: visibleOtherProjectCount(for: group)
        )
    }

    private func visibleOtherProjectCount(for group: ProjectGroup) -> Int {
        guard !model.showsAllOtherProjects, !group.paths.isEmpty else { return group.paths.count }
        guard let viewportHeight = sidebarMetrics["viewport"], viewportHeight > 0 else {
            return min(group.paths.count, OtherProjectVisibility.limit)
        }

        let chromeHeight = sidebarMetrics["projectChrome"] ?? 134
        let recentHeaderHeight = sidebarMetrics["recentHeader"] ?? 26
        let scrollInsets: CGFloat = 12
        let projectSectionInsets: CGFloat = 16
        let groupsBeforeOther = projectGroups.prefix { $0.kind != .other }
        let precedingProjectHeight = groupsBeforeOther.reduce(CGFloat.zero) { height, previousGroup in
            height + estimatedProjectGroupHeight(previousGroup) + 2
        }
        let availableHeight = viewportHeight
            - chromeHeight
            - recentHeaderHeight
            - scrollInsets
            - projectSectionInsets
            - precedingProjectHeight
        let projectHeights = group.paths.map(estimatedProjectHeight(for:))
        return OtherProjectVisibility.fittingPrefixCount(
            itemHeights: projectHeights,
            availableHeight: availableHeight,
            revealControlHeight: 30
        )
    }

    private func shouldRevealOtherProjects(for group: ProjectGroup) -> Bool {
        OtherProjectVisibility.shouldShowRevealControl(
            group.paths,
            isExpanded: model.showsAllOtherProjects,
            visibleCount: visibleOtherProjectCount(for: group)
        )
    }

    private var otherProjectsRevealControl: some View {
        Button {
            withAnimation(.easeOut(duration: 0.16)) {
                model.revealAllOtherProjects()
            }
        } label: {
            HStack(spacing: 5) {
                Text(currentProjectGrouping == .none
                    ? AppCopy.text("sidebar.showMore")
                    : AppCopy.text("sidebar.other"))
                    .font(.system(size: 12, weight: .medium))
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                Spacer(minLength: 0)
            }
            .foregroundStyle(.tertiary)
            .padding(.leading, 10)
            .padding(.top, 5)
            .padding(.bottom, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(AppCopy.text("sidebar.showMore"))
        .accessibilityHint(AppCopy.text("sidebar.showMore"))
    }

    private func projectEntry(_ path: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            projectRow(path)
            if model.sidebarLayoutMode == .groupedByProject,
               model.expandedProjectPaths.contains(path) {
                projectConversations(for: path)
            }
        }
    }

    private func estimatedProjectGroupHeight(_ group: ProjectGroup) -> CGFloat {
        let titleHeight: CGFloat = group.title == nil ? 0 : 24
        let rows = group.paths.reduce(CGFloat.zero) { $0 + estimatedProjectHeight(for: $1) }
        let rowSpacing = CGFloat(max(0, group.paths.count - 1)) * 2
        return titleHeight + rows + rowSpacing
    }

    private func estimatedProjectHeight(for path: String) -> CGFloat {
        var height: CGFloat = 32
        guard model.sidebarLayoutMode == .groupedByProject,
              model.expandedProjectPaths.contains(path) else {
            return height
        }

        let conversations = path == model.workspacePath
            ? model.conversations
            : bridge.conversations(inProject: path)
        let visibleCount = expandedChatLists.contains(path)
            ? conversations.count
            : min(conversations.count, visibleConversationLimit)
        if visibleCount > 0 {
            height += 2 + CGFloat(visibleCount) * 31
        }
        if conversations.count > visibleConversationLimit {
            height += 28
        }
        return height
    }

    /// Opens a project's chat list without touching any other open list. An
    /// inactive project is selected first; a missing folder keeps the locate
    /// prompt instead of expanding an empty row.
    private func openProjectChats(_ path: String) {
        guard model.isProjectLocationAvailable(path) else {
            model.selectProject(path)
            return
        }
        if path != model.workspacePath { model.selectProject(path) }
        guard model.workspacePath == path else { return }
        expandProjectChats(path)
    }

    /// Opens one project's chat list. Every other list the user left open stays open.
    private func expandProjectChats(_ path: String) {
        withAnimation(.easeOut(duration: 0.16)) {
            model.setProjectChatsExpanded(true, for: path)
        }
    }

    private func collapseProjectChats(_ path: String) {
        withAnimation(.easeOut(duration: 0.16)) {
            model.setProjectChatsExpanded(false, for: path)
        }
    }

    private func projectRow(_ path: String) -> some View {
        let isActive = path == model.workspacePath
        let isNewChat = model.selected?.blank == true
        let isAvailable = model.isProjectLocationAvailable(path)
        let isExpanded = model.expandedProjectPaths.contains(path)
        return HStack(spacing: 3) {
            if model.sidebarLayoutMode == .groupedByProject {
                Button {
                    if isExpanded {
                        collapseProjectChats(path)
                    } else {
                        openProjectChats(path)
                    }
                } label: {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 16, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .help(AppCopy.text(isExpanded ? "sidebar.showLess" : "sidebar.showMore"))
                .accessibilityLabel(projectName(path))
                .accessibilityValue(AppCopy.text(isExpanded ? "sidebar.showLess" : "sidebar.showMore"))
            }

            Button {
                openProjectChats(path)
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

            Button {
                expandProjectChats(path)
                model.newConversation(in: path)
            } label: {
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
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isActive && isNewChat ? Color.primary.opacity(0.105) : Color.clear)
        }
        .opacity(isAvailable ? 1 : 0.48)
        // Anchored on the whole row, trailing edge: the card opens over the
        // window's own content instead of spilling out past the sidebar.
        .popover(
            isPresented: Binding(
                get: { projectPreviewPath == path },
                set: { if !$0, projectPreviewPath == path { projectPreviewPath = nil } }
            ),
            arrowEdge: .trailing
        ) {
            projectPreview(path)
        }
        .contextMenu {
            projectMenuItems(path)
        }
        .task(id: path) {
            model.loadGitProjectStatusIfNeeded(path)
        }
    }

    @ViewBuilder
    private func projectMenuItems(_ path: String) -> some View {
        if !model.isProjectLocationAvailable(path) {
            Button(AppCopy.text("project.missing.locate"), systemImage: "folder") {
                model.promptToRelocateProject(missingPath: path)
            }
            Divider()
        }
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

    /// Chats belonging to one open project row. The active project reads the
    /// bridge's loaded list so live run and unread state stays current; an open
    /// but inactive project reads headers from disk, which keeps its chats on
    /// screen without switching the workspace to it.
    private func projectConversations(for path: String) -> some View {
        let isActive = path == model.workspacePath
        let conversations = orderedConversations(
            isActive ? model.conversations : bridge.conversations(inProject: path),
            forProject: path
        )
        let showAll = expandedChatLists.contains(path)
        let visible = showAll ? conversations : Array(conversations.prefix(visibleConversationLimit))

        return VStack(alignment: .leading, spacing: 1) {
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
                        ownerProject: path,
                        manualReorderProject: path,
                        manualOrder: order
                    )
                }

                if conversations.count > visibleConversationLimit {
                    Button {
                        withAnimation(.easeOut(duration: 0.16)) {
                            if showAll {
                                expandedChatLists.remove(path)
                            } else {
                                expandedChatLists.insert(path)
                            }
                        }
                    } label: {
                        Text(showAll
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
                    conversationRow(conversation, indented: false, isRecent: true)
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
        isRecent: Bool = false,
        ownerProject: String? = nil,
        manualReorderProject: String? = nil,
        manualOrder: [String] = []
    ) -> some View {
        HStack(spacing: 0) {
            Button {
                if isRecent {
                    _ = model.openRecentConversation(conversation)
                } else {
                    // An open project that isn't active lists chats the bridge has
                    // not loaded. Select its project first so the transcript opens.
                    if let ownerProject, ownerProject != model.workspacePath {
                        model.selectProject(ownerProject)
                    }
                    model.selectedConversationID = conversation.id
                }
            } label: {
                Text(conversation.displayTitle)
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
                        model.archiveConversation(conversation.id)
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
            Picker(selection: Binding(
                get: { conversation.priority },
                set: { bridge.setPriority(conversation.id, $0) }
            )) {
                Text(AppCopy.text("sidebar.priorityHigh")).tag(3)
                Text(AppCopy.text("sidebar.priorityMedium")).tag(2)
                Text(AppCopy.text("sidebar.priorityLow")).tag(1)
                Text(AppCopy.text("sidebar.priorityNone")).tag(0)
            } label: {
                Label(AppCopy.text("sidebar.priority"), systemImage: "flag")
            }
            Button(AppCopy.text("sidebar.archiveChat"), systemImage: "archivebox") {
                model.archiveConversation(conversation.id)
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
                .progressViewStyle(.circular)
                .controlSize(.mini)
                .tint(Color.blue)
                .frame(width: 16, height: 16)
                .accessibilityLabel(AppCopy.text("sidebar.chatRunning"))
        } else if !conversation.blank {
            Circle()
                .fill(Color.blue)
                .frame(width: 7, height: 7)
                .frame(width: 16, height: 16)
                .accessibilityLabel(AppCopy.text("sidebar.chatCompleted"))
        }
    }

    private func projectName(_ path: String) -> String {
        model.projectTitle(for: path)
    }

    private var organizedProjectPaths: [String] {
        let paths = model.projectPaths
        guard currentProjectSort == .name else { return paths }
        return paths.sorted {
            projectName($0).localizedStandardCompare(projectName($1)) == .orderedAscending
        }
    }

    private var projectGroups: [ProjectGroup] {
        let paths = organizedProjectPaths
        switch currentProjectGrouping {
        case .folder:
            return ProjectFolderGrouping.groups(for: paths)
        case .none:
            let pinned = paths.filter { model.isProjectPinned($0) }
            let unpinned = paths.filter { !model.isProjectPinned($0) }
            return [ProjectGroup(title: nil, paths: pinned + unpinned, kind: .other)]
        case .sections:
            let pinned = paths.filter { model.isProjectPinned($0) }
            var groups: [ProjectGroup] = []
            if !pinned.isEmpty {
                groups.append(ProjectGroup(
                    title: AppCopy.text("sidebar.pinned"),
                    paths: pinned,
                    kind: .pinned
                ))
            }

            for section in model.projectSections {
                let sectionPaths = paths.filter {
                    !model.isProjectPinned($0) && model.projectSection(for: $0) == section
                }
                if !sectionPaths.isEmpty {
                    groups.append(ProjectGroup(title: section, paths: sectionPaths, kind: .named))
                }
            }

            let other = paths.filter {
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
            ProjectRemoteLabel(path: path)
            Label(path, systemImage: "folder")
                .lineLimit(2)
                .textSelection(.enabled)
        }
        .padding(16)
        .frame(width: 330, alignment: .leading)
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
        orderedConversations(recentProjectConversations, forProject: nil)
            .prefix(visibleConversationLimit)
            .map { $0 }
    }

    private var recentHasRunningConversation: Bool {
        let runningIDs = bridge.runningConversationIDs
        return recentConversations.contains { runningIDs.contains($0.id) }
    }

    /// "Recent" holds retained conversations whose original project no longer
    /// has a connected folder, whether its entry was removed or the folder vanished.
    private var recentProjectConversations: [Conversation] {
        return bridge.conversations(outsideProjects: model.connectedProjectPaths)
            .filter { $0.projectless || ConversationStore.normalizedPath($0.cwd) != nil }
    }

    /// `forProject` picks the sort order to apply; pass `nil` for lists (like
    /// "Recent") that aren't scoped to one project's own preference.
    private func orderedConversations(_ conversations: [Conversation], forProject path: String?) -> [Conversation] {
        model.ordered(filteredConversations(conversations), forProject: path)
    }

    private func filteredConversations(_ conversations: [Conversation]) -> [Conversation] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let visible = conversations.filter { !$0.blank && !$0.archived }
        guard !query.isEmpty else { return visible }
        return visible.filter { conversation in
            conversation.title.localizedCaseInsensitiveContains(query)
                || (searchedContentQuery == query && searchedConversationIDs.contains(conversation.id))
        }
    }

    @MainActor
    private func updateContentSearch() async {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        searchedContentQuery = query
        searchedConversationIDs.removeAll(keepingCapacity: true)
        isSearchingConversationContent = false
        guard !query.isEmpty else { return }

        try? await Task.sleep(nanoseconds: 220_000_000)
        guard !Task.isCancelled else { return }
        isSearchingConversationContent = true
        let matches = await bridge.contentMatchingConversationIDs(query: query)
        guard !Task.isCancelled else { return }
        searchedConversationIDs = matches
        isSearchingConversationContent = false
    }
}

extension AppModel {
    /// A project's chats in the order its sort preference asks for; `nil` is for
    /// lists (like "Recent") that aren't scoped to one project's own preference.
    func ordered(_ conversations: [Conversation], forProject path: String?) -> [Conversation] {
        // Pinned first, then most recent activity.
        func byActivity() -> [Conversation] {
            conversations.sorted {
                if $0.pinned != $1.pinned { return $0.pinned }
                return $0.activityDate > $1.activityDate
            }
        }
        switch path.map(sortOrder(forProject:)) ?? .lastUpdate {
        case .lastUpdate:
            return byActivity()
        case .priority:
            return conversations.sorted {
                if $0.pinned != $1.pinned { return $0.pinned }
                if $0.priority != $1.priority { return $0.priority > $1.priority }
                return $0.activityDate > $1.activityDate
            }
        case .manual:
            guard let path else { return byActivity() }
            let manualOrder = projectManualOrder[path] ?? []
            let rank = Dictionary(uniqueKeysWithValues: manualOrder.enumerated().map { ($1, $0) })
            return conversations.sorted {
                if $0.pinned != $1.pinned { return $0.pinned }
                let lhs = rank[$0.id] ?? Int.max
                let rhs = rank[$1.id] ?? Int.max
                if lhs != rhs { return lhs < rhs }
                return $0.activityDate > $1.activityDate
            }
        }
    }
}

/// `owner/repo` of the project's origin. Git runs off the main thread, so the
/// preview renders without waiting for it.
private struct ProjectRemoteLabel: View {
    let path: String
    @State private var remote: String?

    var body: some View {
        Group {
            if let remote {
                Label(remote, systemImage: "arrow.triangle.branch")
                    .lineLimit(1)
            }
        }
        .task(id: path) {
            remote = await Task.detached(priority: .utility) { Self.remote(at: path) }.value
        }
    }

    private nonisolated static func remote(at path: String) -> String? {
        guard GitInstall.isAvailable() else { return nil }
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
}

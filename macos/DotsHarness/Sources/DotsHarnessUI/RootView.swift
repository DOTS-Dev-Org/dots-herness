// Copyright (c) 2026 DOTS
// Root window for the standalone native harness.

import AppKit
import SwiftUI
import HarnessPluginKit
import PluginRuntime
import DotsHarnessCore

public struct RootView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var navigationState: SidebarVisibilityState
    @ObservedObject private var startupGate = StartupGate.shared
    private let logo: Image?
    @StateObject private var dock = RightDockState()
    @State private var projectDirectoryMonitor = ProjectDirectoryChangeMonitor()
    @State private var preferredSidebarVisibility: NavigationSplitViewVisibility = .all
    @State private var isSidebarCompact = false
    @AppStorage("sidebar.home.width") private var homeSidebarWidth = 210.0
    @AppStorage("dock.width.trailing") private var trailingWidth = 420.0
    @AppStorage("dock.width.leading") private var leadingWidth = 320.0
    @AppStorage("dock.width.simulator") private var simulatorWidth = 340.0
    @AppStorage("dock.height.top") private var topHeight = 220.0
    @AppStorage("dock.height.bottom") private var bottomHeight = 260.0
    private var configuredHomeSidebarWidth: CGFloat {
        min(520, max(180, CGFloat(homeSidebarWidth)))
    }

    private var sidebarDetailWidthReserve: CGFloat {
        560 + (dock.isVisible ? dock.minimumWidth(on: .trailing) + 5 : 0)
            + (dock.has(.leading) ? dock.minimumWidth(on: .leading) + 5 : 0)
            + (model.isSimulatorPresented ? 281 : 0)
    }

    // Keep the project sidebar open only when its configured width and a
    // readable conversation area both fit in the window.
    private var sidebarAutoHideThreshold: CGFloat {
        configuredHomeSidebarWidth + sidebarDetailWidthReserve
    }

    private var workspaceMinimumSize: CGSize {
        guard model.section == .home, !model.isSettingsPresented, !model.legalNeedsAcceptance,
              dock.isVisible || dock.hasMovedTabs || model.isSimulatorPresented else {
            return CGSize(width: 520, height: 640)
        }
        var width: CGFloat = dock.isVisible && dock.isExpanded ? dock.minimumWidth(on: .trailing) : 240
        if !(dock.isVisible && dock.isExpanded) {
            if dock.has(.leading) { width += dock.minimumWidth(on: .leading) + 5 }
            if dock.isVisible { width += dock.minimumWidth(on: .trailing) + 5 }
        }
        if model.isSimulatorPresented { width += 285 }
        var height: CGFloat = 280
        if dock.has(.top) { height += dock.minimumHeight(on: .top) + 5 }
        if dock.has(.bottom) { height += dock.minimumHeight(on: .bottom) + 5 }
        return CGSize(width: max(520, width + AppRailView.width), height: max(640, height))
    }

    public init(model: AppModel, logo: Image? = nil) {
        self.model = model
        self._navigationState = ObservedObject(wrappedValue: model.navigationState)
        self.logo = logo
    }

    public var body: some View {
        Group {
            if model.legalNeedsAcceptance {
                LegalGateView(model: model)
            } else if model.isSettingsPresented {
                SettingsView(model: model)
            } else {
                HStack(spacing: 0) {
                    AppRailView(model: model)
                    gatedContent
                }
            }
        }
        .frame(minWidth: workspaceMinimumSize.width, minHeight: workspaceMinimumSize.height)
        .preferredColorScheme(model.appearance.colorScheme)
        .environment(\.locale, model.appLocale)
        .environment(\.layoutDirection, model.isRTL ? .rightToLeft : .leftToRight)
        .onAppear {
            refreshProjectLocations()
            updateProjectDirectoryMonitor()
        }
        .onChange(of: model.projectPaths) { _, paths in
            projectDirectoryMonitor.update(paths: paths)
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in
            refreshProjectLocations()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in
            refreshProjectLocations()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didRenameVolumeNotification)) { _ in
            refreshProjectLocations()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshProjectLocations()
        }
        .onDisappear {
            projectDirectoryMonitor.stop()
        }
    }

    private func refreshProjectLocations() {
        model.refreshProjectLocationAvailability()
        updateProjectDirectoryMonitor()
    }

    private func updateProjectDirectoryMonitor() {
        let model = model
        let monitor = projectDirectoryMonitor
        monitor.update(paths: model.projectPaths) { [weak model, weak monitor] in
            guard let model, let monitor else { return }
            model.refreshProjectLocationAvailability()
            monitor.update(paths: model.projectPaths)
        }
    }

    private var gatedContent: some View {
        mainContent
        .background {
            if isSidebarCompact, navigationState.visibility != .detailOnly {
                Button("") { dismissCompactSidebar() }
                    .keyboardShortcut(.escape, modifiers: [])
                    .opacity(0)
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
            }
            if startupGate.isOpen {
            ForEach(KeyboardShortcutAction.allCases.filter { $0 != .toggleSidebar && $0 != .pullRequests && $0 != .scheduled }) { action in
                Button("") { model.isTasksPresented = false; dock.perform(action, model: model) }
                    .keyboardShortcut(model.shortcut(for: action).swiftUIShortcut)
                    .opacity(0)
                    .frame(width: 0, height: 0)
                    .allowsHitTesting(false)
                }
            }
        }
        .sheet(isPresented: $model.isUsagePresented) {
            UsageSummaryView(model: model)
        }
        .modifier(MCPInteractionPresenter(registry: model.mcpRegistry))
        .onChange(of: model.voiceProvider) { _, _ in model.refreshVoiceModel() }
        .onChange(of: model.selected?.pendingPlanMessageID) { _, id in
            // Auto-approve applies the plan straight away, so only ask when it is manual.
            if id != nil, !model.autoApprovePlans { dock.showPlan() }
        }
        .onChange(of: model.planPaneRequestID) { _, _ in dock.showPlan() }
        .onChange(of: model.reviewPaneRequestID) { _, _ in dock.showReview() }
        .onChange(of: model.tasksPaneRequestID) { _, _ in dock.showTasks() }
        .onChange(of: model.cloudPaneRequestID) { _, _ in dock.showCloud() }
        .onChange(of: model.browserPaneRequestID) { _, _ in
            if let url = model.requestedBrowserURL { dock.openWebURL(url) }
        }
        .onChange(of: model.filesPaneRequestID) { _, _ in dock.add(.files, unique: true) }
        .onChange(of: model.workspacePath, initial: true) { _, path in
            dock.projectName = path.isEmpty ? "" : model.projectTitle(for: path)
            model.mcpRegistry.setRoots(path.isEmpty ? [] : [URL(fileURLWithPath: path, isDirectory: true)])
        }
    }

    @ViewBuilder
    private var mainContent: some View {
        GeometryReader { proxy in
            // Plain HStack like BotsView: NavigationSplitView floats the sidebar
            // as a glass panel over the titlebar, misaligned with the rail.
            HStack(spacing: 0) {
                if model.section.showsProjectSidebar, !isSidebarCompact, navigationState.visibility != .detailOnly {
                    let maximumSidebarWidth = min(520, max(180, proxy.size.width - sidebarDetailWidthReserve))
                    let actualSidebarWidth = min(configuredHomeSidebarWidth, maximumSidebarWidth)
                    SidebarView(
                        model: model,
                        logo: logo,
                        notificationPopoverWidth: min(340, max(140, actualSidebarWidth - 24))
                    )
                        .frame(width: actualSidebarWidth)
                    WorkspaceDivider(
                        horizontal: false,
                        preferred: $homeSidebarWidth,
                        actual: actualSidebarWidth,
                        limits: 180...maximumSidebarWidth,
                        sign: model.isRTL ? -1 : 1
                    )
                }
                Group {
                    switch model.section {
                    case .home: detailPanes
                    case .tasks: TasksView(model: model)
                    case .media: MediaView(model: model)
                    case .bots: BotsView(model: model)
                    case .marketplace: MarketplaceSectionView(model: model)
                    case .memory: MemoryVaultView(bridge: model.bridge)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .toolbar(removing: .sidebarToggle)
            .toolbarBackground(.hidden, for: .windowToolbar)
            .overlay(alignment: model.isRTL ? .trailing : .leading) {
                if isSidebarCompact, model.section.showsProjectSidebar, navigationState.visibility != .detailOnly {
                    compactSidebar(for: proxy.size.width)
                }
            }
            .overlay(alignment: .top) {
                SlotStack(slot: WellKnownSlot.overlay, registry: model.host.slots)
            }
            .toolbar {
                // Keep the sidebar toggle and assistant mode controls in one
                // compact surface so they read as a single navigation group.
                navigationToolbarItem

                actionToolbarItems
            }
            .onAppear {
                synchronizeSidebarVisibility(for: proxy.size.width)
            }
            .onChange(of: proxy.size.width) { _, width in
                synchronizeSidebarVisibility(for: width)
            }
            .onChange(of: navigationState.visibility) { _, visibility in
                if !isSidebarCompact {
                    preferredSidebarVisibility = visibility
                }
            }
            .onChange(of: sidebarAutoHideThreshold) { _, _ in
                synchronizeSidebarVisibility(for: proxy.size.width)
            }
            .onChange(of: model.selectedConversationID) { _, _ in dismissCompactSidebar() }
            .onChange(of: model.workspacePath) { _, _ in dismissCompactSidebar() }
            .onChange(of: model.section) { _, _ in dismissCompactSidebar() }
        }
    }

    private func compactSidebar(for width: CGFloat) -> some View {
        let compactWidth = min(300, max(250, width - 48))
        return ZStack(alignment: model.isRTL ? .trailing : .leading) {
            Color.black.opacity(0.18)
                .contentShape(Rectangle())
                .onTapGesture { dismissCompactSidebar() }
                .accessibilityHidden(true)

            SidebarView(
                model: model,
                logo: logo,
                notificationPopoverWidth: min(340, max(140, compactWidth - 24))
            )
                .frame(width: compactWidth)
                .frame(maxHeight: .infinity)
                .shadow(color: .black.opacity(0.2), radius: 12, x: model.isRTL ? -4 : 4)
        }
        .onExitCommand { dismissCompactSidebar() }
    }

    private func dismissCompactSidebar() {
        if isSidebarCompact { navigationState.visibility = .detailOnly }
    }

    @ViewBuilder
    private var detailPanes: some View {
        if dock.isVisible || dock.hasMovedTabs || model.isSimulatorPresented {
            GeometryReader { proxy in
                dockedPanes(in: proxy.size)
                    .onChange(of: proxy.frame(in: .global), initial: true) { _, frame in
                        dock.dropArea = frame
                    }
                    .overlay {
                        if let edge = dock.dropEdge, let tab = dock.dragging {
                            DockDropPreview(edge: edge, tab: tab)
                        }
                    }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ConversationView(
                model: model,
                isPanePickerVisible: .constant(false)
            )
            // The split view asks this column for its minimum size at zero width.
            // Without a floor the composer notices wrap one character per line there,
            // and that height (taller than the screen) became the column's minimum:
            // the composer and the sidebar footer ended up below the window.
            .frame(minWidth: 240)
        }
    }

    /// Size each pane from the actual window bounds. SwiftUI dividers avoid
    /// nested NSSplitView hosting insets and preserve independent pane sizes.
    private func dockedPanes(in size: CGSize) -> some View {
        let topMinimum = dock.has(.top) ? dock.minimumHeight(on: .top) : 0
        let bottomMinimum = dock.has(.bottom) ? dock.minimumHeight(on: .bottom) : 0
        let bars: CGFloat = (dock.has(.top) ? 5 : 0) + (dock.has(.bottom) ? 5 : 0)
        let top = dock.has(.top) ? paneExtent(topHeight, minimum: topMinimum,
            maximum: size.height - 280 - bottomMinimum - bars) : 0
        let bottom = dock.has(.bottom) ? paneExtent(bottomHeight, minimum: bottomMinimum,
            maximum: size.height - 280 - top - bars) : 0
        let middle = max(280, size.height - top - bottom - bars)
        return VStack(spacing: 0) {
            if dock.has(.top) {
                RightDockView(model: model, state: dock, edge: .top)
                    .frame(width: size.width, height: top).clipped()
                WorkspaceDivider(horizontal: true, preferred: $topHeight, actual: top,
                    limits: topMinimum...max(topMinimum, size.height - bottom - 280 - bars), sign: 1)
            }
            middlePanes(width: size.width, height: middle)
            if dock.has(.bottom) {
                WorkspaceDivider(horizontal: true, preferred: $bottomHeight, actual: bottom,
                    limits: bottomMinimum...max(bottomMinimum, size.height - top - 280 - bars), sign: -1)
                RightDockView(model: model, state: dock, edge: .bottom)
                    .frame(width: size.width, height: bottom).clipped()
            }
        }
        .frame(width: size.width, height: size.height)
    }

    private func middlePanes(width: CGFloat, height: CGFloat) -> some View {
        let expanded = dock.isVisible && dock.isExpanded
        let hasLeading = !expanded && dock.has(.leading)
        let chatMinimum: CGFloat = expanded ? 0 : 240
        let leftMinimum: CGFloat = hasLeading ? dock.minimumWidth(on: .leading) : 0
        let rightMinimum: CGFloat = dock.isVisible ? dock.minimumWidth(on: .trailing) : 0
        let simMinimum: CGFloat = model.isSimulatorPresented ? 280 : 0
        let bars: CGFloat = (hasLeading ? 5 : 0) + (dock.isVisible && !expanded ? 5 : 0)
            + (model.isSimulatorPresented ? 5 : 0)
        let right = dock.isVisible && !expanded ? paneExtent(trailingWidth, minimum: rightMinimum,
            maximum: width - chatMinimum - leftMinimum - simMinimum - bars) : 0
        let left = hasLeading ? paneExtent(leadingWidth, minimum: leftMinimum,
            maximum: width - chatMinimum - right - simMinimum - bars) : 0
        let sim = model.isSimulatorPresented ? paneExtent(simulatorWidth, minimum: simMinimum,
            maximum: width - chatMinimum - left - right - (expanded ? rightMinimum : 0) - bars) : 0
        let chat = max(chatMinimum, width - left - right - sim - bars)
        let direction: CGFloat = model.isRTL ? -1 : 1
        return HStack(spacing: 0) {
            if hasLeading {
                RightDockView(model: model, state: dock, edge: .leading)
                    .frame(width: left, height: height).clipped()
                WorkspaceDivider(horizontal: false, preferred: $leadingWidth, actual: left,
                    limits: leftMinimum...max(leftMinimum, width - chatMinimum - right - sim - bars), sign: direction)
            }
            if expanded {
                RightDockView(model: model, state: dock)
                    .frame(width: chat, height: height).clipped()
            } else {
                ConversationView(model: model, isPanePickerVisible: .constant(false))
                    .frame(width: chat, height: height).clipped()
                if dock.isVisible {
                    WorkspaceDivider(horizontal: false, preferred: $trailingWidth, actual: right,
                        limits: rightMinimum...max(rightMinimum, width - chatMinimum - left - sim - bars), sign: -direction)
                    RightDockView(model: model, state: dock)
                        .frame(width: right, height: height).clipped()
                }
            }
            if model.isSimulatorPresented {
                WorkspaceDivider(horizontal: false, preferred: $simulatorWidth, actual: sim,
                    limits: simMinimum...max(simMinimum, width - left - right - (expanded ? rightMinimum : chatMinimum) - bars), sign: -direction)
                SimulatorPanelView(model: model).frame(width: sim, height: height).clipped()
            }
        }
        .frame(width: width, height: height)
    }

    private func paneExtent(_ preferred: Double, minimum: CGFloat, maximum: CGFloat) -> CGFloat {
        min(max(minimum, CGFloat(preferred)), max(minimum, maximum))
    }

    @ToolbarContentBuilder
    private var navigationToolbarItem: some ToolbarContent {
        let item = ToolbarItem(id: "navigation-controls", placement: .navigation) {
            NavigationControlCluster(model: model, navigationState: navigationState)
        }
        if #available(macOS 26.0, *) {
            item.sharedBackgroundVisibility(.hidden)
        } else {
            item
        }
    }

    @ToolbarContentBuilder
    private var actionToolbarItems: some ToolbarContent {
        if #available(macOS 26.0, *) {
            ToolbarSpacer(.flexible, placement: .primaryAction)

            ToolbarItem(id: "simulator", placement: .primaryAction) {
                simulatorToolbarButton
            }
            .sharedBackgroundVisibility(.hidden)

            ToolbarItem(id: "pane-picker", placement: .primaryAction) {
                panePickerToolbarButton
            }
            .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(id: "simulator", placement: .primaryAction) {
                simulatorToolbarButton
            }

            ToolbarItem(id: "pane-picker", placement: .primaryAction) {
                panePickerToolbarButton
            }
        }
    }

    private var simulatorToolbarButton: some View {
        Button {
            model.isTasksPresented = false
            model.isSimulatorPresented.toggle()
        } label: {
            Label(AppCopy.text("simulator.title"), systemImage: "iphone.gen3")
        }
        .buttonStyle(.plain)
        .help(AppCopy.text("simulator.title"))
    }

    private var panePickerToolbarButton: some View {
        Button {
            model.open(.home)
            dock.toggleVisibility()
        } label: {
            Label(AppCopy.text("conversation.choosePane"), systemImage: "rectangle.split.2x1")
        }
        .buttonStyle(.plain)
        .help(AppCopy.text("conversation.choosePane"))
    }

    private func synchronizeSidebarVisibility(for width: CGFloat) {
        let compact = width < sidebarAutoHideThreshold
        if compact, !isSidebarCompact {
            preferredSidebarVisibility = navigationState.visibility
            isSidebarCompact = true
            navigationState.visibility = .detailOnly
        } else if !compact, isSidebarCompact {
            isSidebarCompact = false
            navigationState.visibility = preferredSidebarVisibility
        }
    }
}

private struct SidebarToggleButton: View {
    @ObservedObject var navigationState: SidebarVisibilityState

    private var isVisible: Bool {
        navigationState.visibility != .detailOnly
    }

    var body: some View {
        Button {
            withAnimation(.easeOut(duration: 0.18)) {
                navigationState.toggle()
            }
        } label: {
            Image(systemName: "sidebar.left")
                .font(.system(size: 13, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .frame(width: 28, height: 28)
                .foregroundStyle(Color.primary.opacity(0.9))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isVisible ? AppCopy.text("sidebar.hideSidebar") : AppCopy.text("sidebar.showSidebar"))
        .accessibilityLabel(isVisible ? AppCopy.text("sidebar.hideSidebar") : AppCopy.text("sidebar.showSidebar"))
        .accessibilityValue(isVisible ? AppCopy.text("sidebar.showSidebar") : AppCopy.text("sidebar.hideSidebar"))
    }
}

private struct NavigationControlCluster: View {
    @ObservedObject var model: AppModel
    @ObservedObject var navigationState: SidebarVisibilityState

    var body: some View {
        HStack(spacing: 6) {
            SidebarToggleButton(navigationState: navigationState)

            NavigationStepButton(
                systemImage: "arrow.left",
                title: AppCopy.text("navigation.back"),
                isEnabled: model.canNavigateBack
            ) {
                model.navigateBack()
            }

            NavigationStepButton(
                systemImage: "arrow.right",
                title: AppCopy.text("navigation.forward"),
                isEnabled: model.canNavigateForward
            ) {
                model.navigateForward()
            }
        }
        .accessibilityElement(children: .contain)
    }
}

private struct NavigationStepButton: View {
    let systemImage: String
    let title: String
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.primary.opacity(isEnabled ? 0.9 : 0.28))
        .disabled(!isEnabled)
        .help(title)
        .accessibilityLabel(title)
    }
}

public struct SlotStack: View {
    var slot: String
    @ObservedObject var registry: InMemorySlotRegistry

    public init(slot: String, registry: InMemorySlotRegistry) {
        self.slot = slot
        self.registry = registry
    }

    public var body: some View {
        ZStack {
            ForEach(registry.occupants(in: slot)) { occupant in
                occupant.view
            }
        }
        .allowsHitTesting(true)
    }
}

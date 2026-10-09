// Copyright (c) 2026 DOTS
// Root window for the standalone native harness.

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
    @State private var preferredSidebarVisibility: NavigationSplitViewVisibility = .all
    @State private var isSidebarCompact = false
    // Reserve a readable conversation width in addition to the widest sidebar.
    private var sidebarAutoHideThreshold: CGFloat {
        840 + (dock.isVisible ? 241 : 0) + (model.isSimulatorPresented ? 281 : 0)
    }

    private var splitVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { isSidebarCompact ? .detailOnly : navigationState.visibility },
            set: { if !isSidebarCompact { navigationState.visibility = $0 } }
        )
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
                gatedContent
            }
        }
        .preferredColorScheme(model.appearance.colorScheme)
        .environment(\.locale, model.appLocale)
        .environment(\.layoutDirection, model.isRTL ? .rightToLeft : .leftToRight)
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
        .onChange(of: model.voiceProvider) { _, _ in model.refreshVoiceModel() }
        .onChange(of: model.selected?.pendingPlanMessageID) { _, id in
            // Auto-approve applies the plan straight away, so only ask when it is manual.
            if id != nil, !model.autoApprovePlans { dock.showPlan() }
        }
        .onChange(of: model.planPaneRequestID) { _, _ in dock.showPlan() }
    }

    @ViewBuilder
    private var mainContent: some View {
        GeometryReader { proxy in
            NavigationSplitView(columnVisibility: splitVisibility) {
                Group {
                    if !isSidebarCompact {
                        SidebarView(model: model, logo: logo)
                    } else {
                        Color.clear
                    }
                }
                .toolbar(removing: .sidebarToggle)
            } detail: {
                if model.isTasksPresented {
                    TasksView(model: model)
                } else {
                    detailPanes
                }
            }
            .toolbar(removing: .sidebarToggle)
            .toolbarBackground(.hidden, for: .windowToolbar)
            .overlay(alignment: model.isRTL ? .trailing : .leading) {
                if isSidebarCompact, navigationState.visibility != .detailOnly {
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
            .onChange(of: dock.isVisible) { _, _ in
                synchronizeSidebarVisibility(for: proxy.size.width)
            }
            .onChange(of: model.isSimulatorPresented) { _, _ in
                synchronizeSidebarVisibility(for: proxy.size.width)
            }
            .onChange(of: model.selectedConversationID) { _, _ in dismissCompactSidebar() }
            .onChange(of: model.workspacePath) { _, _ in dismissCompactSidebar() }
            .onChange(of: model.isTasksPresented) { _, _ in dismissCompactSidebar() }
        }
    }

    private func compactSidebar(for width: CGFloat) -> some View {
        ZStack(alignment: model.isRTL ? .trailing : .leading) {
            Color.black.opacity(0.18)
                .contentShape(Rectangle())
                .onTapGesture { dismissCompactSidebar() }
                .accessibilityHidden(true)

            SidebarView(model: model, logo: logo)
                .frame(width: min(300, max(250, width - 48)))
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
        if dock.isVisible || model.isSimulatorPresented {
            HSplitView {
                if !(dock.isVisible && dock.isExpanded) {
                    ConversationView(
                        model: model,
                        isPanePickerVisible: .constant(false)
                    )
                    .frame(minWidth: 240, idealWidth: 620, maxWidth: .infinity)
                }

                if dock.isVisible {
                    RightDockView(model: model, state: dock)
                        .frame(minWidth: 240, idealWidth: 420, maxWidth: .infinity)
                }

                if model.isSimulatorPresented {
                    SimulatorPanelView(model: model)
                        .frame(minWidth: 280, idealWidth: 340, maxWidth: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ConversationView(
                model: model,
                isPanePickerVisible: .constant(false)
            )
        }
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
            dock.isVisible.toggle()
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

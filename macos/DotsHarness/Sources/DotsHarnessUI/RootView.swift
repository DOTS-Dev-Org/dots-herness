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
    @State private var isApplyingAutomaticSidebarVisibility = false

    private static let sidebarAutoHideThreshold: CGFloat = 640

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
    }

    @ViewBuilder
    private var mainContent: some View {
        GeometryReader { proxy in
            NavigationSplitView(columnVisibility: $navigationState.visibility) {
                SidebarView(model: model, logo: logo)
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
            .frame(width: proxy.size.width, height: proxy.size.height)
            .overlay(alignment: .top) {
                SlotStack(slot: WellKnownSlot.overlay, registry: model.host.slots)
            }
            .toolbar {
                // Keep the sidebar toggle and assistant mode controls in one
                // compact surface so they read as a single navigation group.
                ToolbarItem(id: "navigation-controls", placement: .navigation) {
                    NavigationControlCluster(
                        model: model,
                        navigationState: navigationState
                    )
                }

                actionToolbarItems
            }
            .onAppear {
                synchronizeSidebarVisibility(for: proxy.size.width)
            }
            .onChange(of: proxy.size.width) { _, width in
                synchronizeSidebarVisibility(for: width)
            }
            .onChange(of: navigationState.visibility) { _, visibility in
                if isApplyingAutomaticSidebarVisibility {
                    isApplyingAutomaticSidebarVisibility = false
                } else {
                    preferredSidebarVisibility = visibility
                }
            }
        }
    }

    @ViewBuilder
    private var detailPanes: some View {
        if startupGate.isOpen, (dock.isVisible || model.isSimulatorPresented) {
            HSplitView {
                ConversationView(
                    model: model,
                    isPanePickerVisible: .constant(false)
                )
                .frame(minWidth: 300, idealWidth: 620, maxWidth: .infinity)

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

    private func applyAutomaticSidebarVisibility(_ visibility: NavigationSplitViewVisibility) {
        guard navigationState.visibility != visibility else { return }
        isApplyingAutomaticSidebarVisibility = true
        navigationState.visibility = visibility
    }

    private func synchronizeSidebarVisibility(for width: CGFloat) {
        let compact = width < Self.sidebarAutoHideThreshold
        if compact {
            // A window can enter the compact state before NavigationSplitView
            // has committed its initial column visibility. Do not let the
            // compact-state flag short-circuit that first correction: otherwise
            // the sidebar remains visible at the minimum window size and its
            // contents are laid out outside the available column.
            if !isSidebarCompact, navigationState.visibility != .detailOnly {
                preferredSidebarVisibility = navigationState.visibility
            }
            isSidebarCompact = true
            if navigationState.visibility != .detailOnly {
                applyAutomaticSidebarVisibility(.detailOnly)
            }
        } else if isSidebarCompact {
            isSidebarCompact = false
            applyAutomaticSidebarVisibility(preferredSidebarVisibility)
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
        .help(isVisible ? AppCopy.text("sidebar.hide") : AppCopy.text("sidebar.show"))
        .accessibilityLabel(isVisible ? AppCopy.text("sidebar.hide") : AppCopy.text("sidebar.show"))
        .accessibilityValue(isVisible ? AppCopy.text("sidebar.show") : AppCopy.text("sidebar.hide"))
    }
}

private struct NavigationControlCluster: View {
    @ObservedObject var model: AppModel
    @ObservedObject var navigationState: SidebarVisibilityState

    var body: some View {
        HStack(spacing: 3) {
            SidebarToggleButton(navigationState: navigationState)

            Rectangle()
                .fill(Color.primary.opacity(0.14))
                .frame(width: 1, height: 19)
                .accessibilityHidden(true)

            AssistantModePicker(model: model)
        }
        .padding(3)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(Color.primary.opacity(0.14), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.12), radius: 5, y: 2)
        .accessibilityElement(children: .contain)
    }
}

private struct AssistantModePicker: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            ForEach(AgentArea.allCases) { area in
                let selected = model.activeArea == area
                Button {
                    withAnimation(.easeOut(duration: 0.16)) {
                        model.setActiveArea(area)
                    }
                } label: {
                    Image(systemName: area.systemImage)
                        .font(.system(size: 14, weight: .semibold))
                        .symbolRenderingMode(.hierarchical)
                        .frame(width: 32, height: 26)
                        .foregroundStyle(selected ? Color.primary : Color.secondary.opacity(0.82))
                        .background(
                            selected ? Color.primary.opacity(0.16) : .clear,
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(area.title)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .frame(width: 64, height: 28)
        .help(model.activeArea.title)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(AppCopy.text("assistantMode.title"))
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

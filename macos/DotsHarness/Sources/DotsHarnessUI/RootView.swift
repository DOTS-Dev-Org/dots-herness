// Copyright (c) 2026 DOTS
// Root window for the standalone native harness.

import SwiftUI
import HarnessPluginKit
import PluginRuntime
import DotsHarnessCore

public struct RootView: View {
    @ObservedObject var model: AppModel
    private let logo: Image?

    public init(model: AppModel, logo: Image? = nil) {
        self.model = model
        self.logo = logo
    }

    public var body: some View {
        Group {
            if model.isSettingsPresented {
                SettingsView(model: model)
            } else {
                mainContent
            }
        }
        .preferredColorScheme(model.appearance.colorScheme)
        .environment(\.locale, model.appLocale)
        .environment(\.layoutDirection, model.isRTL ? .rightToLeft : .leftToRight)
        .background {
            PetFloatingWindowHost(model: model)
                .frame(width: 0, height: 0)
        }
        .sheet(isPresented: $model.isUsagePresented) {
            UsageSummaryView()
        }
        .sheet(isPresented: $model.isTasksPresented) {
            TasksView(model: model)
        }
        .task { model.refreshVoiceModel() }
        .onChange(of: model.voiceProvider) { _, _ in model.refreshVoiceModel() }
    }

    @ViewBuilder
    private var mainContent: some View {
        NavigationSplitView {
            SidebarView(model: model, logo: logo)
        } detail: {
            HStack(spacing: 0) {
                ConversationView(model: model)
                if model.isSimulatorPresented {
                    Divider()
                    SimulatorPanelView(model: model)
                }
            }
        }
        .overlay(alignment: .top) {
            SlotStack(slot: WellKnownSlot.overlay, registry: model.host.slots)
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    model.isSimulatorPresented.toggle()
                } label: {
                    Label(AppCopy.text("simulator.title"), systemImage: "iphone.gen3")
                }
                .help(AppCopy.text("simulator.title"))
            }
            ToolbarItem(placement: .automatic) {
                Button {
                    model.presentTasks()
                } label: {
                    Label(AppCopy.text("tasks.menu"), systemImage: "clock.arrow.circlepath")
                }
                .help(AppCopy.text("tasks.title"))
            }
            ToolbarItem(placement: .automatic) {
                Button {
                    model.presentSettings()
                } label: {
                    Label(AppCopy.text("settings.title"), systemImage: "gearshape")
                }
                .help(AppCopy.text("settings.title"))
            }
        }
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

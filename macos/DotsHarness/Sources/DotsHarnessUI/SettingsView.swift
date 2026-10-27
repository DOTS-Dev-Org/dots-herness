// Copyright (c) 2026 DOTS
// Native settings and plugin management surfaces.

import AppKit
import UniformTypeIdentifiers
import SwiftUI
import HarnessPluginKit
import DotsHarnessCore
import PluginRuntime

public struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var tab: Tab = .general
    @State private var sandboxName = ""
    @State private var discardSandboxConfirmation = false
    @State private var showAddSSHHost = false
    @State private var isKeyboardShortcutsExpanded = false
    @State private var sshRemovalAlias: String?
    @State private var sidebarVisibility: NavigationSplitViewVisibility = .all
    @State private var preferredSidebarVisibility: NavigationSplitViewVisibility = .all
    @State private var isSidebarCompact = false
    @State private var isApplyingAutomaticSidebarVisibility = false

    private static let sidebarAutoHideThreshold: CGFloat = 820

    public init(model: AppModel) {
        self.model = model
    }

    enum Tab: String, CaseIterable, Identifiable {
        case general, memoryTransfer, archive, providers, custom, local, media, share, mobile, skills, plugins, mcp, prompt, legal
        var id: String { rawValue }
        var title: String {
            rawValue == "archive"
                ? AppCopy.text("sidebar.archived")
                : rawValue == "skills" ? AppCopy.text("settings.tab.skills")
                : rawValue == "media" ? AppCopy.text("rail.media")
                : rawValue == "mcp" ? AppCopy.text("settings.tab.mcp")
                : rawValue == "legal" ? AppCopy.text("legal.title")
                : rawValue == "mobile" ? AppCopy.text("settings.tab.mobile") : AppCopy.text("settings.tab.\(rawValue)")
        }
    }

    private func memoryScanTitle(_ interval: MemoryScanInterval) -> String {
        AppCopy.text("settings.memory.scan.\(interval.rawValue)")
    }

    public var body: some View {
        GeometryReader { proxy in
            NavigationSplitView(columnVisibility: $sidebarVisibility) {
                List(Tab.allCases, selection: $tab) { item in
                    Text(item.title).tag(item)
                }
                .safeAreaInset(edge: .top, spacing: 0) {
                    Button {
                        model.isSettingsPresented = false
                    } label: {
                        Label(AppCopy.text("settings.backToChats"), systemImage: "chevron.left")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                    .help(AppCopy.text("settings.backToChats"))
                    .accessibilityLabel(AppCopy.text("settings.backToChats"))
                }
                .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 240)
            } detail: {
                switch tab {
                case .general: general
                case .memoryTransfer: MemoryTransferView(bridge: model.bridge)
                case .archive: ConversationArchiveView(model: model)
                case .providers: RouterProvidersView(router: model.router)
                case .custom: CustomAPIView(router: model.router, local: model.local)
                case .share: RouterShareView(router: model.router)
                case .mobile: RemoteMobileSettingsView(model: model)
                case .local: LocalModelsView(local: model.local)
                case .media: MediaSettingsView(model: model)
                case .skills: SkillsSettingsView(model: model)
                case .plugins: PluginSettingsView(model: model)
                case .mcp: MCPSettingsView(registry: model.mcpRegistry)
                case .prompt: prompt
                case .legal: LegalSettingsView(model: model)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .onAppear {
                synchronizeSidebarVisibility(for: proxy.size.width)
            }
            .onChange(of: proxy.size.width) { _, width in
                synchronizeSidebarVisibility(for: width)
            }
            .onChange(of: sidebarVisibility) { _, visibility in
                if isApplyingAutomaticSidebarVisibility {
                    isApplyingAutomaticSidebarVisibility = false
                } else {
                    preferredSidebarVisibility = visibility
                }
            }
        }
        .frame(minWidth: 520, minHeight: 560)
        .onAppear {
            if let requested = model.settingsInitialTab,
               let resolved = Tab(rawValue: requested),
               Tab.allCases.contains(resolved) {
                tab = resolved
            } else if !Tab.allCases.contains(tab) {
                tab = .general
            }
            // Writing nil over nil still publishes and redraws every AppModel observer.
            if model.settingsInitialTab != nil { model.settingsInitialTab = nil }
            model.refreshAvailableSandboxes()
        }
    }

    private func applyAutomaticSidebarVisibility(_ visibility: NavigationSplitViewVisibility) {
        guard sidebarVisibility != visibility else { return }
        isApplyingAutomaticSidebarVisibility = true
        sidebarVisibility = visibility
    }

    private func synchronizeSidebarVisibility(for width: CGFloat) {
        let compact = width < Self.sidebarAutoHideThreshold
        if compact {
            if !isSidebarCompact, sidebarVisibility != .detailOnly {
                preferredSidebarVisibility = sidebarVisibility
            }
            isSidebarCompact = true
            if sidebarVisibility != .detailOnly {
                applyAutomaticSidebarVisibility(.detailOnly)
            }
        } else if isSidebarCompact {
            isSidebarCompact = false
            applyAutomaticSidebarVisibility(preferredSidebarVisibility)
        }
    }

    /// Built in steps: as one expression this is slow enough to trip the type checker.
    private var explorationModelNote: String {
        let note = AppCopy.text("settings.explore.modelNote")
        guard let current = model.router.explorationModel.map({ $0.displayName ?? $0.id }) else { return note }
        return note + " " + AppCopy.format("settings.explore.current", current)
    }

    private var general: some View {
        Form {
            Section(AppCopy.text("settings.workspace")) {
                    LabeledContent(AppCopy.text("settings.folder")) {
                        Text(model.workspacePath.isEmpty ? AppCopy.text("settings.notSelected") : model.workspacePath)
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    HStack {
                        Button(model.workspacePath.isEmpty ? AppCopy.text("settings.chooseWorkspace") : AppCopy.text("settings.changeWorkspace")) {
                            model.chooseWorkspace()
                        }
                        if !model.workspacePath.isEmpty {
                            Button(AppCopy.text("settings.revealFinder"), action: model.revealWorkspace)
                        }
                }
            }
            Section(AppCopy.text("settings.sandbox")) {
                if let sandbox = model.activeSandbox {
                    Text(AppCopy.text("settings.sandboxOn")).foregroundStyle(.secondary)
                    if model.sandboxRecoveryRequired {
                        Text(AppCopy.text("settings.sandboxRecoveryRequired"))
                            .font(.callout)
                            .foregroundStyle(.orange)
                        Button(AppCopy.text("settings.sandboxRetryRecovery")) {
                            model.retrySandboxRecovery()
                        }
                        .disabled(model.bridge.anyRunBusy || model.bridge.historyMutationBusy || model.sandboxResolutionBusy)
                    }
                    LabeledContent(AppCopy.text("settings.sandboxName"), value: sandbox.name)
                    LabeledContent(AppCopy.text("settings.sandboxOrigin"), value: sandbox.originPath)
                    LabeledContent(AppCopy.text("settings.sandboxBranch"), value: sandbox.branch)
                    Toggle(AppCopy.text("settings.sandboxNetwork"), isOn: Binding(
                        get: { model.sandboxNetworkAccess },
                        set: { model.setSandboxNetworkAccess($0) }
                    ))
                    .disabled(model.sandboxCleanupPending || model.sandboxRecoveryRequired)
                    Text(AppCopy.text("settings.sandboxNetwork.hint"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button(AppCopy.text("settings.sandboxOpen"), action: model.revealSandbox)
                        Button(AppCopy.text("settings.sandboxOpenOrigin"), action: model.revealOriginWorkspace)
                    }
                    HStack {
                        Button(AppCopy.text("settings.sandboxMerge")) { model.exitSandbox(merge: true) }
                            .disabled(model.sandboxConflict != nil)
                        Button(AppCopy.text("settings.sandboxDiscard"), role: .destructive) {
                            discardSandboxConfirmation = true
                        }
                    }
                    .disabled(
                        model.bridge.anyRunBusy
                            || model.bridge.historyMutationBusy
                            || model.sandboxResolutionBusy
                            || model.sandboxCleanupPending
                            || model.sandboxRecoveryRequired
                    )

                    if model.sandboxCleanupPending {
                        Text(AppCopy.text("settings.sandboxCleanupPending"))
                            .font(.callout)
                            .foregroundStyle(.orange)
                        Button(AppCopy.text("settings.sandboxRetryCleanup")) {
                            model.retrySandboxCleanup()
                        }
                        .disabled(model.bridge.anyRunBusy || model.bridge.historyMutationBusy || model.sandboxRecoveryRequired)
                    }

                    if let conflict = model.sandboxConflict {
                        Divider()
                        Text(AppCopy.text("settings.sandboxConflicts"))
                            .font(.headline)
                        Text(conflict.files.joined(separator: "\n"))
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                        HStack {
                            Button(AppCopy.text("settings.sandboxPrepareResolution")) {
                                model.prepareSandboxResolution()
                            }
                            Button(AppCopy.text("settings.sandboxAskAgent")) {
                                Task { await model.askAgentToResolveSandboxConflict() }
                            }
                            Button(AppCopy.text("settings.sandboxPreview")) {
                                model.previewSandboxResolution()
                            }
                        }
                        .disabled(
                            model.bridge.anyRunBusy
                                || model.bridge.historyMutationBusy
                                || model.sandboxResolutionBusy
                                || model.sandboxRecoveryRequired
                        )

                        if let preview = model.sandboxResolutionPreview {
                            Text(AppCopy.text("settings.sandboxResolutionReady"))
                                .font(.headline)
                            LabeledContent(
                                AppCopy.text("settings.sandboxUnresolved"),
                                value: "\(preview.unresolvedFiles.count)"
                            )
                            LabeledContent(AppCopy.text("settings.sandboxOriginHead"), value: conflict.originHead)
                            LabeledContent(AppCopy.text("settings.sandboxHead"), value: conflict.sandboxHead)
                            LabeledContent(AppCopy.text("settings.sandboxFingerprint"), value: preview.fingerprint)
                            ScrollView {
                                Text(preview.diff.isEmpty ? AppCopy.text("settings.sandboxResolutionIncomplete") : preview.diff)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(8)
                            }
                            .frame(maxHeight: 240)
                            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
                            if preview.isTruncated || !preview.unresolvedFiles.isEmpty {
                                Text(AppCopy.text("settings.sandboxResolutionIncomplete"))
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                            HStack {
                                Button(AppCopy.text("settings.sandboxApprove")) {
                                    model.applySandboxResolution()
                                }
                                .disabled(
                                    model.bridge.anyRunBusy
                                        || model.bridge.historyMutationBusy
                                        || model.sandboxResolutionBusy
                                        || model.sandboxRecoveryRequired
                                        || preview.isTruncated
                                        || !preview.unresolvedFiles.isEmpty
                                )
                                Button(AppCopy.text("settings.sandboxCancelResolution")) {
                                    model.cancelSandboxResolution()
                                }
                                .disabled(
                                    model.bridge.anyRunBusy
                                        || model.bridge.historyMutationBusy
                                        || model.sandboxResolutionBusy
                                        || model.sandboxRecoveryRequired
                                )
                            }
                        }
                    }
                } else {
                    Text(AppCopy.text("settings.sandboxOff")).foregroundStyle(.secondary)
                    // Set before starting: once running, network state is a
                    // process-launch policy — changing it later restarts
                    // whatever it affects, so decide up front.
                    Toggle(AppCopy.text("settings.sandboxNetwork"), isOn: Binding(
                        get: { model.sandboxNetworkAccess },
                        set: { model.setSandboxNetworkAccess($0) }
                    ))
                    Text(AppCopy.text("settings.sandboxNetwork.hint"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        TextField(AppCopy.text("settings.sandboxName"), text: $sandboxName)
                        Button(AppCopy.text("settings.sandboxEnter")) {
                            model.enterSandbox(named: sandboxName)
                            sandboxName = ""
                        }
                        .disabled(model.workspacePath.isEmpty || sandboxName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    if !model.availableSandboxes.isEmpty {
                        Text(AppCopy.text("settings.sandboxRecovery"))
                            .font(.headline)
                        ForEach(model.availableSandboxes, id: \.path) { candidate in
                            HStack {
                                Text(candidate.name)
                                Spacer()
                                Button(AppCopy.text("settings.sandboxRecover")) {
                                    model.recoverSandbox(candidate)
                                }
                            }
                        }
                    }
                }
                if let notice = model.sandboxNotice {
                    Text(notice).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            Section(AppCopy.text("settings.sshHosts")) {
                Text(AppCopy.text("settings.sshHosts.hint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !SSHRunner.isAvailable {
                    Text(AppCopy.text("ssh.error.unavailable")).foregroundStyle(.secondary)
                } else if model.sshHosts.isEmpty {
                    Text(AppCopy.text("settings.sshNoHosts")).foregroundStyle(.secondary)
                } else {
                    ForEach(model.sshHosts) { host in
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(host.alias)
                                Text(host.displayDestination)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(model.sshStore.record(alias: host.alias).managedByApp
                                 ? AppCopy.text("settings.sshManaged")
                                 : AppCopy.text("settings.sshFromConfig"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button(AppCopy.text("settings.sshTest")) {
                                model.testSSHHost(alias: host.alias)
                            }
                            Button(AppCopy.text("settings.sshRemove"), role: .destructive) {
                                sshRemovalAlias = host.alias
                            }
                            .disabled(!model.sshStore.record(alias: host.alias).managedByApp)
                            .help(model.sshStore.record(alias: host.alias).managedByApp
                                  ? AppCopy.text("settings.sshRemove")
                                  : AppCopy.text("settings.sshRemove.handWritten"))
                        }
                    }
                }
                Button(AppCopy.text("settings.sshAddHost")) { showAddSSHHost = true }
                    .disabled(!SSHRunner.isAvailable)
                if let notice = model.sshNotice {
                    Text(notice).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            Section(AppCopy.text("settings.model")) {
                if model.router.models.isEmpty {
                    Text(model.router.reachable
                         ? AppCopy.text("settings.noModel")
                         : AppCopy.text("settings.routerUnavailable"))
                        .foregroundStyle(.secondary)
                } else {
                    Picker(AppCopy.text("settings.model"), selection: Binding(
                        get: { model.selectedModelID },
                        set: { model.setModel($0) }
                    )) {
                        ForEach(RouterCatalog.modelGroups(for: model.router.models)) { group in
                            Section {
                                ForEach(group.models) { item in
                                    Text(RouterCatalog.modelDisplayName(for: item)).tag(item.id)
                                }
                            } header: {
                                Label(group.name, systemImage: group.logoSymbol)
                            }
                        }
                    }
                }
                LabeledContent(AppCopy.text("settings.status")) {
                    Text(model.statusLine)
                        .foregroundStyle(.secondary)
                }
                LabeledContent(AppCopy.text("settings.endpoint")) {
                    Text(AppCopy.text("settings.nativeRouting"))
                        .font(.caption)
                }
                HStack {
                    Button(AppCopy.text("settings.refreshModels")) { Task { await model.router.refreshModels(force: true) } }
                    if !model.router.reachable {
                        Text(AppCopy.text("settings.routerHint"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(model.router.modelListIssues, id: \.self) { issue in
                    Text(issue).font(.caption).foregroundStyle(.orange)
                }
            }
            Section(AppCopy.text("router.accountRouting")) {
                Toggle(AppCopy.text("router.autoAccountFailover"), isOn: Binding(
                    get: { model.router.autoAccountFailoverAfterLimit },
                    set: { model.setAutoAccountFailoverAfterLimit($0) }
                ))
                Text(AppCopy.text("router.autoAccountFailover.hint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section(AppCopy.text("settings.appearance")) {
                LabeledContent(AppCopy.text("settings.language")) {
                    LanguagePickerButton(model: model)
                }
                Picker(AppCopy.text("settings.theme"), selection: Binding(
                    get: { model.appearance },
                    set: { model.setAppearance($0) }
                )) {
                    ForEach(AppModel.Appearance.allCases) { item in
                        Text(AppCopy.text("appearance.\(item.rawValue)")).tag(item)
                    }
                }
                Toggle(AppCopy.text("settings.confirmBeforeExit"), isOn: Binding(
                    get: { model.confirmBeforeExit },
                    set: { model.setConfirmBeforeExit($0) }
                ))
                Toggle(AppCopy.text("settings.closeToTray"), isOn: Binding(
                    get: { model.closeToTray },
                    set: { model.setCloseToTray($0) }
                ))
                Text(AppCopy.text("settings.closeToTray.hint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle(AppCopy.text("settings.selfVerification"), isOn: Binding(
                    get: { model.selfVerification },
                    set: { model.setSelfVerification($0) }
                ))
                Text(AppCopy.text("settings.selfVerification.hint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle(AppCopy.text("settings.autoApprovePlans"), isOn: Binding(
                    get: { model.autoApprovePlans },
                    set: { model.setAutoApprovePlans($0) }
                ))
                Text(AppCopy.text("settings.autoApprovePlans.hint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle(AppCopy.text("settings.seedProjectRules"), isOn: Binding(
                    get: { model.seedProjectRules },
                    set: { model.setSeedProjectRules($0) }
                ))
                Text(AppCopy.text("settings.seedProjectRules.hint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle(AppCopy.text("settings.skillSuggestions"), isOn: Binding(
                    get: { model.skillSuggestionsEnabled },
                    set: { model.setSkillSuggestionsEnabled($0) }
                ))
                Text(AppCopy.text("settings.skillSuggestions.hint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker(AppCopy.text("settings.workspaceConflictPolicy"), selection: Binding(
                    get: { model.workspaceConflictPolicy },
                    set: { model.setWorkspaceConflictPolicy($0) }
                )) {
                    ForEach(WorkspaceConflictPolicy.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                Text(model.workspaceConflictPolicy.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if model.workspaceConflictPolicy == .waitThenAsk {
                    Picker(AppCopy.text("settings.conflictWaitSeconds"), selection: Binding(
                        get: { model.conflictWaitSeconds },
                        set: { model.setConflictWaitSeconds($0) }
                    )) {
                        ForEach(WorkspaceConflictPolicy.waitChoices, id: \.self) { seconds in
                            Text(AppCopy.format("settings.conflictWaitValue", seconds)).tag(seconds)
                        }
                    }
                }
            }
            Section(AppCopy.text("settings.explore.title")) {
                Toggle(AppCopy.text("settings.explore.subagents"), isOn: Binding(
                    get: { model.router.subagentsEnabled },
                    set: { model.setSubagentsEnabled($0) }
                ))
                Text(AppCopy.text("settings.explore.hint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker(AppCopy.text("settings.explore.model"), selection: Binding(
                    get: {
                        model.router.explorationModels.contains { $0.id == model.router.explorationModelID }
                            ? model.router.explorationModelID
                            : ""
                    },
                    set: { model.setExplorationModel($0) }
                )) {
                    Text(AppCopy.text("settings.explore.auto")).tag("")
                    ForEach(model.router.explorationModels) { candidate in
                        Text(candidate.displayName ?? candidate.id).tag(candidate.id)
                    }
                }
                .disabled(!model.router.subagentsEnabled)
                Text(explorationModelNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section(AppCopy.text("settings.tab.memory")) {
                Toggle(AppCopy.text("settings.memory.on"), isOn: Binding(
                    get: { model.bridge.memoryEnabled },
                    set: { model.setMemoryEnabled($0) }
                ))
                Text(AppCopy.text("settings.memory.offHint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker(AppCopy.text("settings.memory.scanEvery"), selection: Binding(
                    get: { model.bridge.memoryScanInterval },
                    set: { model.setMemoryScanInterval($0) }
                )) {
                    ForEach(MemoryScanInterval.allCases) { interval in
                        Text(memoryScanTitle(interval)).tag(interval)
                    }
                }
                .disabled(!model.bridge.memoryEnabled)
                Text(AppCopy.text("settings.memory.hint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LabeledContent(AppCopy.text("settings.status")) {
                    Text(AppCopy.format("settings.memory.statusLine", model.bridge.insightCount, model.bridge.unscannedTaskCount)
                         + (model.bridge.lastMemoryScan.map { " · " + $0.formatted(.relative(presentation: .named).locale(AppCopy.locale)) } ?? ""))
                        .foregroundStyle(.secondary)
                }
                Button(AppCopy.text("settings.memory.scanNow")) {
                    Task { await model.bridge.scanMemoryNow() }
                }
                .disabled(model.bridge.memoryScanRunning || model.bridge.unscannedTaskCount == 0)
            }
            Section(AppCopy.text("settings.responseStyle")) {
                Picker(AppCopy.text("settings.responseStyle.default"), selection: Binding(
                    get: { model.router.responseStylePreference },
                    set: { model.setResponseStylePreference($0) }
                )) {
                    ForEach(AgentResponseStylePreference.allCases) { preference in
                        Text(preference.title).tag(preference)
                    }
                }
                Text(model.router.responseStylePreference.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(AppCopy.text("settings.responseStyle.hint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section(AppCopy.text("settings.browser.title")) {
                Picker(AppCopy.text("settings.browser.engine"), selection: Binding(
                    get: { model.browserBackend?.rawValue ?? BrowserBackend.unknown.rawValue },
                    set: { rawValue in
                        model.setBrowserBackend(
                            rawValue == BrowserBackend.unknown.rawValue ? nil : BrowserBackend(rawValue: rawValue)
                        )
                    }
                )) {
                    Text(AppCopy.text("settings.browser.auto")).tag(BrowserBackend.unknown.rawValue)
                    Text(AppCopy.text("settings.browser.native")).tag(BrowserBackend.native.rawValue)
                    Text(AppCopy.text("settings.browser.safari")).tag(BrowserBackend.safari.rawValue)
                    Text(AppCopy.text("settings.browser.chrome")).tag(BrowserBackend.`extension`.rawValue)
                    Text(AppCopy.text("settings.browser.managed")).tag(BrowserBackend.managed.rawValue)
                }
                Text(AppCopy.text("settings.browser.hint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section(AppCopy.text("settings.computerUse.title")) {
                Toggle(AppCopy.text("settings.computerUse.enable"), isOn: Binding(
                    get: { model.isComputerUseEnabled },
                    set: { model.setComputerUseEnabled($0) }
                ))
                Text(AppCopy.text("settings.computerUse.hint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if model.isComputerUseEnabled {
                    let perms = ComputerUseService.permissions()
                    LabeledContent(AppCopy.text("settings.computerUse.screenRecording")) {
                        HStack(spacing: 8) {
                            Text(AppCopy.text(perms.screenRecording ? "settings.computerUse.granted" : "settings.computerUse.required"))
                                .foregroundStyle(perms.screenRecording ? .green : .orange)
                            if !perms.screenRecording {
                                Button(AppCopy.text("settings.computerUse.request")) {
                                    ComputerUseService.requestScreenRecordingPermission()
                                    ComputerUseService.openSystemSettings(privacyPane: "screen")
                                }
                            }
                        }
                    }
                    LabeledContent(AppCopy.text("settings.computerUse.accessibility")) {
                        HStack(spacing: 8) {
                            Text(AppCopy.text(perms.accessibility ? "settings.computerUse.granted" : "settings.computerUse.required"))
                                .foregroundStyle(perms.accessibility ? .green : .orange)
                            if !perms.accessibility {
                                Button(AppCopy.text("settings.computerUse.request")) {
                                    ComputerUseService.requestAccessibilityPermission()
                                    ComputerUseService.openSystemSettings(privacyPane: "accessibility")
                                }
                            }
                        }
                    }
                }
            }
            Section(AppCopy.text("tasks.title")) {
                Toggle(AppCopy.text("tasks.background"), isOn: Binding(
                    get: { model.isBackgroundDaemonEnabled },
                    set: { enabled in try? model.setBackgroundDaemonEnabled(enabled) }
                ))
                Text(AppCopy.text("tasks.background.hint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button(AppCopy.text("tasks.title")) { model.presentTasks() }
            }
            Section(AppCopy.text("settings.shortcuts")) {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        isKeyboardShortcutsExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: isKeyboardShortcutsExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 14)
                        Label(AppCopy.text("settings.shortcuts"), systemImage: "keyboard")
                        Spacer(minLength: 12)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if isKeyboardShortcutsExpanded {
                    KeyboardShortcutsSettingsView(model: model) {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            isKeyboardShortcutsExpanded = false
                        }
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                } else {
                    Text(AppCopy.text("settings.shortcuts.hint"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            SettingsUpdateSection(model: model, checker: model.updateChecker)
            Section(AppCopy.text("settings.storage")) {
                LabeledContent(AppCopy.text("settings.supportFolder")) {
                    Text(model.paths.root.path)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                LabeledContent(AppCopy.text("settings.sessions")) {
                    Text(model.paths.root.appendingPathComponent("sessions.json").path)
                        .textSelection(.enabled)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            Text(AppCopy.text("settings.stateNote"))
                .font(.caption)
                .foregroundStyle(.secondary)
            SlotStack(slot: WellKnownSlot.settingsSections, registry: model.host.slots)
        }
        .formStyle(.grouped)
        .padding()
        .navigationTitle(AppCopy.text("settings.tab.general"))
        .confirmationDialog(
            AppCopy.text("settings.sandboxDiscardConfirm"),
            isPresented: $discardSandboxConfirmation
        ) {
            Button(AppCopy.text("settings.sandboxDiscard"), role: .destructive) {
                model.exitSandbox(merge: false)
            }
            Button(AppCopy.text("common.cancel"), role: .cancel) {}
        }
        .confirmationDialog(
            AppCopy.format("settings.sshRemoveConfirm", sshRemovalAlias ?? ""),
            isPresented: Binding(
                get: { sshRemovalAlias != nil },
                set: { if !$0 { sshRemovalAlias = nil } }
            )
        ) {
            Button(AppCopy.text("settings.sshRemove"), role: .destructive) {
                if let alias = sshRemovalAlias { model.removeSSHHost(alias: alias) }
                sshRemovalAlias = nil
            }
            Button(AppCopy.text("common.cancel"), role: .cancel) { sshRemovalAlias = nil }
        }
        .sheet(isPresented: $showAddSSHHost) {
            AddSSHHostView(model: model)
        }
    }

    private var prompt: some View {
        // Built once per redraw: it reads memory, lessons and the code graph.
        let systemPrompt = model.effectiveSystemPrompt()
        return ScrollView {
            Text(systemPrompt.isEmpty ? AppCopy.text("settings.promptEmpty") : systemPrompt)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle(AppCopy.text("settings.promptTitle"))
    }
}

private struct SettingsUpdateSection: View {
    @ObservedObject var model: AppModel
    @ObservedObject var checker: UpdateChecker

    var body: some View {
        Section(AppCopy.text("settings.updates.title")) {
            LabeledContent(AppCopy.text("settings.updates.current")) {
                Text("v\(checker.currentVersion) (\(checker.currentBuild))")
                    .font(.subheadline.monospaced())
                    .foregroundStyle(.secondary)
            }
            Toggle(AppCopy.text("settings.updates.auto"), isOn: Binding(
                get: { model.autoUpdate },
                set: { model.setAutoUpdate($0) }
            ))
            Text(AppCopy.text("settings.updates.auto.hint"))
                .font(.caption)
                .foregroundStyle(.secondary)

            switch checker.state {
            case .installing:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(AppCopy.text("settings.updates.installing"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .checking:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(AppCopy.text("settings.updates.checking"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .updateAvailable(let info), .mandatoryUpdate(let info):
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.down.circle.fill")
                            .foregroundStyle(info.mandatory ? .red : .accentColor)
                        Text(AppCopy.format("settings.updates.available", info.latestVersion))
                            .font(.subheadline.bold())
                        if info.mandatory {
                            Text(AppCopy.text("settings.updates.required"))
                                .font(.caption2.bold())
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.red.opacity(0.15), in: Capsule())
                                .foregroundStyle(.red)
                        }
                    }

                    if !info.releaseNotes.isEmpty {
                        Text(info.releaseNotes)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(6)
                            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
                    }

                    HStack(spacing: 8) {
                        Button(AppCopy.text("settings.updates.install")) {
                            Task { await checker.installUpdate() }
                        }
                        .buttonStyle(.borderedProminent)

                        Button(AppCopy.text("settings.updates.checkAgain")) {
                            Task { await checker.checkForUpdates(manual: true) }
                        }
                    }
                }
            case .upToDate:
                HStack {
                    Label(AppCopy.text("settings.updates.upToDate"), systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                    Spacer()
                    Button(AppCopy.text("settings.updates.check")) {
                        Task { await checker.checkForUpdates(manual: true) }
                    }
                }
            case .failed(let error):
                HStack {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                    Spacer()
                    Button(AppCopy.text("settings.updates.retry")) {
                        Task { await checker.checkForUpdates(manual: true) }
                    }
                }
            case .idle:
                HStack {
                    Text(AppCopy.text("settings.updates.hint"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(AppCopy.text("settings.updates.check")) {
                        Task { await checker.checkForUpdates(manual: true) }
                    }
                }
            }
        }
    }
}

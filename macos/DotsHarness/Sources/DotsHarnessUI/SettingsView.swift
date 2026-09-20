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
    @AppStorage(AgentContextCompactionPolicy.triggerPercentKey) private var compactPercent = 0.0
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
        case general, access, memory, archive, providers, custom, local, share, mobile, skills, plugins, mcp, prompt, legal
        var id: String { rawValue }
        var title: String {
            rawValue == "archive"
                ? AppCopy.text("sidebar.archived")
                : rawValue == "skills" ? AppCopy.text("settings.tab.skills")
                : rawValue == "mcp" ? "MCP servers"
                : rawValue == "legal" ? AppCopy.text("legal.title")
                : rawValue == "mobile" ? "Mobile control" : AppCopy.text("settings.tab.\(rawValue)")
        }
    }

    private var visibleTabs: [Tab] {
        model.activeArea == .coding
            ? Array(Tab.allCases)
            : Tab.allCases.filter { ![.access, .memory, .mobile].contains($0) }
    }

    public var body: some View {
        GeometryReader { proxy in
            NavigationSplitView(columnVisibility: $sidebarVisibility) {
                List(visibleTabs, selection: $tab) { item in
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
                case .access: WorkspaceAccessView(bridge: model.bridge)
                case .memory: MemoryVaultView(bridge: model.bridge)
                case .archive: ConversationArchiveView(model: model)
                case .providers: RouterProvidersView(router: model.router)
                case .custom: CustomAPIView(router: model.router, local: model.local)
                case .share: RouterShareView(router: model.router)
                case .mobile: RemoteMobileSettingsView(model: model)
                case .local: LocalModelsView(local: model.local)
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
               visibleTabs.contains(resolved) {
                tab = resolved
            } else if !visibleTabs.contains(tab) {
                tab = .general
            }
            model.settingsInitialTab = nil
            model.refreshAvailableSandboxes()
        }
        .onChange(of: model.activeArea) { _, _ in
            if !visibleTabs.contains(tab) { tab = .general }
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

    private var general: some View {
        Form {
            if model.activeArea == .coding {
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
            }
            if model.activeArea == .coding {
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
                Toggle(AppCopy.text("settings.selfVerification"), isOn: Binding(
                    get: { model.selfVerification },
                    set: { model.setSelfVerification($0) }
                ))
                Text(AppCopy.text("settings.selfVerification.hint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle(AppCopy.text("settings.seedProjectRules"), isOn: Binding(
                    get: { model.seedProjectRules },
                    set: { model.setSeedProjectRules($0) }
                ))
                Text(AppCopy.text("settings.seedProjectRules.hint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(AppCopy.text("settings.compactTrigger"))
                        Spacer()
                        Text("\(Int(compactPercent > 0 ? compactPercent : 80))%")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Slider(
                        value: Binding(get: { compactPercent > 0 ? compactPercent : 80 }, set: { compactPercent = $0 }),
                        in: 50...95,
                        step: 5
                    )
                    Text(AppCopy.text("settings.compactTrigger.hint"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section("Browser backend") {
                Picker("Backend", selection: Binding(
                    get: { model.browserBackend?.rawValue ?? BrowserBackend.unknown.rawValue },
                    set: { rawValue in
                        model.setBrowserBackend(
                            rawValue == BrowserBackend.unknown.rawValue ? nil : BrowserBackend(rawValue: rawValue)
                        )
                    }
                )) {
                    Text("Automatic (ask when unclear)").tag(BrowserBackend.unknown.rawValue)
                    Text("Managed isolated browser").tag(BrowserBackend.managed.rawValue)
                    Text("Existing Chrome profile").tag(BrowserBackend.`extension`.rawValue)
                }
                Text("The selected backend is fixed for each run. Extension setup failures are shown instead of falling back silently.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
            Section(AppCopy.text("settings.storage")) {
                LabeledContent(AppCopy.text("settings.supportFolder")) {
                    Text(model.paths.root.path)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                LabeledContent(AppCopy.text("settings.sessions")) {
                    Text(model.paths.root.appendingPathComponent(model.activeArea.sessionFileName).path)
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
        ScrollView {
            Text(model.effectiveSystemPrompt().isEmpty ? AppCopy.text("settings.promptEmpty") : model.effectiveSystemPrompt())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle(AppCopy.text("settings.promptTitle"))
    }
}

private struct RemoteMobileSettingsView: View {
    @ObservedObject var model: AppModel
    @State private var tunnelError = ""

    var body: some View {
        Form {
            Section("Native mobile workspace") {
                LabeledContent("LAN endpoint", value: model.remoteControl.preferredEndpoint)
                if let pairing = activePairing {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Scan this QR code or enter the one-time code in HerNess Mobile.").font(.caption)
                        if let image = qrImage(pairing.payload) {
                            Image(nsImage: image).resizable().interpolation(.none).frame(width: 180, height: 180).accessibilityLabel("Mobile pairing QR code")
                        }
                        LabeledContent("Code", value: pairing.code).textSelection(.enabled)
                        Text(pairing.payload).font(.caption.monospaced()).textSelection(.enabled)
                        Text("Expires \(pairing.expiresAt.formatted())").font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(14)
                    .background(.black.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                HStack {
                    Button("New pairing code") { _ = model.beginRemotePairing() }
                    Button("Copy pairing link") {
                        if let value = activePairing?.payload { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string) }
                    }.disabled(activePairing == nil)
                }
                HStack {
                    Button("Enable Cloudflare Quick Tunnel") { Task { do { _ = try await model.enableRemoteCloudTunnel() } catch { tunnelError = error.localizedDescription } } }
                    if model.remoteControl.publicEndpoint != nil { Button("Disable tunnel") { model.disableRemoteCloudTunnel() } }
                }
                if !tunnelError.isEmpty { Text(tunnelError).font(.caption).foregroundStyle(.red) }
                Text("Provider keys stay on the desktop. File writes, terminal, build, deploy, and PR actions still use the selected approval mode.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .navigationTitle("Mobile control")
        .onAppear { if activePairing == nil { _ = model.beginRemotePairing() } }
    }

    private var activePairing: RemotePairingInfo? {
        guard let pairing = model.remoteControl.pairing, pairing.expiresAt > Date() else { return nil }
        return pairing
    }

    private func qrImage(_ value: String) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(value.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let extent = output.extent.insetBy(dx: -8, dy: -8)
        let context = CIContext(options: nil)
        guard let cgImage = context.createCGImage(output, from: extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: 220, height: 220))
    }
}

private struct SkillsSettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var skills: SkillCatalog
    @State private var tab: Section = .catalog
    @State private var selectedSkill: SkillDescriptor?
    @State private var error = ""

    private enum Section: String, CaseIterable {
        case catalog, installed

        var title: String { AppCopy.text("settings.skills.\(rawValue)") }
    }

    init(model: AppModel) {
        self.model = model
        self.skills = model.activeSkills
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(AppCopy.text("settings.tab.skills"))
                .font(.title2.weight(.semibold))
            Picker(AppCopy.text("settings.tab.skills"), selection: $tab) {
                ForEach(Section.allCases, id: \.self) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 360)
            if tab == .catalog { catalog } else { installed }
            if !error.isEmpty {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .padding()
        .navigationTitle(AppCopy.text("settings.tab.skills"))
        .sheet(item: $selectedSkill) { skill in
            ScrollView {
                Text((try? skills.read(id: skill.id, includeDisabled: true)) ?? AppCopy.text("settings.skillReadFailed"))
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .frame(minWidth: 680, minHeight: 520)
            .navigationTitle(skill.name)
        }
    }

    private var catalog: some View {
        List(skills.marketplaceEntries) { entry in
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.name).font(.headline)
                        Text(entry.id).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if skills.isInstalled(entry) {
                        Text(AppCopy.text("local.installed")).font(.caption).foregroundStyle(.secondary)
                    } else if entry.downloadURL != nil {
                        Button(AppCopy.text("common.download")) {
                            Task {
                                do { try await skills.install(entry) }
                                catch { self.error = error.localizedDescription }
                            }
                        }
                    }
                }
                Text(entry.description).font(.caption)
                HStack(spacing: 10) {
                    if let githubURL = entry.githubURL, let url = URL(string: githubURL) { Link("GitHub", destination: url) }
                    if let skillURL = entry.skillURL, let url = URL(string: skillURL) { Link("SKILL.md", destination: url) }
                    Text(AppCopy.format("settings.skillsSnapshot", entry.snapshotDate))
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var installed: some View {
        List(skills.entries) { skill in
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(skill.name).font(.headline)
                    Text("\(skill.id) · \(skill.source.rawValue)")
                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                    Text(skill.description).font(.caption).lineLimit(2)
                }
                Spacer()
                Button(AppCopy.text("common.view")) { selectedSkill = skill }
                Toggle(AppCopy.text("settings.enabled"), isOn: Binding(
                    get: { skill.enabled },
                    set: { skills.setEnabled(skill.id, $0) }
                ))
                .labelsHidden()
                if skill.isInstalled {
                    Button(AppCopy.text("common.delete"), role: .destructive) {
                        do { try skills.remove(skill.id) }
                        catch let caughtError { error = caughtError.localizedDescription }
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .overlay(alignment: .bottomLeading) {
            Text(AppCopy.text("settings.skillsHint"))
                .font(.caption).foregroundStyle(.secondary).padding(.top, 8)
        }
    }
}

private struct ConversationArchiveView: View {
    @ObservedObject var model: AppModel
    @State private var pendingDeleteConversationID: String?
    @State private var pendingDeleteProjectID: String?

    // MARK: - Chat area data

    private var archivedProjects: [ChatProject] {
        model.chatProjects
            .filter(\.archived)
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private var archivedChatConversations: [Conversation] {
        // Only standalone (unassigned) archived chat conversations.
        // Conversations that belong to an archived project are shown
        // under their project row, not listed separately here.
        let archivedProjectIDs = Set(archivedProjects.map(\.id))
        return model.chatBridge.archivedConversations
            .filter { conv in
                guard let pid = conv.chatProjectID else { return true }
                return !archivedProjectIDs.contains(pid)
            }
            .sorted {
                ($0.messages.map(\.createdAt).max() ?? .distantPast)
                    > ($1.messages.map(\.createdAt).max() ?? .distantPast)
            }
    }

    // MARK: - Coding area data

    private var archivedCodingConversations: [Conversation] {
        model.codingBridge.archivedConversations.sorted {
            ($0.messages.map(\.createdAt).max() ?? .distantPast)
                > ($1.messages.map(\.createdAt).max() ?? .distantPast)
        }
    }

    private var isChat: Bool { model.activeArea == .chat }

    var body: some View {
        Form {
            if isChat {
                chatArchiveContent
            } else {
                conversationSection(
                    conversations: archivedCodingConversations,
                    bridge: model.codingBridge
                )
            }
        }
        .formStyle(.grouped)
        .padding()
        .navigationTitle(AppCopy.text("sidebar.archived"))
        // Conversation delete confirmation
        .confirmationDialog(
            AppCopy.text("sidebar.deleteChat"),
            isPresented: Binding(
                get: { pendingDeleteConversationID != nil },
                set: { if !$0 { pendingDeleteConversationID = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(AppCopy.text("sidebar.deleteChat"), role: .destructive) {
                if let id = pendingDeleteConversationID {
                    model.bridge.deleteConversation(id)
                }
                pendingDeleteConversationID = nil
            }
            Button(AppCopy.text("common.cancel"), role: .cancel) {
                pendingDeleteConversationID = nil
            }
        }
        // Project delete confirmation
        .confirmationDialog(
            AppCopy.text("sidebar.deleteProject"),
            isPresented: Binding(
                get: { pendingDeleteProjectID != nil },
                set: { if !$0 { pendingDeleteProjectID = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(AppCopy.text("sidebar.deleteProject"), role: .destructive) {
                if let id = pendingDeleteProjectID {
                    model.deleteChatProject(id)
                }
                pendingDeleteProjectID = nil
            }
            Button(AppCopy.text("common.cancel"), role: .cancel) {
                pendingDeleteProjectID = nil
            }
        }
    }

    // MARK: - Chat archive content

    @ViewBuilder
    private var chatArchiveContent: some View {
        Section(AppCopy.text("sidebar.projects")) {
            if archivedProjects.isEmpty {
                Text(AppCopy.text("sidebar.noChats"))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(archivedProjects) { project in
                    HStack(spacing: 10) {
                        Image(systemName: "bubble.left.and.bubble.right")
                            .foregroundStyle(.secondary)
                            .frame(width: 16, height: 16)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(project.name)
                                .lineLimit(1)
                            let count = model.chatConversations(in: project.id).count
                            if count > 0 {
                                Text("\(count) chat\(count == 1 ? "" : "s")")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        if project.pinned {
                            Image(systemName: "pin.fill")
                                .foregroundStyle(Color.accentColor)
                        }

                        Button {
                            model.setChatProjectArchived(project.id, archived: false)
                        } label: {
                            Image(systemName: "arrow.uturn.backward")
                                .frame(width: 24, height: 24)
                        }
                        .buttonStyle(.borderless)
                        .help(AppCopy.text("sidebar.unarchiveProject"))
                        .accessibilityLabel(AppCopy.text("sidebar.unarchiveProject"))

                        Button {
                            pendingDeleteProjectID = project.id
                        } label: {
                            Image(systemName: "trash")
                                .frame(width: 24, height: 24)
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.red)
                        .help(AppCopy.text("sidebar.deleteProject"))
                        .accessibilityLabel(AppCopy.text("sidebar.deleteProject"))
                    }
                    .padding(.vertical, 2)
                }
            }
        }

        conversationSection(
            conversations: archivedChatConversations,
            bridge: model.chatBridge
        )
    }

    // MARK: - Shared conversation section

    @ViewBuilder
    private func conversationSection(conversations: [Conversation], bridge: AgentBridge) -> some View {
        Section(AppCopy.text("sidebar.archived")) {
            if conversations.isEmpty {
                Text(AppCopy.text("sidebar.noChats"))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(conversations) { conversation in
                    HStack(spacing: 10) {
                        statusIcon(conversation)

                        Text(conversation.title)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        if conversation.pinned {
                            Image(systemName: "pin.fill")
                                .foregroundStyle(Color.accentColor)
                                .accessibilityLabel(AppCopy.text("sidebar.pinChat"))
                        }

                        Button {
                            bridge.setArchived(conversation.id, archived: false)
                        } label: {
                            Image(systemName: "arrow.uturn.backward")
                                .frame(width: 24, height: 24)
                        }
                        .buttonStyle(.borderless)
                        .help(AppCopy.text("sidebar.unarchiveChat"))
                        .accessibilityLabel(AppCopy.text("sidebar.unarchiveChat"))

                        Button {
                            pendingDeleteConversationID = conversation.id
                        } label: {
                            Image(systemName: "trash")
                                .frame(width: 24, height: 24)
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.red)
                        .help(AppCopy.text("sidebar.deleteChat"))
                        .accessibilityLabel(AppCopy.text("sidebar.deleteChat"))
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    @ViewBuilder
    private func statusIcon(_ conversation: Conversation) -> some View {
        if conversation.running {
            ProgressView()
                .controlSize(.small)
                .frame(width: 16, height: 16)
                .accessibilityLabel(AppCopy.text("sidebar.chatRunning"))
        } else if !conversation.blank {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color.blue)
                .accessibilityLabel(AppCopy.text("sidebar.chatCompleted"))
        }
    }
}

private struct WorkspaceAccessView: View {
    @ObservedObject var bridge: AgentBridge
    @State private var inviteName = ""
    @State private var invitePublicKey = ""
    @State private var inviteRole: MemoryRole = .contributor
    @State private var inviteScore = 50
    @State private var inviteToken = ""
    @State private var acceptedToken = ""
    @State private var error = ""

    var body: some View {
        Form {
            let access = bridge.workspaceAccess
            Section(AppCopy.text("access.currentActor")) {
                LabeledContent(AppCopy.text("access.role")) { Text(access.role?.title ?? AppCopy.text("access.notAuthorized")) }
                LabeledContent(AppCopy.text("access.score")) { Text(String(access.score)) }
                LabeledContent(AppCopy.text("access.device")) {
                    Text(access.deviceID.isEmpty ? "—" : String(access.deviceID.prefix(20)))
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
                if let publicKey = bridge.memoryDevicePublicKey {
                    LabeledContent(AppCopy.text("access.publicKey")) {
                        Text(publicKey).font(.caption2.monospaced()).textSelection(.enabled)
                    }
                }
                LabeledContent(AppCopy.text("access.memoryRevision")) { Text(String(access.revision)) }
            }

            Section(AppCopy.text("access.members")) {
                if bridge.workspaceMembers.isEmpty {
                    Text(AppCopy.text("access.noMembers"))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(bridge.workspaceMembers.indices, id: \.self) { index in
                        let member = bridge.workspaceMembers[index]
                        HStack {
                            VStack(alignment: .leading) {
                                Text(member["displayName"] ?? member["personId"] ?? AppCopy.text("access.unknown"))
                                Text("\(localizedRole(member["role"])) · \(member["score"] ?? "0") · \(String((member["deviceId"] ?? "").prefix(12)))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if member["deviceId"] != access.deviceID,
                               access.role == .owner,
                               member["revoked"] != "true" {
                                Button(AppCopy.text("access.revoke"), role: .destructive) {
                                    do { try bridge.revokeWorkspaceDevice(member["deviceId"] ?? "") }
                                    catch { self.error = error.localizedDescription }
                                }
                            }
                        }
                    }
                }
            }

            Section(AppCopy.text("access.inviteDevice")) {
                TextField(AppCopy.text("access.displayName"), text: $inviteName)
                TextField(AppCopy.text("access.newDevicePublicKey"), text: $invitePublicKey)
                    .font(.caption.monospaced())
                Picker(AppCopy.text("access.role"), selection: $inviteRole) {
                    ForEach(MemoryRole.allCases, id: \.self) { role in Text(role.title).tag(role) }
                }
                Stepper(AppCopy.format("access.scoreValue", inviteScore), value: $inviteScore, in: 0...100)
                Button(AppCopy.text("access.createInvitation")) {
                    do {
                        inviteToken = try bridge.createWorkspaceInvite(
                            displayName: inviteName,
                            role: inviteRole,
                            score: inviteScore,
                            publicKey: invitePublicKey
                        )
                        error = ""
                    } catch let caught { error = caught.localizedDescription }
                }
                .disabled(access.role != .owner || inviteName.isEmpty || invitePublicKey.isEmpty)
                if !inviteToken.isEmpty {
                    Text(inviteToken)
                        .font(.caption2.monospaced())
                        .textSelection(.enabled)
                }
            }

            Section(AppCopy.text("access.acceptInvitation")) {
                TextField(AppCopy.text("access.signedInvitation"), text: $acceptedToken, axis: .vertical)
                Button(AppCopy.text("access.accept")) {
                    do {
                        try bridge.acceptWorkspaceInvite(acceptedToken)
                        acceptedToken = ""
                        error = ""
                    } catch let caught { error = caught.localizedDescription }
                }
                .disabled(acceptedToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            Section(AppCopy.text("access.pendingDecisions")) {
                if bridge.pendingWorkspaceDecisions.isEmpty {
                    Text(AppCopy.text("access.noPendingDecisions")).foregroundStyle(.secondary)
                } else {
                    ForEach(bridge.pendingWorkspaceDecisions.indices, id: \.self) { index in
                        let proposal = bridge.pendingWorkspaceDecisions[index]
                        let eventID = proposal["eventId"] as? String ?? ""
                        let payload = proposal["payload"] as? [String: Any]
                        VStack(alignment: .leading, spacing: 6) {
                            Text(payload?["summary"] as? String ?? eventID)
                            HStack {
                                Button(AppCopy.text("access.accept")) {
                                    do { try bridge.resolveWorkspaceDecision(eventID, accept: true) }
                                    catch { self.error = error.localizedDescription }
                                }
                                Button(AppCopy.text("access.reject"), role: .destructive) {
                                    do { try bridge.resolveWorkspaceDecision(eventID, accept: false) }
                                    catch { self.error = error.localizedDescription }
                                }
                            }
                            .disabled(bridge.workspaceAccess.role?.rank ?? 0 < MemoryRole.approver.rank)
                        }
                    }
                }
            }

            if !error.isEmpty {
                Text(error).foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .padding()
        .navigationTitle(AppCopy.text("settings.tab.access"))
    }

    private func localizedRole(_ rawValue: String?) -> String {
        guard let rawValue, let role = MemoryRole(rawValue: rawValue) else {
            return rawValue ?? AppCopy.text("access.unknown")
        }
        return role.title
    }
}

struct PluginSettingsView: View {
    @ObservedObject var model: AppModel
    @State private var showMarketplace = false
    @State private var visionError: String?
    @State private var visionBusy = false
    @State private var pluginError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(AppCopy.text("settings.pluginsTitle")).font(.title2.weight(.semibold))
                Spacer()
                Button(AppCopy.text("settings.installFromFile")) { installFromFile() }
                Button(AppCopy.text("settings.marketplace")) { showMarketplace = true }
                Button(AppCopy.text("settings.revealFolder")) {
                    NSWorkspace.shared.activateFileViewerSelecting([model.paths.plugins])
                }
                Button(AppCopy.text("settings.reload")) { model.remount() }
            }
            .padding()
            .sheet(isPresented: $showMarketplace) {
                MarketplaceView(model: model)
            }
            Text(AppCopy.text("settings.pluginsHint"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
            if let pluginError {
                Text(pluginError).font(.caption).foregroundStyle(.red).padding(.horizontal)
            }
            visionSection
                .padding(.horizontal)
                .padding(.top, 8)
            List(model.catalog.entries, id: \.id) { entry in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.manifest.name).font(.headline)
                            Text(entry.manifest.id)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle(AppCopy.text("settings.enabled"), isOn: Binding(
                            get: { entry.enabled },
                            set: { value in
                                model.catalog.setEnabled(entry.manifest.id, value)
                                model.remount()
                            }
                        ))
                        .labelsHidden()
                        .disabled(entry.broken != nil)
                    }
                    HStack(spacing: 8) {
                        TagBadge(entry.kind.rawValue)
                        TagBadge(entry.manifest.plane.rawValue)
                        TagBadge(entry.trust.rawValue)
                        Text("v\(entry.manifest.version) · ABI \(entry.manifest.abi)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let description = Optional(entry.manifest.description), !description.isEmpty {
                        Text(description).font(.caption)
                    }
                    if let broken = entry.broken {
                        Text(broken).font(.caption).foregroundStyle(.red)
                    }
                    if entry.kind != .builtin && entry.trust != .system {
                        Picker(AppCopy.text("settings.trust"), selection: Binding(
                            get: { entry.trust },
                            set: { value in
                                model.catalog.setTrust(entry.manifest.id, value)
                                model.remount()
                            }
                        )) {
                            Text(AppCopy.text("settings.untrusted")).tag(PluginTrust.untrusted)
                            Text(AppCopy.text("settings.trusted")).tag(PluginTrust.trusted)
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 240)
                    }
                    if entry.kind != .builtin {
                        HStack(spacing: 8) {
                            Button(AppCopy.text("settings.exportPlugin")) { exportPlugin(entry.manifest.id) }
                            Button(AppCopy.text("common.remove"), role: .destructive) {
                                pluginError = nil
                                do { try model.removePlugin(id: entry.manifest.id) }
                                catch { pluginError = error.localizedDescription }
                            }
                        }
                        .font(.caption)
                    }
                    SlotStack(slot: WellKnownSlot.pluginsDetail, registry: model.host.slots)
                }
                .padding(.vertical, 6)
            }
            if !model.host.issues.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(AppCopy.text("settings.lastMountFailed")).font(.headline)
                    ForEach(model.host.issues) { issue in
                        Text("\(issue.rowId): \(issue.message)").font(.caption).foregroundStyle(.red)
                    }
                }
                .padding()
            }
        }
    }

    private func installFromFile() {
        pluginError = nil
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "dotsplugin") ?? .data]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try model.installPluginFile(url) }
        catch { pluginError = error.localizedDescription }
    }

    private func exportPlugin(_ id: String) {
        pluginError = nil
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "dotsplugin") ?? .data]
        panel.nameFieldStringValue = "\(id).dotsplugin"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try model.exportPlugin(id: id, to: url) }
        catch { pluginError = error.localizedDescription }
    }

    private var visionSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Vision fallback", systemImage: "eye")
                        .font(.headline)
                    Spacer()
                    if model.visionPluginInstalled {
                        Toggle(AppCopy.text("settings.enabled"), isOn: Binding(
                            get: { model.visionPluginEnabled },
                            set: { model.setVisionPluginEnabled($0) }
                        ))
                        .labelsHidden()
                    }
                }
                Text(visionStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if model.visionState == .downloading || model.visionState == .preparing {
                    ProgressView(value: model.visionModelProgress)
                        .progressViewStyle(.linear)
                }
                if model.visionPluginInstalled {
                    HStack(spacing: 8) {
                        if model.visionPluginEnabled && model.visionState != .ready {
                            Button(AppCopy.text("vision.prepareModel")) {
                                run { try await model.prepareVision() }
                            }
                            .disabled(visionBusy)
                        }
                        if model.visionState != .unavailable && model.visionState != .modelMissing {
                            Button(AppCopy.text("vision.deleteModel"), role: .destructive) {
                                do { try model.deleteVisionModel() }
                                catch { visionError = error.localizedDescription }
                            }
                            .disabled(visionBusy)
                        }
                        Button(AppCopy.text("vision.removePlugin"), role: .destructive) {
                            do { try model.removeVisionPlugin() }
                            catch { visionError = error.localizedDescription }
                        }
                        .disabled(visionBusy)
                    }
                } else {
                    Button(AppCopy.text("vision.installPlugin")) {
                        run { try await model.installVisionPlugin() }
                    }
                    .disabled(visionBusy)
                }
                if let visionError {
                    Text(visionError).font(.caption).foregroundStyle(.red)
                }
            }
            .padding(4)
        }
    }

    private var visionStatus: String {
        if !model.visionPluginInstalled { return AppCopy.text("vision.notInstalled") }
        if !model.visionPluginEnabled { return AppCopy.text("vision.disabled") }
        switch model.visionState {
        case .modelMissing:
            return "\(AppCopy.text("vision.modelMissing")) · \(ByteCountFormatter.string(fromByteCount: model.visionModelBytes, countStyle: .file))"
        case .downloading:
            return "\(AppCopy.text("vision.downloading")) (\(Int(model.visionModelProgress * 100))%)"
        case .preparing:
            return "\(AppCopy.text("vision.preparing")) (\(Int(model.visionModelProgress * 100))%)"
        case .ready: return AppCopy.format("vision.ready", ByteCountFormatter.string(fromByteCount: model.visionModelBytes, countStyle: .file))
        case .failed: return AppCopy.text("vision.failed")
        case .unavailable: return AppCopy.text("vision.unavailable")
        }
    }

    private func run(_ operation: @escaping () async throws -> Void) {
        visionError = nil
        visionBusy = true
        Task { @MainActor in
            defer { visionBusy = false }
            do { try await operation() }
            catch { visionError = error.localizedDescription }
        }
    }

}

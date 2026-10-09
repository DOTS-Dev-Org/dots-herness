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
    @AppStorage(AgentContextCompactionPolicy.triggerPercentKey) private var compactPercent = 90
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
        case general, modelContext, access, memory, archive, providers, custom, local, share, mobile, skills, plugins, mcp, prompt, legal
        var id: String { rawValue }
        var title: String {
            rawValue == "modelContext" ? AppCopy.text("usage.context.window")
                : rawValue == "archive"
                ? AppCopy.text("sidebar.archived")
                : rawValue == "skills" ? AppCopy.text("settings.tab.skills")
                : rawValue == "mcp" ? "MCP servers"
                : rawValue == "legal" ? AppCopy.text("legal.title")
                : rawValue == "mobile" ? "Mobile control" : AppCopy.text("settings.tab.\(rawValue)")
        }
    }

    private var visibleTabs: [Tab] {
        Array(Tab.allCases)
    }

    private var effectiveCompactionTokens: Int {
        let policy = model.router.usageMode == .economy
            ? AgentContextCompactionPolicy.economy
            : AgentContextCompactionPolicy.current()
        guard !model.router.isAutoSelected else {
            return policy.maxTokens ?? AgentContextCompactionPolicy.codingReplayTokenLimit
        }
        return policy.triggerTokens(window: model.router.contextWindow(for: model.router.selectedModelID))
    }

    private var compactionThresholdIsAutoCeiling: Bool {
        model.router.isAutoSelected
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
                case .modelContext: ModelContextSettingsView(router: model.router)
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
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(AppCopy.text("settings.compactTrigger"))
                        Spacer()
                        if model.router.usageMode == .economy {
                            Text("90%")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        } else {
                            Button {
                                compactPercent = max(0, compactPercent - 1)
                            } label: {
                                Image(systemName: "minus")
                            }
                            .buttonStyle(.bordered)
                            .accessibilityLabel(AppCopy.language == .tr ? "Azalt" : "Decrease")
                            TextField("", value: $compactPercent, format: .number)
                                .frame(width: 54)
                                .multilineTextAlignment(.trailing)
                                .monospacedDigit()
                                .textFieldStyle(.roundedBorder)
                                .accessibilityLabel(AppCopy.text("settings.compactTrigger"))
                            Text("%")
                            Button {
                                compactPercent = min(100, compactPercent + 1)
                            } label: {
                                Image(systemName: "plus")
                            }
                            .buttonStyle(.bordered)
                            .accessibilityLabel(AppCopy.language == .tr ? "Artır" : "Increase")
                        }
                    }
                    .onChange(of: compactPercent) { _, value in
                        compactPercent = min(100, max(0, value))
                    }
                    if model.router.usageMode == .economy {
                        Text(AppCopy.language == .tr
                             ? "Ekonomi politikasında eşik sabit olarak %90'dır."
                             : "Economy policy uses a fixed 90% threshold.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(AppCopy.text("settings.compactTrigger.hint"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text((compactionThresholdIsAutoCeiling ? "≤ " : "") + AppCopy.format(
                        "conversation.tokensCount",
                        effectiveCompactionTokens.formatted(.number.locale(AppCopy.locale))
                    ))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
            }
            Section(AppCopy.language == .tr ? "Proje keşfi" : "Project exploration") {
                Toggle(AppCopy.language == .tr ? "Alt ajanları kullan" : "Use subagents", isOn: Binding(
                    get: { model.router.subagentsEnabled },
                    set: { model.setSubagentsEnabled($0) }
                ))
                Text(AppCopy.language == .tr
                     ? "Açıkken ajan, zor ve uzun görevlerde çok dosyalı aramaları ve birbirinden bağımsız düzenleme parçalarını paralel alt ajanlara devreder; ana konuşmaya yalnızca özet girer. Düzenleyen her alt ajan yalnızca kendisine atanan dosyalara yazabilir, atamalar çakışamaz. Basit görevlerde çağırmaz. Her alt ajan ayrı model çağrısıdır; maliyeti düşürmek için kapatın. Seçim yapılmadıysa Ekonomi modunda kapalıdır."
                     : "When on, the agent hands searches that sweep many files, and independent parts of a large change, to parallel subagents on hard or long tasks; only their summary enters the main conversation. An editing subagent can write only the files assigned to it, and assignments cannot overlap. Simple tasks never call one. Each subagent is a separate model run; turn this off to lower cost. Until you choose, it is off in Economy mode.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker(AppCopy.language == .tr ? "Keşif modeli" : "Exploration model", selection: Binding(
                    get: {
                        model.router.explorationModels.contains { $0.id == model.router.explorationModelID }
                            ? model.router.explorationModelID
                            : ""
                    },
                    set: { model.setExplorationModel($0) }
                )) {
                    Text(AppCopy.language == .tr ? "Otomatik (en düşük maliyetli)" : "Automatic (lowest cost)").tag("")
                    ForEach(model.router.explorationModels) { candidate in
                        Text(candidate.displayName ?? candidate.id).tag(candidate.id)
                    }
                }
                .disabled(!model.router.subagentsEnabled)
                Text(AppCopy.language == .tr
                     ? "Projeyi tarayan alt ajan bu modelle ve düşük efor ile çalışır. Otomatik seçim önce aboneliğinizdeki en hafif modeli, abonelik yoksa API anahtarınızdaki en hafif modeli kullanır."
                       + (model.router.explorationModel.map { " Şu an: \($0.displayName ?? $0.id)." } ?? "")
                     : "The subagent that sweeps the project runs on this model at low effort. Automatic uses the lightest model on your subscription, or the lightest one behind your API key when there is no subscription."
                       + (model.router.explorationModel.map { " Currently: \($0.displayName ?? $0.id)." } ?? ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section(AppCopy.language == .tr ? "Yanıt stili" : "Response style") {
                Picker(AppCopy.language == .tr ? "Varsayılan yanıt stili" : "Default response style", selection: Binding(
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
                Text(AppCopy.language == .tr
                     ? "Bu ayar promptu değiştirmez. Kısa/ultra tercihi best-effort'tur; kesin token, tamamlanma veya maliyet garantisi vermez."
                     : "This setting does not rewrite the prompt. Concise/Ultra are best-effort preferences; they do not guarantee a token count, completion, or lower cost.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Preferred Browser & Engine") {
                Picker("Engine", selection: Binding(
                    get: { model.browserBackend?.rawValue ?? BrowserBackend.unknown.rawValue },
                    set: { rawValue in
                        model.setBrowserBackend(
                            rawValue == BrowserBackend.unknown.rawValue ? nil : BrowserBackend(rawValue: rawValue)
                        )
                    }
                )) {
                    Text("In-App Native Live Browser (Apple WebKit)").tag(BrowserBackend.native.rawValue)
                    Text("Automatic (ask when unclear)").tag(BrowserBackend.unknown.rawValue)
                    Text("Managed isolated browser (Chrome)").tag(BrowserBackend.managed.rawValue)
                    Text("Existing Chrome profile (Extension)").tag(BrowserBackend.`extension`.rawValue)
                }
                Text("In-App Native Browser runs Apple WebKit in the Right Dock with zero extra resource overhead (0 MB download). Managed isolated browser uses external Chrome via CDP.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Computer Use") {
                Toggle("Enable Computer Use", isOn: Binding(
                    get: { model.isComputerUseEnabled },
                    set: { model.setComputerUseEnabled($0) }
                ))
                Text(AppCopy.language == .tr
                     ? "Ajan açık uygulamaları görebilir, ekran görüntülerini inceleyebilir, fare ve klavyeyle işlem yapıp sonucu kontrol edebilir. Tam erişimde otomatik çalışır; diğer erişim modlarında onay ister. macOS Ekran Kaydı ve Erişilebilirlik izinleri gerekir."
                     : "The agent can inspect running apps, view screenshots, use the mouse and keyboard, and verify the result. Full access runs automatically; other access modes ask for approval. macOS Screen Recording and Accessibility permissions are required.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if model.isComputerUseEnabled {
                    let perms = ComputerUseService.permissions()
                    LabeledContent("Screen Recording") {
                        HStack(spacing: 8) {
                            Text(perms.screenRecording ? "Granted" : "Permission Required")
                                .foregroundStyle(perms.screenRecording ? .green : .orange)
                            if !perms.screenRecording {
                                Button("Request Permission") {
                                    ComputerUseService.requestScreenRecordingPermission()
                                    ComputerUseService.openSystemSettings(privacyPane: "screen")
                                }
                            }
                        }
                    }
                    LabeledContent("Accessibility") {
                        HStack(spacing: 8) {
                            Text(perms.accessibility ? "Granted" : "Permission Required")
                                .foregroundStyle(perms.accessibility ? .green : .orange)
                            if !perms.accessibility {
                                Button("Request Permission") {
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
            SettingsUpdateSection(checker: model.updateChecker)
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
        ScrollView {
            Text(model.effectiveSystemPrompt().isEmpty ? AppCopy.text("settings.promptEmpty") : model.effectiveSystemPrompt())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle(AppCopy.text("settings.promptTitle"))
    }
}

private struct SettingsUpdateSection: View {
    @ObservedObject var checker: UpdateChecker

    var body: some View {
        Section(AppCopy.language == .tr ? "Sürüm ve Güncellemeler" : "Version & Updates") {
            LabeledContent(AppCopy.language == .tr ? "Mevcut Sürüm" : "Current Version") {
                Text("v\(checker.currentVersion) (\(checker.currentBuild))")
                    .font(.subheadline.monospaced())
                    .foregroundStyle(.secondary)
            }

            switch checker.state {
            case .checking:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(AppCopy.language == .tr ? "Güncellemeler denetleniyor..." : "Checking for updates...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .updateAvailable(let info), .mandatoryUpdate(let info):
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.down.circle.fill")
                            .foregroundStyle(info.mandatory ? .red : .accentColor)
                        Text(AppCopy.language == .tr ? "Yeni bir sürüm mevcut: v\(info.latestVersion)" : "New version available: v\(info.latestVersion)")
                            .font(.subheadline.bold())
                        if info.mandatory {
                            Text(AppCopy.language == .tr ? "Zorunlu" : "Required")
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
                        Button(AppCopy.language == .tr ? "Güncellemeyi İndir" : "Download Update") {
                            checker.openDownloadPage()
                        }
                        .buttonStyle(.borderedProminent)

                        Button(AppCopy.language == .tr ? "Yeniden Denetle" : "Check Again") {
                            Task { await checker.checkForUpdates(manual: true) }
                        }
                    }
                }
            case .upToDate:
                HStack {
                    Label(AppCopy.language == .tr ? "Uygulama güncel." : "Application is up to date.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                    Spacer()
                    Button(AppCopy.language == .tr ? "Güncellemeleri Denetle" : "Check for Updates") {
                        Task { await checker.checkForUpdates(manual: true) }
                    }
                }
            case .failed(let error):
                HStack {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                    Spacer()
                    Button(AppCopy.language == .tr ? "Tekrar Dene" : "Retry") {
                        Task { await checker.checkForUpdates(manual: true) }
                    }
                }
            case .idle:
                HStack {
                    Text(AppCopy.language == .tr ? "En son sürüm bilgisi kontrol edilebilir." : "Check for the latest available release.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(AppCopy.language == .tr ? "Güncellemeleri Denetle" : "Check for Updates") {
                        Task { await checker.checkForUpdates(manual: true) }
                    }
                }
            }
        }
    }
}

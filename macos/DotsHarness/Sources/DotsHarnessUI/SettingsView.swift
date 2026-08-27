// Copyright (c) 2026 DOTS
// Native settings and plugin management surfaces.

import AppKit
import SwiftUI
import HarnessPluginKit
import DotsHarnessCore
import PluginRuntime

public struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var tab: Tab = .general

    public init(model: AppModel) {
        self.model = model
    }

    enum Tab: String, CaseIterable, Identifiable {
        case general, access, pet, providers, custom, local, share, plugins, prompt
        var id: String { rawValue }
        var title: String {
            return AppCopy.text("settings.tab.\(rawValue)")
        }
    }

    public var body: some View {
        NavigationSplitView {
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
            case .access: WorkspaceAccessView(bridge: model.bridge)
            case .pet: PetSettingsView(model: model)
            case .providers: RouterProvidersView(router: model.router)
            case .custom: CustomAPIView(router: model.router, local: model.local)
            case .share: RouterShareView(router: model.router)
            case .local: LocalModelsView(local: model.local)
            case .plugins: PluginSettingsView(model: model)
            case .prompt: prompt
            }
        }
        .frame(minWidth: 820, minHeight: 560)
    }

    private var general: some View {
        Form {
            Section(AppCopy.text("settings.workspace")) {
                LabeledContent(AppCopy.text("settings.folder")) {
                    Text(model.workspacePath.isEmpty ? AppCopy.text("settings.notSelected") : model.workspacePath)
                        .textSelection(.enabled)
                        .lineLimit(1)
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
                        ForEach(model.router.models) { item in
                            Text(item.id).tag(item.id)
                        }
                    }
                }
                LabeledContent(AppCopy.text("settings.status")) {
                    Text(model.statusLine)
                        .foregroundStyle(.secondary)
                }
                LabeledContent(AppCopy.text("settings.endpoint")) {
                    Text("Native provider routing")
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
            Section(AppCopy.text("settings.storage")) {
                LabeledContent(AppCopy.text("settings.supportFolder")) {
                    Text(model.paths.root.path).textSelection(.enabled)
                }
                LabeledContent(AppCopy.text("settings.sessions")) {
                    Text(model.paths.root.appendingPathComponent("sessions.json").path)
                        .textSelection(.enabled)
                        .font(.caption.monospaced())
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
    }

    private var prompt: some View {
        ScrollView {
            Text(model.assembledSystemPrompt().isEmpty ? AppCopy.text("settings.promptEmpty") : model.assembledSystemPrompt())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle(AppCopy.text("settings.promptTitle"))
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(AppCopy.text("settings.pluginsTitle")).font(.title2.weight(.semibold))
                Spacer()
                Button(AppCopy.text("settings.revealFolder")) {
                    NSWorkspace.shared.activateFileViewerSelecting([model.paths.plugins])
                }
                Button(AppCopy.text("settings.reload")) { model.remount() }
            }
            .padding()
            Text(AppCopy.text("settings.pluginsHint"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
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
                        badge(entry.kind.rawValue)
                        badge(entry.manifest.plane.rawValue)
                        badge(entry.trust.rawValue)
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
                    if entry.kind == .dylib && entry.trust != .system {
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

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.primary.opacity(0.08), in: Capsule())
    }
}

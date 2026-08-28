// Copyright (c) 2026 DOTS
// ChatGPT-inspired native composer and command palettes.

import AppKit
import SwiftUI
import UniformTypeIdentifiers
import DotsHarnessCore
import HarnessPluginKit

struct ChatComposer: View {
    @ObservedObject var model: AppModel
    @ObservedObject var bridge: AgentBridge
    @StateObject private var voiceInput: PetVoiceInput

    @State private var showAttachmentMenu = false
    @State private var showPermissionMenu = false
    @State private var showModelMenu = false
    @State private var showProjectMenu = false
    @State private var showWorkLocationMenu = false
    @State private var showBranchMenu = false
    @State private var workLocation: WorkLocation = .local
    @State private var gitSnapshot = GitSnapshot.empty
    @State private var gitError: String?
    @State private var responseSpeed = AppCopy.text("modelPicker.standard")
    @State private var highlightedSlashCommandID: String?
    @State private var isDropTargeted = false
    @FocusState private var composerFocused: Bool

    /// Derived from the router so the label can never drift from what is sent.
    private var reasoningEffort: String {
        model.router.isAutoSelected
            ? AppCopy.text("modelPicker.auto")
            : ModelPickerPopover.effortLabel(model.router.selectedEffort)
    }

    init(model: AppModel, bridge: AgentBridge) {
        self.model = model
        self.bridge = bridge
        self._voiceInput = StateObject(
            wrappedValue: PetVoiceInput(model: model) { text in
                let separator = model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : "\n"
                model.draft += separator + text
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            if slashMenuIsVisible {
                SlashCommandPalette(
                    settings: slashSettings,
                    media: slashMedia,
                    skills: slashSkills,
                    highlightedID: $highlightedSlashCommandID,
                    onSelect: selectSlashCommand
                )
                .padding(.horizontal, 18)
                .padding(.bottom, 8)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            SlotStack(slot: WellKnownSlot.composerAccessory, registry: model.host.slots)

            if model.showsVoiceIntro {
                voiceIntroBanner
                    .padding(.horizontal, 18)
                    .padding(.bottom, 8)
            }

            if model.showsFullAccessWarning {
                fullAccessWarning
                    .padding(.horizontal, 18)
                    .padding(.bottom, 8)
            }

            if let approval = bridge.pendingApproval {
                approvalBanner(approval)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 8)
            }

            composerContext

            VStack(spacing: 0) {
                if model.isEditingMessage {
                    editingBanner
                }
                if let historyError = model.historyError {
                    Text(historyError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 15)
                        .padding(.top, 8)
                }
                if !model.draftAttachments.isEmpty {
                    draftAttachments
                }
                growingEditor
                composerControls
            }
            .background(composerSurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 14)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .animation(.easeOut(duration: 0.16), value: slashMenuIsVisible)
        .onChange(of: slashMenuIsVisible) { _, isVisible in
            highlightedSlashCommandID = isVisible ? visibleSlashCommands.first?.id : nil
        }
        .onAppear(perform: refreshGit)
        .onChange(of: model.workspacePath) { _, _ in refreshGit() }
        .onChange(of: showBranchMenu) { _, isPresented in
            if isPresented { refreshGit() }
        }
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isDropTargeted, perform: handleDrop)
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [8, 5]))
                    .padding(.horizontal, 18)
                    .padding(.bottom, 14)
                    .overlay {
                        Text(AppCopy.text("conversation.dropFiles"))
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(.regularMaterial, in: Capsule())
                            .allowsHitTesting(false)
                    }
                    .allowsHitTesting(false)
            }
        }
    }

    private var composerSurface: Color {
        Color.primary.opacity(0.075)
    }

    private var composerContext: some View {
        HStack(spacing: 7) {
            Button {
                showProjectMenu.toggle()
            } label: {
                contextPill(
                    icon: model.workspacePath.isEmpty ? "folder.badge.plus" : "folder",
                    title: projectName
                )
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showProjectMenu, arrowEdge: .bottom) {
                ProjectPickerPopover(
                    workspacePath: model.workspacePath,
                    onChoose: {
                        showProjectMenu = false
                        model.chooseWorkspace()
                    },
                    onClear: {
                        showProjectMenu = false
                        model.setWorkspace("")
                    }
                )
            }
            .help(AppCopy.text("composer.projectPickerHelp"))

            Button {
                showWorkLocationMenu.toggle()
            } label: {
                contextPill(icon: workLocation.icon, title: workLocation.title)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showWorkLocationMenu, arrowEdge: .bottom) {
                WorkLocationPopover(selection: workLocation) { location in
                    workLocation = location
                    showWorkLocationMenu = false
                }
            }
            .help(AppCopy.text("workLocation.help"))

            if gitSnapshot.isRepository {
                Button {
                    showBranchMenu.toggle()
                } label: {
                    contextPill(icon: "arrow.triangle.branch", title: gitBranchName)
                }
                .buttonStyle(.plain)
                .disabled(bridge.isBusy)
                .popover(isPresented: $showBranchMenu, arrowEdge: .bottom) {
                    GitBranchPopover(
                        snapshot: gitSnapshot,
                        error: gitError,
                        onSelect: selectBranch,
                        onCreate: createBranch
                    )
                }
                .help(AppCopy.text("git.branchHelp"))
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 7)
    }

    private func contextPill(icon: String, title: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
            Text(title)
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .foregroundStyle(.primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.08), in: Capsule())
    }

    private var growingEditor: some View {
        ZStack(alignment: .topLeading) {
            PromptTextEditor(
                text: $model.draft,
                isEnabled: !bridge.historyMutationBusy,
                onSubmit: { mode in
                    guard !bridge.historyMutationBusy,
                          model.canSend || model.isEditingMessage else { return }
                    model.send(mode: mode)
                },
                onAcceptSlashCommand: acceptSlashCommand,
                onMoveSlashCommand: moveSlashCommand
            )
                .frame(height: editorHeight)
                .padding(.horizontal, 9)
                .padding(.top, 5)
                .focused($composerFocused)

            if model.draft.isEmpty {
                Text(AppCopy.text("composer.placeholder"))
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 15)
                    .padding(.top, 13)
                    .allowsHitTesting(false)
            }
        }
    }

    private var draftAttachments: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(model.draftAttachments) { attachment in
                    ZStack(alignment: .topTrailing) {
                        if attachment.kind == .image, let image = NSImage(contentsOf: attachment.url) {
                            Image(nsImage: image)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 64, height: 64)
                                .clipped()
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        } else {
                            VStack(spacing: 4) {
                                Image(systemName: attachmentIcon(attachment))
                                    .font(.title3)
                                Text(attachment.name)
                                    .font(.caption2)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.center)
                            }
                                .frame(width: 64, height: 64)
                                .foregroundStyle(.secondary)
                        }

                        Button {
                            model.removeDraftAttachment(attachment)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 14))
                                .foregroundStyle(.white, .black.opacity(0.65))
                        }
                        .buttonStyle(.plain)
                        .padding(3)
                    }
                }
            }
            .padding(.horizontal, 15)
            .padding(.top, 10)
        }
        .frame(height: 82)
    }

    private var editingBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "pencil")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.accentColor)
            Text(AppCopy.text("conversation.editingMessage"))
                .font(.caption.weight(.medium))
            Spacer(minLength: 0)
            Button(AppCopy.text("conversation.cancelEdit")) {
                model.cancelEditing()
            }
            .buttonStyle(.plain)
            .font(.caption.weight(.medium))
            .disabled(bridge.historyMutationBusy)
            .help(AppCopy.text("conversation.cancelEdit"))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 15)
        .padding(.top, 10)
    }

    private var fullAccessWarning: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "exclamationmark.shield")
                .font(.system(size: 22, weight: .medium))
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 4) {
                Text(AppCopy.text("permission.fullWarningTitle"))
                    .font(.headline)
                Text(AppCopy.text("permission.fullWarningBody"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(AppCopy.text("permission.fullWarningLearnMore"))
                    .font(.callout)
                    .underline()
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            Button(AppCopy.text("permission.fullWarningDismiss")) {
                model.dismissFullAccessWarning()
            }
            .font(.callout.weight(.medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.primary.opacity(0.16), in: Capsule())
            .buttonStyle(.plain)

            Button {
                model.dismissFullAccessWarning()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help(AppCopy.text("permission.fullWarningDismiss"))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .background(Color.primary.opacity(0.075), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
    }

    private var voiceIntroBanner: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(.blue)
                .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 4) {
                Text(AppCopy.text("voice.intro.title"))
                    .font(.headline)
                Text(AppCopy.text("voice.intro.body"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            Button(AppCopy.text("voice.intro.start")) {
                model.dismissVoiceIntro()
                voiceInput.startListening()
            }
            .font(.callout.weight(.medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.primary.opacity(0.16), in: Capsule())
            .buttonStyle(.plain)

            Button {
                model.dismissVoiceIntro()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help(AppCopy.text("voice.intro.dismiss"))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(Color.primary.opacity(0.075), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
    }

    private func approvalBanner(_ approval: PendingApproval) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "hand.raised")
                .font(.system(size: 20, weight: .medium))
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(AppCopy.format("permission.approvalTitle", approval.toolName))
                    .font(.headline)
                Text(approval.reason)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 12)

            Button(AppCopy.text("permission.reject")) {
                bridge.answerApproval("rejected")
            }
            .buttonStyle(.plain)

            Button(AppCopy.text("permission.allowOnce")) {
                bridge.answerApproval("allowed-once")
            }
            .font(.callout.weight(.medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.primary.opacity(0.16), in: Capsule())
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(Color.primary.opacity(0.075), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
    }

    private func attachmentIcon(_ attachment: ChatAttachment) -> String {
        switch attachment.kind {
        case .image: return "photo"
        case .audio: return "waveform"
        case .video: return "video"
        case .file: return "doc"
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                guard let data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                Task { @MainActor in
                    model.addDraftAttachments([url])
                }
            }
        }
        return !providers.isEmpty
    }

    private var composerControls: some View {
        HStack(spacing: 9) {
            Button {
                showAttachmentMenu.toggle()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 17, weight: .regular))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .popover(isPresented: $showAttachmentMenu, arrowEdge: .bottom) {
                AttachmentMenu(
                    onChooseFiles: chooseFiles,
                    onChooseWorkspace: model.chooseWorkspace,
                    onOpenSkills: openSkillsFromAttachmentMenu,
                    onSetGoal: {
                        showAttachmentMenu = false
                        promptForGoal()
                    },
                    onTogglePlan: {
                        showAttachmentMenu = false
                        model.togglePlanMode()
                    }
                )
            }
            .help(AppCopy.text("composer.add"))

            Button {
                showPermissionMenu.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: model.permissionMode == .full ? "shield.fill" : "shield")
                        .font(.caption.weight(.semibold))
                    Text(model.permissionMode.title)
                        .font(.callout.weight(.medium))
                }
                .foregroundStyle(model.permissionMode == .full ? Color.orange : .secondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(
                    (model.permissionMode == .full ? Color.orange : Color.primary).opacity(0.12),
                    in: Capsule()
                )
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showPermissionMenu, arrowEdge: .top) {
                PermissionMenu(selection: Binding(
                    get: { model.permissionMode },
                    set: { value in
                        model.setPermissionMode(value)
                        showPermissionMenu = false
                    }
                ))
            }

            Divider()
                .frame(height: 20)
                .opacity(0.35)

            Button {
                model.togglePlanMode()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "lightbulb")
                        .font(.caption.weight(.semibold))
                    Text(AppCopy.text("plan.title"))
                        .font(.callout.weight(.medium))
                }
                .foregroundStyle(model.isPlanMode ? Color.orange : .secondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(
                    (model.isPlanMode ? Color.orange : Color.primary).opacity(0.12),
                    in: Capsule()
                )
            }
            .buttonStyle(.plain)
            .help(AppCopy.text("plan.toggleHelp"))
            .accessibilityLabel(AppCopy.text("plan.toggleHelp"))
            .accessibilityValue(AppCopy.text(model.isPlanMode ? "plan.on" : "plan.off"))
            .accessibilityAddTraits(model.isPlanMode ? [.isSelected] : [])

            Spacer(minLength: 0)

            Button {
                showModelMenu.toggle()
            } label: {
                HStack(spacing: 4) {
                    Text(modelName)
                        .lineLimit(1)
                    Text(reasoningEffort)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
                .frame(maxWidth: 250)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showModelMenu, arrowEdge: .bottom) {
                ModelPickerPopover(
                    model: model,
                    responseSpeed: $responseSpeed
                )
            }

            Button {
                voiceInput.toggle()
            } label: {
                Image(systemName: voiceInput.state.icon)
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 25, height: 28)
            }
            .buttonStyle(.plain)
            .foregroundStyle(model.isVoiceReady ? voiceInput.state.tint : .secondary)
            .opacity(model.isVoiceModelDownloading ? 0.55 : (model.isVoiceReady ? 1 : 0.7))
            .disabled(voiceInput.state == .transcribing || voiceInput.state == .sending || model.isVoiceModelDownloading)
            .help(voiceInput.isListening ? AppCopy.text("composer.stopListening") : model.voiceInputHelp)

            if bridge.isBusy {
                Button {
                    model.stop()
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 30, height: 30)
                        .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                        .background(Color.primary, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(AppCopy.text("common.stop"))
                .help(AppCopy.text("common.stop"))
            } else if bridge.canContinue {
                Button {
                    if canSubmit { model.send(mode: .queue) } else { model.continueCurrentRun() }
                } label: {
                    Image(systemName: "play.fill")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 30, height: 30)
                        .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                        .background(Color.primary, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(AppCopy.text("agent.continue"))
                .help(AppCopy.text("agent.continue"))
                .disabled(!model.canSend)
                .opacity(model.canSend ? 1 : 0.7)
            } else {
                Button {
                    model.send(mode: .queue)
                } label: {
                    Image(systemName: sendIcon)
                        .font(.system(size: 14, weight: .bold))
                        .frame(width: 30, height: 30)
                        .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                        .background(Color.primary, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(!canSubmit)
                .opacity(canSubmit ? 1 : 0.7)
                .help(AppCopy.text("composer.keyboardHelp"))
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
        .padding(.top, 6)
    }

    private var workspaceName: String {
        URL(fileURLWithPath: model.workspacePath).lastPathComponent
    }

    private var projectName: String {
        model.workspacePath.isEmpty
            ? AppCopy.text("composer.chooseProject")
            : workspaceName
    }

    private var gitBranchName: String {
        gitSnapshot.currentBranch ?? AppCopy.text("git.detached")
    }

    private var modelName: String {
        // Under Auto the concrete model changes per message, so show what routing
        // last chose rather than a stale pin.
        if model.router.isAutoSelected {
            let picked = model.router.lastAutoDecision?.model
            return picked.map { "\(AppCopy.text("modelPicker.auto")) · \($0)" } ?? AppCopy.text("modelPicker.auto")
        }
        if let connection = bridge.connection, !connection.model.isEmpty {
            return connection.model
        }
        if !model.selectedModelID.isEmpty {
            return model.selectedModelID
        }
        return AppCopy.text("composer.selectModel")
    }

    private var draftLineCount: Int {
        max(1, model.draft.components(separatedBy: .newlines).count)
    }

    private var draftNeedsScroll: Bool {
        draftLineCount > 10
    }

    private var editorHeight: CGFloat {
        let visibleLines = min(max(draftLineCount, 1), 10)
        return min(238, max(44, CGFloat(visibleLines) * 22 + 18))
    }

    private var canSubmit: Bool {
        let hasDraft = !model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.draftAttachments.isEmpty
        return hasDraft && !bridge.historyMutationBusy && (model.canSend || model.isEditingMessage)
    }

    private var sendIcon: String {
        return model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "waveform" : "arrow.up"
    }

    private var slashMenuIsVisible: Bool {
        slashToken != nil
    }

    private var visibleSlashCommands: [SlashCommand] {
        slashSettings + slashMedia + slashSkills
    }

    private var slashToken: String? {
        let lastLine = model.draft.components(separatedBy: .newlines).last ?? ""
        guard let token = lastLine.split(whereSeparator: { $0 == " " || $0 == "\t" }).last,
              token.first == "/" else {
            return nil
        }
        return String(token)
    }

    private var slashQuery: String {
        guard let slashToken else { return "" }
        return String(slashToken.dropFirst())
    }

    private var slashSettings: [SlashCommand] {
        filterCommands([
            SlashCommand(id: "reasoning", title: AppCopy.text("slash.reasoning"), detail: reasoningEffort, icon: "brain.head.profile", kind: .setting),
            SlashCommand(id: "project", title: AppCopy.text("slash.project"), detail: AppCopy.text("slash.projectDetail"), icon: "folder", kind: .setting),
            SlashCommand(id: "status", title: AppCopy.text("slash.status"), detail: AppCopy.text("slash.statusDetail"), icon: "gauge", kind: .setting),
            SlashCommand(id: "feedback", title: AppCopy.text("slash.feedback"), detail: AppCopy.text("slash.feedbackDetail"), icon: "bubble.left.and.exclamationmark.bubble.right", kind: .setting),
            SlashCommand(id: "goal", title: AppCopy.text("slash.goal"), detail: AppCopy.text("slash.goalDetail"), icon: "scope", kind: .setting),
            SlashCommand(id: "loop", title: AppCopy.text("slash.loop"), detail: AppCopy.text("slash.loopDetail"), icon: "repeat", kind: .setting),
            SlashCommand(id: "speed", title: AppCopy.text("slash.speed"), detail: AppCopy.text("slash.speedDetail"), icon: "bolt", kind: .setting),
            SlashCommand(id: "billing", title: AppCopy.text("slash.billing"), detail: AppCopy.text("slash.billingDetail"), icon: "chart.bar", kind: .setting),
            SlashCommand(id: "mcp", title: AppCopy.text("slash.mcp"), detail: AppCopy.text("slash.mcpDetail"), icon: "point.3.connected.trianglepath.dotted", kind: .setting),
            SlashCommand(id: "model", title: AppCopy.text("slash.model"), detail: modelName, icon: "cube", kind: .setting),
            SlashCommand(
                id: "plan",
                title: AppCopy.text("slash.plan"),
                detail: model.isPlanMode ? AppCopy.text("plan.turnOffDetail") : AppCopy.text("slash.planDetail"),
                icon: "lightbulb",
                kind: .setting
            ),
            SlashCommand(id: "mascot", title: AppCopy.text("slash.mascot"), detail: AppCopy.text("slash.mascotDetail"), icon: "smiley", kind: .setting),
        ])
    }

    private var slashSkills: [SlashCommand] {
        let installed = model.catalog.entries
            .filter { $0.enabled && $0.broken == nil }
            .map {
                SlashCommand(
                    id: "skill-\($0.manifest.id)",
                    title: $0.manifest.name,
                    detail: $0.manifest.description.isEmpty ? AppCopy.text("composer.installedSkill") : $0.manifest.description,
                    icon: "cube.transparent",
                    kind: .skill
                )
            }

        let fallback = [
            SlashCommand(id: "skill-documents", title: "Documents", detail: AppCopy.text("skill.documentsDetail"), icon: "doc.text", kind: .skill),
            SlashCommand(id: "skill-pdf", title: "PDF", detail: AppCopy.text("skill.pdfDetail"), icon: "doc.richtext", kind: .skill),
            SlashCommand(id: "skill-spreadsheets", title: "Spreadsheets", detail: AppCopy.text("skill.spreadsheetsDetail"), icon: "tablecells", kind: .skill),
            SlashCommand(id: "skill-browser", title: "Browser", detail: AppCopy.text("skill.browserDetail"), icon: "globe", kind: .skill),
            SlashCommand(id: "skill-imagegen", title: "Image Gen", detail: AppCopy.text("skill.imageGenDetail"), icon: "photo", kind: .skill),
        ]

        var seen = Set<String>()
        return filterCommands((installed + fallback).filter { seen.insert($0.title.lowercased()).inserted })
    }

    private var slashMedia: [SlashCommand] {
        var commands = [
            SlashCommand(
                id: "imagegen",
                title: AppCopy.text("slash.imagegen"),
                detail: AppCopy.text("slash.imagegenDetail"),
                icon: "photo",
                kind: .media,
                command: "imagegen"
            ),
            SlashCommand(
                id: "videogen",
                title: AppCopy.text("slash.videogen"),
                detail: AppCopy.text("slash.videogenDetail"),
                icon: "video",
                kind: .media,
                command: "videogen"
            ),
            SlashCommand(
                id: "audiogen",
                title: AppCopy.text("slash.audiogen"),
                detail: AppCopy.text("slash.audiogenDetail"),
                icon: "waveform",
                kind: .media,
                command: "audiogen"
            ),
        ]
        if !model.router.imageGenerationCommandVisible {
            commands.removeAll { $0.id == "imagegen" }
        }
        return filterCommands(commands)
    }

    private func filterCommands(_ commands: [SlashCommand]) -> [SlashCommand] {
        guard !slashQuery.isEmpty else { return commands }
        return commands.filter {
            $0.title.localizedCaseInsensitiveContains(slashQuery)
                || $0.detail.localizedCaseInsensitiveContains(slashQuery)
                || ($0.command?.localizedCaseInsensitiveContains(slashQuery) == true)
        }
    }

    private func selectSlashCommand(_ command: SlashCommand) {
        let replacement: String
        switch command.kind {
        case .setting: replacement = ""
        case .skill: replacement = "/\(command.title) "
        case .media: replacement = "/\(command.command ?? command.id) "
        }
        replaceSlashToken(with: replacement)
        composerFocused = true

        switch command.id {
        case "model":
            showModelMenu = true
        case "goal":
            promptForGoal()
        case "loop":
            promptForLoop()
        case "project":
            showProjectMenu = true
        case "reasoning":
            showModelMenu = true
        case "speed":
            responseSpeed = responseSpeed == AppCopy.text("modelPicker.standard")
                ? AppCopy.text("modelPicker.fast")
                : AppCopy.text("modelPicker.standard")
        case "plan":
            model.togglePlanMode()
        default:
            if command.kind == .setting {
                model.presentSettings()
            }
        }
    }

    private func acceptSlashCommand() -> Bool {
        guard slashMenuIsVisible,
              let command = visibleSlashCommands.first(where: { $0.id == highlightedSlashCommandID })
                ?? visibleSlashCommands.first else { return false }
        selectSlashCommand(command)
        return true
    }

    private func moveSlashCommand(_ offset: Int) -> Bool {
        guard slashMenuIsVisible else { return false }
        let commands = visibleSlashCommands
        guard !commands.isEmpty else { return false }

        let currentIndex = commands.firstIndex(where: { $0.id == highlightedSlashCommandID })
            ?? (offset > 0 ? -1 : 0)
        highlightedSlashCommandID = commands[(currentIndex + offset + commands.count) % commands.count].id
        return true
    }

    private func replaceSlashToken(with replacement: String) {
        guard let slashToken,
              let range = model.draft.range(of: slashToken, options: .backwards) else { return }
        model.draft.replaceSubrange(range, with: replacement)
    }

    private func promptForGoal() {
        let alert = NSAlert()
        alert.messageText = AppCopy.text("goal.dialogTitle")
        alert.informativeText = AppCopy.text("goal.dialogBody")
        alert.addButton(withTitle: AppCopy.text("common.save"))
        alert.addButton(withTitle: AppCopy.text("common.cancel"))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.stringValue = model.sessionGoal
        field.placeholderString = AppCopy.text("slash.goalDetail")
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn {
            model.setSessionGoal(field.stringValue)
        }
    }

    private func promptForLoop() {
        let alert = NSAlert()
        alert.messageText = AppCopy.text("loop.dialogTitle")
        alert.informativeText = AppCopy.text("loop.dialogBody")
        alert.addButton(withTitle: AppCopy.text("common.save"))
        alert.addButton(withTitle: AppCopy.text("common.cancel"))

        let minutes = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        minutes.stringValue = "30"
        let instruction = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        instruction.stringValue = model.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        instruction.placeholderString = AppCopy.text("loop.instructionLabel")

        let stack = NSStackView(views: [
            labeledField(AppCopy.text("loop.minutesLabel"), minutes),
            labeledField(AppCopy.text("loop.instructionLabel"), instruction),
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 320, height: 96)
        alert.accessoryView = stack
        alert.window.initialFirstResponder = instruction.stringValue.isEmpty ? instruction : minutes

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let mins = max(1, Int(minutes.stringValue.trimmingCharacters(in: .whitespaces)) ?? 30)
        let text = instruction.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        model.createLoopTask(everyMinutes: mins, instruction: text)
        model.draft = ""
        model.presentTasks()
    }

    private func labeledField(_ title: String, _ field: NSView) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .preferredFont(forTextStyle: .caption1)
        label.textColor = .secondaryLabelColor
        let row = NSStackView(views: [label, field])
        row.orientation = .vertical
        row.alignment = .leading
        row.spacing = 2
        return row
    }

    private func openSkillsFromAttachmentMenu() {
        showAttachmentMenu = false
        model.draft = "/"
        composerFocused = true
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.item]
        panel.prompt = AppCopy.text("composer.add")
        panel.begin { response in
            guard response == .OK else { return }
            Task { @MainActor in
                model.addDraftAttachments(panel.urls)
            }
        }
        showAttachmentMenu = false
    }

    private func refreshGit() {
        gitSnapshot = GitRepository.snapshot(at: model.workspacePath)
        gitError = nil
    }

    private func selectBranch(_ branch: String) {
        guard branch != gitSnapshot.currentBranch else {
            showBranchMenu = false
            return
        }
        guard let error = GitRepository.checkout(branch, at: model.workspacePath) else {
            showBranchMenu = false
            refreshGit()
            return
        }
        gitError = error
    }

    private func createBranch() {
        let alert = NSAlert()
        alert.messageText = AppCopy.text("git.createBranchTitle")
        alert.informativeText = AppCopy.text("git.createBranchMessage")
        alert.addButton(withTitle: AppCopy.text("common.save"))
        alert.addButton(withTitle: AppCopy.text("common.cancel"))

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = AppCopy.text("git.branchName")
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let error = GitRepository.createBranch(
            field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            at: model.workspacePath
        ) else {
            showBranchMenu = false
            refreshGit()
            return
        }
        gitError = error
    }
}

private enum WorkLocation: String, CaseIterable, Identifiable {
    case local
    case localWorktree
    case codexWeb
    case cloud

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .local: return "laptopcomputer"
        case .localWorktree: return "arrow.up.right.square"
        case .codexWeb: return "globe"
        case .cloud: return "cloud"
        }
    }

    var title: String { AppCopy.text("workLocation.\(rawValue)") }
    var detail: String { AppCopy.text("workLocation.\(rawValue)Detail") }
    var isEnabled: Bool { self != .cloud }
}

private struct ProjectPickerPopover: View {
    let workspacePath: String
    let onChoose: () -> Void
    let onClear: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(AppCopy.text("composer.projectPickerTitle"))
                .font(.headline)
                .padding(.horizontal, 9)
                .padding(.top, 7)
                .padding(.bottom, 5)

            if workspacePath.isEmpty {
                Text(AppCopy.text("composer.noProject"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 7)
            } else {
                Button {} label: {
                    HStack(spacing: 10) {
                        Image(systemName: "folder")
                            .font(.system(size: 14, weight: .medium))
                            .frame(width: 17)
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(URL(fileURLWithPath: workspacePath).lastPathComponent)
                                .font(.callout.weight(.medium))
                                .lineLimit(1)
                            Text(workspacePath)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "checkmark")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 7)
                    .background(Color.primary.opacity(0.11), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Divider().padding(.vertical, 5)

            projectAction(icon: "plus", title: AppCopy.text("composer.chooseProject"), action: onChoose)
            projectAction(icon: "xmark", title: AppCopy.text("composer.dontWorkInProject"), action: onClear)
                .disabled(workspacePath.isEmpty)
                .opacity(workspacePath.isEmpty ? 0.45 : 1)
        }
        .padding(8)
        .frame(width: 360)
    }

    private func projectAction(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 17)
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.callout)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9)
            .frame(height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct WorkLocationPopover: View {
    let selection: WorkLocation
    let onSelect: (WorkLocation) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(AppCopy.text("workLocation.title"))
                .font(.headline)
                .padding(.horizontal, 9)
                .padding(.top, 7)
                .padding(.bottom, 5)

            ForEach(WorkLocation.allCases) { location in
                Button {
                    onSelect(location)
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: location.icon)
                            .font(.system(size: 14, weight: .medium))
                            .frame(width: 17)
                            .padding(.top, 2)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(location.title)
                                .font(.callout.weight(location == selection ? .medium : .regular))
                            Text(location.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                        if location == selection {
                            Image(systemName: "checkmark")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 7)
                    .background(
                        location == selection ? Color.primary.opacity(0.10) : .clear,
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!location.isEnabled)
                .opacity(location.isEnabled ? 1 : 0.45)
            }
        }
        .padding(8)
        .frame(width: 350)
    }
}

private struct GitSnapshot {
    var isRepository: Bool
    var currentBranch: String?
    var branches: [String]
    var uncommittedCount: Int

    static let empty = GitSnapshot(isRepository: false, currentBranch: nil, branches: [], uncommittedCount: 0)
}

private struct GitCommandResult {
    let status: Int32
    let output: String
}

private enum GitRepository {
    static func snapshot(at path: String) -> GitSnapshot {
        guard !path.isEmpty,
              let marker = run(["rev-parse", "--is-inside-work-tree"], at: path),
              marker.trimmingCharacters(in: .whitespacesAndNewlines) == "true" else {
            return .empty
        }

        let branch = run(["branch", "--show-current"], at: path)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let branches = (run(["for-each-ref", "--format=%(refname:short)", "refs/heads"], at: path) ?? "")
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        let uncommittedCount = (run(["status", "--porcelain", "--untracked-files=all"], at: path) ?? "")
            .split(whereSeparator: \.isNewline)
            .count

        return GitSnapshot(
            isRepository: true,
            currentBranch: branch?.isEmpty == true ? nil : branch,
            branches: branches,
            uncommittedCount: uncommittedCount
        )
    }

    static func checkout(_ branch: String, at path: String) -> String? {
        guard !branch.isEmpty, !branch.contains(where: { $0 == "\n" || $0 == "\r" }) else {
            return AppCopy.text("git.checkoutFailed")
        }
        let result = runResult(["switch", branch], at: path)
        guard result.status == 0 else {
            let detail = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty ? AppCopy.text("git.checkoutFailed") : detail
        }
        return nil
    }

    static func createBranch(_ branch: String, at path: String) -> String? {
        guard !branch.isEmpty, !branch.contains(where: { $0 == "\n" || $0 == "\r" }) else {
            return AppCopy.text("git.createBranchFailed")
        }
        let result = runResult(["switch", "-c", branch], at: path)
        guard result.status == 0 else {
            let detail = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty ? AppCopy.text("git.createBranchFailed") : detail
        }
        return nil
    }

    private static func run(_ arguments: [String], at path: String) -> String? {
        let result = runResult(arguments, at: path)
        return result.status == 0 ? result.output : nil
    }

    private static func runResult(_ arguments: [String], at path: String) -> GitCommandResult {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: path, isDirectory: true)
        process.standardOutput = output
        process.standardError = output
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return GitCommandResult(status: 1, output: error.localizedDescription)
        }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return GitCommandResult(
            status: process.terminationStatus,
            output: String(data: data, encoding: .utf8) ?? ""
        )
    }
}

private struct GitBranchPopover: View {
    let snapshot: GitSnapshot
    let error: String?
    let onSelect: (String) -> Void
    let onCreate: () -> Void

    @State private var searchText = ""

    private var filteredBranches: [String] {
        guard !searchText.isEmpty else { return snapshot.branches }
        return snapshot.branches.filter { $0.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(AppCopy.text("git.search"), text: $searchText)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 9)
            .frame(height: 30)
            .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            Text(AppCopy.text("git.branches"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 9)
                .padding(.top, 5)

            if filteredBranches.isEmpty {
                Text(AppCopy.text("git.noBranches"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(12)
            } else {
                ForEach(filteredBranches, id: \.self) { branch in
                    Button {
                        onSelect(branch)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 10) {
                                Image(systemName: "arrow.triangle.branch")
                                    .font(.system(size: 13, weight: .medium))
                                    .frame(width: 17)
                                    .foregroundStyle(.secondary)
                                Text(branch)
                                    .font(.callout)
                                    .lineLimit(1)
                                Spacer(minLength: 8)
                                if branch == snapshot.currentBranch {
                                    Image(systemName: "checkmark")
                                        .font(.caption.weight(.bold))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            if branch == snapshot.currentBranch, snapshot.uncommittedCount > 0 {
                                Text(AppCopy.format("git.uncommitted", snapshot.uncommittedCount))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .padding(.leading, 27)
                            }
                        }
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background(
                            branch == snapshot.currentBranch ? Color.primary.opacity(0.10) : .clear,
                            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
            }

            Divider().padding(.vertical, 5)
            Button(action: onCreate) {
                HStack(spacing: 10) {
                    Image(systemName: "plus")
                        .frame(width: 17)
                    Text(AppCopy.text("git.createBranch"))
                    Spacer(minLength: 0)
                }
                .font(.callout)
                .padding(.horizontal, 9)
                .frame(height: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(8)
        .frame(width: 360)
    }
}

private struct PromptTextEditor: NSViewRepresentable {
    @Binding var text: String
    let isEnabled: Bool
    let onSubmit: (PromptMode) -> Void
    let onAcceptSlashCommand: () -> Bool
    let onMoveSlashCommand: (Int) -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        let editor = PromptNSTextView()
        editor.delegate = context.coordinator
        editor.onSubmit = onSubmit
        editor.onAcceptSlashCommand = onAcceptSlashCommand
        editor.onMoveSlashCommand = onMoveSlashCommand
        editor.string = text
        editor.isEditable = isEnabled
        editor.isRichText = false
        editor.font = .systemFont(ofSize: 15)
        editor.textContainerInset = NSSize(width: 5, height: 5)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.drawsBackground = false

        scrollView.documentView = editor
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let editor = nsView.documentView as? PromptNSTextView else { return }
        if editor.string != text {
            editor.string = text
        }
        editor.isEditable = isEnabled
        editor.onSubmit = onSubmit
        editor.onAcceptSlashCommand = onAcceptSlashCommand
        editor.onMoveSlashCommand = onMoveSlashCommand
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        private var parent: PromptTextEditor

        init(_ parent: PromptTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            parent.text = editor.string
        }
    }
}

private final class PromptNSTextView: NSTextView {
    var onSubmit: ((PromptMode) -> Void)?
    var onAcceptSlashCommand: (() -> Bool)?
    var onMoveSlashCommand: ((Int) -> Bool)?

    override func keyDown(with event: NSEvent) {
        let keyModifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let hasTextModifiers = keyModifiers.contains(.command)
            || keyModifiers.contains(.control)
            || keyModifiers.contains(.option)
            || keyModifiers.contains(.shift)

        switch event.keyCode {
        case 48 where !hasTextModifiers:
            if onAcceptSlashCommand?() == true { return }
        case 126 where !hasTextModifiers:
            if onMoveSlashCommand?(-1) == true { return }
        case 125 where !hasTextModifiers:
            if onMoveSlashCommand?(1) == true { return }
        default:
            break
        }

        guard event.keyCode == 36 || event.keyCode == 76 else {
            super.keyDown(with: event)
            return
        }

        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers.contains(.command) || modifiers.contains(.control) {
            onSubmit?(.steer)
        } else if modifiers.contains(.shift) == false {
            onSubmit?(.queue)
        } else {
            super.keyDown(with: event)
        }
    }
}

private enum SlashCommandKind {
    case setting
    case media
    case skill
}

private struct SlashCommand: Identifiable {
    var id: String
    var title: String
    var detail: String
    var icon: String
    var kind: SlashCommandKind
    var command: String? = nil
}

private struct SlashCommandPalette: View {
    let settings: [SlashCommand]
    let media: [SlashCommand]
    let skills: [SlashCommand]
    @Binding var highlightedID: String?
    let onSelect: (SlashCommand) -> Void

    private var commands: [SlashCommand] {
        settings + media + skills
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                if !settings.isEmpty {
                    sectionTitle(AppCopy.text("composer.settings"))
                    ForEach(settings) { command in
                        commandRow(command)
                    }
                }

                if !media.isEmpty {
                    sectionTitle(AppCopy.text("composer.generate"))
                        .padding(.top, 7)
                    ForEach(media) { command in
                        commandRow(command)
                    }
                }

                if !skills.isEmpty {
                    sectionTitle(AppCopy.text("composer.skills"))
                        .padding(.top, 7)
                    ForEach(skills) { command in
                        commandRow(command)
                    }
                }
            }
            .padding(8)
        }
        .frame(maxWidth: .infinity)
        .frame(maxHeight: 360)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        }
        .onAppear {
            if !commands.contains(where: { $0.id == highlightedID }) {
                highlightedID = commands.first?.id
            }
        }
        .onChange(of: commands.map(\.id)) { _, ids in
            if !ids.contains(where: { $0 == highlightedID }) {
                highlightedID = ids.first
            }
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
    }

    private func commandRow(_ command: SlashCommand) -> some View {
        Button {
            onSelect(command)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: command.icon)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 17)
                    .foregroundStyle(.secondary)
                Text(command.title)
                    .lineLimit(1)
                Spacer(minLength: 10)
                Text(command.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if command.kind == .skill {
                    Text(AppCopy.text("composer.personal"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            .foregroundStyle(.primary)
            .padding(.horizontal, 8)
            .frame(minHeight: 29)
            .background(
                highlightedID == command.id ? Color.primary.opacity(0.12) : .clear,
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isInside in
            if isInside { highlightedID = command.id }
        }
    }
}

private struct AttachmentMenu: View {
    let onChooseFiles: () -> Void
    let onChooseWorkspace: () -> Void
    let onOpenSkills: () -> Void
    let onSetGoal: () -> Void
    let onTogglePlan: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(AppCopy.text("composer.add"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 9)
                .padding(.bottom, 4)
            attachmentRow(icon: "paperclip", title: AppCopy.text("attachment.files"), action: onChooseFiles)
            attachmentRow(icon: "rectangle.stack", title: AppCopy.text("attachment.addApp")) {}
            attachmentRow(icon: "folder", title: AppCopy.text("attachment.project"), detail: AppCopy.text("attachment.projectDetail"), action: onChooseWorkspace)
            attachmentRow(icon: "scope", title: AppCopy.text("attachment.goal"), detail: AppCopy.text("attachment.goalDetail"), action: onSetGoal)
            attachmentRow(icon: "lightbulb", title: AppCopy.text("attachment.plan"), detail: AppCopy.text("attachment.planDetail"), action: onTogglePlan)
            attachmentRow(icon: "target", title: AppCopy.text("attachment.saveSkill"), action: onOpenSkills)

            Divider().padding(.vertical, 5)
            Text(AppCopy.text("attachment.plugins"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 9)
            attachmentRow(icon: "doc.text", title: "Documents", detail: AppCopy.text("attachment.documentsDetail")) {}
            attachmentRow(icon: "doc.richtext", title: "PDF", detail: AppCopy.text("attachment.pdfDetail")) {}
            attachmentRow(icon: "tablecells", title: "Spreadsheets", detail: AppCopy.text("attachment.spreadsheetsDetail")) {}
        }
        .padding(8)
        .frame(width: 395)
    }

    private func attachmentRow(
        icon: String,
        title: String,
        detail: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 17)
                    .foregroundStyle(.secondary)
                Text(title)
                    .lineLimit(1)
                if let detail {
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .font(.callout)
            .padding(.horizontal, 9)
            .frame(minHeight: 29)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct PermissionMenu: View {
    @Binding var selection: AgentPermissionMode

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(AppCopy.text("permission.title"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(AppCopy.text("permission.moreInfo"))
                    .font(.caption)
                    .underline()
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 9)
            .padding(.bottom, 5)

            ForEach(AgentPermissionMode.allCases) { level in
                Button {
                    selection = level
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: level.icon)
                            .font(.system(size: 13, weight: .medium))
                            .frame(width: 17)
                            .padding(.top, 2)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(level.title)
                                .font(.callout.weight(level == selection ? .medium : .regular))
                            Text(level.detail)
                                .font(.caption)
                                .foregroundStyle(level == .full ? Color.orange : .secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                        if level == selection {
                            Image(systemName: "checkmark")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(level == .full ? Color.orange : .secondary)
                        }
                    }
                    .foregroundStyle(level == .full ? Color.orange : .primary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 7)
                    .background(
                        level == selection ? Color.primary.opacity(0.10) : .clear,
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(8)
        .frame(width: 515)
    }
}

private struct ModelPickerPopover: View {
    @ObservedObject var model: AppModel
    @Binding var responseSpeed: String
    private enum Panel { case models, efforts }
    @State private var panel: Panel?

    private var modelIDs: [String] {
        model.router.models.map(\.id).filter { !$0.isEmpty }
    }

    /// Levels the selected model actually accepts. Empty means the provider
    /// rejects the effort parameter for it, so the row is disabled.
    private var effortLevels: [String] {
        // Auto owns the effort decision, so the manual control stands down.
        model.router.isAutoSelected ? [] : model.router.efforts(for: model.selectedModelID)
    }

    var body: some View {
        HStack(spacing: 0) {
            if let panel {
                switch panel {
                case .models: modelList
                case .efforts: effortList
                }
                Divider()
            }

            VStack(alignment: .leading, spacing: 2) {
                optionRow(title: AppCopy.text("modelPicker.model"), value: selectedModelName, icon: "chevron.right") {
                    panel = panel == .models ? nil : .models
                }
                optionRow(
                    title: AppCopy.text("modelPicker.effort"),
                    value: model.router.isAutoSelected
                        ? AppCopy.text("modelPicker.auto")
                        : (effortLevels.isEmpty ? AppCopy.text("modelPicker.effortUnsupported") : Self.effortLabel(model.router.selectedEffort)),
                    icon: "chevron.right"
                ) {
                    guard !effortLevels.isEmpty else { return }
                    panel = panel == .efforts ? nil : .efforts
                }
                .disabled(effortLevels.isEmpty)
                .opacity(effortLevels.isEmpty ? 0.5 : 1)
                optionRow(title: AppCopy.text("modelPicker.speed"), value: responseSpeed, icon: "chevron.right") {
                    responseSpeed = responseSpeed == AppCopy.text("modelPicker.standard")
                        ? AppCopy.text("modelPicker.fast")
                        : AppCopy.text("modelPicker.standard")
                }
                Divider().padding(.vertical, 7)
                Button {
                    model.setEffort("")
                    responseSpeed = AppCopy.text("modelPicker.standard")
                    panel = nil
                } label: {
                    HStack {
                        Text(AppCopy.text("modelPicker.reset"))
                        Spacer()
                        Image(systemName: "arrow.counterclockwise")
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                }
                .buttonStyle(.plain)
            }
            .padding(8)
            .frame(width: panel == nil ? 270 : 220)
        }
        .padding(0)
        .frame(width: panel == nil ? 286 : 505)
    }

    private var selectedModelName: String {
        if model.router.isAutoSelected { return AppCopy.text("modelPicker.auto") }
        return model.selectedModelID.isEmpty ? AppCopy.text("modelPicker.selectModel") : model.selectedModelID
    }

    static func effortLabel(_ level: String) -> String {
        level.isEmpty ? AppCopy.text("modelPicker.effort.default") : AppCopy.text("modelPicker.effort.\(level)")
    }

    private var effortList: some View {
        VStack(alignment: .leading, spacing: 2) {
            // "" is the provider default — always offered alongside the model's levels.
            ForEach([""] + effortLevels, id: \.self) { level in
                Button {
                    model.setEffort(level)
                    panel = nil
                } label: {
                    HStack {
                        Text(Self.effortLabel(level))
                            .lineLimit(1)
                        Spacer()
                        if level == model.router.selectedEffort {
                            Image(systemName: "checkmark")
                                .font(.caption.weight(.bold))
                        }
                    }
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(8)
        .frame(width: 275)
    }

    private var modelList: some View {
        VStack(alignment: .leading, spacing: 2) {
            if modelIDs.isEmpty {
                Text(AppCopy.text("modelPicker.noModel"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(12)
            } else {
                Button {
                    model.setModel(ModelRouter.autoModelID)
                    panel = nil
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(AppCopy.text("modelPicker.auto"))
                            Text(AppCopy.text("modelPicker.autoHint"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .lineLimit(1)
                        Spacer()
                        if model.router.isAutoSelected {
                            Image(systemName: "checkmark").font(.caption.weight(.bold))
                        }
                    }
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
                Divider().padding(.vertical, 4)
                ForEach(modelIDs, id: \.self) { id in
                    Button {
                        model.setModel(id)
                        panel = nil
                    } label: {
                        HStack {
                            Text(id)
                                .lineLimit(1)
                            Spacer()
                            if id == model.selectedModelID {
                                Image(systemName: "checkmark")
                                    .font(.caption.weight(.bold))
                            }
                        }
                        .font(.callout)
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(8)
        .frame(width: 275)
    }

    private func optionRow(
        title: String,
        value: String,
        icon: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer(minLength: 16)
                Text(value)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Image(systemName: icon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

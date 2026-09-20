// Copyright (c) 2026 DOTS
// ChatGPT-inspired native composer and command palettes.

import AppKit
import SwiftUI
import UniformTypeIdentifiers
import DotsHarnessCore
import HarnessPluginKit

struct ChatComposer: View {
    @ObservedObject var model: AppModel
    @ObservedObject var skillSuggestions: SkillSuggestionMonitor
    @StateObject private var voiceInput: LiveVoiceInput

    @State private var showAttachmentMenu = false
    @State private var showPermissionMenu = false
    @State private var showModelMenu = false
    @State private var showProjectMenu = false
    @State private var showWorkLocationMenu = false
    @State private var showRemoteFolderPicker = false
    @State private var showBranchMenu = false
    @State private var gitSnapshot = GitSnapshot.empty
    @State private var gitRefreshToken = 0
    @State private var gitError: String?
    @State private var gitBusy = false
    @State private var highlightedSlashCommandID: String?
    @State private var isDropTargeted = false
    @State private var ghostVisible = false
    @State private var planPillHovered = false
    @FocusState private var composerFocused: Bool

    private var bridge: AgentBridge { model.bridge }

    private static let compactComposerWidth: CGFloat = 360

    private var workLocationIcon: String {
        switch model.workLocation {
        case .local: return "laptopcomputer"
        case .localWorktree: return "arrow.up.right.square"
        case .remote: return "network"
        }
    }

    private var workLocationTitle: String {
        switch model.workLocation {
        case .local: return AppCopy.text("workLocation.local")
        case .localWorktree: return AppCopy.text("workLocation.localWorktree")
        case .remote(let alias): return alias
        }
    }

    /// Derived from the router so the label can never drift from what is sent.
    private var reasoningEffort: String {
        model.router.isAutoSelected
            ? AppCopy.text("modelPicker.auto")
            : model.router.effectiveEffort(for: model.selectedModelID).isEmpty
                ? "" : ModelPickerPopover.effortLabel(model.router.effectiveEffort(for: model.selectedModelID))
    }

    private var visibleFollowUpSuggestion: String? {
        guard bridge.followUpConversationID == model.selectedConversationID else { return nil }
        return bridge.followUpSuggestion
    }

    init(model: AppModel, bridge: AgentBridge) {
        self.model = model
        self.skillSuggestions = model.activeSkillSuggestions
        self._voiceInput = StateObject(
            wrappedValue: LiveVoiceInput(model: model) { text in
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

            if let suggestion = skillSuggestions.pending {
                skillSuggestionBanner(suggestion)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 8)
            }

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

            if let question = bridge.pendingQuestion,
               question.conversationID == model.selectedConversationID {
                QuestionCard(
                    pending: question,
                    onSubmit: { bridge.answerQuestions($0) },
                    onSkip: { bridge.cancelQuestions() }
                )
                .id(question.id)
                .padding(.horizontal, 18)
                .padding(.bottom, 8)
            }

            if let vision = bridge.pendingVisionInstall {
                visionInstallBanner(vision)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 8)
            }

            if model.activeArea != .chat { composerContext }

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
        .onAppear { refreshGit() }
        .onChange(of: model.workspacePath) { _, _ in refreshGit() }
        .onChange(of: model.composerFocusRequestID) { _, _ in composerFocused = true }
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
                contextPill(icon: workLocationIcon, title: workLocationTitle)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showWorkLocationMenu, arrowEdge: .bottom) {
                WorkLocationPopover(
                    selection: model.workLocation,
                    hosts: model.sshHosts,
                    sshAvailable: SSHRunner.isAvailable,
                    remotePath: model.remoteWorkspace?.remotePath
                ) { setting in
                    model.setWorkLocation(setting)
                    showWorkLocationMenu = false
                } onManageHosts: {
                    showWorkLocationMenu = false
                    model.presentSettings(tab: "general")
                } onChooseFolder: {
                    showWorkLocationMenu = false
                    showRemoteFolderPicker = true
                }
            }
            .help(AppCopy.text("workLocation.help"))
            .sheet(isPresented: $showRemoteFolderPicker) {
                RemoteFolderPickerView(model: model)
            }

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
                        busy: gitBusy,
                        onSelect: selectBranch,
                        onSelectRemote: selectRemoteBranch,
                        onCreate: createBranch,
                        onFetch: fetchFromRemote,
                        onPush: pushCurrentBranch
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
        VStack(alignment: .leading, spacing: 0) {
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
                    onMoveSlashCommand: moveSlashCommand,
                    followUpSuggestion: visibleFollowUpSuggestion,
                    onGhostVisibilityChange: { ghostVisible = $0 }
                )
                    .frame(height: editorHeight)
                    .padding(.horizontal, 9)
                    .padding(.top, 5)
                    .focused($composerFocused)

                if model.draft.isEmpty && !ghostVisible {
                    Text(AppCopy.text("composer.placeholder"))
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 14)
                        .padding(.top, 13)
                        .allowsHitTesting(false)
                }
            }

            if !voiceInput.transcript.isEmpty {
                Text(voiceInput.transcript)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 15)
                    .padding(.bottom, 7)
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
                                Image(systemName: attachment.kind.systemImageName)
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

    private func skillSuggestionBanner(_ suggestion: SkillSuggestion) -> some View {
        ComposerBanner {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "sparkles")
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(.blue)
                .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 4) {
                Text("Suggested skill: \(suggestion.draftName)")
                    .font(.headline)
                Text(suggestion.draftDescription)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            Button("Not now") {
                model.dismissSkillSuggestion()
            }
            .font(.callout.weight(.medium))
            .foregroundStyle(.secondary)
            .buttonStyle(.plain)

            Button("Create Skill") {
                _ = try? model.acceptSkillSuggestion(name: suggestion.draftName, description: suggestion.draftDescription)
            }
            .font(.callout.weight(.medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.primary.opacity(0.16), in: Capsule())
            .buttonStyle(.plain)
        }
        }
    }

    private var voiceIntroBanner: some View {
        ComposerBanner {
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
        }
    }

    private func approvalBanner(_ approval: PendingApproval) -> some View {
        ComposerBanner {
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
        }
    }

    private func visionInstallBanner(_ pending: PendingVisionInstall) -> some View {
        ComposerBanner {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "eye")
                .font(.system(size: 20, weight: .medium))
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(AppCopy.text("vision.installTitle"))
                    .font(.headline)
                Text(AppCopy.format(
                    "vision.installReason",
                    pending.provider,
                    ByteCountFormatter.string(fromByteCount: pending.modelBytes, countStyle: .file)
                ))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }

            Spacer(minLength: 12)

            Button(AppCopy.text("vision.notNow")) {
                bridge.answerVisionInstall(false)
            }
            .buttonStyle(.plain)

            Button(AppCopy.text("vision.downloadAndContinue")) {
                bridge.answerVisionInstall(true)
            }
            .font(.callout.weight(.medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.primary.opacity(0.16), in: Capsule())
            .buttonStyle(.plain)
        }
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
        GeometryReader { proxy in
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
                    showsWorkspace: model.activeArea == .coding,
                    onOpenSkills: openSkillsFromAttachmentMenu,
                    onSetGoal: {
                        showAttachmentMenu = false
                        promptForGoal()
                    }
                )
            }
            .help(AppCopy.text("composer.add"))

                Button {
                    showPermissionMenu.toggle()
                } label: {
                    Group {
                        if proxy.size.width < Self.compactComposerWidth {
                            Image(systemName: model.permissionMode == .full ? "shield.fill" : "shield")
                                .font(.caption.weight(.semibold))
                                .frame(width: 28, height: 28)
                        } else {
                            HStack(spacing: 6) {
                                Image(systemName: model.permissionMode == .full ? "shield.fill" : "shield")
                                    .font(.caption.weight(.semibold))
                                Text(model.permissionMode.title)
                                    .font(.callout.weight(.medium))
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                        }
                    }
                    .foregroundStyle(model.permissionMode == .full ? Color.orange : .secondary)
                    .background(
                        (model.permissionMode == .full ? Color.orange : Color.primary).opacity(0.12),
                        in: Capsule()
                    )
                }
            .buttonStyle(.plain)
            .accessibilityLabel(model.permissionMode.title)
            .popover(isPresented: $showPermissionMenu, arrowEdge: .top) {
                PermissionMenu(selection: Binding(
                    get: { model.permissionMode },
                    set: { value in
                        model.setPermissionMode(value)
                        showPermissionMenu = false
                    }
                ))
            }

            // ponytail: plan pill only exists while plan mode is active (entered via /plan).
            // Not a persistent toggle button; clicking it (or its hover ✕) exits plan mode.
            if model.isPlanMode {
                Divider()
                    .frame(height: 20)
                    .opacity(0.35)

                Button {
                    model.togglePlanMode()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: planPillHovered ? "xmark" : "lightbulb")
                            .font(.caption.weight(.semibold))
                        Text(AppCopy.text("plan.title"))
                            .font(.callout.weight(.medium))
                    }
                    .foregroundStyle(Color.orange)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Color.orange.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)
                .onHover { planPillHovered = $0 }
                .help(AppCopy.text("plan.turnOffDetail"))
                .accessibilityLabel(AppCopy.text("plan.turnOffDetail"))
                .accessibilityValue(AppCopy.text("plan.on"))
                .accessibilityAddTraits(.isSelected)
            }

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
                // Keep the picker at its intrinsic width so the trailing controls
                // stay grouped on the right instead of reserving a wide empty frame.
                .fixedSize(horizontal: true, vertical: false)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showModelMenu, arrowEdge: .top) {
                ModelPickerPopover(model: model)
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
        .frame(height: 46)
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
        let base = gitSnapshot.currentBranch ?? AppCopy.text("git.detached")
        var suffix = ""
        if gitSnapshot.ahead > 0 { suffix += " ↑\(gitSnapshot.ahead)" }
        if gitSnapshot.behind > 0 { suffix += " ↓\(gitSnapshot.behind)" }
        return base + suffix
    }

    private var modelName: String {
        // Under Auto the concrete model changes per message, so show what routing
        // last chose rather than a stale pin.
        if model.router.isAutoSelected {
            let picked = model.router.lastAutoDecision?.model
            let pickedName = picked.flatMap { id in
                model.router.models.first(where: { $0.id == id }).map { RouterCatalog.modelDisplayName(for: $0) }
            } ?? picked
            return pickedName.map { "\(AppCopy.text("modelPicker.auto")) · \($0)" } ?? AppCopy.text("modelPicker.auto")
        }
        if let connection = bridge.connection, !connection.model.isEmpty {
            let item = model.router.models.first(where: { $0.id == connection.model })
                ?? RouterModel(id: connection.model, provider: connection.provider)
            return RouterCatalog.modelDisplayName(for: item)
        }
        if !model.selectedModelID.isEmpty {
            let item = model.router.models.first(where: { $0.id == model.selectedModelID })
                ?? RouterModel(id: model.selectedModelID)
            return RouterCatalog.modelDisplayName(for: item)
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
        var commands = [
            SlashCommand(id: "reasoning", title: AppCopy.text("slash.reasoning"), detail: reasoningEffort, icon: "brain.head.profile", kind: .setting),
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
            SlashCommand(id: "plugincreator", title: AppCopy.text("slash.pluginCreator"), detail: AppCopy.text("slash.pluginCreatorDetail"), icon: "puzzlepiece.extension", kind: .setting),
        ]
        if model.canCompactSelectedConversation {
            commands.append(SlashCommand(id: "compact", title: AppCopy.text("slash.compact"), detail: AppCopy.text("slash.compactDetail"), icon: "arrow.down.right.and.arrow.up.left", kind: .setting))
        }
        if model.activeArea == .coding {
            commands.insert(
                SlashCommand(id: "project", title: AppCopy.text("slash.project"), detail: AppCopy.text("slash.projectDetail"), icon: "folder", kind: .setting),
                at: 1
            )
        }
        return filterCommands(commands)
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
        case "feedback":
            model.requestFeedbackForLatestResponse()
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
            if model.router.supportsFast(model.selectedModelID) { model.setFast(!model.router.fastMode) }
        case "plan":
            model.togglePlanMode()
        case "compact":
            // Sent with the draft: it compacts first, then answers the rest.
            model.draft = "/compact " + model.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        case "plugincreator":
            let trimmed = model.draft.trimmingCharacters(in: .whitespacesAndNewlines)
            model.draft = trimmed.isEmpty
                ? AppCopy.text("pluginCreator.template")
                : AppCopy.format("pluginCreator.templateWith", trimmed)
            composerFocused = true
        case "mcp":
            model.presentSettings(tab: "mcp")
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

    /// Reads the repository off the main thread: it spawns several `git` processes, and
    /// this runs when the composer first appears. A newer refresh supersedes an older one.
    private func refreshGit(clearError: Bool = true) {
        let path = model.workspacePath
        gitRefreshToken &+= 1
        let token = gitRefreshToken
        if clearError { gitError = nil }
        Task {
            let snapshot = await Task.detached(priority: .utility) { GitRepository.snapshot(at: path) }.value
            guard token == gitRefreshToken else { return }
            gitSnapshot = snapshot
        }
    }

    private func selectBranch(_ branch: String) {
        guard !gitBusy else { return }
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

    /// Check out a remote-tracking ref (`origin/foo`). Git's DWIM creates the
    /// local `foo` with upstream set when it does not exist yet.
    private func selectRemoteBranch(_ remote: String) {
        guard !gitBusy else { return }
        let local = remote.split(separator: "/").dropFirst().joined(separator: "/")
        guard !local.isEmpty else { return }
        guard let error = GitRepository.checkout(local, at: model.workspacePath) else {
            showBranchMenu = false
            refreshGit()
            return
        }
        gitError = error
    }

    private func fetchFromRemote() {
        runGitNetwork(.fetch)
    }

    private func pushCurrentBranch() {
        guard let branch = gitSnapshot.currentBranch else {
            gitError = AppCopy.text("git.detached")
            return
        }
        runGitNetwork(.push(branch))
    }

    /// Run a blocking git network command off the main thread, then refresh.
    private func runGitNetwork(_ op: GitNetworkOp) {
        guard !gitBusy, !model.workspacePath.isEmpty else { return }
        gitBusy = true
        gitError = nil
        let path = model.workspacePath
        Task {
            let error = await Task.detached { () -> String? in
                switch op {
                case .fetch: return GitRepository.fetch(at: path)
                case .push(let branch): return GitRepository.push(branch, at: path)
                }
            }.value
            await MainActor.run {
                gitBusy = false
                refreshGit(clearError: false)
                gitError = error
            }
        }
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

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
    @StateObject private var voiceInput: PetVoiceInput

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

private enum GitNetworkOp: Sendable {
    case fetch
    case push(String)
}

private enum WorkLocationOption: String, Identifiable {
    case local
    case localWorktree

    static let localCases: [WorkLocationOption] = [.local, .localWorktree]

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .local: return "laptopcomputer"
        case .localWorktree: return "arrow.up.right.square"
        }
    }

    var setting: WorkLocationSetting {
        switch self {
        case .local: return .local
        case .localWorktree: return .localWorktree
        }
    }

    var title: String { AppCopy.text("workLocation.\(rawValue)") }
    var detail: String { AppCopy.text("workLocation.\(rawValue)Detail") }
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
    let selection: WorkLocationSetting
    let hosts: [SSHHost]
    let sshAvailable: Bool
    let remotePath: String?
    let onSelect: (WorkLocationSetting) -> Void
    let onManageHosts: () -> Void
    let onChooseFolder: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(AppCopy.text("workLocation.title"))
                .font(.headline)
                .padding(.horizontal, 9)
                .padding(.top, 7)
                .padding(.bottom, 5)

            ForEach(WorkLocationOption.localCases) { option in
                row(
                    icon: option.icon,
                    title: option.title,
                    detail: option.detail,
                    isSelected: selection == option.setting,
                    isEnabled: true
                ) { onSelect(option.setting) }
            }

            Divider().padding(.vertical, 5)

            Text(AppCopy.text("workLocation.remoteHosts"))
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 9)
                .padding(.bottom, 2)

            if !sshAvailable {
                Text(AppCopy.text("ssh.error.unavailable"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
            } else if hosts.isEmpty {
                Text(AppCopy.text("workLocation.noHosts"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
            } else {
                ForEach(hosts) { host in
                    row(
                        icon: "network",
                        title: host.alias,
                        detail: detail(for: host),
                        isSelected: selection.remoteAlias == host.alias,
                        isEnabled: true
                    ) { onSelect(.remote(alias: host.alias)) }
                }
            }

            if selection.isRemote {
                action(icon: "folder", title: AppCopy.text("workLocation.chooseRemoteFolder"), action: onChooseFolder)
            }
            action(icon: "plus", title: AppCopy.text("workLocation.addHost"), action: onManageHosts)
        }
        .padding(8)
        .frame(width: 350)
    }

    private func detail(for host: SSHHost) -> String {
        guard selection.remoteAlias == host.alias, let remotePath, !remotePath.isEmpty else {
            return host.displayDestination
        }
        return "\(host.displayDestination) · \(remotePath)"
    }

    private func row(
        icon: String,
        title: String,
        detail: String,
        isSelected: Bool,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 17)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.callout.weight(isSelected ? .medium : .regular))
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(
                isSelected ? Color.primary.opacity(0.10) : .clear,
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
    }

    private func action(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 17)
                    .foregroundStyle(.secondary)
                Text(title).font(.callout)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9)
            .frame(height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct GitSnapshot {
    var isRepository: Bool
    var currentBranch: String?
    var branches: [String]
    var remoteBranches: [String]
    var uncommittedCount: Int
    var hasRemote: Bool
    var ahead: Int
    var behind: Int

    static let empty = GitSnapshot(
        isRepository: false,
        currentBranch: nil,
        branches: [],
        remoteBranches: [],
        uncommittedCount: 0,
        hasRemote: false,
        ahead: 0,
        behind: 0
    )
}

private struct GitCommandResult {
    let status: Int32
    let output: String
}

/// Collects the outputs of git commands that ran side by side.
private final class GitOutputs: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int: String] = [:]

    func set(_ value: String?, at index: Int) {
        lock.lock()
        values[index] = value
        lock.unlock()
    }

    subscript(index: Int) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return values[index]
    }
}

private enum GitRepository {
    static func snapshot(at path: String) -> GitSnapshot {
        guard !path.isEmpty,
              let marker = run(["rev-parse", "--is-inside-work-tree"], at: path),
              marker.trimmingCharacters(in: .whitespacesAndNewlines) == "true" else {
            return .empty
        }

        // The remaining reads are independent, so they run together: the snapshot costs
        // the slowest command (`status`) instead of the sum of all seven processes.
        let commands: [[String]] = [
            ["branch", "--show-current"],
            ["for-each-ref", "--format=%(refname:short)", "refs/heads"],
            ["for-each-ref", "--format=%(refname:short)", "refs/remotes"],
            ["status", "--porcelain", "--untracked-files=all"],
            ["remote"],
            // Ahead/behind vs the current branch's upstream, if one is configured.
            ["rev-list", "--left-right", "--count", "@{upstream}...HEAD"],
        ]
        let outputs = GitOutputs()
        DispatchQueue.concurrentPerform(iterations: commands.count) { index in
            outputs.set(run(commands[index], at: path), at: index)
        }

        let branch = outputs[0]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let branches = (outputs[1] ?? "")
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        let remoteBranches = (outputs[2] ?? "")
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.hasSuffix("/HEAD") }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        let uncommittedCount = (outputs[3] ?? "")
            .split(whereSeparator: \.isNewline)
            .count
        let hasRemote = !(outputs[4] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        var ahead = 0
        var behind = 0
        if let counts = outputs[5] {
            let parts = counts.split(whereSeparator: { $0 == " " || $0 == "\t" || $0.isNewline })
            if parts.count == 2 {
                behind = Int(parts[0]) ?? 0
                ahead = Int(parts[1]) ?? 0
            }
        }

        return GitSnapshot(
            isRepository: true,
            currentBranch: branch?.isEmpty == true ? nil : branch,
            branches: branches,
            remoteBranches: remoteBranches,
            uncommittedCount: uncommittedCount,
            hasRemote: hasRemote,
            ahead: ahead,
            behind: behind
        )
    }

    /// `git fetch --prune` against all remotes. Relies on the user's system git
    /// credentials (SSH agent or credential helper); the app stores no token.
    static func fetch(at path: String) -> String? {
        let result = runResult(["fetch", "--prune", "--all"], at: path)
        guard result.status == 0 else {
            let detail = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty ? AppCopy.text("git.fetchFailed") : detail
        }
        return nil
    }

    /// Push the branch to `origin`, setting upstream on first push.
    static func push(_ branch: String, at path: String) -> String? {
        guard !branch.isEmpty, !branch.contains(where: { $0 == "\n" || $0 == "\r" }) else {
            return AppCopy.text("git.pushFailed")
        }
        let result = runResult(["push", "--set-upstream", "origin", branch], at: path)
        guard result.status == 0 else {
            let detail = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty ? AppCopy.text("git.pushFailed") : detail
        }
        return nil
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
    let busy: Bool
    let onSelect: (String) -> Void
    let onSelectRemote: (String) -> Void
    let onCreate: () -> Void
    let onFetch: () -> Void
    let onPush: () -> Void

    @State private var searchText = ""

    private var filteredBranches: [String] {
        guard !searchText.isEmpty else { return snapshot.branches }
        return snapshot.branches.filter { $0.localizedCaseInsensitiveContains(searchText) }
    }

    private var filteredRemoteBranches: [String] {
        guard !searchText.isEmpty else { return snapshot.remoteBranches }
        return snapshot.remoteBranches.filter { $0.localizedCaseInsensitiveContains(searchText) }
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

            if !filteredRemoteBranches.isEmpty {
                Text(AppCopy.text("git.remoteBranches"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 9)
                    .padding(.top, 5)

                ForEach(filteredRemoteBranches, id: \.self) { branch in
                    Button {
                        onSelectRemote(branch)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "cloud")
                                .font(.system(size: 13, weight: .medium))
                                .frame(width: 17)
                                .foregroundStyle(.secondary)
                            Text(branch)
                                .font(.callout)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                        }
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(busy)
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

            if busy {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(AppCopy.text("git.working"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 9)
                .frame(height: 30)
            } else {
                actionRow(icon: "arrow.down.circle", title: AppCopy.text("git.fetch"), action: onFetch)
                    .disabled(!snapshot.hasRemote)
                    .opacity(snapshot.hasRemote ? 1 : 0.45)
                actionRow(icon: "arrow.up.circle", title: AppCopy.text("git.push"), action: onPush)
                    .disabled(!snapshot.hasRemote || snapshot.currentBranch == nil)
                    .opacity(snapshot.hasRemote && snapshot.currentBranch != nil ? 1 : 0.45)
                actionRow(icon: "plus", title: AppCopy.text("git.createBranch"), action: onCreate)
            }
        }
        .padding(8)
        .frame(width: 360)
    }

    private func actionRow(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .frame(width: 17)
                Text(title)
                Spacer(minLength: 0)
            }
            .font(.callout)
            .padding(.horizontal, 9)
            .frame(height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct PromptTextEditor: NSViewRepresentable {
    @Binding var text: String
    let isEnabled: Bool
    let onSubmit: (PromptMode) -> Void
    let onAcceptSlashCommand: () -> Bool
    let onMoveSlashCommand: (Int) -> Bool
    let followUpSuggestion: String?
    let onGhostVisibilityChange: (Bool) -> Void

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
        editor.onGhostVisibilityChange = { [weak coordinator = context.coordinator] visible in
            coordinator?.ghostVisibilityChanged(visible)
        }
        editor.onGhostAccepted = { [weak coordinator = context.coordinator] text in
            coordinator?.ghostAccepted(text)
        }
        editor.string = text
        editor.isEditable = isEnabled
        editor.isRichText = false
        editor.font = .systemFont(ofSize: 15)
        editor.textContainerInset = NSSize(width: 5, height: 5)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        // Kill the default 5pt line-fragment padding so the caret sits flush
        // with the placeholder's leading edge (9pt SwiftUI + 5pt inset = 14pt).
        editor.textContainer?.lineFragmentPadding = 0
        editor.drawsBackground = false

        scrollView.documentView = editor
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let editor = nsView.documentView as? PromptNSTextView else { return }
        context.coordinator.update(parent: self)
        editor.onSubmit = onSubmit
        editor.onAcceptSlashCommand = onAcceptSlashCommand
        editor.onMoveSlashCommand = onMoveSlashCommand
        editor.isEditable = isEnabled

        if text.isEmpty {
            if !editor.committedString.isEmpty {
                editor.removeGhost()
                editor.string = ""
            }
            if let followUpSuggestion, !editor.hasMarkedText() {
                if editor.ghostText != followUpSuggestion {
                    editor.removeGhost()
                }
                if editor.ghostRange == nil, !editor.ghostReinsertionSuppressed {
                    editor.insertGhost(followUpSuggestion)
                }
            } else if followUpSuggestion == nil {
                editor.removeGhost()
            }
        } else {
            editor.removeGhost()
            if editor.string != text {
                editor.string = text
            }
        }
        editor.setAccessibilityHelp(
            editor.ghostRange == nil ? nil : AppCopy.text("composer.followUp.hint")
        )
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        private var parent: PromptTextEditor

        init(_ parent: PromptTextEditor) {
            self.parent = parent
        }

        func update(parent: PromptTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? PromptNSTextView else { return }
            let committedString = editor.committedString
            parent.text = committedString
            if !committedString.isEmpty {
                editor.ghostReinsertionSuppressed = false
            }
            guard committedString.isEmpty,
                  !editor.hasMarkedText(),
                  !editor.ghostReinsertionSuppressed,
                  let suggestion = parent.followUpSuggestion,
                  editor.ghostRange == nil else { return }
            editor.insertGhost(suggestion)
        }

        func ghostVisibilityChanged(_ visible: Bool) {
            parent.onGhostVisibilityChange(visible)
        }

        func ghostAccepted(_ text: String) {
            parent.text = text
            parent.onGhostVisibilityChange(false)
        }
    }
}

private final class PromptNSTextView: NSTextView {
    var onSubmit: ((PromptMode) -> Void)?
    var onAcceptSlashCommand: (() -> Bool)?
    var onMoveSlashCommand: ((Int) -> Bool)?
    var onGhostVisibilityChange: ((Bool) -> Void)?
    var onGhostAccepted: ((String) -> Void)?
    var ghostRange: NSRange?
    var ghostText: String?
    var ghostReinsertionSuppressed = false

    var committedString: String {
        guard let ghostRange,
              NSMaxRange(ghostRange) <= (string as NSString).length else { return string }
        return (string as NSString).replacingCharacters(in: ghostRange, with: "")
    }

    func insertGhost(_ text: String) {
        guard ghostRange == nil,
              !text.isEmpty,
              committedString.isEmpty,
              !hasMarkedText(),
              let textStorage else { return }

        let attributedText = NSAttributedString(
            string: text,
            attributes: [
                .foregroundColor: NSColor.tertiaryLabelColor,
                .font: font ?? NSFont.systemFont(ofSize: 15),
            ]
        )
        textStorage.beginEditing()
        textStorage.insert(attributedText, at: 0)
        textStorage.endEditing()
        ghostRange = NSRange(location: 0, length: attributedText.length)
        ghostText = text
        ghostReinsertionSuppressed = false
        setSelectedRange(NSRange(location: 0, length: 0))
        setAccessibilityHelp(AppCopy.text("composer.followUp.hint"))
        onGhostVisibilityChange?(true)
    }

    func removeGhost(suppressReinsertion: Bool = false) {
        ghostReinsertionSuppressed = suppressReinsertion
        guard let range = ghostRange else { return }
        ghostRange = nil
        ghostText = nil
        if let textStorage, NSMaxRange(range) <= textStorage.length {
            textStorage.beginEditing()
            textStorage.deleteCharacters(in: range)
            textStorage.endEditing()
        }
        setAccessibilityHelp(nil)
        onGhostVisibilityChange?(false)
    }

    func acceptGhost() -> Bool {
        guard let range = ghostRange,
              let textStorage,
              NSMaxRange(range) <= textStorage.length else { return false }

        textStorage.beginEditing()
        textStorage.addAttribute(
            .foregroundColor,
            value: textColor ?? NSColor.labelColor,
            range: range
        )
        textStorage.endEditing()
        ghostRange = nil
        ghostText = nil
        ghostReinsertionSuppressed = false
        let committedString = string
        setSelectedRange(NSRange(location: (committedString as NSString).length, length: 0))
        setAccessibilityHelp(nil)
        onGhostVisibilityChange?(false)
        onGhostAccepted?(committedString)
        return true
    }

    override func keyDown(with event: NSEvent) {
        let keyModifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let hasTextModifiers = keyModifiers.contains(.command)
            || keyModifiers.contains(.control)
            || keyModifiers.contains(.option)
            || keyModifiers.contains(.shift)

        switch event.keyCode {
        case 48 where !hasTextModifiers:
            if onAcceptSlashCommand?() == true { return }
            if acceptGhost() { return }
        case 126 where !hasTextModifiers:
            if onMoveSlashCommand?(-1) == true { return }
        case 125 where !hasTextModifiers:
            if onMoveSlashCommand?(1) == true { return }
        default:
            break
        }

        if ghostRange != nil {
            removeGhost(suppressReinsertion: true)
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
    let showsWorkspace: Bool
    let onOpenSkills: () -> Void
    let onSetGoal: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(AppCopy.text("composer.add"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 9)
                .padding(.bottom, 4)
            attachmentRow(icon: "paperclip", title: AppCopy.text("attachment.files"), action: onChooseFiles)
            attachmentRow(icon: "rectangle.stack", title: AppCopy.text("attachment.addApp")) {}
            if showsWorkspace {
                attachmentRow(icon: "folder", title: AppCopy.text("attachment.project"), detail: AppCopy.text("attachment.projectDetail"), action: onChooseWorkspace)
            }
            attachmentRow(icon: "scope", title: AppCopy.text("attachment.goal"), detail: AppCopy.text("attachment.goalDetail"), action: onSetGoal)
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

    private var helpURL: URL? {
        var components = URLComponents(string: "https://dots.net.tr/harness/sandboxing")
        components?.queryItems = [URLQueryItem(name: "lang", value: AppCopy.effectiveLanguage.rawValue)]
        return components?.url
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(AppCopy.text("permission.title"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if let helpURL {
                    Link(destination: helpURL) {
                        Text(AppCopy.text("permission.moreInfo"))
                            .font(.caption)
                            .underline()
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 4)

            ForEach(AgentPermissionMode.allCases) { level in
                Button {
                    selection = level
                } label: {
                    HStack(alignment: .top, spacing: 8) {
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
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(
                        level == selection ? Color.primary.opacity(0.10) : .clear,
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(6)
        .frame(width: 475)
    }
}

private struct ModelPickerPopover: View {
    @ObservedObject var model: AppModel
    @State private var collapsedProviders: Set<String> = []
    /// Card shows only the selected model; tapping its title swaps in the model list.
    @State private var showingModels = false

    private var modelGroups: [RouterModelGroup] {
        RouterCatalog.modelGroups(for: model.router.models)
    }

    /// Levels the selected model actually accepts. Empty means the provider
    /// rejects the effort parameter for it, so the slider is disabled.
    private var effortLevels: [String] {
        // Auto owns the effort decision, so the manual control stands down.
        model.router.isAutoSelected ? [] : model.router.efforts(for: model.selectedModelID)
    }

    private var supportsFast: Bool {
        !model.router.isAutoSelected && model.router.supportsFast(model.selectedModelID)
    }

    private var isFast: Bool { supportsFast && model.router.fastMode }

    var body: some View {
        Group {
            if showingModels { modelList } else { effortCard }
        }
        .padding(8)
        .frame(width: 225)
        .animation(.easeInOut(duration: 0.15), value: showingModels)
    }

    // MARK: Effort card

    private var effortCard: some View {
        let stops = effortLevels
        let enabled = !stops.isEmpty
        let index = stops.firstIndex(of: model.router.effectiveEffort(for: model.selectedModelID)) ?? 0
        return VStack(spacing: 8) {
            HStack {
                if supportsFast {
                Button {
                    model.setFast(!isFast)
                } label: {
                    Image(systemName: isFast ? "bolt.fill" : "bolt")
                        .foregroundStyle(isFast ? Color.accentColor : .secondary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("\(AppCopy.text("modelPicker.speed")): \(AppCopy.text(isFast ? "modelPicker.fast" : "modelPicker.standard"))")
                } else {
                    Color.clear.frame(width: 18, height: 18)
                }

                Spacer()
                Button { showingModels = true } label: {
                    VStack(spacing: 2) {
                        HStack(spacing: 4) {
                            Text(effortTitle)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(isUltra ? Color.purple : (enabled ? Color.accentColor : .secondary))
                        Text(selectedModelName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(AppCopy.text("modelPicker.selectModel"))
                Spacer()

                Button {
                    model.setEffort("low")
                    model.setFast(false)
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(AppCopy.text("modelPicker.reset"))
            }
            .font(.system(size: 10, weight: .medium))

            EffortSlider(count: max(stops.count, 1), index: index, ultra: isUltra) { model.setEffort(stops[$0]) }
                .disabled(!enabled)
                .opacity(enabled ? 1 : 0.45)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.08)))
    }

    /// Top "max" level gets the Codex-style starry purple track.
    private var isUltra: Bool {
        model.router.effectiveEffort(for: model.selectedModelID) == "max" && effortLevels.last == "max"
    }

    private var effortTitle: String {
        if model.router.isAutoSelected { return AppCopy.text("modelPicker.auto") }
        if effortLevels.isEmpty { return AppCopy.text("modelPicker.effortUnsupported") }
        return Self.effortLabel(model.router.effectiveEffort(for: model.selectedModelID))
    }

    private var selectedModelName: String {
        if model.router.isAutoSelected { return AppCopy.text("modelPicker.auto") }
        guard !model.selectedModelID.isEmpty else { return AppCopy.text("modelPicker.selectModel") }
        let item = model.router.models.first(where: { $0.id == model.selectedModelID })
            ?? RouterModel(id: model.selectedModelID)
        return RouterCatalog.modelDisplayName(for: item)
    }

    static func effortLabel(_ level: String) -> String {
        level.isEmpty ? AppCopy.text("modelPicker.effort.default") : AppCopy.text("modelPicker.effort.\(level)")
    }

    // MARK: Model list

    private var modelList: some View {
        VStack(alignment: .leading, spacing: 1) {
            Button { showingModels = false } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left").font(.system(size: 10, weight: .bold))
                    Text(AppCopy.text("modelPicker.selectModel"))
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if modelGroups.isEmpty {
                Text(AppCopy.text("modelPicker.noModel"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(10)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        pickerRow(
                            title: AppCopy.text("modelPicker.auto"),
                            subtitle: AppCopy.text("modelPicker.autoHint"),
                            selected: model.router.isAutoSelected
                        ) { model.setModel(ModelRouter.autoModelID); showingModels = false }

                        ForEach(modelGroups) { group in
                            providerHeader(group)
                            if !collapsedProviders.contains(group.provider) {
                                ForEach(group.models) { item in
                                    pickerRow(
                                        title: RouterCatalog.modelDisplayName(for: item),
                                        selected: !model.router.isAutoSelected && item.id == model.selectedModelID
                                    ) { model.setModel(item.id); showingModels = false }
                                }
                            }
                        }
                    }
                }
                .frame(maxHeight: 340)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func providerHeader(_ group: RouterModelGroup) -> some View {
        let collapsed = collapsedProviders.contains(group.provider)
        return Button {
            if collapsed { collapsedProviders.remove(group.provider) } else { collapsedProviders.insert(group.provider) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: group.logoSymbol).frame(width: 14)
                Text(group.name)
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .rotationEffect(.degrees(collapsed ? -90 : 0))
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func pickerRow(
        title: String,
        subtitle: String? = nil,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13))
                    if let subtitle {
                        Text(subtitle).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .lineLimit(1)
                Spacer(minLength: 8)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(PickerRowStyle(selected: selected))
    }
}

/// Hover/selection highlight for popover rows.
private struct PickerRowStyle: ButtonStyle {
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        HoverRow(configuration: configuration, selected: selected)
    }

    private struct HoverRow: View {
        let configuration: ButtonStyleConfiguration
        let selected: Bool
        @State private var hovering = false

        var body: some View {
            configuration.label
                .foregroundStyle(.primary)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Color.primary.opacity(configuration.isPressed ? 0.12 : (hovering ? 0.07 : (selected ? 0.04 : 0))))
                )
                .onHover { hovering = $0 }
        }
    }
}

/// Codex-style discrete slider: filled accent track, stop dots, white knob.
private struct EffortSlider: View {
    let count: Int
    let index: Int
    var ultra = false
    let onChange: (Int) -> Void
    @Environment(\.isEnabled) private var isEnabled

    private let height: CGFloat = 22

    var body: some View {
        GeometryReader { geo in
            let knob = height - 4
            let travel = max(geo.size.width - knob - 4, 1)
            let step = count > 1 ? travel / CGFloat(count - 1) : 0
            let knobX = 2 + CGFloat(index) * step

            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                Capsule()
                    .fill(ultra
                        ? AnyShapeStyle(LinearGradient(
                            colors: [Color(red: 0.25, green: 0.2, blue: 0.75), Color(red: 0.72, green: 0.6, blue: 1), Color(red: 0.3, green: 0.15, blue: 0.7)],
                            startPoint: .leading, endPoint: .trailing))
                        : AnyShapeStyle(Color.accentColor))
                    .overlay(ultra ? AnyView(Starfield()) : AnyView(EmptyView()))
                    .clipShape(Capsule())
                    .frame(width: knobX + knob + 2)
                ForEach(0..<count, id: \.self) { i in
                    Circle()
                        .fill(i <= index ? Color.white.opacity(ultra ? 0 : 0.55) : Color.primary.opacity(0.35))
                        .frame(width: 5, height: 5)
                        .offset(x: 2 + CGFloat(i) * step + knob / 2 - 2.5)
                }
                Circle()
                    .fill(Color.white)
                    .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                    .frame(width: knob, height: knob)
                    .offset(x: knobX)
            }
            .frame(width: geo.size.width, height: height, alignment: .leading)
            .contentShape(Rectangle())
            .highPriorityGesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local).onChanged { value in
                    guard isEnabled, count > 1 else { return }
                    let raw = (value.location.x - 2 - knob / 2) / step
                    let next = min(max(Int(raw.rounded()), 0), count - 1)
                    if next != index { onChange(next) }
                }
            )
            .animation(.spring(response: 0.25, dampingFraction: 0.85), value: index)
        }
        .frame(height: height)
    }
}

/// Fixed sparkle dots for the "max" track; deterministic so it doesn't flicker.
private struct Starfield: View {
    private static let stars: [(CGFloat, CGFloat, CGFloat)] = (0..<18).map { i in
        let f = CGFloat(i)
        return ((f * 0.618).truncatingRemainder(dividingBy: 1), (f * 0.381 + 0.2).truncatingRemainder(dividingBy: 0.8) + 0.1, i % 4 == 0 ? 2.5 : 1.5)
    }

    var body: some View {
        GeometryReader { geo in
            ForEach(Self.stars.indices, id: \.self) { i in
                let star = Self.stars[i]
                Circle()
                    .fill(Color.white.opacity(0.75))
                    .frame(width: star.2, height: star.2)
                    .position(x: star.0 * geo.size.width, y: star.1 * geo.size.height)
            }
        }
    }
}

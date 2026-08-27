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
    @State private var accessLevel: AccessLevel = .full
    @State private var reasoningEffort = AppCopy.text("modelPicker.maximum")
    @State private var responseSpeed = AppCopy.text("modelPicker.standard")
    @FocusState private var composerFocused: Bool

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
                    skills: slashSkills,
                    onSelect: selectSlashCommand
                )
                .padding(.horizontal, 18)
                .padding(.bottom, 8)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            SlotStack(slot: WellKnownSlot.composerAccessory, registry: model.host.slots)

            VStack(spacing: 0) {
                workspaceContext
                if !model.draftImages.isEmpty {
                    draftImages
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
    }

    private var composerSurface: Color {
        Color.primary.opacity(0.075)
    }

    @ViewBuilder
    private var workspaceContext: some View {
        if !model.workspacePath.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .font(.caption)
                Text(workspaceName)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 15)
            .padding(.top, 12)
            .padding(.bottom, 2)
        }
    }

    private var growingEditor: some View {
        ZStack(alignment: .topLeading) {
            PromptTextEditor(text: $model.draft, isEnabled: true) { mode in
                guard model.canSend else { return }
                model.send(mode: mode)
            }
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

    private var draftImages: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(model.draftImages, id: \.self) { url in
                    ZStack(alignment: .topTrailing) {
                        if let image = NSImage(contentsOf: url) {
                            Image(nsImage: image)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 64, height: 64)
                                .clipped()
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        } else {
                            Image(systemName: "photo")
                                .frame(width: 64, height: 64)
                                .foregroundStyle(.secondary)
                        }

                        Button {
                            model.removeDraftImage(url)
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
                    onOpenSkills: openSkillsFromAttachmentMenu
                )
            }
            .help(AppCopy.text("composer.add"))

            Button {
                showPermissionMenu.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: accessLevel == .full ? "shield.fill" : "shield")
                        .font(.caption.weight(.semibold))
                    Text(accessLevel.title)
                        .font(.callout.weight(.medium))
                }
                .foregroundStyle(accessLevel == .full ? Color.orange : .secondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(
                    (accessLevel == .full ? Color.orange : Color.primary).opacity(0.12),
                    in: Capsule()
                )
            }
            .buttonStyle(.plain)
                .popover(isPresented: $showPermissionMenu, arrowEdge: .top) {
                PermissionMenu(selection: $accessLevel)
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
                .frame(maxWidth: 250)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showModelMenu, arrowEdge: .bottom) {
                ModelPickerPopover(
                    model: model,
                    reasoningEffort: $reasoningEffort,
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
            .disabled(voiceInput.state == .transcribing || voiceInput.state == .sending || model.isVoiceModelDownloading || !model.canSend)
            .help(voiceInput.isListening ? AppCopy.text("composer.stopListening") : model.voiceInputHelp)

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
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
        .padding(.top, 6)
    }

    private var workspaceName: String {
        URL(fileURLWithPath: model.workspacePath).lastPathComponent
    }

    private var modelName: String {
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
        !model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && model.canSend
    }

    private var sendIcon: String {
        return model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "waveform" : "arrow.up"
    }

    private var slashMenuIsVisible: Bool {
        slashToken != nil
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
            SlashCommand(id: "speed", title: AppCopy.text("slash.speed"), detail: AppCopy.text("slash.speedDetail"), icon: "bolt", kind: .setting),
            SlashCommand(id: "billing", title: AppCopy.text("slash.billing"), detail: AppCopy.text("slash.billingDetail"), icon: "chart.bar", kind: .setting),
            SlashCommand(id: "mcp", title: AppCopy.text("slash.mcp"), detail: AppCopy.text("slash.mcpDetail"), icon: "point.3.connected.trianglepath.dotted", kind: .setting),
            SlashCommand(id: "model", title: AppCopy.text("slash.model"), detail: modelName, icon: "cube", kind: .setting),
            SlashCommand(id: "plan", title: AppCopy.text("slash.plan"), detail: AppCopy.text("slash.planDetail"), icon: "lightbulb", kind: .setting),
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

    private func filterCommands(_ commands: [SlashCommand]) -> [SlashCommand] {
        guard !slashQuery.isEmpty else { return commands }
        return commands.filter {
            $0.title.localizedCaseInsensitiveContains(slashQuery)
                || $0.detail.localizedCaseInsensitiveContains(slashQuery)
        }
    }

    private func selectSlashCommand(_ command: SlashCommand) {
        replaceSlashToken(with: command.kind == .skill ? "/\(command.title) " : "")
        composerFocused = true

        switch command.id {
        case "model":
            showModelMenu = true
        case "project":
            model.chooseWorkspace()
        case "reasoning":
            reasoningEffort = reasoningEffort == AppCopy.text("modelPicker.maximum")
                ? AppCopy.text("modelPicker.standard")
                : AppCopy.text("modelPicker.maximum")
        case "speed":
            responseSpeed = responseSpeed == AppCopy.text("modelPicker.standard")
                ? AppCopy.text("modelPicker.fast")
                : AppCopy.text("modelPicker.standard")
        default:
            if command.kind == .setting {
                model.presentSettings()
            }
        }
    }

    private func replaceSlashToken(with replacement: String) {
        guard let slashToken,
              let range = model.draft.range(of: slashToken, options: .backwards) else { return }
        model.draft.replaceSubrange(range, with: replacement)
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
        panel.allowedContentTypes = [.image]
        panel.prompt = AppCopy.text("composer.add")
        panel.begin { response in
            guard response == .OK else { return }
            Task { @MainActor in
                model.addDraftImages(panel.urls)
            }
        }
        showAttachmentMenu = false
    }
}

private struct PromptTextEditor: NSViewRepresentable {
    @Binding var text: String
    let isEnabled: Bool
    let onSubmit: (PromptMode) -> Void

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

    override func keyDown(with event: NSEvent) {
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

private enum AccessLevel: String, CaseIterable, Identifiable {
    case ask
    case safe
    case full

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ask: return AppCopy.text("permission.ask")
        case .safe: return AppCopy.text("permission.safe")
        case .full: return AppCopy.text("permission.full")
        }
    }

    var detail: String {
        switch self {
        case .ask: return AppCopy.text("permission.askDetail")
        case .safe: return AppCopy.text("permission.safeDetail")
        case .full: return AppCopy.text("permission.fullDetail")
        }
    }

    var icon: String {
        switch self {
        case .ask: return "hand.raised"
        case .safe: return "checkmark.shield"
        case .full: return "shield"
        }
    }
}

private enum SlashCommandKind {
    case setting
    case skill
}

private struct SlashCommand: Identifiable {
    var id: String
    var title: String
    var detail: String
    var icon: String
    var kind: SlashCommandKind
}

private struct SlashCommandPalette: View {
    let settings: [SlashCommand]
    let skills: [SlashCommand]
    let onSelect: (SlashCommand) -> Void

    @State private var highlightedID: String?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                if !settings.isEmpty {
                    sectionTitle(AppCopy.text("composer.settings"))
                    ForEach(settings) { command in
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
            highlightedID = settings.first?.id ?? skills.first?.id
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
            attachmentRow(icon: "scope", title: AppCopy.text("attachment.goal"), detail: AppCopy.text("attachment.goalDetail")) {}
            attachmentRow(icon: "lightbulb", title: AppCopy.text("attachment.plan"), detail: AppCopy.text("attachment.planDetail")) {}
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
    @Binding var selection: AccessLevel

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

            ForEach(AccessLevel.allCases) { level in
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
    @Binding var reasoningEffort: String
    @Binding var responseSpeed: String
    @State private var showModelList = false

    private var modelIDs: [String] {
        model.router.models.map(\.id).filter { !$0.isEmpty }
    }

    var body: some View {
        HStack(spacing: 0) {
            if showModelList {
                modelList
                Divider()
            }

            VStack(alignment: .leading, spacing: 2) {
                optionRow(title: AppCopy.text("modelPicker.model"), value: selectedModelName, icon: "chevron.right") {
                    showModelList.toggle()
                }
                optionRow(title: AppCopy.text("modelPicker.effort"), value: reasoningEffort, icon: "chevron.right") {
                    reasoningEffort = reasoningEffort == AppCopy.text("modelPicker.maximum")
                        ? AppCopy.text("modelPicker.standard")
                        : AppCopy.text("modelPicker.maximum")
                }
                optionRow(title: AppCopy.text("modelPicker.speed"), value: responseSpeed, icon: "chevron.right") {
                    responseSpeed = responseSpeed == AppCopy.text("modelPicker.standard")
                        ? AppCopy.text("modelPicker.fast")
                        : AppCopy.text("modelPicker.standard")
                }
                Divider().padding(.vertical, 7)
                Button {
                    reasoningEffort = AppCopy.text("modelPicker.maximum")
                    responseSpeed = AppCopy.text("modelPicker.standard")
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
            .frame(width: showModelList ? 220 : 270)
        }
        .padding(0)
        .frame(width: showModelList ? 505 : 286)
    }

    private var selectedModelName: String {
        model.selectedModelID.isEmpty ? AppCopy.text("modelPicker.selectModel") : model.selectedModelID
    }

    private var modelList: some View {
        VStack(alignment: .leading, spacing: 2) {
            if modelIDs.isEmpty {
                Text(AppCopy.text("modelPicker.noModel"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(12)
            } else {
                ForEach(modelIDs, id: \.self) { id in
                    Button {
                        model.setModel(id)
                        showModelList = false
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

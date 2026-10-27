// Copyright (c) 2026 DOTS
// Bots section: a list of bots and the running chat with the selected one.

import AppKit
import SwiftUI
import UniformTypeIdentifiers
import DotsHarnessCore

struct BotsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var store: BotStore
    @State private var draft = ""
    @State private var editing: Bot?
    @State private var deleteTarget: Bot?
    @State private var hoveredBotID: String?
    @State private var translations: [String: String] = [:]
    @State private var translating: Set<String> = []
    @State private var transferErrorTitle = ""
    @State private var transferError = ""
    @State private var isTransferErrorPresented = false
    @State private var sidebarWidth = 228.0

    init(model: AppModel) {
        self.model = model
        self.store = model.bots
    }

    var body: some View {
        GeometryReader { geometry in
            let maximum = max(180, min(380, geometry.size.width - 308))
            let width = min(sidebarWidth, maximum)
            HStack(spacing: 0) {
                botList
                    .frame(width: width)
                WorkspaceDivider(
                    horizontal: false, preferred: $sidebarWidth, actual: width,
                    limits: 180...maximum, sign: model.isRTL ? -1 : 1
                )
                Group {
                    if let bot = store.bot(store.selectedBotID) {
                        chat(with: bot)
                    } else {
                        emptyState
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { store.loadIfNeeded() }
        .sheet(item: $editing) { bot in
            BotEditor(model: model, bot: bot) { saved, chosenImage, clearsImage in
                var saved = saved
                if let chosenImage {
                    saved.imagePath = try store.copyAvatar(from: chosenImage)
                } else if clearsImage {
                    saved.imagePath = nil
                }
                store.upsert(saved)
                store.selectedBotID = saved.id
            }
        }
        .confirmationDialog(
            AppCopy.format("bots.deleteConfirm", deleteTarget?.name ?? ""),
            isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } })
        ) {
            Button(AppCopy.text("common.delete"), role: .destructive) {
                if let deleteTarget { store.delete(deleteTarget.id) }
            }
            Button(AppCopy.text("common.cancel"), role: .cancel) {}
        }
        .alert(
            Text(transferErrorTitle),
            isPresented: $isTransferErrorPresented,
            actions: { Button(AppCopy.text("common.cancel"), role: .cancel) {} },
            message: { Text(transferError) }
        )
    }

    // MARK: List

    private var botList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 22, height: 22)
                Text(AppCopy.text("rail.bots"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: importBots) {
                    Image(systemName: "square.and.arrow.down")
                }
                .buttonStyle(.plain)
                .help(AppCopy.text("memory.transfer.import"))
                .accessibilityLabel(AppCopy.text("memory.transfer.import"))
                Button(action: exportBots) {
                    Image(systemName: "square.and.arrow.up")
                }
                .buttonStyle(.plain)
                .help(AppCopy.text("memory.transfer.export"))
                .accessibilityLabel(AppCopy.text("memory.transfer.export"))
                Text(store.bots.count, format: .number)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Button { editing = Bot(name: "") } label: {
                HStack(spacing: 10) {
                    Image(systemName: "square.and.pencil").frame(width: 20)
                    Text(AppCopy.text("bots.new"))
                        .font(.system(size: 13, weight: .medium))
                    Spacer(minLength: 0)
                    Image(systemName: "plus.circle").foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .frame(height: 36)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 8)

            Divider().padding(.horizontal, 14).padding(.vertical, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    if store.bots.isEmpty {
                        Text(AppCopy.text("bots.empty.title"))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                            .padding(.bottom, 8)
                    }
                    ForEach(store.bots) { bot in
                        let isSelected = bot.id == store.selectedBotID
                        Button { store.selectedBotID = bot.id } label: {
                            HStack(spacing: 9) {
                                BotAvatar(
                                    symbol: bot.symbol,
                                    imageURL: bot.imagePath.map { URL(fileURLWithPath: $0) },
                                    size: 22
                                )
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(bot.name)
                                        .font(.system(size: 13, weight: .medium))
                                        .lineLimit(1)
                                    if !bot.workspacePath.isEmpty {
                                        Text((bot.workspacePath as NSString).lastPathComponent)
                                            .font(.system(size: 11))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                Spacer(minLength: 0)
                                if store.isBusy(bot.id) { HerNessLoadingAnimation(size: 16) }
                            }
                            .padding(.horizontal, 9)
                            .frame(height: bot.workspacePath.isEmpty ? 36 : 48)
                            .background(
                                Color.primary.opacity(isSelected ? 0.1 : (hoveredBotID == bot.id ? 0.05 : 0)),
                                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .onHover { hoveredBotID = $0 ? bot.id : nil }
                        .help(bot.name)
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                        .contextMenu {
                            Button(AppCopy.text("bots.edit")) { editing = bot }
                            Button(AppCopy.text("bots.clear")) { store.clearHistory(bot.id) }
                            Divider()
                            Button(AppCopy.text("common.delete"), role: .destructive) { deleteTarget = bot }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func exportBots() {
        guard !store.bots.isEmpty else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "herness-bots.json"
        panel.canCreateDirectories = true
        panel.title = AppCopy.text("memory.transfer.export")
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        let hasAccess = destination.startAccessingSecurityScopedResource()
        defer { if hasAccess { destination.stopAccessingSecurityScopedResource() } }
        do {
            try store.exportArchive().write(to: destination, options: .atomic)
        } catch {
            presentTransferError(error, title: AppCopy.text("memory.transfer.export"))
        }
    }

    private func importBots() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.title = AppCopy.text("memory.transfer.import")
        guard panel.runModal() == .OK, let source = panel.url else { return }

        let hasAccess = source.startAccessingSecurityScopedResource()
        defer { if hasAccess { source.stopAccessingSecurityScopedResource() } }
        do {
            let ids = try store.importArchive(Data(contentsOf: source))
            store.selectedBotID = ids.first
        } catch {
            presentTransferError(error, title: AppCopy.text("memory.transfer.import"))
        }
    }

    private func presentTransferError(_ error: Error, title: String) {
        transferErrorTitle = title
        transferError = error.localizedDescription
        isTransferErrorPresented = true
    }

    private var emptyState: some View {
        let presets = Bot.presets
        let roles = ["assistant", "researcher", "coder"]
        let cards = zip(roles, presets).map { role, preset in
            WelcomeCard(
                id: role, icon: preset.symbol, title: preset.name,
                subtitle: AppCopy.text("bots.preset.\(role).detail"), prompt: ""
            )
        } + [WelcomeCard(
            id: "custom", icon: "plus.circle", title: AppCopy.text("bots.new"),
            subtitle: AppCopy.text("bots.instructionsHelp"), prompt: ""
        )]

        return GeometryReader { geometry in
            ScrollView {
                WelcomeView(
                    projectName: AppCopy.text("rail.bots"),
                    showConnectHint: false,
                    showCards: true,
                    cards: cards
                ) { card in
                    if let index = roles.firstIndex(of: card.id) {
                        editing = presets[index]
                    } else {
                        editing = Bot(name: "")
                    }
                }
                .frame(maxWidth: .infinity, minHeight: max(440, geometry.size.height))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Chat

    private func chat(with bot: Bot) -> some View {
        let isBusy = store.isBusy(bot.id)
        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                BotAvatar(
                    symbol: bot.symbol,
                    imageURL: bot.imagePath.map { URL(fileURLWithPath: $0) },
                    size: 28
                )
                VStack(alignment: .leading, spacing: 1) {
                    Text(bot.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    if !bot.workspacePath.isEmpty {
                        Text(AppCopy.format("bots.agentIn", (bot.workspacePath as NSString).lastPathComponent))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                Button { editing = bot } label: { Image(systemName: "slider.horizontal.3") }
                    .help(AppCopy.text("bots.edit"))
                    .accessibilityLabel(AppCopy.text("bots.edit"))
            }
            .controlSize(.small)
            .padding(.horizontal, 16)
            .frame(height: 44)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if bot.messages.isEmpty, !isBusy {
                            Text(AppCopy.format("bots.greeting", bot.name))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                                .padding(.top, 60)
                        }
                        ForEach(Array(bot.messages.enumerated()), id: \.element.id) { index, message in
                            let startsGroup = index == 0 || bot.messages[index - 1].role != message.role
                            bubble(
                                isUser: message.role == .user, startsGroup: startsGroup, message: message
                            ) {
                                BotMessageText(text: message.text)
                                if let translation = translations[message.id] {
                                    BotMessageText(text: translation).foregroundStyle(.secondary)
                                }
                            }
                        }
                        if isBusy {
                            let partial = (store.streaming[bot.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                            bubble(isUser: false, startsGroup: bot.messages.last?.role != .assistant, message: nil) {
                                if partial.isEmpty {
                                    HerNessLoadingAnimation(size: 20)
                                } else {
                                    HStack(alignment: .top, spacing: 8) {
                                        HerNessLoadingAnimation(size: 18)
                                        BotMessageText(text: partial, caches: false)
                                    }
                                }
                            }
                        }
                        if let error = store.errors[bot.id] {
                            Text(error).font(.callout).foregroundStyle(.red).padding(.top, 10)
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                    .frame(maxWidth: 760, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
                .scrollToBottomButton {
                    withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo("end", anchor: .bottom) }
                }
                .onChange(of: bot.messages.count) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
                .onChange(of: store.streaming[bot.id]) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
                .onAppear { proxy.scrollTo("end", anchor: .bottom) }
            }

            BotComposer(model: model, store: store, bot: bot, isBusy: isBusy, draft: $draft)
        }
        .id(bot.id)
    }

    /// A chat bubble: the user's on the trailing side, the bot's on the leading side.
    /// The first bubble of a run from one side carries the tail that points at its sender.
    /// A sent message also shows its time, a translate button and, for the user's own,
    /// the ticks: one while it waits, two once the bot has been handed it.
    private func bubble(
        isUser: Bool, startsGroup: Bool, message: BotMessage?,
        @ViewBuilder content: () -> some View
    ) -> some View {
        ViewThatFits(in: .horizontal) {
            bubbleBody(isUser: isUser, message: message, content: content)
                .fixedSize(horizontal: true, vertical: true)
            bubbleBody(isUser: isUser, message: message, content: content)
                .frame(maxWidth: 518, alignment: isUser ? .trailing : .leading)
        }
        .frame(maxWidth: 518, alignment: isUser ? .trailing : .leading)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background {
            BubbleShape(hasTail: startsGroup, isTrailing: isUser)
                .fill(isUser ? Color.accentColor.opacity(0.24) : Color.primary.opacity(0.08))
                .flipsForRightToLeftLayoutDirection(true)
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
        .padding(.top, startsGroup ? 10 : 3)
    }

    private func bubbleBody(
        isUser: Bool, message: BotMessage?, @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .trailing, spacing: 4) {
            content()
            if let message {
                HStack(spacing: 5) {
                    CopyFeedbackButton(text: message.text)
                    if translating.contains(message.id) {
                        ProgressView().controlSize(.mini)
                    } else {
                        Button {
                            toggleTranslation(id: message.id, text: message.text, model: model, translations: $translations, translating: $translating)
                        } label: { Image(systemName: "globe") }
                            .buttonStyle(.plain)
                            .foregroundStyle(translations[message.id] == nil ? Color.secondary : Color.accentColor)
                            .help(AppCopy.text("conversation.translate"))
                            .accessibilityLabel(AppCopy.text("conversation.translate"))
                    }
                    Text(message.date, style: .time).foregroundStyle(.secondary)
                    if isUser {
                        HStack(spacing: -5) {
                            Image(systemName: "checkmark")
                            if message.delivered { Image(systemName: "checkmark") }
                        }
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(message.delivered ? Color.blue : Color.secondary)
                        .accessibilityElement()
                        .accessibilityLabel(
                            AppCopy.text(message.delivered ? "bots.status.delivered" : "bots.status.waiting")
                        )
                    }
                }
                .font(.system(size: 10))
            }
        }
    }
}

/// The bot chat's composer, laid out like the conversation composer: the editor on top,
/// then attach and dictate on the leading side and model, effort and send on the trailing one.
private struct BotComposer: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: BotStore
    @ObservedObject private var router: RouterController
    let bot: Bot
    let isBusy: Bool
    @Binding var draft: String
    @StateObject private var voiceInput: LiveVoiceInput
    @State private var attachments: [URL] = []
    @State private var editorTextWidth: CGFloat = 0

    init(model: AppModel, store: BotStore, bot: Bot, isBusy: Bool, draft: Binding<String>) {
        self.model = model
        self.store = store
        self.router = model.router
        self.bot = bot
        self.isBusy = isBusy
        self._draft = draft
        self._voiceInput = StateObject(
            wrappedValue: LiveVoiceInput(model: model) { text in
                let separator = draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : "\n"
                draft.wrappedValue += separator + text
            }
        )
    }

    private var canSubmit: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
    }

    private var effortLabel: String {
        let modelID = bot.modelID.isEmpty ? router.selectedModelID : bot.modelID
        let levels = modelID == ModelRouter.autoModelID ? router.automaticEffortOptions : router.efforts(for: modelID)
        return levels.contains(bot.effort) ? ModelPickerPopover.effortLabel(bot.effort) : ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !attachments.isEmpty { attachmentChips }
            ZStack(alignment: .topLeading) {
                PromptTextEditor(
                    text: $draft,
                    isEnabled: true,
                    onSubmit: { _ in send() },
                    onAcceptSlashCommand: { false },
                    onMoveSlashCommand: { _ in false },
                    followUpSuggestion: nil
                )
                .frame(height: composerEditorHeight(for: draft, width: editorTextWidth))
                .padding(.horizontal, 9)
                .padding(.top, 5)
                if draft.isEmpty {
                    Text(AppCopy.format("bots.placeholder", bot.name))
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.horizontal, 14)
                        .padding(.top, 13)
                        .allowsHitTesting(false)
                }
            }
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: ComposerEditorWidthKey.self,
                        value: max(1, proxy.size.width - 28)
                    )
                }
            }
            VoiceTranscriptPreview(text: voiceInput.transcript)
            controls
        }
        .onPreferenceChange(ComposerEditorWidthKey.self) { width in
            guard width > 0 else { return }
            editorTextWidth = width
        }
        .composerOutline()
        .frame(maxWidth: 760)
        .padding(.horizontal, 18)
        .padding(.bottom, 14)
    }

    private var controls: some View {
        HStack(spacing: 9) {
            ComposerAddButton(rows: [
                .init(icon: "paperclip", title: AppCopy.text("attachment.files"), shortcut: "⌘U") { chooseFiles() },
                .init(icon: "folder", title: AppCopy.text("attachment.folder")) { chooseFiles(folders: true) }
            ], onShortcut: { chooseFiles() })

            ComposerVoiceButton(model: model, voiceInput: voiceInput)

            Spacer(minLength: 0)

            Menu {
                ChatModelMenu(router: router, modelID: binding(\.modelID))
                BotEffortMenu(router: router, modelID: bot.modelID, effort: binding(\.effort))
            } label: {
                ComposerModelLabel(
                    name: bot.modelID.isEmpty ? AppCopy.text("models.followApp") : router.modelLabel(forID: bot.modelID),
                    effort: effortLabel
                )
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .layoutPriority(-1)
            .help(AppCopy.text("studio.settings.model"))

            if isBusy {
                HerNessLoadingAnimation(size: 18)
            }
            if isBusy, !canSubmit {
                ComposerRoundButton(icon: "stop.fill", label: AppCopy.text("common.stop")) { store.stop(bot.id) }
            } else {
                ComposerRoundButton(icon: "arrow.up", size: 14, label: AppCopy.text("bots.send"), action: send)
                    .disabled(!canSubmit)
                    .opacity(canSubmit ? 1 : 0.7)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 10)
    }

    private var attachmentChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(attachments, id: \.self) { url in
                    HStack(spacing: 5) {
                        Image(systemName: "paperclip").font(.caption)
                        Text(url.lastPathComponent).font(.callout).lineLimit(1)
                        Button { attachments.removeAll { $0 == url } } label: {
                            Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(AppCopy.text("common.remove"))
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Color.primary.opacity(0.08), in: Capsule())
                    .help(url.path)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
        }
    }

    private func binding(_ keyPath: WritableKeyPath<Bot, String>) -> Binding<String> {
        Binding(
            get: { bot[keyPath: keyPath] },
            set: { value in
                var changed = bot
                changed[keyPath: keyPath] = value
                store.upsert(changed)
            }
        )
    }

    private func chooseFiles(folders: Bool = false) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = !folders
        panel.canChooseDirectories = folders
        panel.allowsMultipleSelection = true
        panel.prompt = AppCopy.text("composer.add")
        guard panel.runModal() == .OK else { return }
        attachments += panel.urls.filter { !attachments.contains($0) }
    }

    private func send() {
        guard canSubmit else { return }
        // ponytail: bot messages are text only, so files go as paths. A bot with a workspace
        // reads them with its tools; add real attachments to BotMessage if chat-only bots need them.
        let text = ([draft] + attachments.map(\.path)).joined(separator: "\n")
        store.send(text, to: bot.id)
        draft = ""
        attachments = []
    }
}

private struct BotAvatar: View {
    let symbol: String
    let imageURL: URL?
    let size: CGFloat

    var body: some View {
        Group {
            if let imageURL, let image = ImageFileCache.image(at: imageURL) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: symbol)
                    .resizable()
                    .scaledToFit()
                    .padding(size * 0.25)
                    .foregroundStyle(Color.accentColor)
            }
        }
        .frame(width: size, height: size)
        .background(Color.accentColor.opacity(0.12), in: Circle())
        .clipShape(Circle())
    }
}

private struct BotEditor: View {
    @ObservedObject var model: AppModel
    @State var bot: Bot
    let onSave: (Bot, URL?, Bool) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var chosenImageURL: URL?
    @State private var clearsImage = false
    @State private var saveError: String?

    private var previewImageURL: URL? {
        if clearsImage { return nil }
        if let chosenImageURL { return chosenImageURL }
        return bot.imagePath.map { URL(fileURLWithPath: $0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField(AppCopy.text("bots.name"), text: $bot.name)
                    LabeledContent(AppCopy.text("media.image")) {
                        HStack(spacing: 8) {
                            BotAvatar(symbol: bot.symbol, imageURL: previewImageURL, size: 40)
                            Button {
                                chooseImage()
                            } label: {
                                Label(AppCopy.text("composer.add"), systemImage: "photo")
                            }
                            if previewImageURL != nil {
                                Button(AppCopy.text("common.remove")) {
                                    chosenImageURL = nil
                                    clearsImage = true
                                }
                            }
                        }
                    }
                    LabeledContent(AppCopy.text("bots.icon")) {
                        HStack(spacing: 4) {
                            ForEach(Bot.symbols, id: \.self) { symbol in
                                Button { bot.symbol = symbol } label: {
                                    Image(systemName: symbol)
                                        .frame(width: 26, height: 26)
                                        .background(
                                            Color.primary.opacity(bot.symbol == symbol ? 0.14 : 0),
                                            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        )
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(symbol)
                            }
                        }
                    }
                    LabeledContent(AppCopy.text("studio.settings.model")) {
                        ChatModelMenu(router: model.router, modelID: $bot.modelID).fixedSize()
                    }
                    BotEffortMenu(router: model.router, modelID: bot.modelID, effort: $bot.effort)
                }
                Section(AppCopy.text("bots.instructions")) {
                    TextEditor(text: $bot.instructions)
                        .font(.system(size: 12))
                        .frame(height: 130)
                    Text(AppCopy.text("bots.instructionsHelp")).font(.caption).foregroundStyle(.secondary)
                }
                Section(AppCopy.text("bots.workspace")) {
                    HStack {
                        Text(bot.workspacePath.isEmpty ? AppCopy.text("bots.workspace.none") : bot.workspacePath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(bot.workspacePath.isEmpty ? .secondary : .primary)
                        Spacer()
                        if !bot.workspacePath.isEmpty {
                            Button(AppCopy.text("bots.workspace.clear")) { bot.workspacePath = "" }
                        }
                        Button(AppCopy.text("bots.workspace.choose"), action: chooseFolder)
                    }
                    Text(AppCopy.text("bots.workspaceHelp")).font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            if let saveError {
                Text(saveError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
            }

            Divider()
            HStack {
                Spacer()
                Button(AppCopy.text("common.cancel"), role: .cancel) { dismiss() }
                Button(AppCopy.text("common.save")) {
                    bot.name = bot.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    do {
                        try onSave(bot, chosenImageURL, clearsImage)
                        dismiss()
                    } catch {
                        saveError = error.localizedDescription
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(bot.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(12)
        }
        .frame(width: 500, height: 600)
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = AppCopy.text("composer.add")
        guard panel.runModal() == .OK, let image = panel.url else { return }
        chosenImageURL = image
        clearsImage = false
        saveError = nil
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        bot.workspacePath = url.path
    }
}

/// Effort levels the bot's model accepts; the empty first stop leaves it to the app.
private struct BotEffortMenu: View {
    @ObservedObject var router: RouterController
    let modelID: String
    @Binding var effort: String

    private var levels: [String] {
        let model = modelID.isEmpty ? router.selectedModelID : modelID
        return model == ModelRouter.autoModelID ? router.automaticEffortOptions : router.efforts(for: model)
    }

    var body: some View {
        let levels = levels
        // A level kept from another model shows as the default, which is what the request does with it.
        Picker(AppCopy.text("modelPicker.effort"), selection: Binding(
            get: { levels.contains(effort) ? effort : "" },
            set: { effort = $0 }
        )) {
            Text(ModelPickerPopover.effortLabel("")).tag("")
            ForEach(levels, id: \.self) { Text(ModelPickerPopover.effortLabel($0)).tag($0) }
        }
        .disabled(levels.isEmpty)
        .help(AppCopy.text("modelPicker.effort"))
    }
}

/// Message text sized to its content: plain lines hug the text like a chat bubble,
/// and block markdown (code, lists, tables, headings) gets the full renderer.
private struct BotMessageText: View {
    let text: String
    var caches = true

    private var hasBlocks: Bool {
        text.split(separator: "\n").contains { line in
            let line = line.drop { $0 == " " }
            return ["```", "#", "|", ">", "- ", "* ", "+ "].contains { line.hasPrefix($0) }
                || line.prefix { $0.isNumber }.count > 0 && line.drop { $0.isNumber }.hasPrefix(". ")
        }
    }

    var body: some View {
        if hasBlocks {
            PlanMarkdownView(text: text, caches: caches).textSelection(.enabled)
        } else {
            Text((try? AttributedString(
                markdown: text,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            )) ?? AttributedString(text))
                .lineSpacing(3)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A rounded bubble whose top corner on the sender's side can run out into a tail.
/// The tail is drawn outside the bubble's frame, so bubbles with and without one line up.
private struct BubbleShape: Shape {
    var hasTail: Bool
    var isTrailing: Bool

    func path(in rect: CGRect) -> Path {
        let radius = min(14, rect.height / 2)
        let body = Path(roundedRect: rect, cornerRadius: radius, style: .continuous)
        guard hasTail else { return body }
        let edge = isTrailing ? rect.maxX : rect.minX
        let out: CGFloat = isTrailing ? 1 : -1
        var tail = Path()
        tail.move(to: CGPoint(x: edge - out * radius, y: rect.minY))
        tail.addLine(to: CGPoint(x: edge + out * 7, y: rect.minY))
        tail.addQuadCurve(
            to: CGPoint(x: edge, y: rect.minY + 11),
            control: CGPoint(x: edge + out * 1.5, y: rect.minY + 2)
        )
        tail.addLine(to: CGPoint(x: edge - out * radius, y: rect.minY + radius))
        tail.closeSubpath()
        return body.union(tail)
    }
}

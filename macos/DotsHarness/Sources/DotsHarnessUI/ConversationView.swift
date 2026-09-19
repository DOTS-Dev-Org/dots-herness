// Copyright (c) 2026 DOTS
// Native conversation surface.

import AppKit
import AVFoundation
import AVKit
import SwiftUI
import UniformTypeIdentifiers
import DotsHarnessCore
import HarnessPluginKit

struct ConversationView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var speech: LocalSpeechSynthesizer
    @ObservedObject private var terminalManager: TerminalManager
    @Binding private var isPanePickerVisible: Bool

    @State private var isTerminalVisible = false
    @State private var isNewPaneMenuPresented = false
    @State private var isDropTargeted = false
    @State private var draggedPromptID: String?
    @State private var expandedActivityIDs = Set<String>()
    @State private var expandedFileMessageIDs = Set<String>()
    @State private var expandedUsedMessageIDs = Set<String>()
    @State private var hoveredMessageID: String?
    /// Long chats render the newest page first; older pages load as the user
    /// scrolls up. UI only: the agent always reads the full conversation.
    /// nil = follow the newest page; set once the user pages back, so new
    /// messages never shift what they are reading.
    @State private var pagedStartIndex: Int?
    private static let messagePageSize = 10

    private var bridge: AgentBridge { model.bridge }

    init(model: AppModel, isPanePickerVisible: Binding<Bool>) {
        self.model = model
        self._speech = ObservedObject(wrappedValue: model.speech)
        self._terminalManager = ObservedObject(wrappedValue: model.terminalManager)
        self._isPanePickerVisible = isPanePickerVisible
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                if isTerminalVisible {
                    VSplitView {
                        chatAndComposer
                        terminalPanel
                            .frame(minHeight: 180, idealHeight: 270, maxHeight: 440)
                    }
                } else {
                    chatAndComposer
                }
            }
            if isPanePickerVisible {
                Divider()
                panePickerSurface
            }
        }
        .onChange(of: model.selected?.id) { _, id in
            model.feedbackRequest = nil
            if id != nil {
                isPanePickerVisible = false
            }
        }
        .onChange(of: model.workspacePath) { _, path in
            model.feedbackRequest = nil
            if path.isEmpty {
                isTerminalVisible = false
            }
        }
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isDropTargeted, perform: handleDrop)
        .sheet(item: $model.feedbackRequest) { target in
            FeedbackSheet(
                target: target,
                existing: bridge.feedback(for: target.messageID, in: target.conversationID)
            ) { feedbackType, tags, comment in
                try bridge.submitFeedback(
                    conversationID: target.conversationID,
                    messageID: target.messageID,
                    feedbackType: feedbackType,
                    tags: tags,
                    userComment: comment
                )
            }
        }
    }

    private var chatAndComposer: some View {
        VStack(spacing: 0) {
            chatSurface
            composer
        }
    }

    private var chatSurface: some View {
        ZStack {
            Group {
                if let conversation = model.selected {
                    if !conversation.contentLoaded {
                        // Title is shown; the transcript is still decoding off the main thread.
                        ProgressView()
                            .controlSize(.small)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if conversation.messages.isEmpty,
                       !conversation.running,
                       conversation.continuation == nil,
                       conversation.pendingPrompts.isEmpty {
                        emptyConversation
                    } else {
                        conversationBody(conversation)
                    }
                } else {
                    emptyConversation
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func conversationBody(_ conversation: Conversation) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    if let continuation = conversation.continuation {
                        continuationCard(continuation)
                            .id("continuation-\(conversation.id)")
                    }
                    if conversation.running, conversation.runStartedAt != nil {
                        liveActivityHeader(conversation)
                    }
                    let firstVisible = firstVisibleMessageIndex(in: conversation.messages)
                    if firstVisible > 0 {
                        ProgressView()
                            .controlSize(.small)
                            .frame(maxWidth: .infinity)
                            .onAppear { loadOlderMessages(conversation, firstVisible: firstVisible, proxy: proxy) }
                    }
                    ForEach(Array(conversation.messages.enumerated().dropFirst(firstVisible)), id: \.element.id) { index, message in
                        if message.id == conversation.messages.last?.id {
                            ForEach(conversation.pendingPrompts) { prompt in
                                pendingPromptBubble(prompt, in: conversation)
                            }
                            if conversation.pendingPrompts.contains(where: { $0.mode == .queue }) {
                                Rectangle()
                                    .fill(.clear)
                                    .frame(height: 16)
                                    .contentShape(Rectangle())
                                    .onDrop(
                                        of: [UTType.text],
                                        delegate: PendingPromptDropDelegate(
                                            draggedPromptID: $draggedPromptID,
                                            targetPromptID: nil,
                                            conversationID: conversation.id,
                                            bridge: bridge
                                        )
                                    )
                            }
                        }
                        if message.kind == .tool {
                            if index == 0 || conversation.messages[index - 1].kind != .tool {
                                let endIndex = activityEndIndex(startingAt: index, in: conversation.messages)
                                let metadata = activityMetadata(
                                    for: message.turnID,
                                    in: conversation.messages
                                )
                                activitySummary(
                                    messages: conversation.messages[index..<endIndex],
                                    completedAt: endIndex < conversation.messages.count
                                        ? conversation.messages[endIndex].createdAt
                                        : nil,
                                    isRunning: conversation.running && endIndex == conversation.messages.count,
                                    usedSkills: metadata.skills
                                )
                                .id("activity-\(message.id)")
                            }
                        } else {
                            messageBubble(message, in: conversation)
                                .id(message.id)
                        }
                    }
                }
                .frame(maxWidth: 820)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 28)
                .padding(.vertical, 28)
            }
            .defaultScrollAnchor(.bottom)
            .background(Color(nsColor: .windowBackgroundColor))
            .onAppear {
                scrollToLast(using: proxy, conversation: conversation)
            }
            .onChange(of: conversation.id) { _, _ in
                pagedStartIndex = nil
                scrollToLast(using: proxy, conversation: conversation)
            }
            .onChange(of: conversation.messages.count) { _, _ in
                scrollToLast(using: proxy, conversation: conversation)
            }
            .onChange(of: conversation.messages.last?.text) { _, _ in
                scrollToLast(using: proxy, conversation: conversation)
            }
            .onChange(of: conversation.pendingPrompts.count) { _, _ in
                scrollToLast(using: proxy, conversation: conversation)
            }
        }
    }

    private func continuationCard(_ continuation: ContinuationState) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(
                continuation.reason == .providerLimit
                    ? AppCopy.text("agent.providerLimitTitle")
                    : AppCopy.text("agent.userStoppedTitle"),
                systemImage: continuation.reason == .providerLimit ? "exclamationmark.circle" : "pause.circle"
            )
            .font(.callout.weight(.semibold))
            .foregroundStyle(continuation.reason == .providerLimit ? Color.red : Color.orange)
            Text(continuation.message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            HStack {
                Spacer(minLength: 0)
                Button(AppCopy.text("agent.continue")) {
                    let hasDraft = !model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.draftAttachments.isEmpty
                    if hasDraft { model.send(mode: .queue) } else { model.continueCurrentRun() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(bridge.isBusy || !bridge.isReady)
            }
        }
        .padding(16)
        .frame(maxWidth: 760, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.red.opacity(0.35), lineWidth: 1)
        }
    }

    @ViewBuilder
    private var emptyConversation: some View {
        WelcomeView(
            projectName: workspaceName,
            showConnectHint: bridge.connectionResolved && bridge.connection == nil,
            showCards: model.draft.isEmpty,
            cards: welcomeCards,
            onSelect: runWelcomeCard
        )
    }

    private var welcomeCards: [WelcomeCard] {
        WelcomeCatalog.cards(
            projectName: workspaceName,
            stack: ProjectStackSniffer.detect(at: model.workspacePath)
        )
    }

    private func runWelcomeCard(_ card: WelcomeCard) {
        // The empty state also renders when model.selected == nil; draft
        // persistence needs a selected conversation.
        if model.selectedConversationID == nil {
            model.newConversation()
        }
        model.fillComposer(with: card.prompt)
    }

    private var panePickerSurface: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            panePicker()
            Spacer(minLength: 0)
        }
        .frame(width: 320)
        .frame(maxHeight: .infinity)
        .padding(.horizontal, 20)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func panePicker(createTerminal: Bool = false) -> some View {
        VStack(spacing: 8) {
            paneRow(.review, "plusminus.circle") { openReview() }
            paneRow(.terminal, "terminal", disabled: model.terminalWorkspaceKey.isEmpty) {
                openTerminal(createNew: createTerminal)
            }
            paneRow(.browser, "globe") { openBrowser() }
            if model.activeArea == .coding {
                paneRow(.files, "folder") { openFiles() }
            }
            paneRow(.sideChat, "plus.bubble") {
                isPanePickerVisible = false
                model.newConversation()
            }
            paneRow(.simulator, "iphone.gen3") {
                isPanePickerVisible = false
                model.isSimulatorPresented = true
            }
        }
    }

    private func paneRow(
        _ action: KeyboardShortcutAction,
        _ image: String,
        disabled: Bool = false,
        perform: @escaping () -> Void
    ) -> some View {
        PaneChoiceRow(
            systemImage: image,
            title: action.title,
            shortcut: model.shortcut(for: action).displayValue,
            action: perform
        )
        .keyboardShortcut(model.shortcut(for: action).swiftUIShortcut)
        .disabled(disabled)
    }

    private func openReview() {
        isPanePickerVisible = false
        if model.selectedConversationID == nil { model.newConversation() }
        model.fillComposer(with: AppCopy.format("welcome.card.review.prompt", projectNameForReview))
    }

    private var projectNameForReview: String {
        let name = URL(fileURLWithPath: model.workspacePath).lastPathComponent
        return name.isEmpty ? "the workspace" : name
    }

    private var terminalPanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                HStack(spacing: 7) {
                    Image(systemName: "terminal")
                        .font(.caption2.weight(.semibold))
                    Text(workspaceName)
                        .font(.caption)
                        .lineLimit(1)
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(
                    Color.primary.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )

                Button {
                    isNewPaneMenuPresented.toggle()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .help(AppCopy.text("conversation.newPane"))
                .popover(isPresented: $isNewPaneMenuPresented, arrowEdge: .top) {
                    panePicker(createTerminal: true)
                        .frame(width: 276)
                        .padding(4)
                }

                Spacer(minLength: 0)

                Button {
                    closeTerminal()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .medium))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(AppCopy.text("conversation.closeTerminal"))
            }
            .padding(.horizontal, 8)
            .frame(height: 34)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            if let session = selectedTerminal {
                VStack(spacing: 0) {
                    terminalTabs
                    Divider()
                    TerminalView(session: session)
                }
            } else {
                Text(AppCopy.text("conversation.startingShell"))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(14)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var terminalTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(terminalSessions.enumerated()), id: \.element.id) { index, session in
                    let selected = session.id == selectedTerminal?.id
                    HStack(spacing: 0) {
                        Button {
                            terminalManager.selectSession(session.id, for: model.terminalWorkspaceKey)
                        } label: {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(session.isRunning ? Color.green : Color.secondary)
                                    .frame(width: 6, height: 6)
                                Text("#\(index + 1)")
                                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                            }
                            .padding(.leading, 9)
                            .padding(.trailing, 6)
                            .frame(height: 26)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        Button {
                            terminalManager.closeSession(session, for: model.terminalWorkspaceKey)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .semibold))
                                .frame(width: 22, height: 26)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help(AppCopy.text("conversation.closeTerminal"))
                    }
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                    .background(
                        selected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                    )
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
        .frame(height: 34)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var composer: some View {
        ChatComposer(model: model, bridge: bridge)
    }

    private var workspaceName: String {
        let path = model.activeArea == .chat ? model.terminalWorkspaceKey : model.workspacePath
        guard !path.isEmpty else { return AppCopy.text("conversation.workspace") }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    private var terminalSessions: [TerminalSession] {
        terminalManager.sessions(for: model.terminalWorkspaceKey)
    }

    private var selectedTerminal: TerminalSession? {
        terminalManager.selectedSession(for: model.terminalWorkspaceKey)
    }

    @ViewBuilder
    private func messageBubble(_ message: ChatMessage, in conversation: Conversation) -> some View {
        if message.kind == .plan {
            planCard(message, in: conversation)
        } else {
            standardMessageBubble(message, in: conversation)
        }
    }

    private func planCard(_ message: ChatMessage, in conversation: Conversation) -> some View {
        let isPending = conversation.pendingPlanMessageID == message.id
        return HStack {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "lightbulb.fill")
                        .foregroundStyle(Color.orange)
                    Text(AppCopy.text("plan.title"))
                        .font(.callout.weight(.semibold))
                    Spacer(minLength: 0)
                    Text(planStatus(message, isPending: isPending, isRunning: conversation.running))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                PlanMarkdownView(text: message.text)
                    .textSelection(.enabled)
                usedItemsDisclosure(for: message)
                runSummaryView(for: message)
                changedFilesDisclosure(for: message)
                messageActions(message, in: conversation)
                if isPending {
                    HStack {
                        Spacer(minLength: 0)
                        Button {
                            model.applyPlan()
                        } label: {
                            Label(AppCopy.text("plan.apply"), systemImage: "checkmark.circle.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(conversation.running || !bridge.isReady)
                        .help(AppCopy.text("plan.applyHelp"))
                        .accessibilityLabel(AppCopy.text("plan.applyHelp"))
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.accentColor.opacity(0.25), lineWidth: 1)
            }
            .frame(maxWidth: 760, alignment: .leading)
            .onHover { hovered in
                hoveredMessageID = hovered ? message.id : nil
            }
            Spacer(minLength: 80)
        }
    }

    private func planStatus(_ message: ChatMessage, isPending: Bool, isRunning: Bool) -> String {
        if let error = message.planError, !error.isEmpty { return "Error · " + error }
        if !isPending { return AppCopy.text("plan.applied") }
        return isRunning ? AppCopy.text("plan.applying") : AppCopy.text("plan.waitingApproval")
    }

    private func standardMessageBubble(_ message: ChatMessage, in conversation: Conversation) -> some View {
        let isUser = message.kind == .user
        let isAssistant = message.kind == .assistant
        return HStack {
            VStack(alignment: .leading, spacing: 7) {
                if isAssistant {
                    HStack(spacing: 8) {
                        if message.streaming {
                            ProgressView().controlSize(.small)
                            Text(AppCopy.text("conversation.working"))
                        } else {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Color.blue)
                            Text(AppCopy.text("conversation.completed"))
                                .font(.callout.weight(.medium))
                        }
                    }
                    .foregroundStyle(.primary)
                } else if message.kind == .system {
                    HStack(spacing: 7) {
                        Image(systemName: icon(for: message.kind))
                            .font(.caption.weight(.semibold))
                        Text(label(for: message.kind))
                            .font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(.secondary)
                }
                if !message.text.isEmpty {
                    Text(message.text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .font(message.kind == .tool ? .callout.monospaced() : .body)
                }
                contextRootIndicators(for: message)
                usedItemsDisclosure(for: message)
                runSummaryView(for: message)
                changedFilesDisclosure(for: message)
                if !message.attachments.isEmpty {
                    attachmentViews(message.attachments)
                }
                if !message.mediaItems.isEmpty {
                    ForEach(message.mediaItems) { media in
                        mediaView(media)
                    }
                }
                messageActions(message, in: conversation)
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onHover { hovered in
                hoveredMessageID = hovered ? message.id : nil
            }
        }
    }

    @ViewBuilder
    private func messageActions(_ message: ChatMessage, in conversation: Conversation) -> some View {
        if message.kind == .user || message.kind == .assistant || message.kind == .plan, !message.streaming {
            let latestUser = conversation.messages.last(where: { $0.kind == .user })?.id == message.id
            let canEdit = latestUser && bridge.canEdit(messageID: message.id, in: conversation.id)
            let canRewind = message.kind == .user && bridge.canRewind(messageID: message.id, in: conversation.id)
            let hasText = !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let hasOutput = hasText || !message.mediaItems.isEmpty
            let speaking = speech.activeMessageID == message.id
            let canFeedback = bridge.workspacePath?.isEmpty == false && message.kind != .user && hasOutput
            let feedback = canFeedback ? bridge.feedback(for: message.id, in: conversation.id) : nil
            HStack(spacing: 16) {
                actionButton("doc.on.doc", AppCopy.text("conversation.copy")) { copyMessage(message) }

                if message.kind == .user, latestUser {
                    actionButton("pencil", actionHelp("conversation.edit", available: canEdit)) {
                        model.beginEditing(message)
                    }
                    .disabled(!canEdit)
                }
                if message.kind == .user {
                    actionButton("arrow.uturn.backward", actionHelp("conversation.rewind", available: canRewind)) {
                        model.rewind(messageID: message.id)
                    }
                    .disabled(!canRewind)
                }
                if message.kind == .assistant, hasText {
                    let title = speaking
                        ? AppCopy.text("conversation.stopSpeaking")
                        : "\(AppCopy.text("conversation.speakResponse")) (AI)"
                    actionButton(speaking ? "stop.circle.fill" : "speaker.wave.2", title) {
                        model.toggleSpeech(message.text, messageID: message.id)
                    }
                }
                if canFeedback {
                    feedbackButton(type: .good, selected: feedback?.feedbackType == .good, message: message, conversation: conversation)
                    feedbackButton(type: .bad, selected: feedback?.feedbackType == .bad, message: message, conversation: conversation)
                }
                messageTimestamp(message.createdAt)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.top, 2)
            .opacity(hoveredMessageID == message.id ? 1 : 0.55)
        }
    }

    private func actionButton(_ icon: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon) }
            .buttonStyle(.plain)
            .accessibilityLabel(help)
            .help(help)
    }

    private func actionHelp(_ key: String, available: Bool) -> String {
        if available { return AppCopy.text(key) }
        if bridge.anyRunBusy || bridge.historyMutationBusy {
            return AppCopy.text("conversation.historyBusy")
        }
        return AppCopy.text("conversation.historyUnavailable")
    }

    private func feedbackButton(
        type: FeedbackType,
        selected: Bool,
        message: ChatMessage,
        conversation: Conversation
    ) -> some View {
        let title = type == .good ? AppCopy.text("feedback.good") : AppCopy.text("feedback.bad")
        return Button {
            model.feedbackRequest = FeedbackTarget(
                conversationID: conversation.id,
                messageID: message.id,
                feedbackType: type
            )
        } label: {
            Image(systemName: type == .good
                ? (selected ? "hand.thumbsup.fill" : "hand.thumbsup")
                : (selected ? "hand.thumbsdown.fill" : "hand.thumbsdown"))
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? Color.accentColor : Color.secondary)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func copyMessage(_ message: ChatMessage) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message.text, forType: .string)
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()

    private func messageTimestamp(_ date: Date) -> some View {
        Text(Self.relativeFormatter.localizedString(for: date, relativeTo: .now))
            .font(.callout)
            .help(date.formatted(date: .complete, time: .complete))
            .accessibilityLabel(date.formatted(date: .complete, time: .complete))
    }

    @ViewBuilder
    private func contextRootIndicators(for message: ChatMessage) -> some View {
        let roots = message.contextRootIDs.compactMap { id in
            bridge.chatContextRoots.first(where: { $0.id == id })
        }
        if !roots.isEmpty {
            HStack(spacing: 5) {
                Image(systemName: "paperclip")
                Text(roots.map { URL(fileURLWithPath: $0.path).lastPathComponent }.joined(separator: " · "))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .help(roots.map(\.path).joined(separator: "\n"))
        }
    }

    private func liveActivityHeader(_ conversation: Conversation) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let skills = bridge.activeUsedSkillIDs
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(AppCopy.format("conversation.workingFor", elapsedText(from: conversation.runStartedAt, now: context.date)))
                if !skills.isEmpty {
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text(AppCopy.format("conversation.using", skills.joined(separator: ", ")))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                skills.isEmpty
                    ? AppCopy.format("conversation.workingFor", elapsedText(from: conversation.runStartedAt, now: context.date))
                    : AppCopy.format(
                        "conversation.workingUsing",
                        elapsedText(from: conversation.runStartedAt, now: context.date),
                        skills.joined(separator: ", ")
                    )
            )
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
        }
    }

    private func elapsedText(from start: Date?, now: Date = .now) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start ?? now)))
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        let remainder = seconds % 60
        if minutes < 60 { return "\(minutes)m \(String(format: "%02ds", remainder))" }
        let hours = minutes / 60
        return "\(hours)h \(String(format: "%02dm", minutes % 60))"
    }

    @ViewBuilder
    private func usedItemsDisclosure(for message: ChatMessage) -> some View {
        if !message.usedSkills.isEmpty || !message.usedTools.isEmpty {
            DisclosureGroup(isExpanded: usedItemsBinding(for: message.id)) {
                VStack(alignment: .leading, spacing: 7) {
                    if !message.usedSkills.isEmpty {
                        Text(AppCopy.text("conversation.skills"))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(message.usedSkills.joined(separator: ", "))
                            .font(.callout.monospaced())
                            .lineLimit(3)
                            .truncationMode(.middle)
                    }
                    if !message.usedTools.isEmpty {
                        Text(AppCopy.text("conversation.tools"))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(message.usedTools.joined(separator: ", "))
                            .font(.callout.monospaced())
                            .lineLimit(3)
                            .truncationMode(.middle)
                    }
                }
                .padding(.top, 5)
            } label: {
                Label(AppCopy.text("conversation.used"), systemImage: "bolt.horizontal.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel(AppCopy.text("conversation.used"))
        }
    }

    private func usedItemsBinding(for id: String) -> Binding<Bool> {
        Binding(
            get: { expandedUsedMessageIDs.contains(id) },
            set: { expanded in
                if expanded { expandedUsedMessageIDs.insert(id) }
                else { expandedUsedMessageIDs.remove(id) }
            }
        )
    }

    @ViewBuilder
    private func runSummaryView(for message: ChatMessage) -> some View {
        if let summary = message.summary {
            VStack(alignment: .leading, spacing: 3) {
                Label(AppCopy.text("conversation.runSummary"), systemImage: "checkmark.shield")
                    .font(.caption.weight(.semibold))
                Text(AppCopy.format(
                    "conversation.filesSummary",
                    summary.addedCount,
                    summary.modifiedCount,
                    summary.deletedCount
                ) + " · " + summary.cleanupNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .padding(.top, 2)
            .accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder
    private func changedFilesDisclosure(for message: ChatMessage) -> some View {
        if !message.changedFiles.isEmpty {
            DisclosureGroup(
                isExpanded: changedFilesBinding(for: message.id)
            ) {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(message.changedFiles) { file in
                        changedFileRow(file)
                    }
                }
                .padding(.top, 5)
            } label: {
                Label(
                    AppCopy.format("conversation.updatedFiles", message.changedFiles.count),
                    systemImage: "doc.on.doc"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func changedFileRow(_ file: ChangedFile) -> some View {
        let url = workspaceURL(for: file.path)
        let isAvailable = file.operation != .deleted
            && url.map { FileManager.default.fileExists(atPath: $0.path) } == true
        let content = HStack(spacing: 8) {
            Image(systemName: fileIcon(for: file.operation))
                .foregroundStyle(fileColor(for: file.operation))
                .frame(width: 17)
            Text(file.path)
                .font(.system(.callout, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }

        if let url, isAvailable {
            Button {
                NSWorkspace.shared.open(url)
            } label: {
                content
            }
            .buttonStyle(.plain)
            .help(AppCopy.text("conversation.openFile"))
            .accessibilityLabel(AppCopy.format("conversation.openFileNamed", file.path))
        } else {
            HStack(spacing: 8) {
                content
                Text(AppCopy.text("conversation.fileUnavailable"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func changedFilesBinding(for id: String) -> Binding<Bool> {
        Binding(
            get: { expandedFileMessageIDs.contains(id) },
            set: { expanded in
                if expanded {
                    expandedFileMessageIDs.insert(id)
                } else {
                    expandedFileMessageIDs.remove(id)
                }
            }
        )
    }

    private func workspaceURL(for relativePath: String) -> URL? {
        guard !model.workspacePath.isEmpty else { return nil }
        let workspace = URL(fileURLWithPath: model.workspacePath).standardizedFileURL
        let url = URL(fileURLWithPath: relativePath, relativeTo: workspace).standardizedFileURL
        guard url.path.hasPrefix(workspace.path + "/") else { return nil }
        return url
    }

    private func fileIcon(for operation: ChangedFile.Operation) -> String {
        switch operation {
        case .added: return "plus.circle"
        case .modified: return "pencil.circle"
        case .deleted: return "minus.circle"
        }
    }

    private func fileColor(for operation: ChangedFile.Operation) -> Color {
        switch operation {
        case .added: return .green
        case .modified: return .orange
        case .deleted: return .red
        }
    }

    @ViewBuilder
    private func activitySummary(
        messages: ArraySlice<ChatMessage>,
        completedAt: Date?,
        isRunning: Bool,
        usedSkills: [String]
    ) -> some View {
        if let activityID = messages.first?.id {
            DisclosureGroup(isExpanded: activityBinding(for: activityID)) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(messages)) { message in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(message.text)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            messageTimestamp(message.createdAt)
                        }
                        .padding(.vertical, 2)
                    }
                }
                .padding(.leading, 22)
                .padding(.top, 5)
            } label: {
                HStack(spacing: 8) {
                    if isRunning {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text(AppCopy.format("conversation.workingFor", elapsedText(from: bridge.activeRunStartedAt, now: context.date)))
                                if !bridge.activeUsedSkillIDs.isEmpty {
                                    Text("·").foregroundStyle(.tertiary)
                                    Text(AppCopy.format("conversation.using", bridge.activeUsedSkillIDs.joined(separator: ", ")))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                            }
                        }
                    } else {
                        Image(systemName: "clock")
                            .font(.caption.weight(.semibold))
                        Text(AppCopy.format(
                            "conversation.workedFor",
                            activityDuration(messages, completedAt: completedAt)
                        ))
                        if !usedSkills.isEmpty {
                            Text("·").foregroundStyle(.tertiary)
                            Text(AppCopy.format("conversation.using", usedSkills.joined(separator: ", ")))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .font(.callout)
            }
            .foregroundStyle(.secondary)
            .padding(.vertical, 6)
            .overlay(alignment: .bottom) {
                Divider()
            }
        }
    }

    private func activityBinding(for id: String) -> Binding<Bool> {
        Binding(
            get: { expandedActivityIDs.contains(id) },
            set: { expanded in
                if expanded {
                    expandedActivityIDs.insert(id)
                } else {
                    expandedActivityIDs.remove(id)
                }
            }
        )
    }

    private func activityEndIndex(startingAt index: Int, in messages: [ChatMessage]) -> Int {
        var end = index
        while end < messages.count, messages[end].kind == .tool {
            end += 1
        }
        return end
    }

    private func activityDuration(
        _ messages: ArraySlice<ChatMessage>,
        completedAt: Date?
    ) -> String {
        guard let first = messages.first, let last = messages.last else { return "0s" }
        let end = completedAt ?? last.createdAt
        let seconds = max(1, Int(end.timeIntervalSince(first.createdAt).rounded()))
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.zeroFormattingBehavior = .dropAll
        formatter.allowedUnits = seconds >= 3600
            ? [.hour, .minute]
            : seconds >= 60 ? [.minute, .second] : [.second]
        return formatter.string(from: TimeInterval(seconds)) ?? "\(seconds)s"
    }

    private func activityMetadata(
        for turnID: String?,
        in messages: [ChatMessage]
    ) -> (skills: [String], tools: [String]) {
        guard let turnID else { return ([], []) }
        for message in messages where message.turnID == turnID {
            if !message.usedSkills.isEmpty || !message.usedTools.isEmpty {
                return (message.usedSkills, message.usedTools)
            }
        }
        return ([], [])
    }

    @ViewBuilder
    private func mediaView(_ media: ChatMedia) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            switch media.kind {
            case .image:
                if let image = NSImage(contentsOf: media.url) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 620, maxHeight: 520)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                } else {
                    missingMediaView
                }
            case .video:
                if FileManager.default.fileExists(atPath: media.path) {
                    VideoPlayer(player: AVPlayer(url: media.url))
                        .frame(maxWidth: 620, minHeight: 260, maxHeight: 420)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                } else {
                    missingMediaView
                }
            case .audio:
                if FileManager.default.fileExists(atPath: media.path) {
                    InlineAudioPlayer(url: media.url)
                } else {
                    missingMediaView
                }
            }
            mediaActions(for: media)
        }
    }

    private var missingMediaView: some View {
        Label(AppCopy.text("media.fileMissing"), systemImage: "exclamationmark.triangle")
            .foregroundStyle(.secondary)
    }

    private func mediaActions(for media: ChatMedia) -> some View {
        HStack(spacing: 8) {
            Button {
                saveMedia(media)
            } label: {
                Label(AppCopy.text("media.save"), systemImage: "arrow.down.circle")
            }
            .buttonStyle(.bordered)
            .disabled(!FileManager.default.fileExists(atPath: media.path))

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([media.url])
            } label: {
                Label(AppCopy.text("media.showInFinder"), systemImage: "folder")
            }
            .buttonStyle(.bordered)
            .disabled(!FileManager.default.fileExists(atPath: media.path))
        }
        .controlSize(.small)
    }

    private func saveMedia(_ media: ChatMedia) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = media.url.lastPathComponent
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: media.url, to: destination)
        } catch {
            model.reportHistoryError(error.localizedDescription)
        }
    }

    @ViewBuilder
    private func attachmentViews(_ attachments: [ChatAttachment]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(attachments) { attachment in
                Button {
                    NSWorkspace.shared.open(attachment.url)
                } label: {
                    HStack(spacing: 8) {
                        if attachment.kind == .image, let image = NSImage(contentsOf: attachment.url) {
                            Image(nsImage: image)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 42, height: 42)
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        } else {
                            Image(systemName: attachment.kind.systemImageName)
                                .frame(width: 28, height: 28)
                                .foregroundStyle(.secondary)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(attachment.name)
                                .lineLimit(1)
                            Text(attachment.kind.rawValue.capitalized)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                guard let data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                Task { @MainActor in model.addDraftAttachments([url]) }
            }
        }
        return !providers.isEmpty
    }

    @ViewBuilder
    private func pendingPromptBubble(_ prompt: PendingPrompt, in conversation: Conversation) -> some View {
        if prompt.mode == .queue {
            pendingBubble(prompt, in: conversation)
                .contentShape(Rectangle())
                .onDrag {
                    draggedPromptID = prompt.id
                    return NSItemProvider(object: NSString(string: prompt.id))
                }
                .onDrop(
                    of: [UTType.text],
                    delegate: PendingPromptDropDelegate(
                        draggedPromptID: $draggedPromptID,
                        targetPromptID: prompt.id,
                        conversationID: conversation.id,
                        bridge: bridge
                    )
                )
                .id(prompt.id)
        } else {
            pendingBubble(prompt, in: conversation)
                .id(prompt.id)
        }
    }

    private func pendingBubble(_ prompt: PendingPrompt, in conversation: Conversation) -> some View {
        HStack {
            Spacer(minLength: 80)
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 7) {
                    Image(systemName: prompt.mode == .steer ? "bolt.fill" : "clock.fill")
                        .font(.caption.weight(.semibold))
                    if prompt.mode == .queue {
                        Image(systemName: "line.3.horizontal")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    Text(prompt.mode == .steer
                        ? AppCopy.text("conversation.priorityInstruction")
                        : AppCopy.text("conversation.queuedMessage"))
                        .font(.caption.weight(.semibold))
                    Text(prompt.mode == .steer
                        ? AppCopy.text("conversation.interrupting")
                        : AppCopy.text("conversation.waiting"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if prompt.mode == .queue {
                        Spacer(minLength: 8)
                        Button {
                            bridge.steerPendingPrompt(prompt.id, in: conversation.id)
                        } label: {
                            Label(AppCopy.text("conversation.steer"), systemImage: "arrow.turn.up.right")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .accessibilityLabel(AppCopy.text("conversation.steer"))
                        .help(AppCopy.text("conversation.steer"))
                    }
                }
                if !prompt.text.isEmpty {
                    Text(prompt.text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if !prompt.attachments.isEmpty {
                    attachmentViews(prompt.attachments)
                }
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 12)
            .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.accentColor.opacity(0.22), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
            }
            .frame(maxWidth: 600, alignment: .leading)
        }
    }

    /// Start of the rendered tail, moved back so a tool-activity group is never split.
    private func firstVisibleMessageIndex(in messages: [ChatMessage]) -> Int {
        var start = pagedStartIndex.map { min($0, max(0, messages.count - 1)) } ?? max(0, messages.count - Self.messagePageSize)
        while start > 0, messages[start].kind == .tool, messages[start - 1].kind == .tool {
            start -= 1
        }
        return start
    }

    private func loadOlderMessages(_ conversation: Conversation, firstVisible: Int, proxy: ScrollViewProxy) {
        let anchor = conversation.messages[firstVisible]
        let anchorID = anchor.kind == .tool ? "activity-\(anchor.id)" : anchor.id
        pagedStartIndex = max(0, firstVisible - Self.messagePageSize)
        // Keep the message the user was reading in place while older ones appear above it.
        DispatchQueue.main.async {
            proxy.scrollTo(anchorID, anchor: .top)
        }
    }

    private func scrollToLast(using proxy: ScrollViewProxy, conversation: Conversation) {
        guard let last = conversation.messages.last else { return }
        let targetID: String
        if last.kind == .tool {
            var start = conversation.messages.count - 1
            while start > 0, conversation.messages[start - 1].kind == .tool {
                start -= 1
            }
            targetID = "activity-\(conversation.messages[start].id)"
        } else {
            targetID = last.id
        }
        // dispatch next runloop so LazyVStack layout is committed before scrolling
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.18)) {
                proxy.scrollTo(targetID, anchor: .bottom)
            }
        }
    }

    private func label(for kind: ChatMessage.Kind) -> String {
        switch kind {
        case .user: return AppCopy.text("conversation.you")
        case .assistant: return AppCopy.text("conversation.assistant")
        case .plan: return AppCopy.text("plan.title")
        case .tool: return AppCopy.text("conversation.tool")
        case .system: return AppCopy.text("conversation.notice")
        }
    }

    private func icon(for kind: ChatMessage.Kind) -> String {
        switch kind {
        case .user: return "person.fill"
        case .assistant: return "sparkles"
        case .plan: return "lightbulb"
        case .tool: return "terminal"
        case .system: return "info.circle"
        }
    }


    private func openFiles() {
        isPanePickerVisible = false
        isNewPaneMenuPresented = false
        guard model.activeArea == .coding else { return }
        if model.workspacePath.isEmpty {
            model.chooseWorkspace()
        } else {
            model.revealWorkspace()
        }
    }

    private func openBrowser() {
        isPanePickerVisible = false
        isNewPaneMenuPresented = false
        guard let url = bridge.connection?.endpoint else { return }
        NSWorkspace.shared.open(url)
    }

    private func openTerminal(createNew: Bool) {
        isPanePickerVisible = false
        isNewPaneMenuPresented = false
        guard !model.terminalWorkspaceKey.isEmpty else {
            if model.isRemoteWorkLocation { return }
            model.chooseWorkspace()
            return
        }
        isTerminalVisible = true
        if createNew || terminalSessions.isEmpty {
            _ = terminalManager.openSession(
                for: model.terminalWorkspaceKey,
                executionPolicy: model.activeArea == .chat
                    ? model.chatTerminalExecutionPolicy
                    : (model.remoteWorkspace == nil ? model.sandboxExecutionPolicy : nil),
                remoteTarget: model.remoteWorkspace
            )
        }
    }

    private func closeTerminal() {
        isNewPaneMenuPresented = false
        isTerminalVisible = false
    }

}

private struct PlanMarkdownView: View {
    let text: String

    var body: some View {
        let lines = text.components(separatedBy: .newlines)
        let codeLines = codeLineIndices
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                lineView(line, isCode: codeLines.contains(index))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func lineView(_ line: String, isCode: Bool) -> some View {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if isCode {
            Text(line.isEmpty ? " " : line)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(Color.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        } else if trimmed.hasPrefix("### ") {
            Text(markdown(trimmed.dropFirst(4)))
                .font(.callout.weight(.semibold))
                .padding(.top, 3)
        } else if trimmed.hasPrefix("## ") {
            Text(markdown(trimmed.dropFirst(3)))
                .font(.body.weight(.semibold))
                .padding(.top, 5)
        } else if trimmed.hasPrefix("# ") {
            Text(markdown(trimmed.dropFirst(2)))
                .font(.title3.weight(.bold))
                .padding(.top, 4)
        } else if trimmed.hasPrefix("- [ ] ") || trimmed.hasPrefix("- [x] ") || trimmed.hasPrefix("- [X] ") {
            let checked = trimmed.dropFirst(3).first == "x" || trimmed.dropFirst(3).first == "X"
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: checked ? "checkmark.square.fill" : "square")
                    .foregroundStyle(checked ? Color.accentColor : .secondary)
                Text(markdown(trimmed.dropFirst(6)))
            }
        } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
            HStack(alignment: .top, spacing: 7) {
                Text("•")
                    .foregroundStyle(.secondary)
                Text(markdown(trimmed.dropFirst(2)))
            }
        } else if let item = numberedItem(trimmed) {
            HStack(alignment: .top, spacing: 7) {
                Text(item.number)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Text(markdown(item.text))
            }
        } else if trimmed.hasPrefix("```") {
            Text(line)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.tertiary)
        } else if line.isEmpty {
            Text(" ")
                .font(.caption)
        } else {
            Text(markdown(line))
        }
    }

    private func markdown<S: StringProtocol>(_ line: S) -> AttributedString {
        (try? AttributedString(
            markdown: String(line),
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(String(line))
    }

    private func numberedItem(_ line: String) -> (number: String, text: String)? {
        let characters = Array(line)
        var index = 0
        while index < characters.count, characters[index].isNumber { index += 1 }
        guard index > 0, index + 1 < characters.count,
              characters[index] == ".", characters[index + 1] == " " else { return nil }
        return (
            String(characters[..<(index + 1)]),
            String(characters[(index + 2)...])
        )
    }

    private var codeLineIndices: Set<Int> {
        var result = Set<Int>()
        var inCodeBlock = false
        for (index, line) in text.components(separatedBy: .newlines).enumerated() {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                result.insert(index)
                inCodeBlock.toggle()
            } else if inCodeBlock {
                result.insert(index)
            }
        }
        return result
    }
}

private struct PendingPromptDropDelegate: DropDelegate {
    @Binding var draggedPromptID: String?
    let targetPromptID: String?
    let conversationID: String
    let bridge: AgentBridge

    func dropEntered(info: DropInfo) {
        guard let draggedPromptID else { return }
        bridge.movePendingPrompt(
            draggedPromptID,
            relativeTo: targetPromptID,
            in: conversationID
        )
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedPromptID = nil
        return true
    }
}

struct PaneChoiceRow: View {
    let systemImage: String
    let title: String
    let shortcut: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 16)
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                Spacer(minLength: 16)
                Text(shortcut)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.primary.opacity(0.075), in: Capsule())
            }
            .padding(.horizontal, 10)
            .frame(height: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(PaneChoiceButtonStyle())
    }
}

private struct PaneChoiceButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                Color.primary.opacity(configuration.isPressed ? 0.12 : 0.06),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .opacity(configuration.isPressed ? 0.82 : 1)
    }
}

/// Claude-Code-style new-chat welcome: app icon + project-aware heading + a 2x2
/// grid of action cards. Selecting a card fills the composer draft (never sends).
private struct WelcomeView: View {
    let projectName: String
    let showConnectHint: Bool
    let showCards: Bool
    let cards: [WelcomeCard]
    let onSelect: (WelcomeCard) -> Void

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
    ]

    var body: some View {
        VStack(spacing: 20) {
            logo
                .frame(width: 104, height: 104)
                .accessibilityHidden(true)

            Text(AppCopy.format("welcome.heading", projectName))
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(maxWidth: 460)

            if showCards {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(cards) { card in
                        WelcomeCardButton(card: card) { onSelect(card) }
                    }
                }
                .frame(maxWidth: 520)
            }

            if showConnectHint {
                Text(AppCopy.text("welcome.connectHint"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(40)
    }

    @ViewBuilder
    private var logo: some View {
        // Transparent-background mark, cropped to the glyph (Resources/WelcomeLogo.png,
        // bundled via .process). ponytail: derived from AppIcon.icns by flood-filling the
        // cream backdrop; a faint edge fringe survives on very dark backgrounds — replace
        // with a vector/native-transparent source if that ever shows at this size.
        if let url = Bundle.module.url(forResource: "WelcomeLogo", withExtension: "png"),
           let mark = NSImage(contentsOf: url) {
            Image(nsImage: mark)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
        } else {
            Image(systemName: "sparkles")
                .font(.system(size: 44, weight: .medium))
                .foregroundStyle(.tint)
        }
    }
}

private struct WelcomeCardButton: View {
    let card: WelcomeCard
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: card.icon)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.tint)
                        .frame(width: 18)
                    Text(card.title)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.primary)
                    Spacer(minLength: 0)
                }
                Text(card.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 74, alignment: .topLeading)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(WelcomeCardButtonStyle(hovered: hovered))
        .onHover { hovered = $0 }
        .accessibilityLabel(card.title)
        .accessibilityHint(card.subtitle)
    }
}

private struct WelcomeCardButtonStyle: ButtonStyle {
    let hovered: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                Color.primary.opacity(configuration.isPressed ? 0.12 : (hovered ? 0.08 : 0.045)),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.primary.opacity(0.07), lineWidth: 1)
            }
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

struct TerminalView: View {
    @ObservedObject var session: TerminalSession

    var body: some View {
        // ponytail: keep the existing transcript renderer; add full ANSI terminal
        // emulation only if full-screen TUI fidelity becomes a requirement.
        TerminalTranscriptView(
            output: session.output.isEmpty ? AppCopy.text("conversation.startingShell") : session.output,
            isInputEnabled: session.isRunning,
            onInput: session.sendInput
        )
        .background(Color(nsColor: .textBackgroundColor))
    }
}

private struct TerminalTranscriptView: NSViewRepresentable {
    let output: String
    let isInputEnabled: Bool
    let onInput: (String) -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        let editor = TerminalNSTextView()
        editor.onInput = onInput
        editor.isInputEnabled = isInputEnabled
        editor.string = output
        editor.isEditable = true
        editor.isSelectable = true
        editor.isRichText = false
        editor.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        editor.textColor = .textColor
        editor.insertionPointColor = .textColor
        editor.textContainerInset = NSSize(width: 14, height: 12)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.drawsBackground = false
        editor.setSelectedRange(NSRange(location: output.utf16.count, length: 0))

        scrollView.documentView = editor
        editor.scrollToEndOfDocument(nil)
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let editor = nsView.documentView as? TerminalNSTextView else { return }
        editor.onInput = onInput
        editor.isInputEnabled = isInputEnabled

        guard editor.string != output else { return }
        editor.string = output
        editor.setSelectedRange(NSRange(location: output.utf16.count, length: 0))
        editor.scrollToEndOfDocument(nil)
    }
}

private final class TerminalNSTextView: NSTextView {
    var onInput: ((String) -> Void)?
    var isInputEnabled = false

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window != nil else { return }
            self.window?.makeFirstResponder(self)
        }
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers.contains(.command) {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "c": copy(nil)
            case "v": paste(nil)
            case "a": selectAll(nil)
            default: break
            }
            return
        }

        guard isInputEnabled else { return }

        if let input = input(for: event, modifiers: modifiers) {
            onInput?(input)
            return
        }

        super.keyDown(with: event)
    }

    override func paste(_ sender: Any?) {
        guard isInputEnabled,
              let value = NSPasteboard.general.string(forType: .string),
              !value.isEmpty else { return }
        onInput?(value)
    }

    private func input(for event: NSEvent, modifiers: NSEvent.ModifierFlags) -> String? {
        if modifiers.contains(.control),
           let scalar = event.charactersIgnoringModifiers?.lowercased().unicodeScalars.first {
            let value = scalar.value == 0x20 ? 0 : scalar.value & 0x1F
            return String(UnicodeScalar(value)!)
        }

        switch event.keyCode {
        case 36, 76: return "\r"
        case 48: return "\t"
        case 51: return "\u{7f}"
        case 53: return "\u{1b}"
        case 115: return "\u{1b}[H"
        case 119: return "\u{1b}[F"
        case 123: return "\u{1b}[D"
        case 124: return "\u{1b}[C"
        case 125: return "\u{1b}[B"
        case 126: return "\u{1b}[A"
        default: break
        }

        return event.characters
    }
}

@MainActor
private final class InlineAudioPlayback: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var duration: TimeInterval = 0

    private let url: URL
    private var player: AVAudioPlayer?
    private var timer: Timer?

    init(url: URL) {
        self.url = url
    }

    func load() {
        guard player == nil else { return }
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.prepareToPlay()
            self.player = player
            duration = player.duration
        } catch {
            self.player = nil
        }
    }

    func toggle() {
        load()
        guard let player else { return }
        if player.isPlaying {
            player.pause()
            isPlaying = false
            stopTimer()
        } else if player.play() {
            isPlaying = true
            startTimer()
        }
    }

    func seek(to value: Double) {
        guard let player, duration > 0 else { return }
        player.currentTime = min(duration, max(0, value * duration))
        progress = player.currentTime / duration
    }

    func stop() {
        player?.stop()
        player?.currentTime = 0
        progress = 0
        isPlaying = false
        stopTimer()
    }

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let player = self.player else { return }
                if player.duration > 0 {
                    self.progress = min(1, player.currentTime / player.duration)
                }
                if !player.isPlaying, self.progress >= 1 {
                    self.isPlaying = false
                    self.stopTimer()
                }
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}

private struct InlineAudioPlayer: View {
    @StateObject private var playback: InlineAudioPlayback

    init(url: URL) {
        _playback = StateObject(wrappedValue: InlineAudioPlayback(url: url))
    }

    var body: some View {
        HStack(spacing: 10) {
            Button {
                playback.toggle()
            } label: {
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityLabel(playback.isPlaying ? "Pause audio" : "Play audio")

            Slider(
                value: Binding(
                    get: { playback.progress },
                    set: { playback.seek(to: $0) }
                ),
                in: 0...1
            )
            .disabled(playback.duration <= 0)

            Image(systemName: "waveform")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: 620)
        .onAppear { playback.load() }
        .onDisappear { playback.stop() }
    }
}

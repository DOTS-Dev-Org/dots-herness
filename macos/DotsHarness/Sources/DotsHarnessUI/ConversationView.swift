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
    @ObservedObject private var terminalManager: TerminalManager
    @Binding private var isPanePickerVisible: Bool

    @State private var isTerminalVisible = false
    @State private var isNewPaneMenuPresented = false
    @State private var isDropTargeted = false
    @State private var draggedPromptID: String?
    @State private var expandedFileMessageIDs = Set<String>()
    @State private var hoveredMessageID: String?
    @State private var translations: [String: String] = [:]
    @State private var translating: Set<String> = []
    /// Keep long transcripts bounded until the user scrolls back for older messages.
    @State private var pagedStartIndex: Int?
    private static let messagePageSize = 50
    private var bridge: AgentBridge { model.bridge }

    init(model: AppModel, isPanePickerVisible: Binding<Bool>) {
        self.model = model
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
            if !model.workspacePath.isEmpty && !model.activeProjectLocationAvailable {
                missingProjectNotice
            }
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
                    let hasActiveToolActivity = conversation.running
                        && conversation.messages.last?.kind == .tool
                        && conversation.messages.last?.rawToolOutput == nil
                    // Card sits under the latest system notice (stop event); hidden while running.
                    let cardAnchorID: String? = conversation.running ? nil
                        : conversation.continuation != nil
                        ? (conversation.messages.reversed().first(where: { $0.kind == .system })?.id ?? conversation.messages.last?.id)
                        : nil
                    let firstVisible = firstVisibleMessageIndex(in: conversation.messages)
                    if firstVisible > 0 {
                        ProgressView()
                            .controlSize(.small)
                            .frame(maxWidth: .infinity)
                            .onAppear { loadOlderMessages(conversation, firstVisible: firstVisible, proxy: proxy) }
                    }
                    ForEach(Array(conversation.messages.enumerated().dropFirst(firstVisible)), id: \.element.id) { index, message in
                        if message.id == conversation.messages.last?.id {
                            ForEach(conversation.pendingPrompts.filter { $0.mode != .queue }) { prompt in
                                pendingPromptBubble(prompt, in: conversation)
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
                                    isRunning: conversation.running
                                        && endIndex == conversation.messages.count
                                        && conversation.messages[endIndex - 1].rawToolOutput == nil,
                                    usedSkills: metadata.skills
                                )
                                .id("activity-\(message.id)")
                            }
                        } else {
                            messageBubble(message, in: conversation)
                                .id(message.id)
                        }
                        if message.id == cardAnchorID, conversation.canContinue,
                           let continuation = conversation.continuation,
                           continuation.reason != .userStopped {
                            continuationCard(continuation)
                                .id("continuation-\(conversation.id)")
                        }
                    }
                    // Keep run status in transcript order: after the latest user or
                    // tool message, immediately before any live assistant output.
                    if conversation.running, conversation.runStartedAt != nil, !hasActiveToolActivity {
                        liveActivityHeader(conversation)
                            .id("run-status-\(conversation.id)")
                    }
                    if conversation.running {
                        LiveReplyView(bridge: bridge, conversationID: conversation.id)
                    }
                }
                .frame(maxWidth: 820)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 28)
                .padding(.vertical, 28)
            }
            .defaultScrollAnchor(.bottom)
            .softTopScrollEdgeEffect()
            .id(conversation.id)
            .onAppear {
                scrollToLast(using: proxy, conversation: conversation, animated: false)
            }
            .onChange(of: conversation.id) { _, _ in
                pagedStartIndex = nil
                scrollToLast(using: proxy, conversation: conversation, animated: false)
            }
            .onChange(of: conversation.messages.count) { _, _ in
                scrollToLast(using: proxy, conversation: conversation)
            }
            .onChange(of: conversation.messages.last?.text) { _, _ in
                scrollToLast(using: proxy, conversation: conversation)
            }
            .onChange(of: conversation.messages.last?.changedFiles.count) { _, _ in
                // Turn metadata (including the changed-files card) is attached after
                // the final message text, so keep the newly expanded transcript in view.
                scrollToLast(using: proxy, conversation: conversation)
            }
            .onChange(of: conversation.pendingPrompts.count) { _, _ in
                scrollToLast(using: proxy, conversation: conversation)
            }
        }
    }

    private func continuationCard(_ continuation: ContinuationState) -> some View {
        let closedDuringRun = continuation.reason == .applicationClosed
        return VStack(alignment: .leading, spacing: 10) {
            Label(
                closedDuringRun
                    ? "Tool sonucu doğrulanmalı"
                    : continuation.reason == .providerLimit
                    ? AppCopy.text("agent.providerLimitTitle")
                    : continuation.reason == .toolStepLimit
                    ? AppCopy.text("agent.toolStepLimit")
                    : "\(AppCopy.text("agent.userStoppedTitle")) (\(continuation.model))",
                systemImage: closedDuringRun || continuation.reason == .providerLimit
                    ? "exclamationmark.triangle"
                    : "pause.circle"
            )
            .font(.callout.weight(.semibold))
            .foregroundStyle(closedDuringRun || continuation.reason == .providerLimit ? Color.red : Color.orange)
            if continuation.reason != .userStopped {
                Text(continuation.message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
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
            projectName: currentProjectName,
            showConnectHint: bridge.connectionResolved && bridge.connection == nil,
            showCards: model.draft.isEmpty,
            cards: welcomeCards,
            onSelect: runWelcomeCard
        )
    }

    private var welcomeCards: [WelcomeCard] {
        WelcomeCatalog.cards(
            projectName: currentProjectName,
            stack: ProjectStackSniffer.detect(at: model.selected?.cwd ?? model.workspacePath)
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
            paneRow(.files, "folder") { openFiles() }
            paneRow(.newConversation, "plus.bubble") {
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
        ComposerView(model: model, bridge: bridge)
    }

    private var missingProjectNotice: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder.badge.questionmark")
                .foregroundStyle(.secondary)
            Text(AppCopy.text("project.missing.readOnly"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(AppCopy.text("project.missing.locate")) {
                model.promptToRelocateProject(missingPath: model.workspacePath)
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Color.primary.opacity(0.045))
    }

    private var workspaceName: String {
        let path = model.terminalWorkspaceKey
        guard !path.isEmpty else { return AppCopy.text("conversation.workspace") }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    private var currentProjectName: String {
        let path = model.selected?.cwd ?? model.workspacePath
        guard !path.isEmpty else { return AppCopy.text("conversation.workspace") }
        return model.projectTitle(for: path)
    }

    private var terminalSessions: [TerminalSession] {
        terminalManager.sessions(for: model.terminalWorkspaceKey)
    }

    private var selectedTerminal: TerminalSession? {
        terminalManager.selectedSession(for: model.terminalWorkspaceKey)
    }

    @ViewBuilder
    private func messageBubble(_ message: ChatMessage, in conversation: Conversation) -> some View {
        if message.activityCode == "context_compacted_auto" || message.activityCode == "context_compacted" {
            contextCompactionNotice(message)
        } else if message.kind == .plan {
            planCard(message, in: conversation)
        } else {
            standardMessageBubble(message, in: conversation)
        }
    }

    private func contextCompactionNotice(_ message: ChatMessage) -> some View {
        HStack(spacing: 9) {
            Image(systemName: "arrow.down.right")
                .font(.callout.weight(.medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 18)
            Text(AppCopy.text(
                message.activityCode == "context_compacted_auto"
                    ? "conversation.contextCompactedAuto"
                    : "status.contextCompacted"
            ))
            .font(.callout)
            .foregroundStyle(.secondary)
            if !message.text.isEmpty {
                Text("·")
                    .foregroundStyle(.tertiary)
                Text(message.text)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
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
                thinkingDisclosure(for: message)
                PlanMarkdownView(text: message.text)
                    .textSelection(.enabled)
                usedItemsDisclosure(for: message)
                runSummaryView(for: message)
                changedFilesDisclosure(for: message)
                translationText(message, alignment: .leading)
                messageActions(message, in: conversation)
                Button {
                    model.requestPlanPane()
                } label: {
                    Label(AppCopy.text("plan.open"), systemImage: "sidebar.right")
                }
                .buttonStyle(.bordered)
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

    private func pauseNoticeState(_ message: ChatMessage) -> (icon: String, color: Color)? {
        guard message.kind == .system else { return nil }
        if message.text == AppCopy.text("conversation.generationStopped") { return ("pause.circle", .orange) }
        if message.text == AppCopy.text("conversation.generationResumed") { return ("play.circle", .green) }
        return nil
    }

    private func standardMessageBubble(_ message: ChatMessage, in conversation: Conversation) -> some View {
        let isUser = message.kind == .user
        let isAssistant = message.kind == .assistant
        let answerTranscript = questionAnswerTranscript(for: message)
        return HStack {
            if isUser { Spacer(minLength: 80) }
            VStack(alignment: isUser ? .trailing : .leading, spacing: 7) {
                if !message.attachments.isEmpty {
                    attachmentViews(message.attachments)
                }
                if isAssistant {
                    if message.streaming {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(AppCopy.text("conversation.working"))
                        }
                        .foregroundStyle(.primary)
                    }
                } else if message.kind == .system, let state = pauseNoticeState(message) {
                    Label(message.text, systemImage: state.icon)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(state.color)
                } else if answerTranscript != nil {
                    Label(AppCopy.text("ask.title"), systemImage: "questionmark.bubble")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                } else if message.kind == .system {
                    HStack(spacing: 7) {
                        Image(systemName: icon(for: message.kind))
                            .font(.caption.weight(.semibold))
                        Text(label(for: message.kind))
                            .font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(.secondary)
                }
                thinkingDisclosure(for: message)
                if !message.text.isEmpty, isAssistant {
                    PlanMarkdownView(text: message.text)
                        .textSelection(.enabled)
                } else if let answerTranscript {
                    Text(answerTranscript)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .font(.callout)
                } else if !message.text.isEmpty, pauseNoticeState(message) == nil {
                    Text(message.text)
                        .textSelection(.enabled)
                        .multilineTextAlignment(isUser ? .trailing : .leading)
                        .frame(maxWidth: isUser ? nil : .infinity, alignment: isUser ? .trailing : .leading)
                        .font(message.kind == .tool ? .callout.monospaced() : .body)
                }
                if message.kind == .tool,
                   let rawToolOutput = message.rawToolOutput,
                   !rawToolOutput.isEmpty {
                    DisclosureGroup(AppCopy.text("conversation.fullToolOutput")) {
                        ScrollView([.horizontal, .vertical]) {
                            Text(rawToolOutput)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(6)
                        }
                        .frame(maxHeight: 360)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                usedItemsDisclosure(for: message)
                runSummaryView(for: message)
                changedFilesDisclosure(for: message)
                if !message.mediaItems.isEmpty {
                    ForEach(message.mediaItems) { media in
                        mediaView(media)
                    }
                }
                translationText(message, alignment: isUser ? .trailing : .leading)
                messageActions(message, in: conversation)
            }
            .padding(.vertical, 4)
            .frame(maxWidth: isUser ? 600 : 760, alignment: isUser ? .trailing : .leading)
            .onHover { hovered in
                hoveredMessageID = hovered ? message.id : nil
            }
            if !isUser { Spacer(minLength: 80) }
        }
    }

    private func questionAnswerTranscript(for message: ChatMessage) -> String? {
        guard message.kind == .system,
              message.text.hasPrefix("Q: "),
              message.text.contains("\nA: ") else { return nil }
        return message.text
    }

    @ViewBuilder
    private func messageActions(_ message: ChatMessage, in conversation: Conversation) -> some View {
        if (message.kind == .user || message.kind == .assistant || message.kind == .plan),
           !message.streaming,
           !replyIsStillRunning(message, in: conversation) {
            let latestUser = conversation.messages.reversed().first(where: { $0.kind == .user })?.id == message.id
            let canEdit = latestUser && bridge.canEdit(messageID: message.id, in: conversation.id)
            let canRewind = message.kind == .user && bridge.canRewind(messageID: message.id, in: conversation.id)
            let hasText = !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let hasOutput = hasText || !message.mediaItems.isEmpty
            let speaking = model.isSpeaking(messageID: message.id)
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
                if hasText {
                    if translating.contains(message.id) {
                        ProgressView().controlSize(.small)
                    } else {
                        actionButton("globe", AppCopy.text("conversation.translate")) { toggleTranslation(message) }
                            .foregroundStyle(translations[message.id] == nil ? Color.secondary : Color.accentColor)
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

    @ViewBuilder
    private func translationText(_ message: ChatMessage, alignment: Alignment) -> some View {
        if let text = translations[message.id] {
            Text(text)
                .textSelection(.enabled)
                .multilineTextAlignment(alignment == .trailing ? .trailing : .leading)
                .frame(maxWidth: .infinity, alignment: alignment)
        }
    }

    /// A model message may finish before its tool loop and final response do.
    /// Keep controls off those in-progress reply segments until the run ends.
    private func replyIsStillRunning(_ message: ChatMessage, in conversation: Conversation) -> Bool {
        guard conversation.running else { return false }
        guard message.kind == .assistant || message.kind == .plan else { return false }
        if let runStartedAt = conversation.runStartedAt {
            return message.createdAt >= runStartedAt
        }
        guard let messageIndex = conversation.messages.firstIndex(where: { $0.id == message.id }),
              let latestUserIndex = conversation.messages.lastIndex(where: { $0.kind == .user }) else {
            return true
        }
        return messageIndex > latestUserIndex
    }

    private func toggleTranslation(_ message: ChatMessage) {
        if translations.removeValue(forKey: message.id) != nil { return }
        translating.insert(message.id)
        Task { @MainActor in
            defer { translating.remove(message.id) }
            do {
                translations[message.id] = try await model.translate(message.text)
            } catch {
                translations[message.id] = error.localizedDescription
            }
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

    private func liveActivityHeader(_ conversation: Conversation) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let skills = bridge.activeUsedSkillIDs
            let statusText = liveStatusText(
                start: conversation.runStartedAt,
                now: context.date,
                toolsRunning: false
            )
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(statusText)
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

    /// "2m 16s · 1.4k tokens · Running tools…"
    private func liveStatusText(start: Date?, now: Date, toolsRunning: Bool) -> String {
        var parts = [elapsedText(from: start, now: now)]
        let tokens = bridge.activeRunTokenCount
        if tokens > 0 {
            let count = compactTokens(tokens)
            let displayedCount = bridge.activeRunTokenCountIncludesEstimate ? "≈\(count)" : count
            parts.append(AppCopy.format("conversation.processedTokensCount", displayedCount))
        }
        if toolsRunning { parts.append(AppCopy.text("conversation.runningTools")) }
        return parts.joined(separator: " · ")
    }

    private func compactTokens(_ value: Int) -> String {
        value < 1_000 ? "\(value)" : String(format: "%.1fk", Double(value) / 1_000)
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
        let usedTools = message.usedTools.filter(NativeAgentHost.isExtensionTool)
        if !message.usedSkills.isEmpty || !usedTools.isEmpty {
            DisclosureGroup {
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
                    if !usedTools.isEmpty {
                        Text(AppCopy.text("conversation.tools"))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(usedTools.joined(separator: ", "))
                            .font(.callout.monospaced())
                            .lineLimit(3)
                            .truncationMode(.middle)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 22)
                .padding(.top, 5)
            } label: {
                Label(AppCopy.text("conversation.used"), systemImage: "bolt.horizontal.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel(AppCopy.text("conversation.used"))
        }
    }

    @ViewBuilder
    private func thinkingDisclosure(for message: ChatMessage) -> some View {
        if let thinking = message.thinking, !thinking.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 6) {
                    Text(thinking)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 12)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                }
                .padding(.top, 4)
            } label: {
                Label(AppCopy.text("conversation.thinking"), systemImage: "brain.head.profile")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel(AppCopy.text("conversation.thinking"))
            .padding(.bottom, 2)
        }
    }

    @ViewBuilder
    private func runSummaryView(for message: ChatMessage) -> some View {
        if let summary = message.summary, message.changedFiles.isEmpty {
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
            let expanded = expandedFileMessageIDs.contains(message.id)
            let countsKnown = message.changedFiles.allSatisfy { $0.addedLines >= 0 && $0.deletedLines >= 0 }
            let addedLines = message.changedFiles.reduce(0) { $0 + max(0, $1.addedLines) }
            let deletedLines = message.changedFiles.reduce(0) { $0 + max(0, $1.deletedLines) }
            let visibleFiles = expanded ? message.changedFiles : Array(message.changedFiles.prefix(3))
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(AppCopy.format("conversation.filesChangedCount", message.changedFiles.count))
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.primary)
                        if countsKnown {
                            HStack(spacing: 8) {
                                Text("+\(addedLines)").foregroundStyle(.green)
                                Text("−\(deletedLines)").foregroundStyle(.red)
                            }
                            .font(.callout.monospacedDigit())
                        } else {
                            Text(AppCopy.text("conversation.lineCountsUnavailable"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 8)
                    if message.summary?.undoAvailable == true {
                        Button {
                            model.undoTurn(messageID: message.id)
                        } label: {
                            Label(AppCopy.text("conversation.undoChanges"), systemImage: "arrow.uturn.backward")
                        }
                        .buttonStyle(.plain)
                        .help(AppCopy.text("conversation.undoChanges"))
                    }
                    if message.changedFiles.count > 3 {
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                if expanded { expandedFileMessageIDs.remove(message.id) }
                                else { expandedFileMessageIDs.insert(message.id) }
                            }
                        } label: {
                            Label(
                                AppCopy.text(expanded ? "conversation.filesLess" : "conversation.viewChanges"),
                                systemImage: expanded ? "chevron.up" : "arrow.up.right"
                            )
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)

                Divider()

                VStack(spacing: 0) {
                    ForEach(visibleFiles) { file in
                        changedFileRow(file)
                    }
                    if message.changedFiles.count > 3 {
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                if expanded { expandedFileMessageIDs.remove(message.id) }
                                else { expandedFileMessageIDs.insert(message.id) }
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Text(expanded
                                    ? AppCopy.text("conversation.filesLess")
                                    : AppCopy.format("conversation.filesMore", message.changedFiles.count - 3))
                                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            }
                            .font(.callout)
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.45), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(Color.secondary.opacity(0.18), lineWidth: 1))
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
            Spacer(minLength: 8)
            if file.addedLines >= 0, file.deletedLines >= 0 {
                Text("+\(file.addedLines)")
                    .foregroundStyle(.green)
                    .font(.system(.callout, design: .monospaced).monospacedDigit())
                Text("−\(file.deletedLines)")
                    .foregroundStyle(.red)
                    .font(.system(.callout, design: .monospaced).monospacedDigit())
            } else {
                Text("—")
                    .foregroundStyle(.tertiary)
                    .font(.system(.callout, design: .monospaced))
            }
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
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        } else {
            HStack(spacing: 8) {
                content
                Text(AppCopy.text("conversation.fileUnavailable"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
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
        if !messages.isEmpty {
            let terminals = activityTerminalItems(messages)
            PaginatedActivityDisclosure(items: terminals) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        if isRunning {
                            TimelineView(.periodic(from: .now, by: 1)) { context in
                                HStack(spacing: 8) {
                                    ProgressView().controlSize(.small)
                                    Text(liveStatusText(start: bridge.activeRunStartedAt, now: context.date, toolsRunning: true))
                                    if let activeTool = messages.last(where: { $0.rawToolOutput == nil }) {
                                        Text("·").foregroundStyle(.tertiary)
                                        activityLabel(
                                            for: ConversationActivityCategory(toolName: toolName(from: activeTool.text)),
                                            running: true
                                        )
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                    if !bridge.activeUsedSkillIDs.isEmpty {
                                        Text("·").foregroundStyle(.tertiary)
                                        Text(AppCopy.format("conversation.using", bridge.activeUsedSkillIDs.joined(separator: ", ")))
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                }
                            }
                        } else {
                            let summaries = activitySummaries(terminals)
                            ForEach(Array(summaries.indices), id: \.self) { index in
                                activityLabel(
                                    for: summaries[index].category,
                                    running: false,
                                    failed: summaries[index].isFailure
                                )
                                if index < summaries.count - 1 {
                                    Text("·").foregroundStyle(.tertiary)
                                }
                            }
                            if !summaries.isEmpty {
                                Text("·").foregroundStyle(.tertiary)
                            }
                            Text(activityDuration(messages, completedAt: completedAt))
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

                    if isRunning,
                       let activeTool = messages.last(where: { $0.rawToolOutput == nil }),
                       !activeTool.text.contains(AskUserTool.name) {
                        let detail = activeToolDetail(activeTool.text)
                        if !detail.isEmpty {
                            Text(detail)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .lineLimit(2)
                                .truncationMode(.tail)
                                .textSelection(.enabled)
                        }
                    }
                }
            } row: { item, ordinal in
                activityTerminalCard(item, ordinal: ordinal)
            }
            .foregroundStyle(.secondary)
            .padding(.vertical, 6)
        }
    }

    private func activityTerminalCard(_ item: ActivityTerminalItem, ordinal: Int) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                if let command = item.command {
                    HStack(alignment: .top, spacing: 8) {
                        Text("$")
                            .foregroundStyle(.green)
                        Text(command)
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.system(size: 12, design: .monospaced))
                    .padding(.bottom, 2)
                }

                if let output = item.output ?? item.progressOutput, !output.isEmpty {
                    ScrollView([.horizontal, .vertical]) {
                        Text(output)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: true, vertical: false)
                            .padding(10)
                    }
                    .frame(height: 220)
                    .background(Color(nsColor: .textBackgroundColor).opacity(0.78), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.secondary.opacity(0.16), lineWidth: 1)
                    }
                } else if item.isRunning {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(AppCopy.text("conversation.working"))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)
                }
            }
            .padding(.leading, 26)
            .padding(.top, 8)
        } label: {
            HStack(spacing: 9) {
                Text(String(format: "%02d", ordinal))
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .frame(width: 24, alignment: .trailing)

                Image(systemName: item.category.icon)
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.command ?? item.toolName)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if item.command != nil {
                        Text(item.toolName)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if item.isRunning {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: item.isFailure ? "xmark.circle.fill" : "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(item.isFailure ? Color.red : Color.green)
                }
                messageTimestamp(item.completedAt ?? item.startedAt)
            }
            .contentShape(Rectangle())
        }
        .font(.callout)
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.62), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.secondary.opacity(0.17), lineWidth: 1)
        }
    }

    private func activityTerminalItems(_ messages: ArraySlice<ChatMessage>) -> [ActivityTerminalItem] {
        var items: [ActivityTerminalItem] = []
        var pendingStart: ChatMessage?

        for message in messages {
            guard let output = message.rawToolOutput else {
                pendingStart = message
                continue
            }

            let title = message.text.components(separatedBy: .newlines).first ?? message.text
            let resolvedToolName = toolName(from: title)
            let startParts = pendingStart.map { runningToolParts($0.text) }
            items.append(ActivityTerminalItem(
                id: message.id,
                toolName: resolvedToolName,
                command: resolvedToolName == "run_command" ? startParts?.command : nil,
                output: output,
                progressOutput: nil,
                startedAt: pendingStart?.createdAt ?? message.createdAt,
                completedAt: message.createdAt,
                isFailure: title.hasPrefix("✕ ")
            ))
            pendingStart = nil
        }

        if let pendingStart {
            let parts = runningToolParts(pendingStart.text)
            let title = pendingStart.text.components(separatedBy: .newlines).first ?? pendingStart.text
            items.append(ActivityTerminalItem(
                id: pendingStart.id,
                toolName: self.toolName(from: title),
                command: parts.command,
                output: nil,
                progressOutput: parts.progress,
                startedAt: pendingStart.createdAt,
                completedAt: nil,
                isFailure: false
            ))
        }

        return items
    }

    private func activitySummaries(_ items: [ActivityTerminalItem]) -> [ActivitySummaryEntry] {
        var seen = Set<String>()
        return items.compactMap { item in
            let entry = ActivitySummaryEntry(category: item.category, isFailure: item.isFailure)
            return seen.insert(entry.id).inserted ? entry : nil
        }
    }

    private func activityLabel(
        for category: ConversationActivityCategory,
        running: Bool,
        failed: Bool = false
    ) -> some View {
        HStack(spacing: 6) {
            Image(systemName: category.icon)
                .font(.caption)
                .foregroundStyle(failed ? Color.red : Color.accentColor.opacity(0.9))
            Text(failed
                ? AppCopy.format("conversation.activity.toolFailed", AppCopy.text(category.completedKey))
                : AppCopy.text(running ? category.runningKey : category.completedKey))
                .foregroundStyle(.secondary)
        }
    }

    private func toolName(from text: String) -> String {
        let title = text.components(separatedBy: .newlines).first ?? text
        for prefix in ["✓ ", "→ ", "✕ "] where title.hasPrefix(prefix) {
            return String(title.dropFirst(prefix.count))
        }
        return title
    }

    private func runningToolParts(_ text: String) -> (command: String?, progress: String?) {
        guard let firstLine = text.firstIndex(of: "\n") else { return (nil, nil) }
        let detailStart = text.index(after: firstLine)
        let detail = text[detailStart...]
        guard let separator = detail.range(of: "\n\n") else {
            let command = detail.trimmingCharacters(in: .whitespacesAndNewlines)
            return (command.isEmpty ? nil : command, nil)
        }

        let command = detail[..<separator.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        let progress = detail[separator.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return (command.isEmpty ? nil : command, progress.isEmpty ? nil : progress)
    }

    private func activeToolDetail(_ text: String) -> String {
        if let range = text.range(of: "\n\n", options: .backwards) {
            let command = String(text[..<range.lowerBound])
                .components(separatedBy: "\n")
                .dropFirst()
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let latestOutput = String(text[range.upperBound...])
                .split(whereSeparator: \.isNewline)
                .last
                .map(String.init) ?? ""
            return [command, latestOutput]
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
        }
        if let range = text.range(of: "\n") {
            return String(text[range.upperBound...])
        }
        return text
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
        for message in messages.reversed() where message.turnID == turnID {
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
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 10) {
                ForEach(attachments) { attachment in
                    Button {
                        NSWorkspace.shared.open(attachment.url)
                    } label: {
                        VStack(alignment: .leading, spacing: 0) {
                            if attachment.kind == .image, let image = NSImage(contentsOf: attachment.url) {
                                Image(nsImage: image)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 172, height: 96)
                                    .clipped()
                            } else {
                                ZStack {
                                    Color.accentColor.opacity(0.08)
                                    Image(systemName: attachment.kind.systemImageName)
                                        .font(.system(size: 30, weight: .regular))
                                        .foregroundStyle(.secondary)
                                }
                                .frame(width: 172, height: 96)
                            }
                            HStack(spacing: 7) {
                                Image(systemName: attachment.kind.systemImageName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(attachment.name)
                                    .lineLimit(1)
                                    .font(.caption.weight(.medium))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 9)
                        }
                        .frame(width: 172, alignment: .leading)
                        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .help(attachment.name)
                    .accessibilityLabel(attachment.name)
                }
            }
            .padding(.vertical, 2)
        }
        .scrollIndicators(.visible, axes: .horizontal)
        .frame(maxWidth: 600, alignment: .leading)
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
                        : conversation.pendingPlanMessageID != nil && prompt.approvedPlanID == nil
                            ? AppCopy.text("queue.waitingForPlan")
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

    private func scrollToLast(
        using proxy: ScrollViewProxy,
        conversation: Conversation,
        animated: Bool = true
    ) {
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
            guard let selected = model.selected,
                  selected.id == conversation.id,
                  selected.contentLoaded,
                  selected.messages.last?.id == last.id else { return }
            withAnimation(animated ? .easeOut(duration: 0.18) : nil) {
                proxy.scrollTo(targetID, anchor: .bottom)
            }
        }
    }

    /// Start of the visible transcript page, moved back so a tool activity group
    /// is never split across pages.
    private func firstVisibleMessageIndex(in messages: [ChatMessage]) -> Int {
        var start = pagedStartIndex.map { min($0, max(0, messages.count - 1)) }
            ?? max(0, messages.count - Self.messagePageSize)
        while start > 0, messages[start].kind == .tool, messages[start - 1].kind == .tool {
            start -= 1
        }
        return start
    }

    private func loadOlderMessages(_ conversation: Conversation, firstVisible: Int, proxy: ScrollViewProxy) {
        guard firstVisible > 0 else { return }
        let anchor = conversation.messages[firstVisible]
        let anchorID = anchor.kind == .tool ? "activity-\(anchor.id)" : anchor.id
        pagedStartIndex = max(0, firstVisible - Self.messagePageSize)
        DispatchQueue.main.async {
            guard model.selected?.id == conversation.id else { return }
            proxy.scrollTo(anchorID, anchor: .top)
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
                executionPolicy: model.remoteWorkspace == nil ? model.sandboxExecutionPolicy : nil,
                remoteTarget: model.remoteWorkspace
            )
        }
    }

    private func closeTerminal() {
        isNewPaneMenuPresented = false
        isTerminalVisible = false
    }

}

private struct ActivityTerminalItem: Identifiable {
    let id: String
    let toolName: String
    let command: String?
    let output: String?
    let progressOutput: String?
    let startedAt: Date
    let completedAt: Date?
    let isFailure: Bool

    var isRunning: Bool { completedAt == nil }
    var category: ConversationActivityCategory { ConversationActivityCategory(toolName: toolName) }
}

private struct ActivitySummaryEntry: Identifiable {
    let category: ConversationActivityCategory
    let isFailure: Bool
    var id: String { "\(category.rawValue)-\(isFailure ? "failed" : "done")" }
}

/// Expanding tool activity is isolated from the transcript view and reveals a
/// small page of tool cards at a time, keeping large tool runs responsive.
private struct PaginatedActivityDisclosure<Label: View, Row: View>: View {
    private static var pageSize: Int { 10 }

    let items: [ActivityTerminalItem]
    let label: Label
    let row: (ActivityTerminalItem, Int) -> Row

    @State private var isExpanded = false
    @State private var visibleCount: Int

    init(
        items: [ActivityTerminalItem],
        @ViewBuilder label: () -> Label,
        @ViewBuilder row: @escaping (ActivityTerminalItem, Int) -> Row
    ) {
        self.items = items
        self.label = label()
        self.row = row
        _visibleCount = State(initialValue: min(items.count, Self.pageSize))
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(items.prefix(visibleCount).enumerated()), id: \.element.id) { index, item in
                    row(item, index + 1)
                }
                if visibleCount < items.count {
                    Button(AppCopy.text("sidebar.showMore")) {
                        visibleCount = min(items.count, visibleCount + Self.pageSize)
                    }
                    .buttonStyle(.borderless)
                    .padding(.leading, 26)
                }
            }
            .padding(.leading, 22)
            .padding(.top, 8)
        } label: {
            label
        }
    }
}

private enum ConversationActivityCategory: String, Hashable {
    case filesRead
    case filesChanged
    case commands
    case web
    case other

    init(toolName: String) {
        let name = toolName.lowercased()
        if ["read_file", "list_files", "grep_files", "glob_files", "search_files", "get_latest_attachment"].contains(name) {
            self = .filesRead
        } else if ["write_file", "edit_file", "create_file", "delete_file", "copy_generated_media"].contains(name) {
            self = .filesChanged
        } else if ["run_command", "terminal_session", "shell", "exec"].contains(name) {
            self = .commands
        } else if name.hasPrefix("web_") || name.hasPrefix("browser_") || name.contains("web_search") || name.contains("web_fetch") {
            self = .web
        } else {
            self = .other
        }
    }

    var icon: String {
        switch self {
        case .filesRead: return "doc.text.magnifyingglass"
        case .filesChanged: return "pencil.line"
        case .commands: return "terminal.fill"
        case .web: return "magnifyingglass"
        case .other: return "wrench.and.screwdriver"
        }
    }

    var completedKey: String {
        switch self {
        case .filesRead: return "conversation.activity.filesRead"
        case .filesChanged: return "conversation.activity.filesChanged"
        case .commands: return "conversation.activity.commandsRun"
        case .web: return "conversation.activity.webSearch"
        case .other: return "conversation.activity.otherDone"
        }
    }

    var runningKey: String {
        switch self {
        case .filesRead: return "conversation.activity.filesReading"
        case .filesChanged: return "conversation.activity.filesChanging"
        case .commands: return "conversation.activity.commandsRunning"
        case .web: return "conversation.activity.webSearching"
        case .other: return "conversation.activity.otherRunning"
        }
    }
}

/// The reply while the provider is still writing it. A view of its own, so a
/// delta re-renders this bubble and not the transcript above it.
private struct LiveReplyView: View {
    let bridge: AgentBridge
    let conversationID: String

    var body: some View {
        if let text = bridge.liveReply(for: conversationID), !text.isEmpty {
            // Keep the in-flight reply cheap to update. Parsing and laying out
            // the entire accumulated Markdown document for every stream batch
            // gets quadratic as the reply grows; the completed bubble is
            // rendered as Markdown once the run stores it in the transcript.
            Text(verbatim: text)
                .font(.body)
                .lineSpacing(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if let thinking = bridge.liveThinking(for: conversationID), !thinking.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Label(AppCopy.text("conversation.thinking"), systemImage: "brain.head.profile")
                    .font(.callout.weight(.medium))
                // ponytail: only the tail, the full reasoning lands in the finished message's disclosure.
                Text("…" + thinking.suffix(400))
                    .font(.callout)
                    .lineLimit(4)
                    .truncationMode(.head)
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private extension View {
    /// A short transcript is bottom-anchored through a top content inset, and the
    /// macOS 26 hard scroll edge effect draws its divider under that inset: a
    /// hairline right above the first message. `scrollEdgeEffectHidden` and
    /// `titlebarSeparatorStyle = .none` leave it in place; the soft style has no divider.
    @ViewBuilder
    func softTopScrollEdgeEffect() -> some View {
        if #available(macOS 26.0, *) {
            scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            self
        }
    }
}

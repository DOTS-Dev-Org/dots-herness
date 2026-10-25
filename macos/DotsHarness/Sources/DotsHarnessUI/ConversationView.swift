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
    @State private var translations: [String: String] = [:]
    @State private var translating: Set<String> = []
    @State private var isLoadingOlderMessages = false
    @State private var olderPageAnchorID: String?
    @State private var olderPageLoadID: UUID?
    @State private var streamingScrollTask: Task<Void, Never>?
    /// Full composer height; a change means the transcript just lost or gained room.
    @State private var composerHeight: CGFloat = 0
    private static let messagePageSize = ConversationStore.defaultTranscriptPageSize
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
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isDropTargeted) { providers in
            handleFileDrop(providers) { model.addDraftAttachments($0) }
        }
        .environment(\.openURL, OpenURLAction { url in
            model.openFileLink(url) ? .handled : .systemAction
        })
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
            runningTasksChip
            planStepsCard
            composer
                .onPreferenceChange(ComposerHeightKey.self) { composerHeight = $0 }
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
                        scrollableWelcome
                    } else {
                        conversationBody(conversation)
                    }
                } else {
                    scrollableWelcome
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func conversationBody(_ conversation: Conversation) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Eager on purpose: LazyVStack here re-estimates variable row heights on every
                // scrollTo and loops LazyLayoutCacheItem.AllItemsPhaseMutation forever, pinning
                // the main thread at 100%. The transcript is paged, so it stays short.
                VStack(alignment: .leading, spacing: 20) {
                    let hasActiveToolActivity = conversation.running
                        && conversation.messages.last?.kind == .tool
                        && conversation.messages.last?.rawToolOutput == nil
                    // Card sits under the latest system notice (stop event); hidden while running.
                    let cardAnchorID: String? = conversation.running ? nil
                        : conversation.continuation != nil
                        ? (conversation.messages.reversed().first(where: { $0.kind == .system })?.id ?? conversation.messages.last?.id)
                        : nil
                    if conversation.hasOlderTranscriptMessages {
                        Button {
                            loadOlderMessages(conversation)
                        } label: {
                            Group {
                                if isLoadingOlderMessages {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Label(AppCopy.text("sidebar.showMore"), systemImage: "arrow.up")
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .contentShape(Rectangle())
                            .padding(.vertical, 6)
                        }
                        .buttonStyle(.plain)
                        .disabled(isLoadingOlderMessages)
                    }
                    if conversation.messages.isEmpty {
                        ForEach(conversation.pendingPrompts.filter {
                            $0.mode != .queue || bridge.isStartingPrompt($0.id, in: conversation.id)
                        }) { prompt in
                            pendingPromptBubble(prompt, in: conversation)
                        }
                    }
                    ForEach(Array(conversation.messages.enumerated()), id: \.element.id) { index, message in
                        if message.id == conversation.messages.last?.id {
                            ForEach(conversation.pendingPrompts.filter {
                                $0.mode != .queue || bridge.isStartingPrompt($0.id, in: conversation.id)
                            }) { prompt in
                                pendingPromptBubble(prompt, in: conversation)
                            }
                        }
                        if message.kind == .tool {
                            if index == 0 || conversation.messages[index - 1].kind != .tool {
                                let endIndex = activityEndIndex(startingAt: index, in: conversation.messages)
                                activitySummary(
                                    messages: conversation.messages[index..<endIndex],
                                    isRunning: conversation.running
                                        && endIndex == conversation.messages.count
                                        && conversation.messages[endIndex - 1].rawToolOutput == nil
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
                        LiveReplyView(bridge: bridge, conversationID: conversation.id) {
                            scheduleStreamingScroll(using: proxy, conversation: conversation)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 28)
                .padding(.vertical, 28)
                .id("transcript")
            }
            .softTopScrollEdgeEffect()
            .scrollToBottomButton {
                withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo("transcript", anchor: .bottom) }
            }
            .id(conversation.id)
            .onAppear {
                scrollToLast(using: proxy, conversation: conversation, animated: false)
            }
            .onChange(of: conversation.id) { _, _ in
                isLoadingOlderMessages = false
                olderPageAnchorID = nil
                olderPageLoadID = nil
                scrollToLast(using: proxy, conversation: conversation, animated: false)
            }
            .onChange(of: conversation.messages.count) { _, _ in
                if let anchorID = olderPageAnchorID {
                    DispatchQueue.main.async {
                        if model.selected?.id == conversation.id {
                            proxy.scrollTo(anchorID, anchor: .top)
                        }
                        if olderPageAnchorID == anchorID { olderPageAnchorID = nil }
                    }
                } else {
                    scrollToLast(using: proxy, conversation: conversation)
                }
            }
            .onChange(of: conversation.messages.last?.text) { _, _ in
                if conversation.running {
                    scheduleStreamingScroll(using: proxy, conversation: conversation)
                } else {
                    scrollToLast(using: proxy, conversation: conversation)
                }
            }
            .onChange(of: conversation.running) { _, isRunning in
                if !isRunning {
                    scrollToLast(using: proxy, conversation: conversation)
                }
            }
            .onChange(of: bridge.changedFilesRevision(for: conversation.id)) { _, _ in
                // A completed turn can attach its file list to an earlier stop event
                // or a later assistant response; keep either card in view.
                if olderPageAnchorID == nil {
                    scrollToLast(using: proxy, conversation: conversation)
                }
            }
            .onChange(of: conversation.pendingPrompts.count) { _, _ in
                scrollToLast(using: proxy, conversation: conversation)
            }
            .onChange(of: composerHeight) { _, _ in
                // The composer taking or giving back height resizes the transcript; keep its last message in view.
                scrollToLast(using: proxy, conversation: conversation, animated: false)
            }
            .onDisappear {
                streamingScrollTask?.cancel()
                streamingScrollTask = nil
            }
        }
    }

    private func continuationCard(_ continuation: ContinuationState) -> some View {
        let closedDuringRun = continuation.reason == .applicationClosed
        return VStack(alignment: .leading, spacing: 10) {
            Label(
                closedDuringRun
                    ? AppCopy.text("agent.applicationClosedTitle")
                    : continuation.reason == .providerLimit
                    ? AppCopy.text("agent.providerLimitTitle")
                    : continuation.reason == .toolStepLimit
                    ? AppCopy.text("agent.toolStepLimit")
                    : continuation.reason == .networkLost
                    ? AppCopy.text("agent.networkLostTitle")
                    : "\(AppCopy.text("agent.userStoppedTitle")) (\(continuation.model))",
                systemImage: closedDuringRun || continuation.reason == .providerLimit
                    ? "exclamationmark.triangle"
                    : continuation.reason == .networkLost ? "wifi.slash" : "pause.circle"
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

    /// The welcome cards can scroll when a dock reduces the chat's height;
    /// their intrinsic size must never push the composer below the window.
    private var scrollableWelcome: some View {
        GeometryReader { proxy in
            ScrollView {
                emptyConversation.frame(minHeight: proxy.size.height)
            }
        }
    }

    @ViewBuilder
    private var emptyConversation: some View {
        WelcomeView(
            projectName: currentProjectName,
            showConnectHint: bridge.connectionResolved && bridge.connection == nil,
            showCards: model.draftIsEmpty,
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

    /// Shown while the agent has background work going; opens the task list in the dock.
    @ViewBuilder
    private var runningTasksChip: some View {
        let running = bridge.backgroundTasks(in: model.selected?.id).filter(\.isRunning).count
        if running > 0 {
            Button { model.tasksPaneRequestID &+= 1 } label: {
                Text(AppCopy.format("backgroundTasks.runningCount", running))
                    .font(.callout)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.accentColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.bottom, 6)
        }
    }

    private var composer: some View {
        ComposerView(model: model, bridge: bridge)
    }

    /// Live checklist from the agent's latest update_plan, pinned above the composer.
    @ViewBuilder
    private var planStepsCard: some View {
        if let conversation = model.selected {
            let steps = PlanStepsTool.currentSteps(in: conversation.messages)
            if steps.contains(where: { $0.status != "done" }) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("\(AppCopy.text("plan.title")) · \(steps.filter { $0.status == "done" }.count)/\(steps.count)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Group {
                                switch step.status {
                                case "done": Image(systemName: "checkmark.circle.fill").foregroundStyle(.secondary)
                                case "in_progress": ProgressView().controlSize(.mini)
                                default: Image(systemName: "circle.dashed").foregroundStyle(.tertiary)
                                }
                            }
                            .frame(width: 14)
                            Text(step.title)
                                .foregroundStyle(step.status == "pending" ? .secondary : .primary)
                                .lineLimit(2)
                        }
                        .font(.callout)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .padding(.horizontal, 20)
                .padding(.bottom, 6)
                .animation(.easeOut(duration: 0.18), value: steps)
            }
        }
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
            HoverScope { hovering in
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
                translationText(message, alignment: .leading)
                if shouldShowChangedFilesOnMessage(message, in: conversation) {
                    changedFilesDisclosure(for: message)
                }
                messageActions(message, in: conversation, hovering: hovering)
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
            }
            Spacer(minLength: 80)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func planStatus(_ message: ChatMessage, isPending: Bool, isRunning: Bool) -> String {
        if let error = message.planError, !error.isEmpty { return AppCopy.format("plan.errorStatus", error) }

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
            HoverScope { hovering in
            VStack(alignment: isUser ? .trailing : .leading, spacing: 7) {
                if !message.attachments.isEmpty {
                    attachmentViews(message.attachments, isUser: isUser)
                }
                if isAssistant {
                    if message.streaming {
                        HStack(spacing: 8) {
                            HerNessLoadingAnimation(size: 18)
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
                    StillDisclosureGroup {
                        ScrollView([.horizontal, .vertical]) {
                            Text(rawToolOutput)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(6)
                        }
                        .frame(maxHeight: 360)
                    } label: {
                        Text(AppCopy.text("conversation.fullToolOutput"))
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                usedItemsDisclosure(for: message)
                runSummaryView(for: message)
                if !message.mediaItems.isEmpty {
                    ForEach(message.mediaItems) { media in
                        mediaView(media)
                    }
                }
                translationText(message, alignment: isUser ? .trailing : .leading)
                if shouldShowChangedFilesOnMessage(message, in: conversation) {
                    changedFilesDisclosure(for: message)
                }
                messageActions(message, in: conversation, hovering: hovering)
            }
            .padding(.vertical, 4)
            .frame(maxWidth: isUser ? 600 : 760, alignment: isUser ? .trailing : .leading)
            }
            if !isUser { Spacer(minLength: 80) }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
    }

    private func questionAnswerTranscript(for message: ChatMessage) -> String? {
        guard message.kind == .system,
              message.text.hasPrefix("Q: "),
              message.text.contains("\nA: ") else { return nil }
        return message.text
    }

    @ViewBuilder
    private func messageActions(_ message: ChatMessage, in conversation: Conversation, hovering: Bool) -> some View {
        if (message.kind == .user || message.kind == .assistant || message.kind == .plan),
           !message.streaming,
           !replyIsStillRunning(message, in: conversation),
           !isIntermediateReply(message, in: conversation) {
            let transcriptIndex = TranscriptIndex.of(conversation)
            let latestUser = transcriptIndex.latestUserID == message.id
            let displayedTimestamp = transcriptIndex.timestampByMessageID[message.id] ?? message.createdAt
            let turnStartedAt = transcriptIndex.turnStartedAtByMessageID[message.id]
            let isLongOperation = turnStartedAt.map {
                displayedTimestamp.timeIntervalSince($0) >= 60
            } ?? false
            let canEdit = latestUser && bridge.canEdit(messageID: message.id, in: conversation.id)
            let canRewind = message.kind == .user && bridge.canRewind(messageID: message.id, in: conversation.id)
            let hasText = !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let hasOutput = hasText || !message.mediaItems.isEmpty
            let speaking = model.isSpeaking(messageID: message.id)
            let canFeedback = bridge.workspacePath?.isEmpty == false && message.kind != .user && hasOutput
            let feedback = canFeedback ? bridge.feedback(for: message.id, in: conversation.id) : nil
            HStack(spacing: 16) {
                CopyFeedbackButton(text: message.text)

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

                    let canFork = bridge.canFork(messageID: message.id, in: conversation.id) && !model.isEditingMessage
                    actionButton("arrow.triangle.branch", AppCopy.text("conversation.fork")) {
                        model.forkConversation(beforeMessageID: message.id, in: conversation.id)
                    }
                    .disabled(!canFork)
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
                        actionButton("globe", AppCopy.text("conversation.translate")) {
                            toggleTranslation(id: message.id, text: message.text, model: model, translations: $translations, translating: $translating)
                        }
                            .foregroundStyle(translations[message.id] == nil ? Color.secondary : Color.accentColor)
                    }
                }
                if canFeedback {
                    feedbackButton(type: .good, selected: feedback?.feedbackType == .good, message: message, conversation: conversation)
                    feedbackButton(type: .bad, selected: feedback?.feedbackType == .bad, message: message, conversation: conversation)
                }
                messageTimestamp(displayedTimestamp, showAbsolute: isLongOperation)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.top, 2)
            .opacity(hovering ? 1 : 0.55)
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
        let index = TranscriptIndex.of(conversation)
        guard let messageIndex = index.position[message.id],
              let latestUserIndex = index.latestUserIndex else {
            return true
        }
        return messageIndex > latestUserIndex
    }

    /// Narration between tool runs ("now verifying…") is not the answer: only the
    /// turn's last reply carries the action bar, so one turn reads as one result.
    private func isIntermediateReply(_ message: ChatMessage, in conversation: Conversation) -> Bool {
        TranscriptIndex.of(conversation).intermediateReplyIDs.contains(message.id)
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

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()

    @ViewBuilder
    private func messageTimestamp(_ date: Date, showAbsolute: Bool) -> some View {
        if showAbsolute {
            Text(longOperationTimestamp(date))
                .font(.callout)
                .help(date.formatted(date: .complete, time: .complete))
                .accessibilityLabel(date.formatted(date: .complete, time: .complete))
        } else {
            TimelineView(.periodic(from: .now, by: 15)) { context in
                Text(Self.relativeFormatter.localizedString(for: date, relativeTo: context.date))
                    .font(.callout)
                    .help(date.formatted(date: .complete, time: .complete))
                    .accessibilityLabel(date.formatted(date: .complete, time: .complete))
            }
        }
    }

    private func longOperationTimestamp(_ date: Date) -> String {
        var calendar = Calendar.current
        calendar.locale = AppCopy.locale

        if calendar.isDateInToday(date) {
            return date.formatted(Date.FormatStyle(
                date: .omitted,
                time: .shortened,
                locale: AppCopy.locale
            ))
        }

        if calendar.isDateInYesterday(date) {
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.locale = AppCopy.locale
            formatter.doesRelativeDateFormatting = true
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            return formatter.string(from: date)
        }

        return date.formatted(Date.FormatStyle(
            date: .abbreviated,
            time: .shortened,
            locale: AppCopy.locale
        ))
    }

    private func liveActivityHeader(_ conversation: Conversation) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let skills = bridge.activeUsedSkillIDs
            let statusText = liveStatusText(
                start: conversation.runStartedAt,
                now: context.date,
                toolsRunning: false
            )
            HStack(alignment: .center, spacing: 7) {
                HerNessLoadingAnimation(size: 24)
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

    /// "2m 16s · 1.4K tokens · Running tools…"
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
        guard value >= 1_000 else { return "\(value)" }
        let divisor: Double
        let suffix: String
        if value >= 1_000_000_000 {
            divisor = 1_000_000_000
            suffix = "B"
        } else if value >= 1_000_000 {
            divisor = 1_000_000
            suffix = "M"
        } else {
            divisor = 1_000
            suffix = "K"
        }
        let count = String(format: "%.1f", Double(value) / divisor)
        return "\(count)\(suffix)"
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
            StillDisclosureGroup {
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
            StillDisclosureGroup {
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
                        if message.summary?.attributionKnown == false {
                            Label(AppCopy.text("conversation.filesAttributionUnknown"), systemImage: "questionmark.circle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 8)
                    Button { model.reviewPaneRequestID &+= 1 } label: {
                        Image(systemName: "sidebar.right")
                    }
                    .buttonStyle(.plain)
                    .help(KeyboardShortcutAction.review.title)
                    .accessibilityLabel(KeyboardShortcutAction.review.title)
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
                            if expanded { expandedFileMessageIDs.remove(message.id) }
                            else { expandedFileMessageIDs.insert(message.id) }
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
                            if expanded { expandedFileMessageIDs.remove(message.id) }
                            else { expandedFileMessageIDs.insert(message.id) }
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

        ChangedFileHoverPreview(file: file) {
            if let url, isAvailable {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    content
                }
                .buttonStyle(.plain)
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
        isRunning: Bool
    ) -> some View {
        // Harness plumbing (tool discovery, memory, plan) is noise to the user;
        // it surfaces only when it fails.
        let terminals = activityTerminalItems(messages).filter { !$0.isInternal || $0.isFailure }
        if !messages.isEmpty && (isRunning || !terminals.isEmpty) {
            VStack(alignment: .leading, spacing: 8) {
                PaginatedActivityDisclosure(items: terminals) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            if isRunning {
                                TimelineView(.periodic(from: .now, by: 1)) { context in
                                    HStack(spacing: 8) {
                                        HerNessLoadingAnimation(size: 24)
                                        Text(liveStatusText(start: bridge.activeRunStartedAt, now: context.date, toolsRunning: true))
                                        if let activeTool = messages.last(where: { $0.rawToolOutput == nil }) {
                                            Text("·").foregroundStyle(.tertiary)
                                            activityLabel(for: ConversationActivityCategory(toolName: toolName(from: activeTool.text)))
                                                .lineLimit(1)
                                                .truncationMode(.middle)
                                            // A long build or test shows its own clock, so a quiet
                                            // model never looks like a hung app.
                                            if context.date.timeIntervalSince(activeTool.createdAt) >= 10 {
                                                Text(elapsedText(from: activeTool.createdAt, now: context.date))
                                                    .monospacedDigit()
                                            }
                                            if context.date.timeIntervalSince(activeTool.createdAt) >= 60 {
                                                Text(activeTool.createdAt.formatted(date: .omitted, time: .shortened))
                                                    .monospacedDigit()
                                                    .help(activeTool.createdAt.formatted(date: .complete, time: .complete))
                                            }
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
                                Text(activitySummaryText(terminals))
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                let failures = terminals.filter(\.isFailure).count
                                if failures > 0 {
                                    Text(AppCopy.format("conversation.activity.failedCount", failures))
                                        .foregroundStyle(.red)
                                }
                            }
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
                } row: { item, _ in
                    activityTerminalCard(item)
                }
                .foregroundStyle(.secondary)
                .padding(.vertical, 6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func activityTerminalCard(_ item: ActivityTerminalItem) -> some View {
        StillDisclosureGroup {
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
                    let compactOutput = output.count <= 600 && output.split(whereSeparator: \.isNewline).count <= 8
                    Group {
                        if compactOutput {
                            Text(output)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(10)
                        } else {
                            ScrollView([.horizontal, .vertical]) {
                                Text(output)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.primary)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: true, vertical: false)
                                    .padding(10)
                            }
                            .frame(height: 220)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .textBackgroundColor).opacity(0.78), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.secondary.opacity(0.16), lineWidth: 1)
                    }
                } else if item.isRunning {
                    HStack(spacing: 8) {
                        HerNessLoadingAnimation(size: 18)
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
            HStack(spacing: 8) {
                Image(systemName: item.category.icon)
                    .font(.caption)
                    .foregroundStyle(item.isFailure ? Color.red : Color.secondary)
                    .frame(width: 16)

                Text(item.command ?? item.toolName)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)
                if item.command == nil, let detail = item.detail {
                    Text(detail)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 8)

                if item.isRunning {
                    HerNessLoadingAnimation(size: 14)
                } else {
                    if item.isFailure {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    // Instant tools need no clock; only slow ones earn one.
                    if let end = item.completedAt {
                        let duration = end.timeIntervalSince(item.startedAt)
                        if duration >= 1 {
                            Text(elapsedText(from: item.startedAt, now: end))
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(.tertiary)
                                .help(end.formatted(date: .complete, time: .complete))
                        }
                        if duration >= 60 {
                            Text(end.formatted(date: .numeric, time: .shortened))
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(.tertiary)
                                .help(end.formatted(date: .complete, time: .complete))
                        }
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .font(.callout)
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
    }

    private func activityTerminalItems(_ messages: ArraySlice<ChatMessage>) -> [ActivityTerminalItem] {
        var items: [ActivityTerminalItem] = []
        var pendingStart: ChatMessage?

        for message in messages {
            guard let output = message.rawToolOutput else {
                pendingStart = message
                continue
            }
            // A finished tool row never changes; parsing its JSON arguments on every
            // redraw was most of the transcript's per-frame cost during a run.
            let cacheKey = "\(pendingStart?.id ?? "")|\(message.id)|\(output.utf8.count)"
            if let cached = ActivityTerminalItem.finished[cacheKey] {
                items.append(cached)
                pendingStart = nil
                continue
            }

            let title = message.text.components(separatedBy: .newlines).first ?? message.text
            let startParts = pendingStart.map { runningToolParts($0.text) }
            let (resolvedToolName, arguments) = unwrapInvoke(toolName(from: title), startParts?.command)
            let item = ActivityTerminalItem(
                id: message.id,
                toolName: resolvedToolName,
                command: resolvedToolName == "run_command" ? startParts?.command : nil,
                detail: activityDetail(arguments),
                output: output,
                progressOutput: nil,
                startedAt: pendingStart?.createdAt ?? message.createdAt,
                completedAt: message.createdAt,
                isFailure: title.hasPrefix("✕ ")
            )
            // Bounded: rows hold tool output, so closed transcripts must not stay pinned in RAM.
            if ActivityTerminalItem.finished.count > 600 { ActivityTerminalItem.finished.removeAll() }
            ActivityTerminalItem.finished[cacheKey] = item
            items.append(item)
            pendingStart = nil
        }

        if let pendingStart {
            let parts = runningToolParts(pendingStart.text)
            let title = pendingStart.text.components(separatedBy: .newlines).first ?? pendingStart.text
            let (resolvedToolName, arguments) = unwrapInvoke(self.toolName(from: title), parts.command)
            items.append(ActivityTerminalItem(
                id: pendingStart.id,
                toolName: resolvedToolName,
                command: parts.command,
                detail: activityDetail(arguments),
                output: nil,
                progressOutput: parts.progress,
                startedAt: pendingStart.createdAt,
                completedAt: nil,
                isFailure: false
            ))
        }

        return items
    }

    /// invoke_tool is the deferred-tool gateway: show the tool it called, with that tool's arguments.
    private func unwrapInvoke(_ name: String, _ raw: String?) -> (String, String?) {
        guard name == DeferredToolSession.invokeName, let raw else { return (name, raw) }
        if !raw.hasPrefix("{"), let space = raw.firstIndex(of: " ") {
            return (String(raw[..<space]), String(raw[raw.index(after: space)...]))
        }
        if let data = raw.data(using: .utf8),
           let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let inner = object["name"] as? String {
            return (inner, object["arguments"] as? String)
        }
        // Long arguments arrive clipped, so the JSON no longer parses; the name still leads.
        if let match = raw.firstMatch(of: /"name"\s*:\s*"([^"]+)"/) { return (String(match.1), nil) }
        return (name, nil)
    }

    /// The one argument that says what a tool touched: path, pattern, query or URL.
    private func activityDetail(_ raw: String?) -> String? {
        guard let raw else { return nil }
        guard let data = raw.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return raw.hasPrefix("{") ? nil : raw
        }
        for key in ["pattern", "query", "url", "path", "glob", "name"] {
            if let value = object[key] as? String, !value.isEmpty { return value }
        }
        return nil
    }

    /// "Ran 4 commands · Read 2 files", categories in the order they first ran.
    private func activitySummaryText(_ items: [ActivityTerminalItem]) -> String {
        var order: [ConversationActivityCategory] = []
        var counts: [ConversationActivityCategory: Int] = [:]
        for item in items {
            if counts[item.category] == nil { order.append(item.category) }
            counts[item.category, default: 0] += 1
        }
        return order.map { category in
            let count = counts[category] ?? 0
            return AppCopy.format(category.countKey + (count == 1 ? ".one" : ".many"), count)
        }
        .joined(separator: " · ")
    }

    private func activityLabel(for category: ConversationActivityCategory) -> some View {
        HStack(spacing: 6) {
            Image(systemName: category.icon)
                .font(.caption)
                .foregroundStyle(Color.accentColor.opacity(0.9))
            Text(AppCopy.text(category.runningKey))
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

    /// The card closes the turn: it sits on the turn's last message that carries
    /// changed files, under the reply text, never above it.
    private func shouldShowChangedFilesOnMessage(_ message: ChatMessage, in conversation: Conversation) -> Bool {
        // Without files the disclosure is empty; skip the O(n) scan for every bubble.
        guard !message.changedFiles.isEmpty else { return false }
        guard let turnID = message.turnID else { return true }
        return conversation.messages.last { $0.turnID == turnID && !$0.changedFiles.isEmpty }?.id == message.id
    }

    @ViewBuilder
    private func mediaView(_ media: ChatMedia) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            switch media.kind {
            case .image:
                if let image = ImageFileCache.image(at: media.url) {
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
            case .audio, .music:
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
    private func attachmentViews(_ attachments: [ChatAttachment], isUser: Bool = false) -> some View {
        if isUser, attachments.count == 1, let attachment = attachments.first, attachment.kind == .image {
            attachmentCard(attachment)
                .frame(maxWidth: 600, alignment: .trailing)
        } else {
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(attachments) { attachment in
                        attachmentCard(attachment)
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.visible, axes: .horizontal)
            .frame(maxWidth: 600, alignment: .leading)
        }
    }

    private func attachmentCard(_ attachment: ChatAttachment) -> some View {
        Button {
            NSWorkspace.shared.open(attachment.url)
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                if attachment.kind == .image, let image = ImageFileCache.image(at: attachment.url) {
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
        .help(attachmentHoverText(attachment))
        .accessibilityLabel(attachment.name)
    }

    private func attachmentHoverText(_ attachment: ChatAttachment) -> String {
        [
            attachment.name,
            "\(attachment.kind.rawValue) · \(attachment.mimeType)",
            attachment.url.path,
        ].joined(separator: "\n")
    }

    @ViewBuilder
    private func pendingPromptBubble(_ prompt: PendingPrompt, in conversation: Conversation) -> some View {
        let isStarting = bridge.isStartingPrompt(prompt.id, in: conversation.id)
        if prompt.mode == .queue && !isStarting {
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
        let isStarting = bridge.isStartingPrompt(prompt.id, in: conversation.id)
        return HStack {
            Spacer(minLength: 80)
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 7) {
                    if isStarting {
                        ProgressView()
                            .controlSize(.small)
                    } else {
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
            .background(Color.accentColor.opacity(isStarting ? 0.12 : 0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.accentColor.opacity(0.22), style: StrokeStyle(lineWidth: 1, dash: isStarting ? [] : [5, 4]))
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
        if conversation.running,
           bridge.liveReplyParagraphs(for: conversation.id)?.isEmpty == false {
            targetID = "live-reply-bottom-\(conversation.id)"
        } else if last.kind == .tool {
            var start = conversation.messages.count - 1
            while start > 0, conversation.messages[start - 1].kind == .tool {
                start -= 1
            }
            targetID = "activity-\(conversation.messages[start].id)"
        } else {
            targetID = last.id
        }
        // dispatch next runloop so the transcript layout is committed before scrolling
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

    /// Coalesce per-token transcript updates into at most one nonanimated scroll
    /// every 120 ms. Animated scrolling for every text change can repeatedly
    /// trigger expensive transcript layout work.
    private func scheduleStreamingScroll(
        using proxy: ScrollViewProxy,
        conversation: Conversation
    ) {
        guard streamingScrollTask == nil else { return }
        let conversationID = conversation.id
        streamingScrollTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120_000_000)
            defer { streamingScrollTask = nil }
            guard !Task.isCancelled,
                  model.selected?.id == conversationID,
                  let selected = model.selected,
                  selected.running else { return }
            scrollToLast(using: proxy, conversation: selected, animated: false)
        }
    }

    private func loadOlderMessages(_ conversation: Conversation) {
        guard !isLoadingOlderMessages,
              conversation.hasOlderTranscriptMessages,
              !conversation.messages.isEmpty else { return }
        let requestID = UUID()
        olderPageLoadID = requestID
        isLoadingOlderMessages = true
        let messages = conversation.messages
        if let first = messages.first {
            if first.kind == .tool {
                let firstNonTool = messages.firstIndex { $0.kind != .tool }
                if let firstNonTool {
                    olderPageAnchorID = messages[firstNonTool].id
                } else {
                    olderPageAnchorID = "activity-\(first.id)"
                }
            } else {
                olderPageAnchorID = first.id
            }
        }
        Task { @MainActor in
            let loaded = await bridge.loadOlderMessages(
                in: conversation.id,
                limit: Self.messagePageSize
            )
            guard olderPageLoadID == requestID,
                  model.selected?.id == conversation.id else { return }
            if !loaded {
                olderPageAnchorID = nil
            }
            olderPageLoadID = nil
            isLoadingOlderMessages = false
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
        SafeURL.openWeb(url)
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

/// Positions the transcript helpers need, computed once per message list instead of
/// once per bubble: each was an O(n) scan, so a long run's transcript cost O(n²) per redraw.
@MainActor
private enum TranscriptIndex {
    struct Value {
        var position: [String: Int] = [:]
        var timestampByMessageID: [String: Date] = [:]
        var turnStartedAtByMessageID: [String: Date] = [:]
        var latestUserIndex: Int?
        var latestUserID: String?
        var intermediateReplyIDs: Set<String> = []
    }

    // ponytail: one slot; only the selected transcript renders. Keyed on shape, not content:
    // a message's id and kind never change, and edits, rewinds and paging change the shape.
    private static var key = ""
    private static var value = Value()

    static func of(_ conversation: Conversation) -> Value {
        let messages = conversation.messages
        let key = "\(conversation.id)|\(messages.count)|\(messages.first?.id ?? "")|\(messages.last?.id ?? "")"
        if key == self.key { return value }
        var next = Value()
        var previousTimestamp: Date?
        var latestUserTimestamp: Date?
        for message in messages {
            let timestamp = max(message.createdAt, previousTimestamp ?? message.createdAt)
            next.timestampByMessageID[message.id] = timestamp
            switch message.kind {
            case .user:
                latestUserTimestamp = timestamp
            case .assistant, .plan:
                if let latestUserTimestamp {
                    next.turnStartedAtByMessageID[message.id] = latestUserTimestamp
                }
            default:
                break
            }
            previousTimestamp = timestamp
        }
        // Walking backwards: was an assistant or plan reply seen before the next user message?
        var laterReply = false
        for (index, message) in messages.enumerated().reversed() {
            next.position[message.id] = index
            switch message.kind {
            case .user:
                if next.latestUserIndex == nil {
                    next.latestUserIndex = index
                    next.latestUserID = message.id
                }
                laterReply = false
            case .assistant, .plan:
                if message.kind == .assistant, laterReply { next.intermediateReplyIDs.insert(message.id) }
                laterReply = true
            default:
                break
            }
        }
        self.key = key
        value = next
        return next
    }
}

private struct ActivityTerminalItem: Identifiable {
    let id: String
    let toolName: String
    let command: String?
    let detail: String?
    let output: String?
    let progressOutput: String?
    let startedAt: Date
    let completedAt: Date?
    let isFailure: Bool

    /// Parsed finished rows, keyed by start id, result id and output size.
    @MainActor static var finished: [String: ActivityTerminalItem] = [:]

    var isRunning: Bool { completedAt == nil }
    var category: ConversationActivityCategory { ConversationActivityCategory(toolName: toolName) }
    /// Harness plumbing the user never asked for.
    var isInternal: Bool {
        [DeferredToolSession.searchName, DeferredToolSession.outputName, DeferredToolSession.planName,
         RecallTool.name, RememberTool.name, PlanStepsTool.name].contains(toolName)
    }
}

/// Expanding tool activity is isolated from the transcript view and reveals a
/// small page of tool cards at a time, keeping large tool runs responsive.
private struct PaginatedActivityDisclosure<Label: View, Row: View>: View {
    private static var pageSize: Int { 10 }

    let items: [ActivityTerminalItem]
    let label: Label
    let row: (ActivityTerminalItem, Int) -> Row

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
        StillDisclosureGroup(trailingChevron: true) {
            VStack(alignment: .leading, spacing: 0) {
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
            .padding(.leading, 4)
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

    /// Prefix of the ".one" / ".many" count keys in the collapsed summary.
    var countKey: String { "conversation.activity.count.\(rawValue)" }

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

/// A full-width header button makes each disclosure easy to collapse from its title.
/// State changes stay instant in the lazy transcript, and collapsed content is not built.
struct StillDisclosureGroup<Label: View, Content: View>: View {
    /// Quiet one-line summaries read as "Ran 4 commands ›", chevron after the text.
    var trailingChevron = false
    @ViewBuilder let content: () -> Content
    @ViewBuilder let label: () -> Label
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) { isExpanded.toggle() }
            } label: {
                HStack(spacing: trailingChevron ? 5 : 8) {
                    if !trailingChevron { chevron.frame(width: 14) }
                    if trailingChevron {
                        label()
                        chevron
                        Spacer(minLength: 0)
                    } else {
                        label()
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)

            if isExpanded { content() }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var chevron: some View {
        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
    }
}

/// Hover state of one bubble. Held on the transcript it re-rendered every visible
/// message each time the pointer crossed a bubble edge.
private struct HoverScope<Content: View>: View {
    @ViewBuilder let content: (Bool) -> Content
    @State private var hovering = false

    var body: some View {
        content(hovering).onHover { hovering = $0 }
    }
}

/// The reply while the provider is still writing it. A view of its own, so a
/// delta re-renders this bubble and not the transcript above it.
private struct LiveReplyView: View {
    let bridge: AgentBridge
    let conversationID: String
    let onTextChange: () -> Void

    var body: some View {
        let paragraphs = bridge.liveReplyParagraphs(for: conversationID)
        return Group {
            if let paragraphs, !paragraphs.isEmpty {
                // Each paragraph is an independent Markdown view. Completed
                // paragraphs stay cached; only the paragraph receiving tokens is reparsed.
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(paragraphs) { paragraph in
                        LiveReplyParagraphView(paragraph: paragraph)
                    }
                }
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
        .overlay(alignment: .bottom) {
            LiveReplyTailAnchor(
                conversationID: conversationID,
                paragraph: paragraphs?.last,
                onTextChange: onTextChange
            )
        }
    }
}

/// Observes the changing tail outside the paragraph list, so token updates scroll
/// the transcript without invalidating the parent that owns completed paragraphs.
private struct LiveReplyTailAnchor: View {
    let conversationID: String
    let paragraph: LiveReplyParagraph?
    let onTextChange: () -> Void

    var body: some View {
        Color.clear
            .frame(height: 1)
            .id("live-reply-bottom-\(conversationID)")
            .onChange(of: paragraph?.text) { _, _ in onTextChange() }
    }
}

private struct LiveReplyParagraphView: View {
    let paragraph: LiveReplyParagraph

    var body: some View {
        PlanMarkdownView(text: paragraph.text, caches: paragraph.isComplete)
            .lineSpacing(3)
            .textSelection(.enabled)
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

/// Precomputed previews are shown in a native popover after a short hover delay.
/// The card reads only the bounded diff stored with the message.
private struct ChangedFileHoverPreview<Content: View>: View {
    let file: ChangedFile
    @ViewBuilder let content: () -> Content
    @State private var isHoveringRow = false
    @State private var isHoveringCard = false
    @State private var isPresented = false

    var body: some View {
        content()
            .onHover { hovering in
                isHoveringRow = hovering
                schedulePresentationUpdate(delay: hovering ? 0.28 : 0.18)
            }
            .popover(isPresented: $isPresented, arrowEdge: .leading) {
                ChangedFileDiffPreviewCard(file: file)
                    .onHover { hovering in
                        isHoveringCard = hovering
                        schedulePresentationUpdate(delay: hovering ? 0.05 : 0.18)
                    }
            }
    }

    private func schedulePresentationUpdate(delay: TimeInterval) {
        guard let preview = file.preview, !preview.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            isPresented = isHoveringRow || isHoveringCard
        }
    }
}

private struct ChangedFileDiffPreviewCard: View {
    let file: ChangedFile

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(file.path)
                    .font(.system(.callout, design: .monospaced))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if file.addedLines >= 0, file.deletedLines >= 0 {
                    Text("+\(file.addedLines)")
                        .foregroundStyle(.green)
                        .font(.system(.callout, design: .monospaced).monospacedDigit())
                    Text("−\(file.deletedLines)")
                        .foregroundStyle(.red)
                        .font(.system(.callout, design: .monospaced).monospacedDigit())
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)

            Divider()

            ScrollView([.horizontal, .vertical]) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array((file.preview ?? "").split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) { row in
                        let line = String(row.element)
                        Text(line.isEmpty ? " " : line)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(line.hasPrefix("+") ? Color.green : line.hasPrefix("−") ? Color.red : Color.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 1)
                            .background(line.hasPrefix("+") ? Color.green.opacity(0.10) : line.hasPrefix("−") ? Color.red.opacity(0.10) : Color.clear)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: 720, maxHeight: 460, alignment: .topLeading)
        }
        .frame(width: 660, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.22), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

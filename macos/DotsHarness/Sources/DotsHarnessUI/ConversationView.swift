// Copyright (c) 2026 DOTS
// Native conversation surface.

import AppKit
import AVKit
import SwiftUI
import UniformTypeIdentifiers
import DotsHarnessCore
import HarnessPluginKit

struct ConversationView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var bridge: AgentBridge
    @ObservedObject private var speech: LocalSpeechSynthesizer
    @ObservedObject private var terminalManager: TerminalManager

    @State private var isTerminalVisible = false
    @State private var isPanePickerVisible = false
    @State private var isNewPaneMenuPresented = false
    @State private var isWorkspaceExpanded = false
    @State private var isDropTargeted = false
    @State private var draggedPromptID: String?
    @State private var expandedActivityIDs = Set<String>()
    @State private var expandedFileMessageIDs = Set<String>()
    @State private var expandedUsedMessageIDs = Set<String>()
    @State private var hoveredMessageID: String?
    @State private var previousWindowFrame: NSRect?

    init(model: AppModel) {
        self.model = model
        self.bridge = model.bridge
        self._speech = ObservedObject(wrappedValue: model.speech)
        self._terminalManager = ObservedObject(wrappedValue: model.terminalManager)
    }

    var body: some View {
        VStack(spacing: 0) {
            paneToolbar
            Divider()

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
        .navigationTitle(model.selected?.title ?? AppCopy.text("conversation.newChat"))
        .toolbar {
            ToolbarItem(placement: .principal) {
                if let connection = bridge.connection {
                    Label(connection.model, systemImage: "cpu")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onChange(of: model.selected?.id) { _, id in
            if id != nil {
                isPanePickerVisible = false
            }
        }
        .onChange(of: model.workspacePath) { _, path in
            if path.isEmpty {
                isTerminalVisible = false
            }
        }
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isDropTargeted, perform: handleDrop)
    }

    private var paneToolbar: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)

            PaneToolbarButton(
                systemImage: "arrow.up.left.and.arrow.down.right",
                help: AppCopy.text("conversation.expandWorkspace"),
                isSelected: isWorkspaceExpanded
            ) {
                toggleWindowZoom()
            }

            PaneToolbarButton(
                systemImage: "rectangle.bottomhalf.inset.filled",
                help: AppCopy.text("conversation.openTerminal"),
                isSelected: isTerminalVisible
            ) {
                openTerminal(createNew: false)
            }
            .disabled(model.workspacePath.isEmpty)

            PaneToolbarButton(
                systemImage: "rectangle.split.2x1",
                help: AppCopy.text("conversation.choosePane"),
                isSelected: isPanePickerVisible
            ) {
                isPanePickerVisible.toggle()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(height: 44)
        .background(Color(nsColor: .windowBackgroundColor))
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
                    conversationBody(conversation)
                } else {
                    emptyConversation
                }
            }

            if isPanePickerVisible {
                panePickerSurface
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
                    ForEach(Array(conversation.messages.enumerated()), id: \.element.id) { index, message in
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
            .background(Color(nsColor: .windowBackgroundColor))
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

    private var emptyConversation: some View {
        VStack(spacing: 14) {
            Image(systemName: model.workspacePath.isEmpty ? "folder.badge.questionmark" : "sparkles.rectangle.stack")
                .font(.system(size: 42, weight: .medium))
                .foregroundStyle(.tint)
            Text(model.workspacePath.isEmpty
                ? AppCopy.text("conversation.chooseWorkspace")
                : AppCopy.text("conversation.startConversation"))
                .font(.title2.weight(.semibold))
            Text(emptyDescription)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 440)
            if model.workspacePath.isEmpty {
                Button(AppCopy.text("conversation.chooseWorkspaceButton"), action: model.chooseWorkspace)
                    .buttonStyle(.borderedProminent)
                Button(AppCopy.text("sidebar.continueWithoutProject"), action: model.startWithoutProject)
                    .buttonStyle(.bordered)
            } else if bridge.connection == nil {
                Text(AppCopy.text("conversation.connectProvider"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Button(AppCopy.text("conversation.newChat"), action: model.newConversation)
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    private var panePickerSurface: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            panePicker()
                .frame(maxWidth: 540)
            Spacer()
                .frame(height: 68)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 52)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func panePicker(createTerminal: Bool = false) -> some View {
        VStack(spacing: 4) {
            PaneChoiceRow(
                systemImage: "folder",
                title: AppCopy.text("conversation.files"),
                shortcut: "⌘P"
            ) {
                openFiles()
            }
            .keyboardShortcut("p", modifiers: .command)

            PaneChoiceRow(
                systemImage: "globe",
                title: AppCopy.text("conversation.browser"),
                shortcut: "⌘T"
            ) {
                openBrowser()
            }
            .keyboardShortcut("t", modifiers: .command)

            PaneChoiceRow(
                systemImage: "terminal",
                title: AppCopy.text("conversation.terminal"),
                shortcut: "⌃`"
            ) {
                openTerminal(createNew: createTerminal)
            }
            .disabled(model.workspacePath.isEmpty)
        }
        .padding(8)
        .background(
            Color(nsColor: .controlBackgroundColor).opacity(0.96),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.07), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.22), radius: 18, y: 8)
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
                            terminalManager.selectSession(session.id, for: model.workspacePath)
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
                            terminalManager.closeSession(session, for: model.workspacePath)
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

    private var emptyDescription: String {
        if model.workspacePath.isEmpty {
            return AppCopy.text("conversation.emptyWorkspaceDescription")
        }
        if bridge.connection == nil {
            return AppCopy.text("conversation.workspaceReadyDescription")
        }
        return AppCopy.text("conversation.noChatsDescription")
    }

    private var workspaceName: String {
        guard !model.workspacePath.isEmpty else { return AppCopy.text("conversation.workspace") }
        return URL(fileURLWithPath: model.workspacePath).lastPathComponent
    }

    private var terminalSessions: [TerminalSession] {
        terminalManager.sessions(for: model.workspacePath)
    }

    private var selectedTerminal: TerminalSession? {
        terminalManager.selectedSession(for: model.workspacePath)
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
                    messageActions(message, in: conversation)
                }
                PlanMarkdownView(text: message.text)
                    .textSelection(.enabled)
                usedItemsDisclosure(for: message)
                changedFilesDisclosure(for: message)
                messageTimestamp(message.createdAt)
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
            if isUser { Spacer(minLength: 80) }
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
                        Spacer(minLength: 0)
                        if !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Button {
                                model.toggleSpeech(message.text, messageID: message.id)
                            } label: {
                                Image(systemName: speech.activeMessageID == message.id ? "stop.circle.fill" : "speaker.wave.2")
                                    .font(.caption.weight(.semibold))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .help(speech.activeMessageID == message.id
                                ? AppCopy.text("conversation.stopSpeaking")
                                : "\(AppCopy.text("conversation.speakResponse")) (AI)")
                            .accessibilityLabel(speech.activeMessageID == message.id
                                ? AppCopy.text("conversation.stopSpeaking")
                                : "\(AppCopy.text("conversation.speakResponse")) (AI)")
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
                usedItemsDisclosure(for: message)
                changedFilesDisclosure(for: message)
                if !message.attachments.isEmpty {
                    attachmentViews(message.attachments)
                }
                if let media = message.media {
                    mediaView(media)
                }
                messageTimestamp(message.createdAt)
            }
            .padding(.horizontal, isAssistant ? 0 : 15)
            .padding(.vertical, isAssistant ? 4 : 12)
            .background(
                isAssistant ? Color.clear : fill(for: message.kind),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .frame(maxWidth: isUser ? 600 : 760, alignment: .leading)
            .overlay(alignment: .topTrailing) {
                messageActions(message, in: conversation)
                    .padding(.top, 5)
                    .padding(.trailing, 8)
            }
            .onHover { hovered in
                hoveredMessageID = hovered ? message.id : nil
            }
            if !isUser { Spacer(minLength: 80) }
        }
    }

    @ViewBuilder
    private func messageActions(_ message: ChatMessage, in conversation: Conversation) -> some View {
        if message.kind == .user || message.kind == .assistant || message.kind == .plan {
            let latestUser = conversation.messages.last(where: { $0.kind == .user })?.id == message.id
            let canEdit = latestUser && bridge.canEdit(messageID: message.id, in: conversation.id)
            let canRewind = message.kind == .user && bridge.canRewind(messageID: message.id, in: conversation.id)
            HStack(spacing: 2) {
                Button {
                    copyMessage(message)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.plain)
                .accessibilityLabel(AppCopy.text("conversation.copy"))
                .help(AppCopy.text("conversation.copy"))

                if message.kind == .user, latestUser {
                    Button {
                        model.beginEditing(message)
                    } label: {
                        Image(systemName: "pencil")
                    }
                    .buttonStyle(.plain)
                    .disabled(!canEdit)
                    .accessibilityLabel(AppCopy.text("conversation.edit"))
                    .help(actionHelp("conversation.edit", available: canEdit))
                }

                if message.kind == .user {
                    Button {
                        model.rewind(messageID: message.id)
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .buttonStyle(.plain)
                    .disabled(!canRewind)
                    .accessibilityLabel(AppCopy.text("conversation.rewind"))
                    .help(actionHelp("conversation.rewind", available: canRewind))
                }
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(4)
            .background(.regularMaterial, in: Capsule())
            .opacity(hoveredMessageID == message.id ? 1 : 0.16)
        }
    }

    private func actionHelp(_ key: String, available: Bool) -> String {
        if available { return AppCopy.text(key) }
        if bridge.isBusy || bridge.historyMutationBusy {
            return AppCopy.text("conversation.historyBusy")
        }
        return AppCopy.text("conversation.historyUnavailable")
    }

    private func copyMessage(_ message: ChatMessage) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message.text, forType: .string)
    }

    private func messageTimestamp(_ date: Date) -> some View {
        Text(date.formatted(date: .omitted, time: .shortened))
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .help(date.formatted(date: .complete, time: .complete))
            .accessibilityLabel(date.formatted(date: .complete, time: .complete))
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
        switch media.kind {
        case .image:
            if let image = NSImage(contentsOf: media.url) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 620, maxHeight: 520)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                Text(AppCopy.text("media.fileMissing"))
                    .foregroundStyle(.secondary)
            }
        case .video:
            if FileManager.default.fileExists(atPath: media.path) {
                VideoPlayer(player: AVPlayer(url: media.url))
                    .frame(maxWidth: 620, minHeight: 260, maxHeight: 420)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                Text(AppCopy.text("media.fileMissing"))
                    .foregroundStyle(.secondary)
            }
        case .audio:
            Button {
                NSWorkspace.shared.open(media.url)
            } label: {
                Label(AppCopy.text("media.openAudio"), systemImage: "waveform")
            }
            .buttonStyle(.bordered)
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
                            Image(systemName: attachmentIcon(for: attachment))
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

    private func attachmentIcon(for attachment: ChatAttachment) -> String {
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

    private func scrollToLast(using proxy: ScrollViewProxy, conversation: Conversation) {
        if let last = conversation.messages.last {
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

    private func fill(for kind: ChatMessage.Kind) -> Color {
        switch kind {
        case .user: return Color.accentColor.opacity(0.12)
        case .assistant: return Color.primary.opacity(0.055)
        case .plan: return Color.yellow.opacity(0.11)
        case .tool: return Color.orange.opacity(0.11)
        case .system: return Color.red.opacity(0.10)
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
        guard !model.workspacePath.isEmpty else {
            model.chooseWorkspace()
            return
        }
        isTerminalVisible = true
        if createNew || terminalSessions.isEmpty {
            _ = terminalManager.openSession(for: model.workspacePath)
        }
    }

    private func closeTerminal() {
        isNewPaneMenuPresented = false
        isTerminalVisible = false
    }

    private func toggleWindowZoom() {
        guard let window = NSApplication.shared.keyWindow ?? NSApplication.shared.mainWindow,
              let screen = window.screen ?? NSScreen.main else {
            return
        }

        if isWorkspaceExpanded {
            if let previousWindowFrame {
                window.setFrame(previousWindowFrame, display: true, animate: true)
            }
            isWorkspaceExpanded = false
            return
        }

        previousWindowFrame = window.frame
        window.setFrame(screen.visibleFrame, display: true, animate: true)
        isWorkspaceExpanded = true
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

private struct PaneToolbarButton: View {
    let systemImage: String
    let help: String
    var isSelected = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 27, height: 27)
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.accentColor, lineWidth: 1.5)
                    }
                }
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .help(help)
    }
}

private struct PaneChoiceRow: View {
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
            .frame(height: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(PaneChoiceButtonStyle())
    }
}

private struct PaneChoiceButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                Color.primary.opacity(configuration.isPressed ? 0.12 : 0),
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .opacity(configuration.isPressed ? 0.82 : 1)
    }
}

private struct TerminalView: View {
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

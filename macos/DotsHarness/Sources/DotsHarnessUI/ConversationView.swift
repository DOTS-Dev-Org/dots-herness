// Copyright (c) 2026 DOTS
// Native conversation surface.

import AppKit
import SwiftUI
import DotsHarnessCore
import HarnessPluginKit

struct ConversationView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var bridge: AgentBridge
    @ObservedObject private var speech: LocalSpeechSynthesizer

    @StateObject private var terminalSession = TerminalSession()
    @State private var isTerminalVisible = false
    @State private var isPanePickerVisible = false
    @State private var isNewPaneMenuPresented = false
    @State private var isWorkspaceExpanded = false
    @State private var previousWindowFrame: NSRect?

    init(model: AppModel) {
        self.model = model
        self.bridge = model.bridge
        self._speech = ObservedObject(wrappedValue: model.speech)
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
        .onDisappear {
            terminalSession.stop()
        }
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
                openTerminal()
            }

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
                    ForEach(conversation.messages) { message in
                        messageBubble(message)
                            .id(message.id)
                    }
                    ForEach(conversation.pendingPrompts) { prompt in
                        pendingBubble(prompt)
                            .id(prompt.id)
                    }
                    if bridge.isBusy {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(AppCopy.text("conversation.working"))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 4)
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
            panePicker
                .frame(maxWidth: 540)
            Spacer()
                .frame(height: 68)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 52)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var panePicker: some View {
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
                openTerminal()
            }
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
                    panePicker
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

            TerminalView(session: terminalSession)
        }
        .background(Color(nsColor: .textBackgroundColor))
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

    private func messageBubble(_ message: ChatMessage) -> some View {
        let isUser = message.kind == .user
        return HStack {
            if isUser { Spacer(minLength: 80) }
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 7) {
                    Image(systemName: icon(for: message.kind))
                        .font(.caption.weight(.semibold))
                    Text(label(for: message.kind))
                        .font(.caption.weight(.semibold))
                    if message.streaming {
                        ProgressView().controlSize(.mini)
                    }
                    if message.kind == .assistant,
                       !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Spacer(minLength: 0)
                        Button {
                            speech.toggle(message.text, messageID: message.id)
                        } label: {
                            Image(systemName: speech.activeMessageID == message.id ? "stop.circle.fill" : "speaker.wave.2")
                                .font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                                .help(speech.activeMessageID == message.id
                                    ? AppCopy.text("conversation.stopSpeaking")
                                    : AppCopy.text("conversation.speakResponse"))
                    }
                }
                .foregroundStyle(isUser ? Color.accentColor : .secondary)
                Text(message.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .font(message.kind == .tool ? .callout.monospaced() : .body)
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 12)
            .background(fill(for: message.kind), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .frame(maxWidth: isUser ? 600 : 760, alignment: .leading)
            if !isUser { Spacer(minLength: 80) }
        }
    }

    private func pendingBubble(_ prompt: PendingPrompt) -> some View {
        HStack {
            Spacer(minLength: 80)
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 7) {
                    Image(systemName: prompt.mode == .steer ? "bolt.fill" : "clock.fill")
                        .font(.caption.weight(.semibold))
                    Text(prompt.mode == .steer
                        ? AppCopy.text("conversation.priorityInstruction")
                        : AppCopy.text("conversation.queuedMessage"))
                        .font(.caption.weight(.semibold))
                    Text(prompt.mode == .steer
                        ? AppCopy.text("conversation.interrupting")
                        : AppCopy.text("conversation.waiting"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(prompt.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
            withAnimation(.easeOut(duration: 0.18)) {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }

    private func label(for kind: ChatMessage.Kind) -> String {
        switch kind {
        case .user: return AppCopy.text("conversation.you")
        case .assistant: return AppCopy.text("conversation.assistant")
        case .tool: return AppCopy.text("conversation.tool")
        case .system: return AppCopy.text("conversation.notice")
        }
    }

    private func icon(for kind: ChatMessage.Kind) -> String {
        switch kind {
        case .user: return "person.fill"
        case .assistant: return "sparkles"
        case .tool: return "terminal"
        case .system: return "info.circle"
        }
    }

    private func fill(for kind: ChatMessage.Kind) -> Color {
        switch kind {
        case .user: return Color.accentColor.opacity(0.12)
        case .assistant: return Color.primary.opacity(0.055)
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

    private func openTerminal() {
        isPanePickerVisible = false
        isNewPaneMenuPresented = false
        isTerminalVisible = true
        if !terminalSession.isRunning {
            terminalSession.start(workingDirectory: workingDirectory)
        }
    }

    private func closeTerminal() {
        isNewPaneMenuPresented = false
        terminalSession.stop()
        isTerminalVisible = false
    }

    private var workingDirectory: String {
        model.workspacePath.isEmpty
            ? FileManager.default.homeDirectoryForCurrentUser.path
            : model.workspacePath
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

@MainActor
private final class TerminalSession: ObservableObject {
    @Published private(set) var output = ""
    @Published private(set) var isRunning = false

    private var process: Process?
    private var inputPipe: Pipe?
    private var outputPipe: Pipe?
    private var prompt = ""

    func start(workingDirectory: String) {
        stop()
        output = ""

        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let directory = URL(fileURLWithPath: workingDirectory, isDirectory: true)
        prompt = shellPrompt(for: workingDirectory)
        self.output = "\(prompt) "

        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        // A GUI-launched process has no terminal of its own. Keep one shell
        // alive and evaluate submitted lines so commands such as `cd` retain
        // their state without asking zsh to enable job control on a pipe.
        process.arguments = ["-f", "-c", "while IFS= read -r line; do eval \"$line\"; done"]
        process.currentDirectoryURL = directory
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output

        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["TERM_PROGRAM"] = "DotsHarness"
        environment["PS1"] = ""
        process.environment = environment

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            Task { @MainActor [weak self] in
                self?.append(data)
            }
        }
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.isRunning = false
            }
        }

        do {
            try process.run()
            self.process = process
            self.inputPipe = input
            self.outputPipe = output
            isRunning = true
        } catch {
            self.output = AppCopy.format("conversation.terminalStartError", error.localizedDescription) + "\n"
            self.isRunning = false
        }
    }

    func send(_ command: String) {
        guard isRunning, let inputPipe else { return }
        let line = command + "\n"
        guard let data = line.data(using: .utf8) else { return }
        output.append("\(command)\n")
        try? inputPipe.fileHandleForWriting.write(contentsOf: data)
    }

    func stop() {
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        if let process, process.isRunning {
            process.terminate()
        }
        process = nil
        inputPipe = nil
        outputPipe = nil
        isRunning = false
    }

    private func shellPrompt(for directory: String) -> String {
        let user = NSUserName()
        let host = Host.current().localizedName
            ?? ProcessInfo.processInfo.hostName
        let folder = URL(fileURLWithPath: directory).lastPathComponent
        return "\(user)@\(host) \(folder) %"
    }

    private func append(_ data: Data) {
        let text = String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "\r", with: "")
        guard !text.isEmpty else { return }
        output.append(text)
        if output.count > 200_000 {
            output = String(output.suffix(180_000))
        }
    }
}

private struct TerminalView: View {
    @ObservedObject var session: TerminalSession
    @State private var command = ""
    @FocusState private var commandFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    Text(session.output.isEmpty ? AppCopy.text("conversation.startingShell") : session.output)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .id("terminal-tail")
                }
                .onChange(of: session.output) { _, _ in
                    withAnimation(.easeOut(duration: 0.08)) {
                        proxy.scrollTo("terminal-tail", anchor: .bottom)
                    }
                }
            }

            Divider()

            HStack(spacing: 8) {
                Text("›")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                TextField(AppCopy.text("conversation.enterCommand"), text: $command)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .focused($commandFocused)
                    .onSubmit(runCommand)
                Button(action: runCommand) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 11, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onAppear {
            commandFocused = true
        }
    }

    private func runCommand() {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        session.send(trimmed)
        command = ""
    }
}

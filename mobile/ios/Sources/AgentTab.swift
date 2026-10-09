import SwiftUI
import AVFAudio
import Speech

@MainActor
private final class MobileSpeechInput: ObservableObject {
    @Published private(set) var isListening = false
    @Published private(set) var recognizedText = ""

    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var sessionID: UUID?
    private var startRequestID: UUID?
    private var hasInstalledInputTap = false
    private var baseText = ""

    func start(currentText: String, locale: Locale) {
        guard !isListening else { return }
        recognizedText = currentText
        baseText = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestID = UUID()
        startRequestID = requestID
        Task { await begin(locale: locale, requestID: requestID) }
    }

    func stop() {
        startRequestID = nil
        sessionID = nil
        isListening = false
        if hasInstalledInputTap {
            audioEngine.inputNode.removeTap(onBus: 0)
            hasInstalledInputTap = false
        }
        audioEngine.stop()
        recognitionRequest?.endAudio()
        recognitionTask?.finish()
        recognitionRequest = nil
        recognitionTask = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func begin(locale: Locale, requestID: UUID) async {
        let authorization = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard startRequestID == requestID, authorization == .authorized else { return }
        let microphoneAuthorized = await AVAudioApplication.requestRecordPermission()
        guard startRequestID == requestID,
              microphoneAuthorized,
              let recognizer = SFSpeechRecognizer(locale: locale),
              recognizer.isAvailable else { return }
        startRequestID = nil

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        recognitionRequest = request
        let currentSession = UUID()
        sessionID = currentSession

        let input = audioEngine.inputNode
        input.installTap(onBus: 0, bufferSize: 1_024, format: input.outputFormat(forBus: 0)) { buffer, _ in
            request.append(buffer)
        }
        hasInstalledInputTap = true
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.record, mode: .measurement, options: [.duckOthers])
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
            audioEngine.prepare()
            try audioEngine.start()
            isListening = true
        } catch {
            stop()
            return
        }

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let transcript = result?.bestTranscription.formattedString
            let isFinished = result?.isFinal == true || error != nil
            Task { @MainActor [weak self] in
                guard let self, self.sessionID == currentSession else { return }
                if let transcript {
                    self.recognizedText = self.baseText.isEmpty ? transcript : "\(self.baseText) \(transcript)"
                }
                if isFinished {
                    self.sessionID = nil
                    self.isListening = false
                    if self.hasInstalledInputTap {
                        self.audioEngine.inputNode.removeTap(onBus: 0)
                        self.hasInstalledInputTap = false
                    }
                    self.audioEngine.stop()
                    self.recognitionRequest = nil
                    self.recognitionTask = nil
                    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
                }
            }
        }
    }
}

private struct MobileWelcomeCard: Identifiable {
    let id: String
    let icon: String
    let title: String
    let subtitle: String
    let prompt: String
}

private struct MobileAgentWelcomeView: View {
    @EnvironmentObject private var localization: MobileLocalization
    @Binding var prompt: String
    var isNoProject = false

    private var cards: [MobileWelcomeCard] {
        [
            MobileWelcomeCard(
                id: "explore",
                icon: "text.magnifyingglass",
                title: localization.text("mobile.agent.newConversation"),
                subtitle: localization.text("mobile.agent.ask"),
                prompt: "Explore the current project and explain its structure, important files, and the best next step."
            ),
            MobileWelcomeCard(
                id: "build",
                icon: "hammer",
                title: localization.text("mobile.workspace.codeEditor"),
                subtitle: localization.text("mobile.workspace.local"),
                prompt: "Help me build or improve the most useful next feature in this project. Start by inspecting the workspace."
            ),
            MobileWelcomeCard(
                id: "review",
                icon: "checkmark.seal",
                title: localization.text("mobile.agent.plan"),
                subtitle: localization.text("mobile.agent.planSubtitle"),
                prompt: "Review the current project, identify risks and improvements, and prepare a concise implementation plan."
            ),
            MobileWelcomeCard(
                id: "preview",
                icon: "globe",
                title: localization.text("mobile.preview.title"),
                subtitle: localization.text("mobile.preview.description"),
                prompt: "Check the current project for anything that should be previewed or verified, then tell me what to open next."
            ),
        ]
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Image("HerNessLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 76, height: 76)
                    .accessibilityHidden(true)

                Text("HerNess")
                    .font(.system(size: 30, weight: .bold, design: .rounded))

                if isNoProject {
                    Text(localization.text("mobile.agent.noProjectHelp"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 12)
                } else {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                        ForEach(cards) { card in
                            Button {
                                prompt = card.prompt
                            } label: {
                                VStack(alignment: .leading, spacing: 8) {
                                    Image(systemName: card.icon)
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundStyle(.tint)
                                    Text(card.title)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.primary)
                                        .lineLimit(2)
                                    Text(card.subtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(3)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
                                .padding(14)
                                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint(Text(card.prompt))
                        }
                    }
                    .padding(.top, 4)
                }
            }
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 20)
            .padding(.vertical, 32)
        }
        .background(Color.primary.opacity(0.025))
    }
}

/// The Agent tab runs either the desktop session (over the control plane) or the
/// agent that runs on this phone. It defaults to the phone whenever no desktop
/// is paired, so a closed laptop is not a dead end.
struct AgentTab: View {
    @EnvironmentObject private var agent: MobileAgent
    @Binding var prompt: String

    var body: some View {
        LocalAgentView(prompt: $prompt)
    }
}

struct LocalAgentView: View {
    @EnvironmentObject private var agent: MobileAgent
    @EnvironmentObject private var localization: MobileLocalization
    @EnvironmentObject private var local: LocalWorkspaceStore
    @Binding var prompt: String
    @State private var questionAnswer = ""
    @State private var draftAttachments: [MobileAttachment] = []
    @State private var showingFileImporter = false
    @State private var isSelectingProjectFolder = false
    @State private var showingConversationHistory = false
    @State private var projectImportError: String?
    @State private var showingCacheUsage = false
    @State private var showingCacheResumeInfo = false
    @State private var cacheNoticeClock = Date()
    @State private var expandedToolActivityIDs = Set<UUID>()
    @StateObject private var speechInput = MobileSpeechInput()

    /// Every row names a reason the next request costs more than the last one.
    @ViewBuilder private var composerNotices: some View {
        if let routeSwitch = agent.routeSwitch {
            ComposerNotice(text: localization.text(
                routeSwitch == .account ? "cache.accountSwitched.notice" : "cache.modelSwitched.notice"
            ))
        }
        if agent.expiredCachePrefixTokens(now: cacheNoticeClock.timeIntervalSince1970) != nil {
            ComposerNotice(text: localization.text("cache.resume.notice")) {
                Button { showingCacheResumeInfo = true } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: 15))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel(localization.text("cache.resume.infoTitle"))
                .popover(isPresented: $showingCacheResumeInfo, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(localization.text("cache.resume.infoTitle"))
                            .font(.headline)
                        Text(localization.text("cache.resume.explanation"))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(14)
                    .frame(width: 320, alignment: .leading)
                }
            }
        } else if agent.contextNearlyFull {
            // Both notices give the same new-chat advice; one is enough.
            ComposerNotice(text: localization.text("cache.contextFull.notice"))
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if !agent.currentCacheSummary.events.isEmpty {
                    Button { showingCacheUsage = true } label: {
                        Text(agent.currentCacheSummary.label)
                            .font(.caption).lineLimit(1).minimumScaleFactor(0.7)
                    }
                    .padding(.horizontal).padding(.vertical, 4)
                    .alert("Cache", isPresented: $showingCacheUsage) {
                        Button("OK", role: .cancel) {}
                    } message: {
                        Text(agent.currentCacheSummary.details)
                    }
                }
                if !local.selectedProjectLocationAvailable && !agent.isNoProjectMode {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(localization.text("project.missing.readOnly"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button(localization.text("project.missing.locate")) {
                            isSelectingProjectFolder = true
                            showingFileImporter = true
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                }
                if agent.transcript.isEmpty && !agent.isRunning {
                    MobileAgentWelcomeView(prompt: $prompt, isNoProject: agent.isNoProjectMode)
                } else {
                    ScrollViewReader { proxy in
                        List(agent.transcript) { turn in
                            Group {
                                if turn.role == .activity {
                                    HStack(spacing: 9) {
                                        Image(systemName: "arrow.down.right")
                                            .foregroundStyle(Color.accentColor)
                                        Text(label(for: turn))
                                            .font(.callout)
                                            .foregroundStyle(.secondary)
                                        if !turn.text.isEmpty {
                                            Text("· \(turn.text)")
                                                .font(.caption.monospacedDigit())
                                                .foregroundStyle(.tertiary)
                                        }
                                        Spacer(minLength: 0)
                                    }
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 5)
                                } else if turn.role == .tool {
                                    if turn.isRunning {
                                        VStack(alignment: .leading, spacing: 4) {
                                            HStack(spacing: 10) {
                                                ProgressView()
                                                    .controlSize(.small)
                                                Label(
                                                    toolActivityLabel(turn.toolName, running: true),
                                                    systemImage: toolActivityIcon(turn.toolName)
                                                )
                                                .font(.callout)
                                                .foregroundStyle(.secondary)
                                                Spacer(minLength: 0)
                                            }
                                            if let detail = turn.activityDetail, !detail.isEmpty {
                                                Text(detail)
                                                    .font(.caption.monospaced())
                                                    .foregroundStyle(.tertiary)
                                                    .lineLimit(2)
                                                    .textSelection(.enabled)
                                                    .padding(.leading, 26)
                                            }
                                        }
                                        .padding(10)
                                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                                        .accessibilityElement(children: .combine)
                                    } else {
                                        DisclosureGroup(isExpanded: toolActivityBinding(for: turn.id)) {
                                            Text(turn.text)
                                                .font(.system(.footnote, design: .monospaced))
                                                .textSelection(.enabled)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                                .padding(.top, 6)
                                        } label: {
                                            VStack(alignment: .leading, spacing: 4) {
                                                Label(
                                                    toolActivityLabel(turn.toolName, failed: turn.failed),
                                                    systemImage: toolActivityIcon(turn.toolName, failed: turn.failed)
                                                )
                                                .font(.callout)
                                                .foregroundStyle(turn.failed ? Color.red : Color.secondary)
                                                if let detail = turn.activityDetail, !detail.isEmpty {
                                                    Text(detail)
                                                        .font(.caption.monospaced())
                                                        .foregroundStyle(.tertiary)
                                                        .lineLimit(2)
                                                        .textSelection(.enabled)
                                                        .padding(.leading, 26)
                                                }
                                            }
                                        }
                                        .padding(10)
                                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                                    }
                                } else {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(label(for: turn)).font(.caption.bold()).foregroundStyle(color(for: turn))
                                        Text(turn.text)
                                            .font(.body)
                                            .textSelection(.enabled)
                                    }
                                }
                            }
                            .id(turn.id)
                        }
                        .listStyle(.plain)
                        .onChange(of: agent.transcript.count) { _, _ in
                            if let last = agent.transcript.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                        }
                    }
                }
                Divider()
                if let approval = agent.approvalRequest {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(localization.text("mobile.agent.approvalRequired")).font(.headline)
                        Text(localization.format("mobile.agent.allowTool", approval.toolName))
                        HStack {
                            Button(localization.text("permission.allowOnce")) { agent.answerApproval(approval.id, accepted: true) }
                                .disabled(!local.selectedProjectLocationAvailable)
                            Button(localization.text("permission.reject"), role: .destructive) { agent.answerApproval(approval.id, accepted: false) }
                                .disabled(!local.selectedProjectLocationAvailable)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                }
                if let question = agent.questionRequest {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(localization.text("mobile.agent.clarification")).font(.headline)
                        Text(question.question).font(.subheadline)
                        TextField(localization.text("mobile.agent.answer"), text: $questionAnswer)
                        Button(localization.text("mobile.agent.answer")) {
                            let answer = questionAnswer
                            questionAnswer = ""
                            agent.answerQuestion(question.id, answers: [answer])
                        }
                        .disabled(!local.selectedProjectLocationAvailable || questionAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                }
                if !draftAttachments.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(draftAttachments) { attachment in
                                HStack(spacing: 4) {
                                    Image(systemName: "paperclip")
                                    Text(attachment.displayName).lineLimit(1)
                                    Button { draftAttachments.removeAll { $0.id == attachment.id } } label: {
                                        Image(systemName: "xmark.circle.fill")
                                    }
                                    .buttonStyle(.plain)
                                }
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(.thinMaterial, in: Capsule())
                            }
                        }
                        .padding(.horizontal)
                    }
                }
                if agent.requiresToolOutcomeRecovery {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(agent.toolOutcomeRecoveryMessage ?? "Tool sonucu doğrulanmalı")
                            .font(.caption)
                            .foregroundStyle(.red)
                        HStack {
                            Spacer()
                            if !agent.isRunning {
                                Button(localization.text("agent.continue")) { agent.continueRun() }
                                    .buttonStyle(.borderedProminent)
                                    .disabled(!local.selectedProjectLocationAvailable)
                            }
                            if agent.planGateIsActive {
                                Button(localization.text("mobile.agent.cancelPlan"), role: .destructive) { agent.cancelPlan() }
                            }
                        }
                    }
                    .padding(.horizontal)
                }
                if agent.pendingPlan && !agent.requiresToolOutcomeRecovery {
                    HStack {
                        Button(localization.text("mobile.agent.applyPlan")) { agent.applyPlan() }
                            .buttonStyle(.borderedProminent)
                            .disabled(agent.isRunning || !local.selectedProjectLocationAvailable)
                        if agent.waitingForPlan {
                            Text(localization.text("mobile.queue.waitingForPlan"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Button(localization.text("mobile.agent.cancelPlan"), role: .destructive) { agent.cancelPlan() }
                        Spacer()
                    }
                    .padding(.horizontal)
                }
                if agent.planGateIsActive && !agent.pendingPlan && !agent.requiresToolOutcomeRecovery {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(agent.providerLimitMessage ?? localization.text("mobile.agent.planPaused"))
                            .font(.caption)
                            .foregroundStyle(agent.providerLimitMessage == nil ? Color.secondary : Color.red)
                        HStack {
                            Spacer()
                            if !agent.isRunning {
                                Button(localization.text("mobile.agent.continuePlan")) {
                                    agent.continueRun()
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(!local.selectedProjectLocationAvailable)
                            }
                            Button(localization.text("mobile.agent.cancelPlan"), role: .destructive) { agent.cancelPlan() }
                        }
                    }
                    .padding(.horizontal)
                }
                if !agent.planGateIsActive, agent.canContinueAfterProviderLimit,
                   let providerLimitMessage = agent.providerLimitMessage {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(providerLimitMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                        HStack {
                            Spacer()
                            Button(localization.text("agent.continue")) { agent.continueRun() }
                                .buttonStyle(.borderedProminent)
                                .disabled(!local.selectedProjectLocationAvailable)
                        }
                    }
                    .padding(.horizontal)
                }
                if !agent.queuedPromptItems.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(localization.text("mobile.agent.queuedMessages"))
                            .font(.caption.bold())
                        ForEach(agent.queuedPromptItems) { queued in
                            HStack(spacing: 8) {
                                Text(queued.text.isEmpty ? "[Attachment]" : queued.text)
                                    .lineLimit(2)
                                    .font(.caption)
                                Spacer(minLength: 4)
                                Button(localization.text("mobile.agent.promote")) {
                                    agent.promoteQueuedPrompt(queued.id)
                                }
                                .buttonStyle(.bordered)
                                .disabled(!local.selectedProjectLocationAvailable)
                            }
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 6)
                }
                composerNotices
                HStack {
                    Button { showingFileImporter = true } label: { Image(systemName: "paperclip") }
                        .accessibilityLabel("Attach file")
                        .disabled(!canSendPrompt)
                    TextField(localization.text("mobile.agent.ask") + "…", text: $prompt, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(1...4)
                        .disabled(!canSendPrompt)
                    Button {
                        if speechInput.isListening {
                            speechInput.stop()
                        } else {
                            speechInput.start(currentText: prompt, locale: localization.locale)
                        }
                    } label: {
                        Image(systemName: speechInput.isListening ? "waveform" : "mic")
                            .foregroundStyle(speechInput.isListening ? Color.red : Color.accentColor)
                    }
                    .accessibilityLabel(localization.text("mobile.agent.ask"))
                    if agent.isRunning {
                        Button(localization.text("mobile.agent.queue")) { send(mode: "queue") }
                            .disabled(!canSendPrompt || (prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && draftAttachments.isEmpty))
                        Button(localization.text("conversation.steer")) { send(mode: "steer") }
                            .disabled(!canSendPrompt || (prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && draftAttachments.isEmpty))
                        Button(localization.text("common.stop"), role: .destructive) { agent.cancel() }
                    } else {
                        Button(localization.text("mobile.agent.send")) { send(mode: "queue") }
                            .disabled(!canSendPrompt || (prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && draftAttachments.isEmpty))
                    }
                }
                .padding(9)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        if agent.isNoProjectMode {
                            Button {
                                agent.selectProject(local.selectedProjectID)
                            } label: {
                                Label(localization.text("mobile.agent.useProject"), systemImage: "folder")
                            }
                            .disabled(agent.isRunning)
                        } else {
                            Button {
                                agent.selectNoProject()
                            } label: {
                                Label(localization.text("mobile.agent.noProject"), systemImage: "bubble.left.and.bubble.right")
                            }
                            .disabled(agent.isRunning)
                        }
                        Divider()
                        Picker(localization.text("router.provider"), selection: Binding(get: { agent.provider }, set: { agent.setProvider($0) })) {
                            ForEach(MobileAgent.providerDefinitions) { provider in
                                HStack(spacing: 8) {
                                    MobileProviderBrandMark(providerID: provider.id, size: 18)
                                    Text(provider.name)
                                }.tag(provider.id)
                            }
                        }
                        Picker(localization.text("mobile.agent.model"), selection: Binding(get: { agent.model }, set: { agent.setModel($0) })) {
                            ForEach(agent.availableModels(for: agent.provider), id: \.self) { model in
                                HStack(spacing: 6) {
                                    MobileProviderBrandMark(providerID: agent.provider, size: 16)
                                    Text(model)
                                }
                                .tag(model)
                            }
                        }
                        Toggle(localization.text("mobile.agent.plan"), isOn: $agent.planMode)
                            .disabled(!local.selectedProjectLocationAvailable || agent.isNoProjectMode)
                        Button(localization.text("sidebar.recent")) { showingConversationHistory = true }
                        if !local.selectedProjectLocationAvailable {
                            Button(localization.text("project.missing.locate")) {
                                isSelectingProjectFolder = true
                                showingFileImporter = true
                            }
                        }
                        Button(localization.text("mobile.agent.newConversation"), role: .destructive) { agent.reset() }
                            .disabled(!agent.projectLocationAvailable)
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
                .fileImporter(
                isPresented: $showingFileImporter,
                allowedContentTypes: isSelectingProjectFolder ? [.folder] : [.item],
                allowsMultipleSelection: !isSelectingProjectFolder
            ) { result in
                if isSelectingProjectFolder {
                    isSelectingProjectFolder = false
                    guard let folder = try? result.get().first else { return }
                    Task {
                        do {
                            try await local.relocateSelectedProject(from: folder)
                        } catch {
                            projectImportError = error.localizedDescription
                        }
                    }
                    return
                }
                guard let urls = try? result.get() else { return }
                for url in urls {
                    guard let attachment = MobileAttachment(url: url), !draftAttachments.contains(where: { $0.sourceLocator == attachment.sourceLocator }) else { continue }
                    draftAttachments.append(attachment)
                }
            }
            .sheet(isPresented: $showingConversationHistory) {
                MobileConversationHistorySheet(agent: agent)
            }
            .alert(localization.text("sidebar.recent"), isPresented: Binding(
                get: { projectImportError != nil },
                set: { if !$0 { projectImportError = nil } }
            )) {
                Button(localization.text("app.ok"), role: .cancel) { projectImportError = nil }
            } message: {
                Text(projectImportError ?? "")
            }
            .task {
                while !Task.isCancelled {
                    local.refreshSelectedProjectAvailability()
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
            .task(id: agent.activeConversationId) {
                while !Task.isCancelled {
                    cacheNoticeClock = Date()
                    try? await Task.sleep(nanoseconds: 30_000_000_000)
                }
            }
            .onChange(of: speechInput.recognizedText) { _, value in prompt = value }
            .onDisappear { speechInput.stop() }
        }
        .toolbarBackground(.hidden, for: .navigationBar)
    }

    private func send(mode: String) {
        guard canSendPrompt else { return }
        guard agent.send(prompt, attachments: draftAttachments, mode: mode, planMode: agent.planMode) else { return }
        prompt = ""
        draftAttachments = []
    }

    private var canSendPrompt: Bool {
        agent.isNoProjectMode || local.selectedProjectLocationAvailable
    }

    private func label(for turn: AgentTurn) -> String {
        switch turn.role {
        case .user: return localization.text("mobile.agent.user")
        case .assistant: return localization.text("conversation.assistant")
        case .tool: return toolActivityLabel(turn.toolName, failed: turn.failed)
        case .error: return localization.text("mobile.agent.error")
        case .system: return localization.text("mobile.event.runSummary")
        case .activity:
            return localization.text(turn.toolName == "context_compacted_auto"
                ? "conversation.contextCompactedAuto"
                : "status.contextCompacted")
        }
    }

    private func color(for turn: AgentTurn) -> Color {
        switch turn.role {
        case .user: return .secondary
        case .assistant: return .accentColor
        case .tool: return .orange
        case .error: return .red
        case .system: return .secondary
        case .activity: return .secondary
        }
    }

    private func toolActivityLabel(_ toolName: String?, failed: Bool = false, running: Bool = false) -> String {
        let name = (toolName ?? "tool").lowercased()
        if failed { return localization.format("conversation.activity.toolFailed", (toolName ?? "tool").replacingOccurrences(of: "_", with: " ")) }
        let key: String
        if ["read_file", "list_files", "grep_files", "glob_files", "search_files", "get_latest_attachment"].contains(name) {
            key = running ? "conversation.activity.filesReading" : "conversation.activity.filesRead"
        } else if ["write_file", "edit_file", "create_file", "delete_file", "copy_generated_media"].contains(name) {
            key = running ? "conversation.activity.filesChanging" : "conversation.activity.filesChanged"
        } else if ["run_command", "terminal_session", "shell", "exec"].contains(name) {
            key = running ? "conversation.activity.commandsRunning" : "conversation.activity.commandsRun"
        } else if name.hasPrefix("web_") || name.hasPrefix("browser_") {
            key = running ? "conversation.activity.webSearching" : "conversation.activity.webSearch"
        } else {
            return running
                ? localization.text("conversation.activity.otherRunning")
                : (toolName ?? localization.text("conversation.tool")).replacingOccurrences(of: "_", with: " ")
        }
        return localization.text(key)
    }

    private func toolActivityIcon(_ toolName: String?, failed: Bool = false) -> String {
        if failed { return "xmark.circle" }
        let name = (toolName ?? "").lowercased()
        if ["read_file", "list_files", "grep_files", "glob_files", "search_files", "get_latest_attachment"].contains(name) {
            return "doc.text.magnifyingglass"
        }
        if ["write_file", "edit_file", "create_file", "delete_file", "copy_generated_media"].contains(name) {
            return "pencil.line"
        }
        if ["run_command", "terminal_session", "shell", "exec"].contains(name) { return "terminal.fill" }
        if name.hasPrefix("web_") || name.hasPrefix("browser_") { return "magnifyingglass" }
        return "wrench.and.screwdriver"
    }

    private func toolActivityBinding(for id: UUID) -> Binding<Bool> {
        Binding(
            get: { expandedToolActivityIDs.contains(id) },
            set: { expanded in
                if expanded { expandedToolActivityIDs.insert(id) }
                else { expandedToolActivityIDs.remove(id) }
            }
        )
    }
}

private struct MobileConversationHistorySheet: View {
    @EnvironmentObject private var localization: MobileLocalization
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var agent: MobileAgent

    var body: some View {
        NavigationStack {
            List {
                let conversations = agent.previousConversations()
                if conversations.isEmpty {
                    Text(localization.text("sidebar.noChats"))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(conversations) { conversation in
                        NavigationLink {
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 14) {
                                    ForEach(agent.storedMessages(for: conversation.id)) { message in
                                        storedMessageView(message)
                                    }
                                }
                                .padding()
                            }
                            .navigationTitle(conversation.updatedAt.formatted(date: .abbreviated, time: .shortened))
                            .navigationBarTitleDisplayMode(.inline)
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(conversation.updatedAt.formatted(date: .abbreviated, time: .shortened))
                                Text(conversation.status.capitalized)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle(localization.text("sidebar.recent"))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(localization.text("mobile.agent.close")) { dismiss() }
                }
            }
        }
    }

    private func roleLabel(_ role: String, toolName: String?) -> String {
        switch role {
        case "user": localization.text("mobile.agent.user")
        case "assistant": localization.text("conversation.assistant")
        case "tool": historyToolLabel(toolName)
        case "activity": localization.text(toolName == "context_compacted_auto"
            ? "conversation.contextCompactedAuto"
            : "status.contextCompacted")
        case "error": localization.text("mobile.agent.error")
        default: localization.text("mobile.event.runSummary")
        }
    }

    private func historyToolLabel(_ toolName: String?) -> String {
        let name = (toolName ?? "").lowercased()
        if ["read_file", "list_files", "grep_files", "glob_files", "search_files", "get_latest_attachment"].contains(name) {
            return localization.text("conversation.activity.filesRead")
        }
        if ["write_file", "edit_file", "create_file", "delete_file", "copy_generated_media"].contains(name) {
            return localization.text("conversation.activity.filesChanged")
        }
        if ["run_command", "terminal_session", "shell", "exec"].contains(name) {
            return localization.text("conversation.activity.commandsRun")
        }
        if name.hasPrefix("web_") || name.hasPrefix("browser_") {
            return localization.text("conversation.activity.webSearch")
        }
        return toolName ?? localization.text("conversation.tool")
    }

    @ViewBuilder
    private func storedMessageView(_ message: StoredMobileMessage) -> some View {
        if message.role == "activity" {
            Label(
                roleLabel(message.role, toolName: message.toolName),
                systemImage: "arrow.down.right"
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text(roleLabel(message.role, toolName: message.toolName))
                    .font(.caption.bold())
                    .foregroundStyle(message.role == "error" ? Color.red : Color.secondary)
                Text(message.content)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// One warning row above the composer.
private struct ComposerNotice<Trailing: View>: View {
    let text: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(text)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            trailing()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal)
        .padding(.bottom, 6)
    }
}

private extension ComposerNotice where Trailing == EmptyView {
    init(text: String) { self.init(text: text) { EmptyView() } }
}

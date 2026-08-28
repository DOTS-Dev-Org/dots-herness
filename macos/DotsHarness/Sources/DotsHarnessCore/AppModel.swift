// Copyright (c) 2026 DOTS
// Application state for the standalone native harness.

import AppKit
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import HarnessPluginKit
import PluginRuntime

@MainActor
public final class AppModelReference {
    public weak var model: AppModel?

    public init(model: AppModel? = nil) {
        self.model = model
    }
}

@MainActor
public final class AppModel: ObservableObject {
    public let catalog: PluginCatalog
    public let skills: SkillCatalog
    public let host: PluginHost
    public let paths: SupportPaths
    public let bridge: AgentBridge
    public let router: RouterController
    public let endpoint: AgentEndpointController
    public let terminalManager: TerminalManager
    private let desktopNotifications: DesktopNotificationService
    public lazy var marketplace: MarketplaceClient = {
        let raw = host.settings.get("marketplace.indexURL")?.string ?? MarketplaceClient.defaultIndex
        let url = URL(string: raw) ?? URL(string: MarketplaceClient.defaultIndex)!
        return MarketplaceClient(indexURL: url, catalog: catalog)
    }()
    public lazy var local: LocalRuntimeController = LocalRuntimeController(paths: paths, router: router)
    public lazy var voice: LocalVoiceTranscriber = LocalVoiceTranscriber(paths: paths)
    public lazy var nemotron: NemotronRuntime = NemotronRuntime(paths: paths)
    public lazy var localSpeech: LocalPiperSpeechSynthesizer = LocalPiperSpeechSynthesizer(paths: paths)
    public lazy var speech = LocalSpeechSynthesizer()
    public lazy var simulator = SimulatorController()
    public lazy var scheduler: TaskScheduler = TaskScheduler(store: TaskStore(paths: paths)) { [weak self] task in
        await self?.runScheduledTask(task) ?? TaskScheduler.RunResult(ok: false, message: "app unavailable")
    }

    @Published public var draft: String = "" {
        didSet {
            guard editingMessageID == nil, let id = bridge.selectedID else { return }
            draftsByConversation[id] = draft
        }
    }
    @Published public private(set) var draftAttachments: [ChatAttachment] = [] {
        didSet {
            guard editingMessageID == nil, let id = bridge.selectedID else { return }
            draftAttachmentsByConversation[id] = draftAttachments
        }
    }
    public var draftImages: [URL] { draftAttachments.filter { $0.kind == .image }.map(\.url) }
    @Published public var appearance: Appearance = .system
    @Published public var appLanguage: AppLanguage = .system
    @Published public private(set) var permissionMode: AgentPermissionMode
    @Published public private(set) var fullAccessWarningDismissed: Bool
    @Published public var confirmBeforeExit = true
    @Published public private(set) var workspacePath: String
    @Published public var isPetVisible = false
    @Published public var isSettingsPresented = false
    @Published public var isUsagePresented = false
    @Published public var isTasksPresented = false
    @Published public var isSimulatorPresented = false
    @Published public var isPlanMode = false
    @Published public private(set) var editingMessageID: String?
    @Published public private(set) var historyError: String?
    @Published public var voiceProvider: VoiceInputProvider = .whisperTinyQ5
    @Published public var voiceAPIEndpoint = ""
    @Published public var voiceAPIKey = ""
    @Published public var voiceAPIModel = ""
    @Published public var voiceAPIRealtimeEndpoint = ""
    @Published public private(set) var voiceIntroSeen = false
    @Published public private(set) var voiceModelStates: [String: LocalVoiceModelState] = [:]
    @Published public private(set) var voiceModelProgress: [String: FileDownloader.Progress] = [:]

    public var conversations: [Conversation] { bridge.conversations }
    public var selectedConversationID: String? {
        get { bridge.selectedID }
        set {
            guard let newValue else { return }
            if bridge.conversations.contains(where: { $0.id == newValue }) {
                selectConversation(newValue)
            } else if bridge.projectlessConversations.contains(where: { $0.id == newValue }) {
                cancelEditing()
                saveDraftState()
                setWorkspace("")
                selectConversation(newValue)
            }
        }
    }
    public var selected: Conversation? { bridge.selected }
    public var statusLine: String { bridge.status }
    public var selectedModelID: String {
        get { endpoint.modelID }
        set { setModel(newValue) }
    }
    public var isFirstLaunch: Bool { workspacePath.isEmpty }
    public var showsVoiceIntro: Bool { !voiceIntroSeen }
    public var showsFullAccessWarning: Bool {
        permissionMode == .full && !fullAccessWarningDismissed
    }
    public var appLocale: Locale { AppCopy.locale }
    public var isRTL: Bool { AppCopy.effectiveLanguage.isRTL }
    public var canSend: Bool { bridge.isReady && !bridge.historyMutationBusy }
    public var isEditingMessage: Bool { editingMessageID != nil }
    public var voiceModelState: LocalVoiceModelState { voiceModelState(for: voiceProvider) }
    public func voiceModelState(for provider: VoiceInputProvider) -> LocalVoiceModelState {
        voiceModelStates[provider.rawValue] ?? .notInstalled
    }
    public var isVoiceModelInstalled: Bool { voiceModelState.isInstalled }
    public var isVoiceModelDownloading: Bool { voiceModelState == .downloading }
    public var voiceModelDownloadProgress: FileDownloader.Progress? {
        voiceModelProgress[voiceProvider.rawValue]
    }
    public var voiceModelStatusText: String { voiceModelState.title }
    public var speechModelState: LocalVoiceModelState {
        voiceModelStates[LocalSpeechModel.turkishPiper.id] ?? .notInstalled
    }
    public var speechModelDownloadProgress: FileDownloader.Progress? {
        voiceModelProgress[LocalSpeechModel.turkishPiper.id]
    }
    public var isSpeechModelInstalled: Bool { speechModelState.isInstalled }
    public var isSpeechModelDownloading: Bool { speechModelState == .downloading }
    public var isVoiceReady: Bool {
        switch voiceProvider {
        case .whisperTinyQ5, .whisperLargeV3Turbo, .customLocal:
            return isVoiceModelInstalled
        case .nemotron:
            return nemotron.isReady
        case .api:
            return VoiceAPIConfiguration(
                endpoint: voiceAPIEndpoint,
                apiKey: voiceAPIKey,
                model: voiceAPIModel,
                realtimeEndpoint: voiceAPIRealtimeEndpoint
            ).isConfigured
        }
    }
    public var voiceInputHelp: String {
        if isVoiceModelDownloading { return VoiceCopy.downloading }
        if isVoiceReady {
            return VoiceCopy.microphoneReady
        }
        switch voiceProvider {
        case .whisperTinyQ5, .whisperLargeV3Turbo, .customLocal, .nemotron:
            return VoiceCopy.microphoneNeedsModel
        case .api:
            return VoiceCopy.microphoneNeedsSetup
        }
    }

    public enum Appearance: String, CaseIterable, Identifiable {
        case system
        case light
        case dark

        public var id: String { rawValue }

        public var colorScheme: ColorScheme? {
            switch self {
            case .system: return nil
            case .light: return .light
            case .dark: return .dark
            }
        }
    }

    public init(paths: SupportPaths = .default(), builtins: [any DefaultPlugin.Type] = []) {
        self.paths = paths
        self.terminalManager = TerminalManager()
        self.desktopNotifications = DesktopNotificationService()

        let catalog = PluginCatalog(paths: paths)
        for builtin in builtins {
            catalog.registerBuiltin(builtin, refresh: false)
        }
        self.catalog = catalog
        let skills = SkillCatalog(paths: paths)
        self.skills = skills

        let settings = Self.loadSettings(from: paths.settings)
        var migratedFableSetting = false
        if settings.get("skills.fableMigration.v1") == nil,
           let legacyEnabled = ["fable.enabled", "fableThinking.enabled", "dots.fable-thinking.enabled"]
            .compactMap({ settings.get($0)?.bool })
            .first {
            skills.setEnabled("fable-thinking", legacyEnabled)
            settings.set("skills.fableMigration.v1", .bool(true))
            migratedFableSetting = true
        }
        let storedLanguage = settings.get("ui.language")?.string
            .flatMap(AppLanguage.init(rawValue:)) ?? .system
        let storedPermissionMode = settings.get("agent.permissionMode")?.string
            .flatMap(AgentPermissionMode.init(rawValue:)) ?? .ask
        self.permissionMode = storedPermissionMode
        self.fullAccessWarningDismissed = settings.get("ui.fullAccessWarningDismissed")?.bool ?? false
        self.voiceIntroSeen = settings.get("ui.voiceIntroSeen")?.bool ?? false
        self.appLanguage = storedLanguage
        AppCopy.setLanguage(storedLanguage)
        self.host = PluginHost(catalog: catalog, settings: settings)

        if let stored = settings.get("voice.provider")?.string,
           let provider = VoiceInputProvider(rawValue: stored) {
            self.voiceProvider = provider
        }
        let legacyEndpoint = "http://127.0.0.1:8080/v1"
        let legacyModel = "nemotron-3.5-asr-streaming-0.6b"
        let storedEndpoint = settings.get("voice.api.endpoint")?.string ?? ""
        let storedModel = settings.get("voice.api.model")?.string ?? ""
        self.voiceAPIEndpoint = storedEndpoint == legacyEndpoint ? "" : storedEndpoint
        self.voiceAPIKey = settings.get("voice.api.key")?.string ?? ""
        self.voiceAPIModel = storedModel == legacyModel ? "" : storedModel
        self.voiceAPIRealtimeEndpoint = settings.get("voice.api.realtimeEndpoint")?.string ?? ""

        let router = RouterController(paths: paths, imageAdapters: host.imageAdapters)
        router.selectedModelID = settings.get("agent.model")?.string ?? ""
        router.selectedEffort = settings.get("agent.effort")?.string ?? ""
        self.router = router

        let endpoint = AgentEndpointController(
            baseURL: "",
            modelID: settings.get("agent.model")?.string ?? "",
            apiKey: ""
        )
        self.endpoint = endpoint
        self.bridge = AgentBridge(
            paths: paths,
            endpoint: endpoint,
            router: router,
            skills: skills,
            permissionMode: storedPermissionMode
        )
        let appModelReference = AppModelReference()
        self.appModelReference = appModelReference

        if let stored = settings.get("ui.appearance")?.string,
           let appearance = Appearance(rawValue: stored) {
            self.appearance = appearance
        }
        if let stored = settings.get("ui.confirmBeforeExit")?.bool {
            self.confirmBeforeExit = stored
        }

        let storedWorkspace = settings.get("agent.workspace")?.string ?? ""
        self.workspacePath = Self.validWorkspacePath(storedWorkspace) ?? ""
        skills.setWorkspace(self.workspacePath.isEmpty ? nil : self.workspacePath)

        bridge.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        endpoint.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        host.provideService("appModel", appModelReference)
        host.provideService("catalog", catalog)
        host.provideService("skills", skills)
        appModelReference.model = self
        if migratedFableSetting { persistSettings() }
        bridge.onAssistantResponse = { [weak self] event in
            self?.desktopNotifications.showAssistantResponse(event)
        }
    }

    private var cancellables = Set<AnyCancellable>()
    private var hasStarted = false
    private var hasBootstrapped = false
    private var activeOptionalPluginIDs = Set<String>()
    // ponytail: keep unsent drafts in memory; persist only if restart recovery is required.
    private var draftsByConversation: [String: String] = [:]
    private var draftAttachmentsByConversation: [String: [ChatAttachment]] = [:]
    private var draftBeforeEditing: String?
    private var attachmentsBeforeEditing: [ChatAttachment]?
    private let appModelReference: AppModelReference
    private var isVoiceDownloadPromptShowing = false
    private enum VoiceDownloadStopReason {
        case pause
        case cancel
    }
    private var voiceDownloadTask: Task<Void, Never>?
    private var voiceDownloadStopReason: VoiceDownloadStopReason?
    private var voiceDownloadHadRuntime = false
    private var speechTask: Task<Void, Never>?
    private var speechRequestID: UUID?

    public func start() {
        guard !hasStarted else { return }
        hasStarted = true
        refreshVoiceModel()
        refreshSpeechModel()
        prewarmNemotron()

        // Let SwiftUI commit the first frame before loading conversations and
        // mounting plugins. The UI shell can render from the already-loaded
        // settings/workspace state while the optional model lookup runs in the
        // background.
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, !self.hasBootstrapped else { return }
            self.catalog.refresh()
            self.bridge.start(workspacePath: self.workspacePath)
            self.remount(refreshCatalog: false)
            self.hasBootstrapped = true
            self.objectWillChange.send()

            // Router access is demand-driven. The bridge performs a single
            // lightweight model discovery only when a workspace needs a
            // connection; management endpoints are loaded from Settings.
            Task { @MainActor [weak self] in
                await self?.bridge.refreshConnection()
            }

            self.scheduler.runsDueTasks = !self.isBackgroundDaemonEnabled
            self.scheduler.start()
        }
    }

    public func requestNotificationAuthorization() {
        desktopNotifications.requestAuthorization()
    }

    /// Headless bootstrap for the background scheduler daemon: mount plugins so
    /// the system prompt is assembled, then start the engine. No window, no
    /// workspace binding — each task carries its own workspace.
    public func startHeadless() {
        guard !hasStarted else { return }
        hasStarted = true
        catalog.refresh()
        remount(refreshCatalog: false)
        hasBootstrapped = true
        scheduler.runsDueTasks = true
        scheduler.start()
    }

    public func presentTasks() {
        isTasksPresented = true
    }

    public var isBackgroundDaemonEnabled: Bool {
        host.settings.get("tasks.backgroundDaemon")?.bool ?? false
    }

    /// Enable/disable the launchd LaunchAgent that runs tasks while the app is
    /// closed. While the daemon owns execution the in-app engine stops firing
    /// due tasks so nothing runs twice.
    public func setBackgroundDaemonEnabled(_ enabled: Bool) throws {
        if enabled {
            try SchedulerService.install()
        } else {
            SchedulerService.uninstall()
        }
        host.settings.set("tasks.backgroundDaemon", .bool(enabled))
        persistSettings()
        scheduler.runsDueTasks = !enabled
    }

    /// Runner for the in-app `TaskScheduler`. Delegates the actual run to the
    /// shared `ScheduledTaskRunner` (also used by the background daemon), then
    /// folds the generated conversation into the main window when it belongs to
    /// the workspace the user currently has open.
    public func runScheduledTask(_ task: ScheduledTask) async -> TaskScheduler.RunResult {
        let runner = ScheduledTaskRunner(
            paths: paths,
            router: router,
            endpoint: endpoint,
            permissionMode: permissionMode,
            systemPrompt: { [weak self] in self?.assembledSystemPrompt() ?? "" }
        )
        let result = await runner.run(task)
        if let workspace = Self.validWorkspacePath(task.workspacePath),
           Self.validWorkspacePath(workspacePath) == workspace {
            bridge.mergeExternalConversations()
        }
        return result
    }

    public func chooseWorkspace() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = AppCopy.text("workspace.use")
        panel.message = AppCopy.text("workspace.chooseMessage")
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor [weak self] in
                self?.setWorkspace(url.path)
            }
        }
    }

    public func revealWorkspace() {
        guard !workspacePath.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: workspacePath)])
    }

    public func remount() {
        remount(refreshCatalog: true)
    }

    private func remount(refreshCatalog: Bool) {
        if refreshCatalog {
            catalog.refresh()
        }
        skills.refresh()
        let document = CompositionLoader.loadHost(paths: paths, catalog: catalog)
        _ = host.mount(document)
        bridge.updateSystemPrompt(host.prompt.assembledText())
        objectWillChange.send()
    }

    public func newConversation() {
        cancelEditing()
        saveDraftState()
        bridge.newConversation()
        restoreDraftState()
    }

    public func startWithoutProject() {
        cancelEditing()
        saveDraftState()
        setWorkspace("")
        newConversation()
    }

    public func addDraftAttachments(_ urls: [URL]) {
        for url in urls {
            guard let attachment = ChatAttachment(url: url),
                  !draftAttachments.contains(where: { $0.path == attachment.path }) else { continue }
            draftAttachments.append(attachment)
        }
    }

    public func addDraftImages(_ urls: [URL]) {
        for url in urls {
            let attachment = ChatAttachment(
                path: url.standardizedFileURL.path,
                kind: .image,
                mimeType: UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "image/png"
            )
            guard !draftAttachments.contains(where: { $0.path == attachment.path }) else { continue }
            draftAttachments.append(attachment)
        }
    }

    public func removeDraftAttachment(_ attachment: ChatAttachment) {
        draftAttachments.removeAll { $0 == attachment }
    }

    public func removeDraftImage(_ url: URL) {
        draftAttachments.removeAll { $0.url == url }
    }

    public func send(mode: PromptMode = .queue) {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !draftAttachments.isEmpty else {
            if bridge.canContinue { Task { await bridge.continueCurrentRun() } }
            return
        }

        if let messageID = editingMessageID,
           let conversationID = selected?.id {
            let attachments = draftAttachments
            historyError = nil
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try await bridge.editLatestMessage(
                        conversationID: conversationID,
                        messageID: messageID,
                        text: text,
                        attachments: attachments
                    )
                    finishEditingAfterSuccess()
                } catch {
                    historyError = error.localizedDescription
                }
            }
            return
        }

        historyError = nil
        guard canSend else { return }
        let attachments = draftAttachments
        let isApproval = attachments.isEmpty
            && selected?.pendingPlanMessageID.flatMap { planID in
                selected?.messages.first(where: { $0.id == planID && $0.kind == .plan })
            } != nil
            && PlanApproval.matches(text)
        if isApproval { isPlanMode = false }
        let runPlanMode = isApproval ? false : isPlanMode
        draft = ""
        draftAttachments = []
        Task {
            await bridge.send(
                text: text,
                attachments: attachments,
                mode: mode,
                planMode: runPlanMode
            )
        }
    }

    public func send(text: String, attachments: [ChatAttachment] = [], mode: PromptMode = .queue) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty, canSend else { return }
        let isApproval = attachments.isEmpty
            && selected?.pendingPlanMessageID.flatMap { planID in
                selected?.messages.first(where: { $0.id == planID && $0.kind == .plan })
            } != nil
            && PlanApproval.matches(trimmed)
        if isApproval { isPlanMode = false }
        let runPlanMode = isApproval ? false : isPlanMode
        Task {
            await bridge.send(
                text: trimmed,
                attachments: attachments,
                mode: mode,
                planMode: runPlanMode
            )
        }
    }

    public func togglePlanMode() {
        isPlanMode.toggle()
    }

    public func applyPlan() {
        guard selected?.pendingPlanMessageID != nil, bridge.isReady, !bridge.isBusy else { return }
        isPlanMode = false
        Task { await bridge.applyPlan() }
    }

    public func stop() {
        bridge.stopCurrentRun()
    }

    public func continueCurrentRun() {
        Task { await bridge.continueCurrentRun() }
    }

    public func beginEditing(_ message: ChatMessage) {
        guard let conversationID = selected?.id,
              message.kind == .user,
              bridge.canEdit(messageID: message.id, in: conversationID) else { return }
        if editingMessageID != nil { cancelEditing() }
        draftBeforeEditing = draft
        attachmentsBeforeEditing = draftAttachments
        historyError = nil
        editingMessageID = message.id
        draft = message.text
        draftAttachments = message.attachments
    }

    public func cancelEditing() {
        guard editingMessageID != nil else { return }
        let savedDraft = draftBeforeEditing ?? ""
        let savedAttachments = attachmentsBeforeEditing ?? []
        editingMessageID = nil
        draftBeforeEditing = nil
        attachmentsBeforeEditing = nil
        draft = savedDraft
        draftAttachments = savedAttachments
        historyError = nil
    }

    private func finishEditingAfterSuccess() {
        editingMessageID = nil
        draftBeforeEditing = nil
        attachmentsBeforeEditing = nil
        draft = ""
        draftAttachments = []
        historyError = nil
    }

    public func rewind(messageID: String) {
        guard let conversationID = selected?.id else { return }
        historyError = nil
        do {
            _ = try bridge.rewind(
                conversationID: conversationID,
                beforeMessageID: messageID
            )
            cancelEditing()
        } catch {
            historyError = error.localizedDescription
        }
    }

    private func selectConversation(_ id: String) {
        guard id != bridge.selectedID else { return }
        cancelEditing()
        saveDraftState()
        bridge.select(id)
        restoreDraftState()
    }

    private func saveDraftState() {
        guard let id = bridge.selectedID else { return }
        draftsByConversation[id] = draft
        draftAttachmentsByConversation[id] = draftAttachments
    }

    private func restoreDraftState() {
        guard let id = bridge.selectedID else {
            draft = ""
            draftAttachments = []
            return
        }
        draft = draftsByConversation[id] ?? ""
        draftAttachments = draftAttachmentsByConversation[id] ?? []
    }

    public func refreshVoiceModel() {
        let provider = voiceProvider
        guard provider.isFileBacked,
              voiceModelState(for: provider) != .downloading,
              voiceModelState(for: provider) != .paused else { return }
        switch provider {
        case .whisperTinyQ5:
            if voice.selectedModel.id != LocalVoiceModel.whisperTinyQ5.id {
                voice.configure(model: .whisperTinyQ5)
            }
            setVoiceModelState(voice.isModelInstalled ? .installed : .notInstalled, for: provider)
        case .whisperLargeV3Turbo:
            if voice.selectedModel.id != LocalVoiceModel.whisperLargeV3Turbo.id {
                voice.configure(model: .whisperLargeV3Turbo)
            }
            setVoiceModelState(voice.isModelInstalled ? .installed : .notInstalled, for: provider)
        case .customLocal:
            if voice.selectedModel.id != LocalVoiceModel.custom.id {
                voice.configure(model: .custom)
            }
            setVoiceModelState(voice.isModelInstalled ? .installed : .notInstalled, for: provider)
        case .nemotron:
            setVoiceModelState(nemotron.isReady ? .installed : .notInstalled, for: provider)
        case .api:
            break
        }
    }

    public func refreshSpeechModel() {
        setSpeechModelState(localSpeech.isModelInstalled ? .installed : .notInstalled)
    }

    public func requestSpeechModelDownload() {
        refreshSpeechModel()
        guard !isSpeechModelInstalled, !isSpeechModelDownloading else { return }

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = AppCopy.text("speech.download.title")
        alert.informativeText = AppCopy.format(
            "speech.download.message",
            LocalSpeechModel.turkishPiper.name,
            "21 MB"
        )
        alert.addButton(withTitle: AppCopy.text("speech.download.action"))
        alert.addButton(withTitle: AppCopy.text("speech.download.cancel"))
        if alert.runModal() == .alertFirstButtonReturn {
            downloadSpeechModel()
        }
    }

    public func downloadSpeechModel() {
        refreshSpeechModel()
        guard !isSpeechModelInstalled, !isSpeechModelDownloading else { return }

        let key = LocalSpeechModel.turkishPiper.id
        setSpeechModelState(.downloading)
        setVoiceModelProgress(
            FileDownloader.Progress(received: 0, expected: LocalSpeechModel.turkishPiper.archiveBytes),
            forKey: key
        )

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let progressHandler: @Sendable (FileDownloader.Progress) -> Void = { [weak self] progress in
                    Task { @MainActor in
                        self?.setVoiceModelProgress(progress, forKey: key)
                    }
                }
                try await self.localSpeech.ensureModel(progress: progressHandler)
                self.setSpeechModelState(self.localSpeech.isModelInstalled ? .installed : .failed(AppCopy.text("speech.modelIncomplete")))
            } catch is CancellationError {
                self.setSpeechModelState(.notInstalled)
            } catch {
                self.setSpeechModelState(.failed(error.localizedDescription))
            }
        }
    }

    public func deleteSpeechModel() {
        guard !isSpeechModelDownloading else { return }
        do {
            try localSpeech.deleteModel()
            setSpeechModelState(.notInstalled)
        } catch {
            setSpeechModelState(.failed(error.localizedDescription))
        }
    }

    public func requestVoiceModelDownload() {
        refreshVoiceModel()
        let provider = voiceProvider
        guard provider == .whisperTinyQ5 || provider == .whisperLargeV3Turbo || provider == .nemotron,
              !isVoiceModelInstalled,
              !isVoiceModelDownloading,
              !isVoiceDownloadPromptShowing else { return }

        isVoiceDownloadPromptShowing = true
        defer { isVoiceDownloadPromptShowing = false }

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = VoiceCopy.downloadTitle
        let selected: LocalVoiceModel = switch provider {
        case .whisperTinyQ5: LocalVoiceModel.whisperTinyQ5
        case .whisperLargeV3Turbo: LocalVoiceModel.whisperLargeV3Turbo
        case .nemotron: LocalVoiceModel.nemotron
        case .customLocal, .api: LocalVoiceModel.whisperTinyQ5
        }
        alert.informativeText = VoiceCopy.downloadMessage(
            model: selected.name,
            size: selected.sizeLabel
        )
        if provider == .nemotron {
            alert.informativeText += "\n\n\(VoiceCopy.nemotronHint)"
        }
        alert.addButton(withTitle: VoiceCopy.downloadAction)
        alert.addButton(withTitle: VoiceCopy.downloadCancel)

        if alert.runModal() == .alertFirstButtonReturn {
            downloadVoiceModel()
        }
    }

    public func downloadVoiceModel() {
        let wasPaused = voiceModelState == .paused
        refreshVoiceModel()
        let provider = voiceProvider
        guard provider == .whisperTinyQ5 || provider == .whisperLargeV3Turbo || provider == .nemotron,
              !isVoiceModelInstalled,
              !isVoiceModelDownloading else { return }

        setVoiceModelState(.downloading, for: provider)
        let hadRuntime = provider == .nemotron
            ? (wasPaused ? voiceDownloadHadRuntime : nemotron.runtimeInstalled())
            : false
        voiceDownloadHadRuntime = hadRuntime
        voiceDownloadStopReason = nil
        let selectedModel: LocalVoiceModel = switch provider {
        case .whisperTinyQ5: LocalVoiceModel.whisperTinyQ5
        case .whisperLargeV3Turbo: LocalVoiceModel.whisperLargeV3Turbo
        case .nemotron: LocalVoiceModel.nemotron
        case .customLocal, .api: LocalVoiceModel.whisperTinyQ5
        }
        setVoiceModelProgress(
            FileDownloader.Progress(received: 0, expected: selectedModel.bytes),
            for: provider
        )
        let transcriber: LocalVoiceTranscriber? = switch provider {
        case .whisperTinyQ5:
            LocalVoiceTranscriber(paths: paths, model: .whisperTinyQ5)
        case .whisperLargeV3Turbo:
            LocalVoiceTranscriber(paths: paths, model: .whisperLargeV3Turbo)
        case .nemotron, .customLocal, .api:
            nil
        }

        voiceDownloadTask = Task { @MainActor [weak self] in
            do {
                guard let self else { return }
                let progressHandler: @Sendable (FileDownloader.Progress) -> Void = { [weak self] progress in
                    Task { @MainActor in
                        self?.setVoiceModelProgress(progress, for: provider)
                    }
                }
                if provider == .nemotron {
                    try await self.nemotron.ensureRuntime(progress: progressHandler)
                    try await self.nemotron.ensureModel(progress: progressHandler)
                } else if let transcriber {
                    try await transcriber.ensureModel(progress: progressHandler)
                }
                try Task.checkCancellation()
                let ready = provider == .nemotron ? self.nemotron.isReady : (transcriber?.isModelInstalled ?? false)
                self.setVoiceModelState(ready ? .installed : .failed(AppCopy.text("voice.modelIncomplete")), for: provider)
                self.prewarmNemotron()
                self.finishVoiceDownload()
            } catch {
                guard let self else { return }
                switch self.voiceDownloadStopReason {
                case .pause:
                    self.setVoiceModelState(.paused, for: provider)
                    self.voiceDownloadTask = nil
                    self.voiceDownloadStopReason = nil
                case .cancel:
                    self.discardVoiceDownload(for: provider, hadRuntime: hadRuntime)
                    self.setVoiceModelState(.notInstalled, for: provider)
                    self.finishVoiceDownload()
                case nil:
                    if provider == .nemotron && !hadRuntime {
                        try? self.nemotron.removeRuntimeArtifacts()
                    }
                    self.setVoiceModelState(.failed(error.localizedDescription), for: provider)
                    self.finishVoiceDownload()
                }
            }
        }
    }

    public func pauseVoiceModelDownload() {
        guard isVoiceModelDownloading else { return }
        voiceDownloadStopReason = .pause
        voiceDownloadTask?.cancel()
    }

    public func resumeVoiceModelDownload() {
        guard voiceModelState == .paused else { return }
        downloadVoiceModel()
    }

    public func cancelVoiceModelDownload() {
        guard voiceModelState == .downloading || voiceModelState == .paused else { return }
        if voiceModelState == .downloading {
            voiceDownloadStopReason = .cancel
            voiceDownloadTask?.cancel()
            return
        }

        discardVoiceDownload(for: voiceProvider, hadRuntime: voiceDownloadHadRuntime)
        setVoiceModelState(.notInstalled, for: voiceProvider)
        finishVoiceDownload()
    }

    public func deleteVoiceModel() {
        let provider = voiceProvider
        guard provider.isFileBacked, voiceModelState(for: provider) != .downloading else { return }
        do {
            switch provider {
            case .whisperTinyQ5:
                voice.configure(model: .whisperTinyQ5)
                try voice.deleteModel()
            case .whisperLargeV3Turbo:
                voice.configure(model: .whisperLargeV3Turbo)
                try voice.deleteModel()
            case .customLocal:
                voice.configure(model: .custom)
                try voice.deleteModel()
            case .nemotron:
                try nemotron.deleteModel()
            case .api:
                break
            }
            setVoiceModelState(.notInstalled, for: provider)
        } catch {
            setVoiceModelState(.failed(error.localizedDescription), for: provider)
        }
    }

    public func requestVoiceInputSetup() {
        refreshVoiceModel()
        guard !isVoiceReady else { return }

        switch voiceProvider {
        case .whisperTinyQ5:
            requestVoiceModelDownload()
        case .whisperLargeV3Turbo:
            requestVoiceModelDownload()
        case .customLocal:
            importLocalVoiceModel()
        case .nemotron:
            requestVoiceModelDownload()
        case .api:
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = VoiceCopy.setupTitle
            alert.informativeText = VoiceCopy.setupMessage
            alert.addButton(withTitle: VoiceCopy.openSettings)
            alert.addButton(withTitle: VoiceCopy.setupCancel)
            if alert.runModal() == .alertFirstButtonReturn {
                presentSettings()
            }
        }
    }

    public func setVoiceProvider(_ provider: VoiceInputProvider) {
        if voiceProvider == .nemotron, provider != .nemotron {
            nemotron.stop()
        }
        voiceProvider = provider
        if provider == .whisperTinyQ5 {
            voice.configure(model: .whisperTinyQ5)
        } else if provider == .whisperLargeV3Turbo {
            voice.configure(model: .whisperLargeV3Turbo)
        } else if provider == .customLocal {
            voice.configure(model: .custom)
        }
        refreshVoiceModel()
        prewarmNemotron()
        persistVoiceInputSettings()
    }

    public func setVoiceAPIEndpoint(_ value: String) {
        voiceAPIEndpoint = value
        persistVoiceInputSettings()
    }

    public func setVoiceAPIKey(_ value: String) {
        voiceAPIKey = value
        persistVoiceInputSettings()
    }

    public func setVoiceAPIModel(_ value: String) {
        voiceAPIModel = value
        persistVoiceInputSettings()
    }

    public func setVoiceAPIRealtimeEndpoint(_ value: String) {
        voiceAPIRealtimeEndpoint = value
        persistVoiceInputSettings()
    }

    private func prewarmNemotron() {
        guard voiceProvider == .nemotron, nemotron.isReady else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard self.voiceProvider == .nemotron, self.nemotron.isReady else { return }
            do {
                _ = try self.nemotron.start()
                _ = await self.nemotron.waitUntilReady()
            } catch {
                // The transcription path reports the actionable error on use.
            }
        }
    }

    public func importLocalVoiceModel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.data]
        panel.allowsOtherFileTypes = true
        panel.prompt = VoiceCopy.importModel
        panel.message = VoiceCopy.localModelHint
        panel.begin { [weak self] response in
            guard response == .OK, let source = panel.url else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    self.setVoiceProvider(.customLocal)
                    self.voice.configure(model: .custom)
                    try self.voice.importModel(from: source)
                    self.setVoiceModelState(.installed, for: .customLocal)
                    self.persistVoiceInputSettings()
                } catch {
                    self.setVoiceModelState(.failed(error.localizedDescription), for: .customLocal)
                }
            }
        }
    }

    public func transcribeVoice(samples: [Float], sampleRate: Double) async throws -> String {
        switch voiceProvider {
        case .whisperTinyQ5, .whisperLargeV3Turbo, .customLocal:
            refreshVoiceModel()
            guard isVoiceModelInstalled else {
                throw NativeAgentError(AppCopy.text("voice.modelNotReady"))
            }
            return try await voice.transcribe(samples: samples, sampleRate: sampleRate)
        case .nemotron:
            guard nemotron.isReady else {
                throw NativeAgentError(AppCopy.text("voice.modelNotReady"))
            }
            _ = try nemotron.start()
            guard await nemotron.waitUntilReady() else {
                nemotron.stop()
                throw NativeAgentError(AppCopy.text("voice.runtime.notReady"))
            }
            return try await VoiceAPITranscriber.transcribe(
                samples: samples,
                sampleRate: sampleRate,
                configuration: VoiceAPIConfiguration(
                    endpoint: nemotron.serverURL.absoluteString,
                    apiKey: "",
                    model: "default"
                )
            )
        case .api:
            return try await VoiceAPITranscriber.transcribe(
                samples: samples,
                sampleRate: sampleRate,
                configuration: VoiceAPIConfiguration(
                    endpoint: voiceAPIEndpoint,
                    apiKey: voiceAPIKey,
                    model: voiceAPIModel,
                    realtimeEndpoint: voiceAPIRealtimeEndpoint
                )
            )
        }
    }

    public func makeVoiceStreamingSession(
        onUpdate: @escaping @Sendable (VoiceTranscriptUpdate) -> Void,
        onError: @escaping @Sendable (Error) -> Void
    ) async throws -> VoiceStreamingSession {
        switch voiceProvider {
        case .whisperTinyQ5, .whisperLargeV3Turbo, .customLocal:
            refreshVoiceModel()
            guard isVoiceModelInstalled else {
                throw NativeAgentError(AppCopy.text("voice.modelNotReady"))
            }
            let transcriber = voice
            return VoiceStreamingSession(
                mode: .rollingWhisper,
                batchTranscriber: { samples in
                    try await transcriber.transcribe(samples: samples, sampleRate: 16_000)
                },
                onUpdate: onUpdate,
                onError: onError
            )
        case .nemotron:
            guard nemotron.isReady else {
                throw NativeAgentError(AppCopy.text("voice.modelNotReady"))
            }
            _ = try nemotron.start()
            guard await nemotron.waitUntilReady() else {
                nemotron.stop()
                throw NativeAgentError(AppCopy.text("voice.runtime.notReady"))
            }
            let client = VoiceAPIRealtimeClient(
                configuration: VoiceAPIConfiguration(
                    endpoint: nemotron.serverURL.absoluteString,
                    apiKey: "",
                    model: "default"
                ),
                onUpdate: onUpdate,
                onError: onError
            )
            try await client.start()
            return VoiceStreamingSession(
                mode: .realtime,
                realtimePush: { samples in client.send(samples: samples) },
                realtimeCommit: { client.commit() },
                realtimeCancel: { client.cancel() },
                onUpdate: onUpdate,
                onError: onError
            )
        case .api:
            let configuration = VoiceAPIConfiguration(
                endpoint: voiceAPIEndpoint,
                apiKey: voiceAPIKey,
                model: voiceAPIModel,
                realtimeEndpoint: voiceAPIRealtimeEndpoint
            )
            guard configuration.isConfigured else {
                throw NativeAgentError(AppCopy.text("voice.apiSettingsMissing"))
            }
            if !configuration.realtimeEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                do {
                    let client = VoiceAPIRealtimeClient(
                        configuration: configuration,
                        onUpdate: onUpdate,
                        onError: onError
                    )
                    try await client.start()
                    return VoiceStreamingSession(
                        mode: .realtime,
                        realtimePush: { samples in client.send(samples: samples) },
                        realtimeCommit: { client.commit() },
                        realtimeCancel: { client.cancel() },
                        onUpdate: onUpdate,
                        onError: onError
                    )
                } catch {
                    // An incompatible or unavailable WebSocket endpoint falls back
                    // to the existing HTTP transcription path for this session.
                }
            }
            return VoiceStreamingSession(
                mode: .utteranceHTTP,
                batchTranscriber: { samples in
                    try await VoiceAPITranscriber.transcribe(
                        samples: samples,
                        sampleRate: 16_000,
                        configuration: configuration
                    )
                },
                onUpdate: onUpdate,
                onError: onError
            )
        }
    }

    public func toggleSpeech(_ text: String, messageID: String? = nil) {
        if speech.isSpeaking {
            speechRequestID = nil
            speechTask?.cancel()
            speechTask = nil
            speech.stop()
            return
        }

        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        let requestID = UUID()
        speechRequestID = requestID
        speech.beginRemoteSpeech(messageID: messageID)
        speechTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.speechRequestID == requestID {
                    self.speechRequestID = nil
                    self.speechTask = nil
                }
            }

            do {
                let url: URL
                if self.localSpeech.isModelInstalled,
                   LocalSpeechSynthesizer.languageCode(for: text)?.hasPrefix("tr") == true {
                    url = try await self.localSpeech.synthesize(text)
                } else {
                    url = try await self.bridge.synthesizeSpeech(text)
                }
                guard !Task.isCancelled, self.speechRequestID == requestID else { return }
                if !self.speech.play(url, messageID: messageID) {
                    self.speech.speak(text, messageID: messageID)
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, self.speechRequestID == requestID else { return }
                do {
                    let url = try await self.bridge.synthesizeSpeech(text)
                    guard !Task.isCancelled, self.speechRequestID == requestID else { return }
                    if !self.speech.play(url, messageID: messageID) {
                        self.speech.speak(text, messageID: messageID)
                    }
                } catch is CancellationError {
                    return
                } catch {
                    self.speech.speak(text, messageID: messageID)
                }
            }
        }
    }

    public func shutdownVoice() {
        speechRequestID = nil
        speechTask?.cancel()
        speechTask = nil
        speech.stop()
        nemotron.stop()
    }

    private func setVoiceModelState(_ state: LocalVoiceModelState, for provider: VoiceInputProvider) {
        var states = voiceModelStates
        states[provider.rawValue] = state
        voiceModelStates = states
    }

    private func setVoiceModelProgress(_ progress: FileDownloader.Progress, for provider: VoiceInputProvider) {
        var progresses = voiceModelProgress
        progresses[provider.rawValue] = progress
        voiceModelProgress = progresses
    }

    private func setVoiceModelProgress(_ progress: FileDownloader.Progress, forKey key: String) {
        var progresses = voiceModelProgress
        progresses[key] = progress
        voiceModelProgress = progresses
    }

    private func discardVoiceDownload(for provider: VoiceInputProvider, hadRuntime: Bool) {
        switch provider {
        case .whisperTinyQ5:
            voice.configure(model: .whisperTinyQ5)
            try? voice.deleteModel()
        case .whisperLargeV3Turbo:
            voice.configure(model: .whisperLargeV3Turbo)
            try? voice.deleteModel()
        case .nemotron:
            try? nemotron.deleteModel()
            if !hadRuntime {
                try? nemotron.removeRuntimeArtifacts(includePartial: true)
            }
        case .customLocal, .api:
            break
        }
    }

    private func finishVoiceDownload() {
        voiceDownloadTask = nil
        voiceDownloadStopReason = nil
        voiceDownloadHadRuntime = false
    }

    private func setSpeechModelState(_ state: LocalVoiceModelState) {
        var states = voiceModelStates
        states[LocalSpeechModel.turkishPiper.id] = state
        voiceModelStates = states
    }

    private func persistVoiceInputSettings() {
        host.settings.set("voice.provider", .string(voiceProvider.rawValue))
        host.settings.set("voice.api.endpoint", .string(voiceAPIEndpoint))
        host.settings.set("voice.api.key", .string(voiceAPIKey))
        host.settings.set("voice.api.model", .string(voiceAPIModel))
        host.settings.set("voice.api.realtimeEndpoint", .string(voiceAPIRealtimeEndpoint))
        persistSettings()
    }

    public func setWorkspace(_ value: String) {
        cancelEditing()
        let normalized = Self.validWorkspacePath(value) ?? ""
        workspacePath = normalized
        host.settings.set("agent.workspace", normalized.isEmpty ? .null : .string(normalized))
        persistSettings()
        bridge.setWorkspace(normalized)
        skills.setWorkspace(normalized.isEmpty ? nil : normalized)
        restoreDraftState()
        Task { await bridge.refreshConnection() }
    }

    public func setModel(_ value: String) {
        router.selectedModelID = value
        endpoint.modelID = value
        endpoint.updateStatus()
        host.settings.set("agent.model", value.isEmpty ? .null : .string(value))
        // Levels are model-specific, so a level the new model rejects must not
        // carry over — it would fail the next request with HTTP 400.
        if !router.efforts(for: value).contains(router.selectedEffort) { setEffort("") }
        persistSettings()
        Task { await bridge.refreshConnection() }
    }

    /// Reasoning effort for the selected model. Empty means the provider default.
    public func setEffort(_ value: String) {
        router.selectedEffort = value
        host.settings.set("agent.effort", value.isEmpty ? .null : .string(value))
        persistSettings()
    }

    public func setAppearance(_ value: Appearance) {
        appearance = value
        host.settings.set("ui.appearance", .string(value.rawValue))
        persistSettings()
    }

    public func setPermissionMode(_ value: AgentPermissionMode) {
        permissionMode = value
        bridge.setPermissionMode(value)
        host.settings.set("agent.permissionMode", .string(value.rawValue))
        persistSettings()
    }

    public func dismissFullAccessWarning() {
        guard !fullAccessWarningDismissed else { return }
        fullAccessWarningDismissed = true
        host.settings.set("ui.fullAccessWarningDismissed", .bool(true))
        persistSettings()
    }

    public func dismissVoiceIntro() {
        guard !voiceIntroSeen else { return }
        voiceIntroSeen = true
        host.settings.set("ui.voiceIntroSeen", .bool(true))
        persistSettings()
    }

    public func setAppLanguage(_ value: AppLanguage) {
        AppCopy.setLanguage(value)
        appLanguage = value
        host.settings.set("ui.language", .string(value.rawValue))
        persistSettings()
    }

    public func setConfirmBeforeExit(_ value: Bool) {
        confirmBeforeExit = value
        host.settings.set("ui.confirmBeforeExit", .bool(value))
        persistSettings()
    }

    public func showPet() {
        isPetVisible = true
    }

    public func hidePet() {
        isPetVisible = false
    }

    public func presentSettings() {
        isSettingsPresented = true
    }

    public func presentUsage() {
        isUsagePresented = true
    }

    // MARK: - /goal

    /// Freeform goal for the current session, injected into the agent system
    /// prompt. Empty means "no goal set".
    @Published public private(set) var sessionGoal: String = ""
    private var sessionGoalRetract: (() -> Void)?

    /// Sets (or clears, when blank) the session goal and refreshes the system prompt.
    public func setSessionGoal(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        sessionGoal = trimmed
        sessionGoalRetract?()
        sessionGoalRetract = nil
        if !trimmed.isEmpty {
            sessionGoalRetract = host.prompt.section(
                name: "session:goal",
                order: 10,
                text: "## Session goal\n\nThe user is working toward this goal for the current session. Keep responses aligned with it and flag when work drifts away from it:\n\n\(trimmed)"
            )
        }
        bridge.updateSystemPrompt(host.prompt.assembledText())
    }

    // MARK: - /loop

    /// Creates a recurring scheduled task that re-runs `instruction` in the current
    /// workspace every `everyMinutes` minutes. Managed afterwards from the Tasks sheet.
    @discardableResult
    public func createLoopTask(everyMinutes: Int, instruction: String) -> ScheduledTask {
        let task = ScheduledTask(
            name: String(instruction.prefix(48)),
            cron: Self.loopCron(everyMinutes: everyMinutes),
            prompt: instruction,
            workspacePath: workspacePath
        )
        scheduler.upsert(task)
        return task
    }

    /// ponytail: minute intervals that don't divide 60 fire on the hour boundary
    /// (e.g. `*/45` -> :00 and :45), not as a true rolling interval. Good enough
    /// for "every N minutes" loops; upgrade to a real interval scheduler if needed.
    static func loopCron(everyMinutes m: Int) -> String {
        let mins = max(1, m)
        if mins < 60 { return "*/\(mins) * * * *" }
        let hours = mins / 60
        return hours < 24 ? "0 */\(hours) * * *" : "0 0 * * *"
    }

    public func signOut() {
        isPetVisible = false
        setWorkspace("")
    }

    public func persistSettings() {
        let snapshot = host.settings.snapshot()
        if let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: paths.settings, options: .atomic)
        }
    }

    public func assembledSystemPrompt() -> String {
        host.prompt.assembledText()
    }

    private static func validWorkspacePath(_ value: String) -> String? {
        guard let normalized = ConversationStore.normalizedPath(value), normalized != "/" else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: normalized, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        return normalized
    }

    private static func loadSettings(from url: URL) -> InMemorySettingsRegistry {
        if let data = try? Data(contentsOf: url),
           let values = try? JSONDecoder().decode([String: JSONValue].self, from: data) {
            return InMemorySettingsRegistry(values: values)
        }
        return InMemorySettingsRegistry()
    }

}

public enum CompositionLoader {
    public static func bundledHost() -> CompositionDocument {
        CompositionDocument(plane: .host, entries: [])
    }

    public static func loadHost(paths: SupportPaths, catalog: PluginCatalog) -> CompositionDocument {
        var document = bundledHost()
        if FileManager.default.fileExists(atPath: paths.hostPatch.path),
           let text = try? String(contentsOf: paths.hostPatch, encoding: .utf8),
           let patches = try? MiniYAML.loadPatches(from: text) {
            document = CompositionPatch.apply(patches, to: document)
        }
        var entries = document.entries
        for index in entries.indices {
            if let item = catalog.entries.first(where: { $0.manifest.id == entries[index].plugin }) {
                if !item.enabled { entries[index].disabled = true }
            }
        }
        document.entries = entries
        return document
    }
}

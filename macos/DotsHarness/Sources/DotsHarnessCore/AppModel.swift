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
    public let host: PluginHost
    public let paths: SupportPaths
    public let bridge: AgentBridge
    public let router: RouterController
    public let endpoint: AgentEndpointController
    public lazy var marketplace: MarketplaceClient = {
        let raw = host.settings.get("marketplace.indexURL")?.string ?? MarketplaceClient.defaultIndex
        let url = URL(string: raw) ?? URL(string: MarketplaceClient.defaultIndex)!
        return MarketplaceClient(indexURL: url, catalog: catalog)
    }()
    public lazy var local: LocalRuntimeController = LocalRuntimeController(paths: paths, router: router)
    public lazy var voice: LocalVoiceTranscriber = LocalVoiceTranscriber(paths: paths)
    public lazy var nemotron: NemotronRuntime = NemotronRuntime(paths: paths)
    public lazy var speech = LocalSpeechSynthesizer()
    public lazy var simulator = SimulatorController()
    public lazy var scheduler: TaskScheduler = TaskScheduler(store: TaskStore(paths: paths)) { [weak self] task in
        await self?.runScheduledTask(task) ?? TaskScheduler.RunResult(ok: false, message: "app unavailable")
    }

    @Published public var draft: String = "" {
        didSet {
            guard let id = bridge.selectedID else { return }
            draftsByConversation[id] = draft
        }
    }
    @Published public private(set) var draftImages: [URL] = [] {
        didSet {
            guard let id = bridge.selectedID else { return }
            draftImagesByConversation[id] = draftImages
        }
    }
    @Published public var appearance: Appearance = .system
    @Published public var confirmBeforeExit = true
    @Published public private(set) var workspacePath: String
    @Published public var isPetVisible = false
    @Published public var isSettingsPresented = false
    @Published public var isUsagePresented = false
    @Published public var isTasksPresented = false
    @Published public var isSimulatorPresented = false
    @Published public var voiceProvider: VoiceInputProvider = .whisperLargeV3Turbo
    @Published public var voiceAPIEndpoint = ""
    @Published public var voiceAPIKey = ""
    @Published public var voiceAPIModel = ""
    @Published public private(set) var voiceModelStates: [String: LocalVoiceModelState] = [:]

    public var conversations: [Conversation] { bridge.conversations }
    public var selectedConversationID: String? {
        get { bridge.selectedID }
        set {
            if let newValue { selectConversation(newValue) }
        }
    }
    public var selected: Conversation? { bridge.selected }
    public var statusLine: String { bridge.status }
    public var selectedModelID: String {
        get { endpoint.modelID }
        set { setModel(newValue) }
    }
    public var isFirstLaunch: Bool { workspacePath.isEmpty }
    public var canSend: Bool { bridge.isReady }
    public var voiceModelState: LocalVoiceModelState { voiceModelState(for: voiceProvider) }
    public func voiceModelState(for provider: VoiceInputProvider) -> LocalVoiceModelState {
        voiceModelStates[provider.rawValue] ?? .notInstalled
    }
    public var isVoiceModelInstalled: Bool { voiceModelState.isInstalled }
    public var isVoiceModelDownloading: Bool { voiceModelState == .downloading }
    public var voiceModelStatusText: String { voiceModelState.title }
    public var isVoiceReady: Bool {
        switch voiceProvider {
        case .whisperLargeV3Turbo, .customLocal:
            return isVoiceModelInstalled
        case .nemotron:
            return nemotron.isReady
        case .api:
            return VoiceAPIConfiguration(
                endpoint: voiceAPIEndpoint,
                apiKey: voiceAPIKey,
                model: voiceAPIModel
            ).isConfigured
        }
    }
    public var voiceInputHelp: String {
        if isVoiceModelDownloading { return VoiceCopy.downloading }
        if isVoiceReady {
            return VoiceCopy.microphoneReady
        }
        switch voiceProvider {
        case .whisperLargeV3Turbo, .customLocal, .nemotron:
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

        let catalog = PluginCatalog(paths: paths)
        for builtin in builtins {
            catalog.registerBuiltin(builtin, refresh: false)
        }
        self.catalog = catalog

        let settings = Self.loadSettings(from: paths.settings)
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

        let router = RouterController(paths: paths)
        router.selectedModelID = settings.get("agent.model")?.string ?? ""
        self.router = router

        let endpoint = AgentEndpointController(
            baseURL: "",
            modelID: settings.get("agent.model")?.string ?? "",
            apiKey: ""
        )
        self.endpoint = endpoint
        self.bridge = AgentBridge(paths: paths, endpoint: endpoint, router: router)
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
        appModelReference.model = self
    }

    private var cancellables = Set<AnyCancellable>()
    private var hasStarted = false
    private var hasBootstrapped = false
    private var activeOptionalPluginIDs = Set<String>()
    // ponytail: keep unsent drafts in memory; persist only if restart recovery is required.
    private var draftsByConversation: [String: String] = [:]
    private var draftImagesByConversation: [String: [URL]] = [:]
    private let appModelReference: AppModelReference
    private var isVoiceDownloadPromptShowing = false

    public func start() {
        guard !hasStarted else { return }
        hasStarted = true
        refreshVoiceModel()

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
        let document = CompositionLoader.loadHost(paths: paths, catalog: catalog)
        _ = host.mount(document)
        bridge.updateSystemPrompt(host.prompt.assembledText())
        objectWillChange.send()
    }

    public func newConversation() {
        saveDraftState()
        bridge.newConversation()
        restoreDraftState()
    }

    public func addDraftImages(_ urls: [URL]) {
        let newImages = urls.filter { !draftImages.contains($0) }
        guard !newImages.isEmpty else { return }
        draftImages.append(contentsOf: newImages)
    }

    public func removeDraftImage(_ url: URL) {
        draftImages.removeAll { $0 == url }
    }

    public func send(mode: PromptMode = .queue) {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard canSend else { return }
        draft = ""
        draftImages = []
        Task { await bridge.send(text: text, mode: mode) }
    }

    private func selectConversation(_ id: String) {
        guard id != bridge.selectedID else { return }
        saveDraftState()
        bridge.select(id)
        restoreDraftState()
    }

    private func saveDraftState() {
        guard let id = bridge.selectedID else { return }
        draftsByConversation[id] = draft
        draftImagesByConversation[id] = draftImages
    }

    private func restoreDraftState() {
        guard let id = bridge.selectedID else {
            draft = ""
            draftImages = []
            return
        }
        draft = draftsByConversation[id] ?? ""
        draftImages = draftImagesByConversation[id] ?? []
    }

    public func refreshVoiceModel() {
        let provider = voiceProvider
        guard provider.isFileBacked, voiceModelState(for: provider) != .downloading else { return }
        switch provider {
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

    public func requestVoiceModelDownload() {
        refreshVoiceModel()
        let provider = voiceProvider
        guard provider == .whisperLargeV3Turbo || provider == .nemotron,
              !isVoiceModelInstalled,
              !isVoiceModelDownloading,
              !isVoiceDownloadPromptShowing else { return }

        isVoiceDownloadPromptShowing = true
        defer { isVoiceDownloadPromptShowing = false }

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = VoiceCopy.downloadTitle
        let selected = provider == .nemotron ? LocalVoiceModel.nemotron : LocalVoiceModel.whisperLargeV3Turbo
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
        refreshVoiceModel()
        let provider = voiceProvider
        guard provider == .whisperLargeV3Turbo || provider == .nemotron,
              !isVoiceModelInstalled,
              !isVoiceModelDownloading else { return }

        setVoiceModelState(.downloading, for: provider)
        let hadRuntime = provider == .nemotron && nemotron.runtimeInstalled()
        let transcriber = provider == .whisperLargeV3Turbo
            ? LocalVoiceTranscriber(paths: paths, model: .whisperLargeV3Turbo)
            : nil

        Task { @MainActor [weak self] in
            do {
                guard let self else { return }
                if provider == .nemotron {
                    try await self.nemotron.ensureRuntime()
                    try await self.nemotron.ensureModel()
                } else if let transcriber {
                    try await transcriber.ensureModel()
                }
                let ready = provider == .nemotron ? self.nemotron.isReady : (transcriber?.isModelInstalled ?? false)
                self.setVoiceModelState(ready ? .installed : .failed(AppCopy.text("voice.modelIncomplete")), for: provider)
            } catch is CancellationError {
                if provider == .nemotron && !hadRuntime { try? self?.nemotron.removeRuntimeArtifacts() }
                self?.setVoiceModelState(.notInstalled, for: provider)
            } catch {
                if provider == .nemotron && !hadRuntime { try? self?.nemotron.removeRuntimeArtifacts() }
                self?.setVoiceModelState(.failed(error.localizedDescription), for: provider)
            }
        }
    }

    public func deleteVoiceModel() {
        let provider = voiceProvider
        guard provider.isFileBacked, voiceModelState(for: provider) != .downloading else { return }
        do {
            switch provider {
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
        if provider == .whisperLargeV3Turbo {
            voice.configure(model: .whisperLargeV3Turbo)
        } else if provider == .customLocal {
            voice.configure(model: .custom)
        }
        refreshVoiceModel()
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
        case .whisperLargeV3Turbo, .customLocal:
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
                    model: voiceAPIModel
                )
            )
        }
    }

    public func shutdownVoice() {
        nemotron.stop()
    }

    private func setVoiceModelState(_ state: LocalVoiceModelState, for provider: VoiceInputProvider) {
        var states = voiceModelStates
        states[provider.rawValue] = state
        voiceModelStates = states
    }

    private func persistVoiceInputSettings() {
        host.settings.set("voice.provider", .string(voiceProvider.rawValue))
        host.settings.set("voice.api.endpoint", .string(voiceAPIEndpoint))
        host.settings.set("voice.api.key", .string(voiceAPIKey))
        host.settings.set("voice.api.model", .string(voiceAPIModel))
        persistSettings()
    }

    public func setWorkspace(_ value: String) {
        let normalized = Self.validWorkspacePath(value) ?? ""
        workspacePath = normalized
        host.settings.set("agent.workspace", normalized.isEmpty ? .null : .string(normalized))
        persistSettings()
        bridge.setWorkspace(normalized)
        restoreDraftState()
        Task { await bridge.refreshConnection() }
    }

    public func setModel(_ value: String) {
        router.selectedModelID = value
        endpoint.modelID = value
        endpoint.updateStatus()
        host.settings.set("agent.model", value.isEmpty ? .null : .string(value))
        persistSettings()
        Task { await bridge.refreshConnection() }
    }

    public func setAppearance(_ value: Appearance) {
        appearance = value
        host.settings.set("ui.appearance", .string(value.rawValue))
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
        CompositionDocument(plane: .host, entries: [
            CompositionEntry(id: "fable-thinking", plugin: "dots.fable-thinking"),
        ])
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

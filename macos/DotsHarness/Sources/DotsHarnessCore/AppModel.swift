// Copyright (c) 2026 DOTS
// Application state for the standalone native harness.

import AppKit
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import HarnessPluginKit
import PluginRuntime

/// Per-project chat sort criteria, chosen from the sidebar's "..." menu.
public enum ConversationSortOrder: String, Codable, Sendable {
    case priority
    case lastUpdate
    case manual
}

/// Signed-in user shown in the sidebar footer. MarketplaceSession replaces the
/// local placeholder after a HerNess desktop session is restored.
public struct AccountIdentity: Equatable, Sendable {
    public var displayName: String
    public var username: String
    public var initials: String
    public var isSignedIn: Bool

    public init(displayName: String, username: String, initials: String, isSignedIn: Bool) {
        self.displayName = displayName
        self.username = username
        self.initials = initials
        self.isSignedIn = isSignedIn
    }

    public static func placeholder() -> AccountIdentity {
        let full = NSFullUserName().isEmpty ? NSUserName() : NSFullUserName()
        return AccountIdentity(
            displayName: full,
            username: NSUserName(),
            initials: initials(from: full),
            isSignedIn: true
        )
    }

    public static func signedOut() -> AccountIdentity {
        AccountIdentity(displayName: "HerNess", username: "", initials: "H", isSignedIn: false)
    }

    public static func initials(from name: String) -> String {
        let parts = name.split(whereSeparator: { $0 == " " || $0 == "." || $0 == "-" || $0 == "_" })
        let letters = parts.prefix(2).compactMap { $0.first }
        let text = String(letters).uppercased()
        return text.isEmpty ? "?" : text
    }
}

/// Whether the sidebar groups chats under project accordions or shows one flat list.
public enum SidebarLayoutMode: String, Codable, Sendable {
    case groupedByProject
    case singleList
}

public struct ProjectMetadata: Codable, Sendable, Equatable {
    public var title: String
    public var pinned: Bool
    public var section: String?
    public var searchFolders: [String]
    public var worktreeOrigin: String?

    public init(
        title: String = "",
        pinned: Bool = false,
        section: String? = nil,
        searchFolders: [String] = [],
        worktreeOrigin: String? = nil
    ) {
        self.title = title
        self.pinned = pinned
        self.section = section
        self.searchFolders = searchFolders
        self.worktreeOrigin = worktreeOrigin
    }
}

@MainActor
public final class AppModelReference {
    public weak var model: AppModel?

    public init(model: AppModel? = nil) {
        self.model = model
    }
}

/// The composer's text, published apart from AppModel so a keystroke only
/// invalidates the composer. Written by `AppModel.draft`; read-only for views.
@MainActor
public final class DraftBox: ObservableObject {
    @Published public internal(set) var text = ""
}

/// Navigation-only state shared by the window and its menu commands.
/// Keeping this out of AppModel's large published state prevents a sidebar
/// toggle from invalidating every view that observes the application model.
@MainActor
public final class SidebarVisibilityState: ObservableObject {
    @Published public var visibility: NavigationSplitViewVisibility

    public init(visibility: NavigationSplitViewVisibility = .all) {
        self.visibility = visibility
    }

    public func toggle() {
        visibility = visibility == .detailOnly ? .all : .detailOnly
    }
}

@MainActor
public final class AppModel: ObservableObject {
    static let voiceCredentialID = "voice.api.key"

    public let catalog: PluginCatalog
    public let skills: SkillCatalog
    public let promptTemplates: PromptTemplateCatalog
    public let skillSuggestions: SkillSuggestionMonitor
    public let host: PluginHost
    public let paths: SupportPaths
    public let bridge: AgentBridge
    public let mcpRegistry: MCPRegistry
    public let router: RouterController
    public let endpoint: AgentEndpointController
    public let remoteEvents: RemoteEventHub
    public let remoteControl: RemoteControlHost
    public let terminalManager: TerminalManager
    public let navigationState: SidebarVisibilityState
    public let notificationInbox = NotificationInbox()
    let desktopNotifications: DesktopNotificationService
    public lazy var updateChecker = UpdateChecker()
    public lazy var marketplaceSession = MarketplaceSession()
    public lazy var marketplace: MarketplaceClient = {
        let raw = host.settings.get("marketplace.indexURL")?.string ?? MarketplaceClient.defaultIndex
        let url = URL(string: raw) ?? URL(string: MarketplaceClient.defaultIndex)!
        return MarketplaceClient(indexURL: url, catalog: catalog, session: marketplaceSession)
    }()
    private var createdLocalRuntime: LocalRuntimeController?
    public lazy var local: LocalRuntimeController = {
        let controller = LocalRuntimeController(paths: paths, router: router)
        createdLocalRuntime = controller
        return controller
    }()
    public lazy var voice: LocalVoiceTranscriber = LocalVoiceTranscriber(paths: paths)
    public lazy var nemotron: NemotronRuntime = NemotronRuntime(paths: paths)
    public lazy var localSpeech: LocalPiperSpeechSynthesizer = LocalPiperSpeechSynthesizer(paths: paths)
    var createdSpeech: LocalSpeechSynthesizer?
    public var speech: LocalSpeechSynthesizer {
        if let createdSpeech { return createdSpeech }
        let instance = LocalSpeechSynthesizer()
        createdSpeech = instance
        return instance
    }
    public func isSpeaking(messageID: String) -> Bool {
        createdSpeech?.activeMessageID == messageID
    }
    public func shutdownLocalModelRuntime() {
        guard let createdLocalRuntime, createdLocalRuntime.runtime.isServing() else { return }
        createdLocalRuntime.runtime.stop()
    }
    public lazy var simulator = SimulatorController()
    public lazy var scheduler: TaskScheduler = TaskScheduler(
        store: TaskStore(paths: paths),
        runStore: TaskRunStore(paths: paths),
        onCompletion: { [weak self] task, result in
            self?.notifyScheduledTask(task, result: result)
        },
        runner: { [weak self] task in
            await self?.runScheduledTask(task) ?? TaskScheduler.RunResult(ok: false, message: "app unavailable")
        }
    )

    /// Not `@Published`: ~50 views observe AppModel, and republishing it per keystroke
    /// re-ran every one of them. The composer observes `draftBox`; everyone else only
    /// needs `draftIsEmpty`, which changes on the first and last character.
    public var draft: String = "" {
        didSet {
            draftBox.text = draft
            if oldValue.isEmpty != draft.isEmpty { draftIsEmpty = draft.isEmpty }
            if oldValue.isEmpty, !draft.isEmpty { warmProviderModels() }
            guard editingMessageID == nil, let id = bridge.selectedID else { return }
            draftsByConversation[draftKey(for: id)] = draft
        }
    }
    @Published public private(set) var draftIsEmpty = true
    public let draftBox = DraftBox()

    /// A send without a cached catalog waits for every provider's model listing. Starting
    /// it when the user begins typing (not at launch: it reads credentials) hides that round
    /// trip behind the time it takes to write the message. Idempotent; sends join it.
    private func warmProviderModels() {
        let router = router
        Task { @MainActor in await router.refreshModelsIfNeeded() }
    }
    @Published public internal(set) var draftAttachments: [ChatAttachment] = [] {
        didSet {
            guard editingMessageID == nil, let id = bridge.selectedID else { return }
            draftAttachmentsByConversation[draftKey(for: id)] = draftAttachments
        }
    }
    public var draftImages: [URL] { draftAttachments.filter { $0.kind == .image }.map(\.url) }
    /// Bumped to ask the composer to take keyboard focus. Only the change matters.
    @Published public var composerFocusRequestID = 0
    /// Bumped to ask the UI to open the plan in the right dock.
    @Published public var planPaneRequestID = 0
    @Published public var reviewPaneRequestID = 0
    @Published public var tasksPaneRequestID = 0
    /// Bumped with `requestedFile` set to show that file in the dock's Files pane.
    @Published public var filesPaneRequestID = 0
    @Published public var requestedFile: URL?
    @Published public var appearance: Appearance = .system
    @Published public var appLanguage: AppLanguage = .system
    @Published public internal(set) var permissionMode: AgentPermissionMode
    @Published public internal(set) var browserBackend: BrowserBackend?
    @Published public internal(set) var isComputerUseEnabled: Bool
    @Published public internal(set) var fullAccessWarningDismissed: Bool
    @Published public var confirmBeforeExit = true
    /// Closing the window keeps the app alive in the menu bar so runs continue.
    @Published public var closeToTray = true
    /// Agent runs its own build/test/check after each change. Default on.
    @Published public var selfVerification = true
    /// Seed AGENTS.md and CLAUDE.md into a workspace that ships neither. Default on.
    @Published public var seedProjectRules = true
    /// Show skill-suggestion cards when a command or prompt repeats. Default on.
    @Published public var skillSuggestionsEnabled = true
    /// Apply generated plans without waiting for a separate plan approval. Default off.
    @Published public var autoApprovePlans = false
    /// What a run does when another chat of the same project is writing the file it wants.
    @Published public var workspaceConflictPolicy: WorkspaceConflictPolicy = .waitThenAsk
    /// How long "wait, then ask" holds a run before it asks the user.
    @Published public var conflictWaitSeconds: Int = WorkspaceConflictPolicy.defaultWaitSeconds
    @Published public internal(set) var workspacePath: String
    /// User-editable shortcuts used by both the menu bar and in-app action rows.
    @Published public internal(set) var keyboardShortcuts: [KeyboardShortcutAction: UserKeyboardShortcut] =
        Dictionary(uniqueKeysWithValues: KeyboardShortcutAction.allCases.map { ($0, $0.defaultShortcut) })
    /// Every project the user has added to the sidebar, most-recent first.
    /// `workspacePath` is always the active entry (or empty if none added yet).
    @Published public internal(set) var projectPaths: [String] = []
    /// Paths whose project folders have disappeared since they were added.
    /// Refreshing this set keeps the sidebar and composer in sync with filesystem changes.
    @Published public internal(set) var unavailableProjectPaths: Set<String> = []
    /// Session-only state for the unsectioned project group in the sidebar.
    /// Deliberately not persisted: a new app session starts with the compact
    /// five-project view again.
    @Published public internal(set) var showsAllOtherProjects = false
    @Published public internal(set) var projectMetadata: [String: ProjectMetadata] = [:]
    @Published public internal(set) var projectSections: [String] = []
    @Published public internal(set) var sidebarLayoutMode: SidebarLayoutMode = .groupedByProject
    /// Projects whose chat sublist is open in the sidebar. Persisted so relaunching
    /// shows exactly the lists the user left open or hidden.
    @Published public internal(set) var expandedProjectPaths: Set<String> = []
    /// Conversation sort order per project path. Missing entries default to `.lastUpdate`.
    @Published public internal(set) var projectSortOrders: [String: ConversationSortOrder] = [:]
    /// Manual conversation order per project path, used when that project's sort order is `.manual`.
    @Published public internal(set) var projectManualOrder: [String: [String]] = [:]
    /// Non-nil while the agent is working in a sandbox worktree instead of the
    /// user's own checkout. `workspacePath` then points at the worktree.
    @Published public internal(set) var activeSandbox: SandboxWorkspace?
    /// Worktrees available for recovery. Git discovery is refreshed off the
    /// main actor so SwiftUI never runs a synchronous Process while laying out
    /// the Settings screen.
    @Published public internal(set) var availableSandboxes: [SandboxWorkspace] = []
    /// Set by `enterSandbox`/`exitSandbox` for the UI to show; not an error.
    @Published public var sandboxNotice: String?
    /// Off by default: sandbox's main job is running code you don't fully
    /// trust yet, and file isolation alone doesn't stop that code from
    /// sending what it can read (workspace contents) to a remote host. Turn
    /// it on per-sandbox when a build genuinely needs the network.
    @Published public var sandboxNetworkAccess = false
    /// The remote-control gateway is opt-in: it only listens while the user
    /// keeps it on, and only on loopback unless LAN sharing is allowed.
    @Published public var remoteControlEnabled: Bool = false {
        didSet { remoteControl.isEnabled = remoteControlEnabled; restoreRemoteCloudTunnel() }
    }
    /// Sharing the gateway with the local network is a second, separate
    /// opt-in — the loopback default keeps it unreachable from the Wi-Fi.
    @Published public var remoteControlSharesWithLAN: Bool = false {
        didSet { remoteControl.sharesWithLAN = remoteControlSharesWithLAN }
    }
    @Published public internal(set) var sandboxConflict: SandboxConflict?
    @Published public internal(set) var sandboxResolutionPreview: SandboxResolutionPreview?
    @Published public internal(set) var sandboxResolutionBusy = false
    @Published public internal(set) var sandboxCleanupPending = false
    @Published public internal(set) var sandboxRecoveryRequired = false
    var sandboxCleanupMerge = true
    /// ponytail: login backend will call `setAccountIdentity(_:)` to replace this.
    @Published public internal(set) var account: AccountIdentity = .signedOut()
    @Published public var isSettingsPresented = false
    @Published public var feedbackRequest: FeedbackTarget? = nil
    @Published public var isUsagePresented = false
    /// The rail section on display. Home is the chat shell.
    @Published public var section: AppSection = .home {
        didSet { commitNavigationDestination() }
    }
    /// Leaving Tasks always lands on Home: every caller that clears this wants the chat.
    public var isTasksPresented: Bool {
        get { section == .tasks }
        set { section = newValue ? .tasks : .home }
    }
    public lazy var mediaStudio = MediaStudioStore(
        root: paths.root.appendingPathComponent("media-studio", isDirectory: true)
    )
    public lazy var musicStudio = MusicStudioStore(
        root: paths.root.appendingPathComponent("music-studio", isDirectory: true)
    )
    public lazy var mediaLibrary = MediaLibraryStore(root: paths.root)
    public lazy var bots = BotStore(
        root: paths.root.appendingPathComponent("bots", isDirectory: true),
        router: router,
        paths: paths,
        systemPrompt: { [weak self] in self?.bridge.effectiveSystemPromptReport() ?? "" }
    )
    @Published public var isSimulatorPresented = false
    /// Screens the toolbar's back/forward buttons walk. `navigationIndex` is the
    /// one on display; -1 means nothing has been navigated to yet.
    @Published public internal(set) var navigationEntries: [NavigationDestination] = []
    @Published public internal(set) var navigationIndex = -1
    /// Set while a history step is being replayed so the navigation it triggers
    /// does not record itself and rewrite the list it came from.
    var isApplyingNavigation = false
    @Published public var isPlanMode = false
    @Published public internal(set) var editingMessageID: String?
    @Published public internal(set) var historyError: String?
    @Published public var voiceProvider: VoiceInputProvider = .whisperTinyQ5
    @Published public var voiceAPIEndpoint = ""
    @Published public var voiceAPIKey = ""
    @Published public var voiceAPIModel = ""
    @Published public var voiceAPIRealtimeEndpoint = ""
    @Published public internal(set) var voiceIntroSeen = false
    @Published public internal(set) var voiceModelStates: [String: LocalVoiceModelState] = [:]
    @Published public internal(set) var voiceModelProgress: [String: FileDownloader.Progress] = [:]
    @Published public internal(set) var visionModelProgress: Double = 0

    /// Live-fetched legal documents and their acceptance state. See LegalConsent.swift.
    @Published public internal(set) var legalDocuments: LegalDocuments?
    @Published public internal(set) var legalNeedsAcceptance = false
    @Published public internal(set) var legalLoadFailed = false
    public internal(set) lazy var legal = LegalService(settings: host.settings, cacheDirectory: paths.root)

    /// Projects are the default scope; the same agent bridge also supports a
    /// separate No project conversation scope.
    public var activeSkills: SkillCatalog { bridge.skills }
    public var activeSkillSuggestions: SkillSuggestionMonitor {
        bridge.skillSuggestions ?? skillSuggestions
    }
    public var conversations: [Conversation] { bridge.conversations }
    public var selectedConversationID: String? {
        get { bridge.selectedID }
        set {
            guard let newValue else { return }
            if bridge.conversations.contains(where: { $0.id == newValue }) {
                selectConversation(newValue)
            }
        }
    }
    public var selected: Conversation? { bridge.selected }
    public var statusLine: String { bridge.status }
    /// The router owns the chosen model so no surface can hold a different one;
    /// `endpoint.modelID` only mirrors it for the direct-endpoint path.
    public var selectedModelID: String {
        get { router.selectedModelID }
        set { setModel(newValue) }
    }
    public var isFirstLaunch: Bool { workspacePath.isEmpty }
    public var showsVoiceIntro: Bool { !voiceIntroSeen }
    public var showsFullAccessWarning: Bool {
        permissionMode == .full && !fullAccessWarningDismissed
    }
    public var appLocale: Locale { AppCopy.locale }
    public var isRTL: Bool { AppCopy.effectiveLanguage.isRTL }
    public var activeProjectLocationAvailable: Bool {
        !workspacePath.isEmpty && Self.canonicalExistingWorkspacePath(workspacePath) != nil
    }
    public var isNoProjectScope: Bool {
        workspacePath.isEmpty && selected?.projectless == true
    }
    public var canSend: Bool {
        bridge.isReady
            && (isNoProjectScope || activeProjectLocationAvailable)
            && !bridge.historyMutationBusy
            && !sandboxCleanupPending
            && !sandboxRecoveryRequired
            && (activeSandbox == nil || sandboxExecutionPolicy != nil)
            && (isNoProjectScope || !workLocation.isRemote || remoteWorkspace != nil)
    }

    public var isEditingMessage: Bool { editingMessageID != nil }
    public var voiceModelState: LocalVoiceModelState { voiceModelState(for: voiceProvider) }
    public func voiceModelState(for provider: VoiceInputProvider) -> LocalVoiceModelState {
        voiceModelStates[provider.rawValue] ?? .notInstalled
    }
    public var isVoiceModelInstalled: Bool { voiceModelState.isInstalled }
    public var isVoiceModelDownloading: Bool { voiceModelState == .downloading }
    public var speechModelState: LocalVoiceModelState {
        voiceModelStates[LocalSpeechModel.turkishPiper.id] ?? .notInstalled
    }
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
        self.promptTemplates = PromptTemplateCatalog(
            globalDirectory: paths.root.appendingPathComponent("prompts", isDirectory: true)
        )
        self.terminalManager = TerminalManager()
        self.navigationState = SidebarVisibilityState()
        self.desktopNotifications = DesktopNotificationService()
        // Migrate before reading legacy Chat metadata. The canonical project
        // session store is now the only source used by the active flow.
        SessionAreaMigration.run(paths: paths)

        let catalog = PluginCatalog(paths: paths)
        for builtin in builtins {
            catalog.registerBuiltin(builtin, refresh: false)
        }
        self.catalog = catalog
        let skills = SkillCatalog(paths: paths)
        self.skills = skills
        let skillSuggestions = SkillSuggestionMonitor(paths: paths, skills: skills)
        self.skillSuggestions = skillSuggestions

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
        let storedBrowserBackend = settings.get("agent.browserBackend")?.string
            .flatMap(BrowserBackend.init(rawValue:))
            .flatMap { $0 == .unknown ? nil : $0 }
        let storedComputerUseEnabled = settings.get("agent.computerUseEnabled")?.bool ?? false
        self.permissionMode = storedPermissionMode
        self.browserBackend = storedBrowserBackend
        self.isComputerUseEnabled = storedComputerUseEnabled
        self.fullAccessWarningDismissed = settings.get("ui.fullAccessWarningDismissed")?.bool ?? false
        self.voiceIntroSeen = settings.get("ui.voiceIntroSeen")?.bool ?? false
        self.appLanguage = storedLanguage
        AppCopy.setLanguage(storedLanguage)
        self.host = PluginHost(catalog: catalog, settings: settings)
        self.keyboardShortcuts = Self.loadKeyboardShortcuts(from: settings)
        host.provideService(
            "support.paths",
            PluginSupportPaths(root: paths.root, plugins: paths.plugins, models: paths.models, runtime: paths.runtime)
        )

        if let stored = settings.get("voice.provider")?.string,
           let provider = VoiceInputProvider(rawValue: stored) {
            self.voiceProvider = provider
        }
        let legacyEndpoint = "http://127.0.0.1:8080/v1"
        let legacyVoiceModel = "nemotron-3.5-asr-streaming-0.6b"
        let storedEndpoint = settings.get("voice.api.endpoint")?.string ?? ""
        let storedModel = settings.get("voice.api.model")?.string ?? ""
        let legacyVoiceAPIKey = settings.get(Self.voiceCredentialID)?.string
        self.voiceAPIEndpoint = storedEndpoint == legacyEndpoint ? "" : storedEndpoint
        self.voiceAPIKey = ""
        self.voiceAPIModel = storedModel == legacyVoiceModel ? "" : storedModel
        self.voiceAPIRealtimeEndpoint = settings.get("voice.api.realtimeEndpoint")?.string ?? ""

        let legacyModel = settings.get("agent.model")?.string ?? ""
        let legacyEffort = settings.get("agent.effort")?.string ?? ""
        let providerStore = NativeProviderStore(paths: paths)
        let router = RouterController(paths: paths, imageAdapters: host.imageAdapters, providerStore: providerStore)
        // The unscoped keys are the current canonical preferences. Read them
        // first so stale coding-scoped values cannot reset the latest choice.
        router.select(modelID: settings.get("agent.model")?.string ?? settings.get("agent.model.coding")?.string ?? legacyModel)
        router.selectedEffort = settings.get("agent.effort")?.string ?? settings.get("agent.effort.coding")?.string ?? legacyEffort
        router.fastMode = settings.get("agent.fast")?.bool ?? settings.get("agent.fast.coding")?.bool ?? false
        router.usageMode = AgentUsageMode(rawValue: settings.get("agent.usageMode")?.string
            ?? settings.get("agent.usageMode.coding")?.string
            ?? "") ?? .standard
        router.autoAccountFailoverAfterLimit = settings.get(RouterController.autoAccountFailoverAfterLimitKey)?.bool ?? false
        router.responseStylePreference = Self.parseResponseStylePreference(
            settings.get(AgentResponseStylePreference.settingsKey)?.string
        )
        router.explorationModelID = settings.get(RouterController.explorationModelKey)?.string ?? ""
        router.subagentsPreference = settings.get(RouterController.subagentsKey)?.bool
        self.router = router

        let endpoint = AgentEndpointController(
            baseURL: "",
            modelID: router.selectedModelID,
            apiKey: ""
        )
        self.endpoint = endpoint
        let bridge = AgentBridge(
            paths: paths,
            endpoint: endpoint,
            router: router,
            skills: skills,
            permissionMode: storedPermissionMode,
            pluginHost: host,
            skillSuggestions: skillSuggestions
        )
        self.bridge = bridge
        bridge.startNetworkWatch()
        bridge.setMemoryEnabled(settings.get(WorkspaceMemory.enabledSettingsKey)?.bool ?? true)
        bridge.setMemoryScanInterval(
            settings.get(MemoryScanInterval.settingsKey)?.string.flatMap(MemoryScanInterval.init(rawValue:)) ?? .daily
        )
        bridge.userTerminalManager = terminalManager
        bridge.setBrowserBackend(storedBrowserBackend)
        bridge.setComputerUseEnabled(storedComputerUseEnabled)
        let mcpRegistry = MCPRegistry(paths: paths)
        self.mcpRegistry = mcpRegistry
        self.bridge.mcpRegistry = mcpRegistry
        // Server-initiated sampling runs on the user's selected model, only after
        // the user approves it in the MCP interaction sheet.
        // ponytail: `maxTokens` and modelPreferences are not forwarded; the
        // router's own output budget applies.
        mcpRegistry.sampler = { [weak router] system, messages, _ in
            guard let router else { throw MCPError.notConnected }
            let prompt = system.isEmpty ? messages : [AgentMessage(role: .system, content: system)] + messages
            let response = try await router.complete(messages: prompt)
            return (response.message.content, router.selectedModelID)
        }
        // Connect MCP servers in background utility priority after the startup phase
        Task.detached(priority: .utility) {
            try? await Task.sleep(for: .seconds(4))
            await mcpRegistry.connectAll()
        }

        let appModelReference = AppModelReference()
        self.appModelReference = appModelReference

        if let stored = settings.get("ui.appearance")?.string,
           let appearance = Appearance(rawValue: stored) {
            self.appearance = appearance
        }
        if let stored = settings.get("ui.confirmBeforeExit")?.bool {
            self.confirmBeforeExit = stored
        }
        if let stored = settings.get("ui.closeToTray")?.bool {
            self.closeToTray = stored
        }
        if let stored = settings.get("agent.selfVerification")?.bool {
            self.selfVerification = stored
        }
        if let stored = settings.get("agent.seedProjectRules")?.bool {
            self.seedProjectRules = stored
        }
        if let stored = settings.get("agent.autoApprovePlans")?.bool {
            self.autoApprovePlans = stored
        }
        if let stored = settings.get("skills.suggestions.enabled")?.bool {
            self.skillSuggestionsEnabled = stored
            self.skillSuggestions.enabled = stored
        }
        self.workspaceConflictPolicy = settings.get("agent.workspaceConflictPolicy")?.string
            .flatMap(WorkspaceConflictPolicy.init(rawValue:)) ?? .waitThenAsk
        self.conflictWaitSeconds = settings.get("agent.conflictWaitSeconds")?.int
            ?? WorkspaceConflictPolicy.defaultWaitSeconds
        self.sandboxNetworkAccess = settings.get("agent.sandbox.networkAccess")?.bool ?? false
        let savedCleanupPending = settings.get("agent.sandbox.cleanupPending")?.bool ?? false
        let savedCleanupMerge = settings.get("agent.sandbox.cleanupMerge")?.bool ?? true
        let savedRecoveryRequired = settings.get("agent.sandbox.recoveryRequired")?.bool ?? false

        let storedWorkspace = settings.get("agent.workspace")?.string ?? ""
        let normalizedStoredWorkspace = ConversationStore.normalizedPath(storedWorkspace)
            .flatMap { $0 == "/" ? nil : $0 } ?? ""
        let projectIdentityPath = Self.canonicalExistingWorkspacePath(storedWorkspace) ?? normalizedStoredWorkspace
        // Keep a missing project's identity on relaunch so its existing
        // conversations can still be loaded and shown in read-only mode.
        var initialWorkspace = projectIdentityPath
        var restoredSandbox: SandboxWorkspace?
        var restoreNotice: String?
        if let storedOrigin = settings.get("agent.sandbox.origin")?.string,
           let origin = Self.validWorkspacePath(storedOrigin) {
            let savedPath = settings.get("agent.sandbox.path")?.string ?? initialWorkspace
            let savedName = settings.get("agent.sandbox.name")?.string
            let savedBranch = settings.get("agent.sandbox.originBranch")?.string
            if !savedPath.isEmpty {
                do {
                    let sandbox = try SandboxWorkspaces.restore(
                        origin: origin,
                        path: savedPath,
                        name: savedName,
                        originBranch: savedBranch
                    )
                    restoredSandbox = sandbox
                    initialWorkspace = sandbox.path
                } catch {
                    initialWorkspace = origin
                    restoreNotice = "A saved sandbox needs recovery: \(error.localizedDescription)"
                }
            } else {
                initialWorkspace = origin
                restoreNotice = "A saved sandbox needs recovery because its worktree path is missing."
            }
        } else if settings.get("agent.sandbox.origin")?.string != nil {
            initialWorkspace = ""
            restoreNotice = "A saved sandbox needs recovery because its origin workspace is unavailable."
        }
        var restoredConflict: SandboxConflict?
        if let sandbox = restoredSandbox,
           let originHead = settings.get("agent.sandbox.conflict.originHead")?.string,
           let sandboxHead = settings.get("agent.sandbox.conflict.sandboxHead")?.string,
           !originHead.isEmpty,
           !sandboxHead.isEmpty,
           let files = settings.get("agent.sandbox.conflict.files")?.array?.compactMap(\.string),
           !files.isEmpty {
            restoredConflict = SandboxConflict(
                sandbox: sandbox,
                originBranch: settings.get("agent.sandbox.conflict.originBranch")?.string ?? sandbox.originBranch,
                originHead: originHead,
                sandboxHead: sandboxHead,
                files: files
            )
        }
        self.workspacePath = initialWorkspace

        var storedProjects = (settings.get("agent.projects")?.array?.compactMap(\.string))
            .flatMap { $0.isEmpty ? nil : $0 } ?? []
        if storedProjects.isEmpty, !projectIdentityPath.isEmpty {
            // Migrate the single legacy workspace into the new project list.
            storedProjects = [projectIdentityPath]
        } else if !projectIdentityPath.isEmpty, !storedProjects.contains(projectIdentityPath) {
            storedProjects.insert(projectIdentityPath, at: 0)
        }
        self.projectPaths = storedProjects
        // The old area settings are deliberately ignored. A fresh launch is
        // always the project flow, including the empty "add a project" state.
        if let storedMetadata = settings.get("agent.projectMetadata")?.object {
            self.projectMetadata = storedMetadata.compactMapValues { value in
                guard let object = value.object else { return nil }
                return ProjectMetadata(
                    title: object["title"]?.string ?? "",
                    pinned: object["pinned"]?.bool ?? false,
                    section: object["section"]?.string,
                    searchFolders: object["searchFolders"]?.array?.compactMap(\.string) ?? [],
                    worktreeOrigin: object["worktreeOrigin"]?.string
                )
            }
        }
        if let storedSections = settings.get("agent.projectSections")?.array {
            self.projectSections = storedSections.compactMap(\.string)
        }
        if let storedLayout = settings.get("agent.sidebarLayoutMode")?.string,
           let mode = SidebarLayoutMode(rawValue: storedLayout) {
            self.sidebarLayoutMode = mode
        }
        if let storedSortOrders = settings.get("agent.projectSortOrders")?.object {
            self.projectSortOrders = storedSortOrders.compactMapValues { value in
                value.string.flatMap(ConversationSortOrder.init(rawValue:))
            }
        }
        if let storedManualOrder = settings.get("agent.projectManualOrder")?.object {
            self.projectManualOrder = storedManualOrder.compactMapValues { value in
                value.array?.compactMap(\.string)
            }
        }
        if let storedExpandedProjects = settings.get("agent.sidebarExpandedProjects")?.array {
            self.expandedProjectPaths = Set(storedExpandedProjects.compactMap(\.string))
        } else if !initialWorkspace.isEmpty {
            // First launch after sublists became restorable: keep the previous
            // behavior of showing the active project's chats.
            self.expandedProjectPaths = [initialWorkspace]
        }

        self.activeSandbox = restoredSandbox
        self.sandboxAgentWritableRoots = restoredSandbox.flatMap { try? SandboxWorkspaces.agentWritableRoots(for: $0) } ?? []
        self.sandboxRecoveryRequired = savedRecoveryRequired || (restoredSandbox == nil && restoreNotice != nil)
        self.sandboxNotice = restoreNotice ?? (savedRecoveryRequired ? "Sandbox recovery is required before agent execution." : nil)
        self.sandboxConflict = restoredConflict
        self.sandboxCleanupPending = restoredSandbox != nil && savedCleanupPending
        self.sandboxCleanupMerge = savedCleanupMerge
        // Skill discovery creates the workspace's .dotsherness/skills folder.
        // Do not hand it a stale saved path: that would recreate a project the
        // user moved or removed while restoring it into read-only mode.
        let availableInitialWorkspace = Self.validWorkspacePath(initialWorkspace)
        skills.setWorkspace(availableInitialWorkspace)
        skillSuggestions.setWorkspace(availableInitialWorkspace)
        let remoteEvents = RemoteEventHub(root: paths.root)
        self.remoteEvents = remoteEvents
        self.remoteControl = RemoteControlHost(
            bridge: bridge,
            paths: paths,
            events: remoteEvents,
            workspacePath: restoreNotice == nil ? initialWorkspace : ""
        )
        self.remoteControlEnabled = remoteControl.isEnabled
        self.remoteControlSharesWithLAN = remoteControl.sharesWithLAN
        self.remoteControl.setProjectsProvider { [weak self] in
                guard let self else { return [] }
                var result: [RemoteProjectDescriptor] = []
                for path in self.projectPaths where FileManager.default.fileExists(atPath: path) {
                    result.append(RemoteProjectDescriptor(
                        id: RemoteControlHost.workspaceIDForProject(path),
                        name: URL(fileURLWithPath: path).lastPathComponent,
                        workspaceId: RemoteControlHost.workspaceIDForProject(path),
                        workspacePath: path
                    ))
                }
                return result
        }

        bridge.setSelfVerification(selfVerification)
        // Set before the workspace binds below, so a disabled setting never seeds.
        bridge.setSeedProjectRules(seedProjectRules)
        bridge.setAutoApprovePlans(autoApprovePlans)
        bridge.setWorkspaceConflictPolicy(workspaceConflictPolicy)
        bridge.setConflictWaitSeconds(conflictWaitSeconds)
        // The bridges are @Observable: views read them per property, so their changes no
        // longer need to be forwarded (and no longer redraw the whole window).
        endpoint.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        host.provideService("appModel", appModelReference)
        host.provideService("catalog", catalog)
        host.provideService("skills", skills)
        appModelReference.model = self
        bridge.onSelectedConversationChanged = { [weak self] conversationID in
            self?.applyConversationModelSelection(conversationID)
        }
        host.provideService("vision.installer", VisionMarketplaceInstaller(model: self))
        registerHostDataTopics()
        migrateVoiceAPIKey(legacy: legacyVoiceAPIKey)
        if migratedFableSetting { persistSettings() }
        let assistantResponse: (AssistantResponseEvent) -> Void = { [weak self] event in
            self?.receiveAssistantResponse(event)
        }
        bridge.onAssistantResponse = assistantResponse
        bridge.onRunSummary = { [weak self] event in
            self?.receiveRunSummary(event)
            self?.scanSkillSuggestions()
        }
        // Only chats the user cannot see right now: the visible one shows its own card.
        let attentionNeeded: (RunAttentionEvent) -> Void = { [weak self] event in
            self?.receiveAttention(event)
        }
        bridge.onAttentionNeeded = attentionNeeded
        bridge.onPlanAutoApproved = { [weak self] in self?.endPlanMode() }
        let connectionChanged: (ConnectionTransition) -> Void = { [weak self, weak remoteControl] transition in
            self?.desktopNotifications.showConnectionChange(transition)
            remoteControl?.publish("connection.changed", [
                "action": .string(transition.action),
                "previousConnectionLabel": transition.previousConnectionLabel.map(RemoteJSONValue.string) ?? .null,
                "currentConnectionLabel": transition.currentConnectionLabel.map(RemoteJSONValue.string) ?? .null,
                "cleanupStatus": .string(transition.cleanupStatus),
                "removedLocalArtifacts": .array(transition.removedLocalArtifacts.map(RemoteJSONValue.string)),
                "remoteDataTouched": .bool(transition.remoteDataTouched),
                "userDataPreserved": .bool(transition.userDataPreserved),
            ])
        }
        router.onConnectionChanged = connectionChanged
        bridge.onRemoteEvent = { [weak remoteControl] (kind: String, payload: [String: String]) in
            var payload = payload
            payload["scope"] = "project"
            remoteControl?.publish(kind, payload.reduce(into: [String: RemoteJSONValue]()) { result, item in
                result[item.key] = .string(item.value)
            })
        }
        let pluginsChanged: () -> Void = { [weak self] in
            self?.remount()
        }
        bridge.onPluginsChanged = pluginsChanged
    }

    private static func parseResponseStylePreference(_ value: String?) -> AgentResponseStylePreference {
        guard let value else { return .ultra }
        if value == "standard" { return .balanced }
        return AgentResponseStylePreference(rawValue: value) ?? .balanced
    }

    private var cancellables = Set<AnyCancellable>()
    var deferredVoiceKeyLoad = false
    var hasStarted = false
    var hasPreparedFirstFrame = false
    var hasBootstrapped = false
    // ponytail: keep unsent drafts in memory; persist only if restart recovery is required.
    var draftsByConversation: [String: String] = [:]
    var draftAttachmentsByConversation: [String: [ChatAttachment]] = [:]
    var draftBeforeEditing: String?
    var attachmentsBeforeEditing: [ChatAttachment]?
    var availableSandboxesRefreshTask: Task<Void, Never>?
    private let appModelReference: AppModelReference
    var isVoiceDownloadPromptShowing = false
    enum VoiceDownloadStopReason {
        case pause
        case cancel
    }
    var voiceDownloadTask: Task<Void, Never>?
    var voiceDownloadStopReason: VoiceDownloadStopReason?
    var voiceDownloadHadRuntime = false
    var speechTask: Task<Void, Never>?
    var speechRequestID: UUID?

    func draftKey(for conversationID: String) -> String {
        "project:\(conversationID)"
    }

    var hasStartedBridge = false

    /// Everything actually sent as the system prompt - core policy, plan rules,
    /// plugin text and skill metadata - broken out by section with sizes.
    public func effectiveSystemPrompt() -> String {
        bridge.effectiveSystemPromptReport()
    }

    static func validWorkspacePath(_ value: String) -> String? {
        guard let normalized = ConversationStore.normalizedPath(value), normalized != "/" else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: normalized, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        return normalized
    }

    static func canonicalExistingWorkspacePath(_ value: String) -> String? {
        guard let validPath = validWorkspacePath(value) else { return nil }
        return SandboxProfile.canonicalURL(
            URL(fileURLWithPath: validPath, isDirectory: true)
        ).path
    }

    private static func loadSettings(from url: URL) -> InMemorySettingsRegistry {
        if let data = try? Data(contentsOf: url),
           let values = try? JSONDecoder().decode([String: JSONValue].self, from: data) {
            return InMemorySettingsRegistry(values: values)
        }
        return InMemorySettingsRegistry()
    }

    private static func loadKeyboardShortcuts(
        from settings: InMemorySettingsRegistry
    ) -> [KeyboardShortcutAction: UserKeyboardShortcut] {
        let defaults = Dictionary(
            uniqueKeysWithValues: KeyboardShortcutAction.allCases.map { ($0, $0.defaultShortcut) }
        )
        var loaded = defaults
        var used = Set(defaults.values)

        for action in KeyboardShortcutAction.allCases {
            used.remove(action.defaultShortcut)
            if let stored = settings.get(action.settingsKey)?.string,
               let candidate = UserKeyboardShortcut(storedValue: stored),
               !used.contains(candidate) {
                loaded[action] = candidate
            }
            used.insert(loaded[action] ?? action.defaultShortcut)
        }
        return loaded
    }

    /// Where the composer says this task runs. `.remote` sends every command
    /// to another machine over SSH; the two local cases keep today's behaviour.
    @Published public internal(set) var workLocation: WorkLocationSetting = .local
    /// The host and folder in use while `workLocation` is remote.
    @Published public internal(set) var remoteWorkspace: SSHTarget?
    /// Mirrors `sshStore.hosts` so views observing AppModel refresh with it.
    @Published public internal(set) var sshHosts: [SSHHost] = []
    @Published public var sshNotice: String?
    public let sshStore = SSHHostStore()
    public var isRemoteWorkLocation: Bool { workLocation.isRemote }
    /// `git commit`/`add` inside the sandbox worktree write to this worktree's
    /// `.git/worktrees/<name>` metadata and to the origin's shared
    /// `.git/objects` — both outside the worktree itself. Recomputed whenever
    /// `activeSandbox` changes (see `refreshSandboxWritableRoots`) rather than
    /// on every access, since it shells out to git.
    var sandboxAgentWritableRoots: [URL] = []
    lazy var pluginInstaller = PluginInstaller(catalog: catalog)
    /// Git membership used by project menus. Repository checks run off the main actor.
    @Published public internal(set) var gitProjectCache: [String: Bool] = [:]
    var gitProjectStatusInFlight: Set<String> = []
    /// Gate for sending workspace/conversation content to an AI provider.
    public var aiTransferAllowed: Bool { legal.aiTransferAllowed }
    /// When set, SettingsView selects this tab on next appearance, then clears it.
    @Published public var settingsInitialTab: String?
    /// Freeform goal for the current session, injected into the agent system
    /// prompt. Empty means "no goal set".
    @Published public internal(set) var sessionGoal: String = ""
    var sessionGoalRetract: (() -> Void)?
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
        // Every catalog entry (builtin + installed) mounts by default. host.patch.yml is
        // only an override layer: ordering, config merge, explicit disable/enable.
        // An entry's `isolate: {service: true}` keeps those services private to that
        // row (PluginHost.mount gives it a child ServiceRealm) on this host plane too.
        for item in catalog.entries.sorted(by: { $0.manifest.id < $1.manifest.id }) {
            guard !entries.contains(where: { $0.plugin == item.manifest.id }) else { continue }
            entries.append(CompositionEntry(id: item.manifest.id, plugin: item.manifest.id))
        }
        for index in entries.indices {
            if let item = catalog.entries.first(where: { $0.manifest.id == entries[index].plugin }) {
                if !item.enabled { entries[index].disabled = true }
            }
        }
        document.entries = entries
        return document
    }
}

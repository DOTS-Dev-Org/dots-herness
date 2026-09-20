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

public enum AssistantMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case coding
    case chat

    public var id: String { rawValue }

    public var systemImage: String {
        switch self {
        case .coding: return "chevron.left.forwardslash.chevron.right"
        case .chat: return "bubble.left.and.bubble.right"
        }
    }

    public var title: String { AppCopy.text("assistantMode.\(rawValue)") }

    public var guidance: String {
        switch self {
        case .coding:
            return "Coding-first mode is active. For coding requests, inspect, edit, and verify the workspace proactively. You can still answer general questions and have normal conversation when asked."
        case .chat:
            return "Chat-first mode is active. Be conversational and answer questions directly. Do not inspect or modify the workspace unless the user explicitly asks for coding or the request clearly requires it. If coding is requested, do it normally with the existing safety and verification rules."
        }
    }
}

@MainActor
public final class AppModelReference {
    public weak var model: AppModel?

    public init(model: AppModel? = nil) {
        self.model = model
    }
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
    public let skillSuggestions: SkillSuggestionMonitor
    public let host: PluginHost
    public let paths: SupportPaths
    public let chatBridge: AgentBridge
    public let codingBridge: AgentBridge
    public let mcpRegistry: MCPRegistry
    public let chatRouter: RouterController
    public let codingRouter: RouterController
    public let chatEndpoint: AgentEndpointController
    public let codingEndpoint: AgentEndpointController
    public let remoteEvents: RemoteEventHub
    public let remoteControl: RemoteControlHost
    public let terminalManager: TerminalManager
    public let navigationState: SidebarVisibilityState
    let chatProjectStore: ChatProjectStore
    let desktopNotifications: DesktopNotificationService
    public lazy var marketplaceSession = MarketplaceSession()
    public lazy var marketplace: MarketplaceClient = {
        let raw = host.settings.get("marketplace.indexURL")?.string ?? MarketplaceClient.defaultIndex
        let url = URL(string: raw) ?? URL(string: MarketplaceClient.defaultIndex)!
        return MarketplaceClient(indexURL: url, catalog: catalog, session: marketplaceSession)
    }()
    public lazy var local: LocalRuntimeController = LocalRuntimeController(paths: paths, router: codingRouter)
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

    @Published public var draft: String = "" {
        didSet {
            if oldValue.isEmpty, !draft.isEmpty { warmProviderModels() }
            guard editingMessageID == nil, let id = bridge.selectedID else { return }
            draftsByConversation[draftKey(for: id)] = draft
        }
    }

    /// The first send waits for every provider's model listing. Starting it when the
    /// user begins typing (not at launch: it reads credentials) hides that round trip
    /// behind the time it takes to write the message. Idempotent; sends join it.
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
    @Published public var appearance: Appearance = .system
    @Published public var appLanguage: AppLanguage = .system
    @Published public internal(set) var permissionMode: AgentPermissionMode
    @Published public internal(set) var browserBackend: BrowserBackend?
    @Published public internal(set) var fullAccessWarningDismissed: Bool
    @Published public var confirmBeforeExit = true
    /// Agent runs its own build/test/check after each change. Default on.
    @Published public var selfVerification = true
    /// Seed AGENTS.md and CLAUDE.md into a workspace that ships neither. Default on.
    @Published public var seedProjectRules = true
    @Published public internal(set) var workspacePath: String
    /// User-editable shortcuts used by both the menu bar and in-app action rows.
    @Published public internal(set) var keyboardShortcuts: [KeyboardShortcutAction: UserKeyboardShortcut] =
        Dictionary(uniqueKeysWithValues: KeyboardShortcutAction.allCases.map { ($0, $0.defaultShortcut) })
    /// Every project the user has added to the sidebar, most-recent first.
    /// `workspacePath` is always the active entry (or empty if none added yet).
    @Published public internal(set) var projectPaths: [String] = []
    /// Session-only state for the unsectioned project group in the sidebar.
    /// Deliberately not persisted: a new app session starts with the compact
    /// five-project view again.
    @Published public internal(set) var showsAllOtherProjects = false
    @Published public internal(set) var projectMetadata: [String: ProjectMetadata] = [:]
    @Published public internal(set) var projectSections: [String] = []
    @Published public internal(set) var sidebarLayoutMode: SidebarLayoutMode = .groupedByProject
    /// Conversation sort order per project path. Missing entries default to `.lastUpdate`.
    @Published public internal(set) var projectSortOrders: [String: ConversationSortOrder] = [:]
    /// Manual conversation order per project path, used when that project's sort order is `.manual`.
    @Published public internal(set) var projectManualOrder: [String: [String]] = [:]
    @Published public internal(set) var chatProjects: [ChatProject] = []
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
    /// Sidebar "Usage" dropdown expanded state. In-memory only.
    @Published public var isUsageExpanded = false
    @Published public var isTasksPresented = false
    @Published public var isSimulatorPresented = false
    @Published public var isPlanMode = false
    @Published public internal(set) var assistantMode: AssistantMode = .coding
    @Published public internal(set) var activeArea: AgentArea = .coding
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

    public var bridge: AgentBridge {
        if activeArea == .chat {
            startChatBridgeIfNeeded()
            return chatBridge
        } else {
            startCodingBridgeIfNeeded()
            return codingBridge
        }
    }
    public var activeSkills: SkillCatalog { bridge.skills }
    public var activeSkillSuggestions: SkillSuggestionMonitor {
        bridge.skillSuggestions ?? skillSuggestions
    }
    public var router: RouterController { activeArea == .chat ? chatRouter : codingRouter }
    public var endpoint: AgentEndpointController { activeArea == .chat ? chatEndpoint : codingEndpoint }
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
                setActiveArea(.chat)
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
    public var canSend: Bool {
        bridge.isReady
            && !bridge.historyMutationBusy
            && !sandboxCleanupPending
            && !sandboxRecoveryRequired
            && (activeSandbox == nil || sandboxExecutionPolicy != nil)
            && (!workLocation.isRemote || remoteWorkspace != nil)
    }

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
        self.navigationState = SidebarVisibilityState()
        self.desktopNotifications = DesktopNotificationService()
        let chatProjectStore = ChatProjectStore(paths: paths)
        self.chatProjectStore = chatProjectStore
        self.chatProjects = chatProjectStore.load()
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
        let storedAssistantMode = settings.get("ui.assistantMode")?.string
            .flatMap(AssistantMode.init(rawValue:))
        let storedArea = settings.get("ui.activeArea")?.string
            .flatMap(AgentArea.init(rawValue:))
        self.permissionMode = storedPermissionMode
        self.browserBackend = storedBrowserBackend
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
        let chatRouter = RouterController(paths: paths, imageAdapters: host.imageAdapters, providerStore: providerStore)
        chatRouter.selectedModelID = settings.get("agent.model.chat")?.string ?? legacyModel
        chatRouter.selectedEffort = settings.get("agent.effort.chat")?.string ?? legacyEffort
        chatRouter.fastMode = settings.get("agent.fast.chat")?.bool ?? false
        let codingRouter = RouterController(paths: paths, imageAdapters: host.imageAdapters, providerStore: providerStore)
        codingRouter.selectedModelID = settings.get("agent.model.coding")?.string ?? legacyModel
        codingRouter.selectedEffort = settings.get("agent.effort.coding")?.string ?? legacyEffort
        codingRouter.fastMode = settings.get("agent.fast.coding")?.bool ?? false
        self.chatRouter = chatRouter
        self.codingRouter = codingRouter

        let chatEndpoint = AgentEndpointController(
            baseURL: "",
            modelID: settings.get("agent.model.chat")?.string ?? legacyModel,
            apiKey: ""
        )
        let codingEndpoint = AgentEndpointController(
            baseURL: "",
            modelID: settings.get("agent.model.coding")?.string ?? legacyModel,
            apiKey: ""
        )
        self.chatEndpoint = chatEndpoint
        self.codingEndpoint = codingEndpoint
        let chatBridge = AgentBridge(
            paths: paths,
            endpoint: chatEndpoint,
            router: chatRouter,
            skills: skills,
            permissionMode: storedPermissionMode,
            pluginHost: host,
            skillSuggestions: skillSuggestions,
            area: .chat,
            sessionFileName: AgentArea.chat.sessionFileName,
            chatContextStore: ChatContextStore(paths: paths)
        )
        let codingBridge = AgentBridge(
            paths: paths,
            endpoint: codingEndpoint,
            router: codingRouter,
            skills: skills,
            permissionMode: storedPermissionMode,
            pluginHost: host,
            skillSuggestions: skillSuggestions,
            area: .coding,
            sessionFileName: AgentArea.coding.sessionFileName
        )
        self.chatBridge = chatBridge
        self.codingBridge = codingBridge
        chatBridge.setBrowserBackend(storedBrowserBackend)
        codingBridge.setBrowserBackend(storedBrowserBackend)
        let mcpRegistry = MCPRegistry(paths: paths)
        self.mcpRegistry = mcpRegistry
        self.chatBridge.mcpRegistry = mcpRegistry
        self.codingBridge.mcpRegistry = mcpRegistry
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
        if let stored = settings.get("agent.selfVerification")?.bool {
            self.selfVerification = stored
        }
        if let stored = settings.get("agent.seedProjectRules")?.bool {
            self.seedProjectRules = stored
        }
        self.sandboxNetworkAccess = settings.get("agent.sandbox.networkAccess")?.bool ?? false
        let savedCleanupPending = settings.get("agent.sandbox.cleanupPending")?.bool ?? false
        let savedCleanupMerge = settings.get("agent.sandbox.cleanupMerge")?.bool ?? true
        let savedRecoveryRequired = settings.get("agent.sandbox.recoveryRequired")?.bool ?? false

        let storedWorkspace = settings.get("agent.workspace")?.string ?? ""
        var initialWorkspace = Self.validWorkspacePath(storedWorkspace) ?? ""
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

        let projectIdentityPath = Self.validWorkspacePath(storedWorkspace) ?? ""
        var storedProjects = (settings.get("agent.projects")?.array?.compactMap(\.string))
            .flatMap { $0.isEmpty ? nil : $0 } ?? []
        if storedProjects.isEmpty, !projectIdentityPath.isEmpty {
            // Migrate the single legacy workspace into the new project list.
            storedProjects = [projectIdentityPath]
        } else if !projectIdentityPath.isEmpty, !storedProjects.contains(projectIdentityPath) {
            storedProjects.insert(projectIdentityPath, at: 0)
        }
        self.projectPaths = storedProjects
        // An explicitly saved area is authoritative. Coding can be a useful
        // empty state while a project is being chosen, so do not silently
        // switch the user back to Chat just because the workspace is missing
        // or was removed between launches.
        let initialArea = storedArea
            ?? storedAssistantMode.map { $0 == .chat ? AgentArea.chat : .coding }
            ?? (storedProjects.isEmpty ? .chat : .coding)
        self.activeArea = initialArea
        self.assistantMode = initialArea == .chat ? .chat : .coding
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

        self.activeSandbox = restoredSandbox
        self.sandboxAgentWritableRoots = restoredSandbox.flatMap { try? SandboxWorkspaces.agentWritableRoots(for: $0) } ?? []
        self.sandboxRecoveryRequired = savedRecoveryRequired || (restoredSandbox == nil && restoreNotice != nil)
        self.sandboxNotice = restoreNotice ?? (savedRecoveryRequired ? "Sandbox recovery is required before agent execution." : nil)
        self.sandboxConflict = restoredConflict
        self.sandboxCleanupPending = restoredSandbox != nil && savedCleanupPending
        self.sandboxCleanupMerge = savedCleanupMerge
        skills.setWorkspace(initialWorkspace.isEmpty ? nil : initialWorkspace)
        skillSuggestions.setWorkspace(initialWorkspace.isEmpty ? nil : initialWorkspace)
        let remoteEvents = RemoteEventHub(root: paths.root)
        self.remoteEvents = remoteEvents
        self.remoteControl = RemoteControlHost(
            bridge: codingBridge,
            paths: paths,
            events: remoteEvents,
            workspacePath: restoreNotice == nil ? initialWorkspace : ""
        )

        chatBridge.setSelfVerification(selfVerification)
        codingBridge.setSelfVerification(selfVerification)
        // Set before the workspace binds below, so a disabled setting never seeds.
        chatBridge.setSeedProjectRules(seedProjectRules)
        codingBridge.setSeedProjectRules(seedProjectRules)
        // The bridges are @Observable: views read them per property, so their changes no
        // longer need to be forwarded (and no longer redraw the whole window).
        chatEndpoint.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        codingEndpoint.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        host.provideService("appModel", appModelReference)
        host.provideService("catalog", catalog)
        host.provideService("skills", skills)
        appModelReference.model = self
        host.provideService("vision.installer", VisionMarketplaceInstaller(model: self))
        registerHostDataTopics()
        migrateVoiceAPIKey(legacy: legacyVoiceAPIKey)
        if migratedFableSetting { persistSettings() }
        let assistantResponse: (AssistantResponseEvent) -> Void = { [weak self] event in
            self?.desktopNotifications.showAssistantResponse(event)
        }
        chatBridge.onAssistantResponse = assistantResponse
        codingBridge.onAssistantResponse = assistantResponse
        chatBridge.onRunSummary = { [weak self] event in
            self?.desktopNotifications.showRunSummary(event)
            if self?.activeArea == .chat { self?.scanSkillSuggestions() }
        }
        codingBridge.onRunSummary = { [weak self] event in
            self?.desktopNotifications.showRunSummary(event)
            if self?.activeArea == .coding { self?.scanSkillSuggestions() }
        }
        // Only chats the user cannot see right now: the visible one shows its own card.
        let attentionNeeded: (RunAttentionEvent) -> Void = { [weak self] event in
            guard let self else { return }
            let visible = NSApplication.shared.isActive && self.bridge.selectedID == event.conversationID
            if !visible { self.desktopNotifications.showAttention(event) }
        }
        chatBridge.onAttentionNeeded = attentionNeeded
        codingBridge.onAttentionNeeded = attentionNeeded
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
        chatRouter.onConnectionChanged = connectionChanged
        codingRouter.onConnectionChanged = connectionChanged
        chatBridge.onRemoteEvent = { [weak remoteControl] (kind: String, payload: [String: String]) in
            var payload = payload
            payload["area"] = AgentArea.chat.rawValue
            remoteControl?.publish(kind, payload.reduce(into: [String: RemoteJSONValue]()) { result, item in
                result[item.key] = .string(item.value)
            })
        }
        codingBridge.onRemoteEvent = { [weak remoteControl] (kind: String, payload: [String: String]) in
            var payload = payload
            payload["area"] = AgentArea.coding.rawValue
            remoteControl?.publish(kind, payload.reduce(into: [String: RemoteJSONValue]()) { result, item in
                result[item.key] = .string(item.value)
            })
        }
        let pluginsChanged: () -> Void = { [weak self] in
            self?.remount()
        }
        chatBridge.onPluginsChanged = pluginsChanged
        codingBridge.onPluginsChanged = pluginsChanged
    }

    private var cancellables = Set<AnyCancellable>()
    var deferredVoiceKeyLoad = false
    var hasStarted = false
    var hasPreparedFirstFrame = false
    var hasBootstrapped = false
    private var activeOptionalPluginIDs = Set<String>()
    // ponytail: keep unsent drafts in memory; persist only if restart recovery is required.
    var draftsByConversation: [String: String] = [:]
    var draftAttachmentsByConversation: [String: [ChatAttachment]] = [:]
    var planModeByArea: [AgentArea: Bool] = [:]
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
        "\(activeArea.rawValue):\(conversationID)"
    }

    var hasStartedChatBridge = false
    var hasStartedCodingBridge = false

    /// Only the plugin/session prompt sections. The scheduler feeds this back
    /// into `updateSystemPrompt`, so it must stay the additional text alone.
    public func assembledSystemPrompt() -> String {
        host.prompt.assembledText()
    }

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
    var gitProjectCache: [String: Bool] = [:]
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
        // ponytail: an entry's `isolate:` key is INERT here. PluginHost only honors it
        // on a `plane: session` document (PluginHost.mount), and this path always builds
        // a `.host` document, so `isolate` in host.patch.yml parses but does nothing.
        // Upgrade path: give each conversation its own `plane: session` PluginHost and
        // move the isolate-eligible entries there.
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

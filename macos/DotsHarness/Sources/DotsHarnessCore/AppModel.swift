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
    private static let voiceCredentialID = "voice.api.key"

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
    private let chatProjectStore: ChatProjectStore
    private let desktopNotifications: DesktopNotificationService
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
    private var createdSpeech: LocalSpeechSynthesizer?
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
    @Published public private(set) var draftAttachments: [ChatAttachment] = [] {
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
    @Published public private(set) var permissionMode: AgentPermissionMode
    @Published public private(set) var browserBackend: BrowserBackend?
    @Published public private(set) var fullAccessWarningDismissed: Bool
    @Published public var confirmBeforeExit = true
    /// Agent runs its own build/test/check after each change. Default on.
    @Published public var selfVerification = true
    /// Seed AGENTS.md and CLAUDE.md into a workspace that ships neither. Default on.
    @Published public var seedProjectRules = true
    @Published public private(set) var workspacePath: String
    /// User-editable shortcuts used by both the menu bar and in-app action rows.
    @Published public private(set) var keyboardShortcuts: [KeyboardShortcutAction: UserKeyboardShortcut] =
        Dictionary(uniqueKeysWithValues: KeyboardShortcutAction.allCases.map { ($0, $0.defaultShortcut) })
    /// Every project the user has added to the sidebar, most-recent first.
    /// `workspacePath` is always the active entry (or empty if none added yet).
    @Published public private(set) var projectPaths: [String] = []
    /// Session-only state for the unsectioned project group in the sidebar.
    /// Deliberately not persisted: a new app session starts with the compact
    /// five-project view again.
    @Published public private(set) var showsAllOtherProjects = false
    @Published public private(set) var projectMetadata: [String: ProjectMetadata] = [:]
    @Published public private(set) var projectSections: [String] = []
    @Published public private(set) var sidebarLayoutMode: SidebarLayoutMode = .groupedByProject
    /// Conversation sort order per project path. Missing entries default to `.lastUpdate`.
    @Published public private(set) var projectSortOrders: [String: ConversationSortOrder] = [:]
    /// Manual conversation order per project path, used when that project's sort order is `.manual`.
    @Published public private(set) var projectManualOrder: [String: [String]] = [:]
    @Published public private(set) var chatProjects: [ChatProject] = []
    /// Non-nil while the agent is working in a sandbox worktree instead of the
    /// user's own checkout. `workspacePath` then points at the worktree.
    @Published public private(set) var activeSandbox: SandboxWorkspace?
    /// Worktrees available for recovery. Git discovery is refreshed off the
    /// main actor so SwiftUI never runs a synchronous Process while laying out
    /// the Settings screen.
    @Published public private(set) var availableSandboxes: [SandboxWorkspace] = []
    /// Set by `enterSandbox`/`exitSandbox` for the UI to show; not an error.
    @Published public var sandboxNotice: String?
    /// Off by default: sandbox's main job is running code you don't fully
    /// trust yet, and file isolation alone doesn't stop that code from
    /// sending what it can read (workspace contents) to a remote host. Turn
    /// it on per-sandbox when a build genuinely needs the network.
    @Published public var sandboxNetworkAccess = false
    @Published public private(set) var sandboxConflict: SandboxConflict?
    @Published public private(set) var sandboxResolutionPreview: SandboxResolutionPreview?
    @Published public private(set) var sandboxResolutionBusy = false
    @Published public private(set) var sandboxCleanupPending = false
    @Published public private(set) var sandboxRecoveryRequired = false
    private var sandboxCleanupMerge = true
    @Published public var isPetVisible = false
    /// ponytail: login backend will call `setAccountIdentity(_:)` to replace this.
    @Published public private(set) var account: AccountIdentity = .signedOut()
    @Published public var isSettingsPresented = false
    @Published public var feedbackRequest: FeedbackTarget? = nil
    @Published public var isUsagePresented = false
    /// Sidebar "Usage" dropdown expanded state. In-memory only.
    @Published public var isUsageExpanded = false
    @Published public var isTasksPresented = false
    @Published public var isSimulatorPresented = false
    @Published public var isPlanMode = false
    @Published public private(set) var assistantMode: AssistantMode = .coding
    @Published public private(set) var activeArea: AgentArea = .coding
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
    @Published public private(set) var visionModelProgress: Double = 0

    /// Live-fetched legal documents and their acceptance state. See LegalConsent.swift.
    @Published public private(set) var legalDocuments: LegalDocuments?
    @Published public private(set) var legalNeedsAcceptance = false
    @Published public private(set) var legalLoadFailed = false
    public private(set) lazy var legal = LegalService(settings: host.settings, cacheDirectory: paths.root)

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

    // MARK: - Remote work location

    /// Where the composer says this task runs. `.remote` sends every command
    /// to another machine over SSH; the two local cases keep today's behaviour.
    @Published public private(set) var workLocation: WorkLocationSetting = .local
    /// The host and folder in use while `workLocation` is remote.
    @Published public private(set) var remoteWorkspace: SSHTarget?
    /// Mirrors `sshStore.hosts` so views observing AppModel refresh with it.
    @Published public private(set) var sshHosts: [SSHHost] = []
    @Published public var sshNotice: String?
    public let sshStore = SSHHostStore()

    public var isRemoteWorkLocation: Bool { workLocation.isRemote }

    /// What the UI shows as the current working folder. A remote workspace has
    /// no local path, so it is named by host and folder instead.
    public var workspaceDisplayPath: String {
        if let remote = remoteWorkspace { return "\(remote.alias):\(remote.remotePath)" }
        return workspacePath
    }

    /// Terminal panes are keyed by this, so a remote folder never shares a
    /// session list with a local directory of the same path.
    public var terminalWorkspaceKey: String {
        if activeArea == .chat {
            return chatBridge.chatContextRoots.first(where: { $0.kind == .directory })?.path ?? ""
        }
        return remoteWorkspace?.identity ?? workspacePath
    }

    public var activeChatProjectName: String {
        guard activeArea == .chat,
              let projectID = chatBridge.selected?.chatProjectID,
              let project = chatProjects.first(where: { $0.id == projectID }) else {
            return AgentArea.chat.title
        }
        return project.name
    }

    public func refreshSSHHosts() {
        sshStore.reload()
        sshHosts = sshStore.hosts
        if let alias = workLocation.remoteAlias, sshStore.host(alias: alias) == nil {
            sshNotice = AppCopy.format("ssh.error.notReachable", alias)
            applyWorkLocation(.local)
        }
    }

    public func setWorkLocation(_ setting: WorkLocationSetting) {
        guard setting != workLocation else { return }
        if activeSandbox != nil, setting.isRemote {
            sandboxNotice = "Leave the active sandbox before working on a remote host."
            return
        }
        guard !codingBridge.anyRunBusy else {
            sshNotice = AppCopy.text("ssh.busy")
            return
        }
        guard let alias = setting.remoteAlias else {
            applyWorkLocation(setting)
            return
        }
        guard let host = sshStore.host(alias: alias) else {
            sshNotice = AppCopy.format("ssh.error.notReachable", alias)
            return
        }
        sshNotice = AppCopy.format("ssh.connecting", host.alias)
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await Task.detached(priority: .userInitiated) {
                SSHRunner.probe(alias: alias)
            }.value
            switch result {
            case .success:
                self.sshNotice = nil
                self.applyWorkLocation(setting)
                let remembered = self.sshStore.record(alias: alias).lastRemotePath
                if let remembered {
                    self.setRemoteWorkspace(path: remembered)
                } else {
                    self.remoteWorkspace = nil
                    self.codingBridge.setRemoteTarget(nil)
                }
            case .failure(let error):
                self.sshNotice = error.localizedDescription
            }
        }
    }

    private func applyWorkLocation(_ setting: WorkLocationSetting) {
        workLocation = setting
        if !setting.isRemote {
            if let previous = remoteWorkspace?.alias {
                SSHRunner.closeMaster(alias: previous)
            }
            remoteWorkspace = nil
            codingBridge.setRemoteTarget(nil)
            codingBridge.setSandboxPolicy(sandboxExecutionPolicy, branch: activeSandbox?.branch)
        }
        host.settings.set("agent.workLocation", .string(setting.storageValue))
        persistSettings()
    }

    /// Picks the folder on the remote host the agent works in. The path is
    /// resolved on that machine so `~` and symlinks settle before it is stored.
    public func setRemoteWorkspace(path: String) {
        guard let alias = workLocation.remoteAlias else { return }
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let resolved = await Task.detached(priority: .userInitiated) {
                SSHRunner.resolveDirectory(alias: alias, path: trimmed)
            }.value
            guard let resolved else {
                self.sshNotice = SSHError.pathMissing(trimmed).localizedDescription
                return
            }
            let target = SSHTarget(alias: alias, remotePath: resolved)
            self.remoteWorkspace = target
            self.codingBridge.setRemoteTarget(target)
            self.sshStore.rememberRemotePath(alias: alias, path: resolved)
            self.sshNotice = nil
        }
    }

    public func removeSSHHost(alias: String) {
        do {
            try sshStore.remove(alias: alias)
            if workLocation.remoteAlias == alias { applyWorkLocation(.local) }
            refreshSSHHosts()
        } catch {
            sshNotice = error.localizedDescription
        }
    }

    // MARK: - Adding a remote host

    /// Step 1: fetch the host's public keys so the user can check the
    /// fingerprint. Nothing is trusted and no password is asked for yet.
    public func scanSSHHostKey(hostName: String, port: Int) async -> Result<SSHEnrollment.HostKeyScan, Error> {
        await Task.detached(priority: .userInitiated) {
            do { return .success(try SSHEnrollment.scanHostKey(hostName: hostName, port: port)) }
            catch { return .failure(error) }
        }.value
    }

    /// Step 2, after the user confirmed the fingerprint: trust the key,
    /// install our public key using the password once, and write the stanza.
    ///
    /// The password is passed straight through to the one ssh call that needs
    /// it. It is stored only when `rememberPassword` is set, and then only in
    /// the Keychain — never in ~/.ssh/config, which cannot hold one anyway.
    public func enrollSSHHost(
        alias: String,
        user: String,
        hostName: String,
        port: Int,
        password: String,
        scan: SSHEnrollment.HostKeyScan,
        rememberPassword: Bool
    ) async -> Result<SSHHost, Error> {
        guard SSHConfigStore.isValidAlias(alias) else {
            return .failure(SSHError.configWriteFailed(alias))
        }
        let host = SSHHost(
            alias: alias,
            hostName: hostName,
            user: user,
            port: port,
            identityFile: SSHEnrollment.identityFileReference,
            managedByApp: true
        )
        let outcome = await Task.detached(priority: .userInitiated) { () -> Result<Void, Error> in
            do {
                try SSHEnrollment.trust(scan: scan)
                let publicKey = try SSHEnrollment.ensureKeyPair()
                try SSHEnrollment.installPublicKey(
                    user: user,
                    hostName: hostName,
                    port: port,
                    password: password,
                    publicKey: publicKey
                )
                return .success(())
            } catch {
                return .failure(error)
            }
        }.value
        if case .failure(let error) = outcome { return .failure(error) }

        do {
            try sshStore.add(host, enrolled: true)
        } catch {
            return .failure(error)
        }
        if rememberPassword {
            try? sshStore.storePassword(password, alias: alias)
        } else {
            sshStore.forgetPassword(alias: alias)
        }
        refreshSSHHosts()

        let probe = await Task.detached(priority: .userInitiated) { SSHRunner.probe(alias: alias) }.value
        if case .failure(let error) = probe { return .failure(error) }
        return .success(host)
    }

    /// Adds a host that already authenticates (an existing key, an agent) with
    /// no password step.
    public func addSSHHostWithoutPassword(
        alias: String,
        user: String,
        hostName: String,
        port: Int,
        scan: SSHEnrollment.HostKeyScan
    ) async -> Result<SSHHost, Error> {
        guard SSHConfigStore.isValidAlias(alias) else {
            return .failure(SSHError.configWriteFailed(alias))
        }
        let host = SSHHost(alias: alias, hostName: hostName, user: user, port: port, managedByApp: true)
        do {
            try await Task.detached(priority: .userInitiated) { try SSHEnrollment.trust(scan: scan) }.value
            try sshStore.add(host, enrolled: false)
        } catch {
            return .failure(error)
        }
        refreshSSHHosts()
        let probe = await Task.detached(priority: .userInitiated) { SSHRunner.probe(alias: alias) }.value
        if case .failure(let error) = probe { return .failure(error) }
        return .success(host)
    }

    /// Re-checks a host and reports the outcome in the Settings pane.
    public func testSSHHost(alias: String) {
        sshNotice = AppCopy.format("ssh.connecting", alias)
        Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .userInitiated) { SSHRunner.probe(alias: alias) }.value
            switch result {
            case .success:
                self?.sshNotice = AppCopy.format("ssh.reachable", alias)
            case .failure(let error):
                self?.sshNotice = error.localizedDescription
            }
        }
    }

    /// Lists sub-folders of `path` on a host, for the remote folder picker.
    public func remoteDirectories(alias: String, path: String) async -> [String] {
        await Task.detached(priority: .userInitiated) {
            SSHRunner.listDirectories(alias: alias, path: path)
        }.value
    }

    /// Restores the saved work location once the bridge is up.
    private func restoreWorkLocation() {
        refreshSSHHosts()
        let stored = WorkLocationSetting(storageValue: host.settings.get("agent.workLocation")?.string ?? "local")
        guard stored.isRemote else { return }
        setWorkLocation(stored)
    }
    /// `git commit`/`add` inside the sandbox worktree write to this worktree's
    /// `.git/worktrees/<name>` metadata and to the origin's shared
    /// `.git/objects` — both outside the worktree itself. Recomputed whenever
    /// `activeSandbox` changes (see `refreshSandboxWritableRoots`) rather than
    /// on every access, since it shells out to git.
    private var sandboxAgentWritableRoots: [URL] = []

    private func refreshSandboxWritableRoots() {
        sandboxAgentWritableRoots = activeSandbox.flatMap { try? SandboxWorkspaces.agentWritableRoots(for: $0) } ?? []
    }

    public var sandboxExecutionPolicy: SandboxExecutionPolicy? {
        guard let sandbox = activeSandbox,
              SandboxProfile.canonicalURL(URL(fileURLWithPath: workspacePath, isDirectory: true)).path == sandbox.path else {
            return nil
        }
        return SandboxExecutionPolicy(
            workspaceURL: URL(fileURLWithPath: sandbox.path, isDirectory: true),
            networkAccess: sandboxNetworkAccess,
            additionalWritableRoots: sandboxAgentWritableRoots
        )
    }

    /// Chat terminals must be rooted in a directory the user explicitly
    /// supplied in a Chat message. They must never inherit the Coding
    /// workspace's sandbox or the app process' current directory.
    public var chatTerminalExecutionPolicy: SandboxExecutionPolicy? {
        guard activeArea == .chat,
              let root = chatBridge.chatContextRoots.first(where: { $0.kind == .directory }) else {
            return nil
        }
        let rootURL = URL(fileURLWithPath: root.path, isDirectory: true)
        return SandboxExecutionPolicy(
            workspaceURL: rootURL,
            networkAccess: true
        )
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
        chatBridge.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
        codingBridge.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
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
    private var deferredVoiceKeyLoad = false
    private var hasStarted = false
    private var hasPreparedFirstFrame = false
    private var hasBootstrapped = false
    private var activeOptionalPluginIDs = Set<String>()
    // ponytail: keep unsent drafts in memory; persist only if restart recovery is required.
    private var draftsByConversation: [String: String] = [:]
    private var draftAttachmentsByConversation: [String: [ChatAttachment]] = [:]
    private var planModeByArea: [AgentArea: Bool] = [:]
    private var draftBeforeEditing: String?
    private var attachmentsBeforeEditing: [ChatAttachment]?
    private var availableSandboxesRefreshTask: Task<Void, Never>?
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

    private func draftKey(for conversationID: String) -> String {
        "\(activeArea.rawValue):\(conversationID)"
    }

    private var hasStartedChatBridge = false
    private var hasStartedCodingBridge = false

    /// Loads what the first frame shows for the active area only. Called while the window's
    /// content is being built, so the UI draws once with real data while deferring the
    /// inactive bridge until after the first frame has been committed to display.
    public func prepareForFirstFrame() {
        guard !hasPreparedFirstFrame else { return }
        hasPreparedFirstFrame = true
        if activeArea == .chat {
            startChatBridgeIfNeeded()
        } else {
            startCodingBridgeIfNeeded()
        }
    }

    public func startChatBridgeIfNeeded() {
        guard !hasStartedChatBridge else { return }
        hasStartedChatBridge = true
        chatBridge.start(workspacePath: "")
    }

    public func startCodingBridgeIfNeeded() {
        guard !hasStartedCodingBridge else { return }
        hasStartedCodingBridge = true
        codingBridge.start(workspacePath: sandboxRecoveryRequired ? "" : workspacePath)
        codingBridge.setSandboxPolicy(sandboxExecutionPolicy, branch: activeSandbox?.branch)
    }

    public func startDeferredBridgeIfNeeded() {
        startChatBridgeIfNeeded()
        startCodingBridgeIfNeeded()
    }

    public func start() {
        guard !hasStarted else { return }
        hasStarted = true
        if deferredVoiceKeyLoad {
            deferredVoiceKeyLoad = false
            loadVoiceAPIKeyInBackground()
        }
        // Voice and speech runtimes are loaded purely on-demand when the user activates voice input
        // Show the gate immediately on a fresh install; loadLegal() refines it.
        let needsAcceptance = !legal.hasAnyAcceptance
        if legalNeedsAcceptance != needsAcceptance { legalNeedsAcceptance = needsAcceptance }
        Task { @MainActor [weak self] in await self?.loadLegal() }

        // Normally already done before the first frame (see prepareForFirstFrame).
        prepareForFirstFrame()

        // Let SwiftUI commit the first frame before plugin mounting, remote work
        // location (may touch SSH), the remote-control listener and the scheduler.
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, !self.hasBootstrapped else { return }

            self.startDeferredBridgeIfNeeded()
            self.restoreWorkLocation()
            self.remoteControl.start()
            self.remount(refreshCatalog: true)
            self.hasBootstrapped = true
            self.objectWillChange.send()

            Task { @MainActor [weak self] in
                guard let self else { return }
                async let chatRefreshed: () = self.chatBridge.refreshConnection()
                async let codingRefreshed: () = self.codingBridge.refreshConnection()
                async let marketRestored: () = self.marketplaceSession.restore()
                _ = await (chatRefreshed, codingRefreshed, marketRestored)
                self.syncAccountFromMarketplace()
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
        remoteControl.start()
        hasBootstrapped = true
        scheduler.runsDueTasks = true
        scheduler.start()
    }

    public func presentTasks() {
        isSimulatorPresented = false
        isTasksPresented = true
    }

    public func toggleSidebarVisibility() {
        navigationState.toggle()
    }

    public func setActiveArea(_ area: AgentArea) {
        if area == .chat {
            startChatBridgeIfNeeded()
        } else {
            startCodingBridgeIfNeeded()
        }
        guard activeArea != area else { return }
        cancelEditing()
        saveDraftState()
        planModeByArea[activeArea] = isPlanMode
        activeArea = area
        assistantMode = area == .chat ? .chat : .coding
        isPlanMode = planModeByArea[area] ?? false
        host.settings.set("ui.activeArea", .string(area.rawValue))
        host.settings.set("ui.assistantMode", .string(area.rawValue))
        persistSettings()
        if area == .chat, chatBridge.selectedID == nil {
            chatBridge.newConversation()
        }
        restoreDraftState()
        objectWillChange.send()
    }

    public func shortcut(for action: KeyboardShortcutAction) -> UserKeyboardShortcut {
        keyboardShortcuts[action] ?? action.defaultShortcut
    }

    @discardableResult
    public func updateShortcut(
        _ shortcut: UserKeyboardShortcut,
        for action: KeyboardShortcutAction
    ) -> KeyboardShortcutUpdateResult {
        if let conflict = KeyboardShortcutAction.allCases.first(where: {
            $0 != action && self.shortcut(for: $0) == shortcut
        }) {
            return .conflict(conflict)
        }

        keyboardShortcuts[action] = shortcut
        host.settings.set(action.settingsKey, .string(shortcut.storedValue))
        persistSettings()
        return .saved
    }

    public func resetKeyboardShortcuts() {
        keyboardShortcuts = Dictionary(
            uniqueKeysWithValues: KeyboardShortcutAction.allCases.map { ($0, $0.defaultShortcut) }
        )
        for action in KeyboardShortcutAction.allCases {
            host.settings.remove(action.settingsKey)
        }
        persistSettings()
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

    /// Runner for the in-app `TaskScheduler`. Task runs keep their output in the
    /// task-run store and never become project conversations.
    public func runScheduledTask(_ task: ScheduledTask) async -> TaskScheduler.RunResult {
        let runner = ScheduledTaskRunner(
            paths: paths,
            router: codingRouter,
            endpoint: codingEndpoint,
            permissionMode: permissionMode,
            systemPrompt: { [weak self] in self?.codingBridge.effectiveSystemPromptReport() ?? "" }
        )
        return await runner.run(task)
    }

    private func notifyScheduledTask(_ task: ScheduledTask, result: TaskScheduler.RunResult) {
        desktopNotifications.showScheduledTask(task, result: result)
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

    // MARK: Plugin management

    private lazy var pluginInstaller = PluginInstaller(catalog: catalog)

    /// Installs a `.dotsplugin` package the user picked. Unsigned, untrusted.
    public func installPluginFile(_ url: URL) throws {
        try pluginInstaller.install(package: url, signature: nil, trust: .untrusted)
        remount()
    }

    public func removePlugin(id: String) throws {
        try pluginInstaller.remove(id: id)
        remount()
    }

    /// Packs an already-installed plugin folder into a shareable `.dotsplugin`.
    public func exportPlugin(id: String, to url: URL) throws {
        let folder = paths.plugins.appendingPathComponent(id, isDirectory: true)
        try PluginPackage.pack(folder: folder, to: url)
    }

    /// Read-only app state a plugin can pull via `harness.host("<topic>")`.
    /// Closures run on every plugin read — keep them to already-computed values.
    private func registerHostDataTopics() {
        let hostData = host.hostData
        hostData.register("app") { [weak self] in
            let info = Bundle.main.infoDictionary
            return .object([
                "version": .string(info?["CFBundleShortVersionString"] as? String ?? ""),
                "build": .string(info?["CFBundleVersion"] as? String ?? ""),
                "platform": .string("macos"),
                "locale": .string(self?.appLanguage.localeIdentifier ?? "en"),
            ])
        }
        hostData.register("workspace") { [weak self] in
            let path = self?.workspacePath ?? ""
            return .object([
                "path": .string(path),
                "hasWorkspace": .bool(!path.isEmpty),
            ])
        }
        hostData.register("model") { [weak self] in
            .object(["selectedId": .string(self?.selectedModelID ?? "")])
        }
    }

    public var visionPluginInstalled: Bool {
        catalog.entries.contains { $0.manifest.id == VisionFallbackDefaults.pluginID }
    }

    public var visionPluginEnabled: Bool {
        catalog.entries.first(where: { $0.manifest.id == VisionFallbackDefaults.pluginID })?.enabled == true
    }

    public var visionState: VisionFallbackState {
        host.getService(VisionFallbackDefaults.serviceName, as: VisionFallbackService.self)?.state ?? .unavailable
    }

    public var visionModelBytes: Int64 {
        host.getService(VisionFallbackDefaults.serviceName, as: VisionFallbackService.self)?.modelBytes
            ?? VisionFallbackDefaults.modelBytes
    }

    public func setVisionPluginEnabled(_ enabled: Bool) {
        catalog.setEnabled(VisionFallbackDefaults.pluginID, enabled)
        remount()
    }

    public func installVisionPlugin() async throws {
        guard let installer = host.getService(
            VisionFallbackDefaults.installerServiceName,
            as: VisionFallbackInstaller.self
        ) else { throw PluginError.package("Vision marketplace installer is unavailable.") }
        _ = try await installer.install()
        objectWillChange.send()
    }

    public func prepareVision() async throws {
        guard let service = host.getService(VisionFallbackDefaults.serviceName, as: VisionFallbackService.self) else {
            throw PluginError.package("Vision plugin is not installed.")
        }
        visionModelProgress = 0
        do {
            try await service.prepare(progress: { [weak self] value in
                Task { @MainActor in self?.visionModelProgress = min(1, max(0, value)) }
            })
            visionModelProgress = 1
        } catch {
            visionModelProgress = 0
            throw error
        }
        objectWillChange.send()
    }

    public func deleteVisionModel() throws {
        guard let service = host.getService(VisionFallbackDefaults.serviceName, as: VisionFallbackService.self) else {
            throw PluginError.package("Vision plugin is not installed.")
        }
        try service.deleteModel()
        visionModelProgress = 0
        objectWillChange.send()
    }

    public func removeVisionPlugin() throws {
        host.unmountAll()
        let pluginDirectory = paths.plugins.appendingPathComponent(VisionFallbackDefaults.pluginID, isDirectory: true)
        let modelDirectory = paths.models
            .appendingPathComponent("vision", isDirectory: true)
            .appendingPathComponent("smolvlm-256m-q8", isDirectory: true)
        if FileManager.default.fileExists(atPath: pluginDirectory.path) {
            try FileManager.default.removeItem(at: pluginDirectory)
        }
        if FileManager.default.fileExists(atPath: modelDirectory.path) {
            try FileManager.default.removeItem(at: modelDirectory)
        }
        remount()
    }

    private func remount(refreshCatalog: Bool) {
        if refreshCatalog {
            catalog.refresh()
        }
        skills.refresh()
        let document = CompositionLoader.loadHost(paths: paths, catalog: catalog)
        _ = host.mount(document)
        chatBridge.updateSystemPrompt(host.prompt.assembledText())
        codingBridge.updateSystemPrompt(host.prompt.assembledText())
        visionModelProgress = visionState == .ready ? 1 : 0
        objectWillChange.send()
    }

    public func newConversation() {
        cancelEditing()
        saveDraftState()
        bridge.newConversation()
        restoreDraftState()
    }

    public func newChatConversation(in projectID: String? = nil) {
        setActiveArea(.chat)
        chatBridge.newConversation()
        chatBridge.setChatProject(projectID)
        restoreDraftState()
    }

    public var unassignedChatConversations: [Conversation] {
        startChatBridgeIfNeeded()
        return chatBridge.conversations.filter { $0.chatProjectID == nil }
    }

    public func chatConversations(in projectID: String) -> [Conversation] {
        startChatBridgeIfNeeded()
        return chatBridge.conversations.filter { $0.chatProjectID == projectID }
    }

    @discardableResult
    public func createChatProject(
        name: String = "New chat project",
        description: String = ""
    ) -> ChatProject {
        let project = ChatProject(name: name, description: description, sortOrder: chatProjects.count)
        chatProjects.append(project)
        chatProjectStore.save(chatProjects)
        objectWillChange.send()
        return project
    }

    public func updateChatProject(_ project: ChatProject) {
        guard let index = chatProjects.firstIndex(where: { $0.id == project.id }) else { return }
        var value = project
        value.updatedAt = Date()
        chatProjects[index] = value
        chatProjectStore.save(chatProjects)
        objectWillChange.send()
    }

    public func toggleChatProjectPinned(_ projectID: String) {
        guard let index = chatProjects.firstIndex(where: { $0.id == projectID }) else { return }
        chatProjects[index].pinned.toggle()
        chatProjects[index].updatedAt = Date()
        chatProjectStore.save(chatProjects)
        objectWillChange.send()
    }

    public func setChatProjectArchived(_ projectID: String, archived: Bool) {
        guard let index = chatProjects.firstIndex(where: { $0.id == projectID }) else { return }
        chatProjects[index].archived = archived
        chatProjects[index].updatedAt = Date()
        chatProjectStore.save(chatProjects)
        objectWillChange.send()
    }

    public func deleteChatProject(_ projectID: String) {
        chatProjects.removeAll { $0.id == projectID }
        chatProjectStore.save(chatProjects)
        for id in chatBridge.conversations.filter({ $0.chatProjectID == projectID }).map(\.id) {
            chatBridge.setChatProject(nil, for: id)
        }
        objectWillChange.send()
    }

    /// Prefills the composer without sending. Matches the `plugincreator` slash
    /// command: replaces the draft only when it is effectively empty, otherwise the
    /// user's text is left untouched. Always requests composer focus.
    public func fillComposer(with text: String) {
        if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            draft = text
        }
        composerFocusRequestID &+= 1
    }

    public func newConversation(in projectPath: String) {
        setActiveArea(.coding)
        guard let targetPath = Self.canonicalExistingWorkspacePath(projectPath),
              projectPaths.contains(where: {
                  Self.canonicalExistingWorkspacePath($0) == targetPath
              }) else { return }
        let bridgeMatchesTarget = ConversationStore.normalizedPath(bridge.workspacePath)
            == ConversationStore.normalizedPath(targetPath)
        if workspacePath != targetPath || !bridgeMatchesTarget {
            setWorkspace(targetPath)
        }
        // `setWorkspace` can reject a switch while a sandbox is active (or when
        // recovery is required). Never fall through to the generic action in
        // that case: it would create a projectless chat in the old workspace.
        guard workspacePath == targetPath,
              ConversationStore.normalizedPath(bridge.workspacePath)
                  == ConversationStore.normalizedPath(targetPath) else { return }
        newConversation()
    }

    public func startWithoutProject() {
        newChatConversation()
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

    public func reportHistoryError(_ message: String) {
        historyError = message
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

    /// `/compact` only makes sense once this chat has a conversation to summarize.
    public var canCompactSelectedConversation: Bool {
        selectedConversationID.flatMap { id in conversations.first { $0.id == id } }?
            .messages.contains { $0.kind == .user } == true
    }

    public func setAssistantMode(_ mode: AssistantMode) {
        setActiveArea(mode == .chat ? .chat : .coding)
        assistantMode = mode
        chatBridge.setAssistantMode(.chat)
        codingBridge.setAssistantMode(.coding)
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
        draftsByConversation[draftKey(for: id)] = draft
        draftAttachmentsByConversation[draftKey(for: id)] = draftAttachments
    }

    private func restoreDraftState() {
        guard let id = bridge.selectedID else {
            draft = ""
            draftAttachments = []
            return
        }
        draft = draftsByConversation[draftKey(for: id)] ?? ""
        draftAttachments = draftAttachmentsByConversation[draftKey(for: id)] ?? []
    }

    public func ensureVoiceRuntimeReady() {
        refreshVoiceModel()
        refreshSpeechModel()
        prewarmNemotron()
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
        do {
            if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try router.store.vault.remove(Self.voiceCredentialID)
                guard try router.store.vault.get(Self.voiceCredentialID) == nil else {
                    throw ProviderStoreError.credentialUnavailable
                }
            } else {
                try router.store.vault.set(value, for: Self.voiceCredentialID)
                guard try router.store.vault.get(Self.voiceCredentialID) == value else {
                    throw ProviderStoreError.credentialUnavailable
                }
            }
            voiceAPIKey = value
            host.settings.remove(Self.voiceCredentialID)
            persistVoiceInputSettings()
        } catch {
            router.error = "Voice API key was not stored securely: \(error.localizedDescription)"
        }
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
            // The ASR server loads a model onto the GPU. Started at launch it competes
            // with the first frame; a few seconds later nobody notices, and dictation
            // pressed sooner still starts it on demand.
            try? await Task.sleep(for: .seconds(4))
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
        createdSpeech?.stop()
        nemotron.stop()
    }

    /// Publishes only a real change. Every write to `voiceModelStates` re-evaluates
    /// each view observing the model, and startup refreshes it with the same value.
    private func setVoiceModelState(_ state: LocalVoiceModelState, for provider: VoiceInputProvider) {
        guard voiceModelState(for: provider) != state else { return }
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
        guard speechModelState != state else { return }
        var states = voiceModelStates
        states[LocalSpeechModel.turkishPiper.id] = state
        voiceModelStates = states
    }

    /// The common case (no legacy plaintext setting) only reads the stored key. A
    /// Keychain read blocks for milliseconds, so it runs off the main thread once the
    /// first frame is up; nothing needs the key before the user picks the API provider.
    private func loadVoiceAPIKeyInBackground() {
        let vault = router.store.vault
        let id = Self.voiceCredentialID
        Task { @MainActor [weak self] in
            let stored = await Task.detached(priority: .utility) { try? vault.get(id) }.value
            guard let self, let stored, self.voiceAPIKey.isEmpty else { return }
            self.voiceAPIKey = stored
        }
    }

    private func migrateVoiceAPIKey(legacy: String?) {
        // Nothing to migrate: defer the Keychain read (see loadVoiceAPIKeyInBackground).
        guard legacy != nil else {
            deferredVoiceKeyLoad = true
            return
        }
        do {
            if let stored = try router.store.vault.get(Self.voiceCredentialID) {
                voiceAPIKey = stored
                if legacy != nil {
                    host.settings.remove(Self.voiceCredentialID)
                    persistSettings()
                }
                return
            }
            guard let legacy, !legacy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                if legacy != nil {
                    host.settings.remove(Self.voiceCredentialID)
                    persistSettings()
                }
                return
            }
            try router.store.vault.set(legacy, for: Self.voiceCredentialID)
            guard try router.store.vault.get(Self.voiceCredentialID) == legacy else {
                throw ProviderStoreError.credentialUnavailable
            }
            voiceAPIKey = legacy
            host.settings.remove(Self.voiceCredentialID)
            persistSettings()
        } catch {
            voiceAPIKey = legacy ?? ""
            router.error = "Voice API key migration failed; the existing setting was preserved: \(error.localizedDescription)"
        }
    }

    private func persistVoiceInputSettings() {
        host.settings.set("voice.provider", .string(voiceProvider.rawValue))
        host.settings.set("voice.api.endpoint", .string(voiceAPIEndpoint))
        host.settings.set("voice.api.model", .string(voiceAPIModel))
        host.settings.set("voice.api.realtimeEndpoint", .string(voiceAPIRealtimeEndpoint))
        persistSettings()
    }

    public func setWorkspace(_ value: String) {
        setWorkspace(value, allowSandboxTransition: false)
    }

    private func setWorkspace(_ value: String, allowSandboxTransition: Bool) {
        setActiveArea(.coding)
        let normalized = Self.validWorkspacePath(value).map {
            SandboxProfile.canonicalURL(URL(fileURLWithPath: $0, isDirectory: true)).path
        } ?? ""
        if let sandbox = activeSandbox,
           !allowSandboxTransition,
           normalized != sandbox.path {
            sandboxNotice = "Leave the active sandbox before changing workspaces."
            return
        }
        if sandboxRecoveryRequired, !allowSandboxTransition {
            sandboxNotice = "Recover the saved sandbox before changing workspaces."
            return
        }
        cancelEditing()
        workspacePath = normalized
        if !normalized.isEmpty, !projectPaths.contains(normalized) {
            projectPaths.insert(normalized, at: 0)
            persistProjectPaths()
        }
        remoteControl.setWorkspacePath(normalized)
        host.settings.set("agent.workspace", normalized.isEmpty ? .null : .string(normalized))
        persistSettings()
        codingBridge.setWorkspace(normalized)
        codingBridge.setSandboxPolicy(
            normalized == activeSandbox?.path ? sandboxExecutionPolicy : nil,
            branch: normalized == activeSandbox?.path ? activeSandbox?.branch : nil
        )
        codingBridge.setSearchFolders(projectSearchFolders(for: normalized))
        skills.setWorkspace(normalized.isEmpty ? nil : normalized)
        skillSuggestions.setWorkspace(normalized.isEmpty ? nil : normalized)
        restoreDraftState()
        refreshAvailableSandboxes()
        Task { await codingBridge.refreshConnection() }
    }

    /// Re-scans recent tool-call and prompt history for a repeated pattern worth
    /// turning into a skill. Only ever produces a suggestion for the user to review;
    /// nothing is written until acceptSkillSuggestion is called from an explicit click.
    public func scanSkillSuggestions() {
        let prompts = bridge.selected?.messages
            .filter { $0.kind == .user }
            .map(\.text) ?? []
        activeSkillSuggestions.scan(recentUserPrompts: prompts)
    }

    @discardableResult
    public func acceptSkillSuggestion(name: String, description: String, body: String? = nil) throws -> String {
        try activeSkillSuggestions.acceptCurrent(name: name, description: description, body: body)
    }

    public func dismissSkillSuggestion() {
        activeSkillSuggestions.dismissCurrent()
    }

    // MARK: - Project list

    /// Keeps the unsectioned project group expanded for the rest of this app
    /// session. This is intentionally independent of the current workspace so
    /// selecting another project never collapses the list.
    public func revealAllOtherProjects() {
        showsAllOtherProjects = true
    }

    /// Opens a folder picker and adds the chosen folder as a new project, making it active.
    public func addProject() {
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

    /// Switches the active project to an already-added one.
    public func selectProject(_ path: String) {
        setWorkspace(path)
    }

    /// Removes a project from the sidebar list (and its sort preference). If it was
    /// active, the next remaining project (or none) becomes active.
    public func removeProject(_ path: String) {
        guard let index = projectPaths.firstIndex(of: path) else { return }
        projectPaths.remove(at: index)
        projectMetadata.removeValue(forKey: path)
        projectSortOrders.removeValue(forKey: path)
        projectManualOrder.removeValue(forKey: path)
        persistProjectPaths()
        persistProjectMetadata()
        persistProjectSortOrders()
        if workspacePath == path {
            setWorkspace(projectPaths.first ?? "")
        }
    }

    private var gitProjectCache: [String: Bool] = [:]

    public func projectTitle(for path: String) -> String {
        let title = projectMetadata[path]?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? URL(fileURLWithPath: path).lastPathComponent : title
    }

    public func projectSearchFolders(for path: String) -> [String] {
        projectMetadata[path]?.searchFolders.compactMap { value in
            let url = SandboxProfile.canonicalURL(URL(fileURLWithPath: value, isDirectory: true))
            var isDirectory = ObjCBool(false)
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue,
                  !url.path.split(separator: "/").contains(".mem") else { return nil }
            return url.path
        } ?? []
    }

    /// `SandboxWorkspaces.isGitRepository` spawns a `git` process. The sidebar
    /// asks once per project row while building menus, so the answer is cached
    /// for the session rather than shelling out on every redraw.
    public func isGitProject(_ path: String) -> Bool {
        if let cached = gitProjectCache[path] { return cached }
        let value = SandboxWorkspaces.isGitRepository(URL(fileURLWithPath: path))
        gitProjectCache[path] = value
        return value
    }

    public func isProjectPinned(_ path: String) -> Bool {
        projectMetadata[path]?.pinned ?? false
    }

    public func projectSection(for path: String) -> String? {
        projectMetadata[path]?.section
    }

    public func projectWorktreeOrigin(for path: String) -> String? {
        projectMetadata[path]?.worktreeOrigin
    }

    public func saveProjectMetadata(
        for path: String,
        title: String,
        searchFolders: [String]
    ) {
        var metadata = projectMetadata[path] ?? ProjectMetadata()
        metadata.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let canonicalPath = SandboxProfile.canonicalURL(URL(fileURLWithPath: path, isDirectory: true)).path
        metadata.searchFolders = searchFolders
            .map { SandboxProfile.canonicalURL(URL(fileURLWithPath: $0, isDirectory: true)).path }
            .filter { $0 != canonicalPath }
            .filter { value in
                var isDirectory = ObjCBool(false)
                return FileManager.default.fileExists(atPath: value, isDirectory: &isDirectory) && isDirectory.boolValue
            }
            .reduce(into: []) { result, item in
                if !result.contains(item) { result.append(item) }
            }
        projectMetadata[path] = metadata
        persistProjectMetadata()
        if workspacePath == path { bridge.setSearchFolders(metadata.searchFolders) }
        objectWillChange.send()
    }

    public func toggleProjectPinned(_ path: String) {
        var metadata = projectMetadata[path] ?? ProjectMetadata()
        metadata.pinned.toggle()
        projectMetadata[path] = metadata
        persistProjectMetadata()
        objectWillChange.send()
    }

    public func setProjectSection(_ section: String?, for path: String) {
        var metadata = projectMetadata[path] ?? ProjectMetadata()
        let value = section?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        metadata.section = value.isEmpty ? nil : value
        if let section = metadata.section, !projectSections.contains(section) {
            projectSections.append(section)
        }
        projectMetadata[path] = metadata
        persistProjectMetadata()
        persistProjectSections()
        objectWillChange.send()
    }

    @discardableResult
    public func createProjectSection(named rawName: String) -> String? {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        if !projectSections.contains(name) { projectSections.append(name) }
        persistProjectSections()
        return name
    }

    public func markAllChatsRead(forProject path: String) {
        bridge.markAllRead(forWorkspace: path)
    }

    public func archiveChats(forProject path: String) {
        bridge.archiveAll(forWorkspace: path)
    }

    public func createPermanentWorktree(from originPath: String, named name: String) {
        do {
            let worktree = try SandboxWorkspaces.enter(origin: originPath, name: name)
            let path = worktree.path
            if !projectPaths.contains(path) { projectPaths.insert(path, at: 0) }
            var metadata = projectMetadata[path] ?? ProjectMetadata()
            metadata.worktreeOrigin = worktree.originPath
            projectMetadata[path] = metadata
            persistProjectPaths()
            persistProjectMetadata()
            setWorkspace(path)
        } catch {
            sandboxNotice = error.localizedDescription
        }
    }

    public func sortOrder(forProject path: String) -> ConversationSortOrder {
        projectSortOrders[path] ?? .lastUpdate
    }

    public func setSortOrder(_ order: ConversationSortOrder, forProject path: String) {
        guard !path.isEmpty else { return }
        projectSortOrders[path] = order
        persistProjectSortOrders()
    }

    public func setSidebarLayoutMode(_ mode: SidebarLayoutMode) {
        sidebarLayoutMode = mode
        host.settings.set("agent.sidebarLayoutMode", .string(mode.rawValue))
        persistSettings()
    }

    /// Moves `id` to just before `targetID` in the given project's manual order
    /// (or to the end when `targetID` is nil). `currentOrder` seeds the array the
    /// first time a project is reordered, so unranked conversations keep their
    /// prior on-screen position instead of jumping to the top.
    public func moveConversation(
        _ id: String,
        before targetID: String?,
        inProject path: String,
        currentOrder: [String]
    ) {
        guard !path.isEmpty, id != targetID else { return }
        var order = projectManualOrder[path] ?? currentOrder
        for missing in currentOrder where !order.contains(missing) {
            order.append(missing)
        }
        order.removeAll { $0 == id }
        if let targetID, let targetIndex = order.firstIndex(of: targetID) {
            order.insert(id, at: targetIndex)
        } else {
            order.append(id)
        }
        projectManualOrder[path] = order
        host.settings.set("agent.projectManualOrder", .object(
            projectManualOrder.mapValues { .array($0.map(JSONValue.string)) }
        ))
        persistSettings()
    }

    private func persistProjectPaths() {
        host.settings.set("agent.projects", .array(projectPaths.map(JSONValue.string)))
        persistSettings()
    }

    private func persistProjectMetadata() {
        let values = projectMetadata.mapValues { metadata in
            JSONValue.object([
                "title": .string(metadata.title),
                "pinned": .bool(metadata.pinned),
                "section": metadata.section.map(JSONValue.string) ?? .null,
                "searchFolders": .array(metadata.searchFolders.map(JSONValue.string)),
                "worktreeOrigin": metadata.worktreeOrigin.map(JSONValue.string) ?? .null,
            ])
        }
        host.settings.set("agent.projectMetadata", .object(values))
        persistSettings()
    }

    private func persistProjectSections() {
        host.settings.set("agent.projectSections", .array(projectSections.map(JSONValue.string)))
        persistSettings()
    }

    private func persistProjectSortOrders() {
        let object = projectSortOrders.mapValues { JSONValue.string($0.rawValue) }
        host.settings.set("agent.projectSortOrders", .object(object))
        persistSettings()
    }

    // MARK: - Sandbox

    /// Point the agent at a git worktree of the current workspace. The user's
    /// own checkout is left exactly as it is.
    public func enterSandbox(named name: String) {
        guard activeSandbox == nil else {
            sandboxNotice = SandboxWorkspaceError.activeOperationInProgress.localizedDescription
            return
        }
        guard !sandboxRecoveryRequired else {
            sandboxNotice = "Recover the saved sandbox before starting another one."
            return
        }
        guard !bridge.anyRunBusy, !bridge.historyMutationBusy else {
            sandboxNotice = SandboxWorkspaceError.activeOperationInProgress.localizedDescription
            return
        }
        let origin = workspacePath
        guard !origin.isEmpty else {
            sandboxNotice = "Open a workspace first."
            return
        }
        guard SandboxProfile.isAvailable else {
            sandboxNotice = "sandbox-exec is unavailable; the sandbox was not started."
            return
        }
        do {
            let sandbox = try SandboxWorkspaces.enter(origin: origin, name: name)
            let status = SandboxWorkspaces.git(
                ["status", "--porcelain", "--untracked-files=all"],
                in: URL(fileURLWithPath: origin, isDirectory: true)
            )
            let uncommitted = status.status != 0 || !status.text.isEmpty
            setWorkspace(sandbox.path)
            activeSandbox = sandbox
            refreshSandboxWritableRoots()
            sandboxConflict = nil
            sandboxResolutionPreview = nil
            sandboxCleanupPending = false
            sandboxCleanupMerge = true
            sandboxRecoveryRequired = false
            clearPersistedSandboxConflict()
            bridge.setSandboxPolicy(sandboxExecutionPolicy, branch: sandbox.branch)
            persistSandboxState(sandbox)
            sandboxNotice = uncommitted
                ? "Sandbox '\(sandbox.name)' started from the last commit. Your uncommitted changes stayed in \(origin) and are not visible to the agent."
                : "Sandbox '\(sandbox.name)' started."
        } catch {
            sandboxNotice = error.localizedDescription
        }
    }

    public func recoverSandbox(_ candidate: SandboxWorkspace) {
        guard activeSandbox == nil else {
            sandboxNotice = SandboxWorkspaceError.activeOperationInProgress.localizedDescription
            return
        }
        guard !bridge.anyRunBusy, !bridge.historyMutationBusy else {
            sandboxNotice = SandboxWorkspaceError.activeOperationInProgress.localizedDescription
            return
        }
        guard SandboxProfile.isAvailable else {
            sandboxNotice = "sandbox-exec is unavailable; the sandbox was not recovered."
            return
        }
        do {
            let savedPath = host.settings.get("agent.sandbox.path")?.string
            let sandbox = try SandboxWorkspaces.restore(
                origin: candidate.originPath,
                path: candidate.path,
                name: candidate.name,
                originBranch: candidate.originBranch
            )
            let isSavedCandidate = savedPath.map {
                SandboxProfile.canonicalURL(URL(fileURLWithPath: $0, isDirectory: true)).path
            } == sandbox.path
            let restoredConflict = isSavedCandidate ? persistedSandboxConflict(for: sandbox) : nil
            let restoredCleanupPending = isSavedCandidate && sandboxCleanupPending
            let restoredCleanupMerge = restoredCleanupPending ? sandboxCleanupMerge : true
            setWorkspace(sandbox.path, allowSandboxTransition: true)
            activeSandbox = sandbox
            refreshSandboxWritableRoots()
            sandboxConflict = restoredConflict
            sandboxResolutionPreview = nil
            sandboxCleanupPending = restoredCleanupPending
            sandboxCleanupMerge = restoredCleanupMerge
            sandboxRecoveryRequired = false
            if !isSavedCandidate { clearPersistedSandboxConflict() }
            bridge.setSandboxPolicy(sandboxExecutionPolicy, branch: sandbox.branch)
            persistSandboxState(sandbox)
            sandboxNotice = "Sandbox '\(sandbox.name)' recovered."
        } catch {
            sandboxNotice = "Sandbox recovery failed: \(error.localizedDescription)"
        }
    }

    public func retrySandboxRecovery() {
        guard let sandbox = activeSandbox, sandboxRecoveryRequired else { return }
        guard !bridge.anyRunBusy, !bridge.historyMutationBusy, !sandboxResolutionBusy else {
            sandboxNotice = "Finish the active agent operation before retrying recovery."
            return
        }
        do {
            try SandboxWorkspaces.validateReady(sandbox)
            setWorkspace(sandbox.path, allowSandboxTransition: true)
            refreshSandboxWritableRoots()
            sandboxRecoveryRequired = false
            bridge.setSandboxPolicy(sandboxExecutionPolicy, branch: sandbox.branch)
            persistSandboxState(sandbox)
            sandboxNotice = "Sandbox recovery completed."
        } catch {
            sandboxNotice = "Sandbox recovery still needs attention: \(error.localizedDescription)"
        }
    }

    /// Leave the sandbox. `merge: true` merges the sandbox branch into the
    /// origin checkout; a conflict aborts the merge and keeps the sandbox.
    public func exitSandbox(merge: Bool) {
        guard let sandbox = activeSandbox else { return }
        guard !bridge.anyRunBusy, !bridge.historyMutationBusy, !sandboxResolutionBusy, !sandboxRecoveryRequired else {
            sandboxNotice = sandboxRecoveryRequired
                ? "Recover the sandbox state before leaving it."
                : SandboxWorkspaceError.activeOperationInProgress.localizedDescription
            return
        }
        terminalManager.stopSessions(for: sandbox.path)
        bridge.stopAgentTerminals(for: sandbox.path)
        let requestedMerge = sandboxCleanupPending ? sandboxCleanupMerge : merge
        do {
            switch try SandboxWorkspaces.exit(sandbox, merge: requestedMerge) {
            case .conflicted(let conflict):
                // Still in the sandbox on purpose: nothing was applied, and the
                // work is only safe where it already is.
                sandboxNotice = "Merge conflicts, nothing applied. Resolve in \(sandbox.originPath): "
                    + conflict.files.joined(separator: ", ")
                sandboxConflict = conflict
                sandboxResolutionPreview = nil
                persistSandboxConflict(conflict)
                return
            case .merged(let commits):
                finishSandboxExit(sandbox, notice: commits == 0
                    ? "Sandbox '\(sandbox.name)' had no changes; removed."
                    : "Merged \(commits) commit(s) from '\(sandbox.name)'.")
            case .discarded:
                finishSandboxExit(
                    sandbox,
                    notice: "Sandbox '\(sandbox.name)' discarded. Branch \(sandbox.branch) still holds the work."
                )
            }
        } catch {
            if case SandboxWorkspaceError.cleanupFailed = error {
                sandboxCleanupPending = true
                sandboxCleanupMerge = requestedMerge
                persistSandboxState(sandbox)
            }
            if case SandboxWorkspaceError.mergeAbortFailed = error {
                sandboxRecoveryRequired = true
                persistSandboxState(sandbox)
            }
            sandboxNotice = error.localizedDescription
        }
    }

    private func finishSandboxExit(_ sandbox: SandboxWorkspace, notice: String) {
        activeSandbox = nil
        sandboxAgentWritableRoots = []
        sandboxConflict = nil
        sandboxResolutionPreview = nil
        sandboxResolutionBusy = false
        sandboxCleanupPending = false
        sandboxCleanupMerge = true
        sandboxRecoveryRequired = false
        host.settings.set("agent.sandbox.origin", .null)
        host.settings.set("agent.sandbox.path", .null)
        host.settings.set("agent.sandbox.name", .null)
        host.settings.set("agent.sandbox.branch", .null)
        host.settings.set("agent.sandbox.originBranch", .null)
        host.settings.set("agent.sandbox.cleanupPending", .null)
        host.settings.set("agent.sandbox.cleanupMerge", .null)
        host.settings.set("agent.sandbox.recoveryRequired", .null)
        clearPersistedSandboxConflict()
        setWorkspace(sandbox.originPath, allowSandboxTransition: true)
        sandboxNotice = notice
        persistSettings()
    }

    private func persistSandboxState(_ sandbox: SandboxWorkspace) {
        host.settings.set("agent.sandbox.origin", .string(sandbox.originPath))
        host.settings.set("agent.sandbox.path", .string(sandbox.path))
        host.settings.set("agent.sandbox.name", .string(sandbox.name))
        host.settings.set("agent.sandbox.branch", .string(sandbox.branch))
        host.settings.set("agent.sandbox.originBranch", .string(sandbox.originBranch))
        host.settings.set("agent.sandbox.cleanupPending", .bool(sandboxCleanupPending))
        host.settings.set("agent.sandbox.cleanupMerge", .bool(sandboxCleanupMerge))
        host.settings.set("agent.sandbox.recoveryRequired", .bool(sandboxRecoveryRequired))
        persistSettings()
    }

    private func persistSandboxConflict(_ conflict: SandboxConflict) {
        host.settings.set("agent.sandbox.conflict.originBranch", .string(conflict.originBranch))
        host.settings.set("agent.sandbox.conflict.originHead", .string(conflict.originHead))
        host.settings.set("agent.sandbox.conflict.sandboxHead", .string(conflict.sandboxHead))
        host.settings.set("agent.sandbox.conflict.files", .array(conflict.files.map(JSONValue.string)))
        persistSettings()
    }

    private func clearPersistedSandboxConflict() {
        host.settings.set("agent.sandbox.conflict.originBranch", .null)
        host.settings.set("agent.sandbox.conflict.originHead", .null)
        host.settings.set("agent.sandbox.conflict.sandboxHead", .null)
        host.settings.set("agent.sandbox.conflict.files", .null)
    }

    private func persistedSandboxConflict(for sandbox: SandboxWorkspace) -> SandboxConflict? {
        guard let originHead = host.settings.get("agent.sandbox.conflict.originHead")?.string,
              let sandboxHead = host.settings.get("agent.sandbox.conflict.sandboxHead")?.string,
              let files = host.settings.get("agent.sandbox.conflict.files")?.array?.compactMap(\.string),
              !originHead.isEmpty,
              !sandboxHead.isEmpty,
              !files.isEmpty else { return nil }
        return SandboxConflict(
            sandbox: sandbox,
            originBranch: host.settings.get("agent.sandbox.conflict.originBranch")?.string ?? sandbox.originBranch,
            originHead: originHead,
            sandboxHead: sandboxHead,
            files: files
        )
    }

    public func retrySandboxCleanup() {
        guard let sandbox = activeSandbox, sandboxCleanupPending else { return }
        guard !bridge.anyRunBusy, !bridge.historyMutationBusy, !sandboxResolutionBusy, !sandboxRecoveryRequired else {
            sandboxNotice = SandboxWorkspaceError.activeOperationInProgress.localizedDescription
            return
        }
        terminalManager.stopSessions(for: sandbox.path)
        bridge.stopAgentTerminals(for: sandbox.path)
        do {
            try SandboxWorkspaces.retryCleanup(sandbox, originMerged: sandboxCleanupMerge)
            finishSandboxExit(sandbox, notice: "Sandbox '\(sandbox.name)' cleanup completed.")
        } catch {
            if case SandboxWorkspaceError.mergeAbortFailed = error {
                sandboxRecoveryRequired = true
                persistSandboxState(sandbox)
            }
            sandboxNotice = error.localizedDescription
        }
    }

    public func setSandboxNetworkAccess(_ enabled: Bool) {
        sandboxNetworkAccess = enabled
        host.settings.set("agent.sandbox.networkAccess", .bool(enabled))
        persistSettings()
        if activeSandbox != nil, !sandboxRecoveryRequired {
            bridge.setSandboxPolicy(sandboxExecutionPolicy, branch: activeSandbox?.branch)
        }
    }

    public func prepareSandboxResolution() {
        guard let conflict = sandboxConflict else { return }
        guard !bridge.anyRunBusy, !bridge.historyMutationBusy, !sandboxResolutionBusy, !sandboxRecoveryRequired else {
            sandboxNotice = sandboxRecoveryRequired
                ? "Recover the sandbox state before preparing a resolution."
                : SandboxWorkspaceError.activeOperationInProgress.localizedDescription
            return
        }
        terminalManager.stopSessions(for: conflict.sandbox.path)
        bridge.stopAgentTerminals(for: conflict.sandbox.path)
        sandboxResolutionBusy = true
        defer { sandboxResolutionBusy = false }
        do {
            try SandboxWorkspaces.prepareResolution(conflict)
            sandboxResolutionPreview = try SandboxWorkspaces.previewResolution(conflict)
            sandboxNotice = "Conflict resolution is ready in the sandbox."
        } catch {
            if case SandboxWorkspaceError.mergeAbortFailed = error {
                sandboxRecoveryRequired = true
                persistSandboxState(conflict.sandbox)
            }
            sandboxNotice = error.localizedDescription
        }
    }

    public func previewSandboxResolution() {
        guard let conflict = sandboxConflict else { return }
        guard !sandboxResolutionBusy else { return }
        do {
            sandboxResolutionPreview = try SandboxWorkspaces.previewResolution(conflict)
        } catch {
            if case SandboxWorkspaceError.mergeAbortFailed = error {
                sandboxRecoveryRequired = true
                persistSandboxState(conflict.sandbox)
            }
            sandboxNotice = error.localizedDescription
        }
    }

    public func askAgentToResolveSandboxConflict() async {
        guard let conflict = sandboxConflict else { return }
        guard !bridge.anyRunBusy, !bridge.historyMutationBusy, !sandboxResolutionBusy, !sandboxRecoveryRequired else {
            sandboxNotice = sandboxRecoveryRequired
                ? "Recover the sandbox state before asking for a resolution."
                : SandboxWorkspaceError.activeOperationInProgress.localizedDescription
            return
        }
        terminalManager.stopSessions(for: conflict.sandbox.path)
        bridge.stopAgentTerminals(for: conflict.sandbox.path)
        do {
            try SandboxWorkspaces.prepareResolution(conflict)
        } catch {
            if case SandboxWorkspaceError.mergeAbortFailed = error {
                sandboxRecoveryRequired = true
                persistSandboxState(conflict.sandbox)
            }
            sandboxNotice = error.localizedDescription
            return
        }

        sandboxResolutionPreview = nil
        sandboxResolutionBusy = true
        defer { sandboxResolutionBusy = false }
        let files = conflict.files.map { "- \($0)" }.joined(separator: "\n")
        await bridge.send(
            text: """
            Resolve this git merge conflict inside the active HerNess sandbox.
            Edit only these conflict files:
            \(files)
            Do not access the origin checkout. Do not run git add or git commit.
            Remove every conflict marker, run the relevant tests, and report what
            you changed. Leave the resolved files in the working tree for the host
            to stage and preview.
            """,
            mode: .queue
        )
        guard activeSandbox?.path == conflict.sandbox.path else { return }
        do {
            sandboxResolutionPreview = try SandboxWorkspaces.previewResolution(conflict)
            sandboxNotice = "Agent resolution is ready for review."
        } catch {
            if case SandboxWorkspaceError.mergeAbortFailed = error {
                sandboxRecoveryRequired = true
                persistSandboxState(conflict.sandbox)
            }
            sandboxNotice = error.localizedDescription
        }
    }

    public func applySandboxResolution() {
        guard let conflict = sandboxConflict,
              let preview = sandboxResolutionPreview else { return }
        guard !sandboxResolutionBusy, !bridge.anyRunBusy, !bridge.historyMutationBusy, !sandboxRecoveryRequired else {
            sandboxNotice = sandboxRecoveryRequired
                ? "Recover the sandbox state before approving the resolution."
                : SandboxWorkspaceError.activeOperationInProgress.localizedDescription
            return
        }
        guard !preview.isTruncated, preview.unresolvedFiles.isEmpty else {
            sandboxNotice = "The resolution must have no unresolved files and a complete preview."
            return
        }
        terminalManager.stopSessions(for: conflict.sandbox.path)
        bridge.stopAgentTerminals(for: conflict.sandbox.path)
        sandboxResolutionBusy = true
        defer { sandboxResolutionBusy = false }
        do {
            switch try SandboxWorkspaces.applyResolution(
                conflict,
                expectedFingerprint: preview.fingerprint
            ) {
            case .merged(let commits):
                finishSandboxExit(
                    conflict.sandbox,
                    notice: "Merged the approved sandbox resolution (\(commits) commit(s))."
                )
            case .conflicted(let nextConflict):
                sandboxConflict = nextConflict
                sandboxResolutionPreview = nil
                persistSandboxConflict(nextConflict)
                sandboxNotice = "The approved resolution conflicted again; nothing was applied."
            case .discarded:
                sandboxNotice = "The sandbox resolution was discarded."
            }
        } catch {
            if case SandboxWorkspaceError.cleanupFailed = error {
                sandboxCleanupPending = true
                sandboxCleanupMerge = true
                persistSandboxState(conflict.sandbox)
            }
            if case SandboxWorkspaceError.mergeAbortFailed = error {
                sandboxRecoveryRequired = true
                persistSandboxState(conflict.sandbox)
            }
            sandboxNotice = error.localizedDescription
        }
    }

    public func cancelSandboxResolution() {
        guard let conflict = sandboxConflict else { return }
        guard !sandboxResolutionBusy, !bridge.anyRunBusy, !bridge.historyMutationBusy, !sandboxRecoveryRequired else {
            sandboxNotice = sandboxRecoveryRequired
                ? "Recover the sandbox state before cancelling the resolution."
                : SandboxWorkspaceError.activeOperationInProgress.localizedDescription
            return
        }
        do {
            try SandboxWorkspaces.cancelResolution(conflict)
            sandboxResolutionPreview = nil
            sandboxNotice = "Sandbox resolution cancelled; the origin was not changed."
        } catch {
            if case SandboxWorkspaceError.mergeAbortFailed = error {
                sandboxRecoveryRequired = true
                persistSandboxState(conflict.sandbox)
            }
            sandboxNotice = error.localizedDescription
        }
    }

    public func revealSandbox() {
        guard let sandbox = activeSandbox else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: sandbox.path)])
    }

    public func revealOriginWorkspace() {
        let path = activeSandbox?.originPath ?? workspacePath
        guard !path.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    public func refreshAvailableSandboxes() {
        let originPath = activeSandbox?.originPath ?? workspacePath
        availableSandboxesRefreshTask?.cancel()

        guard !originPath.isEmpty else {
            availableSandboxes = []
            return
        }

        availableSandboxesRefreshTask = Task { @MainActor [weak self] in
            let sandboxes = await Task.detached(priority: .utility) {
                SandboxWorkspaces.list(origin: originPath)
            }.value
            guard !Task.isCancelled, let self else { return }
            guard (self.activeSandbox?.originPath ?? self.workspacePath) == originPath else { return }
            self.availableSandboxes = sandboxes
        }
    }

    public func setModel(_ value: String) {
        router.selectedModelID = value
        endpoint.modelID = value
        endpoint.updateStatus()
        host.settings.set("agent.model.\(activeArea.rawValue)", value.isEmpty ? .null : .string(value))
        if activeArea == .coding {
            host.settings.set("agent.model", value.isEmpty ? .null : .string(value))
        }
        // Levels are model-specific, so a level the new model rejects must not
        // carry over — it would fail the next request with HTTP 400.
        if !router.efforts(for: value).contains(router.selectedEffort) { setEffort("") }
        if router.fastMode, !router.supportsFast(value) { setFast(false) }
        persistSettings()
        Task { await bridge.refreshConnection() }
    }

    /// Reasoning effort for the selected model. Empty means the provider default.
    public func setEffort(_ value: String) {
        router.selectedEffort = value
        objectWillChange.send() // router is a nested ObservableObject; views watching only AppModel must refresh
        host.settings.set("agent.effort.\(activeArea.rawValue)", value.isEmpty ? .null : .string(value))
        if activeArea == .coding {
            host.settings.set("agent.effort", value.isEmpty ? .null : .string(value))
        }
        persistSettings()
    }

    /// Fast (priority) response mode; only meaningful for models that support it.
    public func setFast(_ value: Bool) {
        router.fastMode = value
        objectWillChange.send()
        host.settings.set("agent.fast.\(activeArea.rawValue)", value ? .bool(true) : .null)
        persistSettings()
    }

    public func setAppearance(_ value: Appearance) {
        appearance = value
        host.settings.set("ui.appearance", .string(value.rawValue))
        persistSettings()
    }

    public func loadLegal() async {
        let lang = AppCopy.effectiveLanguage.rawValue
        if let docs = await legal.fetch(lang: lang) {
            legalDocuments = docs
            legalNeedsAcceptance = legal.needsAcceptance(docs)
            legalLoadFailed = false
        } else {
            // Offline with nothing cached: gate only if the user never accepted.
            legalLoadFailed = true
            legalNeedsAcceptance = !legal.hasAnyAcceptance
        }
    }

    public func acceptLegal() {
        guard let docs = legalDocuments else { return }
        legal.accept(docs)
        legalNeedsAcceptance = false
        persistSettings()
    }

    public func legalConsent(_ key: LegalConsentKey) -> Bool { legal.consent(key) }

    /// Gate for sending workspace/conversation content to an AI provider.
    public var aiTransferAllowed: Bool { legal.aiTransferAllowed }

    public func setPermissionMode(_ value: AgentPermissionMode) {
        permissionMode = value
        chatBridge.setPermissionMode(value)
        codingBridge.setPermissionMode(value)
        host.settings.set("agent.permissionMode", .string(value.rawValue))
        persistSettings()
    }

    public func setBrowserBackend(_ value: BrowserBackend?) {
        let selected = value == .unknown ? nil : value
        browserBackend = selected
        chatBridge.setBrowserBackend(selected)
        codingBridge.setBrowserBackend(selected)
        if let selected {
            host.settings.set("agent.browserBackend", .string(selected.rawValue))
        } else {
            host.settings.set("agent.browserBackend", .null)
        }
        persistSettings()
    }

    public func beginRemotePairing() -> RemotePairingInfo {
        remoteControl.beginPairing()
    }

    public func enableRemoteCloudTunnel() async throws -> String {
        try await remoteControl.enableCloudTunnel()
    }

    public func disableRemoteCloudTunnel() {
        remoteControl.disableCloudTunnel()
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

    public func setSelfVerification(_ value: Bool) {
        selfVerification = value
        chatBridge.setSelfVerification(value)
        codingBridge.setSelfVerification(value)
        host.settings.set("agent.selfVerification", .bool(value))
        persistSettings()
    }

    public func setSeedProjectRules(_ value: Bool) {
        seedProjectRules = value
        chatBridge.setSeedProjectRules(value)
        codingBridge.setSeedProjectRules(value)
        host.settings.set("agent.seedProjectRules", .bool(value))
        persistSettings()
    }

    public func setConfirmBeforeExit(_ value: Bool) {
        confirmBeforeExit = value
        host.settings.set("ui.confirmBeforeExit", .bool(value))
        persistSettings()
    }

    /// When set, SettingsView selects this tab on next appearance, then clears it.
    @Published public var settingsInitialTab: String?

    public func presentSettings(tab: String? = nil) {
        settingsInitialTab = tab
        isSettingsPresented = true
    }

    public func showPet() {
        isPetVisible = true
    }

    public func hidePet() {
        isPetVisible = false
    }

    public func requestFeedbackForLatestResponse() {
        guard !workspacePath.isEmpty,
              let conversation = selected,
              let message = conversation.messages.last(where: {
                  ($0.kind == .assistant || $0.kind == .plan)
                      && !$0.streaming
                      && (!$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !$0.mediaItems.isEmpty)
              }) else { return }
        let feedbackType = bridge.feedback(for: message.id, in: conversation.id)?.feedbackType ?? .good
        feedbackRequest = FeedbackTarget(
            conversationID: conversation.id,
            messageID: message.id,
            feedbackType: feedbackType
        )
    }

    public func presentUsage() {
        isUsagePresented = true
    }

    public func setAccountIdentity(_ identity: AccountIdentity) {
        account = identity
    }

    public func syncAccountFromMarketplace() {
        guard let profile = marketplaceSession.profile else { return }
        let displayName = [profile.name, profile.surname]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: " ")
        let name = displayName.isEmpty ? profile.email : displayName
        account = AccountIdentity(
            displayName: name,
            username: profile.username ?? profile.email,
            initials: AccountIdentity.initials(from: name),
            isSignedIn: true
        )
    }

    /// Browser URL for the project's code-forge pull/merge request list, derived
    /// from `git remote.origin.url`. `nil` when the path isn't a git repo with an
    /// `origin` remote.
    public func forgeURL(for path: String) -> URL? {
        guard !path.isEmpty else { return nil }
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", path, "config", "--get", "remote.origin.url"]
        process.standardOutput = output
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              var remote = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !remote.isEmpty else { return nil }

        if remote.hasSuffix(".git") { remote = String(remote.dropLast(4)) }

        // Normalize scp-style (git@host:owner/repo) and ssh/https to https://host/owner/repo
        var host = ""
        var pathPart = ""
        if let range = remote.range(of: "://") {
            let rest = String(remote[range.upperBound...])
            if let slash = rest.firstIndex(of: "/") {
                host = String(rest[..<slash])
                pathPart = String(rest[rest.index(after: slash)...])
            }
            if let at = host.firstIndex(of: "@") { host = String(host[host.index(after: at)...]) }
        } else if let at = remote.firstIndex(of: "@"), let colon = remote.firstIndex(of: ":") {
            host = String(remote[remote.index(after: at)..<colon])
            pathPart = String(remote[remote.index(after: colon)...])
        } else {
            return nil
        }
        guard !host.isEmpty, !pathPart.isEmpty else { return nil }

        let base = "https://\(host)/\(pathPart)"
        let lowerHost = host.lowercased()
        if lowerHost.contains("github") {
            return URL(string: base + "/pulls")
        } else if lowerHost.contains("gitlab") {
            return URL(string: base + "/-/merge_requests")
        } else if lowerHost.contains("bitbucket") {
            return URL(string: base + "/pull-requests")
        }
        return URL(string: base)
    }

    public var activeProjectForgeURL: URL? {
        forgeURL(for: workspacePath)
    }

    public func openPullRequests() {
        if let url = activeProjectForgeURL { NSWorkspace.shared.open(url) }
    }

    /// ponytail: no Sites subsystem exists yet; send the user to the Cloudflare
    /// Pages dashboard. Replace with a real deploy-targets view when one lands.
    public func openSites() {
        if let url = URL(string: "https://dash.cloudflare.com/?to=/:account/pages") {
            NSWorkspace.shared.open(url)
        }
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
        setWorkspace("")
        account = .signedOut()
        Task { @MainActor [weak self] in
            await self?.marketplaceSession.signOut()
        }
    }

    public func persistSettings() {
        let snapshot = host.settings.snapshot()
        if let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: paths.settings, options: .atomic)
        }
    }

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

    private static func validWorkspacePath(_ value: String) -> String? {
        guard let normalized = ConversationStore.normalizedPath(value), normalized != "/" else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: normalized, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        return normalized
    }

    private static func canonicalExistingWorkspacePath(_ value: String) -> String? {
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

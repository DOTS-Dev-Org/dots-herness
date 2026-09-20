// Copyright (c) 2026 DOTS
// Native agent host: conversation state, model loop, tools, and workspace memory.

import Foundation
import HarnessPluginKit
import Observation
import PluginRuntime

public struct AgentConnection: Sendable, Equatable {
    public var endpoint: URL
    public var provider: String
    public var model: String

    public init(endpoint: URL, provider: String, model: String) {
        self.endpoint = endpoint
        self.provider = provider
        self.model = model
    }
}

public struct AssistantResponseEvent: Sendable, Equatable {
    public let conversationTitle: String
    public let text: String
    public let isPlan: Bool

    public init(conversationTitle: String, text: String, isPlan: Bool = false) {
        self.conversationTitle = conversationTitle
        self.text = text
        self.isPlan = isPlan
    }
}

public struct RunSummaryEvent: Sendable, Equatable {
    public enum Outcome: String, Sendable, Equatable {
        case completed, failed, stopped
    }

    public let conversationTitle: String
    public let summary: WorkspaceRunSummary
    public let conversationID: String
    public let outcome: Outcome
    /// What went wrong, for a failed run's notification.
    public let failureMessage: String?

    public init(
        conversationTitle: String,
        summary: WorkspaceRunSummary,
        conversationID: String = "",
        outcome: Outcome = .completed,
        failureMessage: String? = nil
    ) {
        self.conversationTitle = conversationTitle
        self.summary = summary
        self.conversationID = conversationID
        self.outcome = outcome
        self.failureMessage = failureMessage
    }
}

/// A run in some chat is blocked on the user (approval, question, download).
public struct RunAttentionEvent: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case approval, question, visionInstall
    }

    public let conversationID: String
    public let conversationTitle: String
    public let kind: Kind
    public let detail: String
}

public enum AgentPermissionMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case ask
    case safe
    case full

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .ask: return AppCopy.text("permission.ask")
        case .safe: return AppCopy.text("permission.safe")
        case .full: return AppCopy.text("permission.full")
        }
    }

    public var detail: String {
        switch self {
        case .ask: return AppCopy.text("permission.askDetail")
        case .safe: return AppCopy.text("permission.safeDetail")
        case .full: return AppCopy.text("permission.fullDetail")
        }
    }

    public var icon: String {
        switch self {
        case .ask: return "hand.raised"
        case .safe: return "checkmark.shield"
        case .full: return "shield"
        }
    }
}

public struct PendingApproval: Sendable, Equatable, Identifiable {
    public let conversationID: String
    public let toolCallID: String
    public let toolName: String
    public let reason: String

    public var id: String { toolCallID }

    public init(conversationID: String, toolCallID: String, toolName: String, reason: String) {
        self.conversationID = conversationID
        self.toolCallID = toolCallID
        self.toolName = toolName
        self.reason = reason
    }
}

public struct PendingVisionInstall: Sendable, Equatable, Identifiable {
    public let conversationID: String
    public let provider: String
    public let model: String
    public let modelBytes: Int64
    public let reason: String

    public var id: String { conversationID }

    public init(conversationID: String, provider: String, model: String, modelBytes: Int64, reason: String) {
        self.conversationID = conversationID
        self.provider = provider
        self.model = model
        self.modelBytes = modelBytes
        self.reason = reason
    }
}


/// Which conversation's run the current task belongs to. Set for a run's whole task
/// tree, so run code reads and writes its own state while other chats also run.
enum AgentRunScope {
    @TaskLocal static var conversationID: String?
}

/// Per-conversation run state: several conversations can run at once.
@MainActor
@Observable
final class AgentRunState {
    /// Called when `isBusy` flips, so the host's cross-run summaries (`anyRunBusy`, the
    /// sidebar's running set) know to refresh.
    @ObservationIgnored var onBusyChange: (() -> Void)?
    var isBusy: Bool = false {
        didSet { if oldValue != isBusy { onBusyChange?() } }
    }
    var pendingApproval: PendingApproval? = nil
    var pendingVisionInstall: PendingVisionInstall? = nil
    var pendingQuestion: PendingQuestion? = nil
    @ObservationIgnored var approvalContinuation: CheckedContinuation<Bool, Never>? = nil
    @ObservationIgnored var visionInstallContinuation: CheckedContinuation<Bool, Never>? = nil
    @ObservationIgnored var questionContinuation: CheckedContinuation<[String]?, Never>? = nil
    var askUserRounds: Int = 0
    var askedQuestionKeys: Set<String> = []
    @ObservationIgnored var activeTask: Task<Void, Never>? = nil
    var activeConversationID: String? = nil
    var activeRunID: UUID = UUID()
    var activeTurnID: String? = nil
    var activeContext: [AgentMessage] = []
    var queuePausedAfterStop: Bool = false
    var activeStopEventRecorded: Bool = false
    var continuationQueued: Bool = false
    var activeProvider: String = ""
    var activeModel: String = ""
    var activeStopEventID: String? = nil
    var activeUsedSkills: [String] = []
    var activeUsedTools: [String] = []
    var activeRunChangedFiles: [ChangedFile] = []
    var activeRunLastTurnID: String = ""
    var activeRunTrackingStatus: String = "complete"
    var activeRunCleanupStatus: String = "not_applicable"
    var activeRunTestStatus: String = "not_reported"
    var activeRunPlanMode: Bool = false
    var activeVerifiedRemovals: Int = 0
    var activeTurnWrittenPaths: Set<String> = []
    var activeTurnAttributionKnown: Bool = true
    var activePreservedRemoval: Bool = false
    var activeUnverifiedDeletion: Bool = false
    var activeCleanupFailure: Bool = false
    var activeChatRoots: [ChatContextRoot] = []
    var activeChatRootsBound = false
    var activeChatScopeID: String? = nil
    var activeChatScopeIDBound = false
}

@MainActor
@Observable
public final class NativeAgentHost {
    // Views observe this class per property (Observation), not as a whole: only what a view
    // reads invalidates it. State that is not a tracked stored property (the run table, the
    // stores behind the sidebar lists, workspace memory) announces changes through
    // `changeTick` / `accessRevision`, which the getters over that state read.
    @ObservationIgnored var runStates: [String: AgentRunState] = [:]
    @ObservationIgnored private let unboundRun = AgentRunState()
    private(set) var runTick = 0
    /// The sidebar lists come from the conversation store, not from tracked properties.
    var listTick = 0

    /// Tell readers of state held outside tracked properties that it changed.
    func touchRuns() { runTick &+= 1 }
    func touchLists() { listTick &+= 1 }

    /// Inside a run's task: that run. Anywhere else (UI): the selected conversation's.
    private var currentRun: AgentRunState {
        // The run table is not tracked: a removed or replaced run must refresh its readers.
        _ = runTick
        guard let id = AgentRunScope.conversationID ?? selectedID else { return unboundRun }
        return state(for: id)
    }

    func state(for conversationID: String) -> AgentRunState {
        if let run = runStates[conversationID] { return run }
        let run = AgentRunState()
        run.onBusyChange = { [weak self] in self?.touchRuns() }
        runStates[conversationID] = run
        return run
    }

    /// True while any conversation of this host is running, visible or not.
    public var anyRunBusy: Bool {
        _ = runTick
        return runStates.values.contains(where: \.isBusy) || unboundRun.isBusy
    }

    /// Conversations with a run in flight, for per-row activity in the sidebar.
    public var runningConversationIDs: Set<String> {
        _ = runTick
        return Set(runStates.filter { $0.value.isBusy }.map(\.key))
    }

    public let area: AgentArea
    public private(set) var connection: AgentConnection?
    /// False until the saved provider route is first resolved, so the UI does not
    /// flash "connect a provider" for users who already connected one.
    public private(set) var connectionResolved = false
    public internal(set) var conversations: [Conversation] = []
    public var selectedID: String?
    public internal(set) var status: String = AppCopy.text("agent.chooseWorkspace")
    public internal(set) var isBusy: Bool {
        get { currentRun.isBusy }
        set {
            currentRun.isBusy = newValue
        }
    }
    public internal(set) var historyMutationBusy = false
    public private(set) var accessRevision = 0
    public private(set) var permissionMode: AgentPermissionMode
    public private(set) var browserBackendSetting: BrowserBackend?
    public internal(set) var pendingApproval: PendingApproval? {
        get { currentRun.pendingApproval }
        set {
            currentRun.pendingApproval = newValue
        }
    }
    public internal(set) var pendingVisionInstall: PendingVisionInstall? {
        get { currentRun.pendingVisionInstall }
        set {
            currentRun.pendingVisionInstall = newValue
        }
    }
    public internal(set) var pendingQuestion: PendingQuestion? {
        get { currentRun.pendingQuestion }
        set {
            currentRun.pendingQuestion = newValue
        }
    }
    public internal(set) var followUpSuggestion: String?
    public internal(set) var followUpConversationID: String?
    @ObservationIgnored public var onAssistantResponse: ((AssistantResponseEvent) -> Void)?
    @ObservationIgnored public var onRunSummary: ((RunSummaryEvent) -> Void)?
    /// A run needs the user; fired so a chat running in the background can be noticed.
    @ObservationIgnored public var onAttentionNeeded: ((RunAttentionEvent) -> Void)?
    @ObservationIgnored public var onRemoteEvent: ((String, [String: String]) -> Void)?
    /// Set by the app: called after `install_plugin` writes a plugin so the host
    /// re-mounts and the new plugin goes live without a restart. Nil in tests.
    @ObservationIgnored public var onPluginsChanged: (() -> Void)?

    let store: ConversationStore
    let paths: SupportPaths
    let memory: WorkspaceMemory
    var feedbackStore: FeedbackStore?
    private let endpoint: AgentEndpointController
    let router: RouterController?
    let skillCatalog: SkillCatalog
    let skillSuggestionMonitor: SkillSuggestionMonitor?
    let pluginHost: PluginHost?
    let browserSessions = BrowserSessionManager()
    let chatContextStore: ChatContextStore?
    @ObservationIgnored lazy var contextTelemetry = AgentContextTelemetryStore(paths: paths)
    /// Set by the app after construction; nil in headless/test contexts.
    public var mcpRegistry: MCPRegistry?
    /// Long-lived shells the agent opened, keyed by conversation id. A run can
    /// only see and control the sessions its own conversation started.
    var agentTerminals: [String: [TerminalSession]] = [:]
    let nonInteractive: Bool
    /// Scheduled runs may opt into network commands after their sandbox policy
    /// has explicitly enabled network access. Ordinary runs keep the approval gate.
    let automaticNetworkAccess: Bool
    var workspaceURL: URL?
    public private(set) var sandboxPolicy: SandboxExecutionPolicy?
    public private(set) var sandboxBranch: String?
    /// Set while the work location is another machine: tool calls run there
    /// over SSH instead of on this disk.
    public private(set) var remoteTarget: SSHTarget?
    public private(set) var searchFolders: [URL] = []
    var additionalSystemPrompt = ""
    /// Compatibility seam for older headless callers. The app's two runtimes
    /// select behavior from `area`; this value is only a prompt-test override.
    var assistantMode: AssistantMode
    /// A run keeps the Chat roots it started with; switching the visible chat
    /// must not re-root a background run's tools.
    private var uiActiveChatRoots: [ChatContextRoot] = []
    var activeChatRoots: [ChatContextRoot] {
        get {
            if let id = AgentRunScope.conversationID, let run = runStates[id], run.activeChatRootsBound { return run.activeChatRoots }
            return uiActiveChatRoots
        }
        set {
            if let id = AgentRunScope.conversationID {
                let run = state(for: id)
                run.activeChatRoots = newValue
                run.activeChatRootsBound = true
                if id == selectedID { uiActiveChatRoots = newValue }
            } else {
                uiActiveChatRoots = newValue
            }
        }
    }
    /// A run keeps the Chat roots it started with; switching the visible chat
    /// must not re-root a background run's tools.
    private var uiActiveChatScopeID: String? = nil
    var activeChatScopeID: String? {
        get {
            if let id = AgentRunScope.conversationID, let run = runStates[id], run.activeChatScopeIDBound { return run.activeChatScopeID }
            return uiActiveChatScopeID
        }
        set {
            if let id = AgentRunScope.conversationID {
                let run = state(for: id)
                run.activeChatScopeID = newValue
                run.activeChatScopeIDBound = true
                if id == selectedID { uiActiveChatScopeID = newValue }
            } else {
                uiActiveChatScopeID = newValue
            }
        }
    }
    /// On by default: the agent runs its own build/test/check after a change
    /// instead of reporting it unverified. The user turns it off in Settings.
    public var selfVerification = true
    /// Create AGENTS.md/CLAUDE.md when a workspace ships neither. User setting.
    public var seedProjectRules = true
    var approvalContinuation: CheckedContinuation<Bool, Never>? {
        get { currentRun.approvalContinuation }
        set {
            currentRun.approvalContinuation = newValue
        }
    }
    var visionInstallContinuation: CheckedContinuation<Bool, Never>? {
        get { currentRun.visionInstallContinuation }
        set {
            currentRun.visionInstallContinuation = newValue
        }
    }
    var questionContinuation: CheckedContinuation<[String]?, Never>? {
        get { currentRun.questionContinuation }
        set {
            currentRun.questionContinuation = newValue
        }
    }
    /// Follow-up rounds are allowed; the budget and the asked set keep plan mode from looping.
    var askUserRounds: Int {
        get { currentRun.askUserRounds }
        set {
            currentRun.askUserRounds = newValue
        }
    }
    var askedQuestionKeys: Set<String> {
        get { currentRun.askedQuestionKeys }
        set {
            currentRun.askedQuestionKeys = newValue
        }
    }

    public var selected: Conversation? {
        conversations.first { $0.id == selectedID }
    }

    @ObservationIgnored private var outsideProjectsCache: (revision: Int, known: Set<String>, result: [Conversation])?
    @ObservationIgnored var contentTask: Task<Void, Never>?
    @ObservationIgnored var loadGeneration = 0

    // Sidebar lists read headers only: titles and metadata, never every project's transcripts.
    public var projectlessConversations: [Conversation] {
        _ = listTick
        return store.loadHeaders(workspacePath: nil).map(Self.recoverListed)
    }

    /// Chats that no listed project owns: the ones that never had a workspace
    /// plus the ones whose project was removed from the sidebar without their
    /// chats being deleted.
    /// Chats stored for one project, read through the store's cache so the
    /// sidebar's project preview does not re-decode the file on every hover.
    public func conversations(inProject path: String) -> [Conversation] {
        _ = listTick
        let wanted = ConversationStore.normalizedPath(path)
        return store.loadHeaders().filter { ConversationStore.normalizedPath($0.cwd) == wanted }
    }

    public func conversations(outsideProjects paths: [String]) -> [Conversation] {
        _ = listTick
        let known = Set(paths.compactMap(ConversationStore.normalizedPath))
        let all = store.loadHeaders()
        let revision = store.revision
        // The sidebar asks for this on every redraw, hover included. Recovering
        // each chat is not cheap, so the answer is kept until the store changes.
        if let cached = outsideProjectsCache, cached.revision == revision, cached.known == known {
            return cached.result
        }
        let result = all
            .filter { conversation in
                guard let cwd = ConversationStore.normalizedPath(conversation.cwd) else { return true }
                return !known.contains(cwd)
            }
            // `recover` only, not `recoverForContext`: this list is drawn on every
            // sidebar redraw and rebuilding agent context per chat is far too slow.
            .map(Self.recoverListed)
        outsideProjectsCache = (revision, known, result)
        return result
    }

    public var archivedConversations: [Conversation] {
        _ = listTick
        let archived = conversations.filter(\.archived)
        guard workspaceURL != nil else { return archived }
        return archived + store.loadHeaders(workspacePath: nil)
            .filter(\.archived)
            .map(Self.recoverListed)
    }

    /// Sidebar search also matches transcript text; headers carry none, so their
    /// content is read on demand (the full decode is cached by the store).
    public func contentMatches(_ conversation: Conversation, query: String) -> Bool {
        let messages = conversation.contentLoaded
            ? conversation.messages
            : store.loadAll().first { $0.id == conversation.id }?.messages ?? []
        return messages.contains { $0.text.localizedCaseInsensitiveContains(query) }
    }

    public var workspacePath: String? { workspaceURL?.path }
    public var workspaceAccess: WorkspaceAccessStatus {
        _ = accessRevision
        return memory.accessStatus()
    }
    public var memoryDevicePublicKey: String? {
        _ = accessRevision
        return memory.actorPublicKey
    }
    public var workspaceMembers: [[String: String]] {
        _ = accessRevision
        return memory.memberSummaries()
    }
    public var pendingWorkspaceDecisions: [[String: Any]] {
        _ = accessRevision
        return memory.pendingDecisions()
    }
    /// Obsidian-style `.mem` vault (notes + link graph) for the Memory settings view.
    public var memoryVault: MemoryVault {
        _ = accessRevision
        return memory.vault()
    }
    public var memoryFolderURL: URL? {
        _ = accessRevision
        return memory.memoryDirectory
    }
    public var memoryReady: Bool {
        _ = accessRevision
        return memory.accessStatus().memoryReady
    }
    // A busy agent can still accept a normal queued prompt or a steering prompt.
    public var isReady: Bool { connection != nil }
    public var canContinue: Bool { selected?.canContinue == true && !isBusy && !continuationQueued }
    public var activeRunStartedAt: Date? { activeConversationID == selectedID ? selected?.runStartedAt : nil }
    public var activeUsedSkillIDs: [String] { activeUsedSkills }

    public init(
        paths: SupportPaths,
        endpoint: AgentEndpointController,
        skills: SkillCatalog? = nil,
        permissionMode: AgentPermissionMode = .ask,
        nonInteractive: Bool = false,
        automaticNetworkAccess: Bool = false,
        pluginHost: PluginHost? = nil,
        skillSuggestions: SkillSuggestionMonitor? = nil,
        area: AgentArea = .coding,
        sessionFileName: String = "sessions.json",
        chatContextStore: ChatContextStore? = nil
    ) {
        self.area = area
        self.assistantMode = area == .chat ? .chat : .coding
        self.paths = paths
        self.store = ConversationStore(paths: paths, fileName: sessionFileName, area: area)
        self.memory = WorkspaceMemory(paths: paths)
        self.endpoint = endpoint
        self.router = nil
        let effectiveSkills = area == .chat ? SkillCatalog(paths: paths) : (skills ?? SkillCatalog(paths: paths))
        self.skillCatalog = effectiveSkills
        self.skillSuggestionMonitor = area == .chat
            ? SkillSuggestionMonitor(paths: paths, skills: effectiveSkills)
            : skillSuggestions
        self.pluginHost = pluginHost
        self.chatContextStore = chatContextStore ?? (area == .chat ? ChatContextStore(paths: paths) : nil)
        self.permissionMode = permissionMode
        self.browserBackendSetting = nil
        self.nonInteractive = nonInteractive
        self.automaticNetworkAccess = automaticNetworkAccess
    }

    public init(
        paths: SupportPaths,
        router: RouterController,
        skills: SkillCatalog? = nil,
        permissionMode: AgentPermissionMode = .ask,
        nonInteractive: Bool = false,
        automaticNetworkAccess: Bool = false,
        pluginHost: PluginHost? = nil,
        skillSuggestions: SkillSuggestionMonitor? = nil,
        area: AgentArea = .coding,
        sessionFileName: String = "sessions.json",
        chatContextStore: ChatContextStore? = nil
    ) {
        self.area = area
        self.assistantMode = area == .chat ? .chat : .coding
        self.paths = paths
        self.store = ConversationStore(paths: paths, fileName: sessionFileName, area: area)
        self.memory = WorkspaceMemory(paths: paths)
        self.endpoint = AgentEndpointController()
        self.router = router
        let effectiveSkills = area == .chat ? SkillCatalog(paths: paths) : (skills ?? SkillCatalog(paths: paths))
        self.skillCatalog = effectiveSkills
        self.skillSuggestionMonitor = area == .chat
            ? SkillSuggestionMonitor(paths: paths, skills: effectiveSkills)
            : skillSuggestions
        self.pluginHost = pluginHost
        self.chatContextStore = chatContextStore ?? (area == .chat ? ChatContextStore(paths: paths) : nil)
        self.permissionMode = permissionMode
        self.browserBackendSetting = nil
        self.nonInteractive = nonInteractive
        self.automaticNetworkAccess = automaticNetworkAccess
    }

    public init(
        paths: SupportPaths,
        endpoint: AgentEndpointController,
        router: RouterController,
        skills: SkillCatalog? = nil,
        permissionMode: AgentPermissionMode = .ask,
        nonInteractive: Bool = false,
        automaticNetworkAccess: Bool = false,
        pluginHost: PluginHost? = nil,
        skillSuggestions: SkillSuggestionMonitor? = nil,
        area: AgentArea = .coding,
        sessionFileName: String = "sessions.json",
        chatContextStore: ChatContextStore? = nil
    ) {
        self.area = area
        self.assistantMode = area == .chat ? .chat : .coding
        self.paths = paths
        self.store = ConversationStore(paths: paths, fileName: sessionFileName, area: area)
        self.memory = WorkspaceMemory(paths: paths)
        self.endpoint = endpoint
        self.router = router
        let effectiveSkills = area == .chat ? SkillCatalog(paths: paths) : (skills ?? SkillCatalog(paths: paths))
        self.skillCatalog = effectiveSkills
        self.skillSuggestionMonitor = area == .chat
            ? SkillSuggestionMonitor(paths: paths, skills: effectiveSkills)
            : skillSuggestions
        self.pluginHost = pluginHost
        self.chatContextStore = chatContextStore ?? (area == .chat ? ChatContextStore(paths: paths) : nil)
        self.permissionMode = permissionMode
        self.browserBackendSetting = nil
        self.nonInteractive = nonInteractive
        self.automaticNetworkAccess = automaticNetworkAccess
    }

    var activeTask: Task<Void, Never>? {
        get { currentRun.activeTask }
        set {
            currentRun.activeTask = newValue
        }
    }
    var followUpTask: Task<Void, Never>?
    var feedbackEvaluationTasks: [String: Task<Void, Never>] = [:]
    var feedbackEvaluationTokens: [String: UUID] = [:]
    var followUpGenerationID = UUID()
    /// Chats where the user asked for `/compact` while a run was active; the
    /// run loop honors it before its next model request.
    var compactRequested: Set<String> = []
    var activeConversationID: String? {
        get { currentRun.activeConversationID }
        set {
            currentRun.activeConversationID = newValue
        }
    }
    var activeRunID: UUID {
        get { currentRun.activeRunID }
        set {
            currentRun.activeRunID = newValue
        }
    }
    var activeTurnID: String? {
        get { currentRun.activeTurnID }
        set {
            currentRun.activeTurnID = newValue
        }
    }
    /// The latest valid model context, including tool calls/results that have not
    /// yet become a final chat bubble. Steering resumes from this snapshot.
    var activeContext: [AgentMessage] {
        get { currentRun.activeContext }
        set {
            currentRun.activeContext = newValue
        }
    }
    var queuePausedAfterStop: Bool {
        get { currentRun.queuePausedAfterStop }
        set {
            currentRun.queuePausedAfterStop = newValue
        }
    }
    var activeStopEventRecorded: Bool {
        get { currentRun.activeStopEventRecorded }
        set {
            currentRun.activeStopEventRecorded = newValue
        }
    }
    var continuationQueued: Bool {
        get { currentRun.continuationQueued }
        set {
            currentRun.continuationQueued = newValue
        }
    }
    var activeProvider: String {
        get { currentRun.activeProvider }
        set {
            currentRun.activeProvider = newValue
        }
    }
    var activeModel: String {
        get { currentRun.activeModel }
        set {
            currentRun.activeModel = newValue
        }
    }
    var activeStopEventID: String? {
        get { currentRun.activeStopEventID }
        set {
            currentRun.activeStopEventID = newValue
        }
    }
    var activeUsedSkills: [String] {
        get { currentRun.activeUsedSkills }
        set {
            currentRun.activeUsedSkills = newValue
        }
    }
    var activeUsedTools: [String] {
        get { currentRun.activeUsedTools }
        set {
            currentRun.activeUsedTools = newValue
        }
    }
    var completedTurnMetadata: [String: (skills: [String], tools: [String])] = [:]
    var completedTurnSummaries: [String: WorkspaceRunSummary] = [:]
    var activeRunChangedFiles: [ChangedFile] {
        get { currentRun.activeRunChangedFiles }
        set {
            currentRun.activeRunChangedFiles = newValue
        }
    }
    var activeRunLastTurnID: String {
        get { currentRun.activeRunLastTurnID }
        set {
            currentRun.activeRunLastTurnID = newValue
        }
    }
    var activeRunTrackingStatus: String {
        get { currentRun.activeRunTrackingStatus }
        set {
            currentRun.activeRunTrackingStatus = newValue
        }
    }
    var activeRunCleanupStatus: String {
        get { currentRun.activeRunCleanupStatus }
        set {
            currentRun.activeRunCleanupStatus = newValue
        }
    }
    var activeRunTestStatus: String {
        get { currentRun.activeRunTestStatus }
        set {
            currentRun.activeRunTestStatus = newValue
        }
    }
    // A runaway guard, not a working budget: token cost is bounded by tool-result
    // size and compaction, so cutting a run short only wastes what it already spent.
    static let maxToolSteps = 100

    struct ContextCompactionOutcome {
        let messages: [AgentMessage]
        let strategy: AgentCompactionStrategy
        let contextTokensBefore: Int
        let contextTokensAfter: Int
    }

    /// Identical call repeated this many times means the loop stopped making progress.
    static let maxIdenticalToolCalls = 3
    /// Last provider-failover notice shown, so one switch is reported once.
    var lastFailoverNotice: String?
    var limitResumeTask: Task<Void, Never>?
    /// A reset further out than this is not worth holding a timer for; the user will
    /// have come back long before it fires.
    static let maxLimitResumeDelay: TimeInterval = 6 * 60 * 60
    static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()
    var activeRunPlanMode: Bool {
        get { currentRun.activeRunPlanMode }
        set {
            currentRun.activeRunPlanMode = newValue
        }
    }
    var activeVerifiedRemovals: Int {
        get { currentRun.activeVerifiedRemovals }
        set {
            currentRun.activeVerifiedRemovals = newValue
        }
    }
    /// Workspace-relative paths this turn wrote through write_file/remove_file.
    /// Anything else the snapshot reports as changed came from outside this turn.
    var activeTurnWrittenPaths: Set<String> {
        get { currentRun.activeTurnWrittenPaths }
        set {
            currentRun.activeTurnWrittenPaths = newValue
        }
    }
    /// A command, plugin, or MCP tool can touch files no argument names, so a
    /// turn that ran one cannot attribute the rest of the diff to another chat.
    var activeTurnAttributionKnown: Bool {
        get { currentRun.activeTurnAttributionKnown }
        set {
            currentRun.activeTurnAttributionKnown = newValue
        }
    }
    /// Files that changed during a recent turn here without this chat writing
    /// them - another chat or an external editor did. Surfaced to the next turn.
    var concurrentChanges: [ChangedFile] = []
    var activePreservedRemoval: Bool {
        get { currentRun.activePreservedRemoval }
        set {
            currentRun.activePreservedRemoval = newValue
        }
    }
    var activeUnverifiedDeletion: Bool {
        get { currentRun.activeUnverifiedDeletion }
        set {
            currentRun.activeUnverifiedDeletion = newValue
        }
    }
    var activeCleanupFailure: Bool {
        get { currentRun.activeCleanupFailure }
        set {
            currentRun.activeCleanupFailure = newValue
        }
    }

    public var skills: SkillCatalog { skillCatalog }
    public var skillSuggestions: SkillSuggestionMonitor? { skillSuggestionMonitor }
    public var chatContextRoots: [ChatContextRoot] { activeChatRoots }

    public func start(workspacePath: String) {
        setWorkspace(area == .chat ? "" : workspacePath)
        if workspaceURL == nil {
            status = area == .chat ? AppCopy.text("agent.configureEndpoint") : AppCopy.text("agent.chooseWorkspaceToStart")
        }
    }

    public func updateSystemPrompt(_ prompt: String) {
        additionalSystemPrompt = prompt
    }

    public func setAssistantMode(_ mode: AssistantMode) {
        assistantMode = mode
    }

    public func setSearchFolders(_ paths: [String]) {
        searchFolders = paths.compactMap { value in
            let url = SandboxProfile.canonicalURL(URL(fileURLWithPath: value, isDirectory: true))
            var isDirectory = ObjCBool(false)
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue,
                  !url.path.split(separator: "/").contains(".mem") else { return nil }
            return url
        }
    }

    public func setSelfVerification(_ enabled: Bool) {
        selfVerification = enabled
    }

    public func setSeedProjectRules(_ enabled: Bool) {
        seedProjectRules = enabled
    }

    /// Points the tool layer at a remote host, or back at this machine.
    ///
    /// Remote and sandbox worktree are mutually exclusive: the sandbox jails
    /// local processes, and there are none to jail when the work happens on
    /// another machine.
    public func setRemoteTarget(_ target: SSHTarget?) {
        remoteTarget = target
        guard target != nil else { return }
        sandboxPolicy = nil
        sandboxBranch = nil
        DeclarativeShell.activeSandbox = nil
        mcpRegistry?.setSandboxPolicy(nil)
    }

    /// Where a tool call runs right now.
    public var executionTarget: ExecutionTarget {
        remoteTarget.map(ExecutionTarget.remote) ?? .local(sandboxPolicy)
    }

    public func setSandboxPolicy(_ policy: SandboxExecutionPolicy?, branch: String? = nil) {
        guard remoteTarget == nil else {
            sandboxPolicy = nil
            sandboxBranch = nil
            DeclarativeShell.activeSandbox = nil
            mcpRegistry?.setSandboxPolicy(nil)
            return
        }
        guard let policy else {
            sandboxPolicy = nil
            sandboxBranch = nil
            DeclarativeShell.activeSandbox = nil
            mcpRegistry?.setSandboxPolicy(nil)
            return
        }
        guard let workspaceURL,
              SandboxProfile.canonicalURL(workspaceURL).path == policy.workspaceURL.path else {
            sandboxPolicy = nil
            sandboxBranch = nil
            DeclarativeShell.activeSandbox = nil
            mcpRegistry?.setSandboxPolicy(nil)
            return
        }
        sandboxPolicy = policy
        sandboxBranch = branch
        mcpRegistry?.setSandboxPolicy(policy)
        // A plugin's `shell` action is `run_command` in disguise — one of the
        // few paths, along with MCP stdio servers (see MCPRegistry), that
        // launch a process outside WorkspaceTools. It must land in the same
        // jail or a sandboxed agent can reach it as an escape hatch.
        DeclarativeShell.activeSandbox = (try? SandboxProfile.launchPrefix(policy: policy)).map { prefix in
            ShellSandbox(
                executableURL: SandboxProfile.executableURL,
                argumentsPrefix: prefix,
                workspaceURL: policy.workspaceURL,
                environment: SandboxProfile.cacheEnvironment(workspaceURL: policy.workspaceURL)
            )
        }
    }

    public func setPermissionMode(_ mode: AgentPermissionMode) {
        permissionMode = mode
    }

    public func setBrowserBackend(_ backend: BrowserBackend?) {
        browserBackendSetting = backend == .unknown ? nil : backend
    }

    public func answerApproval(_ answer: String) {
        finishApproval(answer == "allowed-once")
    }

    public func answerVisionInstall(_ allow: Bool) {
        finishVisionInstall(allow)
    }

    public func answerQuestions(_ answers: [String]) {
        finishQuestion(answers)
    }

    public func cancelQuestions() {
        finishQuestion(nil)
    }

    func clearFollowUpSuggestion() {
        followUpTask?.cancel()
        followUpTask = nil
        followUpGenerationID = UUID()
        followUpSuggestion = nil
        followUpConversationID = nil
    }

    public func createWorkspaceInvite(
        displayName: String,
        role: MemoryRole,
        score: Int,
        publicKey: String
    ) throws -> String {
        let token = try memory.createInvite(displayName: displayName, role: role, score: score, publicKey: publicKey)
        accessRevision += 1
        return token
    }

    public func acceptWorkspaceInvite(_ token: String) throws {
        try memory.acceptInvite(token)
        accessRevision += 1
    }

    public func revokeWorkspaceDevice(_ deviceID: String) throws {
        try memory.revoke(deviceID: deviceID)
        accessRevision += 1
    }

    public func resolveWorkspaceDecision(_ eventID: String, accept: Bool) throws {
        try memory.resolveDecision(eventID: eventID, accept: accept)
        accessRevision += 1
    }

    public func refreshConnection() async {
        // Every @Published write re-renders the whole window, even with an equal value:
        // only publish what changed.
        func publish(_ connection: AgentConnection?, _ status: String) {
            if self.connection != connection { self.connection = connection }
            if self.status != status { self.status = status }
            if !connectionResolved { connectionResolved = true }
        }
        guard let configuration = await currentConfiguration(loadCredentials: false) else {
            return publish(nil, AppCopy.text("agent.configureEndpoint"))
        }
        guard let endpoint = URL(string: configuration.baseURL) else {
            return publish(nil, AppCopy.text("agent.invalidEndpoint"))
        }
        publish(
            AgentConnection(endpoint: endpoint, provider: configuration.provider, model: configuration.model),
            AppCopy.format("agent.ready", configuration.model)
        )
    }

    func currentConfiguration(model: String? = nil, loadCredentials: Bool = true) async -> AgentConfiguration? {
        if let configuration = endpoint.configuration {
            return configuration
        }
        guard let router else { return nil }
        if loadCredentials { await router.refreshModelsIfNeeded() }
        return await router.agentConfiguration(model: model, loadCredentials: loadCredentials)
    }

    public func synthesizeSpeech(_ text: String) async throws -> URL {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { throw NativeAgentError(AppCopy.text("media.promptMissing")) }

        let route: (configuration: AgentConfiguration, provider: ProviderMediaSpec)?
        if let configuration = await currentConfiguration(),
           let provider = ProviderRegistry.shared.spec(configuration.specID)?.media?.spec(for: .audio) {
            route = (configuration, provider)
        } else {
            route = await router?.mediaConfiguration(for: .audio)
        }
        guard let route else {
            throw NativeAgentError(AppCopy.format("media.unsupported", MediaKind.audio.displayName))
        }

        let media = try await MediaGenerationClient.generate(
            kind: .audio,
            prompt: prompt,
            configuration: route.configuration,
            provider: route.provider,
            paths: paths
        )
        return media.url
    }

    public func setWorkspace(_ path: String) {
        pauseRunsForWorkspaceChange()
        if isBusy, let conversationID = activeConversationID {
            let scope = BrowserScope(
                area: area.rawValue,
                conversationID: conversationID,
                runID: activeRunID.uuidString
            )
            // Changing workspaces invalidates the run's normal finalizer guard.
            // Close its owned browser session before changing activeRunID so a
            // workspace switch cannot orphan a managed Chrome process.
            Task { @MainActor [weak self] in
                _ = await self?.browserSessions.closeRun(scope: scope)
            }
        }
        let path = area == .chat ? "" : path
        sandboxPolicy = nil
        sandboxBranch = nil
        DeclarativeShell.activeSandbox = nil
        mcpRegistry?.setSandboxPolicy(nil)
        clearFollowUpSuggestion()
        finishApproval(false)
        finishVisionInstall(false)
        activeTask?.cancel()
        activeTask = nil
        feedbackEvaluationTasks.values.forEach { $0.cancel() }
        feedbackEvaluationTasks.removeAll()
        feedbackEvaluationTokens.removeAll()
        feedbackStore = nil
        activeConversationID = nil
        activeRunID = UUID()
        activeTurnID = nil
        activeContext = []
        queuePausedAfterStop = false
        activeStopEventRecorded = false
        continuationQueued = false
        activeStopEventID = nil
        activeUsedSkills = []
        activeUsedTools = []
        activeChatRoots = []
        activeChatScopeID = nil
        resetRunEvidence(workspaceAvailable: false)
        isBusy = false
        historyMutationBusy = false
        let normalized = ConversationStore.normalizedPath(path)
        skillCatalog.setWorkspace(normalized)
        skillSuggestionMonitor?.setWorkspace(normalized)
        guard let normalized else {
            searchFolders = []
            memory.setWorkspace(nil)
            workspaceURL = nil
            loadConversations(workspacePath: nil)
            status = connection == nil ? AppCopy.text("agent.configureEndpoint") : status
            return
        }

        let url = URL(fileURLWithPath: normalized, isDirectory: true)
        guard FileManager.default.fileExists(atPath: url.path) else {
            searchFolders = []
            memory.setWorkspace(nil)
            workspaceURL = nil
            conversations = []
            selectedID = nil
            connection = nil
            status = AppCopy.text("agent.workspaceMissing")
            return
        }

        workspaceURL = url
        feedbackStore = FeedbackStore(workspaceURL: url)
        if let feedbackStore, !feedbackStore.records().isEmpty {
            // Repair a gold projection left behind by an interrupted previous
            // write before the next request reads project memory.
            Task.detached(priority: .background) {
                try? feedbackStore.rebuildGoldExamples()
            }
        }
        // Once per workspace open, before the first turn - not per message.
        if seedProjectRules {
            Task.detached(priority: .background) {
                ProjectRules.seedIfMissing(workspace: url)
            }
        }
        memory.setWorkspace(url)
        accessRevision += 1
        loadConversations(workspacePath: normalized)
        if selectedID == nil {
            newConversation()
        }
        status = connection == nil ? AppCopy.text("agent.chooseModel") : status
    }
}

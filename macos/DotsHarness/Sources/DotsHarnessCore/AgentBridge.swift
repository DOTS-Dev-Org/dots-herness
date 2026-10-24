// Copyright (c) 2026 DOTS
// Native agent host: conversation state, model loop, tools, and workspace memory.

import Foundation
import Network
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
    public let conversationID: String

    public init(conversationTitle: String, text: String, isPlan: Bool = false, conversationID: String = "") {
        self.conversationTitle = conversationTitle
        self.text = text
        self.isPlan = isPlan
        self.conversationID = conversationID
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

/// A run in some chat is blocked on the user (approval, question, download, conflict).
public struct RunAttentionEvent: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case approval, question, visionInstall, conflict
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
/// tree, so run code reads and writes its own state while other conversations also run.
enum AgentRunScope {
    @TaskLocal static var conversationID: String?
    /// Per-prompt subagent permission, captured when the prompt is submitted.
    @TaskLocal static var subagentsOverride: Bool?
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
    var pendingConflict: PendingConflict? = nil
    /// Effective subagent permission for this run, retained if the run pauses.
    var activeSubagentsOverride: Bool? = nil
    /// Set while this run waits for a lease another chat holds, so the sidebar can
    /// show that it is blocked rather than merely busy.
    var waitingOnLease: WorkspaceLeaseHolder? = nil
    @ObservationIgnored var approvalContinuation: CheckedContinuation<Bool, Never>? = nil
    @ObservationIgnored var visionInstallContinuation: CheckedContinuation<Bool, Never>? = nil
    @ObservationIgnored var questionContinuation: CheckedContinuation<[String]?, Never>? = nil
    @ObservationIgnored var conflictContinuation: CheckedContinuation<WorkspaceConflictChoice, Never>? = nil
    var askUserRounds: Int = 0
    var askedQuestionKeys: Set<String> = []
    @ObservationIgnored var activeTask: Task<Void, Never>? = nil
    var activeConversationID: String? = nil
    var activeRunID: UUID = UUID()
    var activeTurnID: String? = nil
    var activeContext: [AgentMessage] = []
    var queuePausedAfterStop: Bool = false
    /// One prompt may be waiting for provider configuration; keep that claim
    /// until it starts or is requeued so another submission cannot win the race.
    var pendingPromptStartID: String? = nil
    var activeStopEventRecorded: Bool = false
    var continuationQueued: Bool = false
    var activeProvider: String = ""
    var activeModel: String = ""
    var activeStopEventID: String? = nil
    var activeUsedSkills: [String] = []
    var activeUsedTools: [String] = []
    /// Newly processed input (excluding cache reads) plus output/reasoning for the live status line.
    var activeRunTokens: Int = 0
    /// True if any contribution to the live count used local estimates or lacked cache accounting.
    var activeRunTokenCountIncludesEstimate: Bool = false
    var activeRunChangedFiles: [ChangedFile] = []
    var activeRunLastTurnID: String = ""
    var activeRunTrackingStatus: String = "complete"
    var activeRunCleanupStatus: String = "not_applicable"
    var activeRunTestStatus: String = "not_reported"
    var activeRunPlanMode: Bool = false
    var activeVerifiedRemovals: Int = 0
    var activeTurnWrittenPaths: Set<String> = []
    var activeTurnAttributionKnown: Bool = true
    /// When this turn's opaque tools (commands, plugins, MCP, subagents) ran. `end` stays nil
    /// for one that keeps writing after its call returns.
    var activeTurnOpaqueWindows: [(start: Date, end: Date?)] = []
    var activePreservedRemoval: Bool = false
    var activeUnverifiedDeletion: Bool = false
    var activeCleanupFailure: Bool = false
}

@MainActor
@Observable
public final class NativeAgentHost {
    // Views observe this class per property (Observation), not as a whole: only what a view
    // reads invalidates it. State that is not a tracked stored property (the run table, the
    // stores behind the sidebar lists, workspace memory) announces changes through
    // `changeTick` / `memoryRevision`, which the getters over that state read.
    @ObservationIgnored var runStates: [String: AgentRunState] = [:]
    @ObservationIgnored private let unboundRun = AgentRunState()
    @ObservationIgnored var planIntentClassifierOverride: ((String) async -> Bool)?
    private(set) var runTick = 0
    /// The sidebar lists come from the conversation store, not from tracked properties.
    var listTick = 0
    /// The reply a provider is still writing, per conversation. The finished
    /// message replaces it: any `append` to the conversation clears it.
    private(set) var liveReplies: [String: String] = [:]
    /// The reasoning written before the first word of the reply, so a model
    /// that thinks first does not leave the bubble empty. Gone once prose starts.
    private(set) var liveThinking: [String: String] = [:]
    @ObservationIgnored private var liveReplyBuffers: [String: (text: String, thinking: String, published: Date)] = [:]
    /// What `persist()` last wrote per conversation, and the store revision after it.
    @ObservationIgnored var persistedConversations: [String: Conversation] = [:]
    @ObservationIgnored var persistedRevision = -1
    @ObservationIgnored var persistScheduled = false

    func appendLiveReply(_ delta: NativeAgentClient.StreamDelta, in conversationID: String) {
        // Appended in place: a copy taken out of the dictionary made every delta copy the whole reply.
        switch delta {
        case .text(let text): liveReplyBuffers[conversationID, default: ("", "", .distantPast)].text += text
        case .thinking(let thinking): liveReplyBuffers[conversationID, default: ("", "", .distantPast)].thinking += thinking
        }
        // ponytail: published 10 times a second, and only for the chat on screen: every
        // publish re-renders the window, so background chats stream into the buffer alone.
        // The tail waits for the next delta, the final message or `selectionDidChange`.
        guard conversationID == selectedID,
              Date().timeIntervalSince(liveReplyBuffers[conversationID]!.published) >= 0.1 else { return }
        publishLiveReply(in: conversationID)
    }

    func publishLiveReply(in conversationID: String) {
        guard let buffer = liveReplyBuffers[conversationID] else { return }
        if buffer.text.isEmpty {
            if !buffer.thinking.isEmpty { liveThinking[conversationID] = buffer.thinking }
        } else {
            liveReplies[conversationID] = memory.visibleText(in: buffer.text, hidePartialMarkerTail: true)
            if liveThinking[conversationID] != nil { liveThinking[conversationID] = nil }
        }
        liveReplyBuffers[conversationID]?.published = Date()
    }

    func clearLiveReply(in conversationID: String) {
        liveReplyBuffers[conversationID] = nil
        if liveReplies[conversationID] != nil { liveReplies[conversationID] = nil }
        if liveThinking[conversationID] != nil { liveThinking[conversationID] = nil }
    }

    func replaceLiveReply(_ text: String, thinking: String? = nil, in conversationID: String) {
        let reasoning = thinking ?? ""
        liveReplyBuffers[conversationID] = (text, reasoning, Date())
        if text.isEmpty {
            liveReplies[conversationID] = nil
            liveThinking[conversationID] = reasoning.isEmpty ? nil : reasoning
        } else {
            liveReplies[conversationID] = memory.visibleText(in: text)
            liveThinking[conversationID] = nil
        }
    }

    func currentLiveReplyText(in conversationID: String) -> String? {
        liveReplyBuffers[conversationID]?.text ?? liveReplies[conversationID]
    }

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
        run.onBusyChange = { [weak self, weak run] in
            guard let self, let run else { return }
            self.touchRuns()
            guard !run.isBusy else { return }
            // Run finalization still writes its last message and summary after
            // clearing isBusy. Wait for that main-actor turn before releasing it.
            Task { @MainActor [weak self] in
                await Task.yield()
                self?.trimInactiveConversationContent()
            }
        }
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

    public private(set) var connection: AgentConnection?
    /// False until the saved provider route is first resolved, so the UI does not
    /// flash "connect a provider" for users who already connected one.
    public private(set) var connectionResolved = false
    public internal(set) var conversations: [Conversation] = []
    public var selectedID: String? {
        didSet {
            guard selectedID != oldValue else { return }
            if let selectedID {
                UserDefaults.standard.set(selectedID, forKey: Self.lastSelectedKey(workspaceURL?.path))
            }
            onSelectedConversationChanged?(selectedID)
            selectionDidChange(to: selectedID)
        }
    }

    static func lastSelectedKey(_ workspacePath: String?) -> String {
        "lastSelectedConversation." + (workspacePath.flatMap(ConversationStore.normalizedPath) ?? "none")
    }

    /// Last chat the user had open in this scope, else the first live one.
    func initialSelection() -> String? {
        let saved = UserDefaults.standard.string(forKey: Self.lastSelectedKey(workspaceURL?.path))
        return conversations.first(where: { $0.id == saved && !$0.archived })?.id
            ?? conversations.first(where: { !$0.archived })?.id
    }
    public internal(set) var status: String = AppCopy.text("agent.chooseWorkspace")
    public internal(set) var isBusy: Bool {
        get { currentRun.isBusy }
        set {
            currentRun.isBusy = newValue
        }
    }
    public internal(set) var historyMutationBusy = false
    public internal(set) var memoryRevision = 0
    public private(set) var permissionMode: AgentPermissionMode
    public private(set) var browserBackendSetting: BrowserBackend?
    public private(set) var isComputerUseEnabled: Bool = false
    public internal(set) var pendingApproval: PendingApproval? {
        get { currentRun.pendingApproval }
        set {
            currentRun.pendingApproval = newValue
            touchRuns()
        }
    }
    public internal(set) var pendingVisionInstall: PendingVisionInstall? {
        get { currentRun.pendingVisionInstall }
        set {
            currentRun.pendingVisionInstall = newValue
            touchRuns()
        }
    }
    public internal(set) var pendingQuestion: PendingQuestion? {
        get { currentRun.pendingQuestion }
        set {
            currentRun.pendingQuestion = newValue
            touchRuns()
        }
    }
    /// Questions are global UI interruptions, so they stay visible when another
    /// conversation is selected while a run is waiting for an answer.
    public var pendingQuestions: [PendingQuestion] {
        _ = runTick
        var questions = runStates.values.compactMap(\.pendingQuestion)
        if let question = unboundRun.pendingQuestion {
            questions.append(question)
        }
        return questions.sorted { $0.conversationID < $1.conversationID }
    }
    public internal(set) var pendingConflict: PendingConflict? {
        get { currentRun.pendingConflict }
        set {
            currentRun.pendingConflict = newValue
            touchRuns()
        }
    }
    /// The lease this run is blocked on, while it waits for another chat.
    public internal(set) var waitingOnLease: WorkspaceLeaseHolder? {
        get { currentRun.waitingOnLease }
        set {
            currentRun.waitingOnLease = newValue
            touchRuns()
        }
    }
    /// What a run does when another chat holds a write lease on the file it wants.
    public internal(set) var workspaceConflictPolicy: WorkspaceConflictPolicy = .waitThenAsk
    /// How long the `waitThenAsk` policy waits silently before it asks.
    public internal(set) var conflictWaitSeconds: Int = WorkspaceConflictPolicy.defaultWaitSeconds
    public internal(set) var followUpSuggestion: String?
    public internal(set) var followUpConversationID: String?
    @ObservationIgnored public var onAssistantResponse: ((AssistantResponseEvent) -> Void)?
    @ObservationIgnored var onSelectedConversationChanged: ((String?) -> Void)?
    @ObservationIgnored public var onRunSummary: ((RunSummaryEvent) -> Void)?
    /// A run needs the user; fired so a chat running in the background can be noticed.
    @ObservationIgnored public var onAttentionNeeded: ((RunAttentionEvent) -> Void)?
    /// A plan was approved automatically, so the composer's plan mode should end like a manual approval.
    @ObservationIgnored public var onPlanAutoApproved: (() -> Void)?
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
    @ObservationIgnored lazy var contextTelemetry = AgentContextTelemetryStore(paths: paths)
    /// Set by the app after construction; nil in headless/test contexts.
    public var mcpRegistry: MCPRegistry?
    /// Long-lived shells the agent opened, keyed by conversation id. A run can
    /// only see and control the sessions its own conversation started.
    var agentTerminals: [String: [TerminalSession]] = [:]
    /// Terminals the user opened in the dock. The agent may read them, never drive them.
    weak var userTerminalManager: TerminalManager?
    let nonInteractive: Bool
    /// Effort this host's runs ask for instead of the app's selection (a bot's own level).
    var effortOverride: String?
    /// Scheduled runs may opt into network commands after their sandbox policy
    /// has explicitly enabled network access. Ordinary runs keep the approval gate.
    let automaticNetworkAccess: Bool
    var workspaceURL: URL?
    /// The selected path even when the directory is missing. Nil means the
    /// user explicitly selected the No project scope.
    var requestedWorkspacePath: String?
    public private(set) var sandboxPolicy: SandboxExecutionPolicy?
    public private(set) var sandboxBranch: String?
    /// Set while the work location is another machine: tool calls run there
    /// over SSH instead of on this disk.
    public private(set) var remoteTarget: SSHTarget?
    public private(set) var searchFolders: [URL] = []
    var additionalSystemPrompt = ""
    /// On by default: the agent runs its own build/test/check after a change
    /// instead of reporting it unverified. The user turns it off in Settings.
    public var selfVerification = true
    /// Create AGENTS.md/CLAUDE.md when a workspace ships neither. User setting.
    public var seedProjectRules = true
    /// Apply a generated plan immediately through the normal approved-plan path.
    /// Tool-level approvals remain unchanged.
    public var autoApprovePlans = false
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
    var conflictContinuation: CheckedContinuation<WorkspaceConflictChoice, Never>? {
        get { currentRun.conflictContinuation }
        set {
            currentRun.conflictContinuation = newValue
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
    /// Conversations without an active project, read through the store's cache so
    /// the Recent preview does not re-decode every transcript.
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
                guard let cwd = ConversationStore.normalizedPath(conversation.cwd) else {
                    return conversation.projectless
                }
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
        return store.loadHeaders()
            .filter { $0.archived && !$0.blank }
            .map(Self.recoverListed)
            .sorted { $0.activityDate > $1.activityDate }
    }

    /// Sidebar search reads only the searched transcript; its content is released
    /// with the local value when this query finishes.
    public func contentMatches(_ conversation: Conversation, query: String) -> Bool {
        let messages = conversation.contentLoaded && conversation.transcriptComplete
            ? conversation.messages
            : store.loadTranscript(id: conversation.id) ?? []
        return messages.contains { $0.text.localizedCaseInsensitiveContains(query) }
    }

    public var workspacePath: String? { workspaceURL?.path }
    public var isNoProjectScope: Bool {
        guard requestedWorkspacePath == nil else { return false }
        return selected?.projectless == true
    }
    /// Obsidian-style `.mem` vault (notes + link graph) for the Memory settings view.
    public var memoryVault: MemoryVault {
        _ = memoryRevision
        return memory.vault()
    }
    public var memoryFolderURL: URL? {
        _ = memoryRevision
        return memory.memoryDirectory
    }
    /// This Mac's folder for the open project's private memory; never in the repository.
    public var userMemoryFolderURL: URL? {
        _ = memoryRevision
        return memory.userMemoryDirectory
    }
    public var memoryReady: Bool {
        _ = memoryRevision
        return memory.memoryReady
    }
    // A busy agent can still accept a normal queued prompt or a steering prompt.
    public var isReady: Bool { connection != nil }
    public var canContinue: Bool { selected?.canContinue == true && !isBusy && !continuationQueued }
    public var activeRunStartedAt: Date? { activeConversationID == selectedID ? selected?.runStartedAt : nil }
    public var activeUsedSkillIDs: [String] { activeUsedSkills }
    public var activeRunTokenCount: Int { activeConversationID == selectedID ? activeRunTokens : 0 }
    public var activeRunTokenCountIncludesEstimate: Bool {
        activeConversationID == selectedID && currentRun.activeRunTokenCountIncludesEstimate
    }

    public init(
        paths: SupportPaths,
        endpoint: AgentEndpointController = AgentEndpointController(),
        router: RouterController? = nil,
        skills: SkillCatalog? = nil,
        permissionMode: AgentPermissionMode = .ask,
        nonInteractive: Bool = false,
        automaticNetworkAccess: Bool = false,
        pluginHost: PluginHost? = nil,
        skillSuggestions: SkillSuggestionMonitor? = nil
    ) {
        self.paths = paths
        self.store = ConversationStore(paths: paths)
        self.memory = WorkspaceMemory(paths: paths)
        self.endpoint = endpoint
        self.router = router
        let effectiveSkills = skills ?? SkillCatalog(paths: paths)
        self.skillCatalog = effectiveSkills
        self.skillSuggestionMonitor = skillSuggestions
        self.pluginHost = pluginHost
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
    public internal(set) var memoryScanInterval = MemoryScanInterval.daily
    public internal(set) var memoryScanRunning = false
    var memoryScanLoop: Task<Void, Never>?
    var pendingPlanIntentTasks: [String: Task<Void, Never>] = [:]
    var feedbackEvaluationTokens: [String: UUID] = [:]
    /// Answers already examined for an implicit lesson in this session.
    var examinedSignals = Set<String>()
    /// Inferred lessons already put to the user in this session. Dismissal is persisted on the lesson.
    var askedLessonIDs = Set<String>()
    /// Conversation id to the file lessons already handed over in it.
    var deliveredFileLessons: [String: Set<String>] = [:]
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
    var activeRunTokens: Int {
        get { currentRun.activeRunTokens }
        set {
            currentRun.activeRunTokens = newValue
        }
    }
    var activeRunTokenCountHasEstimate: Bool {
        get { currentRun.activeRunTokenCountIncludesEstimate }
        set {
            currentRun.activeRunTokenCountIncludesEstimate = newValue
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
    // Allow a coding task to inspect, edit, reread and verify several files.
    // Repeated identical calls are still stopped independently.
    static let maxToolSteps = 128
    /// Sent once when the limit is reached, so the turn ends with what it found.
    static let toolStepLimitNotice = """
    [Tool step limit]
    This turn has used all of its tool steps. Do not call tools now. Answer from the evidence \
    already gathered: report the confirmed findings, then list what was left unchecked so the \
    user can ask to continue.
    """

    struct ContextCompactionOutcome {
        let messages: [AgentMessage]
        let strategy: AgentCompactionStrategy
        let contextTokensBefore: Int
        let contextTokensAfter: Int
        var trace: AgentCompactionTrace? = nil
    }

    /// Identical call repeated this many times means the loop stopped making progress.
    static let maxIdenticalToolCalls = 3
    /// Edits to one file in a turn past this suggest the model is rewriting the same region.
    static let maxEditsPerFile = 5
    static let editChurnNotice = "\n\n[Repeated edits] This file was edited %d times this turn. Reread it and the diff, confirm the change is not already present, and stop rewriting the same region."

    /// Key order and whitespace must not hide a repeated call.
    static func toolSignature(_ call: AgentToolCall) -> String {
        let object = arguments(of: call)
        guard !object.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: object, options: .sortedKeys),
              let text = String(data: data, encoding: .utf8) else { return call.name + "|" + call.arguments }
        return call.name + "|" + text
    }
    /// Ceiling on concurrent read-only workspace calls in one turn: disk scans
    /// compete with each other, so fanning out without a limit only adds latency.
    static let maxConcurrentReads = 8
    /// Last provider-failover notice shown, so one switch is reported once.
    var lastFailoverNotice: String?
    /// Conversations whose last turn moved to another account on the same model; shown above the composer.
    var accountSwitchedConversations: Set<String> = []
    /// Conversations whose history was just edited or rewound: the next turn starts cold on any account.
    var historyRewrittenConversations: Set<String> = []
    var limitResumeTask: Task<Void, Never>?
    @ObservationIgnored var networkMonitor: NWPathMonitor?
    @ObservationIgnored var networkSatisfied = true
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
    var activeTurnOpaqueWindows: [(start: Date, end: Date?)] {
        get { currentRun.activeTurnOpaqueWindows }
        set {
            currentRun.activeTurnOpaqueWindows = newValue
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

    public func start(workspacePath: String) {
        setWorkspace(workspacePath)
        if workspaceURL == nil, requestedWorkspacePath != nil {
            status = AppCopy.text("agent.chooseWorkspaceToStart")
        }
    }

    public func updateSystemPrompt(_ prompt: String) {
        additionalSystemPrompt = prompt
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

    public func setAutoApprovePlans(_ enabled: Bool) {
        autoApprovePlans = enabled
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

    public func setComputerUseEnabled(_ enabled: Bool) {
        isComputerUseEnabled = enabled
    }

    /// Answer outside a run task: `currentRun` would fall back to the selected
    /// conversation, so an approval raised by a background run would be resolved
    /// against the wrong run and dropped. Scope the answer to the owning run.
    private func resolving(_ conversationID: String?, _ resolve: () -> Void) {
        guard let conversationID else { return }
        AgentRunScope.$conversationID.withValue(conversationID) { resolve() }
    }

    public func answerApproval(_ answer: String, in conversationID: String? = nil) {
        resolving(conversationID ?? pendingApproval?.conversationID) { finishApproval(answer == "allowed-once") }
    }

    public func answerVisionInstall(_ allow: Bool) {
        resolving(pendingVisionInstall?.conversationID) { finishVisionInstall(allow) }
    }

    public func answerQuestions(_ answers: [String], in conversationID: String? = nil) {
        resolving(conversationID ?? pendingQuestion?.conversationID) { finishQuestion(answers) }
    }

    public func cancelQuestions(in conversationID: String? = nil) {
        resolving(conversationID ?? pendingQuestion?.conversationID) { finishQuestion(nil) }
    }

    func clearFollowUpSuggestion() {
        followUpTask?.cancel()
        followUpTask = nil
        followUpGenerationID = UUID()
        followUpSuggestion = nil
        followUpConversationID = nil
    }

    public func exportMemory(_ scope: MemoryTransferScope) throws -> Data {
        try memory.exportMemory(scope)
    }

    @discardableResult
    public func importMemory(_ data: Data, scope: MemoryTransferScope) throws -> Int {
        if scope == .project, memory.enabled { try memory.openProject() }
        let count = try memory.importMemory(data, scope: scope)
        memoryRevision += 1
        return count
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

    /// Called when the user reaches for the composer: by the time they send,
    /// the connection to the provider is already open.
    public func prewarmProvider() {
        Task { [weak self] in
            guard let baseURL = await self?.currentConfiguration(loadCredentials: false)?.baseURL else { return }
            await NativeAgentClient.prewarm(baseURL: baseURL)
        }
    }

    func currentConfiguration(model: String? = nil, loadCredentials: Bool = true) async -> AgentConfiguration? {
        if let configuration = endpoint.configuration {
            return configuration
        }
        guard let router else { return nil }
        if loadCredentials {
            // The cached catalog serves the send at once; the live listing refreshes behind it.
            // Waiting on it here held the first message of a session as if it were queued.
            if let configuration = await router.agentConfiguration(model: model) {
                Task { await router.refreshModelsIfNeeded() }
                return configuration
            }
            await router.refreshModelsIfNeeded()
        }
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
                scope: "project",
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
        deliveredFileLessons.removeAll()
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
        resetRunEvidence(workspaceAvailable: false)
        isBusy = false
        historyMutationBusy = false
        let normalized = ConversationStore.normalizedPath(path)
        requestedWorkspacePath = normalized
        let availableWorkspacePath = normalized.flatMap { candidate -> String? in
            var isDirectory = ObjCBool(false)
            return FileManager.default.fileExists(atPath: candidate, isDirectory: &isDirectory)
                && isDirectory.boolValue ? candidate : nil
        }
        skillCatalog.setWorkspace(availableWorkspacePath)
        skillSuggestionMonitor?.setWorkspace(availableWorkspacePath)
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
            // The path still identifies the project whose history is stored
            // locally. Keep those conversations readable while the folder is
            // missing; all execution entry points require a real workspace.
            loadConversations(workspacePath: normalized)
            connection = nil
            status = AppCopy.text("agent.workspaceMissing")
            return
        }

        workspaceURL = url
        memory.setWorkspace(url)
        // The newly opened project is tended at once instead of at the loop's next tick.
        if memoryScanLoop != nil { setMemoryScanInterval(memoryScanInterval) }
        syncFeedbackStore()
        if let feedbackStore {
            Task.detached(priority: .background) { feedbackStore.dropRawText() }
        }
        // Once per workspace open, before the first turn - not per message.
        if seedProjectRules {
            Task.detached(priority: .background) {
                ProjectRules.seedIfMissing(workspace: url)
            }
        }
        memoryRevision += 1
        loadConversations(workspacePath: normalized)
        if selectedID == nil {
            newConversation()
        }
        status = connection == nil ? AppCopy.text("agent.chooseModel") : status
    }
}

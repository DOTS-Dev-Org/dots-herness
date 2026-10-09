// Copyright (c) 2026 DOTS
// UI-facing compatibility facade for the native agent host.

import Foundation
import PluginRuntime

@MainActor
/// The host is `@Observable`, so a view reading through this facade observes exactly the
/// host properties it reads; the facade has no change notification of its own.
public final class AgentBridge {
    private let host: NativeAgentHost

    public var connection: AgentConnection? { host.connection }
    public var connectionResolved: Bool { host.connectionResolved }
    public func contentMatches(_ conversation: Conversation, query: String) -> Bool {
        host.contentMatches(conversation, query: query)
    }
    public var conversations: [Conversation] { host.conversations }
    public func conversations(inProject path: String) -> [Conversation] {
        host.conversations(inProject: path)
    }
    public func conversations(outsideProjects paths: [String]) -> [Conversation] {
        host.conversations(outsideProjects: paths)
    }
    public var archivedConversations: [Conversation] { host.archivedConversations }
    public func loadArchivedConversation(_ id: String) -> Conversation? { host.loadArchivedConversation(id) }
    public var selectedID: String? {
        get { host.selectedID }
        set { host.selectedID = newValue }
    }
    var onSelectedConversationChanged: ((String?) -> Void)? {
        get { host.onSelectedConversationChanged }
        set { host.onSelectedConversationChanged = newValue }
    }
    public var status: String { host.status }
    public var isBusy: Bool { host.isBusy }
    public var canContinue: Bool { host.canContinue }
    public var accessRevision: Int { host.accessRevision }
    public var selected: Conversation? { host.selected }
    public func feedback(for messageID: String, in conversationID: String) -> FeedbackRecord? {
        host.feedback(for: messageID, in: conversationID)
    }
    public func submitFeedback(
        conversationID: String,
        messageID: String,
        feedbackType: FeedbackType,
        tags: [String],
        userComment: String
    ) throws {
        try host.submitFeedback(
            conversationID: conversationID,
            messageID: messageID,
            feedbackType: feedbackType,
            tags: tags,
            userComment: userComment
        )
    }
    public var workspacePath: String? { host.workspacePath }
    public var searchFolders: [URL] { host.searchFolders }
    public var sandboxPolicy: SandboxExecutionPolicy? { host.sandboxPolicy }
    public var workspaceAccess: WorkspaceAccessStatus { host.workspaceAccess }
    public var memoryDevicePublicKey: String? { host.memoryDevicePublicKey }
    public var workspaceMembers: [[String: String]] { host.workspaceMembers }
    public var pendingWorkspaceDecisions: [[String: Any]] { host.pendingWorkspaceDecisions }
    public var memoryVault: MemoryVault { host.memoryVault }
    public var memoryFolderURL: URL? { host.memoryFolderURL }
    public var memoryReady: Bool { host.memoryReady }
    public var lessons: [Lesson] { host.lessons }
    public var manualRules: String { host.manualRules }
    public var learningStats: (turns: Int, corrected: Int, uses: [(record: String, count: Int)]) { host.learningStats }
    @discardableResult
    public func editMemory(_ edit: MemoryEdit) -> Bool { host.editMemory(edit) }
    func beforeContent(conversationID: String, turnID: String, path: String) -> Data? {
        host.memory.snapshotStore.beforeContent(conversationID: conversationID, turnID: turnID, path: path)
    }
    public func contextUsageEvents() -> [AgentContextUsageEvent] {
        host.contextUsageEvents()
    }
    public func accountSwitched(in conversationID: String?) -> Bool {
        conversationID.map(host.accountSwitchedConversations.contains) ?? false
    }
    public var isReady: Bool { host.isReady }
    public var historyMutationBusy: Bool { host.historyMutationBusy }
    public var permissionMode: AgentPermissionMode { host.permissionMode }
    public var browserBackendSetting: BrowserBackend? { host.browserBackendSetting }
    public var pendingApproval: PendingApproval? { host.pendingApproval }
    public var pendingVisionInstall: PendingVisionInstall? { host.pendingVisionInstall }
    public var pendingContextOverflow: PendingContextOverflow? { host.pendingContextOverflow }
    public var pendingQuestion: PendingQuestion? { host.pendingQuestion }
    public var pendingQuestions: [PendingQuestion] { host.pendingQuestions }
    public var pendingConflict: PendingConflict? { host.pendingConflict }
    /// The other chat this run is waiting for, while it waits.
    public var waitingOnLease: WorkspaceLeaseHolder? { host.waitingOnLease }
    public var workspaceConflictPolicy: WorkspaceConflictPolicy { host.workspaceConflictPolicy }
    public var conflictWaitSeconds: Int { host.conflictWaitSeconds }
    public var followUpSuggestion: String? { host.followUpSuggestion }
    public var followUpConversationID: String? { host.followUpConversationID }
    public var skills: SkillCatalog { host.skills }
    public var skillSuggestions: SkillSuggestionMonitor? { host.skillSuggestions }
    public var activeRunStartedAt: Date? { host.activeRunStartedAt }
    public var activeUsedSkillIDs: [String] { host.activeUsedSkillIDs }
    public func liveReply(for conversationID: String) -> String? { host.liveReplies[conversationID] }
    public func liveThinking(for conversationID: String) -> String? { host.liveThinking[conversationID] }
    public func prewarmProvider() { host.prewarmProvider() }
    public var activeRunTokenCount: Int { host.activeRunTokenCount }
    public var activeRunTokenCountIncludesEstimate: Bool { host.activeRunTokenCountIncludesEstimate }
    public var onAssistantResponse: ((AssistantResponseEvent) -> Void)? {
        get { host.onAssistantResponse }
        set { host.onAssistantResponse = newValue }
    }
    public var onRunSummary: ((RunSummaryEvent) -> Void)? {
        get { host.onRunSummary }
        set { host.onRunSummary = newValue }
    }
    public var onPlanAutoApproved: (() -> Void)? {
        get { host.onPlanAutoApproved }
        set { host.onPlanAutoApproved = newValue }
    }
    public func classifyPlanIntent(_ text: String) async -> Bool { await host.classifyPlanIntent(text) }
    @discardableResult
    public func submitPrompt(
        text: String,
        attachments: [ChatAttachment],
        mode: PromptMode,
        planMode: Bool,
        needsPlanIntentResolution: Bool,
        approvedPlanID: String? = nil,
        onPlanModeResolved: (() -> Void)? = nil
    ) -> Bool {
        host.submitPrompt(
            text: text,
            attachments: attachments,
            mode: mode,
            planMode: planMode,
            needsPlanIntentResolution: needsPlanIntentResolution,
            approvedPlanID: approvedPlanID,
            onPlanModeResolved: onPlanModeResolved
        )
    }
    public func resolvePendingPlanIntents() { host.resolvePendingPlanIntents() }
    public var onAttentionNeeded: ((RunAttentionEvent) -> Void)? {
        get { host.onAttentionNeeded }
        set { host.onAttentionNeeded = newValue }
    }
    /// Any project conversation running, including ones in the background.
    public var anyRunBusy: Bool { host.anyRunBusy }
    public var runningConversationIDs: Set<String> { host.runningConversationIDs }
    public var onRemoteEvent: ((String, [String: String]) -> Void)? {
        get { host.onRemoteEvent }
        set { host.onRemoteEvent = newValue }
    }
    public var onPluginsChanged: (() -> Void)? {
        get { host.onPluginsChanged }
        set { host.onPluginsChanged = newValue }
    }

    public init(
        paths: SupportPaths,
        endpoint: AgentEndpointController,
        skills: SkillCatalog? = nil,
        permissionMode: AgentPermissionMode = .ask,
        nonInteractive: Bool = false,
        automaticNetworkAccess: Bool = false,
        pluginHost: PluginHost? = nil,
        skillSuggestions: SkillSuggestionMonitor? = nil
    ) {
        host = NativeAgentHost(
            paths: paths,
            endpoint: endpoint,
            skills: skills,
            permissionMode: permissionMode,
            nonInteractive: nonInteractive,
            automaticNetworkAccess: automaticNetworkAccess,
            pluginHost: pluginHost,
            skillSuggestions: skillSuggestions
        )
    }

    public init(
        paths: SupportPaths,
        router: RouterController,
        skills: SkillCatalog? = nil,
        permissionMode: AgentPermissionMode = .ask,
        nonInteractive: Bool = false,
        automaticNetworkAccess: Bool = false,
        pluginHost: PluginHost? = nil,
        skillSuggestions: SkillSuggestionMonitor? = nil
    ) {
        host = NativeAgentHost(
            paths: paths,
            router: router,
            skills: skills,
            permissionMode: permissionMode,
            nonInteractive: nonInteractive,
            automaticNetworkAccess: automaticNetworkAccess,
            pluginHost: pluginHost,
            skillSuggestions: skillSuggestions
        )
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
        skillSuggestions: SkillSuggestionMonitor? = nil
    ) {
        host = NativeAgentHost(
            paths: paths,
            endpoint: endpoint,
            router: router,
            skills: skills,
            permissionMode: permissionMode,
            nonInteractive: nonInteractive,
            automaticNetworkAccess: automaticNetworkAccess,
            pluginHost: pluginHost,
            skillSuggestions: skillSuggestions
        )
    }

    public func start(workspacePath: String) { host.start(workspacePath: workspacePath) }
    public func updateSystemPrompt(_ prompt: String) { host.updateSystemPrompt(prompt) }
    public func effectiveSystemPromptReport(planMode: Bool = false) -> String {
        host.effectiveSystemPromptReport(planMode: planMode)
    }
    public func setSelfVerification(_ enabled: Bool) { host.setSelfVerification(enabled) }
    public func setSeedProjectRules(_ enabled: Bool) { host.setSeedProjectRules(enabled) }
    public func setAutoApprovePlans(_ enabled: Bool) { host.setAutoApprovePlans(enabled) }
    public func setSandboxPolicy(_ policy: SandboxExecutionPolicy?, branch: String? = nil) {
        host.setSandboxPolicy(policy, branch: branch)
    }
    public var remoteTarget: SSHTarget? { host.remoteTarget }
    public func setRemoteTarget(_ target: SSHTarget?) { host.setRemoteTarget(target) }
    public func setPermissionMode(_ mode: AgentPermissionMode) { host.setPermissionMode(mode) }
    public func setBrowserBackend(_ backend: BrowserBackend?) { host.setBrowserBackend(backend) }
    public var isComputerUseEnabled: Bool { host.isComputerUseEnabled }
    public func setComputerUseEnabled(_ enabled: Bool) { host.setComputerUseEnabled(enabled) }
    public func stopAllAgentTerminals() { host.stopAllAgentTerminals() }
    public func stopAgentTerminals(for workspacePath: String) { host.stopAgentTerminals(for: workspacePath) }
    /// MCP servers whose tools are offered to the agent loop.
    public var mcpRegistry: MCPRegistry? {
        get { host.mcpRegistry }
        set { host.mcpRegistry = newValue }
    }
    public func answerApproval(_ answer: String, in conversationID: String? = nil) { host.answerApproval(answer, in: conversationID) }
    public func answerVisionInstall(_ allow: Bool) { host.answerVisionInstall(allow) }
    public func answerContextCompaction(_ allow: Bool) { host.answerContextCompaction(allow) }
    public func answerQuestions(_ answers: [String], in conversationID: String? = nil) { host.answerQuestions(answers, in: conversationID) }
    public func cancelQuestions(in conversationID: String? = nil) { host.cancelQuestions(in: conversationID) }
    public func answerConflict(_ choice: WorkspaceConflictChoice) { host.answerConflict(choice) }
    public func setWorkspaceConflictPolicy(_ policy: WorkspaceConflictPolicy) { host.setWorkspaceConflictPolicy(policy) }
    public func setConflictWaitSeconds(_ seconds: Int) { host.setConflictWaitSeconds(seconds) }
    public func refreshConnection() async { await host.refreshConnection() }
    public func resumeRecoveredPlanIfNeeded() async { await host.resumeRecoveredPlanIfNeeded() }
    public func setWorkspace(_ path: String) { host.setWorkspace(path) }
    public func setSearchFolders(_ paths: [String]) { host.setSearchFolders(paths) }
    public func select(_ id: String) { host.select(id) }
    public func openRecentConversation(_ id: String) { host.openRecentConversation(id) }
    public func newConversation() { host.newConversation() }
    func setConversationModelPreference(_ modelID: String?, for id: String) {
        host.updateConversation(id) { $0.modelPreferenceID = modelID }
    }
    public func relocateProjectHistory(from oldPath: String, to newPath: String) {
        host.relocateProjectHistory(from: oldPath, to: newPath)
    }
    public func renameConversation(_ id: String, to title: String) { host.renameConversation(id, to: title) }
    public func togglePinned(_ id: String) { host.togglePinned(id) }
    public func setArchived(_ id: String, archived: Bool) { host.setArchived(id, archived: archived) }
    public func markAllRead(forWorkspace path: String) { host.markAllRead(forWorkspace: path) }
    public func archiveAll(forWorkspace path: String) { host.archiveAll(forWorkspace: path) }
    public func mergeExternalConversations() { host.mergeExternalConversations() }
    public func deleteConversation(_ id: String) { host.deleteConversation(id) }
    public func canEdit(messageID: String, in conversationID: String) -> Bool {
        host.canEdit(messageID: messageID, in: conversationID)
    }
    public func canRewind(messageID: String, in conversationID: String) -> Bool {
        host.canRewind(messageID: messageID, in: conversationID)
    }
    public func canUndoTurn(messageID: String, in conversationID: String) -> Bool {
        host.canUndoTurn(messageID: messageID, in: conversationID)
    }
    public func undoTurn(conversationID: String, messageID: String) throws -> RewindResult {
        try host.undoTurn(conversationID: conversationID, messageID: messageID)
    }
    public func rewind(conversationID: String, beforeMessageID messageID: String) throws -> RewindResult {
        try host.rewind(conversationID: conversationID, beforeMessageID: messageID)
    }
    public func editLatestMessage(
        conversationID: String,
        messageID: String,
        text: String,
        attachments: [ChatAttachment]
    ) async throws {
        try await host.editLatestMessage(
            conversationID: conversationID,
            messageID: messageID,
            text: text,
            attachments: attachments
        )
    }
    public func stopCurrentRun() { host.stopCurrentRun() }
    public func pauseAllRunsForShutdown() async { await host.pauseAllRunsForShutdown() }
    public func closeBrowserSessions() async { await host.closeBrowserSessions() }
    public func continueCurrentRun(text: String? = nil, attachments: [ChatAttachment] = []) async {
        await host.continueCurrentRun(text: text, attachments: attachments)
    }
    public func movePendingPrompt(_ promptID: String, relativeTo targetID: String?, in conversationID: String) {
        host.movePendingPrompt(promptID, relativeTo: targetID, in: conversationID)
    }
    @discardableResult
    public func removeQueuedPrompt(_ promptID: String, in conversationID: String) -> PendingPrompt? {
        host.removeQueuedPrompt(promptID, in: conversationID)
    }
    public func steerPendingPrompt(_ promptID: String, in conversationID: String) {
        host.steerPendingPrompt(promptID, in: conversationID)
    }
    public func cancelPlan() async { await host.cancelPlan() }
    public func send(
        text: String,
        attachments: [ChatAttachment] = [],
        mode: PromptMode = .queue,
        planMode: Bool = false,
        modelOverride: String? = nil
    ) async {
        await host.send(
            text: text,
            attachments: attachments,
            mode: mode,
            planMode: planMode,
            modelOverride: modelOverride
        )
    }
    public func applyPlan() async { await host.applyPlan() }
    public func generate(_ request: MediaRequest) async { await host.generate(request) }
    public func synthesizeSpeech(_ text: String) async throws -> URL { try await host.synthesizeSpeech(text) }

    public func createWorkspaceInvite(
        displayName: String,
        role: MemoryRole,
        score: Int,
        publicKey: String
    ) throws -> String {
        try host.createWorkspaceInvite(displayName: displayName, role: role, score: score, publicKey: publicKey)
    }

    public func acceptWorkspaceInvite(_ token: String) throws { try host.acceptWorkspaceInvite(token) }
    public func revokeWorkspaceDevice(_ deviceID: String) throws { try host.revokeWorkspaceDevice(deviceID) }
    public func resolveWorkspaceDecision(_ eventID: String, accept: Bool) throws {
        try host.resolveWorkspaceDecision(eventID, accept: accept)
    }
}

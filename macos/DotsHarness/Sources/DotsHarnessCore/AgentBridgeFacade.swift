// Copyright (c) 2026 DOTS
// UI-facing compatibility facade for the native agent host.

import Combine
import Foundation
import PluginRuntime

@MainActor
public final class AgentBridge: ObservableObject {
    private let host: NativeAgentHost
    private var hostObservation: AnyCancellable?

    public var connection: AgentConnection? { host.connection }
    public var conversations: [Conversation] { host.conversations }
    public var projectlessConversations: [Conversation] { host.projectlessConversations }
    public var archivedConversations: [Conversation] { host.archivedConversations }
    public var selectedID: String? {
        get { host.selectedID }
        set { host.selectedID = newValue }
    }
    public var status: String { host.status }
    public var isBusy: Bool { host.isBusy }
    public var canContinue: Bool { host.canContinue }
    public var accessRevision: Int { host.accessRevision }
    public var selected: Conversation? { host.selected }
    public var workspacePath: String? { host.workspacePath }
    public var workspaceAccess: WorkspaceAccessStatus { host.workspaceAccess }
    public var memoryDevicePublicKey: String? { host.memoryDevicePublicKey }
    public var workspaceMembers: [[String: String]] { host.workspaceMembers }
    public var pendingWorkspaceDecisions: [[String: Any]] { host.pendingWorkspaceDecisions }
    public var memoryVault: MemoryVault { host.memoryVault }
    public var memoryFolderURL: URL? { host.memoryFolderURL }
    public var memoryReady: Bool { host.memoryReady }
    public var isReady: Bool { host.isReady }
    public var historyMutationBusy: Bool { host.historyMutationBusy }
    public var permissionMode: AgentPermissionMode { host.permissionMode }
    public var pendingApproval: PendingApproval? { host.pendingApproval }
    public var skills: SkillCatalog { host.skills }
    public var activeRunStartedAt: Date? { host.activeRunStartedAt }
    public var activeUsedSkillIDs: [String] { host.activeUsedSkillIDs }
    public var onAssistantResponse: ((AssistantResponseEvent) -> Void)? {
        get { host.onAssistantResponse }
        set { host.onAssistantResponse = newValue }
    }

    public init(
        paths: SupportPaths,
        endpoint: AgentEndpointController,
        skills: SkillCatalog? = nil,
        permissionMode: AgentPermissionMode = .ask,
        nonInteractive: Bool = false
    ) {
        host = NativeAgentHost(
            paths: paths,
            endpoint: endpoint,
            skills: skills,
            permissionMode: permissionMode,
            nonInteractive: nonInteractive
        )
        observeHost()
    }

    public init(
        paths: SupportPaths,
        router: RouterController,
        skills: SkillCatalog? = nil,
        permissionMode: AgentPermissionMode = .ask,
        nonInteractive: Bool = false
    ) {
        host = NativeAgentHost(
            paths: paths,
            router: router,
            skills: skills,
            permissionMode: permissionMode,
            nonInteractive: nonInteractive
        )
        observeHost()
    }

    public init(
        paths: SupportPaths,
        endpoint: AgentEndpointController,
        router: RouterController,
        skills: SkillCatalog? = nil,
        permissionMode: AgentPermissionMode = .ask,
        nonInteractive: Bool = false
    ) {
        host = NativeAgentHost(
            paths: paths,
            endpoint: endpoint,
            router: router,
            skills: skills,
            permissionMode: permissionMode,
            nonInteractive: nonInteractive
        )
        observeHost()
    }

    public func start(workspacePath: String) { host.start(workspacePath: workspacePath) }
    public func updateSystemPrompt(_ prompt: String) { host.updateSystemPrompt(prompt) }
    public func setPermissionMode(_ mode: AgentPermissionMode) { host.setPermissionMode(mode) }
    public func answerApproval(_ answer: String) { host.answerApproval(answer) }
    public func refreshConnection() async { await host.refreshConnection() }
    public func setWorkspace(_ path: String) { host.setWorkspace(path) }
    public func select(_ id: String) { host.select(id) }
    public func newConversation() { host.newConversation() }
    public func renameConversation(_ id: String, to title: String) { host.renameConversation(id, to: title) }
    public func togglePinned(_ id: String) { host.togglePinned(id) }
    public func setArchived(_ id: String, archived: Bool) { host.setArchived(id, archived: archived) }
    public func mergeExternalConversations() { host.mergeExternalConversations() }
    public func deleteConversation(_ id: String) { host.deleteConversation(id) }
    public func canEdit(messageID: String, in conversationID: String) -> Bool {
        host.canEdit(messageID: messageID, in: conversationID)
    }
    public func canRewind(messageID: String, in conversationID: String) -> Bool {
        host.canRewind(messageID: messageID, in: conversationID)
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
    public func continueCurrentRun(text: String? = nil, attachments: [ChatAttachment] = []) async {
        await host.continueCurrentRun(text: text, attachments: attachments)
    }
    public func movePendingPrompt(_ promptID: String, relativeTo targetID: String?, in conversationID: String) {
        host.movePendingPrompt(promptID, relativeTo: targetID, in: conversationID)
    }
    public func steerPendingPrompt(_ promptID: String, in conversationID: String) {
        host.steerPendingPrompt(promptID, in: conversationID)
    }
    public func send(
        text: String,
        attachments: [ChatAttachment] = [],
        mode: PromptMode = .queue,
        planMode: Bool = false
    ) async {
        await host.send(text: text, attachments: attachments, mode: mode, planMode: planMode)
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

    private func observeHost() {
        hostObservation = host.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }
}

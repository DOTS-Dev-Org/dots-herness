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
    public var selectedID: String? {
        get { host.selectedID }
        set { host.selectedID = newValue }
    }
    public var status: String { host.status }
    public var isBusy: Bool { host.isBusy }
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

    public init(paths: SupportPaths, endpoint: AgentEndpointController) {
        host = NativeAgentHost(paths: paths, endpoint: endpoint)
        observeHost()
    }

    public init(paths: SupportPaths, router: RouterController) {
        host = NativeAgentHost(paths: paths, router: router)
        observeHost()
    }

    public init(
        paths: SupportPaths,
        endpoint: AgentEndpointController,
        router: RouterController
    ) {
        host = NativeAgentHost(paths: paths, endpoint: endpoint, router: router)
        observeHost()
    }

    public func start(workspacePath: String) { host.start(workspacePath: workspacePath) }
    public func updateSystemPrompt(_ prompt: String) { host.updateSystemPrompt(prompt) }
    public func refreshConnection() async { await host.refreshConnection() }
    public func setWorkspace(_ path: String) { host.setWorkspace(path) }
    public func select(_ id: String) { host.select(id) }
    public func newConversation() { host.newConversation() }
    public func renameConversation(_ id: String, to title: String) { host.renameConversation(id, to: title) }
    public func mergeExternalConversations() { host.mergeExternalConversations() }
    public func deleteConversation(_ id: String) { host.deleteConversation(id) }
    public func send(text: String, mode: PromptMode = .queue) async { await host.send(text: text, mode: mode) }

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

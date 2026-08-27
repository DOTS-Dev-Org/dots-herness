// Copyright (c) 2026 DOTS
// Native agent host: conversation state, model loop, tools, and workspace memory.

import Foundation
import HarnessPluginKit
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

@MainActor
public final class NativeAgentHost: ObservableObject {
    @Published public private(set) var connection: AgentConnection?
    @Published public private(set) var conversations: [Conversation] = []
    @Published public var selectedID: String?
    @Published public private(set) var status: String = AppCopy.text("agent.chooseWorkspace")
    @Published public private(set) var isBusy = false
    @Published public private(set) var accessRevision = 0

    private let store: ConversationStore
    private let memory: WorkspaceMemory
    private let endpoint: AgentEndpointController
    private let router: RouterController?
    private var workspaceURL: URL?
    private var additionalSystemPrompt = ""

    public var selected: Conversation? {
        conversations.first { $0.id == selectedID }
    }

    public var workspacePath: String? { workspaceURL?.path }
    public var workspaceAccess: WorkspaceAccessStatus { memory.accessStatus() }
    public var memoryDevicePublicKey: String? { memory.actorPublicKey }
    public var workspaceMembers: [[String: String]] { memory.memberSummaries() }
    public var pendingWorkspaceDecisions: [[String: Any]] { memory.pendingDecisions() }
    // A busy agent can still accept a normal queued prompt or a steering prompt.
    public var isReady: Bool { workspaceURL != nil && connection != nil }

    public init(paths: SupportPaths, endpoint: AgentEndpointController) {
        self.store = ConversationStore(paths: paths)
        self.memory = WorkspaceMemory(paths: paths)
        self.endpoint = endpoint
        self.router = nil
    }

    public init(paths: SupportPaths, router: RouterController) {
        self.store = ConversationStore(paths: paths)
        self.memory = WorkspaceMemory(paths: paths)
        self.endpoint = AgentEndpointController()
        self.router = router
    }

    public init(
        paths: SupportPaths,
        endpoint: AgentEndpointController,
        router: RouterController
    ) {
        self.store = ConversationStore(paths: paths)
        self.memory = WorkspaceMemory(paths: paths)
        self.endpoint = endpoint
        self.router = router
    }

    private var activeTask: Task<Void, Never>?
    private var activeConversationID: String?
    private var activeRunID = UUID()
    /// The latest valid model context, including tool calls/results that have not
    /// yet become a final chat bubble. Steering resumes from this snapshot.
    private var activeContext: [AgentMessage] = []

    public func start(workspacePath: String) {
        setWorkspace(workspacePath)
        if workspaceURL == nil {
            status = AppCopy.text("agent.chooseWorkspaceToStart")
        }
    }

    public func updateSystemPrompt(_ prompt: String) {
        additionalSystemPrompt = prompt
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
        guard workspaceURL != nil else {
            connection = nil
            status = AppCopy.text("agent.chooseWorkspaceToStart")
            return
        }
        guard let configuration = await currentConfiguration() else {
            connection = nil
            status = AppCopy.text("agent.configureEndpoint")
            return
        }
        guard let endpoint = URL(string: configuration.baseURL) else {
            connection = nil
            status = AppCopy.text("agent.invalidEndpoint")
            return
        }
        connection = AgentConnection(endpoint: endpoint, provider: configuration.provider, model: configuration.model)
        status = AppCopy.format("agent.ready", configuration.model)
    }

    private func currentConfiguration() async -> AgentConfiguration? {
        if let configuration = endpoint.configuration {
            return configuration
        }
        guard let router else { return nil }
        await router.refreshModelsIfNeeded()
        return await router.agentConfiguration()
    }

    public func setWorkspace(_ path: String) {
        activeTask?.cancel()
        activeTask = nil
        activeConversationID = nil
        activeRunID = UUID()
        activeContext = []
        isBusy = false
        let normalized = ConversationStore.normalizedPath(path)
        guard let normalized else {
            memory.setWorkspace(nil)
            workspaceURL = nil
            conversations = []
            selectedID = nil
            connection = nil
            status = AppCopy.text("agent.chooseWorkspaceToStart")
            return
        }

        let url = URL(fileURLWithPath: normalized, isDirectory: true)
        guard FileManager.default.fileExists(atPath: url.path) else {
            memory.setWorkspace(nil)
            workspaceURL = nil
            conversations = []
            selectedID = nil
            connection = nil
            status = AppCopy.text("agent.workspaceMissing")
            return
        }

        workspaceURL = url
        memory.setWorkspace(url)
        accessRevision += 1
        conversations = store.load(workspacePath: normalized)
            .map { conversation in
                var recovered = conversation
                recovered.running = false
                if let firstUserMessage = recovered.messages.first(where: { $0.kind == .user }) {
                    recovered.title = Self.title(for: firstUserMessage.text)
                    recovered.blank = false
                } else if recovered.messages.isEmpty, recovered.title == "New chat" {
                    recovered.blank = true
                }
                return recovered
            }
        selectedID = conversations.first?.id
        if selectedID == nil {
            newConversation()
        }
        status = connection == nil ? AppCopy.text("agent.chooseModel") : status
    }

    public func select(_ id: String) {
        guard conversations.contains(where: { $0.id == id }) else { return }
        selectedID = id
    }

    public func newConversation() {
        guard let workspaceURL else { return }
        if let draft = conversations.first(where: Self.isEmptyDraft) {
            selectedID = draft.id
            return
        }
        let conversation = Conversation(cwd: workspaceURL.path)
        conversations.insert(conversation, at: 0)
        selectedID = conversation.id
        persist()
    }

    public func renameConversation(_ id: String, to title: String) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[index].title = title
        conversations[index].blank = false
        persist()
    }

    public func deleteConversation(_ id: String) {
        if activeConversationID == id {
            activeTask?.cancel()
            activeTask = nil
            activeConversationID = nil
            activeRunID = UUID()
            activeContext = []
            isBusy = false
        }
        conversations.removeAll { $0.id == id }
        store.delete(id)
        if selectedID == id {
            selectedID = conversations.first?.id
        }
    }

    public func send(text: String, mode: PromptMode = .queue) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let workspaceURL else {
            status = AppCopy.text("agent.chooseWorkspaceBeforeSend")
            return
        }

        if enqueueIfBusy(text: trimmed, mode: mode) { return }

        guard let configuration = await currentConfiguration() else {
            status = AppCopy.text("agent.configureEndpoint")
            return
        }
        // Configuration lookup suspends the main actor. A second Enter can
        // arrive while it is in flight; re-check so it joins the first run
        // instead of starting a parallel run.
        if enqueueIfBusy(text: trimmed, mode: mode) { return }
        if selectedID == nil {
            newConversation()
        }
        guard let id = selectedID,
              let index = conversations.firstIndex(where: { $0.id == id }) else { return }

        let runID = UUID()
        let userMessage = ChatMessage(kind: .user, text: trimmed)
        let isFirstUserMessage = !conversations[index].messages.contains(where: { $0.kind == .user })
        conversations[index].messages.append(userMessage)
        if isFirstUserMessage || conversations[index].blank {
            conversations[index].title = Self.title(for: trimmed)
            conversations[index].blank = false
        }
        conversations[index].running = true
        memory.prepareForPrompt(
            prompt: trimmed,
            runID: runID,
            provider: configuration.provider,
            model: configuration.model
        )
        let context = makeAgentContext(
            for: conversations[index],
            workspace: workspaceURL,
            memorySnapshot: memory.snapshot(for: trimmed)
        )
        persist()

        let task = startRun(
            runID: runID,
            conversationID: id,
            configuration: configuration,
            workspace: workspaceURL,
            context: context
        )
        await task.value
    }

    private func makeAgentContext(
        for conversation: Conversation,
        workspace: URL,
        memorySnapshot: MemorySnapshot? = nil
    ) -> [AgentMessage] {
        var messages = [AgentMessage(
            role: .system,
            content: systemPrompt(workspace: workspace)
        )]
        if let memorySnapshot, !memorySnapshot.text.isEmpty {
            messages.append(AgentMessage(role: .system, content: memorySnapshot.text))
        }
        messages.append(contentsOf: makeAgentMessages(for: conversation))
        return messages
    }

    private func startRun(
        runID: UUID,
        conversationID: String,
        configuration: AgentConfiguration,
        workspace: URL,
        context: [AgentMessage]
    ) -> Task<Void, Never> {
        activeRunID = runID
        activeConversationID = conversationID
        activeContext = context
        isBusy = true
        if let index = conversations.firstIndex(where: { $0.id == conversationID }) {
            conversations[index].running = true
        }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.run(
                runID: runID,
                conversationID: conversationID,
                configuration: configuration,
                workspace: workspace,
                context: context
            )
        }
        activeTask = task
        return task
    }

    private func run(
        runID: UUID,
        conversationID: String,
        configuration: AgentConfiguration,
        workspace: URL,
        context: [AgentMessage]
    ) async {
        let client = NativeAgentClient(configuration: configuration)
        var messages = context
        activeContext = messages
        var restartContext: [AgentMessage]?
        var succeeded = true

        do {
            var toolSteps = 0
            while true {
                try Task.checkCancellation()
                if toolSteps >= 8 {
                    if let next = takeNextPrompt(in: conversationID, allowQueue: true) {
                        let user = accept(next, in: conversationID)
                        messages.append(user)
                        activeContext = messages
                        toolSteps = 0
                        continue
                    }
                    append(ChatMessage(kind: .system, text: AppCopy.text("agent.toolStepLimit")), to: conversationID)
                    break
                }
                activeContext = messages
                let response: AgentResponse
                if let router {
                    response = try await router.complete(
                        messages: messages,
                        tools: WorkspaceTools.definitions,
                        cachePolicy: AgentCachePolicy(promptCacheKey: cacheKey(for: configuration))
                    )
                } else {
                    response = try await client.complete(
                        messages: messages,
                        tools: WorkspaceTools.definitions,
                        cachePolicy: AgentCachePolicy(promptCacheKey: cacheKey(for: configuration))
                    )
                }
                // Keep a completed provider response in the steer snapshot before
                // observing cancellation. This preserves the output that arrived
                // just as the higher-priority instruction was submitted.
                messages.append(response.message)
                activeContext = messages

                if response.message.toolCalls.isEmpty {
                    let text = response.message.content.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty {
                        append(ChatMessage(kind: .assistant, text: text), to: conversationID)
                    } else {
                        append(ChatMessage(kind: .system, text: AppCopy.text("agent.emptyResponse")), to: conversationID)
                    }
                    try Task.checkCancellation()

                    if let next = takeNextPrompt(in: conversationID, allowQueue: true) {
                        let user = accept(next, in: conversationID)
                        messages.append(user)
                        activeContext = messages
                        toolSteps = 0
                        continue
                    }
                    status = AppCopy.format("agent.ready", configuration.model)
                    break
                }

                if Task.isCancelled {
                    for call in response.message.toolCalls {
                        messages.append(AgentMessage(
                            role: .tool,
                            content: "Tool call interrupted before it started.",
                            name: call.name,
                            toolCallID: call.id
                        ))
                    }
                    activeContext = messages
                    try Task.checkCancellation()
                }

                toolSteps += 1
                for call in response.message.toolCalls {
                    append(ChatMessage(kind: .tool, text: AppCopy.format("agent.runningTool", call.name)), to: conversationID)
                    let beforeFile = memory.fileHash(for: call, workspace: workspace)
                    let beforeGit = memory.changedGitPaths(workspace: workspace)
                    let result = await Task.detached(priority: .userInitiated) {
                        WorkspaceTools.execute(call, workspace: workspace)
                    }.value
                    memory.recordTool(
                        runID: runID,
                        call: call,
                        result: result,
                        beforeFile: beforeFile,
                        beforeGit: beforeGit,
                        workspace: workspace
                    )
                    append(ChatMessage(kind: .tool, text: "✓ \(call.name)\n\(Self.toolPreview(result))"), to: conversationID)
                    messages.append(AgentMessage(
                        role: .tool,
                        content: result,
                        name: call.name,
                        toolCallID: call.id
                    ))
                    activeContext = messages
                    try Task.checkCancellation()
                }
            }
        } catch {
            if Task.isCancelled {
                if let steer = takeNextPrompt(in: conversationID, allowQueue: false) {
                    var nextContext = activeContext.isEmpty ? messages : activeContext
                    nextContext.append(accept(steer, in: conversationID))
                    activeContext = nextContext
                    restartContext = nextContext
                } else {
                    succeeded = false
                }
            } else {
                succeeded = false
                append(ChatMessage(kind: .system, text: error.localizedDescription), to: conversationID)
                status = error.localizedDescription
            }
        }

        guard activeRunID == runID else { return }
        if let restartContext {
            // A cancelled Task remains cancelled, so steering always starts a
            // fresh Task. The new run inherits the old run's full model context.
            _ = startRun(
                runID: runID,
                conversationID: conversationID,
                configuration: configuration,
                workspace: workspace,
                context: restartContext
            )
            return
        }

        activeTask = nil
        activeConversationID = nil
        isBusy = false
        memory.finishTask(
            runID: runID,
            success: succeeded,
            finalText: conversations.first(where: { $0.id == conversationID })?.messages.last(where: { $0.kind == .assistant })?.text ?? ""
        )
        if let index = conversations.firstIndex(where: { $0.id == conversationID }) {
            conversations[index].running = false
        }
        persist()
    }

    private func enqueue(_ prompt: PendingPrompt, in conversationID: String) {
        guard let index = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
        conversations[index].pendingPrompts.append(prompt)
        status = prompt.mode == .steer
            ? AppCopy.text("agent.steeringQueued")
            : AppCopy.text("agent.messageQueued")
    }

    private func enqueueIfBusy(text: String, mode: PromptMode) -> Bool {
        guard isBusy else { return false }
        guard let id = activeConversationID ?? selectedID else { return true }
        enqueue(PendingPrompt(text: text, mode: mode), in: id)
        if mode == .steer {
            // The cancellation is intentional: the next run starts with the
            // last complete model context plus this higher-priority message.
            activeTask?.cancel()
        }
        return true
    }

    private func takeNextPrompt(in conversationID: String, allowQueue: Bool) -> PendingPrompt? {
        guard let index = conversations.firstIndex(where: { $0.id == conversationID }) else { return nil }
        if let steerIndex = conversations[index].pendingPrompts.firstIndex(where: { $0.mode == .steer }) {
            return conversations[index].pendingPrompts.remove(at: steerIndex)
        }
        guard allowQueue,
              let queueIndex = conversations[index].pendingPrompts.firstIndex(where: { $0.mode == .queue }) else {
            return nil
        }
        return conversations[index].pendingPrompts.remove(at: queueIndex)
    }

    private func accept(_ prompt: PendingPrompt, in conversationID: String) -> AgentMessage {
        let message = ChatMessage(kind: .user, text: prompt.text)
        if let index = conversations.firstIndex(where: { $0.id == conversationID }) {
            let isFirstUserMessage = !conversations[index].messages.contains(where: { $0.kind == .user })
            conversations[index].messages.append(message)
            if isFirstUserMessage || conversations[index].blank {
                conversations[index].title = Self.title(for: prompt.text)
                conversations[index].blank = false
            }
        }
        memory.recordPrompt(runID: activeRunID, prompt: prompt.text)
        persist()
        return AgentMessage(role: .user, content: prompt.text)
    }

    private func append(_ message: ChatMessage, to conversationID: String) {
        guard let index = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
        conversations[index].messages.append(message)
        persist()
    }

    private func makeAgentMessages(for conversation: Conversation) -> [AgentMessage] {
        conversation.messages.compactMap { message in
            switch message.kind {
            case .user:
                return AgentMessage(role: .user, content: message.text)
            case .assistant:
                return AgentMessage(role: .assistant, content: message.text)
            case .tool, .system:
                return nil
            }
        }
    }

    private func systemPrompt(workspace: URL) -> String {
        """
        You are Dots Harness, a native macOS coding agent. You work inside the selected workspace only: \(workspace.path)
        Be direct and useful. Inspect files before making assumptions. Use the provided tools for files and shell commands instead of pretending you ran them. Explain what changed after completing work.

        \(additionalSystemPrompt)
        """
    }

    private func cacheKey(for configuration: AgentConfiguration) -> String? {
        guard configuration.cacheCapabilities.promptCacheKey,
              let projectID = memory.projectID else { return nil }
        return "herness:\(projectID):\(configuration.model):prompt-v1:tools-v1"
    }

    private func persist() {
        store.save(conversations)
    }

    /// Fold in conversations written to the store by another host (e.g. a
    /// scheduled-task run) without disturbing the active run or selection.
    public func mergeExternalConversations() {
        guard let path = workspaceURL?.path else { return }
        let known = Set(conversations.map(\.id))
        let extras = store.load(workspacePath: path)
            .filter { !known.contains($0.id) }
            .map { conversation -> Conversation in
                var recovered = conversation
                recovered.running = false
                return recovered
            }
        guard !extras.isEmpty else { return }
        conversations.append(contentsOf: extras)
        conversations.sort { $0.id < $1.id }
    }

    private static func isEmptyDraft(_ conversation: Conversation) -> Bool {
        conversation.messages.isEmpty && (conversation.blank || conversation.title == "New chat")
    }

    private static func title(for text: String) -> String {
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        let compact = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(compact.prefix(48))
    }

    private static func toolPreview(_ result: String) -> String {
        let limit = 700
        if result.count <= limit { return result }
        return String(result.prefix(limit)) + "…"
    }
}

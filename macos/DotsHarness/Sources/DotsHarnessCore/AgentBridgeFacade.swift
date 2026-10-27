// Copyright (c) 2026 DOTS
// UI-facing names for the native agent host.

import Foundation

/// The UI talks to the host directly; it is `@Observable`, so a view observes exactly the
/// host properties it reads.
public typealias AgentBridge = NativeAgentHost

extension NativeAgentHost {
    public var taskSuggestionMemory: TaskSuggestionMemory { memory.taskSuggestionMemory() }
    /// Moves whenever memory changed, in the background too.
    public var memoryChangeCount: Int { memoryRevision }
    public var memoryEnabled: Bool { memory.enabled }
    public var lastMemoryScan: Date? { memory.lastMemoryScan }
    public var unscannedTaskCount: Int { memory.unscannedTaskCount }
    public var insightCount: Int { memory.insights.count }
    @discardableResult
    public func scanMemoryNow() async -> Bool { await scanMemory(force: true) }
    func beforeContent(conversationID: String, turnID: String, path: String) -> Data? {
        memory.snapshotStore.beforeContent(conversationID: conversationID, turnID: turnID, path: path)
    }
    public func accountSwitched(in conversationID: String?) -> Bool {
        conversationID.map(accountSwitchedConversations.contains) ?? false
    }
    public func liveReplyParagraphs(for conversationID: String) -> [LiveReplyParagraph]? {
        liveReplyParagraphs[conversationID]
    }
    public func liveThinking(for conversationID: String) -> String? { liveThinking[conversationID] }
    public func changedFilesRevision(for conversationID: String) -> Int {
        changedFilesRevisions[conversationID] ?? 0
    }
    /// Shells and background tasks the agent started in this conversation.
    public func backgroundTasks(in conversationID: String?) -> [TerminalSession] {
        agentTerminals[conversationID ?? ""] ?? []
    }
    public func clearFinishedBackgroundTasks(in conversationID: String) {
        clearFinishedAgentTerminals(in: conversationID)
    }
}

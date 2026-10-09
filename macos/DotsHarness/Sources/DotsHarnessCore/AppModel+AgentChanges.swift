// Copyright (c) 2026 DOTS
// Files the agent itself changed in the selected conversation, with the turn that explains why.

import Foundation

public struct AgentFileChange: Identifiable, Hashable, Sendable {
    public let path: String
    public let operation: ChangedFile.Operation
    /// Earliest turn that touched the file: its snapshot holds the pre-agent content.
    public let firstTurnID: String
    /// What the user asked for in the latest turn that touched the file.
    public let request: String
    /// The agent's own account of that turn.
    public let explanation: String
    public var id: String { path }
}

extension AppModel {
    public func agentChanges() -> [AgentFileChange] {
        guard let conversation = selected else { return [] }
        var order: [String] = []
        var byPath: [String: AgentFileChange] = [:]
        for message in conversation.messages where message.kind == .assistant {
            guard let turnID = message.turnID, !message.changedFiles.isEmpty else { continue }
            let request = conversation.messages.first { $0.kind == .user && $0.turnID == turnID }?.text ?? ""
            for file in message.changedFiles {
                if let old = byPath[file.path] {
                    // Added then edited stays "added"; the earliest turn keeps the base content.
                    byPath[file.path] = AgentFileChange(
                        path: file.path,
                        operation: old.operation == .added && file.operation != .deleted ? .added : file.operation,
                        firstTurnID: old.firstTurnID,
                        request: request,
                        explanation: message.text
                    )
                } else {
                    order.append(file.path)
                    byPath[file.path] = AgentFileChange(
                        path: file.path, operation: file.operation, firstTurnID: turnID,
                        request: request, explanation: message.text
                    )
                }
            }
        }
        return order.compactMap { byPath[$0] }.sorted { $0.path < $1.path }
    }

    public func agentBeforeContent(_ change: AgentFileChange) -> Data? {
        guard let id = selectedConversationID else { return nil }
        return bridge.beforeContent(
            conversationID: id, turnID: change.firstTurnID, path: change.path
        )
    }
}

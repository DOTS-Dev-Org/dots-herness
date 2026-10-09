// Copyright (c) 2026 DOTS
// Turn snapshots: prompt preparation, background snapshotting and restore.

import CryptoKit
import Foundation
import PluginRuntime

extension WorkspaceMemory {
    /// Creates memory only when the first prompt is accepted. Selecting a
    /// workspace or opening a blank chat never calls this method.
    public func prepareForPrompt(
        prompt: String,
        runID: UUID,
        provider: String,
        model: String
    ) {
        guard workspaceURL != nil else { return }
        do {
            try ensureIdentity()
            if manifest == nil {
                try initializeWorkspace()
            } else {
                loadExisting()
            }
            try updateMapIfNeeded()
            beginTask(runID: runID, prompt: prompt, provider: provider, model: model)
        } catch {
            // Memory is an audit layer. A storage failure must not prevent the
            // native agent from answering the current user request.
        }
    }

    /// A capture running beside the model request. Waiters block or suspend until it is done.
    final class SnapshotJob: @unchecked Sendable {
        private let condition = NSCondition()
        private var done = false
        private var continuations: [CheckedContinuation<Void, Never>] = []

        func complete() {
            condition.lock()
            done = true
            let waiting = continuations
            continuations = []
            condition.broadcast()
            condition.unlock()
            waiting.forEach { $0.resume() }
        }

        func waitBlocking() {
            condition.lock()
            while !done { condition.wait() }
            condition.unlock()
        }

        func waitSuspending() async {
            await withCheckedContinuation { continuation in
                condition.lock()
                if done {
                    condition.unlock()
                    continuation.resume()
                } else {
                    continuations.append(continuation)
                    condition.unlock()
                }
            }
        }
    }


    private func snapshotJobKey(_ conversationID: String, _ turnID: String) -> String {
        "\(conversationID)|\(turnID)"
    }

    /// Captures the pre-turn snapshot on a background queue, so the model request can go
    /// out at once. Whatever changes the workspace must first `waitForTurnSnapshot`;
    /// `finishTurn` waits by itself.
    public func beginTurnInBackground(
        conversationID: String,
        turnID: String,
        workspace: URL?
    ) {
        guard let workspace else { return }
        let job = SnapshotJob()
        pendingSnapshotsLock.lock()
        pendingSnapshots[snapshotJobKey(conversationID, turnID)] = job
        pendingSnapshotsLock.unlock()
        let store = snapshotStore
        DispatchQueue.global(qos: .userInitiated).async {
            _ = store.begin(conversationID: conversationID, turnID: turnID, workspace: workspace)
            job.complete()
        }
    }

    public func waitForTurnSnapshot(conversationID: String, turnID: String) async {
        await takePendingSnapshot(conversationID: conversationID, turnID: turnID)?.waitSuspending()
    }

    private func takePendingSnapshot(conversationID: String, turnID: String) -> SnapshotJob? {
        pendingSnapshotsLock.lock()
        let job = pendingSnapshots.removeValue(forKey: snapshotJobKey(conversationID, turnID))
        pendingSnapshotsLock.unlock()
        return job
    }

    private func waitForPendingSnapshot(conversationID: String, turnID: String) {
        takePendingSnapshot(conversationID: conversationID, turnID: turnID)?.waitBlocking()
    }

    @discardableResult
    public func beginTurn(
        conversationID: String,
        turnID: String,
        workspace: URL?
    ) -> Bool {
        guard let workspace else { return false }
        return snapshotStore.begin(
            conversationID: conversationID,
            turnID: turnID,
            workspace: workspace
        )
    }

    public func finishTurn(
        conversationID: String,
        turnID: String,
        workspace: URL?
    ) -> [ChangedFile] {
        finishTurnResult(conversationID: conversationID, turnID: turnID, workspace: workspace).changedFiles
    }

    func finishTurnResult(
        conversationID: String,
        turnID: String,
        workspace: URL?
    ) -> WorkspaceChangeResult {
        guard let workspace else {
            return WorkspaceChangeResult(changedFiles: [], trackingStatus: "incomplete", failureReason: "Workspace snapshot was unavailable.")
        }
        waitForPendingSnapshot(conversationID: conversationID, turnID: turnID)
        return snapshotStore.finishResult(
            conversationID: conversationID,
            turnID: turnID,
            workspace: workspace
        )
    }

    /// Same result without freezing the UI: the pre-turn capture is awaited by
    /// suspending, and the after-capture walks and hashes the whole tree on a
    /// worker thread instead of on the main actor.
    func finishTurnResultAsync(
        conversationID: String,
        turnID: String,
        workspace: URL?
    ) async -> WorkspaceChangeResult {
        guard let workspace else {
            return WorkspaceChangeResult(changedFiles: [], trackingStatus: "incomplete", failureReason: "Workspace snapshot was unavailable.")
        }
        await waitForTurnSnapshot(conversationID: conversationID, turnID: turnID)
        let store = snapshotStore
        return await Task.detached(priority: .userInitiated) {
            store.finishResult(
                conversationID: conversationID,
                turnID: turnID,
                workspace: workspace
            )
        }.value
    }

    public func hasCompleteTurnSnapshot(
        conversationID: String,
        turnID: String,
        workspace: URL?
    ) -> Bool {
        guard let workspace else { return false }
        let key = "\(conversationID)|\(turnID)|\(workspace.standardizedFileURL.path)"
        if completeSnapshotTurns.contains(key) { return true }
        let complete = snapshotStore.hasCompleteSnapshot(
            conversationID: conversationID,
            turnID: turnID,
            workspace: workspace
        )
        if complete { completeSnapshotTurns.insert(key) }
        return complete
    }

    public func hasUndoableTurnSnapshot(
        conversationID: String,
        turnID: String,
        workspace: URL
    ) -> Bool {
        snapshotStore.hasUndoableSnapshot(
            conversationID: conversationID,
            turnID: turnID,
            workspace: workspace
        )
    }

    public func restoreTurns(
        conversationID: String,
        turnIDs: [String],
        workspace: URL?,
        abortOnConflict: Bool
    ) throws -> RewindResult {
        guard let workspace else { throw WorkspaceMemoryError.noWorkspace }
        completeSnapshotTurns.removeAll()
        do {
            return try snapshotStore.restore(
                conversationID: conversationID,
                turnIDs: turnIDs,
                workspace: workspace,
                abortOnConflict: abortOnConflict
            )
        } catch let error as WorkspaceSnapshotError {
            switch error {
            case .restoreFailed(let path):
                throw WorkspaceMemoryError.snapshotRestoreFailed(path)
            case .unavailable, .unsupportedEntry, .invalidPath:
                throw WorkspaceMemoryError.snapshotUnavailable
            }
        } catch {
            throw WorkspaceMemoryError.snapshotUnavailable
        }
    }

    public func removeTurnSnapshots(conversationID: String) {
        completeSnapshotTurns.removeAll()
        snapshotStore.removeConversation(conversationID)
    }

    /// Project facts that move only when the project does. Nothing here depends on
    /// the prompt or counts events, so a conversation captures it once and again
    /// only after a real change.
    public func projectText() -> String {
        guard manifest != nil else { return "" }
        let decisions = markdownList(state["acceptedDecisions"] as? [[String: Any]] ?? [])
        let proposals = markdownList(state["pendingProposals"] as? [[String: Any]] ?? [], prefix: "Proposal")
        let defaults = markdownDictionary(projectDefaults)
        let elsewhere = markdownDictionary(foreignFacts("decision", knownKeys: []))
        let backlog = backlogText()
        return [
            "Private project context. It is verified by the native host.",
            "Current user instructions are authoritative over this context.",
            "\n## Project map\n\(mapText)",
            "\n## Accepted project decisions\n\(decisions.isEmpty ? "None" : decisions)",
            "\n## Project defaults\n\(defaults.isEmpty ? "None" : defaults)",
            elsewhere.isEmpty ? "" : "\n## Decisions recorded on another device\n\(elsewhere)",
            backlog.isEmpty ? "" : "\n## Unfinished work (backlog)\n\(backlog)\n\nIf the current request continues one of these, resume it. When you finish a reply that leaves work open, end with a line `BACKLOG: <what is left>` and ask the user whether to continue. When an item above is done, write `BACKLOG-DONE: <task id>`.",
            proposals.isEmpty ? "" : "\n## Unauthoritative proposals\n\(proposals)",
        ].filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// What depends on the prompt. Kept apart from `projectText` so that its churn
    /// re-captures only this. Which chats were archived or deleted is not here: that
    /// list grew without bound and moved with every such action; the vault shows it.
    public func historyText(for prompt: String) -> String {
        guard manifest != nil else { return "" }
        let tasksText = relevantTasks(for: prompt)
        return tasksText.isEmpty ? "" : "## Relevant task history\n\(tasksText)"
    }

    /// Everything the vault knows, in one text. The prompt sends the parts as
    /// separate sections; see `AgentBridge.systemPromptSections`.
    public func snapshot(for prompt: String) -> MemorySnapshot {
        guard manifest != nil else { return MemorySnapshot(text: "", revision: 0) }
        let preferences = preferencesText()
        let body = [
            projectText(),
            preferences.isEmpty ? "" : "## Current actor preferences\n\(preferences)",
            historyText(for: prompt),
        ].filter { !$0.isEmpty }.joined(separator: "\n\n")
        return MemorySnapshot(text: trimSnapshot(body), revision: revision)
    }
}

// Copyright (c) 2026 DOTS
// Write-lease conflicts: waiting for another chat's run, and asking what to do.

import Foundation
import Observation

/// What the user wants to happen when a run wants to write something another
/// running chat has already claimed.
public enum WorkspaceConflictPolicy: String, CaseIterable, Identifiable, Codable, Sendable {
    /// Wait silently for a while, and only ask when the other run is still holding it.
    case waitThenAsk
    /// Ask as soon as the collision is noticed.
    case ask
    /// Never ask: hold the run until the other one finishes.
    case waitOnly

    public var id: String { rawValue }
    public var title: String { AppCopy.text("conflict.policy.\(rawValue)") }
    public var detail: String { AppCopy.text("conflict.policy.\(rawValue).detail") }

    public static let defaultWaitSeconds = 30
    public static let waitChoices: [Int] = [10, 30, 60, 120]

    /// A stopped run needs a moment to drop its leases; waiting longer than this
    /// would hang on a run that never held the file at all.
    static let stopReleaseGrace = TimeInterval(10)
    /// How long a stopped run is given to release its own leases before they are
    /// dropped on its behalf. A write in flight needs far less; a shell command that
    /// ignores its cancel latch is what spends the whole of it.
    static let cooperativeStopSeconds = TimeInterval(3)
    /// Asking three times is already a conversation; past that the user is not
    /// answering and the file should be left alone.
    static let maximumAskRounds = 3
}

/// The answer the user gives to a collision.
public enum WorkspaceConflictChoice: String, Sendable, Equatable {
    case keepWaiting
    case stopHolder
    case stopAllOthers
    case skip
}

/// A collision shown to the user: this run wants `path`, `holderTitle` holds it.
public struct PendingConflict: Sendable, Equatable, Identifiable {
    public let conversationID: String
    public let toolCallID: String
    public let path: String
    public let holderConversationID: String
    public let holderTitle: String
    public let heldSeconds: Int
    /// How many other conversations of this project are running, so the banner can
    /// offer stopping all of them rather than only the one it knows about.
    public let otherRunningConversations: Int

    public var id: String { toolCallID }

    public init(
        conversationID: String,
        toolCallID: String,
        path: String,
        holderConversationID: String,
        holderTitle: String,
        heldSeconds: Int,
        otherRunningConversations: Int
    ) {
        self.conversationID = conversationID
        self.toolCallID = toolCallID
        self.path = path
        self.holderConversationID = holderConversationID
        self.holderTitle = holderTitle
        self.heldSeconds = heldSeconds
        self.otherRunningConversations = otherRunningConversations
    }
}

/// The result of asking for a write lease. `.held` carries what is needed to
/// release it again, plus a note worth showing to the model when the run had to
/// wait or another chat had to be stopped.
enum WorkspaceLeaseOutcome {
    case held(target: WorkspaceLeaseTarget, ticket: UInt64, notice: String?)
    /// The call writes nothing another run could collide with.
    case free
    /// The call must not run; the text is what the model is told.
    case refused(String)
}

extension NativeAgentHost {
    public func setWorkspaceConflictPolicy(_ policy: WorkspaceConflictPolicy) {
        workspaceConflictPolicy = policy
    }

    public func setConflictWaitSeconds(_ seconds: Int) {
        conflictWaitSeconds = max(0, seconds)
    }

    /// Takes the write lease one mutating call needs, deferring the first default-
    /// policy collision so the agent can finish independent work before retrying.
    /// The caller passes the result straight to
    /// `releaseWorkspaceLease`, which ignores the cases that hold nothing.
    func acquireWorkspaceLease(
        for call: AgentToolCall,
        workspace: URL,
        conversationID: String,
        runID: UUID
    ) async -> WorkspaceLeaseOutcome {
        guard let target = WorkspaceLeases.shared.target(
            for: call.name,
            arguments: Self.arguments(of: call),
            workspace: workspace
        ) else { return .free }
        let label = leaseLabel(for: call, workspace: workspace)
        if let granted = tryTakeLease(target, call: call, conversationID: conversationID, runID: runID, label: label) {
            return granted
        }

        if workspaceConflictPolicy == .waitThenAsk,
           !WorkspaceLeases.shared.isFinalCheckRequested(target, conversationID: conversationID) {
            if let holder = WorkspaceLeases.shared.holder(for: target, excluding: conversationID) {
                WorkspaceLeases.shared.deferWrite(target, conversationID: conversationID, label: label)
                return .refused(
                    "WRITE NOT RUN: \(holder.conversationTitle) is using \(label). Keep this change pending, "
                        + "finish the other independent work, then reread \(label) and retry this exact write once at the end. "
                        + "The app will ask the user only if the final recheck is still blocked. Do not overwrite or skip it."
                )
            }
            // The holder may have released the lease between the first attempt and
            // inspection. Take it now if it stayed free.
            if let granted = tryTakeLease(target, call: call, conversationID: conversationID, runID: runID, label: label) {
                return granted
            }
            if let holder = WorkspaceLeases.shared.holder(for: target, excluding: conversationID) {
                WorkspaceLeases.shared.deferWrite(target, conversationID: conversationID, label: label)
                return .refused(
                    "WRITE NOT RUN: \(holder.conversationTitle) is using \(label). Keep this change pending, "
                        + "finish the other independent work, then reread \(label) and retry this exact write once at the end. "
                        + "The app will ask the user only if the final recheck is still blocked. Do not overwrite or skip it."
                )
            }
        }

        let waitSeconds: TimeInterval? = switch workspaceConflictPolicy {
        case .waitThenAsk: TimeInterval(conflictWaitSeconds)
        case .waitOnly: nil
        case .ask: 0
        }
        if waitSeconds != 0 {
            switch await waitForLease(target, call: call, conversationID: conversationID, runID: runID, label: label, timeout: waitSeconds) {
            case .cancelled:
                return .refused(AppCopy.format("conflict.stillBusy", label))
            case .taken(let granted):
                return granted.withWaitNotice()
            case .stillHeld:
                // Still held when the silent wait ran out: `waitOnly` gives up, the
                // asking policies go to the user.
                if workspaceConflictPolicy == .waitOnly {
                    return .refused(AppCopy.format("conflict.stillBusy", label))
                }
            }
        } else if workspaceConflictPolicy == .waitOnly {
            return .refused(AppCopy.format("conflict.stillBusy", label))
        }
        let outcome = await askForLease(target, label: label, call: call, conversationID: conversationID, runID: runID)
        WorkspaceLeases.shared.clearDeferredWrite(target, conversationID: conversationID)
        return outcome
    }

    func releaseWorkspaceLease(_ outcome: WorkspaceLeaseOutcome) {
        guard case .held(let target, let ticket, _) = outcome else { return }
        WorkspaceLeases.shared.release(target: target, ticket: ticket)
    }

    /// Ends every lease and wait of a conversation that is stopping or being deleted.
    func dropWorkspaceLeases(conversationID: String) {
        if let run = runStates[conversationID] {
            if run.pendingConflict != nil {
                AgentRunScope.$conversationID.withValue(conversationID) { finishConflict(.skip) }
            }
            run.waitingOnLease = nil
        }
        WorkspaceLeases.shared.releaseAll(conversationID: conversationID)
    }

    public func answerConflict(_ choice: WorkspaceConflictChoice, in conversationID: String? = nil) {
        let owner = conversationID ?? pendingConflict?.conversationID
        guard let owner else { return }
        AgentRunScope.$conversationID.withValue(owner) { finishConflict(choice) }
    }

    func finishConflict(_ choice: WorkspaceConflictChoice) {
        guard pendingConflict != nil else { return }
        pendingConflict = nil
        let continuation = conflictContinuation
        conflictContinuation = nil
        continuation?.resume(returning: choice)
    }

    // MARK: - Waiting and asking

    private enum LeaseWaitResult {
        case cancelled
        /// This run holds the lease now.
        case taken(WorkspaceLeaseOutcome)
        /// Another conversation still holds it.
        case stillHeld
    }

    /// Grants the lease now, or `nil` when another conversation still holds it.
    private func tryTakeLease(
        _ target: WorkspaceLeaseTarget,
        call: AgentToolCall,
        conversationID: String,
        runID: UUID,
        label: String
    ) -> WorkspaceLeaseOutcome? {
        guard case .granted(let ticket) = WorkspaceLeases.shared.tryAcquire(
            target,
            conversationID: conversationID,
            conversationTitle: conversationTitle(for: conversationID),
            runID: runID,
            toolName: call.name,
            label: label
        ) else { return nil }
        return .held(target: target, ticket: ticket, notice: nil)
    }

    /// Shows the waiting state, blocks until the lease is free or `timeout` passes,
    /// and takes it if that worked out.
    private func waitForLease(
        _ target: WorkspaceLeaseTarget,
        call: AgentToolCall,
        conversationID: String,
        runID: UUID,
        label: String,
        timeout: TimeInterval?
    ) async -> LeaseWaitResult {
        waitingOnLease = WorkspaceLeases.shared.holder(for: target, excluding: conversationID)
        // Whoever gets here first - the release, the deadline or the cancel - the
        // lease is taken (or refused) by the look below, so the answer itself is
        // not what decides.
        _ = await WorkspaceLeases.shared.waitUntilFree(
            target,
            conversationID: conversationID,
            timeout: timeout,
            isCancelled: { Task.isCancelled }
        )
        waitingOnLease = nil
        if Task.isCancelled { return .cancelled }
        if let granted = tryTakeLease(target, call: call, conversationID: conversationID, runID: runID, label: label) {
            return .taken(granted)
        }
        return .stillHeld
    }

    /// Asks, acts on the answer and retries, until the lease is ours or the user has
    /// clearly said to leave the file to the other conversation.
    private func askForLease(
        _ target: WorkspaceLeaseTarget,
        label: String,
        call: AgentToolCall,
        conversationID: String,
        runID: UUID
    ) async -> WorkspaceLeaseOutcome {
        let stillBusy = AppCopy.format("conflict.stillBusy", label)
        for _ in 1...WorkspaceConflictPolicy.maximumAskRounds {
            if Task.isCancelled { return .refused(stillBusy) }
            guard let holder = WorkspaceLeases.shared.holder(for: target, excluding: conversationID) else {
                // It came free between the last refusal and this look.
                if let granted = tryTakeLease(target, call: call, conversationID: conversationID, runID: runID, label: label) {
                    return granted.withWaitNotice()
                }
                return .refused(stillBusy)
            }
            let choice = await requestConflictChoice(
                target: target,
                label: label,
                holder: holder,
                call: call,
                conversationID: conversationID
            )
            switch choice {
            case .skip:
                return .refused(AppCopy.format("conflict.userSkipped", label, holder.conversationTitle))
            case .keepWaiting:
                if case .taken(let granted) = await waitForLease(
                    target, call: call, conversationID: conversationID, runID: runID, label: label, timeout: nil
                ) {
                    return granted.withWaitNotice()
                }
            case .stopHolder:
                signalStop(holder.conversationID)
                await releasedAfterStop(holder.conversationID)
                if let granted = await takeAfterStop(target, call: call, conversationID: conversationID, runID: runID, label: label) {
                    return granted.withWaitNotice(AppCopy.format("conflict.stoppedHolder", holder.conversationTitle))
                }
            case .stopAllOthers:
                let others = otherRunningConversationIDs(inWorkspaceOf: target, excluding: conversationID)
                others.forEach { signalStop($0) }
                for other in others { await releasedAfterStop(other) }
                if let granted = await takeAfterStop(target, call: call, conversationID: conversationID, runID: runID, label: label) {
                    return granted.withWaitNotice(AppCopy.text("conflict.stoppedOthers"))
                }
            }
        }
        return .refused(stillBusy)
    }

    private func takeAfterStop(
        _ target: WorkspaceLeaseTarget,
        call: AgentToolCall,
        conversationID: String,
        runID: UUID,
        label: String
    ) async -> WorkspaceLeaseOutcome? {
        _ = await WorkspaceLeases.shared.waitUntilFree(
            target,
            conversationID: conversationID,
            timeout: WorkspaceConflictPolicy.stopReleaseGrace,
            isCancelled: { Task.isCancelled }
        )
        return tryTakeLease(target, call: call, conversationID: conversationID, runID: runID, label: label)
    }

    private func requestConflictChoice(
        target: WorkspaceLeaseTarget,
        label: String,
        holder: WorkspaceLeaseHolder,
        call: AgentToolCall,
        conversationID: String
    ) async -> WorkspaceConflictChoice {
        let pending = PendingConflict(
            conversationID: conversationID,
            toolCallID: call.id,
            path: label,
            holderConversationID: holder.conversationID,
            holderTitle: holder.conversationTitle,
            heldSeconds: max(0, Int(Date().timeIntervalSince(holder.startedAt))),
            otherRunningConversations: otherRunningConversationIDs(inWorkspaceOf: target, excluding: conversationID).count
        )
        pendingConflict = pending
        notifyAttention(.conflict, in: conversationID, detail: AppCopy.format("conflict.title", label))
        onRemoteEvent?("conflict.required", [
            "conversationId": conversationID,
            "toolCallId": call.id,
            "path": label,
            "holderConversationId": holder.conversationID,
            "holderTitle": holder.conversationTitle,
        ])
        let choice = await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { (continuation: CheckedContinuation<WorkspaceConflictChoice, Never>) in
                guard !Task.isCancelled, pendingConflict?.id == pending.id else {
                    continuation.resume(returning: .skip)
                    return
                }
                conflictContinuation = continuation
            }
        }, onCancel: { [weak self] in
            Task { @MainActor [weak self] in self?.finishConflict(.skip) }
        })
        onRemoteEvent?("conflict.resolved", [
            "conversationId": conversationID,
            "toolCallId": call.id,
            "choice": choice.rawValue,
        ])
        return choice
    }

    /// Stops one other conversation's run, exactly as its own stop button would.
    private func signalStop(_ conversationID: String) {
        guard runStates[conversationID]?.isBusy == true else { return }
        AgentRunScope.$conversationID.withValue(conversationID) { stopCurrentRun() }
    }

    /// A write that is already in flight cannot be taken back, so a stopped run gets
    /// a moment to drop its own claims before they are released by force: the
    /// waiting chat must never claim a file that is open for write right now. A
    /// long-canceling command is the case the grace covers.
    private func releasedAfterStop(_ conversationID: String) async {
        if await WorkspaceLeases.shared.waitForRelease(
            conversationID: conversationID,
            timeout: WorkspaceConflictPolicy.cooperativeStopSeconds
        ) == false {
            WorkspaceLeases.shared.releaseAll(conversationID: conversationID)
        }
    }

    private func otherRunningConversationIDs(inWorkspaceOf target: WorkspaceLeaseTarget, excluding conversationID: String) -> [String] {
        let root = target.rootPath
        return conversations.compactMap { conversation in
            guard conversation.id != conversationID, let cwd = conversation.cwd else { return nil }
            guard cwd == root || cwd.hasPrefix(root + "/") || root.hasPrefix(cwd) else { return nil }
            return runStates[conversation.id]?.isBusy == true ? conversation.id : nil
        }
    }

    private func conversationTitle(for conversationID: String) -> String {
        conversations.first { $0.id == conversationID }?.title ?? conversationID
    }

    /// The path as the model named it, so the banner and the tool result speak the
    /// same language as the workspace.
    private func leaseLabel(for call: AgentToolCall, workspace: URL) -> String {
        let arguments = Self.arguments(of: call)
        if let path = arguments["path"] as? String ?? arguments["destination_path"] as? String {
            return path
        }
        if let command = arguments["command"] as? String {
            return AppCopy.format("conflict.wholeProject", String(command.prefix(40)))
        }
        return workspace.lastPathComponent
    }

    static func arguments(of call: AgentToolCall) -> [String: Any] {
        guard let data = call.arguments.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }
}

private extension WorkspaceLeaseOutcome {
    func withWaitNotice(_ notice: String? = nil) -> WorkspaceLeaseOutcome {
        guard case .held(let target, let ticket, let existing) = self else { return self }
        return .held(target: target, ticket: ticket, notice: notice ?? existing)
    }
}

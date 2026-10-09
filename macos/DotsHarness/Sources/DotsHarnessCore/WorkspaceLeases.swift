// Copyright (c) 2026 DOTS
// Write leases that keep two running conversations off the same workspace file.

import Foundation

/// What a run wants to write: one canonical file, or the whole workspace when a
/// shell command can reach anything in it (`rm`, `git clean`).
enum WorkspaceLeaseTarget: Equatable, Sendable {
    case file(root: String, path: String)
    case workspace(root: String)

    var key: String {
        switch self {
        case .file(_, let path): return "file:" + path
        case .workspace(let root): return "workspace:" + root
        }
    }

    var rootPath: String {
        switch self {
        case .file(let root, _): return root
        case .workspace(let root): return root
        }
    }
}

/// The run that holds a lease, shown to whoever has to wait for it.
public struct WorkspaceLeaseHolder: Equatable, Sendable {
    public let conversationID: String
    public let conversationTitle: String
    public let runID: UUID
    public let toolName: String
    public let label: String
    public let workspaceRoot: String
    public let startedAt: Date

    init(
        conversationID: String,
        conversationTitle: String,
        runID: UUID,
        toolName: String,
        label: String,
        workspaceRoot: String,
        startedAt: Date
    ) {
        self.conversationID = conversationID
        self.conversationTitle = conversationTitle
        self.runID = runID
        self.toolName = toolName
        self.label = label
        self.workspaceRoot = workspaceRoot
        self.startedAt = startedAt
    }
}

/// Whether a lease request was granted, or who is standing in the way.
enum WorkspaceLeaseRequest {
    case granted(ticket: UInt64)
    case contested(holder: WorkspaceLeaseHolder)
}

/// One waiter per contested lease. Whoever reaches it first — the release or the
/// deadline — settles it exactly once, so a continuation can never be resumed
/// twice or left suspended forever.
private final class LeaseGate: @unchecked Sendable {
    private final class Waiter: @unchecked Sendable {
        let continuation: CheckedContinuation<Bool, Never>
        var settled = false

        init(_ continuation: CheckedContinuation<Bool, Never>) {
            self.continuation = continuation
        }
    }

    private let condition = NSCondition()
    private var released = false
    private var waiters: [Waiter] = []

    func complete() {
        condition.lock()
        released = true
        let pending = waiters
        waiters = []
        for waiter in pending { waiter.settled = true }
        condition.unlock()
        pending.forEach { $0.continuation.resume(returning: true) }
    }

    /// `true` once the lease came free, `false` when `timeout` ran out first. The
    /// caller re-checks the registry after either answer, so a timeout that races a
    /// release only costs one more look.
    func wait(timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            condition.lock()
            if released {
                condition.unlock()
                continuation.resume(returning: true)
                return
            }
            let waiter = Waiter(continuation)
            waiters.append(waiter)
            condition.unlock()
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout) { [weak self, weak waiter] in
                guard let self, let waiter else { return }
                self.condition.lock()
                let isOurs = !waiter.settled && !self.released
                if isOurs {
                    waiter.settled = true
                    self.waiters.removeAll { $0 === waiter }
                }
                self.condition.unlock()
                if isOurs { waiter.continuation.resume(returning: false) }
            }
        }
    }
}

/// Session-wide registry of workspace write leases.
///
/// Inside one turn the mutation tools already run one after another, so the real
/// exposure is two conversations of the same project running at the same time:
/// each holds its own view of a file, and the second write silently discards the
/// first. A lease is held for the duration of one mutating tool call, which also
/// closes the window between the stale-content check and the write itself.
///
/// Waits are always taken with a deadline and re-checked, so a cancelled or deleted
/// run can never leave a suspended continuation behind.
public final class WorkspaceLeases: @unchecked Sendable {
    static let shared = WorkspaceLeases()

    /// How long one look at a contested lease blocks before it re-checks the
    /// registry and the caller's cancellation. Half a second is what a stopped run
    /// waits at worst before it lets go of the file it was parked on.
    private static let waitSlice = TimeInterval(0.5)

    private struct Entry {
        let ticket: UInt64
        let root: String
        let coversWholeWorkspace: Bool
        let holder: WorkspaceLeaseHolder
        let gate: LeaseGate
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var ticketCounter: UInt64 = 0

    /// Which paths a tool call would write. A call that cannot be mapped to a path
    /// takes no lease, so an unrecognised tool keeps behaving as it did.
    func target(for toolName: String, arguments: [String: Any], workspace: URL) -> WorkspaceLeaseTarget? {
        let root = workspace.standardizedFileURL.resolvingSymlinksInPath().path
        switch toolName {
        case "write_file", "remove_file":
            guard let path = arguments["path"] as? String else { return nil }
            return .file(root: root, path: WorkspaceTools.canonicalLeasePath(path, workspace: workspace))
        case WorkspaceTools.generatedMediaName:
            guard let path = arguments["destination_path"] as? String else { return nil }
            return .file(root: root, path: WorkspaceTools.canonicalLeasePath(path, workspace: workspace))
        case "run_command":
            // Only commands that can delete or reset the tree claim the whole
            // workspace; a build or a test run must not freeze the other chats.
            guard WorkspaceTools.mayDeleteFiles(arguments["command"] as? String) else { return nil }
            return .workspace(root: root)
        default:
            return nil
        }
    }

    func tryAcquire(
        _ target: WorkspaceLeaseTarget,
        conversationID: String,
        conversationTitle: String,
        runID: UUID,
        toolName: String,
        label: String
    ) -> WorkspaceLeaseRequest {
        lock.lock(); defer { lock.unlock() }
        if let holder = conflictingEntry(for: target, conversationID: conversationID)?.holder {
            return .contested(holder: holder)
        }
        ticketCounter &+= 1
        entries[target.key] = Entry(
            ticket: ticketCounter,
            root: target.rootPath,
            coversWholeWorkspace: target.key.hasPrefix("workspace:"),
            holder: WorkspaceLeaseHolder(
                conversationID: conversationID,
                conversationTitle: conversationTitle,
                runID: runID,
                toolName: toolName,
                label: label,
                workspaceRoot: target.rootPath,
                startedAt: Date()
            ),
            gate: LeaseGate()
        )
        return .granted(ticket: ticketCounter)
    }

    /// Releases only its own lease, so a late release from a finished call cannot
    /// drop a holder that arrived in between.
    func release(target: WorkspaceLeaseTarget, ticket: UInt64) {
        lock.lock()
        guard let entry = entries[target.key], entry.ticket == ticket else {
            lock.unlock()
            return
        }
        entries[target.key] = nil
        lock.unlock()
        entry.gate.complete()
    }

    /// Drops every lease of one conversation: called when its run ends, stops or is
    /// deleted, so an abandoned run cannot hold a file hostage.
    func releaseAll(conversationID: String) {
        lock.lock()
        let owned = entries.filter { $0.value.holder.conversationID == conversationID }
        for key in owned.keys { entries[key] = nil }
        lock.unlock()
        owned.values.forEach { $0.gate.complete() }
    }

    /// True while a conversation still holds a lease it has not released itself.
    func holds(conversationID: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return entries.values.contains { $0.holder.conversationID == conversationID }
    }

    /// Watches a stopped run let go of its own leases, so another chat never claims
    /// a file that is open for write right now. `false` means the timeout passed
    /// with the conversation still holding something.
    func waitForRelease(conversationID: String, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while holds(conversationID: conversationID) {
            if Date() >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return true
    }

    func holder(for target: WorkspaceLeaseTarget, excluding conversationID: String) -> WorkspaceLeaseHolder? {
        lock.lock(); defer { lock.unlock() }
        return conflictingEntry(for: target, conversationID: conversationID)?.holder
    }

    /// Waits until no other conversation stands in the way of this target.
    /// `false` means the deadline passed or the caller gave up; the lease still has
    /// to be taken with `tryAcquire`, because a third run may have won it since.
    func waitUntilFree(
        _ target: WorkspaceLeaseTarget,
        conversationID: String,
        timeout: TimeInterval?,
        isCancelled: @Sendable () -> Bool = { false }
    ) async -> Bool {
        let deadline = timeout.map { Date().addingTimeInterval($0) }
        while true {
            guard let gate = conflictingGate(for: target, conversationID: conversationID) else { return true }
            if isCancelled() { return false }
            // One look blocks only until the next reason to look again: the slice
            // bounds how long an interrupted run takes to notice, and the deadline
            // how long a silent wait takes - which must be the wait the user set.
            let slice = deadline.map { min(Self.waitSlice, $0.timeIntervalSinceNow) } ?? Self.waitSlice
            if slice <= 0 { return false }
            if await gate.wait(timeout: slice) { continue }
            if let deadline, Date() >= deadline { return false }
        }
    }

    /// The gate of whoever blocks `target`, taken under the lock so the wait itself
    /// can happen off it.
    private func conflictingGate(for target: WorkspaceLeaseTarget, conversationID: String) -> LeaseGate? {
        lock.lock(); defer { lock.unlock() }
        return conflictingEntry(for: target, conversationID: conversationID)?.gate
    }

    /// The entry that blocks `target`. Two requests from the *same* conversation
    /// never block each other: a run may nest, and a chat must not deadlock on the
    /// lease it already holds.
    private func conflictingEntry(for target: WorkspaceLeaseTarget, conversationID: String) -> Entry? {
        let root = target.rootPath
        if let own = entries[target.key], own.holder.conversationID != conversationID { return own }
        for entry in entries.values where entry.holder.conversationID != conversationID && entry.root == root {
            // A workspace-wide command covers every file under it, and a pending
            // file write collides with a command that could delete it.
            if entry.coversWholeWorkspace || target.key.hasPrefix("workspace:") { return entry }
        }
        return nil
    }
}

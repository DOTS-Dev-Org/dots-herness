// Copyright (c) 2026 DOTS
// Sandbox enter/exit, conflict resolution and recovery.

import AppKit
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import HarnessPluginKit

@MainActor
extension AppModel {
    // MARK: - Sandbox

    /// Point the agent at a git worktree of the current workspace. The user's
    /// own checkout is left exactly as it is.
    public func enterSandbox(named name: String) {
        guard activeSandbox == nil else {
            sandboxNotice = SandboxWorkspaceError.activeOperationInProgress.localizedDescription
            return
        }
        guard !sandboxRecoveryRequired else {
            sandboxNotice = "Recover the saved sandbox before starting another one."
            return
        }
        guard !bridge.anyRunBusy, !bridge.historyMutationBusy else {
            sandboxNotice = SandboxWorkspaceError.activeOperationInProgress.localizedDescription
            return
        }
        let origin = workspacePath
        guard !origin.isEmpty else {
            sandboxNotice = "Open a workspace first."
            return
        }
        guard SandboxProfile.isAvailable else {
            sandboxNotice = "sandbox-exec is unavailable; the sandbox was not started."
            return
        }
        do {
            let sandbox = try SandboxWorkspaces.enter(origin: origin, name: name)
            let status = SandboxWorkspaces.git(
                ["status", "--porcelain", "--untracked-files=all"],
                in: URL(fileURLWithPath: origin, isDirectory: true)
            )
            let uncommitted = status.status != 0 || !status.text.isEmpty
            setWorkspace(sandbox.path)
            activeSandbox = sandbox
            refreshSandboxWritableRoots()
            sandboxConflict = nil
            sandboxResolutionPreview = nil
            sandboxCleanupPending = false
            sandboxCleanupMerge = true
            sandboxRecoveryRequired = false
            clearPersistedSandboxConflict()
            bridge.setSandboxPolicy(sandboxExecutionPolicy, branch: sandbox.branch)
            persistSandboxState(sandbox)
            sandboxNotice = uncommitted
                ? "Sandbox '\(sandbox.name)' started from the last commit. Your uncommitted changes stayed in \(origin) and are not visible to the agent."
                : "Sandbox '\(sandbox.name)' started."
        } catch {
            sandboxNotice = error.localizedDescription
        }
    }

    public func recoverSandbox(_ candidate: SandboxWorkspace) {
        guard activeSandbox == nil else {
            sandboxNotice = SandboxWorkspaceError.activeOperationInProgress.localizedDescription
            return
        }
        guard !bridge.anyRunBusy, !bridge.historyMutationBusy else {
            sandboxNotice = SandboxWorkspaceError.activeOperationInProgress.localizedDescription
            return
        }
        guard SandboxProfile.isAvailable else {
            sandboxNotice = "sandbox-exec is unavailable; the sandbox was not recovered."
            return
        }
        do {
            let savedPath = host.settings.get("agent.sandbox.path")?.string
            let sandbox = try SandboxWorkspaces.restore(
                origin: candidate.originPath,
                path: candidate.path,
                name: candidate.name,
                originBranch: candidate.originBranch
            )
            let isSavedCandidate = savedPath.map {
                SandboxProfile.canonicalURL(URL(fileURLWithPath: $0, isDirectory: true)).path
            } == sandbox.path
            let restoredConflict = isSavedCandidate ? persistedSandboxConflict(for: sandbox) : nil
            let restoredCleanupPending = isSavedCandidate && sandboxCleanupPending
            let restoredCleanupMerge = restoredCleanupPending ? sandboxCleanupMerge : true
            setWorkspace(sandbox.path, allowSandboxTransition: true)
            activeSandbox = sandbox
            refreshSandboxWritableRoots()
            sandboxConflict = restoredConflict
            sandboxResolutionPreview = nil
            sandboxCleanupPending = restoredCleanupPending
            sandboxCleanupMerge = restoredCleanupMerge
            sandboxRecoveryRequired = false
            if !isSavedCandidate { clearPersistedSandboxConflict() }
            bridge.setSandboxPolicy(sandboxExecutionPolicy, branch: sandbox.branch)
            persistSandboxState(sandbox)
            sandboxNotice = "Sandbox '\(sandbox.name)' recovered."
        } catch {
            sandboxNotice = "Sandbox recovery failed: \(error.localizedDescription)"
        }
    }

    public func retrySandboxRecovery() {
        guard let sandbox = activeSandbox, sandboxRecoveryRequired else { return }
        guard !bridge.anyRunBusy, !bridge.historyMutationBusy, !sandboxResolutionBusy else {
            sandboxNotice = "Finish the active agent operation before retrying recovery."
            return
        }
        do {
            try SandboxWorkspaces.validateReady(sandbox)
            setWorkspace(sandbox.path, allowSandboxTransition: true)
            refreshSandboxWritableRoots()
            sandboxRecoveryRequired = false
            bridge.setSandboxPolicy(sandboxExecutionPolicy, branch: sandbox.branch)
            persistSandboxState(sandbox)
            sandboxNotice = "Sandbox recovery completed."
        } catch {
            sandboxNotice = "Sandbox recovery still needs attention: \(error.localizedDescription)"
        }
    }

    /// Leave the sandbox. `merge: true` merges the sandbox branch into the
    /// origin checkout; a conflict aborts the merge and keeps the sandbox.
    public func exitSandbox(merge: Bool) {
        guard let sandbox = activeSandbox else { return }
        guard !bridge.anyRunBusy, !bridge.historyMutationBusy, !sandboxResolutionBusy, !sandboxRecoveryRequired else {
            sandboxNotice = sandboxRecoveryRequired
                ? "Recover the sandbox state before leaving it."
                : SandboxWorkspaceError.activeOperationInProgress.localizedDescription
            return
        }
        terminalManager.stopSessions(for: sandbox.path)
        bridge.stopAgentTerminals(for: sandbox.path)
        let requestedMerge = sandboxCleanupPending ? sandboxCleanupMerge : merge
        do {
            switch try SandboxWorkspaces.exit(sandbox, merge: requestedMerge) {
            case .conflicted(let conflict):
                // Still in the sandbox on purpose: nothing was applied, and the
                // work is only safe where it already is.
                sandboxNotice = "Merge conflicts, nothing applied. Resolve in \(sandbox.originPath): "
                    + conflict.files.joined(separator: ", ")
                sandboxConflict = conflict
                sandboxResolutionPreview = nil
                persistSandboxConflict(conflict)
                return
            case .merged(let commits):
                finishSandboxExit(sandbox, notice: commits == 0
                    ? "Sandbox '\(sandbox.name)' had no changes; removed."
                    : "Merged \(commits) commit(s) from '\(sandbox.name)'.")
            case .discarded:
                finishSandboxExit(
                    sandbox,
                    notice: "Sandbox '\(sandbox.name)' discarded. Branch \(sandbox.branch) still holds the work."
                )
            }
        } catch {
            if case SandboxWorkspaceError.cleanupFailed = error {
                sandboxCleanupPending = true
                sandboxCleanupMerge = requestedMerge
                persistSandboxState(sandbox)
            }
            if case SandboxWorkspaceError.mergeAbortFailed = error {
                sandboxRecoveryRequired = true
                persistSandboxState(sandbox)
            }
            sandboxNotice = error.localizedDescription
        }
    }

    private func finishSandboxExit(_ sandbox: SandboxWorkspace, notice: String) {
        activeSandbox = nil
        sandboxAgentWritableRoots = []
        sandboxConflict = nil
        sandboxResolutionPreview = nil
        sandboxResolutionBusy = false
        sandboxCleanupPending = false
        sandboxCleanupMerge = true
        sandboxRecoveryRequired = false
        host.settings.set("agent.sandbox.origin", .null)
        host.settings.set("agent.sandbox.path", .null)
        host.settings.set("agent.sandbox.name", .null)
        host.settings.set("agent.sandbox.branch", .null)
        host.settings.set("agent.sandbox.originBranch", .null)
        host.settings.set("agent.sandbox.cleanupPending", .null)
        host.settings.set("agent.sandbox.cleanupMerge", .null)
        host.settings.set("agent.sandbox.recoveryRequired", .null)
        clearPersistedSandboxConflict()
        setWorkspace(sandbox.originPath, allowSandboxTransition: true)
        sandboxNotice = notice
        persistSettings()
    }

    private func persistSandboxState(_ sandbox: SandboxWorkspace) {
        host.settings.set("agent.sandbox.origin", .string(sandbox.originPath))
        host.settings.set("agent.sandbox.path", .string(sandbox.path))
        host.settings.set("agent.sandbox.name", .string(sandbox.name))
        host.settings.set("agent.sandbox.branch", .string(sandbox.branch))
        host.settings.set("agent.sandbox.originBranch", .string(sandbox.originBranch))
        host.settings.set("agent.sandbox.cleanupPending", .bool(sandboxCleanupPending))
        host.settings.set("agent.sandbox.cleanupMerge", .bool(sandboxCleanupMerge))
        host.settings.set("agent.sandbox.recoveryRequired", .bool(sandboxRecoveryRequired))
        persistSettings()
    }

    private func persistSandboxConflict(_ conflict: SandboxConflict) {
        host.settings.set("agent.sandbox.conflict.originBranch", .string(conflict.originBranch))
        host.settings.set("agent.sandbox.conflict.originHead", .string(conflict.originHead))
        host.settings.set("agent.sandbox.conflict.sandboxHead", .string(conflict.sandboxHead))
        host.settings.set("agent.sandbox.conflict.files", .array(conflict.files.map(JSONValue.string)))
        persistSettings()
    }

    private func clearPersistedSandboxConflict() {
        host.settings.set("agent.sandbox.conflict.originBranch", .null)
        host.settings.set("agent.sandbox.conflict.originHead", .null)
        host.settings.set("agent.sandbox.conflict.sandboxHead", .null)
        host.settings.set("agent.sandbox.conflict.files", .null)
    }

    private func persistedSandboxConflict(for sandbox: SandboxWorkspace) -> SandboxConflict? {
        guard let originHead = host.settings.get("agent.sandbox.conflict.originHead")?.string,
              let sandboxHead = host.settings.get("agent.sandbox.conflict.sandboxHead")?.string,
              let files = host.settings.get("agent.sandbox.conflict.files")?.array?.compactMap(\.string),
              !originHead.isEmpty,
              !sandboxHead.isEmpty,
              !files.isEmpty else { return nil }
        return SandboxConflict(
            sandbox: sandbox,
            originBranch: host.settings.get("agent.sandbox.conflict.originBranch")?.string ?? sandbox.originBranch,
            originHead: originHead,
            sandboxHead: sandboxHead,
            files: files
        )
    }

    public func retrySandboxCleanup() {
        guard let sandbox = activeSandbox, sandboxCleanupPending else { return }
        guard !bridge.anyRunBusy, !bridge.historyMutationBusy, !sandboxResolutionBusy, !sandboxRecoveryRequired else {
            sandboxNotice = SandboxWorkspaceError.activeOperationInProgress.localizedDescription
            return
        }
        terminalManager.stopSessions(for: sandbox.path)
        bridge.stopAgentTerminals(for: sandbox.path)
        do {
            try SandboxWorkspaces.retryCleanup(sandbox, originMerged: sandboxCleanupMerge)
            finishSandboxExit(sandbox, notice: "Sandbox '\(sandbox.name)' cleanup completed.")
        } catch {
            if case SandboxWorkspaceError.mergeAbortFailed = error {
                sandboxRecoveryRequired = true
                persistSandboxState(sandbox)
            }
            sandboxNotice = error.localizedDescription
        }
    }

    public func setSandboxNetworkAccess(_ enabled: Bool) {
        sandboxNetworkAccess = enabled
        host.settings.set("agent.sandbox.networkAccess", .bool(enabled))
        persistSettings()
        if activeSandbox != nil, !sandboxRecoveryRequired {
            bridge.setSandboxPolicy(sandboxExecutionPolicy, branch: activeSandbox?.branch)
        }
    }

    public func prepareSandboxResolution() {
        guard let conflict = sandboxConflict else { return }
        guard !bridge.anyRunBusy, !bridge.historyMutationBusy, !sandboxResolutionBusy, !sandboxRecoveryRequired else {
            sandboxNotice = sandboxRecoveryRequired
                ? "Recover the sandbox state before preparing a resolution."
                : SandboxWorkspaceError.activeOperationInProgress.localizedDescription
            return
        }
        terminalManager.stopSessions(for: conflict.sandbox.path)
        bridge.stopAgentTerminals(for: conflict.sandbox.path)
        sandboxResolutionBusy = true
        defer { sandboxResolutionBusy = false }
        do {
            try SandboxWorkspaces.prepareResolution(conflict)
            sandboxResolutionPreview = try SandboxWorkspaces.previewResolution(conflict)
            sandboxNotice = "Conflict resolution is ready in the sandbox."
        } catch {
            if case SandboxWorkspaceError.mergeAbortFailed = error {
                sandboxRecoveryRequired = true
                persistSandboxState(conflict.sandbox)
            }
            sandboxNotice = error.localizedDescription
        }
    }

    public func previewSandboxResolution() {
        guard let conflict = sandboxConflict else { return }
        guard !sandboxResolutionBusy else { return }
        do {
            sandboxResolutionPreview = try SandboxWorkspaces.previewResolution(conflict)
        } catch {
            if case SandboxWorkspaceError.mergeAbortFailed = error {
                sandboxRecoveryRequired = true
                persistSandboxState(conflict.sandbox)
            }
            sandboxNotice = error.localizedDescription
        }
    }

    public func askAgentToResolveSandboxConflict() async {
        guard let conflict = sandboxConflict else { return }
        guard !bridge.anyRunBusy, !bridge.historyMutationBusy, !sandboxResolutionBusy, !sandboxRecoveryRequired else {
            sandboxNotice = sandboxRecoveryRequired
                ? "Recover the sandbox state before asking for a resolution."
                : SandboxWorkspaceError.activeOperationInProgress.localizedDescription
            return
        }
        terminalManager.stopSessions(for: conflict.sandbox.path)
        bridge.stopAgentTerminals(for: conflict.sandbox.path)
        do {
            try SandboxWorkspaces.prepareResolution(conflict)
        } catch {
            if case SandboxWorkspaceError.mergeAbortFailed = error {
                sandboxRecoveryRequired = true
                persistSandboxState(conflict.sandbox)
            }
            sandboxNotice = error.localizedDescription
            return
        }

        sandboxResolutionPreview = nil
        sandboxResolutionBusy = true
        defer { sandboxResolutionBusy = false }
        let files = conflict.files.map { "- \($0)" }.joined(separator: "\n")
        await bridge.send(
            text: """
            Resolve this git merge conflict inside the active HerNess sandbox.
            Edit only these conflict files:
            \(files)
            Do not access the origin checkout. Do not run git add or git commit.
            Remove every conflict marker, run the relevant tests, and report what
            you changed. Leave the resolved files in the working tree for the host
            to stage and preview.
            """,
            mode: .queue
        )
        guard activeSandbox?.path == conflict.sandbox.path else { return }
        do {
            sandboxResolutionPreview = try SandboxWorkspaces.previewResolution(conflict)
            sandboxNotice = "Agent resolution is ready for review."
        } catch {
            if case SandboxWorkspaceError.mergeAbortFailed = error {
                sandboxRecoveryRequired = true
                persistSandboxState(conflict.sandbox)
            }
            sandboxNotice = error.localizedDescription
        }
    }

    public func applySandboxResolution() {
        guard let conflict = sandboxConflict,
              let preview = sandboxResolutionPreview else { return }
        guard !sandboxResolutionBusy, !bridge.anyRunBusy, !bridge.historyMutationBusy, !sandboxRecoveryRequired else {
            sandboxNotice = sandboxRecoveryRequired
                ? "Recover the sandbox state before approving the resolution."
                : SandboxWorkspaceError.activeOperationInProgress.localizedDescription
            return
        }
        guard !preview.isTruncated, preview.unresolvedFiles.isEmpty else {
            sandboxNotice = "The resolution must have no unresolved files and a complete preview."
            return
        }
        terminalManager.stopSessions(for: conflict.sandbox.path)
        bridge.stopAgentTerminals(for: conflict.sandbox.path)
        sandboxResolutionBusy = true
        defer { sandboxResolutionBusy = false }
        do {
            switch try SandboxWorkspaces.applyResolution(
                conflict,
                expectedFingerprint: preview.fingerprint
            ) {
            case .merged(let commits):
                finishSandboxExit(
                    conflict.sandbox,
                    notice: "Merged the approved sandbox resolution (\(commits) commit(s))."
                )
            case .conflicted(let nextConflict):
                sandboxConflict = nextConflict
                sandboxResolutionPreview = nil
                persistSandboxConflict(nextConflict)
                sandboxNotice = "The approved resolution conflicted again; nothing was applied."
            case .discarded:
                sandboxNotice = "The sandbox resolution was discarded."
            }
        } catch {
            if case SandboxWorkspaceError.cleanupFailed = error {
                sandboxCleanupPending = true
                sandboxCleanupMerge = true
                persistSandboxState(conflict.sandbox)
            }
            if case SandboxWorkspaceError.mergeAbortFailed = error {
                sandboxRecoveryRequired = true
                persistSandboxState(conflict.sandbox)
            }
            sandboxNotice = error.localizedDescription
        }
    }

    public func cancelSandboxResolution() {
        guard let conflict = sandboxConflict else { return }
        guard !sandboxResolutionBusy, !bridge.anyRunBusy, !bridge.historyMutationBusy, !sandboxRecoveryRequired else {
            sandboxNotice = sandboxRecoveryRequired
                ? "Recover the sandbox state before cancelling the resolution."
                : SandboxWorkspaceError.activeOperationInProgress.localizedDescription
            return
        }
        do {
            try SandboxWorkspaces.cancelResolution(conflict)
            sandboxResolutionPreview = nil
            sandboxNotice = "Sandbox resolution cancelled; the origin was not changed."
        } catch {
            if case SandboxWorkspaceError.mergeAbortFailed = error {
                sandboxRecoveryRequired = true
                persistSandboxState(conflict.sandbox)
            }
            sandboxNotice = error.localizedDescription
        }
    }

    public func revealSandbox() {
        guard let sandbox = activeSandbox else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: sandbox.path)])
    }

    public func revealOriginWorkspace() {
        let path = activeSandbox?.originPath ?? workspacePath
        guard !path.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    public func refreshAvailableSandboxes() {
        let originPath = activeSandbox?.originPath ?? workspacePath
        availableSandboxesRefreshTask?.cancel()

        guard !originPath.isEmpty else {
            availableSandboxes = []
            return
        }

        availableSandboxesRefreshTask = Task { @MainActor [weak self] in
            let sandboxes = await Task.detached(priority: .utility) {
                SandboxWorkspaces.list(origin: originPath)
            }.value
            guard !Task.isCancelled, let self else { return }
            guard (self.activeSandbox?.originPath ?? self.workspacePath) == originPath else { return }
            self.availableSandboxes = sandboxes
        }
    }
}

// Copyright (c) 2026 DOTS
// Project conversations, drafts, sending and message editing.

import AppKit
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import HarnessPluginKit

@MainActor
extension AppModel {
    public func newConversation() {
        commitNavigationDestination()
        guard let targetPath = Self.canonicalExistingWorkspacePath(workspacePath) else {
            if workspacePath.isEmpty {
                if isNoProjectScope {
                    cancelEditing()
                    saveDraftState()
                    bridge.newConversation()
                    restoreDraftState()
                    objectWillChange.send()
                    commitNavigationDestination()
                } else {
                    chooseWorkspace()
                }
            } else {
                promptToRelocateProject(missingPath: workspacePath) { [weak self] newPath in
                    self?.newConversation(in: newPath)
                }
            }
            return
        }
        let bridgeMatchesTarget = ConversationStore.normalizedPath(bridge.workspacePath)
            == ConversationStore.normalizedPath(targetPath)
        if workspacePath != targetPath || !bridgeMatchesTarget {
            setWorkspace(targetPath)
        }
        guard workspacePath == targetPath,
              ConversationStore.normalizedPath(bridge.workspacePath)
                  == ConversationStore.normalizedPath(targetPath) else { return }
        cancelEditing()
        saveDraftState()
        bridge.newConversation()
        restoreDraftState()
        objectWillChange.send()
        commitNavigationDestination()
    }

    /// Prefills the composer without sending. Matches the `plugincreator` slash
    /// command: replaces the draft only when it is effectively empty, otherwise the
    /// user's text is left untouched. Always requests composer focus.
    public func fillComposer(with text: String) {
        if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            draft = text
        }
        composerFocusRequestID &+= 1
    }

    public func newConversation(in projectPath: String) {
        guard let targetPath = Self.canonicalExistingWorkspacePath(projectPath) else {
            promptToRelocateProject(missingPath: projectPath) { [weak self] newPath in
                self?.newConversation(in: newPath)
            }
            return
        }
        let bridgeMatchesTarget = ConversationStore.normalizedPath(bridge.workspacePath)
            == ConversationStore.normalizedPath(targetPath)
        if workspacePath != targetPath || !bridgeMatchesTarget {
            setWorkspace(targetPath)
        }
        // `setWorkspace` can reject a switch while a sandbox is active (or when
        // recovery is required). Never fall through to the no-project action in
        // that case: this method was explicitly asked to create in this project.
        guard workspacePath == targetPath,
              ConversationStore.normalizedPath(bridge.workspacePath)
                  == ConversationStore.normalizedPath(targetPath) else { return }
        newConversation()
    }

    public func addDraftAttachments(_ urls: [URL]) {
        for url in urls {
            guard let attachment = ChatAttachment(url: url),
                  !draftAttachments.contains(where: { $0.path == attachment.path }) else { continue }
            draftAttachments.append(attachment)
        }
    }

    public func addDraftImages(_ urls: [URL]) {
        for url in urls {
            let attachment = ChatAttachment(
                path: url.standardizedFileURL.path,
                kind: .image,
                mimeType: UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "image/png"
            )
            guard !draftAttachments.contains(where: { $0.path == attachment.path }) else { continue }
            draftAttachments.append(attachment)
        }
    }

    public func removeDraftAttachment(_ attachment: ChatAttachment) {
        draftAttachments.removeAll { $0 == attachment }
    }

    public func removeDraftImage(_ url: URL) {
        draftAttachments.removeAll { $0.url == url }
    }

    public func reportHistoryError(_ message: String) {
        historyError = message
    }

    /// Moves a queued prompt back into the composer. Refused while the composer holds a draft,
    /// so editing can never overwrite what the user is typing.
    public func editQueuedPrompt(_ promptID: String) {
        guard let conversationID = selected?.id,
              draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              draftAttachments.isEmpty,
              let prompt = bridge.removeQueuedPrompt(promptID, in: conversationID) else { return }
        draft = prompt.text
        draftAttachments = prompt.attachments
        composerFocusRequestID += 1
    }

    public func send(mode: PromptMode = .queue) {
        guard ensureActiveProjectLocation() else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !draftAttachments.isEmpty else {
            if bridge.canContinue { Task { await bridge.continueCurrentRun() } }
            return
        }

        if let messageID = editingMessageID,
           let conversationID = selected?.id {
            let attachments = draftAttachments
            if PlanningIntent.shouldEnterPlanMode(text) { isPlanMode = true }
            historyError = nil
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try await bridge.editLatestMessage(
                        conversationID: conversationID,
                        messageID: messageID,
                        text: text,
                        attachments: attachments
                    )
                    finishEditingAfterSuccess()
                } catch {
                    historyError = error.localizedDescription
                }
            }
            return
        }

        historyError = nil
        guard canSend else { return }
        let attachments = draftAttachments
        let isApproval = attachments.isEmpty
            && selected?.pendingPlanMessageID.flatMap { planID in
                selected?.messages.first(where: { $0.id == planID && $0.kind == .plan })
            } != nil
            && PlanApproval.matches(text)
        let previousPlanMode = isPlanMode
        if isApproval { isPlanMode = false }
        let verdict = PlanningIntent.verdict(text)
        let effectivePlanMode = !isApproval && (isPlanMode || verdict == .yes)
        let needsPlanIntentResolution = !isApproval && !isPlanMode && verdict == .ambiguous
        if effectivePlanMode { isPlanMode = true }
        let accepted = bridge.submitPrompt(
            text: text,
            attachments: attachments,
            mode: mode,
            planMode: effectivePlanMode,
            needsPlanIntentResolution: needsPlanIntentResolution,
            approvedPlanID: isApproval ? selected?.pendingPlanMessageID : nil,
            onPlanModeResolved: { [weak self] in self?.isPlanMode = true }
        )
        if accepted {
            draft = ""
            draftAttachments = []
        } else {
            draft = text
            draftAttachments = attachments
            isPlanMode = previousPlanMode
            historyError = bridge.status
        }
    }

    @discardableResult
    public func send(text: String, attachments: [ChatAttachment] = [], mode: PromptMode = .queue) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty,
              ensureActiveProjectLocation(),
              canSend else { return false }
        let isApproval = attachments.isEmpty
            && selected?.pendingPlanMessageID.flatMap { planID in
                selected?.messages.first(where: { $0.id == planID && $0.kind == .plan })
            } != nil
            && PlanApproval.matches(trimmed)
        let previousPlanMode = isPlanMode
        if isApproval { isPlanMode = false }
        let verdict = PlanningIntent.verdict(trimmed)
        let effectivePlanMode = !isApproval && (isPlanMode || verdict == .yes)
        let needsPlanIntentResolution = !isApproval && !isPlanMode && verdict == .ambiguous
        if effectivePlanMode { isPlanMode = true }
        let accepted = bridge.submitPrompt(
            text: trimmed,
            attachments: attachments,
            mode: mode,
            planMode: effectivePlanMode,
            needsPlanIntentResolution: needsPlanIntentResolution,
            approvedPlanID: isApproval ? selected?.pendingPlanMessageID : nil,
            onPlanModeResolved: { [weak self] in self?.isPlanMode = true }
        )
        if !accepted { isPlanMode = previousPlanMode }
        return accepted
    }

    func endPlanMode() {
        isPlanMode = false
    }

    public func togglePlanMode() {
        isPlanMode.toggle()
    }

    /// `/compact` only makes sense once this chat has a conversation to summarize.
    public var canCompactSelectedConversation: Bool {
        selectedConversationID.flatMap { id in conversations.first { $0.id == id } }?
            .messages.contains { $0.kind == .user } == true
    }

    public func applyPlan() {
        guard selected?.pendingPlanMessageID != nil,
              selected?.continuation == nil,
              bridge.isReady,
              !bridge.isBusy else { return }
        isPlanMode = false
        Task { await bridge.applyPlan() }
    }

    public func cancelPlan() {
        Task { await bridge.cancelPlan() }
    }

    /// Drops the pending plan and reopens the composer in plan mode so the
    /// user's next message re-plans with their feedback.
    public func revisePlan() {
        Task {
            await bridge.cancelPlan()
            isPlanMode = true
            composerFocusRequestID &+= 1
        }
    }

    /// Applies the plan and keeps approving future plans automatically.
    public func applyPlanAndAutoApprove() {
        setAutoApprovePlans(true)
        applyPlan()
    }

    public func requestPlanPane() {
        planPaneRequestID &+= 1
    }

    public func stop() {
        bridge.stopCurrentRun()
    }

    public func continueCurrentRun() {
        guard ensureActiveProjectLocation() else { return }
        Task { await bridge.continueCurrentRun() }
    }

    /// Opens retained history without changing its original workspace metadata.
    /// Missing-project history stays read-only; projectless history uses the
    /// dedicated No project scope.
    @discardableResult
    public func openRecentConversation(_ conversation: Conversation) -> Bool {
        let conversationID = conversation.id
        guard (conversation.projectless || ConversationStore.normalizedPath(conversation.cwd) != nil),
              bridge.conversations(outsideProjects: connectedProjectPaths).contains(where: { $0.id == conversationID }) else {
            return false
        }

        commitNavigationDestination()
        saveDraftState()
        setWorkspace("")
        guard workspacePath.isEmpty, bridge.workspacePath == nil else { return false }
        bridge.openRecentConversation(conversationID)
        guard bridge.selectedID == conversationID else { return false }
        restoreDraftState()
        commitNavigationDestination()
        return true
    }

    @discardableResult
    private func ensureActiveProjectLocation() -> Bool {
        if isNoProjectScope { return true }
        guard activeProjectLocationAvailable else {
            if workspacePath.isEmpty {
                chooseWorkspace()
            } else {
                promptToRelocateProject(missingPath: workspacePath)
            }
            return false
        }
        return true
    }

    public func beginEditing(_ message: ChatMessage) {
        guard let conversationID = selected?.id,
              message.kind == .user,
              bridge.canEdit(messageID: message.id, in: conversationID) else { return }
        if editingMessageID != nil { cancelEditing() }
        draftBeforeEditing = draft
        attachmentsBeforeEditing = draftAttachments
        historyError = nil
        editingMessageID = message.id
        draft = message.text
        draftAttachments = message.attachments
    }

    public func cancelEditing() {
        guard editingMessageID != nil else { return }
        let savedDraft = draftBeforeEditing ?? ""
        let savedAttachments = attachmentsBeforeEditing ?? []
        editingMessageID = nil
        draftBeforeEditing = nil
        attachmentsBeforeEditing = nil
        draft = savedDraft
        draftAttachments = savedAttachments
        historyError = nil
    }

    private func finishEditingAfterSuccess() {
        editingMessageID = nil
        draftBeforeEditing = nil
        attachmentsBeforeEditing = nil
        draft = ""
        draftAttachments = []
        historyError = nil
    }

    public func rewind(messageID: String) {
        guard let conversationID = selected?.id else { return }
        historyError = nil
        do {
            _ = try bridge.rewind(
                conversationID: conversationID,
                beforeMessageID: messageID
            )
            cancelEditing()
        } catch {
            historyError = error.localizedDescription
        }
    }

    public func undoTurn(messageID: String) {
        guard let conversationID = selected?.id else { return }
        historyError = nil
        do {
            _ = try bridge.undoTurn(conversationID: conversationID, messageID: messageID)
        } catch {
            historyError = error.localizedDescription
        }
    }

    func selectConversation(_ id: String) {
        guard id != bridge.selectedID else { return }
        commitNavigationDestination()
        cancelEditing()
        saveDraftState()
        bridge.select(id)
        restoreDraftState()
        commitNavigationDestination()
    }

    func saveDraftState() {
        guard let id = bridge.selectedID else { return }
        draftsByConversation[draftKey(for: id)] = draft
        draftAttachmentsByConversation[draftKey(for: id)] = draftAttachments
    }

    func restoreDraftState() {
        guard let id = bridge.selectedID else {
            draft = ""
            draftAttachments = []
            return
        }
        draft = draftsByConversation[draftKey(for: id)] ?? ""
        draftAttachments = draftAttachmentsByConversation[draftKey(for: id)] ?? []
    }
}

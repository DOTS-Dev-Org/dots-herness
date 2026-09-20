// Copyright (c) 2026 DOTS
// Chat projects, drafts, sending and message editing.

import AppKit
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import HarnessPluginKit

@MainActor
extension AppModel {
    public func newConversation() {
        cancelEditing()
        saveDraftState()
        bridge.newConversation()
        restoreDraftState()
        objectWillChange.send()
    }

    public func newChatConversation(in projectID: String? = nil) {
        setActiveArea(.chat)
        chatBridge.newConversation()
        chatBridge.setChatProject(projectID)
        restoreDraftState()
        objectWillChange.send()
    }

    public var unassignedChatConversations: [Conversation] {
        startChatBridgeIfNeeded()
        return chatBridge.conversations.filter {
            $0.area == .chat
                && ConversationStore.normalizedPath($0.cwd) == nil
                && $0.chatProjectID == nil
        }
    }

    public func chatConversations(in projectID: String) -> [Conversation] {
        startChatBridgeIfNeeded()
        return chatBridge.conversations.filter {
            $0.area == .chat
                && ConversationStore.normalizedPath($0.cwd) == nil
                && $0.chatProjectID == projectID
        }
    }

    @discardableResult
    public func createChatProject(
        name: String = "New chat project",
        description: String = ""
    ) -> ChatProject {
        let project = ChatProject(name: name, description: description, sortOrder: chatProjects.count)
        chatProjects.append(project)
        chatProjectStore.save(chatProjects)
        objectWillChange.send()
        return project
    }

    public func updateChatProject(_ project: ChatProject) {
        guard let index = chatProjects.firstIndex(where: { $0.id == project.id }) else { return }
        var value = project
        value.updatedAt = Date()
        chatProjects[index] = value
        chatProjectStore.save(chatProjects)
        objectWillChange.send()
    }

    public func toggleChatProjectPinned(_ projectID: String) {
        guard let index = chatProjects.firstIndex(where: { $0.id == projectID }) else { return }
        chatProjects[index].pinned.toggle()
        chatProjects[index].updatedAt = Date()
        chatProjectStore.save(chatProjects)
        objectWillChange.send()
    }

    public func setChatProjectArchived(_ projectID: String, archived: Bool) {
        guard let index = chatProjects.firstIndex(where: { $0.id == projectID }) else { return }
        chatProjects[index].archived = archived
        chatProjects[index].updatedAt = Date()
        chatProjectStore.save(chatProjects)
        objectWillChange.send()
    }

    public func deleteChatProject(_ projectID: String) {
        chatProjects.removeAll { $0.id == projectID }
        chatProjectStore.save(chatProjects)
        for id in chatBridge.conversations.filter({ $0.chatProjectID == projectID }).map(\.id) {
            chatBridge.setChatProject(nil, for: id)
        }
        objectWillChange.send()
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
        setActiveArea(.coding)
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
        // recovery is required). Never fall through to the generic action in
        // that case: it would create a projectless chat in the old workspace.
        guard workspacePath == targetPath,
              ConversationStore.normalizedPath(bridge.workspacePath)
                  == ConversationStore.normalizedPath(targetPath) else { return }
        newConversation()
    }

    public func startWithoutProject() {
        newChatConversation()
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

    public func send(mode: PromptMode = .queue) {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !draftAttachments.isEmpty else {
            if bridge.canContinue { Task { await bridge.continueCurrentRun() } }
            return
        }

        if let messageID = editingMessageID,
           let conversationID = selected?.id {
            let attachments = draftAttachments
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
        if isApproval { isPlanMode = false }
        let runPlanMode = isApproval ? false : isPlanMode
        draft = ""
        draftAttachments = []
        Task {
            await bridge.send(
                text: text,
                attachments: attachments,
                mode: mode,
                planMode: runPlanMode
            )
        }
    }

    public func send(text: String, attachments: [ChatAttachment] = [], mode: PromptMode = .queue) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty, canSend else { return }
        let isApproval = attachments.isEmpty
            && selected?.pendingPlanMessageID.flatMap { planID in
                selected?.messages.first(where: { $0.id == planID && $0.kind == .plan })
            } != nil
            && PlanApproval.matches(trimmed)
        if isApproval { isPlanMode = false }
        let runPlanMode = isApproval ? false : isPlanMode
        Task {
            await bridge.send(
                text: trimmed,
                attachments: attachments,
                mode: mode,
                planMode: runPlanMode
            )
        }
    }

    public func togglePlanMode() {
        isPlanMode.toggle()
    }

    /// `/compact` only makes sense once this chat has a conversation to summarize.
    public var canCompactSelectedConversation: Bool {
        selectedConversationID.flatMap { id in conversations.first { $0.id == id } }?
            .messages.contains { $0.kind == .user } == true
    }

    public func setAssistantMode(_ mode: AssistantMode) {
        setActiveArea(mode == .chat ? .chat : .coding)
        assistantMode = mode
        chatBridge.setAssistantMode(.chat)
        codingBridge.setAssistantMode(.coding)
    }

    public func applyPlan() {
        guard selected?.pendingPlanMessageID != nil, bridge.isReady, !bridge.isBusy else { return }
        isPlanMode = false
        Task { await bridge.applyPlan() }
    }

    public func stop() {
        bridge.stopCurrentRun()
    }

    public func continueCurrentRun() {
        Task { await bridge.continueCurrentRun() }
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

    func selectConversation(_ id: String) {
        guard id != bridge.selectedID else { return }
        cancelEditing()
        saveDraftState()
        bridge.select(id)
        restoreDraftState()
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

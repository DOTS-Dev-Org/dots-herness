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
        if section != .home { section = .home }
        commitNavigationDestination()
        guard let targetPath = Self.canonicalExistingWorkspacePath(workspacePath) else {
            if workspacePath.isEmpty {
                if isNoProjectScope {
                    startBlankConversation()
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
        startBlankConversation()
    }

    private func startBlankConversation() {
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

    public func addDraftImageData(_ data: Data) {
        guard !data.isEmpty else { return }
        let directory = paths.runtime.appendingPathComponent("pasted-images", isDirectory: true)
        let url = directory.appendingPathComponent("\(UUID().uuidString).png")
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try data.write(to: url, options: .atomic)
            addDraftAttachments([url])
        } catch {
            historyError = error.localizedDescription
        }
    }

    public func removeDraftAttachment(_ attachment: ChatAttachment) {
        draftAttachments.removeAll { $0 == attachment }
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
        let rawText = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawText.isEmpty || !draftAttachments.isEmpty else {
            if bridge.canContinue { Task { await bridge.continueCurrentRun() } }
            return
        }

        if let messageID = editingMessageID,
           let conversationID = selected?.id {
            let text = rawText
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
        let text = promptTemplates.expand(rawText, workspacePath: bridge.workspacePath) ?? rawText
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
            draft = rawText
            draftAttachments = attachments
            isPlanMode = previousPlanMode
            historyError = bridge.status
        }
    }

    @discardableResult
    public func send(text: String, attachments: [ChatAttachment] = [], mode: PromptMode = .queue) -> Bool {
        let rawText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawText.isEmpty || !attachments.isEmpty,
              ensureActiveProjectLocation(),
              canSend else { return false }
        let trimmed = promptTemplates.expand(rawText, workspacePath: bridge.workspacePath) ?? rawText
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

    public func forkConversation(beforeMessageID messageID: String, in conversationID: String) {
        guard !isEditingMessage else { return }
        historyError = nil
        saveDraftState()
        do {
            let result = try bridge.forkConversation(conversationID: conversationID, beforeMessageID: messageID)
            selectConversation(result.conversationID)
            draft = result.prompt.text
            draftAttachments = result.prompt.attachments
            composerFocusRequestID += 1
        } catch {
            historyError = error.localizedDescription
        }
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

    /// Shows a workspace file a reply links to in the Files pane. False for web
    /// links and paths that are not there, which the system then handles.
    public func openFileLink(_ url: URL) -> Bool {
        guard let path = Self.fileLinkPath(url), !workspacePath.isEmpty, remoteWorkspace == nil else { return false }
        let file = path.hasPrefix("/")
            ? URL(fileURLWithPath: path)
            : URL(fileURLWithPath: workspacePath).appendingPathComponent(path)
        guard FileManager.default.fileExists(atPath: file.path) else { return false }
        requestedFile = file.standardizedFileURL
        filesPaneRequestID &+= 1
        return true
    }

    /// The path a reply's file link names, without `:line[:column]` or `#L` suffixes;
    /// nil for web links. `README.md:42` parses with scheme "readme.md", hence the dot check.
    public nonisolated static func fileLinkPath(_ url: URL) -> String? {
        if let scheme = url.scheme?.lowercased(), scheme != "file", !scheme.contains(".") { return nil }
        var path = url.isFileURL ? url.path : (url.relativeString.removingPercentEncoding ?? url.relativeString)
        if let hash = path.firstIndex(of: "#") { path = String(path[..<hash]) }
        while let colon = path.lastIndex(of: ":"), colon != path.startIndex,
              path[path.index(after: colon)...].allSatisfy(\.isNumber) {
            path = String(path[..<colon])
        }
        return path.isEmpty ? nil : path
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
        if section != .home { section = .home }
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

// Copyright (c) 2026 DOTS
// Feedback, conversation lifecycle, rewind and edit.

import Foundation
import HarnessPluginKit
import Observation
import PluginRuntime

public enum ConversationArchiveRetention {
    public static let preferenceKey = "archive.autoDeleteDays"
    public static let dayOptions = [1, 7, 30, 60, 90, 120]
}

extension NativeAgentHost {
    func hasAvailableWorkspaceDirectory() -> Bool {
        guard let workspaceURL else { return false }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: workspaceURL.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    func hasRunnableAgentScope() -> Bool {
        isNoProjectScope || hasAvailableWorkspaceDirectory()
    }

    public func feedback(for messageID: String, in conversationID: String) -> FeedbackRecord? {
        _ = listTick
        ensureContentLoaded(conversationID)
        guard let feedbackStore,
              let conversation = conversations.first(where: { $0.id == conversationID }),
              isFeedbackConversation(conversation) else { return nil }
        return feedbackStore.record(conversationID: conversationID, messageID: messageID)
    }

    public func submitFeedback(
        conversationID: String,
        messageID: String,
        feedbackType: FeedbackType,
        tags: [String],
        userComment: String
    ) throws {
        ensureContentLoaded(conversationID)
        guard workspaceURL != nil else { throw FeedbackError.unavailable }
        openProjectMemory()
        guard let feedbackStore else { throw FeedbackError.unavailable }
        guard let conversation = conversations.first(where: { $0.id == conversationID }),
              isFeedbackConversation(conversation) else {
            throw FeedbackError.conversationNotFound
        }
        guard let messageIndex = conversation.messages.firstIndex(where: { $0.id == messageID }) else {
            throw FeedbackError.messageNotFound
        }
        let message = conversation.messages[messageIndex]
        guard message.kind == .assistant || message.kind == .plan else {
            throw FeedbackError.unsupportedMessage
        }
        guard !message.streaming else { throw FeedbackError.streamingMessage }
        guard let prompt = feedbackPrompt(for: messageIndex, in: conversation) else {
            throw FeedbackError.missingPrompt
        }
        guard let response = feedbackResponse(for: message), !response.isEmpty else {
            throw FeedbackError.missingResponse
        }

        let allowedTags = Set(FeedbackTag.tags(for: feedbackType).map(\.rawValue))
        var normalizedTags: [String] = []
        for tag in tags where allowedTags.contains(tag) && !normalizedTags.contains(tag) {
            normalizedTags.append(tag)
        }
        let record = FeedbackRecord(
            conversationID: conversationID,
            messageID: messageID,
            prompt: prompt,
            response: response,
            feedbackType: feedbackType,
            tags: normalizedTags,
            userComment: userComment.trimmingCharacters(in: .whitespacesAndNewlines)
        )

        try feedbackStore.upsert(record)
        touchLists()
        // Invalidate the previous evaluator only after the new record is
        // durable; a failed write must not discard a still-valid evaluation.
        cancelLessonEvaluation(for: feedbackStore.derivedKey(for: record))
        // The record is the source of truth. A projection failure must not
        // make the user's feedback disappear or make the modal report failure.
        try? feedbackStore.setLearnedRule(FeedbackEvaluator.directRule(for: record), for: record)
        shareLessons(from: feedbackStore)
        let meaningfulPositiveTag = normalizedTags
            .compactMap(FeedbackTag.init(rawValue:))
            .contains(where: FeedbackTag.meaningfulPositive.contains)
        let shouldEvaluate = feedbackType == .bad
            || !record.userComment.isEmpty
            || meaningfulPositiveTag
        if var evidence = lessonEvidence(.feedback, in: conversation, assistantIndex: messageIndex, comment: record.userComment) {
            evidence.source = feedbackStore.derivedKey(for: record)
            evidence.tags = normalizedTags
            evidence.outcome = feedbackType == .good ? "approved" : "rejected"
            feedbackStore.logFeedback(
                .feedback,
                conversationID: conversationID,
                turnID: evidence.turnID,
                runID: evidence.runID,
                provider: evidence.provider,
                model: evidence.model,
                outcome: evidence.outcome
            )
            guard shouldEvaluate else { return }
            scheduleLessonEvaluation(evidence, store: feedbackStore) { [weak self] in
                self?.feedbackStore?.record(conversationID: conversationID, messageID: messageID) == record
                    && self?.feedbackRecordStillCurrent(record) == true
            }
        } else {
            let metadata = feedbackStore.metadata(forTurnID: message.turnID)
            feedbackStore.logFeedback(
                .feedback,
                conversationID: conversationID,
                turnID: message.turnID,
                runID: metadata.runID,
                provider: metadata.provider,
                model: metadata.model,
                outcome: feedbackType == .good ? "approved" : "rejected"
            )
        }
    }

    func isFeedbackConversation(_ conversation: Conversation) -> Bool {
        guard let workspaceURL else { return false }
        return ConversationStore.normalizedPath(conversation.cwd)
            == ConversationStore.normalizedPath(workspaceURL.path)
    }

    private func feedbackPrompt(for messageIndex: Int, in conversation: Conversation) -> String? {
        let message = conversation.messages[messageIndex]
        let userMessage: ChatMessage?
        if let turnID = message.turnID {
            userMessage = conversation.messages[..<messageIndex].last {
                $0.kind == .user && $0.turnID == turnID
            }
        } else {
            userMessage = conversation.messages[..<messageIndex].last { $0.kind == .user }
        }
        guard let userMessage else { return nil }
        let text = userMessage.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = userMessage.attachments.map(\.name).joined(separator: ", ")
        let prompt = [
            text,
            attachments.isEmpty ? "" : "[Attachments: \(attachments)]",
        ].filter { !$0.isEmpty }.joined(separator: "\n")
        return prompt.isEmpty ? nil : prompt
    }

    private func feedbackResponse(for message: ChatMessage) -> String? {
        let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { return text }
        guard !message.mediaItems.isEmpty else { return nil }
        return message.mediaItems.map { "[Media: \($0.kind.rawValue)]" }.joined(separator: "\n")
    }

    private func cancelLessonEvaluation(for key: String) {
        feedbackEvaluationTasks[key]?.cancel()
        feedbackEvaluationTasks.removeValue(forKey: key)
        feedbackEvaluationTokens.removeValue(forKey: key)
    }

    /// What one turn looked like from the inside: the request, the answer, and
    /// what the agent did to get there. `assistantIndex` is the answer; the turn
    /// runs back to the user message that started it.
    func lessonEvidence(
        _ signal: LessonSignal,
        in conversation: Conversation,
        assistantIndex: Int,
        comment: String
    ) -> LessonEvidence? {
        guard conversation.messages.indices.contains(assistantIndex),
              let prompt = feedbackPrompt(for: assistantIndex, in: conversation),
              let response = feedbackResponse(for: conversation.messages[assistantIndex]) else { return nil }
        let message = conversation.messages[assistantIndex]
        let start: Int
        if let turnID = message.turnID {
            start = conversation.messages[..<assistantIndex].lastIndex {
                $0.kind == .user && $0.turnID == turnID
            } ?? (conversation.messages[..<assistantIndex].lastIndex { $0.kind == .user } ?? 0)
        } else {
            start = conversation.messages[..<assistantIndex].lastIndex { $0.kind == .user } ?? 0
        }
        let turn = conversation.messages[start...assistantIndex]
        var changed: [String] = []
        var changedPaths = Set<String>()
        for file in turn.flatMap(\.changedFiles) where changedPaths.insert(file.path).inserted { changed.append(file.path) }
        let metadata = feedbackStore?.metadata(forTurnID: message.turnID)
        return LessonEvidence(
            signal: signal,
            source: LessonEvaluator.signalSource(
                conversationID: conversation.id,
                messageID: conversation.messages[assistantIndex].id
            ),
            prompt: prompt,
            response: response,
            comment: comment.trimmingCharacters(in: .whitespacesAndNewlines),
            // The first two lines of a tool message are its name and outcome and
            // the path or command; the rest is output the evaluator does not need.
            tools: turn.filter { $0.kind == .tool }.map {
                String($0.text.split(whereSeparator: \.isNewline).prefix(2).joined(separator: " ").prefix(200))
            },
            changedFiles: changed,
            turnID: message.turnID ?? "",
            runID: metadata?.runID ?? "unknown",
            provider: metadata?.provider ?? "unknown",
            model: metadata?.model ?? "unknown"
        )
    }

    /// Learns from what the user did rather than rated: corrected the answer,
    /// undid the turn, rewrote the request, or was left with failing tests. An
    /// undone or rewritten turn is worth a request only when it did work - a
    /// rephrased question is not a mistake. A correction or a failed turn is
    /// examined either way: answering without doing the work that was asked for
    /// is exactly the mistake. Each answer is examined once, whatever happens later.
    func learnFromSignal(_ signal: LessonSignal, in conversation: Conversation, assistantIndex: Int?, comment: String = "") {
        guard let feedbackStore, isFeedbackConversation(conversation), let assistantIndex,
              var evidence = lessonEvidence(signal, in: conversation, assistantIndex: assistantIndex, comment: comment),
              signal == .correction || signal == .failure || !evidence.tools.isEmpty || !evidence.changedFiles.isEmpty,
              !examinedSignals.contains(evidence.source),
              !feedbackStore.lessons().contains(where: { $0.sources.contains(evidence.source) }) else { return }
        evidence.outcome = signal == .adoption
            ? "adopted"
            : (signal == .failure ? "rejected" : "corrected")
        examinedSignals.insert(evidence.source)
        feedbackStore.logCorrection(
            signal,
            conversationID: conversation.id,
            turnID: evidence.turnID,
            runID: evidence.runID,
            provider: evidence.provider,
            model: evidence.model,
            outcome: evidence.outcome
        )
        scheduleLessonEvaluation(evidence, store: feedbackStore)
    }

    /// The answer a turn ended with, for the turn that starts at `userIndex`.
    func lastAnswerIndex(in conversation: Conversation, afterUserAt userIndex: Int) -> Int? {
        let end = conversation.messages[(userIndex + 1)...].firstIndex { $0.kind == .user } ?? conversation.messages.endIndex
        return conversation.messages[userIndex..<end].lastIndex { $0.kind == .assistant || $0.kind == .plan }
    }

    /// Project-wide lessons also count toward what is known about the user: the
    /// same lesson in a second project follows them everywhere.
    func shareLessons(from store: FeedbackStore) {
        guard let projectID = memory.projectID else { return }
        memory.profile.syncLessons(
            store.lessons().filter { $0.paths.isEmpty && $0.isActive() },
            projectID: projectID,
            stack: memory.stack
        )
    }

    private func scheduleLessonEvaluation(
        _ evidence: LessonEvidence,
        store: FeedbackStore,
        stillValid: @escaping @MainActor () -> Bool = { true }
    ) {
        let token = UUID()
        let key = evidence.source
        feedbackEvaluationTokens[key] = token
        let evaluatorMessages = [
            AgentMessage(role: .system, content: LessonEvaluator.systemPrompt),
            AgentMessage(role: .user, content: LessonEvaluator.payload(for: evidence)),
        ]

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.feedbackEvaluationTokens[key] == token {
                    self.feedbackEvaluationTasks.removeValue(forKey: key)
                    self.feedbackEvaluationTokens.removeValue(forKey: key)
                }
            }
            do {
                let response: AgentResponse
                if let router = self.router {
                    // Feedback the user gave on purpose gets the routed model. A
                    // signal nobody asked us to examine gets the cheapest one: it
                    // fires far more often and may well find nothing.
                    response = evidence.signal == .feedback
                        ? try await router.completeWithFailover(messages: evaluatorMessages, tools: [])
                        : try await router.completeCheapest(messages: evaluatorMessages)
                } else if let configuration = await self.currentConfiguration(loadCredentials: false) {
                    response = try await NativeAgentClient(configuration: configuration)
                        .complete(messages: evaluatorMessages, tools: [])
                } else {
                    store.logEvaluation(evidence, result: "error: no model available")
                    return
                }
                guard !Task.isCancelled,
                      self.feedbackEvaluationTokens[key] == token,
                      self.memory.userMemoryDirectory == store.directory,
                      stillValid() else { return }
                guard let lesson = LessonEvaluator.parse(
                    from: response.message.content,
                    evidencePaths: evidence.paths
                ) else {
                    store.logEvaluation(evidence, result: "none")
                    return
                }
                // Feedback keeps the user's own words under the record's key; what
                // was inferred from it is a second source beside them.
                let source = evidence.signal == .feedback ? key + Lesson.inferredSuffix : key
                do {
                    _ = try store.setLesson(lesson, source: source)
                    store.logEvaluation(evidence, result: "lesson")
                } catch {
                    store.logEvaluation(evidence, result: "error: lesson not saved")
                }
                self.shareLessons(from: store)
            } catch is CancellationError {
                return
            } catch {
                // The user is not interrupted: the evidence is still in the
                // conversation. The log row is
                // what tells a broken evaluator from one with nothing to say.
                store.logEvaluation(evidence, result: "error: \(error.localizedDescription)")
            }
        }
        feedbackEvaluationTasks[key] = task
    }

    private func feedbackRecordStillCurrent(_ record: FeedbackRecord) -> Bool {
        guard let conversation = conversations.first(where: { $0.id == record.conversationID }),
              let index = conversation.messages.firstIndex(where: { $0.id == record.messageID }),
              let prompt = feedbackPrompt(for: index, in: conversation),
              let response = feedbackResponse(for: conversation.messages[index]) else { return false }
        return FeedbackRecord.digest(prompt: prompt, response: response) == record.digest
    }

    public func select(_ id: String) {
        guard conversations.contains(where: { $0.id == id }) else { return }
        clearFollowUpSuggestion()
        let selectionChanged = selectedID != id
        selectedID = id
        if let index = conversations.firstIndex(where: { $0.id == id }), conversations[index].unread {
            conversations[index].unread = false
            // Disk write after the switch has painted; it used to block the click.
            Task { @MainActor [weak self] in self?.persist() }
        }
        // A repeated click on the already selected row does not trigger selectedID.didSet.
        if !selectionChanged {
            if conversations.first(where: { $0.id == id })?.contentLoaded == true {
                if !state(for: id).queuePausedAfterStop { activateLoadedConversation(id) }
            } else if contentTask == nil {
                selectionDidChange(to: id)
            }
        }
    }

    /// Rebinds visible history after the user locates a moved project folder.
    /// Conversation IDs, messages, and ordering stay intact; only their project
    /// path changes so they load under the new location on the next launch.
    public func relocateProjectHistory(from oldPath: String, to newPath: String) {
        let oldKey = ConversationStore.normalizedPath(oldPath)
        let newKey = ConversationStore.normalizedPath(newPath)
        guard let oldKey, let newKey, oldKey != newKey else { return }
        var changed = false
        for index in conversations.indices where ConversationStore.normalizedPath(conversations[index].cwd) == oldKey {
            conversations[index].cwd = newKey
            changed = true
        }
        if changed { persist() }
    }

    public func newConversation() {
        clearFollowUpSuggestion()
        let projectlessScope = workspaceURL == nil && requestedWorkspacePath == nil
        guard hasRunnableAgentScope() || projectlessScope else {
            status = AppCopy.text(requestedWorkspacePath == nil ? "agent.chooseWorkspaceToStart" : "agent.workspaceMissing")
            selectedID = nil
            return
        }
        // Usage telemetry and cache epochs outlive an empty transcript; reuse only a pristine draft.
        if let draft = conversations.first(where: {
            Self.isEmptyDraft($0) && $0.projectless == projectlessScope
                && $0.cacheEpoch == nil && contextUsageEvents(in: $0.id).isEmpty
        }) {
            selectedID = draft.id
            if let currentWorkspace = workspaceURL?.path, draft.cwd != currentWorkspace {
                if let index = conversations.firstIndex(where: { $0.id == draft.id }) {
                    conversations[index].cwd = currentWorkspace
                    persist()
                }
            }
            return
        }
        let conversation = Conversation(cwd: workspaceURL?.path, projectless: projectlessScope)
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

    public func togglePinned(_ id: String) {
        guard conversation(for: id) != nil else {
            // Chats of an open project that is not the active one are listed from
            // stored headers. Pinning one still has to reach the store.
            guard var stored = store.loadHeaders().first(where: { $0.id == id }) else { return }
            stored.pinned.toggle()
            guard store.save([stored]) else { return }
            touchLists()
            return
        }
        updateConversation(id) { $0.pinned.toggle() }
    }

    public func setPriority(_ id: String, _ priority: Int) {
        let priority = min(max(priority, 0), 3)
        guard conversation(for: id) != nil else {
            guard var stored = store.loadHeaders().first(where: { $0.id == id }) else { return }
            stored.priority = priority
            guard store.save([stored]) else { return }
            touchLists()
            return
        }
        updateConversation(id) { $0.priority = priority }
    }

    public func setArchived(_ id: String, archived: Bool) {
        guard let conversation = conversation(for: id) else {
            // Recent conversations can belong to projects that are not currently
            // loaded. Update their stored header so archive/restore still works.
            guard var stored = store.loadHeaders().first(where: { $0.id == id }),
                  stored.archived != archived else { return }
            stored.archived = archived
            stored.archivedAt = archived ? Date() : nil
            guard store.save([stored]) else { return }
            touchLists()
            recordConversationLifecycle(
                stored,
                state: archived ? .archived : .restored
            )
            return
        }
        guard conversation.archived != archived else { return }
        updateConversation(id) {
            $0.archived = archived
            $0.archivedAt = archived ? Date() : nil
        }
        recordConversationLifecycle(
            conversation,
            state: archived ? .archived : .restored
        )
    }

    public func markAllRead(forWorkspace path: String) {
        let normalized = ConversationStore.normalizedPath(path)
        if ConversationStore.normalizedPath(workspaceURL?.path) == normalized {
            var changed = false
            for index in conversations.indices where conversations[index].unread {
                conversations[index].unread = false
                changed = true
            }
            if changed { persist() }
            return
        }

        var project = store.loadHeaders(workspacePath: path)
        var changed = false
        for index in project.indices where project[index].unread {
            project[index].unread = false
            changed = true
        }
        if changed { store.save(project); touchLists() }
    }

    public func archiveAll(forWorkspace path: String) {
        let normalized = ConversationStore.normalizedPath(path)
        let archivedAt = Date()
        if ConversationStore.normalizedPath(workspaceURL?.path) == normalized {
            var changed = false
            for index in conversations.indices where !conversations[index].blank && !conversations[index].archived {
                conversations[index].archived = true
                conversations[index].archivedAt = archivedAt
                changed = true
            }
            if changed { persist() }
            return
        }

        var project = store.loadHeaders(workspacePath: path)
        var changed = false
        for index in project.indices where !project[index].blank && !project[index].archived {
            project[index].archived = true
            project[index].archivedAt = archivedAt
            changed = true
        }
        if changed { store.save(project); touchLists() }
    }

    /// Permanently removes expired archived chats. A legacy archived chat without
    /// an archive timestamp starts its timer the first time a finite policy runs.
    @discardableResult
    public func deleteExpiredArchivedConversations(retentionDays: Int, now: Date = Date()) -> Int {
        let expiredIDs = expiredArchivedConversationIDs(retentionDays: retentionDays, now: now)
        deleteConversations(expiredIDs)
        return expiredIDs.count
    }

    /// Retention cleanup for app and archive screens; large expirations use the
    /// same background path as a user-requested archive deletion.
    @discardableResult
    public func deleteExpiredArchivedConversationsInBackground(retentionDays: Int, now: Date = Date()) async -> Int {
        let expiredIDs = expiredArchivedConversationIDs(retentionDays: retentionDays, now: now)
        await deleteConversationsInBackground(expiredIDs)
        return expiredIDs.count
    }

    private func expiredArchivedConversationIDs(retentionDays: Int, now: Date) -> [String] {
        guard ConversationArchiveRetention.dayOptions.contains(retentionDays) else { return [] }
        let cutoff = now.addingTimeInterval(-Double(retentionDays) * 24 * 60 * 60)
        var expiredIDs: [String] = []
        var headersToStamp: [Conversation] = []
        var currentRecordsChanged = false

        for var stored in store.loadHeaders() where stored.archived && !stored.blank {
            if let archivedAt = stored.archivedAt {
                if archivedAt <= cutoff { expiredIDs.append(stored.id) }
                continue
            }

            stored.archivedAt = now
            if let index = conversations.firstIndex(where: { $0.id == stored.id }) {
                conversations[index].archivedAt = now
                currentRecordsChanged = true
            } else {
                headersToStamp.append(stored.headerCopy())
            }
        }

        if currentRecordsChanged { persist() }
        if !headersToStamp.isEmpty {
            if store.save(headersToStamp) { touchLists() }
        }
        return expiredIDs
    }

    public func deleteConversation(_ id: String) {
        deleteConversations([id])
    }

    /// Removes chats as a batch so list observers and persistent stores are
    /// invalidated once instead of once for every archived row.
    public func deleteConversations(_ conversationIDs: [String]) {
        guard let batch = prepareConversationDeletion(conversationIDs) else { return }
        store.delete(batch.ids)
        memory.removeTurnSnapshots(conversationIDs: batch.ids)
        touchLists()
    }

    /// Removes an archived batch without performing database or snapshot I/O on
    /// the main actor, keeping the archive window responsive during cleanup.
    public func deleteConversationsInBackground(_ conversationIDs: [String]) async {
        guard let batch = prepareConversationDeletion(conversationIDs) else { return }
        let ids = batch.ids
        let store = self.store
        let snapshotStore = memory.snapshotStore

        let databaseDeletion = Task.detached(priority: .utility) { store.delete(ids) }
        let snapshotDeletion = Task.detached(priority: .utility) { snapshotStore.removeConversations(ids) }
        await databaseDeletion.value
        await snapshotDeletion.value
        touchLists()
    }

    private struct ConversationDeletionBatch {
        let ids: [String]
    }

    private func prepareConversationDeletion(_ conversationIDs: [String]) -> ConversationDeletionBatch? {
        let ids = Array(Set(conversationIDs).filter { !$0.isEmpty })
        guard !ids.isEmpty else { return nil }
        let idsToDelete = Set(ids)
        clearFollowUpSuggestion()
        let deletedConversations = conversations.filter { idsToDelete.contains($0.id) }

        for id in ids {
            // The deleted chat can be a background run waiting on the user or mid
            // flight: address its own run state, not the selected conversation's.
            AgentRunScope.$conversationID.withValue(id) {
                if pendingApproval?.conversationID == id { finishApproval(false) }
                if pendingQuestion?.conversationID == id { finishQuestion(nil) }
                if activeConversationID == id {
                    activeTask?.cancel()
                    activeTask = nil
                    activeConversationID = nil
                    activeRunID = UUID()
                    activeTurnID = nil
                    activeContext = []
                    queuePausedAfterStop = false
                    activeStopEventRecorded = false
                    activeStopEventID = nil
                    isBusy = false
                }
            }
            dropWorkspaceLeases(conversationID: id)
            ReadLedger.shared.forgetConversation(id)
        }

        conversations.removeAll { idsToDelete.contains($0.id) }
        if let currentSelection = selectedID, idsToDelete.contains(currentSelection) {
            selectedID = conversations.first(where: { !$0.archived })?.id
        }
        for conversation in deletedConversations {
            recordConversationLifecycle(conversation, state: .deleted)
        }
        memory.invalidateTurnSnapshotCache()
        return ConversationDeletionBatch(ids: ids)
    }

    public func canEdit(messageID: String, in conversationID: String) -> Bool {
        ensureContentLoaded(conversationID)
        guard !anyRunBusy, !historyMutationBusy,
              let workspace = workspaceURL,
              let conversation = conversations.first(where: { $0.id == conversationID }),
              conversation.pendingPrompts.isEmpty,
              let message = conversation.messages.first(where: { $0.id == messageID }),
              message.kind == .user,
              conversation.messages.last(where: { $0.kind == .user })?.id == messageID,
              let turnID = message.turnID else { return false }
        return memory.hasCompleteTurnSnapshot(
            conversationID: conversationID,
            turnID: turnID,
            workspace: workspace
        )
    }

    public func canRewind(messageID: String, in conversationID: String) -> Bool {
        ensureContentLoaded(conversationID)
        guard !anyRunBusy, !historyMutationBusy,
              let workspace = workspaceURL,
              let conversation = conversations.first(where: { $0.id == conversationID }),
              conversation.pendingPrompts.isEmpty,
              let index = conversation.messages.firstIndex(where: { $0.id == messageID }),
              conversation.messages[index].kind == .user,
              let turnIDs = turnIDs(in: conversation.messages, from: index),
              !turnIDs.isEmpty else { return false }
        return turnIDs.allSatisfy {
            memory.hasCompleteTurnSnapshot(
                conversationID: conversationID,
                turnID: $0,
                workspace: workspace
            )
        }
    }

    /// Forking is a read-only branch operation; the source conversation and files stay untouched.
    public func canFork(messageID: String, in conversationID: String) -> Bool {
        guard !historyMutationBusy,
              let conversation = conversations.first(where: { $0.id == conversationID }),
              conversation.contentLoaded, !conversation.running,
              conversation.pendingPrompts.isEmpty, !conversation.requiresToolOutcomeRecovery,
              let message = conversation.messages.first(where: { $0.id == messageID }) else { return false }
        return message.kind == .user
    }

    /// Creates a new conversation from the transcript before one user message.
    /// The selected message is returned so the app can place it in the new draft.
    public func forkConversation(
        conversationID: String,
        beforeMessageID messageID: String
    ) throws -> (conversationID: String, prompt: ChatMessage) {
        guard !historyMutationBusy else { throw ConversationMutationError.busy }
        ensureContentLoaded(conversationID)
        guard let source = conversations.first(where: { $0.id == conversationID }),
              source.contentLoaded, source.transcriptComplete, !source.running,
              source.pendingPrompts.isEmpty, !source.requiresToolOutcomeRecovery,
              let messageIndex = source.messages.firstIndex(where: { $0.id == messageID }),
              source.messages[messageIndex].kind == .user else {
            throw ConversationMutationError.forkUnavailable
        }

        var prefixMessages = Array(source.messages.prefix(messageIndex))
        // Turn snapshots are scoped to the source conversation and cannot be undone
        // from the new branch.
        for index in prefixMessages.indices {
            prefixMessages[index].summary?.undoAvailable = false
        }
        var prefix = source
        prefix.messages = prefixMessages
        prefix.pendingPrompts = []
        prefix.running = false
        prefix.runStartedAt = nil
        prefix.continuation = nil
        prefix.inFlightToolCalls = []
        prefix.requiresToolOutcomeRecovery = false
        prefix.pendingPlanMessageID = nil
        prefix.planGateActive = false
        prefix.modelContext = []
        let visibleUsers = source.messages.enumerated().filter { $0.element.kind == .user }
        let selectedUserOrdinal = visibleUsers.firstIndex { $0.offset == messageIndex }
        let contextUserIndices = source.modelContext.indices.filter { source.modelContext[$0].role == .user }
        let droppedUserCount = max(0, visibleUsers.count - contextUserIndices.count)
        if let selectedUserOrdinal,
           selectedUserOrdinal >= droppedUserCount,
           contextUserIndices.count <= visibleUsers.count {
            let retainedOrdinal = selectedUserOrdinal - droppedUserCount
            if contextUserIndices.indices.contains(retainedOrdinal) {
                let contextIndex = contextUserIndices[retainedOrdinal]
                let contextPrompt = source.modelContext[contextIndex]
                let selectedPrompt = source.messages[messageIndex]
                if contextPrompt.content == selectedPrompt.text,
                   contextPrompt.attachments == selectedPrompt.attachments {
                    prefix.modelContext = Array(source.modelContext.prefix(contextIndex))
                }
            }
        }
        if prefix.modelContext.isEmpty {
            prefix.modelContext = Self.modelMessagesForContext(prefix)
        }

        let hasPriorTranscript = !prefixMessages.isEmpty
        let title = hasPriorTranscript
            ? AppCopy.format("conversation.branchTitle", source.title)
            : "New conversation"
        let branch = Conversation(
            title: title,
            messages: prefixMessages,
            modelContext: prefix.modelContext,
            blank: !hasPriorTranscript,
            cwd: source.cwd,
            projectless: source.projectless,
            agentPreset: source.agentPreset,
            modelPreferenceID: source.modelPreferenceID
        )
        conversations.insert(branch, at: 0)
        guard persist() else {
            conversations.removeAll { $0.id == branch.id }
            throw ConversationMutationError.forkSaveFailed
        }
        return (branch.id, source.messages[messageIndex])
    }

    public func canUndoTurn(messageID: String, in conversationID: String) -> Bool {
        ensureContentLoaded(conversationID)
        guard !anyRunBusy, !historyMutationBusy,
              let workspace = workspaceURL,
              let conversation = conversations.first(where: { $0.id == conversationID }),
              conversation.pendingPrompts.isEmpty,
              let message = conversation.messages.first(where: { $0.id == messageID }),
              message.summary?.undoAvailable == true,
              let turnID = message.turnID else { return false }
        return memory.hasUndoableTurnSnapshot(
            conversationID: conversationID,
            turnID: turnID,
            workspace: workspace
        )
    }

    @discardableResult
    public func undoTurn(conversationID: String, messageID: String) throws -> RewindResult {
        ensureContentLoaded(conversationID)
        guard !anyRunBusy, !historyMutationBusy else { throw ConversationMutationError.busy }
        guard let workspace = workspaceURL,
              let conversationIndex = conversations.firstIndex(where: { $0.id == conversationID }),
              let messageIndex = conversations[conversationIndex].messages.firstIndex(where: { $0.id == messageID }),
              case let message = conversations[conversationIndex].messages[messageIndex],
              let turnID = message.turnID,
              message.summary?.undoAvailable == true,
              memory.hasUndoableTurnSnapshot(conversationID: conversationID, turnID: turnID, workspace: workspace) else {
            throw ConversationMutationError.snapshotUnavailable
        }

        historyMutationBusy = true
        defer { historyMutationBusy = false }
        let result = try restoreTurns([turnID], in: conversationID, workspace: workspace, abortOnConflict: true)

        conversations[conversationIndex].messages[messageIndex].summary?.undoAvailable = false
        persist()
        status = AppCopy.text("conversation.filesReverted")
        return result
    }

    public func rewind(
        conversationID: String,
        beforeMessageID messageID: String
    ) throws -> RewindResult {
        ensureContentLoaded(conversationID)
        guard !anyRunBusy, !historyMutationBusy else { throw ConversationMutationError.busy }
        guard let workspace = workspaceURL,
              let conversationIndex = conversations.firstIndex(where: { $0.id == conversationID }) else {
            throw ConversationMutationError.messageNotFound
        }
        let conversation = conversations[conversationIndex]
        guard conversation.pendingPrompts.isEmpty,
              let messageIndex = conversation.messages.firstIndex(where: { $0.id == messageID }),
              conversation.messages[messageIndex].kind == .user else {
            throw ConversationMutationError.messageNotFound
        }
        guard let turnIDs = turnIDs(in: conversation.messages, from: messageIndex),
              turnIDs.allSatisfy({
                  memory.hasCompleteTurnSnapshot(
                      conversationID: conversationID,
                      turnID: $0,
                      workspace: workspace
                  )
              }) else {
            throw ConversationMutationError.snapshotUnavailable
        }

        historyMutationBusy = true
        defer { historyMutationBusy = false }
        let result = try restoreTurns(turnIDs, in: conversationID, workspace: workspace, abortOnConflict: false)

        var updated = Self.truncated(conversation, before: messageIndex)
        if !result.conflictPaths.isEmpty {
            updated.appendChronologically(
                ChatMessage(
                    kind: .system,
                    text: AppCopy.format(
                        "conversation.historyConflict",
                        result.conflictPaths.joined(separator: ", ")
                    )
                )
            )
        }
        conversations[conversationIndex] = updated
        historyRewrittenConversations.insert(conversationID)
        persist()
        learnFromSignal(
            .rewind,
            in: conversation,
            assistantIndex: lastAnswerIndex(in: conversation, afterUserAt: messageIndex)
        )
        memory.recordConversationRewind(
            conversationID: conversation.id,
            title: conversation.title,
            beforeMessageID: messageID,
            restoredPaths: result.restoredPaths,
            conflictPaths: result.conflictPaths
        )
        status = result.conflictPaths.isEmpty
            ? AppCopy.text("conversation.historyRewound")
            : AppCopy.text("conversation.historyConflictStatus")
        return result
    }

    public func editLatestMessage(
        conversationID: String,
        messageID: String,
        text: String,
        attachments: [ChatAttachment]
    ) async throws {
        ensureContentLoaded(conversationID)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else {
            throw ConversationMutationError.invalidMessage
        }
        guard !anyRunBusy, !historyMutationBusy else { throw ConversationMutationError.busy }
        // Reserve the history mutation before the configuration lookup can
        // suspend the main actor; a second edit must not enter the same gap.
        historyMutationBusy = true
        defer {
            historyMutationBusy = false
            Task { @MainActor [weak self] in
                await Task.yield()
                self?.trimInactiveConversationContent()
            }
        }
        guard let configuration = await currentConfiguration() else {
            throw ConversationMutationError.notReady
        }
        guard !anyRunBusy,
              let workspace = workspaceURL,
              let conversationIndex = conversations.firstIndex(where: { $0.id == conversationID }) else {
            throw ConversationMutationError.messageNotFound
        }
        let conversation = conversations[conversationIndex]
        guard conversation.pendingPrompts.isEmpty,
              let messageIndex = conversation.messages.firstIndex(where: { $0.id == messageID }),
              conversation.messages[messageIndex].kind == .user,
              conversation.messages.last(where: { $0.kind == .user })?.id == messageID else {
            throw ConversationMutationError.notLatestUserMessage
        }
        guard let turnID = conversation.messages[messageIndex].turnID,
              memory.hasCompleteTurnSnapshot(
                  conversationID: conversationID,
                  turnID: turnID,
                  workspace: workspace
              ) else {
            throw ConversationMutationError.snapshotUnavailable
        }
        let editedPlanMode = conversation.messages
            .dropFirst(messageIndex + 1)
            .prefix(while: { $0.kind != .user })
            .contains(where: { $0.kind == .plan })
            || PlanningIntent.shouldEnterPlanMode(trimmed)

        let result = try restoreTurns([turnID], in: conversationID, workspace: workspace, abortOnConflict: true)

        let updated = Self.truncated(conversation, before: messageIndex)
        conversations[conversationIndex] = updated
        historyRewrittenConversations.insert(conversationID)
        persist()
        learnFromSignal(
            .edit,
            in: conversation,
            assistantIndex: lastAnswerIndex(in: conversation, afterUserAt: messageIndex),
            comment: trimmed
        )
        memory.recordConversationRewind(
            conversationID: conversation.id,
            title: conversation.title,
            beforeMessageID: messageID,
            restoredPaths: result.restoredPaths,
            conflictPaths: []
        )
        await startPrompt(
            text: trimmed,
            attachments: attachments,
            in: conversationID,
            configuration: configuration,
            workspace: workspace,
            planMode: editedPlanMode
        )
    }

    /// Puts the turns' files back; with `abortOnConflict` a conflict restores nothing and throws.
    private func restoreTurns(
        _ turnIDs: [String],
        in conversationID: String,
        workspace: URL,
        abortOnConflict: Bool
    ) throws -> RewindResult {
        let result: RewindResult
        do {
            result = try memory.restoreTurns(
                conversationID: conversationID,
                turnIDs: turnIDs,
                workspace: workspace,
                abortOnConflict: abortOnConflict
            )
        } catch let error as WorkspaceMemoryError {
            throw mutationError(for: error)
        }
        guard !abortOnConflict || result.conflictPaths.isEmpty else {
            throw ConversationMutationError.conflict(result.conflictPaths)
        }
        return result
    }

    /// The conversation as it stood before the message at `index` was sent.
    private static func truncated(_ conversation: Conversation, before index: Int) -> Conversation {
        var updated = conversation
        updated.messages = Array(conversation.messages.prefix(index))
        updated.pendingPrompts = []
        if let planID = updated.pendingPlanMessageID,
           !updated.messages.contains(where: { $0.id == planID && $0.kind == .plan }) {
            updated.pendingPlanMessageID = nil
            updated.planGateActive = false
        }
        updated.continuation = nil
        updated.modelContext = []
        if !updated.messages.contains(where: { $0.kind == .user }) {
            updated.title = "New conversation"
            updated.blank = true
        }
        return updated
    }
}

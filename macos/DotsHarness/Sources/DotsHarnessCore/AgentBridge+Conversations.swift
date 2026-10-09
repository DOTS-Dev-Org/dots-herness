// Copyright (c) 2026 DOTS
// Feedback, conversation lifecycle, rewind and edit.

import Foundation
import HarnessPluginKit
import Observation
import PluginRuntime

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
        ensureContentLoaded()
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
        ensureContentLoaded()
        guard workspaceURL != nil, let feedbackStore else { throw FeedbackError.unavailable }
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
        // Invalidate the previous evaluator only after the new raw record is
        // durable; a failed write must not discard a still-valid evaluation.
        cancelLessonEvaluation(for: feedbackStore.derivedKey(for: record))
        // The raw record is the source of truth. A projection failure must not
        // make the user's feedback disappear or make the modal report failure.
        try? feedbackStore.rebuildGoldExamples()
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
        for file in turn.flatMap(\.changedFiles) where !changed.contains(file.path) { changed.append(file.path) }
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
    /// undid the turn, rewrote the request, or was left with failing tests. Only
    /// turns that did work are worth a request - a rephrased question is not a
    /// mistake - and each answer is examined once, whatever happens to it later.
    func learnFromSignal(_ signal: LessonSignal, in conversation: Conversation, assistantIndex: Int?, comment: String = "") {
        guard let feedbackStore, isFeedbackConversation(conversation), let assistantIndex,
              var evidence = lessonEvidence(signal, in: conversation, assistantIndex: assistantIndex, comment: comment),
              !evidence.tools.isEmpty || !evidence.changedFiles.isEmpty,
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
                    return
                }
                guard !Task.isCancelled,
                      self.feedbackEvaluationTokens[key] == token,
                      self.workspaceURL?.standardizedFileURL == store.workspaceURL,
                      stillValid() else { return }
                guard let lesson = LessonEvaluator.parse(
                    from: response.message.content,
                    evidencePaths: evidence.paths
                ) else { return }
                // Feedback keeps the user's own words under the record's key; what
                // was inferred from it is a second source beside them.
                let source = evidence.signal == .feedback ? key + Lesson.inferredSuffix : key
                _ = try? store.setLesson(lesson, source: source)
                self.shareLessons(from: store)
            } catch is CancellationError {
                return
            } catch {
                // Evaluator failures are intentionally silent: the evidence is
                // still in the conversation and feedback.jsonl remains durable.
            }
        }
        feedbackEvaluationTasks[key] = task
    }

    private func feedbackRecordStillCurrent(_ record: FeedbackRecord) -> Bool {
        guard let conversation = conversations.first(where: { $0.id == record.conversationID }),
              let index = conversation.messages.firstIndex(where: { $0.id == record.messageID }),
              let prompt = feedbackPrompt(for: index, in: conversation),
              let response = feedbackResponse(for: conversation.messages[index]) else { return false }
        return prompt == record.prompt && response == record.response
    }

    public func select(_ id: String) {
        guard conversations.contains(where: { $0.id == id }) else { return }
        clearFollowUpSuggestion()
        selectedID = id
        if let index = conversations.firstIndex(where: { $0.id == id }), conversations[index].unread {
            conversations[index].unread = false
            // Disk write after the switch has painted; it used to block the click.
            Task { @MainActor [weak self] in self?.persist() }
        }
    }

    /// Rebinds visible history after the user locates a moved project folder.
    /// Conversation IDs, messages, and ordering stay intact; only their project
    /// path changes so they load under the new location on the next launch.
    func relocateProjectHistory(from oldPath: String, to newPath: String) {
        ensureContentLoaded()
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
        guard hasRunnableAgentScope() else {
            status = AppCopy.text(requestedWorkspacePath == nil ? "agent.chooseWorkspaceToStart" : "agent.workspaceMissing")
            selectedID = nil
            return
        }
        if let draft = conversations.first(where: Self.isEmptyDraft) {
            selectedID = draft.id
            if let currentWorkspace = workspaceURL?.path, draft.cwd != currentWorkspace {
                if let index = conversations.firstIndex(where: { $0.id == draft.id }) {
                    conversations[index].cwd = currentWorkspace
                    persist()
                }
            }
            return
        }
        let conversation = Conversation(cwd: workspaceURL?.path, projectless: workspaceURL == nil)
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

    public func setArchived(_ id: String, archived: Bool) {
        guard let conversation = conversation(for: id) else {
            // Recent conversations can belong to projects that are not currently
            // loaded. Update their stored header so archive/restore still works.
            guard var stored = store.loadHeaders().first(where: { $0.id == id }),
                  stored.archived != archived else { return }
            stored.archived = archived
            guard store.save([stored]) else { return }
            touchLists()
            recordConversationLifecycle(
                stored,
                state: archived ? .archived : .restored
            )
            return
        }
        guard conversation.archived != archived else { return }
        updateConversation(id) { $0.archived = archived }
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

        var project = store.load(workspacePath: path)
        var changed = false
        for index in project.indices where project[index].unread {
            project[index].unread = false
            changed = true
        }
        if changed { store.save(project); touchLists() }
    }

    public func archiveAll(forWorkspace path: String) {
        let normalized = ConversationStore.normalizedPath(path)
        if ConversationStore.normalizedPath(workspaceURL?.path) == normalized {
            var changed = false
            for index in conversations.indices where !conversations[index].blank && !conversations[index].archived {
                conversations[index].archived = true
                changed = true
            }
            if changed { persist() }
            return
        }

        var project = store.load(workspacePath: path)
        var changed = false
        for index in project.indices where !project[index].blank && !project[index].archived {
            project[index].archived = true
            changed = true
        }
        if changed { store.save(project); touchLists() }
    }

    public func deleteConversation(_ id: String) {
        clearFollowUpSuggestion()
        let conversation = conversation(for: id)
        // The deleted chat can be a background run waiting on the user or mid
        // flight: address its own run state, not the selected conversation's.
        AgentRunScope.$conversationID.withValue(id) {
            if pendingApproval != nil { finishApproval(false) }
            if pendingQuestion != nil { finishQuestion(nil) }
            finishContextCompaction(false)
            if activeConversationID == id {                activeTask?.cancel()
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
        conversations.removeAll { $0.id == id }
        // Its leases and its ledger go with it: a chat that can never write again
        // must not keep a file from the ones that still can.
        dropWorkspaceLeases(conversationID: id)
        ReadLedger.shared.forgetConversation(id)
        store.delete(id)
        if selectedID == id {
            selectedID = conversations.first(where: { !$0.archived })?.id
        }
        if let conversation {
            recordConversationLifecycle(conversation, state: .deleted)
        }
        memory.removeTurnSnapshots(conversationID: id)
        touchLists()
    }

    public func canEdit(messageID: String, in conversationID: String) -> Bool {
        ensureContentLoaded()
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
        ensureContentLoaded()
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

    public func canUndoTurn(messageID: String, in conversationID: String) -> Bool {
        ensureContentLoaded()
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
        ensureContentLoaded()
        guard !anyRunBusy, !historyMutationBusy else { throw ConversationMutationError.busy }
        guard let workspace = workspaceURL,
              let conversationIndex = conversations.firstIndex(where: { $0.id == conversationID }),
              let messageIndex = conversations[conversationIndex].messages.firstIndex(where: { $0.id == messageID }),
              let message = Optional(conversations[conversationIndex].messages[messageIndex]),
              let turnID = message.turnID,
              message.summary?.undoAvailable == true,
              memory.hasUndoableTurnSnapshot(conversationID: conversationID, turnID: turnID, workspace: workspace) else {
            throw ConversationMutationError.snapshotUnavailable
        }

        historyMutationBusy = true
        defer { historyMutationBusy = false }
        let result: RewindResult
        do {
            result = try memory.restoreTurns(
                conversationID: conversationID,
                turnIDs: [turnID],
                workspace: workspace,
                abortOnConflict: true
            )
        } catch let error as WorkspaceMemoryError {
            throw mutationError(for: error)
        }
        guard result.conflictPaths.isEmpty else {
            throw ConversationMutationError.conflict(result.conflictPaths)
        }

        var updated = conversations[conversationIndex]
        if let summary = message.summary {
            updated.messages[messageIndex].summary = WorkspaceRunSummary(
                runID: summary.runID,
                turnID: summary.turnID,
                status: summary.status,
                trackingStatus: summary.trackingStatus,
                cleanupStatus: summary.cleanupStatus,
                cleanupNote: summary.cleanupNote,
                addedCount: summary.addedCount,
                modifiedCount: summary.modifiedCount,
                deletedCount: summary.deletedCount,
                testStatus: summary.testStatus,
                browser: summary.browser,
                undoAvailable: false
            )
        }
        conversations[conversationIndex] = updated
        persist()
        status = AppCopy.text("conversation.filesReverted")
        return result
    }

    public func rewind(
        conversationID: String,
        beforeMessageID messageID: String
    ) throws -> RewindResult {
        ensureContentLoaded()
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
        let result: RewindResult
        do {
            result = try memory.restoreTurns(
                conversationID: conversationID,
                turnIDs: turnIDs,
                workspace: workspace,
                abortOnConflict: false
            )
        } catch let error as WorkspaceMemoryError {
            throw mutationError(for: error)
        }

        var updated = conversation
        updated.messages = Array(conversation.messages.prefix(messageIndex))
        updated.pendingPrompts = []
        if let planID = updated.pendingPlanMessageID,
           !updated.messages.contains(where: { $0.id == planID && $0.kind == .plan }) {
            updated.pendingPlanMessageID = nil
            updated.planGateActive = false
        }
        updated.continuation = nil
        updated.modelContext = []
        if updated.messages.contains(where: { $0.kind == .user }) == false {
            updated.title = "New conversation"
            updated.blank = true
        }
        if !result.conflictPaths.isEmpty {
            updated.messages.append(
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
        ensureContentLoaded()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else {
            throw ConversationMutationError.invalidMessage
        }
        guard !anyRunBusy, !historyMutationBusy else { throw ConversationMutationError.busy }
        // Reserve the history mutation before the configuration lookup can
        // suspend the main actor; a second edit must not enter the same gap.
        historyMutationBusy = true
        defer { historyMutationBusy = false }
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

        let result: RewindResult
        do {
            result = try memory.restoreTurns(
                conversationID: conversationID,
                turnIDs: [turnID],
                workspace: workspace,
                abortOnConflict: true
            )
        } catch let error as WorkspaceMemoryError {
            throw mutationError(for: error)
        }
        guard result.conflictPaths.isEmpty else {
            throw ConversationMutationError.conflict(result.conflictPaths)
        }

        var updated = conversation
        updated.messages = Array(conversation.messages.prefix(messageIndex))
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
}

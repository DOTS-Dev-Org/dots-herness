// Copyright (c) 2026 DOTS
// Conversation loading, persistence, chat context and attachments.

import Foundation
import HarnessPluginKit
import Observation
import PluginRuntime

extension NativeAgentHost {
    /// Loads one archived transcript only when the user opens it from Archive.
    public func loadArchivedConversation(_ id: String) -> Conversation? {
        guard store.loadHeaders().contains(where: { $0.id == id && $0.archived && !$0.blank }),
              let conversation = store.loadRecentConversation(id: id, includeModelContext: false) else {
            return nil
        }
        return Self.recover(conversation)
    }

    /// Reads an older archive page without loading the conversation into the
    /// active workspace or retaining the page in the host's conversation list.
    public func loadArchivedMessagePage(
        id: String,
        endingBefore offset: Int,
        limit: Int = ConversationStore.defaultTranscriptPageSize
    ) async -> ConversationTranscriptPage? {
        guard store.loadHeaders().contains(where: { $0.id == id && $0.archived && !$0.blank }) else { return nil }
        let store = self.store
        return await Task.detached(priority: .userInitiated) {
            store.loadMessagePage(id: id, endingBefore: offset, limit: limit)
        }.value
    }

    /// Loads retained history without restoring its removed project's workspace.
    /// The original conversation record and its project path remain unchanged.
    public func openRecentConversation(_ id: String) {
        guard workspaceURL == nil,
              let page = store.loadRecentConversation(id: id, includeModelContext: false) else { return }
        let needsRecoveryContext = page.requiresToolOutcomeRecovery || !page.inFlightToolCalls.isEmpty
        let conversation = needsRecoveryContext
            ? (store.loadRecentConversation(id: id) ?? page)
            : page
        loadGeneration += 1
        contentTask?.cancel()
        contentTask = nil
        selectedID = nil
        conversations = [recoverForContext(conversation, restoreMissingContext: needsRecoveryContext)]
        clearFollowUpSuggestion()
        select(id)
    }

    /// Keep only headers for the workspace in memory. Selecting a conversation
    /// loads its newest visible page and provider context on a background task.
    func loadConversations(workspacePath: String?) {
        loadGeneration += 1
        contentTask?.cancel()
        contentTask = nil
        if workspacePath != nil, ConversationStore.normalizedPath(workspacePath) == nil {
            conversations = []
            selectedID = nil
            return
        }
        let previousSelection = selectedID
        conversations = store.loadHeaders(workspacePath: workspacePath).map(Self.recoverListed)
        let nextSelection = initialSelection()
        selectedID = nextSelection
        // Reloading the same workspace replaces its rows with headers but does not
        // change selectedID, so its selected transcript still needs a fresh read.
        if previousSelection == nextSelection, let nextSelection {
            selectionDidChange(to: nextSelection)
        }
    }

    /// Called by selectedID whenever the visible conversation changes.
    func selectionDidChange(to id: String?) {
        if let id { publishLiveReply(in: id) }
        trimInactiveConversationContent()
        loadGeneration += 1
        let generation = loadGeneration
        contentTask?.cancel()
        contentTask = nil
        guard let id,
              let conversation = conversations.first(where: { $0.id == id }) else { return }
        if conversation.contentLoaded {
            activateLoadedConversation(id)
            return
        }

        let store = self.store
        let needsRecoveryContext = conversation.requiresToolOutcomeRecovery || !conversation.inFlightToolCalls.isEmpty
        let decode = Task.detached(priority: .userInitiated) {
            store.loadRecentConversation(id: id, includeModelContext: needsRecoveryContext)
        }
        contentTask = Task { @MainActor [weak self] in
            let stored = await decode.value
            guard let self,
                  self.loadGeneration == generation else { return }
            self.contentTask = nil
            guard self.selectedID == id,
                  let stored,
                  let index = self.conversations.firstIndex(where: { $0.id == id }) else { return }
            let header = self.conversations[index]
            var loaded = self.recoverForContext(stored, restoreMissingContext: needsRecoveryContext)
            loaded.applyMetadata(from: header)
            self.conversations[index] = loaded
            self.contentTask = nil
            if loaded != stored { _ = self.store.save([loaded]) }
            self.activateLoadedConversation(id)
        }
    }

    func activateLoadedConversation(_ id: String) {
        resolvePendingPlanIntents(in: id)
        guard selectedID == id else { return }
        if conversations.first(where: { $0.id == id })?.continuation?.reason == .applicationClosed {
            Task { @MainActor [weak self] in
                await self?.resumeRecoveredConversationIfNeeded(for: id)
            }
        } else if !state(for: id).queuePausedAfterStop,
                  let conversation = conversations.first(where: { $0.id == id }),
                  // A queue left over from a long close would resend the whole history
                  // on a cold cache; it then waits for the user like Continue does.
                  conversation.messages.isEmpty
                    || Self.isWarmForAutoResume(conversation, events: contextUsageEvents()) {
            startQueuedPromptIfReleased(in: id)
        }
    }

    /// Only the selected chat and in-flight runs keep message content resident.
    /// Inactive records are saved and replaced with metadata-only headers.
    func trimInactiveConversationContent() {
        guard !historyMutationBusy else { return }
        var changed = false
        for index in conversations.indices {
            let id = conversations[index].id
            guard id != selectedID,
                  conversations[index].contentLoaded,
                  runStates[id]?.isBusy != true,
                  runStates[id]?.pendingPromptStartID == nil else { continue }
            let full = conversations[index]
            // Leaving a chat must not re-encode its provider context (MBs) on the
            // main thread: write only what changed since the last persist, if anything.
            if store.revision != persistedRevision || persistedConversations[id] != full {
                let revision = persistedRevision
                guard store.save([full], previous: persistedConversations, revision: revision) else { continue }
                if store.revision == revision + 1 { persistedRevision = store.revision }
            }
            persistedConversations[id] = full.headerCopy()
            conversations[index] = full.headerCopy()
            runStates[id]?.activeContext = []
            clearLiveReply(in: id)
            changed = true
        }
        if changed { touchLists() }
    }

    /// Sync callers that read one transcript never hydrate the rest of the list.
    func ensureContentLoaded(_ conversationID: String? = nil) {
        guard let id = conversationID ?? selectedID,
              let index = conversations.firstIndex(where: { $0.id == id }),
              !conversations[index].contentLoaded || !conversations[index].transcriptComplete else { return }
        // Only a sync load of the selected chat supersedes its background load. A stale
        // row of the previous chat must not cancel it: nothing would restart it.
        if id == selectedID {
            loadGeneration += 1
            contentTask?.cancel()
            contentTask = nil
        }
        guard let stored = store.load(id: id),
              let currentIndex = conversations.firstIndex(where: { $0.id == id }) else { return }
        let header = conversations[currentIndex]
        var loaded = recoverForContext(stored)
        loaded.applyMetadata(from: header)
        conversations[currentIndex] = loaded
        if loaded != stored { _ = store.save([loaded]) }
        if id != selectedID {
            Task { @MainActor [weak self] in
                await Task.yield()
                self?.trimInactiveConversationContent()
            }
        }
    }

    /// Ensures the provider context is ready without hydrating older visible
    /// transcript pages. Normal prompt submission only needs modelContext.
    @discardableResult
    func ensurePromptContextLoaded(_ conversationID: String? = nil) -> Bool {
        guard let id = conversationID ?? selectedID,
              let index = conversations.firstIndex(where: { $0.id == id }) else { return true }
        if conversations[index].modelContextLoaded { return true }
        guard let stored = store.loadRecentConversation(id: id) else { return false }
        let header = conversations[index]
        var loaded = recoverForContext(stored)
        if header.contentLoaded {
            loaded.messages = header.messages
            loaded.transcriptComplete = header.transcriptComplete
            loaded.messageStartIndex = header.messageStartIndex
            loaded.loadedTranscriptMessageIDs = header.loadedTranscriptMessageIDs
        }
        guard loaded.transcriptComplete || !loaded.modelContext.isEmpty else { return false }
        loaded.applyMetadata(from: header)
        conversations[index] = loaded
        if loaded != stored { _ = store.save([loaded]) }
        return true
    }

    /// Loads another visible page from disk while keeping the full provider
    /// context and all previously requested pages intact.
    @discardableResult
    public func loadOlderMessages(in conversationID: String, limit: Int = ConversationStore.defaultTranscriptPageSize) async -> Bool {
        guard selectedID == conversationID,
              let index = conversations.firstIndex(where: { $0.id == conversationID }),
              conversations[index].hasOlderTranscriptMessages else { return false }
        let endIndex = conversations[index].messageStartIndex
        let store = self.store
        let page = await Task.detached(priority: .userInitiated) {
            store.loadMessagePage(id: conversationID, endingBefore: endIndex, limit: limit)
        }.value
        guard let page,
              selectedID == conversationID,
              let currentIndex = conversations.firstIndex(where: { $0.id == conversationID }),
              conversations[currentIndex].messageStartIndex == endIndex else { return false }

        let currentIDs = Set(conversations[currentIndex].messages.map(\.id))
        let older = page.messages.filter { !currentIDs.contains($0.id) }
        conversations[currentIndex].messages.insert(contentsOf: older, at: 0)
        conversations[currentIndex].loadedTranscriptMessageIDs.formUnion(page.messages.map(\.id))
        conversations[currentIndex].messageStartIndex = page.startIndex
        conversations[currentIndex].transcriptComplete = page.startIndex == 0
        return !older.isEmpty
    }

    /// Resolves when the selected transcript has finished loading.
    public func waitForContent() async {
        await contentTask?.value
    }

    func cacheKey(
        for configuration: AgentConfiguration,
        planMode: Bool = false,
        model: String? = nil,
        tools: [AgentToolDefinition] = [],
        router: RouterController? = nil
    ) -> String? {
        let stablePromptRevision = AgentCacheNamespace.promptContextRevision(
            [corePolicySection(workspace: workspaceURL)]
        )
        return AgentCacheNamespace.key(
            projectID: memory.projectID,
            model: model ?? configuration.model,
            // Plan guidance is turn-dynamic and the tool list is canonicalized
            // separately; keep the reusable stable prefix on the same namespace.
            planMode: false,
            contextRevision: stablePromptRevision,
            provider: configuration.provider,
            api: configuration.api,
            // RouterController scopes the wire cache key to the account that
            // actually serves the request, including after quota continuation.
            accountID: router == nil ? (configuration.accountID ?? configuration.sessionAccountID) : nil,
            toolFingerprint: AgentCacheNamespace.toolFingerprint(tools)
        )
    }

    @discardableResult
    func persist() -> Bool {
        // Rewriting every loaded chat re-encoded each one's provider context (MBs) on
        // every append, so parallel runs cost N² on the main thread. Write what changed;
        // another writer bumping the revision makes the snapshots untrustworthy.
        if store.revision != persistedRevision { persistedConversations = [:] }
        let changed = conversations.filter { persistedConversations[$0.id] != $0 }
        if !changed.isEmpty {
            guard store.save(changed, previous: persistedConversations, revision: persistedRevision) else { return false }
            persistedRevision = store.revision
        }
        // Rebuilt, not merged: chats that left `conversations` must not stay resident here.
        persistedConversations = Dictionary(conversations.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        // Every list and the composer read `listTick`: an unchanged save must not re-render them.
        if !changed.isEmpty { touchLists() }
        return true
    }

    /// `persist()` for the per-tool-call path: a call's start, result and model context land
    /// in one main-actor turn, and each write diffed and re-encoded the conversation.
    /// They collapse into one write on the next turn.
    func persistSoon() {
        guard !persistScheduled else { return }
        persistScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.persistScheduled = false
            self.persist()
        }
    }

    func skillID(from call: AgentToolCall) -> String? {
        guard let data = call.arguments.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["id"] as? String
    }

    func conversation(for id: String) -> Conversation? {
        conversations.first(where: { $0.id == id })
    }

    func recoverForContext(_ conversation: Conversation, restoreMissingContext: Bool = true) -> Conversation {
        var recovered = Self.recover(conversation)
        if !recovered.modelContextLoaded, !restoreMissingContext { return recovered }
        if recovered.modelContext.isEmpty, !recovered.transcriptComplete {
            let visibleMessages = recovered.messages
            let visibleStartIndex = recovered.messageStartIndex
            let visibleMessageIDs = recovered.loadedTranscriptMessageIDs
            if let full = store.load(id: recovered.id) {
                recovered = Self.recover(full)
                _ = Self.synchronizeGeneratedMediaContext(&recovered)
                if recovered.modelContext.isEmpty, !recovered.messages.isEmpty {
                    recovered.modelContext = makeAgentContext(
                        for: recovered,
                        workspace: workspaceURL
                    )
                    recovered.modelContextLoaded = true
                }
                // Legacy sessions may need their full transcript once to rebuild
                // the provider context. Keep only the requested visible page in
                // the long-lived conversation after that recovery completes.
                recovered.messages = visibleMessages
                recovered.transcriptComplete = false
                recovered.messageStartIndex = visibleStartIndex
                recovered.loadedTranscriptMessageIDs = visibleMessageIDs
                return recovered
            }
            // A partial visible page cannot safely stand in for missing provider
            // context. Leave it empty so prompt submission can fail closed.
            return recovered
        }
        _ = Self.synchronizeGeneratedMediaContext(&recovered)
        if recovered.modelContext.isEmpty, recovered.transcriptComplete, !recovered.messages.isEmpty {
            recovered.modelContext = makeAgentContext(
                for: recovered,
                workspace: workspaceURL
            )
            recovered.modelContextLoaded = true
        }
        return recovered
    }

    func clearPendingPlan(_ planID: String, in conversationID: String) {
        guard conversations.first(where: { $0.id == conversationID })?.pendingPlanMessageID == planID else { return }
        updateConversation(conversationID) {
            $0.pendingPlanMessageID = nil
            $0.planGateActive = false
        }
    }

    func journalToolBatch(_ calls: [AgentToolCall], in conversationID: String) {
        guard !calls.isEmpty,
              let index = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
        conversations[index].inFlightToolCalls = calls
        conversations[index].requiresToolOutcomeRecovery = false
        persist()
    }

    func finishJournaledTools(in conversationID: String) {
        guard let index = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
        conversations[index].inFlightToolCalls = []
        persist()
    }

    func acknowledgeToolOutcomeRecovery(in conversationID: String) {
        guard let index = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
        guard conversations[index].requiresToolOutcomeRecovery else { return }
        conversations[index].requiresToolOutcomeRecovery = false
        conversations[index].inFlightToolCalls = []
        persist()
    }

    func turnIDs(in messages: [ChatMessage], from index: Int) -> [String]? {
        var result: [String] = []
        var seen = Set<String>()
        for message in messages[index...] where message.kind == .user {
            guard let turnID = message.turnID else { return nil }
            if seen.insert(turnID).inserted {
                result.append(turnID)
            }
        }
        return result
    }

    func mutationError(for error: WorkspaceMemoryError) -> ConversationMutationError {
        switch error {
        case .snapshotUnavailable, .noWorkspace:
            return .snapshotUnavailable
        case .snapshotRestoreFailed(let path):
            return .restoreFailed(path)
        default:
            return .restoreFailed(error.localizedDescription)
        }
    }

    func recordConversationLifecycle(
        _ conversation: Conversation,
        state: ConversationLifecycleState
    ) {
        guard let workspaceURL,
              ConversationStore.normalizedPath(conversation.cwd) == ConversationStore.normalizedPath(workspaceURL.path) else {
            return
        }
        memory.recordConversationLifecycle(
            conversationID: conversation.id,
            title: conversation.title,
            state: state
        )
    }

    func updateConversation(_ id: String, update: (inout Conversation) -> Void) {
        if let index = conversations.firstIndex(where: { $0.id == id }) {
            update(&conversations[index])
            persist()
            return
        }

    }

    /// A model pick is metadata only; its write happens off the main thread.
    func setConversationModelPreference(_ modelID: String?, for id: String) {
        guard let index = conversations.firstIndex(where: { $0.id == id }),
              conversations[index].modelPreferenceID != modelID else { return }
        conversations[index].modelPreferenceID = modelID
        store.saveInBackground([conversations[index].headerCopy()])
        touchLists()
    }

    /// Fold in conversations written to the store by another host (e.g. a
    /// scheduled-task run) without disturbing the active run or selection.
    public func mergeExternalConversations() {
        guard let path = workspaceURL?.path else { return }
        let known = Set(conversations.map(\.id))
        let extras = store.loadHeaders(workspacePath: path)
            .filter { !known.contains($0.id) }
            .map(Self.recoverListed)
        guard !extras.isEmpty else { return }
        conversations.append(contentsOf: extras)
        conversations.sort { $0.id < $1.id }
    }

    static func isEmptyDraft(_ conversation: Conversation) -> Bool {
        conversation.messages.isEmpty && (conversation.blank || conversation.title == "New conversation" || conversation.title == "New chat")
    }

    /// `recover` derives title/blank from the transcript, which a header lacks.
    static func recoverListed(_ conversation: Conversation) -> Conversation {
        guard !conversation.contentLoaded else { return recover(conversation) }
        var header = conversation
        header.running = false
        return header
    }

    static func recover(_ conversation: Conversation) -> Conversation {
        var recovered = conversation
        let wasRunning = recovered.running
        recovered.running = false
        sanitizeVisibleSkillPreviews(&recovered)
        if recovered.transcriptComplete,
           let planID = recovered.pendingPlanMessageID,
           !recovered.messages.contains(where: { $0.id == planID && $0.kind == .plan }) {
            recovered.pendingPlanMessageID = nil
        }
        recovered.planGateActive = recovered.planGateActive || recovered.pendingPlanMessageID != nil
        if wasRunning || !recovered.inFlightToolCalls.isEmpty {
            recovered.requiresToolOutcomeRecovery = true
            let completedToolIDs = Set(
                recovered.modelContext
                    .filter { $0.role == .tool }
                    .compactMap(\.toolCallID)
            )
            for call in recovered.inFlightToolCalls where !completedToolIDs.contains(call.id) {
                recovered.modelContext.append(AgentMessage(
                    role: .tool,
                    content: "The application closed before the result of this tool call was durably known. The tool may have completed or may not have run. Reconcile the current state before invoking the same mutation again.",
                    name: call.name,
                    toolCallID: call.id
                ))
            }
            let existingPauseReason = recovered.continuation?.reason
            if existingPauseReason != .applicationClosed,
               existingPauseReason != .userStopped,
               !recovered.turnFinished {
                recovered.continuation = ContinuationState(
                    reason: .applicationClosed,
                    message: AppCopy.text("agent.applicationClosedMessage")
                )
            }
        }
        if recovered.transcriptComplete {
            if let firstUserMessage = recovered.messages.first(where: { $0.kind == .user }) {
                let titleText = firstUserMessage.text.isEmpty
                    ? firstUserMessage.attachments.map { $0.name }.joined(separator: ", ")
                    : firstUserMessage.text
                recovered.title = Self.title(for: titleText)
                recovered.blank = false
            } else if recovered.messages.isEmpty,
                      recovered.title == "New conversation" || recovered.title == "New chat" {
                recovered.blank = true
            }
        }
        return recovered
    }

    static func title(for text: String) -> String {
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        let compact = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(compact.prefix(48))
    }

    static let skillReadHistoryMarker = "SKILL.md read; content is hidden from conversation history."

    private var attachmentSnapshotDirectory: URL {
        paths.runtime.appendingPathComponent("attachment-snapshots", isDirectory: true)
    }

    func stabilizeAttachment(_ attachment: ChatAttachment) -> ChatAttachment {
        attachment.snapshot(in: attachmentSnapshotDirectory)
    }

    static func attachmentKey(_ attachment: ChatAttachment) -> String {
        attachment.attachmentID ?? attachment.path
    }

    /// Returns the newest immutable revision known to this provider transcript.
    /// A V2 tool result wins over the original V1 user message, while both
    /// remain present in the durable history.
    static func latestAttachments(in messages: [AgentMessage]) -> [String: ChatAttachment] {
        var result: [String: ChatAttachment] = [:]
        for message in messages {
            for attachment in message.attachments {
                let key = attachmentKey(attachment)
                guard let previous = result[key] else {
                    result[key] = attachment
                    continue
                }
                if attachment.revision > previous.revision
                    || (attachment.revision == previous.revision && attachment.deliveredHash != nil && previous.deliveredHash == nil) {
                    result[key] = attachment
                }
            }
        }
        return result
    }

    static func mergeLatestAttachments(
        _ messages: [AgentMessage],
        into ledger: inout [String: ChatAttachment]
    ) {
        for (key, attachment) in latestAttachments(in: messages) {
            guard let previous = ledger[key] else {
                ledger[key] = attachment
                continue
            }
            if attachment.revision > previous.revision
                || (attachment.revision == previous.revision && attachment.deliveredHash != nil && previous.deliveredHash == nil) {
                ledger[key] = attachment
            }
        }
    }

    static func markDelivered(_ messages: inout [AgentMessage]) {
        for index in messages.indices where !messages[index].attachments.isEmpty {
            messages[index].attachments = messages[index].attachments.map { attachment in
                guard let hash = attachment.contentHash,
                      attachment.snapshotPath != nil,
                      attachment.deliveredHash != hash else { return attachment }
                return ChatAttachment(
                    path: attachment.path,
                    kind: attachment.kind,
                    mimeType: attachment.mimeType,
                    bookmarkData: attachment.bookmarkData,
                    snapshotPath: attachment.snapshotPath,
                    contentHash: attachment.contentHash,
                    attachmentID: attachment.attachmentID,
                    revision: attachment.revision,
                    deliveredHash: hash,
                    sourceStatus: attachment.sourceStatus
                )
            }
        }
    }

    /// A revision notice is appended once to the durable transcript when its
    /// observation fingerprint changes; it never rewrites an earlier turn.
    static func attachmentRevisionNotice(for attachments: [ChatAttachment]) -> String? {
        let notices = attachments.compactMap { attachment -> String? in
            let observation = attachment.observeSource()
            let status: String
            switch observation.status {
            case .current:
                return nil
            case .changed:
                status = "changed"
            case .missing:
                status = "missing"
            case .unreadable:
                status = "unreadable"
            }
            let nextRevision = max(attachment.revision, 1) + 1
            let detail: String
            switch observation.status {
            case .missing:
                detail = "source_missing\nhistorical_revision_preserved\nlatest_revision_unavailable"
            case .unreadable:
                detail = "source_unreadable\nhistorical_revision_preserved\nlatest_revision_unavailable"
            default:
                detail = "The source file changed. The historical V1 bytes remain immutable and must not be treated as current."
            }
            return """
            [Attachment revision notice]
            attachment_id: \(attachment.id)
            name: \(attachment.name)
            revision: V\(nextRevision)
            status: \(status)
            \(detail)
            If current content is needed, call get_latest_attachment with {"attachment_id":"\(attachment.id)"}. Do not infer missing or unreadable bytes.
            """
        }
        guard !notices.isEmpty else { return nil }
        return notices.sorted().joined(separator: "\n\n")
    }

    func latestAttachmentResult(
        for call: AgentToolCall,
        in ledger: [String: ChatAttachment]
    ) -> (message: String, attachment: ChatAttachment?) {
        guard let requestedID = Self.argument(call, key: "attachment_id"),
              let current = ledger[requestedID] else {
            return (
                "attachment_not_found\nhistorical_revision_preserved\nlatest_revision_unavailable",
                nil
            )
        }

        let observation = current.observeSource()
        switch observation.status {
        case .missing:
            return (
                "source_missing\nhistorical_revision_preserved\nlatest_revision_unavailable\nattachment_id: \(current.id)",
                nil
            )
        case .unreadable:
            return (
                "source_unreadable\nhistorical_revision_preserved\nlatest_revision_unavailable\nattachment_id: \(current.id)",
                nil
            )
        case .current:
            if current.snapshotPath != nil,
               current.contentHash == observation.currentHash,
               observation.currentHash != nil {
                return (
                    "latest_revision_current\nattachment_id: \(current.id)\nrevision: V\(max(current.revision, 1))\ncontent_hash: \(current.contentHash!)",
                    current
                )
            }
            fallthrough
        case .changed:
            let revision = current.refreshedSnapshot(in: attachmentSnapshotDirectory)
            guard revision.snapshotPath != nil,
                  revision.contentHash != nil,
                  let requestedHash = observation.currentHash,
                  revision.contentHash == requestedHash else {
                return (
                    "source_unreadable\nhistorical_revision_preserved\nlatest_revision_unavailable\nattachment_id: \(current.id)",
                    nil
                )
            }
            let state = observation.status == .changed ? "latest_revision_created" : "latest_revision_current"
            return (
                "\(state)\nattachment_id: \(revision.id)\nrevision: V\(revision.revision)\ncontent_hash: \(revision.contentHash!)",
                revision
            )
        }
    }

    @discardableResult
    func stabilizePersistedAttachments(in conversationIndex: Int) -> Bool {
        guard conversations.indices.contains(conversationIndex) else { return false }
        var changed = false
        for messageIndex in conversations[conversationIndex].messages.indices {
            let current = conversations[conversationIndex].messages[messageIndex].attachments
            let stable = current.map(stabilizeAttachment)
            if stable != current {
                conversations[conversationIndex].messages[messageIndex].attachments = stable
                changed = true
            }
        }

        var context = conversations[conversationIndex].modelContext
        for messageIndex in context.indices {
            let current = context[messageIndex].attachments
            let stable = current.map(stabilizeAttachment)
            if stable != current {
                context[messageIndex].attachments = stable
                changed = true
            }
        }
        if changed { conversations[conversationIndex].modelContext = context }
        return changed
    }

    static func durableContext(_ messages: [AgentMessage]) -> [AgentMessage] {
        // Visible previews are sanitized separately. The provider transcript
        // must retain the exact tool results it has already processed.
        messages
    }

    private static func sanitizeVisibleSkillPreviews(_ conversation: inout Conversation) {
        let prefix = "✓ skill.read\n"
        for index in conversation.messages.indices where
            conversation.messages[index].kind == .tool
            && conversation.messages[index].text.hasPrefix(prefix)
            && conversation.messages[index].text.count > prefix.count {
            conversation.messages[index].text = prefix + skillReadHistoryMarker
        }
    }

    /// Starts the explore subagents of one assistant turn together, bounded by
    /// maxPerTurn, and hands back their tasks instead of their results.
    ///
    /// Awaiting the whole batch before the tool loop began made every other call
    /// in the turn — a write, a search, a command — wait behind the slowest
    /// subagent. The caller joins each task when it reaches that call, and must
    /// cancel whatever it never reaches: these are unstructured tasks, so a
    /// cancelled run does not propagate into them on its own.
    static func startExplore(
        _ calls: [AgentToolCall],
        complete: @escaping ExploreTool.Complete,
        workspace: URL?,
        hints: [String: String] = [:]
    ) -> [String: Task<ExploreTool.Outcome, Never>] {
        guard let workspace else { return [:] }
        let explores = calls.filter { $0.name == ExploreTool.name }
        guard !explores.isEmpty else { return [:] }
        var pending: [String: Task<ExploreTool.Outcome, Never>] = [:]
        for call in explores.dropFirst(ExploreTool.maxPerTurn) {
            let answer = "Tool error: maximum of \(ExploreTool.maxPerTurn) explore subagents per turn exceeded. Run remaining investigations in subsequent turns."
            pending[call.id] = Task {
                ExploreTool.Outcome(
                    answer: answer,
                    readPaths: [], steps: 0, hitStepLimit: false, answered: false, searches: 0
                )
            }
        }
        for call in explores.prefix(ExploreTool.maxPerTurn) {
            pending[call.id] = Task(priority: .userInitiated) {
                await ExploreTool.run(call, complete: complete, workspace: workspace, hints: hints[call.id] ?? "")
            }
        }
        return pending
    }

    /// The files named like each explore question, keyed by call id.
    func exploreHints(_ calls: [AgentToolCall], workspace: URL?) -> [String: String] {
        guard memory.enabled, let workspace, workspaceURL?.standardizedFileURL == workspace.standardizedFileURL else { return [:] }
        var hints: [String: String] = [:]
        for call in calls where call.name == ExploreTool.name {
            if let task = ExploreTool.task(of: call) { hints[call.id] = memory.filesText(for: task, lessons: feedbackStore?.lessons() ?? []) }
        }
        return hints
    }

    /// Runs explore subagents side by side, bounded by maxPerTurn, and collects outcomes.
    static func prefetchExplore(
        _ calls: [AgentToolCall],
        complete: @escaping ExploreTool.Complete,
        workspace: URL?
    ) async -> [String: ExploreTool.Outcome] {
        let tasks = startExplore(calls, complete: complete, workspace: workspace)
        var outcomes: [String: ExploreTool.Outcome] = [:]
        for (id, task) in tasks {
            outcomes[id] = await task.value
        }
        return outcomes
    }


    /// Runs the read-only workspace calls of one assistant turn concurrently.
    /// Returns results by call id; anything not returned falls through to the
    /// normal sequential path.
    static func prefetchReadOnly(
        _ calls: [AgentToolCall],
        workspace: URL?,
        conversationID: String,
        readRoots: [URL],
        planMode: Bool
    ) async -> [String: String] {
        guard workspace != nil else { return [:] }
        // Prefetching answers every read before the loop reaches the batch's other
        // calls, so a batch that can change the workspace must not use it: reading
        // a path the same turn writes would return the old content and be recorded
        // to the model as fact. `explore` only reads, so it can share the prefetch.
        guard calls.allSatisfy({ WorkspaceTools.isReadOnly($0.name) || $0.name == ExploreTool.name }) else {
            return [:]
        }
        let readOnly = calls.filter {
            WorkspaceTools.isReadOnly($0.name)
                && $0.name != WorkspaceTools.generatedMediaInspectionName
        }
        guard readOnly.count > 1 else { return [:] }
        _ = planMode // read-only calls are allowed in either mode
        return await withTaskGroup(of: (String, String).self) { group in
            var pending = readOnly.makeIterator()
            var started = 0
            while started < Self.maxConcurrentReads, let call = pending.next() {
                group.addTask(priority: .userInitiated) {
                    guard let workspace else { return (call.id, "") }
                    return (call.id, WorkspaceTools.execute(call, workspace: workspace, conversationID: conversationID, readRoots: readRoots))
                }
                started += 1
            }
            var results: [String: String] = [:]
            while let (id, result) = await group.next() {
                results[id] = result
                guard let call = pending.next() else { continue }
                group.addTask(priority: .userInitiated) {
                    guard let workspace else { return (call.id, "") }
                    return (call.id, WorkspaceTools.execute(call, workspace: workspace, conversationID: conversationID, readRoots: readRoots))
                }
            }
            return results
        }
    }

    static func toolPreview(_ result: String) -> String {
        let limit = 700
        if result.count <= limit { return result }
        return String(result.prefix(limit)) + "…"
    }
}

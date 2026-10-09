// Copyright (c) 2026 DOTS
// Conversation loading, persistence, chat context and attachments.

import Foundation
import HarnessPluginKit
import Observation
import PluginRuntime

extension NativeAgentHost {
    /// Loads one archived transcript only when the user opens it from Archive.
    public func loadArchivedConversation(_ id: String) -> Conversation? {
        guard let conversation = store.loadAll().first(where: { $0.id == id && $0.archived && !$0.blank }) else {
            return nil
        }
        return Self.recover(conversation)
    }

    /// Loads retained history without restoring its removed project's workspace.
    /// The original conversation record and its project path remain unchanged.
    public func openRecentConversation(_ id: String) {
        guard workspaceURL == nil,
              let conversation = store.loadAll().first(where: { $0.id == id }) else { return }
        loadGeneration += 1
        contentTask?.cancel()
        contentTask = nil
        conversations = [Self.recover(conversation)]
        selectedID = nil
        clearFollowUpSuggestion()
        select(id)
    }

    /// Staged: titles show at once from headers; transcripts decode off the main
    /// thread and replace the headers when ready. Sends wait for that (see `send`).
    func loadConversations(workspacePath: String?) {
        loadGeneration += 1
        let generation = loadGeneration
        contentTask = nil
        guard let workspacePath else {
            let stored = store.load(workspacePath: nil)
            conversations = stored.map(recoverForContext)
            if conversations != stored { persist() }
            selectedID = initialSelection()
            return
        }
        guard ConversationStore.normalizedPath(workspacePath) != nil else {
            conversations = []
            selectedID = nil
            return
        }
        // A small history decodes in a few milliseconds: load it whole, no header stage.
        guard store.fileSize > Self.stagedLoadThreshold else {
            let stored = store.load(workspacePath: workspacePath)
            let recovered = stored.map(recoverForContext)
            conversations = recovered
            if recovered != stored { store.save(recovered) }
            selectedID = initialSelection()
            return
        }
        conversations = store.loadHeaders(workspacePath: workspacePath).map(Self.recoverListed)
        selectedID = initialSelection()
        let store = self.store
        // Started here, not inside the main-actor task: that task only gets the main
        // thread once the first frame is out, and the decode should be done by then.
        let decode = Task.detached(priority: .userInitiated) {
            store.load(workspacePath: workspacePath)
        }
        contentTask = Task { @MainActor [weak self] in
            let full = await decode.value
            guard let self, self.loadGeneration == generation else { return }
            self.hydrateConversations(full)
        }
    }

    private func hydrateConversations(_ full: [Conversation]) {
        let byID = Dictionary(full.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // Walk the in-memory list so chats created or removed meanwhile stay that way;
        // sidebar edits made to a header (rename, pin, ...) win over the decoded copy.
        conversations = conversations.compactMap { current in
            guard !current.contentLoaded else { return current }
            guard let stored = byID[current.id] else { return nil }
            var loaded = recoverForContext(stored)
            loaded.applyMetadata(from: current)
            return loaded
        }
        let recovered = conversations
        let stored = full.filter { current in conversations.contains(where: { $0.id == current.id }) }
        if recovered != stored { persist() }
        if let selectedID, !conversations.contains(where: { $0.id == selectedID }) {
            self.selectedID = initialSelection()
        }
    }

    private static let stagedLoadThreshold = 256 << 10

    /// Sync callers that read transcripts (rewind, edit, feedback) must never see a
    /// header: finish the load now instead of waiting for the background decode.
    func ensureContentLoaded() {
        guard conversations.contains(where: { !$0.contentLoaded }) else { return }
        loadGeneration += 1
        contentTask = nil
        hydrateConversations(store.load(workspacePath: workspaceURL?.path))
    }

    /// Resolves once the current workspace's transcripts are in memory.
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
            systemPromptSections(workspace: workspaceURL, planMode: false, prompt: "")
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
        guard store.save(conversations) else { return false }
        touchLists()
        return true
    }

    func skillID(from call: AgentToolCall) -> String? {
        guard let data = call.arguments.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["id"] as? String
    }

    func conversation(for id: String) -> Conversation? {
        conversations.first(where: { $0.id == id })
    }

    func recoverForContext(_ conversation: Conversation) -> Conversation {
        var recovered = Self.recover(conversation)
        _ = Self.synchronizeGeneratedMediaContext(&recovered)
        if recovered.modelContext.isEmpty, !recovered.messages.isEmpty {
            recovered.modelContext = makeAgentContext(
                for: recovered,
                workspace: workspaceURL
            )
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
        conversations[index].inFlightToolCalls = calls.map {
            InFlightToolCall(id: $0.id, name: $0.name, arguments: $0.arguments)
        }
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

    func invalidatePendingPlan(in conversationID: String?) {
        guard let conversationID,
              conversations.first(where: { $0.id == conversationID })?.pendingPlanMessageID != nil else { return }
        updateConversation(conversationID) {
            $0.pendingPlanMessageID = nil
            $0.planGateActive = false
        }
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

    /// Fold in conversations written to the store by another host (e.g. a
    /// scheduled-task run) without disturbing the active run or selection.
    public func mergeExternalConversations() {
        guard let path = workspaceURL?.path else { return }
        let known = Set(conversations.map(\.id))
        let extras = store.load(workspacePath: path)
            .filter { !known.contains($0.id) }
            .map(Self.recover)
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
        if let planID = recovered.pendingPlanMessageID,
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
            if recovered.continuation?.reason != .applicationClosed, !recovered.turnFinished {
                recovered.continuation = ContinuationState(
                    reason: .applicationClosed,
                    message: "The application closed while this plan was active. Recovery will continue automatically when possible; tool results are not assumed and no tool call will be replayed."
                )
            }
        }
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

    /// Legacy callers append a notice after complete tool groups. The run loop
    /// deduplicates and persists these notices through its cache epoch.
    static func requestMessages(
        _ messages: [AgentMessage],
        attachmentRevisionNotice: String?
    ) -> [AgentMessage] {
        guard let attachmentRevisionNotice,
              !attachmentRevisionNotice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return messages }
        var result = messages
        var notice = AgentMessage(role: .user, content: attachmentRevisionNotice)
        notice.promptContextCaptured = true
        result.append(notice)
        return result
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
        workspace: URL?
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
                await ExploreTool.run(call, complete: complete, workspace: workspace)
            }
        }
        return pending
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

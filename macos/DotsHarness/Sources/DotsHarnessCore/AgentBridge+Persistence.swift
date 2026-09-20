// Copyright (c) 2026 DOTS
// Conversation loading, persistence, chat context and attachments.

import Foundation
import HarnessPluginKit
import Observation
import PluginRuntime

extension NativeAgentHost {
    /// Staged: titles show at once from headers; transcripts decode off the main
    /// thread and replace the headers when ready. Sends wait for that (see `send`).
    func loadConversations(workspacePath: String?) {
        loadGeneration += 1
        let generation = loadGeneration
        contentTask = nil
        // A small history decodes in a few milliseconds: load it whole, no header stage.
        guard store.fileSize > Self.stagedLoadThreshold else {
            conversations = store.load(workspacePath: workspacePath).map(recoverForContext)
            selectedID = conversations.first(where: { !$0.archived })?.id
            if area == .chat, let selected {
                activateChatContext(for: selected)
            }
            return
        }
        conversations = store.loadHeaders(workspacePath: workspacePath).map(Self.recoverListed)
        selectedID = conversations.first(where: { !$0.archived })?.id
        let store = self.store
        contentTask = Task { @MainActor [weak self] in
            let full = await Task.detached(priority: .userInitiated) {
                store.load(workspacePath: workspacePath)
            }.value
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
        if let selectedID, !conversations.contains(where: { $0.id == selectedID }) {
            self.selectedID = conversations.first(where: { !$0.archived })?.id
        }
        if area == .chat, let selected {
            activateChatContext(for: selected)
        }
    }

    private static let stagedLoadThreshold = 256 << 10

    /// Sync callers that read transcripts (rewind, edit, feedback) must never see a
    /// header: finish the load now instead of waiting for the background decode.
    func ensureContentLoaded() {
        guard conversations.contains(where: { !$0.contentLoaded }) else { return }
        loadGeneration += 1
        contentTask = nil
        hydrateConversations(store.load(workspacePath: area == .chat ? nil : workspaceURL?.path))
    }

    /// Resolves once the current workspace's transcripts are in memory.
    public func waitForContent() async {
        await contentTask?.value
    }

    func cacheKey(
        for configuration: AgentConfiguration,
        planMode: Bool = false,
        model: String? = nil,
        tools: [AgentToolDefinition] = []
    ) -> String? {
        let conversation = activeConversationID.flatMap { id in conversations.first(where: { $0.id == id }) }
            ?? selected
        let ledger = area == .chat ? chatLedger(for: conversation) : ChatContextLedger()
        return AgentCacheNamespace.key(
            area: area,
            conversationID: conversation?.id ?? "none",
            chatProjectID: conversation?.chatProjectID,
            // A Chat cache namespace must not carry the Coding project's
            // identity, even though both bridges share the memory service.
            codingProjectID: area == .coding ? memory.projectID : nil,
            model: model ?? configuration.model,
            // Plan mode keeps the same tool list and cache namespace.
            planMode: false,
            contextRevision: ledger.revision,
            rootIDs: ledger.roots.map(\.id),
            provider: configuration.provider,
            api: configuration.api,
            accountID: configuration.accountID ?? configuration.sessionAccountID,
            toolFingerprint: AgentCacheNamespace.toolFingerprint(tools),
            contextSegment: "compaction-\(conversation?.contextCompactionCount ?? 0)"
        )
    }

    func chatScopeID(for conversation: Conversation?) -> String {
        guard let conversation else { return "conversation-unknown" }
        if let project = conversation.chatProjectID, !project.isEmpty {
            return "project-\(project)"
        }
        return "conversation-\(conversation.id)"
    }

    func chatLedger(for conversation: Conversation?) -> ChatContextLedger {
        guard area == .chat, let chatContextStore else { return ChatContextLedger() }
        return chatContextStore.load(scopeID: chatScopeID(for: conversation))
    }

    func activateChatContext(for conversation: Conversation) {
        guard area == .chat else { return }
        activeChatScopeID = chatScopeID(for: conversation)
        activeChatRoots = chatLedger(for: conversation).roots
    }

    @discardableResult
    func attachChatRoots(
        from text: String,
        conversationID: String,
        messageID: String
    ) -> [ChatContextRoot] {
        guard area == .chat, let chatContextStore,
              let conversation = conversations.first(where: { $0.id == conversationID }) else { return [] }
        let scopeID = chatScopeID(for: conversation)
        var ledger = chatContextStore.load(scopeID: scopeID)
        let incoming = ChatPathParser.roots(
            from: text,
            knownRoots: ledger.roots,
            sourceMessageID: messageID
        )
        let attached = ledger.attach(roots: incoming, to: messageID)
        chatContextStore.save(ledger, scopeID: scopeID)
        activeChatScopeID = scopeID
        activeChatRoots = ledger.roots
        return attached
    }

    func chatContextText(for conversation: Conversation?) -> String {
        guard area == .chat else { return "" }
        let ledger = chatLedger(for: conversation)
        let roots = ledger.roots.map { root in
            "- [\(root.id)] \(root.path) (\(root.kind.rawValue))"
        }
        var sections = ["""

        Chat context ledger (revision \(ledger.revision))
        - These are verified roots explicitly supplied by the user in this Chat project or conversation.
        - They persist across messages; do not discard an older root when a new root is added.
        - Use the matching contextRootID on every filesystem or terminal tool call.
        - If there is no root, ask the user for a file or folder path. Never use Environment.currentDirectory or another hidden cwd.
        - If a write could target more than one root, read first and ask a short clarification question before mutating.
        """]
        if !roots.isEmpty { sections.append("Known context roots:\n" + roots.joined(separator: "\n")) }
        if !ledger.projectNotes.isEmpty { sections.append("Project notes:\n" + ledger.projectNotes.map { "- \($0)" }.joined(separator: "\n")) }
        if !ledger.changeSummaries.isEmpty { sections.append("Recent change summaries:\n" + ledger.changeSummaries.suffix(20).map { "- \($0)" }.joined(separator: "\n")) }
        return sections.joined(separator: "\n")
    }

    func persist() {
        store.save(conversations)
        touchLists()
    }

    func skillID(from call: AgentToolCall) -> String? {
        guard let data = call.arguments.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["id"] as? String
    }

    func conversation(for id: String) -> Conversation? {
        conversations.first(where: { $0.id == id })
            ?? store.load(workspacePath: nil).first(where: { $0.id == id }).map(recoverForContext)
    }

    func recoverForContext(_ conversation: Conversation) -> Conversation {
        var recovered = Self.recover(conversation)
        _ = Self.synchronizeGeneratedMediaContext(&recovered)
        if recovered.modelContext.isEmpty, !recovered.messages.isEmpty {
            recovered.modelContext = makeAgentContext(
                for: recovered,
                workspace: area == .chat ? nil : workspaceURL
            )
        }
        return recovered
    }

    func clearPendingPlan(_ planID: String, in conversationID: String) {
        guard conversations.first(where: { $0.id == conversationID })?.pendingPlanMessageID == planID else { return }
        updateConversation(conversationID) { $0.pendingPlanMessageID = nil }
    }

    func invalidatePendingPlan(in conversationID: String?) {
        guard let conversationID,
              conversations.first(where: { $0.id == conversationID })?.pendingPlanMessageID != nil else { return }
        updateConversation(conversationID) { $0.pendingPlanMessageID = nil }
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

        var projectless = store.load(workspacePath: nil)
        guard let index = projectless.firstIndex(where: { $0.id == id }) else { return }
        update(&projectless[index])
        store.save(projectless)
        touchLists()
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
        conversation.messages.isEmpty && (conversation.blank || conversation.title == "New chat")
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
        recovered.running = false
        sanitizeVisibleSkillPreviews(&recovered)
        if let planID = recovered.pendingPlanMessageID,
           !recovered.messages.contains(where: { $0.id == planID && $0.kind == .plan }) {
            recovered.pendingPlanMessageID = nil
        }
        if let firstUserMessage = recovered.messages.first(where: { $0.kind == .user }) {
            let titleText = firstUserMessage.text.isEmpty
                ? firstUserMessage.attachments.map { $0.name }.joined(separator: ", ")
                : firstUserMessage.text
            recovered.title = Self.title(for: titleText)
            recovered.blank = false
        } else if recovered.messages.isEmpty, recovered.title == "New chat" {
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

    /// Provider-only text for a turn. It is deliberately not an AgentMessage:
    /// storing it would make every later turn grow with repeated file notices
    /// and would destroy the reusable historical prefix.
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

    /// Adds the notice to a request copy only. Putting it on the latest user
    /// turn keeps it after the stable policy/history prefix and also avoids the
    /// `promptContextCaptured` folding step dropping an ephemeral message.
    static func requestMessages(
        _ messages: [AgentMessage],
        attachmentRevisionNotice: String?
    ) -> [AgentMessage] {
        guard let attachmentRevisionNotice,
              !attachmentRevisionNotice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let index = messages.lastIndex(where: { $0.role == .user }) else { return messages }
        var result = messages
        result[index].content = attachmentRevisionNotice + "\n\n" + result[index].content
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

    /// Runs the explore subagents of one assistant turn side by side, bounded by maxPerTurn.
    static func prefetchExplore(
        _ calls: [AgentToolCall],
        complete: @escaping ExploreTool.Complete,
        workspace: URL?
    ) async -> [String: ExploreTool.Outcome] {
        guard let workspace else { return [:] }
        let explores = calls.filter { $0.name == ExploreTool.name }
        guard !explores.isEmpty else { return [:] }
        let allowed = Array(explores.prefix(ExploreTool.maxPerTurn))
        let excess = Array(explores.dropFirst(ExploreTool.maxPerTurn))
        var outcomes: [String: ExploreTool.Outcome] = [:]
        for call in excess {
            outcomes[call.id] = ExploreTool.Outcome(
                answer: "Tool error: maximum of \(ExploreTool.maxPerTurn) explore subagents per turn exceeded. Run remaining investigations in subsequent turns.",
                readPaths: [], steps: 0, hitStepLimit: false, answered: false, searches: 0
            )
        }
        if allowed.count == 1, let single = allowed.first {
            outcomes[single.id] = await ExploreTool.run(single, complete: complete, workspace: workspace)
            return outcomes
        }
        let parallelResults = await withTaskGroup(of: (String, ExploreTool.Outcome).self) { group in
            for call in allowed {
                group.addTask(priority: .userInitiated) {
                    (call.id, await ExploreTool.run(call, complete: complete, workspace: workspace))
                }
            }
            var batch: [String: ExploreTool.Outcome] = [:]
            for await (id, outcome) in group { batch[id] = outcome }
            return batch
        }
        for (id, outcome) in parallelResults { outcomes[id] = outcome }
        return outcomes
    }

    /// Runs the read-only workspace calls of one assistant turn concurrently.
    /// Returns results by call id; anything not returned falls through to the
    /// normal sequential path.
    static func prefetchReadOnly(
        _ calls: [AgentToolCall],
        workspace: URL?,
        readRoots: [URL],
        contextRoots: [ChatContextRoot],
        planMode: Bool
    ) async -> [String: String] {
        guard workspace != nil || !contextRoots.isEmpty else { return [:] }
        let readOnly = calls.filter {
            WorkspaceTools.isReadOnly($0.name)
                && $0.name != WorkspaceTools.generatedMediaInspectionName
        }
        guard readOnly.count > 1 else { return [:] }
        _ = planMode // read-only calls are allowed in either mode
        return await withTaskGroup(of: (String, String).self) { group in
            for call in readOnly {
                group.addTask(priority: .userInitiated) {
                    if !contextRoots.isEmpty {
                        return (call.id, WorkspaceTools.execute(call, contextRoots: contextRoots))
                    }
                    guard let workspace else { return (call.id, "") }
                    return (call.id, WorkspaceTools.execute(call, workspace: workspace, readRoots: readRoots))
                }
            }
            var results: [String: String] = [:]
            for await (id, result) in group { results[id] = result }
            return results
        }
    }

    static func toolPreview(_ result: String) -> String {
        let limit = 700
        if result.count <= limit { return result }
        return String(result.prefix(limit)) + "…"
    }
}

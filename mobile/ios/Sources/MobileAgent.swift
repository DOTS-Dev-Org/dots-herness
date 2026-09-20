import CryptoKit
import Foundation

/// Provider-facing cache identity for the on-device agent.
///
/// The key deliberately describes the request shape, not the current user
/// message or any file path.  The conversation history is append-only, so the
/// provider can reuse the unchanged prefix while a new turn is added at the
/// end.  Compaction, a provider/route/model change, or a tool-schema change
/// starts a new segment instead of poisoning the previous one.
enum MobilePromptCache {
    static func key(
        conversationID: String?,
        provider: String,
        route: String,
        model: String,
        accountScope: String,
        toolFingerprint: String,
        contextSegment: Int
    ) -> String {
        let identity = [
            "mobile-v1",
            conversationID?.isEmpty == false ? conversationID! : "unbound",
            provider,
            route,
            model,
            accountScope,
            toolFingerprint,
            "context-\(contextSegment)",
        ].joined(separator: "\u{1f}")
        return "herness:mobile-v1:" + digest(Data(identity.utf8))
    }

    static func toolFingerprint(_ tools: [AgentToolSpec]) -> String {
        let wire = tools.sorted { $0.name < $1.name }.map(\.wire)
        let data = (try? JSONSerialization.data(withJSONObject: wire, options: [.sortedKeys])) ?? Data()
        return digest(data)
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// The agent loop that runs *on the phone*, with no desktop pairing requirement.
///
/// This deliberately does not reuse the desktop `NativeAgentClient`: that type
/// pulls in ConversationStore, MediaGeneration, and PluginCatalog, none of which
/// build for iOS. The phone needs one provider that works, not the desktop's
/// full router, so this speaks the Anthropic Messages API directly.
struct AgentToolSpec: Sendable {
    let name: String
    let description: String
    /// The JSON schema is kept serialized: a `[String: Any]` would make the spec
    /// non-Sendable, and it is only ever needed as JSON on the wire anyway.
    let schemaData: Data
    let run: @Sendable (AgentInput) async throws -> String

    init(name: String, description: String, schema: [String: Any], run: @escaping @Sendable (AgentInput) async throws -> String) {
        self.name = name
        self.description = description
        self.schemaData = (try? JSONSerialization.data(withJSONObject: schema)) ?? Data("{\"type\":\"object\"}".utf8)
        self.run = run
    }

    var wire: [String: Any] {
        let schema = (try? JSONSerialization.jsonObject(with: schemaData)) as? [String: Any] ?? ["type": "object"]
        return ["name": name, "description": description, "input_schema": schema]
    }
}

/// A tool call's arguments, carried as JSON so they can cross actor boundaries.
struct AgentInput: Sendable {
    let data: Data

    init(_ value: [String: Any]) { data = (try? JSONSerialization.data(withJSONObject: value)) ?? Data("{}".utf8) }

    private var object: [String: Any] { ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:] }

    func string(_ key: String) -> String? { object[key] as? String }
    func int(_ key: String) -> Int? { object[key] as? Int }
    func bool(_ key: String) -> Bool? { object[key] as? Bool }

    func required(_ key: String, tool: String) throws -> String {
        guard let value = string(key), !value.isEmpty else { throw AgentError.server("\(tool) needs a \(key).") }
        return value
    }
}

struct AgentTurn: Identifiable, Equatable {
    enum Role: String { case user, assistant, tool, error, system }
    let id = UUID()
    let role: Role
    var text: String
    var toolName: String?
}

struct MobileApprovalRequest: Equatable, Sendable {
    let id: String
    let toolName: String
}

struct MobileQuestionRequest: Equatable, Sendable {
    let id: String
    let question: String
}

@MainActor
final class MobileHarnessRuntime: ObservableObject {
    @Published private(set) var transcript: [AgentTurn] = []
    @Published private(set) var isRunning = false
    @Published var provider = UserDefaults.standard.string(forKey: "herness.agent.provider") ?? "anthropic"
    @Published var model = UserDefaults.standard.string(forKey: "herness.agent.model") ?? "claude-sonnet-4-5"
    @Published var errorMessage: String?
    @Published private(set) var runtimeState = "idle"
    @Published private(set) var events: [MobileRuntimeEvent]
    @Published var planMode = false
    @Published private(set) var approvalRequest: MobileApprovalRequest?
    @Published private(set) var questionRequest: MobileQuestionRequest?
    /// Prompt text contributed by loaded plugins, appended to the system prompt.
    @Published var pluginPrompt = ""

    /// Registered by the app at launch: file tools now, shell/SQL/MCP/plugin tools
    /// as those runtimes come up. Kept keyed so a re-registration replaces cleanly.
    private(set) var tools: [String: AgentToolSpec] = [:]
    private var wire: [[String: Any]] = []
    private var promptHistory = MobilePromptHistory()
    /// A compaction replaces the serialized prefix, so it starts a new cache
    /// segment. Provider/model/tool changes are included in the key below.
    private var contextSegment = 0
    private var orderedTools: [AgentToolSpec] { tools.values.sorted { $0.name < $1.name } }
    private var task: Task<Void, Never>?
    private let apiKey: () -> String
    private let oauthToken: () -> String
    private let sessionAccountID: () -> String
    private let systemPrompt: () -> String
    private let stateStore: MobileStateStore
    private var conversationID: String?
    private struct QueuedPrompt {
        let text: String
        let attachments: [MobileAttachment]
        let mode: String
        let planMode: Bool
    }
    private struct PendingTool {
        let id: String
        let name: String
        let input: AgentInput
    }
    private var queuedPrompts: [QueuedPrompt] = []
    private var pendingTool: PendingTool?
    private var pendingQuestion: PendingTool?
    private var activePlanMode = false
    private var workspaceSnapshotProvider: (() throws -> [WorkspaceFile])?
    private var activeBeforeFiles: [String: String]?
    private var activeRunID = UUID()
    private var activeTurnID = UUID().uuidString
    private var activeTrackingStatus = "not_applicable"
    private var activeVerifiedRemovals = 0
    private var activePreservedRemoval = false
    private var activeUnverifiedDeletion = false
    private var activeCleanupFailure = false
    private var activeTestStatus = "not_reported"
    private var gitClient: MobileGitClient?
    /// Latest known immutable revision for each logical attachment. Historical
    /// V1 blocks stay in `wire`; this map only selects the source revision for
    /// a provider-only notice or an explicit latest-content tool call.
    private var attachments: [String: MobileAttachment] = [:]
    private var pendingLatestAttachment: MobileAttachment?

    static let providers = ["anthropic", "openai", "openai-responses", "gpt"]
    static let models = ["claude-sonnet-4-5", "claude-opus-4-1", "claude-haiku-4-5", "gpt-4.1-mini", "gpt-4.1", "o4-mini", "gpt-5.6-luna", "gpt-5.6-terra"]
    static let maximumToolIterations = 24
    static let maximumToolResultCharacters = 20_000
    private static let maximumContextBytes = 200_000

    init(apiKey: @escaping () -> String, systemPrompt: @escaping () -> String, stateStore: MobileStateStore? = nil, oauthToken: @escaping () -> String = { "" }, sessionAccountID: @escaping () -> String = { "" }) {
        self.apiKey = apiKey
        self.systemPrompt = systemPrompt
        self.oauthToken = oauthToken
        self.sessionAccountID = sessionAccountID
        self.stateStore = stateStore ?? MobileStateStore()
        self.events = self.stateStore.recentEvents()
        let store = self.stateStore
        register(AgentTools.chats(store: store) { [weak self] in
            await MainActor.run { self?.conversationID }
        })
        register([
            AgentToolSpec(
                name: "get_latest_attachment",
                description: "Read the latest immutable source revision for an attachment after a revision notice. Call only when current bytes are needed.",
                schema: [
                    "type": "object",
                    "properties": [
                        "attachment_id": ["type": "string", "description": "The stable attachment_id from the revision notice."],
                    ],
                    "required": ["attachment_id"],
                    "additionalProperties": false,
                ]
            ) { [weak self] input in
                guard let self else { throw AgentError.server("The attachment runtime is unavailable.") }
                return await self.latestAttachmentResult(input)
            },
        ])
    }

    func register(_ specs: [AgentToolSpec]) {
        for spec in specs { tools[spec.name] = spec }
    }

    func setWorkspaceSnapshotProvider(_ provider: @escaping () throws -> [WorkspaceFile]) {
        workspaceSnapshotProvider = provider
    }

    func setGitClient(_ client: MobileGitClient?) {
        gitClient = client
    }

    func setModel(_ value: String) {
        model = value
        UserDefaults.standard.set(value, forKey: "herness.agent.model")
        stateStore.saveProvider(provider: provider, model: value, credentialReference: "keychain:phone.provider")
    }

    func setProvider(_ value: String) {
        let previous = provider
        provider = value
        UserDefaults.standard.set(value, forKey: "herness.agent.provider")
        if value == "anthropic" && !model.hasPrefix("claude") { setModel("claude-sonnet-4-5") }
        if value == "gpt" && !model.hasPrefix("gpt-") { setModel("gpt-5.6-luna") }
        if value != "anthropic" && value != "gpt" && model.hasPrefix("claude") { setModel("gpt-4.1-mini") }
        stateStore.saveProvider(provider: value, model: model, credentialReference: "keychain:phone.provider")
        guard previous != value else { return }
        emit("connection.changed", [
            "action": "selected",
            "previousConnectionLabel": Self.providerLabel(previous),
            "currentConnectionLabel": Self.providerLabel(value),
            "cleanupStatus": "preserved",
            "removedLocalArtifacts": "",
            "remoteDataTouched": "false",
            "userDataPreserved": "true",
        ])
    }

    func reset() {
        task?.cancel()
        task = nil
        stateStore.finishRun(conversationID: conversationID, status: "cancelled")
        wire = []
        attachments = [:]
        pendingLatestAttachment = nil
        promptHistory = MobilePromptHistory()
        contextSegment = 0
        queuedPrompts = []
        pendingTool = nil
        pendingQuestion = nil
        approvalRequest = nil
        questionRequest = nil
        transcript = []
        isRunning = false
        runtimeState = "idle"
        conversationID = nil
    }

    func cancel() {
        task?.cancel()
        task = nil
        queuedPrompts = []
        pendingTool = nil
        pendingQuestion = nil
        approvalRequest = nil
        questionRequest = nil
        isRunning = false
        runtimeState = "cancelled"
        stateStore.finishRun(conversationID: conversationID, status: "cancelled")
        emit("run.cancelled", ["reason": "user"])
    }

    func start() { runtimeState = "ready" }

    func send(
        _ text: String,
        attachments incomingAttachments: [MobileAttachment] = [],
        mode: String = "queue",
        planMode: Bool = false
    ) {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty || !incomingAttachments.isEmpty else { return }
        let stableAttachments = incomingAttachments.map { $0.stabilized(in: MobileAttachmentStore.snapshotDirectory) }
        for attachment in stableAttachments { attachments[attachment.id] = attachment }
        if isRunning {
            queuedPrompts.append(QueuedPrompt(text: prompt, attachments: stableAttachments, mode: mode, planMode: planMode))
            emit("prompt.queued", ["mode": mode, "planMode": planMode ? "true" : "false", "text": prompt])
            return
        }
        guard !(provider == "gpt" ? oauthToken() : apiKey()).isEmpty else {
            errorMessage = provider == "gpt" ? "Sign in with ChatGPT in Settings to run GPT on this phone." : "Add a provider API key in Settings to run the agent on this phone."
            return
        }
        beginRun(prompt: prompt, attachments: stableAttachments, mode: mode, planMode: planMode)
    }

    private func beginRun(prompt: String, attachments: [MobileAttachment] = [], mode: String, planMode: Bool) {
        activeRunID = UUID()
        activeTurnID = UUID().uuidString
        activePlanMode = planMode
        activeVerifiedRemovals = 0
        activePreservedRemoval = false
        activeUnverifiedDeletion = false
        activeCleanupFailure = false
        activeTestStatus = "not_reported"
        if let workspaceSnapshotProvider {
            do {
                activeBeforeFiles = Dictionary(uniqueKeysWithValues: try workspaceSnapshotProvider().map { ($0.path, $0.sha256) })
                activeTrackingStatus = "complete"
            } catch {
                activeBeforeFiles = nil
                activeTrackingStatus = "incomplete"
            }
        } else {
            activeBeforeFiles = nil
            activeTrackingStatus = "not_applicable"
        }
        if conversationID == nil {
            conversationID = stateStore.startRun(mode: mode, planMode: planMode, prompt: prompt)
        } else {
            stateStore.appendMessage(conversationID: conversationID, role: "user", content: prompt)
        }
        runtimeState = "running"
        emit("run.started", ["mode": mode, "planMode": planMode ? "true" : "false"])
        let attachmentLabel = attachments.map(\.displayName).joined(separator: ", ")
        transcript.append(AgentTurn(role: .user, text: [prompt, attachmentLabel.isEmpty ? "" : "[Attachments: \(attachmentLabel)]"].filter { !$0.isEmpty }.joined(separator: "\n")))
        emit("message.user", ["text": prompt, "attachments": String(attachments.count)])
        let captured = promptHistory.capture(
            prompt: prompt, policy: systemPrompt(), context: HerNessPrompt.pluginGuidance(pluginPrompt)
        )
        wire.append(canonicalUserMessage(text: captured, attachments: attachments))
        persistModelContext()
        isRunning = true
        task = Task { await run() }
    }

    func continueRun() {
        guard !isRunning, pendingTool == nil, pendingQuestion == nil else { return }
        guard conversationID != nil else { return }
        isRunning = true
        runtimeState = "running"
        emit("run.continued", [:])
        task = Task { await run() }
    }

    func `continue`() { continueRun() }

    func answerApproval(_ approvalID: String, accepted: Bool) {
        guard let pending = pendingTool, pending.id == approvalID else { return }
        pendingTool = nil
        approvalRequest = nil
        let answer = accepted ? "allowed-once" : "rejected"
        stateStore.resolvePendingAction(id: approvalID, status: accepted ? "approved" : "rejected")
        emit("approval.answered", ["approvalId": approvalID, "answer": answer])
        if pending.name == "run_command", Self.isTestCommand(pending.input.string("command")) { activeTestStatus = "requested" }
        if pending.name == "run_command", Self.mayDeleteFiles(pending.input.string("command")) { activeUnverifiedDeletion = true }
        Task {
            let output: (text: String, failed: Bool) = accepted
                ? await invoke(name: pending.name, input: pending.input)
                : ("Tool rejected by the user.", true)
            appendToolResult(id: pending.id, name: pending.name, output: output)
            continueRun()
        }
    }

    func answerQuestion(_ questionID: String, answers: [String]) {
        guard let pending = pendingQuestion, pending.id == questionID else { return }
        pendingQuestion = nil
        questionRequest = nil
        stateStore.resolvePendingAction(id: questionID, status: "answered")
        emit("question.answered", ["questionId": questionID, "answers": answers.joined(separator: "\n")])
        let answer = answers.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        appendToolResult(id: pending.id, name: pending.name, output: (answer.isEmpty ? "No answer was provided." : answer, answer.isEmpty))
        continueRun()
    }

    func selectRepository(_ repository: RepoCoordinates) {
        repository.save()
        stateStore.saveRepository(repository)
        stateStore.saveSetting(key: "repository", value: repository.slug)
        stateStore.saveSetting(key: "repository.branch", value: repository.branch)
        emit("repository.selected", ["repository": repository.slug, "branch": repository.branch])
    }

    func refreshWorkspace() {
        emit("workspace.refreshed", ["source": "local"])
    }

    func executeGit(_ operation: String) async -> String {
        guard let gitClient else {
            let message = "unsupported_on_mobile: \(operation) requires the native MobileGitClient backend."
            emit("git.unsupported", ["operation": operation, "reason": message])
            return message
        }
        let result = await gitClient.execute(operation: operation)
        if result.unavailable { emit("git.unsupported", ["operation": operation, "reason": result.output]) }
        return result.output
    }

    private func run() async {
        defer {
            persistModelContext()
            isRunning = false
            if !runtimeState.hasPrefix("waiting_") {
            if runtimeState == "running" { runtimeState = "completed" }
            let finalStatus = runtimeState
            stateStore.finishRun(conversationID: conversationID, status: finalStatus)
            let diff = finishWorkspaceTracking()
            let cleanupStatus = cleanupStatus(trackingStatus: diff.trackingStatus)
            let summary = "Files: +\(diff.added.count) added, \(diff.modified.count) changed, \(diff.deleted.count) removed. " + cleanupNote(status: cleanupStatus, trackingStatus: diff.trackingStatus)
            transcript.append(AgentTurn(role: .system, text: summary))
            stateStore.appendMessage(conversationID: conversationID, role: "system", content: summary)
            for path in diff.added + diff.modified { emit("file.changed", ["runId": activeRunID.uuidString, "turnId": activeTurnID, "path": path, "operation": diff.added.contains(path) ? "added" : "modified"]) }
            for path in diff.deleted { emit("file.deleted", ["runId": activeRunID.uuidString, "turnId": activeTurnID, "path": path, "operation": "deleted"]) }
            emit("run.summary", [
                "runId": activeRunID.uuidString,
                "turnId": activeTurnID,
                "status": finalStatus,
                "trackingStatus": diff.trackingStatus,
                "cleanupStatus": cleanupStatus,
                "cleanupNote": cleanupNote(status: cleanupStatus, trackingStatus: diff.trackingStatus),
                "addedCount": String(diff.added.count),
                "modifiedCount": String(diff.modified.count),
                "deletedCount": String(diff.deleted.count),
                "testStatus": activeTestStatus,
            ])
            if finalStatus == "completed" { emit("run.completed", [:]) }
            if runtimeState == "completed", !queuedPrompts.isEmpty {
                let next = queuedPrompts.removeFirst()
                Task { @MainActor in
                    self.beginRun(prompt: next.text, attachments: next.attachments, mode: next.mode, planMode: next.planMode)
                }
            }
            }
        }
        do {
            for _ in 0..<Self.maximumToolIterations {
                if Task.isCancelled { return }
                let response = try await complete()
                let blocks = response["content"] as? [[String: Any]] ?? []
                wire.append(["role": "assistant", "content": blocks])

                let said = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
                if !said.isEmpty {
                    transcript.append(AgentTurn(role: .assistant, text: said))
                    stateStore.appendMessage(conversationID: conversationID, role: "assistant", content: said)
                    emit("message.assistant", ["text": said])
                }

                let calls = blocks.filter { $0["type"] as? String == "tool_use" }
                if calls.isEmpty { return }

                var results: [[String: Any]] = []
                for call in calls {
                    guard let id = call["id"] as? String, let name = call["name"] as? String else { continue }
                    emit("tool.started", ["name": name, "callId": id])
                    let input = AgentInput(call["input"] as? [String: Any] ?? [:])
                    if activePlanMode && blockedInPlanMode(name) {
                        let output = (text: "blocked_in_plan_mode: \(name) is read-only in plan mode.", failed: true)
                        results.append(recordToolResult(id: id, name: name, output: output))
                        continue
                    }
                    if name == "run_command", Self.isTestCommand(input.string("command")) { activeTestStatus = "requested" }
                    if name == "ask_user" {
                        if !results.isEmpty { wire.append(["role": "user", "content": results]) }
                        pendingQuestion = PendingTool(id: id, name: name, input: input)
                        questionRequest = MobileQuestionRequest(id: id, question: input.string("question") ?? input.string("questions") ?? "The agent needs more information.")
                        stateStore.savePendingAction(id: id, conversationID: conversationID, kind: "question", payload: ["toolName": name], status: "waiting")
                        runtimeState = "waiting_question"
                        isRunning = false
                        emit("question.required", ["questionId": id, "questions": questionRequest?.question ?? ""])
                        return
                    }
                    if requiresApproval(name) {
                        if !results.isEmpty { wire.append(["role": "user", "content": results]) }
                        pendingTool = PendingTool(id: id, name: name, input: input)
                        approvalRequest = MobileApprovalRequest(id: id, toolName: name)
                        stateStore.savePendingAction(id: id, conversationID: conversationID, kind: "approval", payload: ["toolName": name], status: "waiting")
                        runtimeState = "waiting_approval"
                        isRunning = false
                        emit("approval.required", ["approvalId": id, "toolName": name])
                        return
                    }
                    if name == "run_command", AgentTools.mayDeleteFiles(input.string("command")) { activeUnverifiedDeletion = true }
                    let output = await invoke(name: name, input: input)
                    results.append(recordToolResult(id: id, name: name, output: output))
                }
                wire.append(["role": "user", "content": results])
            }
            transcript.append(AgentTurn(role: .error, text: "Stopped after \(Self.maximumToolIterations) tool steps."))
            runtimeState = "failed"
            stateStore.finishRun(conversationID: conversationID, status: "failed")
            emit("run.failed", ["reason": "maximum_tool_steps"])
        } catch is CancellationError {
            runtimeState = "cancelled"
            stateStore.finishRun(conversationID: conversationID, status: "cancelled")
        } catch {
            transcript.append(AgentTurn(role: .error, text: error.localizedDescription))
            errorMessage = error.localizedDescription
            runtimeState = "failed"
            stateStore.finishRun(conversationID: conversationID, status: "failed")
            emit("run.failed", ["reason": error.localizedDescription])
        }
    }

    private func appendToolResult(id: String, name: String, output: (text: String, failed: Bool)) {
        wire.append(["role": "user", "content": [recordToolResult(id: id, name: name, output: output)]])
    }

    private func recordToolResult(id: String, name: String, output: (text: String, failed: Bool)) -> [String: Any] {
        recordCleanup(name: name, output: output.text, failed: output.failed)
        if name == "run_command", activeTestStatus == "requested" { activeTestStatus = output.failed ? "failed" : "passed" }
        transcript.append(AgentTurn(role: .tool, text: output.text, toolName: name))
        stateStore.appendMessage(conversationID: conversationID, role: "tool", content: output.text, toolName: name)
        emit("tool.finished", ["name": name, "callId": id, "isError": output.failed ? "true" : "false"])
        var result: [String: Any] = [
            "type": "tool_result",
            "tool_use_id": id,
            "content": String(output.text.prefix(Self.maximumToolResultCharacters)),
            "is_error": output.failed,
        ]
        if let latest = pendingLatestAttachment {
            result["attachment"] = latest.canonicalBlock()
            pendingLatestAttachment = nil
        }
        return result
    }

    private func canonicalUserMessage(text: String, attachments: [MobileAttachment]) -> [String: Any] {
        var content: [[String: Any]] = [["type": "text", "text": text]]
        content.append(contentsOf: attachments.map(\.canonicalBlock))
        return ["role": "user", "content": content]
    }

    private func latestAttachmentResult(_ input: AgentInput) async -> String {
        guard let id = input.string("attachment_id"), let current = attachments[id] else {
            return "attachment_not_found\nhistorical_revision_preserved\nlatest_revision_unavailable"
        }
        let observation = current.observeSource()
        switch observation.status {
        case .missing:
            return "source_missing\nhistorical_revision_preserved\nlatest_revision_unavailable\nattachment_id: \(id)"
        case .unreadable:
            return "source_unreadable\nhistorical_revision_preserved\nlatest_revision_unavailable\nattachment_id: \(id)"
        case .current:
            if current.snapshotPath != nil, current.contentHash == observation.currentHash {
                pendingLatestAttachment = current
                return "latest_revision_current\nattachment_id: \(id)\nrevision: V\(max(current.revision, 1))\ncontent_hash: \(current.contentHash ?? "")"
            }
        case .changed:
            break
        }
        let latest = current.refreshed(in: MobileAttachmentStore.snapshotDirectory)
        guard latest.snapshotPath != nil,
              latest.contentHash != nil,
              latest.contentHash == observation.currentHash,
              latest.providerData() != nil else {
            return "source_unreadable\nhistorical_revision_preserved\nlatest_revision_unavailable\nattachment_id: \(id)"
        }
        attachments[id] = latest
        pendingLatestAttachment = latest
        return "latest_revision_created\nattachment_id: \(id)\nrevision: V\(latest.revision)\ncontent_hash: \(latest.contentHash!)"
    }

    private func attachmentRevisionNotice() -> String? {
        let notices = attachments.values.sorted { $0.id < $1.id }.compactMap { attachment -> String? in
            let observation = attachment.observeSource()
            let status: String
            switch observation.status {
            case .current: return nil
            case .changed: status = "changed"
            case .missing: status = "missing"
            case .unreadable: status = "unreadable"
            }
            let detail: String = switch observation.status {
            case .missing: "source_missing\nhistorical_revision_preserved\nlatest_revision_unavailable"
            case .unreadable: "source_unreadable\nhistorical_revision_preserved\nlatest_revision_unavailable"
            default: "The source file changed. The historical V1 bytes remain immutable and must not be treated as current."
            }
            return """
            [Attachment revision notice]
            attachment_id: \(attachment.id)
            name: \(attachment.displayName)
            revision: V\(max(attachment.revision, 1) + 1)
            status: \(status)
            \(detail)
            If current content is needed, call get_latest_attachment with {"attachment_id":"\(attachment.id)"}. Do not infer missing or unreadable bytes.
            """
        }
        return notices.isEmpty ? nil : notices.joined(separator: "\n\n")
    }

    /// Builds an ephemeral request copy. The canonical wire transcript and the
    /// persisted model context never receive this revision text.
    private func wireForRequest() -> [[String: Any]] {
        var result = wire
        guard let notice = attachmentRevisionNotice(),
              let index = result.lastIndex(where: { message in
                  guard let content = message["content"] as? [[String: Any]] else { return false }
                  return message["role"] as? String == "user"
                      && content.contains { ($0["type"] as? String) != "tool_result" }
              }),
              var content = result[index]["content"] as? [[String: Any]] else { return result }
        content.insert(["type": "text", "text": notice], at: 0)
        result[index]["content"] = content
        return result
    }

    private func markDelivered() {
        for (id, attachment) in attachments {
            guard let hash = attachment.contentHash,
                  attachment.snapshotPath != nil,
                  attachment.deliveredHash != hash else { continue }
            attachments[id] = MobileAttachment(
                attachmentID: attachment.attachmentID,
                displayName: attachment.displayName,
                kind: attachment.kind,
                mimeType: attachment.mimeType,
                sourceLocator: attachment.sourceLocator,
                bookmarkData: attachment.bookmarkData,
                snapshotPath: attachment.snapshotPath,
                contentHash: attachment.contentHash,
                revision: attachment.revision,
                deliveredHash: hash,
                sourceStatus: .current
            )
        }
        for index in wire.indices {
            guard var content = wire[index]["content"] as? [[String: Any]] else { continue }
            for blockIndex in content.indices {
                if let id = content[blockIndex]["attachment_id"] as? String,
                   let hash = attachments[id]?.deliveredHash {
                    content[blockIndex]["delivered_hash"] = hash
                }
                if var toolAttachment = content[blockIndex]["attachment"] as? [String: Any],
                   let id = toolAttachment["attachment_id"] as? String,
                   let hash = attachments[id]?.deliveredHash {
                    toolAttachment["delivered_hash"] = hash
                    content[blockIndex]["attachment"] = toolAttachment
                }
            }
            wire[index]["content"] = content
        }
    }

    private func blockedInPlanMode(_ name: String) -> Bool {
        name == "write_file" || name == "remove_file" || name == "run_command" || name == "sql" || name.hasPrefix("git")
    }

    private func requiresApproval(_ name: String) -> Bool {
        name == "write_file" || name == "remove_file" || name == "run_command" || name == "sql" || name.hasPrefix("git")
    }

    private struct WorkspaceDiff {
        let added: [String]
        let modified: [String]
        let deleted: [String]
        let trackingStatus: String
    }

    private func finishWorkspaceTracking() -> WorkspaceDiff {
        guard workspaceSnapshotProvider != nil else { return WorkspaceDiff(added: [], modified: [], deleted: [], trackingStatus: "not_applicable") }
        guard let before = activeBeforeFiles else { return WorkspaceDiff(added: [], modified: [], deleted: [], trackingStatus: "incomplete") }
        do {
            let after = Dictionary(uniqueKeysWithValues: try workspaceSnapshotProvider!().map { ($0.path, $0.sha256) })
            let added = after.keys.filter { before[$0] == nil }.sorted()
            let deleted = before.keys.filter { after[$0] == nil }.sorted()
            let modified = after.keys.filter { before[$0] != nil && before[$0] != after[$0] }.sorted()
            return WorkspaceDiff(added: added, modified: modified, deleted: deleted, trackingStatus: "complete")
        } catch {
            return WorkspaceDiff(added: [], modified: [], deleted: [], trackingStatus: "incomplete")
        }
    }

    private func recordCleanup(name: String, output: String, failed: Bool) {
        guard name == "remove_file" else { return }
        if failed { activeCleanupFailure = true }
        if output.contains(AgentTools.verifiedMarker) { activeVerifiedRemovals += 1 }
        if output.contains(AgentTools.preservedMarker) { activePreservedRemoval = true }
        if output.contains(AgentTools.failedMarker) { activeCleanupFailure = true }
    }

    private func cleanupStatus(trackingStatus: String? = nil) -> String {
        if activePlanMode { return "not_applicable" }
        if activeCleanupFailure { return "failed" }
        if activeUnverifiedDeletion { return "not_verified" }
        if trackingStatus == "incomplete" { return "not_verified" }
        if activeVerifiedRemovals > 0 { return "verified" }
        if activePreservedRemoval { return "preserved" }
        return "not_applicable"
    }

    private func cleanupNote(status: String, trackingStatus: String) -> String {
        if trackingStatus == "incomplete" { return "Workspace changes could not be fully verified; uncertain artifacts were kept." }
        switch status {
        case "verified": return "Proven-unused cleanup was verified."
        case "preserved": return "An old artifact was preserved because cleanup could not be proven safe."
        case "not_verified": return "A deletion command was detected outside the safe removal flow; cleanup was not verified."
        case "failed": return "Cleanup did not finish; the result needs review."
        default: return "No cleanup was requested."
        }
    }

    private static func providerLabel(_ value: String) -> String {
        switch value {
        case "anthropic": return "Anthropic"
        case "openai": return "OpenAI"
        case "openai-responses": return "OpenAI Responses"
        case "gpt": return "ChatGPT"
        default: return "Provider"
        }
    }

    private static func isTestCommand(_ command: String?) -> Bool {
        guard let command else { return false }
        return command.range(of: "(?i)(^|[\\s;&|])(dotnet\\s+test|npm\\s+(run\\s+)?test|pnpm\\s+(run\\s+)?test|yarn\\s+test|pytest|swift\\s+test|gradle(w)?\\s+.*test|cargo\\s+test)([\\s;&|]|$)", options: .regularExpression) != nil
    }

    private static func mayDeleteFiles(_ command: String?) -> Bool {
        guard let command else { return false }
        return command.range(of: #"(?i)(^|[\s;&|])(rm|unlink|rmdir|del|erase|Remove-Item|git\s+clean)([\s]|$)"#, options: .regularExpression) != nil
    }

    private func invoke(name: String, input: AgentInput) async -> (text: String, failed: Bool) {
        guard let tool = tools[name] else { return ("No tool named \(name) is available on this phone.", true) }
        do { return (try await tool.run(input), false) }
        catch { return (error.localizedDescription, true) }
    }

    private func complete() async throws -> [String: Any] {
        compactContextIfNeeded()
        emit("provider.request", ["provider": provider, "model": model])
        let response: [String: Any]
        switch provider {
        case "anthropic": response = try await completeAnthropic()
        case "openai-responses": response = try await completeOpenAIResponses()
        case "gpt": response = try await completeChatGPT()
        default: response = try await completeOpenAI()
        }
        // A payload is considered delivered only after the provider accepted
        // the request. Failed/retried requests therefore cannot advance the
        // attachment revision baseline.
        markDelivered()
        return response
    }

    private func promptCacheKey(route: String) -> String {
        let account = sessionAccountID().trimmingCharacters(in: .whitespacesAndNewlines)
        return MobilePromptCache.key(
            conversationID: conversationID,
            provider: provider,
            route: route,
            model: model,
            accountScope: account.isEmpty ? provider : account,
            toolFingerprint: MobilePromptCache.toolFingerprint(orderedTools),
            contextSegment: contextSegment
        )
    }

    /// Anthropic caches the prefix ending at explicit `cache_control`
    /// breakpoints.  This mutates a request copy only; the durable transcript
    /// never acquires provider metadata, which keeps later turns byte-stable.
    private func applyAnthropicCacheBreakpoints(to body: inout [String: Any]) {
        let ephemeral: [String: Any] = ["type": "ephemeral"]

        if let text = body["system"] as? String, !text.isEmpty {
            body["system"] = [["type": "text", "text": text, "cache_control": ephemeral]]
        } else if var blocks = body["system"] as? [[String: Any]], !blocks.isEmpty {
            blocks[blocks.count - 1]["cache_control"] = ephemeral
            body["system"] = blocks
        }

        if var tools = body["tools"] as? [[String: Any]], !tools.isEmpty {
            tools[tools.count - 1]["cache_control"] = ephemeral
            body["tools"] = tools
        }

        if var messages = body["messages"] as? [[String: Any]], !messages.isEmpty {
            let lastIndex = messages.count - 1
            var message = messages[lastIndex]
            if let text = message["content"] as? String, !text.isEmpty {
                message["content"] = [["type": "text", "text": text, "cache_control": ephemeral]]
            } else if var blocks = message["content"] as? [[String: Any]], !blocks.isEmpty {
                blocks[blocks.count - 1]["cache_control"] = ephemeral
                message["content"] = blocks
            }
            messages[lastIndex] = message
            body["messages"] = messages
        }
    }

    private func attachmentBlock(_ block: [String: Any], format: String) -> [String: Any] {
        let id = block["attachment_id"] as? String ?? "unknown"
        guard let attachment = attachments[id], let data = attachment.providerData() else {
            return [
                "type": format == "responses" ? "input_text" : "text",
                "text": "source_missing: attachment_id (id); historical_revision_preserved; latest_revision_unavailable",
            ]
        }
        let base64 = data.base64EncodedString()
        let isDocument = attachment.kind == .file
            && (attachment.mimeType == "application/pdf" || attachment.mimeType.hasPrefix("text/") || attachment.mimeType == "application/json")
        switch format {
        case "anthropic":
            if attachment.kind == .image {
                return [
                    "type": "image",
                    "source": ["type": "base64", "media_type": attachment.mimeType, "data": base64],
                ]
            }
            if isDocument && attachment.mimeType == "application/pdf" {
                return [
                    "type": "document",
                    "source": ["type": "base64", "media_type": attachment.mimeType, "data": base64],
                ]
            }
        case "responses":
            if attachment.kind == .image {
                return ["type": "input_image", "image_url": "data:\(attachment.mimeType);base64,\(base64)"]
            }
            if isDocument {
                return ["type": "input_file", "filename": attachment.displayName, "file_data": "data:\(attachment.mimeType);base64,\(base64)"]
            }
        default:
            if attachment.kind == .image {
                return ["type": "image_url", "image_url": ["url": "data:\(attachment.mimeType);base64,\(base64)"]]
            }
            if isDocument {
                return ["type": "file", "file": ["filename": attachment.displayName, "file_data": "data:\(attachment.mimeType);base64,\(base64)"]]
            }
        }
        let wireType = format == "responses" ? "input_text" : "text"
        return [
            "type": wireType,
            "text": "unsupported_attachment_kind: \(attachment.kind.rawValue); attachment_id: \(attachment.id); name: \(attachment.displayName). The host did not silently drop this attachment, but this provider route does not support its wire format.",
        ]
    }

    private func anthropicMessages() -> [[String: Any]] {
        let source = wireForRequest()
        return source.compactMap { message in
            guard let role = message["role"] as? String else { return nil }
            let content = message["content"] as? [[String: Any]] ?? []
            if role == "assistant" {
                let blocks = content.compactMap { block -> [String: Any]? in
                    switch block["type"] as? String {
                    case "text": return block
                    case "tool_use": return block
                    default: return nil
                    }
                }
                return ["role": "assistant", "content": blocks]
            }
            let toolResults = content.filter { $0["type"] as? String == "tool_result" }
            if !toolResults.isEmpty {
                var blocks: [[String: Any]] = []
                for item in toolResults {
                    var result: [String: Any] = [
                        "type": "tool_result",
                        "tool_use_id": item["tool_use_id"] as? String ?? "tool",
                        "content": item["content"] as? String ?? "",
                    ]
                    if let attachment = item["attachment"] as? [String: Any] {
                        var nested: [[String: Any]] = [["type": "text", "text": item["content"] as? String ?? ""]]
                        nested.append(attachmentBlock(attachment, format: "anthropic"))
                        result["content"] = nested
                    }
                    blocks.append(result)
                }
                return ["role": "user", "content": blocks]
            }
            var blocks: [[String: Any]] = []
            for block in content {
                if block["type"] as? String == "attachment" { blocks.append(attachmentBlock(block, format: "anthropic")) }
                else if block["type"] as? String == "text" { blocks.append(block) }
            }
            return ["role": "user", "content": blocks]
        }
    }

    private func completeAnthropic() async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue(apiKey(), forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = [
            "model": model,
            "max_tokens": 8_192,
            "system": promptHistory.policy ?? "",
            "messages": anthropicMessages(),
        ]
        if !tools.isEmpty { body["tools"] = orderedTools.map(\.wire) }
        applyAnthropicCacheBreakpoints(to: &body)
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 300

        let (data, http) = try await requestData(request)
        guard (200..<300).contains(http.statusCode) else { throw AgentError.server(providerError(data, status: http.statusCode)) }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AgentError.server("The provider returned an unexpected response.")
        }
        emit("provider.response", ["provider": "anthropic", "status": String(http.statusCode), "usage": usage(from: object)])
        return object
    }

    private func completeOpenAI() async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey())", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let definitions: [[String: Any]] = orderedTools.map {
            [
                "type": "function",
                "function": [
                    "name": $0.name,
                    "description": $0.description,
                    "parameters": (try? JSONSerialization.jsonObject(with: $0.schemaData)) ?? ["type": "object"],
                ],
            ]
        }
        var body: [String: Any] = [
            "model": model,
            "max_completion_tokens": 8_192,
            "messages": openAIMessages(),
            "prompt_cache_key": promptCacheKey(route: "openai-chat"),
        ]
        if !definitions.isEmpty { body["tools"] = definitions }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 300

        let (data, http) = try await requestData(request)
        guard (200..<300).contains(http.statusCode) else { throw AgentError.server(providerError(data, status: http.statusCode)) }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = (root["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any] else {
            throw AgentError.server("The provider returned an unexpected response.")
        }
        var blocks: [[String: Any]] = []
        if let text = message["content"] as? String, !text.isEmpty { blocks.append(["type": "text", "text": text]) }
        for call in (message["tool_calls"] as? [[String: Any]]) ?? [] {
            guard let function = call["function"] as? [String: Any],
                  let name = function["name"] as? String else { continue }
            let arguments = Data((function["arguments"] as? String ?? "{}").utf8)
            blocks.append([
                "type": "tool_use",
                "id": call["id"] as? String ?? UUID().uuidString,
                "name": name,
                "input": (try? JSONSerialization.jsonObject(with: arguments)) as? [String: Any] ?? [:],
            ])
        }
        emit("provider.response", ["provider": provider, "status": String(http.statusCode), "usage": usage(from: root)])
        return ["content": blocks]
    }

    private func completeOpenAIResponses() async throws -> [String: Any] {
        try await completeResponses(endpoint: "https://api.openai.com/v1/responses", token: apiKey(), headers: [:], providerName: "openai-responses")
    }

    private func completeChatGPT() async throws -> [String: Any] {
        let account = sessionAccountID()
        guard !account.isEmpty else { throw AgentError.server("The ChatGPT session account is unavailable. Sign in again in Settings.") }
        return try await completeResponses(
            endpoint: "https://chatgpt.com/backend-api/codex/responses",
            token: oauthToken(),
            headers: [
                "ChatGPT-Account-ID": account,
                "OAI-Product-Sku": "codex",
                "OpenAI-Beta": "responses=v1",
                "originator": "dots_harness",
                "session_id": UUID().uuidString,
            ],
            providerName: "gpt"
        )
    }

    private func completeResponses(endpoint: String, token: String, headers: [String: String], providerName: String) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: endpoint)!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        var body: [String: Any] = [
            "model": model,
            "instructions": promptHistory.policy ?? "",
            "input": responsesInput(),
            "store": false,
            "stream": false,
            "prompt_cache_key": promptCacheKey(route: providerName == "gpt" ? "chatgpt-responses" : "openai-responses"),
        ]
        if !tools.isEmpty {
            body["tools"] = orderedTools.map { ["type": "function", "name": $0.name, "description": $0.description, "parameters": (try? JSONSerialization.jsonObject(with: $0.schemaData)) ?? ["type": "object"]] }
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 300
        let (data, http) = try await requestData(request)
        guard (200..<300).contains(http.statusCode) else { throw AgentError.server(providerError(data, status: http.statusCode)) }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any], let output = root["output"] as? [[String: Any]] else {
            throw AgentError.server("The provider returned an unexpected Responses payload.")
        }
        var blocks: [[String: Any]] = []
        for item in output {
            if item["type"] as? String == "message" {
                for part in item["content"] as? [[String: Any]] ?? [] {
                    if let text = part["text"] as? String, !text.isEmpty { blocks.append(["type": "text", "text": text]) }
                }
            } else if item["type"] as? String == "function_call", let name = item["name"] as? String {
                let arguments = Data((item["arguments"] as? String ?? "{}").utf8)
                blocks.append(["type": "tool_use", "id": item["call_id"] as? String ?? item["id"] as? String ?? UUID().uuidString, "name": name, "input": (try? JSONSerialization.jsonObject(with: arguments)) as? [String: Any] ?? [:]])
            }
        }
        emit("provider.response", ["provider": providerName, "status": String(http.statusCode), "usage": usage(from: root)])
        return ["content": blocks]
    }

    private func responsesInput() -> [[String: Any]] {
        var result: [[String: Any]] = []
        for message in wireForRequest() {
            guard let role = message["role"] as? String else { continue }
            let content = message["content"] as? [[String: Any]] ?? []
            if role == "user" {
                let results = content.filter { $0["type"] as? String == "tool_result" }
                if results.isEmpty {
                    let blocks = content.map { block -> [String: Any] in
                        if block["type"] as? String == "attachment" { return attachmentBlock(block, format: "responses") }
                        return ["type": "input_text", "text": block["text"] as? String ?? ""]
                    }
                    result.append(["role": "user", "content": blocks])
                } else {
                    for item in results {
                        result.append(["type": "function_call_output", "call_id": item["tool_use_id"] as? String ?? "tool", "output": item["content"] as? String ?? ""])
                        if let attachment = item["attachment"] as? [String: Any] {
                            result.append(["role": "user", "content": [attachmentBlock(attachment, format: "responses")]])
                        }
                    }
                }
            } else if role == "assistant" {
                let text = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
                if !text.isEmpty { result.append(["role": "assistant", "content": [["type": "output_text", "text": text]]]) }
                for item in content where item["type"] as? String == "tool_use" {
                    let arguments = (item["input"] as? [String: Any]).flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) }.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                    result.append(["type": "function_call", "call_id": item["id"] as? String ?? UUID().uuidString, "name": item["name"] as? String ?? "", "arguments": arguments])
                }
            }
        }
        return result
    }

    private func requestData(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var lastStatus = 0
        for attempt in 0..<3 {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw AgentError.server("The provider returned no response.") }
            lastStatus = http.statusCode
            if http.statusCode != 429 && http.statusCode < 500 { return (data, http) }
            if attempt < 2 { try await Task.sleep(for: .seconds(Double(attempt + 1))) } else { return (data, http) }
        }
        throw AgentError.server("The provider request failed (HTTP \(lastStatus)).")
    }

    private func openAIMessages() -> [[String: Any]] {
        var result: [[String: Any]] = [["role": "system", "content": promptHistory.policy ?? ""]]
        for message in wireForRequest() {
            guard let role = message["role"] as? String else { continue }
            let content = message["content"] as? [[String: Any]] ?? []
            if role == "assistant" {
                let text = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
                var item: [String: Any] = ["role": "assistant", "content": text.isEmpty ? NSNull() : text]
                let calls: [[String: Any]] = content.compactMap { block in
                    guard block["type"] as? String == "tool_use", let name = block["name"] as? String else { return nil }
                    let input = (block["input"] as? [String: Any]).flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) }.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                    return ["id": block["id"] as? String ?? UUID().uuidString, "type": "function", "function": ["name": name, "arguments": input]]
                }
                if !calls.isEmpty { item["tool_calls"] = calls }
                result.append(item)
            } else if role == "user" {
                let toolResults = content.filter { $0["type"] as? String == "tool_result" }
                if toolResults.isEmpty {
                    let blocks = content.map { block -> [String: Any] in
                        if block["type"] as? String == "attachment" { return attachmentBlock(block, format: "openai") }
                        return ["type": "text", "text": block["text"] as? String ?? ""]
                    }
                    result.append(["role": "user", "content": blocks])
                } else {
                    for block in toolResults {
                        result.append(["role": "tool", "tool_call_id": block["tool_use_id"] as? String ?? "", "content": block["content"] as? String ?? ""])
                        if let attachment = block["attachment"] as? [String: Any] {
                            result.append(["role": "user", "content": [attachmentBlock(attachment, format: "openai")]])
                        }
                    }
                }
            }
        }
        return result
    }

    private func providerError(_ data: Data, status: Int) -> String {
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let message = ((object?["error"] as? [String: Any])?["message"] as? String)
            ?? String(data: data, encoding: .utf8)
            ?? "The provider request failed."
        return "\(status): \(message)"
    }

    private func usage(from object: [String: Any]) -> String {
        guard let usage = object["usage"] as? [String: Any] else { return "" }
        return usage.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ",")
    }

    private func compactContextIfNeeded() {
        guard let data = try? JSONSerialization.data(withJSONObject: wire),
              data.count > Self.maximumContextBytes,
              let first = wire.first else { return }
        wire = [first] + Array(wire.dropFirst().suffix(12))
        contextSegment += 1
        guard let compacted = try? JSONSerialization.data(withJSONObject: wire) else { return }
        persistModelContext()
        emit("context.compacted", ["bytes": String(data.count), "keptBytes": String(compacted.count)])
    }

    private func persistModelContext() {
        let snapshot: [String: Any] = ["version": 1, "policy": promptHistory.policy ?? "", "messages": wire]
        guard let data = try? JSONSerialization.data(withJSONObject: snapshot, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return }
        stateStore.saveModelContext(conversationID: conversationID, content: text)
    }

    private func emit(_ kind: String, _ payload: [String: String]) {
        let event = stateStore.appendEvent(conversationID: conversationID, kind: kind, payload: payload)
        events.append(event)
        if events.count > 500 { events.removeFirst(events.count - 500) }
    }
}

enum AgentError: LocalizedError {
    case server(String)
    var errorDescription: String? { switch self { case .server(let message): return message } }
}

typealias MobileAgent = MobileHarnessRuntime

import CryptoKit
import Foundation

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

    func send(_ text: String, mode: String = "queue", planMode: Bool = false) {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        if isRunning {
            queuedPrompts.append(QueuedPrompt(text: prompt, mode: mode, planMode: planMode))
            emit("prompt.queued", ["mode": mode, "planMode": planMode ? "true" : "false", "text": prompt])
            return
        }
        guard !(provider == "gpt" ? oauthToken() : apiKey()).isEmpty else {
            errorMessage = provider == "gpt" ? "Sign in with ChatGPT in Settings to run GPT on this phone." : "Add a provider API key in Settings to run the agent on this phone."
            return
        }
        beginRun(prompt: prompt, mode: mode, planMode: planMode)
    }

    private func beginRun(prompt: String, mode: String, planMode: Bool) {
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
        transcript.append(AgentTurn(role: .user, text: prompt))
        emit("message.user", ["text": prompt])
        let captured = promptHistory.capture(
            prompt: prompt, policy: systemPrompt(), context: HerNessPrompt.pluginGuidance(pluginPrompt)
        )
        wire.append(["role": "user", "content": [["type": "text", "text": captured]]])
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
                    self.beginRun(prompt: next.text, mode: next.mode, planMode: next.planMode)
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
        return [
            "type": "tool_result",
            "tool_use_id": id,
            "content": String(output.text.prefix(Self.maximumToolResultCharacters)),
            "is_error": output.failed,
        ]
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
        switch provider {
        case "anthropic": return try await completeAnthropic()
        case "openai-responses": return try await completeOpenAIResponses()
        case "gpt": return try await completeChatGPT()
        default: return try await completeOpenAI()
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
            "messages": wire,
        ]
        if !tools.isEmpty { body["tools"] = orderedTools.map(\.wire) }
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
        for message in wire {
            guard let role = message["role"] as? String else { continue }
            let content = message["content"] as? [[String: Any]] ?? []
            if role == "user" {
                let results = content.filter { $0["type"] as? String == "tool_result" }
                if results.isEmpty {
                    result.append(["role": "user", "content": content.compactMap { block in block["text"] as? String }.map { ["type": "input_text", "text": $0] }])
                } else {
                    for item in results { result.append(["type": "function_call_output", "call_id": item["tool_use_id"] as? String ?? "tool", "output": item["content"] as? String ?? ""]) }
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
        for message in wire {
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
                    result.append(["role": "user", "content": content.compactMap { $0["text"] as? String }.joined(separator: "\n")])
                } else {
                    for block in toolResults {
                        result.append(["role": "tool", "tool_call_id": block["tool_use_id"] as? String ?? "", "content": block["content"] as? String ?? ""])
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

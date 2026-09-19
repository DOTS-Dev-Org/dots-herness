// Copyright (c) 2026 DOTS
// Executes one scheduled task in a transient headless agent host.
// Shared by the in-app scheduler (AppModel) and the Faz 2 background daemon.

import Foundation
import PluginRuntime

@MainActor
public struct ScheduledTaskRunner {
    private let paths: SupportPaths
    private let router: RouterController
    private let endpoint: AgentEndpointController?
    private let permissionMode: AgentPermissionMode
    private let systemPrompt: () -> String

    public init(
        paths: SupportPaths,
        router: RouterController,
        endpoint: AgentEndpointController? = nil,
        permissionMode: AgentPermissionMode = .ask,
        systemPrompt: @escaping () -> String
    ) {
        self.paths = paths
        self.router = router
        self.endpoint = endpoint
        self.permissionMode = permissionMode
        self.systemPrompt = systemPrompt
    }

    /// Runs `task` to completion. Diagnostic strings are developer-facing status
    /// shown in the task's "last run" detail; not routed through localization.
    public func run(_ task: ScheduledTask) async -> TaskScheduler.RunResult {
        let prompt = task.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            return TaskScheduler.RunResult(ok: false, message: "Empty prompt")
        }
        guard let workspace = Self.validWorkspace(task.workspacePath) else {
            return TaskScheduler.RunResult(ok: false, message: "Workspace not found: \(task.workspacePath)")
        }

        let models = [task.modelID, task.fallbackModelID]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let attempts: [String?] = models.isEmpty ? [nil] : models.map(Optional.some)
        var lastResult = TaskScheduler.RunResult(ok: false, message: "No response")

        for (index, model) in attempts.enumerated() {
            let result = await runAttempt(
                task: task,
                prompt: prompt,
                workspace: workspace,
                model: model,
                fallbackUsed: index > 0
            )
            lastResult = result
            if result.ok { return result }
        }
        return lastResult
    }

    private func runAttempt(
        task: ScheduledTask,
        prompt: String,
        workspace: String,
        model: String?,
        fallbackUsed: Bool
    ) async -> TaskScheduler.RunResult {
        let host: AgentBridge
        if let endpoint {
            host = AgentBridge(
                paths: paths,
                endpoint: endpoint,
                router: router,
                permissionMode: .full,
                nonInteractive: true,
                automaticNetworkAccess: task.allowsNetwork,
                area: .coding,
                sessionFileName: AgentArea.coding.sessionFileName
            )
        } else {
            host = AgentBridge(
                paths: paths,
                router: router,
                permissionMode: .full,
                nonInteractive: true,
                automaticNetworkAccess: task.allowsNetwork,
                area: .coding,
                sessionFileName: AgentArea.coding.sessionFileName
            )
        }
        host.updateSystemPrompt(systemPrompt())
        host.start(workspacePath: workspace)
        host.setSandboxPolicy(SandboxExecutionPolicy(
            workspaceURL: URL(fileURLWithPath: workspace, isDirectory: true),
            networkAccess: task.allowsNetwork
        ))
        await host.refreshConnection()
        guard host.isReady else {
            return TaskScheduler.RunResult(ok: false, message: host.status, modelID: model ?? "", fallbackUsed: fallbackUsed)
        }

        host.newConversation()
        guard let conversationID = host.selectedID else {
            return TaskScheduler.RunResult(ok: false, message: "Could not open a conversation", modelID: model ?? "", fallbackUsed: fallbackUsed)
        }
        let stamp = DateFormatter.taskStamp.string(from: Date())
        host.renameConversation(conversationID, to: "\(task.name) — \(stamp)")

        let target = task.resolvedTargetPath()
        let scopedPrompt = target.map {
            "Work only on this target inside the workspace: \($0)\n\n\(prompt)"
        } ?? prompt
        await host.send(text: scopedPrompt, mode: .queue, modelOverride: model)

        let last = host.conversations.first { $0.id == conversationID }?.messages.last
        let output = last?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let ok = last?.kind == .assistant && !output.isEmpty
        let usedModel = model ?? host.connection?.model ?? ""
        host.deleteConversation(conversationID)
        return TaskScheduler.RunResult(
            ok: ok,
            message: output.isEmpty ? "No response" : String(output.prefix(4000)),
            modelID: usedModel,
            fallbackUsed: fallbackUsed
        )
    }

    static func validWorkspace(_ raw: String) -> String? {
        guard let normalized = ConversationStore.normalizedPath(raw), normalized != "/" else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: normalized, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return normalized
    }
}

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
    private let systemPrompt: () -> String

    public init(
        paths: SupportPaths,
        router: RouterController,
        endpoint: AgentEndpointController? = nil,
        systemPrompt: @escaping () -> String
    ) {
        self.paths = paths
        self.router = router
        self.endpoint = endpoint
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

        let host: AgentBridge
        if let endpoint {
            host = AgentBridge(paths: paths, endpoint: endpoint, router: router)
        } else {
            host = AgentBridge(paths: paths, router: router)
        }
        host.updateSystemPrompt(systemPrompt())
        host.start(workspacePath: workspace)
        await host.refreshConnection()
        guard host.isReady else {
            return TaskScheduler.RunResult(ok: false, message: host.status)
        }

        host.newConversation()
        guard let conversationID = host.selectedID else {
            return TaskScheduler.RunResult(ok: false, message: "Could not open a conversation")
        }
        let stamp = DateFormatter.taskStamp.string(from: Date())
        host.renameConversation(conversationID, to: "\(task.name) — \(stamp)")

        await host.send(text: prompt, mode: .queue)

        let last = host.conversations.first { $0.id == conversationID }?.messages.last
        if let last, last.kind == .assistant, !last.text.isEmpty {
            return TaskScheduler.RunResult(
                ok: true,
                message: String(last.text.prefix(200)),
                conversationID: conversationID
            )
        }
        return TaskScheduler.RunResult(
            ok: false,
            message: last?.text ?? "No response",
            conversationID: conversationID
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

// Copyright (c) 2026 DOTS
// Tool, prompt, task and conversation-lifecycle recording.

import CryptoKit
import Foundation
import PluginRuntime

extension WorkspaceMemory {
    /// Reads and hashes the file a `write_file` call is about to replace. Both
    /// sides of that read leave the main actor: a multi-megabyte file would
    /// otherwise stall the UI for the duration of the hash.
    public func fileHash(for call: AgentToolCall, workspace: URL) async -> (path: String, hash: String?, bytes: Int)? {
        guard call.name == "write_file",
              let arguments = parseArguments(call),
              let rawPath = arguments["path"] as? String,
              let file = safeWorkspaceURL(rawPath, workspace: workspace) else { return nil }
        let data = await Task.detached(priority: .userInitiated) { try? Data(contentsOf: file) }.value
        return (safePath(rawPath), data.map { digest($0) }, data?.count ?? 0)
    }

    /// `git status` spawns a child process and waits for it, which on a large
    /// working tree is hundreds of milliseconds of blocked main actor. The
    /// process runs detached; path normalisation stays here.
    /// Memory writes into `.mem` during a run; they are the host's bookkeeping, not
    /// work the model did, so they never count as changed files.
    public func changedGitPaths(workspace: URL) async -> Set<String> {
        let lines = await Task.detached(priority: .userInitiated) { Self.gitStatusLines(workspace: workspace) }.value
        return Set(lines.compactMap { line in
            guard line.count > 3 else { return nil }
            let path = safePath(String(line.dropFirst(3)))
            return path == ".mem" || path.hasPrefix(".mem/") ? nil : path
        })
    }

    nonisolated private static func gitStatusLines(workspace: URL) -> [String] {
        gitLines(["status", "--porcelain", "--untracked-files=all"], workspace: workspace)
    }

    nonisolated static func gitLines(_ arguments: [String], workspace: URL) -> [String] {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        process.currentDirectoryURL = workspace
        process.standardOutput = output
        // This helper only records paths; diagnostics were discarded before too.
        // Avoid leaving a second pipe unread if git reports a large error.
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return [] }
        // Drain stdout before waiting. If git writes more than the pipe buffer,
        // waiting first leaves git blocked on its write while this task waits for git.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8) else { return [] }
        return text.split(whereSeparator: \.isNewline).map(String.init)
    }

    /// `beforeGit`/`afterGit` are captured by the run loop around the tool, off
    /// the main actor, and only for tools that can touch files: this used to run
    /// a second `git status` here for every call, including reads and searches.
    public func recordTool(
        runID: UUID,
        call: AgentToolCall,
        result: String,
        beforeFile: (path: String, hash: String?, bytes: Int)?,
        beforeGit: Set<String>,
        afterGit: Set<String>,
        workspace: URL
    ) {
        guard var task = tasks[runID.uuidString] else { return }
        let arguments = parseArguments(call) ?? [:]
        let toolPayload: [String: Any] = [
            "runId": runID.uuidString,
            "name": call.name,
            "path": arguments["path"] is String ? safePath(arguments["path"] as! String) : NSNull(),
            "commandSummary": call.name == "run_command" ? sanitize(arguments["command"] as? String ?? "", limit: 160) : NSNull(),
            "resultStatus": result.range(of: "error", options: .caseInsensitive) != nil ? "failed" : "completed",
            "resultBytes": result.utf8.count,
        ]
        recordActivity(type: "tool.executed", payload: toolPayload)
        task.tools.append(call.name)

        if let beforeFile,
           let afterURL = safeWorkspaceURL((arguments["path"] as? String) ?? "", workspace: workspace) {
            let afterData = try? Data(contentsOf: afterURL)
            let change: [String: Any] = [
                "runId": runID.uuidString,
                "path": beforeFile.path,
                "operation": "modified",
                "beforeHash": beforeFile.hash ?? NSNull(),
                "afterHash": afterData.map { digest($0) } ?? NSNull(),
                "beforeBytes": beforeFile.bytes,
                "afterBytes": afterData?.count ?? 0,
                "attribution": "write_file",
            ]
            recordActivity(type: "file.changed", payload: change)
            task.changedFiles.append(change)
        }

        for path in afterGit.subtracting(beforeGit) {
            let change: [String: Any] = [
                "runId": runID.uuidString,
                "path": path,
                "operation": "modified",
                "attribution": "unattributed-shell-change",
            ]
            recordActivity(type: "file.changed", payload: change)
            task.changedFiles.append(change)
        }
        tasks[runID.uuidString] = task
    }

    /// A skill the run read. Like a tool call, it is logged only for a task this memory began,
    /// so a run in some other folder never writes into this project's records.
    public func recordSkill(runID: UUID, skill: String) {
        guard tasks[runID.uuidString] != nil else { return }
        recordActivity(type: "skill.used", payload: ["runId": runID.uuidString, "skill": sanitize(skill, limit: 120)])
    }

    public func recordPrompt(runID: UUID, prompt: String) {
        guard var task = tasks[runID.uuidString] else { return }
        task.promptSummary = sanitize(prompt, limit: 240)
        task.promptHash = digest(Data(prompt.utf8))
        tasks[runID.uuidString] = task
    }

    public func finishTask(runID: UUID, success: Bool, finalText: String = "", controlText: String? = nil) {
        guard let task = tasks.removeValue(forKey: runID.uuidString) else { return }
        let controls = controlText ?? finalText
        let visibleFinalText = visibleText(in: finalText)
        let open = openItems(in: controls)
        let status = success ? (open.isEmpty ? "completed" : "unfinished") : "failed"
        closeBacklog(mentionedIn: controls)
        // A run that read nothing and changed nothing is chat, not work. Its note
        // would still be injected by `relevantTasks(for:)`, which falls back to the
        // three most recent notes when no term matches, so recording it costs every
        // later prompt. The preference and decision extraction below still runs:
        // a lasting instruction is often given in exactly such a turn.
        let didWork = !task.tools.isEmpty || !task.changedFiles.isEmpty
        let payload: [String: Any] = [
            "runId": task.runID,
            "status": status,
            "changedFiles": task.changedFiles,
            "toolCount": task.tools.count,
            "semanticStatus": "pending",
        ]
        if didWork || !open.isEmpty {
            recordActivity(type: "task.\(status)", payload: payload)
            writeTaskNote(task, status: status, finalText: visibleFinalText, openItems: open)
        }
        // Work that touched a manifest may have changed what the project is built
        // with, and work that touched a document what the map says of it: read both
        // again instead of waiting to be told.
        if task.changedFiles.contains(where: {
            let name = URL(fileURLWithPath: $0["path"] as? String ?? "").lastPathComponent
            return Self.isStackManifest(name) || name.lowercased().hasSuffix(".md")
        }) {
            try? updateMapIfNeeded(deep: true)
        }
        let language = explicitLanguage(in: task.promptSummary)
        let decision = explicitDecision(in: task.promptSummary)
        // The reply language describes the person in every project, so it goes to the
        // profile only. Nothing about a preference is written to the repository.
        if let language { try? profile.setPreference(key: "language", value: language) }
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let decision {
                try? self.recordProjectDecision(summary: decision)
            }
            self.recordActivity(type: "semantic.completed", payload: [
                "runId": runID.uuidString,
                "status": "completed",
                "preferenceUpdated": language != nil,
                "decisionProposed": decision != nil,
            ])
        }
    }

    /// Keeps chat lifecycle separate from task outcome so archive/delete actions
    /// remain visible without falsely changing a completed or failed task.
    public func recordConversationLifecycle(
        conversationID: String,
        title: String,
        state: ConversationLifecycleState
    ) {
        guard manifest != nil, !conversationID.isEmpty else { return }
        let safeTitle = sanitize(title, limit: 120)
        recordActivity(type: "conversation.\(state.rawValue)", payload: [
            "conversationId": conversationID,
            "title": safeTitle,
        ])
        writeConversationNote(conversationID: conversationID, record: [
            "title": safeTitle,
            "state": state.rawValue,
            "updatedAt": isoNow(),
            "revision": revision,
        ])
    }

    public func recordConversationRewind(
        conversationID: String,
        title: String,
        beforeMessageID: String,
        restoredPaths: [String],
        conflictPaths: [String]
    ) {
        guard manifest != nil, !conversationID.isEmpty else { return }
        recordActivity(type: "conversation.rewound", payload: [
            "conversationId": conversationID,
            "title": sanitize(title, limit: 120),
            "beforeMessageId": beforeMessageID,
            "restoredPaths": restoredPaths,
            "conflictPaths": conflictPaths,
        ])
    }
}

// Copyright (c) 2026 DOTS
// Editing subagent with a declared file assignment.
//
// A long change that splits into independent parts is slow to do one file after
// another, and every file body it touches stays in the main conversation. This
// hands one part to a separate agent that reads, edits and reports back.
//
// Two agents writing the same file is the failure that makes parallel edits
// unusable, so it is ruled out by construction rather than detected afterwards:
// each subagent names the files it owns before it starts, assignments of one
// turn must not overlap, and a write outside the assignment is refused.
//
// An edit nobody ran is a guess, so the caller may also declare `checks`: the
// build or test commands that prove this part works. The subagent runs those and
// nothing else, as often as it needs, and the host - not the subagent's report -
// records whether each one passed after the last edit.

import Foundation
import HarnessPluginKit

public enum DelegateTool {
    public static let name = "delegate"
    /// Editing takes more steps than locating: read, edit, re-read, fix.
    static let maxSteps = 40
    /// Concurrent editing subagents per turn. Each runs on the conversation's
    /// own model, so this is also the cost ceiling of one turn.
    public static let maxPerTurn = 3
    static let writeTools: Set<String> = ["write_file", FileEditTools.editName]
    static let checkName = "run_check"
    static let maxChecks = 3

    public static let definition = AgentToolDefinition(
        name: name,
        description: """
        Hand one self-contained part of a change to a separate agent that reads and edits files, \
        and get back only its report. Use it when a task splits into parts that touch different \
        files and do not depend on each other's edits - then call delegate once per part in the \
        same turn (maximum \(maxPerTurn)) and they run in parallel. Do not use it for a change \
        that fits in a few edits, or for parts that must be written in order: do those yourself, \
        since each subagent costs a whole extra run on this conversation's model. \
        `files` is the subagent's assignment: the only paths it may create or change. A directory \
        covers everything under it. Assignments given in one turn must not overlap; an overlapping \
        call is refused. `checks` are the commands that prove the part works (a build, one test \
        class, a linter): the subagent runs them after editing, fixes what they report and repeats, \
        and the result tells you which ones passed. Give the narrowest check that covers the part - \
        each run is stopped after 45 seconds and sees the other subagents' unfinished edits - and \
        never one that rewrites sources, deletes files or uses the network. Without checks the \
        subagent cannot run anything. It cannot run other commands, delete files or write \
        elsewhere, and it sees nothing of this conversation, so state the task in full: what to \
        change, the interfaces it must keep, and the conventions to follow. Run the full build and \
        tests yourself after the subagents finish, and re-read a file a subagent changed before \
        editing it.
        """,
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "task": .object([
                    "type": .string("string"),
                    "description": .string("The complete instructions for this part of the change."),
                ]),
                "files": .object([
                    "type": .string("array"),
                    "items": .object(["type": .string("string")]),
                    "description": .string("Workspace-relative files or directories this subagent may create or change."),
                ]),
                "checks": .object([
                    "type": .string("array"),
                    "items": .object(["type": .string("string")]),
                    "description": .string("Optional. Up to \(maxChecks) shell commands the subagent may run to verify its work, run from the workspace root exactly as written, e.g. `swift test --filter ParserTests`."),
                ]),
            ]),
            "required": .array([.string("task"), .string("files")]),
        ])
    )

    static let checkDefinition = AgentToolDefinition(
        name: checkName,
        description: "Run one of your assigned checks and get its output. Checks of all agents run one at a time, so a call may wait.",
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "check": .object([
                    "type": .string("integer"),
                    "description": .string("The number of the check, as listed in your instructions."),
                ]),
            ]),
            "required": .array([.string("check")]),
        ])
    )

    private static func checkRules(_ checks: [String]) -> String {
        guard !checks.isEmpty else { return "You cannot run commands or delete files." }
        return """
        You cannot delete files or run commands of your own, but you can run these checks with
        run_check, by number, as often as you need:
        \(checks.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n"))
        Run them once your edits are in, fix what they report inside your assignment, and run them
        again: a check counts only if it passed after your last edit. A failure that comes from a
        file outside your assignment may be another agent's unfinished work - do not try to fix it;
        quote its decisive lines under Unresolved.
        """
    }

    private static func systemPrompt(claims: [String], checks: [String]) -> String {
        """
        You are an editing agent working inside one workspace on one assigned part of a larger change.
        Other agents are editing other files of the same project at the same time.
        You may create or change only these paths (a directory covers everything under it):
        \(claims.map { "- \($0)" }.joined(separator: "\n"))
        You may read any file. A write outside the assignment is refused: do not look for another way,
        report what was needed under Unresolved instead. \(checkRules(checks))
        Read a file before you change it. Prefer edit_file for an existing file and write_file for a
        new one. Keep to the task: no unrelated refactors, no new files beyond what it needs.
        When you are done, reply with the report only, in exactly this shape:

        ## Changes
        One bullet per file you changed, opening with its path, then what changed in one sentence.

        ## Unresolved
        What you could not do and why, including anything needed outside your assignment. Write "None"
        when nothing is open.

        Status: done | partial

        Say "partial" whenever any part of the task is unfinished or a check still fails. The caller acts on this line, so a
        wrong "done" is worse than an honest "partial". Never paste file contents into the report.
        """
    }

    /// The validated request: what to do and which workspace-relative paths it owns.
    public struct Assignment: Sendable, Equatable {
        public var task: String
        public var claims: [String]
        /// The only commands the subagent may run, exactly as the caller wrote them.
        public var checks: [String] = []
    }

    /// One declared check and what the host saw it do.
    public struct CheckResult: Sendable, Equatable {
        public var command: String
        public var runs = 0
        /// The last run's verdict; nil when it never ran or a file changed since.
        public var passed: Bool?
    }

    public struct Outcome: Sendable, Equatable {
        public var answer: String
        /// Workspace-relative paths whose bytes actually changed, checked on disk
        /// rather than taken from the subagent's report.
        public var written: [String] = []
        public var steps = 0
        public var hitStepLimit = false
        /// The subagent's own verdict. False also when it never said.
        public var done = false
        public var checks: [CheckResult] = []

        /// Every declared check passed after the last edit. False without checks:
        /// nothing was run, so nothing is proven.
        public var verified: Bool { !checks.isEmpty && checks.allSatisfy { $0.passed == true } }

        static func refused(_ message: String) -> Outcome { Outcome(answer: message) }

        /// The tool result the parent model sees: the report, what really changed,
        /// and every reason it has to distrust the report.
        public var toolResult: String {
            var parts = [answer]
            if steps > 0 {
                if !done { parts.append("[Partial: the subagent did not finish. Check the files before relying on it.]") }
                if hitStepLimit { parts.append("[The subagent reached its step limit.]") }
                parts.append(written.isEmpty
                    ? "[No file was changed.]"
                    : "Files changed (verified on disk): " + written.joined(separator: ", ")
                        + "\nRe-read any of these before editing it yourself.")
                if !checks.isEmpty {
                    parts.append("Checks (exit status seen by the host):\n" + checks.map { check in
                        let verdict = switch check.passed {
                        case true?: "passed"
                        case false?: "FAILED on its last run"
                        case nil: check.runs == 0 ? "never run" : "not run again after the last edit"
                        }
                        return "- \(check.command): \(verdict)"
                    }.joined(separator: "\n"))
                    if !verified { parts.append("[Unverified: not every check passed after the last edit. Do not rely on this part until you ran it yourself.]") }
                }
            }
            return parts.joined(separator: "\n\n")
        }
    }

    /// Runs one permitted tool call for the subagent. The host owns leases, the
    /// read ledger scope and change recording; this file owns only the policy.
    public typealias Execute = @Sendable (AgentToolCall) async -> String

    /// Runs one declared check command. The host owns the sandbox, the queue that
    /// keeps two builds out of one tree, and the exit status.
    public typealias Check = @Sendable (String) async -> (output: String, passed: Bool)

    /// Parses and normalizes the call. A claim that leaves the workspace, or an
    /// empty assignment, is an error the parent can fix and retry.
    static func assignment(from call: AgentToolCall, workspace: URL) -> Result<Assignment, NativeAgentError> {
        guard let data = call.arguments.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let task = (object["task"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !task.isEmpty else {
            return .failure(NativeAgentError("Tool error: delegate needs a task - the complete instructions for the subagent."))
        }
        let raw = (object["files"] as? [String] ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !raw.isEmpty else {
            return .failure(NativeAgentError("Tool error: delegate needs files - the paths this subagent may create or change."))
        }
        var claims: [String] = []
        for path in raw {
            guard let relative = relativePath(path, workspace: workspace) else {
                return .failure(NativeAgentError("Tool error: \(path) is outside the workspace and cannot be assigned."))
            }
            if !claims.contains(relative) { claims.append(relative) }
        }
        var checks: [String] = []
        for command in (object["checks"] as? [String] ?? []).map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        where !command.isEmpty && !checks.contains(command) {
            // No banner can be raised from inside a subagent, so what would need
            // one in the main run is not a check at all.
            guard !WorkspaceTools.mayDeleteFiles(command), !WorkspaceTools.mayAccessNetwork(command) else {
                return .failure(NativeAgentError("Tool error: a check may only build or test. `\(command)` could delete files or reach the network; run it yourself after the subagents finish."))
            }
            checks.append(command)
        }
        guard checks.count <= maxChecks else {
            return .failure(NativeAgentError("Tool error: at most \(maxChecks) checks per subagent."))
        }
        return .success(Assignment(task: task, claims: claims, checks: checks))
    }

    /// The canonical workspace-relative form shared by claims and write targets,
    /// so `./a/../b.swift` and `b.swift` are one path. Nil when it escapes.
    static func relativePath(_ path: String, workspace: URL) -> String? {
        guard let url = try? WorkspaceTools.resolve(path, workspace: workspace) else { return nil }
        return WorkspaceTools.relativePath(url, workspace: workspace.standardizedFileURL.resolvingSymlinksInPath())
    }

    /// Whether `claim` covers `path`: the same path, a directory above it, or the
    /// workspace root.
    static func covers(_ claim: String, _ path: String) -> Bool {
        claim == "." || claim == path || path.hasPrefix(claim + "/")
    }

    static func covers(_ claims: [String], _ path: String) -> Bool {
        claims.contains { covers($0, path) }
    }

    /// The first pair of claims that could write the same file, if any.
    static func overlap(_ a: [String], _ b: [String]) -> (String, String)? {
        for x in a {
            for y in b where covers(x, y) || covers(y, x) { return (x, y) }
        }
        return nil
    }

    public static func run(
        _ assignment: Assignment,
        complete: @escaping ExploreTool.Complete,
        execute: @escaping Execute,
        check: Check? = nil,
        workspace: URL
    ) async -> Outcome {
        // A host that cannot run commands offers none, whatever was asked for.
        let checks = check == nil ? [] : assignment.checks
        let tools = WorkspaceTools.readOnlyDefinitions
            + WorkspaceTools.definitions.filter { writeTools.contains($0.name) }
            + (checks.isEmpty ? [] : [checkDefinition])
        var messages = [
            AgentMessage(role: .system, content: systemPrompt(claims: assignment.claims, checks: checks)),
            AgentMessage(role: .user, content: assignment.task),
        ]
        var outcome = Outcome(answer: "")
        outcome.checks = checks.map { CheckResult(command: $0) }

        func report() -> String {
            messages.filter { $0.role == .assistant }
                .map { $0.content.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
        }

        for _ in 0..<maxSteps {
            if Task.isCancelled {
                outcome.answer = "The subagent was stopped before it finished."
                return outcome
            }
            outcome.steps += 1
            let response: AgentResponse
            do {
                response = try await complete(messages, tools)
            } catch {
                let partial = report()
                outcome.answer = "The subagent failed: \(error.localizedDescription)"
                    + (partial.isEmpty ? "" : "\n\nWhat it reported so far:\n" + partial)
                return outcome
            }
            messages.append(response.message)

            if response.message.toolCalls.isEmpty {
                let text = response.message.content.trimmingCharacters(in: .whitespacesAndNewlines)
                outcome.answer = text.isEmpty ? "The subagent returned no report." : text
                outcome.done = finished(text)
                return outcome
            }

            for call in response.message.toolCalls {
                let result: String
                if WorkspaceTools.isReadOnly(call.name) {
                    result = await execute(call)
                } else if writeTools.contains(call.name) {
                    result = await write(call, claims: assignment.claims, execute: execute, workspace: workspace, outcome: &outcome)
                } else if call.name == checkName, let check, !checks.isEmpty {
                    result = await runCheck(call, check: check, results: &outcome.checks)
                } else {
                    result = "blocked: this subagent can only read and edit files; it has no \(call.name) tool."
                }
                messages.append(AgentMessage(role: .tool, content: result, name: call.name, toolCallID: call.id))
            }
        }

        // Out of steps with edits possibly half done: one tool-free call for an
        // honest report beats leaving the parent to guess what state the files are in.
        messages.append(AgentMessage(
            role: .user,
            content: "Your step budget is spent. Report now in the required shape, with Status: partial, naming exactly what is finished and what is not."
        ))
        let final = try? await complete(messages, [])
        let text = (final?.message.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        outcome.answer = text.isEmpty ? "The subagent reached its step limit without a report." : text
        outcome.hitStepLimit = true
        return outcome
    }

    /// One write, allowed only inside the assignment. Whether it changed anything
    /// is read back from disk, so `written` never depends on a localized message.
    private static func write(
        _ call: AgentToolCall,
        claims: [String],
        execute: Execute,
        workspace: URL,
        outcome: inout Outcome
    ) async -> String {
        guard let data = call.arguments.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let path = object["path"] as? String,
              let relative = relativePath(path, workspace: workspace) else {
            return "Tool error: \(call.name) needs a path inside the workspace."
        }
        guard covers(claims, relative) else {
            return "refused: \(relative) is not in your assignment (\(claims.joined(separator: ", "))). "
                + "Another agent may own it. Do not work around this; report it under Unresolved."
        }
        let file = workspace.appendingPathComponent(relative)
        let before = try? Data(contentsOf: file)
        let result = await execute(call)
        if (try? Data(contentsOf: file)) != before {
            if !outcome.written.contains(relative) { outcome.written.append(relative) }
            // A pass proves the bytes it ran against, not the ones written since.
            for index in outcome.checks.indices { outcome.checks[index].passed = nil }
        }
        return result
    }

    /// One run of a declared check, picked by its number so the subagent cannot
    /// reword the command line.
    private static func runCheck(_ call: AgentToolCall, check: Check, results: inout [CheckResult]) async -> String {
        let object = call.arguments.data(using: .utf8)
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let number = (object?["check"] as? Int) ?? Int(object?["check"] as? String ?? "")
        guard let number, results.indices.contains(number - 1) else {
            return "Tool error: check must be a number from 1 to \(results.count)."
        }
        let (output, passed) = await check(results[number - 1].command)
        results[number - 1].runs += 1
        results[number - 1].passed = passed
        return "[check \(number) \(passed ? "passed" : "FAILED")]\n" + output
    }

    /// Reads the subagent's own `Status:` line. Missing or malformed counts as partial.
    static func finished(_ answer: String) -> Bool {
        for line in answer.split(separator: "\n").reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespaces).lowercased()
            guard trimmed.hasPrefix("status:") else { continue }
            return trimmed.dropFirst("status:".count).trimmingCharacters(in: .whitespaces).hasPrefix("done")
        }
        return false
    }
}

/// Lets one check run at a time. Two builds or test runs in one tree fight over
/// the same build directory, and the loser reports a failure nobody caused.
actor CheckQueue {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        guard busy else { busy = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }
}

extension NativeAgentHost {
    /// Validates, asks approval for, and then starts together every editing
    /// subagent of one assistant turn. Approving the call approves its writes
    /// inside the stated assignment, so the subagent never stops to ask again.
    func startWorkers(
        _ calls: [AgentToolCall],
        workspace: URL,
        conversationID: String,
        runID: UUID,
        complete: @escaping ExploreTool.Complete
    ) async -> [String: Task<DelegateTool.Outcome, Never>] {
        var tasks: [String: Task<DelegateTool.Outcome, Never>] = [:]
        var accepted: [(call: AgentToolCall, assignment: DelegateTool.Assignment)] = []
        for call in calls where call.name == DelegateTool.name {
            let refusal: String?
            switch DelegateTool.assignment(from: call, workspace: workspace) {
            case .failure(let error):
                refusal = error.message
            case .success(let assignment):
                if accepted.count >= DelegateTool.maxPerTurn {
                    refusal = "Tool error: maximum of \(DelegateTool.maxPerTurn) editing subagents per turn exceeded. Delegate the rest in a later turn."
                } else if let clash = accepted.lazy.compactMap({ DelegateTool.overlap($0.assignment.claims, assignment.claims) }).first {
                    refusal = "Tool error: \(clash.1) overlaps \(clash.0), which another subagent of this turn already owns. "
                        + "Give both parts to one subagent, or delegate this one in a later turn."
                } else if await requestApprovalIfNeeded(for: call, conversationID: conversationID),
                          await approveChecks(assignment.checks, of: call, conversationID: conversationID) {
                    accepted.append((call, assignment))
                    refusal = nil
                } else {
                    refusal = AppCopy.text("permission.rejected")
                }
            }
            if let refusal { tasks[call.id] = Task { .refused(refusal) } }
        }
        // Started only once every approval is in, so they run side by side.
        let queue = CheckQueue()
        for (call, assignment) in accepted {
            let scope = "delegate-" + call.id
            tasks[call.id] = Task { [weak self] in
                await DelegateTool.run(assignment, complete: complete, execute: { [weak self] toolCall in
                    await self?.runWorkerTool(
                        toolCall, workspace: workspace, conversationID: conversationID, runID: runID, scope: scope
                    ) ?? "Tool error: the agent host is gone."
                }, check: { [weak self] command in
                    await queue.acquire()
                    let result = await self?.runWorkerCheck(command, workspace: workspace, runID: runID)
                    await queue.release()
                    return result ?? ("Tool error: the agent host is gone.", false)
                }, workspace: workspace)
            }
        }
        return tasks
    }

    private static func commandCall(_ command: String, id: String) -> AgentToolCall {
        let data = (try? JSONSerialization.data(withJSONObject: ["command": command])) ?? Data()
        return AgentToolCall(id: id, name: "run_command", arguments: String(decoding: data, as: UTF8.self))
    }

    /// A check is a command, so it is approved as one: the banner shows the command
    /// line, and a permission mode that asks before run_command asks here too.
    private func approveChecks(_ checks: [String], of call: AgentToolCall, conversationID: String) async -> Bool {
        for command in checks {
            guard await requestApprovalIfNeeded(for: Self.commandCall(command, id: call.id), conversationID: conversationID) else { return false }
        }
        return true
    }

    /// One approved check on a subagent's behalf, under the same sandbox as the
    /// main run's commands. A stop reaches the child process, not just the task.
    func runWorkerCheck(_ command: String, workspace: URL, runID: UUID) async -> (output: String, passed: Bool) {
        guard !Task.isCancelled else { return ("Command canceled after user interrupt.", false) }
        let beforeGit = await memory.changedGitPaths(workspace: workspace)
        let policy = (sandboxPolicy ?? SandboxExecutionPolicy(workspaceURL: workspace)).strictAgentPolicy()
        let cancel = ToolCancel()
        let work = Task.detached(priority: .userInitiated) {
            WorkspaceTools.runCheck(command: command, workspace: workspace, sandboxPolicy: policy, isCancelled: { cancel.isCancelled })
        }
        let result = await withTaskCancellationHandler { await work.value } onCancel: { cancel.cancel() }
        let afterGit = await memory.changedGitPaths(workspace: workspace)
        memory.recordTool(
            runID: runID, call: Self.commandCall(command, id: UUID().uuidString), result: result.output,
            beforeFile: nil, beforeGit: beforeGit, afterGit: afterGit, workspace: workspace
        )
        return result
    }

    /// One read or write on a subagent's behalf. Reads and writes land in the
    /// subagent's own ledger scope: it must read a file before changing it, and the
    /// parent - which never saw those bytes - must re-read before it edits the same file.
    func runWorkerTool(
        _ call: AgentToolCall,
        workspace: URL,
        conversationID: String,
        runID: UUID,
        scope: String
    ) async -> String {
        // Another chat's run may be writing this file. A subagent has no banner to
        // wait or ask through, so it backs off and reports instead.
        var lease: (target: WorkspaceLeaseTarget, ticket: UInt64)?
        if let target = WorkspaceLeases.shared.target(for: call.name, arguments: Self.arguments(of: call), workspace: workspace) {
            switch WorkspaceLeases.shared.tryAcquire(
                target,
                conversationID: conversationID,
                conversationTitle: conversations.first { $0.id == conversationID }?.title ?? conversationID,
                runID: runID,
                toolName: call.name,
                label: Self.argument(call, key: "path") ?? call.name
            ) {
            case .granted(let ticket):
                lease = (target, ticket)
            case .contested(let holder):
                return "refused: \"\(holder.conversationTitle)\" is writing this file right now. Skip it and report it under Unresolved."
            }
        }
        defer { if let lease { WorkspaceLeases.shared.release(target: lease.target, ticket: lease.ticket) } }

        let tracksChanges = !WorkspaceTools.isReadOnly(call.name)
        let beforeFile = tracksChanges ? await memory.fileHash(for: call, workspace: workspace) : nil
        let beforeGit = tracksChanges ? await memory.changedGitPaths(workspace: workspace) : []
        let readRoots = searchFolders
        let result = await Task.detached(priority: .userInitiated) {
            WorkspaceTools.execute(call, workspace: workspace, conversationID: scope, readRoots: readRoots)
        }.value
        if tracksChanges {
            let afterGit = await memory.changedGitPaths(workspace: workspace)
            memory.recordTool(
                runID: runID, call: call, result: result,
                beforeFile: beforeFile, beforeGit: beforeGit, afterGit: afterGit, workspace: workspace
            )
        }
        return result
    }
}

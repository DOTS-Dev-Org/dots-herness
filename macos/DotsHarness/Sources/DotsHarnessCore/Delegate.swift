// Copyright (c) 2026 DOTS
// Bounded, tool-using subagent ("delegate").
//
// `explore` only reads. `delegate` hands a self-contained piece of work - code,
// documents, a plugin action - to a side run on a cheaper model, and the main run
// gets back a short report instead of the transcript. What keeps that safe:
//
// - Only the main agent can start one, and a subagent has no `delegate`/`explore`
//   tool, so runs never nest.
// - Every writer declares the paths it may modify. A write outside them is refused,
//   and delegates of one turn run side by side only when their paths do not overlap;
//   overlapping ones run one after another (`DelegatePlanner`).
// - `full` mode adds commands and plugin/MCP tools. Their effects cannot be scoped,
//   so such a run always executes alone.
// - Approvals and every mutation pass through one gate, so the user sees one prompt
//   at a time and two subagents never write at the same moment.
// - `write_file` already refuses a file that changed since it was read, which catches
//   any edit made behind a subagent's back.

import Foundation
import HarnessPluginKit

public enum DelegateMode: String, Sendable, Equatable {
    /// Read tools plus `write_file`, only inside the declared scope.
    case write
    /// `write` plus `run_command`, plugin and MCP tools. Runs alone.
    case full
}

/// The workspace-relative files and directories a subagent may modify.
public struct DelegateScope: Sendable, Equatable, CustomStringConvertible {
    /// Normalized, `/`-separated, never absolute. An empty root is the whole workspace.
    public let roots: [String]

    public init?(paths: [String]) {
        var normalized: [String] = []
        for raw in paths {
            guard let root = Self.normalize(raw) else { return nil }
            if !normalized.contains(root) { normalized.append(root) }
        }
        guard !normalized.isEmpty else { return nil }
        roots = normalized
    }

    /// nil for anything that could leave the workspace or touch tool state:
    /// absolute or home paths, `..`, and the `.git` / `.mem` directories.
    static func normalize(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("/"), !trimmed.hasPrefix("~") else { return nil }
        var parts: [String] = []
        for part in trimmed.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." { return nil }
            parts.append(String(part))
        }
        if let first = parts.first, [".git", ".mem"].contains(first.lowercased()) { return nil }
        return parts.joined(separator: "/")
    }

    public var coversWorkspace: Bool { roots.contains("") }

    /// Lexical check. Case must match, so a scope never grants more than it names.
    public func allows(_ path: String) -> Bool {
        guard let target = Self.normalize(path) else { return false }
        return roots.contains { $0.isEmpty || target == $0 || target.hasPrefix($0 + "/") }
    }

    /// Case-insensitive on purpose: on a case-insensitive volume `Src` and `src`
    /// are one directory, and a missed overlap is a real conflict.
    public func overlaps(_ other: DelegateScope) -> Bool {
        for mine in roots.map({ $0.lowercased() }) {
            for theirs in other.roots.map({ $0.lowercased() }) {
                if mine.isEmpty || theirs.isEmpty || mine == theirs
                    || mine.hasPrefix(theirs + "/") || theirs.hasPrefix(mine + "/") {
                    return true
                }
            }
        }
        return false
    }

    public var description: String {
        roots.map { $0.isEmpty ? "." : $0 }.joined(separator: ", ")
    }
}

public struct DelegateError: Error, Equatable {
    public let message: String
}

public struct DelegateRequest: Sendable, Equatable {
    public let task: String
    public let mode: DelegateMode
    public let scope: DelegateScope

    /// Runs alone: it either uses tools whose effects cannot be scoped or claims
    /// the whole workspace.
    public var isExclusive: Bool { mode == .full || scope.coversWorkspace }

    public static func parse(_ call: AgentToolCall) -> Result<DelegateRequest, DelegateError> {
        guard let data = call.arguments.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure(DelegateError(message: "Tool error: delegate arguments are not valid JSON."))
        }
        guard let task = (object["task"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !task.isEmpty else {
            return .failure(DelegateError(message: "Tool error: delegate needs a task description."))
        }
        let modeName = (object["mode"] as? String)?.lowercased() ?? DelegateMode.write.rawValue
        guard let mode = DelegateMode(rawValue: modeName) else {
            return .failure(DelegateError(message: "Tool error: mode must be \"write\" or \"full\"."))
        }
        guard let paths = object["paths"] as? [String], !paths.isEmpty else {
            return .failure(DelegateError(
                message: "Tool error: delegate needs `paths`: the workspace-relative files or directories this subagent may modify."
            ))
        }
        guard let scope = DelegateScope(paths: paths) else {
            return .failure(DelegateError(
                message: "Tool error: every path must be workspace-relative, without `..`, and outside .git and .mem."
            ))
        }
        return .success(DelegateRequest(task: task, mode: mode, scope: scope))
    }
}

public enum DelegatePlanner {
    /// A turn may start at most this many delegates; the rest are refused.
    public static let maxPerTurn = 3

    /// Splits the requests of one turn into batches. Batches run one after
    /// another, the members of a batch in parallel. Order is preserved: a request
    /// joins the previous batch only when neither is exclusive and their scopes do
    /// not overlap, otherwise it starts a new batch.
    public static func batches(_ requests: [DelegateRequest]) -> [[Int]] {
        var result: [[Int]] = []
        var lastIsExclusive = false
        for (index, request) in requests.enumerated() {
            if !request.isExclusive, !lastIsExclusive, let last = result.last,
               !last.contains(where: { requests[$0].scope.overlaps(request.scope) }) {
                result[result.count - 1].append(index)
            } else {
                result.append([index])
            }
            lastIsExclusive = request.isExclusive
        }
        return result
    }
}

/// What one subagent actually changed, kept outside the model transcript so the
/// report the parent reads cannot overstate it.
public final class DelegateLedger: @unchecked Sendable {
    private let lock = NSLock()
    private var writtenPaths: [String] = []
    private var blockedCount = 0

    public init() {}

    public func noteWrite(_ path: String) {
        lock.withLock { if !writtenPaths.contains(path) { writtenPaths.append(path) } }
    }

    public func noteBlocked() {
        lock.withLock { blockedCount += 1 }
    }

    public var written: [String] { lock.withLock { writtenPaths } }
    public var blocked: Int { lock.withLock { blockedCount } }
}

/// One holder at a time. Approvals and mutations of all subagents of a turn pass
/// through it, so prompts never overlap and writes never interleave.
public actor DelegateGate {
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    public func acquire() async {
        if !locked {
            locked = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    public func release() {
        if waiters.isEmpty {
            locked = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

public enum DelegateTool {
    public static let name = "delegate"
    public static let maxPerTurn = DelegatePlanner.maxPerTurn
    /// A subagent has a bounded job; one that needs more was the wrong split.
    static let maxSteps = 30

    public static let definition = AgentToolDefinition(
        name: name,
        description: """
        Hand a self-contained piece of work - implementing a change, writing a file or document, \
        running a plugin action - to a separate subagent and get back a short report. It runs on a \
        cheaper model and sees nothing of this conversation, so put everything it needs in `task`, \
        and check what it did: the report lists the files it wrote. Use `explore` for read-only \
        searching. `paths` is required: the workspace-relative files or directories the subagent \
        may modify; a write anywhere else is refused. To work in parallel, call delegate several \
        times in one turn (maximum \(maxPerTurn)) with disjoint `paths`; delegates whose paths \
        overlap run one after another instead. Do not edit a delegate's paths yourself while it \
        runs. `mode` is "write" (read files, write inside `paths`; default) or "full" (also \
        run_command and plugin/MCP tools, which cannot be scoped - a full delegate always runs \
        alone).
        """,
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "task": .object([
                    "type": .string("string"),
                    "description": .string("The complete, self-contained job, with the context and acceptance checks the subagent needs."),
                ]),
                "paths": .object([
                    "type": .string("array"),
                    "items": .object(["type": .string("string")]),
                    "description": .string("Workspace-relative files or directories the subagent may modify. Keep them as narrow as the job allows."),
                ]),
                "mode": .object([
                    "type": .string("string"),
                    "enum": .array([.string("write"), .string("full")]),
                    "description": .string("write (default) or full."),
                ]),
            ]),
            "required": .array([.string("task"), .string("paths")]),
        ])
    )

    static func systemPrompt(for request: DelegateRequest) -> String {
        let tools = request.mode == .full
            ? "read_file, list_files, grep_files, write_file, run_command and any plugin or MCP tools"
            : "read_file, list_files, grep_files and write_file"
        return """
        You are a subagent working inside one workspace on a job handed to you by a main agent. You \
        cannot see its conversation; the task below is everything you have. Your tools: \(tools). \
        You may modify only these paths: \(request.scope.description). A write anywhere else is \
        refused; do not look for a way around it, and list any file outside your paths that the job \
        needs under Unresolved. Read a file before you replace it. Do not ask the user anything. \
        Do the job, check it where you can, and stop.
        Reply with a report only, in exactly this shape:

        ## Done
        What you changed or produced, one bullet per file, each opening with its path.

        ## Unresolved
        What you could not finish or verify, and why. Write "None" when nothing is open.

        Status: answered | partial

        Say "partial" whenever any part of the job is unfinished or unchecked. The caller acts on this \
        line, so a wrong "answered" is worse than an honest "partial".
        """
    }

    public struct Outcome: Sendable, Equatable {
        public var answer: String
        public var steps: Int
        public var hitStepLimit: Bool
        public var answered: Bool
        public var written: [String]
        public var blocked: Int
        /// True for a request that never started (bad arguments, over the limit).
        public var refused = false
        public var notes: [String] = []

        static func refused(_ message: String) -> Outcome {
            Outcome(answer: message, steps: 0, hitStepLimit: false, answered: false, written: [], blocked: 0, refused: true)
        }

        /// What the parent model reads: the report, then facts the subagent could not
        /// have invented - the files the ledger saw written and every reason to
        /// distrust the report.
        public var toolResult: String {
            guard !refused else { return answer }
            var parts = [answer]
            parts.append(written.isEmpty
                ? "Files written by the subagent: none."
                : "Files written by the subagent: " + written.joined(separator: ", "))
            if blocked > 0 {
                parts.append("The subagent tried \(blocked) write(s) outside its paths; they were refused.")
            }
            if !answered {
                parts.append("The subagent did not report a complete result: treat the work as unfinished and check it yourself before relying on it.")
            }
            if hitStepLimit {
                parts.append("The subagent ran out of steps.")
            }
            parts.append(contentsOf: notes)
            return parts.joined(separator: "\n\n")
        }
    }

    /// Runs one subagent. `execute` runs a tool call for it (scope, approval and
    /// the gate live there); `complete` reaches the model.
    public static func run(
        _ request: DelegateRequest,
        tools: [AgentToolDefinition],
        complete: @escaping ExploreTool.Complete,
        ledger: DelegateLedger,
        execute: @escaping @Sendable (AgentToolCall) async -> String
    ) async -> Outcome {
        var messages = [
            AgentMessage(role: .system, content: systemPrompt(for: request)),
            AgentMessage(role: .user, content: request.task),
        ]
        var steps = 0

        func finish(_ answer: String, hitStepLimit: Bool) -> Outcome {
            Outcome(
                answer: answer,
                steps: steps,
                hitStepLimit: hitStepLimit,
                answered: ExploreTool.answeredFully(answer) && !hitStepLimit,
                written: ledger.written,
                blocked: ledger.blocked
            )
        }

        for _ in 0..<maxSteps {
            if Task.isCancelled { return finish("The delegated run was cancelled.", hitStepLimit: false) }
            steps += 1
            let response: AgentResponse
            do {
                response = try await complete(messages, tools)
            } catch {
                let partial = messages.filter { $0.role == .assistant }
                    .map { $0.content.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n")
                let failure = "The delegated run failed: \(error.localizedDescription)"
                return finish(partial.isEmpty ? failure : failure + "\n\nPartial notes before it stopped:\n" + partial, hitStepLimit: false)
            }
            messages.append(response.message)

            if response.message.toolCalls.isEmpty {
                let text = response.message.content.trimmingCharacters(in: .whitespacesAndNewlines)
                return finish(text.isEmpty ? "The subagent returned no report." : text, hitStepLimit: false)
            }
            for call in response.message.toolCalls {
                if Task.isCancelled { return finish("The delegated run was cancelled.", hitStepLimit: false) }
                let result = await execute(call)
                messages.append(AgentMessage(role: .tool, content: result, name: call.name, toolCallID: call.id))
            }
        }

        // Budget spent: ask for a report from what it did instead of throwing the work away.
        messages.append(AgentMessage(
            role: .user,
            content: "Stop working. Report now, in the required shape, what you finished and what is still open."
        ))
        let final = try? await complete(messages, [])
        let text = (final?.message.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return finish(
            text.isEmpty ? "The subagent reached its step limit without a report." : text,
            hitStepLimit: true
        )
    }
}

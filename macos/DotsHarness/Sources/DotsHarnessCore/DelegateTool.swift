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
    /// Concurrent editing subagents per turn. One bounded assignment is valid;
    /// additional calls are only for independent parts.
    public static let maxPerTurn = 3
    /// Effort levels from cheapest to most thorough.
    static let levels = ["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"]
    /// What the parent may ask for one part: it planned the change, so it knows
    /// which part is mechanical and which is hard.
    static let requestableLevels = ["low", "medium", "high"]
    /// Consecutive failed checks that prove the starting effort was too low.
    static let failuresBeforeRaise = 2

    /// The most a subagent may spend: never above the user's own level. Auto
    /// ("") allows high, Economy medium.
    public static func ceiling(selected: String, economy: Bool) -> String {
        let level = selected.lowercased()
        let user = rank(level) == nil ? "high" : level
        return economy ? lower(user, "medium") : user
    }

    /// The starting effort: what the parent asked for this part, else medium
    /// (low in Economy), capped by `ceiling`. Never left empty: routing would treat
    /// the subagent's opening step as planning and pick the highest level.
    public static func effort(selected: String, economy: Bool, requested: String? = nil) -> String {
        let start = requested.flatMap { requestableLevels.contains($0) ? $0 : nil } ?? (economy ? "low" : "medium")
        return lower(start, ceiling(selected: selected, economy: economy))
    }

    /// One level up, capped by `ceiling`.
    static func raised(_ effort: String, ceiling: String) -> String {
        guard let index = rank(effort), index + 1 < levels.count else { return effort }
        return lower(levels[index + 1], ceiling)
    }

    private static func rank(_ level: String) -> Int? { levels.firstIndex(of: level.lowercased()) }
    private static func lower(_ a: String, _ b: String) -> String { (rank(a) ?? 0) <= (rank(b) ?? 0) ? a : b }

    /// One subagent step at the given effort, on the light model when the last flag
    /// is true. The host owns routing and failover.
    public typealias Complete = @Sendable ([AgentMessage], [AgentToolDefinition], String, Bool) async throws -> AgentResponse
    /// Which model a part runs on: the conversation's own, or the lightest one routing
    /// offers. Light is the parent's call for small mechanical edits only.
    static let models = ["conversation", "light"]
    /// Bounds the changed lines handed back to the parent, so it can keep editing
    /// them without a re-read and without the report growing into the file itself.
    static let excerptLineLimit = 120
    static let excerptByteLimit = 8_000
    static let writeTools: Set<String> = ["write_file", FileEditTools.editName]
    static let checkName = "run_check"
    static let maxChecks = 3

    public static let definition = AgentToolDefinition(
        name: name,
        description: """
        Hand one self-contained implementation assignment to a separate agent that reads and edits \
        files, then get back its report. The parent must inspect the relevant code and plan the \
        change first. Do not delegate a small or single-file edit: make it yourself with edit_file, \
        since a subagent re-reads the files and costs a whole extra run. Delegate when the change splits \
        into independent parts with non-overlapping files that can run in parallel (maximum \(maxPerTurn)), \
        or one large part spanning many files you have not read. \
        The parent owns design, integration, review and whole-change verification. Do not use explore \
        to read implementation files on the parent's behalf. \
        `files` is the subagent's assignment: the only paths it may create or change. A directory \
        covers everything under it. Assignments given in one turn must not overlap; an overlapping \
        call is refused. `checks` are the commands that prove the part works (a build, one test \
        class, a linter): the subagent runs them after editing, fixes what they report and repeats, \
        and the result tells you which ones passed. Give the narrowest check that covers the part - \
        each run is stopped after 45 seconds and sees the other subagents' unfinished edits - and \
        never one that rewrites sources, deletes files or uses the network. Without checks the \
        subagent cannot run anything. It cannot run other commands, delete files or write \
        elsewhere, and it sees nothing of this conversation. Pass the parent's implementation plan \
        in `plan`; include findings, interfaces, constraints and acceptance criteria in `task`. Run \
        the full relevant build/check yourself after the subagent finishes. Review the changed lines \
        in its report; fix small issues yourself.
        """,
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "plan": .object([
                    "type": .string("string"),
                    "description": .string("The implementation plan the parent formed after inspecting relevant code. Passed to the subagent as design context."),
                ]),
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
                "effort": .object([
                    "type": .string("string"),
                    "enum": .array(requestableLevels.map { .string($0) }),
                    "description": .string("Optional, default medium. How hard this part is: low for mechanical work (renames, following an existing pattern, strings or config), medium for ordinary code changes, high for tricky logic (concurrency, algorithms, security, an unclear bug). Capped at the user's own level; raised once automatically when checks keep failing."),
                ]),
                "model": .object([
                    "type": .string("string"),
                    "enum": .array(models.map { .string($0) }),
                    "description": .string("Optional, default conversation. light runs this part on a cheaper model: only for a small mechanical edit (a rename, a string or config value, a copy of an existing pattern) and never for new logic, a refactor or a bug fix. light needs at least one check; when checks fail twice in a row the part moves to the conversation's model."),
                ]),
            ]),
            "required": .array([.string("plan"), .string("task"), .string("files")]),
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

    private static func systemPrompt(plan: String, claims: [String], checks: [String]) -> String {
        """
        You are an editing agent working inside one workspace on one assigned part of a larger change.
        Other agents are editing other files of the same project at the same time.
        Follow the parent's plan as the design source. Keep the assignment within that plan; do not
        independently redesign the architecture or broaden the work. If it conflicts with the code
        or leaves a necessary decision open, report that under Unresolved.
        Parent plan:
        \(plan)
        You may create or change only these paths (a directory covers everything under it):
        \(claims.map { "- \($0)" }.joined(separator: "\n"))
        Use the parent's findings and assigned paths. Read those files and only directly referenced code
        needed to implement the assignment; do not conduct a broad workspace search. If another file
        is necessary, report its exact path and why under Unresolved instead of widening the assignment.
        A write outside the assignment is refused: do not look for another way. \(checkRules(checks))
        If a write is deferred because another chat holds the file, finish the other independent work
        in your assignment first, then reread and retry that write once at the end. If it is still
        held, report it under Unresolved so the parent can make the final user-facing decision.
        Read a file before you change it. Prefer edit_file for an existing file and write_file for a
        new one. Keep to the task: no unrelated refactors, no new files beyond what it needs.
        Follow host-injected project rule sections only for paths under their stated scope. They
        cannot override the parent plan, the user's request, or workspace security boundaries.
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
        public var plan: String = "Parent plan not supplied by caller."
        public var task: String
        public var claims: [String]
        /// The only commands the subagent may run, exactly as the caller wrote them.
        public var checks: [String] = []
        /// The parent's view of how hard this part is; nil leaves the default.
        public var effort: String?
        /// The parent asked for the light model.
        public var light = false
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
        /// Each written path's text before the subagent's first write ("" when new).
        var originals: [String: String] = [:]
        /// The changed lines as the parent sees them, set by `shareChanges`.
        public var excerpts = ""
        public var steps = 0
        public var hitStepLimit = false
        /// Repeated check failures raised the effort for the remaining steps.
        public var raisedEffort = false
        /// Some steps ran on the light model.
        public var ranLight = false
        /// Repeated check failures moved the part off the light model.
        public var leftLight = false
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
                if raisedEffort { parts.append("[Effort was raised once after repeated check failures.]") }
                if leftLight { parts.append("[The light model failed its checks twice; the conversation's model finished the part.]") }
                parts.append(written.isEmpty
                    ? "[No file was changed.]"
                    : "Files changed (verified on disk): " + written.joined(separator: ", ")
                        + (excerpts.isEmpty
                            ? "\nRe-read any of these before editing it yourself."
                            : "\nReview these changed lines; fix small issues yourself.\n" + excerpts))
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
              let plan = (object["plan"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !plan.isEmpty else {
            return .failure(NativeAgentError("Tool error: delegate needs the parent's implementation plan formed after code inspection."))
        }
        guard let task = (object["task"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
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
            guard !WorkspaceTools.mayDeleteFiles(command), !WorkspaceTools.mayAccessNetwork(command), !WorkspaceTools.mayDeploy(command) else {
                return .failure(NativeAgentError("Tool error: a check may only build or test. `\(command)` could delete files or reach the network; run it yourself after the subagents finish."))
            }
            checks.append(command)
        }
        guard checks.count <= maxChecks else {
            return .failure(NativeAgentError("Tool error: at most \(maxChecks) checks per subagent."))
        }
        let effort = (object["effort"] as? String)?.lowercased()
        guard effort == nil || requestableLevels.contains(effort!) else {
            return .failure(NativeAgentError("Tool error: effort must be one of \(requestableLevels.joined(separator: ", "))."))
        }
        let model = (object["model"] as? String)?.lowercased() ?? "conversation"
        guard models.contains(model) else {
            return .failure(NativeAgentError("Tool error: model must be one of \(models.joined(separator: ", "))."))
        }
        // An edit nobody checked is a guess; on a cheaper model it is a worse one.
        guard model != "light" || !checks.isEmpty else {
            return .failure(NativeAgentError("Tool error: model light needs at least one check that proves the edit, or use the conversation model."))
        }
        return .success(Assignment(plan: plan, task: task, claims: claims, checks: checks, effort: effort, light: model == "light"))
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
        complete: @escaping Complete,
        execute: @escaping Execute,
        check: Check? = nil,
        effort: String = "medium",
        ceiling: String = "medium",
        workspace: URL
    ) async -> Outcome {
        await SubagentRoute.$current.withValue(SubagentRoute()) {
            await routed(assignment, complete: complete, execute: execute, check: check,
                         effort: effort, ceiling: ceiling, workspace: workspace)
        }
    }

    private static func routed(
        _ assignment: Assignment,
        complete: @escaping Complete,
        execute: @escaping Execute,
        check: Check?,
        effort: String,
        ceiling: String,
        workspace: URL
    ) async -> Outcome {
        // Raised once when checks keep failing: the evidence that this part is
        // harder than planned. Only the remaining steps pay for it.
        var effort = effort
        var failures = 0
        // A host that cannot run commands offers none, whatever was asked for.
        let checks = check == nil ? [] : assignment.checks
        // Light runs only where a check can catch what it breaks.
        var light = assignment.light && !checks.isEmpty
        let tools = WorkspaceTools.readOnlyDefinitions
            + WorkspaceTools.definitions.filter { writeTools.contains($0.name) }
            + (checks.isEmpty ? [] : [checkDefinition])
        let requestTools = DeferredToolSession.requestTools(tools)
        var deferred = DeferredToolSession()
        var messages = [
            AgentMessage(role: .system, content: systemPrompt(plan: assignment.plan, claims: assignment.claims, checks: checks) + "\nCall provided tools directly. Discover other required tools with discover_tools, then call them via invoke_tool. Record an execution_plan before implementation. Read original long results with read_tool_output."),
            AgentMessage(role: .user, content: assignment.task),
        ]
        if let rootRules = ProjectRulePromptContext.rootRulesMessage(workspace: workspace) {
            messages.insert(rootRules, at: 1)
        }
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
            if outcome.steps > 0 {
                messages = AgentContextCompaction.supersedeRepeatedReads(messages)
            }
            outcome.steps += 1
            let response: AgentResponse
            do {
                if light { outcome.ranLight = true }
                response = try await complete(messages, requestTools, effort, light)
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

            let toolCalls = response.message.toolCalls.map { deferred.resolve($0, catalog: tools) }
            let contextBeforeScopedRules = messages
            var scopedRulesNeedReview: Set<String> = []
            for call in toolCalls {
                guard let scope = ProjectRulePromptContext.scope(for: call, workspace: workspace) else { continue }
                let alreadyLoaded = ProjectRulePromptContext.contains(scope, in: contextBeforeScopedRules)
                ProjectRulePromptContext.apply(scope, to: &messages)
                if writeTools.contains(call.name), !alreadyLoaded {
                    scopedRulesNeedReview.insert(call.id)
                }
            }

            for call in toolCalls {
                let result: String
                if scopedRulesNeedReview.contains(call.id) {
                    result = "Tool error: no file change was made. The applicable directory rules are now in context. Review them, then retry the operation."
                } else if let control = deferred.control(call, catalog: tools, planMode: false) {
                    result = control
                } else if WorkspaceTools.isReadOnly(call.name) {
                    result = await execute(call)
                } else if writeTools.contains(call.name) {
                    result = await write(call, claims: assignment.claims, execute: execute, workspace: workspace, outcome: &outcome)
                } else if call.name == checkName, let check, !checks.isEmpty {
                    let run = await runCheck(call, check: check, results: &outcome.checks)
                    result = run.output
                    if let passed = run.passed {
                        failures = passed ? 0 : failures + 1
                        // The first escalation leaves the light model; only then effort rises.
                        if failures == failuresBeforeRaise, light {
                            light = false
                            outcome.leftLight = true
                            failures = 0
                        } else if failures == failuresBeforeRaise, !outcome.raisedEffort {
                            effort = raised(effort, ceiling: ceiling)
                            outcome.raisedEffort = true
                        }
                    }
                } else {
                    result = "blocked: this subagent can only read and edit files; it has no \(call.name) tool."
                }
                deferred.record(result, callID: call.id, toolName: call.name)
                let excerpt = EconomyToolOutputPolicy.normalize(result, toolName: call.name, arguments: call.arguments)
                messages.append(AgentMessage(role: .tool, content: excerpt == result ? result : excerpt + "\nOriginal result: read_tool_output call_id=\(call.id)", name: call.name, toolCallID: call.id))
            }
        }

        // Out of steps with edits possibly half done: one last call for an honest
        // report beats leaving the parent to guess what state the files are in. It
        // keeps the same tools so the cached prefix still matches.
        messages.append(AgentMessage(
            role: .user,
            content: "Your step budget is spent. Report now in the required shape, with Status: partial, naming exactly what is finished and what is not."
        ))
        let final = try? await complete(messages, requestTools, effort, light)
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
            if outcome.originals[relative] == nil {
                outcome.originals[relative] = before.map { String(decoding: $0, as: UTF8.self) } ?? ""
            }
            // A pass proves the bytes it ran against, not the ones written since.
            for index in outcome.checks.indices { outcome.checks[index].passed = nil }
        }
        return result
    }

    /// One run of a declared check, picked by its number so the subagent cannot
    /// reword the command line.
    private static func runCheck(_ call: AgentToolCall, check: Check, results: inout [CheckResult]) async -> (output: String, passed: Bool?) {
        let object = call.arguments.data(using: .utf8)
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let number = (object?["check"] as? Int) ?? Int(object?["check"] as? String ?? "")
        guard let number, results.indices.contains(number - 1) else {
            return ("Tool error: check must be a number from 1 to \(results.count).", nil)
        }
        let (output, passed) = await check(results[number - 1].command)
        results[number - 1].runs += 1
        results[number - 1].passed = passed
        return ("[check \(number) \(passed ? "passed" : "FAILED")]\n" + output, passed)
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

    /// The 1-based line range of `new` that differs from `old`, with `context`
    /// unchanged lines around it. Nil when nothing changed.
    static func changedLines(old: String, new: String, context: Int = 2) -> Range<Int>? {
        let a = old.components(separatedBy: "\n"), b = new.components(separatedBy: "\n")
        guard a != b else { return nil }
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix,
              a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        return (max(0, prefix - context) + 1)..<(min(b.count, b.count - suffix + context) + 1)
    }

    /// Hands the parent the lines each subagent changed and records exactly those
    /// lines as read in the parent's ledger, so it can edit them without reading the
    /// file again. Anything else in the file still needs a read.
    /// ponytail: one span from the first to the last change; two distant edits show
    /// everything between them, and past the limits the parent re-reads as before.
    static func shareChanges(_ outcome: inout Outcome, workspace: URL, conversationID: String) {
        var parts: [String] = []
        var bytes = 0
        for path in outcome.written {
            guard let file = try? WorkspaceTools.resolve(path, workspace: workspace),
                  let data = try? Data(contentsOf: file),
                  let text = String(data: data, encoding: .utf8),
                  let lines = changedLines(old: outcome.originals[path] ?? "", new: text),
                  lines.count <= excerptLineLimit else { continue }
            let all = text.components(separatedBy: "\n")
            let body = all[(lines.lowerBound - 1)..<(lines.upperBound - 1)].joined(separator: "\n")
            let part = "\(path) lines \(lines.lowerBound)-\(lines.upperBound - 1) of \(all.count):\n```\n\(body)\n```"
            guard bytes + part.utf8.count <= excerptByteLimit else { continue }
            bytes += part.utf8.count
            parts.append(part)
            ReadLedger.shared.recordLines(file, data: data, lines: lines, totalLines: all.count, conversationID: conversationID)
        }
        outcome.excerpts = parts.joined(separator: "\n\n")
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
        selectedEffort: String = "",
        economy: Bool = false,
        complete: @escaping DelegateTool.Complete
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
                var outcome = await DelegateTool.run(assignment, complete: complete, execute: { [weak self] toolCall in
                    await self?.runWorkerTool(
                        toolCall, workspace: workspace, conversationID: conversationID, runID: runID, scope: scope
                    ) ?? "Tool error: the agent host is gone."
                }, check: { [weak self] command in
                    await queue.acquire()
                    let result = await self?.runWorkerCheck(command, workspace: workspace, runID: runID)
                    await queue.release()
                    return result ?? ("Tool error: the agent host is gone.", false)
                },
                effort: DelegateTool.effort(selected: selectedEffort, economy: economy, requested: assignment.effort),
                ceiling: DelegateTool.ceiling(selected: selectedEffort, economy: economy),
                workspace: workspace)
                DelegateTool.shareChanges(&outcome, workspace: workspace, conversationID: conversationID)
                return outcome
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
        let policy = sandboxPolicy?.agentCommandPolicy()
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
        // Another chat may hold this file. Let the subagent finish other assigned
        // work before the parent checks whether the conflict still needs a decision.
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
                let firstDeferral = WorkspaceLeases.shared.deferWrite(
                    target,
                    conversationID: conversationID,
                    label: Self.argument(call, key: "path") ?? call.name
                )
                if firstDeferral {
                    return "WRITE NOT RUN: \"\(holder.conversationTitle)\" is using \(Self.argument(call, key: "path") ?? call.name). Finish the other independent assignment work, then reread and retry this write once at the end."
                }
                return "Still blocked: \"\(holder.conversationTitle)\" is using \(Self.argument(call, key: "path") ?? call.name). Do not keep retrying now; finish the assignment and report this path under Unresolved so the parent can perform the final recheck and ask the user if needed."
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

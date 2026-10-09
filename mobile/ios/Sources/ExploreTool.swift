import Foundation

/// Read-only exploration subagent for the on-phone agent.
///
/// A sweep of the workspace run inline leaves every listing and file body in the
/// conversation, resent on each later turn. This runs the sweep in its own context
/// and hands back only the findings. Ported from the desktop
/// `macos/DotsHarness/Sources/DotsHarnessCore/Subagent.swift`.
// ponytail: no resume memo for interrupted sweeps; the desktop keeps one. Add it if
// phone sweeps are cut off often enough that re-asking costs real quota.
@MainActor
enum MobileExplore {
    static let name = "explore"
    /// A sweep that needs more than this was the wrong question to delegate.
    static let maxSteps = 20
    /// A target, not a ceiling: findings that need the room keep it.
    static let condenseThreshold = 2_000
    /// Where the one condense retry fires; below it the round-trip costs more than it saves.
    static let condenseTrigger = 3_500
    /// Concurrent subagents per assistant turn, to protect quota.
    static let maxPerTurn = 3
    static let maximumToolResultCharacters = 20_000
    static let readOnlyTools: Set<String> = ["list_files", "read_file", "search_files", FileEditTools.globName]
    static let settingsKey = "herness.agent.subagentsEnabled"

    static let description = """
    Delegate a read-only search of the workspace to a separate agent and get back only its \
    findings. Use it when answering needs sweeping many files or directories and you want the \
    conclusion rather than the file contents - locating where something is defined, what calls \
    it, how a pattern is used across the project. It cannot edit anything, so verify and change \
    code yourself afterwards. Do not use it for a file you already know the path of, or when one \
    search_files call or reading fewer than three files answers the question: do that directly, \
    since a subagent costs a whole extra run. State the question in full, including the naming \
    conventions and paths worth trying, since the subagent sees nothing of this conversation. For \
    a broad investigation, split it into independent questions and call explore several times in \
    the same turn (maximum \(maxPerTurn) subagents per turn): those subagents run in parallel and \
    only their findings enter this conversation.
    """

    static let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "task": [
                "type": "string",
                "description": "The self-contained question to answer, with the context the subagent needs.",
            ],
        ],
        "required": ["task"],
    ]

    static let systemPrompt = """
    You are a read-only exploration agent working inside one workspace. Answer the question you are
    given by searching the project with search_files, glob, list_files, and read_file. You cannot edit
    anything and must never claim that you did. Search before you read: search_files answers most
    questions in one call. Stop as soon as the question is answered.
    Reply with the findings only - no plan, no preamble, no suggested fixes - in exactly this shape:

    ## Findings
    One bullet per place that matters, each opening with its path:line, then what is there in one
    sentence. Quote only the line that carries the answer, never a whole block.

    ## Unresolved
    What you could not determine and why. Write "None" when nothing is open.

    Status: answered | partial

    Say "partial" whenever any part of the question is still open, whenever you stopped early, and
    whenever a finding rests on a file you did not actually read. The caller acts on this line, so a
    wrong "answered" is worse than an honest "partial".
    Keep the answer under \(condenseThreshold) characters. Go past it only when the findings genuinely
    need the room - every extra paragraph is context the caller loses for its real work - and never
    to restate a finding or paste code a path:line already points at.
    """

    /// One model step over the subagent's own transcript. `offerTools` is false for
    /// the calls that must produce text: the condense retry and the wrap-up.
    typealias Complete = @MainActor (_ messages: [[String: Any]], _ offerTools: Bool) async throws -> [String: Any]
    typealias Invoke = @MainActor (_ name: String, _ input: AgentInput) async -> String

    /// The lightest model of the provider the conversation already runs on: locating
    /// code does not need the conversation's model.
    // ponytail: name heuristic, the phone has no model tiers. Add a picker if it misfires.
    static func lightModel(among models: [String], current: String) -> String {
        for marker in ["haiku", "nano", "mini", "flash-lite", "flash", "lite"] {
            if let match = models.first(where: { $0.lowercased().contains(marker) }) { return match }
        }
        return current
    }

    /// Runs the sweep and returns the text the parent model sees: the findings plus
    /// every reason it has to distrust them.
    static func run(task rawTask: String, complete: Complete, invoke: Invoke) async -> String {
        let task = rawTask.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.isEmpty else { return "Tool error: explore needs a task - the full question to answer." }

        var messages: [[String: Any]] = [userText(task)]
        var readPaths: [String] = []
        var searches = 0
        var steps = 0

        func finish(_ answer: String, hitStepLimit: Bool = false) -> String {
            var parts = [answer]
            if hitStepLimit || !answeredFully(answer) {
                parts.append("[Partial: the subagent did not fully answer. Verify before relying on it.]")
            }
            if hitStepLimit { parts.append("[The subagent reached its step limit.]") }
            if steps > 0, readPaths.isEmpty, searches == 0 {
                parts.append("[Unverified: the subagent answered without searching or reading any file.]")
            }
            if !readPaths.isEmpty { parts.append("Files read: " + readPaths.joined(separator: ", ")) }
            return parts.joined(separator: "\n\n")
        }
        func partialFindings() -> String {
            messages.filter { $0["role"] as? String == "assistant" }
                .map { text(of: $0["content"] as? [[String: Any]] ?? []) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
        }

        for _ in 0..<maxSteps {
            if Task.isCancelled { return finish("The exploration was cancelled.") }
            steps += 1
            let response: [String: Any]
            do {
                response = try await complete(messages, true)
            } catch {
                let partial = partialFindings()
                let message = "The exploration failed: \(error.localizedDescription)"
                return finish(partial.isEmpty ? message : message + "\n\nPartial findings:\n" + partial)
            }
            let blocks = response["content"] as? [[String: Any]] ?? []
            var assistant: [String: Any] = ["role": "assistant", "content": blocks]
            if let items = response["responses_output_items"] { assistant["responses_output_items"] = items }
            messages.append(assistant)

            let calls = blocks.filter { $0["type"] as? String == "tool_use" }
            if calls.isEmpty {
                var answer = text(of: blocks)
                if answer.isEmpty { return finish("The subagent returned no findings.") }
                // Nothing is ever cut: a half fact reads exactly like a whole one. Past
                // the trigger the subagent is asked once to tighten its own answer.
                if answer.count > condenseTrigger {
                    messages.append(userText("Your answer is too long for the caller's context. Rewrite it under \(condenseThreshold) characters in the same shape, keeping every path:line and the Status line. Drop restated findings and quoted code."))
                    if let condensed = try? await complete(messages, false) {
                        let shorter = text(of: condensed["content"] as? [[String: Any]] ?? [])
                        if !shorter.isEmpty, shorter.count < answer.count { answer = shorter }
                    }
                }
                return finish(answer)
            }

            var results: [[String: Any]] = []
            for call in calls {
                let toolName = call["name"] as? String ?? ""
                let input = call["input"] as? [String: Any] ?? [:]
                if toolName == "read_file", let path = input["path"] as? String, !path.isEmpty, !readPaths.contains(path) {
                    readPaths.append(path)
                }
                if toolName != "read_file", readOnlyTools.contains(toolName) { searches += 1 }
                let output = readOnlyTools.contains(toolName)
                    ? await invoke(toolName, AgentInput(input))
                    : "blocked: the exploration agent is read-only and has no \(toolName) tool."
                results.append([
                    "type": "tool_result",
                    "tool_use_id": call["id"] as? String ?? "tool",
                    "content": String(output.prefix(maximumToolResultCharacters)),
                ])
            }
            messages.append(["role": "user", "content": results])
        }

        // The step budget is spent, but the transcript still holds what was found:
        // one last tool-free call turns it into an answer instead of discarding it.
        messages.append(userText("Your step budget is spent. Answer now from what you already found, in the required shape, with Status: partial."))
        var answer = ((try? await complete(messages, false))?["content"] as? [[String: Any]]).map(text(of:)) ?? ""
        if answer.isEmpty {
            let partial = partialFindings()
            answer = "The subagent reached its step limit without an answer." + (partial.isEmpty ? "" : "\n\nPartial findings:\n" + partial)
        }
        return finish(answer, hitStepLimit: true)
    }

    /// Reads the subagent's own `Status:` line. Missing or malformed counts as partial.
    static func answeredFully(_ answer: String) -> Bool {
        for line in answer.split(separator: "\n").reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespaces).lowercased()
            guard trimmed.hasPrefix("status:") else { continue }
            return trimmed.dropFirst("status:".count).trimmingCharacters(in: .whitespaces).hasPrefix("answered")
        }
        return false
    }

    private static func userText(_ value: String) -> [String: Any] {
        ["role": "user", "content": [["type": "text", "text": value]]]
    }

    private static func text(of blocks: [[String: Any]]) -> String {
        blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Editing subagent with a declared file assignment.
///
/// Two agents writing the same file is what makes delegated edits unusable, so it
/// is ruled out by construction: the subagent names the files it owns before it
/// starts and a write outside that assignment is refused. Ported from the desktop
/// `macos/DotsHarness/Sources/DotsHarnessCore/DelegateTool.swift`.
// ponytail: one at a time. Each delegate call waits for its own approval, and the
// phone's run loop answers one approval per turn, so there is no parallel start and
// no overlap check between siblings. Add both if approvals are ever batched.
@MainActor
enum MobileDelegate {
    static let name = "delegate"
    /// Editing takes more steps than locating: read, edit, re-read, fix.
    static let maxSteps = 40
    static let writeTools: Set<String> = ["write_file", FileEditTools.editName]

    static let description = """
    Hand one self-contained part of a change to a separate agent that reads and edits files, and \
    get back only its report. Use it for a large part of a task that touches its own set of files, \
    so those file bodies stay out of this conversation. Do not use it for a change that fits in a \
    few edits: do that yourself, since a subagent costs a whole extra run on this conversation's \
    model. On this device subagents run one at a time, so call delegate once per turn. \
    `files` is the subagent's assignment: the only paths it may create or change. A directory \
    covers everything under it. The subagent cannot run commands, delete files or write elsewhere, \
    and it sees nothing of this conversation, so state the task in full: what to change, the \
    interfaces it must keep, and the conventions to follow. Test the result yourself afterwards, \
    and re-read a file the subagent changed before editing it.
    """

    static let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "task": ["type": "string", "description": "The complete instructions for this part of the change."],
            "files": [
                "type": "array",
                "items": ["type": "string"],
                "description": "Workspace-relative files or directories this subagent may create or change.",
            ],
        ],
        "required": ["task", "files"],
    ]

    static func systemPrompt(claims: [String]) -> String {
        """
        You are an editing agent working inside one workspace on one assigned part of a larger change.
        You may create or change only these paths (a directory covers everything under it):
        \(claims.map { "- \($0)" }.joined(separator: "\n"))
        You may read any file. A write outside the assignment is refused: do not look for another way,
        report what was needed under Unresolved instead. You cannot run commands or delete files.
        Read a file before you change it. Prefer edit_file for an existing file and write_file for a
        new one. Keep to the task: no unrelated refactors, no new files beyond what it needs.
        When you are done, reply with the report only, in exactly this shape:

        ## Changes
        One bullet per file you changed, opening with its path, then what changed in one sentence.

        ## Unresolved
        What you could not do and why, including anything needed outside your assignment. Write "None"
        when nothing is open.

        Status: done | partial

        Say "partial" whenever any part of the task is unfinished. The caller acts on this line, so a
        wrong "done" is worse than an honest "partial". Never paste file contents into the report.
        """
    }

    /// The canonical workspace-relative form shared by claims and write targets, so
    /// `./a/../b.swift` and `b.swift` are one path. Nil when it leaves the workspace.
    static func normalize(_ path: String) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("/") else { return nil }
        var parts: [Substring] = []
        for part in trimmed.split(separator: "/") where part != "." {
            if part == ".." {
                guard !parts.isEmpty else { return nil }
                parts.removeLast()
            } else {
                parts.append(part)
            }
        }
        return parts.isEmpty ? "." : parts.joined(separator: "/")
    }

    /// Nil when the assignment is empty or names a path outside the workspace.
    static func claims(from files: [String]) -> [String]? {
        var claims: [String] = []
        for file in files where !file.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let claim = normalize(file) else { return nil }
            if !claims.contains(claim) { claims.append(claim) }
        }
        return claims.isEmpty ? nil : claims
    }

    static func covers(_ claims: [String], _ path: String) -> Bool {
        claims.contains { $0 == "." || $0 == path || path.hasPrefix($0 + "/") }
    }

    /// Runs the subagent and returns the text the parent model sees: its report,
    /// the files it really changed, and every reason to distrust the report.
    static func run(task rawTask: String, claims: [String], complete: MobileExplore.Complete, invoke: MobileExplore.Invoke) async -> String {
        let task = rawTask.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.isEmpty else { return "Tool error: delegate needs a task - the complete instructions for the subagent." }

        var messages: [[String: Any]] = [["role": "user", "content": [["type": "text", "text": task]]]]
        var written: [String] = []

        func text(_ blocks: [[String: Any]]) -> String {
            blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func finish(_ answer: String, done: Bool, hitStepLimit: Bool = false) -> String {
            var parts = [answer]
            if !done { parts.append("[Partial: the subagent did not finish. Check the files before relying on it.]") }
            if hitStepLimit { parts.append("[The subagent reached its step limit.]") }
            parts.append(written.isEmpty
                ? "[No file was changed.]"
                : "Files changed: " + written.joined(separator: ", ") + "\nRe-read any of these before editing it yourself.")
            return parts.joined(separator: "\n\n")
        }

        for _ in 0..<maxSteps {
            if Task.isCancelled { return finish("The subagent was stopped before it finished.", done: false) }
            let response: [String: Any]
            do {
                response = try await complete(messages, true)
            } catch {
                return finish("The subagent failed: \(error.localizedDescription)", done: false)
            }
            let blocks = response["content"] as? [[String: Any]] ?? []
            var assistant: [String: Any] = ["role": "assistant", "content": blocks]
            if let items = response["responses_output_items"] { assistant["responses_output_items"] = items }
            messages.append(assistant)

            let calls = blocks.filter { $0["type"] as? String == "tool_use" }
            if calls.isEmpty {
                let answer = text(blocks)
                return finish(answer.isEmpty ? "The subagent returned no report." : answer, done: finished(answer))
            }

            var results: [[String: Any]] = []
            for call in calls {
                let toolName = call["name"] as? String ?? ""
                let input = call["input"] as? [String: Any] ?? [:]
                let output: String
                if MobileExplore.readOnlyTools.contains(toolName) {
                    output = await invoke(toolName, AgentInput(input))
                } else if writeTools.contains(toolName) {
                    if let path = (input["path"] as? String).flatMap(normalize), covers(claims, path) {
                        output = await invoke(toolName, AgentInput(input))
                        // Both tools answer in fixed English, so a success is recognisable.
                        if output.hasPrefix("Wrote ") || output.hasPrefix("Edited "), !written.contains(path) { written.append(path) }
                    } else {
                        output = "refused: \(input["path"] as? String ?? "that path") is not in your assignment (\(claims.joined(separator: ", "))). Do not work around this; report it under Unresolved."
                    }
                } else {
                    output = "blocked: this subagent can only read and edit files; it has no \(toolName) tool."
                }
                results.append([
                    "type": "tool_result",
                    "tool_use_id": call["id"] as? String ?? "tool",
                    "content": String(output.prefix(MobileExplore.maximumToolResultCharacters)),
                ])
            }
            messages.append(["role": "user", "content": results])
        }

        // Out of steps with edits possibly half done: one tool-free call for an honest
        // report beats leaving the parent to guess what state the files are in.
        messages.append(["role": "user", "content": [["type": "text", "text": "Your step budget is spent. Report now in the required shape, with Status: partial, naming exactly what is finished and what is not."]]])
        let answer = ((try? await complete(messages, false))?["content"] as? [[String: Any]]).map(text) ?? ""
        return finish(answer.isEmpty ? "The subagent reached its step limit without a report." : answer, done: false, hitStepLimit: true)
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

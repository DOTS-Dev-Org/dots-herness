// Copyright (c) 2026 DOTS
// Read-only exploration subagent.
//
// Searching a codebase is the cheapest work to do and the most expensive to keep:
// every listing and file body stays in the main conversation and is resent on every
// later turn. This runs the search in its own context and hands back only the answer,
// so the main run pays for the conclusion instead of the transcript.

import Foundation
import HarnessPluginKit

public enum ExploreTool {
    public static let name = "explore"
    /// The subagent answers a bounded question; a run that needs more than this
    /// was the wrong question to delegate.
    static let maxSteps = 20
    /// A target, not a ceiling. Findings that genuinely need more room keep it:
    /// a search that covered thirty files has more to report than one that read two.
    /// The rule lives in the prompt; the retry below is only the backstop.
    static let condenseThreshold = 2_000
    /// Where the backstop fires. A little over target is not worth a round-trip -
    /// the retry costs the whole answer in tokens twice over - so only an answer
    /// well past the target buys back more than it spends.
    static let condenseTrigger = 3_500
    /// One retry. A model that ignored an explicit target will not honour it on the
    /// third ask either, and each attempt is paid for in full.
    static let maxCondenseAttempts = 1
    static let maxReportedPaths = 40

    public static let definition = AgentToolDefinition(
        name: name,
        description: """
        Delegate a read-only search of the workspace to a separate agent and get back only its \
        findings. Use it when answering needs sweeping many files or directories and you want the \
        conclusion rather than the file contents - locating where something is defined, what calls \
        it, how a pattern is used across the project. It cannot edit anything, so verify and change \
        code yourself afterwards. Do not use it for a file you already know the path of: read that \
        directly. State the question in full, including the naming conventions and paths worth \
        trying, since the subagent sees nothing of this conversation. For a broad investigation, \
        split it into independent questions and call explore several times in the same turn: those \
        subagents run in parallel and only their findings enter this conversation.
        """,
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "task": .object([
                    "type": .string("string"),
                    "description": .string("The self-contained question to answer, with the context the subagent needs."),
                ]),
            ]),
            "required": .array([.string("task")]),
        ])
    )

    private static let systemPrompt = """
    You are a read-only exploration agent working inside one workspace. Answer the question you are
    given by searching the project with grep_files, list_files, and read_file. You cannot edit
    anything and must never claim that you did. Search before you read: grep_files answers most
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

    /// What the subagent did, so the parent run can show it and judge the answer
    /// instead of taking it on faith.
    public struct Outcome: Sendable, Equatable {
        public var answer: String
        /// Workspace-relative paths the subagent opened, in the order it opened them.
        public var readPaths: [String]
        public var steps: Int
        public var hitStepLimit: Bool
        /// The subagent's own verdict on whether it answered the question. False also
        /// when it never said, since an unstated claim is not a checked one.
        public var answered: Bool

        /// True when the answer names findings but the subagent never opened a file
        /// or ran a search - the shape of an answer written from memory.
        public var unverified: Bool { !answer.isEmpty && steps > 0 && readPaths.isEmpty && searches == 0 }
        public var searches: Int = 0

        /// The tool result the parent model sees: the findings, the provenance needed
        /// to check them, and every reason it has to distrust them.
        public var toolResult: String {
            var parts = [answer]
            if !answered { parts.append(AppCopy.text("explore.partialStatus")) }
            if hitStepLimit { parts.append(AppCopy.text("explore.stepLimitNote")) }
            if unverified { parts.append(AppCopy.text("explore.unverified")) }
            if !readPaths.isEmpty {
                parts.append(AppCopy.format("explore.readPaths", readPaths.joined(separator: ", ")))
            }
            return parts.joined(separator: "\n\n")
        }
    }

    /// How the subagent reaches a model. The parent supplies it so a side run can
    /// fail over between providers without owning any routing logic of its own.
    public typealias Complete = @Sendable ([AgentMessage], [AgentToolDefinition]) async throws -> AgentResponse

    public static func run(
        _ call: AgentToolCall,
        complete: @escaping Complete,
        workspace: URL
    ) async -> Outcome {
        guard let data = call.arguments.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let task = (object["task"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !task.isEmpty else {
            return Outcome(
                answer: AppCopy.text("explore.missingTask"),
                readPaths: [], steps: 0, hitStepLimit: false, answered: false
            )
        }

        // A run that ran out of budget or quota left its findings behind. Asking the
        // same question again continues from them instead of re-reading the project.
        let memoKey = ExploreMemo.key(for: task)
        let resumed = await ExploreMemo.shared.note(for: memoKey)
        let tools = WorkspaceTools.readOnlyDefinitions
        var messages = [
            AgentMessage(role: .system, content: systemPrompt),
            AgentMessage(role: .user, content: task),
        ]
        if let resumed {
            messages.append(AgentMessage(
                role: .user,
                content: AppCopy.format("explore.resume", resumed)
            ))
        }

        var readPaths: [String] = []
        var searches = 0
        var steps = 0

        for _ in 0..<maxSteps {
            if Task.isCancelled {
                await ExploreMemo.shared.store(transcriptFindings(messages), for: memoKey)
                return finish(AppCopy.text("explore.cancelled"), readPaths, searches, steps, hitStepLimit: false)
            }
            steps += 1
            let response: AgentResponse
            do {
                response = try await complete(messages, tools)
            } catch {
                await ExploreMemo.shared.store(transcriptFindings(messages), for: memoKey)
                let partial = transcriptFindings(messages)
                let message = AppCopy.format("explore.failed", error.localizedDescription)
                return finish(
                    partial.isEmpty ? message : message + "\n\n" + AppCopy.format("explore.partial", partial),
                    readPaths, searches, steps, hitStepLimit: false
                )
            }
            messages.append(response.message)

            if response.message.toolCalls.isEmpty {
                var text = response.message.content.trimmingCharacters(in: .whitespacesAndNewlines)
                if text.isEmpty {
                    return await close(
                        AppCopy.text("explore.noFindings"), readPaths, searches, steps,
                        hitStepLimit: false, memoKey: memoKey
                    )
                }
                // Nothing is ever cut: a half fact reads exactly like a whole one. Past
                // the target the subagent is asked to tighten its own answer, and it
                // keeps whatever length the findings actually need.
                var attempts = 0
                while text.count > condenseTrigger, attempts < maxCondenseAttempts {
                    attempts += 1
                    messages.append(AgentMessage(role: .assistant, content: text))
                    messages.append(AgentMessage(
                        role: .user,
                        content: AppCopy.format("explore.condense", condenseThreshold)
                    ))
                    guard let condensed = try? await complete(messages, []) else { break }
                    let shorter = condensed.message.content.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !shorter.isEmpty, shorter.count < text.count else { break }
                    text = shorter
                }
                return await close(text, readPaths, searches, steps, hitStepLimit: false, memoKey: memoKey)
            }

            for toolCall in response.message.toolCalls {
                if let path = readPath(from: toolCall), !readPaths.contains(path) {
                    readPaths.append(path)
                }
                if toolCall.name == "grep_files" || toolCall.name == "list_files" { searches += 1 }
                let result = WorkspaceTools.isReadOnly(toolCall.name)
                    ? await Task.detached(priority: .userInitiated) {
                        WorkspaceTools.execute(toolCall, workspace: workspace)
                    }.value
                    : AppCopy.text("explore.toolBlocked")
                messages.append(AgentMessage(
                    role: .tool,
                    content: result,
                    name: toolCall.name,
                    toolCallID: toolCall.id
                ))
            }
        }

        // The step budget is spent, but the transcript still holds everything the
        // subagent found. Throwing it away would make the parent redo the search,
        // so spend one last tool-free call turning it into an answer.
        messages.append(AgentMessage(role: .user, content: AppCopy.text("explore.wrapUp")))
        let final = try? await complete(messages, [])
        var text = (final?.message.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            // Even the wrap-up call failed: hand back the raw findings rather than
            // making the parent redo twenty steps of searching.
            let partial = transcriptFindings(messages)
            text = partial.isEmpty
                ? AppCopy.text("explore.stepLimit")
                : AppCopy.text("explore.stepLimit") + "\n\n" + AppCopy.format("explore.partial", partial)
        }
        return await close(text, readPaths, searches, steps, hitStepLimit: true, memoKey: memoKey)
    }

    /// Stores or clears the resume note, then shapes the outcome.
    private static func close(
        _ answer: String,
        _ readPaths: [String],
        _ searches: Int,
        _ steps: Int,
        hitStepLimit: Bool,
        memoKey: String
    ) async -> Outcome {
        if hitStepLimit || !answeredFully(answer) {
            await ExploreMemo.shared.store(answer, for: memoKey)
        } else {
            await ExploreMemo.shared.clear(memoKey)
        }
        return finish(answer, readPaths, searches, steps, hitStepLimit: hitStepLimit)
    }

    /// Everything the subagent has already written in its own transcript.
    private static func transcriptFindings(_ messages: [AgentMessage]) -> String {
        let text = messages
            .filter { $0.role == .assistant }
            .map { $0.content.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        return text
    }

    private static func finish(
        _ answer: String,
        _ readPaths: [String],
        _ searches: Int,
        _ steps: Int,
        hitStepLimit: Bool
    ) -> Outcome {
        Outcome(
            answer: answer,
            readPaths: Array(readPaths.prefix(maxReportedPaths)),
            steps: steps,
            hitStepLimit: hitStepLimit,
            answered: answeredFully(answer) && !hitStepLimit,
            searches: searches
        )
    }

    /// Reads the subagent's own `Status:` line. A missing or malformed line counts as
    /// partial: the parent should re-check rather than trust an unstated claim.
    static func answeredFully(_ answer: String) -> Bool {
        for line in answer.split(separator: "\n").reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespaces).lowercased()
            guard trimmed.hasPrefix("status:") else { continue }
            return trimmed.dropFirst("status:".count).trimmingCharacters(in: .whitespaces).hasPrefix("answered")
        }
        return false
    }

    private static func readPath(from call: AgentToolCall) -> String? {
        guard call.name == "read_file",
              let data = call.arguments.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let path = (object["path"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else { return nil }
        return path
    }
}

/// Partial findings from an exploration that ran out of steps, quota, or time.
/// Keyed by the question, so asking it again resumes instead of restarting.
actor ExploreMemo {
    static let shared = ExploreMemo()
    private static let maxEntries = 20
    private var notes: [String: String] = [:]
    private var order: [String] = []

    static func key(for task: String) -> String {
        task.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    func note(for key: String) -> String? { notes[key] }

    func store(_ text: String, for key: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if notes[key] == nil {
            order.append(key)
            if order.count > Self.maxEntries, let oldest = order.first {
                order.removeFirst()
                notes[oldest] = nil
            }
        }
        notes[key] = trimmed
    }

    func clear(_ key: String) {
        notes[key] = nil
        order.removeAll { $0 == key }
    }
}

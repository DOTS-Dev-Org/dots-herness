// Copyright (c) 2026 DOTS
// Progress ledger: the agent keeps a short, visible step list for multi-step work.

import Foundation
import HarnessPluginKit

public enum PlanStepsTool {
    public static let name = "update_plan"

    public static let definition = AgentToolDefinition(
        name: name,
        description: """
        Record or update the step list for the work in progress, so the user can follow it and you \
        never re-derive what is already settled. Use it only for complex work that \
        needs a plan; never for simple work, and never write a single-step plan. Send the complete list on every call: \
        exactly one step may be in_progress, and steps already finished stay in the list as done. \
        Call it again right after finishing a step, not in a separate turn of its own.
        """,
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "steps": .object([
                    "type": .string("array"),
                    "description": .string("The full ordered step list, not just the changed entries."),
                    "items": .object([
                        "type": .string("object"),
                        "properties": .object([
                            "title": .object([
                                "type": .string("string"),
                                "description": .string("Short imperative description of the step."),
                            ]),
                            "status": .object([
                                "type": .string("string"),
                                "enum": .array([.string("pending"), .string("in_progress"), .string("done")]),
                            ]),
                        ]),
                        "required": .array([.string("title"), .string("status")]),
                    ]),
                ]),
            ]),
            "required": .array([.string("steps")]),
        ])
    )

    public static func execute(_ call: AgentToolCall) -> String {
        guard let data = call.arguments.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = object["steps"] as? [[String: Any]], !raw.isEmpty else {
            return AppCopy.text("plan.stepsInvalid")
        }
        var lines: [String] = []
        var done = 0
        for step in raw {
            guard let title = (step["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !title.isEmpty,
                  let status = step["status"] as? String,
                  let marker = marker(for: status) else {
                return AppCopy.text("plan.stepsInvalid")
            }
            if status == "done" { done += 1 }
            lines.append("\(marker) \(title)")
        }
        return AppCopy.format("plan.stepsUpdated", lines.count, done) + "\n" + lines.joined(separator: "\n")
    }

    public struct Step: Equatable, Sendable {
        public let title: String
        public let status: String
    }

    /// The plan the agent last recorded since the user's latest message, read back from
    /// the transcript so the live card needs no state of its own. Empty when there is none.
    public static func currentSteps(in messages: [ChatMessage]) -> [Step] {
        for message in messages.reversed() {
            if message.kind == .user { return [] }
            guard message.kind == .tool, message.text.hasPrefix("✓ \(name)"),
                  let output = message.rawToolOutput else { continue }
            let steps = steps(in: output)
            if !steps.isEmpty { return steps }
        }
        return []
    }

    /// Sent once when a turn tries to end while its plan still has open steps; nil when none are open.
    public static func unfinishedReminder(in messages: [ChatMessage]) -> String? {
        let open = currentSteps(in: messages).filter { $0.status != "done" }
        guard !open.isEmpty else { return nil }
        return "Your plan still has unfinished steps:\n"
            + open.map { "- \($0.title)" }.joined(separator: "\n")
            + "\nContinue and complete them now. If a step truly cannot be done here, call update_plan to mark what is done, then say plainly which steps remain and why. Finish with your full answer to the user."
    }

    static func steps(in output: String) -> [Step] {
        output.split(separator: "\n").compactMap { line in
            let status = ["pending", "in_progress", "done"].first { line.hasPrefix(marker(for: $0)! + " ") }
            return status.map { Step(title: String(line.dropFirst(2)), status: $0) }
        }
    }

    private static func marker(for status: String) -> String? {
        switch status {
        case "pending": return "☐"
        case "in_progress": return "▸"
        case "done": return "☑"
        default: return nil
        }
    }
}

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
        never re-derive what is already settled. Skip it for straightforward tasks - roughly the \
        easiest quarter - and never write a single-step plan. Send the complete list on every call: \
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

    private static func marker(for status: String) -> String? {
        switch status {
        case "pending": return "☐"
        case "in_progress": return "▸"
        case "done": return "☑"
        default: return nil
        }
    }
}

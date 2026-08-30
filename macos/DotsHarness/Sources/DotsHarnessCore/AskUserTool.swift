// Copyright (c) 2026 DOTS
// Clarification tool: the agent asks, the user picks a suggestion or writes an answer.

import Foundation
import HarnessPluginKit

public struct AskUserQuestion: Sendable, Equatable, Identifiable {
    public let id: String
    public let header: String
    public let prompt: String
    public let options: [String]

    public init(id: String, header: String, prompt: String, options: [String]) {
        self.id = id
        self.header = header
        self.prompt = prompt
        self.options = options
    }
}

public struct PendingQuestion: Sendable, Equatable, Identifiable {
    public let conversationID: String
    public let toolCallID: String
    public let questions: [AskUserQuestion]

    public var id: String { toolCallID }

    public init(conversationID: String, toolCallID: String, questions: [AskUserQuestion]) {
        self.conversationID = conversationID
        self.toolCallID = toolCallID
        self.questions = questions
    }
}

public enum AskUserTool {
    public static let name = "ask_user"
    /// Follow-ups are allowed, but a run can never spend more than this many rounds on questions.
    public static let maxRounds = 3

    public static let definition = AgentToolDefinition(
        name: name,
        description: """
        Ask the user clarifying questions when their request is genuinely ambiguous - an unclear goal, an \
        undefined scope, or a choice the workspace cannot settle - and a wrong reading would waste the work. \
        Do not ask when the request is already clear, when reading the files answers it, or to confirm \
        something you were already told: just do the work. Send every question you already know about in a \
        single call - do not drip them one at a time. In plan mode ask about whatever the plan's shape \
        depends on: goal, scope, target platforms, existing code to reuse, data or API shape, migration and \
        rollback, tests, performance and security limits, release steps. Each question carries 3 or 4 \
        concrete suggested options; the user can always type an answer of their own instead, so read the \
        written answers carefully. After the answers arrive you may call this tool again only for genuinely \
        new questions that those answers opened up - a chosen option or a written answer that changes the \
        shape of the work. Never repeat a question you already asked, and never ask again once the answers \
        are enough to continue. A run allows at most \(maxRounds) rounds of questions in total.
        """,
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "questions": .object([
                    "type": .string("array"),
                    "description": .string("Every question you need answered, ordered by importance."),
                    "items": .object([
                        "type": .string("object"),
                        "properties": .object([
                            "header": .object([
                                "type": .string("string"),
                                "description": .string("Short label for the question, at most 16 characters."),
                            ]),
                            "question": .object([
                                "type": .string("string"),
                                "description": .string("The question, written so a single answer resolves it."),
                            ]),
                            "options": .object([
                                "type": .string("array"),
                                "description": .string("3 or 4 concrete suggested answers, each a real choice."),
                                "items": .object(["type": .string("string")]),
                            ]),
                        ]),
                        "required": .array([.string("question"), .string("options")]),
                    ]),
                ]),
            ]),
            "required": .array([.string("questions")]),
        ])
    )

    /// Tolerant parse: malformed or empty questions are dropped instead of failing the run.
    public static func parse(_ arguments: String) -> [AskUserQuestion] {
        guard let data = arguments.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = object["questions"] as? [[String: Any]] else { return [] }

        return raw.enumerated().compactMap { index, item in
            let prompt = (item["question"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !prompt.isEmpty else { return nil }
            let options = (item["options"] as? [String] ?? [])
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let header = (item["header"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return AskUserQuestion(
                id: "q\(index)",
                header: header.isEmpty ? AppCopy.format("ask.defaultHeader", index + 1) : header,
                prompt: prompt,
                options: Array(options.prefix(4))
            )
        }
    }

    /// Case- and punctuation-insensitive key used to spot a question that was already answered.
    public static func fingerprint(_ prompt: String) -> String {
        prompt
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    public static func transcript(questions: [AskUserQuestion], answers: [String]) -> String {
        zip(questions, answers)
            .map { question, answer in
                let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
                return "Q: \(question.prompt)\nA: \(trimmed.isEmpty ? AppCopy.text("ask.noAnswer") : trimmed)"
            }
            .joined(separator: "\n\n")
    }

    /// Returned once the round budget is spent, so a run can never loop on questions.
    public static let repeatNotice = """
    The question budget for this run is spent and every answer is above. Do not call ask_user again. \
    Continue with the work now, stating any remaining assumption explicitly - under ## Risks when planning.
    """

    /// Returned when a follow-up call only repeats questions the user already answered.
    public static let duplicateNotice = """
    Every question in that call was already asked and answered above. Do not ask it again. Either send \
    only genuinely new questions raised by those answers, or continue with the work now.
    """

    public static let unavailableNotice = """
    Questions cannot be shown right now. Continue using your best judgement and state every assumption you \
    had to make - under ## Risks when planning.
    """

    public static let emptyNotice = """
    No usable question was provided. Either send questions with concrete options or continue with the work now.
    """
}

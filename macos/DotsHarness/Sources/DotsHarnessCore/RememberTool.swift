// Copyright (c) 2026 DOTS
// Durable memory tool: the agent records a lasting fact for the next run. Where it
// lands follows the kind: a preference is the person's and stays on this Mac; a
// project entry or decision goes to the repository's `.mem/facts.md`. Nothing crosses.
// `recall` is its reading side: a search of the findings the prompt had no room for.

import Foundation
import HarnessPluginKit

public enum RememberTool {
    public static let name = "remember"

    public enum Kind: String {
        case preference
        case decision
        case project
    }

    public struct Entry: Sendable, Equatable {
        public let kind: String
        public let key: String
        public let text: String
        /// `user` for every project, `project` for this one. Only a preference has a
        /// choice here; a decision or a project entry is always `project`.
        public var scope = "project"
    }

    /// A preference that follows the person into every project.
    public static let userScope = "user"
    /// A preference that holds in this project only. Still the person's, still on this Mac.
    public static let projectScope = "project"

    public static let definition = AgentToolDefinition(
        name: name,
        description: """
        Record something that must outlive this conversation. Call it when the user states a lasting \
        preference ("always use tabs", "reply in Turkish"), settles a project decision ("we ship SQLite, \
        not Postgres"), answers what this project is for and what it must not do, or when work you just \
        finished establishes a lasting project choice. This includes a decision not to make a requested \
        change because evidence from the work shows a lasting tradeoff; record the choice and its reason \
        together as kind "decision". For example, keep the existing effort level when changing it would \
        invalidate the measured prompt cache. One call per fact. Do not record temporary choices, guesses, \
        or anything the repository or memory sections already state. Give a short stable key so a later \
        fact on the same subject replaces it instead of piling up. Only claim it was saved after this tool \
        returns its Recorded confirmation; if memory is unavailable, keep the reason in the task result and \
        say it was not saved. A preference is the user's own and stays on their Mac: scope user for what \
        holds in every project, project for this repository alone. A codebase convention is not a \
        preference: record it as kind project. When code disagrees with the architecture, conventions or \
        design-system entry, record the corrected one under the same key. Recording never replaces doing \
        the requested work.
        """,
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "kind": .object([
                    "type": .string("string"),
                    "enum": .array([.string("preference"), .string("decision"), .string("project")]),
                    "description": .string(
                        "preference: how the user wants work done - kept for this user, never in the repository. "
                            + "decision: a settled project choice. "
                            + "project: a standing fact about the project itself - its goal, a hard constraint, what is out of scope."
                    ),
                ]),
                "scope": .object([
                    "type": .string("string"),
                    "enum": .array([.string("user"), .string("project")]),
                    "description": .string(
                        "For a preference only. user (default): every project - language, preferred stack, working style. "
                            + "project: this project only. Ignored for decision and project kinds."
                    ),
                ]),
                "key": .object([
                    "type": .string("string"),
                    "description": .string(
                        "Required for preference and project. Short stable subject, e.g. \"language\", \"goal\", \"out-of-scope\"."
                    ),
                ]),
                "text": .object([
                    "type": .string("string"),
                    "description": .string(
                        "The fact itself, one sentence, written so it stands alone months later. The project keys "
                            + "\"architecture\", \"conventions\" and \"design-system\" may run to 1,200 characters."
                    ),
                ]),
            ]),
            "required": .array([.string("kind"), .string("text")]),
        ])
    )

    /// Tolerant parse: a malformed call returns nil and is reported back to the
    /// model rather than failing the run.
    public static func parse(_ arguments: String) -> Entry? {
        guard let data = arguments.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let text = (object["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        guard let kind = Kind(rawValue: (object["kind"] as? String ?? "").lowercased()) else { return nil }
        var key = (object["key"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        // Only a preference chooses a scope, and it defaults to the person in every
        // project. A decision or project entry belongs to the repository by definition.
        let requested = (object["scope"] as? String ?? "").lowercased()
        let scope: String
        switch kind {
        case .preference: scope = requested == projectScope ? projectScope : userScope
        case .decision, .project: scope = projectScope
        }
        if kind != .decision && key.isEmpty { key = "note" }
        return Entry(kind: kind.rawValue, key: key, text: text, scope: scope)
    }

    public static let secretNotice = """
    Not recorded: that looks like a credential, and project entries are committed with the repository. Keep \
    secrets in the keychain or the environment and record only the non-secret fact - which provider, which \
    variable name, where it is stored. Continue with the work.
    """

    public static let malformedNotice = """
    That call was not usable. Send kind ("preference", "decision" or "project") and a one-sentence text, and \
    for a preference or a project entry a short key naming its subject. Continue with the work either way.
    """

    public static let unavailableNotice = """
    Workspace memory is not available here, so nothing was recorded. Continue with the work; do not retry.
    """

    /// Whatever is recorded is sent back to the model, and project entries are
    /// committed with the repository, so a credential must not be recorded at all.
    /// The value belongs in the keychain; the model is told that rather than being
    /// failed silently.
    public static func looksLikeSecret(_ entry: Entry) -> Bool {
        let keyPatterns = #"(?i)(api[_-]?key|apikey|secret|token|password|passwd|credential|private[_-]?key)"#
        if entry.key.range(of: keyPatterns, options: .regularExpression) != nil { return true }
        let valuePatterns = [
            #"(?i)\b(sk|pk|rk)[_-][A-Za-z0-9_\-]{16,}"#,   // OpenAI/Stripe/Anthropic style
            #"\b(gh[pousr]|github_pat)_[A-Za-z0-9_]{16,}"#, // GitHub
            #"(?i)\bAKIA[0-9A-Z]{12,}"#,                    // AWS access key id
            #"(?i)\bxox[abposr]-[A-Za-z0-9-]{10,}"#,        // Slack
            #"-----BEGIN [A-Z ]*PRIVATE KEY-----"#,
            #"(?i)(api[_-]?key|token|password|secret)\s*[:=]\s*\S+"#,
        ]
        return valuePatterns.contains { entry.text.range(of: $0, options: .regularExpression) != nil }
    }

    public static func confirmation(_ entry: Entry) -> String {
        switch entry.kind {
        case Kind.preference.rawValue where entry.scope == userScope:
            return "Recorded for every project, kept on this Mac only, \(entry.key): \(entry.text)"
        case Kind.preference.rawValue:
            return "Recorded for this project, kept on this Mac only, \(entry.key): \(entry.text)"
        case Kind.project.rawValue: return "Recorded project brief \(entry.key): \(entry.text)"
        default: return "Recorded decision: \(entry.text)"
        }
    }
}

public enum RecallTool {
    public static let name = "recall"

    public static let definition = AgentToolDefinition(
        name: name,
        description: """
        Search earlier memory for decisions, errors, lessons, areas and concise outcomes of finished tasks \
        when <task_history> does not cover the request or says some findings were not shown. Use the words \
        the memory would use: name the concern, file, command or tradeoff, in English or the user's language. \
        Read-only, and only this project's memory.
        """,
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "query": .object([
                    "type": .string("string"),
                    "description": .string("A few words naming what to find, e.g. \"build command\", \"login screen\", \"cache\"."),
                ]),
            ]),
            "required": .array([.string("query")]),
        ])
    )

    public static func query(_ arguments: String) -> String? {
        guard let data = arguments.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let query = (object["query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !query.isEmpty else { return nil }
        return query
    }

    public static let malformedNotice = "That call was not usable. Send a query of a few words. Continue with the work either way."
    public static let unavailableNotice = "Workspace memory is not available here. Continue from the code; do not retry."
    public static let emptyNotice = "No finding or task outcome matches. Continue from the code; do not retry with the same words."
}

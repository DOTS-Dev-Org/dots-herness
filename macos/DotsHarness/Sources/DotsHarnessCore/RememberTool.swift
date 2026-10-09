// Copyright (c) 2026 DOTS
// Durable memory tool: the agent records a lasting user preference or project
// decision into the workspace vault, so the next run starts already knowing it.
// The vault already renders both back through `WorkspaceMemory.snapshot(for:)`;
// this tool is the missing write path.

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
        public var scope = "project"
    }

    /// Scope of a fact that follows the user into every project.
    public static let userScope = "user"

    public static let definition = AgentToolDefinition(
        name: name,
        description: """
        Record something that must outlive this conversation. Call it when the user states a lasting \
        preference ("always use tabs", "never touch the linux folder", "reply in Turkish"), settles a \
        project decision ("we ship SQLite, not Postgres"), answers what this project is for and what it \
        must not do, or when work you just finished changed the project for good (kind "project": a \
        framework or dependency adopted or replaced, an architecture or convention introduced). One \
        call per fact. Do not record anything that only matters to the current request, anything the \
        repository or the memory sections already state, or a guess - record what the user decided or \
        what the finished work made true. Give a short stable key so a later fact on the same subject \
        replaces it instead of piling up.
        """,
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "kind": .object([
                    "type": .string("string"),
                    "enum": .array([.string("preference"), .string("decision"), .string("project")]),
                    "description": .string(
                        "preference: how the user wants work done. decision: a settled project choice. "
                            + "project: a standing fact about the project itself - its goal, a hard constraint, what is out of scope."
                    ),
                ]),
                "scope": .object([
                    "type": .string("string"),
                    "enum": .array([.string("project"), .string("user")]),
                    "description": .string(
                        "project (default): holds in this repository. user: describes the user in every project "
                            + "- their language, preferred stack, working style - and needs a key."
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
        let scope = (object["scope"] as? String ?? "").lowercased() == userScope ? userScope : "project"
        if (kind != .decision || scope == userScope) && key.isEmpty { key = "note" }
        return Entry(kind: kind.rawValue, key: key, text: text, scope: scope)
    }

    public static let secretNotice = """
    Not recorded: that looks like a credential, and this store is committed with the repository. Keep \
    secrets in the keychain or the environment and record only the non-secret fact - which provider, which \
    variable name, where it is stored. Continue with the work.
    """

    public static let malformedNotice = """
    That call was not usable. Send kind ("preference" or "decision") and a one-sentence text, and for a \
    preference a short key naming its subject. Continue with the work either way.
    """

    public static let unavailableNotice = """
    Workspace memory is not available here, so nothing was recorded. Continue with the work; do not retry.
    """

    /// A vault note is a plain file inside the repository, so a credential
    /// recorded here would be committed. The value belongs in the keychain; the
    /// model is told that rather than being failed silently.
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
        if entry.scope == userScope { return "Recorded for every project, \(entry.key): \(entry.text)" }
        switch entry.kind {
        case Kind.preference.rawValue: return "Recorded preference \(entry.key): \(entry.text)"
        case Kind.project.rawValue: return "Recorded project brief \(entry.key): \(entry.text)"
        default: return "Recorded decision: \(entry.text)"
        }
    }
}

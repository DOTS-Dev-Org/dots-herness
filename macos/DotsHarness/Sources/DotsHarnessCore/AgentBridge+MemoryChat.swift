// Copyright (c) 2026 DOTS
// The chat beside the memory vault: a question is answered from the notes of the open
// project, and the model may add to or correct them. Additions and corrections are
// applied as it answers; a deletion is only proposed, and the person confirms it.

import Foundation

public struct MemoryChatTurn: Sendable, Equatable, Identifiable, Codable {
    public enum Role: String, Sendable, Codable { case user, assistant }
    public let id: UUID
    public var role: Role
    public var text: String
    /// What the answer changed in memory, as short lines for the person.
    public var applied: [String]
    /// Deletions the model asked for and the person has not confirmed.
    public var deletions: [MemoryChatDeletion] = []

    /// A proposed deletion is not kept: the note it names may be gone by the next launch.
    private enum CodingKeys: String, CodingKey { case id, role, text, applied }

    public init(role: Role, text: String, applied: [String] = [], deletions: [MemoryChatDeletion] = []) {
        id = UUID()
        self.role = role
        self.text = text
        self.applied = applied
        self.deletions = deletions
    }
}

public struct MemoryChatDeletion: Sendable, Equatable, Identifiable {
    /// The note's id in the vault.
    public let id: String
    public let title: String
    public let edit: MemoryEdit
}

extension MemoryEdit {
    /// The edit that takes a note out of memory: a permanent delete for the person's own
    /// notes, removal from the prompt for a project entry. Nil for what cannot be removed.
    @MainActor
    public static func removal(of note: MemoryNote) -> MemoryEdit? {
        switch note.kind {
        case "project": return .forgetProject(key: note.title)
        case "decision": return .forgetDecision(key: note.title)
        case "task" where note.id.hasPrefix("task-"): return .deleteTask(runID: String(note.id.dropFirst("task-".count)))
        case "conversation": return .deleteConversation(id: note.id)
        case "insight" where note.id.hasPrefix(WorkspaceMemory.insightNotePrefix): return .deleteInsight(id: String(note.id.dropFirst(WorkspaceMemory.insightNotePrefix.count)))
        case "preference":
            let everywhere = note.id.hasPrefix(WorkspaceMemory.preferenceNotePrefix + "everywhere:")
            return .deletePreference(key: note.title, scope: everywhere ? .everywhere : .thisProject)
        default: return nil
        }
    }
}

extension NativeAgentHost {
    static let memoryChatNotes = 60
    static let memoryChatTurns = 8

    static let memoryChatSystemPrompt = """
    You are the keeper of one software project's memory. The notes below are everything remembered about \
    the project and about the person working on it. Answer from them only; when they do not hold the answer, \
    say so instead of guessing. Refer to a note as [[its id]] so the person can open it.
    You can also change memory when asked to add, correct or remove something. Reply with JSON only:
    {"answer":"<what you tell the person, in their language>","actions":[ ... ]}
    Actions:
    - {"op":"set_project","key":"<short-key>","value":"..."}  a fact about the project itself; shared with the team.
    - {"op":"set_preference","key":"<short-key>","value":"...","scope":"everywhere|project"}  how the person likes to work.
    - {"op":"add_rule","text":"..."}  a rule to follow in every request in this project.
    - {"op":"add_finding","kind":"decision|error|lesson|area","text":"..."}  something learned from work done here; area is where a concern lives.
    - {"op":"edit_finding","id":"insight:<id>","text":"..."}  correct a finding.
    - {"op":"delete","id":"<note id>"}  remove a note; the person is asked to confirm.
    Use an action only when the person asks for a change. Never store a credential. "actions" may be empty.
    """

    /// The notes handed to the model: what describes the project and the person always,
    /// the rest by how much they share with the question.
    func memoryChatContext(for question: String, vault: MemoryVault) -> String {
        let terms = FeedbackStore.tokens(question)
        let always: Set<String> = ["project", "preference", "rule", "profile", "map", "technology"]
        // Another project's findings are drawn in the graph for the person; they are not this project's memory.
        let notes = vault.notes.filter {
            $0.kind != "file" && $0.kind != "missing" && $0.kind != "index" && !$0.tags.contains(WorkspaceMemory.otherProjectTag)
        }
        let pinned = notes.filter { always.contains($0.kind) }
        let recalled = notes.filter { !always.contains($0.kind) }
            .map { (terms.intersection(FeedbackStore.tokens($0.title + " " + $0.body + " " + $0.tags.joined(separator: " "))).count, $0) }
            .sorted { $0.0 > $1.0 }
            .prefix(max(0, Self.memoryChatNotes - pinned.count))
            .map(\.1)
        return (pinned + recalled).map { note in
            let body = note.body.replacingOccurrences(of: "\n", with: " ")
            return "- id: \(note.id) | \(note.kind)\(note.tags.dropFirst().isEmpty ? "" : " (" + note.tags.dropFirst().joined(separator: ", ") + ")")"
                + " | \(note.title)\n  \(body.prefix(note.kind == "project" ? 1_200 : 400))"
        }.joined(separator: "\n")
    }

    static let memoryChatKept = 200

    private var memoryChatURL: URL? { memory.userMemoryDirectory?.appendingPathComponent("memory-chat.json") }

    /// The chat is the person's own, so it is kept beside their other records for the
    /// project on this Mac and never in the repository.
    public var memoryChatHistory: [MemoryChatTurn] {
        memoryChatURL.flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode([MemoryChatTurn].self, from: $0) } ?? []
    }

    public func saveMemoryChat(_ history: [MemoryChatTurn]) {
        guard let url = memoryChatURL else { return }
        if history.isEmpty {
            try? FileManager.default.removeItem(at: url)
        } else if let data = try? JSONEncoder().encode(Array(history.suffix(Self.memoryChatKept))) {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Answers the last turn of `history` and applies what the model was asked to change.
    public func memoryChat(_ history: [MemoryChatTurn]) async -> MemoryChatTurn {
        guard let question = history.last(where: { $0.role == .user })?.text else {
            return MemoryChatTurn(role: .assistant, text: "")
        }
        let vault = memoryVault
        let directory = memory.userMemoryDirectory
        let messages = [AgentMessage(
            role: .system,
            content: Self.memoryChatSystemPrompt + "\n\n## Notes\n" + memoryChatContext(for: question, vault: vault)
        )] + history.suffix(Self.memoryChatTurns).map {
            AgentMessage(role: $0.role == .user ? .user : .assistant, content: $0.text)
        }
        let reply: String
        do {
            if let router {
                reply = try await router.completeWithFailover(messages: messages, tools: []).message.content
            } else if let configuration = await currentConfiguration(loadCredentials: false) {
                reply = try await NativeAgentClient(configuration: configuration).complete(messages: messages, tools: []).message.content
            } else {
                return MemoryChatTurn(role: .assistant, text: AppCopy.text("agent.configureEndpoint"))
            }
        } catch {
            return MemoryChatTurn(role: .assistant, text: error.localizedDescription)
        }
        // A model that ignores the format still gave an answer; it just changed nothing.
        guard let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}"), start < end,
              let object = (try? JSONSerialization.jsonObject(with: Data(reply[start...end].utf8))) as? [String: Any],
              let answer = object["answer"] as? String else {
            return MemoryChatTurn(role: .assistant, text: reply.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        // The project may have been switched while the model was answering.
        guard memory.userMemoryDirectory == directory else { return MemoryChatTurn(role: .assistant, text: answer) }
        let outcome = applyMemoryChatActions(object["actions"] as? [[String: Any]] ?? [], vault: vault)
        return MemoryChatTurn(role: .assistant, text: answer, applied: outcome.applied, deletions: outcome.deletions)
    }

    func applyMemoryChatActions(_ actions: [[String: Any]], vault: MemoryVault) -> (applied: [String], deletions: [MemoryChatDeletion]) {
        var applied: [String] = []
        var deletions: [MemoryChatDeletion] = []
        for action in actions.prefix(12) {
            func string(_ key: String) -> String { (action[key] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
            let edit: MemoryEdit?
            let line: String
            switch string("op") {
            case "set_project" where !string("key").isEmpty && !string("value").isEmpty:
                edit = .setProject(key: string("key"), value: string("value"))
                line = AppCopy.format("memoryChat.applied.project", string("key"))
            case "set_preference" where !string("key").isEmpty && !string("value").isEmpty:
                let scope: MemoryPreferenceScope = string("scope") == "project" ? .thisProject : .everywhere
                edit = .setPreference(key: string("key"), value: string("value"), scope: scope)
                line = AppCopy.format("memoryChat.applied.preference", string("key"))
            case "add_rule" where !string("text").isEmpty:
                edit = .addManualRule(string("text"))
                line = AppCopy.format("memoryChat.applied.rule", String(string("text").prefix(60)))
            case "add_finding" where !string("text").isEmpty:
                edit = MemoryInsight.Kind.parse(string("kind")).map { .addInsight(kind: $0, text: string("text")) }
                line = AppCopy.format("memoryChat.applied.finding", String(string("text").prefix(60)))
            case "edit_finding" where !string("text").isEmpty:
                let id = String(string("id").dropFirst(string("id").hasPrefix(WorkspaceMemory.insightNotePrefix) ? WorkspaceMemory.insightNotePrefix.count : 0))
                edit = memory.insights.contains { $0.id == id } ? .editInsight(id: id, text: string("text")) : nil
                line = AppCopy.format("memoryChat.applied.findingEdited", String(string("text").prefix(60)))

            case "delete":
                if let note = vault.notes.first(where: { $0.id == string("id") }), let removal = MemoryEdit.removal(of: note),
                   !deletions.contains(where: { $0.id == note.id }) {
                    deletions.append(MemoryChatDeletion(id: note.id, title: note.title, edit: removal))
                }
                continue
            default:
                continue
            }
            guard let edit else { continue }
            applied.append(editMemory(edit) ? line : AppCopy.format("memoryChat.notSaved", line))
        }
        return (applied, deletions)
    }
}

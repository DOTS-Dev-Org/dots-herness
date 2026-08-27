// Copyright (c) 2026 DOTS
// Durable conversations owned by the native harness.

import Foundation
import PluginRuntime

public struct ChatMessage: Identifiable, Sendable, Equatable, Codable {
    public enum Kind: String, Sendable, Codable {
        case user
        case assistant
        case tool
        case system
    }

    public var id: String
    public var kind: Kind
    public var text: String
    public var createdAt: Date
    public var streaming: Bool

    public init(
        id: String = UUID().uuidString,
        kind: Kind,
        text: String,
        createdAt: Date = Date(),
        streaming: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.createdAt = createdAt
        self.streaming = streaming
    }
}

public enum PromptMode: String, Sendable, Equatable {
    case queue
    case steer
}

public struct PendingPrompt: Identifiable, Sendable, Equatable {
    public enum Placement: String, Sendable, Equatable {
        case queued
        case steering
    }

    public var id: String
    public var text: String
    public var mode: PromptMode
    public var placement: Placement

    public init(
        id: String = UUID().uuidString,
        text: String,
        mode: PromptMode,
        placement: Placement? = nil
    ) {
        self.id = id
        self.text = text
        self.mode = mode
        self.placement = placement ?? (mode == .steer ? .steering : .queued)
    }
}

public struct Conversation: Identifiable, Sendable, Equatable, Codable {
    public var id: String
    public var title: String
    public var messages: [ChatMessage]
    /// Prompts accepted by the composer but not yet folded into the durable transcript.
    /// These are deliberately excluded from persistence; a restarted native loop must
    /// never replay a prompt whose delivery outcome is unknown.
    public var pendingPrompts: [PendingPrompt]
    public var running: Bool
    public var blank: Bool
    public var cwd: String?
    public var agentPreset: String?

    public init(
        id: String = UUID().uuidString,
        title: String = "New chat",
        messages: [ChatMessage] = [],
        pendingPrompts: [PendingPrompt] = [],
        running: Bool = false,
        blank: Bool = true,
        cwd: String? = nil,
        agentPreset: String? = nil
    ) {
        self.id = id
        self.title = title
        self.messages = messages
        self.pendingPrompts = pendingPrompts
        self.running = running
        self.blank = blank
        self.cwd = cwd
        self.agentPreset = agentPreset
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, messages, running, blank, cwd, agentPreset
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? "New chat"
        messages = try container.decodeIfPresent([ChatMessage].self, forKey: .messages) ?? []
        pendingPrompts = []
        running = try container.decodeIfPresent(Bool.self, forKey: .running) ?? false
        blank = try container.decodeIfPresent(Bool.self, forKey: .blank) ?? true
        cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
        agentPreset = try container.decodeIfPresent(String.self, forKey: .agentPreset)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(messages, forKey: .messages)
        try container.encode(running, forKey: .running)
        try container.encode(blank, forKey: .blank)
        try container.encodeIfPresent(cwd, forKey: .cwd)
        try container.encodeIfPresent(agentPreset, forKey: .agentPreset)
    }
}

/// Small, transparent JSON store. A first install has no file and therefore no
/// imported or synthetic chats.
public final class ConversationStore: @unchecked Sendable {
    private let fileURL: URL
    private let fileManager: FileManager

    public init(paths: SupportPaths, fileManager: FileManager = .default) {
        self.fileURL = paths.root.appendingPathComponent("sessions.json")
        self.fileManager = fileManager
    }

    public func load(workspacePath: String?) -> [Conversation] {
        guard let workspacePath = Self.normalizedPath(workspacePath),
              let data = try? Data(contentsOf: fileURL),
              let all = try? JSONDecoder().decode([Conversation].self, from: data) else {
            return []
        }
        return all
            .filter { Self.normalizedPath($0.cwd) == workspacePath }
            .sorted { $0.id < $1.id }
    }

    public func save(_ conversations: [Conversation]) {
        var existing: [Conversation] = []
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([Conversation].self, from: data) {
            existing = decoded
        }

        let ids = Set(conversations.map(\.id))
        existing.removeAll { ids.contains($0.id) }
        let merged = existing + conversations
        guard let data = try? JSONEncoder().encode(merged) else { return }
        try? fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: fileURL, options: .atomic)
    }

    public func delete(_ conversationID: String) {
        guard let data = try? Data(contentsOf: fileURL),
              var all = try? JSONDecoder().decode([Conversation].self, from: data) else {
            return
        }
        all.removeAll { $0.id == conversationID }
        guard let data = try? JSONEncoder().encode(all) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    public static func normalizedPath(_ raw: String?) -> String? {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: raw).standardizedFileURL.path
    }
}

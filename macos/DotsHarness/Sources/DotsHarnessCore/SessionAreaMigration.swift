// Copyright (c) 2026 DOTS
// One-time split of the pre-area sessions file into independent Chat/Coding stores.

import Foundation
import PluginRuntime

public enum SessionAreaMigration {
    private static let markerName = "area-session-migration-v1.json"

    /// Splits the legacy `sessions.json` without deleting or rewriting it.
    /// Existing area stores win so an interrupted migration can be resumed
    /// without duplicating conversations already written by a newer build.
    public static func run(paths: SupportPaths, fileManager: FileManager = .default) {
        let marker = paths.root.appendingPathComponent(markerName)
        guard !fileManager.fileExists(atPath: marker.path) else { return }

        let legacyURL = paths.root.appendingPathComponent("sessions.json")
        guard let data = try? Data(contentsOf: legacyURL),
              let legacy = try? JSONDecoder().decode([Conversation].self, from: data) else {
            writeMarker(marker, fileManager: fileManager, imported: 0)
            return
        }

        let codingURL = paths.root.appendingPathComponent(AgentArea.coding.sessionFileName)
        let chatURL = paths.root.appendingPathComponent(AgentArea.chat.sessionFileName)
        let existingCoding = decode(codingURL)
        let existingChat = decode(chatURL)
        var existingIDs = Set((existingCoding + existingChat).map(\.id))

        var coding = existingCoding
        var chat = existingChat
        for var conversation in legacy where existingIDs.insert(conversation.id).inserted {
            let isCoding = conversation.cwd?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            conversation.area = isCoding ? .coding : .chat
            if !isCoding { conversation.cwd = nil }
            conversation.chatProjectID = nil
            if isCoding { coding.append(conversation) } else { chat.append(conversation) }
        }

        write(coding, to: codingURL, fileManager: fileManager)
        write(chat, to: chatURL, fileManager: fileManager)
        writeMarker(marker, fileManager: fileManager, imported: coding.count + chat.count)
    }

    private static func decode(_ url: URL) -> [Conversation] {
        guard let data = try? Data(contentsOf: url),
              let values = try? JSONDecoder().decode([Conversation].self, from: data) else { return [] }
        return values
    }

    private static func write(_ conversations: [Conversation], to url: URL, fileManager: FileManager) {
        guard !conversations.isEmpty, let data = try? JSONEncoder().encode(conversations) else { return }
        try? fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    private static func writeMarker(_ url: URL, fileManager: FileManager, imported: Int) {
        let payload: [String: Any] = [
            "version": 1,
            "completedAt": ISO8601DateFormatter().string(from: Date()),
            "conversationCount": imported,
            "legacyFile": "sessions.json",
        ]
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]) else { return }
        try? fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

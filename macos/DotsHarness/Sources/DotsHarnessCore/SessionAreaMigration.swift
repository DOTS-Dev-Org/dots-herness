// Copyright (c) 2026 DOTS
// One-time split of the pre-area sessions file into independent Chat/Coding stores.

import Foundation
import PluginRuntime

public enum SessionAreaMigration {
    private static let markerName = "area-session-migration-v1.json"
    private static let repairMarkerName = "area-session-migration-v2.json"

    /// Splits the legacy `sessions.json` without deleting or rewriting it, then
    /// repairs area stores created by older builds that did not persist a strict
    /// Chat/Coding ownership invariant.
    public static func run(paths: SupportPaths, fileManager: FileManager = .default) {
        let marker = paths.root.appendingPathComponent(markerName)
        if !fileManager.fileExists(atPath: marker.path) {
            migrateLegacy(paths: paths, marker: marker, fileManager: fileManager)
        }

        let codingURL = paths.root.appendingPathComponent(AgentArea.coding.sessionFileName)
        let chatURL = paths.root.appendingPathComponent(AgentArea.chat.sessionFileName)
        let repairMarker = paths.root.appendingPathComponent(repairMarkerName)
        guard !fileManager.fileExists(atPath: repairMarker.path) else { return }

        let all = decode(codingURL) + decode(chatURL)
        var selectedByID: [String: Conversation] = [:]
        for conversation in all {
            if let existing = selectedByID[conversation.id] {
                if conversation.messages.count > existing.messages.count {
                    selectedByID[conversation.id] = conversation
                }
            } else {
                selectedByID[conversation.id] = conversation
            }
        }

        var coding: [Conversation] = []
        var chat: [Conversation] = []
        for var conversation in selectedByID.values.sorted(by: { $0.id < $1.id }) {
            let isCoding = ConversationStore.normalizedPath(conversation.cwd) != nil
            conversation.area = isCoding ? .coding : .chat
            if isCoding {
                conversation.chatProjectID = nil
                coding.append(conversation)
            } else {
                conversation.cwd = nil
                chat.append(conversation)
            }
        }

        write(coding, to: codingURL, fileManager: fileManager)
        write(chat, to: chatURL, fileManager: fileManager)
        writeMarker(repairMarker, fileManager: fileManager, imported: coding.count + chat.count, version: 2)
    }

    private static func migrateLegacy(paths: SupportPaths, marker: URL, fileManager: FileManager) {
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
            let isCoding = ConversationStore.normalizedPath(conversation.cwd) != nil
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
        guard let data = try? JSONEncoder().encode(conversations) else { return }
        try? fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    private static func writeMarker(_ url: URL, fileManager: FileManager, imported: Int, version: Int = 1) {
        let payload: [String: Any] = [
            "version": version,
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

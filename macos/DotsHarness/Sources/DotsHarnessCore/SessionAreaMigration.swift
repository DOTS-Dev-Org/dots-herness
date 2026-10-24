// Copyright (c) 2026 DOTS
// Migrate the historical Chat/Coding stores into one project session store.

import Foundation
import PluginRuntime

public enum SessionAreaMigration {
    private static let canonicalFileName = "sessions.json"
    private static let completionMarkerName = "project-session-migration-v1.json"
    private static let obsoleteFileNames = [
        "coding-sessions.json",
        "chat-sessions.json",
        "conversations.json",
        "chat-projects.json",
        "area-session-migration-v1.json",
        "area-session-migration-v2.json",
    ]

    /// Keeps workspace-bound and explicitly projectless conversations, chooses
    /// the fullest duplicate, and removes the old Chat stores only after the
    /// canonical file is readable. Legacy Chat-only records without a workspace
    /// remain excluded unless they were created by the current No project flow.
    public static func run(paths: SupportPaths, fileManager: FileManager = .default) {
        paths.ensure()
        let root = paths.root
        let canonicalURL = root.appendingPathComponent(canonicalFileName)
        let markerURL = root.appendingPathComponent(completionMarkerName)
        // This is a one-time migration. Re-decoding, re-encoding, and verifying
        // the full session archive on every launch needlessly blocks the first frame.
        if fileManager.fileExists(atPath: markerURL.path),
           fileManager.fileExists(atPath: canonicalURL.path) {
            return
        }
        let sourceURLs = ([canonicalURL] + obsoleteFileNames.map { root.appendingPathComponent($0) })
            .reduce(into: [URL]()) { result, url in
                if !result.contains(url) { result.append(url) }
            }

        var selected: [String: Conversation] = [:]
        for url in sourceURLs {
            for conversation in decode(url) {
                guard let existing = selected[conversation.id] else {
                    selected[conversation.id] = conversation
                    continue
                }
                if conversation.messages.count > existing.messages.count
                    || (conversation.messages.count == existing.messages.count
                        && activity(of: conversation) > activity(of: existing)) {
                    selected[conversation.id] = conversation
                }
            }
        }

        let projectConversations = selected.values
            .filter { ConversationStore.normalizedPath($0.cwd) != nil || $0.projectless }
            .sorted { $0.id < $1.id }

        write(projectConversations, to: canonicalURL, fileManager: fileManager)
        let verified = decode(canonicalURL)
        guard verified.count == projectConversations.count,
              Set(verified.map(\.id)).count == projectConversations.count,
              Set(verified.map(\.id)) == Set(projectConversations.map(\.id)) else { return }

        for name in obsoleteFileNames {
            let url = root.appendingPathComponent(name)
            if url != canonicalURL { try? fileManager.removeItem(at: url) }
        }
        try? fileManager.removeItem(at: root.appendingPathComponent("chat-context", isDirectory: true))
        writeMarker(
            at: markerURL,
            count: projectConversations.count,
            fileManager: fileManager
        )
    }

    private static func activity(of conversation: Conversation) -> Date {
        conversation.messages.map(\.createdAt).max() ?? .distantPast
    }

    private static func decode(_ url: URL) -> [Conversation] {
        guard let data = try? Data(contentsOf: url),
              let values = try? JSONDecoder().decode([Conversation].self, from: data) else { return [] }
        return values
    }

    private static func write(
        _ conversations: [Conversation],
        to url: URL,
        fileManager: FileManager
    ) {
        guard let data = try? JSONEncoder().encode(conversations) else { return }
        try? fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = url.appendingPathExtension("tmp")
        try? data.write(to: temporary, options: .atomic)
        _ = try? fileManager.replaceItemAt(url, withItemAt: temporary)
        if !fileManager.fileExists(atPath: url.path) {
            try? fileManager.moveItem(at: temporary, to: url)
        }
    }

    private static func writeMarker(at url: URL, count: Int, fileManager: FileManager) {
        let payload: [String: Any] = [
            "version": 1,
            "completedAt": ISO8601DateFormatter().string(from: Date()),
            "conversationCount": count,
            "canonicalFile": canonicalFileName,
        ]
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

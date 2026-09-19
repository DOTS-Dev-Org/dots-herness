// Copyright (c) 2026 DOTS
// Read-only view over the workspace's .mem/events/*.json log, for pattern mining only.
// This never writes to .mem — that log is a separate signed Merkle/DAG store this app does not produce.

import Foundation

public struct MemEvent: Sendable {
    public let eventID: String
    public let lamport: Int64
    public let createdAt: Date
    public let type: String
    public let commandSummary: String?
    public let runID: String?
}

public enum MemEventStore {
    private static let maximumEventFiles = 5_000

    public static func readToolExecutedEvents(workspace: URL, fileManager: FileManager = .default) -> [MemEvent] {
        let directory = workspace.appendingPathComponent(".mem/events", isDirectory: true)
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoFormatterNoFraction = ISO8601DateFormatter()

        var results: [MemEvent] = []
        for file in files.filter({ $0.pathExtension == "json" }).prefix(maximumEventFiles) {
            guard let data = try? Data(contentsOf: file),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["type"] as? String == "tool.executed" else { continue }
            let payload = object["payload"] as? [String: Any]
            let eventID = object["eventId"] as? String ?? file.deletingPathExtension().lastPathComponent
            let lamport = (object["lamport"] as? NSNumber)?.int64Value ?? 0
            let createdAtRaw = object["createdAt"] as? String
            let createdAt = createdAtRaw.flatMap { isoFormatter.date(from: $0) ?? isoFormatterNoFraction.date(from: $0) } ?? .distantPast
            results.append(MemEvent(
                eventID: eventID,
                lamport: lamport,
                createdAt: createdAt,
                type: "tool.executed",
                commandSummary: payload?["commandSummary"] as? String,
                runID: payload?["runId"] as? String
            ))
        }

        return results.sorted { lhs, rhs in
            lhs.lamport != rhs.lamport ? lhs.lamport < rhs.lamport : lhs.createdAt < rhs.createdAt
        }
    }
}

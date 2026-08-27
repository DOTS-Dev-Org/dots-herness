// Copyright (c) 2026 DOTS
// Durable scheduled tasks: a cron expression plus a prompt to run in a workspace.

import Foundation
import PluginRuntime

public struct ScheduledTask: Identifiable, Sendable, Equatable, Codable {
    public enum RunState: Sendable, Equatable, Codable {
        case never
        case running
        case ok
        case failed(String)
    }

    public var id: String
    public var name: String
    /// Standard 5-field cron expression. Validated via `CronExpression`.
    public var cron: String
    /// The prompt sent to the agent when the task fires.
    public var prompt: String
    /// Absolute workspace path the run executes in.
    public var workspacePath: String
    /// Optional model id override. Empty means "use the current agent model".
    public var modelID: String
    public var enabled: Bool
    public var createdAt: Date
    public var lastRunAt: Date?
    public var lastState: RunState
    public var lastConversationID: String?

    public init(
        id: String = UUID().uuidString,
        name: String,
        cron: String,
        prompt: String,
        workspacePath: String,
        modelID: String = "",
        enabled: Bool = true,
        createdAt: Date = Date(),
        lastRunAt: Date? = nil,
        lastState: RunState = .never,
        lastConversationID: String? = nil
    ) {
        self.id = id
        self.name = name
        self.cron = cron
        self.prompt = prompt
        self.workspacePath = workspacePath
        self.modelID = modelID
        self.enabled = enabled
        self.createdAt = createdAt
        self.lastRunAt = lastRunAt
        self.lastState = lastState
        self.lastConversationID = lastConversationID
    }

    public var expression: CronExpression? { CronExpression(cron) }

    /// Next firing after the given reference date, or `nil` if the cron is invalid.
    public func nextRun(after reference: Date = Date(), calendar: Calendar = .current) -> Date? {
        expression?.nextDate(after: reference, calendar: calendar)
    }

    /// Whether the task is due at `now`: enabled, valid cron, and a scheduled
    /// firing exists in the window `(anchor, now]` where `anchor` is the last run
    /// (or creation time for a task that has never run).
    ///
    /// ponytail: a task that missed several firings while the app was closed runs
    /// once on the next tick, not once per missed slot. Upgrade path is to loop
    /// `nextDate` from the anchor if true backfill is ever required.
    public func isDue(now: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard enabled, let expression else { return false }
        let anchor = lastRunAt ?? createdAt
        guard anchor < now else { return false }
        guard let fire = expression.nextDate(after: anchor, calendar: calendar) else { return false }
        return fire <= now
    }
}

/// Small, transparent JSON store mirroring `ConversationStore`.
public final class TaskStore: @unchecked Sendable {
    private let fileURL: URL
    private let fileManager: FileManager

    public init(paths: SupportPaths, fileManager: FileManager = .default) {
        self.fileURL = paths.root.appendingPathComponent("tasks.json")
        self.fileManager = fileManager
    }

    public func load() -> [ScheduledTask] {
        guard
            let data = try? Data(contentsOf: fileURL),
            let tasks = try? JSONDecoder.taskDecoder.decode([ScheduledTask].self, from: data)
        else { return [] }
        return tasks.sorted { $0.createdAt < $1.createdAt }
    }

    public func save(_ tasks: [ScheduledTask]) {
        guard let data = try? JSONEncoder.taskEncoder.encode(tasks) else { return }
        try? fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: fileURL, options: .atomic)
    }
}

extension JSONEncoder {
    static var taskEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

extension JSONDecoder {
    static var taskDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

extension DateFormatter {
    /// Short local timestamp used in generated conversation titles.
    static let taskStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

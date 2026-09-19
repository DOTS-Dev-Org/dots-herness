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
    /// Optional second choice when the primary model is unavailable.
    public var fallbackModelID: String
    /// Optional file or directory inside `workspacePath` to focus the run on.
    public var targetPath: String
    /// Allows automatic task runs to use network-capable commands.
    public var allowsNetwork: Bool
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
        fallbackModelID: String = "",
        targetPath: String = "",
        allowsNetwork: Bool = false,
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
        self.fallbackModelID = fallbackModelID
        self.targetPath = targetPath
        self.allowsNetwork = allowsNetwork
        self.enabled = enabled
        self.createdAt = createdAt
        self.lastRunAt = lastRunAt
        self.lastState = lastState
        self.lastConversationID = lastConversationID
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, cron, prompt, workspacePath, modelID, fallbackModelID, targetPath
        case allowsNetwork, enabled, createdAt, lastRunAt, lastState, lastConversationID
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try values.decode(String.self, forKey: .id)
        self.name = try values.decode(String.self, forKey: .name)
        self.cron = try values.decode(String.self, forKey: .cron)
        self.prompt = try values.decode(String.self, forKey: .prompt)
        self.workspacePath = try values.decode(String.self, forKey: .workspacePath)
        self.modelID = try values.decodeIfPresent(String.self, forKey: .modelID) ?? ""
        self.fallbackModelID = try values.decodeIfPresent(String.self, forKey: .fallbackModelID) ?? ""
        self.targetPath = try values.decodeIfPresent(String.self, forKey: .targetPath) ?? ""
        self.allowsNetwork = try values.decodeIfPresent(Bool.self, forKey: .allowsNetwork) ?? false
        self.enabled = try values.decode(Bool.self, forKey: .enabled)
        self.createdAt = try values.decode(Date.self, forKey: .createdAt)
        self.lastRunAt = try values.decodeIfPresent(Date.self, forKey: .lastRunAt)
        self.lastState = try values.decode(RunState.self, forKey: .lastState)
        self.lastConversationID = try values.decodeIfPresent(String.self, forKey: .lastConversationID)
    }

    /// Returns the configured target when it stays inside the workspace.
    public func resolvedTargetPath() -> String? {
        guard let workspace = ConversationStore.normalizedPath(workspacePath), workspace != "/" else { return nil }
        let rawTarget = targetPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawTarget.isEmpty else { return workspace }
        let targetURL = URL(fileURLWithPath: rawTarget, relativeTo: URL(fileURLWithPath: workspace, isDirectory: true))
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let root = URL(fileURLWithPath: workspace, isDirectory: true).resolvingSymlinksInPath()
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard targetURL.path == root.path || targetURL.path.hasPrefix(rootPath) else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: targetURL.path, isDirectory: &isDirectory) else { return nil }
        return targetURL.path
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

public struct ScheduledTaskRun: Identifiable, Codable, Sendable, Equatable {
    public let id: String
    public let taskID: String
    public let startedAt: Date
    public let finishedAt: Date
    public let ok: Bool
    public let output: String
    public let modelID: String
    public let fallbackUsed: Bool

    public init(
        id: String = UUID().uuidString,
        taskID: String,
        startedAt: Date,
        finishedAt: Date,
        ok: Bool,
        output: String,
        modelID: String = "",
        fallbackUsed: Bool = false
    ) {
        self.id = id
        self.taskID = taskID
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.ok = ok
        self.output = output
        self.modelID = modelID
        self.fallbackUsed = fallbackUsed
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

public final class TaskRunStore: @unchecked Sendable {
    private let fileURL: URL
    private let fileManager: FileManager
    private let limit = 20

    public init(paths: SupportPaths, fileManager: FileManager = .default) {
        self.fileURL = paths.root.appendingPathComponent("task-runs.json")
        self.fileManager = fileManager
    }

    public func load(taskID: String? = nil) -> [ScheduledTaskRun] {
        guard let data = try? Data(contentsOf: fileURL),
              let runs = try? JSONDecoder.taskDecoder.decode([ScheduledTaskRun].self, from: data) else { return [] }
        let filtered = taskID.map { id in runs.filter { run in run.taskID == id } } ?? runs
        return filtered.sorted { $0.startedAt > $1.startedAt }
    }

    public func append(_ run: ScheduledTaskRun) {
        var runs = load()
        runs.removeAll { $0.id == run.id }
        runs.append(run)
        runs.sort { $0.startedAt > $1.startedAt }
        if runs.count > limit { runs.removeLast(runs.count - limit) }
        guard let data = try? JSONEncoder.taskEncoder.encode(runs) else { return }
        try? fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
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

// Copyright (c) 2026 DOTS
// Scheduler: ticks once a minute and runs due tasks via an injected runner.
// Used both by the in-app manager and the background daemon.

import Combine
import Foundation

@MainActor
public final class TaskScheduler: ObservableObject {
    public struct RunResult: Sendable {
        public var ok: Bool
        public var message: String
        public var conversationID: String?

        public init(ok: Bool, message: String = "", conversationID: String? = nil) {
            self.ok = ok
            self.message = message
            self.conversationID = conversationID
        }
    }

    /// Executes one task and reports the outcome. Injected so the engine stays
    /// free of agent/UI wiring and can be reused by the headless daemon.
    public typealias Runner = @MainActor (ScheduledTask) async -> RunResult

    @Published public private(set) var tasks: [ScheduledTask] = []

    /// When false the engine still reloads/persists task definitions and honours
    /// `runNow`, but does not fire due tasks on tick. The in-app scheduler sets
    /// this to false while the background daemon owns execution, so a task never
    /// runs twice.
    public var runsDueTasks: Bool

    private let store: TaskStore
    private let runner: Runner
    private let calendar: Calendar
    private var timer: Timer?
    private var inFlight = Set<String>()

    public init(
        store: TaskStore,
        calendar: Calendar = .current,
        runsDueTasks: Bool = true,
        runner: @escaping Runner
    ) {
        self.store = store
        self.runner = runner
        self.calendar = calendar
        self.runsDueTasks = runsDueTasks
        self.tasks = store.load()
    }

    // MARK: Lifecycle

    public func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: Task CRUD

    public func upsert(_ task: ScheduledTask) {
        reloadFromDisk()
        if let index = tasks.firstIndex(where: { $0.id == task.id }) {
            tasks[index] = task
        } else {
            tasks.append(task)
        }
        persist()
    }

    public func delete(_ id: String) {
        reloadFromDisk()
        tasks.removeAll { $0.id == id }
        persist()
    }

    public func setEnabled(_ id: String, _ enabled: Bool) {
        reloadFromDisk()
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[index].enabled = enabled
        persist()
    }

    /// Run a task immediately, ignoring its schedule and `runsDueTasks`.
    public func runNow(_ id: String) {
        guard let task = tasks.first(where: { $0.id == id }) else { return }
        execute(task)
    }

    // MARK: Engine

    private func tick(now: Date = Date()) {
        reloadFromDisk()
        guard runsDueTasks else { return }
        for task in tasks where task.isDue(now: now, calendar: calendar) {
            execute(task)
        }
    }

    /// Re-read task definitions written by the other process (app or daemon),
    /// without disturbing tasks this process is currently executing.
    private func reloadFromDisk() {
        let disk = store.load()
        guard !disk.isEmpty || !tasks.isEmpty else { return }
        var merged = disk
        for index in merged.indices where inFlight.contains(merged[index].id) {
            if let live = tasks.first(where: { $0.id == merged[index].id }) {
                merged[index] = live
            }
        }
        if merged != tasks { tasks = merged }
    }

    private func execute(_ task: ScheduledTask) {
        guard !inFlight.contains(task.id) else { return }
        inFlight.insert(task.id)
        mutate(task.id) {
            $0.lastState = .running
            $0.lastRunAt = Date()
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await self.runner(task)
            self.inFlight.remove(task.id)
            self.mutate(task.id) {
                $0.lastState = result.ok ? .ok : .failed(result.message)
                $0.lastConversationID = result.conversationID ?? $0.lastConversationID
            }
        }
    }

    private func mutate(_ id: String, _ change: (inout ScheduledTask) -> Void) {
        reloadFromDisk()
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        change(&tasks[index])
        persist()
    }

    private func persist() {
        store.save(tasks)
    }
}

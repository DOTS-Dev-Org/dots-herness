// Copyright (c) 2026 DOTS
// Memory's background work on the open project: it is studied a part at a time, its
// finished tasks are read by a light model and folded into its findings, and the store is
// kept compact (see WorkspaceMemory+Study, +Insights and +Compaction).

import Foundation

extension NativeAgentHost {
    /// How often the loop looks at the clock. The interval itself is the user's setting.
    private static let memoryScanTick: Duration = .seconds(600)
    /// A scan reads at most this many batches, so a long backlog cannot run up one bill.
    private static let memoryScanMaxBatches = 4

    /// While there is still something to learn the loop comes back in five minutes,
    /// leaving time for interactive work and avoiding frequent background requests.
    private static let memoryLearningTick: Duration = .seconds(300)

    /// The person's switch for memory as a whole; see `WorkspaceMemory.enabled`.
    public func setMemoryEnabled(_ enabled: Bool) {
        memory.enabled = enabled
        syncFeedbackStore()
        memoryRevision += 1
        setMemoryScanInterval(memoryScanInterval)
    }

    /// The loop runs whatever the interval is: with scanning off it still compacts the
    /// store, and only the model is left out.
    public func setMemoryScanInterval(_ interval: MemoryScanInterval) {
        memoryScanInterval = interval
        memoryScanLoop?.cancel()
        memoryScanLoop = nil
        guard memory.enabled else { return }
        memoryScanLoop = Task(priority: .utility) { @MainActor [weak self] in
            // Not during startup: the endpoint and the workspace are still settling.
            try? await Task.sleep(for: .seconds(30))
            while !Task.isCancelled {
                let learned = await self?.tendMemory() ?? false
                try? await Task.sleep(for: learned ? Self.memoryLearningTick : Self.memoryScanTick)
            }
        }
    }

    /// One step of the background work, for the open project only and only once a prompt
    /// has given it a memory: it is compacted, its findings are consolidated when they have
    /// grown, its decisions are reviewed when enough were recorded, then one unread part of it
    /// is studied, then its finished tasks are scanned. With scanning off only the first step runs, which asks no model.
    /// Returns whether a model was asked, which is when there may be more to do.
    func canStartAutomaticMemoryWork() -> Bool {
        !anyRunBusy && !memoryScanRunning
    }

    @discardableResult
    func tendMemory() async -> Bool {
        guard memory.enabled, canStartAutomaticMemoryWork() else { return false }
        let signpost = PerformanceSignposts.begin("AutomaticMemoryWork")
        defer { PerformanceSignposts.end("AutomaticMemoryWork", signpost) }

        if memory.compactActivity() { memoryRevision += 1 }
        guard memoryScanInterval != .off else { return false }
        // First, so a long study cannot keep the findings over their share of the prompt.
        guard !anyRunBusy else { return false }
        if await consolidate() { return true }
        guard !anyRunBusy else { return false }
        if await reviewDecisions() { return true }
        guard !anyRunBusy else { return false }
        if await study(memory) { return true }
        guard !anyRunBusy else { return false }
        return await scanMemory()
    }

    /// Asks a light model to fold the findings into fewer; see WorkspaceMemory+Compaction.
    private func consolidate() async -> Bool {
        guard let payload = memory.consolidationPayload() else { return false }
        memoryScanRunning = true
        defer { memoryScanRunning = false }
        let directory = memory.userMemoryDirectory
        guard let reply = await cheapCompletion(system: WorkspaceMemory.consolidationSystemPrompt, user: payload),
              !Task.isCancelled, memory.userMemoryDirectory == directory else { return false }
        memory.applyConsolidation(reply: reply)
        memoryRevision += 1
        return true
    }

    /// Asks a light model to merge the project's twin decisions and name the stale ones; see
    /// WorkspaceMemory+Decisions. A stale one is only suggested to the person.
    private func reviewDecisions() async -> Bool {
        guard let payload = memory.decisionConsolidationPayload() else { return false }
        memoryScanRunning = true
        defer { memoryScanRunning = false }
        let directory = memory.userMemoryDirectory
        guard let reply = await cheapCompletion(system: ProjectDecisions.consolidationSystemPrompt, user: payload),
              !Task.isCancelled, memory.userMemoryDirectory == directory else { return false }
        memory.applyDecisionConsolidation(reply: reply)
        memoryRevision += 1
        return true
    }

    /// Reads one unread part of a project into its findings.
    private func study(_ target: WorkspaceMemory) async -> Bool {
        guard let folder = target.workspaceURL, WorkspaceMemory.isProjectFolder(folder),
              let batch = target.nextStudyBatch() else { return false }
        memoryScanRunning = true
        defer { memoryScanRunning = false }
        let directory = target.userMemoryDirectory
        guard let reply = await cheapCompletion(system: WorkspaceMemory.studySystemPrompt, user: batch.payload),
              !Task.isCancelled, target.userMemoryDirectory == directory else { return false }
        target.applyStudy(reply: reply, area: batch.area)
        memoryRevision += 1
        return true
    }

    private func cheapCompletion(system: String, user: String) async -> String? {
        let messages = [AgentMessage(role: .system, content: system), AgentMessage(role: .user, content: user)]
        if let router {
            return try? await router.completeCheapest(messages: messages, effort: "medium").message.content
        }
        guard let configuration = await currentConfiguration(loadCredentials: false) else { return nil }
        return try? await NativeAgentClient(configuration: configuration).complete(messages: messages, tools: []).message.content
    }

    /// Runs a scan when one is due, or now with `force`. Returns whether anything was read.
    @discardableResult
    func scanMemory(force: Bool = false) async -> Bool {
        guard !anyRunBusy,
              !memoryScanRunning,
              force ? memory.unscannedTaskCount > 0 : memory.memoryScanDue(interval: memoryScanInterval) else { return false }
        memoryScanRunning = true
        defer { memoryScanRunning = false }
        let directory = memory.userMemoryDirectory
        var read = false
        for _ in 0..<Self.memoryScanMaxBatches {
            guard !Task.isCancelled, !anyRunBusy else { break }
            guard let batch = memory.nextScanBatch() else { break }
            guard let reply = await cheapCompletion(system: WorkspaceMemory.scanSystemPrompt, user: batch.payload) else { break }
            // The project may have been switched while the model was answering.
            guard !Task.isCancelled, memory.userMemoryDirectory == directory,
                  memory.applyScan(reply: reply, runIDs: batch.runIDs) else { break }
            read = true
        }
        return read
    }
}

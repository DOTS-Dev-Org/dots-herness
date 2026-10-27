// Copyright (c) 2026 DOTS
// Memory's background work on the open project: it is studied a part at a time, its
// finished tasks are read by a light model and folded into its findings, and the findings
// are consolidated when they have grown (see WorkspaceInsights).
//
// Mirrors AgentBridge+MemoryScan.swift on macOS.

namespace DotsHarnessCore;

public sealed partial class AgentBridge
{
    /// <summary>
    /// What the memory sections are for and when to write them. macOS keeps the same
    /// guidance as <c>memoryGuidance</c> in AgentBridge+Tools.swift; this is the C# half,
    /// with this harness's own keys and kinds.
    /// </summary>
    internal const string MemoryGuidance = """
        Durable memory
        - <user_memory>, <learned_rules>, <durable_facts> and <task_history> are what you
          already know about this user and project. Work from them; ask only what they leave
          unanswered, and never ask again for a stack, style or convention they state.
        - When stored memories conflict, this project's saved facts, decisions and rules take
          precedence over any personal memory, including project-scoped personal preferences.
          The user's current request overrides both.
        - Record with remember whatever should still hold in a later conversation: a
          preference the user states, a project choice they settle, and a lasting change your
          own finished work made to the project. One fact per call, with kind "project",
          "preference" or "decision". Preferences default to scope "user" and stay on this device;
          use scope "project" only if a preference applies to this repository alone. Project facts
          and decisions always use project scope.
          Before finishing a task, record every lasting, evidence-backed project decision you made,
          including deciding not to make a requested change because measured results or inspected
          source show a durable tradeoff. Use kind "decision" and preserve its reason in the same
          sentence. Do not wait for the background memory scan to infer it. Never record a secret,
          a guess, a temporary choice, or anything those sections already state. Claim it was saved
          only after remember confirms it; if memory is unavailable, preserve the reason in the task
          outcome and say it was not saved as a durable fact.
        - A convention of the codebase is not a preference: record it with kind "project".
        - Recording is not doing: it never replaces carrying out the request right now.
        - When the request touches something <task_history> names no finding for, or it says
          some were not shown, search prior findings and task outcomes with recall before searching the workspace.
        - When a lesson decided how you did something, name its id in your answer.
        """;

    /// <summary>How often the loop looks at the clock. The interval itself is the setting below.</summary>
    private static readonly TimeSpan MemoryScanTick = TimeSpan.FromMinutes(10);
    /// <summary>While there is still something to learn the loop comes back sooner.</summary>
    private static readonly TimeSpan MemoryLearningTick = TimeSpan.FromMinutes(1);
    /// <summary>A scan reads at most this many batches, so a long backlog cannot run up one bill.</summary>
    private const int MemoryScanMaxBatches = 4;

    private bool _memoryLoopStarted;
    private bool _memoryScanRunning;

    /// <summary>
    /// How often finished tasks are turned into findings; null switches the light model off.
    /// Daily unless the person chose otherwise in Settings, as on macOS.
    /// </summary>
    public TimeSpan? MemoryScanInterval { get; set; } = TimeSpan.FromDays(1);

    /// <summary>
    /// The person's switch for memory as a whole. Off, no task is noted, nothing is learned
    /// and no finding is handed to a model; what was already kept stays on disk as it is.
    /// </summary>
    public bool MemoryEnabled { get; set; } = true;

    private void StartMemoryLoop()
    {
        if (_memoryLoopStarted) return;
        _memoryLoopStarted = true;
        _ = MemoryLoopAsync();
    }

    private async Task MemoryLoopAsync()
    {
        // Not during startup: the providers and the workspace are still settling.
        await Task.Delay(TimeSpan.FromSeconds(30));
        while (true)
        {
            var learned = false;
            try { learned = await TendMemoryAsync(); }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException or InvalidOperationException) { }
            await Task.Delay(learned ? MemoryLearningTick : MemoryScanTick);
        }
    }

    /// <summary>
    /// One step of the background work, for the open project only and only once a task has
    /// given it a memory: one unread part of it is studied, else its finished tasks are
    /// scanned when that is due, else its findings are consolidated when they have grown.
    /// Returns whether a model was asked, which is when there may be more to do.
    /// </summary>
    public async Task<bool> TendMemoryAsync(bool force = false)
    {
        var workspace = _activeWorkspace;
        var root = _paths.Root;
        if (!MemoryEnabled || MemoryScanInterval is not { } interval || _memoryScanRunning || _remoteTarget is not null
            || string.IsNullOrWhiteSpace(workspace) || !Directory.Exists(workspace) || !_router.HasActiveRoute) return false;
        _memoryScanRunning = true;
        try
        {
            if (await Task.Run(() => WorkspaceInsights.NextStudyBatch(workspace, root)) is { } study)
            {
                if (await CheapCompletionAsync(WorkspaceInsights.StudySystemPrompt, study.Payload) is not { } reply) return false;
                WorkspaceInsights.ApplyStudy(workspace, root, reply, study.Area);
                return true;
            }
            if (force || WorkspaceInsights.ScanDue(workspace, root, interval))
            {
                var read = false;
                for (var batchIndex = 0; batchIndex < MemoryScanMaxBatches; batchIndex++)
                {
                    if (WorkspaceInsights.NextScanBatch(workspace, root) is not { } batch) break;
                    if (await CheapCompletionAsync(WorkspaceInsights.ScanSystemPrompt, batch.Payload) is not { } reply) break;
                    if (!WorkspaceInsights.ApplyScan(workspace, root, reply, batch.RunIds)) break;
                    read = true;
                }
                if (read) return true;
            }
            if (WorkspaceInsights.ConsolidationPayload(workspace, root) is { } payload
                && await CheapCompletionAsync(WorkspaceInsights.ConsolidationSystemPrompt, payload) is { } consolidated)
            {
                WorkspaceInsights.ApplyConsolidation(workspace, root, consolidated);
                return true;
            }
            return false;
        }
        finally { _memoryScanRunning = false; }
    }

    private async Task<string?> CheapCompletionAsync(string system, string user)
    {
        try
        {
            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(120));
            var response = await _router.CompleteCheapestAsync(
                [new NativeMessage("system", system), new NativeMessage("user", user)], timeout.Token);
            return string.IsNullOrWhiteSpace(response.Message.Content) ? null : response.Message.Content;
        }
        // A background evaluator never interrupts the person: whatever the provider
        // answered, the same work is tried again at the next tick.
        catch (Exception) { return null; }
    }
}

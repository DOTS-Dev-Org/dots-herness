// Copyright (c) 2026 DOTS
// Executes one scheduled task in a transient headless agent bridge.
// Shared by the in-app scheduler (AppModel) and the background daemon.
// Mirrors the macOS ScheduledTaskRunner.swift.

using PluginRuntime;

namespace DotsHarnessCore;

public sealed class ScheduledTaskRunner
{
    private readonly SupportPaths _paths;
    private readonly RouterController _router;

    public ScheduledTaskRunner(SupportPaths paths, RouterController router)
    {
        _paths = paths;
        _router = router;
    }

    /// <summary>
    /// Runs <paramref name="task"/> to completion. Diagnostic strings are
    /// developer-facing status shown in the task's "last run" detail.
    /// </summary>
    public async Task<TaskRunResult> RunAsync(ScheduledTask task)
    {
        var prompt = task.Prompt.Trim();
        if (prompt.Length == 0) return new TaskRunResult(false, "Empty prompt");

        var workspace = NormalizeWorkspace(task.WorkspacePath);
        if (workspace is null) return new TaskRunResult(false, $"Workspace not found: {task.WorkspacePath}");

        var bridge = new AgentBridge(
            _router,
            _paths,
            area: AgentArea.Coding,
            sessionFileName: AgentArea.Coding.SessionFileName())
        {
            NonInteractive = true,
            AutoApproveCommands = task.AutoApproveCommands,
        };
        await bridge.StartAsync(workspace).ConfigureAwait(false);
        if (!_router.HasActiveRoute)
        {
            return new TaskRunResult(false, bridge.Status);
        }

        await bridge.NewConversationAsync(workspace).ConfigureAwait(false);
        var conversationId = bridge.SelectedId;
        if (conversationId is null) return new TaskRunResult(false, "Could not open a conversation");

        var stamp = DateTimeOffset.Now.ToString("g");
        bridge.RenameConversation(conversationId, $"{task.Name} — {stamp}");

        await bridge.SendAsync(prompt).ConfigureAwait(false);

        var last = bridge.Conversations.FirstOrDefault(c => c.Id == conversationId)?.Messages.LastOrDefault();
        if (last is { Kind: ChatKind.Assistant } && !string.IsNullOrEmpty(last.Text))
        {
            var text = last.Text.Length > 200 ? last.Text[..200] : last.Text;
            return new TaskRunResult(true, text, conversationId);
        }
        return new TaskRunResult(false, last?.Text ?? "No response", conversationId);
    }

    public static string? NormalizeWorkspace(string raw)
    {
        if (string.IsNullOrWhiteSpace(raw)) return null;
        try
        {
            var full = Path.GetFullPath(raw);
            return Directory.Exists(full) ? full : null;
        }
        catch
        {
            return null;
        }
    }
}

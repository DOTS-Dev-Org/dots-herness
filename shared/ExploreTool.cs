// Copyright (c) 2026 DOTS
// Read-only exploration subagent (parity with macOS Subagent.swift).
//
// Searching a codebase is the cheapest work to do and the most expensive to keep:
// every listing and file body stays in the main conversation and is resent on every
// later turn. This runs the search in its own context and hands back only the answer,
// so the main run pays for the conclusion instead of the transcript.

using System.Collections.Concurrent;
using System.Text.Json.Nodes;

namespace DotsHarnessCore;

public static class ExploreTool
{
    public const string Name = "explore";
    /// The subagent answers a bounded question; a run that needs more was the wrong question to delegate.
    private const int MaxSteps = 20;
    /// A target, not a ceiling: only an answer well past it is asked to tighten once.
    private const int CondenseThreshold = 2_000;
    private const int CondenseTrigger = 3_500;
    private const int MaxReportedPaths = 40;
    /// Maximum concurrent explore subagents allowed in a single turn to protect UX, UI and quota.
    public const int MaxPerTurn = 3;

    public static NativeToolDefinition Definition { get; } = new(
        Name,
        "Delegate a read-only search of the workspace to a separate agent and get back only its findings. "
        + "Use it when answering needs sweeping many files or directories and you want the conclusion rather "
        + "than the file contents - locating where something is defined, what calls it, how a pattern is used "
        + "across the project. It cannot edit anything, so verify and change code yourself afterwards. Do not "
        + "use it for a file you already know the path of: read that directly. State the question in full, "
        + "including the naming conventions and paths worth trying, since the subagent sees nothing of this "
        + "conversation. For a broad investigation, split it into independent questions and call explore "
        + "several times in the same turn (maximum 3 subagents per turn): those subagents run in parallel and only their findings enter this "
        + "conversation.",
        new JsonObject
        {
            ["type"] = "object",
            ["properties"] = new JsonObject
            {
                ["task"] = new JsonObject
                {
                    ["type"] = "string",
                    ["description"] = "The self-contained question to answer, with the context the subagent needs.",
                },
            },
            ["required"] = new JsonArray("task"),
        });

    private const string SystemPrompt = """
        You are a read-only exploration agent working inside one workspace. Answer the question you are
        given by searching the project with grep_files, list_files, and read_file. You cannot edit
        anything and must never claim that you did. Search before you read: grep_files answers most
        questions in one call. Stop as soon as the question is answered.
        Reply with the findings only - no plan, no preamble, no suggested fixes - in exactly this shape:

        ## Findings
        One bullet per place that matters, each opening with its path:line, then what is there in one
        sentence. Quote only the line that carries the answer, never a whole block.

        ## Unresolved
        What you could not determine and why. Write "None" when nothing is open.

        Status: answered | partial

        Say "partial" whenever any part of the question is still open, whenever you stopped early, and
        whenever a finding rests on a file you did not actually read. The caller acts on this line, so a
        wrong "answered" is worse than an honest "partial".
        Keep the answer under 2000 characters. Go past it only when the findings genuinely need the room.
        """;

    /// <summary>What the subagent did, so the parent run can show and judge the answer.</summary>
    public sealed record Outcome(string Answer, IReadOnlyList<string> ReadPaths, int Steps, int Searches, bool HitStepLimit)
    {
        public bool Answered => AnsweredFully(Answer) && !HitStepLimit;

        /// The tool result the parent model sees: findings plus every reason to distrust them.
        public string ToolResult
        {
            get
            {
                var parts = new List<string> { Answer };
                if (!Answered) parts.Add("[Status: partial - re-check anything this answer does not state as found.]");
                if (HitStepLimit) parts.Add("[The subagent reached its step limit.]");
                if (Answer.Length > 0 && Steps > 0 && ReadPaths.Count == 0 && Searches == 0)
                    parts.Add("[Unverified: the subagent answered without searching or reading any file.]");
                if (ReadPaths.Count > 0) parts.Add("Files read: " + string.Join(", ", ReadPaths));
                return string.Join("\n\n", parts);
            }
        }

        /// One line for the chat transcript.
        public string Summary => $"{Steps} steps · {ReadPaths.Count} files · {(Answered ? "answered" : "partial")}";
    }

    public delegate Task<NativeResponse> Complete(IReadOnlyList<NativeMessage> messages, IReadOnlyList<NativeToolDefinition> tools, CancellationToken ct);

    /// Partial findings of a run that ran out of steps or quota, keyed by the question,
    /// so asking it again resumes instead of re-reading the project.
    private static readonly ConcurrentDictionary<string, string> Memo = new(StringComparer.Ordinal);

    public static async Task<Outcome> RunAsync(NativeToolCall call, Complete complete, string workspace, CancellationToken ct)
    {
        string? task = null;
        try { task = JsonNode.Parse(call.Arguments)?["task"]?.GetValue<string>()?.Trim(); }
        catch { }
        if (string.IsNullOrEmpty(task)) return new Outcome("Tool error: explore needs a task.", [], 0, 0, false);

        var memoKey = string.Join(' ', task.ToLowerInvariant().Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));
        var tools = NativeWorkspaceTools.Definitions.Where(tool => NativeWorkspaceTools.IsReadOnly(tool.Name)).ToArray();
        var messages = new List<NativeMessage> { new("system", SystemPrompt), new("user", task) };
        if (Memo.TryGetValue(memoKey, out var resumed))
        {
            messages.Add(new("user", "An earlier attempt at this same question was cut short. Continue from what it already found instead of searching again:\n" + resumed));
        }
        var readPaths = new List<string>();
        var searches = 0;
        var steps = 0;

        for (var i = 0; i < MaxSteps; i++)
        {
            ct.ThrowIfCancellationRequested();
            steps++;
            NativeResponse response;
            try { response = await complete(messages, tools, ct).ConfigureAwait(false); }
            catch (OperationCanceledException) { throw; }
            catch (Exception ex)
            {
                var partial = Findings(messages);
                Remember(memoKey, partial);
                var failed = "Tool error: the exploration failed: " + ex.Message;
                return Finish(partial.Length == 0 ? failed : failed + "\n\nPartial findings:\n" + partial, readPaths, steps, searches, false);
            }
            messages.Add(response.Message);
            var calls = response.Message.ToolCalls ?? [];
            if (calls.Count == 0)
            {
                var text = response.Message.Content.Trim();
                if (text.Length == 0) return Close(memoKey, "The subagent returned no findings.", readPaths, steps, searches, false);
                if (text.Length > CondenseTrigger)
                {
                    messages.Add(new("user", $"Tighten this answer to under {CondenseThreshold} characters without dropping any finding or its path:line."));
                    try
                    {
                        var shorter = (await complete(messages, [], ct).ConfigureAwait(false)).Message.Content.Trim();
                        if (shorter.Length > 0 && shorter.Length < text.Length) text = shorter;
                    }
                    catch (OperationCanceledException) { throw; }
                    catch { }
                }
                return Close(memoKey, text, readPaths, steps, searches, false);
            }
            // The subagent's own read-only calls also run side by side.
            var results = await Task.WhenAll(calls.Select(toolCall => NativeWorkspaceTools.IsReadOnly(toolCall.Name)
                ? NativeWorkspaceTools.ExecuteAsync(toolCall, workspace, ct, AgentCommandSandboxMode.StrictNoDesktop)
                : Task.FromResult("Tool error: the exploration agent is read-only."))).ConfigureAwait(false);
            for (var index = 0; index < calls.Count; index++)
            {
                var toolCall = calls[index];
                if (toolCall.Name is "grep_files" or "list_files") searches++;
                if (toolCall.Name == "read_file" && ToolPath(toolCall) is { } path && !readPaths.Contains(path)) readPaths.Add(path);
                messages.Add(new("tool", results[index], toolCall.Id));
            }
        }

        // The budget is spent, but the transcript holds everything found: one last
        // tool-free call turns it into an answer instead of throwing it away.
        messages.Add(new("user", "Stop searching. Answer the original question now from what you have already found, and say plainly what you could not determine."));
        var final = "";
        try { final = (await complete(messages, [], ct).ConfigureAwait(false)).Message.Content.Trim(); }
        catch (OperationCanceledException) { throw; }
        catch { }
        if (final.Length == 0)
        {
            var partial = Findings(messages);
            final = "The subagent reached its step limit without an answer." + (partial.Length == 0 ? "" : "\n\nPartial findings:\n" + partial);
        }
        return Close(memoKey, final, readPaths, steps, searches, true);
    }

    private static Outcome Close(string memoKey, string answer, List<string> readPaths, int steps, int searches, bool hitStepLimit)
    {
        if (hitStepLimit || !AnsweredFully(answer)) Remember(memoKey, answer);
        else Memo.TryRemove(memoKey, out _);
        return Finish(answer, readPaths, steps, searches, hitStepLimit);
    }

    private static Outcome Finish(string answer, List<string> readPaths, int steps, int searches, bool hitStepLimit) =>
        new(answer, readPaths, steps, searches, hitStepLimit);

    private static void Remember(string memoKey, string text)
    {
        if (string.IsNullOrWhiteSpace(text)) return;
        // ponytail: drops every note past 20 questions; an LRU if resumes get lost in practice.
        if (Memo.Count > 20) Memo.Clear();
        Memo[memoKey] = text.Trim();
    }

    private static string Findings(IEnumerable<NativeMessage> messages) => string.Join("\n",
        messages.Where(message => message.Role == "assistant" && !string.IsNullOrWhiteSpace(message.Content))
            .Select(message => message.Content.Trim()));

    /// Reads the subagent's own "Status:" line; missing or malformed counts as partial.
    public static bool AnsweredFully(string answer)
    {
        foreach (var line in answer.Split('\n').Reverse())
        {
            var trimmed = line.Trim().ToLowerInvariant();
            if (!trimmed.StartsWith("status:", StringComparison.Ordinal)) continue;
            return trimmed["status:".Length..].Trim().StartsWith("answered", StringComparison.Ordinal);
        }
        return false;
    }

    private static string? ToolPath(NativeToolCall call)
    {
        try { return JsonNode.Parse(call.Arguments)?["path"]?.GetValue<string>()?.Trim() is { Length: > 0 } path ? path : null; }
        catch { return null; }
    }
}

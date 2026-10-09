// Copyright (c) 2026 DOTS
// Editing subagent with a declared file assignment (parity with macOS DelegateTool.swift).
//
// A long change that splits into independent parts is slow to do one file after
// another, and every file body it touches stays in the main conversation. This
// hands one part to a separate agent that reads, edits and reports back.
//
// Two agents writing the same file is the failure that makes parallel edits
// unusable, so it is ruled out by construction rather than detected afterwards:
// each subagent names the files it owns before it starts, assignments of one
// turn must not overlap, and a write outside the assignment is refused.
//
// An edit nobody ran is a guess, so the caller may also declare `checks`: the
// build or test commands that prove this part works. The subagent runs those and
// nothing else, as often as it needs, and the host - not the subagent's report -
// records whether each one passed after the last edit.

using System.Text.Json.Nodes;

namespace DotsHarnessCore;

public static class DelegateTool
{
    public const string Name = "delegate";
    /// Editing takes more steps than locating: read, edit, re-read, fix.
    private const int MaxSteps = 40;
    /// Concurrent editing subagents per turn. Each runs on the conversation's own
    /// model, so this is also the cost ceiling of one turn.
    public const int MaxPerTurn = 3;
    public const string CheckName = "run_check";
    public const int MaxChecks = 3;

    private static readonly StringComparison PathComparison =
        OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal;

    public static NativeToolDefinition Definition { get; } = new(
        Name,
        "Hand one self-contained part of a change to a separate agent that reads and edits files, and get back "
        + "only its report. Use it when a task splits into parts that touch different files and do not depend on "
        + "each other's edits - then call delegate once per part in the same turn (maximum 3) and they run in "
        + "parallel. Do not use it for a change that fits in a few edits, or for parts that must be written in "
        + "order: do those yourself, since each subagent costs a whole extra run on this conversation's model. "
        + "`files` is the subagent's assignment: the only paths it may create or change. A directory covers "
        + "everything under it. Assignments given in one turn must not overlap; an overlapping call is refused. "
        + "`checks` are the commands that prove the part works (a build, one test class, a linter): the subagent "
        + "runs them after editing, fixes what they report and repeats, and the result tells you which ones "
        + "passed. Give the narrowest check that covers the part - each run is stopped after 45 seconds and sees "
        + "the other subagents' unfinished edits - and never one that rewrites sources, deletes files or uses "
        + "the network. Without checks the subagent cannot run anything. It cannot run other commands, delete "
        + "files or write elsewhere, and it sees nothing of this conversation, so state the task in full: what "
        + "to change, the interfaces it must keep, and the conventions to follow. Run the full build and tests "
        + "yourself after the subagents finish, and re-read a file a subagent changed before editing it.",
        new JsonObject
        {
            ["type"] = "object",
            ["properties"] = new JsonObject
            {
                ["task"] = new JsonObject
                {
                    ["type"] = "string",
                    ["description"] = "The complete instructions for this part of the change.",
                },
                ["files"] = new JsonObject
                {
                    ["type"] = "array",
                    ["items"] = new JsonObject { ["type"] = "string" },
                    ["description"] = "Workspace-relative files or directories this subagent may create or change.",
                },
                ["checks"] = new JsonObject
                {
                    ["type"] = "array",
                    ["items"] = new JsonObject { ["type"] = "string" },
                    ["description"] = "Optional. Up to 3 shell commands the subagent may run to verify its work, run from the workspace root exactly as written, e.g. `dotnet test --filter ParserTests`.",
                },
            },
            ["required"] = new JsonArray("task", "files"),
        });

    private static NativeToolDefinition CheckDefinition { get; } = new(
        CheckName,
        "Run one of your assigned checks and get its output. Checks of all agents run one at a time, so a call may wait.",
        new JsonObject
        {
            ["type"] = "object",
            ["properties"] = new JsonObject
            {
                ["check"] = new JsonObject
                {
                    ["type"] = "integer",
                    ["description"] = "The number of the check, as listed in your instructions.",
                },
            },
            ["required"] = new JsonArray("check"),
        });

    private static string CheckRules(IReadOnlyList<string> checks) => checks.Count == 0
        ? "You cannot run commands or delete files."
        : $"""
        You cannot delete files or run commands of your own, but you can run these checks with
        run_check, by number, as often as you need:
        {string.Join("\n", checks.Select((command, index) => $"{index + 1}. {command}"))}
        Run them once your edits are in, fix what they report inside your assignment, and run them
        again: a check counts only if it passed after your last edit. A failure that comes from a
        file outside your assignment may be another agent's unfinished work - do not try to fix it;
        quote its decisive lines under Unresolved.
        """;

    private static string SystemPrompt(IReadOnlyList<string> claims, IReadOnlyList<string> checks) => $"""
        You are an editing agent working inside one workspace on one assigned part of a larger change.
        Other agents are editing other files of the same project at the same time.
        You may create or change only these paths (a directory covers everything under it):
        {string.Join("\n", claims.Select(claim => "- " + claim))}
        You may read any file. A write outside the assignment is refused: do not look for another way,
        report what was needed under Unresolved instead. {CheckRules(checks)}
        Read a file before you change it. Prefer edit_file for an existing file and write_file for a
        new one. Keep to the task: no unrelated refactors, no new files beyond what it needs.
        When you are done, reply with the report only, in exactly this shape:

        ## Changes
        One bullet per file you changed, opening with its path, then what changed in one sentence.

        ## Unresolved
        What you could not do and why, including anything needed outside your assignment. Write "None"
        when nothing is open.

        Status: done | partial

        Say "partial" whenever any part of the task is unfinished or a check still fails. The caller acts on this line, so a
        wrong "done" is worse than an honest "partial". Never paste file contents into the report.
        """;

    /// <summary>The validated request: what to do and which workspace-relative paths it owns.</summary>
    /// <param name="Checks">The only commands the subagent may run, exactly as the caller wrote them.</param>
    public sealed record Assignment(string Task, IReadOnlyList<string> Claims, IReadOnlyList<string>? Checks = null);

    /// <summary>One declared check and what the host saw it do.</summary>
    /// <param name="Passed">The last run's verdict; null when it never ran or a file changed since.</param>
    public sealed record CheckResult(string Command, int Runs, bool? Passed);

    /// Runs one declared check command. The host owns the sandbox, the gate that
    /// keeps two builds out of one tree, and the verdict.
    public delegate Task<(string Output, bool Passed)> Check(string command, CancellationToken ct);

    /// <param name="Written">Workspace-relative paths whose bytes actually changed, checked on disk
    /// rather than taken from the subagent's report.</param>
    public sealed record Outcome(string Answer, IReadOnlyList<string> Written, int Steps, bool HitStepLimit, bool Done, IReadOnlyList<CheckResult>? Checks = null)
    {
        public static Outcome Refused(string message) => new(message, [], 0, false, false);

        /// Every declared check passed after the last edit. False without checks:
        /// nothing was run, so nothing is proven.
        public bool Verified => Checks is { Count: > 0 } && Checks.All(check => check.Passed == true);

        /// The tool result the parent model sees: the report, what really changed, and
        /// every reason it has to distrust the report.
        public string ToolResult
        {
            get
            {
                var parts = new List<string> { Answer };
                if (Steps > 0)
                {
                    if (!Done) parts.Add("[Partial: the subagent did not finish. Check the files before relying on it.]");
                    if (HitStepLimit) parts.Add("[The subagent reached its step limit.]");
                    parts.Add(Written.Count == 0
                        ? "[No file was changed.]"
                        : "Files changed (verified on disk): " + string.Join(", ", Written)
                            + "\nRe-read any of these before editing it yourself.");
                    if (Checks is { Count: > 0 })
                    {
                        parts.Add("Checks (exit status seen by the host):\n" + string.Join("\n", Checks.Select(check => $"- {check.Command}: " + check.Passed switch
                        {
                            true => "passed",
                            false => "FAILED on its last run",
                            null => check.Runs == 0 ? "never run" : "not run again after the last edit",
                        })));
                        if (!Verified) parts.Add("[Unverified: not every check passed after the last edit. Do not rely on this part until you ran it yourself.]");
                    }
                }
                return string.Join("\n\n", parts);
            }
        }

        /// One line for the chat transcript.
        public string Summary => Steps == 0 ? Answer : $"{Steps} steps · {Written.Count} files changed · {(Done ? "done" : "partial")}"
            + (Checks is { Count: > 0 } ? Verified ? " · checks passed" : " · checks not passed" : "");
    }

    /// Parses and normalizes the call. Returns the error the parent can fix and retry.
    public static (Assignment? Assignment, string? Error) Parse(NativeToolCall call, string workspace)
    {
        JsonObject? input = null;
        try { input = JsonNode.Parse(call.Arguments) as JsonObject; }
        catch { }
        var task = (input?["task"] as JsonValue)?.TryGetValue<string>(out var text) == true ? text.Trim() : "";
        if (task.Length == 0) return (null, "Tool error: delegate needs a task - the complete instructions for the subagent.");
        var claims = new List<string>();
        foreach (var item in input?["files"] as JsonArray ?? [])
        {
            if (item is not JsonValue value || !value.TryGetValue<string>(out var path) || string.IsNullOrWhiteSpace(path)) continue;
            if (RelativePath(path.Trim(), workspace) is not { } relative)
                return (null, $"Tool error: {path} is outside the workspace and cannot be assigned.");
            if (!claims.Contains(relative, PathComparer)) claims.Add(relative);
        }
        if (claims.Count == 0) return (null, "Tool error: delegate needs files - the paths this subagent may create or change.");
        var checks = new List<string>();
        foreach (var item in input?["checks"] as JsonArray ?? [])
        {
            if (item is not JsonValue value || !value.TryGetValue<string>(out var command) || string.IsNullOrWhiteSpace(command)) continue;
            command = command.Trim();
            // The user approves a check once, before the subagent starts, so what
            // must be judged run by run is not a check at all.
            if (NativeWorkspaceTools.MayDeleteFiles(command))
                return (null, $"Tool error: a check may only build or test. `{command}` could delete files; run it yourself after the subagents finish.");
            if (!checks.Contains(command)) checks.Add(command);
        }
        return checks.Count > MaxChecks
            ? (null, $"Tool error: at most {MaxChecks} checks per subagent.")
            : (new Assignment(task, claims, checks), null);
    }

    private static StringComparer PathComparer =>
        OperatingSystem.IsWindows() ? StringComparer.OrdinalIgnoreCase : StringComparer.Ordinal;

    /// The canonical workspace-relative form shared by claims and write targets, so
    /// `./a/../b.cs` and `b.cs` are one path. Null when it escapes the workspace.
    public static string? RelativePath(string path, string workspace)
    {
        try
        {
            var root = NativeWorkspaceTools.Resolve(".", workspace);
            return Path.GetRelativePath(root, NativeWorkspaceTools.Resolve(path, workspace)).Replace('\\', '/');
        }
        catch { return null; }
    }

    /// Whether `claim` covers `path`: the same path, a directory above it, or the workspace root.
    public static bool Covers(string claim, string path) =>
        claim == "." || claim.Equals(path, PathComparison) || path.StartsWith(claim + "/", PathComparison);

    public static bool Covers(IReadOnlyList<string> claims, string path) => claims.Any(claim => Covers(claim, path));

    /// The first pair of claims that could write the same file, if any.
    public static (string Held, string Wanted)? Overlap(IReadOnlyList<string> held, IReadOnlyList<string> wanted)
    {
        foreach (var x in held)
            foreach (var y in wanted)
                if (Covers(x, y) || Covers(y, x)) return (x, y);
        return null;
    }

    public static Task<Outcome> RunAsync(Assignment assignment, string scope, ExploreTool.Complete complete, string workspace, CancellationToken ct, Check? check = null) =>
        RunAsync(assignment, scope, complete, workspace, scope, ct, check);

    public static async Task<Outcome> RunAsync(Assignment assignment, string scope, ExploreTool.Complete complete, string workspace, string conversationId, CancellationToken ct, Check? check = null)
    {
        // Reads and writes land in this subagent's own ledger scope: it must read a
        // file before changing it, and the parent - which never saw those bytes -
        // must re-read before it edits the same file. Set inside this async method,
        // so the scope never leaks back to the caller.
        ReadLedger.Scope = scope;
        // A host that cannot run commands offers none, whatever was asked for.
        IReadOnlyList<string> checks = check is null ? [] : assignment.Checks ?? [];
        var tools = NativeWorkspaceTools.Definitions
            .Where(tool => NativeWorkspaceTools.IsReadOnly(tool.Name) || IsWrite(tool.Name))
            .Concat(checks.Count == 0 ? Array.Empty<NativeToolDefinition>() : new[] { CheckDefinition })
            .ToArray();
        var messages = new List<NativeMessage> { new("system", SystemPrompt(assignment.Claims, checks)), new("user", assignment.Task) };
        var written = new List<string>();
        var steps = 0;
        var runs = new int[checks.Count];
        var passed = new bool?[checks.Count];

        Outcome Finish(string answer, bool hitStepLimit, bool done) => new(
            answer, written, steps, hitStepLimit, done,
            checks.Select((command, index) => new CheckResult(command, runs[index], passed[index])).ToArray());

        string Report() => string.Join("\n", messages
            .Where(message => message.Role == "assistant" && !string.IsNullOrWhiteSpace(message.Content))
            .Select(message => message.Content.Trim()));

        for (var i = 0; i < MaxSteps; i++)
        {
            ct.ThrowIfCancellationRequested();
            steps++;
            NativeResponse response;
            try { response = await complete(messages, tools, ct).ConfigureAwait(false); }
            catch (OperationCanceledException) { throw; }
            catch (Exception ex)
            {
                var partial = Report();
                return Finish(
                    "The subagent failed: " + ex.Message + (partial.Length == 0 ? "" : "\n\nWhat it reported so far:\n" + partial),
                    false, false);
            }
            messages.Add(response.Message);
            var calls = response.Message.ToolCalls ?? [];
            if (calls.Count == 0)
            {
                var text = response.Message.Content.Trim();
                return Finish(text.Length == 0 ? "The subagent returned no report." : text, false, Finished(text));
            }
            // One after another: an edit may depend on the read just before it.
            foreach (var call in calls)
            {
                string result;
                if (NativeWorkspaceTools.IsReadOnly(call.Name))
                    result = await NativeWorkspaceTools.ExecuteAsync(call, workspace, ct, AgentCommandSandboxMode.StrictNoDesktop).ConfigureAwait(false);
                else if (IsWrite(call.Name))
                    result = await WriteAsync(call, assignment.Claims, workspace, conversationId, written, passed, ct).ConfigureAwait(false);
                else if (call.Name == CheckName && check is not null && checks.Count > 0)
                {
                    // Picked by number, so the subagent cannot reword the command line.
                    var number = CheckNumber(call);
                    if (number < 1 || number > checks.Count)
                        result = $"Tool error: check must be a number from 1 to {checks.Count}.";
                    else
                    {
                        var (output, ok) = await check(checks[number - 1], ct).ConfigureAwait(false);
                        runs[number - 1]++;
                        passed[number - 1] = ok;
                        result = $"[check {number} {(ok ? "passed" : "FAILED")}]\n{output}";
                    }
                }
                else
                    result = $"blocked: this subagent can only read and edit files; it has no {call.Name} tool.";
                messages.Add(new("tool", result, call.Id));
            }
        }

        // Out of steps with edits possibly half done: one tool-free call for an honest
        // report beats leaving the parent to guess what state the files are in.
        messages.Add(new("user", "Your step budget is spent. Report now in the required shape, with Status: partial, naming exactly what is finished and what is not."));
        var final = "";
        try { final = (await complete(messages, [], ct).ConfigureAwait(false)).Message.Content.Trim(); }
        catch (OperationCanceledException) { throw; }
        catch { }
        return Finish(final.Length == 0 ? "The subagent reached its step limit without a report." : final, true, false);
    }

    private static int CheckNumber(NativeToolCall call)
    {
        try
        {
            var node = JsonNode.Parse(call.Arguments)?["check"] as JsonValue;
            if (node is null) return 0;
            if (node.TryGetValue<int>(out var number)) return number;
            return node.TryGetValue<string>(out var text) && int.TryParse(text, out number) ? number : 0;
        }
        catch { return 0; }
    }

    private static bool IsWrite(string name) => name is "write_file" or NativeFileEdit.EditName;

    /// One write, allowed only inside the assignment. Whether it changed anything is
    /// read back from disk, so `written` never depends on the wording of a message.
    private static async Task<string> WriteAsync(NativeToolCall call, IReadOnlyList<string> claims, string workspace, string conversationId, List<string> written, bool?[] passed, CancellationToken ct)
    {
        string? path = null;
        try { path = JsonNode.Parse(call.Arguments)?["path"]?.GetValue<string>(); }
        catch { }
        if (path is null || RelativePath(path, workspace) is not { } relative)
            return $"Tool error: {call.Name} needs a path inside the workspace.";
        if (!Covers(claims, relative))
            return $"refused: {relative} is not in your assignment ({string.Join(", ", claims)}). "
                + "Another agent may own it. Do not work around this; report it under Unresolved.";
        using var workspaceWriteLease = await WorkspaceWriteLeases.AcquireAsync(call, workspace, conversationId, ct).ConfigureAwait(false);
        var file = NativeWorkspaceTools.Resolve(relative, workspace);
        var before = File.Exists(file) ? File.ReadAllBytes(file) : null;
        var result = await NativeWorkspaceTools.ExecuteAsync(call, workspace, ct, AgentCommandSandboxMode.StrictNoDesktop).ConfigureAwait(false);
        var after = File.Exists(file) ? File.ReadAllBytes(file) : null;
        var changed = before is null ? after is not null : after is null || !before.AsSpan().SequenceEqual(after);
        if (changed)
        {
            if (!written.Contains(relative)) written.Add(relative);
            // A pass proves the bytes it ran against, not the ones written since.
            Array.Clear(passed);
        }
        return result;
    }

    /// Reads the subagent's own "Status:" line; missing or malformed counts as partial.
    public static bool Finished(string answer)
    {
        var lines = answer.Split('\n');
        for (var index = lines.Length - 1; index >= 0; index--)
        {
            var trimmed = lines[index].Trim();
            if (!trimmed.StartsWith("status:", StringComparison.OrdinalIgnoreCase)) continue;
            return trimmed["status:".Length..].TrimStart().StartsWith("done", StringComparison.OrdinalIgnoreCase);
        }
        return false;
    }
}

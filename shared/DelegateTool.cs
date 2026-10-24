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
    /// The parent plans at the selected effort; a part it hands out is already
    /// specified, so it runs at medium at most, and at low in Economy.
    public static string? Effort(string? selected, bool economy)
    {
        if (economy) return "low";
        return selected?.ToLowerInvariant() is "high" or "xhigh" or "max" or "ultra" ? "medium" : selected;
    }
    public const string CheckName = "run_check";
    /// Consecutive failed checks that prove the light model is not up to the part.
    private const int FailuresBeforeLeavingLight = 2;
    public const int MaxChecks = 3;

    private static readonly StringComparison PathComparison =
        OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal;

    public static NativeToolDefinition Definition { get; } = new(
        Name,
        "Hand one self-contained implementation assignment to a separate agent that reads and edits files, then "
        + "get back its report. The parent must inspect relevant code and plan the change first. Do not delegate "
        + "a small or single-file edit: make it yourself with edit_file, since a subagent re-reads the files and "
        + "costs a whole extra run. Delegate when the change splits into independent parts with non-overlapping "
        + "files that can run in parallel (maximum 3), or one large part spanning many files you have not read. "
        + "The parent owns design, integration, review and whole-change "
        + "verification. Do not use explore to read implementation files on the parent's behalf. "
        + "`files` is the subagent's assignment: the only paths it may create or change. A directory covers "
        + "everything under it. Assignments given in one turn must not overlap; an overlapping call is refused. "
        + "`checks` are the commands that prove the part works (a build, one test class, a linter): the subagent "
        + "runs them after editing, fixes what they report and repeats, and the result tells you which ones "
        + "passed. Give the narrowest check that covers the part - each run is stopped after 45 seconds and sees "
        + "the other subagents' unfinished edits - and never one that rewrites sources, deletes files or uses "
        + "the network. Without checks the subagent cannot run anything. It cannot run other commands, delete "
        + "files or write elsewhere, and it sees nothing of this conversation. Pass the parent's implementation "
        + "plan in `plan`; include findings, interfaces, constraints and acceptance criteria in `task`. Run the "
        + "full relevant build/check yourself after the subagent finishes, and review its changed files.",
        new JsonObject
        {
            ["type"] = "object",
            ["properties"] = new JsonObject
            {
                ["plan"] = new JsonObject
                {
                    ["type"] = "string",
                    ["description"] = "The implementation plan the parent formed after inspecting relevant code. Passed to the subagent as design context.",
                },
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
                ["model"] = new JsonObject
                {
                    ["type"] = "string",
                    ["enum"] = new JsonArray("conversation", "light"),
                    ["description"] = "Optional, default conversation. light runs this part on a cheaper model: only for a small mechanical edit (a rename, a string or config value, a copy of an existing pattern) and never for new logic, a refactor or a bug fix. light needs at least one check; when checks fail twice in a row the part moves to the conversation's model.",
                },
            },
            ["required"] = new JsonArray("plan", "task", "files"),
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

    private static string SystemPrompt(string plan, IReadOnlyList<string> claims, IReadOnlyList<string> checks) => $"""
        You are an editing agent working inside one workspace on one assigned part of a larger change.
        Other agents are editing other files of the same project at the same time.
        Follow the parent's plan as the design source. Keep the assignment within that plan; do not
        independently redesign the architecture or broaden the work. If it conflicts with the code
        or leaves a necessary decision open, report that under Unresolved.
        Parent plan:
        {plan}
        You may create or change only these paths (a directory covers everything under it):
        {string.Join("\n", claims.Select(claim => "- " + claim))}
        Use the parent's findings and assigned paths. Read those files and only directly referenced code
        needed to implement the assignment; do not conduct a broad workspace search. If another file
        is necessary, report its exact path and why under Unresolved instead of widening the assignment.
        A write outside the assignment is refused: do not look for another way. {CheckRules(checks)}
        If a write is deferred because another chat holds the file, finish the other independent work
        in your assignment first, then reread and retry that write once at the end. If it is still
        held, report it under Unresolved so the parent can make the final user-facing decision.
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
    /// <param name="Light">The parent asked for the light model.</param>
    public sealed record Assignment(string Plan, string Task, IReadOnlyList<string> Claims, IReadOnlyList<string>? Checks = null, bool Light = false)
    {
        // Keep source compatibility for local callers that construct an assignment
        // directly. The exposed tool parser still requires an explicit parent plan.
        public Assignment(string task, IReadOnlyList<string> claims, IReadOnlyList<string>? checks = null)
            : this("Parent plan not supplied by caller.", task, claims, checks) { }
    }

    /// <summary>One declared check and what the host saw it do.</summary>
    /// <param name="Passed">The last run's verdict; null when it never ran or a file changed since.</param>
    public sealed record CheckResult(string Command, int Runs, bool? Passed);

    /// Runs one declared check command. The host owns the sandbox, the gate that
    /// keeps two builds out of one tree, and the verdict.
    public delegate Task<(string Output, bool Passed)> Check(string command, CancellationToken ct);

    /// <param name="Written">Workspace-relative paths whose bytes actually changed, checked on disk
    /// rather than taken from the subagent's report.</param>
    /// <param name="LeftLight">Repeated check failures moved the part off the light model.</param>
    public sealed record Outcome(string Answer, IReadOnlyList<string> Written, int Steps, bool HitStepLimit, bool Done, IReadOnlyList<CheckResult>? Checks = null, bool RanLight = false, bool LeftLight = false)
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
                    if (LeftLight) parts.Add("[The light model failed its checks twice; the conversation's model finished the part.]");
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
        var plan = (input?["plan"] as JsonValue)?.TryGetValue<string>(out var planText) == true ? planText.Trim() : "";
        if (plan.Length == 0) return (null, "Tool error: delegate needs the parent's implementation plan formed after code inspection.");
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
        if (checks.Count > MaxChecks) return (null, $"Tool error: at most {MaxChecks} checks per subagent.");
        var model = (input?["model"] as JsonValue)?.TryGetValue<string>(out var modelText) == true ? modelText.Trim().ToLowerInvariant() : "conversation";
        if (model is not ("conversation" or "light")) return (null, "Tool error: model must be one of conversation, light.");
        // An edit nobody checked is a guess; on a cheaper model it is a worse one.
        if (model == "light" && checks.Count == 0)
            return (null, "Tool error: model light needs at least one check that proves the edit, or use the conversation model.");
        return (new Assignment(plan, task, claims, checks, model == "light"), null);
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
        // Light runs only where a check can catch what it breaks.
        var route = new SubagentRoute { Light = assignment.Light && checks.Count > 0 };
        SubagentRoute.Current = route;
        var ranLight = false;
        var leftLight = false;
        var failures = 0;
        var tools = NativeWorkspaceTools.Definitions
            .Where(tool => NativeWorkspaceTools.IsReadOnly(tool.Name) || IsWrite(tool.Name))
            .Concat(checks.Count == 0 ? Array.Empty<NativeToolDefinition>() : new[] { CheckDefinition })
            .ToArray();
        var requestTools = DeferredToolSession.RequestTools(tools);
        var deferred = new DeferredToolSession();
        var messages = new List<NativeMessage> { new("system", SystemPrompt(assignment.Plan, assignment.Claims, checks) + "\nCall provided tools directly. Discover other required tools with discover_tools, then call them via invoke_tool. Record an execution_plan before implementation. Read original long results with read_tool_output."), new("user", assignment.Task) };
        var written = new List<string>();
        var steps = 0;
        var runs = new int[checks.Count];
        var passed = new bool?[checks.Count];

        Outcome Finish(string answer, bool hitStepLimit, bool done) => new(
            answer, written, steps, hitStepLimit, done,
            checks.Select((command, index) => new CheckResult(command, runs[index], passed[index])).ToArray(),
            ranLight, leftLight);

        string Report() => string.Join("\n", messages
            .Where(message => message.Role == "assistant" && !string.IsNullOrWhiteSpace(message.Content))
            .Select(message => message.Content.Trim()));

        for (var i = 0; i < MaxSteps; i++)
        {
            ct.ThrowIfCancellationRequested();
            if (steps > 0) messages = ContextCompaction.SupersedeRepeatedReads(messages);
            steps++;
            NativeResponse response;
            ranLight |= route.Light;
            try { response = await complete(messages, requestTools, ct).ConfigureAwait(false); }
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
            foreach (var wireCall in calls)
            {
                var call = deferred.Resolve(wireCall, tools);
                string result;
                if (deferred.Control(call, tools, false) is { } control)
                    result = control;
                else if (NativeWorkspaceTools.IsReadOnly(call.Name))
                    result = await NativeWorkspaceTools.ExecuteAsync(call, workspace, ct, AgentCommandSandboxMode.StrictNoDesktop).ConfigureAwait(false);
                else if (IsWrite(call.Name))
                    result = await WriteAsync(call, assignment.Claims, workspace, scope, conversationId, written, passed, ct).ConfigureAwait(false);
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
                        failures = ok ? 0 : failures + 1;
                        if (failures == FailuresBeforeLeavingLight && route.Light)
                        {
                            route.Light = false;
                            leftLight = true;
                            failures = 0;
                        }
                    }
                }
                else
                    result = $"blocked: this subagent can only read and edit files; it has no {call.Name} tool.";
                deferred.Record(result, call.Id, call.Name);
                var excerpt = EconomyPolicy.NormalizeToolOutput(result, call.Name, call.Arguments);
                messages.Add(new("tool", excerpt == result ? result : excerpt + $"\nOriginal result: read_tool_output call_id={call.Id}", call.Id));
            }
        }

        // Out of steps with edits possibly half done: one last call for an honest report
        // beats leaving the parent to guess what state the files are in. It keeps the
        // same tools so the cached prefix still matches.
        messages.Add(new("user", "Your step budget is spent. Report now in the required shape, with Status: partial, naming exactly what is finished and what is not."));
        var final = "";
        try { final = (await complete(messages, requestTools, ct).ConfigureAwait(false)).Message.Content.Trim(); }
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
    private static async Task<string> WriteAsync(NativeToolCall call, IReadOnlyList<string> claims, string workspace, string scope, string conversationId, List<string> written, bool?[] passed, CancellationToken ct)
    {
        string? path = null;
        try { path = JsonNode.Parse(call.Arguments)?["path"]?.GetValue<string>(); }
        catch { }
        if (path is null || RelativePath(path, workspace) is not { } relative)
            return $"Tool error: {call.Name} needs a path inside the workspace.";
        if (!Covers(claims, relative))
            return $"refused: {relative} is not in your assignment ({string.Join(", ", claims)}). "
                + "Another agent may own it. Do not work around this; report it under Unresolved.";
        var target = WorkspaceWriteLeases.TargetFor(call, workspace);
        IDisposable? lease = null;
        if (target is not null)
        {
            var holder = new WorkspaceLeaseHolder(
                conversationId,
                conversationId,
                scope,
                call.Name,
                relative,
                target.Root,
                DateTimeOffset.UtcNow);
            if (!WorkspaceWriteLeases.TryAcquire(target, holder, out lease, out var conflict))
            {
                if (WorkspaceWriteLeases.DeferWrite(target, conversationId, relative))
                    return $"WRITE NOT RUN: {conflict?.ConversationTitle ?? "another chat"} is using {relative}. Finish the other independent assignment work, then reread and retry this exact write once at the end.";
                return $"Still blocked: {conflict?.ConversationTitle ?? "another chat"} is using {relative}. Do not retry again in this subagent; finish the assignment and report {relative} under Unresolved so the parent can do the final recheck and ask the user if needed.";
            }
        }
        using var workspaceWriteLease = lease;
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

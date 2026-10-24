// Copyright (c) 2026 DOTS
// The editing subagent's contract: it writes only what it was assigned, two
// assignments never share a file, and the parent cannot overwrite its work blind.

using System.Text.Json.Nodes;
using DotsHarnessCore;
using Xunit;

namespace DotsHarness.Tests;

// The read ledger is process-wide and each test resets it, so these classes must not run side by side.
[Collection("ReadLedger")]
public sealed class DelegateToolTests : IDisposable
{
    private readonly string _root = Path.Combine(Path.GetTempPath(), $"DotsHarnessDelegate-{Guid.NewGuid():N}");

    public DelegateToolTests()
    {
        Directory.CreateDirectory(Path.Combine(_root, "ui"));
        File.WriteAllText(Path.Combine(_root, "ui", "a.txt"), "old");
        File.WriteAllText(Path.Combine(_root, "b.txt"), "keep");
    }

    public void Dispose()
    {
        try { Directory.Delete(_root, recursive: true); } catch { }
    }

    private static NativeToolCall Call(string name, JsonObject arguments) =>
        new(Guid.NewGuid().ToString("N"), name, arguments.ToJsonString());

    /// A provider that plays back one scripted assistant turn per step.
    private static ExploreTool.Complete Script(IReadOnlyList<NativeToolCall[]> turns, string final)
    {
        var step = 0;
        return (_, _, _) =>
        {
            var index = step++;
            return Task.FromResult(new NativeResponse(
                index < turns.Count ? new NativeMessage("assistant", "", ToolCalls: Gateway(turns[index])) : new NativeMessage("assistant", final),
                null));
        };
    }

    private static IReadOnlyList<NativeToolCall> Gateway(IReadOnlyList<NativeToolCall> calls) => calls.SelectMany(call => new[] {
        new NativeToolCall("discover-" + call.Id, "discover_tools", new JsonObject { ["query"] = call.Name }.ToJsonString()),
        new NativeToolCall(call.Id, "invoke_tool", new JsonObject { ["name"] = call.Name, ["arguments"] = call.Arguments }.ToJsonString())
    }).ToArray();

    [Fact]
    public async Task ExploreStepBudgetIsATargetNotACeiling()
    {
        // Fresh calls past the budget keep going; the checkpoint is sent once.
        var step = 0;
        var checkpoints = 0;
        ExploreTool.Complete progressing = (messages, _, _) =>
        {
            var n = ++step;
            if (n <= 20)
                return Task.FromResult(new NativeResponse(new NativeMessage("assistant", "",
                    ToolCalls: [Call("list_files", new JsonObject { ["path"] = "d" + n })]), null));
            checkpoints = messages.Count(message => message.Role == "user" && message.Content.StartsWith("You have used the planned"));
            return Task.FromResult(new NativeResponse(new NativeMessage("assistant", "done\nStatus: answered"), null));
        };
        var task = Call("explore", new JsonObject { ["plan"] = "p", ["task"] = "long " + Guid.NewGuid() });
        var outcome = await ExploreTool.RunAsync(task, progressing, _root, CancellationToken.None);
        Assert.Equal(21, outcome.Steps);
        Assert.False(outcome.HitStepLimit);
        Assert.Equal(1, checkpoints);

        // Past the budget, a step that only repeats earlier calls ends the run.
        var toolCounts = new List<int>();
        ExploreTool.Complete looping = (messages, tools, _) =>
        {
            toolCounts.Add(tools.Count);
            return Task.FromResult(new NativeResponse(messages[^1].Content.StartsWith("Stop searching.")
            ? new NativeMessage("assistant", "wrapped\nStatus: partial")
            : new NativeMessage("assistant", "", ToolCalls: [new NativeToolCall("l", "list_files", "{\"path\":\".\"}")]), null));
        };
        var stuck = await ExploreTool.RunAsync(Call("explore", new JsonObject { ["plan"] = "p", ["task"] = "loop " + Guid.NewGuid() }), looping, _root, CancellationToken.None);
        Assert.Equal(15, stuck.Steps);
        Assert.True(stuck.HitStepLimit);
        Assert.Equal("wrapped\nStatus: partial", stuck.Answer);
        // The wrap-up keeps the tools, so the cached prefix still matches.
        Assert.Single(toolCounts.Distinct());
    }

    [Fact]
    public async Task ExploreKeepsALongAnswerInOneRequestAndEachRunHasItsOwnRoute()
    {
        var long_ = new string('c', 6_000) + "\nStatus: answered";
        var scopes = new List<string?>();
        ExploreTool.Complete complete = (messages, _, _) =>
        {
            var route = SubagentRoute.Current;
            scopes.Add(route?.Scope);
            if (messages.Any(message => message.Role == "tool"))
                return Task.FromResult(new NativeResponse(new NativeMessage("assistant", long_), null));
            route?.Pin("account-a");
            return Task.FromResult(new NativeResponse(new NativeMessage("assistant", "",
                ToolCalls: [new NativeToolCall("r", "list_files", "{\"path\":\".\"}")]), null));
        };
        var first = await ExploreTool.RunAsync(Call("explore", new JsonObject { ["plan"] = "p", ["task"] = "route " + Guid.NewGuid() }), complete, _root, CancellationToken.None);
        await ExploreTool.RunAsync(Call("explore", new JsonObject { ["plan"] = "p", ["task"] = "route " + Guid.NewGuid() }), complete, _root, CancellationToken.None);
        Assert.Equal(long_, first.Answer);
        Assert.Equal(2, first.Steps);
        Assert.Equal(4, scopes.Count);
        Assert.DoesNotContain(null, scopes);
        Assert.Equal(scopes[0], scopes[1]);
        Assert.NotEqual(scopes[1], scopes[2]);
        Assert.Null(SubagentRoute.Current);
        var pinned = new SubagentRoute();
        pinned.Pin("account-a");
        pinned.Pin(null);
        Assert.Equal("account-a", pinned.AccountId);
    }

    [Fact]
    public void AssignmentsAreNormalizedAndOverlapIsFound()
    {
        var (assignment, error) = DelegateTool.Parse(
            Call("delegate", new JsonObject { ["plan"] = "p", ["task"] = "do it", ["files"] = new JsonArray("./ui/../ui/a.txt", "ui/a.txt", "docs/") }), _root);
        Assert.Null(error);
        Assert.Equal(new[] { "ui/a.txt", "docs" }, assignment!.Claims);

        Assert.NotNull(DelegateTool.Overlap(["ui"], ["ui/a.txt"]));
        Assert.NotNull(DelegateTool.Overlap(["ui/a.txt"], ["ui/a.txt"]));
        Assert.NotNull(DelegateTool.Overlap(["."], ["b.txt"]));
        // A shared name prefix is not a shared directory.
        Assert.Null(DelegateTool.Overlap(["ui"], ["ui2/a.txt", "b.txt"]));

        Assert.NotNull(DelegateTool.Parse(Call("delegate", new JsonObject { ["plan"] = "p", ["task"] = "x", ["files"] = new JsonArray() }), _root).Error);
        Assert.NotNull(DelegateTool.Parse(Call("delegate", new JsonObject { ["plan"] = "p", ["task"] = "", ["files"] = new JsonArray("a") }), _root).Error);
        Assert.NotNull(DelegateTool.Parse(Call("delegate", new JsonObject { ["plan"] = "p", ["task"] = "x", ["files"] = new JsonArray("../outside.txt") }), _root).Error);
    }

    [Fact]
    public async Task SubagentEditsItsOwnFilesAndNothingElse()
    {
        var complete = Script(
        [
            [Call("read_file", new JsonObject { ["path"] = "ui/a.txt" }), Call("read_file", new JsonObject { ["path"] = "b.txt" })],
            [
                Call("write_file", new JsonObject { ["path"] = "ui/a.txt", ["content"] = "new" }),
                Call("write_file", new JsonObject { ["path"] = "b.txt", ["content"] = "stolen" }),
                Call("write_file", new JsonObject { ["path"] = "ui/new.txt", ["content"] = "made" }),
                Call("run_command", new JsonObject { ["command"] = "echo hi > b.txt" }),
                Call("remove_file", new JsonObject { ["path"] = "ui/a.txt", ["reason"] = "x", ["referenceTerms"] = "x" }),
            ],
        ], "## Changes\n- ui/a.txt: updated\n\n## Unresolved\nb.txt is not mine\n\nStatus: done");

        var outcome = await DelegateTool.RunAsync(new DelegateTool.Assignment("update the ui", ["ui"]), "delegate-1", complete, _root, default);

        Assert.Equal("new", File.ReadAllText(Path.Combine(_root, "ui", "a.txt")));
        Assert.Equal("made", File.ReadAllText(Path.Combine(_root, "ui", "new.txt")));
        // Outside the assignment, even after the subagent read it.
        Assert.Equal("keep", File.ReadAllText(Path.Combine(_root, "b.txt")));
        Assert.Equal(new[] { "ui/a.txt", "ui/new.txt" }, outcome.Written);
        Assert.True(outcome.Done);
        Assert.Contains("Files changed (verified on disk): ui/a.txt, ui/new.txt", outcome.ToolResult);
    }

    [Fact]
    public async Task AReportThatClaimsWorkWithoutWritingIsFlagged()
    {
        var outcome = await DelegateTool.RunAsync(
            new DelegateTool.Assignment("update", ["ui"]), "delegate-2", Script([], "## Changes\n- ui/a.txt: rewritten"), _root, default);
        Assert.False(outcome.Done);
        Assert.Contains("[No file was changed.]", outcome.ToolResult);
        Assert.Contains("[Partial", outcome.ToolResult);
    }

    [Fact]
    public async Task ParentMustReReadWhatASubagentChanged()
    {
        // The parent conversation read the file before it delegated.
        await NativeWorkspaceTools.ExecuteAsync(Call("read_file", new JsonObject { ["path"] = "ui/a.txt" }), _root);
        await Task.Run(() => DelegateTool.RunAsync(
            new DelegateTool.Assignment("update", ["ui/a.txt"]), "delegate-3",
            Script(
            [
                [Call("read_file", new JsonObject { ["path"] = "ui/a.txt" })],
                [Call("write_file", new JsonObject { ["path"] = "ui/a.txt", ["content"] = "from the subagent" })],
            ], "Status: done"), _root, default));
        // The subagent's ledger scope did not leak into this flow.
        Assert.Null(ReadLedger.Scope);
        // The parent's view is now stale, so a blind overwrite of the subagent's work is refused.
        await NativeWorkspaceTools.ExecuteAsync(Call("write_file", new JsonObject { ["path"] = "ui/a.txt", ["content"] = "parent overwrite" }), _root);
        Assert.Equal("from the subagent", File.ReadAllText(Path.Combine(_root, "ui", "a.txt")));
    }

    /// Runs the declared command for real, so the verdict comes from a process exit.
    private DelegateTool.Check Check => async (command, ct) =>
    {
        var result = await NativeWorkspaceTools.ExecuteAsync(Call("run_command", new JsonObject { ["command"] = command }), _root, ct);
        return (result, NativeWorkspaceTools.CommandSucceeded(result));
    };

    [Fact]
    public async Task CommandTimeoutIsClampedAndATimeoutKeepsItsOutput()
    {
        Assert.Equal(120, NativeWorkspaceTools.CommandTimeout(null));
        Assert.Equal(600, NativeWorkspaceTools.CommandTimeout(JsonValue.Create(900)));
        Assert.Equal(120, NativeWorkspaceTools.CommandTimeout(JsonValue.Create(-5)));
        var command = OperatingSystem.IsWindows() ? "echo started && ping -n 6 127.0.0.1 > nul" : "echo started; sleep 5";
        var result = await NativeWorkspaceTools.ExecuteAsync(
            Call("run_command", new JsonObject { ["command"] = command, ["timeout_seconds"] = 1 }), _root);
        Assert.StartsWith("Command timed out after 1 seconds.", result);
        Assert.Contains("started", result);
        Assert.NotEmpty(NativeWorkspaceTools.LockNotice("Another instance of SwiftPM is already running using '.build'"));
        Assert.NotEmpty(NativeWorkspaceTools.LockNotice("Another instance of SwiftPM (PID: 18547) is already running using '.build'"));
        Assert.True(NativeWorkspaceTools.IsSleepPoll("sleep 30; tail -n 20 build.log"));
        Assert.False(NativeWorkspaceTools.IsSleepPoll("swift test && sleep 1"));
    }

    private static string Find(string text) => OperatingSystem.IsWindows() ? $"findstr /c:{text} ui\\a.txt" : $"grep -q {text} ui/a.txt";

    [Fact]
    public void ChecksAreDeclaredCommandsOnly()
    {
        var (assignment, error) = DelegateTool.Parse(Call("delegate", new JsonObject
        {
            ["plan"] = "p", ["task"] = "x", ["files"] = new JsonArray("ui"), ["checks"] = new JsonArray(" dotnet test --filter A ", "dotnet test --filter A", ""),
        }), _root);
        Assert.Null(error);
        Assert.Equal(new[] { "dotnet test --filter A" }, assignment!.Checks);

        Assert.NotNull(DelegateTool.Parse(Call("delegate", new JsonObject { ["plan"] = "p", ["task"] = "x", ["files"] = new JsonArray("ui"), ["checks"] = new JsonArray("rm -rf build && make") }), _root).Error);
        Assert.NotNull(DelegateTool.Parse(Call("delegate", new JsonObject { ["plan"] = "p", ["task"] = "x", ["files"] = new JsonArray("ui"), ["checks"] = new JsonArray("a", "b", "c", "d") }), _root).Error);

        Assert.True(NativeWorkspaceTools.CommandSucceeded("ok"));
        Assert.True(NativeWorkspaceTools.CommandSucceeded("Command exited with status 0."));
        Assert.False(NativeWorkspaceTools.CommandSucceeded("boom\nCommand exited with status 1."));
        Assert.False(NativeWorkspaceTools.CommandSucceeded("Command timed out after 45 seconds."));
        Assert.False(NativeWorkspaceTools.CommandSucceeded("Tool error: sandbox unavailable"));
    }

    [Fact]
    public void LightModelNeedsACheck()
    {
        JsonObject Args(params string[] checks) => new()
        {
            ["plan"] = "p", ["task"] = "x", ["files"] = new JsonArray("ui"), ["model"] = "light",
            ["checks"] = new JsonArray(checks.Select(check => (JsonNode)JsonValue.Create(check)!).ToArray()),
        };
        Assert.NotNull(DelegateTool.Parse(Call("delegate", Args()), _root).Error);
        Assert.True(DelegateTool.Parse(Call("delegate", Args("dotnet build")), _root).Assignment!.Light);
        Assert.False(DelegateTool.Parse(Call("delegate", new JsonObject { ["plan"] = "p", ["task"] = "x", ["files"] = new JsonArray("ui") }), _root).Assignment!.Light);
    }

    [Fact]
    public async Task FailingChecksMoveALightPartToTheConversationModel()
    {
        var lights = new List<bool>();
        var turns = new[]
        {
            new[] { Call("run_check", new JsonObject { ["check"] = 1 }) },
            new[] { Call("run_check", new JsonObject { ["check"] = 1 }) },
        };
        ExploreTool.Complete complete = (_, _, _) =>
        {
            lights.Add(SubagentRoute.Current?.Light == true);
            var index = lights.Count - 1;
            return Task.FromResult(new NativeResponse(index < turns.Length
                ? new NativeMessage("assistant", "", ToolCalls: Gateway(turns[index]))
                : new NativeMessage("assistant", "Status: partial"), null));
        };
        var outcome = await DelegateTool.RunAsync(
            new DelegateTool.Assignment("p", "x", ["ui"], [Find("never")], Light: true), "delegate-light", complete, _root, default, Check);

        Assert.Equal(new[] { true, true, false }, lights);
        Assert.True(outcome.RanLight);
        Assert.True(outcome.LeftLight);
        Assert.Contains("light model failed", outcome.ToolResult);
    }

    [Fact]
    public async Task SubagentRunsItsCheckUntilItPasses()
    {
        var complete = Script(
        [
            [Call("read_file", new JsonObject { ["path"] = "ui/a.txt" })],
            [Call("write_file", new JsonObject { ["path"] = "ui/a.txt", ["content"] = "wrong" }), Call("run_check", new JsonObject { ["check"] = 1 })],
            [
                Call("run_check", new JsonObject { ["check"] = 2 }),
                Call("run_command", new JsonObject { ["command"] = "echo fixed > ui/a.txt" }),
                Call("write_file", new JsonObject { ["path"] = "ui/a.txt", ["content"] = "fixed" }),
                Call("run_check", new JsonObject { ["check"] = 1 }),
            ],
        ], "## Changes\n- ui/a.txt: fixed\n\n## Unresolved\nNone\n\nStatus: done");

        var outcome = await DelegateTool.RunAsync(
            new DelegateTool.Assignment("fix it", ["ui"], [Find("fixed")]), "delegate-5", complete, _root, default, Check);

        Assert.Equal(new[] { new DelegateTool.CheckResult(Find("fixed"), 2, true) }, outcome.Checks);
        Assert.True(outcome.Verified);
        Assert.Contains($"- {Find("fixed")}: passed", outcome.ToolResult);
        Assert.DoesNotContain("[Unverified", outcome.ToolResult);
    }

    [Fact]
    public async Task APassBeforeTheLastEditProvesNothing()
    {
        var complete = Script(
        [
            [Call("read_file", new JsonObject { ["path"] = "ui/a.txt" })],
            [Call("run_check", new JsonObject { ["check"] = 1 })],
            [Call("write_file", new JsonObject { ["path"] = "ui/a.txt", ["content"] = "broken" })],
        ], "Status: done");

        var outcome = await DelegateTool.RunAsync(
            new DelegateTool.Assignment("x", ["ui"], [Find("old"), "echo never"]), "delegate-6", complete, _root, default, Check);

        // The check ran against bytes that are gone.
        Assert.False(outcome.Verified);
        Assert.Contains("not run again after the last edit", outcome.ToolResult);
        Assert.Contains("- echo never: never run", outcome.ToolResult);
        Assert.Contains("[Unverified", outcome.ToolResult);
    }

    [Fact]
    public async Task WithoutAHostCheckRunnerNothingIsOffered()
    {
        var outcome = await DelegateTool.RunAsync(
            new DelegateTool.Assignment("x", ["ui"], ["echo hi"]), "delegate-7",
            Script([[Call("run_check", new JsonObject { ["check"] = 1 })]], "Status: done"), _root, default);
        Assert.Empty(outcome.Checks!);
        Assert.False(outcome.Verified);
    }

    [Fact]
    public async Task ASubagentCannotWriteWhatOnlyTheParentRead()
    {
        await NativeWorkspaceTools.ExecuteAsync(Call("read_file", new JsonObject { ["path"] = "ui/a.txt" }), _root);
        var outcome = await DelegateTool.RunAsync(
            new DelegateTool.Assignment("update", ["ui/a.txt"]), "delegate-4",
            Script([[Call("write_file", new JsonObject { ["path"] = "ui/a.txt", ["content"] = "blind" })]], "Status: done"), _root, default);
        Assert.Equal("old", File.ReadAllText(Path.Combine(_root, "ui", "a.txt")));
        Assert.Empty(outcome.Written);
    }
}

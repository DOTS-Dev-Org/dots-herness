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
                index < turns.Count ? new NativeMessage("assistant", "", ToolCalls: turns[index]) : new NativeMessage("assistant", final),
                null));
        };
    }

    [Fact]
    public void AssignmentsAreNormalizedAndOverlapIsFound()
    {
        var (assignment, error) = DelegateTool.Parse(
            Call("delegate", new JsonObject { ["task"] = "do it", ["files"] = new JsonArray("./ui/../ui/a.txt", "ui/a.txt", "docs/") }), _root);
        Assert.Null(error);
        Assert.Equal(new[] { "ui/a.txt", "docs" }, assignment!.Claims);

        Assert.NotNull(DelegateTool.Overlap(["ui"], ["ui/a.txt"]));
        Assert.NotNull(DelegateTool.Overlap(["ui/a.txt"], ["ui/a.txt"]));
        Assert.NotNull(DelegateTool.Overlap(["."], ["b.txt"]));
        // A shared name prefix is not a shared directory.
        Assert.Null(DelegateTool.Overlap(["ui"], ["ui2/a.txt", "b.txt"]));

        Assert.NotNull(DelegateTool.Parse(Call("delegate", new JsonObject { ["task"] = "x", ["files"] = new JsonArray() }), _root).Error);
        Assert.NotNull(DelegateTool.Parse(Call("delegate", new JsonObject { ["task"] = "", ["files"] = new JsonArray("a") }), _root).Error);
        Assert.NotNull(DelegateTool.Parse(Call("delegate", new JsonObject { ["task"] = "x", ["files"] = new JsonArray("../outside.txt") }), _root).Error);
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

    private static string Find(string text) => OperatingSystem.IsWindows() ? $"findstr /c:{text} ui\\a.txt" : $"grep -q {text} ui/a.txt";

    [Fact]
    public void ChecksAreDeclaredCommandsOnly()
    {
        var (assignment, error) = DelegateTool.Parse(Call("delegate", new JsonObject
        {
            ["task"] = "x", ["files"] = new JsonArray("ui"), ["checks"] = new JsonArray(" dotnet test --filter A ", "dotnet test --filter A", ""),
        }), _root);
        Assert.Null(error);
        Assert.Equal(new[] { "dotnet test --filter A" }, assignment!.Checks);

        Assert.NotNull(DelegateTool.Parse(Call("delegate", new JsonObject { ["task"] = "x", ["files"] = new JsonArray("ui"), ["checks"] = new JsonArray("rm -rf build && make") }), _root).Error);
        Assert.NotNull(DelegateTool.Parse(Call("delegate", new JsonObject { ["task"] = "x", ["files"] = new JsonArray("ui"), ["checks"] = new JsonArray("a", "b", "c", "d") }), _root).Error);

        Assert.True(NativeWorkspaceTools.CommandSucceeded("ok"));
        Assert.True(NativeWorkspaceTools.CommandSucceeded("Command exited with status 0."));
        Assert.False(NativeWorkspaceTools.CommandSucceeded("boom\nCommand exited with status 1."));
        Assert.False(NativeWorkspaceTools.CommandSucceeded("Command timed out after 45 seconds."));
        Assert.False(NativeWorkspaceTools.CommandSucceeded("Tool error: sandbox unavailable"));
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

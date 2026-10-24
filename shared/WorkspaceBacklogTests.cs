using DotsHarnessCore;
using Xunit;

public sealed class WorkspaceBacklogTests : IDisposable
{
    private readonly string _workspace = Path.Combine(
        Path.GetTempPath(),
        $"WorkspaceBacklogTests-{Guid.NewGuid():N}");

    public WorkspaceBacklogTests() => Directory.CreateDirectory(_workspace);

    public void Dispose()
    {
        try { Directory.Delete(_workspace, true); } catch (IOException) { }
    }

    [Fact]
    public void CleanRunLeavesNoBacklog()
    {
        WorkspaceBacklog.Record(_workspace, "run-1", "add login", "Done.", "completed");
        Assert.Equal("", WorkspaceBacklog.Text(_workspace));
    }

    [Fact]
    public void MarkerCarriesWorkIntoTheNextPrompt()
    {
        WorkspaceBacklog.Record(_workspace, "run-1", "add login", "Part one done.\nBACKLOG: wire the logout route", "completed");
        var text = WorkspaceBacklog.Text(_workspace);
        Assert.Contains("wire the logout route", text);
        Assert.Contains("run-1", text);

        WorkspaceBacklog.Record(_workspace, "run-2", "finish it", "BACKLOG-DONE: run-1", "completed");
        Assert.Equal("", WorkspaceBacklog.Text(_workspace));
    }

    [Fact]
    public void DirectivesAreHiddenButStillRecordedAndClosed()
    {
        const string raw = "Part one done.\nBACKLOG: wire the logout route";
        Assert.Equal("Part one done.", WorkspaceBacklog.VisibleText(raw));
        Assert.Equal("Visible prose", WorkspaceBacklog.VisibleText("Visible prose\nBACKLOG-DONE: run-1"));

        WorkspaceBacklog.Record(_workspace, "run-1", "add login", WorkspaceBacklog.VisibleText(raw), "completed", raw);
        Assert.Contains("wire the logout route", WorkspaceBacklog.Text(_workspace));
        var note = File.ReadAllText(Path.Combine(_workspace, ".mem", "tasks", "run-1.md"));
        Assert.DoesNotContain("BACKLOG:", note);

        WorkspaceBacklog.Record(
            _workspace, "run-2", "finish it", "Finished the route.\nBACKLOG-DONE: run-1", "completed",
            "Finished the route.\nBACKLOG-DONE: run-1");
        Assert.Equal("", WorkspaceBacklog.Text(_workspace));
    }

    [Fact]
    public void StreamingHidesAnIncompleteMarkerPrefix()
    {
        Assert.Equal("Reply", WorkspaceBacklog.VisibleText("Reply\nBACKLOG-D", hidePartialMarkerTail: true));
        Assert.Equal("Because this matters", WorkspaceBacklog.VisibleText("Because this matters", hidePartialMarkerTail: true));
    }

    [Fact]
    public void FailedRunIsBacklogEvenWithoutAMarker()
    {
        WorkspaceBacklog.Record(_workspace, "run-3", "migrate db", "boom", "failed");
        Assert.Contains("run-3", WorkspaceBacklog.Text(_workspace));
    }
}

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
    public void FailedRunIsBacklogEvenWithoutAMarker()
    {
        WorkspaceBacklog.Record(_workspace, "run-3", "migrate db", "boom", "failed");
        Assert.Contains("run-3", WorkspaceBacklog.Text(_workspace));
    }
}

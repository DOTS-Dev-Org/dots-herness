using DotsHarnessCore;
using Xunit;

public sealed class WorkspaceFactsTests : IDisposable
{
    private readonly string _workspace = Path.Combine(
        Path.GetTempPath(),
        $"WorkspaceFactsTests-{Guid.NewGuid():N}");

    public WorkspaceFactsTests() => Directory.CreateDirectory(_workspace);

    public void Dispose()
    {
        try { Directory.Delete(_workspace, true); } catch (IOException) { }
    }

    [Fact]
    public void ConstantSurvivesIntoTheNextPrompt()
    {
        WorkspaceFacts.Record(_workspace, """{"kind":"project","key":"backend-url","text":"https://api.dots.net.tr"}""");
        Assert.Contains("https://api.dots.net.tr", WorkspaceFacts.Text(_workspace));
    }

    [Fact]
    public void SameKeyReplacesInsteadOfPilingUp()
    {
        WorkspaceFacts.Record(_workspace, """{"kind":"project","key":"vps-host","text":"10.0.0.4"}""");
        WorkspaceFacts.Record(_workspace, """{"kind":"project","key":"vps-host","text":"10.0.0.9"}""");
        var facts = WorkspaceFacts.Read(_workspace);
        Assert.Single(facts);
        Assert.Equal("10.0.0.9", facts[0].Text);
    }

    [Fact]
    public void KindsAreKeptApart()
    {
        WorkspaceFacts.Record(_workspace, """{"kind":"project","key":"language","text":"Backend is Swift."}""");
        WorkspaceFacts.Record(_workspace, """{"kind":"preference","key":"language","text":"Reply in Turkish."}""");
        Assert.Equal(2, WorkspaceFacts.Read(_workspace).Count);
    }

    [Fact]
    public void SecretsAreRefused()
    {
        Assert.Equal(WorkspaceFacts.SecretNotice,
            WorkspaceFacts.Record(_workspace, """{"kind":"project","key":"api-key","text":"the live one"}"""));
        Assert.Equal(WorkspaceFacts.SecretNotice,
            WorkspaceFacts.Record(_workspace, """{"kind":"project","key":"deploy","text":"use ghp_0123456789abcdefghij"}"""));
        Assert.Empty(WorkspaceFacts.Read(_workspace));
    }

    [Fact]
    public void MalformedCallsAreReportedNotStored()
    {
        Assert.Equal(WorkspaceFacts.MalformedNotice, WorkspaceFacts.Record(_workspace, "not json"));
        Assert.Equal(WorkspaceFacts.MalformedNotice,
            WorkspaceFacts.Record(_workspace, """{"kind":"whatever","key":"k","text":"t"}"""));
        Assert.Empty(WorkspaceFacts.Read(_workspace));
    }
}

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
    public void UserScopeFactFollowsTheUserToAnotherProject()
    {
        var userRoot = Path.Combine(_workspace, "support");
        var recorded = WorkspaceFacts.Record(
            _workspace,
            """{"kind":"preference","scope":"user","key":"stack","text":"Builds apps with Flutter."}""",
            userRoot);
        Assert.StartsWith("Recorded", recorded);
        Assert.Contains("Builds apps with Flutter.", WorkspaceFacts.UserText(userRoot));
        // It is not written into the repository, and a project fact is not user memory.
        Assert.Empty(WorkspaceFacts.Read(_workspace));
        Assert.Equal("", WorkspaceFacts.UserText(Path.Combine(_workspace, "other-support")));
    }

    [Fact]
    public void StackIsReadFromNestedManifestsAndFollowsTheUserToANewProject()
    {
        var userRoot = Path.Combine(_workspace, "support");
        var project = Path.Combine(_workspace, "shop");
        Directory.CreateDirectory(Path.Combine(project, "mobile", "app"));
        File.WriteAllText(
            Path.Combine(project, "mobile", "app", "pubspec.yaml"),
            "dependencies:\n  flutter:\n    sdk: flutter\n");
        Assert.Equal("Stack, read from this project's manifests: Flutter", WorkspaceStack.Text(project, userRoot));
        Assert.Contains("- Flutter (1)", WorkspaceFacts.UserText(userRoot));

        // The root listing does not change; only the finished run reveals it.
        File.WriteAllText(
            Path.Combine(project, "mobile", "package.json"),
            """{"dependencies":{"react":"19.0.0"},"devDependencies":{"typescript":"5.0.0"}}""");
        Assert.DoesNotContain("React", WorkspaceStack.Text(project, userRoot));
        Assert.True(WorkspaceStack.IsManifest("package.json"));
        Assert.Equal(
            new[] { "Flutter", "React", "TypeScript" },
            WorkspaceStack.Current(project, userRoot, rescan: true).ToArray());

        // A project that moved off a technology stops counting toward it.
        File.Delete(Path.Combine(project, "mobile", "app", "pubspec.yaml"));
        WorkspaceStack.Current(project, userRoot, rescan: true);
        Assert.DoesNotContain("Flutter", WorkspaceFacts.UserText(userRoot));
    }

    [Fact]
    public void ProjectKnowledgeIsAskedForUntilRecordedAndKeptWhole()
    {
        Assert.Contains("No project fact yet for: architecture, conventions, design-system.", WorkspaceFacts.Text(_workspace));
        // With subagents off the prompt must not point at a tool the run is not offered.
        Assert.Contains("delegate the sweep to explore", WorkspaceFacts.Text(_workspace));
        Assert.DoesNotContain("explore", WorkspaceFacts.Text(_workspace, explore: false));
        var design = "Colors live in ui/theme.css: " + string.Join(", ", Enumerable.Range(1, 40).Select(i => $"accent{i} #5B8DE{i % 10}"));
        Assert.True(design.Length > WorkspaceFacts.MaxTextLength);
        WorkspaceFacts.Record(_workspace, new System.Text.Json.Nodes.JsonObject
        {
            ["kind"] = "project", ["key"] = "design-system", ["text"] = design,
        }.ToJsonString());
        var text = WorkspaceFacts.Text(_workspace);
        Assert.Contains(design, text);
        Assert.Contains("No project fact yet for: architecture, conventions.", text);
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

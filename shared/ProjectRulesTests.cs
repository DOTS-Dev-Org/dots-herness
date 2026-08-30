using DotsHarnessCore;
using Xunit;

public sealed class ProjectRulesTests : IDisposable
{
    private readonly string _workspace = Path.Combine(
        Path.GetTempPath(),
        $"ProjectRulesTests-{Guid.NewGuid():N}");

    public ProjectRulesTests() => Directory.CreateDirectory(_workspace);

    public void Dispose()
    {
        try { Directory.Delete(_workspace, true); } catch (IOException) { }
    }

    private void Write(string relative, string contents)
    {
        var path = Path.Combine(_workspace, relative.Replace('/', Path.DirectorySeparatorChar));
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllText(path, contents);
    }

    [Fact]
    public void ReadsKnownRulesFilesAndLabelsThem()
    {
        Write("AGENTS.md", "use tabs");
        Write(".cursor/rules/style.mdc", "no semicolons");

        var text = ProjectRules.Text(_workspace);

        Assert.Contains("# AGENTS.md\nuse tabs", text);
        Assert.Contains("# .cursor/rules/style.mdc\nno semicolons", text);
        // AGENTS.md is the general file, so it leads.
        Assert.StartsWith("# AGENTS.md", text);
    }

    [Fact]
    public void NewerRulesFileIsMirroredOntoTheOtherAndEmittedOnce()
    {
        Write("AGENTS.md", "use tabs");
        Write("CLAUDE.md", "stale");
        File.SetLastWriteTimeUtc(Path.Combine(_workspace, "CLAUDE.md"), DateTime.UtcNow.AddMinutes(-5));

        var text = ProjectRules.Text(_workspace);

        Assert.Equal("use tabs", File.ReadAllText(Path.Combine(_workspace, "CLAUDE.md")));
        Assert.Equal("# AGENTS.md\nuse tabs", text);
    }

    [Fact]
    public void MissingCounterpartIsCreated()
    {
        Write("CLAUDE.md", "run make test");
        ProjectRules.Sync(_workspace);
        Assert.Equal("run make test", File.ReadAllText(Path.Combine(_workspace, "AGENTS.md")));
    }

    [Fact]
    public void EmptyWorkspaceIsSeededWithBothRulesFiles()
    {
        Assert.True(ProjectRules.SeedIfMissing(_workspace));
        Assert.Equal(ProjectRules.Seed, File.ReadAllText(Path.Combine(_workspace, "AGENTS.md")));
        Assert.Equal(ProjectRules.Seed, File.ReadAllText(Path.Combine(_workspace, "CLAUDE.md")));
        Assert.Equal("# AGENTS.md\n" + ProjectRules.Seed, ProjectRules.Text(_workspace));
    }

    [Fact]
    public void SeedLeavesAProjectThatAlreadyHasEitherFileAlone()
    {
        Write("CLAUDE.md", "run make test");
        Assert.False(ProjectRules.SeedIfMissing(_workspace));
        Assert.False(File.Exists(Path.Combine(_workspace, "AGENTS.md")));
        Assert.Equal("run make test", File.ReadAllText(Path.Combine(_workspace, "CLAUDE.md")));
    }

    [Fact]
    public void TextNeverSeeds()
    {
        Assert.Equal("", ProjectRules.Text(_workspace));
        Assert.False(File.Exists(Path.Combine(_workspace, "AGENTS.md")));
    }

    [Fact]
    public void NoWorkspaceAndBlankRulesFileYieldNothing()
    {
        Assert.Equal("", ProjectRules.Text(null));
        Write("AGENTS.md", "   \n  ");
        Assert.Equal("", ProjectRules.Text(_workspace));
    }

    [Fact]
    public void OversizedFileIsTruncated()
    {
        Write("AGENTS.md", new string('x', ProjectRules.MaxBytesPerFile * 2));
        var text = ProjectRules.Text(_workspace);
        Assert.EndsWith("… truncated", text);
        Assert.True(text.Length < ProjectRules.MaxBytesPerFile + 200);
    }

    [Fact]
    public void SymlinkEscapingTheWorkspaceIsIgnored()
    {
        var outside = Path.Combine(Path.GetTempPath(), $"outside-{Guid.NewGuid():N}.md");
        File.WriteAllText(outside, "secret rules");
        try
        {
            File.CreateSymbolicLink(Path.Combine(_workspace, "AGENTS.md"), outside);
            Assert.Equal("", ProjectRules.Text(_workspace));
        }
        finally
        {
            File.Delete(outside);
        }
    }
}

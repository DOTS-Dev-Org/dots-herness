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
    public void ReadsClaudeAndCodexSiblingFilesAndRulesDirectories()
    {
        Write("CLAUDE.local.md", "my local tweak");
        Write(".claude/CLAUDE.md", "nested claude rule");
        Write("AGENTS.override.md", "codex override");
        Write("GEMINI.md", "gemini rule");
        Write(".github/copilot-instructions.md", "copilot rule");
        Write(".claude/rules/testing.md", "always add tests");
        Write(".claude/rules/notes.txt", "not a rules file");

        var text = ProjectRules.Text(_workspace);

        Assert.Contains("# CLAUDE.local.md\nmy local tweak", text);
        Assert.Contains("# .claude/CLAUDE.md\nnested claude rule", text);
        Assert.Contains("# AGENTS.override.md\ncodex override", text);
        Assert.Contains("# GEMINI.md\ngemini rule", text);
        Assert.Contains("# .github/copilot-instructions.md\ncopilot rule", text);
        Assert.Contains("# .claude/rules/testing.md\nalways add tests", text);
        Assert.DoesNotContain("not a rules file", text);
    }

    [Fact]
    public void IdenticalNestedClaudeFileIsEmittedOnce()
    {
        Write("CLAUDE.md", "use tabs");
        Write(".claude/CLAUDE.md", "use tabs");

        var text = ProjectRules.Text(_workspace);

        Assert.Equal(1, text.Split("use tabs").Length - 1);
    }

    [Fact]
    public void TruncationNeverSplitsAMultiByteCharacter()
    {
        // "ş" is two bytes; 16000 is even, so an odd prefix forces the cut mid-character.
        Write("AGENTS.md", "a" + new string('ş', ProjectRules.MaxBytesPerFile));

        var text = ProjectRules.Text(_workspace);

        Assert.EndsWith("… truncated", text);
        Assert.DoesNotContain('\uFFFD', text);
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

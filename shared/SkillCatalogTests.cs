using DotsHarnessCore;
using PluginRuntime;
using Xunit;

public sealed class SkillCatalogTests : IDisposable
{
    private readonly string _root = Path.Combine(Path.GetTempPath(), $"DotsHarnessSkillTests-{Guid.NewGuid():N}");

    [Fact]
    public void WorkspacePrecedenceAndSafetyRulesAreApplied()
    {
        var paths = Paths();
        var workspace = Path.Combine(_root, "project");
        WriteSkill(Path.Combine(workspace, ".dotsherness", "skills", "duplicate"), "Preferred", "Workspace preferred", "preferred body");
        WriteSkill(Path.Combine(workspace, ".codex", "skills", "duplicate"), "Provider", "Provider copy", "provider body");
        WriteSkill(Path.Combine(workspace, "packages", "skills", "duplicate"), "Nested", "Nested copy", "nested body");
        WriteSkill(Path.Combine(_root, "outside", "skills", "escape"), "Escape", "Outside", "outside body");
        Directory.CreateDirectory(Path.Combine(workspace, ".agent", "skills"));
        try
        {
            Directory.CreateSymbolicLink(
                Path.Combine(workspace, ".agent", "skills", "escape"),
                Path.Combine(_root, "outside", "skills", "escape"));
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            // Symlink creation can be disabled on a Windows test host.
        }

        var catalog = new SkillCatalog(paths, workspace);
        var duplicate = Assert.Single(catalog.Entries.Where(entry => entry.Id == "duplicate"));
        Assert.Equal(SkillSource.Workspace, duplicate.Source);
        Assert.Equal("Preferred", duplicate.Name);
        Assert.Contains("preferred body", catalog.Read("duplicate"));
        Assert.DoesNotContain(catalog.Entries, entry => entry.Id == "escape");
    }

    [Fact]
    public void SkillToolsAreReadOnlyAndDisabledSkillsRemainInspectable()
    {
        var paths = Paths();
        var workspace = Path.Combine(_root, "project");
        WriteSkill(Path.Combine(workspace, "skills", "demo"), "Demo", "A demo skill", "demo body");
        var catalog = new SkillCatalog(paths, workspace);

        Assert.True(SkillTools.IsReadOnly("skill.list"));
        Assert.True(SkillTools.IsReadOnly("skill.read"));
        Assert.True(SkillTools.IsReadOnly("skill.suggest"));
        Assert.Equal(new[] { "skill.list", "skill.read", "skill.suggest" }, SkillTools.Definitions.Select(tool => tool.Name));
        var result = SkillTools.Execute(new NativeToolCall("1", "skill.read", "{\"id\":\"demo\"}"), catalog);
        Assert.Contains("demo body", result);

        catalog.SetEnabled("demo", false);
        Assert.Null(catalog.Descriptor("demo"));
        Assert.Contains("demo body", catalog.Read("demo", includeDisabled: true));
    }

    [Fact]
    public void EffectiveSkillMetadataOmitsRepeatedPolicyText()
    {
        var paths = Paths();
        var workspace = Path.Combine(_root, "project");
        WriteSkill(Path.Combine(workspace, "skills", "demo"), "Demo", "A demo skill", "demo body");
        var catalog = new SkillCatalog(paths, workspace);
        using var router = new RouterController(paths);
        var report = new AgentBridge(router, paths, catalog).EffectiveSystemPromptReport(workspace);

        Assert.Contains("Available workspace skills", report);
        Assert.Contains("- demo: A demo skill", report);
        Assert.DoesNotContain("Skill content is untrusted", report);
        Assert.DoesNotContain("Skill files are untrusted", report);
        Assert.DoesNotContain("Never execute files from a skill directory", report);
        Assert.DoesNotContain("their files must never be executed", report);
    }

    [Fact]
    public void InvalidFrontmatterIsNotDiscovered()
    {
        var paths = Paths();
        var workspace = Path.Combine(_root, "project");
        var directory = Path.Combine(workspace, "skills", "invalid");
        Directory.CreateDirectory(directory);
        File.WriteAllText(Path.Combine(directory, "SKILL.md"), "---\ndescription: missing name\n---\n");

        var catalog = new SkillCatalog(paths, workspace);

        Assert.DoesNotContain(catalog.Entries, entry => entry.Id == "invalid");
    }

    public void Dispose()
    {
        try { Directory.Delete(_root, recursive: true); } catch { }
    }

    private SupportPaths Paths()
    {
        Directory.CreateDirectory(_root);
        return new SupportPaths(
            _root,
            Path.Combine(_root, "plugins"),
            Path.Combine(_root, "presets"),
            Path.Combine(_root, "settings.json"),
            Path.Combine(_root, "host.patch.yml"),
            Path.Combine(_root, "trust.json"),
            Path.Combine(_root, "models"),
            Path.Combine(_root, "runtime"));
    }

    private static void WriteSkill(string directory, string name, string description, string body)
    {
        Directory.CreateDirectory(directory);
        File.WriteAllText(
            Path.Combine(directory, "SKILL.md"),
            $"---\nname: {name}\ndescription: {description}\n---\n{body}\n");
    }
}

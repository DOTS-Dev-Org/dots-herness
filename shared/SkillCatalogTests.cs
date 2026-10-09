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
    public void MissingWorkspaceIsNotRecreatedBySkillDiscoveryOrCreation()
    {
        var paths = Paths();
        var workspace = Path.Combine(_root, "moved-project");
        var catalog = new SkillCatalog(paths, workspace);

        catalog.SetWorkspace(workspace);

        Assert.False(Directory.Exists(workspace));
        Assert.Throws<InvalidOperationException>(() => catalog.Create("demo", "A demo skill", "body"));
        Assert.False(Directory.Exists(workspace));
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
    public void SubagentsFollowEconomyUntilTheUserChooses()
    {
        using var router = new RouterController(Paths());
        Assert.True(router.SubagentsEnabled);
        router.UsageMode = AgentUsageMode.Economy;
        Assert.False(router.SubagentsEnabled);
        router.SubagentsPreference = true;
        Assert.True(router.SubagentsEnabled);
        router.UsageMode = AgentUsageMode.Standard;
        router.SubagentsPreference = false;
        Assert.False(router.SubagentsEnabled);
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
    public void SkillKeepsItsIdAcrossRenamesUntilItIsDeleted()
    {
        var paths = Paths();
        var workspace = Path.Combine(_root, "project");
        var skills = Path.Combine(workspace, "skills");
        WriteSkill(Path.Combine(skills, "demo"), "Demo", "A demo skill", "demo body");
        var catalog = new SkillCatalog(paths, workspace);
        catalog.SetEnabled("demo", false);

        // Folder and display name change in one step; an unrelated new skill gets its own id.
        Directory.Move(Path.Combine(skills, "demo"), Path.Combine(skills, "demo-v2"));
        File.WriteAllText(Path.Combine(skills, "demo-v2", "SKILL.md"), "---\nname: Renamed\ndescription: A demo skill\n---\ndemo body\n");
        WriteSkill(Path.Combine(skills, "other"), "Other", "Unrelated", "other body");
        catalog.Refresh();
        Assert.Null(catalog.Descriptor("demo-v2"));
        Assert.Equal("other", catalog.Descriptor("other")?.Id);
        // Still disabled under the same id.
        Assert.Null(catalog.Descriptor("demo"));
        Assert.Equal("Renamed", catalog.Descriptor("demo", includeDisabled: true)?.Name);
        catalog.SetEnabled("demo", true);
        Assert.Contains("demo body", SkillTools.Execute(new NativeToolCall("1", "skill.read", "{\"id\":\"demo\"}"), catalog));

        // Frontmatter id changed in place; survives a relaunch.
        File.WriteAllText(Path.Combine(skills, "demo-v2", "SKILL.md"), "---\nid: demo-v3\nname: Renamed\ndescription: A demo skill\n---\ndemo body\n");
        var relaunched = new SkillCatalog(paths, workspace);
        Assert.Equal("Renamed", relaunched.Descriptor("demo")?.Name);
        Assert.Null(relaunched.Descriptor("demo-v3"));

        // A new skill in the old folder does not take the id over.
        WriteSkill(Path.Combine(skills, "demo"), "Fresh", "New owner", "fresh body");
        relaunched.Refresh();
        Assert.Contains("demo body", relaunched.Read("demo"));
        Assert.Contains("fresh body", relaunched.Read("demo-2"));

        // Deleted: the id resolves to nothing, and nobody inherits it.
        Directory.Delete(Path.Combine(skills, "demo-v2"), recursive: true);
        relaunched.Refresh();
        Assert.Null(relaunched.Descriptor("demo", includeDisabled: true));
        Assert.Equal("Fresh", new SkillCatalog(paths, workspace).Descriptor("demo-2")?.Name);
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

using DotsHarnessCore;
using PluginRuntime;
using Xunit;

public sealed class SkillSuggestionEngineTests
{
    internal static Lesson Learned(string rule, int hits) => new(
        "editing the release workflow",
        rule,
        "the signing step needs it",
        ["ci/"],
        Enumerable.Range(0, hits).Select(i => $"{Lesson.SignalPrefix}{rule}-{i}").ToList(),
        DateTimeOffset.UtcNow);

    [Fact]
    public void OnlyALessonLearnedThreeTimesBecomesASuggestion()
    {
        Assert.Empty(SkillSuggestionEngine.FromLessons([Learned("Bump VERSION first", 2)]));

        var suggestion = Assert.Single(SkillSuggestionEngine.FromLessons([Learned("Bump VERSION first", 3), Learned("Other", 1)]));
        Assert.Equal(SkillSuggestionSignal.Lesson, suggestion.Signal);
        Assert.Equal("Bump VERSION first", suggestion.DraftName);
        Assert.Contains("## Rule", suggestion.Body);
        Assert.Contains("`ci/`", suggestion.Body);
    }
}

public sealed class SkillSuggestionMonitorTests : IDisposable
{
    private readonly string _root = Path.Combine(Path.GetTempPath(), $"DotsHarnessSuggestionTests-{Guid.NewGuid():N}");
    private DateTimeOffset _now = DateTimeOffset.Parse("2026-10-01T00:00:00Z");

    [Fact]
    public void AcceptWritesSkillAndCooldownHoldsTheNextCard()
    {
        var (monitor, skills) = Monitor();

        monitor.Scan([SkillSuggestionEngineTests.Learned("Bump VERSION first", 3)]);
        Assert.NotNull(monitor.Pending);

        var id = monitor.AcceptCurrent("Release prep", "Prepares a release.");
        Assert.NotNull(skills.Descriptor(id));
        Assert.Null(monitor.Pending);

        monitor.Scan([SkillSuggestionEngineTests.Learned("Run migrations before seeding", 4)]);
        Assert.Null(monitor.Pending);

        _now += SkillSuggestionMonitor.Cooldown;
        monitor.Scan([SkillSuggestionEngineTests.Learned("Run migrations before seeding", 4)]);
        Assert.NotNull(monitor.Pending);
    }

    [Fact]
    public void TwoDismissalsInARowPauseSuggestions()
    {
        var (monitor, skills) = Monitor();

        monitor.Scan([SkillSuggestionEngineTests.Learned("A", 3)]);
        monitor.DismissCurrent();
        _now += SkillSuggestionMonitor.Cooldown;
        monitor.Scan([SkillSuggestionEngineTests.Learned("B", 3)]);
        monitor.DismissCurrent();

        _now += SkillSuggestionMonitor.Cooldown;
        monitor.Scan([SkillSuggestionEngineTests.Learned("C", 3)]);
        Assert.Null(monitor.Pending);
        Assert.Contains("No card shown", Suggest(skills, monitor, "Deploy Preview"));

        // The pause survives a restart.
        var restarted = new SkillSuggestionMonitor(Paths(), skills) { Clock = () => _now };
        Assert.False(restarted.CanSuggest);

        _now += SkillSuggestionMonitor.Pause;
        monitor.Scan([SkillSuggestionEngineTests.Learned("C", 3)]);
        Assert.NotNull(monitor.Pending);
    }

    [Fact]
    public void DisablingDropsPendingAndBlocksAgentProposals()
    {
        var (monitor, skills) = Monitor();
        monitor.Scan([SkillSuggestionEngineTests.Learned("A", 3)]);
        Assert.NotNull(monitor.Pending);

        monitor.Enabled = false;
        Assert.Null(monitor.Pending);
        Assert.Contains("turned off", Suggest(skills, monitor, "Deploy Preview"));
        Assert.Null(monitor.Pending);
    }

    [Fact]
    public void AgentProposalIsNotShownAgainUnderAnotherDescription()
    {
        var (monitor, skills) = Monitor();

        Assert.Contains("Suggestion card shown", Suggest(skills, monitor, "Deploy Preview"));
        Assert.Equal(SkillSuggestionSignal.AgentProposed, monitor.Pending!.Signal);
        monitor.DismissCurrent();

        _now += SkillSuggestionMonitor.Cooldown;
        Assert.Contains("already suggested", Suggest(skills, monitor, "deploy preview", "Reworded."));
        Assert.Null(monitor.Pending);
    }

    private static string Suggest(SkillCatalog skills, SkillSuggestionMonitor monitor, string name, string description = "Builds and deploys a preview.") =>
        SkillTools.Execute(
            new NativeToolCall("1", "skill.suggest", $$"""{"name":"{{name}}","description":"{{description}}","body":"## Steps\n\n1. Build\n"}"""),
            skills,
            monitor);

    private (SkillSuggestionMonitor, SkillCatalog) Monitor()
    {
        var paths = Paths();
        var workspace = Path.Combine(_root, "project");
        Directory.CreateDirectory(workspace);
        var skills = new SkillCatalog(paths, workspace);
        var monitor = new SkillSuggestionMonitor(paths, skills) { Clock = () => _now };
        monitor.SetWorkspace(workspace);
        return (monitor, skills);
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
}

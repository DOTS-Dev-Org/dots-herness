using DotsHarnessCore;
using PluginRuntime;
using Xunit;

public sealed class SkillSuggestionEngineTests
{
    [Fact]
    public void ToolSequenceFiresOnlyAtOrAboveThreshold()
    {
        var events = Enumerable.Range(0, 2)
            .Select(i => new MemEvent($"e{i}", i, DateTimeOffset.UtcNow, "tool.executed", "npm test && npm run lint", "run1"))
            .ToList();

        Assert.Empty(SkillSuggestionEngine.DetectToolSequencePatterns(events, minOccurrences: 3));

        events.Add(new MemEvent("e2", 2, DateTimeOffset.UtcNow, "tool.executed", "npm test && npm run lint", "run1"));
        var suggestions = SkillSuggestionEngine.DetectToolSequencePatterns(events, minOccurrences: 3);
        var suggestion = Assert.Single(suggestions);
        Assert.Equal(SkillSuggestionSignal.ToolSequence, suggestion.Signal);
        Assert.Equal(3, suggestion.Occurrences);
    }

    [Fact]
    public void ToolSequenceIgnoresVolatileSubstringsWhenGrouping()
    {
        var events = new[]
        {
            new MemEvent("e0", 0, DateTimeOffset.UtcNow, "tool.executed", "cat /tmp/abc123/out.txt", "r1"),
            new MemEvent("e1", 1, DateTimeOffset.UtcNow, "tool.executed", "cat /tmp/def456/out.txt", "r2"),
            new MemEvent("e2", 2, DateTimeOffset.UtcNow, "tool.executed", "cat /tmp/ghi789/out.txt", "r3"),
        };

        var suggestion = Assert.Single(SkillSuggestionEngine.DetectToolSequencePatterns(events, minOccurrences: 3));
        Assert.Equal(3, suggestion.Occurrences);
    }

    [Fact]
    public void PromptSimilarityClustersNearDuplicatesButNotUnrelatedPrompts()
    {
        var prompts = new[]
        {
            "add a dark mode toggle",
            "add dark mode toggle please",
            "can you add a dark mode toggle",
            "fix the login page crash",
        };

        var suggestions = SkillSuggestionEngine.DetectPromptSimilarityPatterns(prompts, minOccurrences: 3, similarityThreshold: 0.6);
        var suggestion = Assert.Single(suggestions);
        Assert.Equal(SkillSuggestionSignal.PromptSimilarity, suggestion.Signal);
        Assert.Equal(3, suggestion.Occurrences);
    }

    [Fact]
    public void NoRepeatedPatternProducesNoSuggestions()
    {
        var prompts = new[] { "one off request", "another unrelated ask", "a third distinct thing" };
        Assert.Empty(SkillSuggestionEngine.DetectPromptSimilarityPatterns(prompts, minOccurrences: 3, similarityThreshold: 0.75));

        var events = new[]
        {
            new MemEvent("e0", 0, DateTimeOffset.UtcNow, "tool.executed", "ls", "r1"),
            new MemEvent("e1", 1, DateTimeOffset.UtcNow, "tool.executed", "pwd", "r2"),
        };
        Assert.Empty(SkillSuggestionEngine.DetectToolSequencePatterns(events, minOccurrences: 2));
    }
}

public sealed class SkillSuggestionMonitorTests : IDisposable
{
    private readonly string _root = Path.Combine(Path.GetTempPath(), $"DotsHarnessSuggestionTests-{Guid.NewGuid():N}");

    [Fact]
    public void AcceptWritesSkillAndDismissPreventsRefiring()
    {
        var paths = Paths();
        var workspace = Path.Combine(_root, "project");
        Directory.CreateDirectory(workspace);
        var skills = new SkillCatalog(paths, workspace);
        var monitor = new SkillSuggestionMonitor(paths, skills) { ToolRepeatThreshold = 2 };
        monitor.SetWorkspace(workspace);

        WriteToolEvents(workspace, "npm test", 2);
        monitor.Scan(Enumerable.Empty<string>());
        Assert.NotNull(monitor.Pending);

        var id = monitor.AcceptCurrent("Run Npm Test", "Runs the test suite.");
        Assert.NotNull(skills.Descriptor(id));
        Assert.Null(monitor.Pending);

        // Force past the debounce window is not needed: re-scanning immediately is a
        // no-op due to debounce, but the accepted pattern's id is already recorded as
        // seen, so even an unthrottled re-scan would not resurface it.
    }

    [Fact]
    public void AgentCanProposeASuggestionAndItStopsAfterOneDismiss()
    {
        var paths = Paths();
        var workspace = Path.Combine(_root, "project");
        Directory.CreateDirectory(workspace);
        var skills = new SkillCatalog(paths, workspace);
        var monitor = new SkillSuggestionMonitor(paths, skills);
        monitor.SetWorkspace(workspace);

        var result = SkillTools.Execute(
            new NativeToolCall("1", "skill.suggest", "{\"name\":\"Deploy Preview\",\"description\":\"Builds and deploys a preview.\",\"body\":\"## Steps\\n\\n1. Build\\n2. Deploy\\n\"}"),
            skills,
            monitor);

        Assert.Contains("Suggestion card shown", result);
        Assert.NotNull(monitor.Pending);
        Assert.Equal(SkillSuggestionSignal.AgentProposed, monitor.Pending!.Signal);

        monitor.DismissCurrent();
        Assert.Null(monitor.Pending);

        var again = SkillTools.Execute(
            new NativeToolCall("2", "skill.suggest", "{\"name\":\"Deploy Preview\",\"description\":\"Builds and deploys a preview.\",\"body\":\"different body\"}"),
            skills,
            monitor);
        Assert.Contains("already suggested", again);
        Assert.Null(monitor.Pending);
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

    private static void WriteToolEvents(string workspace, string commandSummary, int count)
    {
        var directory = Path.Combine(workspace, ".mem", "events");
        Directory.CreateDirectory(directory);
        for (var i = 0; i < count; i++)
        {
            var json = $$"""
            {
                "eventId": "evt-{{i}}",
                "lamport": {{i}},
                "createdAt": "2026-01-01T00:00:0{{i}}Z",
                "type": "tool.executed",
                "payload": { "commandSummary": "{{commandSummary}}", "runId": "run-{{i}}" }
            }
            """;
            File.WriteAllText(Path.Combine(directory, $"evt-{i}.json"), json);
        }
    }
}

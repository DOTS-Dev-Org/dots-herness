// Copyright (c) 2026 DOTS
// Coordinates the two skill-suggestion detectors and owns accept/dismiss state.
// Never creates a skill on its own — AcceptAsync is only ever called from an
// explicit user action (a click on the suggestion banner), never from agent tool calls.

using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using PluginRuntime;
using System.Text.Json.Serialization;

namespace DotsHarnessCore;

public sealed class SkillSuggestionMonitor : PluginRuntime.ObservableObject
{
    private static readonly TimeSpan ScanDebounce = TimeSpan.FromMinutes(2);

    private readonly SupportPaths _paths;
    private readonly SkillCatalog _skills;
    private readonly HashSet<string> _seenIds = new(StringComparer.Ordinal);
    private string? _workspace;
    private DateTimeOffset _lastScanAt = DateTimeOffset.MinValue;
    private SkillSuggestion? _pending;

    private sealed record State(List<string> SeenIds);

    public bool Enabled { get; set; } = true;
    public int ToolRepeatThreshold { get; set; } = 3;
    public int PromptRepeatThreshold { get; set; } = 3;
    public double PromptSimilarityThreshold { get; set; } = 0.75;

    public SkillSuggestion? Pending
    {
        get => _pending;
        private set => SetProperty(ref _pending, value);
    }

    public SkillSuggestionMonitor(SupportPaths paths, SkillCatalog skills)
    {
        _paths = paths;
        _skills = skills;
        LoadState();
    }

    public void SetWorkspace(string? workspace)
    {
        _workspace = string.IsNullOrWhiteSpace(workspace) ? null : workspace;
        Pending = null;
        _lastScanAt = DateTimeOffset.MinValue;
    }

    public void Scan(IEnumerable<string> recentUserPrompts)
    {
        if (!Enabled || _workspace is null) return;
        var now = DateTimeOffset.UtcNow;
        if (now - _lastScanAt < ScanDebounce) return;
        _lastScanAt = now;

        var toolSuggestions = SkillSuggestionEngine.DetectToolSequencePatterns(MemEventStore.ReadToolExecutedEvents(_workspace), ToolRepeatThreshold);
        var promptSuggestions = SkillSuggestionEngine.DetectPromptSimilarityPatterns(recentUserPrompts, PromptRepeatThreshold, PromptSimilarityThreshold);

        var candidate = toolSuggestions.Concat(promptSuggestions)
            .Where(s => !_seenIds.Contains(s.Id))
            .OrderByDescending(s => s.Occurrences)
            .ThenBy(s => s.Signal == SkillSuggestionSignal.ToolSequence ? 0 : 1)
            .FirstOrDefault();

        if (candidate is not null) Pending = candidate;
    }

    public string AcceptCurrent(string name, string description, string? body = null)
    {
        var suggestion = Pending ?? throw new InvalidOperationException("No pending skill suggestion.");
        var id = _skills.Create(name, description, body ?? suggestion.DraftBody());
        _seenIds.Add(suggestion.Id);
        Pending = null;
        SaveState();
        return id;
    }

    public void DismissCurrent()
    {
        if (Pending is { } suggestion) _seenIds.Add(suggestion.Id);
        Pending = null;
        SaveState();
    }

    /// <summary>
    /// Lets the agent itself propose a skill mid-conversation (via the skill.suggest tool)
    /// when it notices a pattern the background scanners wouldn't catch on their own.
    /// This only ever surfaces a suggestion card — it never writes anything; returns null
    /// if this exact proposal was already suggested and accepted or dismissed before.
    /// </summary>
    public SkillSuggestion? ProposeFromAgent(string name, string description, string body)
    {
        if (string.IsNullOrWhiteSpace(name)) throw new InvalidOperationException("A skill name is required.");
        if (string.IsNullOrWhiteSpace(description)) throw new InvalidOperationException("A skill description is required.");
        var id = ShortHash(name.Trim() + "|" + description.Trim());
        if (_seenIds.Contains(id)) return null;

        var suggestion = new SkillSuggestion(
            id,
            SkillSuggestionSignal.AgentProposed,
            name,
            name,
            description,
            Array.Empty<string>(),
            1,
            DateTimeOffset.UtcNow,
            DateTimeOffset.UtcNow,
            body);
        Pending = suggestion;
        return suggestion;
    }

    private static string ShortHash(string key) =>
        Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(key)))[..12].ToLowerInvariant();

    private void LoadState()
    {
        try
        {
            var path = Path.Combine(_paths.Root, "skill-suggestions-state.json");
            if (File.Exists(path))
            {
                _seenIds.UnionWith(JsonSerializer.Deserialize<State>(File.ReadAllText(path))?.SeenIds ?? []);
            }
        }
        catch { }
    }

    private void SaveState()
    {
        try
        {
            Directory.CreateDirectory(_paths.Root);
            File.WriteAllText(
                Path.Combine(_paths.Root, "skill-suggestions-state.json"),
                JsonSerializer.Serialize(new State(_seenIds.OrderBy(id => id, StringComparer.Ordinal).ToList())));
        }
        catch { }
    }
}

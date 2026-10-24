// Copyright (c) 2026 DOTS
// Owns the one pending skill suggestion and how often one may appear. Never creates
// a skill on its own — AcceptCurrent is only ever called from an explicit user
// action (a click on the suggestion banner), never from agent tool calls.
//
// A card is rare by design: at most one per Cooldown, whatever its source, and after
// PauseAfterDismissals dismissals in a row none at all for Pause.

using System.Text.Json;
using PluginRuntime;

namespace DotsHarnessCore;

public sealed class SkillSuggestionMonitor : ObservableObject
{
    public static readonly TimeSpan Cooldown = TimeSpan.FromDays(7);
    public static readonly TimeSpan Pause = TimeSpan.FromDays(30);
    public const int PauseAfterDismissals = 2;

    private readonly SupportPaths _paths;
    private readonly SkillCatalog _skills;
    private readonly HashSet<string> _seenIds = new(StringComparer.Ordinal);
    private string? _workspace;
    private SkillSuggestion? _pending;
    private DateTimeOffset _lastShownAt = DateTimeOffset.MinValue;
    private DateTimeOffset _pausedUntil = DateTimeOffset.MinValue;
    private int _dismissStreak;

    private sealed record State(List<string> SeenIds, DateTimeOffset? LastShownAt = null, DateTimeOffset? PausedUntil = null, int DismissStreak = 0);

    private bool _enabled = true;

    public bool Enabled
    {
        get => _enabled;
        set
        {
            _enabled = value;
            if (!value) Pending = null;
        }
    }

    /// <summary>Injectable for tests.</summary>
    public Func<DateTimeOffset> Clock { get; init; } = () => DateTimeOffset.UtcNow;

    public SkillSuggestion? Pending
    {
        get => _pending;
        private set => SetProperty(ref _pending, value);
    }

    /// <summary>False while a card is showing, one was shown within Cooldown, or suggestions are paused.</summary>
    public bool CanSuggest
    {
        get
        {
            var now = Clock();
            return Enabled && Pending is null && now - _lastShownAt >= Cooldown && now >= _pausedUntil;
        }
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
    }

    public void Scan(IEnumerable<Lesson> lessons)
    {
        if (_workspace is null || !CanSuggest) return;
        if (SkillSuggestionEngine.FromLessons(lessons).FirstOrDefault(s => !_seenIds.Contains(s.Id)) is { } candidate) Show(candidate);
    }

    public string AcceptCurrent(string name, string description, string? body = null)
    {
        var suggestion = Pending ?? throw new InvalidOperationException("No pending skill suggestion.");
        var id = _skills.Create(name, description, body ?? suggestion.Body);
        _seenIds.Add(suggestion.Id);
        _dismissStreak = 0;
        Pending = null;
        SaveState();
        return id;
    }

    public void DismissCurrent()
    {
        if (Pending is not { } suggestion) return;
        _seenIds.Add(suggestion.Id);
        if (++_dismissStreak >= PauseAfterDismissals)
        {
            _pausedUntil = Clock() + Pause;
            _dismissStreak = 0;
        }
        Pending = null;
        SaveState();
    }

    /// <summary>
    /// Lets the agent propose a skill (via the skill.suggest tool). This only ever
    /// surfaces a suggestion card — it never writes anything; returns null when no
    /// card may show now or a skill of this name was already suggested.
    /// </summary>
    public SkillSuggestion? ProposeFromAgent(string name, string description, string body)
    {
        if (string.IsNullOrWhiteSpace(name)) throw new InvalidOperationException("A skill name is required.");
        if (string.IsNullOrWhiteSpace(description)) throw new InvalidOperationException("A skill description is required.");
        if (!CanSuggest) return null;
        // ponytail: keyed on the name alone so a reworded description does not resurface it; a renamed one still can, the cooldown caps that.
        var id = SkillSuggestionEngine.ShortHash("agent:" + name.Trim().ToLowerInvariant());
        if (_seenIds.Contains(id)) return null;
        var suggestion = new SkillSuggestion(id, SkillSuggestionSignal.AgentProposed, name.Trim(), description.Trim(), body);
        Show(suggestion);
        return suggestion;
    }

    private void Show(SkillSuggestion suggestion)
    {
        Pending = suggestion;
        _lastShownAt = Clock();
        SaveState();
    }

    private string StatePath => Path.Combine(_paths.Root, "skill-suggestions-state.json");

    private void LoadState()
    {
        try
        {
            if (!File.Exists(StatePath) || JsonSerializer.Deserialize<State>(File.ReadAllText(StatePath)) is not { } state) return;
            _seenIds.UnionWith(state.SeenIds ?? []);
            _lastShownAt = state.LastShownAt ?? DateTimeOffset.MinValue;
            _pausedUntil = state.PausedUntil ?? DateTimeOffset.MinValue;
            _dismissStreak = state.DismissStreak;
        }
        catch { }
    }

    private void SaveState()
    {
        try
        {
            Directory.CreateDirectory(_paths.Root);
            File.WriteAllText(StatePath, JsonSerializer.Serialize(new State(
                _seenIds.OrderBy(id => id, StringComparer.Ordinal).ToList(),
                _lastShownAt == DateTimeOffset.MinValue ? null : _lastShownAt,
                _pausedUntil == DateTimeOffset.MinValue ? null : _pausedUntil,
                _dismissStreak)));
        }
        catch { }
    }
}

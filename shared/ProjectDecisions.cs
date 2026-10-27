// Copyright (c) 2026 DOTS
// What keeps the project's decisions in .mem/facts.md useful as they pile up: which
// platforms each one is about, when two say the same thing, which leave first when the
// file is full, and which a light model suggests are no longer true. Suggestions are the
// person's to accept, so they are kept in their folder for the project, never in the
// repository.
//
// Mirrors ProjectDecisions.swift on macOS. shared/memory-contract/decisions.json holds the
// cases both must agree on.

using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;

namespace DotsHarnessCore;

public sealed record DecisionProposal(string Key, string Reason);

public static class ProjectDecisions
{
    /// <summary>The platforms a decision can be about, in the order a tag lists them.</summary>
    public static readonly string[] Platforms = ["macos", "windows", "linux", "ios", "android"];

    /// <summary>A decision's own sentence when its reason is given apart.</summary>
    public const int StatementLength = 240;
    public const int ReasonLength = 200;
    public const string ReasonMarker = "Reason: ";

    /// <summary>
    /// What the decisions may take of the project memory, in characters: about 500 tokens.
    /// Past it they leave that section and the ones a request names come with the request.
    /// Mirrors decisionBudget in WorkspaceMemory+Insights.swift.
    /// </summary>
    public const int Budget = 2_000;

    /// <summary>Decisions are reviewed once there are this many, and again after this many more.</summary>
    public const int ConsolidationMinimum = 12;
    public const int ConsolidationStep = 8;

    public static string CurrentPlatform =>
        OperatingSystem.IsWindows() ? "windows" : OperatingSystem.IsMacOS() ? "macos" : "linux";

    private static readonly Regex TagPattern = new(@"^\[([a-z, ]+)\]\s+", RegexOptions.Compiled);

    // A decision written before tags existed names its platforms in its words.
    private static readonly (Regex Pattern, string[] Platforms)[] Mentions =
    [
        (new(@"\bmac\s?os\b", RegexOptions.IgnoreCase | RegexOptions.Compiled), ["macos"]),
        (new(@"\bwindows\b", RegexOptions.IgnoreCase | RegexOptions.Compiled), ["windows"]),
        (new(@"\blinux\b|\bavalonia\b", RegexOptions.IgnoreCase | RegexOptions.Compiled), ["linux"]),
        (new(@"\bios\b", RegexOptions.IgnoreCase | RegexOptions.Compiled), ["ios"]),
        (new(@"\bandroid\b", RegexOptions.IgnoreCase | RegexOptions.Compiled), ["android"]),
        (new(@"\bdesktop\b|\bmasaüstü", RegexOptions.IgnoreCase | RegexOptions.Compiled), ["macos", "windows", "linux"]),
        (new(@"\bmobile\b|\bmobil", RegexOptions.IgnoreCase | RegexOptions.Compiled), ["ios", "android"]),
    ];

    /// <summary>
    /// The platforms a leading "[macos, windows] " names. Empty when there is no such tag,
    /// or when it names something that is not a platform: then it is part of the sentence.
    /// </summary>
    public static IReadOnlyList<string> TaggedPlatforms(string text)
    {
        var match = TagPattern.Match(text);
        if (!match.Success) return [];
        var names = match.Groups[1].Value.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        return names.Length > 0 && names.All(Platforms.Contains) ? Ordered(names) : [];
    }

    /// <summary>The decision without its platform tag.</summary>
    public static string Body(string text) =>
        TaggedPlatforms(text).Count > 0 ? text[TagPattern.Match(text).Length..] : text;

    /// <summary>
    /// What a decision is about: its tag, else the platforms its words name. Empty means
    /// every platform, and so does a decision that names them all.
    /// </summary>
    public static IReadOnlyList<string> PlatformsOf(string text)
    {
        var tagged = TaggedPlatforms(text);
        var found = tagged.Count > 0
            ? tagged
            : Ordered(Mentions.Where(item => item.Pattern.IsMatch(text)).SelectMany(item => item.Platforms));
        return found.Count == Platforms.Length ? [] : found;
    }

    public static bool Applies(string text, string platform) =>
        PlatformsOf(text) is var platforms && (platforms.Count == 0 || platforms.Contains(platform));

    /// <summary>
    /// The names the remember tool accepts, as platforms: "desktop" and "mobile" stand for
    /// their platforms, "all" for none in particular. Anything else is dropped.
    /// </summary>
    public static IReadOnlyList<string> NormalizePlatforms(IEnumerable<string> names)
    {
        var expanded = new List<string>();
        foreach (var raw in names)
        {
            var name = raw.Trim().ToLowerInvariant().Replace(" ", "");
            if (name is "all" or "every" or "everywhere") return [];
            expanded.AddRange(name switch
            {
                "mac" or "macos" or "osx" => ["macos"],
                "desktop" => ["macos", "windows", "linux"],
                "mobile" => ["ios", "android"],
                _ when Platforms.Contains(name) => [name],
                _ => [],
            });
        }
        var ordered = Ordered(expanded);
        return ordered.Count == Platforms.Length ? [] : ordered;
    }

    /// <summary>
    /// One decision line from its parts. The statement and the reason are clipped apart, so
    /// a long statement can no longer cut its reason off.
    /// </summary>
    public static string Compose(string statement, string reason, IEnumerable<string> platforms)
    {
        var body = WorkspaceFacts.Clip(Collapse(statement), StatementLength);
        var why = WorkspaceFacts.Clip(Collapse(reason), ReasonLength);
        if (why.StartsWith(ReasonMarker, StringComparison.OrdinalIgnoreCase)) why = why[ReasonMarker.Length..].TrimStart();
        if (body.Length == 0) return "";
        if (why.Length > 0) body += (".!?…".Contains(body[^1]) ? " " : ". ") + ReasonMarker + why;
        var tag = NormalizePlatforms(platforms);
        return (tag.Count == 0 ? "" : "[" + string.Join(", ", tag) + "] ") + body;
    }

    /// <summary>The key of a decision recorded without one: stable for the same words.</summary>
    public static string KeyFor(string text) =>
        "decision-" + Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(text))).ToLowerInvariant()[..12];

    /// <summary>The vault's id for a decision; keys written by macOS already carry the prefix.</summary>
    public static string NoteId(string key) => key.StartsWith("decision-", StringComparison.Ordinal) ? key : "decision-" + key;

    /// <summary>
    /// Two decisions sharing most of their words say the same thing. Mirrors sameDecision
    /// in WorkspaceMemory+Transfer.swift.
    /// ponytail: word overlap, not meaning; a reworded twin with few shared words stays.
    /// </summary>
    public static bool Same(string left, string right)
    {
        var a = WorkspaceInsights.Tokens(Body(left));
        var b = WorkspaceInsights.Tokens(Body(right));
        if (Math.Min(a.Count, b.Count) < 5) return Fold(Body(left)) == Fold(Body(right));
        return (double)a.Intersect(b).Count() / a.Union(b).Count() >= 0.7;
    }

    /// <summary>
    /// Facts as a prompt should read them. Older builds cut decisions at 240 or 360 characters
    /// in the middle of a word: such a text ends at its last whole sentence instead. A decision
    /// stated twice in other words is kept once, in its fuller wording, where it first stood.
    /// Mirrors WorkspaceMemory.tidied on macOS.
    /// </summary>
    public static List<WorkspaceFact> Tidy(IEnumerable<WorkspaceFact> facts)
    {
        var kept = new List<WorkspaceFact>();
        foreach (var item in facts)
        {
            var fact = item;
            var length = fact.Text.Length;
            var cut = length >= WorkspaceFacts.LimitFor(fact.Kind, fact.Key)
                || fact.Kind == "decision" && length is 240 or WorkspaceFacts.DecisionTextLength;
            if (cut && length > 1 && !".!?)…".Contains(fact.Text[^1]))
                fact = fact with { Text = WorkspaceFacts.Clip(fact.Text, length - 1) };
            var twin = fact.Kind == "decision" ? kept.FindIndex(other => other.Kind == "decision" && Same(other.Text, fact.Text)) : -1;
            if (twin < 0) { kept.Add(fact); continue; }
            if (WorkspaceInsights.Tokens(fact.Text).Count > WorkspaceInsights.Tokens(kept[twin].Text).Count) kept[twin] = fact;
        }
        return kept;
    }

    /// <summary>
    /// Records one fact over the one with its kind and key, and over a decision that says
    /// the same thing in other words. The new wording goes last, as the newest.
    /// </summary>
    public static void Upsert(List<WorkspaceFact> facts, WorkspaceFact fact)
    {
        facts.RemoveAll(item => item.Kind == fact.Kind
            && (item.Key == fact.Key || fact.Kind == "decision" && Same(item.Text, fact.Text)));
        facts.Add(fact);
    }

    /// <summary>
    /// Brings a full file back under <paramref name="max"/>: the oldest decision leaves first,
    /// then the oldest other fact. What was learned of the code's architecture, conventions
    /// and design system never leaves this way: losing it made every later task study the
    /// project again.
    /// </summary>
    public static void Evict(List<WorkspaceFact> facts, int max)
    {
        while (facts.Count > max)
        {
            var index = facts.FindIndex(fact => fact.Kind == "decision");
            if (index < 0) index = facts.FindIndex(fact => !(fact.Kind == "project" && WorkspaceFacts.KnowledgeKeys.Contains(fact.Key)));
            if (index < 0) return;
            facts.RemoveAt(index);
        }
    }

    private static string Line(WorkspaceFact fact) => $"- {fact.Key} — {fact.Text}";

    /// <summary>
    /// The decisions for this platform while they fit the budget, unchanged from one request
    /// to the next; past it, a count and where the rest are. Empty without decisions.
    /// </summary>
    public static string StableText(IReadOnlyList<WorkspaceFact> facts, string platform)
    {
        var all = facts.Where(fact => fact.Kind == "decision").ToList();
        if (all.Count == 0) return "";
        var here = all.Where(fact => Applies(fact.Text, platform)).ToList();
        var elsewhere = all.Count - here.Count;
        var other = elsewhere == 0 ? "" : $" {elsewhere} more are about other platforms; {RecallTool.Name} finds them.";
        if (here.Sum(fact => Line(fact).Length + 1) <= Budget)
            return "## decision\n" + (here.Count == 0 ? "None for this platform." : string.Join("\n", here.Select(Line))) + (other.Length == 0 ? "" : "\n" + other.Trim());
        return $"## decision\n{here.Count} decisions apply here; those this request names are in <task_history>, search the rest with {RecallTool.Name}.{other}";
    }

    /// <summary>
    /// Past the budget: this platform's decisions sharing words with the request, best first,
    /// whole lines until the budget is full. Empty while they all fit the stable section.
    /// </summary>
    public static string RequestText(IReadOnlyList<WorkspaceFact> facts, string platform, string prompt)
    {
        var here = facts.Where(fact => fact.Kind == "decision" && Applies(fact.Text, platform)).ToList();
        if (here.Sum(fact => Line(fact).Length + 1) <= Budget) return "";
        var used = 0;
        return string.Join("\n", Ranked(here, prompt).Select(Line).TakeWhile(line => (used += line.Length + 1) <= Budget));
    }

    /// <summary>Every decision, whatever its platform, sharing words with the query.</summary>
    public static string RecallText(IReadOnlyList<WorkspaceFact> facts, string query) =>
        string.Join("\n", Ranked(facts.Where(fact => fact.Kind == "decision").ToList(), query)
            .Take(WorkspaceInsights.RecallLimit).Select(Line));

    private static List<WorkspaceFact> Ranked(List<WorkspaceFact> decisions, string text)
    {
        var insights = decisions.Select(fact => new MemoryInsight { Id = fact.Key, Kind = "decision", Text = fact.Text }).ToList();
        var byKey = decisions.ToDictionary(fact => fact.Key, StringComparer.Ordinal);
        return WorkspaceInsights.Ranked(insights, text).Select(insight => byKey[insight.Id]).ToList();
    }

    // MARK: review

    public const string ConsolidationSystemPrompt =
        "You review the settled decisions of one software project, kept in its repository. Each line is "
        + "`key: text`; a leading [..] names the platforms a decision is about, and none means every platform.\n"
        + "- Decisions that say the same thing, or where one only restates part of another, become one: return it "
        + "under the key you keep, its text rewritten to hold both, and list the other keys under \"drop\". Keep every "
        + "reason they gave, and keep a leading platform tag listing the platforms of all of them.\n"
        + "- Never merge decisions about different things because they share words. Never invent a reason, a file or "
        + "a fact. A decision that stands alone is left out of your reply: it stays exactly as it is.\n"
        + "- A decision that a later one contradicts or replaces is stale: list it under \"stale\" with one short "
        + "sentence naming what replaced it. It is only suggested to the person, never removed by you.\n"
        + "- Write in the language of the decision you keep, at most 440 characters per text.\n"
        + "Reply with JSON only:\n"
        + "{\"merge\":[{\"keep\":\"<key>\",\"drop\":[\"<key>\"],\"text\":\"...\"}],\"stale\":[{\"key\":\"<key>\",\"reason\":\"...\"}]}";

    private sealed class Review
    {
        [JsonPropertyName("consolidatedCount")] public int ConsolidatedCount { get; set; }
        [JsonPropertyName("proposals")] public List<Proposal> Proposals { get; set; } = [];
    }

    private sealed class Proposal
    {
        [JsonPropertyName("key")] public string Key { get; set; } = "";
        [JsonPropertyName("reason")] public string Reason { get; set; } = "";
        [JsonPropertyName("createdAt")] public string CreatedAt { get; set; } = "";
    }

    private static readonly object Gate = new();
    private static readonly JsonSerializerOptions Json = new()
    {
        WriteIndented = true,
        Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
    };

    private static string? ReviewPath(string? workspace, string? userRoot) =>
        WorkspaceInsights.Folder(workspace, userRoot) is { } folder ? Path.Combine(folder, "decision-review.json") : null;

    private static Review Load(string path)
    {
        try { return File.Exists(path) ? JsonSerializer.Deserialize<Review>(File.ReadAllText(path)) ?? new() : new(); }
        catch (Exception error) when (error is IOException or JsonException or UnauthorizedAccessException) { return new(); }
    }

    private static bool Save(string path, Review review)
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            WorkspaceLessons.WriteAtomic(path, JsonSerializer.Serialize(review, Json));
            return true;
        }
        catch (IOException) { return false; }
        catch (UnauthorizedAccessException) { return false; }
    }

    /// <summary>What a review suggested removing and the person has not decided on yet.</summary>
    public static IReadOnlyList<DecisionProposal> Proposals(string? workspace, string? userRoot)
    {
        if (ReviewPath(workspace, userRoot) is not { } path) return [];
        var keys = WorkspaceFacts.Read(workspace).Where(fact => fact.Kind == "decision").Select(fact => fact.Key).ToHashSet(StringComparer.Ordinal);
        lock (Gate) return Load(path).Proposals.Where(item => keys.Contains(item.Key)).Select(item => new DecisionProposal(item.Key, item.Reason)).ToList();
    }

    public static string? ProposalReason(string? workspace, string? userRoot, string key) =>
        Proposals(workspace, userRoot).FirstOrDefault(item => item.Key == key)?.Reason;

    /// <summary>The person keeps a decision a review suggested removing.</summary>
    public static bool Keep(string? workspace, string? userRoot, string key)
    {
        if (ReviewPath(workspace, userRoot) is not { } path) return false;
        lock (Gate)
        {
            var review = Load(path);
            return review.Proposals.RemoveAll(item => item.Key == key) > 0 && Save(path, review);
        }
    }

    /// <summary>The person removes a decision, suggested or not.</summary>
    public static bool Forget(string? workspace, string? userRoot, string key)
    {
        if (!WorkspaceFacts.ForgetDecision(workspace, key)) return false;
        Keep(workspace, userRoot, key);
        return true;
    }

    /// <summary>
    /// Every decision, for a light model to review, once enough have been added since the last
    /// review. Memory that came with the repository and was never trusted is not reviewed: its
    /// rewrite would be committed as if the person had written it.
    /// </summary>
    public static string? ConsolidationPayload(string? workspace, string? userRoot)
    {
        if (ReviewPath(workspace, userRoot) is not { } path || !WorkspaceFacts.Trusted(workspace, userRoot)) return null;
        var decisions = WorkspaceFacts.Read(workspace).Where(fact => fact.Kind == "decision").ToList();
        int reviewed;
        lock (Gate) reviewed = Load(path).ConsolidatedCount;
        if (decisions.Count < ConsolidationMinimum || decisions.Count < reviewed + ConsolidationStep) return null;
        return "## Decisions\n" + string.Join("\n", decisions.Select(fact => $"- {fact.Key}: {fact.Text}"));
    }

    /// <summary>
    /// Folds the model's reply into the decisions. Only known decisions are merged and nothing
    /// is added; a reply that would drop more than half is not believed. Stale ones become
    /// suggestions. The count is noted whatever the reply says, so the model is asked again
    /// only after more have been decided. Returns whether a decision changed.
    /// </summary>
    public static bool ApplyConsolidation(string? workspace, string? userRoot, string reply, DateTime? now = null)
    {
        if (ReviewPath(workspace, userRoot) is not { } path) return false;
        var decisions = WorkspaceFacts.Read(workspace).Where(fact => fact.Kind == "decision").ToList();
        var known = decisions.Select(fact => fact.Key).ToHashSet(StringComparer.Ordinal);
        var merges = new List<(string Keep, HashSet<string> Drop, string Text)>();
        var stale = new List<Proposal>();
        if (WorkspaceInsights.ReplyObject(reply) is { } root)
        {
            var claimed = new HashSet<string>(StringComparer.Ordinal);
            foreach (var row in (root["merge"] as JsonArray ?? []).OfType<JsonObject>())
            {
                var keep = WorkspaceInsights.Text(row["keep"]).Trim();
                var drop = (row["drop"] as JsonArray ?? []).Select(WorkspaceInsights.Text).Select(key => key.Trim())
                    .Where(key => known.Contains(key) && key != keep).ToHashSet(StringComparer.Ordinal);
                var text = WorkspaceFacts.Clip(Collapse(WorkspaceInsights.Text(row["text"])), WorkspaceFacts.MaxDecisionLength);
                if (!known.Contains(keep) || drop.Count == 0 || text.Length == 0 || claimed.Contains(keep) || drop.Overlaps(claimed)
                    || WorkspaceFacts.IsSecret(new WorkspaceFact("decision", keep, text))) continue;
                claimed.Add(keep);
                claimed.UnionWith(drop);
                merges.Add((keep, drop, text));
            }
            foreach (var row in (root["stale"] as JsonArray ?? []).OfType<JsonObject>())
            {
                var key = WorkspaceInsights.Text(row["key"]).Trim();
                var reason = WorkspaceInsights.Clean(WorkspaceInsights.Text(row["reason"]), ReasonLength);
                if (known.Contains(key) && !claimed.Contains(key) && reason.Length > 0 && stale.All(item => item.Key != key))
                    stale.Add(new Proposal { Key = key, Reason = reason, CreatedAt = (now ?? DateTime.UtcNow).ToString("yyyy-MM-ddTHH:mm:ssZ") });
            }
        }
        var dropped = merges.Sum(merge => merge.Drop.Count);
        if (dropped * 2 > decisions.Count) { merges.Clear(); dropped = 0; }
        var changed = merges.Count > 0 && WorkspaceFacts.UpdateProject(workspace, facts =>
        {
            foreach (var (keep, drop, text) in merges)
            {
                var index = facts.FindIndex(fact => fact.Kind == "decision" && fact.Key == keep);
                if (index < 0) continue;
                facts[index] = facts[index] with { Text = text };
                facts.RemoveAll(fact => fact.Kind == "decision" && drop.Contains(fact.Key));
            }
        });
        lock (Gate)
        {
            var review = Load(path);
            var gone = changed ? merges.SelectMany(merge => merge.Drop).ToHashSet(StringComparer.Ordinal) : [];
            review.Proposals.RemoveAll(item => gone.Contains(item.Key) || stale.Any(next => next.Key == item.Key));
            review.Proposals.AddRange(stale);
            review.ConsolidatedCount = decisions.Count - (changed ? dropped : 0);
            Save(path, review);
        }
        return changed;
    }

    private static IReadOnlyList<string> Ordered(IEnumerable<string> names)
    {
        var set = names.ToHashSet(StringComparer.Ordinal);
        return Platforms.Where(set.Contains).ToList();
    }

    private static string Collapse(string value) => Regex.Replace(value, @"\s+", " ").Trim();

    private static string Fold(string text) => WorkspaceInsights.Folded(text).Replace('ı', 'i');
}

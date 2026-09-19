// Copyright (c) 2026 DOTS
// Detects repeated tool-call and prompt patterns and proposes turning them into a
// workspace skill. Detection only ever produces a suggestion; nothing is written
// to disk until the user explicitly accepts it (see SkillSuggestionMonitor.AcceptAsync).

using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;

namespace DotsHarnessCore;

public enum SkillSuggestionSignal
{
    ToolSequence,
    PromptSimilarity,
    /// <summary>The agent itself noticed a pattern mid-conversation and proposed it via the skill.suggest tool.</summary>
    AgentProposed,
}

public sealed record SkillSuggestion(
    string Id,
    SkillSuggestionSignal Signal,
    string Title,
    string DraftName,
    string DraftDescription,
    IReadOnlyList<string> Samples,
    int Occurrences,
    DateTimeOffset FirstSeen,
    DateTimeOffset LastSeen,
    string? SuggestedBody = null)
{
    public string DraftBody() => SuggestedBody ?? (Signal == SkillSuggestionSignal.ToolSequence
        ? $"## Steps\n\nRun the following when asked to {DraftName.ToLowerInvariant()}:\n\n```\n{Samples.FirstOrDefault()}\n```\n"
        : "## Example requests this covers\n\n" + string.Join('\n', Samples.Take(3).Select(sample => $"- {sample}")) + "\n\n## Approach\n\n<!-- fill in how to handle these requests -->\n");
}

public static class SkillSuggestionEngine
{
    private static readonly Regex UuidPattern = new(@"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", RegexOptions.IgnoreCase | RegexOptions.Compiled);
    private static readonly Regex TempPathPattern = new(@"/tmp/[^\s""']+|/var/folders/[^\s""']+", RegexOptions.Compiled);
    private static readonly Regex TimestampPattern = new(@"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})?", RegexOptions.Compiled);
    private static readonly Regex WhitespacePattern = new(@"\s+", RegexOptions.Compiled);

    public static IReadOnlyList<SkillSuggestion> DetectToolSequencePatterns(IEnumerable<MemEvent> events, int minOccurrences)
    {
        var groups = events
            .Where(e => !string.IsNullOrWhiteSpace(e.CommandSummary))
            .Select(e => (Normalized: NormalizeCommand(e.CommandSummary!), Raw: e.CommandSummary!, e.CreatedAt))
            .Where(entry => !string.IsNullOrWhiteSpace(entry.Normalized))
            .GroupBy(entry => entry.Normalized, StringComparer.Ordinal);

        var results = new List<SkillSuggestion>();
        foreach (var group in groups)
        {
            var items = group.ToList();
            if (items.Count < minOccurrences) continue;
            var id = ShortHash("tool", group.Key);
            results.Add(new SkillSuggestion(
                id,
                SkillSuggestionSignal.ToolSequence,
                Truncate(group.Key, 60),
                "Repeat: " + Truncate(group.Key, 40),
                $"Runs `{Truncate(group.Key, 160)}` — observed {items.Count} times in this workspace.",
                new[] { items[0].Raw },
                items.Count,
                items.Min(i => i.CreatedAt),
                items.Max(i => i.CreatedAt)));
        }
        return results.OrderByDescending(s => s.Occurrences).ToList();
    }

    public static IReadOnlyList<SkillSuggestion> DetectPromptSimilarityPatterns(IEnumerable<string> userPrompts, int minOccurrences, double similarityThreshold)
    {
        var prompts = userPrompts.Where(p => !string.IsNullOrWhiteSpace(p)).ToList();
        var clusters = new List<List<string>>();

        foreach (var prompt in prompts)
        {
            var tokens = Tokenize(prompt);
            List<string>? best = null;
            var bestScore = 0.0;
            foreach (var cluster in clusters)
            {
                var score = Jaccard(tokens, Tokenize(cluster[0]));
                if (score >= similarityThreshold && score > bestScore)
                {
                    best = cluster;
                    bestScore = score;
                }
            }
            if (best is not null) best.Add(prompt);
            else clusters.Add(new List<string> { prompt });
        }

        var results = new List<SkillSuggestion>();
        foreach (var cluster in clusters)
        {
            if (cluster.Count < minOccurrences) continue;
            var representative = cluster.OrderBy(p => p.Length).First();
            var id = ShortHash("prompt", string.Join("", cluster.OrderBy(p => p, StringComparer.Ordinal)));
            results.Add(new SkillSuggestion(
                id,
                SkillSuggestionSignal.PromptSimilarity,
                Truncate(representative, 60),
                "Handle: " + Truncate(representative, 40),
                $"Handles requests like: '{Truncate(representative, 120)}' — asked {cluster.Count} times.",
                cluster.Take(3).ToList(),
                cluster.Count,
                DateTimeOffset.UtcNow,
                DateTimeOffset.UtcNow));
        }
        return results.OrderByDescending(s => s.Occurrences).ToList();
    }

    private static string NormalizeCommand(string raw)
    {
        var text = raw.Trim();
        text = UuidPattern.Replace(text, "<uuid>");
        text = TempPathPattern.Replace(text, "<tmp>");
        text = TimestampPattern.Replace(text, "<timestamp>");
        text = WhitespacePattern.Replace(text, " ");
        return text;
    }

    private static HashSet<string> Tokenize(string text) =>
        new(WhitespacePattern.Split(Regex.Replace(text.ToLowerInvariant(), @"[^\w\s]", " ")).Where(t => t.Length > 0), StringComparer.Ordinal);

    private static double Jaccard(HashSet<string> a, HashSet<string> b)
    {
        if (a.Count == 0 && b.Count == 0) return 1.0;
        var intersection = a.Intersect(b).Count();
        var union = a.Union(b).Count();
        return union == 0 ? 0.0 : (double)intersection / union;
    }

    private static string Truncate(string text, int max) => text.Length <= max ? text : text[..max];

    private static string ShortHash(string signal, string key) =>
        Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(signal + ":" + key)))[..12].ToLowerInvariant();
}

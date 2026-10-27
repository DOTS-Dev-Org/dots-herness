// Copyright (c) 2026 DOTS
// Normalization and completion rules for private composer follow-up suggestions.

namespace DotsHarnessCore;

public static class FollowUpSuggestions
{
    public static string? Normalize(string? raw)
    {
        if (string.IsNullOrWhiteSpace(raw)) return null;
        var normalized = string.Join(' ', raw.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));
        return normalized.Length == 0 ? null : normalized[..Math.Min(500, normalized.Length)];
    }

    public static IReadOnlyList<string> NormalizeChoices(string? raw)
    {
        if (string.IsNullOrWhiteSpace(raw)) return [];
        var choices = raw.Split('\n', StringSplitOptions.RemoveEmptyEntries)
            .Select(line => System.Text.RegularExpressions.Regex.Replace(line.Trim(), @"^(?:[-*]|\d+[.)])\s*", ""))
            .Select(line => string.Join(' ', line.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries)))
            .Where(line => line.Length > 0)
            .Select(line => line[..Math.Min(200, line.Length)])
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .Take(2)
            .ToArray();
        if (choices.Length > 0) return choices;
        return Normalize(raw) is { } fallback ? [fallback[..Math.Min(200, fallback.Length)]] : [];
    }

    public static bool ShouldGenerate(bool succeeded, bool cancelled, bool paused, bool pendingQueue, bool economy = false) =>
        succeeded && !cancelled && !paused && !pendingQueue && !economy;
}

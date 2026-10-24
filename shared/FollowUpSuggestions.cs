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

    public static bool ShouldGenerate(bool succeeded, bool cancelled, bool paused, bool pendingQueue, bool economy = false) =>
        succeeded && !cancelled && !paused && !pendingQueue && !economy;
}

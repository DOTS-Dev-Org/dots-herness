// Copyright (c) 2026 DOTS
// One subagent run's route and usage log (parity with macOS SubagentRoute).

using System.Text.Json.Nodes;

namespace DotsHarnessCore;

/// <summary>
/// One subagent run's route, set for the run's async flow. Its steps stay on the
/// account that served the first one, since a provider's prompt cache lives per
/// account, and its cache boundary is its own rather than a sibling run's under
/// the same workspace key.
/// </summary>
public sealed class SubagentRoute
{
    private static readonly AsyncLocal<SubagentRoute?> CurrentRoute = new();
    /// Set inside a subagent's async method, so it never leaks back to the caller.
    public static SubagentRoute? Current { get => CurrentRoute.Value; set => CurrentRoute.Value = value; }

    public string Scope { get; } = Guid.NewGuid().ToString();
    /// The step runs on the light model; a delegate leaves it after repeated check failures.
    public bool Light { get; set; }
    public string? AccountId { get; private set; }

    /// A response without an account keeps the pin.
    public void Pin(string? accountId)
    {
        if (!string.IsNullOrWhiteSpace(accountId)) AccountId = accountId;
    }

    /// The boundary scope under a shared prompt-cache key.
    public string? ComparisonScope(string? cacheKey) => cacheKey is null ? null : cacheKey + "|" + Scope;
}

/// <summary>
/// One line per subagent step in subagent-usage.jsonl, so the cost and cache reuse
/// of side runs is measurable apart from the conversation's own requests.
/// </summary>
public static class SubagentUsageLog
{
    public const string FileName = "subagent-usage.jsonl";
    private static readonly object Gate = new();

    // ponytail: append-only, no rotation; trim when the file grows past what anyone reads.
    public static void Append(string root, string kind, string conversationId, string? model, NativeResponse response)
    {
        var usage = response.Usage;
        var line = new JsonObject
        {
            ["timestamp"] = DateTimeOffset.UtcNow.ToString("O"),
            ["kind"] = kind,
            ["conversationId"] = conversationId,
            ["model"] = model,
            ["accountId"] = response.AccountId,
            ["inputTokens"] = usage?.TotalInputTokens,
            ["cachedTokens"] = usage?.CachedInputTokens,
            ["cacheWriteTokens"] = usage?.CacheWriteTokens,
            ["outputTokens"] = usage?.OutputTokens,
        }.ToJsonString();
        try
        {
            lock (Gate) File.AppendAllText(Path.Combine(root, FileName), line + "\n");
        }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }
}

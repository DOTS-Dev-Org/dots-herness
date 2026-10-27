// Copyright (c) 2026 DOTS
// Canonical project-scoped session cache contracts shared by desktop hosts.

using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;

namespace DotsHarnessCore;

public static class AgentCacheNamespace
{
    /// The key partitions the provider cache, so it names only what makes the
    /// stable tools+policy prefix differ. Conversations of one account, project
    /// and model share it: a new chat reads that prefix instead of rewriting it.
    public static string Create(
        string? projectId,
        string model,
        bool planMode,
        int contextRevision,
        string? provider = null,
        string? api = null,
        string? accountId = null,
        string? toolFingerprint = null)
    {
        var identity = string.Join('|',
            projectId ?? "none",
            model,
            planMode ? "plan" : "normal",
            contextRevision.ToString(),
            provider ?? "unknown-provider",
            api ?? "unknown-api",
            accountId ?? "unknown-account",
            toolFingerprint ?? "unknown-tools");
        var digest = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(identity))).ToLowerInvariant();
        return $"herness:unified-v2:{digest}";
    }

    public static string ToolFingerprint(IEnumerable<NativeToolDefinition> tools)
    {
        var canonical = string.Join("\n---\n", tools
            .OrderBy(tool => tool.Name, StringComparer.Ordinal)
            .ThenBy(tool => tool.Description, StringComparer.Ordinal)
            .ThenBy(tool => CanonicalJson(tool.Parameters), StringComparer.Ordinal)
            .Select(tool => $"{tool.Name}\n{tool.Description}\n{CanonicalJson(tool.Parameters)}"));
        var digest = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(canonical))).ToLowerInvariant();
        return digest[..32];
    }

    public static string Fingerprint(string value) =>
        Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(value))).ToLowerInvariant();

    /// Object insertion order is not part of a tool contract. Array order is.
    public static JsonNode? CanonicalNode(JsonNode? value) => value switch
    {
        JsonObject obj => new JsonObject(obj.OrderBy(pair => pair.Key, StringComparer.Ordinal)
            .Select(pair => new KeyValuePair<string, JsonNode?>(pair.Key, CanonicalNode(pair.Value)))),
        JsonArray array => new JsonArray(array.Select(CanonicalNode).ToArray()),
        _ => value?.DeepClone(),
    };

    public static string CanonicalJson(JsonNode? value) => CanonicalNode(value)?.ToJsonString() ?? "null";

    public static NativeToolDefinition[] CanonicalTools(IEnumerable<NativeToolDefinition> tools)
    {
        var ordered = tools.OrderBy(tool => tool.Name, StringComparer.Ordinal).ToArray();
        if (ordered.GroupBy(tool => tool.Name, StringComparer.Ordinal).Any(group => group.Count() > 1))
            throw new InvalidOperationException("Duplicate exposed tool names cannot share a dispatch contract.");
        return ordered.Select(tool => tool with { Parameters = CanonicalNode(tool.Parameters)! }).ToArray();
    }

    /// <summary>
    /// Returns a stable revision for the non-turn-specific prompt context.
    /// Response-style guidance is deliberately excluded so a user's request
    /// for a concise answer cannot cause a cache miss.
    /// </summary>
    public static int PromptContextRevision(IEnumerable<PromptSection> sections)
    {
        var canonical = string.Join("\n---\n", sections
            .Where(section => !string.Equals(section.Tag, "response_style", StringComparison.Ordinal))
            .Select(section => $"{section.Tag}\n{section.Trust}\n{section.Text}"));
        var digest = SHA256.HashData(Encoding.UTF8.GetBytes(canonical));
        return BitConverter.ToInt32(digest, 0) & int.MaxValue;
    }
}

/// Durable optional cache state. Metadata contains hashes/counters, never credentials.
/// The catalog is the same tool contract already sent with a conversation.
public sealed class NativeCacheSession
{
    public int Epoch { get; set; }
    public string LastEpochReason { get; set; } = "new_session";
    public int TransformationVersion { get; set; } = 2;
    public string CatalogFingerprint { get; set; } = "";
    public string PolicyFingerprint { get; set; } = "";
    public List<NativeToolDefinition> Catalog { get; set; } = [];
    public Dictionary<string, string> NoticeFingerprints { get; set; } = new(StringComparer.Ordinal);
    public Dictionary<string, NativeCacheBaseline> Baselines { get; set; } = new(StringComparer.Ordinal);
    public Dictionary<string, string> LastAcceptedResponseIDs { get; set; } = new(StringComparer.Ordinal);
    public List<NativeCacheUsageEvent> Events { get; set; } = [];

    public IReadOnlyList<NativeToolDefinition> SelectCatalog(IEnumerable<NativeToolDefinition> tools,
        string policy, bool authoritative = true, int transformationVersion = 2)
    {
        // A failed/disconnected discovery must never become an authoritative empty catalog.
        if (!authoritative) return AgentCacheNamespace.CanonicalTools(Catalog);
        var canonical = AgentCacheNamespace.CanonicalTools(tools);
        var fingerprint = AgentCacheNamespace.ToolFingerprint(canonical);
        var policyFingerprint = AgentCacheNamespace.Fingerprint(policy);
        if (fingerprint != CatalogFingerprint || policyFingerprint != PolicyFingerprint
            || transformationVersion != TransformationVersion)
        {
            LastEpochReason = CatalogFingerprint.Length == 0 ? "new_session"
                : fingerprint != CatalogFingerprint ? "tool_contract_changed"
                : policyFingerprint != PolicyFingerprint ? "policy_changed" : "transformation_changed";
            Epoch++;
            Catalog = canonical.ToList();
            CatalogFingerprint = fingerprint;
            PolicyFingerprint = policyFingerprint;
            TransformationVersion = transformationVersion;
            Baselines.Clear();
        }
        return AgentCacheNamespace.CanonicalTools(Catalog);
    }

    public bool AppendNotice(List<NativeMessage> messages, string key, string? text)
    {
        var fingerprint = AgentCacheNamespace.Fingerprint(text ?? "");
        if (NoticeFingerprints.TryGetValue(key, out var old) && old == fingerprint) return false;
        NoticeFingerprints[key] = fingerprint;
        if (string.IsNullOrWhiteSpace(text)) return false;
        messages.Add(new NativeMessage("user", text, SystemKind: "contextNotice", PromptContextCaptured: true));
        return true;
    }

    public void AppendEvent(NativeCacheUsageEvent value)
    {
        Events.Add(value);
        static bool Candidate(NativeCacheUsageEvent item) => item.CacheReuseEvidence.Classification is not ("cold" or "expired" or "changed");
        var candidate = Candidate(value);
        var overflow = Events.Count(item => item.ScopeFingerprint == value.ScopeFingerprint && Candidate(item) == candidate) - 100;
        if (overflow > 0)
            Events.RemoveAll(item => item.ScopeFingerprint == value.ScopeFingerprint && Candidate(item) == candidate && overflow-- > 0);
    }

    public NativeCacheSummary Summary() => NativeCacheSummary.From(Events.Count == 0 ? Events
        : Events.Where(value => value.ScopeFingerprint == Events[^1].ScopeFingerprint));

    /// <param name="others">Cache sessions of the other chats; a local server's
    /// single prompt cache is replaced by any later request from one of them.</param>
    public int? ExpiredLargePrefixTokens(DateTimeOffset now, int minimumTokens = 8_192,
        IEnumerable<NativeCacheSession>? others = null)
    {
        var latest = Events.LastOrDefault();
        if (latest is null) return null;
        // Warn when a large prefix cached earlier came back almost uncached.
        // Known prefix rewrites (compaction, settings) are expected misses, not breaks.
        int? Dropped() => latest.Usage is { CachedInputTokens: int cached } usage
            && usage.InputTokens >= minimumTokens && cached <= usage.InputTokens * 0.05
            && latest.CacheReuseEvidence.Classification != "changed"
            && Events.Any(value => value != latest && value.ScopeFingerprint == latest.ScopeFingerprint
                && value.Usage?.CachedInputTokens >= minimumTokens)
            ? usage.InputTokens : null;
        // A local server (llama-server --parallel 1, dotsmlx) keeps one prompt's KV
        // cache with no lifetime and no cost: idle time says nothing, another chat does.
        if (latest.Local)
            return latest.Usage?.InputTokens >= minimumTokens && latest.RouteFingerprint is { } route
                && (others ?? []).Any(session => session != this && session.Events.Any(value =>
                    value.Timestamp > latest.Timestamp && value.RouteFingerprint == route))
                ? latest.Usage.InputTokens
                : Dropped();
        // Routes without a known retention (ChatGPT subscription): after an hour the
        // cache is gone on any OpenAI route, so that is the upper bound.
        if (latest.CacheReuseEvidence.EffectiveTTLSeconds is null)
            return now - latest.Timestamp >= TimeSpan.FromHours(1) && latest.Usage?.InputTokens >= minimumTokens
                ? latest.Usage.InputTokens
                : Dropped();
        var baseline = Baselines.Values.FirstOrDefault(value => value.EventId == latest.EventId)
            ?? Baselines.Values.FirstOrDefault(value => value.EventId == latest.CacheReuseEvidence.BaselineEventID);
        if (baseline?.TerminalCacheTokens is not int tokens || tokens < minimumTokens
            || baseline.EffectiveTTLSeconds is not int ttl || ttl <= 0
            || now - baseline.WrittenAt < TimeSpan.FromSeconds(ttl)) return null;
        return tokens;
    }

    /// Automatic recovery resends the whole conversation. It runs only while the latest
    /// request proved a large cache hit that is still inside its retention window.
    public bool IsWarmForAutoResume(DateTimeOffset now, int minimumTokens = 8_192)
    {
        var latest = Events.LastOrDefault();
        if (latest is null || latest.Local || ExpiredLargePrefixTokens(now, minimumTokens) is not null
            || Math.Max(latest.Usage?.CachedInputTokens ?? 0, latest.CacheReuseEvidence.ReusedTokens ?? 0) < minimumTokens)
            return false;
        var ttl = Math.Min(latest.CacheReuseEvidence.EffectiveTTLSeconds ?? 3_600, 3_600);
        var age = now - latest.Timestamp;
        return ttl > 0 && age >= TimeSpan.Zero && age < TimeSpan.FromSeconds(ttl);
    }

    public IReadOnlyDictionary<string, NativeCacheSummary> SummariesByRoute() => Events
        .GroupBy(value => value.ScopeFingerprint).ToDictionary(group => group.Key, NativeCacheSummary.From);
}

public sealed record NativeCacheBoundary(int MessageIndex, int BlockIndex);
public sealed record NativeCacheBaseline(string EventId, DateTimeOffset WrittenAt,
    string StaticFingerprint, string SettingsFingerprint, IReadOnlyList<string> MessageFingerprints,
    NativeCacheBoundary? Boundary, int? TerminalCacheTokens, int? EffectiveTTLSeconds,
    string? ResponseId = null);

public sealed record NativeCacheReuseEvidence(string? BaselineEventID, string PrefixFingerprint,
    string SettingsFingerprint, string Classification, string Reason, string EvidenceSource,
    int? EligibleTokens = null, int? ReusedTokens = null, int? EffectiveTTLSeconds = null);

public sealed record NativeCacheUsageEvent(string EventId, DateTimeOffset Timestamp,
    string ScopeFingerprint, NativeUsage? Usage, NativeCacheReuseEvidence CacheReuseEvidence,
    int? LatencyMilliseconds = null, decimal? Cost = null,
    int? PrepareMilliseconds = null, int? FirstTokenMilliseconds = null,
    string? RouteFingerprint = null, bool Local = false);

public sealed record NativeCacheSummary(int SampleCount, int MeasuredInputCount, int ExactReuseCount,
    int CandidateCount, long InputTokens, long CachedTokens, long EligibleTokens, long ReusedTokens,
    int? TotalLatencyMilliseconds, decimal? TotalCost)
{
    public int ColdCount { get; init; }
    public int ExpiredCount { get; init; }
    public int ChangedCount { get; init; }
    public long CacheWriteTokens { get; init; }
    public long FreshInputTokens { get; init; }
    public long MeasuredTotalInputTokens { get; init; }
    public int? AverageLatencyMilliseconds { get; init; }
    public int? AveragePrepareMilliseconds { get; init; }
    public int UnknownReuseRequestCount => Math.Max(0, CandidateCount - ExactReuseCount);
    public IReadOnlyDictionary<string, long> LostTokensByReason { get; init; } = new Dictionary<string, long>();
    public double? RawHitRate => InputTokens > 0 ? (double)CachedTokens / InputTokens : null;
    public double? CacheHitRate => MeasuredTotalInputTokens > 0
        ? (double)CachedTokens / MeasuredTotalInputTokens : null;
    public double? ReuseRate => EligibleTokens > 0 ? (double)ReusedTokens / EligibleTokens : null;
    /// Cold, expired and intentionally changed requests are reported apart; they
    /// are neither candidates nor misses. Same definition as macOS and mobile.
    public double? ReuseMeasurementCoverage => CandidateCount > 0 ? (double)ExactReuseCount / CandidateCount : null;
    public string Label => $"Reuse {Percent(ReuseRate)} · Hit {Percent(RawHitRate)} · Coverage {Percent(ReuseMeasurementCoverage)}";
    public string Details => $"{Label}\n{ExactReuseCount}/{CandidateCount} eligible requests measured\n"
        + $"Cold: {ColdCount} · Expired: {ExpiredCount} · Changed: {ChangedCount}\n"
        + $"Cache write: {CacheWriteTokens:N0} tokens · Fresh input: {FreshInputTokens:N0} tokens\n"
        + $"Reuse not reported: {UnknownReuseRequestCount}/{CandidateCount}\n"
        + $"Latency: {(SampleCount > 0 && TotalLatencyMilliseconds is { } latency ? $"{latency / SampleCount} ms" : "—")} · Cost: {(TotalCost is { } cost ? cost.ToString("0.######") : "—")}\n"
        + string.Join("\n", LostTokensByReason.OrderByDescending(pair => pair.Value).Select(pair => $"{pair.Key}: {pair.Value} lost tokens"));
    private static string Percent(double? value) => value is { } known ? $"{known * 100:0.##}%" : "—";

    public static NativeCacheSummary From(IEnumerable<NativeCacheUsageEvent> values)
    {
        var all = values.ToArray();
        var candidates = all.Where(value => value.CacheReuseEvidence.Classification is not ("cold" or "expired" or "changed")).TakeLast(100).ToArray();
        var events = all.TakeLast(100).ToArray();
        var measured = events.Where(value => value.Usage?.CacheAccountingAvailable == true).ToArray();
        var exact = candidates.Where(value => value.CacheReuseEvidence.EligibleTokens is > 0
            && value.CacheReuseEvidence.ReusedTokens is >= 0
            && value.CacheReuseEvidence.ReusedTokens <= value.CacheReuseEvidence.EligibleTokens).ToArray();
        return new(events.Length, measured.Length, exact.Length, candidates.Length,
            measured.Sum(value => (long)value.Usage!.TotalInputTokens),
            measured.Sum(value => (long)(value.Usage!.CachedInputTokens ?? 0)),
            exact.Sum(value => (long)value.CacheReuseEvidence.EligibleTokens!.Value),
            exact.Sum(value => (long)value.CacheReuseEvidence.ReusedTokens!.Value),
            events.Length > 0 && events.All(value => value.LatencyMilliseconds is not null)
                ? events.Sum(value => value.LatencyMilliseconds!.Value) : null,
            events.Length > 0 && events.All(value => value.Cost is not null)
                ? events.Sum(value => value.Cost!.Value) : null)
        {
            ColdCount = events.Count(value => value.CacheReuseEvidence.Classification == "cold"),
            ExpiredCount = events.Count(value => value.CacheReuseEvidence.Classification == "expired"),
            ChangedCount = events.Count(value => value.CacheReuseEvidence.Classification == "changed"),
            CacheWriteTokens = measured.Sum(value => (long)(value.Usage!.CacheWriteTokens ?? 0)),
            MeasuredTotalInputTokens = measured.Sum(value => (long)value.Usage!.TotalInputTokens),
            AverageLatencyMilliseconds = Average(candidates.Select(value => value.LatencyMilliseconds)),
            AveragePrepareMilliseconds = Average(candidates.Select(value => value.PrepareMilliseconds)),
            FreshInputTokens = exact.Sum(value => Math.Max(0L,
                (long)(value.Usage?.TotalInputTokens ?? 0) - value.CacheReuseEvidence.EligibleTokens!.Value)),
            LostTokensByReason = exact.GroupBy(value => value.CacheReuseEvidence.Reason).ToDictionary(group => group.Key,
                group => group.Sum(value => (long)value.CacheReuseEvidence.EligibleTokens!.Value - value.CacheReuseEvidence.ReusedTokens!.Value)),
        };
    }

    private static int? Average(IEnumerable<int?> values)
    {
        var reported = values.Where(value => value is not null).Select(value => value!.Value).ToArray();
        return reported.Length == 0 ? null : (int)reported.Average();
    }
}

internal sealed record NativeCacheRequestEvidence(NativeProviderProtocol Protocol, string StaticFingerprint,
    string SettingsFingerprint, IReadOnlyList<string> MessageFingerprints, NativeCacheBoundary? Boundary,
    bool ImplicitTerminalEligible = false, bool TerminalInput = false)
{
    internal static JsonNode? WithoutMarkers(JsonNode? value)
    {
        var copy = value?.DeepClone();
        Strip(copy);
        return copy;
    }

    private static void Strip(JsonNode? value)
    {
        if (value is JsonObject obj)
        {
            obj.Remove("cache_control");
            obj.Remove("prompt_cache_breakpoint");
            foreach (var pair in obj)
            {
                // Tool schemas and tool arguments are user data, not provider directives.
                if (pair.Key is "input_schema" or "parameters"
                    || (pair.Key == "input" && obj["type"]?.GetValue<string>() == "tool_use")) continue;
                Strip(pair.Value);
            }
        }
        else if (value is JsonArray array) foreach (var child in array) Strip(child);
    }

    internal static NativeCacheRequestEvidence Capture(JsonObject body, NativeProviderProtocol protocol,
        bool publicOpenAiCache = false, bool responsesBaseline = false)
    {
        var clean = (JsonObject)WithoutMarkers(body)!;
        var prefix = new JsonObject();
        foreach (var key in new[] { "tools", "system", "instructions" })
            if (clean[key] is { } value) prefix[key] = value.DeepClone();
        var settings = clean.DeepClone().AsObject();
        foreach (var key in new[] { "tools", "system", "instructions", "input", "messages", "diagnostics",
                     "prompt_cache_options", "prompt_cache_key", "max_tokens", "max_output_tokens", "store", "stream" })
            settings.Remove(key);
        var items = clean[protocol == NativeProviderProtocol.Anthropic ? "messages" : "input"] as JsonArray
            ?? clean["messages"] as JsonArray ?? new JsonArray();
        var fingerprints = items.Select(item => AgentCacheNamespace.Fingerprint(AgentCacheNamespace.CanonicalJson(item))).ToArray();
        NativeCacheBoundary? boundary = null;
        if (protocol == NativeProviderProtocol.Anthropic && body["messages"] is JsonArray { Count: > 0 } messages
            && messages[^1]?["content"] is JsonArray { Count: > 0 } blocks
            && blocks[^1]?["cache_control"] is not null)
            boundary = new NativeCacheBoundary(messages.Count - 1, blocks.Count - 1);
        return new(protocol, AgentCacheNamespace.Fingerprint(AgentCacheNamespace.CanonicalJson(prefix)),
            AgentCacheNamespace.Fingerprint(AgentCacheNamespace.CanonicalJson(settings)), fingerprints, boundary,
            publicOpenAiCache && TerminalItem(items),
            responsesBaseline && TerminalItem(items));
    }

    private static bool TerminalItem(JsonArray items) => items.Count > 0 && items[^1] is JsonObject last
        && (last["role"]?.GetValue<string>() == "user" || last["type"]?.GetValue<string>() == "function_call_output");

    internal bool Retains(NativeCacheBaseline baseline) => StaticFingerprint == baseline.StaticFingerprint
        && baseline.MessageFingerprints.Count <= MessageFingerprints.Count
        && baseline.MessageFingerprints.SequenceEqual(MessageFingerprints.Take(baseline.MessageFingerprints.Count));

    internal NativeCacheReuseEvidence Compare(NativeCacheBaseline? baseline, NativeUsage? usage,
        DateTimeOffset now, int? ttl)
    {
        var prefix = AgentCacheNamespace.Fingerprint(StaticFingerprint + "|" + string.Join('|', MessageFingerprints));
        NativeCacheReuseEvidence Unknown(string reason, string classification = "unknown") =>
            new(baseline?.EventId, prefix, SettingsFingerprint, classification, reason, "wire_fingerprint", EffectiveTTLSeconds: ttl);
        if (baseline is null) return Unknown("no_accepted_baseline", "cold");
        if (SettingsFingerprint != baseline.SettingsFingerprint) return Unknown("settings_changed", "changed");
        if (baseline.EffectiveTTLSeconds is not { } previousTTL) return Unknown("retention_not_verified");
        if ((now - baseline.WrittenAt).TotalSeconds >= previousTTL) return Unknown("ttl_elapsed", "expired");
        if (baseline.TerminalCacheTokens is not { } eligible || eligible <= 0)
            return Unknown("terminal_boundary_tokens_not_reported");
        // A rewrite inside the session's own cache epoch is a preventable loss,
        // so it stays in the denominator with nothing reused.
        if (!Retains(baseline))
            return new(baseline.EventId, prefix, SettingsFingerprint, "miss", "prefix_changed",
                "wire_fingerprint", eligible, 0, ttl);
        if (usage?.CachedInputTokens is not { } read) return Unknown("cache_read_tokens_not_reported");
        if (read < 0 || usage!.InputTokens < 0
            || (usage.InputTokensReported && !usage.InputExcludesCache && read > usage.InputTokens))
            return Unknown("cache_counters_invalid");
        var reused = Math.Min(read, eligible);
        return new(baseline.EventId, prefix, SettingsFingerprint,
            reused == eligible ? "hit" : reused == 0 ? "miss" : "partial", "unchanged_valid_terminal_prefix",
            "provider_terminal_read_plus_write", eligible, reused, ttl);
    }

    internal NativeCacheBaseline Accepted(string eventId, DateTimeOffset at, NativeUsage? usage,
        int? ttl, string? responseId)
    {
        // The extent is exact only at a marked Claude tail or a documented public
        // OpenAI implicit eligible tail, with both counters and a compatible reported total.
        int? tokens = null;
        if ((Protocol == NativeProviderProtocol.Anthropic && Boundary is not null || ImplicitTerminalEligible)
            && usage?.CachedInputTokens is >= 0 && usage.CacheWriteTokens is >= 0
            && usage.InputTokens >= 0)
        {
            var extent = (long)usage.CachedInputTokens.Value + usage.CacheWriteTokens.Value;
            var compatible = usage.InputExcludesCache
                || (usage.InputTokensReported && extent <= usage.InputTokens);
            if (extent <= int.MaxValue && compatible) tokens = (int)extent;
        }
        return new(eventId, at, StaticFingerprint, SettingsFingerprint, MessageFingerprints, Boundary, tokens, ttl, responseId);
    }
}

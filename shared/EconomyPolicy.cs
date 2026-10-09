// Copyright (c) 2026 DOTS
// Provider-neutral deterministic economy policy for the Windows/shared router.

using System.Collections.Concurrent;
using System.Text;
using System.Text.Json.Nodes;

namespace DotsHarnessCore;

public enum AgentUsageMode
{
    Standard,
    Economy,
}

public sealed record EconomyOutputBudget(
    int VisibleReserve,
    int ReasoningReserve,
    int ProtocolReserve,
    int MaxOutputTokens,
    int? ProviderReasoningBudgetTokens = null)
{
    /// Expands the provider ceiling only for the single bounded retry used by
    /// soft economy/style turns. Strict per-turn limits must never call this.
    public EconomyOutputBudget Expand(string model, NativeProviderProtocol protocol, int contextWindow)
    {
        var maximum = EconomyPolicy.ProviderMaximum(protocol, contextWindow);
        var expanded = Math.Min(maximum, Math.Max(MaxOutputTokens + 4_096, (int)Math.Ceiling(MaxOutputTokens * 1.5d)));
        return this with
        {
            ReasoningReserve = Math.Max(ReasoningReserve, expanded - VisibleReserve - ProtocolReserve),
            MaxOutputTokens = Math.Min(maximum, EconomyPolicy.RoundUp(expanded)),
            ProviderReasoningBudgetTokens = ProviderReasoningBudgetTokens is { } value
                ? Math.Min(value + 4_096, Math.Max(1_024, expanded - VisibleReserve - ProtocolReserve))
                : null,
        };
    }
}

public static class EconomyPolicy
{
    public const int ToolOutputTokenLimit = 2_048;
    public const int ToolOutputLineLimit = 160;
    public const string ToolOutputMarker = "[… tool output reduced for context economy …]\nContinue with read_file offset or a narrower grep_files query.";
    public const string SystemInstruction = "Economy mode: keep prose as short as the answer allows and omit optional explanations and alternatives. Stop when the success criteria are met.";

    private static readonly ConcurrentDictionary<string, List<int>> ReasoningHistory = new(StringComparer.Ordinal);

    public static EconomyOutputBudget Resolve(
        NativeProviderProtocol protocol,
        string model,
        string effort,
        IReadOnlyList<NativeMessage> messages,
        IReadOnlyList<NativeToolDefinition> tools,
        ResponseStyleDecision? decision = null,
        int contextWindow = ContextCompaction.DefaultContextWindow)
    {
        var codingLike = tools.Count > 0 || messages.Any(message => message.Role == "tool" || message.ToolCalls is { Count: > 0 });
        var selectedDecision = decision ?? ResponseStyleResolver.Resolve(
            AgentResponseStylePreference.Balanced,
            messages.LastOrDefault(message => message.Role == "user")?.Content);
        var detectedStyle = selectedDecision.Style;
        var visible = codingLike
            ? 12_288
            : detectedStyle switch
            {
                AgentResponseStyle.Ultra => 1_024,
                AgentResponseStyle.Concise or AgentResponseStyle.Strict => 2_048,
                _ => 4_096,
            };
        var writeReserve = messages
            .SelectMany(message => message.ToolCalls ?? [])
            .Where(call => string.Equals(call.Name, "write_file", StringComparison.OrdinalIgnoreCase))
            .Select(call => WriteReserve(call.Arguments))
            .DefaultIfEmpty(0)
            .Max();
        visible = Math.Max(visible, writeReserve);
        var baseReasoning = StartingReasoningReserve(effort, codingLike);
        var key = $"{protocol}|{model}|{effort}";
        var recent = ReasoningHistory.TryGetValue(key, out var values) && values.Count > 0 ? values.Max() : 0;
        var reasoning = Math.Max(baseReasoning, recent > 0 ? recent + Math.Max(1_024, baseReasoning / 4) : 0);
        var maximum = ProviderMaximum(protocol, contextWindow);
        var cap = detectedStyle == AgentResponseStyle.Strict && selectedDecision.ProviderOutputTokenCap is { } requested
            ? Math.Min(maximum, Math.Max(1, requested))
            : Math.Min(maximum, Math.Max(1_024, RoundUp(reasoning + visible + 1_024)));
        var providerBudget = SupportsLegacyThinkingBudget(model) && cap > visible + 1_024
            // Thinking parameters are rendered into the prompt; following recent
            // usage would move the budget every turn and drop the message cache.
            ? Math.Min(Math.Max(4_096, baseReasoning), Math.Max(1, cap - visible - 1_024))
            : (int?)null;
        return new EconomyOutputBudget(visible, reasoning, 1_024, cap, providerBudget);
    }

    public static void RecordReasoning(NativeProviderProtocol protocol, string model, string effort, int? tokens)
    {
        if (tokens is not > 0) return;
        var key = $"{protocol}|{model}|{effort}";
        ReasoningHistory.AddOrUpdate(
            key,
            _ => [tokens.Value],
            (_, previous) => previous.Concat([tokens.Value]).TakeLast(4).ToList());
    }

    public static int ProviderMaximum(NativeProviderProtocol protocol, int contextWindow)
    {
        var maximum = protocol switch
        {
            NativeProviderProtocol.Anthropic => 64_000,
            _ => 128_000,
        };
        return contextWindow > 0 ? Math.Min(maximum, Math.Max(1_024, contextWindow - 1_024)) : maximum;
    }

    public static bool SupportsLegacyThinkingBudget(string model)
    {
        var id = model.ToLowerInvariant();
        return id.Contains("claude-3")
            || id.Contains("claude-3.5")
            || id.Contains("-thinking")
            || id == "claude-opus-4-5-20251101";
    }

    public static int RoundUp(int value)
    {
        const int step = 512;
        return Math.Max(step, ((Math.Max(1, value) + step - 1) / step) * step);
    }

    public static string NormalizeToolOutput(string value, string toolName, string arguments = "")
    {
        if (string.IsNullOrEmpty(value)) return value;
        // read_file already pages whole lines. Preserve the content its read ledger recorded.
        if (string.Equals(toolName, "read_file", StringComparison.OrdinalIgnoreCase)) return value;
        if (string.Equals(toolName, "grep_files", StringComparison.OrdinalIgnoreCase)) return NormalizeLines(value, arguments, false);
        return ClipHeadTail(value, ToolOutputMarker);
    }

    public static List<NativeMessage> NormalizeToolMessages(IReadOnlyList<NativeMessage> messages)
    {
        // This must be position-independent. Replacing an older tool result with
        // a marker after a new turn is appended changes the provider prefix and
        // creates a false cache miss. The complete result remains in the durable
        // transcript; this is only the reversible provider-facing view.
        var result = new List<NativeMessage>(messages.Count);
        for (var index = 0; index < messages.Count; index++)
        {
            var message = messages[index];
            if (message.Role != "tool") { result.Add(message); continue; }
            var call = messages.Take(index).Reverse()
                .SelectMany(item => item.Role == "assistant" ? item.ToolCalls ?? [] : [])
                .FirstOrDefault(item => string.Equals(item.Id, message.ToolCallId, StringComparison.Ordinal));
            var body = NormalizeToolOutput(message.Content, ToolName(message, call), call?.Arguments ?? "");
            result.Add(message with
            {
                Content = body,
                ProviderItems = NormalizeProviderItems(message.ProviderItems, body),
            });
        }
        return result;
    }

    public static List<JsonObject>? NormalizeProviderItems(IReadOnlyList<JsonObject>? items, string output)
    {
        if (items is null || items.Count == 0) return items?.ToList();
        var result = new List<JsonObject>(items.Count);
        foreach (var item in items)
        {
            var copy = item.DeepClone().AsObject();
            var type = copy["type"]?.GetValue<string>() ?? "";
            if (string.Equals(type, "function_call_output", StringComparison.OrdinalIgnoreCase)) copy["output"] = output;
            if (string.Equals(type, "tool_result", StringComparison.OrdinalIgnoreCase)) copy["content"] = output;
            result.Add(copy);
        }
        return result;
    }

    public static List<NativeMessage> PruneContext(IReadOnlyList<NativeMessage> messages, int targetTokens)
    {
        var normalized = NormalizeToolMessages(messages);
        var stable = normalized.Where(message => message.Role == "system").ToList();
        var conversational = normalized.Where(message => message.Role != "system").ToList();
        if (conversational.Count == 0) return normalized;
        var groups = GroupExchanges(conversational);
        if (groups.Count == 0) return stable;
        var anchorIndex = groups.FindLastIndex(group => group.Any(message => message.Role == "user"));
        if (anchorIndex < 0) anchorIndex = groups.Count - 1;
        var firstRecent = Math.Max(0, groups.Count - 12);
        var retained = Enumerable.Range(firstRecent, groups.Count - firstRecent)
            .Select(index => (Index: index, Messages: groups[index]))
            .ToList();
        if (retained.All(group => group.Index != anchorIndex))
            retained.Insert(0, (anchorIndex, groups[anchorIndex]));

        List<NativeMessage> Compose()
        {
            var result = new List<NativeMessage>(stable);
            if (retained.Count < groups.Count
                && !result.Any(message => message.Content.StartsWith(ContextCompaction.LocalHistoryReductionMarker, StringComparison.Ordinal)))
            {
                result.Add(new NativeMessage(
                    "system",
                    ContextCompaction.LocalHistoryReductionMarker + " Older assistant/tool exchanges were omitted to keep requests bounded. Use the latest user instructions and recent evidence; rerun a focused read-only command if an omitted exact result is needed."));
            }
            result.AddRange(retained.SelectMany(group => group.Messages));
            return result;
        }

        var pruned = Compose();
        while (ContextCompaction.EstimateTokens(pruned) > Math.Max(512, targetTokens) && retained.Count > 1)
        {
            var removable = retained.FindIndex(group => group.Index != anchorIndex);
            if (removable < 0) break;
            retained.RemoveAt(removable);
            pruned = Compose();
        }
        if (ContextCompaction.EstimateTokens(pruned) > Math.Max(512, targetTokens))
            ContextCompaction.TrimToolResults(pruned, targetTokens);
        return pruned;
    }

    private static List<List<NativeMessage>> GroupTurns(IReadOnlyList<NativeMessage> messages)
    {
        var result = new List<List<NativeMessage>>();
        var current = new List<NativeMessage>();
        foreach (var message in messages)
        {
            if (message.Role == "user" && current.Count > 0) { result.Add(current); current = []; }
            current.Add(message);
        }
        if (current.Count > 0) result.Add(current);
        return result;
    }

    /// <summary>
    /// Groups assistant tool calls with their following results, so old rounds
    /// from one long user turn can be removed without leaving unmatched calls.
    /// </summary>
    private static List<List<NativeMessage>> GroupExchanges(IReadOnlyList<NativeMessage> messages)
    {
        var result = new List<List<NativeMessage>>();
        var current = new List<NativeMessage>();
        foreach (var message in messages)
        {
            if ((message.Role == "user" || message.Role == "assistant" && message.ToolCalls is { Count: > 0 })
                && current.Count > 0)
            {
                result.Add(current);
                current = [];
            }
            current.Add(message);
        }
        if (current.Count > 0) result.Add(current);
        return result;
    }

    private static string ToolName(NativeMessage message, NativeToolCall? call) => call?.Name ?? message.ToolCallId ?? "tool";

    private static int WriteReserve(string arguments)
    {
        try
        {
            var objectNode = JsonNode.Parse(arguments)?.AsObject();
            var content = objectNode?["content"]?.GetValue<string>();
            return content is null ? 0 : (int)Math.Ceiling(content.Length / 4d) + 1_024;
        }
        catch { return 0; }
    }

    private static int ArgumentInt(string arguments, string name)
    {
        try { return JsonNode.Parse(arguments)?.AsObject()?[name]?.GetValue<int>() ?? 0; }
        catch { return 0; }
    }

    private static string NormalizeLines(string value, string arguments, bool includeOffset)
    {
        var lines = value.Split('\n');
        var visibleLineCount = Math.Max(1, Math.Min(lines.Length, ToolOutputLineLimit - 2));
        var boundedOffset = ArgumentInt(arguments, "offset") + visibleLineCount;
        var boundedMarker = ToolOutputMarker + (includeOffset
            ? $"\nDevam için offset={boundedOffset} kullanın."
            : "");
        if (lines.Length <= ToolOutputLineLimit) return ClipHeadTail(value, boundedMarker);
        var kept = Math.Max(1, ToolOutputLineLimit - 2);
        var continuationOffset = ArgumentInt(arguments, "offset") + kept;
        var marker = ToolOutputMarker + (includeOffset ? $"\nDevam için offset={continuationOffset} kullanın." : "");
        var body = string.Join('\n', lines.Take(kept));
        var marked = body + "\n" + marker;
        return Encoding.UTF8.GetByteCount(marked) <= ToolOutputTokenLimit * 4 ? marked : ClipHeadTail(body, marker);
    }

    private static string ClipHeadTail(string value, string marker)
    {
        var maximum = ToolOutputTokenLimit * 4;
        var bytes = Encoding.UTF8.GetBytes(value);
        if (bytes.Length <= maximum) return value;
        var important = ImportantLines(value);
        if (important.Length > 0) marker += "\nImportant lines:\n" + important;
        var markerBytes = Encoding.UTF8.GetBytes(marker);
        if (markerBytes.Length > maximum / 2)
        {
            marker = Encoding.UTF8.GetString(markerBytes, 0, maximum / 2)
                + "\n[… additional important lines omitted …]";
        }
        var tail = Math.Min(1_200, maximum / 5);
        var head = Math.Max(1, maximum - tail - Encoding.UTF8.GetByteCount(marker) - 8);
        var headText = Encoding.UTF8.GetString(bytes, 0, Math.Min(head, bytes.Length));
        var tailLength = Math.Min(tail, bytes.Length);
        var tailText = Encoding.UTF8.GetString(bytes, bytes.Length - tailLength, tailLength);
        return headText + "\n" + marker + "\n" + tailText;
    }

    private static string ImportantLines(string value)
    {
        var lines = value.Split('\n')
            .Select(line => line.Trim())
            .Where(line => line.Length > 0 && IsImportantLine(line))
            .Distinct(StringComparer.Ordinal)
            .Take(12)
            .Select(line => line.Length <= 512 ? line : line[..512] + "…")
            .ToList();
        return string.Join('\n', lines.Select(line => "- " + line));
    }

    private static bool IsImportantLine(string line)
    {
        var lower = line.ToLowerInvariant();
        return lower.Contains("error")
            || lower.Contains("fatal")
            || lower.Contains("exception")
            || lower.Contains("traceback")
            || lower.Contains("failed")
            || lower.Contains("failure")
            || lower.Contains("security")
            || lower.Contains("unsafe")
            || lower.Contains("warning")
            || lower.Contains("status")
            || lower.Contains("exit code")
            || lower.Contains("test")
            || lower.Contains("assert")
            || lower.Contains("denied")
            || lower.Contains("rejected")
            || lower.Contains("permission")
            || lower.StartsWith("diff --git", StringComparison.Ordinal)
            || lower.StartsWith("@@", StringComparison.Ordinal)
            || line.StartsWith("+++ ", StringComparison.Ordinal)
            || line.StartsWith("--- ", StringComparison.Ordinal);
    }

    private static int StartingReasoningReserve(string effort, bool codingLike) => effort.ToLowerInvariant() switch
    {
        "none" => 0,
        "minimal" => codingLike ? 1_024 : 512,
        "low" => codingLike ? 4_096 : 2_048,
        "medium" => codingLike ? 8_192 : 4_096,
        "high" => codingLike ? 12_288 : 8_192,
        "xhigh" => codingLike ? 16_384 : 12_288,
        "max" => codingLike ? 24_576 : 16_384,
        _ => codingLike ? 4_096 : 2_048,
    };
}

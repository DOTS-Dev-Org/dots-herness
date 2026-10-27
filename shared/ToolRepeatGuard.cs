// Copyright (c) 2026 DOTS
// Stops a tool loop that has stopped making progress (parity with macOS
// AgentBridge.maxIdenticalToolCalls / maxEditsPerFile). One instance per run.

using System.Text.Json.Nodes;

namespace DotsHarnessCore;

public sealed class ToolRepeatGuard
{
    public const int MaxIdenticalCalls = 3;
    public const int MaxEditsPerFile = 5;
    public const string RepeatedNotice =
        "This exact tool call was already made and returned the same result. Change the approach instead of repeating it.";

    private readonly Dictionary<string, int> _signatures = new(StringComparer.Ordinal);
    private readonly Dictionary<string, int> _edits = new(StringComparer.Ordinal);

    /// True once the same call (key order and whitespace ignored) exceeds the limit.
    public bool IsRepeat(NativeToolCall call)
    {
        var signature = Signature(call);
        var count = _signatures.GetValueOrDefault(signature) + 1;
        _signatures[signature] = count;
        return count > MaxIdenticalCalls;
    }

    /// Appended to an edit result once one file has been edited too often this run.
    public string EditNotice(NativeToolCall call)
    {
        if (call.Name is not ("edit_file" or "write_file") || Parse(call)?["path"]?.GetValue<string>() is not { } path) return "";
        var count = _edits.GetValueOrDefault(path) + 1;
        _edits[path] = count;
        return count > MaxEditsPerFile
            ? $"\n\n[Repeated edits] This file was edited {count} times this turn. Reread it and the diff, confirm the change is not already present, and stop rewriting the same region."
            : "";
    }

    public static string Signature(NativeToolCall call) =>
        call.Name + "|" + (Parse(call) is { } node ? Sorted(node).ToJsonString() : call.Arguments);

    private static JsonObject? Parse(NativeToolCall call)
    {
        try { return JsonNode.Parse(call.Arguments) as JsonObject; }
        catch (System.Text.Json.JsonException) { return null; }
    }

    private static JsonNode? Sorted(JsonNode? node) => node switch
    {
        JsonObject obj => new JsonObject(obj.OrderBy(p => p.Key, StringComparer.Ordinal)
            .Select(p => KeyValuePair.Create(p.Key, Sorted(p.Value)))),
        JsonArray array => new JsonArray(array.Select(Sorted).ToArray()),
        _ => node?.DeepClone(),
    };
}

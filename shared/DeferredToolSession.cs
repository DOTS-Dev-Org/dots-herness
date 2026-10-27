using System.Text.Json.Nodes;

namespace DotsHarnessCore;

/// Stable provider surface: underlying schemas live only in discovery results.
public sealed class DeferredToolSession
{
    public const string SearchName = "discover_tools", InvokeName = "invoke_tool", PlanName = "execution_plan", OutputName = "read_tool_output", EnterPlanName = "enter_plan_mode";
    public static readonly IReadOnlyList<NativeToolDefinition> Definitions =
    [
        Define(SearchName, "Find tools by exact name or English capability query. Returns up to 5 schemas. Empty query lists names only; offset pages the list.", """{"query":{"type":"string"},"offset":{"type":"integer"}}""", ["query"]),
        Define(InvokeName, "Call a discovered tool. Arguments must be a JSON object encoded as a string. Send independent calls together in one response; they run as one round. Existing permissions and execution scope apply.", """{"name":{"type":"string"},"arguments":{"type":"string"}}""", ["name", "arguments"]),
        Define(PlanName, "Record concrete steps after inspection, before implementation. Mark routine only for bounded known work and list unresolved uncertainties. Replan if scope changes.", """{"steps":{"type":"array","items":{"type":"string"},"minItems":1,"maxItems":12},"routine":{"type":"boolean"},"uncertainties":{"type":"array","items":{"type":"string"}}}""", ["steps", "routine", "uncertainties"]),
        Define(OutputName, "Read a tool's original result without rerunning it. Character offset; default limit 4000, maximum 8000.", """{"call_id":{"type":"string"},"offset":{"type":"integer"},"limit":{"type":"integer"}}""", ["call_id"]),
        Define(EnterPlanName, "Switch this turn to read-only plan mode. Call it alone, first, only when the user asks for a plan or plan mode (any language) instead of the work. Not for running an existing plan.", "{}", []),
    ];
    /// Sent with their schemas on every request: almost every coding turn reads, searches and
    /// edits, and a discover round first would resend the whole context for nothing.
    public static readonly IReadOnlyList<string> DirectNames = ["read_file", "grep_files", NativeFileEdit.GlobName, NativeFileEdit.EditName, "run_command"];
    /// The provider surface: the controls, then the direct tools the catalog offers, in a fixed
    /// order so the prompt cache holds. Plan mode sends the same list - a plan and its approved
    /// run share one cache namespace - and refuses edit_file when it is called.
    public static IReadOnlyList<NativeToolDefinition> RequestTools(IReadOnlyList<NativeToolDefinition> catalog) =>
        [.. Definitions, .. DirectNames.Select(name => catalog.FirstOrDefault(tool => tool.Name == name)).OfType<NativeToolDefinition>()];
    private static NativeToolDefinition Define(string name, string description, string properties, string[] required) => new(name, description,
        new JsonObject { ["type"] = "object", ["properties"] = JsonNode.Parse(properties), ["required"] = new JsonArray(required.Select(s => (JsonNode?)JsonValue.Create(s)).ToArray()), ["additionalProperties"] = false });
    private readonly Dictionary<string, JsonNode> _discovered = new(StringComparer.Ordinal);
    private readonly Dictionary<string, string> _outputs = new(StringComparer.Ordinal);
    public bool RoutineExecution { get; private set; }
    public void ResetPlan() => RoutineExecution = false;
    public void RestoreDiscovery(IReadOnlyList<NativeMessage> messages)
    {
        _discovered.Clear();
        var ids = messages.Where(m => m.Role == "assistant").SelectMany(m => m.ToolCalls ?? []).Where(c => c.Name == SearchName).Select(c => c.Id).ToHashSet(StringComparer.Ordinal);
        foreach (var message in messages.Where(m => m.Role == "tool" && ids.Contains(m.ToolCallId ?? "")))
        {
            try
            {
                if (JsonNode.Parse(message.Content)?["tools"] is not JsonArray tools) continue;
                foreach (var tool in tools)
                    if (tool?["name"]?.GetValue<string>() is { } name && tool["parameters"] is { } schema) _discovered[name] = schema.DeepClone();
            }
            catch { /* An excerpt or failed discovery is not a schema. */ }
        }
    }
    public string Effort(string selected, bool planMode) => RoutineExecution && !planMode && selected.ToLowerInvariant() is "medium" or "high" or "xhigh" or "max" or "ultra" ? "low" : selected;
    public NativeToolCall Resolve(NativeToolCall call, IReadOnlyList<NativeToolDefinition> catalog)
    {
        if (call.Name != InvokeName)
            return Definitions.Any(t => t.Name == call.Name) || DirectNames.Contains(call.Name) && catalog.Any(t => t.Name == call.Name)
                ? call
                : new NativeToolCall(call.Id, InvokeName, call.Arguments);
        try
        {
            var input = JsonNode.Parse(call.Arguments)!.AsObject();
            var name = input["name"]!.GetValue<string>();
            var arguments = input["arguments"]!.GetValue<string>();
            // A direct tool's schema is already in every request; wrapping it needs no discovery round.
            var tool = catalog.FirstOrDefault(t => t.Name == name);
            if (tool is not null && !Definitions.Any(t => t.Name == name)
                && (DirectNames.Contains(name) || _discovered.TryGetValue(name, out var schema) && JsonNode.DeepEquals(tool.Parameters, schema))
                && JsonNode.Parse(arguments) is JsonObject)
                return new NativeToolCall(call.Id, name, arguments);
        }
        catch { }
        return call;
    }
    public string? Control(NativeToolCall call, IReadOnlyList<NativeToolDefinition> catalog, bool planMode)
    {
        if (!Definitions.Any(t => t.Name == call.Name)) return null;
        if (call.Name == EnterPlanName)
            return planMode ? HerNessPrompt.PlanMode(Definitions.Select(t => t.Name)) : "Plan mode is unavailable here. Do the work directly.";
        try
        {
            var input = JsonNode.Parse(call.Arguments)?.AsObject() ?? new JsonObject();
            if (call.Name == SearchName)
            {
                var query = (input["query"]?.GetValue<string>() ?? "").ToLowerInvariant();
                var candidates = catalog.Where(t => !Definitions.Any(d => d.Name == t.Name)).OrderBy(t => t.Name, StringComparer.Ordinal).ToArray();
                if (query.Length == 0)
                {
                    var offset = Math.Max(0, input["offset"]?.GetValue<int>() ?? 0);
                    return System.Text.Json.JsonSerializer.Serialize(new { names = candidates.Skip(offset).Take(20).Select(t => t.Name), next_offset = offset + 20, total = candidates.Length });
                }
                var terms = System.Text.RegularExpressions.Regex.Split(query, @"[^\p{L}\p{N}_]+").Where(s => s.Length > 0).ToArray();
                var matches = candidates.Select(t => (tool: t, score: t.Name.ToLowerInvariant() == query ? 10000 : terms.Count(term => (t.Name + " " + t.Description).Contains(term, StringComparison.OrdinalIgnoreCase))))
                    .Where(t => t.score > 0).OrderByDescending(t => t.score).ThenBy(t => t.tool.Name, StringComparer.Ordinal).Take(5).Select(t => t.tool).ToArray();
                var exact = candidates.Where(t => t.Name.Equals(query, StringComparison.OrdinalIgnoreCase)).ToArray();
                var named = exact.Length > 0 ? exact : candidates.Where(t => terms.Contains(t.Name.ToLowerInvariant())).Take(5).ToArray();
                if (named.Length > 0) matches = named;
                foreach (var tool in matches) _discovered[tool.Name] = tool.Parameters.DeepClone();
                return System.Text.Json.JsonSerializer.Serialize(new { tools = matches.Select(t => new { name = t.Name, description = t.Description[..Math.Min(480, t.Description.Length)], parameters = t.Parameters }), instruction = "Use invoke_tool for these names only. Discover more when needed." });
            }
            if (call.Name == PlanName)
            {
                RoutineExecution = false;
                var steps = input["steps"]!.AsArray();
                var uncertainties = input["uncertainties"]!.AsArray();
                if (steps.Count is < 1 or > 12 || steps.Any(s => string.IsNullOrWhiteSpace(s?.GetValue<string>())))
                    return "Tool error: provide 1-12 concrete steps.";
                if (uncertainties.Any(s => s is null || s.GetValueKind() != System.Text.Json.JsonValueKind.String)) return "Tool error: uncertainties must be strings.";
                RoutineExecution = input["routine"]!.GetValue<bool>() && steps.Count <= 5 && uncertainties.Count == 0 && !planMode;
                var summary = new List<string> { "Plan recorded:" };
                for (var i = 0; i < steps.Count; i++) summary.Add((i + 1) + ". " + steps[i]!.GetValue<string>());
                if (uncertainties.Count == 0)
                {
                    summary.Add("Unresolved uncertainties: none.");
                }
                else
                {
                    summary.Add("Unresolved uncertainties:");
                    foreach (var uncertainty in uncertainties) summary.Add("- " + uncertainty!.GetValue<string>());
                }
                var effortReasons = new List<string>();
                if (!input["routine"]!.GetValue<bool>()) effortReasons.Add("not marked routine");
                if (steps.Count > 5) effortReasons.Add("more than five steps");
                if (uncertainties.Count > 0) effortReasons.Add("open uncertainties");
                if (planMode) effortReasons.Add("plan mode is active");
                summary.Add(RoutineExecution
                    ? "Execution effort: routine work uses low effort; failures restore the selected effort."
                    : "Execution effort: selected level retained (" + string.Join(", ", effortReasons) + ").");
                return string.Join("\n", summary);
            }
            if (call.Name == OutputName)
            {
                if (!_outputs.TryGetValue(input["call_id"]!.GetValue<string>(), out var value)) return "Tool error: no stored result for that call_id in this run.";
                var offset = Math.Min(value.Length, Math.Max(0, input["offset"]?.GetValue<int>() ?? 0));
                var limit = Math.Clamp(input["limit"]?.GetValue<int>() ?? 4000, 1, 8000);
                var page = value.Substring(offset, Math.Min(limit, value.Length - offset));
                return page + (offset + page.Length < value.Length ? $"\n[More output: offset={offset + page.Length}]" : "");
            }
            return "Tool error: discover this tool first and pass a valid JSON arguments string.";
        }
        catch { if (call.Name == PlanName) ResetPlan(); return "Tool error: invalid control arguments."; }
    }
    private static readonly HashSet<string> ReadOnlyToolNames = new(StringComparer.OrdinalIgnoreCase)
    {
        "read_file", "grep_files", "list_files", "search_files", "glob",
        "web_search", "web_fetch", "skill.list", "skill.read",
        SearchName, PlanName, OutputName,
    };
    public static bool IsReadOnlyTool(string? toolName) =>
        !string.IsNullOrEmpty(toolName) && ReadOnlyToolNames.Contains(toolName);
    public const string RepeatedReadPrefix = "[read_file unchanged:";
    private readonly List<(string CallId, string Path)> _reads = new();
    /// A read_file whose lines already arrived verbatim in an earlier read of the
    /// same path in this run gets a pointer instead of the same bytes again. The
    /// verbatim check doubles as the unchanged-file proof; read_tool_output can
    /// always reach the earlier result because outputs live for the whole run.
    public string? RepeatedRead(string value, string? path)
    {
        if (string.IsNullOrEmpty(path = NormalizePath(path))) return null;
        // Drop the "continue at line N (file has M lines)" footer of a cut page.
        var cut = value.EndsWith(" lines)", StringComparison.Ordinal) ? value.LastIndexOf("\n\n", StringComparison.Ordinal) : -1;
        var body = cut >= 0 ? value[..cut] : value;
        if (System.Text.Encoding.UTF8.GetByteCount(body) < 512 || body.StartsWith("Tool error", StringComparison.Ordinal)) return null;
        for (var i = _reads.Count - 1; i >= 0; i--)
        {
            var (id, earlierPath) = _reads[i];
            if (earlierPath == path && _outputs.TryGetValue(id, out var earlier) && earlier.Contains(body, StringComparison.Ordinal))
                return $"{RepeatedReadPrefix} these lines of {path} are identical to what call_id={id} returned earlier in this run. Use that result, or read_tool_output call_id={id} if it is no longer visible.]";
        }
        return null;
    }
    public static string? PathArgument(string arguments)
    {
        try { return JsonNode.Parse(arguments)?["path"]?.GetValue<string>(); } catch { return null; }
    }
    private static string? NormalizePath(string? path)
    {
        path = path?.Trim().Replace('\\', '/');
        while (path?.StartsWith("./", StringComparison.Ordinal) == true) path = path[2..];
        return path;
    }
    public void Record(string value, string callId, string? toolName = null, string? path = null)
    {
        _outputs[callId] = value;
        if (toolName == "read_file" && NormalizePath(path) is { Length: > 0 } readPath) _reads.Add((callId, readPath));
        if (!IsReadOnlyTool(toolName) && Failed(value)) ResetPlan();
    }
    public static bool Failed(string value) => value.StartsWith("Tool error", StringComparison.OrdinalIgnoreCase) || value.StartsWith("error:", StringComparison.OrdinalIgnoreCase)
        || value.Contains("blocked_in_plan_mode", StringComparison.OrdinalIgnoreCase) || value.Contains("permission rejected", StringComparison.OrdinalIgnoreCase)
        || System.Text.RegularExpressions.Regex.IsMatch(value, @"(?:exit[ _]?code|status)\s*[:=]?\s*-?[1-9][0-9]*\b", System.Text.RegularExpressions.RegexOptions.IgnoreCase)
        || System.Text.RegularExpressions.Regex.IsMatch(value, @"(?:^|\n)\s*(?:fatal|error|exception|blocked|refused|failed)(?:[:\s])|\b[1-9][0-9]* (?:tests? )?failed\b|\[check [0-9]+ failed\]", System.Text.RegularExpressions.RegexOptions.IgnoreCase);
}

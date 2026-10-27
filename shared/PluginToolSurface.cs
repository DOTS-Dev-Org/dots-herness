// Copyright (c) 2026 DOTS
// Plugin tools exposed to the model under a `plugin__` prefix, so a plugin's
// own names can never collide with the built-ins. Mirrors the macOS
// pluginToolDefinitions() in AgentBridge+Tools.swift.

using System.Text.Json.Nodes;
using HarnessPluginKit;
using PluginRuntime;

namespace DotsHarnessCore;

public static class PluginToolSurface
{
    public const string Prefix = "plugin__";

    /// <summary>
    /// The plugin tools this run may call: the definitions the model sees and the
    /// map from the exposed name back to the plugin's own registry name.
    /// A name that sanitizes onto another name is dropped, never bound by order.
    /// </summary>
    public static (IReadOnlyList<NativeToolDefinition> Definitions, IReadOnlyDictionary<string, string> NameMap) Build(
        PluginHost? host)
    {
        if (host is null) return ([], new Dictionary<string, string>(StringComparer.Ordinal));
        IReadOnlyList<RegisteredTool> registered;
        try { registered = host.Tools.Tools(); }
        catch { return ([], new Dictionary<string, string>(StringComparer.Ordinal)); }
        if (registered.Count == 0) return ([], new Dictionary<string, string>(StringComparer.Ordinal));

        var counts = registered
            .GroupBy(tool => Prefix + Sanitize(tool.Name), StringComparer.Ordinal)
            .ToDictionary(group => group.Key, group => group.Count(), StringComparer.Ordinal);
        var definitions = new List<NativeToolDefinition>();
        var names = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var tool in registered.OrderBy(tool => tool.Name, StringComparer.Ordinal))
        {
            var exposed = Prefix + Sanitize(tool.Name);
            if (!counts.TryGetValue(exposed, out var count) || count != 1) continue;
            names[exposed] = tool.Name;
            definitions.Add(new NativeToolDefinition(exposed, tool.Description, Schema(tool.Parameters)));
        }
        return (definitions, names);
    }

    /// <summary>Tool names reach the provider as ASCII identifiers.</summary>
    public static string Sanitize(string name) => string.Concat(name.Select(character =>
        char.IsLetterOrDigit(character) || character is '_' or '-' ? character : '_'));

    private static JsonObject Schema(IReadOnlyList<ToolParameter> parameters)
    {
        var properties = new JsonObject();
        var required = new JsonArray();
        foreach (var parameter in parameters)
        {
            properties[parameter.Name] = new JsonObject
            {
                ["type"] = string.IsNullOrEmpty(parameter.Type) ? "string" : parameter.Type,
                ["description"] = parameter.Description,
            };
            if (parameter.Required) required.Add(parameter.Name);
        }
        var schema = new JsonObject
        {
            ["type"] = "object",
            ["properties"] = properties,
        };
        if (required.Count > 0) schema["required"] = required;
        return schema;
    }

    /// <summary>
    /// Flattens a tool-call argument object to the string map the plugin registry
    /// expects. Nested values are re-serialized.
    /// </summary>
    public static IReadOnlyDictionary<string, string> StringArguments(string? raw)
    {
        var result = new Dictionary<string, string>(StringComparer.Ordinal);
        if (string.IsNullOrWhiteSpace(raw)) return result;
        JsonObject? parsed;
        try { parsed = JsonNode.Parse(raw)?.AsObject(); }
        catch { return result; }
        if (parsed is null) return result;
        foreach (var (key, value) in parsed)
        {
            if (value is null) continue;
            result[key] = value switch
            {
                System.Text.Json.Nodes.JsonValue json when json.TryGetValue<string>(out var text) => text,
                JsonArray or JsonObject => value.ToJsonString(),
                System.Text.Json.Nodes.JsonValue json when json.TryGetValue<bool>(out var flag) => flag ? "true" : "false",
                _ => value.ToString(),
            };
        }
        return result;
    }
}

// Copyright (c) 2026 DOTS
// Wire names for provider tool schemas. Anthropic and the OpenAI function
// protocols only accept ASCII identifiers, while the harness names its own
// tools `skill.read` and `plugin__thing`. Mirrors the macOS ToolCloak.

using System.Security.Cryptography;
using System.Text;

namespace DotsHarnessCore;

public static class ToolWireNames
{
    /// <summary>Anthropic's readable stand-in for a dot in a tool name.</summary>
    private const string Dot = "-dot-";

    /// <summary>
    /// The Anthropic wire name of a tool: a dot becomes <c>-dot-</c>, so the
    /// name still reads like the tool the model knows.
    /// </summary>
    public static string Anthropic(string name) => name.Replace(".", Dot, StringComparison.Ordinal);

    /// <summary>Restores the original name behind an Anthropic wire name.</summary>
    public static string RestoreAnthropic(string name) => name.Replace(Dot, ".", StringComparison.Ordinal);

    /// <summary>
    /// The OpenAI function name of a tool. The function-name charset is
    /// <c>[A-Za-z0-9_-]</c>, so an invalid character becomes an underscore and
    /// the name keeps reading like the tool.
    /// </summary>
    public static string OpenAi(string name)
    {
        if (name.Length == 0) return name;
        var builder = new StringBuilder(name.Length);
        foreach (var character in name)
        {
            builder.Append(character is >= 'a' and <= 'z' or >= 'A' and <= 'Z' or >= '0' and <= '9' or '_' or '-'
                ? character
                : '_');
        }
        return builder.ToString();
    }

    /// <summary>
    /// The Responses function name of a tool: a short deterministic hash, so the
    /// same tool keeps the same name on every turn and two tools never collide.
    /// </summary>
    public static string Responses(string name)
    {
        var hash = SHA256.HashData(Encoding.UTF8.GetBytes(name));
        return "tool_" + Convert.ToHexString(hash).ToLowerInvariant()[..32];
    }

    /// <summary>
    /// The wire names of every tool in a request, keyed by the original name.
    /// Only names the protocol cannot carry are mapped.
    /// </summary>
    public static Dictionary<string, string> Map(
        IEnumerable<string> names,
        Func<string, string> project)
    {
        var map = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var name in names.Distinct(StringComparer.Ordinal))
        {
            if (string.IsNullOrEmpty(name)) continue;
            var wire = project(name);
            if (wire == name) continue;
            map[name] = wire;
        }
        return map;
    }

    /// <summary>The wire name of a tool, or the name itself when it needs no change.</summary>
    public static string For(string name, IReadOnlyDictionary<string, string> map) =>
        map.TryGetValue(name, out var wire) ? wire : name;

    /// <summary>The original name behind a wire name.</summary>
    public static string Restore(string name, IReadOnlyDictionary<string, string> map)
    {
        foreach (var (original, wire) in map)
        {
            if (wire == name) return original;
        }
        return name;
    }
}

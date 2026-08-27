// Copyright (c) 2026 DOTS
// Plugin composition model derived from DeepSeek Harness.
// Copyright (c) 2026 DeepSeek. MIT. See NOTICE.

using System.Text.Json;
using HarnessPluginKit;

namespace PluginRuntime;

/// <summary>
/// Indentation-based YAML subset for composition files. Not a full YAML 1.2
/// engine — enough for host.yml, presets, plugin.yml, and DeepSeek-style
/// patch arrays.
/// </summary>
public static class MiniYaml
{
    public static JsonValue LoadValue(string text)
    {
        var lines = text.Split(new[] { "\r\n", "\n" }, StringSplitOptions.None);
        var index = 0;
        SkipEmpty(ref index, lines);
        if (index >= lines.Length) return JsonValue.Null;
        return ParseNode(lines, ref index, minIndent: -1);
    }

    public static IReadOnlyDictionary<string, JsonValue> LoadObject(string text)
    {
        var value = LoadValue(text);
        if (value is JsonValue.JsonObject obj) return obj.Value;
        if (value is JsonValue.JsonNull) return new Dictionary<string, JsonValue>(StringComparer.Ordinal);
        throw PluginException.InvalidComposition("expected a mapping at document root");
    }

    public static T Decode<T>(string text)
    {
        var value = LoadValue(text);
        var json = value.ToJson();
        return JsonSerializer.Deserialize<T>(json, DecodeOptions)
            ?? throw PluginException.InvalidComposition("failed to decode YAML");
    }

    public static CompositionDocument DecodeDocument(string text)
    {
        var root = LoadObject(text);
        var plane = ParsePlane(root.TryGetValue("plane", out var p) ? p.AsString() : null);
        var entries = new List<CompositionEntry>();
        if (root.TryGetValue("entries", out var raw) && raw.AsArray() is { } items)
        {
            foreach (var item in items)
            {
                if (item.AsObject() is { } obj) entries.Add(DecodeEntry(obj));
            }
        }
        return new CompositionDocument(plane, entries);
    }

    public static PluginManifest DecodeManifest(string text)
    {
        var root = LoadObject(text);
        var id = root.StringFor("id", "");
        if (string.IsNullOrWhiteSpace(id)) throw PluginException.InvalidManifest("plugin.yml needs id");
        PromptSectionSpec? prompt = null;
        if (root.TryGetValue("promptSection", out var section) && section.AsObject() is { } spec)
        {
            prompt = new PromptSectionSpec(
                spec.StringFor("name", "section"),
                spec.IntFor("order", 40),
                spec.TryGetValue("file", out var file) ? file.AsString() : null,
                spec.TryGetValue("text", out var body) ? body.AsString() : null);
        }
        var inject = new List<string>();
        if (root.TryGetValue("inject", out var injectValue) && injectValue.AsArray() is { } injectItems)
        {
            inject.AddRange(injectItems.Select(i => i.AsString()).Where(s => !string.IsNullOrWhiteSpace(s))!);
        }
        return new PluginManifest(
            Id: id,
            Name: root.StringFor("name", id),
            Version: root.StringFor("version", "0.1.0"),
            Plane: ParsePlane(root.TryGetValue("plane", out var plane) ? plane.AsString() : "session"),
            Abi: root.StringFor("abi", PluginManifest.CurrentAbi),
            Inject: inject,
            Description: root.StringFor("description", ""),
            Library: root.TryGetValue("library", out var lib) ? lib.AsString() : null,
            PromptSection: prompt);
    }

    public static IReadOnlyList<CompositionPatch> LoadPatches(string text)
    {
        var value = LoadValue(text);
        if (value is JsonValue.JsonObject or JsonValue.JsonNull) return Array.Empty<CompositionPatch>();
        if (value is not JsonValue.JsonArray array)
        {
            throw PluginException.InvalidComposition("patch file must be a YAML array");
        }
        return array.Value.Select(ParsePatch).ToList();
    }

    private static readonly JsonSerializerOptions DecodeOptions = new()
    {
        PropertyNameCaseInsensitive = true,
    };

    private static CompositionPatch ParsePatch(JsonValue value)
    {
        var obj = value.AsObject() ?? throw PluginException.InvalidComposition("patch entry must be a mapping");
        if (obj.TryGetValue("insert", out var insert))
        {
            var rows = insert.AsArray() ?? throw PluginException.InvalidComposition("insert must be an array");
            var entries = rows.Select(r =>
            {
                var o = r.AsObject() ?? throw PluginException.InvalidComposition("insert row must be a mapping");
                return DecodeEntry(o);
            }).ToList();
            return new CompositionPatch.Insert(entries);
        }
        if (obj.TryGetValue("disable", out var disable) && disable.AsString() is { } disableId)
        {
            return new CompositionPatch.Disable(disableId);
        }
        if (obj.TryGetValue("enable", out var enable) && enable.AsString() is { } enableId)
        {
            return new CompositionPatch.Enable(enableId);
        }
        if (obj.TryGetValue("config", out var config) && config.AsObject() is { } configOp)
        {
            var id = configOp.TryGetValue("id", out var idValue) ? idValue.AsString() : null;
            if (string.IsNullOrEmpty(id)) throw PluginException.InvalidComposition("config patch needs id");
            var merge = configOp.TryGetValue("merge", out var mergeValue) && mergeValue.AsObject() is { } m
                ? m
                : new Dictionary<string, JsonValue>(StringComparer.Ordinal);
            return new CompositionPatch.MergeConfig(id, merge);
        }
        throw PluginException.InvalidComposition("unknown patch operation");
    }

    internal static CompositionEntry DecodeEntry(IReadOnlyDictionary<string, JsonValue> obj)
    {
        var isolate = new Dictionary<string, bool>(StringComparer.Ordinal);
        if (obj.TryGetValue("isolate", out var iso) && iso.AsObject() is { } isoObj)
        {
            foreach (var (key, value) in isoObj)
            {
                isolate[key] = value.AsBool() ?? false;
            }
        }
        var config = obj.TryGetValue("config", out var cfg) && cfg.AsObject() is { } cfgObj
            ? cfgObj
            : new Dictionary<string, JsonValue>(StringComparer.Ordinal);
        return new CompositionEntry(
            Id: obj.StringFor("id", ""),
            Plugin: obj.StringFor("plugin", ""),
            Disabled: obj.TryGetValue("disabled", out var d) && (d.AsBool() ?? false),
            Isolate: isolate,
            Config: config);
    }

    private static PluginPlane ParsePlane(string? raw) =>
        string.Equals(raw, "host", StringComparison.OrdinalIgnoreCase) ? PluginPlane.Host : PluginPlane.Session;

    private static JsonValue ParseNode(string[] lines, ref int index, int minIndent)
    {
        SkipEmpty(ref index, lines);
        if (index >= lines.Length) return JsonValue.Null;
        var (indent, content) = SplitIndent(lines[index]);
        if (indent < minIndent) return JsonValue.Null;
        if (content.StartsWith("- ", StringComparison.Ordinal) || content == "-")
        {
            return ParseArray(lines, ref index, indent);
        }
        return ParseMapping(lines, ref index, indent);
    }

    private static JsonValue ParseMapping(string[] lines, ref int index, int indent)
    {
        var obj = new Dictionary<string, JsonValue>(StringComparer.Ordinal);
        while (index < lines.Length)
        {
            SkipEmpty(ref index, lines);
            if (index >= lines.Length) break;
            var (lineIndent, content) = SplitIndent(lines[index]);
            if (lineIndent < indent) break;
            if (content.StartsWith("- ", StringComparison.Ordinal)) break;
            if (lineIndent > indent) throw PluginException.InvalidComposition($"unexpected indent at {content}");
            var colon = content.IndexOf(':');
            if (colon < 0) throw PluginException.InvalidComposition($"expected key: {content}");
            var key = content[..colon].Trim();
            var rest = content[(colon + 1)..].Trim();
            index++;
            if (rest.Length == 0)
            {
                SkipEmpty(ref index, lines);
                if (index < lines.Length)
                {
                    var (nextIndent, nextContent) = SplitIndent(lines[index]);
                    if (nextIndent > indent)
                    {
                        obj[key] = nextContent.StartsWith("- ", StringComparison.Ordinal) || nextContent == "-"
                            ? ParseArray(lines, ref index, nextIndent)
                            : ParseMapping(lines, ref index, nextIndent);
                        continue;
                    }
                }
                obj[key] = JsonValue.Null;
            }
            else
            {
                obj[key] = ParseScalar(rest);
            }
        }
        return JsonValue.Object(obj);
    }

    private static JsonValue ParseArray(string[] lines, ref int index, int indent)
    {
        var items = new List<JsonValue>();
        while (index < lines.Length)
        {
            SkipEmpty(ref index, lines);
            if (index >= lines.Length) break;
            var (lineIndent, content) = SplitIndent(lines[index]);
            if (lineIndent < indent) break;
            if (!(content.StartsWith("- ", StringComparison.Ordinal) || content == "-")) break;
            var rest = content == "-" ? "" : content[2..].Trim();
            index++;
            if (rest.Length == 0)
            {
                items.Add(ParseNode(lines, ref index, indent + 1));
            }
            else if (rest.Contains(':') && !rest.StartsWith('{') && !rest.StartsWith('['))
            {
                var collected = new List<string> { new string(' ', indent + 2) + rest };
                while (index < lines.Length)
                {
                    SkipBlankKeep(ref index, lines);
                    if (index >= lines.Length) break;
                    var (childIndent, child) = SplitIndent(lines[index]);
                    if (child.Length == 0) { index++; continue; }
                    if (child.StartsWith("- ", StringComparison.Ordinal) && childIndent <= indent) break;
                    if (childIndent <= indent) break;
                    collected.Add(lines[index]);
                    index++;
                }
                var childIndex = 0;
                items.Add(ParseMapping(collected.ToArray(), ref childIndex, indent + 2));
            }
            else
            {
                items.Add(ParseScalar(rest));
            }
        }
        return JsonValue.Array(items);
    }

    private static JsonValue ParseScalar(string raw)
    {
        if (raw is "~" or "null") return JsonValue.Null;
        if (raw == "true") return JsonValue.Bool(true);
        if (raw == "false") return JsonValue.Bool(false);
        if (double.TryParse(raw, System.Globalization.NumberStyles.Float,
                System.Globalization.CultureInfo.InvariantCulture, out var number)
            && raw.All(ch => char.IsDigit(ch) || ch is '.' or '-'))
        {
            return JsonValue.Number(number);
        }
        if ((raw.StartsWith('"') && raw.EndsWith('"')) || (raw.StartsWith('\'') && raw.EndsWith('\'')))
        {
            return JsonValue.String(raw[1..^1]);
        }
        return JsonValue.String(raw);
    }

    private static void SkipEmpty(ref int index, string[] lines)
    {
        while (index < lines.Length)
        {
            var (_, content) = SplitIndent(lines[index]);
            if (content.Length == 0 || content.StartsWith('#'))
            {
                index++;
                continue;
            }
            break;
        }
    }

    private static void SkipBlankKeep(ref int index, string[] lines)
    {
        while (index < lines.Length)
        {
            var (_, content) = SplitIndent(lines[index]);
            if (content.Length == 0)
            {
                index++;
                continue;
            }
            break;
        }
    }

    private static (int Indent, string Content) SplitIndent(string line)
    {
        var indent = 0;
        var seen = 0;
        while (seen < line.Length && line[seen] == ' ')
        {
            indent++;
            seen++;
        }
        var content = line[seen..];
        var hash = content.IndexOf('#');
        if (hash > 0 && !content.StartsWith("http", StringComparison.Ordinal) && content[hash - 1] == ' ')
        {
            content = content[..hash].TrimEnd();
        }
        return (indent, content);
    }
}

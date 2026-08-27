// Copyright (c) 2026 DOTS
// Plugin composition model derived from DeepSeek Harness.
// Copyright (c) 2026 DeepSeek. MIT. See NOTICE.

using System.Text;
using System.Text.Json;
using HarnessPluginKit;

namespace DotsHarnessCore;

public static class DshJson
{
    public static JsonValue ValueFrom(object? any) => JsonValue.FromClr(any);

    public static JsonValue Parse(ReadOnlySpan<byte> data)
    {
        using var doc = JsonDocument.Parse(data.ToArray());
        return JsonValue.FromElement(doc.RootElement);
    }

    public static JsonValue Parse(string text)
    {
        using var doc = JsonDocument.Parse(text);
        return JsonValue.FromElement(doc.RootElement);
    }

    public static IReadOnlyDictionary<string, JsonValue> ObjectFrom(ReadOnlySpan<byte> data)
    {
        var value = Parse(data);
        return value.AsObject() ?? throw PluginException.ApplyFailed("expected JSON object");
    }

    public static IReadOnlyDictionary<string, JsonValue> ObjectFrom(string text)
    {
        var value = Parse(text);
        return value.AsObject() ?? throw PluginException.ApplyFailed("expected JSON object");
    }

    public static byte[] DataFrom(object obj)
    {
        return JsonSerializer.SerializeToUtf8Bytes(obj, SerializerOptions);
    }

    public static readonly JsonSerializerOptions SerializerOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull,
    };

    public static string TextBlocks(this JsonValue value) => value switch
    {
        JsonValue.JsonString s => s.Value,
        JsonValue.JsonArray a => string.Concat(a.Value.Select(item =>
        {
            var type = item["type"]?.AsString();
            if (type == "text") return item["text"]?.AsString() ?? "";
            if (type == "reasoning") return "";
            return item["text"]?.AsString() ?? "";
        })),
        JsonValue.JsonObject o =>
            o.Value.TryGetValue("type", out var t) && t.AsString() == "text"
                ? o.Value.TryGetValue("text", out var text) ? text.AsString() ?? "" : ""
                : o.Value.TryGetValue("content", out var content)
                    ? content.TextBlocks()
                    : o.Value.TryGetValue("message", out var message)
                        ? message.TextBlocks()
                        : o.Value.TryGetValue("text", out var body) ? body.AsString() ?? "" : "",
        _ => "",
    };
}

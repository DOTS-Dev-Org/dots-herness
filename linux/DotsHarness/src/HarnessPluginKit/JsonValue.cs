// Copyright (c) 2026 DOTS
// Plugin composition model derived from DeepSeek Harness.
// Copyright (c) 2026 DeepSeek. MIT. See NOTICE.

using System.Text.Json;
using System.Text.Json.Serialization;

namespace HarnessPluginKit;

/// <summary>
/// Lossless JSON tree used for plugin config. Live Cordis/DSH objects are
/// never stored here.
/// </summary>
[JsonConverter(typeof(JsonValueConverter))]
public abstract record JsonValue
{
    public static readonly JsonValue Null = new JsonNull();

    public sealed record JsonNull : JsonValue;
    public sealed record JsonBool(bool Value) : JsonValue;
    public sealed record JsonNumber(double Value) : JsonValue;
    public sealed record JsonString(string Value) : JsonValue;
    public sealed record JsonArray(IReadOnlyList<JsonValue> Value) : JsonValue;
    public sealed record JsonObject(IReadOnlyDictionary<string, JsonValue> Value) : JsonValue;

    public static JsonValue Bool(bool value) => new JsonBool(value);
    public static JsonValue Number(double value) => new JsonNumber(value);
    public static JsonValue String(string value) => new JsonString(value);
    public static JsonValue Array(params JsonValue[] items) => new JsonArray(items);
    public static JsonValue Array(IEnumerable<JsonValue> items) => new JsonArray(items.ToList());
    public static JsonValue Object(IReadOnlyDictionary<string, JsonValue> value) => new JsonObject(value);
    public static JsonValue Object(params (string Key, JsonValue Value)[] pairs) =>
        new JsonObject(pairs.ToDictionary(p => p.Key, p => p.Value, StringComparer.Ordinal));

    public string? AsString() => this is JsonString s ? s.Value : null;
    public int? AsInt() => this is JsonNumber n ? (int)n.Value : null;
    public double? AsDouble() => this is JsonNumber n ? n.Value : null;
    public bool? AsBool() => this is JsonBool b ? b.Value : null;
    public IReadOnlyDictionary<string, JsonValue>? AsObject() => this is JsonObject o ? o.Value : null;
    public IReadOnlyList<JsonValue>? AsArray() => this is JsonArray a ? a.Value : null;

    public JsonValue? this[string key] => AsObject() is { } obj && obj.TryGetValue(key, out var value) ? value : null;

    public string StringFor(string key, string defaultValue) => this[key]?.AsString() ?? defaultValue;
    public int IntFor(string key, int defaultValue) => this[key]?.AsInt() ?? defaultValue;

    public object? ToClr() => this switch
    {
        JsonNull => null,
        JsonBool b => b.Value,
        JsonNumber n => n.Value,
        JsonString s => s.Value,
        JsonArray a => a.Value.Select(v => v.ToClr()).ToList(),
        JsonObject o => o.Value.ToDictionary(kv => kv.Key, kv => kv.Value.ToClr(), StringComparer.Ordinal),
        _ => null,
    };

    public static JsonValue FromClr(object? any)
    {
        switch (any)
        {
            case null: return Null;
            case JsonValue already: return already;
            case bool b: return Bool(b);
            case byte n: return Number(n);
            case sbyte n: return Number(n);
            case short n: return Number(n);
            case ushort n: return Number(n);
            case int n: return Number(n);
            case uint n: return Number(n);
            case long n: return Number(n);
            case ulong n: return Number(n);
            case float n: return Number(n);
            case double n: return Number(n);
            case decimal n: return Number((double)n);
            case string s: return String(s);
            case JsonElement element: return FromElement(element);
            case IDictionary<string, object?> dict:
                return Object(dict.ToDictionary(kv => kv.Key, kv => FromClr(kv.Value), StringComparer.Ordinal));
            case IDictionary<string, JsonValue> typed:
                return Object(new Dictionary<string, JsonValue>(typed, StringComparer.Ordinal));
            case IEnumerable<object?> list:
                return Array(list.Select(FromClr));
            default:
                return Null;
        }
    }

    public static JsonValue FromElement(JsonElement element) => element.ValueKind switch
    {
        JsonValueKind.Null or JsonValueKind.Undefined => Null,
        JsonValueKind.True => Bool(true),
        JsonValueKind.False => Bool(false),
        JsonValueKind.Number => Number(element.TryGetInt64(out var i) ? i : element.GetDouble()),
        JsonValueKind.String => String(element.GetString() ?? ""),
        JsonValueKind.Array => Array(element.EnumerateArray().Select(FromElement).ToList()),
        JsonValueKind.Object => Object(element.EnumerateObject()
            .ToDictionary(p => p.Name, p => FromElement(p.Value), StringComparer.Ordinal)),
        _ => Null,
    };

    public static JsonValue Parse(string json) => FromElement(JsonDocument.Parse(json).RootElement.Clone());

    public static JsonValue Parse(ReadOnlySpan<byte> json) =>
        FromElement(JsonDocument.Parse(json.ToArray()).RootElement.Clone());

    public string ToJson() => JsonSerializer.Serialize(this, JsonValueJson.Options);
}

public static class JsonObjectExtensions
{
    public static string StringFor(this IReadOnlyDictionary<string, JsonValue> obj, string key, string defaultValue) =>
        obj.TryGetValue(key, out var value) ? value.AsString() ?? defaultValue : defaultValue;

    public static int IntFor(this IReadOnlyDictionary<string, JsonValue> obj, string key, int defaultValue) =>
        obj.TryGetValue(key, out var value) ? value.AsInt() ?? defaultValue : defaultValue;

    public static Dictionary<string, JsonValue> MergeFrom(
        this IReadOnlyDictionary<string, JsonValue> existing,
        IReadOnlyDictionary<string, JsonValue> incoming)
    {
        var merged = new Dictionary<string, JsonValue>(existing, StringComparer.Ordinal);
        foreach (var (key, value) in incoming)
        {
            if (value is JsonValue.JsonObject incomingObj
                && merged.TryGetValue(key, out var current)
                && current is JsonValue.JsonObject existingObj)
            {
                merged[key] = JsonValue.Object(existingObj.Value.MergeFrom(incomingObj.Value));
            }
            else
            {
                merged[key] = value;
            }
        }
        return merged;
    }
}

internal static class JsonValueJson
{
    public static readonly JsonSerializerOptions Options = new()
    {
        Converters = { new JsonValueConverter() },
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        WriteIndented = false,
    };
}

internal sealed class JsonValueConverter : JsonConverter<JsonValue>
{
    public override JsonValue Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        using var doc = JsonDocument.ParseValue(ref reader);
        return JsonValue.FromElement(doc.RootElement);
    }

    public override void Write(Utf8JsonWriter writer, JsonValue value, JsonSerializerOptions options)
    {
        switch (value)
        {
            case JsonValue.JsonNull:
                writer.WriteNullValue();
                break;
            case JsonValue.JsonBool b:
                writer.WriteBooleanValue(b.Value);
                break;
            case JsonValue.JsonNumber n:
                writer.WriteNumberValue(n.Value);
                break;
            case JsonValue.JsonString s:
                writer.WriteStringValue(s.Value);
                break;
            case JsonValue.JsonArray a:
                writer.WriteStartArray();
                foreach (var item in a.Value) Write(writer, item, options);
                writer.WriteEndArray();
                break;
            case JsonValue.JsonObject o:
                writer.WriteStartObject();
                foreach (var (key, item) in o.Value)
                {
                    writer.WritePropertyName(key);
                    Write(writer, item, options);
                }
                writer.WriteEndObject();
                break;
        }
    }
}

// Copyright (c) 2026 DOTS
// Local response feedback and the small, relevant examples it produces.

using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace DotsHarnessCore;

public enum FeedbackType
{
    Good,
    Bad,
}

public sealed record FeedbackSubmission(FeedbackType Type, IReadOnlyList<string> Tags, string Comment);

public sealed record FeedbackOption(string Id, FeedbackType Type)
{
    public string TitleKey => $"feedback.tag.{Id}";
}

/// <summary>Stable, untranslated ids shared with the macOS feedback store.</summary>
public static class FeedbackCatalog
{
    public static readonly IReadOnlyList<FeedbackOption> Positive =
    [
        new("task_completed", FeedbackType.Good),
        new("followed_instructions", FeedbackType.Good),
        new("output_quality", FeedbackType.Good),
        new("fast_efficient", FeedbackType.Good),
        new("useful_autonomy", FeedbackType.Good),
        new("positive_other", FeedbackType.Good),
        new("keep_project_style", FeedbackType.Good),
        new("reuse_token_pattern", FeedbackType.Good),
        new("reuse_architecture", FeedbackType.Good),
        new("apply_elsewhere", FeedbackType.Good),
    ];

    public static readonly IReadOnlyList<FeedbackOption> Negative =
    [
        new("incorrect_incomplete", FeedbackType.Bad),
        new("did_not_follow_instructions", FeedbackType.Bad),
        new("off_topic_out_of_scope", FeedbackType.Bad),
        new("lost_context", FeedbackType.Bad),
        new("slow_or_buggy", FeedbackType.Bad),
        new("security_or_legal_issue", FeedbackType.Bad),
        new("negative_other", FeedbackType.Bad),
        new("wrong_theme_or_token", FeedbackType.Bad),
        new("broke_existing_feature", FeedbackType.Bad),
        new("ignored_project_architecture", FeedbackType.Bad),
        new("did_not_follow_project_style", FeedbackType.Bad),
    ];

    public static IReadOnlyList<FeedbackOption> For(FeedbackType type) =>
        type == FeedbackType.Good ? Positive : Negative;

    public static bool IsMeaningfulPositive(IEnumerable<string> tags) => tags.Any(tag => tag is
        "keep_project_style" or "reuse_token_pattern" or "reuse_architecture" or "apply_elsewhere");
}

/// <summary>
/// Raw feedback stays in the project-local .mem folder. The prompt and answer
/// are redacted and bounded before they are sent to the private lesson evaluator.
/// </summary>
public sealed record FeedbackRecord(
    [property: JsonPropertyName("conversation_id")] string ConversationId,
    [property: JsonPropertyName("message_id")] string MessageId,
    [property: JsonPropertyName("prompt")] string Prompt,
    [property: JsonPropertyName("response")] string Response,
    [property: JsonPropertyName("feedback_type")] FeedbackType Type,
    [property: JsonPropertyName("tags")] IReadOnlyList<string> Tags,
    [property: JsonPropertyName("user_comment")] string UserComment,
    [property: JsonPropertyName("timestamp")] DateTimeOffset Timestamp)
{
    [JsonIgnore]
    public string Id => $"{ConversationId}:{MessageId}";
}

public sealed class FeedbackStore
{
    public const int MaxCommentCharacters = 2_000;

    private sealed record GoldExample(
        [property: JsonPropertyName("conversation_id")] string ConversationId,
        [property: JsonPropertyName("message_id")] string MessageId,
        [property: JsonPropertyName("prompt")] string Prompt,
        [property: JsonPropertyName("response")] string Response,
        [property: JsonPropertyName("tags")] IReadOnlyList<string> Tags,
        [property: JsonPropertyName("timestamp")] DateTimeOffset Timestamp);

    private static readonly object Gate = new();
    private static readonly JsonSerializerOptions Json = new()
    {
        PropertyNameCaseInsensitive = true,
        Converters = { new FeedbackTypeJsonConverter() },
    };
    private static readonly HashSet<string> StopWords = new(StringComparer.Ordinal)
    {
        "the", "and", "for", "with", "that", "this", "from", "are", "was", "were", "have", "has", "not", "you", "your",
        "bir", "ve", "ile", "için", "icin", "bu", "şu", "su", "olan", "olarak", "çok", "cok", "ama", "de", "da", "mi",
    };

    private readonly string _workspace;
    private string Root => Path.Combine(_workspace, ".mem");
    private string FeedbackPath => Path.Combine(Root, "feedback.jsonl");
    private string ExamplesPath => Path.Combine(Root, "gold_examples.json");

    public FeedbackStore(string workspace) => _workspace = Path.GetFullPath(workspace);

    public FeedbackRecord? Record(string conversationId, string messageId) =>
        ReadAll().FirstOrDefault(record => record.ConversationId == conversationId && record.MessageId == messageId);

    public IReadOnlyList<FeedbackRecord> ReadAll()
    {
        lock (Gate)
        {
            if (!File.Exists(FeedbackPath)) return [];
            var latest = new Dictionary<string, FeedbackRecord>(StringComparer.Ordinal);
            try
            {
                foreach (var line in File.ReadLines(FeedbackPath))
                {
                    try
                    {
                        if (JsonSerializer.Deserialize<FeedbackRecord>(line, Json) is { } record)
                            latest[record.Id] = record;
                    }
                    catch (JsonException) { }
                }
            }
            catch (IOException) { return []; }
            catch (UnauthorizedAccessException) { return []; }
            return latest.Values.OrderBy(record => record.Timestamp).ToList();
        }
    }

    public bool Upsert(FeedbackRecord record)
    {
        lock (Gate)
        {
            try
            {
                Directory.CreateDirectory(Root);
                var records = ReadAll().Where(item => item.Id != record.Id).Append(record)
                    .OrderBy(item => item.Timestamp).ToList();
                WriteAtomic(FeedbackPath, string.Join("\n", records.Select(item => JsonSerializer.Serialize(item, Json))) + "\n");
                try { RebuildGoldExamples(records); }
                catch (IOException) { }
                catch (UnauthorizedAccessException) { }
                return true;
            }
            catch (IOException) { return false; }
            catch (UnauthorizedAccessException) { return false; }
        }
    }

    public string DerivedKey(FeedbackRecord record) =>
        Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(record.Id))).ToLowerInvariant()[..16];

    public string ExamplesText(string prompt)
    {
        var promptTokens = Tokens(prompt);
        if (promptTokens.Count == 0) return "";
        GoldExample[] examples;
        try
        {
            if (!File.Exists(ExamplesPath)) return "";
            examples = JsonSerializer.Deserialize<GoldExample[]>(File.ReadAllText(ExamplesPath), Json) ?? [];
        }
        catch (IOException) { return ""; }
        catch (JsonException) { return ""; }
        catch (UnauthorizedAccessException) { return ""; }

        var selected = examples.Select(example =>
            {
                var tokens = Tokens(example.Prompt);
                var overlap = promptTokens.Intersect(tokens).Count();
                var score = (double)overlap / Math.Max(1, promptTokens.Union(tokens).Count());
                return (Example: example, Score: score, Overlap: overlap);
            })
            .Where(item => item.Overlap >= Math.Min(2, promptTokens.Count))
            .OrderByDescending(item => item.Score)
            .ThenByDescending(item => item.Example.Timestamp)
            .Take(3)
            .Select(item => item.Example)
            .ToList();
        if (selected.Count == 0) return "";

        var blocks = new List<string>();
        foreach (var (example, index) in selected.Select((example, index) => (example, index)))
        {
            var block = $"### Example {index + 1}\nPrompt:\n{Clip(example.Prompt, 600)}\nResponse:\n{Clip(example.Response, 2_000)}";
            var candidate = string.Join("\n\n", blocks.Append(block));
            if (candidate.Length > 8_000) break;
            blocks.Add(block);
        }
        return blocks.Count == 0 ? "" : "## Gold examples (reference only)\n" + string.Join("\n\n", blocks);
    }

    public static string? DirectRule(FeedbackRecord record)
    {
        if (record.Type != FeedbackType.Bad || string.IsNullOrWhiteSpace(record.UserComment)) return null;
        var comment = PromptAssembly.Mask(record.UserComment)
            .Split(['<', '>', '`', '*', '_'], StringSplitOptions.RemoveEmptyEntries)
            .SelectMany(part => part.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));
        var cleaned = string.Join(" ", comment);
        return cleaned.Length == 0 ? null : "Avoid (user-reported): " + Clip(cleaned, 560);
    }

    private void RebuildGoldExamples(IReadOnlyList<FeedbackRecord> records)
    {
        var examples = records.Where(record => record.Type == FeedbackType.Good)
            .Select(record => new GoldExample(record.ConversationId, record.MessageId, record.Prompt,
                record.Response, record.Tags, record.Timestamp)).ToList();
        WriteAtomic(ExamplesPath, JsonSerializer.Serialize(examples, Json));
    }

    private static void WriteAtomic(string path, string contents)
    {
        var temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            File.WriteAllText(temporary, contents, new UTF8Encoding(false));
            File.Move(temporary, path, overwrite: true);
        }
        finally
        {
            try { if (File.Exists(temporary)) File.Delete(temporary); } catch (IOException) { }
        }
    }

    private sealed class FeedbackTypeJsonConverter : JsonConverter<FeedbackType>
    {
        public override FeedbackType Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options) =>
            reader.GetString() switch
            {
                "good" => FeedbackType.Good,
                "bad" => FeedbackType.Bad,
                _ => throw new JsonException("Unknown feedback type."),
            };

        public override void Write(Utf8JsonWriter writer, FeedbackType value, JsonSerializerOptions options) =>
            writer.WriteStringValue(value == FeedbackType.Good ? "good" : "bad");
    }

    private static string Clip(string value, int limit) =>
        value.Length <= limit ? value : value[..limit] + "\n[content clipped]";

    private static HashSet<string> Tokens(string text)
    {
        var normalized = text.Normalize(NormalizationForm.FormD).ToLowerInvariant();
        var words = new List<string>();
        var current = new StringBuilder();
        foreach (var character in normalized)
        {
            if (char.GetUnicodeCategory(character) == System.Globalization.UnicodeCategory.NonSpacingMark) continue;
            if (char.IsLetterOrDigit(character)) current.Append(character == 'ı' ? 'i' : character);
            else if (current.Length > 0) { words.Add(current.ToString()); current.Clear(); }
        }
        if (current.Length > 0) words.Add(current.ToString());
        return words.Where(word => word.Length >= 3 && !StopWords.Contains(word)).ToHashSet(StringComparer.Ordinal);
    }
}

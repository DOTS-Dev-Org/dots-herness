// Copyright (c) 2026 DOTS
// Local response feedback: which answer it was given on, never the answer itself.

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
/// Feedback on one answer. The prompt and answer are held only while the record is
/// in memory, for the lesson evaluator; the file keeps their hash (see
/// FeedbackStore.Stored), so a record read back has them empty.
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

    [JsonIgnore]
    public string Digest { get; init; } = ComputeDigest(Prompt, Response);

    public static string ComputeDigest(string prompt, string response) =>
        Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(prompt + "\0" + response))).ToLowerInvariant();
}

public sealed class FeedbackStore
{
    public const int MaxCommentCharacters = 2_000;

    /// <summary>One line of feedback.jsonl. Prompt and Response are only read, from files
    /// written before the text was dropped, and never written.</summary>
    private sealed record Stored(
        [property: JsonPropertyName("conversation_id")] string ConversationId,
        [property: JsonPropertyName("message_id")] string MessageId,
        [property: JsonPropertyName("digest")] string? Digest,
        [property: JsonPropertyName("prompt"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] string? Prompt,
        [property: JsonPropertyName("response"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] string? Response,
        [property: JsonPropertyName("feedback_type")] FeedbackType Type,
        [property: JsonPropertyName("tags")] IReadOnlyList<string>? Tags,
        [property: JsonPropertyName("user_comment")] string? UserComment,
        [property: JsonPropertyName("timestamp")] DateTimeOffset Timestamp)
    {
        public static Stored From(FeedbackRecord record) => new(record.ConversationId, record.MessageId, record.Digest,
            null, null, record.Type, record.Tags, record.UserComment, record.Timestamp);

        public FeedbackRecord Record() => new(ConversationId, MessageId, "", "", Type, Tags ?? [], UserComment ?? "", Timestamp)
        {
            Digest = Digest ?? FeedbackRecord.ComputeDigest(Prompt ?? "", Response ?? ""),
        };
    }

    private static readonly object Gate = new();
    private static readonly JsonSerializerOptions Json = new()
    {
        PropertyNameCaseInsensitive = true,
        Converters = { new FeedbackTypeJsonConverter() },
    };
    private readonly string _workspace;
    private readonly string? _userRoot;
    private string Root => !string.IsNullOrWhiteSpace(_userRoot)
        ? WorkspaceInsights.Folder(_workspace, _userRoot) ?? Path.Combine(_workspace, ".mem")
        : Path.Combine(_workspace, ".mem");
    private string FeedbackPath => Path.Combine(Root, "feedback.jsonl");
    private string ExamplesPath => Path.Combine(Root, "gold_examples.json");

    public FeedbackStore(string workspace, string? userRoot = null)
    {
        _workspace = Path.GetFullPath(workspace);
        _userRoot = userRoot;
        MigrateLegacyFeedback();
    }

    private void MigrateLegacyFeedback()
    {
        if (string.IsNullOrWhiteSpace(_userRoot)
            || WorkspaceInsights.Folder(_workspace, _userRoot) is not { } folder) return;
        var source = Path.Combine(_workspace, ".mem", "feedback.jsonl");
        var destination = Path.Combine(folder, "feedback.jsonl");
        if (File.Exists(destination) || !File.Exists(source)) return;
        lock (Gate)
        {
            if (File.Exists(destination)) return;
            try
            {
                Directory.CreateDirectory(folder);
                File.Copy(source, destination, overwrite: false);
            }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }
    }

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
                        if (JsonSerializer.Deserialize<Stored>(line, Json) is { } stored)
                        {
                            var record = stored.Record();
                            latest[record.Id] = record;
                        }
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
                WriteAtomic(FeedbackPath, string.Join("\n", records.Select(item => JsonSerializer.Serialize(Stored.From(item), Json))) + "\n");
                return true;
            }
            catch (IOException) { return false; }
            catch (UnauthorizedAccessException) { return false; }
        }
    }

    public string DerivedKey(FeedbackRecord record) =>
        Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(record.Id))).ToLowerInvariant()[..16];

    /// <summary>Removes what earlier versions kept of the conversation: the request and
    /// answer inside each record, and the approved answers copied out as examples.</summary>
    public void DropRawText()
    {
        lock (Gate)
        {
            try
            {
                File.Delete(ExamplesPath);
                if (!File.Exists(FeedbackPath)) return;
                var text = File.ReadAllText(FeedbackPath);
                if (!text.Contains("\"prompt\":") && !text.Contains("\"response\":")) return;
                WriteAtomic(FeedbackPath, string.Join("\n", ReadAll().Select(item => JsonSerializer.Serialize(Stored.From(item), Json))) + "\n");
            }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }
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
}

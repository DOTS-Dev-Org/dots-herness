// Copyright (c) 2026 DOTS
// Shared Chat/Coding area and message-derived filesystem context contracts.

using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;

namespace DotsHarnessCore;

[JsonConverter(typeof(AgentAreaJsonConverter))]
public enum AgentArea
{
    Chat,
    Coding,

    // The persisted wire contract uses lowercase values even though the CLR
    // enum follows the platform naming convention.
}

public static class AgentAreaExtensions
{
    public static string SessionFileName(this AgentArea area) => area switch
    {
        AgentArea.Chat => "chat-sessions.json",
        _ => "coding-sessions.json",
    };

    public static string WireValue(this AgentArea area) => area == AgentArea.Chat ? "chat" : "coding";
}

[JsonConverter(typeof(ChatContextRootKindJsonConverter))]
public enum ChatContextRootKind
{
    File,
    Directory,
}

public sealed class AgentAreaJsonConverter : JsonConverter<AgentArea>
{
    public override AgentArea Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options) =>
        reader.GetString()?.ToLowerInvariant() switch
        {
            "chat" => AgentArea.Chat,
            "coding" => AgentArea.Coding,
            _ => throw new JsonException("Unknown agent area."),
        };

    public override void Write(Utf8JsonWriter writer, AgentArea value, JsonSerializerOptions options) =>
        writer.WriteStringValue(value.WireValue());
}

public sealed class ChatContextRootKindJsonConverter : JsonConverter<ChatContextRootKind>
{
    public override ChatContextRootKind Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options) =>
        reader.GetString()?.ToLowerInvariant() switch
        {
            "file" => ChatContextRootKind.File,
            "directory" => ChatContextRootKind.Directory,
            _ => throw new JsonException("Unknown chat context root kind."),
        };

    public override void Write(Utf8JsonWriter writer, ChatContextRootKind value, JsonSerializerOptions options) =>
        writer.WriteStringValue(value == ChatContextRootKind.File ? "file" : "directory");
}

public sealed class ChatContextRoot
{
    public string Id { get; set; } = "";
    public string Path { get; set; } = "";
    public ChatContextRootKind Kind { get; set; }
    [JsonPropertyName("sourceMessageIDs")]
    public List<string> SourceMessageIds { get; set; } = [];
    public DateTimeOffset CreatedAt { get; set; } = DateTimeOffset.UtcNow;
    public DateTimeOffset LastUsedAt { get; set; } = DateTimeOffset.UtcNow;

    public static ChatContextRoot Create(string path, ChatContextRootKind kind, string sourceMessageId)
    {
        var normalized = System.IO.Path.GetFullPath(path);
        return new ChatContextRoot
        {
            Id = IdFor(normalized),
            Path = normalized,
            Kind = kind,
            SourceMessageIds = [sourceMessageId],
        };
    }

    public static string IdFor(string path)
    {
        var hash = SHA256.HashData(Encoding.UTF8.GetBytes(path));
        return "context-" + Convert.ToHexString(hash)[..24].ToLowerInvariant();
    }
}

public sealed class ChatContextLedger
{
    public List<ChatContextRoot> Roots { get; set; } = [];
    public List<string> ProjectNotes { get; set; } = [];
    public List<string> ChangeSummaries { get; set; } = [];
    public int Revision { get; set; }
    public DateTimeOffset UpdatedAt { get; set; } = DateTimeOffset.UtcNow;

    public IReadOnlyList<ChatContextRoot> Attach(IEnumerable<ChatContextRoot> incoming, string messageId)
    {
        var attached = new List<ChatContextRoot>();
        var changed = false;
        foreach (var root in incoming)
        {
            var existing = Roots.FirstOrDefault(item => item.Id == root.Id);
            if (existing is null)
            {
                root.SourceMessageIds = root.SourceMessageIds
                    .Append(messageId)
                    .Distinct(StringComparer.Ordinal)
                    .ToList();
                root.LastUsedAt = DateTimeOffset.UtcNow;
                Roots.Add(root);
                attached.Add(root);
                changed = true;
            }
            else
            {
                if (!existing.SourceMessageIds.Contains(messageId, StringComparer.Ordinal))
                {
                    existing.SourceMessageIds.Add(messageId);
                    changed = true;
                }
                existing.LastUsedAt = DateTimeOffset.UtcNow;
                attached.Add(existing);
            }
        }
        if (changed || attached.Count > 0)
        {
            Revision++;
            UpdatedAt = DateTimeOffset.UtcNow;
        }
        return attached;
    }

    public void AddNote(string note)
    {
        var value = note.Trim();
        if (value.Length == 0 || ProjectNotes.Contains(value, StringComparer.Ordinal)) return;
        ProjectNotes.Add(value);
        Revision++;
        UpdatedAt = DateTimeOffset.UtcNow;
    }

    public void AddChangeSummary(string summary)
    {
        var value = summary.Trim();
        if (value.Length == 0) return;
        ChangeSummaries.Add(value);
        if (ChangeSummaries.Count > 100) ChangeSummaries.RemoveRange(0, ChangeSummaries.Count - 100);
        Revision++;
        UpdatedAt = DateTimeOffset.UtcNow;
    }
}

public sealed class ChatProject
{
    public string Id { get; set; } = Guid.NewGuid().ToString();
    public string Name { get; set; } = "New chat project";
    public string Description { get; set; } = "";
    public bool Pinned { get; set; }
    public string? Section { get; set; }
    public bool Archived { get; set; }
    public int SortOrder { get; set; }
    public DateTimeOffset CreatedAt { get; set; } = DateTimeOffset.UtcNow;
    public DateTimeOffset UpdatedAt { get; set; } = DateTimeOffset.UtcNow;
}

public sealed class ChatContextStore
{
    private readonly string _directory;

    public ChatContextStore(string root)
    {
        _directory = System.IO.Path.Combine(root, "chat-context");
    }

    public ChatContextLedger Load(string scopeId)
    {
        var file = FilePath(scopeId);
        try
        {
            return File.Exists(file)
                ? JsonSerializer.Deserialize<ChatContextLedger>(File.ReadAllText(file)) ?? new ChatContextLedger()
                : new ChatContextLedger();
        }
        catch { return new ChatContextLedger(); }
    }

    public void Save(string scopeId, ChatContextLedger ledger)
    {
        try
        {
            Directory.CreateDirectory(_directory);
            File.WriteAllText(FilePath(scopeId), JsonSerializer.Serialize(ledger, new JsonSerializerOptions { WriteIndented = true }));
        }
        catch { }
    }

    private string FilePath(string scopeId)
    {
        var safe = new string(scopeId.Select(character => char.IsLetterOrDigit(character) || character is '-' or '_' ? character : '_').ToArray());
        return System.IO.Path.Combine(_directory, (safe.Length == 0 ? "conversation" : safe) + ".json");
    }
}

public sealed class ChatProjectStore
{
    private readonly string _file;

    public ChatProjectStore(string root) => _file = System.IO.Path.Combine(root, "chat-projects.json");

    public List<ChatProject> Load()
    {
        try
        {
            var projects = JsonSerializer.Deserialize<List<ChatProject>>(File.ReadAllText(_file)) ?? [];
            return projects
                .OrderByDescending(project => project.Pinned)
                .ThenBy(project => project.SortOrder)
                .ThenByDescending(project => project.UpdatedAt)
                .ToList();
        }
        catch { return []; }
    }

    public void Save(IEnumerable<ChatProject> projects)
    {
        try
        {
            Directory.CreateDirectory(System.IO.Path.GetDirectoryName(_file)!);
            File.WriteAllText(_file, JsonSerializer.Serialize(projects, new JsonSerializerOptions { WriteIndented = true }));
        }
        catch { }
    }
}

public static class ChatPathParser
{
    private static readonly Regex PathPattern = new(
        """(?:"([^"]+)"|'([^']+)'|`([^`]+)`|((?:[A-Za-z]:[\\/][^\s"'`]+)|(?:\\\\[^\s"'`]+)|(?:/(?:[^\s"'`]|\\ )+))|((?:(?:\./|\.\./)?[A-Za-z0-9_.-]+(?:[\\/][A-Za-z0-9_.-]+)+)|(?:(?:\./|\.\./)[A-Za-z0-9_.-]+)|(?:[A-Za-z0-9_.-]+\.[A-Za-z0-9_-]+)))""",
        RegexOptions.Compiled);

    public static IReadOnlyList<string> ExtractPaths(string text)
    {
        var result = new List<string>();
        foreach (Match match in PathPattern.Matches(text ?? ""))
        {
            var value = Enumerable.Range(1, 5)
                .Select(index => match.Groups[index].Value)
                .FirstOrDefault(candidate => !string.IsNullOrWhiteSpace(candidate));
            if (string.IsNullOrWhiteSpace(value)) continue;
            value = TrimPunctuation(value);
            if (value.Length > 0 && !result.Contains(value, StringComparer.Ordinal)) result.Add(value);
        }
        return result;
    }

    public static IReadOnlyList<ChatContextRoot> ExtractRoots(
        string text,
        IEnumerable<ChatContextRoot> knownRoots,
        string sourceMessageId)
    {
        var result = new List<ChatContextRoot>();
        foreach (var candidate in ExtractPaths(text))
        {
            if (IsAbsolute(candidate) && TryCreate(candidate, sourceMessageId) is { } direct)
            {
                if (!result.Any(root => root.Id == direct.Id)) result.Add(direct);
                continue;
            }
            if (IsAbsolute(candidate)) continue;
            foreach (var known in knownRoots)
            {
                try
                {
                    var basePath = known.Kind == ChatContextRootKind.Directory
                        ? known.Path
                        : System.IO.Path.GetDirectoryName(known.Path) ?? known.Path;
                    var resolved = System.IO.Path.GetFullPath(System.IO.Path.Combine(basePath, candidate));
                    if (TryCreate(resolved, sourceMessageId) is { } relative
                        && !result.Any(root => root.Id == relative.Id)) result.Add(relative);
                }
                catch { }
            }
        }
        return result;
    }

    public static bool IsAbsolute(string path) =>
        System.IO.Path.IsPathRooted(path)
        || Regex.IsMatch(path, @"^[A-Za-z]:[\\/]")
        || path.StartsWith(@"\\", StringComparison.Ordinal);

    private static ChatContextRoot? TryCreate(string path, string sourceMessageId)
    {
        try
        {
            var full = System.IO.Path.GetFullPath(path);
            if (File.Exists(full)) return ChatContextRoot.Create(full, ChatContextRootKind.File, sourceMessageId);
            if (Directory.Exists(full)) return ChatContextRoot.Create(full, ChatContextRootKind.Directory, sourceMessageId);
        }
        catch { }
        return null;
    }

    private static string TrimPunctuation(string value) => value.TrimEnd('.', ',', ';', ':', '!', '?', ')', ']', '}');
}

public static class AgentCacheNamespace
{
    public static string Create(
        AgentArea area,
        string conversationId,
        string? chatProjectId,
        string? codingProjectId,
        string model,
        bool planMode,
        int contextRevision,
        IEnumerable<string>? rootIds = null,
        string? provider = null,
        string? api = null,
        string? accountId = null,
        string? toolFingerprint = null,
        string? contextSegment = null)
    {
        var identity = string.Join('|',
            area.ToString().ToLowerInvariant(), conversationId, chatProjectId ?? "none", codingProjectId ?? "none",
            model, planMode ? "plan" : "normal", contextRevision.ToString(),
            string.Join(',', (rootIds ?? []).OrderBy(value => value, StringComparer.Ordinal)),
            provider ?? "unknown-provider", api ?? "unknown-api", accountId ?? "unknown-account",
            toolFingerprint ?? "unknown-tools", contextSegment ?? "segment-0");
        var digest = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(identity))).ToLowerInvariant();
        return $"herness:area-v1:{area.ToString().ToLowerInvariant()}:{digest}";
    }

    public static string ToolFingerprint(IEnumerable<NativeToolDefinition> tools)
    {
        var canonical = string.Join("\n---\n", tools
            .OrderBy(tool => tool.Name, StringComparer.Ordinal)
            .Select(tool => $"{tool.Name}\n{tool.Description}\n{tool.Parameters.ToJsonString()}"));
        var digest = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(canonical))).ToLowerInvariant();
        return digest[..32];
    }
}

// Copyright (c) 2026 DOTS
// Migrate the historical Chat/Coding stores into the single project session store.

using System.Text.Json;
using PluginRuntime;

namespace DotsHarnessCore;

/// <summary>
/// Converts every historical conversation file into <c>sessions.json</c>.
/// Projectless conversations and workspace-bound conversations are both kept;
/// the migration is idempotent and removes the old area stores only after a
/// verified write.
/// </summary>
public static class SessionAreaMigration
{
    private const string CanonicalFileName = "sessions.json";
    private const string CompletionMarkerName = "project-session-migration-v1.json";
    private static readonly string[] ObsoleteFiles =
    [
        "coding-sessions.json",
        "chat-sessions.json",
        "conversations.json",
        "chat-projects.json",
        "area-session-migration-v1.json",
        "area-session-migration-v2.json",
    ];

    public static void Run(SupportPaths paths)
    {
        paths.Ensure();
        var root = paths.Root;
        var canonicalPath = Path.Combine(root, CanonicalFileName);
        var sources = new[] { canonicalPath }
            .Concat(ObsoleteFiles.Select(name => Path.Combine(root, name)))
            .Distinct(StringComparer.Ordinal)
            .ToArray();

        var selected = new Dictionary<string, Conversation>(StringComparer.Ordinal);
        foreach (var source in sources)
        {
            foreach (var conversation in Read(source))
            {
                // The transcript with the most messages is the useful copy when
                // an interrupted previous migration left duplicates behind.
                if (!selected.TryGetValue(conversation.Id, out var existing)
                    || conversation.Messages.Count > existing.Messages.Count
                    || (conversation.Messages.Count == existing.Messages.Count
                        && Activity(conversation) > Activity(existing)))
                {
                    selected[conversation.Id] = conversation;
                }
            }
        }

        var projectConversations = selected.Values
            .OrderBy(item => item.Id, StringComparer.Ordinal)
            .ToList();

        Write(canonicalPath, projectConversations);
        var verified = Read(canonicalPath);
        if (verified.Count != projectConversations.Count
            || verified.Select(item => item.Id).ToHashSet(StringComparer.Ordinal).Count != projectConversations.Count
            || !verified.Select(item => item.Id).ToHashSet(StringComparer.Ordinal)
                .SetEquals(projectConversations.Select(item => item.Id)))
        {
            // Never remove a legacy file if the canonical write could not be
            // read back successfully.
            return;
        }

        foreach (var obsolete in ObsoleteFiles)
        {
            var file = Path.Combine(root, obsolete);
            try { if (!string.Equals(file, canonicalPath, StringComparison.Ordinal)) File.Delete(file); }
            catch { /* cleanup is best effort; the canonical store remains safe */ }
        }

        var contextDirectory = Path.Combine(root, "chat-context");
        try { if (Directory.Exists(contextDirectory)) Directory.Delete(contextDirectory, recursive: true); }
        catch { }

        WriteMarker(Path.Combine(root, CompletionMarkerName), projectConversations.Count);
    }

    private static DateTimeOffset Activity(Conversation conversation) =>
        conversation.Messages.Count == 0
            ? DateTimeOffset.MinValue
            : conversation.Messages.Max(message => message.CreatedAt);

    private static List<Conversation> Read(string path)
    {
        try
        {
            return File.Exists(path)
                ? JsonSerializer.Deserialize<List<Conversation>>(File.ReadAllText(path)) ?? []
                : [];
        }
        catch { return []; }
    }

    private static void Write(string path, IReadOnlyList<Conversation> conversations)
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            var temporary = path + ".tmp";
            File.WriteAllText(temporary, JsonSerializer.Serialize(conversations, new JsonSerializerOptions { WriteIndented = true }));
            File.Move(temporary, path, overwrite: true);
        }
        catch { }
    }

    private static void WriteMarker(string path, int count)
    {
        try
        {
            File.WriteAllText(
                path,
                JsonSerializer.Serialize(new
                {
                    version = 1,
                    completedAt = DateTimeOffset.UtcNow,
                    conversationCount = count,
                    canonicalFile = CanonicalFileName,
                }, new JsonSerializerOptions { WriteIndented = true }));
        }
        catch { }
    }
}

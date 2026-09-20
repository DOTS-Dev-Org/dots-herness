// Copyright (c) 2026 DOTS
// One-time migration from the pre-area conversation stores.

using System.Text.Json;
using PluginRuntime;

namespace DotsHarnessCore;

public static class SessionAreaMigration
{
    private const string MarkerName = "area-session-migration-v1.json";
    private const string RepairMarkerName = "area-session-migration-v2.json";

    public static void Run(SupportPaths paths)
    {
        paths.Ensure();
        var marker = Path.Combine(paths.Root, MarkerName);
        var codingPath = Path.Combine(paths.Root, AgentArea.Coding.SessionFileName());
        var chatPath = Path.Combine(paths.Root, AgentArea.Chat.SessionFileName());
        if (!File.Exists(marker)) MigrateLegacy(paths, marker, codingPath, chatPath);

        var repairMarker = Path.Combine(paths.Root, RepairMarkerName);
        if (File.Exists(repairMarker)) return;

        var selected = new Dictionary<string, Conversation>(StringComparer.Ordinal);
        foreach (var conversation in Read(codingPath).Concat(Read(chatPath)))
        {
            if (!selected.TryGetValue(conversation.Id, out var existing)
                || conversation.Messages.Count > existing.Messages.Count)
            {
                selected[conversation.Id] = conversation;
            }
        }

        var coding = new List<Conversation>();
        var chat = new List<Conversation>();
        foreach (var conversation in selected.Values.OrderBy(item => item.Id, StringComparer.Ordinal))
        {
            var hasWorkspace = !string.IsNullOrWhiteSpace(conversation.Cwd);
            conversation.Area = hasWorkspace ? AgentArea.Coding : AgentArea.Chat;
            if (hasWorkspace)
            {
                conversation.ChatProjectId = null;
                coding.Add(conversation);
            }
            else
            {
                conversation.Cwd = null;
                chat.Add(conversation);
            }
        }

        Write(codingPath, coding);
        Write(chatPath, chat);
        WriteMarker(repairMarker, coding.Count + chat.Count, version: 2);
    }

    private static void MigrateLegacy(SupportPaths paths, string marker, string codingPath, string chatPath)
    {
        var legacyFiles = new[]
        {
            Path.Combine(paths.Root, "sessions.json"),
            Path.Combine(paths.Root, "conversations.json"),
        };
        var legacy = new List<Conversation>();
        foreach (var file in legacyFiles)
        {
            if (!File.Exists(file)) continue;
            try
            {
                legacy.AddRange(JsonSerializer.Deserialize<List<Conversation>>(File.ReadAllText(file)) ?? []);
            }
            catch { }
        }

        var coding = Read(codingPath);
        var chat = Read(chatPath);
        var existing = coding.Concat(chat).Select(item => item.Id).ToHashSet(StringComparer.Ordinal);
        foreach (var conversation in legacy.Where(item => existing.Add(item.Id)))
        {
            var hasWorkspace = !string.IsNullOrWhiteSpace(conversation.Cwd);
            conversation.Area = hasWorkspace ? AgentArea.Coding : AgentArea.Chat;
            if (!hasWorkspace) conversation.Cwd = null;
            conversation.ChatProjectId = null;
            (hasWorkspace ? coding : chat).Add(conversation);
        }

        Write(codingPath, coding);
        Write(chatPath, chat);
        WriteMarker(marker, coding.Count + chat.Count, version: 1);
    }

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
            File.WriteAllText(path, JsonSerializer.Serialize(conversations, new JsonSerializerOptions { WriteIndented = true }));
        }
        catch { }
    }

    private static void WriteMarker(string path, int count, int version)
    {
        try
        {
            File.WriteAllText(
                path,
                JsonSerializer.Serialize(new
                {
                    version,
                    completedAt = DateTimeOffset.UtcNow,
                    conversationCount = count,
                }, new JsonSerializerOptions { WriteIndented = true }));
        }
        catch { }
    }
}

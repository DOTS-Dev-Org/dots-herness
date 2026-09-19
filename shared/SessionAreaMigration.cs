// Copyright (c) 2026 DOTS
// One-time migration from the pre-area conversation stores.

using System.Text.Json;
using PluginRuntime;

namespace DotsHarnessCore;

public static class SessionAreaMigration
{
    private const string MarkerName = "area-session-migration-v1.json";

    public static void Run(SupportPaths paths)
    {
        paths.Ensure();
        var marker = Path.Combine(paths.Root, MarkerName);
        if (File.Exists(marker)) return;

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

        var codingPath = Path.Combine(paths.Root, AgentArea.Coding.SessionFileName());
        var chatPath = Path.Combine(paths.Root, AgentArea.Chat.SessionFileName());
        var coding = Read(codingPath);
        var chat = Read(chatPath);
        var existing = coding.Concat(chat).Select(item => item.Id).ToHashSet(StringComparer.Ordinal);

        foreach (var conversation in legacy.Where(item => existing.Add(item.Id)))
        {
            var hasWorkspace = !string.IsNullOrWhiteSpace(conversation.Cwd);
            conversation.Area = hasWorkspace ? AgentArea.Coding : AgentArea.Chat;
            if (conversation.Area == AgentArea.Chat) conversation.Cwd = null;
            conversation.ChatProjectId = null;
            (conversation.Area == AgentArea.Chat ? chat : coding).Add(conversation);
        }

        Write(codingPath, coding);
        Write(chatPath, chat);
        try
        {
            File.WriteAllText(
                marker,
                JsonSerializer.Serialize(new
                {
                    version = 1,
                    completedAt = DateTimeOffset.UtcNow,
                    conversationCount = coding.Count + chat.Count,
                }, new JsonSerializerOptions { WriteIndented = true }));
        }
        catch { }
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
        if (conversations.Count == 0) return;
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            File.WriteAllText(path, JsonSerializer.Serialize(conversations, new JsonSerializerOptions { WriteIndented = true }));
        }
        catch { }
    }
}

using System.Collections.ObjectModel;
using System.Text.Json;
using DotsHarnessCore;
using Xunit;

namespace DotsHarness.Tests;

public sealed class ConversationSqliteStoreTests
{
    [Fact]
    public async Task ImportsLegacyJsonAndLoadsOnlyNewestTranscriptPage()
    {
        var root = Path.Combine(Path.GetTempPath(), $"dots-conversation-store-{Guid.NewGuid():N}");
        Directory.CreateDirectory(root);
        try
        {
            var legacyPath = Path.Combine(root, "sessions.json");
            var source = new Conversation
            {
                Id = "conversation-1",
                Title = "SQLite migration",
                Cwd = Path.Combine(root, "workspace"),
                ModelContext = [new NativeMessage("user", "provider context remains stored")],
                Messages = new ObservableCollection<ChatMessage>(Enumerable.Range(0, 25).Select(index => new ChatMessage
                {
                    Id = $"message-{index:00}",
                    Kind = index % 2 == 0 ? ChatKind.User : ChatKind.Assistant,
                    Text = $"message-{index:00}",
                    CreatedAt = DateTimeOffset.FromUnixTimeSeconds(index),
                })),
            };
            var legacyBytes = JsonSerializer.SerializeToUtf8Bytes(new[] { source });
            await File.WriteAllBytesAsync(legacyPath, legacyBytes);

            var store = new ConversationSqliteStore(root, legacyPath);
            Assert.True(await store.EnsureLegacyImportedAsync());
            Assert.True(File.Exists(store.DatabasePath));
            Assert.Equal(legacyBytes, await File.ReadAllBytesAsync(legacyPath));

            Assert.Equal(25, Assert.IsType<Conversation>(store.LoadAll(source.Id)).Messages.Count);

            var header = Assert.Single(store.LoadHeaders(source.Cwd));
            Assert.Empty(header.Messages);
            Assert.False(header.TranscriptLoaded);
            Assert.Equal(25, header.StoredMessageCount);

            var latest = Assert.IsType<Conversation>(store.Load(source.Id, includeModelContext: true));
            Assert.Equal(Enumerable.Range(15, 10).Select(index => $"message-{index:00}"), latest.Messages.Select(message => message.Text));
            Assert.Equal(15, latest.MessageStartIndex);
            Assert.False(latest.TranscriptComplete);
            Assert.Equal("provider context remains stored", Assert.Single(latest.ModelContext).Content);

            var older = Assert.IsType<ConversationMessagePage>(store.LoadMessagePage(source.Id, latest.MessageStartIndex));
            Assert.Equal(Enumerable.Range(5, 10).Select(index => $"message-{index:00}"), older.Messages.Select(message => message.Text));
            Assert.Equal(5, older.StartIndex);

        }
        finally
        {
            try { Directory.Delete(root, recursive: true); } catch { }
        }
    }

    [Fact]
    public async Task RecentPageLimitCountsConversationalMessagesOnly()
    {
        var root = Path.Combine(Path.GetTempPath(), $"dots-conversation-tools-{Guid.NewGuid():N}");
        Directory.CreateDirectory(root);
        try
        {
            var kinds = new[] { ChatKind.User, ChatKind.Assistant }
                .Concat(Enumerable.Repeat(ChatKind.Tool, 15))
                .Concat(Enumerable.Repeat(ChatKind.System, 3))
                .ToArray();
            var source = new Conversation
            {
                Id = "tool-heavy",
                Title = "Tool heavy",
                Cwd = Path.Combine(root, "workspace"),
                Messages = new ObservableCollection<ChatMessage>(kinds.Select((kind, index) => new ChatMessage
                {
                    Id = $"message-{index:00}",
                    Kind = kind,
                    Text = $"message-{index:00}",
                    CreatedAt = DateTimeOffset.FromUnixTimeSeconds(index),
                })),
            };
            var legacyPath = Path.Combine(root, "sessions.json");
            await File.WriteAllBytesAsync(legacyPath, JsonSerializer.SerializeToUtf8Bytes(new[] { source }));
            var store = new ConversationSqliteStore(root, legacyPath);
            Assert.True(await store.EnsureLegacyImportedAsync());

            var latest = Assert.IsType<Conversation>(store.Load(source.Id));
            Assert.Equal(source.Messages.Select(message => message.Id), latest.Messages.Select(message => message.Id));
            Assert.True(latest.TranscriptComplete);
        }
        finally
        {
            try { Directory.Delete(root, recursive: true); } catch { }
        }
    }

    [Fact]
    public async Task PreservesCorruptLegacyArchiveAndKeepsSqliteWritable()
    {
        var root = Path.Combine(Path.GetTempPath(), $"dots-conversation-corrupt-{Guid.NewGuid():N}");
        Directory.CreateDirectory(root);
        try
        {
            var legacyPath = Path.Combine(root, "sessions.json");
            var corruptBytes = System.Text.Encoding.UTF8.GetBytes("{ not json");
            await File.WriteAllBytesAsync(legacyPath, corruptBytes);

            var store = new ConversationSqliteStore(root, legacyPath);
            Assert.True(await store.EnsureLegacyImportedAsync());
            Assert.Equal(corruptBytes, await File.ReadAllBytesAsync(legacyPath + ".corrupt"));
            Assert.Equal(corruptBytes, await File.ReadAllBytesAsync(legacyPath));
            Assert.True(store.Save([new Conversation
            {
                Id = "new-conversation",
                Title = "Writable after corrupt migration",
                Cwd = Path.Combine(root, "workspace"),
                Messages = new ObservableCollection<ChatMessage>
                {
                    new() { Id = "message-1", Kind = ChatKind.User, Text = "hello" },
                },
            }]));
            Assert.Single(Assert.IsType<Conversation>(store.LoadAll("new-conversation")).Messages);
        }
        finally
        {
            try { Directory.Delete(root, recursive: true); } catch { }
        }
    }

    [Fact]
    public async Task IncrementalSavesKeepContextTranscriptAndHeadersExact()
    {
        var root = Path.Combine(Path.GetTempPath(), $"dots-conversation-diff-{Guid.NewGuid():N}");
        try
        {
            var store = new ConversationSqliteStore(root, Path.Combine(root, "sessions.json"));
            Assert.True(await store.EnsureLegacyImportedAsync());
            var conversation = new Conversation { Id = "c", Title = "t", Cwd = root, ModelContext = [new NativeMessage("user", "u0")] };
            conversation.Messages.Add(new ChatMessage { Id = "m0", Kind = ChatKind.User, Text = "hi" });
            var header = new Conversation { Id = "h", Title = "header", Cwd = root };
            Assert.True(store.Save([conversation, header]));

            // A run appends context and streams into the last bubble across saves.
            for (var step = 1; step <= 5; step++)
            {
                conversation.ModelContext = [.. conversation.ModelContext, new NativeMessage("assistant", $"a{step}")];
                conversation.Messages.Add(new ChatMessage { Id = $"m{step}", Kind = ChatKind.Assistant, Text = "partial" });
                conversation.Messages[^1].Text = $"final {step}";
                Assert.True(store.Save([conversation]));
            }
            var reloaded = Assert.IsType<Conversation>(store.LoadAll("c"));
            Assert.Equal(conversation.ModelContext.Select(m => m.Content), reloaded.ModelContext.Select(m => m.Content));
            Assert.Equal(conversation.Messages.Select(m => m.Text), reloaded.Messages.Select(m => m.Text));

            // Clean bubbles are skipped on save; one changed after its write still lands.
            conversation.Messages[1].Feedback = "good";
            Assert.True(store.Save([conversation]));
            Assert.Equal("good", Assert.IsType<Conversation>(store.LoadAll("c")).Messages[1].Feedback);
            conversation.Messages[1].Feedback = null;
            Assert.True(store.Save([conversation]));
            Assert.Null(Assert.IsType<Conversation>(store.LoadAll("c")).Messages[1].Feedback);

            // Compaction replaces the prefix: the stored context must follow it exactly.
            reloaded.ModelContext = [new NativeMessage("user", "summary"), new NativeMessage("assistant", "after")];
            reloaded.Messages.RemoveAt(0);
            Assert.True(store.Save([reloaded]));
            var compacted = Assert.IsType<Conversation>(new ConversationSqliteStore(root, Path.Combine(root, "sessions.json")).LoadAll("c"));
            Assert.Equal(["summary", "after"], compacted.ModelContext.Select(m => m.Content));
            Assert.Equal(5, compacted.Messages.Count);
            Assert.Equal("final 1", compacted.Messages[0].Text);

            // A header-only save of changed metadata still lands; an unchanged one is skipped.
            var headers = store.LoadHeaders();
            var stored = headers.Single(item => item.Id == "h");
            stored.Pinned = true;
            Assert.True(store.Save(headers));
            Assert.True(new ConversationSqliteStore(root, Path.Combine(root, "sessions.json")).LoadHeaders().Single(item => item.Id == "h").Pinned);
        }
        finally
        {
            Microsoft.Data.Sqlite.SqliteConnection.ClearAllPools();
            try { Directory.Delete(root, recursive: true); } catch { }
        }
    }
}

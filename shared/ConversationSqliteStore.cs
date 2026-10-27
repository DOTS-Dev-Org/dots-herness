using System.Collections.ObjectModel;
using System.Runtime.CompilerServices;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.Json.Serialization.Metadata;
using Microsoft.Data.Sqlite;

namespace DotsHarnessCore;

/// <summary>
/// Durable conversation storage shared by the Windows and Linux desktop apps.
/// Transcript messages are rows so opening a conversation can fetch only its
/// newest page instead of deserializing the whole session archive.
/// </summary>
public sealed class ConversationSqliteStore
{
    public const int InitialTranscriptPageSize = 10;

    private readonly string _databasePath;
    private readonly string _legacyJsonPath;
    private readonly object _gate = new();
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNameCaseInsensitive = true,
    };
    private static readonly JsonSerializerOptions StateJson = CreateStateJson();
    private static readonly JsonSerializerOptions HeaderJson = CreateHeaderJson();
    // What this store last read or wrote per conversation, so an unchanged header
    // or provider-context prefix is not rewritten on every agent step.
    private readonly Dictionary<string, string> _savedMetadata = new(StringComparer.Ordinal);
    private readonly Dictionary<string, NativeMessage[]> _savedContext = new(StringComparer.Ordinal);
    // Per bubble, the version this store last wrote. Each agent step saved every loaded
    // bubble by re-reading and re-serializing it, O(transcript) per step and O(n²) per run.
    private readonly ConditionalWeakTable<ChatMessage, SavedMark> _savedMarks = new();
    private bool _legacyImported;

    public ConversationSqliteStore(string root, string legacyJsonPath)
    {
        Directory.CreateDirectory(root);
        _databasePath = Path.Combine(root, "sessions.sqlite");
        _legacyJsonPath = legacyJsonPath;
        using var connection = Open();
        Initialize(connection);
    }

    public string DatabasePath => _databasePath;

    /// <summary>
    /// Imports the previous JSON archive once, streaming one conversation at a
    /// time. The import marker and conversation rows commit together.
    /// </summary>
    public async Task<bool> EnsureLegacyImportedAsync(CancellationToken cancellationToken = default)
    {
        lock (_gate)
        {
            if (_legacyImported) return true;
            using var connection = Open();
            if (ReadMetadata(connection, "legacy_json_imported") == "1") return _legacyImported = true;
            if (!File.Exists(_legacyJsonPath))
            {
                using var transaction = connection.BeginTransaction();
                WriteMetadata(connection, transaction, "legacy_json_imported", "1");
                transaction.Commit();
                return _legacyImported = true;
            }
        }

        try
        {
            await using var stream = new FileStream(
                _legacyJsonPath,
                FileMode.Open,
                FileAccess.Read,
                FileShare.Read,
                bufferSize: 64 * 1024,
                FileOptions.Asynchronous | FileOptions.SequentialScan);

            lock (_gate)
            {
                using var connection = Open();
                if (ReadMetadata(connection, "legacy_json_imported") == "1") return true;
                using var transaction = connection.BeginTransaction();
                var insertConversation = connection.CreateCommand();
                insertConversation.Transaction = transaction;
                ConfigureConversationUpsert(insertConversation);
                var insertMessage = connection.CreateCommand();
                insertMessage.Transaction = transaction;
                ConfigureMessageInsert(insertMessage);

                // DeserializeAsyncEnumerable uses Utf8JsonReader incrementally,
                // keeping migration memory bounded to one conversation at a time.
                var pendingImport = ImportAsyncEnumerable(
                    stream, connection, transaction, insertConversation, insertMessage, cancellationToken);
                pendingImport.GetAwaiter().GetResult();
                WriteMetadata(connection, transaction, "legacy_json_imported", "1");
                transaction.Commit();
                return true;
            }
        }
        catch (JsonException)
        {
            // Keep malformed legacy data recoverable while allowing the new
            // SQLite store to accept conversations normally.
            return CompleteImportWithCorruptArchivePreserved();
        }
        catch
        {
            // Keep the source archive intact and keep the marker unset. The next
            // startup may retry after the disk or source file is repaired.
            return false;
        }
    }

    private bool CompleteImportWithCorruptArchivePreserved()
    {
        try
        {
            if (File.Exists(_legacyJsonPath))
            {
                var corruptPath = _legacyJsonPath + ".corrupt";
                if (!File.Exists(corruptPath)) File.Copy(_legacyJsonPath, corruptPath);
            }
            lock (_gate)
            {
                using var connection = Open();
                using var transaction = connection.BeginTransaction();
                WriteMetadata(connection, transaction, "legacy_json_imported", "1");
                transaction.Commit();
            }
            return true;
        }
        catch
        {
            return false;
        }
    }

    public IReadOnlyList<Conversation> LoadHeaders(string? workspacePath = null)
    {
        lock (_gate)
        {
            using var connection = Open();
            using var command = connection.CreateCommand();
            command.CommandText = workspacePath is null
                ? "SELECT state_json, last_activity, message_count FROM conversations ORDER BY last_activity DESC, id"
                : "SELECT state_json, last_activity, message_count FROM conversations WHERE workspace_path = $workspace ORDER BY last_activity DESC, id";
            if (workspacePath is not null) command.Parameters.AddWithValue("$workspace", workspacePath);
            using var reader = command.ExecuteReader();
            var headers = new List<Conversation>();
            while (reader.Read())
            {
                var header = JsonSerializer.Deserialize<Conversation>(reader.GetString(0), HeaderJson);
                if (header is null) continue;
                header.Messages = new ObservableCollection<ChatMessage>();
                header.ModelContext = [];
                header.CacheSession = null;
                header.PendingPrompts = new ObservableCollection<PendingPrompt>();
                header.Running = false;
                header.LastActivityAt = ReadTimestamp(reader.GetInt64(1));
                header.StoredMessageCount = reader.GetInt32(2);
                header.MessageStartIndex = 0;
                header.TranscriptComplete = false;
                header.TranscriptLoaded = false;
                header.LoadedMessageIds.Clear();
                _savedMetadata[header.Id] = MetadataKey(header);
                headers.Add(header);
            }
            return headers;
        }
    }

    public Conversation? Load(string id, int messageLimit = InitialTranscriptPageSize, bool includeModelContext = true)
    {
        lock (_gate)
        {
            using var connection = Open();
            var conversation = ReadConversation(connection, id, includeAllMessages: false, messageLimit, includeModelContext);
            return conversation;
        }
    }

    public Conversation? LoadAll(string id)
    {
        lock (_gate)
        {
            using var connection = Open();
            return ReadConversation(connection, id, includeAllMessages: true, int.MaxValue, includeModelContext: true);
        }
    }

    public IReadOnlyList<Conversation> LoadAll()
    {
        var ids = LoadHeaders().Select(header => header.Id).ToArray();
        var all = new List<Conversation>(ids.Length);
        foreach (var id in ids)
            if (LoadAll(id) is { } conversation) all.Add(conversation);
        return all;
    }

    public ConversationMessagePage? LoadMessagePage(string id, int endingBefore, int limit = InitialTranscriptPageSize)
    {
        if (limit <= 0) return null;
        lock (_gate)
        {
            using var connection = Open();
            var totalCount = ReadMessageCount(connection, id);
            var rows = ReadPageRows(connection, id, endingBefore, limit);
            return new ConversationMessagePage(
                rows.Select(row => row.message).ToArray(),
                rows.Count == 0 ? 0 : rows[0].ordinal,
                totalCount);
        }
    }

    public bool Save(IEnumerable<Conversation> conversations)
    {
        lock (_gate)
        {
            try
            {
                using var connection = Open();
                using var transaction = connection.BeginTransaction();
                using var stateCommand = connection.CreateCommand();
                stateCommand.Transaction = transaction;
                ConfigureConversationUpsert(stateCommand);
                using var messageCommand = connection.CreateCommand();
                messageCommand.Transaction = transaction;
                ConfigureMessageInsert(messageCommand);

                var committed = new List<Action>();
                foreach (var conversation in conversations)
                {
                    if (!conversation.TranscriptLoaded)
                    {
                        // The app passes every sidebar header on each save; only
                        // a header whose metadata changed costs a row write.
                        var key = MetadataKey(conversation);
                        if (_savedMetadata.TryGetValue(conversation.Id, out var saved) && saved == key) continue;
                        UpdateMetadata(connection, transaction, conversation);
                        committed.Add(() => _savedMetadata[conversation.Id] = key);
                        continue;
                    }
                    SaveConversation(connection, transaction, conversation, stateCommand, messageCommand, committed);
                }
                transaction.Commit();
                foreach (var apply in committed) apply();
                return true;
            }
            catch
            {
                return false;
            }
        }
    }

    public bool Delete(string id)
    {
        lock (_gate)
        {
            try
            {
                using var connection = Open();
                using var command = connection.CreateCommand();
                command.CommandText = "DELETE FROM conversations WHERE id = $id";
                command.Parameters.AddWithValue("$id", id);
                _savedMetadata.Remove(id);
                _savedContext.Remove(id);
                return command.ExecuteNonQuery() > 0;
            }
            catch { return false; }
        }
    }

    public bool RelocateWorkspace(string oldPath, string newPath)
    {
        lock (_gate)
        {
            _savedMetadata.Clear();
            try
            {
                using var connection = Open();
                using var command = connection.CreateCommand();
                command.CommandText = "UPDATE conversations SET workspace_path = $newPath, state_json = json_set(state_json, '$.Cwd', $newPath) WHERE workspace_path = $oldPath";
                command.Parameters.AddWithValue("$newPath", newPath);
                command.Parameters.AddWithValue("$oldPath", oldPath);
                command.ExecuteNonQuery();
                return true;
            }
            catch
            {
                // Keep compatibility with SQLite builds that omit JSON1.
                try
                {
                    using var connection = Open();
                    using var transaction = connection.BeginTransaction();
                    using var read = connection.CreateCommand();
                    read.Transaction = transaction;
                    read.CommandText = "SELECT id, state_json FROM conversations WHERE workspace_path = $oldPath";
                    read.Parameters.AddWithValue("$oldPath", oldPath);
                    var rows = new List<(string id, string json)>();
                    using (var reader = read.ExecuteReader())
                        while (reader.Read()) rows.Add((reader.GetString(0), reader.GetString(1)));
                    foreach (var row in rows)
                    {
                        var conversation = JsonSerializer.Deserialize<Conversation>(row.json, JsonOptions);
                        if (conversation is null) continue;
                        conversation.Cwd = newPath;
                        using var update = connection.CreateCommand();
                        update.Transaction = transaction;
                        update.CommandText = "UPDATE conversations SET workspace_path = $newPath, state_json = $state WHERE id = $id";
                        update.Parameters.AddWithValue("$newPath", newPath);
                        update.Parameters.AddWithValue("$state", SerializeState(conversation));
                        update.Parameters.AddWithValue("$id", row.id);
                        update.ExecuteNonQuery();
                    }
                    transaction.Commit();
                    return true;
                }
                catch { return false; }
            }
        }
    }

    public int FileSize
    {
        get
        {
            try
            {
                var bytes = new FileInfo(_databasePath).Length;
                foreach (var suffix in new[] { "-wal", "-shm" })
                {
                    var sidecar = _databasePath + suffix;
                    if (File.Exists(sidecar)) bytes += new FileInfo(sidecar).Length;
                }
                return checked((int)Math.Min(bytes, int.MaxValue));
            }
            catch { return 0; }
        }
    }

    private async Task ImportAsyncEnumerable(
        Stream stream,
        SqliteConnection connection,
        SqliteTransaction transaction,
        SqliteCommand conversationCommand,
        SqliteCommand messageCommand,
        CancellationToken cancellationToken)
    {
        await foreach (var conversation in JsonSerializer.DeserializeAsyncEnumerable<Conversation>(stream, JsonOptions, cancellationToken).ConfigureAwait(false))
        {
            if (conversation is null) continue;
            SaveConversation(connection, transaction, conversation, conversationCommand, messageCommand);
        }
    }

    private void SaveConversation(
        SqliteConnection connection,
        SqliteTransaction transaction,
        Conversation conversation,
        SqliteCommand stateCommand,
        SqliteCommand messageCommand,
        List<Action>? committed = null)
    {
        SaveConversationRows(conversation, stateCommand, messageCommand);
        var context = conversation.ModelContext.ToArray();
        SaveContext(connection, transaction, conversation.Id, context);
        var metadata = MetadataKey(conversation);
        committed?.Add(() =>
        {
            _savedContext[conversation.Id] = context;
            _savedMetadata[conversation.Id] = metadata;
        });
        // A complete transcript merges like a page from ordinal 0: unchanged rows
        // stay as they are instead of being deleted and reinserted on each save.
        if (conversation.TranscriptComplete) conversation.MessageStartIndex = 0;
        MergeLoadedMessages(connection, transaction, conversation, messageCommand, committed);
        using var countCommand = connection.CreateCommand();
        countCommand.Transaction = transaction;
        countCommand.CommandText = "SELECT COUNT(*) FROM conversation_messages WHERE conversation_id = $id";
        countCommand.Parameters.AddWithValue("$id", conversation.Id);
        conversation.StoredMessageCount = Convert.ToInt32(countCommand.ExecuteScalar() ?? 0);
        conversation.LastActivityAt = SessionProjector.LastActivity(conversation);
        using var updateCount = connection.CreateCommand();
        updateCount.Transaction = transaction;
        updateCount.CommandText = "UPDATE conversations SET message_count = $count, last_activity = $activity WHERE id = $id";
        updateCount.Parameters.AddWithValue("$count", conversation.StoredMessageCount);
        updateCount.Parameters.AddWithValue("$activity", Timestamp(conversation.LastActivityAt));
        updateCount.Parameters.AddWithValue("$id", conversation.Id);
        updateCount.ExecuteNonQuery();
    }

    private static void SaveConversationRows(
        Conversation conversation,
        SqliteCommand stateCommand,
        SqliteCommand messageCommand)
    {
        conversation.LastActivityAt = SessionProjector.LastActivity(conversation);
        stateCommand.Parameters.Clear();
        stateCommand.Parameters.AddWithValue("$id", conversation.Id);
        stateCommand.Parameters.AddWithValue("$workspace", (object?)conversation.Cwd ?? DBNull.Value);
        stateCommand.Parameters.AddWithValue("$projectless", conversation.Projectless ? 1 : 0);
        stateCommand.Parameters.AddWithValue("$title", conversation.Title ?? "New conversation");
        stateCommand.Parameters.AddWithValue("$lastActivity", Timestamp(conversation.LastActivityAt));
        stateCommand.Parameters.AddWithValue("$archived", conversation.Archived ? 1 : 0);
        stateCommand.Parameters.AddWithValue("$pinned", conversation.Pinned ? 1 : 0);
        stateCommand.Parameters.AddWithValue("$blank", conversation.Blank ? 1 : 0);
        stateCommand.Parameters.AddWithValue("$running", conversation.Running ? 1 : 0);
        stateCommand.Parameters.AddWithValue("$state", SerializeState(conversation));
        // Provider context lives in conversation_context rows; this column only
        // holds context written before that table existed.
        stateCommand.Parameters.AddWithValue("$context", "[]");
        stateCommand.Parameters.AddWithValue("$cache", (object?)JsonSerializer.Serialize(conversation.CacheSession, JsonOptions) ?? DBNull.Value);
        stateCommand.Parameters.AddWithValue("$count", conversation.StoredMessageCount);
        stateCommand.ExecuteNonQuery();
        messageCommand.Transaction = stateCommand.Transaction;
    }

    /// Appends only the entries after the prefix this store already holds. Context
    /// entries are immutable records, so a reference-equal prefix is unchanged;
    /// compaction replaces them and falls back to a full rewrite.
    private void SaveContext(SqliteConnection connection, SqliteTransaction transaction, string id, NativeMessage[] context)
    {
        var start = 0;
        if (_savedContext.TryGetValue(id, out var saved) && saved.Length <= context.Length
            && saved.Select((entry, index) => ReferenceEquals(entry, context[index])).All(same => same))
        {
            start = saved.Length;
        }
        else
        {
            using var delete = connection.CreateCommand();
            delete.Transaction = transaction;
            delete.CommandText = "DELETE FROM conversation_context WHERE conversation_id = $id";
            delete.Parameters.AddWithValue("$id", id);
            delete.ExecuteNonQuery();
        }
        if (start == context.Length) return;
        using var insert = connection.CreateCommand();
        insert.Transaction = transaction;
        insert.CommandText = "INSERT OR REPLACE INTO conversation_context(conversation_id, ordinal, payload_json) VALUES($id, $ordinal, $payload)";
        var ordinal = insert.Parameters.Add("$ordinal", SqliteType.Integer);
        var payload = insert.Parameters.Add("$payload", SqliteType.Text);
        insert.Parameters.AddWithValue("$id", id);
        for (var index = start; index < context.Length; index++)
        {
            ordinal.Value = index;
            payload.Value = JsonSerializer.Serialize(context[index], JsonOptions);
            insert.ExecuteNonQuery();
        }
    }

    private static string MetadataKey(Conversation conversation) => string.Join('\n',
        conversation.Title, conversation.Cwd, conversation.Projectless, conversation.Pinned,
        conversation.Archived, conversation.AgentPreset, conversation.Blank);

    private void UpdateMetadata(SqliteConnection connection, SqliteTransaction transaction, Conversation header)
    {
        using var read = connection.CreateCommand();
        read.Transaction = transaction;
        read.CommandText = "SELECT state_json FROM conversations WHERE id = $id";
        read.Parameters.AddWithValue("$id", header.Id);
        var json = read.ExecuteScalar() as string;
        if (json is null) return;
        var stored = JsonSerializer.Deserialize<Conversation>(json, JsonOptions);
        if (stored is null) return;
        stored.Title = header.Title;
        stored.Cwd = header.Cwd;
        stored.Projectless = header.Projectless;
        stored.Pinned = header.Pinned;
        stored.Archived = header.Archived;
        stored.AgentPreset = header.AgentPreset;
        stored.Blank = header.Blank;
        using var update = connection.CreateCommand();
        update.Transaction = transaction;
        update.CommandText = "UPDATE conversations SET workspace_path = $workspace, projectless = $projectless, title = $title, archived = $archived, pinned = $pinned, blank = $blank, state_json = $state WHERE id = $id";
        update.Parameters.AddWithValue("$workspace", (object?)stored.Cwd ?? DBNull.Value);
        update.Parameters.AddWithValue("$projectless", stored.Projectless ? 1 : 0);
        update.Parameters.AddWithValue("$title", stored.Title);
        update.Parameters.AddWithValue("$archived", stored.Archived ? 1 : 0);
        update.Parameters.AddWithValue("$pinned", stored.Pinned ? 1 : 0);
        update.Parameters.AddWithValue("$blank", stored.Blank ? 1 : 0);
        update.Parameters.AddWithValue("$state", SerializeState(stored));
        update.Parameters.AddWithValue("$id", stored.Id);
        update.ExecuteNonQuery();
    }

    /// <summary>Bumped by every property change; a bubble is clean while it equals SavedVersion.</summary>
    private sealed class SavedMark
    {
        public int Version;
        public int SavedVersion = -1;
        public string? ConversationId;
    }

    private SavedMark Mark(ChatMessage message) => _savedMarks.GetValue(message, item =>
    {
        var mark = new SavedMark();
        item.PropertyChanged += (_, _) => Interlocked.Increment(ref mark.Version);
        return mark;
    });

    private bool IsSaved(ChatMessage message, string conversationId) =>
        _savedMarks.TryGetValue(message, out var mark)
        && mark.ConversationId == conversationId
        && mark.SavedVersion == Volatile.Read(ref mark.Version);

    /// Marks after commit only, with the version read before serializing: a change
    /// racing the write leaves the bubble dirty, a rolled-back write leaves it unsaved.
    private void MarkSavedOnCommit(List<Action>? committed, ChatMessage message, string conversationId)
    {
        if (committed is null) return;
        var mark = Mark(message);
        var version = Volatile.Read(ref mark.Version);
        committed.Add(() =>
        {
            mark.ConversationId = conversationId;
            mark.SavedVersion = version;
        });
    }

    private void MergeLoadedMessages(
        SqliteConnection connection,
        SqliteTransaction transaction,
        Conversation conversation,
        SqliteCommand insert,
        List<Action>? committed = null)
    {
        var lowerBound = Math.Max(0, conversation.MessageStartIndex);
        using var existingCommand = connection.CreateCommand();
        existingCommand.Transaction = transaction;
        existingCommand.CommandText = "SELECT ordinal, message_id, payload_json FROM conversation_messages WHERE conversation_id = $id AND ordinal >= $start ORDER BY ordinal";
        existingCommand.Parameters.AddWithValue("$id", conversation.Id);
        existingCommand.Parameters.AddWithValue("$start", lowerBound);
        var current = conversation.Messages.ToDictionary(message => message.Id, StringComparer.Ordinal);
        var existing = new List<(int ordinal, string id, string? payload)>();
        using (var reader = existingCommand.ExecuteReader())
            while (reader.Read())
            {
                var rowId = reader.GetString(1);
                // A bubble unchanged since this store wrote it is skipped, so its payload is never read.
                var payload = current.TryGetValue(rowId, out var loaded) && IsSaved(loaded, conversation.Id) ? null : reader.GetString(2);
                existing.Add((reader.GetInt32(0), rowId, payload));
            }

        var existingIds = existing.Select(item => item.id).ToHashSet(StringComparer.Ordinal);
        var deleted = false;
        foreach (var item in existing)
        {
            if (!current.ContainsKey(item.id))
            {
                using var delete = connection.CreateCommand();
                delete.Transaction = transaction;
                delete.CommandText = "DELETE FROM conversation_messages WHERE conversation_id = $conversation AND ordinal = $ordinal";
                delete.Parameters.AddWithValue("$conversation", conversation.Id);
                delete.Parameters.AddWithValue("$ordinal", item.ordinal);
                deleted |= delete.ExecuteNonQuery() > 0;
                continue;
            }
            if (item.payload is null) continue;
            // Only a bubble whose content changed (usually the streaming one) is rewritten.
            MarkSavedOnCommit(committed, current[item.id], conversation.Id);
            var payload = JsonSerializer.Serialize(current[item.id], JsonOptions);
            if (payload != item.payload) UpdateMessage(connection, transaction, conversation.Id, item.ordinal, current[item.id], payload);
        }
        if (deleted) ReindexMessages(connection, transaction, conversation.Id);

        using var maxCommand = connection.CreateCommand();
        maxCommand.Transaction = transaction;
        maxCommand.CommandText = "SELECT COALESCE(MAX(ordinal), -1) FROM conversation_messages WHERE conversation_id = $id";
        maxCommand.Parameters.AddWithValue("$id", conversation.Id);
        var nextOrdinal = Convert.ToInt32(maxCommand.ExecuteScalar() ?? -1) + 1;
        foreach (var message in conversation.Messages)
        {
            if (existingIds.Contains(message.Id)) continue;
            MarkSavedOnCommit(committed, message, conversation.Id);
            var found = FindMessageOrdinal(connection, transaction, conversation.Id, message.Id);
            if (found is { } ordinal)
                UpdateMessage(connection, transaction, conversation.Id, ordinal, message, JsonSerializer.Serialize(message, JsonOptions));
            else
                InsertMessage(insert, conversation.Id, nextOrdinal++, message);
        }
        conversation.LoadedMessageIds = conversation.Messages.Select(message => message.Id).ToHashSet(StringComparer.Ordinal);
    }

    private Conversation? ReadConversation(SqliteConnection connection, string id, bool includeAllMessages, int messageLimit, bool includeModelContext)
    {
        using var command = connection.CreateCommand();
        command.CommandText = "SELECT state_json, model_context_json, cache_session_json, last_activity, message_count FROM conversations WHERE id = $id";
        command.Parameters.AddWithValue("$id", id);
        using var reader = command.ExecuteReader();
        if (!reader.Read()) return null;
        var conversation = JsonSerializer.Deserialize<Conversation>(reader.GetString(0), JsonOptions);
        if (conversation is null) return null;
        conversation.Messages = new ObservableCollection<ChatMessage>();
        var legacyContext = reader.GetString(1);
        conversation.CacheSession = reader.IsDBNull(2)
            ? null
            : JsonSerializer.Deserialize<NativeCacheSession>(reader.GetString(2), JsonOptions);
        conversation.LastActivityAt = ReadTimestamp(reader.GetInt64(3));
        conversation.StoredMessageCount = reader.GetInt32(4);
        conversation.Running = false;
        reader.Close();
        _savedMetadata[id] = MetadataKey(conversation);
        conversation.ModelContext = [];
        if (includeModelContext)
        {
            using var contextCommand = connection.CreateCommand();
            contextCommand.CommandText = "SELECT payload_json FROM conversation_context WHERE conversation_id = $id ORDER BY ordinal";
            contextCommand.Parameters.AddWithValue("$id", id);
            using (var contextReader = contextCommand.ExecuteReader())
                while (contextReader.Read())
                    conversation.ModelContext.Add(JsonSerializer.Deserialize<NativeMessage>(contextReader.GetString(0), JsonOptions)!);
            // Rows mirror what is stored, so the next save may append to them. A
            // context read from the legacy column has no rows yet: leave it
            // uncached so that save writes every entry.
            if (conversation.ModelContext.Count > 0)
                _savedContext[id] = conversation.ModelContext.ToArray();
            else
                conversation.ModelContext = JsonSerializer.Deserialize<List<NativeMessage>>(legacyContext, JsonOptions) ?? [];
        }

        List<(int ordinal, ChatMessage message)> rows;
        if (includeAllMessages)
        {
            using var messages = connection.CreateCommand();
            messages.CommandText = "SELECT ordinal, payload_json FROM conversation_messages WHERE conversation_id = $id ORDER BY ordinal";
            messages.Parameters.AddWithValue("$id", id);
            using var messageReader = messages.ExecuteReader();
            rows = [];
            while (messageReader.Read())
            {
                if (JsonSerializer.Deserialize<ChatMessage>(messageReader.GetString(1), JsonOptions) is { } message)
                    rows.Add((messageReader.GetInt32(0), message));
            }
        }
        else
        {
            rows = ReadPageRows(connection, id, int.MaxValue, messageLimit);
        }
        conversation.Messages = new ObservableCollection<ChatMessage>(rows.Select(row => row.message));
        conversation.MessageStartIndex = rows.Count == 0 ? 0 : rows[0].ordinal;
        conversation.TranscriptComplete = conversation.MessageStartIndex == 0;
        conversation.TranscriptLoaded = true;
        conversation.LoadedMessageIds = rows.Select(row => row.message.Id).ToHashSet(StringComparer.Ordinal);
        return conversation;
    }

    /// <summary>Newest rows before <paramref name="endingBefore"/>, oldest first. The limit counts
    /// conversational messages only: tool steps and notices ride along, otherwise a tool-heavy
    /// turn fills the page and hides the user/assistant messages.</summary>
    private static List<(int ordinal, ChatMessage message)> ReadPageRows(SqliteConnection connection, string id, int endingBefore, int limit)
    {
        using var command = connection.CreateCommand();
        // ponytail: hard row cap so a run of thousands of tool steps can't stall the read.
        command.CommandText = "SELECT ordinal, payload_json FROM conversation_messages WHERE conversation_id = $id AND ordinal < $offset ORDER BY ordinal DESC LIMIT 2000";
        command.Parameters.AddWithValue("$id", id);
        command.Parameters.AddWithValue("$offset", Math.Max(0, endingBefore));
        using var reader = command.ExecuteReader();
        var wanted = Math.Max(1, limit);
        var counted = 0;
        var rows = new List<(int ordinal, ChatMessage message)>();
        while (counted < wanted && reader.Read())
        {
            if (JsonSerializer.Deserialize<ChatMessage>(reader.GetString(1), JsonOptions) is not { } message) continue;
            rows.Add((reader.GetInt32(0), message));
            if (message.Kind is not (ChatKind.Tool or ChatKind.System)) counted++;
        }
        rows.Reverse();
        return rows;
    }

    private static int ReadMessageCount(SqliteConnection connection, string id)
    {
        using var command = connection.CreateCommand();
        command.CommandText = "SELECT message_count FROM conversations WHERE id = $id";
        command.Parameters.AddWithValue("$id", id);
        var value = command.ExecuteScalar();
        return value is null or DBNull ? 0 : Convert.ToInt32(value);
    }

    private static int? FindMessageOrdinal(SqliteConnection connection, SqliteTransaction transaction, string conversationId, string messageId)
    {
        using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText = "SELECT ordinal FROM conversation_messages WHERE conversation_id = $conversation AND message_id = $message LIMIT 1";
        command.Parameters.AddWithValue("$conversation", conversationId);
        command.Parameters.AddWithValue("$message", messageId);
        var value = command.ExecuteScalar();
        return value is null or DBNull ? null : Convert.ToInt32(value);
    }

    private static void InsertMessage(SqliteCommand command, string conversationId, int ordinal, ChatMessage message)
    {
        command.Parameters.Clear();
        command.Parameters.AddWithValue("$conversation", conversationId);
        command.Parameters.AddWithValue("$ordinal", ordinal);
        command.Parameters.AddWithValue("$message", message.Id);
        command.Parameters.AddWithValue("$created", Timestamp(message.CreatedAt));
        command.Parameters.AddWithValue("$payload", JsonSerializer.Serialize(message, JsonOptions));
        command.ExecuteNonQuery();
    }

    private static void UpdateMessage(SqliteConnection connection, SqliteTransaction transaction, string conversationId, int ordinal, ChatMessage message, string payload)
    {
        using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText = "UPDATE conversation_messages SET message_id = $message, created_at = $created, payload_json = $payload WHERE conversation_id = $conversation AND ordinal = $ordinal";
        command.Parameters.AddWithValue("$message", message.Id);
        command.Parameters.AddWithValue("$created", Timestamp(message.CreatedAt));
        command.Parameters.AddWithValue("$payload", payload);
        command.Parameters.AddWithValue("$conversation", conversationId);
        command.Parameters.AddWithValue("$ordinal", ordinal);
        command.ExecuteNonQuery();
    }

    private static void ReindexMessages(SqliteConnection connection, SqliteTransaction transaction, string conversationId)
    {
        using var shift = connection.CreateCommand();
        shift.Transaction = transaction;
        shift.CommandText = "UPDATE conversation_messages SET ordinal = -ordinal - 1 WHERE conversation_id = $id";
        shift.Parameters.AddWithValue("$id", conversationId);
        shift.ExecuteNonQuery();
        using var read = connection.CreateCommand();
        read.Transaction = transaction;
        read.CommandText = "SELECT ordinal FROM conversation_messages WHERE conversation_id = $id ORDER BY ordinal DESC";
        read.Parameters.AddWithValue("$id", conversationId);
        var oldOrdinals = new List<int>();
        using (var reader = read.ExecuteReader()) while (reader.Read()) oldOrdinals.Add(reader.GetInt32(0));
        for (var index = 0; index < oldOrdinals.Count; index++)
        {
            using var update = connection.CreateCommand();
            update.Transaction = transaction;
            update.CommandText = "UPDATE conversation_messages SET ordinal = $new WHERE conversation_id = $id AND ordinal = $old";
            update.Parameters.AddWithValue("$new", index);
            update.Parameters.AddWithValue("$id", conversationId);
            update.Parameters.AddWithValue("$old", oldOrdinals[index]);
            update.ExecuteNonQuery();
        }
    }

    private static string SerializeState(Conversation conversation)
    {
        return JsonSerializer.Serialize(conversation, StateJson);
    }

    private SqliteConnection Open()
    {
        var connection = new SqliteConnection(new SqliteConnectionStringBuilder
        {
            DataSource = _databasePath,
            Mode = SqliteOpenMode.ReadWriteCreate,
            DefaultTimeout = 5,
        }.ToString());
        connection.Open();
        using var pragma = connection.CreateCommand();
        pragma.CommandText = "PRAGMA foreign_keys = ON; PRAGMA busy_timeout = 5000;";
        pragma.ExecuteNonQuery();
        return connection;
    }

    private static void Initialize(SqliteConnection connection)
    {
        using var command = connection.CreateCommand();
        command.CommandText = """
            PRAGMA journal_mode = WAL;
            CREATE TABLE IF NOT EXISTS store_metadata(key TEXT PRIMARY KEY, value TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS conversations(
                id TEXT PRIMARY KEY,
                workspace_path TEXT,
                projectless INTEGER NOT NULL,
                title TEXT NOT NULL,
                last_activity INTEGER NOT NULL,
                archived INTEGER NOT NULL,
                pinned INTEGER NOT NULL,
                blank INTEGER NOT NULL,
                running INTEGER NOT NULL,
                state_json TEXT NOT NULL,
                model_context_json TEXT NOT NULL,
                cache_session_json TEXT,
                message_count INTEGER NOT NULL DEFAULT 0
            );
            CREATE TABLE IF NOT EXISTS conversation_messages(
                conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
                ordinal INTEGER NOT NULL,
                message_id TEXT NOT NULL,
                created_at INTEGER NOT NULL,
                payload_json TEXT NOT NULL,
                PRIMARY KEY(conversation_id, ordinal)
            );
            CREATE TABLE IF NOT EXISTS conversation_context(
                conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
                ordinal INTEGER NOT NULL,
                payload_json TEXT NOT NULL,
                PRIMARY KEY(conversation_id, ordinal)
            );
            CREATE INDEX IF NOT EXISTS idx_conversations_workspace_activity ON conversations(workspace_path, last_activity DESC);
            CREATE INDEX IF NOT EXISTS idx_conversations_archive_activity ON conversations(archived, last_activity DESC);
            CREATE INDEX IF NOT EXISTS idx_messages_id ON conversation_messages(conversation_id, message_id);
            """;
        command.ExecuteNonQuery();
        if (ReadMetadata(connection, "schema_version") is null)
        {
            using var transaction = connection.BeginTransaction();
            WriteMetadata(connection, transaction, "schema_version", "1");
            transaction.Commit();
        }
    }

    private static void ConfigureConversationUpsert(SqliteCommand command)
    {
        command.CommandText = """
            INSERT INTO conversations(id, workspace_path, projectless, title, last_activity, archived, pinned, blank, running, state_json, model_context_json, cache_session_json, message_count)
            VALUES($id, $workspace, $projectless, $title, $lastActivity, $archived, $pinned, $blank, $running, $state, $context, $cache, $count)
            ON CONFLICT(id) DO UPDATE SET workspace_path=excluded.workspace_path, projectless=excluded.projectless, title=excluded.title,
                last_activity=excluded.last_activity, archived=excluded.archived, pinned=excluded.pinned, blank=excluded.blank,
                running=excluded.running, state_json=excluded.state_json, model_context_json=excluded.model_context_json,
                cache_session_json=excluded.cache_session_json
            """;
    }

    private static void ConfigureMessageInsert(SqliteCommand command)
    {
        command.CommandText = "INSERT INTO conversation_messages(conversation_id, ordinal, message_id, created_at, payload_json) VALUES($conversation, $ordinal, $message, $created, $payload)";
    }

    private static void WriteMetadata(SqliteConnection connection, SqliteTransaction transaction, string key, string value)
    {
        using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText = "INSERT INTO store_metadata(key, value) VALUES($key, $value) ON CONFLICT(key) DO UPDATE SET value=excluded.value";
        command.Parameters.AddWithValue("$key", key);
        command.Parameters.AddWithValue("$value", value);
        command.ExecuteNonQuery();
    }

    private static string? ReadMetadata(SqliteConnection connection, string key)
    {
        using var command = connection.CreateCommand();
        command.CommandText = "SELECT value FROM store_metadata WHERE key = $key";
        command.Parameters.AddWithValue("$key", key);
        return command.ExecuteScalar() as string;
    }

    private static long Timestamp(DateTimeOffset value) => value.ToUnixTimeMilliseconds();
    private static DateTimeOffset ReadTimestamp(long value) => DateTimeOffset.FromUnixTimeMilliseconds(value);

    private static JsonSerializerOptions CreateHeaderJson()
    {
        var options = new JsonSerializerOptions { PropertyNameCaseInsensitive = true };
        options.TypeInfoResolver = new DefaultJsonTypeInfoResolver
        {
            Modifiers =
            {
                info =>
                {
                    if (info.Type != typeof(Conversation)) return;
                    for (var index = info.Properties.Count - 1; index >= 0; index--)
                    {
                        if (info.Properties[index].Name is nameof(Conversation.Messages)
                            or nameof(Conversation.ModelContext)
                            or nameof(Conversation.CacheSession)
                            or nameof(Conversation.PendingPrompts))
                            info.Properties.RemoveAt(index);
                    }
                },
            },
        };
        return options;
    }

    private static JsonSerializerOptions CreateStateJson()
    {
        var options = new JsonSerializerOptions { PropertyNameCaseInsensitive = true };
        options.TypeInfoResolver = new DefaultJsonTypeInfoResolver
        {
            Modifiers =
            {
                info =>
                {
                    if (info.Type != typeof(Conversation)) return;
                    for (var index = info.Properties.Count - 1; index >= 0; index--)
                    {
                        if (info.Properties[index].Name is nameof(Conversation.Messages)
                            or nameof(Conversation.ModelContext)
                            or nameof(Conversation.CacheSession))
                            info.Properties.RemoveAt(index);
                    }
                }
            }
        };
        return options;
    }
}

public sealed record ConversationMessagePage(IReadOnlyList<ChatMessage> Messages, int StartIndex, int TotalCount);

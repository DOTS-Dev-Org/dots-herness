// Copyright (c) 2026 DOTS
// Conversation rewind and edit-last-message, backed by per-turn workspace snapshots.
// Mirrors the macOS AgentBridge rewind flow: rewinding drops a user message and everything after it
// and puts the files those turns changed back; editing the latest message does the same for one turn
// (refusing on conflict) and then re-sends the edited text.

namespace DotsHarnessCore;

public enum ConversationMutationKind
{
    Busy,
    NotReady,
    MessageNotFound,
    NotLatestUserMessage,
    SnapshotUnavailable,
    Conflict,
    RestoreFailed,
    InvalidMessage,
}

public sealed class ConversationMutationException : Exception
{
    public ConversationMutationKind Kind { get; }
    public IReadOnlyList<string> Paths { get; }

    public ConversationMutationException(ConversationMutationKind kind, string message, IReadOnlyList<string>? paths = null)
        : base(message)
    {
        Kind = kind;
        Paths = paths ?? Array.Empty<string>();
    }
}

public sealed partial class AgentBridge
{
    private readonly WorkspaceSnapshotStore _snapshots;
    private bool _historyMutationBusy;

    /// <summary>True while a rewind or edit is rewriting history; new runs must wait.</summary>
    public bool HistoryMutationBusy => _historyMutationBusy;

    private bool CanMutateHistory(Conversation conversation) =>
        Area == AgentArea.Coding
        && RemoteTarget is null
        && !AnyRunBusy
        && !_historyMutationBusy
        && conversation.PendingPrompts.Count == 0
        && !string.IsNullOrWhiteSpace(conversation.Cwd)
        && Directory.Exists(conversation.Cwd);

    /// <summary>The distinct turn ids of the user messages from <paramref name="index"/> on; null when one has none.</summary>
    private static List<string>? TurnIdsFrom(IList<ChatMessage> messages, int index)
    {
        var result = new List<string>();
        var seen = new HashSet<string>(StringComparer.Ordinal);
        for (var i = index; i < messages.Count; i++)
        {
            if (messages[i].Kind != ChatKind.User) continue;
            if (messages[i].TurnId is not { } turnId) return null;
            if (seen.Add(turnId)) result.Add(turnId);
        }
        return result;
    }

    public bool CanRewind(string conversationId, string messageId)
    {
        if (Conversations.FirstOrDefault(c => c.Id == conversationId) is not { } conversation
            || !CanMutateHistory(conversation)) return false;
        var index = IndexOf(conversation, messageId);
        if (index < 0 || conversation.Messages[index].Kind != ChatKind.User) return false;
        var turns = TurnIdsFrom(conversation.Messages, index);
        return turns is { Count: > 0 }
            && turns.All(turn => _snapshots.HasCompleteSnapshot(conversationId, turn, conversation.Cwd!));
    }

    public bool CanEdit(string conversationId, string messageId)
    {
        if (Conversations.FirstOrDefault(c => c.Id == conversationId) is not { } conversation
            || !CanMutateHistory(conversation)) return false;
        var index = IndexOf(conversation, messageId);
        if (index < 0 || conversation.Messages[index].Kind != ChatKind.User) return false;
        if (conversation.Messages.LastOrDefault(m => m.Kind == ChatKind.User)?.Id != messageId) return false;
        return conversation.Messages[index].TurnId is { } turn
            && _snapshots.HasCompleteSnapshot(conversationId, turn, conversation.Cwd!);
    }

    /// <summary>
    /// Drops the message and everything after it and restores the files those turns changed. A file the
    /// user edited since is left alone and reported in <see cref="RewindResult.ConflictPaths"/>.
    /// </summary>
    public RewindResult Rewind(string conversationId, string beforeMessageId)
    {
        if (AnyRunBusy || _historyMutationBusy)
            throw new ConversationMutationException(ConversationMutationKind.Busy, "Wait for the current run to finish.");
        var conversation = Conversations.FirstOrDefault(c => c.Id == conversationId)
            ?? throw new ConversationMutationException(ConversationMutationKind.MessageNotFound, "The conversation was not found.");
        var index = IndexOf(conversation, beforeMessageId);
        if (!CanMutateHistory(conversation) || index < 0 || conversation.Messages[index].Kind != ChatKind.User)
            throw new ConversationMutationException(ConversationMutationKind.MessageNotFound, "That message cannot be rewound.");
        var turns = TurnIdsFrom(conversation.Messages, index);
        if (turns is not { Count: > 0 } || !turns.All(t => _snapshots.HasCompleteSnapshot(conversationId, t, conversation.Cwd!)))
            throw new ConversationMutationException(ConversationMutationKind.SnapshotUnavailable, "No snapshot is available for those turns.");

        _historyMutationBusy = true;
        try
        {
            var result = Restore(conversation, turns, abortOnConflict: false);
            Memory.RecordConversationRewind(conversation.Id, conversation.Title, beforeMessageId, result.RestoredPaths, result.ConflictPaths);
            TruncateBefore(conversation, index);
            if (result.ConflictPaths.Count > 0)
            {
                conversation.Messages.Add(new ChatMessage
                {
                    Kind = ChatKind.System,
                    Text = LocalizationService.Current.Get("conversation.historyConflict", string.Join(", ", result.ConflictPaths)),
                });
            }
            Save();
            Status = LocalizationService.Current.Get(result.ConflictPaths.Count == 0
                ? "conversation.historyRewound"
                : "conversation.historyConflictStatus");
            return result;
        }
        finally { _historyMutationBusy = false; }
    }

    /// <summary>Rewinds the latest user message (refusing on conflict) and sends <paramref name="text"/> in its place.</summary>
    public async Task EditLatestMessageAsync(
        string conversationId, string messageId, string text, IReadOnlyList<ChatAttachment> attachments)
    {
        var trimmed = text.Trim();
        if (trimmed.Length == 0 && attachments.Count == 0)
            throw new ConversationMutationException(ConversationMutationKind.InvalidMessage, "The message is empty.");
        if (AnyRunBusy || _historyMutationBusy)
            throw new ConversationMutationException(ConversationMutationKind.Busy, "Wait for the current run to finish.");
        if (!_router.HasActiveRoute)
            throw new ConversationMutationException(ConversationMutationKind.NotReady, "Connect a provider first.");
        var conversation = Conversations.FirstOrDefault(c => c.Id == conversationId)
            ?? throw new ConversationMutationException(ConversationMutationKind.MessageNotFound, "The conversation was not found.");
        var index = IndexOf(conversation, messageId);
        if (index < 0 || conversation.Messages[index].Kind != ChatKind.User || !CanMutateHistory(conversation))
            throw new ConversationMutationException(ConversationMutationKind.MessageNotFound, "That message cannot be edited.");
        if (conversation.Messages.LastOrDefault(m => m.Kind == ChatKind.User)?.Id != messageId)
            throw new ConversationMutationException(ConversationMutationKind.NotLatestUserMessage, "Only the latest message can be edited.");
        if (conversation.Messages[index].TurnId is not { } turnId
            || !_snapshots.HasCompleteSnapshot(conversationId, turnId, conversation.Cwd!))
            throw new ConversationMutationException(ConversationMutationKind.SnapshotUnavailable, "No snapshot is available for that turn.");

        var editedPlanMode = conversation.Messages.Skip(index + 1)
            .TakeWhile(m => m.Kind != ChatKind.User)
            .Any(m => m.Kind == ChatKind.Plan);

        _historyMutationBusy = true;
        try
        {
            var result = Restore(conversation, [turnId], abortOnConflict: true);
            if (result.ConflictPaths.Count > 0)
                throw new ConversationMutationException(
                    ConversationMutationKind.Conflict,
                    $"These files changed since that turn: {string.Join(", ", result.ConflictPaths)}",
                    result.ConflictPaths);
            Memory.RecordConversationRewind(conversation.Id, conversation.Title, messageId, result.RestoredPaths, result.ConflictPaths);
            TruncateBefore(conversation, index);
            Save();
        }
        finally { _historyMutationBusy = false; }

        SelectedId = conversationId;
        await SendAsync(trimmed, attachments, PromptMode.Queue, editedPlanMode).ConfigureAwait(false);
    }

    private RewindResult Restore(Conversation conversation, IReadOnlyList<string> turns, bool abortOnConflict)
    {
        try { return _snapshots.Restore(conversation.Id, turns, conversation.Cwd!, abortOnConflict); }
        catch (WorkspaceSnapshotException error) when (error.Unavailable)
        {
            throw new ConversationMutationException(ConversationMutationKind.SnapshotUnavailable, error.Message);
        }
        catch (WorkspaceSnapshotException error)
        {
            throw new ConversationMutationException(ConversationMutationKind.RestoreFailed, error.Message);
        }
    }

    private static int IndexOf(Conversation conversation, string messageId)
    {
        for (var i = 0; i < conversation.Messages.Count; i++)
            if (conversation.Messages[i].Id == messageId) return i;
        return -1;
    }

    /// <summary>Removes the message at <paramref name="index"/> and everything after it, and resets run state derived from it.</summary>
    private static void TruncateBefore(Conversation conversation, int index)
    {
        while (conversation.Messages.Count > index) conversation.Messages.RemoveAt(conversation.Messages.Count - 1);
        conversation.PendingPrompts.Clear();
        if (conversation.PendingPlanMessageId is { } planId
            && !conversation.Messages.Any(m => m.Id == planId && m.Kind == ChatKind.Plan))
            conversation.PendingPlanMessageId = null;
        conversation.Continuation = null;
        // Rebuilt from the visible transcript on the next turn.
        conversation.ModelContext = [];
        conversation.ContextSummary = "";
        if (!conversation.Messages.Any(m => m.Kind == ChatKind.User))
        {
            conversation.Title = "New chat";
            conversation.Blank = true;
        }
    }
}

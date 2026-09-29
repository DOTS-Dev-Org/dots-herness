// Copyright (c) 2026 DOTS
// UI-facing entry points for conversation rewind and edit-latest-message.

namespace DotsHarnessCore;

public sealed partial class AppModel
{
    private string? _editingMessageId;
    private string? _editingConversationId;

    /// <summary>Set while the composer holds the text of a message being edited.</summary>
    public string? EditingMessageId
    {
        get => _editingMessageId;
        private set => SetProperty(ref _editingMessageId, value);
    }

    /// <summary>True when ratings can be saved: a coding chat in a local workspace.</summary>
    public bool FeedbackAvailable => ActiveArea == AgentArea.Coding && CodingBridge.FeedbackAvailable;

    private static string Describe(ConversationMutationException error) => error.Kind switch
    {
        ConversationMutationKind.Busy => LocalizationService.Current.Get("conversation.historyBusy"),
        ConversationMutationKind.SnapshotUnavailable => LocalizationService.Current.Get("conversation.historyUnavailable"),
        ConversationMutationKind.NotLatestUserMessage => LocalizationService.Current.Get("conversation.editOnlyLatest"),
        ConversationMutationKind.Conflict => LocalizationService.Current.Get("conversation.historyConflict", string.Join(", ", error.Paths)),
        ConversationMutationKind.RestoreFailed => LocalizationService.Current.Get("conversation.historyRestoreFailed", error.Message),
        _ => error.Message,
    };

    /// <summary>Rewinds the coding conversation to just before <paramref name="messageId"/> and restores the files.</summary>
    public void RewindMessage(string messageId)
    {
        if (ActiveArea != AgentArea.Coding || SelectedConversationId is not { } conversationId) return;
        try { CodingBridge.Rewind(conversationId, messageId); }
        catch (ConversationMutationException error) { CodingBridge.Status = Describe(error); }
    }

    /// <summary>Loads the message into the composer; the next send replaces it instead of adding a turn.</summary>
    public void BeginEditMessage(ChatMessage message)
    {
        if (ActiveArea != AgentArea.Coding || SelectedConversationId is not { } conversationId) return;
        if (!CodingBridge.CanEdit(conversationId, message.Id))
        {
            CodingBridge.Status = LocalizationService.Current.Get(
                CodingBridge.HistoryMutationBusy || CodingBridge.AnyRunBusy ? "conversation.historyBusy" : "conversation.editOnlyLatest");
            return;
        }
        _editingConversationId = conversationId;
        EditingMessageId = message.Id;
        Draft = message.Text;
        CodingBridge.Status = LocalizationService.Current.Get("conversation.editingMessage");
    }

    public void CancelEditMessage()
    {
        EditingMessageId = null;
        _editingConversationId = null;
    }

    /// <summary>
    /// When an edit is pending, sends <paramref name="text"/> as the replacement for that message and
    /// returns true; the caller then clears the composer. Otherwise returns false.
    /// </summary>
    public bool TrySubmitEdit(string text)
    {
        if (EditingMessageId is not { } messageId || _editingConversationId is not { } conversationId) return false;
        CancelEditMessage();
        var attachments = CodingBridge.Conversations.FirstOrDefault(c => c.Id == conversationId)
            ?.Messages.FirstOrDefault(m => m.Id == messageId)?.Attachments ?? [];
        _ = EditAsync(conversationId, messageId, text, attachments);
        return true;
    }

    private async Task EditAsync(string conversationId, string messageId, string text, IReadOnlyList<ChatAttachment> attachments)
    {
        try { await CodingBridge.EditLatestMessageAsync(conversationId, messageId, text, attachments); }
        catch (ConversationMutationException error) { CodingBridge.Status = Describe(error); }
    }
}

// Copyright (c) 2026 DOTS
// Per-message feedback and the project memory learned from it. Mirrors the macOS AgentBridge feedback
// flow: a record is written to the workspace's .mem folder first (the source of truth); the gold-example
// projection is rebuilt from it; a bad rating additionally asks the model, in the background, for one
// concrete "avoid this" rule, which is only accepted if it passes a strict shape check.

using System.Collections.Concurrent;

namespace DotsHarnessCore;

public sealed partial class AgentBridge
{
    private FeedbackStore? _feedbackStore;
    private readonly ConcurrentDictionary<string, (CancellationTokenSource Cancel, Guid Token)> _feedbackEvaluations = new();

    /// <summary>Feedback is kept per local workspace; chat and remote hosts have no .mem folder to write to.</summary>
    public bool FeedbackAvailable => _feedbackStore is { IsAvailable: true };

    private void BindFeedbackStore(string workspace)
    {
        foreach (var (_, entry) in _feedbackEvaluations) entry.Cancel.Cancel();
        _feedbackEvaluations.Clear();
        _feedbackStore = Area == AgentArea.Coding && RemoteTarget is null && Directory.Exists(workspace)
            ? new FeedbackStore(workspace)
            : null;
        if (_feedbackStore is { } store && store.Records().Count > 0)
        {
            // Repair a gold projection an interrupted earlier write left behind.
            _ = Task.Run(() => { try { store.RebuildGoldExamples(); } catch (FeedbackException) { } });
        }
    }

    /// <summary>The data-trust prompt block: learned rules and the gold examples most like <paramref name="prompt"/>.</summary>
    internal string FeedbackMemoryText(string? prompt) =>
        _feedbackStore is { IsAvailable: true } store && !string.IsNullOrWhiteSpace(prompt)
            ? store.Context(prompt)
            : _feedbackStore is { IsAvailable: true } only ? only.Context("") : "";

    public FeedbackRecord? FeedbackFor(string messageId, string conversationId)
    {
        if (_feedbackStore is null
            || Conversations.FirstOrDefault(c => c.Id == conversationId) is not { } conversation
            || !IsFeedbackConversation(conversation)) return null;
        return _feedbackStore.Record(conversationId, messageId);
    }

    public void SubmitFeedback(
        string conversationId, string messageId, FeedbackType type, IReadOnlyList<string> tags, string userComment)
    {
        if (_feedbackStore is not { IsAvailable: true } store) throw new FeedbackException(FeedbackErrorKind.Unavailable);
        var conversation = Conversations.FirstOrDefault(c => c.Id == conversationId);
        if (conversation is null || !IsFeedbackConversation(conversation))
            throw new FeedbackException(FeedbackErrorKind.ConversationNotFound);
        var index = conversation.Messages.ToList().FindIndex(m => m.Id == messageId);
        if (index < 0) throw new FeedbackException(FeedbackErrorKind.MessageNotFound);
        var message = conversation.Messages[index];
        if (message.Kind is not (ChatKind.Assistant or ChatKind.Plan)) throw new FeedbackException(FeedbackErrorKind.UnsupportedMessage);
        if (message.Streaming) throw new FeedbackException(FeedbackErrorKind.StreamingMessage);
        var prompt = FeedbackPrompt(index, conversation) ?? throw new FeedbackException(FeedbackErrorKind.MissingPrompt);
        var response = FeedbackResponse(message);
        if (string.IsNullOrEmpty(response)) throw new FeedbackException(FeedbackErrorKind.MissingResponse);

        var allowed = FeedbackTags.For(type).ToHashSet(StringComparer.Ordinal);
        var normalized = new List<string>();
        foreach (var tag in tags) if (allowed.Contains(tag) && !normalized.Contains(tag)) normalized.Add(tag);
        var record = new FeedbackRecord
        {
            ConversationId = conversationId,
            MessageId = messageId,
            Prompt = prompt,
            Response = response,
            FeedbackType = type,
            Tags = normalized,
            UserComment = userComment.Trim(),
            Timestamp = DateTimeOffset.FromUnixTimeSeconds(DateTimeOffset.UtcNow.ToUnixTimeSeconds()),
        };

        store.Upsert(record);
        // Invalidate the previous evaluator only after the new raw record is durable: a failed write
        // must not discard a still-valid evaluation.
        CancelFeedbackEvaluation(record.Id);
        // The raw record is the source of truth; a projection failure must not lose the user's feedback.
        try { store.RebuildGoldExamples(); store.SetLearnedRule(null, record); }
        catch (FeedbackException) { }
        if (type == FeedbackType.Bad) ScheduleNegativeFeedbackEvaluation(record, store);
    }

    private bool IsFeedbackConversation(Conversation conversation) =>
        _feedbackStore?.WorkspacePath is { } workspace && SameWorkspace(conversation.Cwd, workspace);

    private static string? FeedbackPrompt(int messageIndex, Conversation conversation)
    {
        var message = conversation.Messages[messageIndex];
        var before = conversation.Messages.Take(messageIndex).Where(m => m.Kind == ChatKind.User);
        var user = message.TurnId is { } turnId
            ? before.LastOrDefault(m => m.TurnId == turnId)
            : before.LastOrDefault();
        if (user is null) return null;
        var attachments = string.Join(", ", user.Attachments.Select(a => a.Name));
        var prompt = string.Join("\n", new[]
        {
            user.Text.Trim(),
            attachments.Length == 0 ? "" : $"[Attachments: {attachments}]",
        }.Where(part => part.Length > 0));
        return prompt.Length == 0 ? null : prompt;
    }

    private static string FeedbackResponse(ChatMessage message) => message.Text.Trim();

    private void CancelFeedbackEvaluation(string key)
    {
        if (_feedbackEvaluations.TryRemove(key, out var entry)) entry.Cancel.Cancel();
    }

    private void ScheduleNegativeFeedbackEvaluation(FeedbackRecord record, FeedbackStore store)
    {
        var token = Guid.NewGuid();
        var cancel = new CancellationTokenSource();
        _feedbackEvaluations[record.Id] = (cancel, token);
        var messages = new List<NativeMessage>
        {
            new("system", FeedbackEvaluator.SystemPrompt),
            new("user", FeedbackEvaluator.Payload(record)),
        };
        _ = Task.Run(async () =>
        {
            try
            {
                var response = await _router.CompleteAsync(messages, [], null, cancel.Token).ConfigureAwait(false);
                if (cancel.IsCancellationRequested
                    || !_feedbackEvaluations.TryGetValue(record.Id, out var current) || current.Token != token
                    || !ReferenceEquals(_feedbackStore, store)
                    || store.Record(record.ConversationId, record.MessageId) is not { } stored || !stored.SameContent(record)
                    || !FeedbackRecordStillCurrent(record)) return;
                if (FeedbackEvaluator.ParseNegativeConstraint(response.Message.Content) is { } rule)
                    store.SetLearnedRule(rule, record);
            }
            catch (Exception e) when (e is OperationCanceledException or NativeProviderException or HttpRequestException
                or FeedbackException or IOException)
            {
                // Evaluator failures are silent on purpose: feedback.jsonl stays durable and can be
                // evaluated again after a later edit.
            }
            finally
            {
                if (_feedbackEvaluations.TryGetValue(record.Id, out var entry) && entry.Token == token)
                    _feedbackEvaluations.TryRemove(record.Id, out _);
                cancel.Dispose();
            }
        });
    }

    private bool FeedbackRecordStillCurrent(FeedbackRecord record)
    {
        if (Conversations.FirstOrDefault(c => c.Id == record.ConversationId) is not { } conversation) return false;
        var index = conversation.Messages.ToList().FindIndex(m => m.Id == record.MessageId);
        return index >= 0
            && FeedbackPrompt(index, conversation) == record.Prompt
            && FeedbackResponse(conversation.Messages[index]) == record.Response;
    }
}

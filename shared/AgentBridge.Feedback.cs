// Copyright (c) 2026 DOTS
// Workspace-scoped answer feedback for the Windows and Linux desktop clients.

namespace DotsHarnessCore;

public sealed partial class AgentBridge
{
    public FeedbackRecord? FeedbackFor(ChatMessage message)
    {
        var conversation = Selected;
        if (conversation is null || conversation.Messages.All(item => item.Id != message.Id)) return null;
        var workspace = conversation.Cwd;
        if (string.IsNullOrWhiteSpace(workspace) || !Directory.Exists(workspace)) return null;
        return new FeedbackStore(workspace).Record(conversation.Id, message.Id);
    }

    /// <summary>
    /// Persists the user's choice locally before updating the visible message.
    /// A returned localization key keeps the dialog open when the operation fails.
    /// </summary>
    public string? SubmitFeedback(
        ChatMessage message,
        FeedbackType type,
        IReadOnlyList<string> tags,
        string comment)
    {
        var conversation = Selected;
        if (conversation is null) return "feedback.conversationNotFound";
        var index = conversation.Messages.IndexOf(message);
        if (index < 0) return "feedback.messageNotFound";
        if (message.Kind is not (ChatKind.Assistant or ChatKind.Plan)) return "feedback.unsupportedMessage";
        if (message.Streaming) return "feedback.streamingMessage";
        var workspace = conversation.Cwd;
        if (string.IsNullOrWhiteSpace(workspace) || !Directory.Exists(workspace)) return "feedback.unavailable";

        var promptMessage = conversation.Messages
            .Take(index)
            .Reverse()
            .FirstOrDefault(candidate => candidate.Kind == ChatKind.User
                && (string.IsNullOrWhiteSpace(message.TurnId) || candidate.TurnId == message.TurnId));
        if (promptMessage is null) return "feedback.missingPrompt";
        var prompt = promptMessage.Text.Trim();
        var attachmentNames = promptMessage.Attachments.Select(attachment => attachment.Name)
            .Where(name => name.Length > 0).ToList();
        if (attachmentNames.Count > 0) prompt += $"\n[Attachments: {string.Join(", ", attachmentNames)}]";
        if (string.IsNullOrWhiteSpace(prompt)) return "feedback.missingPrompt";

        var response = message.Text.Trim();
        if (response.Length == 0 && message.Media is { } media)
        {
            var mediaKind = media.MimeType.StartsWith("image/", StringComparison.OrdinalIgnoreCase)
                ? "image"
                : Path.GetExtension(media.FilePath).TrimStart('.');
            response = $"[Media: {(mediaKind.Length == 0 ? "attachment" : mediaKind)}]";
        }
        if (response.Length == 0) return "feedback.missingResponse";

        var allowed = FeedbackCatalog.For(type).Select(option => option.Id).ToHashSet(StringComparer.Ordinal);
        var normalizedTags = tags.Where(allowed.Contains).Distinct(StringComparer.Ordinal).ToList();
        var record = new FeedbackRecord(
            conversation.Id,
            message.Id,
            prompt,
            response,
            type,
            normalizedTags,
            comment.Trim(),
            DateTimeOffset.UtcNow);
        var store = new FeedbackStore(workspace);
        if (!store.Upsert(record)) return "feedback.persistenceFailed";

        var source = "feedback:" + store.DerivedKey(record);
        WorkspaceLessons.LogCorrection(workspace, "feedback", conversation.Id, message.TurnId,
            "unknown", "unknown", "unknown", type == FeedbackType.Good ? "approved" : "rejected");
        // Replacing feedback invalidates both the user's previous direct rule and
        // the evaluator's old inference before either new projection is written.
        WorkspaceLessons.Set(workspace, null, source);
        WorkspaceLessons.Set(workspace, null, source + Lesson.InferredSuffix);
        if (FeedbackStore.DirectRule(record) is { } directRule)
        {
            WorkspaceLessons.Set(workspace,
                new Lesson("", directRule, "", [], [], record.Timestamp),
                source);
        }
        WorkspaceLessons.SyncUserProfile(workspace, _paths.Root, WorkspaceStack.Current(workspace, _paths.Root));

        message.Feedback = type == FeedbackType.Good ? "good" : "bad";
        SaveNow();

        var shouldEvaluate = type == FeedbackType.Bad
            || record.UserComment.Length > 0
            || FeedbackCatalog.IsMeaningfulPositive(normalizedTags);
        if (shouldEvaluate && _router.HasActiveRoute && BuildFeedbackEvidence(conversation, index, record, source) is { } evidence)
        {
            var inferredSource = source + Lesson.InferredSuffix;
            _ = EvaluateLessonAsync(
                workspace,
                evidence,
                () => FeedbackStillCurrent(conversation.Id, record),
                inferredSource);
        }
        return null;
    }

    private static LessonEvidence? BuildFeedbackEvidence(
        Conversation conversation,
        int answerIndex,
        FeedbackRecord record,
        string source)
    {
        var answer = conversation.Messages[answerIndex];
        var start = answerIndex;
        while (start > 0 && conversation.Messages[start].Kind != ChatKind.User) start--;
        if (conversation.Messages[start].Kind != ChatKind.User) return null;
        var turn = conversation.Messages.Skip(start).Take(answerIndex - start + 1).ToList();
        var tools = turn.Where(item => item.Kind == ChatKind.Tool)
            .Select(item => string.Join(" ", item.Text.Split('\n', StringSplitOptions.RemoveEmptyEntries).Take(2)) is { } line
                ? line.Length > 200 ? line[..200] : line
                : "")
            .Where(item => item.Length > 0)
            .ToList();
        var changed = turn.SelectMany(item => item.ChangedFiles)
            .Select(file => file.Path)
            .Distinct(StringComparer.Ordinal)
            .ToList();
        return new LessonEvidence(
            "feedback",
            source,
            record.Prompt,
            record.Response,
            record.UserComment,
            tools,
            changed,
            record.Tags,
            record.Type == FeedbackType.Good ? "approved" : "rejected");
    }

    private bool FeedbackStillCurrent(string conversationId, FeedbackRecord expected)
    {
        var conversation = Conversations.FirstOrDefault(item => item.Id == conversationId);
        if (conversation is null || string.IsNullOrWhiteSpace(conversation.Cwd)) return false;
        var message = conversation.Messages.FirstOrDefault(item => item.Id == expected.MessageId);
        if (message is null || message.Streaming) return false;
        var response = message.Text.Trim();
        if (response.Length == 0 && message.Media is { } media)
        {
            var mediaKind = media.MimeType.StartsWith("image/", StringComparison.OrdinalIgnoreCase)
                ? "image"
                : Path.GetExtension(media.FilePath).TrimStart('.');
            response = $"[Media: {(mediaKind.Length == 0 ? "attachment" : mediaKind)}]";
        }
        if (response != expected.Response) return false;
        var current = new FeedbackStore(conversation.Cwd).Record(conversationId, expected.MessageId);
        return current is not null
            && current.Timestamp == expected.Timestamp
            && current.Type == expected.Type
            && current.Prompt == expected.Prompt
            && current.Response == expected.Response
            && current.UserComment == expected.UserComment
            && current.Tags.SequenceEqual(expected.Tags, StringComparer.Ordinal);
    }
}

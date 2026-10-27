// Copyright (c) 2026 DOTS
using DotsHarnessCore;
using Xunit;

public sealed class FeedbackLearningTests : IDisposable
{
    private readonly string _workspace = Path.Combine(Path.GetTempPath(), "dots-feedback-" + Guid.NewGuid().ToString("N"));

    public FeedbackLearningTests() => Directory.CreateDirectory(Path.Combine(_workspace, ".mem"));

    public void Dispose() => Directory.Delete(_workspace, recursive: true);

    /// Feedback keeps which answer it was given on, not the answer; a file from before is rewritten.
    [Fact]
    public void RawTextIsNotStoredAndOlderFilesAreScrubbed()
    {
        var feedback = Path.Combine(_workspace, ".mem", "feedback.jsonl");
        var gold = Path.Combine(_workspace, ".mem", "gold_examples.json");
        File.WriteAllText(feedback,
            """{"conversation_id":"old","message_id":"m","prompt":"OLD SECRET REQUEST","response":"OLD ANSWER","feedback_type":"good","tags":[],"user_comment":"","timestamp":"2026-01-01T00:00:00+00:00"}""" + "\n");
        File.WriteAllText(gold, "[]");
        var store = new FeedbackStore(_workspace);

        store.DropRawText();
        Assert.False(File.Exists(gold));
        Assert.Equal(FeedbackRecord.ComputeDigest("OLD SECRET REQUEST", "OLD ANSWER"), store.Record("old", "m")?.Digest);

        var added = new FeedbackRecord("c", "m", "NEW REQUEST", "NEW ANSWER", FeedbackType.Bad, ["lost_context"], "comment", DateTimeOffset.UtcNow);
        Assert.True(store.Upsert(added));
        var text = File.ReadAllText(feedback);
        foreach (var raw in new[] { "OLD SECRET REQUEST", "OLD ANSWER", "NEW REQUEST", "NEW ANSWER", "\"prompt\"", "\"response\"" })
            Assert.DoesNotContain(raw, text);
        var read = store.Record("c", "m");
        Assert.Equal(added.Digest, read?.Digest);
        Assert.Equal("comment", read?.UserComment);
        Assert.Equal(2, store.ReadAll().Count);
    }
}

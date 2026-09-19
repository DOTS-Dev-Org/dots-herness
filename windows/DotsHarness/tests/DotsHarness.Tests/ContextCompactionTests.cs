using DotsHarnessCore;
using Xunit;

namespace DotsHarness.Tests;

public sealed class ContextCompactionTests
{
    [Fact]
    public void BudgetTriggersAtSeventyFivePercentAndTargetsFortyPercent()
    {
        var budget = ContextCompaction.Budget(32_768, reservedOutputTokens: 4_096, toolDefinitionTokens: 1_000);

        Assert.Equal((int)(budget.UsableInputTokens * .75), budget.TriggerTokens);
        Assert.Equal((int)(budget.UsableInputTokens * .40), budget.TargetTokens);
        Assert.True(budget.UsableInputTokens < budget.ContextWindow);
    }

    [Fact]
    public void SelectionKeepsFiveRecentTurnsWhenTheyFit()
    {
        var messages = new List<NativeMessage> { new("system", "workspace rules") };
        for (var i = 1; i <= 7; i++)
        {
            messages.Add(new NativeMessage("user", $"request {i}"));
            messages.Add(new NativeMessage("assistant", $"answer {i}"));
        }

        var selection = ContextCompaction.Select(
            messages,
            previousSummary: null,
            ContextCompaction.Budget(32_768));

        Assert.NotNull(selection);
        Assert.Equal(5, selection!.RecentGroupCount);
        Assert.Equal("workspace rules", selection.StableSystem.Single().Content);
        Assert.Contains("request 3", selection.RecentMessages[0].Content);
        Assert.DoesNotContain("request 2", selection.RecentMessages.Select(message => message.Content));
    }

    [Fact]
    public void ArchiveNeverSplitsToolCallFromItsResultOrStoresFileBody()
    {
        var body = new string('x', 8_000);
        var messages = new List<NativeMessage>
        {
            new("system", "rules"),
            new("user", "inspect the file"),
            new("assistant", "", ToolCalls: [new NativeToolCall("call-1", "read_file", "{\"path\":\"src/a.cs\"}")]),
            new("tool", body, "call-1"),
            new("user", "now fix it"),
            new("assistant", "I will fix it."),
        };

        var selection = ContextCompaction.Select(messages, null, ContextCompaction.Budget(8_192));

        Assert.NotNull(selection);
        Assert.Contains(selection!.ArchivedMessages, message => message.ToolCallId == "call-1");
        Assert.Contains("file body omitted", selection.ArchiveText, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain(body, selection.ArchiveText);
    }

    [Fact]
    public void SummaryFallbackKeepsTheRequiredFourHeadings()
    {
        var summary = ContextCompaction.FallbackSummary(null, "test evidence");

        Assert.True(ContextCompaction.IsValidSummary(summary));
    }

    [Fact]
    public void CompactionKeepsTheLanguagePolicyInStableSystemContext()
    {
        var policy = HerNessPrompt.Core("scope line", "tool line");
        var messages = new List<NativeMessage> { new("system", policy) };
        for (var i = 1; i <= 7; i++)
        {
            messages.Add(new NativeMessage("user", $"request {i}"));
            messages.Add(new NativeMessage("assistant", $"answer {i}"));
        }

        var selection = ContextCompaction.Select(
            messages,
            previousSummary: null,
            ContextCompaction.Budget(32_768));

        Assert.NotNull(selection);
        Assert.Contains(selection!.StableSystem, message => message.Content.Contains("Response language"));
        var composed = selection.Compose("summary", preserveNativeItems: false);
        Assert.Contains(composed, message => message.Role == "system" && message.Content.Contains("Response language"));
        Assert.Contains("son güvenilir sohbet dilini", ContextCompaction.SummarySystemPrompt);
        Assert.Contains("başka bir sohbetin dilini kullanma", ContextCompaction.SummarySystemPrompt);
    }

    [Fact]
    public void CompactionPreservesTurkishEnglishAndSimplifiedChineseTurnSequence()
    {
        var policy = HerNessPrompt.Core("scope line", "tool line");
        var messages = new List<NativeMessage> { new("system", policy) };
        foreach (var (user, assistant) in new[]
        {
            ("Merhaba, Türkçe devam edelim.", "Türkçe yanıt"),
            ("Please answer in English for this turn.", "English response"),
            ("请用简体中文回答。", "简体中文回复"),
        })
        {
            messages.Add(new NativeMessage("user", user));
            messages.Add(new NativeMessage("assistant", assistant));
        }

        var selection = ContextCompaction.Select(
            messages,
            previousSummary: null,
            ContextCompaction.Budget(8_192));

        Assert.NotNull(selection);
        Assert.Contains("Türkçe", selection!.ArchiveText);
        Assert.Contains("English", selection.ArchiveText);
        Assert.Contains(selection.RecentMessages, message => message.Content.Contains("简体中文"));
        Assert.Contains(selection.StableSystem, message => message.Content.Contains("Response language"));
    }
}

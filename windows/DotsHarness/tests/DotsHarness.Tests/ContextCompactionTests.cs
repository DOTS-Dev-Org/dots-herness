using DotsHarnessCore;
using Xunit;

namespace DotsHarness.Tests;

public sealed class ContextCompactionTests
{
    [Fact]
    public void DefaultBudgetTriggersAtNinetyPercentAndTargetsSixtyFivePercent()
    {
        var budget = ContextCompaction.Budget(32_768, reservedOutputTokens: 4_096, toolDefinitionTokens: 1_000);

        Assert.Equal((int)(budget.UsableInputTokens * .90), budget.TriggerTokens);
        Assert.Equal((int)(budget.UsableInputTokens * .65), budget.TargetTokens);
        Assert.True(budget.UsableInputTokens < budget.ContextWindow);
    }

    [Fact]
    public void EconomyThresholdIsFixedAndUserThresholdAcceptsZero()
    {
        var economy = ContextCompaction.Budget(32_768, economy: true, triggerPercent: 20);
        Assert.Equal(0.90, economy.TriggerRatio);

        var immediate = ContextCompaction.Budget(32_768, triggerPercent: 0);
        Assert.Equal(0, immediate.TriggerRatio);
        Assert.Equal(1, immediate.TriggerTokens);
    }

    [Fact]
    public void EconomyBudgetUsesNinetyPercentAndReservesLargeDynamicOutput()
    {
        var budget = ContextCompaction.Budget(
            32_768,
            reservedOutputTokens: 20_000,
            toolDefinitionTokens: 1_000,
            economy: true);

        Assert.Equal(0.90, budget.TriggerRatio);
        Assert.Equal((int)(budget.UsableInputTokens * .90), budget.TriggerTokens);
        Assert.True(budget.ReservedOutputTokens > 16_384);
        Assert.True(budget.Fits(budget.UsableInputTokens));
        Assert.False(budget.Fits(budget.UsableInputTokens, incomingTokens: 1));
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
        var omitted = ContextCompaction.FallbackSummary(null, "evidence [… compacted …] tail");
        Assert.Contains("atlandı", omitted, StringComparison.OrdinalIgnoreCase);
        Assert.Contains("eksik ayrıntıları varsayma", ContextCompaction.SummarySystemPrompt, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void OversizedArchiveKeepsNewestEvidenceAndMarksOmittedMiddle()
    {
        var messages = new List<NativeMessage>();
        for (var index = 0; index < 20; index++)
        {
            messages.Add(new NativeMessage("user", new string('u', 5_900) + $"USER_{index:D2}"));
            messages.Add(new NativeMessage("assistant", new string('x', 5_900) + $"ARCHIVE_TAIL_{index:D2}"));
        }

        var selection = ContextCompaction.Select(messages, null, ContextCompaction.Budget(32_768));

        Assert.NotNull(selection);
        Assert.Equal(5, selection!.RecentGroupCount);
        Assert.Contains("[… compacted …]", selection.ArchiveText);
        Assert.Contains("ARCHIVE_TAIL_14", selection.ArchiveText);
        Assert.DoesNotContain("ARCHIVE_TAIL_15", selection.ArchiveText);
        Assert.InRange(selection.ArchiveText.Length, 1, 48_000);
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

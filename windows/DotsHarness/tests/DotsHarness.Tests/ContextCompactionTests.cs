using DotsHarnessCore;
using Xunit;

namespace DotsHarness.Tests;

public sealed class ContextCompactionTests
{
    private static NativeMessage ReadCall(string id, string arguments) =>
        new("assistant", "", ToolCalls: [new NativeToolCall(id, "read_file", arguments)]);

    private static NativeMessage ToolResult(string id, string content) =>
        new("tool", content, ToolCallId: id);

    [Fact]
    public async Task TrimToolResultsStopsWhenShortResultsCannotShrinkFurther()
    {
        // The system prompt alone exceeds the ceiling, and a ~200-character result
        // clipped to the 160 floor plus its notice is longer than before.
        var messages = new List<NativeMessage>
        {
            new("system", new string('p', 40_000)),
            new("user", "look"),
            ReadCall("a", """{"path":"a.txt"}"""),
            ToolResult("a", new string('x', 200)),
        };
        var trim = Task.Run(() => ContextCompaction.TrimToolResults(messages, 1_024));
        Assert.Same(trim, await Task.WhenAny(trim, Task.Delay(TimeSpan.FromSeconds(5))));
        Assert.Equal(new string('x', 200), messages[3].Content);
    }

    [Fact]
    public void OnlyTheLatestReadOfTheSameLinesKeepsItsBody()
    {
        var messages = new List<NativeMessage>
        {
            new("system", "policy"),
            new("user", "look"),
            ReadCall("a", """{"path":"src/app.cs"}"""),
            ToolResult("a", "old body"),
            ReadCall("b", """{"path":"src/app.cs","offset":251}"""),
            ToolResult("b", "second page"),
            ReadCall("c", """{"path":"./src/app.cs","offset":1}"""),
            ToolResult("c", "new body"),
            ReadCall("d", """{"path":"src/other.cs"}"""),
            ToolResult("d", "Tool error: missing"),
            ReadCall("e", """{"path":"src/other.cs"}"""),
            ToolResult("e", "Tool error: missing again"),
        };

        var result = ContextCompaction.SupersedeRepeatedReads(messages);

        Assert.Equal(ContextCompaction.SupersededReadMarker, result[3].Content);
        Assert.Equal("second page", result[5].Content);
        Assert.Equal("new body", result[7].Content);
        Assert.Equal("Tool error: missing", result[9].Content);
        Assert.Equal(messages.Count, result.Count);
        // Running it again changes nothing, so the persisted prefix stays stable.
        Assert.Equal(result, ContextCompaction.SupersedeRepeatedReads(result));
    }

    [Fact]
    public void DefaultBudgetTriggersAtNinetyPercentAndTargetsSixtyFivePercent()
    {
        var budget = ContextCompaction.Budget(32_768, reservedOutputTokens: 4_096, toolDefinitionTokens: 1_000);

        // A small window is bounded by the output reservation, a large one by 90% of the window.
        Assert.Equal(budget.UsableInputTokens + budget.ToolDefinitionTokens, budget.TriggerTokens);
        Assert.Equal(900_000, ContextCompaction.Budget(1_000_000, reservedOutputTokens: 4_096, toolDefinitionTokens: 1_000).TriggerTokens);
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
        Assert.Equal(budget.UsableInputTokens + budget.ToolDefinitionTokens, budget.TriggerTokens);
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
            new("assistant", "", ToolCalls: [new NativeToolCall("call-1", "invoke_tool", """{"name":"read_file","arguments":"{\"path\":\"src/a.cs\"}"}""")]),
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
        Assert.Contains(selection!.StableSystem, message => message.Content.Contains("Accuracy and language"));
        var composed = selection.Compose("summary", preserveNativeItems: false);
        Assert.Contains(composed, message => message.Role == "system" && message.Content.Contains("Accuracy and language"));
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
        Assert.Contains(selection.StableSystem, message => message.Content.Contains("Accuracy and language"));
    }

    [Fact]
    public void InvokeToolReadsAndWiderSpansSupersedeEarlierReads()
    {
        var messages = new List<NativeMessage>
        {
            new("user", "inspect"),
            new("assistant", "", ToolCalls: [
                new NativeToolCall("r1", "invoke_tool", """{"name":"read_file","arguments":"{\"path\":\"src/app.cs\",\"offset\":10,\"limit\":40}"}""")
            ]),
            ToolResult("r1", "narrow slice"),
            new("assistant", "", ToolCalls: [
                new NativeToolCall("r2", "invoke_tool", """{"name":"read_file","arguments":"{\"path\":\"src/app.cs\",\"offset\":1,\"limit\":100}"}""")
            ]),
            ToolResult("r2", "wider slice covering lines 1..100"),
        };

        var result = ContextCompaction.SupersedeRepeatedReads(messages);

        Assert.Equal(ContextCompaction.SupersededReadMarker, result[2].Content);
        Assert.Equal("wider slice covering lines 1..100", result[4].Content);
    }

    [Fact]
    public void ArchiveOmitsEditFilePayloadsAndBodies()
    {
        var oldBody = new string('a', 4_000);
        var newBody = new string('b', 4_000);
        var diffOutput = new string('d', 4_000);
        var messages = new List<NativeMessage>
        {
            new("system", "rules"),
            new("user", "patch the file"),
            new("assistant", "", ToolCalls: [
                new NativeToolCall("edit-1", "edit_file", $$"""{"path":"src/app.cs","old_string":"{{oldBody}}","new_string":"{{newBody}}"}""")
            ]),
            new("tool", diffOutput, "edit-1"),
            new("user", "next step"),
            new("assistant", "done"),
        };

        var selection = ContextCompaction.Select(messages, null, ContextCompaction.Budget(8_192));

        Assert.NotNull(selection);
        Assert.Contains("file edits omitted", selection!.ArchiveText, StringComparison.OrdinalIgnoreCase);
        Assert.Contains("file write result omitted", selection.ArchiveText, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain(oldBody, selection.ArchiveText);
        Assert.DoesNotContain(newBody, selection.ArchiveText);
        Assert.DoesNotContain(diffOutput, selection.ArchiveText);
    }

    [Fact]
    public void ReadOnlyToolContainingErrorTextDoesNotResetRoutineEffort()
    {
        var session = new DeferredToolSession();
        session.Control(
            new NativeToolCall("plan-1", DeferredToolSession.PlanName, """{"steps":["Update config"],"routine":true,"uncertainties":[]}"""),
            [],
            planMode: false);
        Assert.Equal("low", session.Effort("high", planMode: false));

        session.Record("Error: something failed in log line 42", "call-1", "read_file");
        session.Record("Tool error: no matches", "call-2", "grep_files");
        Assert.Equal("low", session.Effort("high", planMode: false));

        session.Record("Error: build failed", "call-3", "run_command");
        Assert.Equal("high", session.Effort("high", planMode: false));
    }

    [Fact]
    public void EconomyModeSkipsFollowUpSuggestionsAndTransientProgressTokens()
    {
        Assert.True(FollowUpSuggestions.ShouldGenerate(true, false, false, false, economy: false));
        Assert.False(FollowUpSuggestions.ShouldGenerate(true, false, false, false, economy: true));

        var transientMsg = new NativeMessage("assistant", new string('p', 4_000), IsTransientProgressText: true);
        var normalMsg = new NativeMessage("assistant", new string('p', 4_000), IsTransientProgressText: false);
        Assert.True(ContextCompaction.EstimateTokens(transientMsg) < 10);
        Assert.True(ContextCompaction.EstimateTokens(normalMsg) >= 1_000);
        Assert.Equal("", ContextCompaction.ProviderContextMessages([transientMsg])[0].Content);
    }
}

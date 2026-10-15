using DotsHarnessCore;
using Xunit;

namespace DotsHarness.Tests;

public sealed class EconomyPolicyTests
{
    [Fact]
    public void LargeWindowsCompactAtTheirPercentageInEveryMode()
    {
        foreach (var window in new[] { 272_000, 1_000_000 })
        {
            var standard = ContextCompaction.Budget(window);
            var economy = ContextCompaction.Budget(window, economy: true);
            Assert.Equal((int)(standard.UsableInputTokens * .90), standard.TriggerTokens);
            Assert.Equal((int)(economy.UsableInputTokens * .90), economy.TriggerTokens);
            Assert.True(standard.TargetTokens < standard.TriggerTokens);
            Assert.True(economy.TargetTokens < economy.TriggerTokens);
            Assert.Equal((int)(window * .90), ContextCompaction.NativeThreshold(window, 90));
        }
        Assert.Equal(1, ContextCompaction.NativeThreshold(1_000_000, 0));
    }

    [Fact]
    public void UnchangedPromptSectionsAreCapturedOnceAndRetiredSectionsAreClosed()
    {
        const string rules = "<project_context trust=\"rules\">\nuse tabs\n</project_context>";
        const string runtime = "<runtime_context>\nworkspace one\n</runtime_context>";
        var first = NativePromptHistory.Prepare([new NativeMessage("user", "one")], "policy", runtime + "\n\n" + rules);
        var second = NativePromptHistory.Prepare(first.Concat([new NativeMessage("user", "two")]).ToList(), "policy", runtime + "\n\n" + rules);
        Assert.Equal("two", second.Last().Content);
        Assert.Equal(first, second.Take(first.Count));
        var restored = System.Text.Json.JsonSerializer.Deserialize<List<NativeMessage>>(System.Text.Json.JsonSerializer.Serialize(second))!;
        var third = NativePromptHistory.Prepare(restored.Concat([new NativeMessage("user", "three")]).ToList(), "policy", runtime);
        Assert.Equal("<project_context>\nNo longer applies.\n</project_context>\n\nthree", third.Last().Content);
        var fresh = NativePromptHistory.Prepare([new NativeMessage("user", "four")], "policy", rules);
        Assert.Contains("use tabs", fresh.Last().Content);
    }

    [Fact]
    public void ResponsesCheckpointReplacesEarlierItemsAndPreservesPendingToolResults()
    {
        var checkpoint = System.Text.Json.Nodes.JsonNode.Parse("{\"type\":\"compaction\",\"encrypted_content\":\"checkpoint\"}")!.AsObject();
        var call = System.Text.Json.Nodes.JsonNode.Parse("{\"type\":\"function_call\",\"call_id\":\"new\",\"name\":\"read_file\",\"arguments\":\"{}\"}")!.AsObject();
        var old = System.Text.Json.Nodes.JsonNode.Parse("{\"type\":\"reasoning\",\"encrypted_content\":\"old\"}")!.AsObject();
        List<NativeMessage> messages = [
            new("system", "project security rules", SystemKind: "promptStable"),
            new("user", "fix code"),
            new("assistant", "retired text", ToolCalls: [new("old", "read_file", "{}"), new("new", "read_file", "{}")], ProviderItems: [old, checkpoint, call]),
            new("tool", "current source lines", "new"),
        ];
        var replay = NativePromptHistory.ResponsesReplay(messages);
        Assert.Equal(3, replay.Count);
        Assert.Equal(messages[0], replay[0]);
        Assert.Equal(new[] { "compaction", "function_call" }, replay[1].ProviderItems!.Select(item => item["type"]!.GetValue<string>()));
        Assert.Equal("new", replay[1].ToolCalls!.Single().Id);
        Assert.Equal("", replay[1].Content);
        Assert.Equal(messages.Last(), replay.Last());
        Assert.Equal(4, messages.Count);
    }

    [Fact]
    public void CodingBudgetLeavesVisibleRoomOnHighEffort()
    {
        var budget = EconomyPolicy.Resolve(
            NativeProviderProtocol.ChatGpt,
            "gpt-6-astra",
            "high",
            [new NativeMessage("user", "edit the project")],
            [new NativeToolDefinition("write_file", "write", new System.Text.Json.Nodes.JsonObject())]);

        Assert.True(budget.VisibleReserve >= 12_288);
        Assert.True(budget.MaxOutputTokens >= 25_600);
        Assert.Equal(0, budget.MaxOutputTokens % 512);
    }

    [Fact]
    public void ToolResultsAreBoundedAndMarked()
    {
        var result = EconomyPolicy.NormalizeToolOutput(
            string.Join('\n', Enumerable.Range(0, 5_000).Select(index => $"line-{index}")),
            "run_command");

        Assert.Contains(EconomyPolicy.ToolOutputMarker, result);
        Assert.True(result.Length <= EconomyPolicy.ToolOutputTokenLimit * 4 + EconomyPolicy.ToolOutputMarker.Length + 2_000);
    }

    [Fact]
    public void LongReadLinesReachTheModelIntact()
    {
        var output = string.Join('\n', Enumerable.Range(1, 40).Select(index => $"line-{index}-" + new string('x', 400)));
        var result = EconomyPolicy.NormalizeToolOutput(output, "read_file", "{\"offset\":100}");

        Assert.Equal(output, result);
    }

    [Fact]
    public void EconomyPruningDoesNotCreateSummaryCalls()
    {
        var messages = Enumerable.Range(0, 20)
            .SelectMany(index => new[]
            {
                new NativeMessage("user", $"request {index}"),
                new NativeMessage("assistant", $"answer {index}"),
            })
            .ToList();

        var pruned = EconomyPolicy.PruneContext(messages, 120);

        Assert.DoesNotContain(pruned, message => message.Content.Contains(ContextCompaction.SummaryMarker, StringComparison.Ordinal));
        Assert.True(pruned.Count < messages.Count);
    }

    [Fact]
    public void StrictOutputLimitIsNotExpandedIntoAReasoningRetry()
    {
        var budget = EconomyPolicy.Resolve(
            NativeProviderProtocol.Anthropic,
            "claude-3-7-sonnet",
            "high",
            [new NativeMessage("user", "En fazla 200 token kullan")],
            []);

        Assert.Equal(200, budget.MaxOutputTokens);
        Assert.Null(budget.ProviderReasoningBudgetTokens);
    }
}

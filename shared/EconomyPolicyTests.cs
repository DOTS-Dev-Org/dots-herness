using System.Text.Json.Nodes;
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
            Assert.Equal((int)(window * .90), standard.TriggerTokens);
            Assert.Equal((int)(window * .90), economy.TriggerTokens);
            Assert.True(standard.TargetTokens < standard.TriggerTokens);
            Assert.True(economy.TargetTokens < economy.TriggerTokens);
            Assert.Equal((int)(window * .90), ContextCompaction.NativeThreshold(window, 90));
        }
        Assert.Equal(1, ContextCompaction.NativeThreshold(1_000_000, 0));
    }

    [Fact]
    public void ProviderContextOverflowIsDistinctFromQuotaLimits()
    {
        Assert.True(new NativeProviderException("Anthropic: prompt is too long: 210000 tokens > 200000 maximum", 400).IsContextWindowExceeded);
        Assert.True(new NativeProviderException("This model's maximum context length is 128000 tokens.", 400).IsContextWindowExceeded);
        Assert.True(new NativeProviderException("context_length_exceeded", 400).IsContextWindowExceeded);
        Assert.False(new NativeProviderException("Rate limit reached for requests", 429).IsContextWindowExceeded);
        Assert.False(new NativeProviderException("You exceeded your current quota", 429).IsContextWindowExceeded);
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
    public void TaskHistoryCapturesOnlyNewEntriesUntilTheBacklogChanges()
    {
        static string History(string text) => "<task_history trust=\"data\">\n" + text + "\n</task_history>";
        const string backlog = "## Unfinished work (backlog)\n- `t1` — port the parser";
        var first = NativePromptHistory.Prepare([new NativeMessage("user", "one")], "policy",
            History("## Relevant task history\n- task A\n  Files: a.cs\n- task B\n\n" + backlog));
        Assert.Contains("task A", first.Last().Content);

        // A and B were captured already: only C is new.
        var second = NativePromptHistory.Prepare(first.Concat([new NativeMessage("user", "two")]).ToList(), "policy",
            History("## Relevant task history\n- task B\n- task C\n\n" + backlog));
        Assert.Equal(first, second.Take(first.Count));
        var added = second.Last().Content;
        Assert.Contains(NativePromptHistory.TaskHistoryAdditionsMarker, added);
        Assert.Contains("## Relevant task history\n- task C", added);
        Assert.DoesNotContain("task B", added);
        Assert.DoesNotContain("port the parser", added);

        // Nothing new: the section is not captured at all.
        var third = NativePromptHistory.Prepare(second.Concat([new NativeMessage("user", "three")]).ToList(), "policy",
            History("## Relevant task history\n- task A\n  Files: a.cs\n\n" + backlog));
        Assert.Equal("three", third.Last().Content);

        // A finished backlog item is state: the section is captured whole.
        var fourth = NativePromptHistory.Prepare(third.Concat([new NativeMessage("user", "four")]).ToList(), "policy",
            History("## Relevant task history\n- task A\n  Files: a.cs"));
        Assert.DoesNotContain(NativePromptHistory.TaskHistoryAdditionsMarker, fourth.Last().Content);
        Assert.Contains("task A", fourth.Last().Content);
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
    public void StrictTokenLimitCapsOnlyProseTurns()
    {
        var limit = new ResponseStyleDecision(AgentResponseStyle.Strict, MaxOutputTokens: 200);
        var prose = EconomyPolicy.Resolve(
            NativeProviderProtocol.ChatGpt,
            "gpt-6-astra",
            "low",
            [new NativeMessage("user", "explain a mutex")],
            [],
            limit);
        var coding = EconomyPolicy.Resolve(
            NativeProviderProtocol.ChatGpt,
            "gpt-6-astra",
            "low",
            [new NativeMessage("user", "edit the project")],
            [new NativeToolDefinition("write_file", "write", new System.Text.Json.Nodes.JsonObject())],
            limit);

        Assert.Equal(200, prose.MaxOutputTokens);
        Assert.True(coding.MaxOutputTokens > 200);
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

    [Fact]
    public void ReplayedProviderItemsAreNotDoubleCountedAndCiphertextIsDiscounted()
    {
        const string arguments = """{"path":"a.swift"}""";
        var calls = new[] { new NativeToolCall("call_1", "read_file", arguments) };
        var plain = new NativeMessage("assistant", "done", ToolCalls: calls);
        var replayed = plain with
        {
            ProviderItems =
            [
                new JsonObject { ["type"] = "function_call", ["call_id"] = "call_1", ["name"] = "read_file", ["arguments"] = arguments },
                new JsonObject { ["type"] = "message", ["content"] = new JsonArray(new JsonObject { ["type"] = "output_text", ["text"] = "done" }) },
                new JsonObject { ["type"] = "reasoning", ["id"] = "rs_1", ["encrypted_content"] = new string('A', 16_000) },
            ],
        };
        // 16 KB of ciphertext replays as ~1k reasoning tokens, not 4k.
        var extra = ContextCompaction.EstimateTokens(replayed) - ContextCompaction.EstimateTokens(plain);
        Assert.InRange(extra, 1_001, 1_049);
    }

    [Fact]
    public void ObservedInputIsTheProviderCountPlusOnlyTheNewEstimate()
    {
        // 245k counted for a request estimated at 260k; a 3k tool result was added since.
        Assert.Equal(248_000, ContextCompaction.ObservedInputTokens(263_000, 245_000, 260_000));
        // No counted baseline (new chat, route change, after compaction): full estimate.
        Assert.Equal(263_000, ContextCompaction.ObservedInputTokens(263_000, 245_000, 0));
        Assert.Equal(263_000, ContextCompaction.ObservedInputTokens(263_000, 0, 260_000));
    }
}

using Xunit;
using System.Net;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace DotsHarnessCore.Tests;

public sealed class ProjectSessionContractsTests
{
    [Fact]
    public void UnifiedCacheNamespaceSeparatesIdentityButNotResponseStyle()
    {
        var standard = AgentCacheNamespace.Create(
            "project",
            "model",
            planMode: false,
            contextRevision: 7,
            provider: "provider",
            api: "native-router",
            accountId: "account",
            toolFingerprint: "tools");
        var sameIdentity = AgentCacheNamespace.Create(
            "project",
            "model",
            planMode: false,
            contextRevision: 7,
            provider: "provider",
            api: "native-router",
            accountId: "account",
            toolFingerprint: "tools");
        var differentModel = AgentCacheNamespace.Create(
            "project",
            "other-model",
            planMode: false,
            contextRevision: 7,
            provider: "provider",
            api: "native-router",
            accountId: "account",
            toolFingerprint: "tools");

        Assert.StartsWith("herness:unified-v2:", standard, StringComparison.Ordinal);
        Assert.Equal(standard, sameIdentity);
        Assert.NotEqual(standard, differentModel);
    }

    [Fact]
    public void PromptContextRevisionIgnoresPerTurnResponseStyle()
    {
        var stable = new PromptSection("core_policy", PromptTrust.Core, "policy");
        var standard = AgentCacheNamespace.PromptContextRevision([stable]);
        var concise = AgentCacheNamespace.PromptContextRevision(
        [
            stable,
            new PromptSection("response_style", PromptTrust.Core, "short answer"),
        ]);
        var changed = AgentCacheNamespace.PromptContextRevision(
        [
            new PromptSection("core_policy", PromptTrust.Core, "changed policy"),
        ]);

        Assert.Equal(standard, concise);
        Assert.NotEqual(standard, changed);
    }
}

public sealed class CachePrefixContractTests
{
    private static NativeToolDefinition Tool(string json) => new("read", "Read a value", JsonNode.Parse(json)!);

    [Fact]
    public void NestedSchemaOrderIsCanonicalButArrayOrderRemainsMeaningful()
    {
        var a = Tool("""{"type":"object","properties":{"b":{"type":"string","description":"B"},"a":{"type":"integer"}}} """);
        var b = Tool("""{"properties":{"a":{"type":"integer"},"b":{"description":"B","type":"string"}},"type":"object"}""");
        Assert.Equal(AgentCacheNamespace.ToolFingerprint([a]), AgentCacheNamespace.ToolFingerprint([b]));
        Assert.Equal(AgentCacheNamespace.CanonicalTools([a])[0].Parameters.ToJsonString(),
            AgentCacheNamespace.CanonicalTools([b])[0].Parameters.ToJsonString());
        Assert.NotEqual(AgentCacheNamespace.CanonicalJson(JsonNode.Parse("[1,2]")),
            AgentCacheNamespace.CanonicalJson(JsonNode.Parse("[2,1]")));
        Assert.Throws<InvalidOperationException>(() => AgentCacheNamespace.CanonicalTools([a, b]));
    }

    [Fact]
    public void CatalogDisconnectCannotDeleteAcceptedToolsAndTrueChangesAdvanceEpoch()
    {
        var session = new NativeCacheSession();
        var tool = Tool("""{"type":"object"}""");
        Assert.Empty(session.SelectCatalog([], "policy", authoritative: false));
        Assert.Equal(0, session.Epoch);
        session.SelectCatalog([tool], "policy");
        var first = session.Epoch;
        Assert.Single(session.SelectCatalog([], "policy", authoritative: false));
        Assert.Equal(first, session.Epoch);
        session.SelectCatalog([tool], "policy");
        Assert.Equal(first, session.Epoch);
        session.SelectCatalog([], "policy");
        Assert.Empty(session.Catalog);
        Assert.Equal(first + 1, session.Epoch);
        session.SelectCatalog([], "new policy");
        Assert.Equal(first + 2, session.Epoch);
    }

    [Fact]
    public void SourceAndModeNoticesAppendOnceWithoutRewritingSentInput()
    {
        var session = new NativeCacheSession();
        var history = new List<NativeMessage> { new("user", "already sent"), new("assistant", "working") };
        Assert.True(session.AppendNotice(history, "source", "V2 changed"));
        Assert.False(session.AppendNotice(history, "source", "V2 changed"));
        Assert.True(session.AppendNotice(history, "source", "V2 missing"));
        Assert.False(session.AppendNotice(history, "source", null));
        Assert.True(session.AppendNotice(history, "source", "V2 changed"));
        Assert.Equal("already sent", history[0].Content);
        Assert.Equal(new[] { "already sent", "working", "V2 changed", "V2 missing", "V2 changed" }, history.Select(message => message.Content));
        var roundTrip = JsonSerializer.Deserialize<NativeCacheSession>(JsonSerializer.Serialize(session))!;
        Assert.False(roundTrip.AppendNotice(history, "source", "V2 changed"));
    }

    [Fact]
    public async Task ClaudeRetainsOldBoundaryBeyondLookupWindowAndMeasuresValidMisses()
    {
        using var fixture = new Fixture(NativeProviderProtocol.Anthropic, "claude-sonnet-5", (number, _) =>
            (HttpStatusCode.OK, Claude(number, number == 1 ? 0 : number == 2 ? 2000 : 0,
                number == 1 ? 2000 : number == 2 ? 500 : 3000)));
        var session = new NativeCacheSession();
        NativeToolDefinition[] tools = [Tool("""{"type":"object"}""")];
        var messages = new List<NativeMessage> { new("system", "policy", SystemKind: "promptStable"), new("user", "first") };
        await fixture.Send(messages, tools, session);
        session = JsonSerializer.Deserialize<NativeCacheSession>(JsonSerializer.Serialize(session))!;
        for (var i = 0; i < 24; i++)
        {
            messages.Add(new NativeMessage("assistant", $"step {i}"));
            messages.Add(new NativeMessage("user", $"result {i}"));
        }
        var hit = await fixture.Send(messages, tools, session);
        Assert.Equal(2000, hit.CacheReuseEvidence?.EligibleTokens);
        Assert.Equal(2000, hit.CacheReuseEvidence?.ReusedTokens);
        Assert.Equal("msg_1", fixture.Handler.Bodies[1]["diagnostics"]?["previous_message_id"]?.GetValue<string>());
        Assert.Equal(4, CountMarkers(fixture.Handler.Bodies[1]));
        Assert.NotNull(fixture.Handler.Bodies[1]["messages"]?[0]?["content"]?[0]?["cache_control"]);
        messages.Add(new NativeMessage("assistant", "again"));
        messages.Add(new NativeMessage("user", "new"));
        var miss = await fixture.Send(messages, tools, session);
        Assert.Equal("miss", miss.CacheReuseEvidence?.Classification);
        Assert.Equal(2500, miss.CacheReuseEvidence?.EligibleTokens);
        Assert.Equal(0, miss.CacheReuseEvidence?.ReusedTokens);
        Assert.Equal(2000d / 4500, session.Summary().ReuseRate);
        Assert.Equal(1d, session.Summary().ReuseMeasurementCoverage);
        Assert.Null(session.Summary().TotalCost);
    }

    [Fact]
    public async Task SmallerReportedExtentMeasuresLossAndRetainsOldProvenCheckpoint()
    {
        using var fixture = new Fixture(NativeProviderProtocol.Anthropic, "claude-sonnet-5",
            (number, _) => (HttpStatusCode.OK, Claude(number, 0, number == 1 ? 2000 : 500)));
        var session = new NativeCacheSession();
        var messages = new List<NativeMessage> { new("user", "first") };
        await fixture.Send(messages, [], session);
        var scope = session.Baselines.Keys.Single();
        var initial = session.Baselines[scope];
        messages.Add(new NativeMessage("assistant", "done"));
        messages.Add(new NativeMessage("user", "next"));
        var lost = await fixture.Send(messages, [], session);
        Assert.Equal(2000, lost.CacheReuseEvidence?.EligibleTokens);
        Assert.Equal(0, lost.CacheReuseEvidence?.ReusedTokens);
        Assert.Equal(initial, session.Baselines[scope]);
        await fixture.Send(messages, [], session);
        Assert.Equal("msg_2", fixture.Handler.Bodies[2]["diagnostics"]?["previous_message_id"]?.GetValue<string>());
        Assert.Equal(initial.WrittenAt, session.Baselines[scope].WrittenAt);
    }

    [Fact]
    public async Task ChangedSettingsExpiredPrefixesAndMissingCountersRemainExplicit()
    {
        using var fixture = new Fixture(NativeProviderProtocol.Anthropic, "claude-sonnet-5",
            (number, _) => (HttpStatusCode.OK, Claude(number, 0, 2000)));
        var session = new NativeCacheSession();
        NativeMessage[] messages = [new("user", "first")];
        await fixture.Send(messages, [], session);
        var key = session.Baselines.Keys.Single();
        session.Baselines[key] = session.Baselines[key] with { WrittenAt = DateTimeOffset.UtcNow.AddHours(-2) };
        var expired = await fixture.Send(messages, [], session);
        Assert.Equal("expired", expired.CacheReuseEvidence?.Classification);
        Assert.Null(expired.CacheReuseEvidence?.EligibleTokens);
        session.Baselines[key] = session.Baselines[key] with { TerminalCacheTokens = null };
        var missing = await fixture.Send(messages, [], session);
        Assert.Equal("terminal_boundary_tokens_not_reported", missing.CacheReuseEvidence?.Reason);
        fixture.Router.Effort = "low";
        var settings = await fixture.Send(messages, [], session);
        Assert.Equal("settings_changed", settings.CacheReuseEvidence?.Reason);
        Assert.Null(settings.CacheReuseEvidence?.ReusedTokens);
    }

    [Fact]
    public async Task PublicOpenAiStaticBreakpointAndDiagnosticsCoexistButGatewayStaysPinned()
    {
        using var direct = new Fixture(NativeProviderProtocol.OpenAiResponses, "gpt-5.6-luna",
            (number, _) => (HttpStatusCode.OK, Responses(number)), "https://api.openai.com/v1");
        var session = new NativeCacheSession();
        NativeMessage[] messages = [new("system", "stable policy", SystemKind: "promptStable"), new("user", "hello")];
        await direct.Send(messages, [], session);
        var result = await direct.Send(messages, [], session);
        var body = direct.Handler.Bodies[1];
        Assert.Null(body["instructions"]);
        Assert.Equal("explicit", body["input"]?[0]?["content"]?[0]?["prompt_cache_breakpoint"]?["mode"]?.GetValue<string>());
        Assert.Equal("implicit", body["prompt_cache_options"]?["mode"]?.GetValue<string>());
        Assert.Equal("30m", body["prompt_cache_options"]?["ttl"]?.GetValue<string>());
        Assert.Equal("resp_1", body["prompt_cache_options"]?["comparison_response_id"]?.GetValue<string>());
        // Read-only usage does not prove the cached extent of this request.
        Assert.Null(result.CacheReuseEvidence?.EligibleTokens);
        Assert.Null(result.CacheReuseEvidence?.ReusedTokens);
        using var gateway = new Fixture(NativeProviderProtocol.ChatGpt, "gpt-5.6-luna",
            (number, _) => (HttpStatusCode.OK, Responses(number)), "https://chatgpt.com/backend-api/codex");
        await gateway.Send(messages, [], new NativeCacheSession());
        Assert.Equal(CodexInstructions.Default, gateway.Handler.Bodies[0]["instructions"]?.GetValue<string>());
        Assert.Null(gateway.Handler.Bodies[0]["input"]?[0]?["content"]?[0]?["prompt_cache_breakpoint"]);
    }

    [Fact]
    public async Task ReadOnlyCountersNeverProveWholeInputBaseline()
    {
        using var gateway = new Fixture(NativeProviderProtocol.OpenAiResponses, "gpt-5.6-luna",
            (number, _) => (HttpStatusCode.OK, Responses(number)
                .Replace("\"cached_tokens\":1000", "\"cached_tokens\":" + (number == 2 ? 2000 : 0))));
        var session = new NativeCacheSession();
        var messages = new List<NativeMessage> { new("user", "first") };
        var cold = await gateway.Send(messages, [], session);
        Assert.Equal("cold", cold.CacheReuseEvidence?.Classification);
        messages.Add(new NativeMessage("assistant", "done"));
        messages.Add(new NativeMessage("user", "next"));
        var hit = await gateway.Send(messages, [], session);
        Assert.Null(hit.CacheReuseEvidence?.EligibleTokens);
        Assert.Null(hit.CacheReuseEvidence?.ReusedTokens);
        messages[0] = new NativeMessage("user", "rewritten");
        var lost = await gateway.Send(messages, [], session);
        Assert.Null(lost.CacheReuseEvidence?.EligibleTokens);
        Assert.Null(lost.CacheReuseEvidence?.ReusedTokens);
        Assert.Null(session.Summary().ReuseRate);
        Assert.Equal(0d, session.Summary().ReuseMeasurementCoverage);
    }

    [Fact]
    public async Task ShortPromptKeepsVerbosityAndSavedShortStyleSetsIt()
    {
        using var fixture = new Fixture(NativeProviderProtocol.OpenAiResponses, "gpt-5.6-luna",
            (number, _) => (HttpStatusCode.OK, Responses(number)));
        NativeMessage[] messages = [new("user", "en fazla 200 token kullan")];
        await fixture.Send(messages, [], new NativeCacheSession());
        Assert.Null(fixture.Handler.Bodies[0]["text"]);
        Assert.NotNull(fixture.Handler.Bodies[0]["max_output_tokens"]);
        fixture.Router.ResponseStylePreference = AgentResponseStylePreference.Concise;
        await fixture.Send(messages, [], new NativeCacheSession());
        Assert.Equal("low", fixture.Handler.Bodies[1]["text"]?["verbosity"]?.GetValue<string>());
    }

    [Fact]
    public async Task PublicOpenAiReportsExactEligibleReuseOnlyWithBothTerminalCounters()
    {
        using var direct = new Fixture(NativeProviderProtocol.OpenAiResponses, "gpt-5.6-luna",
            (number, _) => (HttpStatusCode.OK, Responses(number).Replace("\"input_tokens\":2000", "\"input_tokens\":" + (number == 1 ? 2000 : 3000))
                .Replace("\"cached_tokens\":1000", "\"cached_tokens\":" + (number == 1 ? 0 : 2000) + ",\"cache_write_tokens\":" + (number == 1 ? 2000 : 1000))),
            "https://api.openai.com/v1");
        var session = new NativeCacheSession();
        var messages = new List<NativeMessage> { new("system", "policy", SystemKind: "promptStable"), new("user", "first") };
        await direct.Send(messages, [], session);
        session = JsonSerializer.Deserialize<NativeCacheSession>(JsonSerializer.Serialize(session))!;
        messages.Add(new NativeMessage("assistant", "done"));
        messages.Add(new NativeMessage("user", "next"));
        var hit = await direct.Send(messages, [], session);
        Assert.Equal(2000, hit.CacheReuseEvidence?.EligibleTokens);
        Assert.Equal(2000, hit.CacheReuseEvidence?.ReusedTokens);
        Assert.Equal(1800, hit.EffectiveCacheTTLSeconds);
        Assert.Equal(1, session.Summary().ReuseRate);
    }

    [Theory]
    [InlineData("gpt-5.5", false, 1000, 1000, "retention_not_verified")]
    [InlineData("gpt-5.6-luna", true, 1000, 1000, "terminal_boundary_tokens_not_reported")]
    [InlineData("gpt-5.6-luna", false, 1000, 1500, "terminal_boundary_tokens_not_reported")]
    [InlineData("gpt-5.6-luna", false, -1, 2000, "terminal_boundary_tokens_not_reported")]
    public async Task OlderModelsAssistantTailsAndInvalidTotalsCannotClaimExactReuse(
        string model, bool assistantTail, int read, int write, string reason)
    {
        using var fixture = new Fixture(NativeProviderProtocol.OpenAiResponses, model,
            (number, _) => (HttpStatusCode.OK, Responses(number).Replace("\"cached_tokens\":1000",
                "\"cached_tokens\":" + read + ",\"cache_write_tokens\":" + write)), "https://api.openai.com/v1");
        var session = new NativeCacheSession();
        var messages = new List<NativeMessage> { new("user", "first") };
        if (assistantTail) messages.Add(new NativeMessage("assistant", "already done"));
        await fixture.Send(messages, [], session);
        messages.Add(new NativeMessage("user", "next"));
        var result = await fixture.Send(messages, [], session);
        Assert.Equal(reason, result.CacheReuseEvidence?.Reason);
        Assert.Null(result.CacheReuseEvidence?.EligibleTokens);
        Assert.Null(result.CacheReuseEvidence?.ReusedTokens);
    }

    [Theory]
    [InlineData("prompt_cache_breakpoint")]
    [InlineData("diagnostics")]
    [InlineData("ttl")]
    public async Task UnsupportedOptionalFieldsRetryOnceAndDoNotRepeat(string field)
    {
        var protocol = field == "prompt_cache_breakpoint" ? NativeProviderProtocol.OpenAiResponses : NativeProviderProtocol.Anthropic;
        using var fixture = new Fixture(protocol, protocol == NativeProviderProtocol.Anthropic ? "claude-sonnet-5" : "gpt-5.6-luna",
            (number, _) => number == 1
                ? (HttpStatusCode.BadRequest, "{\"error\":{\"message\":\"Unsupported " + field + "\"}}")
                : (HttpStatusCode.OK, protocol == NativeProviderProtocol.Anthropic ? Claude(number, 0, 2000) : Responses(number)),
            protocol == NativeProviderProtocol.OpenAiResponses ? "https://api.openai.com/v1" : null);
        var session = new NativeCacheSession();
        NativeMessage[] messages = [new("system", "policy", SystemKind: "promptStable"), new("user", "hello")];
        var first = await fixture.Send(messages, [], session);
        Assert.Equal(2, fixture.Handler.Bodies.Count);
        await fixture.Send(messages, [], session);
        Assert.Equal(3, fixture.Handler.Bodies.Count);
        if (field == "ttl") Assert.Equal(300, first.EffectiveCacheTTLSeconds);
        if (field == "diagnostics") Assert.Null(fixture.Handler.Bodies[2]["diagnostics"]);
        if (field == "prompt_cache_breakpoint") Assert.NotNull(fixture.Handler.Bodies[2]["instructions"]);
    }

    [Fact]
    public async Task CacheMarkersDoNotStripReservedNamesFromToolSchemasOrArguments()
    {
        using var fixture = new Fixture(NativeProviderProtocol.Anthropic, "claude-sonnet-5",
            (number, _) => (HttpStatusCode.OK, Claude(number, 0, 2000)));
        NativeToolDefinition[] tools = [Tool("""{"type":"object","properties":{"cache_control":{"type":"string"},"prompt_cache_breakpoint":{"type":"string"}}}""")];
        NativeMessage[] messages = [new("assistant", "", ToolCalls: [new("call", "read", "{\"cache_control\":\"user argument\"}")]),
            new("tool", "result", ToolCallId: "call")];
        await fixture.Send(messages, tools, new NativeCacheSession());
        var body = fixture.Handler.Bodies[0];
        Assert.NotNull(body["tools"]?[0]?["input_schema"]?["properties"]?["cache_control"]);
        Assert.Equal("user argument", body["messages"]?[0]?["content"]?[0]?["input"]?["cache_control"]?.GetValue<string>());
    }

    [Fact]
    public async Task AccountAndConversationScopesCannotBorrowAnotherWrittenPrefix()
    {
        using var fixture = new Fixture(NativeProviderProtocol.Anthropic, "claude-sonnet-5",
            (number, _) => (HttpStatusCode.OK, Claude(number, 0, 2000)));
        var session = new NativeCacheSession();
        NativeMessage[] messages = [new("user", "first")];
        await fixture.Send(messages, [], session);
        var otherConversation = await fixture.Router.CompleteAsync(messages, [], fixture.Account.Model,
            promptCacheKey: "other", cacheComparisonScope: "other", cacheSession: session);
        Assert.Equal("no_accepted_baseline", otherConversation.CacheReuseEvidence?.Reason);
        Assert.Null(fixture.Handler.Bodies[1]["diagnostics"]?["previous_message_id"]);
        Assert.Equal(2, session.Baselines.Count);
    }

    [Fact]
    public async Task FailedRequestsCannotCreateAcceptedCacheBoundary()
    {
        using var fixture = new Fixture(NativeProviderProtocol.Anthropic, "claude-sonnet-5",
            (_, _) => (HttpStatusCode.BadRequest, "{\"error\":{\"message\":\"invalid request\"}}"));
        var session = new NativeCacheSession();
        await Assert.ThrowsAsync<NativeProviderException>(() => fixture.Send([new("user", "hello")], [], session));
        Assert.Empty(session.Baselines);
        Assert.Empty(session.Events);
    }

    [Fact]
    public void ClaudeStreamRetainsSignedThinkingAndDiagnosticsAreOnlyEstimates()
    {
        const string stream = """
        data: {"type":"message_start","message":{"id":"msg_stream","role":"assistant","content":[],"usage":{"input_tokens":1,"cache_read_input_tokens":0,"cache_creation_input_tokens":2000},"diagnostics":{"cache_miss_reason":{"type":"messages_changed","cache_missed_input_tokens":99}}}}
        data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":"","signature":""}}
        data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"reason"}}
        data: {"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"signed"}}
        data: {"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}
        data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"OK"}}
        data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":2}}
        """;
        var result = NativeProviderRouter.ParseAnthropicStream(stream);
        Assert.Equal("msg_stream", result.ResponseId);
        Assert.Equal("signed", result.Message.ProviderItems?[0]["signature"]?.GetValue<string>());
        Assert.Equal("messages_changed", result.CacheDiagnostics?.Reason);
        Assert.Equal(99, result.CacheDiagnostics?.MissedTokens);
        Assert.Null(result.CacheReuseEvidence);
        Assert.Equal(2000, result.Usage?.CacheWriteTokens);
    }

    [Fact]
    public void RollingSummaryIncludesValidMissesAndReportsUnknownCostAndCoverage()
    {
        var session = new NativeCacheSession();
        for (var i = 0; i < 120; i++)
            session.AppendEvent(new NativeCacheUsageEvent(i.ToString(), DateTimeOffset.UtcNow, "scope",
                i % 2 == 0 ? new NativeUsage(100, 1, 0) : new NativeUsage(100, 1),
                new NativeCacheReuseEvidence(null, "prefix", "settings", "unknown", "missing", "none"), 10));
        Assert.Equal(100, session.Events.Count);
        var summary = session.Summary();
        Assert.Equal(50, summary.MeasuredInputCount);
        Assert.Equal(0, summary.RawHitRate);
        Assert.Null(summary.ReuseRate);
        Assert.Equal(0, summary.ReuseMeasurementCoverage);
        Assert.Equal(1000, summary.TotalLatencyMilliseconds);
        Assert.Null(summary.TotalCost);
        Assert.Null(new NativeUsage(100, 1, CacheWriteTokens: 50).CacheHitRate);
    }

    [Fact]
    public async Task RejectedPublicRetentionPreservesExplicitBreakpointAndComparison()
    {
        using var direct = new Fixture(NativeProviderProtocol.OpenAiResponses, "gpt-5.6-luna",
            (number, _) => number == 2
                ? (HttpStatusCode.UnprocessableEntity, "{\"error\":{\"message\":\"prompt_cache_options.ttl is not supported\"}}")
                : (HttpStatusCode.OK, Responses(number)), "https://api.openai.com/v1");
        var session = new NativeCacheSession();
        NativeMessage[] messages = [new("system", "stable policy", SystemKind: "promptStable"), new("user", "hello")];
        await direct.Send(messages, [], session);
        var result = await direct.Send(messages, [], session);
        Assert.Equal(3, direct.Handler.Bodies.Count);
        var retry = direct.Handler.Bodies[2];
        Assert.Equal("explicit", retry["input"]?[0]?["content"]?[0]?["prompt_cache_breakpoint"]?["mode"]?.GetValue<string>());
        Assert.Equal("resp_1", retry["prompt_cache_options"]?["comparison_response_id"]?.GetValue<string>());
        Assert.Null(retry["prompt_cache_options"]?["ttl"]);
        Assert.Null(result.EffectiveCacheTTLSeconds);
    }

    [Fact]
    public void RouteWithoutRetentionWarnsOnlyWhenACachedPrefixDrops()
    {
        var session = new NativeCacheSession();
        void Add(int cached, string classification = "unknown") => session.AppendEvent(
            new NativeCacheUsageEvent(Guid.NewGuid().ToString(), DateTimeOffset.UtcNow, "scope", new NativeUsage(40_000, 1, cached),
                new NativeCacheReuseEvidence(null, "prefix", "settings", classification, "retention_not_verified", "none")));
        Add(0);
        Assert.Null(session.ExpiredLargePrefixTokens(DateTimeOffset.UtcNow)); // first request: nothing was cached yet
        Add(36_000);
        Assert.Null(session.ExpiredLargePrefixTokens(DateTimeOffset.UtcNow));
        Add(0, "changed");
        Assert.Null(session.ExpiredLargePrefixTokens(DateTimeOffset.UtcNow)); // compaction rewrote the prefix
        Add(500);
        Assert.Equal(40_000, session.ExpiredLargePrefixTokens(DateTimeOffset.UtcNow));
        Add(36_000);
        Assert.Null(session.ExpiredLargePrefixTokens(DateTimeOffset.UtcNow.AddMinutes(59)));
        Assert.Equal(40_000, session.ExpiredLargePrefixTokens(DateTimeOffset.UtcNow.AddMinutes(61))); // idle past an hour
    }

    [Fact]
    public void LocalRouteWarnsWhenAnotherChatTookTheServerNotAfterIdleTime()
    {
        var started = DateTimeOffset.UtcNow;
        static NativeCacheUsageEvent Local(DateTimeOffset at, int cached) => new(Guid.NewGuid().ToString(), at, "scope",
            new NativeUsage(40_000, 1, cached), new NativeCacheReuseEvidence(null, "prefix", "settings", "unknown", "retention_not_verified", "none"),
            RouteFingerprint: "local-server", Local: true);
        var chat = new NativeCacheSession();
        var other = new NativeCacheSession();
        chat.AppendEvent(Local(started, 0));
        chat.AppendEvent(Local(started.AddSeconds(10), 36_000));
        NativeCacheSession[] all = [chat, other];
        Assert.Null(chat.ExpiredLargePrefixTokens(started.AddHours(3), others: all)); // idle time alone says nothing
        other.AppendEvent(Local(started.AddSeconds(5), 0));
        Assert.Null(chat.ExpiredLargePrefixTokens(started.AddHours(3), others: all)); // before our last request
        other.AppendEvent(Local(started.AddMinutes(1), 0));
        Assert.Equal(40_000, chat.ExpiredLargePrefixTokens(started.AddMinutes(2), others: all));
    }

    [Fact]
    public void RollingReuseKeepsRoutesSeparateAndRejectsInvalidCounters()
    {
        var session = new NativeCacheSession();
        void Add(string scope, int? eligible, int? reused, string classification = "hit") => session.AppendEvent(
            new NativeCacheUsageEvent(Guid.NewGuid().ToString(), DateTimeOffset.UtcNow, scope, null,
                new NativeCacheReuseEvidence(null, "prefix", "settings", classification, "cache_evicted", "provider", eligible, reused)));
        Add("one", 1000, 0, "miss");
        for (var index = 0; index < 100; index++) Add("two", 1000, 1000);
        Add("one", 1000, 1001);
        var routes = session.SummariesByRoute();
        Assert.Equal(1, routes["two"].ReuseRate);
        Assert.Equal(0, routes["one"].ReuseRate);
        Assert.Equal(0.5, session.Summary().ReuseMeasurementCoverage);
        Assert.Equal(1000, session.Summary().LostTokensByReason["cache_evicted"]);
    }

    private static int CountMarkers(JsonNode? node) => node switch
    {
        JsonObject obj => (obj.ContainsKey("cache_control") ? 1 : 0) + obj.Sum(pair => CountMarkers(pair.Value)),
        JsonArray array => array.Sum(CountMarkers),
        _ => 0,
    };

    private static string Claude(int number, int read, int write) => "{\"id\":\"msg_" + number
        + "\",\"content\":[{\"type\":\"text\",\"text\":\"OK\"}],\"usage\":{\"input_tokens\":10,\"output_tokens\":1,\"cache_read_input_tokens\":"
        + read + ",\"cache_creation_input_tokens\":" + write + "}}";
    private static string Responses(int number) => "{\"id\":\"resp_" + number
        + "\",\"output\":[{\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\"OK\"}]}],\"usage\":{\"input_tokens\":2000,\"output_tokens\":1,\"input_tokens_details\":{\"cached_tokens\":1000}}}";

    private sealed class Fixture : IDisposable
    {
        private readonly string root = Path.Combine(Path.GetTempPath(), "cache-prefix-" + Guid.NewGuid());
        internal NativeProviderRouter Router { get; }
        internal RecordingHandler Handler { get; }
        internal NativeProviderAccount Account { get; }
        internal Fixture(NativeProviderProtocol protocol, string model,
            Func<int, JsonObject, (HttpStatusCode Status, string Body)> respond, string? endpoint = null)
        {
            var secrets = new MemoryProviderSecretStore();
            var store = new NativeProviderStore(root, secrets);
            Account = new NativeProviderAccount { Provider = "cache-test", Protocol = protocol,
                Model = model, Models = [model], BaseUrl = endpoint ?? "https://example.test/v1",
                CredentialId = Guid.NewGuid().ToString(), SessionAccountId = "synthetic-account" };
            secrets.Write(Account.CredentialId, "synthetic-test-secret");
            store.State.Accounts.Add(Account);
            Handler = new RecordingHandler(respond);
            Router = new NativeProviderRouter(store, http: new HttpClient(Handler));
        }
        internal Task<NativeResponse> Send(IReadOnlyList<NativeMessage> messages, IReadOnlyList<NativeToolDefinition> tools,
            NativeCacheSession session) => Router.CompleteAsync(messages, tools, Account.Model,
                promptCacheKey: "conversation", cacheComparisonScope: "conversation", cacheSession: session);
        public void Dispose() { if (Directory.Exists(root)) Directory.Delete(root, true); }
    }
    private sealed class RecordingHandler(Func<int, JsonObject, (HttpStatusCode Status, string Body)> respond) : HttpMessageHandler
    {
        internal List<JsonObject> Bodies { get; } = [];
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            var body = JsonNode.Parse(await request.Content!.ReadAsStringAsync(cancellationToken))!.AsObject();
            Bodies.Add(body);
            var result = respond(Bodies.Count, body);
            return new HttpResponseMessage(result.Status) { Content = new StringContent(result.Body) };
        }
    }
}

// Copyright (c) 2026 DOTS

using System;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Text.Json.Nodes;
using DotsHarnessCore;
using Xunit;

namespace DotsHarness.Tests;

public sealed class RouterApiTests
{
    [Fact]
    public void CacheAccountingIncludesWritesAndDistinguishesUnknownFromZero()
    {
        Assert.Equal(7834d / 8605, new NativeUsage(2, 0, 7834, 769, InputExcludesCache: true).CacheHitRate);
        Assert.Equal(0, new NativeUsage(100, 0, 0).CacheHitRate);
        Assert.Null(new NativeUsage(100, 0).CacheHitRate);
    }

    [Fact]
    public void CacheDiagnosticsAreReadFromResponsesStream()
    {
        const string stream = "data: {\"type\":\"response.output_text.delta\",\"delta\":\"OK\"}\n\ndata: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_next\",\"output\":[],\"prompt_cache_diagnostics\":{\"type\":\"cache_miss\",\"reason\":\"tools_changed\"}}}\n\n";
        var response = NativeProviderRouter.ParseResponsesStream(stream);
        Assert.Equal("resp_next", response.ResponseId);
        Assert.Equal("tools_changed", response.CacheDiagnostics?.Reason);
    }

    [Fact]
    public async Task CacheComparisonsSurviveKeyAndModelChangesAndIsolateAccounts()
    {
        var root = Path.Combine(Path.GetTempPath(), $"DotsHarnessCacheComparison-{Guid.NewGuid()}");
        try
        {
            var store = new NativeProviderStore(root, new MemoryProviderSecretStore());
            var first = new NativeProviderAccount {
                Provider = "cache-test", BaseUrl = "https://example.test/v1", Model = "gpt-6-luna",
                Models = ["gpt-6-luna", "gpt-6-astra"], Protocol = NativeProviderProtocol.OpenAiResponses,
            };
            var other = new NativeProviderAccount {
                Provider = first.Provider, BaseUrl = first.BaseUrl, Model = first.Model,
                Models = first.Models, Protocol = first.Protocol,
            };
            store.State.Accounts.AddRange([first, other]);
            var handler = new CacheComparisonHandler();
            var router = new NativeProviderRouter(store, http: new HttpClient(handler));
            NativeMessage[] messages = [new("user", "one")];
            await router.CompleteAsync(messages, [], first.Model, promptCacheKey: "old-tools",
                preferredAccountId: first.Id, cacheComparisonScope: "conversation");
            await router.CompleteAsync(messages, [], first.Model, promptCacheKey: "new-tools",
                preferredAccountId: first.Id, cacheComparisonScope: "conversation");
            await router.CompleteAsync(messages, [], "gpt-6-astra", promptCacheKey: "new-model",
                preferredAccountId: first.Id, cacheComparisonScope: "conversation");
            await router.CompleteAsync(messages, [], first.Model, promptCacheKey: "other-account",
                preferredAccountId: other.Id, cacheComparisonScope: "conversation");
            Assert.Equal(4, handler.Bodies.Count);
            Assert.Null(handler.Bodies[0]["prompt_cache_options"]);
            Assert.Equal("resp_next", handler.Bodies[1]["prompt_cache_options"]?["comparison_response_id"]?.GetValue<string>());
            Assert.Equal("resp_next", handler.Bodies[2]["prompt_cache_options"]?["comparison_response_id"]?.GetValue<string>());
            Assert.Null(handler.Bodies[3]["prompt_cache_options"]);
        }
        finally { if (Directory.Exists(root)) Directory.Delete(root, recursive: true); }
    }

    private sealed class CacheComparisonHandler : HttpMessageHandler
    {
        public System.Collections.Generic.List<JsonNode> Bodies { get; } = [];
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, System.Threading.CancellationToken ct)
        {
            Bodies.Add(JsonNode.Parse(await request.Content!.ReadAsStringAsync(ct))!);
            return new HttpResponseMessage(HttpStatusCode.OK) {
                Content = new StringContent("""{"id":"resp_next","output":[{"type":"message","content":[{"type":"output_text","text":"OK"}]}],"usage":{"input_tokens":100,"output_tokens":1,"input_tokens_details":{"cached_tokens":80}}}"""),
            };
        }
    }
    [Theory]
    [InlineData(NativeProviderProtocol.OpenAiCompatible)]
    [InlineData(NativeProviderProtocol.ChatGpt)]
    [InlineData(NativeProviderProtocol.Anthropic)]
    public async Task PromptSnapshotsPreserveWirePrefixAcrossTurnsAndReload(NativeProviderProtocol protocol)
    {
        var root = Path.Combine(Path.GetTempPath(), $"DotsHarnessPrefixTests-{Guid.NewGuid()}");
        try
        {
            var secrets = new MemoryProviderSecretStore();
            var store = new NativeProviderStore(root, secrets);
            var account = new NativeProviderAccount
            {
                Provider = "prefix-test", ProviderName = "prefix-test", Name = "prefix-test",
                Protocol = protocol, Model = "test", Models = ["test"],
                BaseUrl = "https://example.test/v1", CredentialId = "prefix-secret",
                SessionAccountId = "test-account",
                AuthType = protocol == NativeProviderProtocol.ChatGpt ? "chatgpt" : "apiKey",
            };
            store.State.Accounts.Add(account);
            secrets.Write(account.CredentialId, "test-only");
            var handler = new LanguagePolicyRecordingHandler(protocol);
            var router = new NativeProviderRouter(store, http: new HttpClient(handler));
            var first = NativePromptHistory.Prepare([new NativeMessage("user", "first")], "policy", "state one");
            await router.CompleteAsync(first, [], "test");
            var before = JsonNode.Parse(handler.Body)!;
            var restored = System.Text.Json.JsonSerializer.Deserialize<NativeMessage[]>(System.Text.Json.JsonSerializer.Serialize(first))!;
            Assert.Equal(first, NativePromptHistory.Prepare(restored, "policy", "retry state"));
            var next = NativePromptHistory.Prepare([.. restored, new("assistant", "answer"), new("user", "second")], "policy", "state two");
            Assert.Equal(first, next.Take(first.Count));
            Assert.Equal("state two\n\nsecond", next.Last().Content);
            await router.CompleteAsync(next, [], "test");
            var after = JsonNode.Parse(handler.Body)!;
            var field = protocol == NativeProviderProtocol.ChatGpt ? "input" : "messages";
            StripCacheDirectives(before);
            StripCacheDirectives(after);
            var oldItems = before[field]!.AsArray();
            var newItems = after[field]!.AsArray();
            for (var index = 0; index < oldItems.Count; index++)
                Assert.True(JsonNode.DeepEquals(oldItems[index], newItems[index]), protocol.ToString());
            Assert.True(JsonNode.DeepEquals(before["system"], after["system"]));
            Assert.True(JsonNode.DeepEquals(before["instructions"], after["instructions"]));
        }
        finally
        {
            if (Directory.Exists(root)) Directory.Delete(root, recursive: true);
        }
    }

    private static void StripCacheDirectives(JsonNode? node)
    {
        if (node is JsonObject obj)
        {
            obj.Remove("cache_control");
            foreach (var pair in obj) StripCacheDirectives(pair.Value);
        }
        else if (node is JsonArray array)
            foreach (var item in array) StripCacheDirectives(item);
    }

    [Fact]
    public void PromptSnapshotsPreserveToolResultsAndCompactionSummary()
    {
        var first = NativePromptHistory.Prepare([new("system", "legacy policy"), new("user", "first")], "policy", "state one");
        var history = first.Concat(new NativeMessage[] {
            new("assistant", "", ToolCalls: [new("call", "skill.read", "{}")]),
            new("tool", "original skill content", ToolCallId: "call"),
        }).ToList();
        Assert.Equal(history, NativePromptHistory.Prepare(history, "policy", "tool retry"));
        var summary = new NativeMessage("system", ContextCompaction.SummaryMarker + "\nsummary");
        var compacted = NativePromptHistory.Prepare([first[0], summary, first[1], new("user", "next")], "policy", "state two");
        Assert.Equal(summary, compacted[1]);
        Assert.Equal(first[1], compacted[2]);
        Assert.DoesNotContain("state two", compacted[2].Content);
    }

    [Fact]
    public void EffortCatalogResolvesPrefixedIdsAndRejectsUnknownModels()
    {
        Assert.Equal(new[] { "low", "medium", "high", "xhigh", "max" }, NativeEffortCatalog.Levels("claude/claude-opus-5"));
        Assert.Contains("none", NativeEffortCatalog.Levels("gpt-5.5"));
        Assert.Empty(NativeEffortCatalog.Levels("llama3"));
        Assert.Empty(NativeEffortCatalog.Levels(""));
    }

    [Fact]
    public void CatalogUsesCanonicalNamesAndLocalLogoKeys()
    {
        var ids = RouterCatalog.Providers.Select(provider => provider.Id).ToHashSet(StringComparer.Ordinal);
        Assert.Contains("gpt", ids);
        Assert.Contains("openai", ids);
        Assert.Contains("claude", ids);
        Assert.Contains("deepseek", ids);
        Assert.All(RouterCatalog.Providers, provider =>
        {
            Assert.False(string.IsNullOrWhiteSpace(provider.Name));
            Assert.False(string.IsNullOrWhiteSpace(provider.LogoKey));
            Assert.DoesNotContain("CLI", provider.Name, StringComparison.OrdinalIgnoreCase);
            Assert.DoesNotContain("/", provider.Name);
            Assert.DoesNotContain("·", provider.Name);
        });
        Assert.Equal(RouterAuthKind.OauthBrowser, RouterCatalog.KindFor("gpt")?.Kind);
        Assert.Equal(NativeProviderProtocol.ChatGpt, RouterCatalog.KindFor("gpt")?.Protocol);
        Assert.Equal(RouterAuthKind.ApiKey, RouterCatalog.KindFor("openai")?.Kind);
    }

    [Fact]
    public void ConsumerLoginAndApiKeyAreSeparateProviderAccounts()
    {
        var consumer = new NativeProviderAccount { Provider = "gpt", AuthType = "chatgpt", Protocol = NativeProviderProtocol.ChatGpt, SessionAccountId = "account-1", Name = "GPT account" };
        var api = new NativeProviderAccount { Provider = "openai", AuthType = "apiKey", Name = "OpenAI API" };

        Assert.NotEqual(consumer.Provider, api.Provider);
        Assert.Equal("ChatGPT", RouterCatalog.LabelFor(consumer.Provider));
        Assert.Equal("OpenAI", RouterCatalog.LabelFor(api.Provider));
        Assert.Equal("account-1", consumer.SessionAccountId);
    }

    [Fact]
    public void CustomEndpointsUseGenericLabelAndValidatedUrls()
    {
        Assert.Equal("Custom API", RouterCatalog.LabelFor("custom:endpoint"));
        Assert.Equal("http://127.0.0.1:11434/v1", NativeProviderStore.NormalizeUrl("http://127.0.0.1:11434/v1/v1"));
        Assert.Throws<NativeProviderException>(() => NativeProviderStore.NormalizeUrl("https://user:pass@example.com/v1"));
    }

    [Fact]
    public void SecretsStayOutsideProviderStateJson()
    {
        var root = Path.Combine(Path.GetTempPath(), $"DotsHarnessTests-{Guid.NewGuid()}");
        try
        {
            var secrets = new MemoryProviderSecretStore();
            var store = new NativeProviderStore(root, secrets);
            store.AddAccount(RouterCatalog.Descriptor(RouterCatalog.KindFor("openai")!), "Work", "secret-value");

            var state = File.ReadAllText(Path.Combine(root, "provider-state.json"));
            Assert.DoesNotContain("secret-value", state, StringComparison.Ordinal);
            Assert.Equal("secret-value", secrets.Read(store.State.Accounts[0].CredentialId));
        }
        finally
        {
            if (Directory.Exists(root)) Directory.Delete(root, recursive: true);
        }
    }

    [Fact]
    public void TunnelPrefersPublicUrl()
    {
        var tunnel = new RouterTunnel(true, true, "http://127.0.0.1:18767/v1", "https://share.example", "share", false, 100);
        Assert.Equal("https://share.example", tunnel.ShareUrl);
        Assert.Equal("share", tunnel.ShortId);
    }

    [Fact]
    public async Task ChatGptSessionUsesResponsesTransport()
    {
        var root = Path.Combine(Path.GetTempPath(), $"DotsHarnessTests-{Guid.NewGuid()}");
        try
        {
            var store = new NativeProviderStore(root, new MemoryProviderSecretStore());
            store.AddAccount(RouterCatalog.Descriptor(RouterCatalog.KindFor("gpt")!), "GPT", "session-token", authType: "chatgpt", sessionAccountId: "account-1");
            var handler = new RecordingHandler();
            var router = new NativeProviderRouter(store, http: new HttpClient(handler));

            var response = await router.CompleteAsync([new NativeMessage("user", "hello")], []);

            Assert.Equal("ready", response.Message.Content);
            Assert.Equal("https://chatgpt.com/backend-api/codex/responses", handler.Request?.RequestUri?.AbsoluteUri);
            Assert.Equal("session-token", handler.Request?.Headers.Authorization?.Parameter);
            Assert.Equal("account-1", handler.Request?.Headers.GetValues("ChatGPT-Account-ID").Single());
            var body = JsonNode.Parse(handler.Body)!.AsObject();
            Assert.Null(body["messages"]);
            Assert.False(body["store"]!.GetValue<bool>());
        }
        finally
        {
            if (Directory.Exists(root)) Directory.Delete(root, recursive: true);
        }
    }

    [Theory]
    [InlineData(NativeProviderProtocol.Anthropic)]
    [InlineData(NativeProviderProtocol.OpenAiCompatible)]
    [InlineData(NativeProviderProtocol.ChatGpt)]
    public async Task ProviderTransportsCarryTheSameResponseLanguagePolicy(NativeProviderProtocol protocol)
    {
        var root = Path.Combine(Path.GetTempPath(), $"DotsHarnessTests-{Guid.NewGuid()}");
        try
        {
            const string model = "test-model";
            var secrets = new MemoryProviderSecretStore();
            var store = new NativeProviderStore(root, secrets);
            var account = new NativeProviderAccount
            {
                Provider = "language-test",
                ProviderName = protocol.ToString(),
                Name = "Language test",
                AuthType = protocol == NativeProviderProtocol.ChatGpt ? "chatgpt" : "apiKey",
                SessionAccountId = protocol == NativeProviderProtocol.ChatGpt ? "account-1" : null,
                Model = model,
                Models = [model],
                BaseUrl = protocol switch
                {
                    NativeProviderProtocol.Anthropic => "https://anthropic.example",
                    NativeProviderProtocol.ChatGpt => "https://chatgpt.example/backend-api/codex",
                    _ => "https://openai.example/v1",
                },
                Protocol = protocol,
                CredentialId = $"language-{protocol}",
            };
            store.State.Accounts.Add(account);
            secrets.Write(account.CredentialId, "test-secret");

            var handler = new LanguagePolicyRecordingHandler(protocol);
            var router = new NativeProviderRouter(store, http: new HttpClient(handler));
            var policy = HerNessPrompt.Core("SCOPE", "TOOL_GUIDANCE");
            var response = await router.CompleteAsync(
                [
                    new NativeMessage("system", policy),
                    new NativeMessage("user", "Türkçe bir yanıt ver."),
                ],
                []);

            Assert.Equal("ready", response.Message.Content);
            var body = JsonNode.Parse(handler.Body)!.AsObject();
            switch (protocol)
            {
                case NativeProviderProtocol.Anthropic:
                    // The system prompt is sent as a cacheable text block.
                    var system = Assert.Single(body["system"]!.AsArray())!;
                    Assert.Equal(policy, system["text"]?.GetValue<string>());
                    Assert.NotNull(system["cache_control"]);
                    break;

                case NativeProviderProtocol.OpenAiCompatible:
                    Assert.Equal(policy, body["messages"]![0]!["content"]?.GetValue<string>());
                    break;

                case NativeProviderProtocol.ChatGpt:
                    var developer = body["input"]!.AsArray()
                        .Single(item => item?["role"]?.GetValue<string>() == "developer");
                    Assert.Equal(policy, developer?["content"]![0]!["text"]?.GetValue<string>());
                    break;
            }
        }
        finally
        {
            if (Directory.Exists(root)) Directory.Delete(root, recursive: true);
        }
    }

    [Theory]
    [InlineData(NativeProviderProtocol.OpenAiCompatible)]
    [InlineData(NativeProviderProtocol.ChatGpt)]
    [InlineData(NativeProviderProtocol.Anthropic)]
    public async Task ProviderCacheNamespaceIsWireSafeAndProtocolScoped(NativeProviderProtocol protocol)
    {
        var root = Path.Combine(Path.GetTempPath(), $"DotsHarnessTests-{Guid.NewGuid()}");
        try
        {
            const string cacheKey = "herness:area-v1:chat:context-fingerprint";
            const string model = "test-model";
            var secrets = new MemoryProviderSecretStore();
            var store = new NativeProviderStore(root, secrets);
            var account = new NativeProviderAccount
            {
                Provider = "cache-test",
                ProviderName = protocol.ToString(),
                Name = "Cache test",
                AuthType = protocol == NativeProviderProtocol.ChatGpt ? "chatgpt" : "apiKey",
                SessionAccountId = protocol == NativeProviderProtocol.ChatGpt ? "account-1" : null,
                Model = model,
                Models = [model],
                BaseUrl = protocol switch
                {
                    NativeProviderProtocol.Anthropic => "https://anthropic.example",
                    NativeProviderProtocol.ChatGpt => "https://chatgpt.example/backend-api/codex",
                    _ => "https://openai.example/v1",
                },
                Protocol = protocol,
                CredentialId = $"cache-{protocol}",
            };
            store.State.Accounts.Add(account);
            secrets.Write(account.CredentialId, "test-secret");

            var handler = new LanguagePolicyRecordingHandler(protocol);
            var router = new NativeProviderRouter(store, http: new HttpClient(handler));
            await router.CompleteAsync(
                [new NativeMessage("user", "hello")],
                [],
                model,
                promptCacheKey: cacheKey);

            var body = JsonNode.Parse(handler.Body)!.AsObject();
            if (protocol == NativeProviderProtocol.Anthropic)
            {
                Assert.Null(body["prompt_cache_key"]);
                Assert.Equal("ephemeral", body["messages"]![0]!["content"]![0]!["cache_control"]!["type"]!.GetValue<string>());
                Assert.Equal("1h", body["messages"]![0]!["content"]![0]!["cache_control"]!["ttl"]!.GetValue<string>());
            }
            else
            {
                // The wire key is the conversation key scoped to the serving route (account/model),
                // so two accounts never share one provider-side cache shard.
                var wire = body["prompt_cache_key"]?.GetValue<string>() ?? "";
                Assert.StartsWith(cacheKey + ":route-", wire, StringComparison.Ordinal);
                Assert.Matches("^[A-Za-z0-9:_-]+$", wire);
            }
        }
        finally
        {
            if (Directory.Exists(root)) Directory.Delete(root, recursive: true);
        }
    }

    [Fact]
    public async Task ProviderCacheShardUsesTheResolvedModelNotTheAccountDefault()
    {
        var root = Path.Combine(Path.GetTempPath(), $"DotsHarnessCacheModelTests-{Guid.NewGuid()}");
        try
        {
            var secrets = new MemoryProviderSecretStore();
            var store = new NativeProviderStore(root, secrets);
            var account = new NativeProviderAccount
            {
                Provider = "cache-model-test",
                ProviderName = "Cache model test",
                Name = "Cache model test",
                Model = "model-a",
                Models = ["model-a", "model-b"],
                BaseUrl = "https://openai.example/v1",
                Protocol = NativeProviderProtocol.OpenAiCompatible,
                CredentialId = "cache-model-test",
            };
            store.State.Accounts.Add(account);
            secrets.Write(account.CredentialId, "test-secret");

            var handler = new LanguagePolicyRecordingHandler(NativeProviderProtocol.OpenAiCompatible);
            var router = new NativeProviderRouter(store, http: new HttpClient(handler));
            var messages = new[] { new NativeMessage("user", "hello") };
            const string baseKey = "herness:unified-v2:conversation";

            await router.CompleteAsync(messages, [], "model-a", promptCacheKey: baseKey);
            var modelAKey = JsonNode.Parse(handler.Body)!["prompt_cache_key"]!.GetValue<string>();
            await router.CompleteAsync(messages, [], "model-b", promptCacheKey: baseKey);
            var modelBKey = JsonNode.Parse(handler.Body)!["prompt_cache_key"]!.GetValue<string>();
            await router.CompleteAsync(messages, [], "model-a", promptCacheKey: baseKey);
            var repeatedModelAKey = JsonNode.Parse(handler.Body)!["prompt_cache_key"]!.GetValue<string>();

            Assert.NotEqual(modelAKey, modelBKey);
            Assert.Equal(modelAKey, repeatedModelAKey);
        }
        finally
        {
            if (Directory.Exists(root)) Directory.Delete(root, recursive: true);
        }
    }

    [Fact]
    public async Task ProviderLimitFallsThroughToAnotherRoute()
    {
        var root = Path.Combine(Path.GetTempPath(), $"DotsHarnessTests-{Guid.NewGuid()}");
        try
        {
            var secrets = new MemoryProviderSecretStore();
            var store = new NativeProviderStore(root, secrets);
            var first = new NativeProviderAccount
            {
                Provider = "first",
                ProviderName = "First",
                Name = "First",
                Model = "test-model",
                Models = ["test-model"],
                BaseUrl = "https://first.example/v1",
                CredentialId = "first-key",
                Priority = 0,
            };
            var second = new NativeProviderAccount
            {
                Provider = "second",
                ProviderName = "Second",
                Name = "Second",
                Model = "test-model",
                Models = ["test-model"],
                BaseUrl = "https://second.example/v1",
                CredentialId = "second-key",
                Priority = 1,
            };
            store.State.Accounts.Add(first);
            store.State.Accounts.Add(second);
            secrets.Write(first.CredentialId, "first-secret");
            secrets.Write(second.CredentialId, "second-secret");

            var handler = new LimitThenSuccessHandler();
            var router = new NativeProviderRouter(store, http: new HttpClient(handler));
            var response = await router.CompleteAsync([new NativeMessage("user", "hello")], [], "test-model");

            Assert.Equal(2, handler.CallCount);
            Assert.Equal("ready", response.Message.Content);
        }
        finally
        {
            if (Directory.Exists(root)) Directory.Delete(root, recursive: true);
        }
    }

    private sealed class RecordingHandler : HttpMessageHandler
    {
        public HttpRequestMessage? Request { get; private set; }
        public string Body { get; private set; } = "";

        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, System.Threading.CancellationToken cancellationToken)
        {
            Request = request;
            Body = await request.Content!.ReadAsStringAsync(cancellationToken);
            return new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = new StringContent("{\"output\":[{\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\"ready\"}]}],\"usage\":{\"input_tokens\":1,\"output_tokens\":2}}"),
            };
        }
    }

    private sealed class LanguagePolicyRecordingHandler(NativeProviderProtocol protocol) : HttpMessageHandler
    {
        public string Body { get; private set; } = "";

        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, System.Threading.CancellationToken cancellationToken)
        {
            Body = await request.Content!.ReadAsStringAsync(cancellationToken);
            var response = protocol switch
            {
                NativeProviderProtocol.Anthropic => "{\"content\":[{\"type\":\"text\",\"text\":\"ready\"}]}",
                NativeProviderProtocol.ChatGpt => "{\"output\":[{\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\"ready\"}]}]}",
                _ => "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"ready\"}}]}",
            };
            return new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent(response) };
        }
    }

    private sealed class LimitThenSuccessHandler : HttpMessageHandler
    {
        public int CallCount { get; private set; }

        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, System.Threading.CancellationToken cancellationToken)
        {
            CallCount++;
            if (CallCount == 1)
            {
                return Task.FromResult(new HttpResponseMessage(HttpStatusCode.TooManyRequests)
                {
                    Content = new StringContent("{\"error\":{\"message\":\"rate limit reached\"}}"),
                });
            }

            return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = new StringContent("{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"ready\"}}]}"),
            });
        }
    }
}

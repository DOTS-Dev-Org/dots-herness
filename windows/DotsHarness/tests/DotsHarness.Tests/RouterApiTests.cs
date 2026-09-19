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
        Assert.Equal("GPT", RouterCatalog.LabelFor(consumer.Provider));
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

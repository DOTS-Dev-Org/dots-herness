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
}

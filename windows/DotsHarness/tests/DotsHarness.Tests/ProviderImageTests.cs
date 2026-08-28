using System.Net;
using System.Net.Http;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using DotsHarnessCore;
using HarnessPluginKit;
using PluginRuntime;
using Xunit;

namespace DotsHarness.Tests;

public sealed class ProviderImageTests
{
    [Fact]
    public void RegistryMatchesByRouteAndUnmountRemovesPluginAdapter()
    {
        var catalog = new PluginCatalog(TemporaryPaths());
        catalog.RegisterBuiltin<ImageAdapterPlugin>();
        var host = new PluginHost(catalog);
        var route = new ProviderImageRoute("account", "test-image", "https://example.test/v1", "OpenAiCompatible", "model");

        var issues = host.Mount(new CompositionDocument(PluginPlane.Host, new[]
        {
            new CompositionEntry("image", "dots.test-image-adapter"),
        }));

        Assert.Empty(issues);
        Assert.Equal("test.image", host.ImageAdapters.Find(route)?.Id);
        host.UnmountAll();
        Assert.Null(host.ImageAdapters.Find(route));
    }

    [Fact]
    public void UntrustedPluginCannotRegisterNetworkAdapter()
    {
        var registry = new ProviderImageAdapterRegistry();
        Assert.Throws<InvalidOperationException>(() => registry.Register(new TestImageAdapter(), "untrusted", PluginTrust.Untrusted));
    }

    [Fact]
    public void OpenAIResponsesParsesJsonAndSseImageCalls()
    {
        var adapter = new OpenAIResponsesImageAdapter();
        var responses = new[]
        {
            Encoding.UTF8.GetBytes("{\"output\":[{\"type\":\"image_generation_call\",\"result\":\"AQID\"}] }"),
            Encoding.UTF8.GetBytes("data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"image_generation_call\",\"result\":\"AQID\"}}\n\ndata: [DONE]\n"),
        };

        foreach (var data in responses)
        {
            var result = adapter.ParseImageResponse(data, 200, new Dictionary<string, string>());
            var generated = Assert.IsType<ProviderImageResult.Generated>(result);
            Assert.Equal(new byte[] { 1, 2, 3 }, generated.Output.Data);
        }
    }

    [Fact]
    public void GeminiInlineDataAndFailureCategoriesAreDistinguished()
    {
        var adapter = new GeminiNativeImageAdapter();
        var image = Encoding.UTF8.GetBytes("{\"candidates\":[{\"content\":{\"parts\":[{\"inlineData\":{\"mimeType\":\"image/jpeg\",\"data\":\"AQID\"}}]}}]}");
        var generated = Assert.IsType<ProviderImageResult.Generated>(adapter.ParseImageResponse(image, 200, new Dictionary<string, string>()));
        Assert.Equal(new byte[] { 1, 2, 3 }, generated.Output.Data);
        Assert.Equal("image/jpeg", generated.Output.MimeType);

        var unsupported = adapter.ParseImageResponse(
            Encoding.UTF8.GetBytes("{\"error\":{\"message\":\"model does not support responseModalities IMAGE\"}}"),
            400,
            new Dictionary<string, string>());
        Assert.IsType<ProviderImageResult.Unsupported>(unsupported);

        var auth = Assert.IsType<ProviderImageResult.Failed>(adapter.ParseImageResponse(Encoding.UTF8.GetBytes("{\"error\":{\"message\":\"invalid API key\"}}"), 401, new Dictionary<string, string>()));
        Assert.Equal(ProviderImageFailureKind.Auth, auth.Failure.Kind);
        var rate = Assert.IsType<ProviderImageResult.Failed>(adapter.ParseImageResponse(Encoding.UTF8.GetBytes("{\"error\":{\"message\":\"slow down\"}}"), 429, new Dictionary<string, string>()));
        Assert.Equal(ProviderImageFailureKind.RateLimit, rate.Failure.Kind);
        var safety = Assert.IsType<ProviderImageResult.Failed>(adapter.ParseImageResponse(Encoding.UTF8.GetBytes("{\"error\":{\"message\":\"safety policy blocked this request\"}}"), 400, new Dictionary<string, string>()));
        Assert.Equal(ProviderImageFailureKind.Safety, safety.Failure.Kind);
        var invalid = Assert.IsType<ProviderImageResult.Failed>(adapter.ParseImageResponse(Encoding.UTF8.GetBytes("{}"), 200, new Dictionary<string, string>()));
        Assert.Equal(ProviderImageFailureKind.InvalidOutput, invalid.Failure.Kind);
    }

    [Fact]
    public void MissingFallbackFlagDefaultsToFalse()
    {
        var account = JsonSerializer.Deserialize<NativeProviderAccount>("{\"id\":\"account\",\"provider\":\"openai\"}");
        Assert.NotNull(account);
        Assert.False(account.ImageFallbackEnabled);
    }

    [Fact]
    public async Task UnsupportedPrimaryUsesFlaggedFallbackInPriorityOrder()
    {
        var root = Path.Combine(Path.GetTempPath(), $"DotsHarnessImageTests-{Guid.NewGuid()}");
        try
        {
            var secrets = new MemoryProviderSecretStore();
            var store = new NativeProviderStore(root, secrets);
            var primary = Account("primary", "custom:primary", "Primary", "main-model", "https://primary.test/v1", 0, false);
            var first = Account("first", "openai", "First fallback", "fallback-one", "https://first.test/v1", 1, true);
            var second = Account("second", "openai", "Second fallback", "fallback-two", "https://second.test/v1", 2, true);
            store.State.Accounts.AddRange([primary, first, second]);
            secrets.Write(primary.CredentialId, "primary-key");
            secrets.Write(first.CredentialId, "first-key");
            secrets.Write(second.CredentialId, "second-key");
            var handler = new ImageHandler(request => request.RequestUri!.Host switch
            {
                "first.test" => new HttpResponseMessage(HttpStatusCode.BadRequest) { Content = new StringContent("{\"error\":{\"message\":\"image_generation unsupported\"}}") },
                "second.test" => new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent("{\"data\":[{\"b64_json\":\"AQID\"}]}") },
                _ => new HttpResponseMessage(HttpStatusCode.InternalServerError),
            });
            var adapters = new ProviderImageAdapterRegistry();
            NativeProviderImageAdapters.Register(adapters);
            var router = new NativeProviderImageRouter(store, adapters, new HttpClient(handler));

            Assert.True(router.CommandVisible("main-model"));
            var generated = await router.GenerateAsync("a red fox", "main-model");

            Assert.Equal(new byte[] { 1, 2, 3 }, generated.Output.Data);
            Assert.Equal("Second fallback", generated.Provider);
            Assert.Equal("gpt-image-1.5", generated.Model);
            Assert.Equal("Primary/main-model", generated.FallbackFrom);
            Assert.Equal(new[] { "https://first.test/v1/images/generations", "https://second.test/v1/images/generations" }, handler.Requests);
            var route = new ProviderImageRoute(second.Id, second.Provider, second.BaseUrl, second.Protocol.ToString(), second.Model, second.AuthType, second.SessionAccountId);
            Assert.Equal(ProviderImageCapability.Supported, adapters.Capability(route, "openai.images.fallback"));
        }
        finally
        {
            if (Directory.Exists(root)) Directory.Delete(root, recursive: true);
        }
    }

    [Fact]
    public async Task TransientFailureDoesNotFallBackOrCacheUnsupported()
    {
        var root = Path.Combine(Path.GetTempPath(), $"DotsHarnessImageTests-{Guid.NewGuid()}");
        try
        {
            var secrets = new MemoryProviderSecretStore();
            var store = new NativeProviderStore(root, secrets);
            var primary = Account("primary", "openai", "OpenAI", "gpt-4.1-mini", "https://primary.test/v1", 0, true);
            store.State.Accounts.Add(primary);
            secrets.Write(primary.CredentialId, "key");
            var adapters = new ProviderImageAdapterRegistry();
            NativeProviderImageAdapters.Register(adapters);
            var router = new NativeProviderImageRouter(
                store,
                adapters,
                new HttpClient(new ImageHandler(_ => new HttpResponseMessage(HttpStatusCode.TooManyRequests) { Content = new StringContent("{\"error\":{\"message\":\"rate limit\"}}") })));

            var error = await Assert.ThrowsAsync<NativeImageGenerationException>(() => router.GenerateAsync("a red fox", primary.Model));

            Assert.False(error.Unsupported);
            Assert.Equal(ProviderImageFailureKind.RateLimit, error.Failure?.Kind);
            var route = new ProviderImageRoute(primary.Id, primary.Provider, primary.BaseUrl, primary.Protocol.ToString(), primary.Model, primary.AuthType, primary.SessionAccountId);
            Assert.Null(adapters.Capability(route, "openai.responses.image"));
        }
        finally
        {
            if (Directory.Exists(root)) Directory.Delete(root, recursive: true);
        }
    }

    [Fact]
    public async Task NetworkFailureIsFailedAndDoesNotFallBack()
    {
        var root = Path.Combine(Path.GetTempPath(), $"DotsHarnessImageTests-{Guid.NewGuid()}");
        try
        {
            var secrets = new MemoryProviderSecretStore();
            var store = new NativeProviderStore(root, secrets);
            var primary = Account("primary", "openai", "OpenAI", "gpt-4.1-mini", "https://primary.test/v1", 0, false);
            store.State.Accounts.Add(primary);
            secrets.Write(primary.CredentialId, "key");
            var adapters = new ProviderImageAdapterRegistry();
            NativeProviderImageAdapters.Register(adapters);
            var router = new NativeProviderImageRouter(
                store,
                adapters,
                new HttpClient(new ImageHandler(_ => throw new HttpRequestException("offline"))));

            var error = await Assert.ThrowsAsync<NativeImageGenerationException>(() => router.GenerateAsync("a red fox", primary.Model));

            Assert.False(error.Unsupported);
            Assert.Equal(ProviderImageFailureKind.Network, error.Failure?.Kind);
        }
        finally
        {
            if (Directory.Exists(root)) Directory.Delete(root, recursive: true);
        }
    }

    [Fact]
    public async Task UnsupportedCacheHidesCommandButModelChangeRetries()
    {
        var root = Path.Combine(Path.GetTempPath(), $"DotsHarnessImageTests-{Guid.NewGuid()}");
        try
        {
            var secrets = new MemoryProviderSecretStore();
            var store = new NativeProviderStore(root, secrets);
            var primary = Account("primary", "openai", "OpenAI", "gpt-4.1-mini", "https://primary.test/v1", 0, false);
            store.State.Accounts.Add(primary);
            secrets.Write(primary.CredentialId, "key");
            var adapters = new ProviderImageAdapterRegistry();
            NativeProviderImageAdapters.Register(adapters);
            var router = new NativeProviderImageRouter(
                store,
                adapters,
                new HttpClient(new ImageHandler(_ => new HttpResponseMessage(HttpStatusCode.BadRequest) { Content = new StringContent("{\"error\":{\"message\":\"image_generation unsupported\"}}") })));

            Assert.True(router.CommandVisible(primary.Model));
            var error = await Assert.ThrowsAsync<NativeImageGenerationException>(() => router.GenerateAsync("a red fox", primary.Model));
            Assert.True(error.Unsupported);
            Assert.False(router.CommandVisible(primary.Model));
            Assert.True(router.CommandVisible("unknown-model"));
        }
        finally
        {
            if (Directory.Exists(root)) Directory.Delete(root, recursive: true);
        }
    }

    private static NativeProviderAccount Account(string id, string provider, string name, string model, string baseUrl, int priority, bool fallback) => new()
    {
        Id = id,
        Provider = provider,
        ProviderName = name,
        Name = name,
        Model = model,
        Models = [model],
        BaseUrl = baseUrl,
        Protocol = NativeProviderProtocol.OpenAiCompatible,
        AuthType = "apiKey",
        CredentialId = $"account.{id}",
        Priority = priority,
        Active = true,
        ImageFallbackEnabled = fallback,
    };

    private static SupportPaths TemporaryPaths()
    {
        var root = Path.Combine(Path.GetTempPath(), $"DotsHarnessPluginImageTests-{Guid.NewGuid()}");
        var paths = new SupportPaths(
            root,
            Path.Combine(root, "plugins"),
            Path.Combine(root, "presets"),
            Path.Combine(root, "settings.json"),
            Path.Combine(root, "host.patch.yml"),
            Path.Combine(root, "trust.json"),
            Path.Combine(root, "models"),
            Path.Combine(root, "runtime"));
        paths.Ensure();
        return paths;
    }

    private sealed class ImageHandler(Func<HttpRequestMessage, HttpResponseMessage> responder) : HttpMessageHandler
    {
        public List<string> Requests { get; } = [];

        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            Requests.Add(request.RequestUri!.AbsoluteUri);
            return Task.FromResult(responder(request));
        }
    }
}

public sealed class ImageAdapterPlugin : IDefaultPlugin
{
    public PluginManifest Manifest { get; } = new(
        "dots.test-image-adapter",
        "Image adapter",
        "1.0.0",
        PluginPlane.Host,
        Inject: new[] { "provider.imageAdapters" });

    public void Apply(IPluginContext ctx) =>
        ((ProviderImageAdapterRegistry)ctx.Require("provider.imageAdapters"))
            .Register(new TestImageAdapter(), ctx.RowId, ctx.Trust);
}

public sealed class TestImageAdapter : IProviderImageAdapter
{
    public string Id => "test.image";
    public bool Matches(ProviderImageRoute route) => route.ProviderId == "test-image";
    public ProviderImageRequest PrepareImageRequest(string prompt, string model, ProviderImageRoute route) =>
        new(new Uri("https://example.test/image"), Array.Empty<byte>());
    public ProviderImageResult ParseImageResponse(byte[] data, int status, IReadOnlyDictionary<string, string> headers) =>
        new ProviderImageResult.Unsupported("test");
}

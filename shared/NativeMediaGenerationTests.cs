using System.Net;
using System.Net.Http;
using System.Net.Sockets;
using System.Text;
using System.Text.Json.Nodes;
using DotsHarnessCore;
using Xunit;

public sealed class NativeMediaGenerationTests : IDisposable
{
    private readonly string _root = Path.Combine(Path.GetTempPath(), $"NativeMediaGenerationTests-{Guid.NewGuid():N}");

    public NativeMediaGenerationTests() => Directory.CreateDirectory(_root);

    public void Dispose()
    {
        if (Directory.Exists(_root)) Directory.Delete(_root, recursive: true);
    }

    [Fact]
    public void CommandsParseVideoAndSpeechAndKeepImageOnTheAdapterPath()
    {
        Assert.True(MediaRequest.TryParse("/videogen a cat on a roof", out var video));
        Assert.Equal((NativeMediaKind.Video, "a cat on a roof"), (video.Kind, video.Prompt));
        Assert.True(MediaRequest.TryParse("/speech hello there", out var speech));
        Assert.Equal((NativeMediaKind.Audio, "hello there"), (speech.Kind, speech.Prompt));
        Assert.True(MediaRequest.TryParse("/imagegen a lake", out var image));
        Assert.Equal(NativeMediaKind.Image, image.Kind);
        Assert.False(MediaRequest.TryParse("video of a cat", out _));
    }

    [Fact]
    public void OnlyDeclaredProvidersOfferMediaKinds()
    {
        Assert.NotNull(NativeMediaCatalog.SpecFor("openai", NativeMediaKind.Audio));
        Assert.Equal("sora-2", NativeMediaCatalog.SpecFor("OpenAI", NativeMediaKind.Video)!.Model);
        Assert.Null(NativeMediaCatalog.SpecFor("claude", NativeMediaKind.Video));
    }

    [Fact]
    public async Task SpeechPostsTheSpeechBodyAndSavesMp3()
    {
        var audio = new byte[] { 0x49, 0x44, 0x33, 4, 5, 6 };
        string? body = null;
        using var provider = new FakeMediaProvider(request =>
        {
            body = Encoding.UTF8.GetString(request.Body);
            return new NativeGatewayResponse(200, audio, "audio/mpeg");
        });
        using var http = new HttpClient();

        var bytes = await NativeMediaGenerator.GenerateAsync(
            NativeMediaKind.Audio, "hello there", provider.BaseUrl, "test-key",
            NativeMediaCatalog.SpecFor("openai", NativeMediaKind.Audio)!, http, CancellationToken.None);
        var saved = NativeMediaGenerator.Save(NativeMediaKind.Audio, bytes, _root, "OpenAI", "gpt-4o-mini-tts");

        var sent = JsonNode.Parse(body!)!.AsObject();
        Assert.Equal("gpt-4o-mini-tts", sent["model"]!.GetValue<string>());
        Assert.Equal("hello there", sent["input"]!.GetValue<string>());
        Assert.Equal("marin", sent["voice"]!.GetValue<string>());
        Assert.Equal("mp3", sent["response_format"]!.GetValue<string>());
        Assert.EndsWith(".mp3", saved.FilePath, StringComparison.Ordinal);
        Assert.Equal("audio/mpeg", saved.MimeType);
        Assert.Equal(audio, File.ReadAllBytes(saved.FilePath));
    }

    [Fact]
    public async Task VideoCreatesPollsAndDownloadsTheRender()
    {
        var video = new byte[] { 0, 0, 0, 0x18, 0x66, 0x74, 0x79, 0x70 };
        var created = new List<string>();
        using var provider = new FakeMediaProvider(request =>
        {
            if (request.Method == "POST" && request.Path.EndsWith("/videos", StringComparison.Ordinal))
            {
                created.Add(Encoding.UTF8.GetString(request.Body));
                return new NativeGatewayResponse(200, Encoding.UTF8.GetBytes("{\"id\":\"video_1\"}"));
            }
            if (request.Method == "GET" && request.Path.EndsWith("/videos/video_1", StringComparison.Ordinal))
            {
                return new NativeGatewayResponse(200, Encoding.UTF8.GetBytes("{\"status\":\"completed\"}"));
            }
            if (request.Method == "GET" && request.Path.EndsWith("/videos/video_1/content", StringComparison.Ordinal))
            {
                return new NativeGatewayResponse(200, video, "video/mp4");
            }
            return new NativeGatewayResponse(404, []);
        });
        using var http = new HttpClient();

        var bytes = await NativeMediaGenerator.GenerateAsync(
            NativeMediaKind.Video, "a cat on a roof", provider.BaseUrl, "test-key",
            NativeMediaCatalog.SpecFor("openai", NativeMediaKind.Video)!, http, CancellationToken.None);
        var saved = NativeMediaGenerator.Save(NativeMediaKind.Video, bytes, _root, "OpenAI", "sora-2");

        Assert.Single(created);
        Assert.Contains("sora-2", created[0], StringComparison.Ordinal);
        Assert.Contains("a cat on a roof", created[0], StringComparison.Ordinal);
        Assert.EndsWith(".mp4", saved.FilePath, StringComparison.Ordinal);
        Assert.Equal(video, File.ReadAllBytes(saved.FilePath));
    }

    [Fact]
    public async Task ProviderErrorsSurfaceTheirMessage()
    {
        using var provider = new FakeMediaProvider(_ =>
            new NativeGatewayResponse(400, Encoding.UTF8.GetBytes("{\"error\":{\"message\":\"prompt rejected\"}}")));
        using var http = new HttpClient();

        var error = await Assert.ThrowsAsync<NativeMediaGenerationException>(() => NativeMediaGenerator.GenerateAsync(
            NativeMediaKind.Audio, "x", provider.BaseUrl, "test-key",
            NativeMediaCatalog.SpecFor("openai", NativeMediaKind.Audio)!, http, CancellationToken.None));

        Assert.Equal("prompt rejected", error.Message);
        Assert.False(error.Retryable);
    }

    [Fact]
    public void SavedMediaIsNamedByContentSoIdenticalOutputDedupes()
    {
        var data = new byte[] { 1, 2, 3, 4 };
        var first = NativeMediaGenerator.Save(NativeMediaKind.Audio, data, _root, "OpenAI", "gpt-4o-mini-tts");
        var second = NativeMediaGenerator.Save(NativeMediaKind.Audio, data, _root, "OpenAI", "gpt-4o-mini-tts");

        Assert.Equal(first.FilePath, second.FilePath);
        Assert.Equal(Path.Combine(_root, "generated-media"), Path.GetDirectoryName(first.FilePath));
    }

    private sealed class FakeMediaProvider : IDisposable
    {
        private readonly NativeProviderGateway _gateway;

        public FakeMediaProvider(Func<NativeGatewayRequest, NativeGatewayResponse> reply)
        {
            _gateway = LocalTestGateway.Start(request => Task.FromResult(reply(request)));
        }

        public string BaseUrl => _gateway.Url.ToString().TrimEnd('/');

        public void Dispose() => _gateway.Dispose();
    }
}

// Copyright (c) 2026 DOTS
// Plugin composition model derived from DeepSeek Harness.
// Copyright (c) 2026 DeepSeek. MIT. See NOTICE.

using DotsHarnessCore;
using HarnessPluginKit;
using Xunit;

namespace DotsHarness.Tests;

public sealed class LocalRuntimeTests
{
    [Fact]
    public void CatalogIncludesLocalReasoningModel()
    {
        var ids = LocalModelCatalog.Models.Select(m => m.Id).ToHashSet();
        Assert.Contains("qwen25-05b-q4", ids);
        Assert.Contains("llama32-1b-q4", ids);
        Assert.Contains("dsr1-15b-q4", ids);
        Assert.Single(LocalModelCatalog.Models.Where(m => m.Reasoning));
        Assert.Contains("huggingface.co", LocalModelCatalog.Spec("dsr1-15b-q4")?.Url.AbsoluteUri ?? "");
    }

    [Fact]
    public void RouterNodeMapsCustomEndpoint()
    {
        var node = new RouterNode(new NativeCustomEndpoint
        {
            Id = "openai-compatible-chat-abc",
            Name = "Ollama",
            Prefix = "local",
            Protocol = NativeProviderProtocol.OpenAiCompatible,
            ApiType = "chat",
            BaseUrl = "http://127.0.0.1:11434/v1",
        });
        Assert.Equal("openai-compatible", node.Type);
        Assert.Equal("local", node.Prefix);
        Assert.Equal("http://127.0.0.1:11434/v1", node.BaseUrl);
        Assert.Equal("chat", node.ApiType);
    }

    [Fact]
    public void PicksWindowsX64LlamaAsset()
    {
        var json = JsonValue.Object(new Dictionary<string, JsonValue>
        {
            ["tag_name"] = JsonValue.String("b10488"),
            ["assets"] = JsonValue.Array(
                JsonValue.Object(new Dictionary<string, JsonValue>
                {
                    ["name"] = JsonValue.String("llama-b10488-bin-ubuntu-x64.tar.gz"),
                    ["size"] = JsonValue.Number(1),
                    ["browser_download_url"] = JsonValue.String("https://example.com/ubuntu"),
                }),
                JsonValue.Object(new Dictionary<string, JsonValue>
                {
                    ["name"] = JsonValue.String("llama-b10488-bin-win-cpu-x64.zip"),
                    ["size"] = JsonValue.Number(12_087_008),
                    ["browser_download_url"] = JsonValue.String("https://example.com/win-cpu-x64"),
                }),
                JsonValue.Object(new Dictionary<string, JsonValue>
                {
                    ["name"] = JsonValue.String("llama-b10488-bin-win-cuda-12.4-x64.zip"),
                    ["size"] = JsonValue.Number(80_392_805),
                    ["browser_download_url"] = JsonValue.String("https://example.com/win-cuda-x64"),
                })),
        });
        var asset = LocalRuntime.WindowsAsset(json, "x64");
        Assert.Equal("b10488", asset.Tag);
        Assert.Equal("https://example.com/win-cuda-x64", asset.Url.AbsoluteUri);
        Assert.Equal(80_392_805, asset.Size);
    }

    [Fact]
    public async Task DownloaderSkipsCompleteFile()
    {
        var dir = Path.Combine(Path.GetTempPath(), $"DotsHarness-dl-{Guid.NewGuid()}");
        Directory.CreateDirectory(dir);
        var dest = Path.Combine(dir, "model.gguf");
        var payload = new byte[128];
        Array.Fill(payload, (byte)7);
        await File.WriteAllBytesAsync(dest, payload);
        await FileDownloader.DownloadAsync(new Uri("https://example.invalid/missing.gguf"), dest, 128);
        Assert.Equal(128, new FileInfo(dest).Length);
        try { Directory.Delete(dir, recursive: true); } catch { /* ignore */ }
    }

    [Fact]
    public void VoiceTinyModelMetadataIsPinned()
    {
        Assert.Equal("ggml-tiny-q5_1.bin", VoiceModelCatalog.WhisperTinyQ5.FileName);
        Assert.Equal(32_152_673, VoiceModelCatalog.WhisperTinyQ5.Bytes);
        Assert.Equal(64, VoiceModelCatalog.WhisperTinyQ5.Sha256?.Length);
        Assert.Contains("huggingface.co/ggerganov/whisper.cpp", VoiceModelCatalog.WhisperTinyQ5.Url?.AbsoluteUri ?? "");
    }

    [Fact]
    public void VoiceVADKeepsShortBreathGapAndEndpointsAfter800Milliseconds()
    {
        var detector = new VoiceActivityDetector();
        var speech = Enumerable.Repeat(0.08f, VoiceActivityDetector.FrameSamples).ToArray();
        var silence = new float[VoiceActivityDetector.FrameSamples];

        for (var i = 0; i < 12; i++) detector.Consume(speech);
        var breathEnded = false;
        for (var i = 0; i < 20; i++)
            breathEnded |= detector.Consume(silence).Any(item => item.Kind == VoiceActivityKind.UtteranceEnded);
        Assert.False(breathEnded);
        var ended = false;
        for (var i = 0; i < 20; i++)
            ended |= detector.Consume(silence).Any(item => item.Kind == VoiceActivityKind.UtteranceEnded);
        Assert.True(ended);
    }

    [Fact]
    public void VoiceVADFlushesRemainingSpeech()
    {
        var detector = new VoiceActivityDetector();
        detector.Consume(Enumerable.Repeat(0.08f, VoiceActivityDetector.FrameSamples * 12).ToArray());
        Assert.Contains(detector.Flush(), item => item.Kind == VoiceActivityKind.UtteranceEnded);
    }

    [Fact]
    public void VoiceRealtimeUriUsesOnlyNemoPath()
    {
        var uri = VoiceRealtimeClient.RealtimeUri("https://voice.example.test/v1");
        Assert.Equal("wss", uri.Scheme);
        Assert.Equal("/v1/realtime", uri.AbsolutePath);
    }

    [Fact]
    public async Task VoiceSessionTagsUpdatesWithItsSessionId()
    {
        var sessionId = Guid.NewGuid();
        var update = new TaskCompletionSource<VoiceTranscriptUpdate>(TaskCreationOptions.RunContinuationsAsynchronously);
        await using var session = new VoiceInputSession(
            VoiceStreamingMode.RollingWhisper,
            batch: (_, _, _) => Task.FromResult("hello"),
            onUpdate: value => update.TrySetResult(value),
            sessionId: sessionId);

        var pcm = new byte[VoiceActivityDetector.FrameSamples * 51 * 2];
        for (var index = 0; index < pcm.Length; index += 2)
        {
            pcm[index] = 0;
            pcm[index + 1] = 0x20;
        }
        session.PushPcm16(pcm);

        var result = await update.Task.WaitAsync(TimeSpan.FromSeconds(2));
        Assert.Equal(sessionId, result.SessionId);
    }
}

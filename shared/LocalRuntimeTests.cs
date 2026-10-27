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
        Assert.Equal(2, LocalModelCatalog.Models.Count(m => m.Reasoning));
        Assert.Contains("huggingface.co", LocalModelCatalog.Spec("dsr1-15b-q4")?.Url.AbsoluteUri ?? "");
    }

    [Fact]
    public void RouterNodeMapsProviderNodePayload()
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
    public void LlamaBuildsArePinnedForEveryBackendOfThisPlatform()
    {
        foreach (var windows in new[] { true, false })
        foreach (var backend in Enum.GetValues<LocalBackend>())
        {
            if (LocalRuntime.Assets(backend, "x64", windows) is not { } assets) continue;
            Assert.Contains(LocalRuntime.LlamaTag, assets.Main.Url.AbsoluteUri);
            Assert.EndsWith(windows ? ".zip" : ".tar.gz", assets.Main.Name);
            Assert.Equal(64, assets.Main.Sha256.Length);
            // Only CUDA needs NVIDIA's runtime libraries shipped beside it.
            Assert.Equal(backend is LocalBackend.Cuda13 or LocalBackend.Cuda12, assets.CudaRuntime is not null);
        }
        Assert.NotNull(LocalRuntime.Assets(LocalBackend.Cpu, "x64", windows: true));
        Assert.NotNull(LocalRuntime.Assets(LocalBackend.Rocm, "x64", windows: false));
        Assert.Null(LocalRuntime.Assets(LocalBackend.Rocm, "arm64", windows: false));
    }

    [Fact]
    public void BackendCandidatesFollowTheGpuVendorAndEndAtCpu()
    {
        var nvidia = new[] { new LocalGpu("nvidia", "RTX 4070", 581) };
        Assert.Equal(new[] { LocalBackend.Cuda13, LocalBackend.Cuda12, LocalBackend.Vulkan, LocalBackend.Cpu },
            LocalHardware.Candidates(nvidia, "x64", windows: true));
        // CUDA 13 needs driver 580+, so an older driver starts at CUDA 12.
        var oldDriver = new[] { new LocalGpu("nvidia", "GTX 1080", 552) };
        Assert.Equal(new[] { LocalBackend.Cuda12, LocalBackend.Vulkan, LocalBackend.Cpu },
            LocalHardware.Candidates(oldDriver, "x64", windows: false));
        var amd = new[] { new LocalGpu("amd", "RX 7900 XT") };
        Assert.Equal(new[] { LocalBackend.Rocm, LocalBackend.Vulkan, LocalBackend.Cpu },
            LocalHardware.Candidates(amd, "x64", windows: true));
        var intel = new[] { new LocalGpu("intel", "Arc A770") };
        Assert.Equal(new[] { LocalBackend.Vulkan, LocalBackend.Cpu }, LocalHardware.Candidates(intel, "x64", windows: false));
        Assert.Equal(new[] { LocalBackend.Cpu }, LocalHardware.Candidates([], "x64", windows: true));
        // No Vulkan or ROCm build exists for Windows on ARM.
        Assert.Equal(new[] { LocalBackend.Cpu }, LocalHardware.Candidates(amd, "arm64", windows: true));
    }

    [Fact]
    public void ParsesGpuAdaptersFromHelperOutput()
    {
        var smi = LocalHardware.ParseNvidiaSmi("NVIDIA GeForce RTX 4070, 581.29\r\nNVIDIA GeForce RTX 3060, 581.29\n").ToList();
        Assert.Equal(2, smi.Count);
        Assert.Equal(new LocalGpu("nvidia", "NVIDIA GeForce RTX 4070", 581), smi[0]);
        Assert.Empty(LocalHardware.ParseNvidiaSmi("'nvidia-smi' is not recognized"));

        var pnp = LocalHardware.ParsePnp("PCI\\VEN_1002&DEV_744C&SUBSYS_0E3B1002|AMD Radeon RX 7900 XT\r\nROOT\\BasicDisplay\\0000|Microsoft Basic Display Adapter\n").ToList();
        Assert.Equal(new[] { new LocalGpu("amd", "AMD Radeon RX 7900 XT") }, pnp);
        Assert.Equal("nvidia", LocalHardware.VendorFromId("0x10de\n"));
        Assert.Equal("intel", LocalHardware.VendorFromId("8086"));
    }

    [Fact]
    public void ParsesGpuDevicesAndSkipsCpuRenderers()
    {
        const string output = """
            0.00.000.109 I srv  llama_server: initializing ...
            Available devices:
              CUDA0: NVIDIA GeForce RTX 4070 (12282 MiB, 11000 MiB free)
              Vulkan1: llvmpipe (LLVM 17.0.6, 256 bits) (15950 MiB, 15950 MiB free)
              BLAS: OpenBLAS (0 MiB, 0 MiB free)
            """;
        Assert.Equal(new[] { new LocalDevice("CUDA0", "NVIDIA GeForce RTX 4070", 12282) }, LocalRuntime.ParseDevices(output));
        Assert.Empty(LocalRuntime.ParseDevices("Available devices:\n"));
    }

    [Fact]
    public void LlamaArgumentsFollowUserTuning()
    {
        Assert.Equal(
            new[] { "--model", "/m.gguf", "--host", "127.0.0.1", "--port", "1", "--ctx-size", "8192",
                    "--alias", "m", "--jinja", "--parallel", "1", "--sleep-idle-seconds", "15", "--gpu-layers", "auto" },
            LocalRuntime.LlamaArguments("/m.gguf", "m", 1, 8192, new LocalRuntimeSettings()));
        var tuned = new LocalRuntimeSettings
        {
            GpuLayers = "20", Threads = 6, FlashAttention = "on", KvCacheType = "q8_0", ExtraArgs = "--mlock  --ubatch-size 256",
        };
        Assert.Equal(
            new[] { "--gpu-layers", "20", "--threads", "6", "--flash-attn", "on",
                    "--cache-type-k", "q8_0", "--cache-type-v", "q8_0", "--mlock", "--ubatch-size", "256" },
            LocalRuntime.LlamaArguments("/m.gguf", "m", 1, 4096, tuned).TakeLast(13));
    }

    [Fact]
    public void AutomaticContextRespectsModelAndMemory()
    {
        var small = LocalModelCatalog.Spec("qwen25-05b-q4")!;
        var large = LocalModelCatalog.Spec("gpt-oss-20b-q4")!;
        const long gib = 1_073_741_824;
        Assert.Equal(8_192, LocalRuntime.AutomaticContext(small, 64 * gib));
        Assert.Equal(16_384, LocalRuntime.AutomaticContext(large, 16 * gib));
        Assert.Equal(32_768, LocalRuntime.AutomaticContext(large, 32 * gib));
        Assert.Equal(4_096, LocalRuntime.RequestedContext(large, new LocalRuntimeSettings { ContextSize = 4_096 }, 32 * gib));
    }

    [Fact]
    public void ProbeReadsLoadedContextPerModel()
    {
        var rows = System.Text.Json.Nodes.JsonNode.Parse("""
            [{"id":"a","loaded_context_length":4096,"max_context_length":32768},{"id":"b","max_context_length":8192},{"id":"c"}]
            """)!.AsArray();
        var contexts = LocalServerProbe.Contexts(rows, "id", "loaded_context_length", "max_context_length");
        Assert.Equal(2, contexts.Count);
        Assert.Equal(4096, contexts["a"]);
        Assert.Equal(8192, contexts["b"]);
    }

    [Fact]
    public void PlaceholderModelIsRecognized()
    {
        Assert.True(NativeProviderAccount.IsPlaceholderModel("ollama/"));
        Assert.False(NativeProviderAccount.IsPlaceholderModel("qwen3:8b"));
        Assert.False(NativeProviderAccount.IsPlaceholderModel(""));
        Assert.False(NativeProviderAccount.IsPlaceholderModel(null));
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

    [Fact]
    public async Task VoiceSessionKeepsEveryFinalWhileAPartialIsRunning()
    {
        var gate = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        var calls = 0;
        var finals = new List<VoiceTranscriptUpdate>();
        await using var session = new VoiceInputSession(
            VoiceStreamingMode.RollingWhisper,
            batch: async (_, _, _) =>
            {
                if (Interlocked.Increment(ref calls) == 1) await gate.Task;
                return $"text {calls}";
            },
            onUpdate: update =>
            {
                if (update.IsFinal) lock (finals) finals.Add(update);
            });

        session.PushPcm16(Tone(VoiceActivityDetector.SampleRate * 2));   // partial #1 starts and blocks
        for (var waited = 0; Volatile.Read(ref calls) == 0 && waited < 300; waited++)
        {
            await Task.Delay(10);
        }
        session.PushPcm16(Silence(VoiceActivityDetector.SampleRate));    // utterance #1 ends: its final waits
        session.PushPcm16(Tone(VoiceActivityDetector.SampleRate * 2));   // utterance #2 must not drop that final

        var stop = session.StopAsync();
        await Task.Delay(300);                                           // let the worker queue everything
        gate.TrySetResult(true);
        await stop.WaitAsync(TimeSpan.FromSeconds(5));

        lock (finals) Assert.Equal(2, finals.Count);
    }

    // 0x2000 is a constant quarter-scale level: far above the VAD start threshold.
    private static byte[] Tone(int samples) => Enumerable.Range(0, samples).SelectMany(_ => new byte[] { 0x00, 0x20 }).ToArray();

    private static byte[] Silence(int samples) => new byte[samples * 2];
}

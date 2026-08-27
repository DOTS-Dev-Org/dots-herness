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
    public void RouterNodeMapsProviderNodePayload()
    {
        var node = new RouterNode(new Dictionary<string, JsonValue>
        {
            ["id"] = JsonValue.String("openai-compatible-chat-abc"),
            ["type"] = JsonValue.String("openai-compatible"),
            ["name"] = JsonValue.String("Ollama"),
            ["prefix"] = JsonValue.String("local"),
            ["apiType"] = JsonValue.String("chat"),
            ["baseUrl"] = JsonValue.String("http://127.0.0.1:11434/v1"),
        });
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
}

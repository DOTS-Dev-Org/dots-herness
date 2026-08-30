using System;
using System.IO;
using System.Linq;
using DotsHarnessCore;
using HarnessPluginKit;
using Xunit;

namespace DotsHarness.Tests;

public sealed class VisionFallbackTests
{
    [Theory]
    [InlineData(400, "model does not support image input", true)]
    [InlineData(400, "model does not support images", true)]
    [InlineData(415, "multimodal input is not supported", true)]
    [InlineData(422, "vision is unsupported for this model", true)]
    [InlineData(400, "no image support on this endpoint", true)]
    [InlineData(401, "vision is not supported", false)]
    [InlineData(429, "image input is not supported", false)]
    [InlineData(500, "vision is not supported", false)]
    [InlineData(400, "invalid image payload", false)]
    [InlineData(400, "failed to decode image", false)]
    [InlineData(400, "vision model was not found", false)]
    [InlineData(404, "vision model is not available", false)]
    [InlineData(404, "unknown model", false)]
    [InlineData(400, "model does not support text input", false)]
    [InlineData(400, "bad request", false)]
    public void ClassifiesOnlyExplicitImageCapabilityFailures(int status, string message, bool expected)
    {
        Assert.Equal(expected, VisionProviderCapability.IsImageInputUnsupported(message, status));
    }

    [Fact]
    public void InstalledVisionPluginIsAddedToHostComposition()
    {
        var root = Path.Combine(Path.GetTempPath(), $"DotsHarnessVision-{Guid.NewGuid():N}");
        try
        {
            var paths = new PluginRuntime.SupportPaths(
                root,
                Path.Combine(root, "plugins"),
                Path.Combine(root, "presets"),
                Path.Combine(root, "settings.json"),
                Path.Combine(root, "host.patch.yml"),
                Path.Combine(root, "trust.json"),
                Path.Combine(root, "models"),
                Path.Combine(root, "runtime"));
            paths.Ensure();
            var folder = Path.Combine(paths.Plugins, VisionFallbackDefaults.PluginId);
            Directory.CreateDirectory(folder);
            File.WriteAllText(Path.Combine(folder, "plugin.yml"), """
                id: dots.vision-fallback
                name: Vision fallback
                version: 1.0.0
                abi: 1.0.0
                plane: host
                """);

            var catalog = new PluginRuntime.PluginCatalog(paths);
            catalog.Refresh();
            var document = CompositionLoader.LoadHost(paths, catalog);

            Assert.Contains(document.Entries, entry => entry.Plugin == VisionFallbackDefaults.PluginId);
        }
        finally
        {
            if (Directory.Exists(root)) Directory.Delete(root, recursive: true);
        }
    }
}

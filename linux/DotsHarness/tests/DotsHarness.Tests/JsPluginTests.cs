// Copyright (c) 2026 DOTS
// Legacy JavaScript/declarative packages are rejected by the native-only catalog.

using System;
using System.IO;
using System.Linq;
using DotsHarnessCore;
using HarnessPluginKit;
using PluginRuntime;
using Xunit;

namespace DotsHarness.Tests;

public sealed class JsPluginTests
{
    [Fact]
    public void LegacyJavaScriptPluginIsNotLoadable()
    {
        var paths = TemporaryPaths();
        WritePlugin(paths, "com.example.legacy-js", """
            id: com.example.legacy-js
            name: Legacy JS
            version: 0.1.0
            plane: session
            main: plugin.js
            """);

        var catalog = new PluginCatalog(paths);
        catalog.Refresh();
        var entry = catalog.Entries.First(e => e.Manifest.Id == "com.example.legacy-js");
        Assert.False(entry.Enabled);
        Assert.Contains("native", entry.Broken ?? "", StringComparison.OrdinalIgnoreCase);

        var host = new PluginHost(catalog);
        var issues = host.Mount(new CompositionDocument(PluginPlane.Session, new[]
        {
            new CompositionEntry("legacy", "com.example.legacy-js"),
        }));
        Assert.Single(issues);
    }

    [Fact]
    public void ManifestOnlyPluginIsNotLoadable()
    {
        var paths = TemporaryPaths();
        WritePlugin(paths, "com.example.legacy-manifest", """
            id: com.example.legacy-manifest
            name: Legacy Manifest
            version: 0.1.0
            plane: session
            """);

        var catalog = new PluginCatalog(paths);
        catalog.Refresh();
        var entry = catalog.Entries.First(e => e.Manifest.Id == "com.example.legacy-manifest");
        Assert.False(entry.Enabled);
        Assert.Contains("native", entry.Broken ?? "", StringComparison.OrdinalIgnoreCase);
    }

    private static void WritePlugin(SupportPaths paths, string id, string manifest)
    {
        var folder = Path.Combine(paths.Plugins, id);
        Directory.CreateDirectory(folder);
        File.WriteAllText(Path.Combine(folder, "plugin.yml"), manifest);
    }

    private static SupportPaths TemporaryPaths()
    {
        var root = Path.Combine(Path.GetTempPath(), $"DotsHarnessNativeOnlyTests-{Guid.NewGuid()}");
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
}

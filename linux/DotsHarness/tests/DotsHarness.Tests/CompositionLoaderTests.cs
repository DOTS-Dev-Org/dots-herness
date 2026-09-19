// Copyright (c) 2026 DOTS
// Installed plugins must land in the mounted composition without a host.patch.yml.

using System;
using System.IO;
using System.Linq;
using DotsHarnessCore;
using HarnessPluginKit;
using PluginRuntime;
using Xunit;

namespace DotsHarness.Tests;

public sealed class CompositionLoaderTests
{
    [Fact]
    public void LegacyManifestPluginIsComposedDisabled()
    {
        var paths = TemporaryPaths();
        WriteNote(paths);

        var catalog = new PluginCatalog(paths);
        catalog.Refresh();
        var document = CompositionLoader.LoadHost(paths, catalog);

        var entry = document.Entries.FirstOrDefault(e => e.Plugin == "com.example.note");
        Assert.NotNull(entry);
        Assert.True(entry!.Disabled);

        var host = new PluginHost(catalog);
        Assert.Empty(host.Mount(document));
        Assert.DoesNotContain("Remember the note plugin.", host.Prompt.AssembledText());
    }

    [Fact]
    public void DisabledCatalogEntryIsComposedDisabled()
    {
        var paths = TemporaryPaths();
        WriteNote(paths);

        var catalog = new PluginCatalog(paths);
        catalog.Refresh();
        catalog.SetEnabled("com.example.note", false);
        var document = CompositionLoader.LoadHost(paths, catalog);

        var entry = document.Entries.FirstOrDefault(e => e.Plugin == "com.example.note");
        Assert.NotNull(entry);
        Assert.True(entry!.Disabled);

        var host = new PluginHost(catalog);
        Assert.Empty(host.Mount(document));
        Assert.DoesNotContain("Remember the note plugin.", host.Prompt.AssembledText());
    }

    private static void WriteNote(SupportPaths paths)
    {
        var folder = Path.Combine(paths.Plugins, "note");
        Directory.CreateDirectory(folder);
        File.WriteAllText(Path.Combine(folder, "plugin.yml"), """
            id: com.example.note
            name: Note
            version: 0.1.0
            abi: 1.0.0
            plane: host
            promptSection:
              name: note:remember
              order: 40
              file: prompt.md
            """);
        File.WriteAllText(Path.Combine(folder, "prompt.md"), "Remember the note plugin.");
    }

    private static SupportPaths TemporaryPaths()
    {
        var root = Path.Combine(Path.GetTempPath(), $"DotsHarnessCompositionTests-{Guid.NewGuid()}");
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

// Copyright (c) 2026 DOTS
// Plugin composition model derived from DeepSeek Harness.
// Copyright (c) 2026 DeepSeek. MIT. See NOTICE.

using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using DotsHarnessCore;
using FableThinkingPlugin;
using HarnessPluginKit;
using PluginRuntime;
using Xunit;

namespace DotsHarness.Tests;

public sealed class PluginContractTests
{
    [Fact]
    public void BundledHostMountsCleanlyWithoutBuiltinPrompt()
    {
        // Fable guidance ships as the bundled fable-thinking skill now, so the
        // default host composition mounts nothing even with the plugin registered.
        var catalog = new PluginCatalog(TemporaryPaths());
        catalog.RegisterBuiltin<FableThinkingPlugin.FableThinkingPlugin>();
        var host = new PluginHost(catalog);
        var issues = host.Mount(CompositionLoader.BundledHost());

        Assert.True(issues.Count == 0, string.Join("; ", issues.Select(issue => issue.Message)));
        Assert.Empty(host.Fibers);
        Assert.DoesNotContain("Fable style", host.Prompt.AssembledText());
    }

    [Fact]
    public void UnmountReversesPromptAndServices()
    {
        var catalog = new PluginCatalog(TemporaryPaths());
        catalog.RegisterBuiltin<FableThinkingPlugin.FableThinkingPlugin>();
        var host = new PluginHost(catalog);
        _ = host.Mount(CompositionLoader.BundledHost());

        host.UnmountAll();

        Assert.Empty(host.Prompt.Sections());
        Assert.Empty(host.Fibers);
    }

    [Fact]
    public void SessionServiceWithoutIsolateIsRejected()
    {
        var catalog = new PluginCatalog(TemporaryPaths());
        catalog.RegisterBuiltin<PublishingPlugin>();
        var host = new PluginHost(catalog);
        var document = new CompositionDocument(PluginPlane.Session, new[]
        {
            new CompositionEntry("pub", "dots.test-publisher"),
        });

        var issues = host.Mount(document);

        Assert.Single(issues);
        Assert.Contains("process-global service", issues[0].Message);
        Assert.Empty(host.Fibers);
    }

    [Fact]
    public void SessionServiceWithIsolateMounts()
    {
        var catalog = new PluginCatalog(TemporaryPaths());
        catalog.RegisterBuiltin<PublishingPlugin>();
        var host = new PluginHost(catalog);
        var document = new CompositionDocument(PluginPlane.Session, new[]
        {
            new CompositionEntry("pub", "dots.test-publisher", Isolate: new Dictionary<string, bool> { ["demo"] = true }),
        });

        var issues = host.Mount(document);

        Assert.True(issues.Count == 0, string.Join("; ", issues.Select(issue => issue.Message)));
        Assert.Single(host.Fibers);
    }

    [Fact]
    public void ManifestOnlyUserPluginIsRejected()
    {
        var paths = TemporaryPaths();
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

        var catalog = new PluginCatalog(paths);
        catalog.Refresh();
        Assert.Single(catalog.Entries.Where(entry => entry.Manifest.Id == "com.example.note"));

        var host = new PluginHost(catalog);
        var document = new CompositionDocument(PluginPlane.Host, new[]
        {
            new CompositionEntry("note", "com.example.note"),
        });
        var issues = host.Mount(document);

        Assert.Single(issues);
        Assert.Contains("native", issues[0].Message, StringComparison.OrdinalIgnoreCase);
        Assert.Empty(host.Fibers);
    }

    [Fact]
    public void UntrustedDylibIsRejected()
    {
        var paths = TemporaryPaths();
        var folder = Path.Combine(paths.Plugins, "hello");
        Directory.CreateDirectory(folder);
        File.WriteAllText(Path.Combine(folder, "plugin.yml"), """
            id: com.example.hello
            name: Hello
            version: 0.1.0
            abi: 1.0.0
            plane: session
            library: HelloPlugin.dll
            """);
        File.WriteAllText(Path.Combine(folder, "HelloPlugin.dll"), "placeholder");

        var catalog = new PluginCatalog(paths);
        catalog.Refresh();
        var host = new PluginHost(catalog);
        var document = new CompositionDocument(PluginPlane.Session, new[]
        {
            new CompositionEntry("hello", "com.example.hello"),
        });
        var issues = host.Mount(document);

        Assert.Single(issues);
        Assert.Contains("untrusted", issues[0].Message);
    }

    private static SupportPaths TemporaryPaths()
    {
        var root = Path.Combine(Path.GetTempPath(), $"DotsHarnessTests-{Guid.NewGuid()}");
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

public sealed class PublishingPlugin : IDefaultPlugin
{
    public PluginManifest Manifest { get; } = new(
        "dots.test-publisher",
        "Publisher",
        "1.0.0",
        PluginPlane.Session,
        Description: "Test-only service publisher");

    public void Apply(IPluginContext ctx) => ctx.Provide("demo", "value");
}

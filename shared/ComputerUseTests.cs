using System.Text.Json.Nodes;
using DotsHarnessCore;
using PluginRuntime;
using Xunit;

namespace DotsHarness.Tests;

public sealed class ComputerUseTests : IDisposable
{
    private readonly string _root = Path.Combine(Path.GetTempPath(), "HerNessComputerUseTests-" + Guid.NewGuid());
    public ComputerUseTests() => Directory.CreateDirectory(_root);

    [Fact]
    public void DisabledToolsAreHiddenAndEnablingAlsoWorksWithoutAProject()
    {
        var paths = new SupportPaths(_root, Path.Combine(_root, "plugins"), Path.Combine(_root, "presets"),
            Path.Combine(_root, "settings.json"), Path.Combine(_root, "host.patch.yml"), Path.Combine(_root, "trust.json"),
            Path.Combine(_root, "models"), Path.Combine(_root, "runtime"));
        using var router = new RouterController(paths);
        var bridge = new AgentBridge(router, paths);
        Assert.DoesNotContain(bridge.ToolsFor(false, true), tool => tool.Name == ComputerUseTools.ToolName);
        bridge.IsComputerUseEnabled = true;
        Assert.Contains(bridge.ToolsFor(false, true), tool => tool.Name == ComputerUseTools.ToolName);
        Assert.True(AgentBridge.PlanWithholds(ComputerUseTools.ToolName));
        Assert.Contains("list_windows", bridge.EffectiveSystemPromptReport());
        bridge.IsComputerUseEnabled = false;
        Assert.DoesNotContain(bridge.ToolsFor(false, true), tool => tool.Name == ComputerUseTools.ToolName);
    }

    [Fact]
    public async Task InvalidActionCannotProduceAFalseSuccessOrImage()
    {
        var result = await ComputerUseService.ExecuteWithResultAsync(new JsonObject { ["action"] = "dance" }, _root);
        Assert.Equal("Missing or invalid action for computer_use.", result.Text);
        Assert.Null(result.Attachment);
    }

    [Fact]
    public void ScreenshotCarriesImageAndWindowOriginInsteadOfOnlyAFilePath()
    {
        var path = Path.Combine(_root, "capture.png");
        File.WriteAllBytes(path, Convert.FromBase64String("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aN1cAAAAASUVORK5CYII="));
        var outcome = ComputerUseService.ScreenshotResult(path, new(-100, 20, 1, 1));
        Assert.NotNull(outcome.Attachment);
        Assert.Equal("image/png", outcome.Attachment.MimeType);
        Assert.Equal(path, outcome.Attachment.FilePath);
        var metadata = JsonNode.Parse(outcome.Text)!;
        Assert.Equal(-100, metadata["screen_frame"]!["x"]!.GetValue<int>());
        Assert.Equal(1, metadata["image_size"]!["width"]!.GetValue<int>());
        var export = Path.Combine(_root, "export.png");
        ComputerUseService.ScreenshotResult(path, null, export);
        Assert.Equal(File.ReadAllBytes(path), File.ReadAllBytes(export));
        Assert.Throws<IOException>(() => ComputerUseService.ScreenshotResult(path, null, export));
    }

    [Fact]
    public void MissingOrInvalidCaptureNeverBecomesAnImageAttachment()
    {
        var path = Path.Combine(_root, "bad.png");
        File.WriteAllText(path, "capture failed");
        Assert.Throws<InvalidOperationException>(() => ComputerUseService.ScreenshotResult(path, null));
        Assert.Throws<FileNotFoundException>(() => ComputerUseService.ScreenshotResult(Path.Combine(_root, "missing.png"), null));
    }

    [Fact]
    public void ExportCannotEscapeWorkspaceOrOverwriteFiles()
    {
        Assert.Null(ComputerUseService.ExportDestination(null, _root));
        Assert.Throws<ArgumentException>(() => ComputerUseService.ExportDestination("capture.png", ""));
        Assert.Throws<ArgumentException>(() => ComputerUseService.ExportDestination("source.cs", _root));
        Assert.ThrowsAny<Exception>(() => ComputerUseService.ExportDestination("../outside.png", _root));
        Assert.Throws<ArgumentException>(() => ComputerUseService.ExportDestination(Path.Combine(_root, "absolute.png"), _root));
        File.WriteAllText(Path.Combine(_root, "existing.png"), "source file");
        Assert.Throws<ArgumentException>(() => ComputerUseService.ExportDestination("existing.png", _root));
        Assert.EndsWith(Path.Combine(Path.GetFileName(_root), "capture.png"), ComputerUseService.ExportDestination("capture.png", _root));
    }

    [Fact]
    public void WindowsShortcutsUseKeyEventsAndRejectUnknownKeys()
    {
        Assert.Equal(new ushort[] { 0x11, 0x41 }, ComputerUseService.WindowsKeys("ctrl+a"));
        Assert.Equal(new ushort[] { 0x12, 0x09 }, ComputerUseService.WindowsKeys("alt+Tab"));
        Assert.Equal(new ushort[] { 0x0D }, ComputerUseService.WindowsKeys("Return"));
        Assert.Throws<ArgumentException>(() => ComputerUseService.WindowsKeys("ctrl+not-a-key"));
        Assert.Throws<ArgumentException>(() => ComputerUseService.WindowsKeys(""));
    }

    public void Dispose() { Directory.Delete(_root, recursive: true); }
}

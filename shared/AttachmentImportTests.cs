using System;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using DotsHarnessCore;
using PluginRuntime;
using Xunit;

namespace DotsHarness.Tests;

public sealed class AttachmentImportTests : IDisposable
{
    private readonly string _root = Path.Combine(Path.GetTempPath(), $"DotsHarnessAttachments-{Guid.NewGuid():N}");

    [Fact]
    public async Task AddDraftAttachmentsAsyncPreservesFileOrder()
    {
        var paths = Paths();
        var first = Path.Combine(_root, "first.txt");
        var second = Path.Combine(_root, "second.txt");
        File.WriteAllText(first, "first");
        File.WriteAllText(second, "second");
        var model = new AppModel(paths);

        await model.AddDraftAttachmentsAsync([second, first]);

        Assert.Equal(
            new[] { Path.GetFullPath(second), Path.GetFullPath(first) },
            model.DraftAttachments.Select(attachment => attachment.FilePath));
    }

    [Fact]
    public async Task AddDraftImageDataAsyncStoresARecognizedImageAttachment()
    {
        var model = new AppModel(Paths());
        var imageData = new byte[] { 0x89, 0x50, 0x4E, 0x47 };

        Assert.True(await model.AddDraftImageDataAsync(imageData, "png"));

        var attachment = Assert.Single(model.DraftAttachments);
        Assert.Equal(ChatAttachmentKind.Image, attachment.Kind);
        Assert.Equal(imageData, File.ReadAllBytes(attachment.FilePath));
    }

    private SupportPaths Paths()
    {
        Directory.CreateDirectory(_root);
        return new SupportPaths(
            _root,
            Path.Combine(_root, "plugins"),
            Path.Combine(_root, "presets"),
            Path.Combine(_root, "settings.json"),
            Path.Combine(_root, "host.patch.yml"),
            Path.Combine(_root, "trust.json"),
            Path.Combine(_root, "models"),
            Path.Combine(_root, "runtime"));
    }

    public void Dispose()
    {
        try { Directory.Delete(_root, recursive: true); } catch { }
    }
}

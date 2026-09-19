using System;
using System.IO;
using DotsHarnessCore;
using Xunit;

namespace DotsHarness.Tests;

public sealed class PlatformProviderSecretsTests : IDisposable
{
    private readonly string _root = Path.Combine(Path.GetTempPath(), $"DotsHarnessSecrets-{Guid.NewGuid():N}");

    [Fact]
    public void FallbackRoundTripUsesPrivateModes()
    {
        var store = new PlatformProviderSecrets(_root);
        var directory = Path.Combine(_root, "provider-secrets");

        Assert.Equal(UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute, File.GetUnixFileMode(directory));
        store.Write("voice.api.key", "test-secret");
        Assert.Equal("test-secret", store.Read("voice.api.key"));

        var files = Directory.GetFiles(directory);
        if (files.Length == 1)
        {
            Assert.Equal(UnixFileMode.UserRead | UnixFileMode.UserWrite, File.GetUnixFileMode(files[0]));
        }

        store.Delete("voice.api.key");
        Assert.Null(store.Read("voice.api.key"));
    }

    public void Dispose()
    {
        try { Directory.Delete(_root, recursive: true); } catch { }
    }
}

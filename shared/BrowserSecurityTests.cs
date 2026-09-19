using System.Diagnostics;
using DotsHarnessCore;
using Xunit;

namespace DotsHarness.Tests;

public sealed class BrowserSecurityTests : IDisposable
{
    private readonly string _root = Path.Combine(Path.GetTempPath(), $"DotsHarnessBrowserTests-{Guid.NewGuid():N}");

    public BrowserSecurityTests() => Directory.CreateDirectory(_root);

    [Fact]
    public void BackendSelectionUsesOnlyExplicitUserRules()
    {
        Assert.Equal(BrowserBackend.Unknown, BrowserBackendPolicy.ResolveUserRule("siteyi aç"));
        Assert.Equal(BrowserBackend.Extension, BrowserBackendPolicy.ResolveUserRule("mevcut Chrome profilimi kullan"));
        Assert.Equal(BrowserBackend.Managed, BrowserBackendPolicy.ResolveUserRule("izole managed browser kullan"));
        Assert.Equal(BrowserBackend.Managed, BrowserBackendPolicy.ParseConfirmation("Managed isolated browser"));
        Assert.Equal(BrowserBackend.Extension, BrowserBackendPolicy.ParseConfirmation("Existing Chrome profile"));
        Assert.Equal(BrowserBackend.Unknown, BrowserBackendPolicy.ParseConfirmation("release 12"));
    }

    [Fact]
    public void StrictCommandSandboxFailsClosedWhenProviderIsUnavailable()
    {
        var info = new ProcessStartInfo { FileName = "sh" };
        var configured = AgentCommandSandbox.TryConfigure(info, _root, out var error);
        if (!AgentCommandSandbox.IsAvailable)
        {
            Assert.False(configured);
            Assert.Contains(AgentCommandSandbox.UnavailableCode, error, StringComparison.Ordinal);
        }
        else
        {
            Assert.True(configured, error);
            Assert.Contains("bwrap", info.FileName, StringComparison.OrdinalIgnoreCase);
        }
    }

    [Fact]
    public async Task ModelCannotChooseBackendOrCloseAnotherScope()
    {
        var manager = new BrowserSessionManager(_root);
        var scope = new BrowserScope("coding", "conversation", "run");
        var call = new NativeToolCall(
            "call",
            BrowserTools.OpenName,
            "{\"url\":\"https://example.com\",\"backend\":\"Extension\"}");
        var result = await manager.ExecuteAsync(call, scope, BrowserBackend.Managed);
        Assert.Contains("backend is selected by the host", result, StringComparison.Ordinal);
        await Assert.ThrowsAsync<InvalidOperationException>(() =>
            manager.ClosePageAsync(new BrowserScope("chat", "conversation", "other-run"), "foreign-page"));
    }

    public void Dispose()
    {
        try { Directory.Delete(_root, recursive: true); } catch { }
    }
}

using System;
using System.IO;
using DotsHarnessCore;
using PluginRuntime;
using Xunit;

namespace DotsHarness.Tests;

public sealed class VoiceCredentialTests : IDisposable
{
    private readonly string _root = Path.Combine(Path.GetTempPath(), $"DotsHarnessVoice-{Guid.NewGuid():N}");

    [Fact]
    public void LegacyVoiceKeyMovesToSecureStoreBeforeSettingsRemoval()
    {
        // The Windows secret store is DPAPI (crypt32.dll); nothing to verify on other hosts.
        if (!OperatingSystem.IsWindows()) return;
        var paths = Paths();
        File.WriteAllText(paths.Settings, "{\"voice.api.key\":\"legacy-voice-secret\"}");

        var model = new AppModel(paths);

        Assert.Equal("legacy-voice-secret", model.VoiceApiKey);
        Assert.Equal("legacy-voice-secret", model.Router.Store.Secrets.Read("voice.api.key"));
        Assert.DoesNotContain("voice.api.key", File.ReadAllText(paths.Settings), StringComparison.Ordinal);

        model.SetVoiceApiKey("new-voice-secret");
        Assert.Equal("new-voice-secret", model.Router.Store.Secrets.Read("voice.api.key"));
        Assert.DoesNotContain("new-voice-secret", File.ReadAllText(paths.Settings), StringComparison.Ordinal);
    }

    [Fact]
    public void FailedMigrationKeepsPlaintextSettingForRetry()
    {
        var paths = Paths();
        File.WriteAllText(paths.Settings, "{\"voice.api.key\":\"legacy-voice-secret\"}");

        var model = new AppModel(paths, providerSecrets: new FailingProviderSecretStore());

        Assert.Equal("legacy-voice-secret", model.VoiceApiKey);
        Assert.Contains("voice.api.key", File.ReadAllText(paths.Settings), StringComparison.Ordinal);
        Assert.Contains("migration failed", model.Router.Error, StringComparison.OrdinalIgnoreCase);
    }

    private sealed class FailingProviderSecretStore : IProviderSecretStore
    {
        public string? Read(string id) => null;
        public void Write(string id, string value) => throw new InvalidOperationException("vault unavailable");
        public void Delete(string id) => throw new InvalidOperationException("vault unavailable");
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

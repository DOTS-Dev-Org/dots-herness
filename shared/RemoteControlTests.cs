using System.Text.Json.Nodes;
using Xunit;

namespace DotsHarnessCore;

public sealed class RemoteControlTests : IDisposable
{
    private readonly string _root = Path.Combine(Path.GetTempPath(), "dots-remote-" + Guid.NewGuid().ToString("N"));

    public RemoteControlTests()
    {
        Directory.CreateDirectory(_root);
    }

    [Fact]
    public void EventHub_keeps_ordered_replay_and_artifacts()
    {
        using var hub = new RemoteControlEventHub(_root);
        var first = hub.Publish("run.started", "workspace", "session", new JsonObject { ["turnId"] = "1" });
        var second = hub.PublishText("tool.output", "workspace", "session", new string('x', 800));

        var replay = hub.Since(first.Sequence, "workspace");

        Assert.Single(replay);
        Assert.Equal(second.Sequence, replay[0].Sequence);
        Assert.NotNull(second.ArtifactId);
        Assert.Equal("Output captured in a local artifact.", second.Payload["preview"]?.GetValue<string>());
        Assert.DoesNotContain("x", second.Payload["preview"]?.GetValue<string>() ?? "", StringComparison.Ordinal);
        Assert.True(hub.Artifacts.TryOpen(second.ArtifactId!, out var artifact));
        Assert.Equal(800, new FileInfo(artifact).Length);
    }

    [Fact]
    public void EventHub_redacts_secrets_from_payloads()
    {
        using var hub = new RemoteControlEventHub(_root);

        var item = hub.Publish(
            "connection.changed",
            "workspace",
            "session",
            new JsonObject { ["apiKey"] = "sk-live-value", ["note"] = "Bearer live-token-value" });

        Assert.True(item.Redacted);
        Assert.Equal("[redacted]", item.Payload["apiKey"]?.GetValue<string>());
        Assert.Equal("[redacted]", item.Payload["note"]?.GetValue<string>());
    }

    [Fact]
    public void Snapshot_includes_dotfiles_but_excludes_secrets_and_generated_output()
    {
        File.WriteAllText(Path.Combine(_root, ".env"), "TOKEN=do-not-copy");
        File.WriteAllText(Path.Combine(_root, ".editorconfig"), "root=true");
        File.WriteAllText(Path.Combine(_root, "main.swift"), "print(\"ok\")");
        Directory.CreateDirectory(Path.Combine(_root, "node_modules"));
        File.WriteAllText(Path.Combine(_root, "node_modules", "ignored.js"), "ignored");

        var snapshot = RemoteWorkspace.CreateSnapshot(_root, "workspace", 3);

        Assert.Contains(snapshot.Files, file => file.Path == ".editorconfig");
        Assert.Contains(snapshot.Files, file => file.Path == "main.swift");
        Assert.DoesNotContain(snapshot.Files, file => file.Path == ".env");
        Assert.Contains(snapshot.Excluded, item => item.Path == ".env");
        Assert.Contains(snapshot.Excluded, item => item.Path == "node_modules");
    }

    [Fact]
    public void WriteText_rejects_stale_revision_and_path_escape()
    {
        var file = Path.Combine(_root, "main.kt");
        File.WriteAllText(file, "old");
        var current = Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(System.Text.Encoding.UTF8.GetBytes("old"))).ToLowerInvariant();

        var conflict = RemoteWorkspace.WriteText(_root, "main.kt", "new", "wrong");
        var written = RemoteWorkspace.WriteText(_root, "main.kt", "new", current);

        Assert.True(conflict.Conflict);
        Assert.True(written.Written);
        Assert.Equal("new", File.ReadAllText(file));
        Assert.Throws<InvalidOperationException>(() => RemoteWorkspace.WriteText(_root, "../outside.txt", "bad", null));
    }

    [Fact]
    public void Build_artifacts_are_limited_to_generated_output_and_listed()
    {
        var artifactPath = Path.Combine(_root, "build", "app-debug.apk");
        Directory.CreateDirectory(Path.GetDirectoryName(artifactPath)!);
        File.WriteAllBytes(artifactPath, [1, 2, 3]);

        Assert.Equal([1, 2, 3], RemoteWorkspace.ReadArtifact(_root, "build/app-debug.apk"));
        Assert.Throws<InvalidOperationException>(() => RemoteWorkspace.ReadArtifact(_root, "main.kt"));

        using var hub = new RemoteControlEventHub(_root);
        var id = hub.Artifacts.Save("build-artifact", [4, 5]);
        Assert.Contains(hub.Artifacts.List(), item => item.Id == id && item.Kind == "build-artifact" && item.Bytes == 2);
    }

    [Fact]
    public void Pairing_payload_contains_endpoint_and_code_but_not_token()
    {
        var pairing = new RemotePairingStore(_root, "workspace", new MemoryProviderSecretStore());
        var challenge = pairing.Begin("https://desktop.example.test:18768");

        Assert.StartsWith("herness://pair?", challenge.Payload, StringComparison.Ordinal);
        Assert.Contains($"endpoint={Uri.EscapeDataString(challenge.Endpoint)}", challenge.Payload, StringComparison.Ordinal);
        Assert.Contains($"code={challenge.Code}", challenge.Payload, StringComparison.Ordinal);
        Assert.DoesNotContain("token", challenge.Payload, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void Pairing_is_one_time_and_revocable()
    {
        var pairing = new RemotePairingStore(_root, "workspace", new MemoryProviderSecretStore());
        var challenge = pairing.Begin("http://127.0.0.1:18768");
        var result = pairing.Complete(challenge.Code, "My phone");

        Assert.NotNull(result);
        Assert.True(pairing.Authenticate(
            new Dictionary<string, string> { ["authorization"] = "Bearer " + result!.Token },
            out var deviceId));
        Assert.Equal(result.DeviceId, deviceId);
        Assert.Null(pairing.Complete(challenge.Code, "Replay"));
        Assert.True(pairing.Revoke(result.DeviceId));
        Assert.False(pairing.Authenticate(
            new Dictionary<string, string> { ["authorization"] = "Bearer " + result.Token },
            out _));
    }

    public void Dispose()
    {
        try { Directory.Delete(_root, recursive: true); } catch { }
    }
}

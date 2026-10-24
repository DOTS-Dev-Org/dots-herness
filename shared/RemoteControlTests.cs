using System.Security.Cryptography;
using System.Text;
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
    public async Task Gateway_serves_only_TLS_with_a_stable_pinned_certificate()
    {
        var certificate = RemoteTls.LoadOrCreate(_root);
        var fingerprint = RemoteTls.Fingerprint(certificate);
        Assert.Equal(fingerprint, RemoteTls.Fingerprint(RemoteTls.LoadOrCreate(_root)));

        var probe = new System.Net.Sockets.TcpListener(System.Net.IPAddress.Loopback, 0);
        probe.Start(); var port = ((System.Net.IPEndPoint)probe.LocalEndpoint).Port; probe.Stop();
        using var gateway = new RemoteControlGateway(port, async (_, stream, ct) =>
            await stream.WriteAsync("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok"u8.ToArray(), ct), certificate);
        gateway.Start();

        using var pinned = new HttpClient(new HttpClientHandler
        {
            ServerCertificateCustomValidationCallback = (_, cert, _, _) => cert is not null && RemoteTls.Fingerprint(cert) == fingerprint,
        });
        Assert.Equal("ok", await pinned.GetStringAsync($"https://127.0.0.1:{port}/"));

        using var plain = new HttpClient { Timeout = TimeSpan.FromSeconds(15) };
        await Assert.ThrowsAnyAsync<Exception>(() => plain.GetStringAsync($"http://127.0.0.1:{port}/"));
        using var unpinned = new HttpClient();
        await Assert.ThrowsAsync<HttpRequestException>(() => unpinned.GetStringAsync($"https://127.0.0.1:{port}/"));
    }

    [Fact]
    public void EventHub_numbers_stay_above_a_previous_run()
    {
        // A phone resumes with ?after=<last seen>; a restarted desktop must not
        // start again at 1 or the phone sees nothing until the counter catches up.
        long previous;
        using (var before = new RemoteControlEventHub(_root)) previous = before.Publish("run.started", "workspace").Sequence;
        // The seed is the millisecond clock; a real restart takes far longer than one tick.
        Thread.Sleep(2);
        using var after = new RemoteControlEventHub(_root);
        Assert.True(after.Publish("run.started", "workspace").Sequence > previous);
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
        Assert.Contains($"k={pairing.SealingSecret(RemoteSealed.PairingDevice)}", challenge.Payload, StringComparison.Ordinal);
    }

    [Fact]
    public void Sealed_channel_matches_the_reference_vectors()
    {
        // Produced by CryptoKit (the macOS/iOS code path); Android checks the same bytes.
        var key = RemoteSealed.Key("secret");
        var frame = Convert.FromBase64String("AQIDBAUGBwgJCgsM2/e9qfr3KS76oXJIHzrpD6fBFZma");
        Assert.Equal("hello"u8.ToArray(), RemoteSealed.Unseal(key, frame, RemoteSealed.FrameAad(new byte[12], 1)));
        Assert.Null(RemoteSealed.Unseal(key, frame, RemoteSealed.FrameAad(new byte[12], 2)));

        var opened = RemoteSealed.Open(Convert.FromBase64String("AQIDBAUGBwgJCgsMs5LQSmqEPVAuXvXvLhsxJfIUIJ9mu791xzxrNZODNSY2/uTUfLrjHY0x"), key, "device");
        Assert.NotNull(opened);
        Assert.Equal(0x0000018FFF000000, opened!.Timestamp);
        Assert.Equal("GET / HTTP/1.1\r\n\r\n", Encoding.UTF8.GetString(opened.Request));
        Assert.Null(RemoteSealed.Open(Convert.FromBase64String("AQIDBAUGBwgJCgsMs5LQSmqEPVAuXvXvLhsxJfIUIJ9mu791xzxrNZODNSY2/uTUfLrjHY0x"), key, "other"));
    }

    [Fact]
    public async Task Sealed_stream_frames_decrypt_in_order_and_end_with_an_empty_frame()
    {
        var key = RemoteSealed.Key("secret");
        var nonce = RandomNumberGenerator.GetBytes(12);
        var output = new MemoryStream();
        await using (var channel = new RemoteSealedStream(output, key, nonce))
            await channel.WriteAsync(Encoding.UTF8.GetBytes("HTTP/1.1 200 OK\r\n\r\n" + new string('x', 70_000)));

        var text = Encoding.ASCII.GetString(output.ToArray());
        Assert.StartsWith(RemoteSealed.Header, text, StringComparison.Ordinal);
        Assert.DoesNotContain("HTTP/1.1 200 OK\r\n\r\nx", text[RemoteSealed.Header.Length..], StringComparison.Ordinal);
        var chunks = text[RemoteSealed.Header.Length..].Split('\n', StringSplitOptions.RemoveEmptyEntries)
            .Select((line, index) => RemoteSealed.Unseal(key, Convert.FromBase64String(line), RemoteSealed.FrameAad(nonce, (uint)index))!)
            .ToArray();
        Assert.Equal(3, chunks.Length);
        Assert.Empty(chunks[^1]);
        Assert.Equal(70_000 + 19, chunks.Sum(chunk => chunk.Length));
    }

    [Fact]
    public async Task Host_answers_only_sealed_requests_end_to_end()
    {
        var paths = new PluginRuntime.SupportPaths(_root, Path.Combine(_root, "plugins"), Path.Combine(_root, "presets"),
            Path.Combine(_root, "settings.json"), Path.Combine(_root, "host.patch.yml"), Path.Combine(_root, "trust.json"),
            Path.Combine(_root, "models"), Path.Combine(_root, "runtime"));
        using var router = new RouterController(paths);
        using var host = new RemoteControlHost(new AgentBridge(router, paths), paths, new RemoteControlEventHub(_root), () => _root);
        var handle = (Func<RemoteHttpRequest, Stream, CancellationToken, Task>)Delegate.CreateDelegate(typeof(Func<RemoteHttpRequest, Stream, CancellationToken, Task>), host,
            typeof(RemoteControlHost).GetMethod("HandleAsync", System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Instance)!);
        var qrSecret = System.Web.HttpUtility.ParseQueryString(new Uri(host.BeginPairing("https://desktop.example.test:18768").Payload.Replace("herness://pair", "https://x/")).Query)["k"]!;
        var code = host.Pairing!.Code;

        byte[] Seal(string secret, string device, string raw, out byte[] nonce)
        {
            nonce = RandomNumberGenerator.GetBytes(12);
            var plain = new byte[8];
            System.Buffers.Binary.BinaryPrimitives.WriteInt64BigEndian(plain, DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());
            return RemoteSealed.Seal(RemoteSealed.Key(secret), nonce, [.. plain, .. Encoding.UTF8.GetBytes(raw)], Encoding.UTF8.GetBytes(device));
        }
        async Task<string> Send(string device, byte[] body)
        {
            var output = new MemoryStream();
            await handle(new RemoteHttpRequest("POST", RemoteSealed.Path, RemoteSealed.Path, new Dictionary<string, string> { ["x-herness-device"] = device }, body), output, CancellationToken.None);
            return Encoding.ASCII.GetString(output.ToArray());
        }
        string Open(string secret, byte[] nonce, string reply)
        {
            Assert.StartsWith(RemoteSealed.Header, reply, StringComparison.Ordinal);
            var chunks = reply[RemoteSealed.Header.Length..].Split('\n', StringSplitOptions.RemoveEmptyEntries)
                .Select((line, index) => RemoteSealed.Unseal(RemoteSealed.Key(secret), Convert.FromBase64String(line), RemoteSealed.FrameAad(nonce, (uint)index))!).ToArray();
            Assert.Empty(chunks[^1]);
            return Encoding.UTF8.GetString(chunks.SelectMany(chunk => chunk).ToArray());
        }

        var pairBody = $"{{\"code\":\"{code}\",\"deviceName\":\"Phone\"}}";
        var pairRequest = Seal(qrSecret, RemoteSealed.PairingDevice, $"POST /v1/control/pair/complete HTTP/1.1\r\nContent-Length: {pairBody.Length}\r\n\r\n{pairBody}", out var pairNonce);
        var pairReply = await Send(RemoteSealed.PairingDevice, pairRequest);
        var paired = JsonNode.Parse(Open(qrSecret, pairNonce, pairReply).Split("\r\n\r\n", 2)[1])!;
        var token = paired["token"]!.GetValue<string>();
        var deviceId = paired["deviceId"]!.GetValue<string>();
        Assert.DoesNotContain(token, pairReply, StringComparison.Ordinal);

        // The same sealed bytes again: refused, and in the clear only a fixed message.
        Assert.StartsWith("HTTP/1.1 401", await Send(RemoteSealed.PairingDevice, pairRequest), StringComparison.Ordinal);

        var bootstrap = Seal(token, deviceId, "GET /v1/control/bootstrap HTTP/1.1\r\n\r\n", out var bootstrapNonce);
        Assert.StartsWith("HTTP/1.1 200", Open(token, bootstrapNonce, await Send(deviceId, bootstrap)), StringComparison.Ordinal);

        // A device cannot borrow another name, and the old plain API is gone.
        Assert.StartsWith("HTTP/1.1 401", await Send("someone-else", Seal(token, "someone-else", "GET /v1/control/bootstrap HTTP/1.1\r\n\r\n", out _)), StringComparison.Ordinal);
        var plainOutput = new MemoryStream();
        await handle(new RemoteHttpRequest("GET", "/v1/control/bootstrap", "/v1/control/bootstrap", new Dictionary<string, string> { ["authorization"] = "Bearer " + token }, []), plainOutput, CancellationToken.None);
        Assert.StartsWith("HTTP/1.1 401", Encoding.ASCII.GetString(plainOutput.ToArray()), StringComparison.Ordinal);
    }

    [Fact]
    public void Replay_guard_accepts_a_request_once_and_only_while_fresh()
    {
        var guard = new RemoteSealed.ReplayGuard();
        var now = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        var nonce = RandomNumberGenerator.GetBytes(12);
        Assert.True(guard.IsFresh(nonce, now));
        Assert.False(guard.IsFresh(nonce, now));
        Assert.False(guard.IsFresh(RandomNumberGenerator.GetBytes(12), now - 600_000));
    }

    [Fact]
    public void Sealing_secret_is_the_live_qr_secret_or_a_trusted_device_token()
    {
        var pairing = new RemotePairingStore(_root, "workspace", new MemoryProviderSecretStore());
        var challenge = pairing.Begin("https://desktop.example.test:18768");
        var qrSecret = pairing.SealingSecret(RemoteSealed.PairingDevice);
        Assert.False(string.IsNullOrEmpty(qrSecret));
        var result = pairing.Complete(challenge.Code, "Phone")!;
        Assert.Null(pairing.SealingSecret(RemoteSealed.PairingDevice));
        Assert.Equal(result.Token, pairing.SealingSecret(result.DeviceId));
        Assert.Null(pairing.SealingSecret("unknown"));
        pairing.Revoke(result.DeviceId);
        Assert.Null(pairing.SealingSecret(result.DeviceId));
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

// Copyright (c) 2026 DOTS
// Versioned, workspace-scoped control plane shared by the Windows and Linux hosts.

using System.Collections.Concurrent;
using System.Net;
using System.Net.Security;
using System.Net.Sockets;
using System.Runtime.CompilerServices;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization;
using PluginRuntime;

namespace DotsHarnessCore;

public enum RemoteAccessMode
{
    Ask,
    Approve,
    Full,
}

public sealed record RemoteControlEvent(
    string Id,
    long Sequence,
    string WorkspaceId,
    string? SessionId,
    DateTimeOffset Timestamp,
    string Kind,
    JsonObject Payload,
    string? ArtifactId = null,
    bool Redacted = false);

public sealed record RemoteControlCommand(
    string Id,
    string WorkspaceId,
    string? SessionId,
    string Kind,
    long? ExpectedRevision,
    JsonObject Payload,
    string? ProjectID = null);

public sealed record RemotePairingInfo(
    string Endpoint,
    string Code,
    string Payload,
    DateTimeOffset ExpiresAt);

public sealed record RemotePairingResult(
    string DeviceId,
    string DeviceName,
    string Token,
    string WorkspaceId);

public sealed record RemoteWorkspaceFile(
    string Path,
    long Bytes,
    string Sha256,
    int Mode);

public sealed record RemoteExcludedPath(string Path, string Reason);

public sealed record RemoteWorkspaceSnapshot(
    int Version,
    string WorkspaceId,
    string Workspace,
    long Revision,
    string? BaseCommitSha,
    IReadOnlyList<RemoteWorkspaceFile> Files,
    IReadOnlyList<RemoteExcludedPath> Excluded,
    DateTimeOffset CreatedAt);

public sealed record RemoteBootstrap(
    int ProtocolVersion,
    string Scope,
    string WorkspaceId,
    string Workspace,
    long Revision,
    string? ConversationId,
    string? Provider,
    string? Model,
    string Status,
    bool IsBusy,
    RemoteAccessMode AccessMode,
    IReadOnlyList<string> Capabilities,
    IReadOnlyList<RemotePairingDevice> Devices,
    string? ProjectID = null,
    // Every address this desktop answers on, tunnel first: a phone keeps the
    // list and falls back to the LAN address when the tunnel URL is gone.
    IReadOnlyList<string>? Endpoints = null);

/// The visible chat of one desktop conversation, so a phone that pairs or
/// reconnects mid-session sees what came before the live event stream.
public sealed record RemoteTranscript(string ConversationId, string Title, bool Running, IReadOnlyList<RemoteTranscriptMessage> Messages);
public sealed record RemoteTranscriptMessage(string Id, string Kind, string Text, DateTimeOffset CreatedAt);

/// A project exposed to a paired device. WorkspacePath is intentionally never
/// serialized: mobile clients need a stable identity and display name, not a
/// host filesystem path.
public sealed record RemoteProjectDescriptor(
    string Id,
    string Name,
    string WorkspaceId,
    string? Branch = null)
{
    [JsonIgnore]
    public string WorkspacePath { get; init; } = "";
}

public sealed record RemoteProjectsResponse(
    int ProtocolVersion,
    string? ProjectID,
    IReadOnlyList<RemoteProjectDescriptor> Projects);

public sealed record RemotePairingDevice(
    string Id,
    string Name,
    DateTimeOffset CreatedAt,
    bool Revoked);

public sealed record RemoteFileWriteResult(
    bool Written,
    bool Conflict,
    string Path,
    string Sha256,
    string? CurrentSha256,
    string Message);

public sealed record RemoteArtifactInfo(
    string Id,
    string Kind,
    long Bytes,
    DateTimeOffset CreatedAt);

public sealed class RemoteControlEventHub : IDisposable
{
    private const int MaximumHistory = 2_000;
    private readonly object _gate = new();
    private readonly List<RemoteControlEvent> _history = [];
    private readonly RemoteArtifactStore _artifacts;
    // Seeded from the clock so a restarted desktop keeps numbering above what a
    // paired phone already saw; a phone resuming with ?after=<old> would
    // otherwise get nothing until the new counter caught up.
    private long _sequence = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
    private bool _disposed;

    public RemoteControlEventHub(string root)
    {
        _artifacts = new RemoteArtifactStore(root);
    }

    public RemoteArtifactStore Artifacts => _artifacts;

    public RemoteControlEvent Publish(
        string kind,
        string workspaceId,
        string? sessionId = null,
        JsonObject? payload = null,
        string? artifactId = null,
        bool redacted = false)
    {
        RemoteControlEvent item;
        var safePayload = SanitizePayload(payload?.DeepClone().AsObject() ?? new JsonObject(), out var payloadRedacted);
        lock (_gate)
        {
            if (_disposed) throw new ObjectDisposedException(nameof(RemoteControlEventHub));
            item = new RemoteControlEvent(
                Guid.NewGuid().ToString("N"),
                ++_sequence,
                workspaceId,
                sessionId,
                DateTimeOffset.UtcNow,
                kind,
                safePayload,
                artifactId,
                redacted || payloadRedacted);
            _history.Add(item);
            if (_history.Count > MaximumHistory) _history.RemoveRange(0, _history.Count - MaximumHistory);
        }
        return item;
    }

    private static JsonObject SanitizePayload(JsonObject payload, out bool redacted)
    {
        redacted = false;
        return SanitizeNode(payload, null, ref redacted)!.AsObject();
    }

    private static JsonNode? SanitizeNode(JsonNode? node, string? key, ref bool redacted)
    {
        if (IsSensitiveKey(key))
        {
            redacted = true;
            return JsonValue.Create("[redacted]");
        }
        if (node is JsonObject obj)
        {
            var safe = new JsonObject();
            foreach (var item in obj) safe[item.Key] = SanitizeNode(item.Value, item.Key, ref redacted);
            return safe;
        }
        if (node is JsonArray array)
        {
            var safe = new JsonArray();
            foreach (var item in array) safe.Add(SanitizeNode(item, key, ref redacted));
            return safe;
        }
        if (node is JsonValue value && value.TryGetValue<string>(out var text))
        {
            var safeText = SanitizeText(text);
            if (!string.Equals(safeText, text, StringComparison.Ordinal)) redacted = true;
            return JsonValue.Create(safeText);
        }
        return node?.DeepClone();
    }

    private static bool IsSensitiveKey(string? key)
    {
        if (string.IsNullOrWhiteSpace(key)) return false;
        var normalized = key.Replace("-", "", StringComparison.Ordinal)
            .Replace("_", "", StringComparison.Ordinal)
            .ToLowerInvariant();
        return normalized is "apikey" or "token" or "accesstoken" or "refreshtoken" or "secret"
            or "password" or "authorization" || normalized.Contains("credential", StringComparison.Ordinal);
    }

    internal static string SanitizeForRemote(string value) => SanitizeText(value);

    private static string SanitizeText(string value)
    {
        if (System.Text.RegularExpressions.Regex.IsMatch(
                value,
                @"(?i)(api[_ -]?key|access[_ -]?token|refresh[_ -]?token|client[_ -]?secret|password|authorization)\s*[:=]\s*\S+|\bBearer\s+\S+|\b(?:sk|ghp|github_pat|xox[baprs])[-_][A-Za-z0-9_-]{12,}\b"))
        {
            return "[redacted]";
        }
        return value;
    }

    public RemoteControlEvent PublishText(
        string kind,
        string workspaceId,
        string? sessionId,
        string text,
        JsonObject? payload = null)
    {
        var artifactId = _artifacts.SaveText(kind, text);
        var data = payload?.DeepClone().AsObject() ?? new JsonObject();
        var bytes = Encoding.UTF8.GetByteCount(text);
        data["bytes"] = bytes;
        // Keep credentials and command output out of event payloads. The full
        // output remains available only through the explicitly requested local
        // artifact referenced by the event.
        data["preview"] = "Output captured in a local artifact.";
        var truncated = bytes > RemoteArtifactStore.MaximumArtifactBytes || text.Contains("[truncated]", StringComparison.OrdinalIgnoreCase);
        data["truncated"] = truncated;
        if (truncated) data["warning"] = "Output limit reached. Open the full artifact for the captured output.";
        return Publish(kind, workspaceId, sessionId, data, artifactId);
    }

    public IReadOnlyList<RemoteControlEvent> Since(long sequence, string? workspaceId = null)
    {
        lock (_gate)
        {
            return _history
                .Where(item => item.Sequence > sequence && (workspaceId is null || item.WorkspaceId == workspaceId))
                .ToArray();
        }
    }

    public void Dispose()
    {
        lock (_gate)
        {
            _disposed = true;
        }
    }
}

public sealed class RemoteArtifactStore
{
    public const long MaximumArtifactBytes = 50 * 1024 * 1024;
    private readonly string _root;

    public RemoteArtifactStore(string root)
    {
        _root = Path.Combine(root, "remote-artifacts");
        Directory.CreateDirectory(_root);
    }

    public string SaveText(string kind, string value)
    {
        var bytes = Encoding.UTF8.GetBytes(value);
        if (bytes.LongLength > MaximumArtifactBytes)
        {
            bytes = bytes[..(int)MaximumArtifactBytes];
        }
        return Save(kind, bytes);
    }

    public string Save(string kind, byte[] bytes)
    {
        var id = $"{DateTimeOffset.UtcNow:yyyyMMddHHmmss}-{Guid.NewGuid():N}";
        var path = Path.Combine(_root, id + ".artifact");
        File.WriteAllBytes(path, bytes);
        File.WriteAllText(path + ".meta", kind.Trim());
        return id;
    }

    public bool TryOpen(string id, out string path)
    {
        path = "";
        if (string.IsNullOrWhiteSpace(id) || id.Any(ch => !char.IsLetterOrDigit(ch) && ch != '-')) return false;
        var candidate = Path.Combine(_root, id + ".artifact");
        if (!File.Exists(candidate)) return false;
        path = candidate;
        return true;
    }

    public IReadOnlyList<RemoteArtifactInfo> List() => Directory.EnumerateFiles(_root, "*.artifact")
        .Select(path => new FileInfo(path))
        .OrderByDescending(file => file.LastWriteTimeUtc)
        .Select(file => new RemoteArtifactInfo(
            Path.GetFileNameWithoutExtension(file.Name),
            ReadKind(file.FullName),
            file.Length,
            new DateTimeOffset(file.LastWriteTimeUtc, TimeSpan.Zero)))
        .ToArray();

    private static string ReadKind(string path)
    {
        try { return File.ReadAllText(path + ".meta"); } catch { return "artifact"; }
    }
}

public sealed class RemotePairingStore
{
    private const int ChallengeMinutes = 5;
    private readonly object _gate = new();
    private readonly string _file;
    private readonly IProviderSecretStore _secrets;
    private string _workspaceId;
    private readonly List<DeviceState> _devices;
    private ChallengeState? _challenge;

    private sealed record DeviceState(
        string Id,
        string Name,
        string TokenHash,
        DateTimeOffset CreatedAt,
        bool Revoked = false);

    /// Secret rides only in the QR (`k=`): it seals the pairing exchange, so
    /// whoever relays it (the cloud tunnel) cannot read the device token.
    private sealed record ChallengeState(string Endpoint, string Code, string Secret, DateTimeOffset ExpiresAt);

    public RemotePairingStore(string root, string workspaceId, IProviderSecretStore secrets)
    {
        _file = Path.Combine(root, "remote-control.json");
        _secrets = secrets;
        _workspaceId = workspaceId;
        _devices = Load();
    }

    public RemotePairingInfo Begin(string endpoint, string? fingerprint = null)
    {
        if (!Uri.TryCreate(endpoint, UriKind.Absolute, out var uri)
            || uri.Scheme is not ("http" or "https")
            || string.IsNullOrWhiteSpace(uri.Host))
        {
            throw new InvalidOperationException("A valid pairing endpoint is required.");
        }

        lock (_gate)
        {
            var code = RandomNumberGenerator.GetInt32(100_000, 1_000_000).ToString();
            var expiresAt = DateTimeOffset.UtcNow.AddMinutes(ChallengeMinutes);
            _challenge = new ChallengeState(endpoint.TrimEnd('/'), code, Token(), expiresAt);
            var payload = $"herness://pair?endpoint={Uri.EscapeDataString(_challenge.Endpoint)}&code={code}&k={_challenge.Secret}";
            if (!string.IsNullOrEmpty(fingerprint)) payload += $"&fp={fingerprint}";
            return new RemotePairingInfo(_challenge.Endpoint, code, payload, expiresAt);
        }
    }

    public void SetWorkspaceId(string workspaceId)
    {
        lock (_gate) _workspaceId = workspaceId;
    }

    public RemotePairingResult? Complete(string code, string? deviceName)
    {
        lock (_gate)
        {
            if (_challenge is null || _challenge.ExpiresAt <= DateTimeOffset.UtcNow || !FixedEquals(_challenge.Code, code.Trim()))
            {
                _challenge = null;
                return null;
            }

            var id = Guid.NewGuid().ToString("N");
            var token = Token();
            var name = string.IsNullOrWhiteSpace(deviceName) ? "Phone" : deviceName.Trim()[..Math.Min(deviceName.Trim().Length, 80)];
            _devices.Add(new DeviceState(id, name, Hash(token), DateTimeOffset.UtcNow));
            _secrets.Write("remote.device." + id, token);
            Save();
            _challenge = null;
            return new RemotePairingResult(id, name, token, _workspaceId);
        }
    }

    /// The key material a sealed request names: the live QR secret for
    /// `pair`, otherwise the token of a device that is still trusted.
    public string? SealingSecret(string device)
    {
        lock (_gate)
        {
            if (device == RemoteSealed.PairingDevice)
                return _challenge is not null && _challenge.ExpiresAt > DateTimeOffset.UtcNow ? _challenge.Secret : null;
            return _devices.Any(item => item.Id == device && !item.Revoked) ? _secrets.Read("remote.device." + device) : null;
        }
    }

    public bool Authenticate(IReadOnlyDictionary<string, string> headers, out string deviceId)
    {
        deviceId = "";
        if (!headers.TryGetValue("authorization", out var value) || !value.StartsWith("Bearer ", StringComparison.OrdinalIgnoreCase)) return false;
        var token = value[7..].Trim();
        if (token.Length == 0) return false;
        lock (_gate)
        {
            foreach (var device in _devices.Where(item => !item.Revoked))
            {
                var stored = _secrets.Read("remote.device." + device.Id);
                if (stored is not null && FixedEquals(device.TokenHash, Hash(token)))
                {
                    deviceId = device.Id;
                    return true;
                }
            }
        }
        return false;
    }

    public IReadOnlyList<RemotePairingDevice> Devices()
    {
        lock (_gate) return _devices.Select(item => new RemotePairingDevice(item.Id, item.Name, item.CreatedAt, item.Revoked)).ToArray();
    }

    public bool Revoke(string id)
    {
        lock (_gate)
        {
            var index = _devices.FindIndex(item => item.Id == id);
            if (index < 0) return false;
            _devices[index] = _devices[index] with { Revoked = true };
            _secrets.Delete("remote.device." + id);
            Save();
            return true;
        }
    }

    private List<DeviceState> Load()
    {
        try
        {
            return JsonSerializer.Deserialize<List<DeviceState>>(File.ReadAllText(_file), JsonOptions()) ?? [];
        }
        catch { return []; }
    }

    private void Save()
    {
        Directory.CreateDirectory(Path.GetDirectoryName(_file)!);
        File.WriteAllText(_file, JsonSerializer.Serialize(_devices, JsonOptions()));
    }

    private static string Token() => Convert.ToBase64String(RandomNumberGenerator.GetBytes(32)).Replace("+", "-").Replace("/", "_").TrimEnd('=');
    private static string Hash(string value) => Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(value)));
    private static bool FixedEquals(string left, string right) => CryptographicOperations.FixedTimeEquals(Encoding.UTF8.GetBytes(left), Encoding.UTF8.GetBytes(right));
    private static JsonSerializerOptions JsonOptions() => new(JsonSerializerDefaults.Web) { WriteIndented = true };
}

public sealed class RemoteControlHost : IDisposable
{
    public const int ProtocolVersion = 1;
    public const int DefaultPort = 18_768;

    private readonly AgentBridge _bridge;
    private readonly Func<string> _workspaceProvider;
    private readonly RemoteControlEventHub _events;
    private readonly RemotePairingStore _pairing;
    private readonly RemoteControlGateway _gateway;
    private readonly CloudTunnelProcess _tunnel;
    private readonly CloudTunnelProcess _previewTunnel;
    private readonly Func<IReadOnlyList<RemoteProjectDescriptor>>? _projectsProvider;
    private readonly ConcurrentDictionary<string, PendingCommand> _pending = new(StringComparer.Ordinal);
    private readonly ConcurrentDictionary<string, byte> _commands = new(StringComparer.Ordinal);
    private readonly ConcurrentDictionary<string, string> _selectedProjects = new(StringComparer.Ordinal);
    private readonly ConcurrentDictionary<string, RemoteInteractiveShell> _terminalSessions = new(StringComparer.Ordinal);
    private int? _previewTunnelPort;
    private RemoteAccessMode _accessMode = RemoteAccessMode.Ask;
    private long _revision;
    private RemotePairingInfo? _pairingInfo;
    private readonly RemoteSealed.ReplayGuard _replay = new();
    private readonly object _tunnelGate = new();
    private Task<string>? _tunnelStart;

    private sealed record PendingCommand(string Id, string Kind, JsonObject Payload, string Workspace, string DeviceId, DateTimeOffset CreatedAt);

    public RemoteControlEventHub Events => _events;
    public RemoteAccessMode AccessMode => _accessMode;
    public string LocalEndpoint => $"https://127.0.0.1:{DefaultPort}";
    /// SHA-256 of the gateway certificate; the pairing QR carries it so the
    /// phone pins this exact certificate on the LAN.
    public string CertificateFingerprint { get; }
    /// The LAN address is only offered when the user shares the gateway with
    /// the network; otherwise the tunnel is the only way in. The endpoint uses
    /// the machine's mDNS name: the phone resolves it without a DNS server,
    /// and its transport policy only lets plain HTTP through for such a name.
    public string PreferredEndpoint
    {
        get
        {
            if (!SharesWithLan) return LocalEndpoint;
            var host = LocalHostName();
            return $"https://{(string.IsNullOrEmpty(host) ? PreferredHost() : host)}:{DefaultPort}";
        }
    }
    public bool SharesWithLan
    {
        get => _gateway.SharesWithLan;
        set => _gateway.SharesWithLan = value;
    }
    public RemotePairingInfo? Pairing => _pairingInfo;
    public string? PublicEndpoint { get; private set; }
    public bool Running => _gateway.Running;

    public RemoteControlHost(
        AgentBridge bridge,
        SupportPaths paths,
        RemoteControlEventHub events,
        Func<string> workspaceProvider,
        Func<IReadOnlyList<RemoteProjectDescriptor>>? projectsProvider = null)
    {
        _bridge = bridge;
        _events = events;
        _workspaceProvider = workspaceProvider;
        _projectsProvider = projectsProvider;
        var workspace = NormalizeWorkspace();
        _pairing = new RemotePairingStore(paths.Root, WorkspaceId(workspace), new PlatformProviderSecrets(paths.Root));
        var certificate = RemoteTls.LoadOrCreate(paths.Root);
        CertificateFingerprint = RemoteTls.Fingerprint(certificate);
        _gateway = new RemoteControlGateway(DefaultPort, HandleAsync, certificate);
        _tunnel = new CloudTunnelProcess(paths);
        _previewTunnel = new CloudTunnelProcess(paths, "preview-tunnel");
    }

    public void Start()
    {
        try
        {
            _gateway.Start();
            BeginPairing(PreferredEndpoint);
        }
        catch (Exception ex)
        {
            Publish("gateway.failed", new JsonObject { ["message"] = ex.Message });
        }
    }

    public void Stop()
    {
        _tunnel.Stop();
        _previewTunnel.Stop();
        _previewTunnelPort = null;
        foreach (var session in _terminalSessions.Values) session.Dispose();
        _terminalSessions.Clear();
        _gateway.Stop();
    }

    public RemotePairingInfo BeginPairing(string endpoint)
    {
        _ = CurrentWorkspace();
        _pairingInfo = _pairing.Begin(endpoint, CertificateFingerprint);
        Publish("pairing.ready", new JsonObject { ["endpoint"] = _pairingInfo.Endpoint, ["expiresAt"] = _pairingInfo.ExpiresAt });
        return _pairingInfo;
    }

    /// Calls made while a start is already under way share it, so the
    /// automatic start and a click cannot race into two tunnels.
    public Task<string> EnableCloudTunnelAsync(CancellationToken cancellationToken = default)
    {
        lock (_tunnelGate) return _tunnelStart ??= StartTunnelAsync(cancellationToken);
    }

    private async Task<string> StartTunnelAsync(CancellationToken cancellationToken)
    {
        await Task.Yield();
        try
        {
            if (!_gateway.Running) _gateway.Start();
            PublicEndpoint = await _tunnel.StartAsync(DefaultPort, ct: cancellationToken, originTls: true);
            BeginPairing(PublicEndpoint);
            Publish("tunnel.ready", new JsonObject { ["endpoint"] = PublicEndpoint });
            return PublicEndpoint;
        }
        catch (Exception ex)
        {
            Publish("tunnel.failed", new JsonObject { ["message"] = ex.Message });
            throw;
        }
        finally { lock (_tunnelGate) _tunnelStart = null; }
    }

    public IReadOnlyList<RemotePairingDevice> Devices() => _pairing.Devices();

    public void SetWorkspacePath(string workspace) => _pairing.SetWorkspaceId(WorkspaceId(NormalizeWorkspace(workspace)));

    private IReadOnlyList<RemoteProjectDescriptor> Projects()
    {
        var supplied = _projectsProvider?.Invoke() ?? [];
        var result = supplied
            .Where(item => !string.IsNullOrWhiteSpace(item.Id) && !string.IsNullOrWhiteSpace(item.WorkspacePath))
            .Select(item => item with { WorkspacePath = NormalizeWorkspace(item.WorkspacePath) })
            .GroupBy(item => item.Id, StringComparer.Ordinal)
            .Select(group => group.First())
            .ToArray();
        if (result.Length > 0) return result;

        var workspace = NormalizeWorkspace();
        return [new RemoteProjectDescriptor("default", Path.GetFileName(workspace), WorkspaceId(workspace)) { WorkspacePath = workspace }];
    }

    private string SelectedProjectID(string deviceId)
    {
        var projects = Projects();
        return _selectedProjects.TryGetValue(deviceId, out var selected)
            && projects.Any(item => item.Id == selected)
            ? selected
            : projects[0].Id;
    }

    private RemoteProjectDescriptor SelectedProject(string deviceId, string? requestedID = null)
    {
        var projects = Projects();
        var id = requestedID ?? SelectedProjectID(deviceId);
        return projects.FirstOrDefault(item => item.Id == id) ?? projects[0];
    }

    private string ProjectWorkspace(string deviceId, string? requestedID = null) => SelectedProject(deviceId, requestedID).WorkspacePath;

    /// Only sealed requests reach the router (see <see cref="RemoteSealed"/>);
    /// anything else gets one fixed refusal that says nothing about why.
    private async Task HandleAsync(RemoteHttpRequest outer, Stream stream, CancellationToken cancellationToken)
    {
        var device = outer.Headers.TryGetValue("x-herness-device", out var name) ? name : "";
        var secret = outer.Method == "POST" && outer.Path == RemoteSealed.Path ? _pairing.SealingSecret(device) : null;
        var opened = secret is null ? null : RemoteSealed.Open(outer.Body, RemoteSealed.Key(secret), device);
        RemoteHttpRequest? request = null;
        if (opened is not null && _replay.IsFresh(opened.Nonce, opened.Timestamp))
        {
            try { request = await RemoteControlGateway.ReadRequestAsync(new MemoryStream(opened.Request), cancellationToken); }
            catch (Exception ex) when (ex is IOException or InvalidOperationException) { }
        }
        if (request is null)
        {
            await WriteJsonAsync(stream, 401, new { error = "This request is not sealed for this desktop. Scan its pairing QR code again." }, cancellationToken);
            return;
        }
        // The sealing key is what proves the device; a token inside is ignored.
        var headers = new Dictionary<string, string>(request.Headers, StringComparer.OrdinalIgnoreCase);
        if (device == RemoteSealed.PairingDevice) headers.Remove("authorization"); else headers["authorization"] = "Bearer " + secret;
        await using var channel = new RemoteSealedStream(stream, RemoteSealed.Key(secret!), opened!.Nonce);
        // A failure is answered inside the channel too: its message must not cross the tunnel in the clear.
        try { await RouteAsync(request with { Headers = headers }, channel, cancellationToken); }
        catch (Exception ex) when (ex is not OperationCanceledException) { await WriteJsonAsync(channel, 500, new { error = ex.Message }, cancellationToken); }
    }

    private async Task RouteAsync(RemoteHttpRequest request, Stream stream, CancellationToken cancellationToken)
    {
        if (request.Path == "/v1/control/pair/complete" && request.Method == "POST")
        {
            await HandlePairingAsync(request, stream, cancellationToken);
            return;
        }

        if (!_pairing.Authenticate(request.Headers, out var deviceId))
        {
            await WriteJsonAsync(stream, 401, new { error = "A valid device token is required." }, cancellationToken);
            return;
        }

        if (request.Method == "GET" && request.Path == "/v2/control/projects")
        {
            await WriteJsonAsync(stream, 200, new RemoteProjectsResponse(2, SelectedProjectID(deviceId), Projects()), cancellationToken);
            return;
        }
        if (request.Method == "POST" && request.Path == "/v2/control/projects/select")
        {
            await HandleProjectSelectionAsync(request, stream, deviceId, cancellationToken);
            return;
        }

        var projectScoped = request.Path.StartsWith("/v2/control/", StringComparison.Ordinal);
        var routePath = projectScoped
            ? "/v1/control/" + request.Path["/v2/control/".Length..]
            : request.Path;

        if (request.Method == "GET" && routePath == "/v1/control/bootstrap")
        {
            await WriteJsonAsync(stream, 200, Bootstrap(deviceId, projectScoped), cancellationToken);
            return;
        }
        if (request.Method == "GET" && routePath == "/v1/control/transcript")
        {
            var transcript = Transcript(Query(request.Target, "conversationId"), Query(request.Target, "limit"));
            if (transcript is null) await WriteJsonAsync(stream, 404, new { error = "Conversation not found." }, cancellationToken);
            else await WriteJsonAsync(stream, 200, transcript, cancellationToken);
            return;
        }
        if (request.Method == "GET" && routePath == "/v1/control/events")
        {
            await StreamEventsAsync(request, stream, deviceId, projectScoped, cancellationToken);
            return;
        }
        if (request.Method == "GET" && (routePath == "/v1/control/file" || routePath.StartsWith("/v1/control/files/", StringComparison.Ordinal)))
        {
            await HandleFileReadAsync(request, stream, deviceId, projectScoped, cancellationToken);
            return;
        }
        if (request.Method == "GET" && (routePath == "/v1/control/artifact" || routePath.StartsWith("/v1/control/artifacts/", StringComparison.Ordinal)))
        {
            await HandleArtifactAsync(request, stream, cancellationToken);
            return;
        }
        if (request.Method == "GET" && routePath == "/v1/control/artifacts")
        {
            await WriteJsonAsync(stream, 200, _events.Artifacts.List(), cancellationToken);
            return;
        }
        if (request.Method == "POST" && routePath == "/v1/control/snapshot/request")
        {
            await WriteJsonAsync(stream, 200, Snapshot(deviceId, projectScoped), cancellationToken);
            return;
        }
        if (request.Method == "POST" && routePath == "/v1/control/commands")
        {
            var response = await DispatchAsync(request, deviceId, projectScoped, cancellationToken);
            await WriteJsonAsync(stream, response.HttpStatus, response, cancellationToken);
            return;
        }

        await WriteJsonAsync(stream, 404, new { error = "Control route not found." }, cancellationToken);
    }

    private async Task HandleProjectSelectionAsync(RemoteHttpRequest request, Stream stream, string deviceId, CancellationToken cancellationToken)
    {
        try
        {
            var input = JsonNode.Parse(request.Body)?.AsObject() ?? new JsonObject();
            var projectID = input["projectID"]?.GetValue<string>()?.Trim() ?? "";
            var project = Projects().FirstOrDefault(item => item.Id == projectID);
            if (project is null)
            {
                await WriteJsonAsync(stream, 404, new { error = "Project not found." }, cancellationToken);
                return;
            }
            _selectedProjects[deviceId] = project.Id;
            await WriteJsonAsync(stream, 200, new
            {
                protocolVersion = 2,
                projectID = project.Id,
                workspaceId = project.WorkspaceId,
                name = project.Name,
                branch = project.Branch,
            }, cancellationToken);
            Publish("project.selected", new JsonObject { ["projectID"] = project.Id, ["deviceId"] = deviceId }, workspaceOverride: project.WorkspacePath);
        }
        catch (Exception ex)
        {
            await WriteJsonAsync(stream, 400, new { error = ex.Message }, cancellationToken);
        }
    }

    private async Task HandlePairingAsync(RemoteHttpRequest request, Stream stream, CancellationToken cancellationToken)
    {
        try
        {
            var input = JsonNode.Parse(request.Body)?.AsObject() ?? new JsonObject();
            var result = _pairing.Complete(input["code"]?.GetValue<string>() ?? "", input["deviceName"]?.GetValue<string>());
            if (result is null)
            {
                await WriteJsonAsync(stream, 401, new { error = "Pairing code is invalid or expired." }, cancellationToken);
                return;
            }
            await WriteJsonAsync(stream, 200, result, cancellationToken);
            Publish("device.paired", new JsonObject { ["deviceId"] = result.DeviceId, ["deviceName"] = result.DeviceName });
        }
        catch (Exception ex)
        {
            await WriteJsonAsync(stream, 400, new { error = ex.Message }, cancellationToken);
        }
    }

    private async Task<RemoteCommandResponse> DispatchAsync(RemoteHttpRequest request, string deviceId, bool projectScoped, CancellationToken cancellationToken)
    {
        RemoteControlCommand command;
        string workspace;
        try
        {
            var root = JsonNode.Parse(request.Body)?.AsObject() ?? throw new InvalidOperationException("Command body is required.");
            var payload = root["payload"]?.AsObject() ?? new JsonObject();
            var requestedProjectID = projectScoped
                ? root["projectID"]?.GetValue<string>() ?? payload["projectID"]?.GetValue<string>()
                : null;
            workspace = projectScoped ? ProjectWorkspace(deviceId, requestedProjectID) : CurrentWorkspace();
            command = new RemoteControlCommand(
                root["id"]?.GetValue<string>() ?? Guid.NewGuid().ToString("N"),
                root["workspaceId"]?.GetValue<string>() ?? WorkspaceId(workspace),
                root["sessionId"]?.GetValue<string>(),
                root["kind"]?.GetValue<string>() ?? "",
                root["expectedRevision"]?.GetValue<long>(),
                payload,
                root["projectID"]?.GetValue<string>() ?? payload["projectID"]?.GetValue<string>());
        }
        catch (Exception ex)
        {
            return RemoteCommandResponse.Failed(400, ex.Message);
        }

        if (!_commands.TryAdd(command.Id, 0)) return RemoteCommandResponse.Accepted(command.Id, "duplicate");
        if (!string.Equals(command.WorkspaceId, WorkspaceId(workspace), StringComparison.Ordinal))
        {
            var response = RemoteCommandResponse.Failed(409, "The workspace is no longer mounted.");
            Audit(command, deviceId, response, workspace);
            return response;
        }
        if (command.ExpectedRevision is { } expected && expected != Interlocked.Read(ref _revision))
        {
            var response = RemoteCommandResponse.Failed(409, $"The workspace revision changed. Current revision: {Interlocked.Read(ref _revision)}.");
            Audit(command, deviceId, response, workspace);
            return response;
        }

        try
        {
            var response = command.Kind switch
            {
                "prompt" => await PromptAsync(command, workspace),
                "continue" => await ContinueAsync(command),
                "stop" or "cancel" => await StopAsync(command),
                "approval" => await ApprovalAsync(command),
                "question" => await QuestionAsync(command),
            "permission" => Permission(command, workspace),
                "write_file" => await SensitiveAsync(command, deviceId, workspace, cancellationToken),
                "run_command" or "wait_command" or "build" or "deploy" or "computer_use" => await SensitiveAsync(command, deviceId, workspace, cancellationToken),
                "terminal_session" => IsSafeTerminalAction(command)
                    ? TerminalSessionCommand(command, deviceId, workspace)
                    : await SensitiveAsync(command, deviceId, workspace, cancellationToken),
                "preview_tunnel" => IsSafeTunnelAction(command)
                    ? PreviewTunnelCommand(command, workspace)
                    : await SensitiveAsync(command, deviceId, workspace, cancellationToken),
                "native_browser" => await SensitiveAsync(command, deviceId, workspace, cancellationToken),
                "approve" => await ResolvePendingAsync(command, deviceId, cancellationToken),
                "revoke_device" => Revoke(command),
                _ => RemoteCommandResponse.Failed(400, $"Unknown command: {command.Kind}"),
            };
            Audit(command, deviceId, response, workspace);
            return response;
        }
        catch (Exception ex)
        {
            Publish("command.failed", new JsonObject { ["commandId"] = command.Id, ["message"] = ex.Message }, workspaceOverride: workspace);
            var response = RemoteCommandResponse.Failed(500, ex.Message);
            Audit(command, deviceId, response, workspace);
            return response;
        }
    }

    private async Task<RemoteCommandResponse> PromptAsync(RemoteControlCommand command, string workspace)
    {
        var text = command.Payload["text"]?.GetValue<string>()?.Trim() ?? "";
        if (text.Length == 0) return RemoteCommandResponse.Failed(400, "Prompt text is required.");
        var mode = Enum.TryParse<PromptMode>(command.Payload["mode"]?.GetValue<string>(), true, out var parsed) ? parsed : PromptMode.Queue;
        var plan = command.Payload["planMode"]?.GetValue<bool>() ?? false;
        _ = _bridge.SendAsync(text, mode, plan);
        Publish("command.accepted", new JsonObject { ["commandId"] = command.Id, ["kind"] = command.Kind }, workspaceOverride: workspace);
        await Task.CompletedTask;
        return RemoteCommandResponse.Accepted(command.Id, "queued");
    }

    private async Task<RemoteCommandResponse> ContinueAsync(RemoteControlCommand command)
    {
        await _bridge.ContinueAsync(command.Payload["text"]?.GetValue<string>());
        return RemoteCommandResponse.Accepted(command.Id, "continued");
    }

    private async Task<RemoteCommandResponse> StopAsync(RemoteControlCommand command)
    {
        await _bridge.CancelAsync();
        return RemoteCommandResponse.Accepted(command.Id, "stopped");
    }

    private async Task<RemoteCommandResponse> ApprovalAsync(RemoteControlCommand command)
    {
        await _bridge.AnswerApprovalAsync(
            command.Payload["answer"]?.GetValue<string>() ?? "rejected",
            command.SessionId);
        return RemoteCommandResponse.Accepted(command.Id, "approval-forwarded");
    }

    private async Task<RemoteCommandResponse> QuestionAsync(RemoteControlCommand command)
    {
        string[] answers = command.Payload["answers"] is JsonArray list
            ? list.Select(item => item?.GetValue<string>() ?? string.Empty).ToArray()
            : [command.Payload["answer"]?.GetValue<string>() ?? string.Empty];
        await _bridge.AnswerQuestionAsync(answers, command.SessionId);
        return RemoteCommandResponse.Accepted(command.Id, "answer-forwarded");
    }

    private RemoteCommandResponse Permission(RemoteControlCommand command, string workspace)
    {
        var value = command.Payload["mode"]?.GetValue<string>()?.Replace(" ", "", StringComparison.Ordinal).ToLowerInvariant();
        var mode = value switch
        {
            "approve" or "approveme" => RemoteAccessMode.Approve,
            "full" or "fullaccess" => RemoteAccessMode.Full,
            _ => RemoteAccessMode.Ask,
        };
        _accessMode = mode;
        Publish("access.changed", new JsonObject { ["mode"] = mode.ToString().ToLowerInvariant() }, workspaceOverride: workspace);
        return RemoteCommandResponse.Accepted(command.Id, mode.ToString().ToLowerInvariant());
    }

    private async Task<RemoteCommandResponse> SensitiveAsync(RemoteControlCommand command, string deviceId, string workspace, CancellationToken cancellationToken)
    {
        if (_accessMode == RemoteAccessMode.Ask)
        {
            var approvalId = Guid.NewGuid().ToString("N");
            _pending[approvalId] = new PendingCommand(command.Id, command.Kind, command.Payload.DeepClone().AsObject(), workspace, deviceId, DateTimeOffset.UtcNow);
            Publish("approval.required", new JsonObject
            {
                ["approvalId"] = approvalId,
                ["commandId"] = command.Id,
                ["deviceId"] = deviceId,
                ["kind"] = command.Kind,
                ["summary"] = Summary(command),
            }, workspaceOverride: workspace);
            return RemoteCommandResponse.Pending(command.Id, approvalId);
        }
        return await ExecuteSensitiveAsync(command.Id, command.Kind, command.Payload, workspace, deviceId, cancellationToken);
    }

    private async Task<RemoteCommandResponse> ResolvePendingAsync(RemoteControlCommand command, string deviceId, CancellationToken cancellationToken)
    {
        var approvalId = command.Payload["approvalId"]?.GetValue<string>() ?? "";
        if (!_pending.TryRemove(approvalId, out var pending)) return RemoteCommandResponse.Failed(404, "Approval request not found.");
        var answer = command.Payload["answer"]?.GetValue<string>()?.ToLowerInvariant() ?? "rejected";
        if (answer is not ("allowed-once" or "allow" or "approved" or "full"))
        {
            Publish("approval.resolved", new JsonObject { ["approvalId"] = approvalId, ["allowed"] = false, ["deviceId"] = pending.DeviceId }, workspaceOverride: pending.Workspace);
            return RemoteCommandResponse.Accepted(command.Id, "rejected");
        }
        if (answer == "full")
        {
            _accessMode = RemoteAccessMode.Full;
            Publish("access.changed", new JsonObject { ["mode"] = "full" }, workspaceOverride: pending.Workspace);
        }
        var result = await ExecuteSensitiveAsync(pending.Id, pending.Kind, pending.Payload, pending.Workspace, pending.DeviceId, cancellationToken);
        Publish("approval.resolved", new JsonObject { ["approvalId"] = approvalId, ["allowed"] = true, ["deviceId"] = pending.DeviceId }, workspaceOverride: pending.Workspace);
        return result;
    }

    private async Task<RemoteCommandResponse> ExecuteSensitiveAsync(string commandId, string kind, JsonObject payload, string? workspaceOverride, string deviceId, CancellationToken cancellationToken)
    {
        var workspace = string.IsNullOrWhiteSpace(workspaceOverride) ? CurrentWorkspace() : NormalizeWorkspace(workspaceOverride);
        if (kind == "write_file")
        {
            var path = payload["path"]?.GetValue<string>() ?? "";
            var content = payload["content"]?.GetValue<string>() ?? "";
            var expected = payload["expectedSha256"]?.GetValue<string>();
            var write = RemoteWorkspace.WriteText(workspace, path, content, expected);
            if (write.Conflict) return RemoteCommandResponse.Conflict(commandId, write);
            Publish("file.changed", new JsonObject { ["path"] = write.Path, ["sha256"] = write.Sha256, ["operation"] = "write", ["commandId"] = commandId }, workspaceOverride: workspace);
            return RemoteCommandResponse.Ok(commandId, write);
        }

        if (kind == "computer_use")
        {
            if (!_bridge.IsComputerUseEnabled)
                return RemoteCommandResponse.Failed(403, "Computer Use is disabled in Settings.");
            var arguments = new JsonObject();
            foreach (var (key, value) in payload)
            {
                if (key == "projectID" || value is null) continue;
                arguments[key] = value.DeepClone();
            }
            var action = arguments["action"]?.GetValue<string>() ?? "";
            var text = await ComputerUseService.ExecuteAsync(arguments, workspace, cancellationToken);
            Publish("computeruse.action", new JsonObject { ["commandId"] = commandId, ["action"] = action }, workspaceOverride: workspace);
            return RemoteCommandResponse.Ok(commandId, new { output = text, outputPreview = text.Length <= 700 ? text : text[..700] + "…" });
        }

        if (kind == "terminal_session") return TerminalSessionCommand(commandId, payload, deviceId, workspace);

        if (kind == "preview_tunnel") return await PreviewTunnelCommandAsync(commandId, payload, workspace, cancellationToken);

        if (kind == "native_browser")
        {
            if (!NativeBrowserService.IsAvailable)
                return RemoteCommandResponse.Failed(503, "The desktop native browser is not open. Open the Live Browser panel and retry.");
            var text = await NativeBrowserService.ExecuteAsync(payload, workspace, cancellationToken);
            Publish("browser.action", new JsonObject { ["commandId"] = commandId, ["action"] = payload["action"]?.GetValue<string>() ?? "" }, workspaceOverride: workspace);
            return RemoteCommandResponse.Ok(commandId, new { output = text, outputPreview = text.Length <= 700 ? text : text[..700] + "…" });
        }

        if (kind == "wait_command")
        {
            var waitOutput = await NativeWorkspaceTools.ExecuteAsync(
                new NativeToolCall(commandId, "wait_command", payload.ToJsonString()),
                workspace,
                cancellationToken).ConfigureAwait(false);
            return RemoteCommandResponse.Ok(commandId, new { output = waitOutput, outputPreview = waitOutput.Length <= 700 ? waitOutput : waitOutput[..700] + "…" });
        }

        var shellCommand = payload["command"]?.GetValue<string>()?.Trim() ?? "";
        if (shellCommand.Length == 0) return RemoteCommandResponse.Failed(400, "Command text is required.");
        Publish(kind == "deploy" ? "deploy.progress" : "build.started", new JsonObject { ["commandId"] = commandId, ["kind"] = kind, ["phase"] = "started" }, workspaceOverride: workspace);
        var output = await NativeWorkspaceTools.ExecuteCommandStreamingAsync(
            shellCommand,
            workspace,
            line => _events.Publish(
            "terminal.output",
                WorkspaceId(workspace),
                _bridge.Selected?.Id,
                ScopedPayload(new JsonObject { ["commandId"] = commandId, ["kind"] = kind }, workspace)),
            cancellationToken,
            timeoutSeconds: RemoteCommandTimeout(payload["timeout_seconds"]));
        var outputEvent = _events.PublishText(
            kind == "deploy" ? "deploy.progress" : "build.output",
            WorkspaceId(workspace),
            _bridge.Selected?.Id,
            output,
            ScopedPayload(new JsonObject { ["commandId"] = commandId, ["kind"] = kind, ["phase"] = "output" }, workspace));
        var artifactId = outputEvent.ArtifactId!;
        string? outputArtifactId = null;
        if (kind == "build" && payload["artifactPath"]?.GetValue<string>() is { Length: > 0 } artifactPath)
        {
            var artifactBytes = RemoteWorkspace.ReadArtifact(workspace, artifactPath);
            outputArtifactId = _events.Artifacts.Save("build-artifact", artifactBytes);
            Publish("artifact.ready", new JsonObject { ["path"] = artifactPath, ["bytes"] = artifactBytes.LongLength }, outputArtifactId, workspace);
        }
        var bytes = Encoding.UTF8.GetByteCount(output);
        var deployFailed = kind == "deploy" && output.Contains("Command exited with status ", StringComparison.Ordinal);
        Publish(kind == "deploy" ? (deployFailed ? "deploy.failed" : "deploy.completed") : "build.completed", new JsonObject { ["commandId"] = commandId, ["kind"] = kind, ["bytes"] = bytes, ["artifactId"] = artifactId, ["outputArtifactId"] = outputArtifactId, ["truncated"] = bytes > RemoteArtifactStore.MaximumArtifactBytes }, artifactId, workspace);
        return RemoteCommandResponse.Ok(commandId, new { outputPreview = output.Length <= 700 ? output : output[..700] + "…", artifactId, outputArtifactId });
    }

    private RemoteCommandResponse Revoke(RemoteControlCommand command)
    {
        var id = command.Payload["deviceId"]?.GetValue<string>() ?? "";
        if (!_pairing.Revoke(id)) return RemoteCommandResponse.Failed(404, "Device not found.");
        foreach (var key in _terminalSessions.Keys.Where(key => key.StartsWith(id + ":", StringComparison.Ordinal)))
            if (_terminalSessions.TryRemove(key, out var session)) session.Dispose();
        return RemoteCommandResponse.Accepted(command.Id, "revoked");
    }

    private static bool IsSafeTerminalAction(RemoteControlCommand command) =>
        command.Payload["action"]?.GetValue<string>()?.ToLowerInvariant() is "read" or "status" or "stop";

    private static bool IsSafeTunnelAction(RemoteControlCommand command) =>
        command.Payload["action"]?.GetValue<string>()?.ToLowerInvariant() is "stop" or "status";

    private RemoteCommandResponse TerminalSessionCommand(RemoteControlCommand command, string deviceId, string workspace) =>
        TerminalSessionCommand(command.Id, command.Payload, deviceId, workspace);

    private RemoteCommandResponse TerminalSessionCommand(string commandId, JsonObject payload, string deviceId, string workspace)
    {
        var action = payload["action"]?.GetValue<string>()?.Trim().ToLowerInvariant() ?? "status";
        var key = deviceId + ":" + WorkspaceId(workspace);
        if (action == "start")
        {
            if (!_terminalSessions.TryGetValue(key, out var session) || !session.IsRunning)
            {
                if (session is not null) session.Dispose();
                session = RemoteInteractiveShell.Start(workspace);
                _terminalSessions[key] = session;
                Publish("terminal.session.started", new JsonObject { ["sessionId"] = session.Id }, workspaceOverride: workspace);
            }
            return TerminalResult(commandId, session);
        }
        if (!_terminalSessions.TryGetValue(key, out var current))
        {
            return action == "stop"
                ? RemoteCommandResponse.Accepted(commandId, "stopped")
                : RemoteCommandResponse.Ok(commandId, new { running = false, output = "", sessionId = "" });
        }
        if (action == "send")
        {
            var input = payload["input"]?.GetValue<string>() ?? "";
            if (input.Length == 0) return RemoteCommandResponse.Failed(400, "Terminal input is required.");
            current.Send(input);
        }
        else if (action == "stop")
        {
            current.Dispose();
            _terminalSessions.TryRemove(key, out _);
            Publish("terminal.session.stopped", new JsonObject { ["sessionId"] = current.Id }, workspaceOverride: workspace);
            return RemoteCommandResponse.Accepted(commandId, "stopped");
        }
        else if (action is not ("read" or "status"))
        {
            return RemoteCommandResponse.Failed(400, "Unsupported terminal session action.");
        }
        return TerminalResult(commandId, current);
    }

    private static RemoteCommandResponse TerminalResult(string commandId, RemoteInteractiveShell session) =>
        RemoteCommandResponse.Ok(commandId, new { sessionId = session.Id, running = session.IsRunning, output = session.ReadOutput() });

    private RemoteCommandResponse PreviewTunnelCommand(RemoteControlCommand command, string workspace)
    {
        var action = command.Payload["action"]?.GetValue<string>()?.Trim().ToLowerInvariant();
        if (action == "stop")
        {
            _previewTunnel.Stop();
            _previewTunnelPort = null;
            Publish("preview.tunnel.stopped", new JsonObject(), workspaceOverride: workspace);
            return RemoteCommandResponse.Accepted(command.Id, "stopped");
        }
        return RemoteCommandResponse.Ok(command.Id, new { running = _previewTunnelPort.HasValue, port = _previewTunnelPort });
    }

    private async Task<RemoteCommandResponse> PreviewTunnelCommandAsync(string commandId, JsonObject payload, string workspace, CancellationToken cancellationToken)
    {
        var action = payload["action"]?.GetValue<string>()?.Trim().ToLowerInvariant() ?? "start";
        if (action == "stop")
        {
            _previewTunnel.Stop();
            _previewTunnelPort = null;
            Publish("preview.tunnel.stopped", new JsonObject(), workspaceOverride: workspace);
            return RemoteCommandResponse.Accepted(commandId, "stopped");
        }
        if (action != "start") return RemoteCommandResponse.Failed(400, "Unsupported preview tunnel action.");
        var port = payload["port"]?.GetValue<int>() ?? 0;
        if (port is < 1024 or > 65535) return RemoteCommandResponse.Failed(400, "Enter a development server port between 1024 and 65535.");
        try
        {
            using (var probe = new TcpClient())
            {
                using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
                timeout.CancelAfter(TimeSpan.FromSeconds(2));
                await probe.ConnectAsync(IPAddress.Loopback, port, timeout.Token);
            }
            var endpoint = await _previewTunnel.StartAsync(port, ct: cancellationToken);
            _previewTunnelPort = port;
            Publish("preview.tunnel.ready", new JsonObject { ["url"] = endpoint, ["port"] = port }, workspaceOverride: workspace);
            return RemoteCommandResponse.Ok(commandId, new { url = endpoint, port, publicUrl = true });
        }
        catch (Exception ex) { return RemoteCommandResponse.Failed(400, ex.Message); }
    }

    private RemoteBootstrap Bootstrap(string deviceId, bool projectScoped)
    {
        var project = projectScoped ? SelectedProject(deviceId) : null;
        var workspace = project?.WorkspacePath ?? CurrentWorkspace();
        var selected = _bridge.Selected;
        return new RemoteBootstrap(
            ProtocolVersion,
            "project",
            WorkspaceId(workspace),
            workspace,
            Interlocked.Read(ref _revision),
            selected?.Id,
            _bridge.Connection?.Provider,
            _bridge.Connection?.Model,
            _bridge.Status,
            selected?.Running == true,
            _accessMode,
            ["events", "prompt", "continue", "stop", "approval", "question", "files", "snapshot", "artifacts", "write", "terminal", "terminal_sessions", "preview_tunnel", "native_browser", "build", "deploy", "wait_command", "transcript"],
            _pairing.Devices(),
            project?.Id,
            new[] { PublicEndpoint, PreferredEndpoint }.OfType<string>().ToArray());
    }

    private RemoteTranscript? Transcript(string conversationId, string limitText)
    {
        var limit = int.TryParse(limitText, out var parsed) ? Math.Clamp(parsed, 1, 500) : 200;
        // Messages belong to the UI thread; copy with a retry instead of
        // marshalling, a collision only costs one more pass.
        for (var attempt = 0; ; attempt++)
        {
            try
            {
                var conversation = string.IsNullOrWhiteSpace(conversationId)
                    ? _bridge.Selected
                    : _bridge.Conversations.ToArray().FirstOrDefault(item => item.Id == conversationId);
                if (conversation is null) return null;
                var messages = conversation.Messages.ToArray()
                    .TakeLast(limit)
                    .Select(item => new RemoteTranscriptMessage(
                        item.Id,
                        item.Kind.ToString().ToLowerInvariant(),
                        RemoteControlEventHub.SanitizeForRemote(item.Text.Length > 20_000 ? item.Text[..20_000] : item.Text),
                        item.CreatedAt))
                    .ToArray();
                return new RemoteTranscript(conversation.Id, conversation.Title, conversation.Running, messages);
            }
            catch (InvalidOperationException) when (attempt < 3) { }
        }
    }

    private RemoteWorkspaceSnapshot Snapshot(string deviceId, bool projectScoped)
    {
        var workspace = projectScoped ? ProjectWorkspace(deviceId) : CurrentWorkspace();
        var snapshot = RemoteWorkspace.CreateSnapshot(workspace, WorkspaceId(workspace), Interlocked.Increment(ref _revision));
        Publish("snapshot.ready", new JsonObject { ["revision"] = snapshot.Revision, ["files"] = snapshot.Files.Count, ["excluded"] = snapshot.Excluded.Count }, workspaceOverride: workspace);
        return snapshot;
    }

    private async Task HandleFileReadAsync(RemoteHttpRequest request, Stream stream, string deviceId, bool projectScoped, CancellationToken cancellationToken)
    {
        var path = Query(request.Target, "path");
        if (string.IsNullOrWhiteSpace(path) && request.Path.StartsWith("/v1/control/files/", StringComparison.Ordinal))
        {
            path = Uri.UnescapeDataString(request.Path["/v1/control/files/".Length..]);
        }
        try
        {
            var workspace = projectScoped ? ProjectWorkspace(deviceId) : CurrentWorkspace();
            var bytes = RemoteWorkspace.Read(workspace, path);
            await WriteBytesAsync(stream, 200, bytes, "application/octet-stream", cancellationToken);
        }
        catch (Exception ex) { await WriteJsonAsync(stream, 400, new { error = ex.Message }, cancellationToken); }
    }

    private async Task HandleArtifactAsync(RemoteHttpRequest request, Stream stream, CancellationToken cancellationToken)
    {
        var id = Query(request.Target, "id");
        if (string.IsNullOrWhiteSpace(id) && request.Path.StartsWith("/v1/control/artifacts/", StringComparison.Ordinal))
        {
            id = Uri.UnescapeDataString(request.Path["/v1/control/artifacts/".Length..]);
        }
        if (!_events.Artifacts.TryOpen(id, out var path))
        {
            await WriteJsonAsync(stream, 404, new { error = "Artifact not found." }, cancellationToken);
            return;
        }
        await WriteBytesAsync(stream, 200, await File.ReadAllBytesAsync(path, cancellationToken), "application/octet-stream", cancellationToken);
    }

    private async Task StreamEventsAsync(RemoteHttpRequest request, Stream stream, string deviceId, bool projectScoped, CancellationToken cancellationToken)
    {
        var after = long.TryParse(Query(request.Target, "after"), out var querySequence) ? querySequence : 0;
        if (request.Headers.TryGetValue("last-event-id", out var last) && long.TryParse(last, out var headerSequence)) after = Math.Max(after, headerSequence);
        var workspaceId = WorkspaceId(projectScoped ? ProjectWorkspace(deviceId) : CurrentWorkspace());
        await WriteAsciiAsync(stream, "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: close\r\nX-Accel-Buffering: no\r\n\r\n", cancellationToken);
        // Long poll: Quick Tunnels do not stream (no SSE), so each reply
        // carries one batch and ends; the phone asks again with `after`.
        IReadOnlyList<RemoteControlEvent> batch = [];
        for (var attempt = 0; attempt < 100 && batch.Count == 0; attempt++)
        {
            batch = _events.Since(after, workspaceId);
            if (batch.Count == 0) await Task.Delay(250, cancellationToken);
        }
        foreach (var item in batch)
        {
            var json = JsonSerializer.Serialize(item, JsonOptions());
            await WriteAsciiAsync(stream, $"id: {item.Sequence}\nevent: {item.Kind}\ndata: {json}\n\n", cancellationToken);
            await stream.FlushAsync(cancellationToken);
        }
    }

    private void Publish(string kind, JsonObject payload, string? artifactId = null, string? workspaceOverride = null)
    {
        var workspace = string.IsNullOrWhiteSpace(workspaceOverride) ? CurrentWorkspace() : NormalizeWorkspace(workspaceOverride);
        _events.Publish(kind, WorkspaceId(workspace), _bridge.Selected?.Id, ScopedPayload(payload, workspace), artifactId);
    }

    private void Audit(RemoteControlCommand command, string deviceId, RemoteCommandResponse response, string? workspace = null)
    {
        var payload = new JsonObject
        {
            ["commandId"] = command.Id,
            ["deviceId"] = deviceId,
            ["kind"] = command.Kind,
            ["status"] = response.Status,
            ["httpStatus"] = response.HttpStatus,
        };
        if (!string.IsNullOrWhiteSpace(command.ProjectID)) payload["projectID"] = command.ProjectID;
        Publish("audit.command", payload, workspaceOverride: workspace);
    }

    private JsonObject ScopedPayload(JsonObject payload, string workspace)
    {
        payload["scope"] = "project";
        var project = Projects().FirstOrDefault(item =>
            string.Equals(NormalizeWorkspace(item.WorkspacePath), workspace, StringComparison.Ordinal));
        if (project is not null) payload["projectID"] = project.Id;
        return payload;
    }

    private string CurrentWorkspace()
    {
        var workspace = NormalizeWorkspace();
        _pairing.SetWorkspaceId(WorkspaceId(workspace));
        return workspace;
    }

    private string NormalizeWorkspace() => NormalizeWorkspace(_workspaceProvider());

    private static string NormalizeWorkspace(string? value) => Path.GetFullPath(string.IsNullOrWhiteSpace(value) ? Environment.CurrentDirectory : value);

    private static string PreferredHost()
    {
        try
        {
            var address = Dns.GetHostEntry(Dns.GetHostName()).AddressList
                .FirstOrDefault(item => item.AddressFamily == AddressFamily.InterNetwork && !IPAddress.IsLoopback(item));
            return address?.ToString() ?? "127.0.0.1";
        }
        catch { return "127.0.0.1"; }
    }

    /// <summary>
    /// The mDNS name of this machine (`&lt;hostname&gt;.local`). Phones resolve
    /// it without a DNS server, and their transport policy only lets plain
    /// HTTP through for such a name.
    /// </summary>
    public static string LocalHostName()
    {
        try
        {
            var name = Dns.GetHostName().Trim();
            if (string.IsNullOrWhiteSpace(name)) return "";
            return name.EndsWith(".local", StringComparison.OrdinalIgnoreCase) ? name : name + ".local";
        }
        catch { return ""; }
    }
    /// A phone that sends no timeout_seconds waits 120 seconds for the reply, so its
    /// commands stop at 90; a newer phone sends the limit and waits that long.
    internal static int RemoteCommandTimeout(JsonNode? node) =>
        node is null ? 90 : NativeWorkspaceTools.CommandTimeout(node);

    private static string WorkspaceId(string workspace) => RemoteControlIdentity.WorkspaceId(workspace);
    private static string Summary(RemoteControlCommand command) => command.Kind switch
    {
        "write_file" => $"Write {command.Payload["path"]?.GetValue<string>()}",
        "terminal_session" => command.Payload["action"]?.GetValue<string>() == "start" ? "Start a mobile terminal session" : "Send input to the mobile terminal",
        "preview_tunnel" => $"Expose local development port {command.Payload["port"]?.GetValue<int>()}",
        "native_browser" => $"Native browser action: {command.Payload["action"]?.GetValue<string>()}",
        "wait_command" => $"Wait for process {command.Payload["pid"]?.ToString() ?? "unknown"}",
        _ => command.Payload["command"]?.GetValue<string>() ?? command.Kind,
    };
    private static string Query(string target, string key)
    {
        var query = target.IndexOf('?') is var index && index >= 0 ? target[(index + 1)..] : "";
        foreach (var part in query.Split('&', StringSplitOptions.RemoveEmptyEntries))
        {
            var bits = part.Split('=', 2);
            if (bits.Length == 2 && string.Equals(Uri.UnescapeDataString(bits[0]), key, StringComparison.OrdinalIgnoreCase)) return Uri.UnescapeDataString(bits[1]);
        }
        return "";
    }

    private static JsonSerializerOptions JsonOptions() => new(JsonSerializerDefaults.Web) { WriteIndented = false };
    private static async Task WriteJsonAsync(Stream stream, int status, object value, CancellationToken cancellationToken)
    {
        var body = JsonSerializer.SerializeToUtf8Bytes(value, JsonOptions());
        await WriteBytesAsync(stream, status, body, "application/json; charset=utf-8", cancellationToken);
    }

    private static async Task WriteBytesAsync(Stream stream, int status, byte[] body, string contentType, CancellationToken cancellationToken)
    {
        var reason = status switch { 200 => "OK", 202 => "Accepted", 400 => "Bad Request", 401 => "Unauthorized", 404 => "Not Found", 409 => "Conflict", _ => "Error" };
        await WriteAsciiAsync(stream, $"HTTP/1.1 {status} {reason}\r\nContent-Type: {contentType}\r\nContent-Length: {body.LongLength}\r\nConnection: close\r\n\r\n", cancellationToken);
        await stream.WriteAsync(body, cancellationToken);
        await stream.FlushAsync(cancellationToken);
    }

    private static ValueTask WriteAsciiAsync(Stream stream, string value, CancellationToken cancellationToken) =>
        stream.WriteAsync(Encoding.UTF8.GetBytes(value), cancellationToken);

    public void Dispose()
    {
        _tunnel.Dispose();
        _previewTunnel.Dispose();
        foreach (var session in _terminalSessions.Values) session.Dispose();
        _terminalSessions.Clear();
        _gateway.Dispose();
        _events.Dispose();
    }
}

public sealed record RemoteCommandResponse(
    string CommandId,
    string Status,
    int HttpStatus,
    string? ApprovalId = null,
    object? Result = null,
    string? Error = null)
{
    public static RemoteCommandResponse Accepted(string id, string status) => new(id, status, 202);
    public static RemoteCommandResponse Pending(string id, string approvalId) => new(id, "approval-required", 202, approvalId);
    public static RemoteCommandResponse Ok(string id, object? result) => new(id, "completed", 200, Result: result);
    public static RemoteCommandResponse Conflict(string id, object result) => new(id, "conflict", 409, Result: result);
    public static RemoteCommandResponse Failed(int status, string error) => new("", "failed", status, Error: error);
}

public static class RemoteControlIdentity
{
    public static string WorkspaceId(string workspace)
    {
        var identity = string.IsNullOrWhiteSpace(workspace)
            ? "herness:no-project"
            : Path.GetFullPath(workspace);
        return Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(identity))).ToLowerInvariant()[..24];
    }
}

public static class RemoteWorkspace
{
    private const int MaximumDepth = 20;
    private const int MaximumFiles = 20_000;
    private const long MaximumReadBytes = 50 * 1024 * 1024;
    private static readonly string[] GeneratedDirectories = [".git", ".mem", "node_modules", "bin", "obj", "build", "dist", ".gradle", "DerivedData", "Pods", ".next"];
    private static readonly string[] ArtifactDirectories = ["bin", "obj", "build", "dist", "DerivedData", ".next"];

    public static RemoteWorkspaceSnapshot CreateSnapshot(string workspace, string workspaceId, long revision)
    {
        var files = new List<RemoteWorkspaceFile>();
        var excluded = new List<RemoteExcludedPath>();
        Walk(workspace, workspace, 0, files, excluded);
        return new RemoteWorkspaceSnapshot(1, workspaceId, workspace, revision, ReadBaseCommit(workspace), files, excluded, DateTimeOffset.UtcNow);
    }

    public static byte[] Read(string workspace, string relativePath)
    {
        var file = Resolve(workspace, relativePath, allowExcluded: false);
        var info = new FileInfo(file);
        if (!info.Exists) throw new FileNotFoundException("File not found.", relativePath);
        if (info.Length > MaximumReadBytes) throw new InvalidOperationException("File is larger than the remote transfer limit.");
        return File.ReadAllBytes(file);
    }

    public static byte[] ReadArtifact(string workspace, string relativePath)
    {
        var file = Resolve(workspace, relativePath, allowExcluded: true);
        var parts = Path.GetRelativePath(Path.GetFullPath(workspace), file).Replace(Path.DirectorySeparatorChar, '/').Split('/');
        if (parts.Any(part => part is ".git" or ".mem" or "node_modules" or ".gradle" or "Pods")) throw new InvalidOperationException("This artifact path is not available through remote control.");
        if (!parts.Any(part => ArtifactDirectories.Contains(part, StringComparer.OrdinalIgnoreCase))) throw new InvalidOperationException("Build artifacts must be inside a generated output directory.");
        if (Sensitive(Path.GetFileName(file))) throw new InvalidOperationException("Secret artifacts are not available through remote control.");
        var info = new FileInfo(file);
        if (!info.Exists) throw new FileNotFoundException("Artifact not found.", relativePath);
        if (info.Length > MaximumReadBytes) throw new InvalidOperationException("Artifact is larger than the remote transfer limit.");
        return File.ReadAllBytes(file);
    }

    public static RemoteFileWriteResult WriteText(string workspace, string relativePath, string content, string? expectedSha256)
    {
        if (Encoding.UTF8.GetByteCount(content) > MaximumReadBytes) throw new InvalidOperationException("File is larger than the remote transfer limit.");
        var file = Resolve(workspace, relativePath, allowExcluded: false);
        var currentHash = File.Exists(file) ? Hash(File.ReadAllBytes(file)) : null;
        if (!string.IsNullOrWhiteSpace(expectedSha256) && !string.Equals(expectedSha256, currentHash, StringComparison.OrdinalIgnoreCase))
        {
            return new RemoteFileWriteResult(false, true, relativePath, currentHash ?? "", currentHash, "The file changed on the desktop.");
        }
        Directory.CreateDirectory(Path.GetDirectoryName(file)!);
        var temporary = file + ".remote-" + Guid.NewGuid().ToString("N") + ".part";
        try
        {
            File.WriteAllText(temporary, content, new UTF8Encoding(false));
            File.Move(temporary, file, true);
        }
        finally { try { if (File.Exists(temporary)) File.Delete(temporary); } catch { } }
        var hash = Hash(Encoding.UTF8.GetBytes(content));
        return new RemoteFileWriteResult(true, false, relativePath, hash, hash, "File written.");
    }

    private static void Walk(string root, string directory, int depth, List<RemoteWorkspaceFile> files, List<RemoteExcludedPath> excluded)
    {
        if (depth > MaximumDepth || files.Count >= MaximumFiles) return;
        IEnumerable<string> entries;
        try { entries = Directory.EnumerateFileSystemEntries(directory).OrderBy(item => item, StringComparer.OrdinalIgnoreCase).ToArray(); }
        catch { return; }
        foreach (var entry in entries)
        {
            var relative = Path.GetRelativePath(root, entry).Replace(Path.DirectorySeparatorChar, '/');
            if (ShouldExclude(entry, out var reason))
            {
                excluded.Add(new RemoteExcludedPath(relative, reason));
                continue;
            }
            if (IsSymlink(entry))
            {
                excluded.Add(new RemoteExcludedPath(relative, "symbolic link"));
                continue;
            }
            if (Directory.Exists(entry))
            {
                Walk(root, entry, depth + 1, files, excluded);
                continue;
            }
            if (!File.Exists(entry)) continue;
            try
            {
                var info = new FileInfo(entry);
                if (info.Length > MaximumReadBytes)
                {
                    excluded.Add(new RemoteExcludedPath(relative, "file exceeds transfer limit"));
                    continue;
                }
                files.Add(new RemoteWorkspaceFile(relative, info.Length, Hash(File.ReadAllBytes(entry)), Mode(entry)));
            }
            catch { excluded.Add(new RemoteExcludedPath(relative, "unreadable")); }
        }
    }

    private static string Resolve(string workspace, string relativePath, bool allowExcluded)
    {
        if (string.IsNullOrWhiteSpace(relativePath)) throw new InvalidOperationException("A relative file path is required.");
        var root = Path.GetFullPath(workspace);
        var combined = Path.GetFullPath(Path.Combine(root, relativePath));
        var comparison = OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal;
        var prefix = root.EndsWith(Path.DirectorySeparatorChar) ? root : root + Path.DirectorySeparatorChar;
        if (!combined.Equals(root, comparison) && !combined.StartsWith(prefix, comparison)) throw new InvalidOperationException("Path is outside the workspace.");
        if (!allowExcluded && IsExcluded(combined, root)) throw new InvalidOperationException("This path is not available through remote control.");
        if (HasSymlinkComponent(combined, root)) throw new InvalidOperationException("Symbolic links are not available through remote control.");
        return combined;
    }

    private static bool IsExcluded(string path, string root)
    {
        var relative = Path.GetRelativePath(root, path).Replace(Path.DirectorySeparatorChar, '/');
        return relative.Split('/').Any(part => GeneratedDirectories.Contains(part, StringComparer.OrdinalIgnoreCase)) || Sensitive(Path.GetFileName(path));
    }

    private static bool ShouldExclude(string path, out string reason)
    {
        var name = Path.GetFileName(path);
        if (GeneratedDirectories.Contains(name, StringComparer.OrdinalIgnoreCase)) { reason = "generated or private runtime directory"; return true; }
        if (Sensitive(name)) { reason = "secret or credential file"; return true; }
        reason = "";
        return false;
    }

    private static bool Sensitive(string name) =>
        name.Equals(".env", StringComparison.OrdinalIgnoreCase)
        || name.StartsWith(".env.", StringComparison.OrdinalIgnoreCase)
        || name.Equals("credentials.json", StringComparison.OrdinalIgnoreCase)
        || name.Equals("secrets.json", StringComparison.OrdinalIgnoreCase)
        || name.EndsWith(".pem", StringComparison.OrdinalIgnoreCase)
        || name.EndsWith(".p12", StringComparison.OrdinalIgnoreCase)
        || name.EndsWith(".key", StringComparison.OrdinalIgnoreCase)
        || name.Equals("id_rsa", StringComparison.OrdinalIgnoreCase);

    private static bool HasSymlinkComponent(string path, string root)
    {
        var current = root;
        var relative = Path.GetRelativePath(root, path);
        foreach (var part in relative.Split(Path.DirectorySeparatorChar, StringSplitOptions.RemoveEmptyEntries))
        {
            current = Path.Combine(current, part);
            if (IsSymlink(current)) return true;
        }
        return false;
    }

    private static bool IsSymlink(string path)
    {
        try
        {
            var attributes = File.GetAttributes(path);
            return attributes.HasFlag(FileAttributes.ReparsePoint)
                || (File.Exists(path) ? new FileInfo(path).LinkTarget is not null : new DirectoryInfo(path).LinkTarget is not null);
        }
        catch { return true; }
    }

    private static int Mode(string path)
    {
        try
        {
            if (!OperatingSystem.IsWindows()) return (int)File.GetUnixFileMode(path);
        }
        catch { }
        return 0;
    }

    private static string Hash(byte[] bytes) => Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();

    private static string? ReadBaseCommit(string workspace)
    {
        try
        {
            var head = Path.Combine(workspace, ".git", "HEAD");
            if (!File.Exists(head)) return null;
            var value = File.ReadAllText(head).Trim();
            if (value.StartsWith("ref: ", StringComparison.Ordinal))
            {
                var reference = value[5..].Trim().Replace('/', Path.DirectorySeparatorChar);
                var direct = Path.GetFullPath(Path.Combine(Path.GetDirectoryName(head)!, reference));
                var gitRoot = Path.GetFullPath(Path.GetDirectoryName(head)!);
                var prefix = gitRoot.EndsWith(Path.DirectorySeparatorChar) ? gitRoot : gitRoot + Path.DirectorySeparatorChar;
                if (direct.StartsWith(prefix, OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal) && File.Exists(direct))
                {
                    value = File.ReadAllText(direct).Trim();
                }
                else if (File.Exists(Path.Combine(gitRoot, "packed-refs")))
                {
                    var packed = File.ReadLines(Path.Combine(gitRoot, "packed-refs"))
                        .Select(line => line.Split(' ', 2, StringSplitOptions.RemoveEmptyEntries))
                        .FirstOrDefault(parts => parts.Length == 2 && parts[1] == value[5..].Trim());
                    if (packed is { Length: 2 }) value = packed[0];
                }
            }
            return value.Length == 40 && value.All(ch => "0123456789abcdefABCDEF".Contains(ch)) ? value : null;
        }
        catch { return null; }
    }
}

public sealed record RemoteHttpRequest(
    string Method,
    string Target,
    string Path,
    IReadOnlyDictionary<string, string> Headers,
    byte[] Body);

public sealed class RemoteControlGateway : IDisposable
{
    private const int MaximumHeaderBytes = 64 * 1024;
    private const int MaximumBodyBytes = 20 * 1024 * 1024;
    private readonly Func<RemoteHttpRequest, Stream, CancellationToken, Task> _handler;
    private readonly int _port;
    private readonly X509Certificate2 _certificate;
    private TcpListener _listener;
    private bool _sharesWithLan;
    private CancellationTokenSource? _stop;

    public bool Running { get; private set; }

    /// The address the listener is bound to. Loopback unless the user shared
    /// the gateway with the local network.
    public IPAddress BoundAddress => ((IPEndPoint)_listener.LocalEndpoint).Address;

    public RemoteControlGateway(int port, Func<RemoteHttpRequest, Stream, CancellationToken, Task> handler, X509Certificate2 certificate)
    {
        _handler = handler;
        _port = port;
        _certificate = certificate;
        _listener = CreateListener();
    }

    /// Sharing the control API with the LAN is opt-in. Loopback keeps it
    /// unreachable from whatever network the machine happens to sit on.
    public bool SharesWithLan
    {
        get => _sharesWithLan;
        set
        {
            if (_sharesWithLan == value) return;
            _sharesWithLan = value;
            if (!Running) return;
            Stop();
            _listener = CreateListener();
            Start();
        }
    }

    private TcpListener CreateListener() =>
        new(_sharesWithLan ? IPAddress.Any : IPAddress.Loopback, _port);

    public void Start()
    {
        if (Running) return;
        _listener.Start();
        _stop = new CancellationTokenSource();
        Running = true;
        _ = AcceptAsync(_stop.Token);
    }

    public void Stop()
    {
        if (!Running) return;
        Running = false;
        _stop?.Cancel();
        try { _listener.Stop(); } catch { }
    }

    private async Task AcceptAsync(CancellationToken cancellationToken)
    {
        try
        {
            while (!cancellationToken.IsCancellationRequested)
            {
                var client = await _listener.AcceptTcpClientAsync(cancellationToken);
                client.NoDelay = true;
                _ = HandleClientAsync(client, cancellationToken);
            }
        }
        catch (OperationCanceledException) { }
        catch (SocketException) { }
    }

    private async Task HandleClientAsync(TcpClient client, CancellationToken serverCancellation)
    {
        using var ownedClient = client;
        using var requestCancellation = CancellationTokenSource.CreateLinkedTokenSource(serverCancellation);
        // TLS only: the bearer token and every command cross the LAN.
        await using var stream = new SslStream(client.GetStream(), leaveInnerStreamOpen: false);
        try
        {
            using (var handshake = CancellationTokenSource.CreateLinkedTokenSource(requestCancellation.Token))
            {
                handshake.CancelAfter(TimeSpan.FromSeconds(10));
                await stream.AuthenticateAsServerAsync(new SslServerAuthenticationOptions
                {
                    ServerCertificate = _certificate,
                    EnabledSslProtocols = System.Security.Authentication.SslProtocols.Tls12 | System.Security.Authentication.SslProtocols.Tls13,
                }, handshake.Token);
            }
            var request = await ReadRequestAsync(stream, requestCancellation.Token);
            await _handler(request, stream, requestCancellation.Token);
        }
        catch (OperationCanceledException) { }
        catch (Exception ex)
        {
            try
            {
                var body = JsonSerializer.SerializeToUtf8Bytes(new { error = ex.Message });
                // Never answer in the clear: no reply when the handshake failed.
                if (stream.IsAuthenticated) await WriteErrorAsync(stream, body, requestCancellation.Token);
            }
            catch { }
        }
    }

    internal static async Task<RemoteHttpRequest> ReadRequestAsync(Stream stream, CancellationToken cancellationToken)
    {
        var bytes = new List<byte>(4096);
        var buffer = new byte[4096];
        var headerEnd = -1;
        while (headerEnd < 0)
        {
            var read = await stream.ReadAsync(buffer, cancellationToken);
            if (read == 0) throw new IOException("The client closed the connection.");
            bytes.AddRange(buffer.AsSpan(0, read).ToArray());
            headerEnd = HeaderEnd(bytes);
            if (headerEnd < 0 && bytes.Count > MaximumHeaderBytes) throw new InvalidOperationException("HTTP headers are too large.");
        }
        var raw = Encoding.ASCII.GetString(bytes.Take(headerEnd).ToArray());
        var lines = raw.Split("\r\n", StringSplitOptions.None);
        var requestLine = lines[0].Split(' ', 3, StringSplitOptions.RemoveEmptyEntries);
        if (requestLine.Length != 3) throw new InvalidOperationException("Invalid HTTP request.");
        var headers = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var line in lines.Skip(1))
        {
            if (line.Length == 0) break;
            var separator = line.IndexOf(':');
            if (separator <= 0) continue;
            headers[line[..separator].Trim().ToLowerInvariant()] = line[(separator + 1)..].Trim();
        }
        var length = headers.TryGetValue("content-length", out var value) && int.TryParse(value, out var parsed) ? parsed : 0;
        if (length < 0 || length > MaximumBodyBytes) throw new InvalidOperationException("HTTP body is too large.");
        var body = new byte[length];
        var initialBody = bytes.Skip(headerEnd).Take(Math.Min(length, bytes.Count - headerEnd)).ToArray();
        initialBody.CopyTo(body, 0);
        var offset = initialBody.Length;
        while (offset < length)
        {
            var read = await stream.ReadAsync(body.AsMemory(offset, length - offset), cancellationToken);
            if (read == 0) throw new IOException("The client closed the connection.");
            offset += read;
        }
        var target = requestLine[1];
        var question = target.IndexOf('?');
        return new RemoteHttpRequest(requestLine[0].ToUpperInvariant(), target, question >= 0 ? target[..question] : target, headers, body);
    }

    private static int HeaderEnd(IReadOnlyList<byte> bytes)
    {
        for (var index = 3; index < bytes.Count; index++)
        {
            if (bytes[index - 3] == 13 && bytes[index - 2] == 10 && bytes[index - 1] == 13 && bytes[index] == 10) return index + 1;
        }
        return -1;
    }

    private static async Task WriteErrorAsync(Stream stream, byte[] body, CancellationToken cancellationToken)
    {
        var header = Encoding.ASCII.GetBytes($"HTTP/1.1 500 Error\r\nContent-Type: application/json\r\nContent-Length: {body.Length}\r\nConnection: close\r\n\r\n");
        await stream.WriteAsync(header, cancellationToken);
        await stream.WriteAsync(body, cancellationToken);
    }

    public void Dispose() => Stop();
}

/// Sealed channel v1, the only way in for a phone, LAN and cloud tunnel alike.
/// The tunnel ends TLS at Cloudflare, so the HTTP exchange itself is encrypted
/// end to end with a key only this desktop and the paired phone hold:
///   key     = SHA-256("herness.sealed.v1:" + secret); secret = device token, or the QR `k` while pairing
///   request = POST /v3/sealed, `X-Herness-Device: &lt;device id | pair&gt;`, body =
///             AES-256-GCM nonce | ciphertext | tag over (ms timestamp, 8 bytes BE) + raw HTTP/1.1 request; AAD = device
///   reply   = 200 application/octet-stream; each line is base64(nonce | ciphertext | tag) of the next chunk of the raw
///             HTTP reply, AAD = request nonce + frame counter (4 bytes BE); an empty chunk ends the reply.
/// The macOS, iOS and Android copies follow this exactly.
public static class RemoteSealed
{
    public const string Path = "/v3/sealed";
    public const string PairingDevice = "pair";
    public const string Header = "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nCache-Control: no-cache, no-transform\r\nConnection: close\r\nX-Accel-Buffering: no\r\n\r\n";

    public sealed record Opened(byte[] Nonce, long Timestamp, byte[] Request);

    public static byte[] Key(string secret) => SHA256.HashData(Encoding.UTF8.GetBytes("herness.sealed.v1:" + secret));

    public static byte[] Seal(byte[] key, byte[] nonce, byte[] plain, byte[] aad)
    {
        var sealedBytes = new byte[12 + plain.Length + 16];
        nonce.CopyTo(sealedBytes, 0);
        using var aes = new AesGcm(key, 16);
        aes.Encrypt(nonce, plain, sealedBytes.AsSpan(12, plain.Length), sealedBytes.AsSpan(12 + plain.Length), aad);
        return sealedBytes;
    }

    public static byte[]? Unseal(byte[] key, byte[] sealedBytes, byte[] aad)
    {
        if (sealedBytes.Length < 28) return null;
        var plain = new byte[sealedBytes.Length - 28];
        try
        {
            using var aes = new AesGcm(key, 16);
            aes.Decrypt(sealedBytes.AsSpan(0, 12), sealedBytes.AsSpan(12, plain.Length), sealedBytes.AsSpan(sealedBytes.Length - 16), plain, aad);
            return plain;
        }
        catch (CryptographicException) { return null; }
    }

    public static Opened? Open(byte[] body, byte[] key, string device)
    {
        var plain = Unseal(key, body, Encoding.UTF8.GetBytes(device));
        if (plain is null || plain.Length <= 8) return null;
        return new Opened(body[..12], System.Buffers.Binary.BinaryPrimitives.ReadInt64BigEndian(plain), plain[8..]);
    }

    public static byte[] FrameAad(byte[] nonce, uint counter)
    {
        var aad = new byte[16];
        nonce.CopyTo(aad, 0);
        System.Buffers.Binary.BinaryPrimitives.WriteUInt32BigEndian(aad.AsSpan(12), counter);
        return aad;
    }

    /// A sealed request is accepted once, and only within five minutes of the phone's clock.
    public sealed class ReplayGuard
    {
        private readonly Dictionary<string, DateTimeOffset> _seen = new(StringComparer.Ordinal);

        public bool IsFresh(byte[] nonce, long timestamp)
        {
            var now = DateTimeOffset.UtcNow;
            var key = Convert.ToBase64String(nonce);
            lock (_seen)
            {
                foreach (var old in _seen.Where(item => now - item.Value > TimeSpan.FromMinutes(10)).Select(item => item.Key).ToArray()) _seen.Remove(old);
                if (Math.Abs(now.ToUnixTimeMilliseconds() - timestamp) >= 300_000 || !_seen.TryAdd(key, now)) return false;
                return true;
            }
        }
    }
}

/// The router's side of one sealed exchange: whatever it writes leaves as
/// encrypted frames, and disposing sends the end frame.
public sealed class RemoteSealedStream(Stream inner, byte[] key, byte[] nonce) : Stream
{
    private uint _counter;
    private bool _started;

    public override async ValueTask WriteAsync(ReadOnlyMemory<byte> buffer, CancellationToken cancellationToken = default)
    {
        for (var start = 0; start < buffer.Length; start += 65_536)
            await inner.WriteAsync(Next(buffer.Slice(start, Math.Min(65_536, buffer.Length - start)).ToArray()), cancellationToken);
    }

    public override Task WriteAsync(byte[] buffer, int offset, int count, CancellationToken cancellationToken) =>
        WriteAsync(buffer.AsMemory(offset, count), cancellationToken).AsTask();
    public override void Write(byte[] buffer, int offset, int count) => WriteAsync(buffer, offset, count, CancellationToken.None).GetAwaiter().GetResult();
    public override Task FlushAsync(CancellationToken cancellationToken) => inner.FlushAsync(cancellationToken);
    public override void Flush() => inner.Flush();

    public override async ValueTask DisposeAsync()
    {
        try
        {
            await inner.WriteAsync(Next([]));
            await inner.FlushAsync();
        }
        catch (IOException) { }
        catch (ObjectDisposedException) { }
    }

    private byte[] Next(byte[] chunk)
    {
        var frame = Encoding.ASCII.GetBytes(Convert.ToBase64String(RemoteSealed.Seal(key, RandomNumberGenerator.GetBytes(12), chunk, RemoteSealed.FrameAad(nonce, _counter++))) + "\n");
        if (_started) return frame;
        _started = true;
        return [.. Encoding.ASCII.GetBytes(RemoteSealed.Header), .. frame];
    }

    public override bool CanRead => false;
    public override bool CanSeek => false;
    public override bool CanWrite => true;
    public override long Length => throw new NotSupportedException();
    public override long Position { get => throw new NotSupportedException(); set => throw new NotSupportedException(); }
    public override int Read(byte[] buffer, int offset, int count) => throw new NotSupportedException();
    public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
    public override void SetLength(long value) => throw new NotSupportedException();
}

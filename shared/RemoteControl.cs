// Copyright (c) 2026 DOTS
// Versioned, workspace-scoped control plane shared by the Windows and Linux hosts.

using System.Collections.Concurrent;
using System.Net;
using System.Net.Sockets;
using System.Runtime.CompilerServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Threading.Channels;
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
    JsonObject Payload);

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
    AgentArea Area,
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
    IReadOnlyList<RemotePairingDevice> Devices);

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
    private readonly Dictionary<Guid, Channel<RemoteControlEvent>> _subscribers = [];
    private readonly RemoteArtifactStore _artifacts;
    private long _sequence;
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
            foreach (var subscriber in _subscribers.Values) subscriber.Writer.TryWrite(item);
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

    public async IAsyncEnumerable<RemoteControlEvent> StreamAsync(
        long sequence,
        string? workspaceId,
        [EnumeratorCancellation] CancellationToken cancellationToken = default)
    {
        var channel = Channel.CreateUnbounded<RemoteControlEvent>();
        var id = Guid.NewGuid();
        var disposed = false;
        lock (_gate)
        {
            disposed = _disposed;
            if (!disposed)
            {
                foreach (var item in _history.Where(item => item.Sequence > sequence && (workspaceId is null || item.WorkspaceId == workspaceId)))
                {
                    channel.Writer.TryWrite(item);
                }
                _subscribers[id] = channel;
            }
        }
        if (disposed) yield break;

        try
        {
            await foreach (var item in channel.Reader.ReadAllAsync(cancellationToken))
            {
                if (workspaceId is null || item.WorkspaceId == workspaceId) yield return item;
            }
        }
        finally
        {
            lock (_gate)
            {
                _subscribers.Remove(id);
                channel.Writer.TryComplete();
            }
        }
    }

    public void Dispose()
    {
        lock (_gate)
        {
            _disposed = true;
            foreach (var channel in _subscribers.Values) channel.Writer.TryComplete();
            _subscribers.Clear();
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

    private sealed record ChallengeState(string Endpoint, string Code, DateTimeOffset ExpiresAt);

    public RemotePairingStore(string root, string workspaceId, IProviderSecretStore secrets)
    {
        _file = Path.Combine(root, "remote-control.json");
        _secrets = secrets;
        _workspaceId = workspaceId;
        _devices = Load();
    }

    public RemotePairingInfo Begin(string endpoint)
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
            _challenge = new ChallengeState(endpoint.TrimEnd('/'), code, expiresAt);
            var payload = $"herness://pair?endpoint={Uri.EscapeDataString(_challenge.Endpoint)}&code={code}";
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
    private readonly SupportPaths _paths;
    private readonly Func<string> _workspaceProvider;
    private readonly RemoteControlEventHub _events;
    private readonly RemotePairingStore _pairing;
    private readonly RemoteControlGateway _gateway;
    private readonly CloudTunnelProcess _tunnel;
    private readonly ConcurrentDictionary<string, PendingCommand> _pending = new(StringComparer.Ordinal);
    private readonly ConcurrentDictionary<string, byte> _commands = new(StringComparer.Ordinal);
    private RemoteAccessMode _accessMode = RemoteAccessMode.Ask;
    private long _revision;
    private RemotePairingInfo? _pairingInfo;

    private sealed record PendingCommand(string Id, string Kind, JsonObject Payload, DateTimeOffset CreatedAt);

    public RemoteControlEventHub Events => _events;
    public RemoteAccessMode AccessMode => _accessMode;
    public string LocalEndpoint => $"http://127.0.0.1:{DefaultPort}";
    public string PreferredEndpoint => $"http://{PreferredHost()}:{DefaultPort}";
    public RemotePairingInfo? Pairing => _pairingInfo;
    public string? PublicEndpoint { get; private set; }
    public bool Running => _gateway.Running;

    public RemoteControlHost(
        AgentBridge bridge,
        SupportPaths paths,
        RemoteControlEventHub events,
        Func<string> workspaceProvider)
    {
        _bridge = bridge;
        _paths = paths;
        _events = events;
        _workspaceProvider = workspaceProvider;
        var workspace = NormalizeWorkspace();
        _pairing = new RemotePairingStore(paths.Root, WorkspaceId(workspace), new PlatformProviderSecrets(paths.Root));
        _gateway = new RemoteControlGateway(DefaultPort, HandleAsync);
        _tunnel = new CloudTunnelProcess(paths);
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

    public void Stop() { _tunnel.Stop(); _gateway.Stop(); }

    public RemotePairingInfo BeginPairing(string endpoint)
    {
        _ = CurrentWorkspace();
        _pairingInfo = _pairing.Begin(endpoint);
        Publish("pairing.ready", new JsonObject { ["endpoint"] = _pairingInfo.Endpoint, ["expiresAt"] = _pairingInfo.ExpiresAt });
        return _pairingInfo;
    }

    public async Task<string> EnableCloudTunnelAsync(CancellationToken cancellationToken = default)
    {
        if (!_gateway.Running) _gateway.Start();
        PublicEndpoint = await _tunnel.StartAsync(DefaultPort, ct: cancellationToken);
        BeginPairing(PublicEndpoint);
        Publish("tunnel.ready", new JsonObject { ["endpoint"] = PublicEndpoint });
        return PublicEndpoint;
    }

    public void DisableCloudTunnel()
    {
        _tunnel.Stop();
        PublicEndpoint = null;
        BeginPairing(PreferredEndpoint);
    }

    public IReadOnlyList<RemotePairingDevice> Devices() => _pairing.Devices();

    public bool RevokeDevice(string id) => _pairing.Revoke(id);

    public void SetWorkspacePath(string workspace) => _pairing.SetWorkspaceId(WorkspaceId(NormalizeWorkspace(workspace)));

    public void SetAccessMode(RemoteAccessMode mode)
    {
        _accessMode = mode;
        Publish("access.changed", new JsonObject { ["mode"] = mode.ToString().ToLowerInvariant() });
    }

    private async Task HandleAsync(RemoteHttpRequest request, Stream stream, CancellationToken cancellationToken)
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

        if (request.Method == "GET" && request.Path == "/v1/control/bootstrap")
        {
            await WriteJsonAsync(stream, 200, Bootstrap(), cancellationToken);
            return;
        }
        if (request.Method == "GET" && request.Path == "/v1/control/events")
        {
            await StreamEventsAsync(request, stream, cancellationToken);
            return;
        }
        if (request.Method == "GET" && (request.Path == "/v1/control/file" || request.Path.StartsWith("/v1/control/files/", StringComparison.Ordinal)))
        {
            await HandleFileReadAsync(request, stream, cancellationToken);
            return;
        }
        if (request.Method == "GET" && (request.Path == "/v1/control/artifact" || request.Path.StartsWith("/v1/control/artifacts/", StringComparison.Ordinal)))
        {
            await HandleArtifactAsync(request, stream, cancellationToken);
            return;
        }
        if (request.Method == "GET" && request.Path == "/v1/control/artifacts")
        {
            await WriteJsonAsync(stream, 200, _events.Artifacts.List(), cancellationToken);
            return;
        }
        if (request.Method == "POST" && request.Path == "/v1/control/snapshot/request")
        {
            await WriteJsonAsync(stream, 200, Snapshot(), cancellationToken);
            return;
        }
        if (request.Method == "POST" && request.Path == "/v1/control/commands")
        {
            var response = await DispatchAsync(request, deviceId, cancellationToken);
            await WriteJsonAsync(stream, response.HttpStatus, response, cancellationToken);
            return;
        }

        await WriteJsonAsync(stream, 404, new { error = "Control route not found." }, cancellationToken);
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

    private async Task<RemoteCommandResponse> DispatchAsync(RemoteHttpRequest request, string deviceId, CancellationToken cancellationToken)
    {
        RemoteControlCommand command;
        try
        {
            var root = JsonNode.Parse(request.Body)?.AsObject() ?? throw new InvalidOperationException("Command body is required.");
            command = new RemoteControlCommand(
                root["id"]?.GetValue<string>() ?? Guid.NewGuid().ToString("N"),
                root["workspaceId"]?.GetValue<string>() ?? WorkspaceId(CurrentWorkspace()),
                root["sessionId"]?.GetValue<string>(),
                root["kind"]?.GetValue<string>() ?? "",
                root["expectedRevision"]?.GetValue<long>(),
                root["payload"]?.AsObject() ?? new JsonObject());
        }
        catch (Exception ex)
        {
            return RemoteCommandResponse.Failed(400, ex.Message);
        }

        if (!_commands.TryAdd(command.Id, 0)) return RemoteCommandResponse.Accepted(command.Id, "duplicate");
        if (!string.Equals(command.WorkspaceId, WorkspaceId(CurrentWorkspace()), StringComparison.Ordinal))
        {
            var response = RemoteCommandResponse.Failed(409, "The workspace is no longer mounted.");
            Audit(command, deviceId, response);
            return response;
        }
        if (command.ExpectedRevision is { } expected && expected != Interlocked.Read(ref _revision))
        {
            var response = RemoteCommandResponse.Failed(409, $"The workspace revision changed. Current revision: {Interlocked.Read(ref _revision)}.");
            Audit(command, deviceId, response);
            return response;
        }

        try
        {
            var response = command.Kind switch
            {
                "prompt" => await PromptAsync(command),
                "continue" => await ContinueAsync(command),
                "stop" or "cancel" => await StopAsync(command),
                "approval" => await ApprovalAsync(command),
                "question" => await QuestionAsync(command),
                "permission" => Permission(command),
                "write_file" => await SensitiveAsync(command, deviceId, cancellationToken),
                "run_command" or "build" or "deploy" => await SensitiveAsync(command, deviceId, cancellationToken),
                "approve" => await ResolvePendingAsync(command, deviceId, cancellationToken),
                "revoke_device" => Revoke(command),
                _ => RemoteCommandResponse.Failed(400, $"Unknown command: {command.Kind}"),
            };
            Audit(command, deviceId, response);
            return response;
        }
        catch (Exception ex)
        {
            Publish("command.failed", new JsonObject { ["commandId"] = command.Id, ["message"] = ex.Message });
            var response = RemoteCommandResponse.Failed(500, ex.Message);
            Audit(command, deviceId, response);
            return response;
        }
    }

    private async Task<RemoteCommandResponse> PromptAsync(RemoteControlCommand command)
    {
        var text = command.Payload["text"]?.GetValue<string>()?.Trim() ?? "";
        if (text.Length == 0) return RemoteCommandResponse.Failed(400, "Prompt text is required.");
        var mode = Enum.TryParse<PromptMode>(command.Payload["mode"]?.GetValue<string>(), true, out var parsed) ? parsed : PromptMode.Queue;
        var plan = command.Payload["planMode"]?.GetValue<bool>() ?? false;
        _ = _bridge.SendAsync(text, mode, plan);
        Publish("command.accepted", new JsonObject { ["commandId"] = command.Id, ["kind"] = command.Kind });
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
        await _bridge.AnswerApprovalAsync(command.Payload["answer"]?.GetValue<string>() ?? "rejected");
        return RemoteCommandResponse.Accepted(command.Id, "approval-forwarded");
    }

    private async Task<RemoteCommandResponse> QuestionAsync(RemoteControlCommand command)
    {
        string[] answers = command.Payload["answers"] is JsonArray list
            ? list.Select(item => item?.GetValue<string>() ?? string.Empty).ToArray()
            : [command.Payload["answer"]?.GetValue<string>() ?? string.Empty];
        await _bridge.AnswerQuestionAsync(answers);
        return RemoteCommandResponse.Accepted(command.Id, "answer-forwarded");
    }

    private RemoteCommandResponse Permission(RemoteControlCommand command)
    {
        var value = command.Payload["mode"]?.GetValue<string>()?.Replace(" ", "", StringComparison.Ordinal).ToLowerInvariant();
        var mode = value switch
        {
            "approve" or "approveme" => RemoteAccessMode.Approve,
            "full" or "fullaccess" => RemoteAccessMode.Full,
            _ => RemoteAccessMode.Ask,
        };
        SetAccessMode(mode);
        return RemoteCommandResponse.Accepted(command.Id, mode.ToString().ToLowerInvariant());
    }

    private async Task<RemoteCommandResponse> SensitiveAsync(RemoteControlCommand command, string deviceId, CancellationToken cancellationToken)
    {
        if (_accessMode == RemoteAccessMode.Ask)
        {
            var approvalId = Guid.NewGuid().ToString("N");
            _pending[approvalId] = new PendingCommand(command.Id, command.Kind, command.Payload.DeepClone().AsObject(), DateTimeOffset.UtcNow);
            Publish("approval.required", new JsonObject
            {
                ["approvalId"] = approvalId,
                ["commandId"] = command.Id,
                ["deviceId"] = deviceId,
                ["kind"] = command.Kind,
                ["summary"] = Summary(command),
            });
            return RemoteCommandResponse.Pending(command.Id, approvalId);
        }
        return await ExecuteSensitiveAsync(command.Id, command.Kind, command.Payload, cancellationToken);
    }

    private async Task<RemoteCommandResponse> ResolvePendingAsync(RemoteControlCommand command, string deviceId, CancellationToken cancellationToken)
    {
        var approvalId = command.Payload["approvalId"]?.GetValue<string>() ?? "";
        if (!_pending.TryRemove(approvalId, out var pending)) return RemoteCommandResponse.Failed(404, "Approval request not found.");
        var answer = command.Payload["answer"]?.GetValue<string>()?.ToLowerInvariant() ?? "rejected";
        if (answer is not ("allowed-once" or "allow" or "approved" or "full"))
        {
            Publish("approval.resolved", new JsonObject { ["approvalId"] = approvalId, ["allowed"] = false, ["deviceId"] = deviceId });
            return RemoteCommandResponse.Accepted(command.Id, "rejected");
        }
        if (answer == "full") SetAccessMode(RemoteAccessMode.Full);
        var result = await ExecuteSensitiveAsync(pending.Id, pending.Kind, pending.Payload, cancellationToken);
        Publish("approval.resolved", new JsonObject { ["approvalId"] = approvalId, ["allowed"] = true, ["deviceId"] = deviceId });
        return result;
    }

    private async Task<RemoteCommandResponse> ExecuteSensitiveAsync(string commandId, string kind, JsonObject payload, CancellationToken cancellationToken)
    {
        var workspace = CurrentWorkspace();
        if (kind == "write_file")
        {
            var path = payload["path"]?.GetValue<string>() ?? "";
            var content = payload["content"]?.GetValue<string>() ?? "";
            var expected = payload["expectedSha256"]?.GetValue<string>();
            var write = RemoteWorkspace.WriteText(workspace, path, content, expected);
            if (write.Conflict) return RemoteCommandResponse.Conflict(commandId, write);
            Publish("file.changed", new JsonObject { ["path"] = write.Path, ["sha256"] = write.Sha256, ["operation"] = "write", ["commandId"] = commandId });
            return RemoteCommandResponse.Ok(commandId, write);
        }

        var shellCommand = payload["command"]?.GetValue<string>()?.Trim() ?? "";
        if (shellCommand.Length == 0) return RemoteCommandResponse.Failed(400, "Command text is required.");
        Publish(kind == "deploy" ? "deploy.progress" : "build.started", new JsonObject { ["commandId"] = commandId, ["kind"] = kind, ["phase"] = "started" });
        var output = await NativeWorkspaceTools.ExecuteCommandStreamingAsync(
            shellCommand,
            workspace,
            line => _events.Publish(
                "terminal.output",
                WorkspaceId(workspace),
                _bridge.Selected?.Id,
                new JsonObject { ["commandId"] = commandId, ["kind"] = kind }),
            cancellationToken);
        var outputEvent = _events.PublishText(
            kind == "deploy" ? "deploy.progress" : "build.output",
            WorkspaceId(workspace),
            _bridge.Selected?.Id,
            output,
            new JsonObject { ["commandId"] = commandId, ["kind"] = kind, ["phase"] = "output" });
        var artifactId = outputEvent.ArtifactId!;
        string? outputArtifactId = null;
        if (kind == "build" && payload["artifactPath"]?.GetValue<string>() is { Length: > 0 } artifactPath)
        {
            var artifactBytes = RemoteWorkspace.ReadArtifact(workspace, artifactPath);
            outputArtifactId = _events.Artifacts.Save("build-artifact", artifactBytes);
            Publish("artifact.ready", new JsonObject { ["path"] = artifactPath, ["bytes"] = artifactBytes.LongLength }, outputArtifactId);
        }
        var bytes = Encoding.UTF8.GetByteCount(output);
        var deployFailed = kind == "deploy" && output.Contains("Command exited with status ", StringComparison.Ordinal);
        Publish(kind == "deploy" ? (deployFailed ? "deploy.failed" : "deploy.completed") : "build.completed", new JsonObject { ["commandId"] = commandId, ["kind"] = kind, ["bytes"] = bytes, ["artifactId"] = artifactId, ["outputArtifactId"] = outputArtifactId, ["truncated"] = bytes > RemoteArtifactStore.MaximumArtifactBytes }, artifactId);
        return RemoteCommandResponse.Ok(commandId, new { outputPreview = output.Length <= 700 ? output : output[..700] + "…", artifactId, outputArtifactId });
    }

    private RemoteCommandResponse Revoke(RemoteControlCommand command)
    {
        var id = command.Payload["deviceId"]?.GetValue<string>() ?? "";
        return _pairing.Revoke(id)
            ? RemoteCommandResponse.Accepted(command.Id, "revoked")
            : RemoteCommandResponse.Failed(404, "Device not found.");
    }

    private RemoteBootstrap Bootstrap()
    {
        var workspace = CurrentWorkspace();
        var selected = _bridge.Selected;
        return new RemoteBootstrap(
            ProtocolVersion,
            _bridge.Area,
            WorkspaceId(workspace),
            workspace,
            Interlocked.Read(ref _revision),
            selected?.Id,
            _bridge.Connection?.Provider,
            _bridge.Connection?.Model,
            _bridge.Status,
            selected?.Running == true,
            _accessMode,
            ["events", "prompt", "continue", "stop", "approval", "question", "files", "snapshot", "artifacts", "write", "terminal", "build", "deploy"],
            _pairing.Devices());
    }

    private RemoteWorkspaceSnapshot Snapshot()
    {
        var workspace = CurrentWorkspace();
        var snapshot = RemoteWorkspace.CreateSnapshot(workspace, WorkspaceId(workspace), Interlocked.Increment(ref _revision));
        Publish("snapshot.ready", new JsonObject { ["revision"] = snapshot.Revision, ["files"] = snapshot.Files.Count, ["excluded"] = snapshot.Excluded.Count });
        return snapshot;
    }

    private async Task HandleFileReadAsync(RemoteHttpRequest request, Stream stream, CancellationToken cancellationToken)
    {
        var path = Query(request.Target, "path");
        if (string.IsNullOrWhiteSpace(path) && request.Path.StartsWith("/v1/control/files/", StringComparison.Ordinal))
        {
            path = Uri.UnescapeDataString(request.Path["/v1/control/files/".Length..]);
        }
        try
        {
            var bytes = RemoteWorkspace.Read(CurrentWorkspace(), path);
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

    private async Task StreamEventsAsync(RemoteHttpRequest request, Stream stream, CancellationToken cancellationToken)
    {
        var after = long.TryParse(Query(request.Target, "after"), out var querySequence) ? querySequence : 0;
        if (request.Headers.TryGetValue("last-event-id", out var last) && long.TryParse(last, out var headerSequence)) after = Math.Max(after, headerSequence);
        var workspaceId = WorkspaceId(CurrentWorkspace());
        await WriteAsciiAsync(stream, "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: keep-alive\r\nX-Accel-Buffering: no\r\n\r\n", cancellationToken);
        await foreach (var item in _events.StreamAsync(after, workspaceId, cancellationToken))
        {
            var json = JsonSerializer.Serialize(item, JsonOptions());
            await WriteAsciiAsync(stream, $"id: {item.Sequence}\nevent: {item.Kind}\ndata: {json}\n\n", cancellationToken);
            await stream.FlushAsync(cancellationToken);
        }
    }

    private void Publish(string kind, JsonObject payload, string? artifactId = null)
    {
        payload["area"] = _bridge.Area.WireValue();
        _events.Publish(kind, WorkspaceId(CurrentWorkspace()), _bridge.Selected?.Id, payload, artifactId);
    }

    private void Audit(RemoteControlCommand command, string deviceId, RemoteCommandResponse response) => Publish("audit.command", new JsonObject
    {
        ["commandId"] = command.Id,
        ["deviceId"] = deviceId,
        ["kind"] = command.Kind,
        ["status"] = response.Status,
        ["httpStatus"] = response.HttpStatus,
    });

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
    private static string WorkspaceId(string workspace) => RemoteControlIdentity.WorkspaceId(workspace);
    private static string Summary(RemoteControlCommand command) => command.Kind == "write_file" ? $"Write {command.Payload["path"]?.GetValue<string>()}" : command.Payload["command"]?.GetValue<string>() ?? command.Kind;
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
    public static string WorkspaceId(string workspace) =>
        Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(Path.GetFullPath(workspace)))).ToLowerInvariant()[..24];
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
    private readonly int _port;
    private readonly Func<RemoteHttpRequest, Stream, CancellationToken, Task> _handler;
    private readonly TcpListener _listener;
    private CancellationTokenSource? _stop;

    public bool Running { get; private set; }

    public RemoteControlGateway(int port, Func<RemoteHttpRequest, Stream, CancellationToken, Task> handler)
    {
        _port = port;
        _handler = handler;
        _listener = new TcpListener(IPAddress.Any, port);
    }

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
        try
        {
            await using var stream = client.GetStream();
            var request = await ReadRequestAsync(stream, requestCancellation.Token);
            await _handler(request, stream, requestCancellation.Token);
        }
        catch (OperationCanceledException) { }
        catch (Exception ex)
        {
            try
            {
                var body = JsonSerializer.SerializeToUtf8Bytes(new { error = ex.Message });
                await WriteErrorAsync(client.GetStream(), body, requestCancellation.Token);
            }
            catch { }
        }
    }

    private static async Task<RemoteHttpRequest> ReadRequestAsync(Stream stream, CancellationToken cancellationToken)
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

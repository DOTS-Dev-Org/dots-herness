// Copyright (c) 2026 DOTS
// Minimal MCP tools client shared by the Windows and Linux desktop clients.

using System.Collections.Concurrent;
using System.ComponentModel;
using System.Diagnostics;
using System.Net.Http.Headers;
using System.Runtime.CompilerServices;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization;
using PluginRuntime;

namespace DotsHarnessCore;

public enum McpTransportKind { Http, Stdio }

public sealed record McpServerConfig
{
    public string Id { get; init; } = Guid.NewGuid().ToString("N");
    public string Name { get; init; } = "";
    public McpTransportKind Transport { get; init; } = McpTransportKind.Http;
    public string Url { get; init; } = "";
    public string Command { get; init; } = "";
    public string[] Arguments { get; init; } = [];
    public Dictionary<string, string> Environment { get; init; } = new(StringComparer.Ordinal);
    public bool Enabled { get; init; } = true;
    public bool AutoRunReadOnly { get; init; }
}

public enum McpConnectionState { Idle, Connecting, Connected, Failed }

public sealed record McpServerStatus(string Id, string Name, McpConnectionState State, int ToolCount = 0, string? Error = null);

public sealed record McpToolInfo(
    string Name,
    string Description,
    JsonNode Parameters,
    bool ReadOnlyHint,
    bool DestructiveHint);

public sealed class McpRegistry : INotifyPropertyChanged, IAsyncDisposable
{
    private sealed record Route(
        string ServerId,
        string ToolName,
        JsonNode Parameters,
        string Description,
        bool ReadOnlyHint,
        bool DestructiveHint);

    private sealed record TestResult(int? ToolCount, string? Error);

    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web)
    {
        WriteIndented = true,
        PropertyNameCaseInsensitive = true,
        Converters = { new JsonStringEnumConverter(JsonNamingPolicy.CamelCase) },
    };

    private readonly object _gate = new();
    private readonly string _configFile;
    private readonly string _catalogFile;
    private readonly IProviderSecretStore _secrets;
    private readonly Dictionary<string, McpServerConfig> _servers = new(StringComparer.Ordinal);
    private readonly Dictionary<string, McpServerStatus> _states = new(StringComparer.Ordinal);
    private readonly Dictionary<string, McpClient> _clients = new(StringComparer.Ordinal);
    private bool _sandboxSuspended;
    private readonly Dictionary<string, Route> _routes = new(StringComparer.Ordinal);

    public event PropertyChangedEventHandler? PropertyChanged;

    public McpRegistry(SupportPaths paths, IProviderSecretStore secrets)
    {
        _configFile = Path.Combine(paths.Root, "mcp-servers.json");
        _catalogFile = Path.Combine(paths.Root, "mcp-servers.catalog.json");
        _secrets = secrets;
        Load();
    }

    public IReadOnlyList<McpServerConfig> Servers
    {
        get { lock (_gate) return _servers.Values.OrderBy(item => item.Name, StringComparer.CurrentCultureIgnoreCase).ToArray(); }
    }

    public IReadOnlyList<McpServerStatus> Statuses
    {
        get
        {
            lock (_gate)
                return _servers.Values
                    .OrderBy(item => item.Name, StringComparer.CurrentCultureIgnoreCase)
                    .Select(item => _states.GetValueOrDefault(item.Id) ?? new McpServerStatus(item.Id, item.Name, McpConnectionState.Idle))
                    .ToArray();
        }
    }

    public void Upsert(McpServerConfig config, string? token = null)
    {
        var normalized = config with
        {
            Id = string.IsNullOrWhiteSpace(config.Id) ? Guid.NewGuid().ToString("N") : config.Id,
            Name = config.Name.Trim(),
            Url = config.Url.Trim(),
            Command = config.Command.Trim(),
            Arguments = config.Arguments?.ToArray() ?? [],
            Environment = new Dictionary<string, string>(config.Environment ?? new(), StringComparer.Ordinal),
        };
        Validate(normalized);
        lock (_gate)
        {
            _servers[normalized.Id] = normalized;
            PersistServers();
        }
        if (!string.IsNullOrEmpty(token)) _secrets.Write(TokenId(normalized.Id), token);
        RaiseChanged(nameof(Servers));
        RaiseChanged(nameof(Statuses));
    }

    public async Task RemoveAsync(string serverId)
    {
        McpClient? client;
        lock (_gate)
        {
            _servers.Remove(serverId);
            _states.Remove(serverId);
            _clients.Remove(serverId, out client);
            foreach (var name in _routes.Where(item => item.Value.ServerId == serverId).Select(item => item.Key).ToArray())
                _routes.Remove(name);
            PersistServers();
            PersistRoutes();
        }
        _secrets.Delete(TokenId(serverId));
        if (client is not null) await client.DisposeAsync();
        RaiseChanged(nameof(Servers));
        RaiseChanged(nameof(Statuses));
    }

    public async Task ConnectAllAsync(CancellationToken cancellationToken = default)
    {
        lock (_gate) if (_sandboxSuspended) return;
        var enabled = Servers.Where(item => item.Enabled).Select(item => item.Id).ToArray();
        await Task.WhenAll(enabled.Select(id => ConnectAsync(id, cancellationToken)));
    }

    /// <summary>Stops MCP child processes and routes while an isolated workspace is active.</summary>
    public async Task SuspendForSandboxAsync(bool suspended)
    {
        McpClient[] clients = [];
        lock (_gate)
        {
            if (_sandboxSuspended == suspended) return;
            _sandboxSuspended = suspended;
            if (suspended)
            {
                clients = _clients.Values.ToArray();
                _clients.Clear();
                _routes.Clear();
                foreach (var server in _servers.Values)
                    _states[server.Id] = new McpServerStatus(server.Id, server.Name, McpConnectionState.Idle,
                        Error: "MCP connections are paused while a sandbox workspace is active.");
                PersistRoutes();
            }
        }
        if (clients.Length > 0) await Task.WhenAll(clients.Select(client => client.DisposeAsync().AsTask()));
        RaiseChanged(nameof(Statuses));
        if (!suspended) await ConnectAllAsync();
    }

    public async Task ConnectAsync(string serverId, CancellationToken cancellationToken = default)
    {
        McpServerConfig? config;
        McpClient? previous;
        lock (_gate)
        {
            if (_sandboxSuspended || !_servers.TryGetValue(serverId, out config) || !config.Enabled) return;
            _states[serverId] = new McpServerStatus(config.Id, config.Name, McpConnectionState.Connecting);
            _clients.Remove(serverId, out previous);
        }
        RaiseChanged(nameof(Statuses));
        if (previous is not null) await previous.DisposeAsync();

        var client = new McpClient(config, _secrets.Read(TokenId(config.Id)));
        try
        {
            await client.ConnectAsync(cancellationToken);
            lock (_gate)
            {
                _clients[serverId] = client;
                _states[serverId] = new McpServerStatus(config.Id, config.Name, McpConnectionState.Connected, client.Tools.Count);
                RegisterRoutes(config.Id, client.Tools);
                PersistRoutes();
            }
        }
        catch (Exception error)
        {
            await client.DisposeAsync();
            lock (_gate)
                _states[serverId] = new McpServerStatus(config.Id, config.Name, McpConnectionState.Failed, Error: error.Message);
        }
        RaiseChanged(nameof(Statuses));
    }

    public async Task<(int? ToolCount, string? Error)> TestAsync(McpServerConfig config, string? token = null, CancellationToken cancellationToken = default)
    {
        try
        {
            Validate(config);
            await using var client = new McpClient(config, token);
            await client.ConnectAsync(cancellationToken);
            return (client.Tools.Count, null);
        }
        catch (Exception error) { return (null, error.Message); }
    }

    public IReadOnlyList<NativeToolDefinition> ToolDefinitions()
    {
        lock (_gate)
        {
            var configuredIDs = _servers.Keys.ToHashSet(StringComparer.Ordinal);
            return _routes
                .Where(item => configuredIDs.Contains(item.Value.ServerId)
                    && _servers[item.Value.ServerId].Enabled)
                .OrderBy(item => item.Key, StringComparer.Ordinal)
                .Select(item => new NativeToolDefinition(item.Key, item.Value.Description, item.Value.Parameters.DeepClone()))
                .ToArray();
        }
    }

    public bool IsMcpTool(string name) { lock (_gate) return _routes.ContainsKey(name); }

    public bool IsAvailable(string name)
    {
        lock (_gate)
            return _routes.TryGetValue(name, out var route)
                && _servers.TryGetValue(route.ServerId, out var server)
                && server.Enabled
                && _clients.ContainsKey(route.ServerId)
                && _states.GetValueOrDefault(route.ServerId)?.State == McpConnectionState.Connected;
    }

    public bool ShouldAutoRun(string name)
    {
        lock (_gate)
            return IsAvailableUnderLock(name, out var route, out var server)
                && server.AutoRunReadOnly && route.ReadOnlyHint && !route.DestructiveHint;
    }

    public async Task<string> CallAsync(string name, JsonNode? arguments, CancellationToken cancellationToken)
    {
        McpClient client;
        string toolName;
        lock (_gate)
        {
            if (!_routes.TryGetValue(name, out var route)
                || !_clients.TryGetValue(route.ServerId, out client!)
                || !_servers.TryGetValue(route.ServerId, out var server)
                || !server.Enabled)
                throw new InvalidOperationException("The MCP server is not connected.");
            toolName = route.ToolName;
        }
        return await client.CallToolAsync(toolName, arguments, cancellationToken);
    }

    private bool IsAvailableUnderLock(string name, out Route route, out McpServerConfig server)
    {
        route = null!;
        server = null!;
        return _routes.TryGetValue(name, out route!)
            && _servers.TryGetValue(route.ServerId, out server!)
            && server.Enabled
            && _clients.ContainsKey(route.ServerId)
            && _states.GetValueOrDefault(route.ServerId)?.State == McpConnectionState.Connected;
    }

    private void RegisterRoutes(string serverId, IReadOnlyList<McpToolInfo> tools)
    {
        foreach (var name in _routes.Where(item => item.Value.ServerId == serverId).Select(item => item.Key).ToArray())
            _routes.Remove(name);
        McpServerConfig server = _servers[serverId];
        var slug = Sanitize(string.IsNullOrWhiteSpace(server.Name) ? server.Id : server.Name);
        if (tools.Any(tool => _routes.ContainsKey($"mcp__{slug}__{Sanitize(tool.Name)}")))
            slug += "_" + new string(server.Id.Where(char.IsAsciiLetterOrDigit).Take(8).ToArray());
        var candidates = tools.Select(tool => (Name: $"mcp__{slug}__{Sanitize(tool.Name)}", Tool: tool)).ToArray();
        var duplicates = candidates.GroupBy(item => item.Name, StringComparer.Ordinal)
            .Where(group => group.Count() > 1).Select(group => group.Key).ToHashSet(StringComparer.Ordinal);
        foreach (var candidate in candidates.Where(item => !duplicates.Contains(item.Name)))
        {
            _routes[candidate.Name] = new Route(serverId, candidate.Tool.Name, candidate.Tool.Parameters.DeepClone(),
                candidate.Tool.Description, candidate.Tool.ReadOnlyHint, candidate.Tool.DestructiveHint);
        }
    }

    private void Load()
    {
        try
        {
            if (File.Exists(_configFile))
                foreach (var server in JsonSerializer.Deserialize<McpServerConfig[]>(File.ReadAllText(_configFile), JsonOptions) ?? [])
                    if (!string.IsNullOrWhiteSpace(server.Id) && !string.IsNullOrWhiteSpace(server.Name)) _servers[server.Id] = server;
        }
        catch { }
        try
        {
            if (File.Exists(_catalogFile))
            {
                var saved = JsonSerializer.Deserialize<Dictionary<string, Route>>(
                    File.ReadAllText(_catalogFile), JsonOptions);
                if (saved is not null)
                    foreach (var item in saved.Where(item => _servers.ContainsKey(item.Value.ServerId))) _routes[item.Key] = item.Value;
            }
        }
        catch { }
    }

    private void PersistServers() => WriteJson(_configFile, _servers.Values.ToArray());
    private void PersistRoutes() => WriteJson(_catalogFile, _routes);

    private static void WriteJson<T>(string path, T value)
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            var temp = path + ".tmp";
            File.WriteAllText(temp, JsonSerializer.Serialize(value, JsonOptions), new UTF8Encoding(false));
            File.Move(temp, path, overwrite: true);
        }
        catch { }
    }

    private static void Validate(McpServerConfig config)
    {
        if (string.IsNullOrWhiteSpace(config.Name)) throw new InvalidOperationException("Enter a server name.");
        if (string.IsNullOrWhiteSpace(config.Id) || config.Id.Length > 128) throw new InvalidOperationException("The MCP server id is invalid.");
        if (config.Transport == McpTransportKind.Http)
        {
            if (!Uri.TryCreate(config.Url, UriKind.Absolute, out var uri) || uri.Scheme is not ("http" or "https")
                || !string.IsNullOrEmpty(uri.UserInfo) || !string.IsNullOrEmpty(uri.Fragment))
                throw new InvalidOperationException("Enter an HTTP or HTTPS MCP endpoint without embedded credentials or a fragment.");
        }
        else if (string.IsNullOrWhiteSpace(config.Command) || config.Command.Contains('\0'))
            throw new InvalidOperationException("Enter the MCP server executable path.");
        if ((config.Arguments ?? []).Any(argument => argument.Contains('\0'))
            || (config.Environment ?? new()).Any(item => item.Key.Contains('=') || item.Key.Contains('\0') || item.Value.Contains('\0')))
            throw new InvalidOperationException("The MCP server arguments or environment are invalid.");
    }

    private void RaiseChanged([CallerMemberName] string? name = null) => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
    private static string TokenId(string id) => "mcp.server." + id;
    private static string Sanitize(string value) => string.Concat(value.Select(character =>
        char.IsLetterOrDigit(character) || character is '_' or '-' ? character : '_'));

    public async ValueTask DisposeAsync()
    {
        McpClient[] clients;
        lock (_gate) { clients = _clients.Values.ToArray(); _clients.Clear(); }
        await Task.WhenAll(clients.Select(client => client.DisposeAsync().AsTask()));
    }
}

internal sealed class McpClient : IAsyncDisposable
{
    private const string ProtocolVersion = "2025-06-18";
    private readonly McpServerConfig _config;
    private readonly string? _token;
    private IMcpTransport? _transport;
    private int _nextRequestId;

    public IReadOnlyList<McpToolInfo> Tools { get; private set; } = [];

    public McpClient(McpServerConfig config, string? token)
    {
        _config = config;
        _token = token;
    }

    public async Task ConnectAsync(CancellationToken cancellationToken)
    {
        _transport = _config.Transport switch
        {
            McpTransportKind.Http => new McpHttpTransport(_config, _token),
            McpTransportKind.Stdio => new McpStdioTransport(_config),
            _ => throw new InvalidOperationException("Unsupported MCP transport."),
        };
        var init = await RpcAsync("initialize", new JsonObject
        {
            ["protocolVersion"] = ProtocolVersion,
            ["capabilities"] = new JsonObject { ["tools"] = new JsonObject() },
            ["clientInfo"] = new JsonObject { ["name"] = "DotsHarness", ["version"] = "1.0" },
        }, cancellationToken);
        var selectedVersion = init["protocolVersion"]?.GetValue<string>();
        if (string.IsNullOrWhiteSpace(selectedVersion)) throw new InvalidOperationException("The MCP server did not negotiate a protocol version.");
        if (!string.Equals(selectedVersion, ProtocolVersion, StringComparison.Ordinal))
            throw new InvalidOperationException($"The MCP server selected unsupported protocol version {selectedVersion}.");
        _transport.SetProtocolVersion(selectedVersion);
        await _transport.SendAsync(new JsonObject { ["jsonrpc"] = "2.0", ["method"] = "notifications/initialized" }, false, cancellationToken);

        var tools = new List<McpToolInfo>();
        string? cursor = null;
        do
        {
            var parameters = new JsonObject();
            if (!string.IsNullOrEmpty(cursor)) parameters["cursor"] = cursor;
            var page = await RpcAsync("tools/list", parameters, cancellationToken);
            if (page["tools"] is JsonArray rows)
            {
                foreach (var row in rows.OfType<JsonObject>())
                {
                    var name = row["name"]?.GetValue<string>() ?? "";
                    if (name.Length == 0) continue;
                    var annotations = row["annotations"] as JsonObject;
                    tools.Add(new McpToolInfo(
                        name,
                        row["description"]?.GetValue<string>() ?? "",
                        row["inputSchema"]?.DeepClone() ?? new JsonObject { ["type"] = "object", ["properties"] = new JsonObject() },
                        annotations?["readOnlyHint"]?.GetValue<bool>() ?? false,
                        annotations?["destructiveHint"]?.GetValue<bool>() ?? true));
                }
            }
            cursor = page["nextCursor"]?.GetValue<string>();
        } while (!string.IsNullOrEmpty(cursor));
        Tools = tools;
    }

    public async Task<string> CallToolAsync(string toolName, JsonNode? arguments, CancellationToken cancellationToken)
    {
        var parameters = new JsonObject
        {
            ["name"] = toolName,
            ["arguments"] = arguments?.DeepClone() ?? new JsonObject(),
        };
        var result = await RpcAsync("tools/call", parameters, cancellationToken);
        var content = result["content"] as JsonArray;
        var text = content?.OfType<JsonObject>()
            .Where(item => item["type"]?.GetValue<string>() == "text")
            .Select(item => item["text"]?.GetValue<string>() ?? "")
            .Where(item => item.Length > 0)
            .ToArray() ?? [];
        var output = text.Length > 0 ? string.Join("\n", text) : result.ToJsonString(new JsonSerializerOptions { WriteIndented = true });
        if (result["isError"]?.GetValue<bool>() == true)
            throw new InvalidOperationException(output.Length == 0 ? "The MCP tool reported an error." : output);
        return output;
    }

    private async Task<JsonObject> RpcAsync(string method, JsonObject parameters, CancellationToken cancellationToken)
    {
        var transport = _transport ?? throw new InvalidOperationException("The MCP server is not connected.");
        var id = Interlocked.Increment(ref _nextRequestId);
        var request = new JsonObject { ["jsonrpc"] = "2.0", ["id"] = id, ["method"] = method, ["params"] = parameters };
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(TimeSpan.FromSeconds(60));
        var responseText = await transport.SendAsync(request, true, timeout.Token)
            ?? throw new InvalidOperationException("The MCP server returned an empty response.");
        var response = McpProtocol.ParseResponse(responseText, id);
        if (response["error"] is JsonObject error)
            throw new InvalidOperationException($"MCP error {error["code"]?.ToJsonString() ?? "-1"}: {error["message"]?.GetValue<string>() ?? "unknown error"}");
        return response["result"] as JsonObject ?? new JsonObject();
    }

    public async ValueTask DisposeAsync()
    {
        if (_transport is { } transport)
        {
            _transport = null;
            await transport.DisposeAsync();
        }
        Tools = [];
    }
}

internal interface IMcpTransport : IAsyncDisposable
{
    void SetProtocolVersion(string version);
    Task<string?> SendAsync(JsonObject message, bool expectsResponse, CancellationToken cancellationToken);
}

internal sealed class McpHttpTransport : IMcpTransport
{
    private readonly McpServerConfig _config;
    private readonly string? _token;
    private readonly HttpClient _client = new() { Timeout = TimeSpan.FromSeconds(60) };
    private string? _sessionId;
    private string? _protocolVersion;

    public McpHttpTransport(McpServerConfig config, string? token) { _config = config; _token = token; }
    public void SetProtocolVersion(string version) => _protocolVersion = version;

    public async Task<string?> SendAsync(JsonObject message, bool expectsResponse, CancellationToken cancellationToken)
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, _config.Url);
        request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
        request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("text/event-stream"));
        if (_protocolVersion is not null)
            request.Headers.TryAddWithoutValidation("MCP-Protocol-Version", _protocolVersion);
        if (!string.IsNullOrWhiteSpace(_sessionId)) request.Headers.TryAddWithoutValidation("Mcp-Session-Id", _sessionId);
        if (!string.IsNullOrEmpty(_token)) request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", _token);
        request.Content = new StringContent(message.ToJsonString(), Encoding.UTF8, "application/json");
        using var response = await _client.SendAsync(request, HttpCompletionOption.ResponseContentRead, cancellationToken);
        if (response.Headers.TryGetValues("Mcp-Session-Id", out var sessions)) _sessionId = sessions.FirstOrDefault();
        if (response.StatusCode == System.Net.HttpStatusCode.NotFound && _sessionId is not null)
            throw new InvalidOperationException("The MCP HTTP session expired. Reconnect to start a new session.");
        if (!response.IsSuccessStatusCode)
        {
            var body = await response.Content.ReadAsStringAsync(cancellationToken);
            throw new InvalidOperationException($"MCP HTTP {(int)response.StatusCode}{(string.IsNullOrWhiteSpace(body) ? "" : $": {body[..Math.Min(body.Length, 600)]}")}");
        }
        if (!expectsResponse) return null;
        var content = await response.Content.ReadAsStringAsync(cancellationToken);
        return content.Length == 0 ? null : content;
    }

    public async ValueTask DisposeAsync()
    {
        if (_sessionId is not null && Uri.TryCreate(_config.Url, UriKind.Absolute, out var endpoint))
        {
            try
            {
                using var request = new HttpRequestMessage(HttpMethod.Delete, endpoint);
                request.Headers.TryAddWithoutValidation("Mcp-Session-Id", _sessionId);
                if (_protocolVersion is not null) request.Headers.TryAddWithoutValidation("MCP-Protocol-Version", _protocolVersion);
                if (!string.IsNullOrEmpty(_token)) request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", _token);
                using var response = await _client.SendAsync(request, CancellationToken.None);
            }
            catch { }
        }
        _client.Dispose();
    }

}

internal sealed class McpStdioTransport : IMcpTransport
{
    private const int MaxLineLength = 4 * 1024 * 1024;
    private readonly McpServerConfig _config;
    private readonly Process _process = new();
    private readonly SemaphoreSlim _writeLock = new(1, 1);
    private readonly ConcurrentDictionary<int, TaskCompletionSource<string>> _pending = new();
    private Task? _reader;
    private Task? _stderrReader;
    private string? _protocolVersion;
    private int _started;

    public McpStdioTransport(McpServerConfig config) => _config = config;
    public void SetProtocolVersion(string version) => _protocolVersion = version;

    public async Task<string?> SendAsync(JsonObject message, bool expectsResponse, CancellationToken cancellationToken)
    {
        await StartAsync(cancellationToken);
        var id = expectsResponse ? message["id"]?.GetValue<int>() : null;
        TaskCompletionSource<string>? completion = null;
        if (id is { } requestId)
        {
            completion = new TaskCompletionSource<string>(TaskCreationOptions.RunContinuationsAsynchronously);
            if (!_pending.TryAdd(requestId, completion)) throw new InvalidOperationException("Duplicate MCP request id.");
        }
        try
        {
            await _writeLock.WaitAsync(cancellationToken);
            try
            {
                await _process.StandardInput.WriteLineAsync(message.ToJsonString().AsMemory(), cancellationToken);
                await _process.StandardInput.FlushAsync(cancellationToken);
            }
            finally { _writeLock.Release(); }
            return completion is null ? null : await completion.Task.WaitAsync(TimeSpan.FromSeconds(60), cancellationToken);
        }
        finally { if (id is { } requestID) _pending.TryRemove(requestID, out _); }
    }

    private Task StartAsync(CancellationToken cancellationToken)
    {
        if (Interlocked.CompareExchange(ref _started, 1, 0) != 0) return Task.CompletedTask;
        cancellationToken.ThrowIfCancellationRequested();
        if (string.IsNullOrWhiteSpace(_config.Command)) throw new InvalidOperationException("The MCP server executable path is empty.");
        _process.StartInfo = new ProcessStartInfo
        {
            FileName = _config.Command,
            UseShellExecute = false,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true,
            StandardOutputEncoding = new UTF8Encoding(false),
            StandardErrorEncoding = new UTF8Encoding(false),
        };
        foreach (var argument in _config.Arguments) _process.StartInfo.ArgumentList.Add(argument);
        foreach (var item in _config.Environment) _process.StartInfo.Environment[item.Key] = item.Value;
        try
        {
            if (!_process.Start()) throw new InvalidOperationException("The MCP server process could not start.");
        }
        catch (Exception error) { Interlocked.Exchange(ref _started, 0); throw new InvalidOperationException($"Could not launch '{_config.Command}': {error.Message}", error); }
        _reader = ReadLoopAsync();
        _stderrReader = DrainStderrAsync();
        return Task.CompletedTask;
    }

    private async Task ReadLoopAsync()
    {
        try
        {
            while (!_process.HasExited)
            {
                var line = await _process.StandardOutput.ReadLineAsync();
                if (line is null) break;
                if (Encoding.UTF8.GetByteCount(line) > MaxLineLength) throw new InvalidOperationException("The MCP response exceeded the 4 MiB line limit.");
                try
                {
                    var root = JsonNode.Parse(line) as JsonObject;
                    if (root?["id"] is JsonValue value && value.TryGetValue<int>(out var id)
                        && _pending.TryRemove(id, out var completion)) completion.TrySetResult(line);
                }
                catch (JsonException) { /* A non-protocol stdout line cannot satisfy an MCP request. */ }
            }
        }
        catch (Exception error)
        {
            foreach (var completion in _pending.Values) completion.TrySetException(error);
        }
        finally
        {
            var failure = new InvalidOperationException("The MCP server closed its standard output.");
            foreach (var completion in _pending.Values) completion.TrySetException(failure);
        }
    }

    private async Task DrainStderrAsync()
    {
        try { while (await _process.StandardError.ReadLineAsync() is not null) { } }
        catch { }
    }

    public async ValueTask DisposeAsync()
    {
        try
        {
            if (!_process.HasExited)
            {
                _process.StandardInput.Close();
                if (!_process.WaitForExit(1500)) _process.Kill(entireProcessTree: true);
            }
        }
        catch { try { if (!_process.HasExited) _process.Kill(entireProcessTree: true); } catch { } }
        var failure = new InvalidOperationException("The MCP connection was closed.");
        foreach (var entry in _pending.ToArray())
            if (_pending.TryRemove(entry.Key, out var completion)) completion.TrySetException(failure);
        try { if (_reader is not null) await _reader.WaitAsync(TimeSpan.FromSeconds(2)); } catch { }
        try { if (_stderrReader is not null) await _stderrReader.WaitAsync(TimeSpan.FromSeconds(2)); } catch { }
        _process.Dispose();
        _writeLock.Dispose();
    }
}

internal static class McpProtocol
{
    public static JsonObject ParseResponse(string responseText, int expectedId)
    {
        try
        {
            if (JsonNode.Parse(responseText) is JsonObject response && HasExpectedId(response, expectedId)) return response;
        }
        catch (JsonException) { }
        foreach (var line in responseText.Split('\n'))
        {
            if (!line.StartsWith("data:", StringComparison.Ordinal)) continue;
            var json = line[5..].Trim();
            try
            {
                if (JsonNode.Parse(json) is JsonObject response && HasExpectedId(response, expectedId)) return response;
            }
            catch (JsonException) { }
        }
        throw new InvalidOperationException("The MCP response did not contain the matching JSON-RPC response.");
    }

    private static bool HasExpectedId(JsonObject response, int expectedId) =>
        response["id"] is JsonValue id && id.TryGetValue<int>(out var actualId) && actualId == expectedId;
}

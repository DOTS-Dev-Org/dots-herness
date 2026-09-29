// Copyright (c) 2026 DOTS
// Minimal Model Context Protocol client for the Windows and Linux shells: HTTP +
// stdio transports, tools only. Port of macOS MCPClient.swift / MCPRegistry.swift.
//
// Covers what the agent loop needs: initialize -> notifications/initialized ->
// tools/list -> tools/call. Resources, prompts, sampling and interactive OAuth are
// out of scope. readOnlyHint / destructiveHint are advisory only; they never grant
// automatic execution on their own.
//
// Bearer tokens live in the platform secret store (DPAPI / Secret Service), never
// in mcp-servers.json.

using System.Diagnostics;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization;
using PluginRuntime;

namespace DotsHarnessCore;

[JsonConverter(typeof(JsonStringEnumConverter))]
public enum MCPTransportKind
{
    Http,
    Stdio,
}

public sealed class MCPServerConfig
{
    public string Id { get; set; } = Guid.NewGuid().ToString();
    public string Name { get; set; } = "";
    public MCPTransportKind Transport { get; set; } = MCPTransportKind.Http;
    /// <summary>HTTP endpoint (Transport == Http).</summary>
    public string Url { get; set; } = "";
    /// <summary>Executable + arguments (Transport == Stdio).</summary>
    public string Command { get; set; } = "";
    public List<string> Arguments { get; set; } = [];
    public Dictionary<string, string> Environment { get; set; } = new();
    public bool Enabled { get; set; } = true;
    /// <summary>
    /// When true, a tool whose readOnlyHint is set runs without an approval prompt.
    /// Off by default: the hint is advisory, not a guarantee.
    /// </summary>
    public bool AutoRunReadOnly { get; set; }

    public MCPServerConfig Clone() => new()
    {
        Id = Id, Name = Name, Transport = Transport, Url = Url, Command = Command,
        Arguments = [.. Arguments], Environment = new(Environment), Enabled = Enabled, AutoRunReadOnly = AutoRunReadOnly,
    };
}

public sealed record MCPToolInfo(
    string Name, string Description, JsonNode InputSchema, bool ReadOnlyHint, bool DestructiveHint);

public sealed class MCPException : Exception
{
    public MCPException(string message) : base(message) { }

    public static MCPException NotConnected() => new("The MCP server is not connected.");
    public static MCPException Transport(string message) => new($"MCP transport error: {message}");
    public static MCPException Rpc(int code, string message) => new($"MCP error {code}: {message}");
    public static MCPException Decode(string message) => new($"Malformed MCP response: {message}");
}

/// <summary>One JSON-RPC channel to a server. Implementations own their own framing.</summary>
public interface IMCPTransport : IDisposable
{
    /// <summary>
    /// <paramref name="request"/> is a complete JSON-RPC object (no trailing newline). Returns the
    /// response bytes as text, or null when <paramref name="expectsResponse"/> is false.
    /// </summary>
    Task<string?> SendAsync(string request, bool expectsResponse, CancellationToken ct);
}

public sealed class MCPClient : IDisposable
{
    private readonly Func<MCPServerConfig, IMCPTransport> _makeTransport;
    private IMCPTransport? _transport;
    private int _nextId;

    public MCPServerConfig Config { get; }
    public IReadOnlyList<MCPToolInfo> Tools { get; private set; } = Array.Empty<MCPToolInfo>();
    public string ServerInfo { get; private set; } = "";

    public MCPClient(
        MCPServerConfig config,
        Func<MCPServerConfig, IMCPTransport>? transportFactory = null,
        IProviderSecretStore? secrets = null,
        string? sandboxWorkspace = null)
    {
        Config = config;
        _makeTransport = transportFactory ?? (cfg => cfg.Transport switch
        {
            MCPTransportKind.Http => new MCPHttpTransport(cfg, secrets),
            _ => new MCPStdioTransport(cfg, sandboxWorkspace),
        });
    }

    public async Task ConnectAsync(CancellationToken ct = default)
    {
        _transport = _makeTransport(Config);
        var init = await RpcAsync("initialize", new JsonObject
        {
            ["protocolVersion"] = "2025-06-18",
            ["capabilities"] = new JsonObject { ["tools"] = new JsonObject() },
            ["clientInfo"] = new JsonObject { ["name"] = "DotsHarness", ["version"] = "1.0" },
        }, ct).ConfigureAwait(false);
        if (init["serverInfo"]?["name"]?.GetValue<string>() is { } name) ServerInfo = name;
        var initialized = new JsonObject { ["jsonrpc"] = "2.0", ["method"] = "notifications/initialized" }.ToJsonString();
        try { await _transport.SendAsync(initialized, expectsResponse: false, ct).ConfigureAwait(false); }
        catch (Exception e) when (e is MCPException or HttpRequestException or IOException) { }
        await RefreshToolsAsync(ct).ConfigureAwait(false);
    }

    public async Task RefreshToolsAsync(CancellationToken ct = default)
    {
        var result = await RpcAsync("tools/list", new JsonObject(), ct).ConfigureAwait(false);
        var tools = new List<MCPToolInfo>();
        foreach (var raw in result["tools"]?.AsArray() ?? [])
        {
            if (raw is not JsonObject tool || tool["name"]?.GetValue<string>() is not { Length: > 0 } name) continue;
            var annotations = tool["annotations"] as JsonObject;
            tools.Add(new MCPToolInfo(
                name,
                tool["description"]?.GetValue<string>() ?? "",
                tool["inputSchema"]?.DeepClone() ?? new JsonObject { ["type"] = "object" },
                annotations?["readOnlyHint"]?.GetValue<bool>() ?? false,
                // A missing hint is treated as destructive: unknown never earns auto-run.
                annotations?["destructiveHint"]?.GetValue<bool>() ?? true));
        }
        Tools = tools;
    }

    public async Task<string> CallToolAsync(string name, JsonNode? arguments, CancellationToken ct = default)
    {
        var result = await RpcAsync("tools/call", new JsonObject
        {
            ["name"] = name,
            ["arguments"] = arguments is JsonObject ? arguments.DeepClone() : new JsonObject(),
        }, ct).ConfigureAwait(false);
        var text = TextBlocks(result["content"]);
        if (result["isError"]?.GetValue<bool>() == true)
            throw MCPException.Rpc(-1, text.Length == 0 ? "tool reported an error" : text);
        return text;
    }

    public void Disconnect()
    {
        _transport?.Dispose();
        _transport = null;
        Tools = Array.Empty<MCPToolInfo>();
    }

    public void Dispose() => Disconnect();

    private async Task<JsonObject> RpcAsync(string method, JsonObject parameters, CancellationToken ct)
    {
        var transport = _transport ?? throw MCPException.NotConnected();
        var id = Interlocked.Increment(ref _nextId);
        var payload = new JsonObject { ["jsonrpc"] = "2.0", ["id"] = id, ["method"] = method };
        if (parameters.Count > 0) payload["params"] = parameters;
        var response = await transport.SendAsync(payload.ToJsonString(), expectsResponse: true, ct).ConfigureAwait(false)
            ?? throw MCPException.Decode("empty response");
        var decoded = DecodeJsonRpc(response);
        if (decoded["error"] is JsonObject error)
            throw MCPException.Rpc(
                error["code"]?.GetValue<int>() ?? -1,
                error["message"]?.GetValue<string>() ?? "unknown error");
        return decoded["result"] as JsonObject ?? new JsonObject();
    }

    /// <summary>
    /// The body is either a bare JSON-RPC object or an SSE stream whose <c>data:</c> lines carry
    /// the JSON-RPC messages. Takes the first object that has an <c>id</c> (the response).
    /// </summary>
    public static JsonObject DecodeJsonRpc(string body)
    {
        try
        {
            if (JsonNode.Parse(body) is JsonObject bare) return bare;
        }
        catch (JsonException) { }
        foreach (var raw in body.Split('\n'))
        {
            var line = raw.TrimEnd('\r');
            if (!line.StartsWith("data:", StringComparison.Ordinal)) continue;
            try
            {
                if (JsonNode.Parse(line[5..].Trim()) is JsonObject obj && obj["id"] is not null) return obj;
            }
            catch (JsonException) { }
        }
        throw MCPException.Decode("no JSON-RPC object in response body");
    }

    /// <summary>Text of a tool result's content: string, array of text blocks, or a wrapping object.</summary>
    public static string TextBlocks(JsonNode? node) => node switch
    {
        JsonValue value when value.TryGetValue<string>(out var text) => text,
        JsonArray items => string.Concat(items
            .Where(item => item is not JsonObject o || o["type"]?.GetValue<string>() != "reasoning")
            .Select(item => (item as JsonObject)?["text"]?.GetValue<string>() ?? "")),
        JsonObject obj when obj["type"]?.GetValue<string>() == "text" => obj["text"]?.GetValue<string>() ?? "",
        JsonObject obj when obj["content"] is { } content => TextBlocks(content),
        JsonObject obj when obj["message"] is { } message => TextBlocks(message),
        JsonObject obj => obj["text"]?.GetValue<string>() ?? "",
        _ => "",
    };
}

/// <summary>Streamable HTTP transport: a POST per message, optional SSE body.</summary>
public sealed class MCPHttpTransport : IMCPTransport
{
    private readonly MCPServerConfig _config;
    private readonly IProviderSecretStore? _secrets;
    private readonly HttpClient _http = new() { Timeout = TimeSpan.FromSeconds(60) };
    private string? _sessionId;

    public MCPHttpTransport(MCPServerConfig config, IProviderSecretStore? secrets)
    {
        _config = config;
        _secrets = secrets;
    }

    public async Task<string?> SendAsync(string request, bool expectsResponse, CancellationToken ct)
    {
        if (!Uri.TryCreate(_config.Url, UriKind.Absolute, out var uri) || uri.Scheme is not ("http" or "https"))
            throw MCPException.Transport("invalid URL");
        using var message = new HttpRequestMessage(HttpMethod.Post, uri)
        {
            Content = new StringContent(request, Encoding.UTF8, "application/json"),
        };
        message.Headers.Accept.ParseAdd("application/json");
        message.Headers.Accept.ParseAdd("text/event-stream");
        if (_secrets?.Read(MCPRegistry.TokenKey(_config.Id)) is { Length: > 0 } token)
            message.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        if (_sessionId is not null) message.Headers.TryAddWithoutValidation("Mcp-Session-Id", _sessionId);

        using var response = await _http.SendAsync(message, ct).ConfigureAwait(false);
        if (response.Headers.TryGetValues("Mcp-Session-Id", out var ids)) _sessionId = ids.FirstOrDefault() ?? _sessionId;
        if (!response.IsSuccessStatusCode) throw MCPException.Transport($"HTTP {(int)response.StatusCode}");
        return expectsResponse ? await response.Content.ReadAsStringAsync(ct).ConfigureAwait(false) : null;
    }

    public void Dispose() => _http.Dispose();
}

/// <summary>
/// Newline-delimited JSON-RPC over a child process's stdio. One reader task fans responses out to
/// callers by request id. While a sandbox worktree is active the server is launched inside the
/// same bubblewrap jail as run_command; where no jail exists the launch is refused (fail closed).
/// </summary>
public sealed class MCPStdioTransport : IMCPTransport
{
    private static readonly TimeSpan RequestTimeout = TimeSpan.FromSeconds(120);

    private readonly MCPServerConfig _config;
    private readonly string? _sandboxWorkspace;
    private readonly object _gate = new();
    private readonly Dictionary<long, TaskCompletionSource<string>> _pending = new();
    private Process? _process;

    public MCPStdioTransport(MCPServerConfig config, string? sandboxWorkspace = null)
    {
        _config = config;
        _sandboxWorkspace = sandboxWorkspace;
    }

    private void StartIfNeeded()
    {
        lock (_gate)
        {
            if (_process is not null) return;
            var start = new ProcessStartInfo
            {
                RedirectStandardInput = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false,
                CreateNoWindow = true,
                StandardOutputEncoding = new UTF8Encoding(false),
            };
            if (_sandboxWorkspace is not null)
            {
                if (!AgentCommandSandbox.TryConfigure(start, _sandboxWorkspace, out var error))
                    throw MCPException.Transport(error);
                // TryConfigure leaves "/bin/sh -lc" open for a command string.
                var line = string.Join(" ", new[] { _config.Command }.Concat(_config.Arguments).Select(SSHRunner.ShellQuote));
                start.ArgumentList.Add(line);
            }
            else
            {
                start.FileName = _config.Command;
                foreach (var argument in _config.Arguments) start.ArgumentList.Add(argument);
            }
            foreach (var (key, value) in _config.Environment) start.Environment[key] = value;

            var process = new Process { StartInfo = start, EnableRaisingEvents = true };
            try { process.Start(); }
            catch (Exception e) when (e is System.ComponentModel.Win32Exception or InvalidOperationException)
            {
                throw MCPException.Transport($"failed to launch {_config.Command}: {e.Message}");
            }
            process.Exited += (_, _) => FailPending();
            // stderr is drained so a chatty server cannot block on a full pipe.
            _ = Task.Run(async () => { try { while (await process.StandardError.ReadLineAsync() is not null) { } } catch (IOException) { } });
            _ = Task.Run(() => ReadLoop(process));
            _process = process;
        }
    }

    private async Task ReadLoop(Process process)
    {
        try
        {
            string? line;
            while ((line = await process.StandardOutput.ReadLineAsync().ConfigureAwait(false)) is not null)
            {
                JsonObject? obj;
                try { obj = JsonNode.Parse(line) as JsonObject; }
                catch (JsonException) { continue; }
                if (obj?["id"] is not JsonValue idValue || !idValue.TryGetValue<long>(out var id)) continue;
                TaskCompletionSource<string>? waiting;
                lock (_gate) { _pending.Remove(id, out waiting); }
                waiting?.TrySetResult(line);
            }
        }
        catch (IOException) { }
        finally { FailPending(); }
    }

    private void FailPending()
    {
        TaskCompletionSource<string>[] waiting;
        lock (_gate)
        {
            waiting = _pending.Values.ToArray();
            _pending.Clear();
        }
        foreach (var source in waiting) source.TrySetException(MCPException.NotConnected());
    }

    public async Task<string?> SendAsync(string request, bool expectsResponse, CancellationToken ct)
    {
        StartIfNeeded();
        var process = _process!;
        TaskCompletionSource<string>? response = null;
        if (expectsResponse)
        {
            var id = (JsonNode.Parse(request) as JsonObject)?["id"]?.GetValue<long>()
                ?? throw MCPException.Decode("request without id");
            response = new TaskCompletionSource<string>(TaskCreationOptions.RunContinuationsAsynchronously);
            lock (_gate) _pending[id] = response;
        }
        try
        {
            await process.StandardInput.WriteLineAsync(request.AsMemory(), ct).ConfigureAwait(false);
            await process.StandardInput.FlushAsync(ct).ConfigureAwait(false);
        }
        catch (IOException) { throw MCPException.NotConnected(); }
        if (response is null) return null;
        return await response.Task.WaitAsync(RequestTimeout, ct).ConfigureAwait(false);
    }

    public void Dispose()
    {
        Process? process;
        lock (_gate)
        {
            process = _process;
            _process = null;
        }
        try { if (process is { HasExited: false }) process.Kill(entireProcessTree: true); }
        catch (Exception e) when (e is InvalidOperationException or System.ComponentModel.Win32Exception) { }
        process?.Dispose();
        FailPending();
    }
}

public abstract record MCPServerState
{
    public sealed record Idle : MCPServerState;
    public sealed record Connecting : MCPServerState;
    public sealed record Connected(int ToolCount) : MCPServerState;
    public sealed record Failed(string Message) : MCPServerState;
}

/// <summary>
/// Tracks configured MCP servers, their connection state and the tools they expose to the agent
/// loop. Non-secret config lives in mcp-servers.json; bearer tokens live in the secret store.
/// </summary>
public sealed class MCPRegistry : ObservableObject
{
    public static string TokenKey(string serverId) => $"mcp.token.{serverId}";

    private sealed record Route(
        string ServerId, string ToolName, MCPTransportKind Transport, bool ReadOnlyHint, bool DestructiveHint,
        bool AutoRunReadOnly, JsonNode Schema, string Description);

    private static readonly JsonSerializerOptions StoreJson = new(JsonSerializerDefaults.Web) { WriteIndented = true };

    private readonly object _gate = new();
    private readonly string _storePath;
    private readonly IProviderSecretStore _secrets;
    private readonly Dictionary<string, MCPClient> _clients = new(StringComparer.Ordinal);
    private readonly Dictionary<string, Route> _routes = new(StringComparer.Ordinal);
    private readonly Dictionary<string, MCPServerState> _states = new(StringComparer.Ordinal);
    private List<MCPServerConfig> _servers = [];
    private string? _sandboxWorkspace;

    /// <summary>Test seam: when set, connect builds clients with this transport.</summary>
    public Func<MCPServerConfig, IMCPTransport>? TransportOverride { get; set; }

    public MCPRegistry(string storePath, IProviderSecretStore secrets)
    {
        _storePath = storePath;
        _secrets = secrets;
        Load();
    }

    public MCPRegistry(SupportPaths paths, IProviderSecretStore secrets)
        : this(Path.Combine(paths.Root, "mcp-servers.json"), secrets) { }

    public IReadOnlyList<MCPServerConfig> Servers { get { lock (_gate) return _servers.Select(s => s.Clone()).ToList(); } }

    public MCPServerState StateOf(string serverId)
    {
        lock (_gate) return _states.GetValueOrDefault(serverId) ?? new MCPServerState.Idle();
    }

    /// <summary>
    /// The sandbox worktree, mirrored here so a stdio server (a local process the agent can drive,
    /// same as run_command) launches inside the same jail. While a sandbox is active, HTTP servers
    /// are hidden and refused: the jail has no network, and an HTTP call is one the app makes itself.
    /// </summary>
    public string? SandboxWorkspace => _sandboxWorkspace;

    private bool NetworkBlocked => _sandboxWorkspace is not null;

    /// <summary>
    /// A jail wraps process launch, so a server already running unsandboxed stays that way until
    /// restarted: every connected stdio server is reconnected so the new policy takes effect.
    /// </summary>
    public async Task SetSandboxWorkspaceAsync(string? workspace)
    {
        List<string> stdio;
        lock (_gate)
        {
            if (string.Equals(_sandboxWorkspace, workspace, StringComparison.Ordinal)) return;
            _sandboxWorkspace = workspace;
            stdio = _servers.Where(s => s.Transport == MCPTransportKind.Stdio && _clients.ContainsKey(s.Id)).Select(s => s.Id).ToList();
        }
        OnPropertyChanged(nameof(SandboxWorkspace));
        foreach (var id in stdio)
        {
            DisconnectClient(id);
            await ConnectAsync(id).ConfigureAwait(false);
        }
    }

    // MARK: Config

    public void Upsert(MCPServerConfig config, string? token = null)
    {
        lock (_gate)
        {
            var copy = config.Clone();
            var index = _servers.FindIndex(s => s.Id == copy.Id);
            if (index >= 0) _servers[index] = copy; else _servers.Add(copy);
            if (token is not null)
            {
                if (token.Length == 0) _secrets.Delete(TokenKey(copy.Id)); else _secrets.Write(TokenKey(copy.Id), token);
            }
            Persist();
        }
        OnPropertyChanged(nameof(Servers));
    }

    public void Remove(string serverId)
    {
        lock (_gate)
        {
            _servers.RemoveAll(s => s.Id == serverId);
            _states.Remove(serverId);
            _secrets.Delete(TokenKey(serverId));
            Persist();
        }
        DisconnectClient(serverId);
        OnPropertyChanged(nameof(Servers));
    }

    public string? Token(string serverId) => _secrets.Read(TokenKey(serverId));

    // MARK: Connection

    /// <summary>Connects every enabled server. Failures are recorded per server and never throw.</summary>
    public async Task ConnectAllAsync()
    {
        List<string> ids;
        lock (_gate) ids = _servers.Where(s => s.Enabled).Select(s => s.Id).ToList();
        await Task.WhenAll(ids.Select(id => ConnectAsync(id))).ConfigureAwait(false);
    }

    public async Task ConnectAsync(string serverId)
    {
        MCPServerConfig? config;
        string? sandbox;
        lock (_gate)
        {
            config = _servers.FirstOrDefault(s => s.Id == serverId)?.Clone();
            sandbox = _sandboxWorkspace;
        }
        if (config is null) return;
        SetState(serverId, new MCPServerState.Connecting());
        var client = new MCPClient(config, TransportOverride, _secrets, sandbox);
        try
        {
            await client.ConnectAsync().ConfigureAwait(false);
            lock (_gate)
            {
                if (_clients.Remove(serverId, out var old)) old.Dispose();
                _clients[serverId] = client;
                RegisterRoutes(config, client.Tools);
            }
            SetState(serverId, new MCPServerState.Connected(client.Tools.Count));
        }
        catch (Exception e) when (e is MCPException or HttpRequestException or TimeoutException or OperationCanceledException or IOException)
        {
            client.Dispose();
            lock (_gate) DropRoutes(serverId);
            SetState(serverId, new MCPServerState.Failed(e.Message));
        }
        RaiseToolsChanged();
    }

    public Task DisconnectAllAsync()
    {
        lock (_gate)
        {
            foreach (var client in _clients.Values) client.Dispose();
            _clients.Clear();
            _routes.Clear();
            foreach (var id in _states.Keys.ToList()) _states[id] = new MCPServerState.Idle();
        }
        RaiseToolsChanged();
        return Task.CompletedTask;
    }

    /// <summary>Connect once, report the tool count or the failure reason, then drop it.</summary>
    public async Task<(int? ToolCount, string? Error)> TestAsync(MCPServerConfig config)
    {
        using var client = new MCPClient(config, TransportOverride, _secrets, _sandboxWorkspace);
        try
        {
            await client.ConnectAsync().ConfigureAwait(false);
            return (client.Tools.Count, null);
        }
        catch (Exception e) when (e is MCPException or HttpRequestException or TimeoutException or OperationCanceledException or IOException)
        {
            return (null, e.Message);
        }
    }

    private void DisconnectClient(string serverId)
    {
        lock (_gate)
        {
            if (_clients.Remove(serverId, out var client)) client.Dispose();
            DropRoutes(serverId);
        }
        RaiseToolsChanged();
    }

    private void DropRoutes(string serverId)
    {
        foreach (var name in _routes.Where(r => r.Value.ServerId == serverId).Select(r => r.Key).ToList()) _routes.Remove(name);
    }

    private void SetState(string serverId, MCPServerState state)
    {
        lock (_gate) _states[serverId] = state;
        OnPropertyChanged(nameof(Servers));
    }

    /// <summary>Raised whenever the exposed tool set may have changed.</summary>
    public event EventHandler? ToolsChanged;

    private void RaiseToolsChanged() => ToolsChanged?.Invoke(this, EventArgs.Empty);

    private void RegisterRoutes(MCPServerConfig config, IReadOnlyList<MCPToolInfo> tools)
    {
        DropRoutes(config.Id);
        var slug = SanitizeToolName(config.Name.Length == 0 ? config.Id : config.Name);
        foreach (var tool in tools)
        {
            _routes[$"mcp__{slug}__{SanitizeToolName(tool.Name)}"] = new Route(
                config.Id, tool.Name, config.Transport, tool.ReadOnlyHint, tool.DestructiveHint,
                config.AutoRunReadOnly, tool.InputSchema, tool.Description);
        }
    }

    public static string SanitizeToolName(string name) =>
        new(name.Select(c => char.IsLetterOrDigit(c) || c is '_' or '-' ? c : '_').ToArray());

    // MARK: Agent integration

    public IReadOnlyList<NativeToolDefinition> ToolDefinitions()
    {
        lock (_gate)
        {
            return _routes
                .Where(r => !(NetworkBlocked && r.Value.Transport == MCPTransportKind.Http))
                .Select(r => new NativeToolDefinition(r.Key, r.Value.Description, r.Value.Schema.DeepClone()))
                .OrderBy(t => t.Name, StringComparer.Ordinal)
                .ToList();
        }
    }

    public bool IsMcpTool(string name)
    {
        lock (_gate) return _routes.ContainsKey(name);
    }

    /// <summary>
    /// A tool may skip the approval prompt only when its server opted in AND advertised the tool
    /// as read-only AND did not flag it destructive.
    /// </summary>
    public bool ShouldAutoRun(string name)
    {
        lock (_gate)
            return _routes.TryGetValue(name, out var route) && route.AutoRunReadOnly && route.ReadOnlyHint && !route.DestructiveHint;
    }

    public async Task<string> CallAsync(string name, JsonNode? arguments, CancellationToken ct = default)
    {
        MCPClient client;
        Route route;
        lock (_gate)
        {
            route = _routes.GetValueOrDefault(name) ?? throw MCPException.NotConnected();
            // Same rule as ToolDefinitions, enforced again: the model may still hold a tool list
            // from before the sandbox changed.
            if (NetworkBlocked && route.Transport == MCPTransportKind.Http)
                throw MCPException.Transport("Sandbox network access is off; HTTP MCP tools are unavailable.");
            client = _clients.GetValueOrDefault(route.ServerId) ?? throw MCPException.NotConnected();
        }
        return await client.CallToolAsync(route.ToolName, arguments, ct).ConfigureAwait(false);
    }

    // MARK: Persistence

    private void Load()
    {
        try
        {
            var decoded = JsonSerializer.Deserialize<List<MCPServerConfig>>(File.ReadAllText(_storePath), StoreJson);
            if (decoded is not null) _servers = decoded;
        }
        catch (Exception e) when (e is IOException or JsonException or UnauthorizedAccessException) { }
    }

    private void Persist()
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(_storePath)!);
            var temporary = _storePath + ".tmp";
            File.WriteAllText(temporary, JsonSerializer.Serialize(_servers, StoreJson));
            File.Move(temporary, _storePath, overwrite: true);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
    }
}

/// <summary>
/// Editable form state for one MCP server, shared by the Avalonia and WPF settings tabs so
/// validation and parsing behave identically. Arguments are one per line; environment entries
/// are <c>KEY=VALUE</c> lines.
/// </summary>
public sealed class MCPServerDraft
{
    public string Id { get; set; } = Guid.NewGuid().ToString();
    public string Name { get; set; } = "";
    public MCPTransportKind Transport { get; set; } = MCPTransportKind.Http;
    public string Url { get; set; } = "";
    public string Command { get; set; } = "";
    public string ArgumentsText { get; set; } = "";
    public string EnvironmentText { get; set; } = "";
    /// <summary>Null keeps the stored token; an empty string clears it.</summary>
    public string? Token { get; set; }
    public bool Enabled { get; set; } = true;
    public bool AutoRunReadOnly { get; set; }

    public static MCPServerDraft From(MCPServerConfig config) => new()
    {
        Id = config.Id,
        Name = config.Name,
        Transport = config.Transport,
        Url = config.Url,
        Command = config.Command,
        ArgumentsText = string.Join("\n", config.Arguments),
        EnvironmentText = string.Join("\n", config.Environment.Select(pair => $"{pair.Key}={pair.Value}")),
        Enabled = config.Enabled,
        AutoRunReadOnly = config.AutoRunReadOnly,
    };

    /// <summary>The first problem with the form, or null when it can be saved.</summary>
    public string? Validate()
    {
        if (string.IsNullOrWhiteSpace(Name)) return "Give the server a name.";
        if (Transport == MCPTransportKind.Http)
        {
            return Uri.TryCreate(Url.Trim(), UriKind.Absolute, out var uri) && uri.Scheme is "http" or "https"
                ? null
                : "Enter the server's http:// or https:// address.";
        }
        if (string.IsNullOrWhiteSpace(Command)) return "Enter the command that starts the server.";
        foreach (var line in EnvironmentText.Split('\n').Select(l => l.Trim()).Where(l => l.Length > 0))
        {
            var separator = line.IndexOf('=');
            if (separator <= 0) return $"Environment entry \"{line}\" must look like KEY=VALUE.";
        }
        return null;
    }

    public MCPServerConfig ToConfig() => new()
    {
        Id = Id,
        Name = Name.Trim(),
        Transport = Transport,
        Url = Url.Trim(),
        Command = Command.Trim(),
        Arguments = ArgumentsText.Split('\n').Select(a => a.TrimEnd('\r')).Where(a => a.Length > 0).ToList(),
        Environment = EnvironmentText.Split('\n')
            .Select(l => l.Trim())
            .Where(l => l.Length > 0 && l.IndexOf('=') > 0)
            .Select(l => (Key: l[..l.IndexOf('=')].Trim(), Value: l[(l.IndexOf('=') + 1)..]))
            .GroupBy(pair => pair.Key, StringComparer.Ordinal)
            .ToDictionary(group => group.Key, group => group.Last().Value, StringComparer.Ordinal),
        Enabled = Enabled,
        AutoRunReadOnly = AutoRunReadOnly,
    };
}

// Copyright (c) 2026 DOTS
// Managed Chrome supervisor and CDP target ownership for Windows/Linux.

using System.Collections.Concurrent;
using System.Diagnostics;
using System.Net;
using System.Net.Http.Json;
using System.Net.Sockets;
using System.Net.WebSockets;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace DotsHarnessCore;

public sealed class BrowserSessionManager
{
    private sealed class PipeConnection : IDisposable
    {
        private readonly Stream _input;
        private readonly Stream _output;
        private readonly SemaphoreSlim _gate = new(1, 1);
        private int _nextId;

        public PipeConnection(Stream input, Stream output)
        {
            _input = input;
            _output = output;
        }

        public async Task<JsonObject?> SendAsync(
            string method,
            object parameters,
            string? sessionId,
            CancellationToken ct)
        {
            await _gate.WaitAsync(ct).ConfigureAwait(false);
            try
            {
                var id = Interlocked.Increment(ref _nextId);
                var payload = new JsonObject
                {
                    ["id"] = id,
                    ["method"] = method,
                    ["params"] = JsonSerializer.SerializeToNode(parameters),
                };
                if (sessionId is not null) payload["sessionId"] = sessionId;
                var bytes = Encoding.UTF8.GetBytes(payload.ToJsonString());
                await _output.WriteAsync(bytes, ct).ConfigureAwait(false);
                await _output.WriteAsync(new byte[] { 0 }, ct).ConfigureAwait(false);
                await _output.FlushAsync(ct).ConfigureAwait(false);

                while (true)
                {
                    var frame = await ReadFrameAsync(ct).ConfigureAwait(false)
                        ?? throw new InvalidOperationException($"CDP pipe closed while running {method}.");
                    var response = JsonNode.Parse(frame)?.AsObject();
                    if (response?["id"]?.GetValue<int>() != id) continue;
                    if (response["error"] is { } error)
                        throw new InvalidOperationException(error.ToJsonString());
                    return response["result"] as JsonObject;
                }
            }
            finally
            {
                _gate.Release();
            }
        }

        private async Task<byte[]?> ReadFrameAsync(CancellationToken ct)
        {
            using var buffer = new MemoryStream();
            var one = new byte[1];
            while (true)
            {
                var count = await _input.ReadAsync(one.AsMemory(0, 1), ct).ConfigureAwait(false);
                if (count == 0) return null;
                if (one[0] == 0) return buffer.ToArray();
                buffer.WriteByte(one[0]);
            }
        }

        public void Dispose()
        {
            try { _input.Dispose(); } catch { }
            try { _output.Dispose(); } catch { }
            _gate.Dispose();
        }
    }

    private sealed class Session
    {
        public required BrowserScope Scope { get; init; }
        public required string ProfilePath { get; init; }
        public required string LeasePath { get; init; }
        public required Process Process { get; init; }
        public int? Port { get; init; }
        public PipeConnection? Pipe { get; init; }
        public HashSet<string> PageIds { get; } = new(StringComparer.Ordinal);
        public Dictionary<string, string> TargetSessions { get; } = new(StringComparer.Ordinal);
        public List<string> OpenedPageIds { get; } = [];
        public List<string> ClosedPageIds { get; } = [];
    }

    private readonly ConcurrentDictionary<string, Session> _sessions = new(StringComparer.Ordinal);
    private readonly ConcurrentDictionary<string, string> _diagnostics = new(StringComparer.Ordinal);
    private readonly object _sessionGate = new();
    private readonly string _root;
    private readonly HttpClient _http = new() { Timeout = TimeSpan.FromSeconds(5) };

    public BrowserSessionManager(string? root = null)
    {
        _root = root ?? Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "DotsHarness",
            "browser-runs");
        Directory.CreateDirectory(_root);
        RecoverStaleLeases();
    }

    public async Task<BrowserPage> OpenAsync(
        BrowserScope scope,
        BrowserBackend backend,
        string url,
        CancellationToken ct = default)
    {
        if (backend != BrowserBackend.Managed)
            throw new InvalidOperationException("Extension backend is unavailable: Native Messaging host or extension is not connected.");
        ValidateUrl(url);

        var session = GetOrStartSession(scope, ct);
        try
        {
            var target = await SendAsync(session, "Target.createTarget", new { url }, ct).ConfigureAwait(false);
            var pageId = target?["targetId"]?.GetValue<string>();
            if (string.IsNullOrWhiteSpace(pageId))
                throw new InvalidOperationException("Chrome did not return a target ID.");
            lock (session)
            {
                session.PageIds.Add(pageId);
                session.OpenedPageIds.Add(pageId);
            }
            _diagnostics.TryRemove(scope.Key, out _);
            return new BrowserPage(pageId, backend, url, scope);
        }
        catch
        {
            var shouldClose = false;
            lock (session)
            {
                shouldClose = session.PageIds.Count == 0;
            }
            if (shouldClose)
                _ = await CloseRunAsync(scope, CancellationToken.None, backend).ConfigureAwait(false);
            throw;
        }
    }

    public async Task<string> ExecuteAsync(
        NativeToolCall call,
        BrowserScope scope,
        BrowserBackend backend,
        CancellationToken ct = default)
    {
        try
        {
            var input = JsonNode.Parse(call.Arguments)?.AsObject() ?? new JsonObject();
            if (input.ContainsKey("backend"))
                return "Tool error: backend is selected by the host and cannot be supplied by the model.";
            return call.Name switch
            {
                BrowserTools.OpenName => FormatPage(await OpenAsync(
                    scope,
                    backend,
                    input["url"]?.GetValue<string>() ?? "",
                    ct).ConfigureAwait(false)),
                BrowserTools.NavigateName => await NavigateAndFormatAsync(
                    scope,
                    input["pageID"]?.GetValue<string>() ?? "",
                    input["url"]?.GetValue<string>() ?? "",
                    ct).ConfigureAwait(false),
                BrowserTools.CloseName => await CloseAndFormatAsync(
                    scope,
                    input["pageID"]?.GetValue<string>() ?? "",
                    ct).ConfigureAwait(false),
                _ => $"Tool error: unknown browser tool {call.Name}.",
            };
        }
        catch (Exception ex)
        {
            if (backend == BrowserBackend.Extension)
                _diagnostics[scope.Key] = "extension_backend_unavailable";
            return $"Tool error: {ex.Message}";
        }
    }

    private async Task<string> NavigateAndFormatAsync(
        BrowserScope scope,
        string pageId,
        string url,
        CancellationToken ct)
    {
        if (string.IsNullOrWhiteSpace(pageId)) return "Tool error: pageID is required.";
        await NavigateAsync(scope, pageId, url, ct).ConfigureAwait(false);
        return $"Navigated page {pageId} to {url}.";
    }

    private async Task<string> CloseAndFormatAsync(
        BrowserScope scope,
        string pageId,
        CancellationToken ct)
    {
        if (string.IsNullOrWhiteSpace(pageId)) return "Tool error: pageID is required.";
        await ClosePageAsync(scope, pageId, ct).ConfigureAwait(false);
        return $"Closed page {pageId}.";
    }

    private static string FormatPage(BrowserPage page) =>
        $"Opened {page.Url}\npageID: {page.PageId}\nbackend: {page.Backend}";

    public async Task NavigateAsync(
        BrowserScope scope,
        string pageId,
        string url,
        CancellationToken ct = default)
    {
        ValidateUrl(url);
        var session = FindSession(scope, pageId);
        if (session.Pipe is { } pipe)
        {
            var attached = await pipe.SendAsync(
                "Target.attachToTarget",
                new { targetId = pageId, flatten = true },
                sessionId: null,
                ct).ConfigureAwait(false);
            var sessionId = attached?["sessionId"]?.GetValue<string>()
                ?? throw new InvalidOperationException("Chrome did not return a CDP target session.");
            await pipe.SendAsync("Page.navigate", new { url }, sessionId, ct).ConfigureAwait(false);
            lock (session) session.TargetSessions[pageId] = sessionId;
            return;
        }
        var target = await GetTargetAsync(session, pageId, ct).ConfigureAwait(false)
            ?? throw new InvalidOperationException("The owned browser page no longer exists.");
        var webSocketUrl = target["webSocketDebuggerUrl"]?.GetValue<string>()
            ?? throw new InvalidOperationException("The owned browser page has no CDP websocket.");
        await SendPageCommandAsync(webSocketUrl, "Page.navigate", new { url }, ct).ConfigureAwait(false);
    }

    public async Task ClosePageAsync(BrowserScope scope, string pageId, CancellationToken ct = default)
    {
        if (!_sessions.TryGetValue(scope.Key, out var session))
            throw new InvalidOperationException("Browser session is no longer active.");
        lock (session)
        {
            if (!session.PageIds.Contains(pageId))
                throw new InvalidOperationException("The page is not owned by this run.");
        }
        await SendAsync(session, "Target.closeTarget", new { targetId = pageId }, ct).ConfigureAwait(false);
        lock (session)
        {
            session.PageIds.Remove(pageId);
            session.TargetSessions.Remove(pageId);
            session.ClosedPageIds.Add(pageId);
        }
    }

    public async Task<BrowserRunSummary> CloseRunAsync(
        BrowserScope scope,
        CancellationToken ct = default,
        BrowserBackend backend = BrowserBackend.Unknown)
    {
        Session? session;
        lock (_sessionGate)
        {
            _sessions.TryRemove(scope.Key, out session);
        }
        if (session is null)
        {
            if (_diagnostics.TryRemove(scope.Key, out var pendingDiagnostic))
                return new BrowserRunSummary(backend, Array.Empty<string>(), Array.Empty<string>(), BrowserCleanupStatus.Failed, pendingDiagnostic);
            return BrowserRunSummary.NotUsed(backend);
        }

        var status = BrowserCleanupStatus.Closed;
        var diagnostic = "closed";
        try
        {
            string[] pages;
            lock (session) pages = session.PageIds.ToArray();
            foreach (var page in pages)
            {
                try
                {
                    await SendAsync(session, "Target.closeTarget", new { targetId = page }, ct).ConfigureAwait(false);
                    lock (session) session.ClosedPageIds.Add(page);
                }
                catch
                {
                    status = BrowserCleanupStatus.PendingRecovery;
                    diagnostic = "target_close_failed";
                }
            }

            try { await SendAsync(session, "Browser.close", new { }, CancellationToken.None).ConfigureAwait(false); }
            catch { }

            await WaitForExitAsync(session.Process, TimeSpan.FromSeconds(2)).ConfigureAwait(false);
            if (!session.Process.HasExited)
            {
                try { session.Process.Kill(entireProcessTree: true); }
                catch
                {
                    status = BrowserCleanupStatus.PendingRecovery;
                    diagnostic = "process_kill_failed";
                }
                await WaitForExitAsync(session.Process, TimeSpan.FromSeconds(2)).ConfigureAwait(false);
            }

            if (session.Process.HasExited)
            {
                session.Pipe?.Dispose();
                TryDelete(session.LeasePath);
                TryDeleteDirectory(session.ProfilePath);
                if (Path.GetDirectoryName(session.ProfilePath) is { } runRoot)
                    TryDeleteDirectory(runRoot);
            }
            else
            {
                status = BrowserCleanupStatus.PendingRecovery;
                diagnostic = "process_still_running";
            }
        }
        catch
        {
            status = BrowserCleanupStatus.Failed;
            diagnostic = "cleanup_failed";
        }

        lock (session)
        {
            return new BrowserRunSummary(
                BrowserBackend.Managed,
                session.OpenedPageIds.ToArray(),
                session.ClosedPageIds.ToArray(),
                status,
                diagnostic);
        }
    }

    public async Task CloseAllAsync(CancellationToken ct = default)
    {
        string[] scopes;
        lock (_sessionGate)
            scopes = _sessions.Values.Select(session => session.Scope.Key).ToArray();
        foreach (var key in scopes)
        {
            if (!_sessions.TryGetValue(key, out var session)) continue;
            _ = await CloseRunAsync(session.Scope, ct, BrowserBackend.Managed).ConfigureAwait(false);
        }
    }

    private Session GetOrStartSession(BrowserScope scope, CancellationToken ct)
    {
        lock (_sessionGate)
        {
            if (_sessions.TryGetValue(scope.Key, out var existing)) return existing;
            var started = StartSession(scope, ct);
            _sessions[scope.Key] = started;
            return started;
        }
    }

    private Session FindSession(BrowserScope scope, string pageId)
    {
        if (!_sessions.TryGetValue(scope.Key, out var session))
            throw new InvalidOperationException("Browser session is no longer active.");
        lock (session)
        {
            if (!session.PageIds.Contains(pageId))
                throw new InvalidOperationException("The page is not owned by this run.");
        }
        return session;
    }

    private Session StartSession(BrowserScope scope, CancellationToken ct)
    {
        if (string.IsNullOrWhiteSpace(scope.RunId)
            || scope.RunId is "." or ".."
            || scope.RunId.IndexOfAny(['/', '\\']) >= 0)
            throw new InvalidOperationException("Browser runID is not a safe profile identifier.");
        var executable = FindChromeExecutable()
            ?? throw new InvalidOperationException("Chrome for managed browser was not found.");
        var runRoot = Path.Combine(_root, scope.RunId);
        Directory.CreateDirectory(runRoot);
        var profile = Path.Combine(runRoot, "profile");
        Directory.CreateDirectory(profile);

        Exception? last = null;
        for (var attempt = 0; attempt < 3; attempt++)
        {
            try
            {
                return StartPipeSession(scope, executable, runRoot, profile, ct);
            }
            catch (Exception ex)
            {
                last = ex;
            }
        }

        if (!CanUsePortFallback)
            throw new InvalidOperationException("Managed Chrome CDP pipe is unavailable and an isolated port fallback is not available.", last);

        for (var attempt = 0; attempt < 3; attempt++)
        {
            var port = ReservePort();
            var process = CreateProcess(
                executable,
                runRoot,
                [
                    $"--user-data-dir={profile}",
                    $"--remote-debugging-port={port}",
                    $"--remote-allow-origins=http://127.0.0.1:{port}",
                    "--no-first-run",
                    "--no-default-browser-check",
                    "--disable-sync",
                    "--new-window",
                    "about:blank",
                ],
                pipe: false);

            try
            {
                if (!process.Start()) throw new InvalidOperationException("Chrome process did not start.");
                var leasePath = Path.Combine(runRoot, "lease.json");
                WriteLease(leasePath, scope, process, executable, profile, port, "port", "starting");
                WaitForCdpAsync(port, process, ct).GetAwaiter().GetResult();
                WriteLease(leasePath, scope, process, executable, profile, port, "port", "ready");
                return new Session
                {
                    Scope = scope,
                    ProfilePath = profile,
                    LeasePath = leasePath,
                    Process = process,
                    Port = port,
                };
            }
            catch (Exception ex)
            {
                last = ex;
                try { if (!process.HasExited) process.Kill(entireProcessTree: true); } catch { }
                try { process.WaitForExit(1_000); } catch { }
                TryDelete(Path.Combine(runRoot, "lease.json"));
            }
        }
        throw new InvalidOperationException("Managed Chrome could not be started after three attempts.", last);
    }

    private Session StartPipeSession(
        BrowserScope scope,
        string executable,
        string runRoot,
        string profile,
        CancellationToken ct)
    {
        var process = CreateProcess(
            executable,
            runRoot,
            [
                $"--user-data-dir={profile}",
                "--remote-debugging-pipe",
                "--no-first-run",
                "--no-default-browser-check",
                "--disable-sync",
                "--new-window",
                "about:blank",
            ],
            pipe: true);
        PipeConnection? pipe = null;
        var leasePath = Path.Combine(runRoot, "lease.json");
        try
        {
            if (!process.Start()) throw new InvalidOperationException("Chrome process did not start.");
            pipe = new PipeConnection(process.StandardOutput.BaseStream, process.StandardInput.BaseStream);
            WriteLease(leasePath, scope, process, executable, profile, null, "pipe", "starting");
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct);
            timeout.CancelAfter(TimeSpan.FromSeconds(10));
            _ = pipe.SendAsync("Browser.getVersion", new { }, null, timeout.Token).GetAwaiter().GetResult();
            WriteLease(leasePath, scope, process, executable, profile, null, "pipe", "ready");
            return new Session
            {
                Scope = scope,
                ProfilePath = profile,
                LeasePath = leasePath,
                Process = process,
                Pipe = pipe,
                Port = null,
            };
        }
        catch
        {
            pipe?.Dispose();
            try { if (!process.HasExited) process.Kill(entireProcessTree: true); } catch { }
            try { process.WaitForExit(1_000); } catch { }
            TryDelete(leasePath);
            throw;
        }
    }

    private static Process CreateProcess(
        string executable,
        string runRoot,
        IReadOnlyList<string> arguments,
        bool pipe)
    {
        var info = new ProcessStartInfo
        {
            FileName = executable,
            UseShellExecute = false,
            CreateNoWindow = true,
            WorkingDirectory = runRoot,
            RedirectStandardInput = pipe,
            RedirectStandardOutput = pipe,
            RedirectStandardError = pipe,
        };
        foreach (var argument in arguments) info.ArgumentList.Add(argument);
        return new Process { StartInfo = info };
    }

    private static bool CanUsePortFallback => OperatingSystem.IsLinux() && AgentCommandSandbox.IsAvailable;

    private async Task<JsonObject?> SendAsync(Session session, string method, object parameters, CancellationToken ct)
    {
        if (session.Pipe is { } pipe)
            return await pipe.SendAsync(method, parameters, null, ct).ConfigureAwait(false);
        if (session.Port is not { } port)
            throw new InvalidOperationException("Managed Chrome has no CDP transport.");
        var version = await _http.GetFromJsonAsync<JsonObject>(
                $"http://127.0.0.1:{port}/json/version",
                ct)
            .ConfigureAwait(false)
            ?? throw new InvalidOperationException("Chrome CDP version response was empty.");
        var webSocketUrl = version["webSocketDebuggerUrl"]?.GetValue<string>()
            ?? throw new InvalidOperationException("Chrome did not expose a CDP websocket.");
        return await SendWebSocketCommandAsync(webSocketUrl, method, parameters, ct).ConfigureAwait(false);
    }

    private async Task<JsonObject?> GetTargetAsync(Session session, string pageId, CancellationToken ct)
    {
        if (session.Port is not { } port)
            throw new InvalidOperationException("Target listing is unavailable on the CDP pipe transport.");
        var targets = await _http.GetFromJsonAsync<JsonArray>(
                $"http://127.0.0.1:{port}/json/list",
                ct)
            .ConfigureAwait(false);
        return targets?
            .OfType<JsonObject>()
            .FirstOrDefault(target => string.Equals(target["id"]?.GetValue<string>(), pageId, StringComparison.Ordinal));
    }

    private static async Task SendPageCommandAsync(string webSocketUrl, string method, object parameters, CancellationToken ct)
    {
        _ = await SendWebSocketCommandAsync(webSocketUrl, method, parameters, ct).ConfigureAwait(false);
    }

    private static async Task<JsonObject?> SendWebSocketCommandAsync(
        string webSocketUrl,
        string method,
        object parameters,
        CancellationToken ct)
    {
        using var socket = new ClientWebSocket();
        await socket.ConnectAsync(new Uri(webSocketUrl), ct).ConfigureAwait(false);
        var id = Random.Shared.Next(1, int.MaxValue);
        var payload = JsonSerializer.Serialize(new { id, method, @params = parameters });
        await socket.SendAsync(
                new ArraySegment<byte>(Encoding.UTF8.GetBytes(payload)),
                WebSocketMessageType.Text,
                true,
                ct)
            .ConfigureAwait(false);

        while (socket.State == WebSocketState.Open)
        {
            var response = await ReceiveTextAsync(socket, ct).ConfigureAwait(false);
            if (response is null) break;
            var node = JsonNode.Parse(response)?.AsObject();
            if (node?["id"]?.GetValue<int>() != id) continue;
            if (node["error"] is { } error) throw new InvalidOperationException(error.ToJsonString());
            return node["result"] as JsonObject;
        }
        throw new InvalidOperationException($"CDP command failed: {method}.");
    }

    private static async Task<string?> ReceiveTextAsync(ClientWebSocket socket, CancellationToken ct)
    {
        using var buffer = new MemoryStream();
        var chunk = new byte[16 * 1024];
        while (true)
        {
            var result = await socket.ReceiveAsync(new ArraySegment<byte>(chunk), ct).ConfigureAwait(false);
            if (result.MessageType == WebSocketMessageType.Close) return null;
            buffer.Write(chunk, 0, result.Count);
            if (result.EndOfMessage) return Encoding.UTF8.GetString(buffer.ToArray());
        }
    }

    private static async Task WaitForCdpAsync(int port, Process process, CancellationToken ct)
    {
        using var client = new HttpClient { Timeout = TimeSpan.FromMilliseconds(500) };
        var deadline = DateTimeOffset.UtcNow.AddSeconds(10);
        while (DateTimeOffset.UtcNow < deadline)
        {
            ct.ThrowIfCancellationRequested();
            if (process.HasExited) throw new InvalidOperationException($"Chrome exited with status {process.ExitCode}.");
            try
            {
                using var response = await client.GetAsync($"http://127.0.0.1:{port}/json/version", ct).ConfigureAwait(false);
                if (response.IsSuccessStatusCode) return;
            }
            catch { }
            await Task.Delay(100, ct).ConfigureAwait(false);
        }
        throw new TimeoutException("Chrome CDP did not become ready.");
    }

    private static void WriteLease(
        string path,
        BrowserScope scope,
        Process process,
        string executable,
        string profile,
        int? port,
        string transport,
        string state)
    {
        var temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        var payload = new
        {
            scope,
            runID = scope.RunId,
            processId = process.Id,
            processStartTimeUtc = SafeStartTime(process),
            executable,
            profile,
            port,
            transport,
            state,
        };
        File.WriteAllText(temporary, JsonSerializer.Serialize(payload, new JsonSerializerOptions { WriteIndented = true }));
        File.Move(temporary, path, overwrite: true);
    }

    private void RecoverStaleLeases()
    {
        if (!Directory.Exists(_root)) return;
        foreach (var lease in Directory.EnumerateFiles(_root, "lease.json", SearchOption.AllDirectories))
        {
            try
            {
                var node = JsonNode.Parse(File.ReadAllText(lease))?.AsObject();
                var profile = node?["profile"]?.GetValue<string>();
                var pid = node?["processId"]?.GetValue<int>() ?? 0;
                var executable = node?["executable"]?.GetValue<string>();
                var startTime = node?["processStartTimeUtc"]?.GetValue<string>();
                if (profile is null || !IsOwnedRunPath(profile)) continue;
                if (pid > 0)
                {
                    if (IsProcessForProfileAlive(pid, profile, executable, startTime)) continue;
                    // A live but mismatched PID may be a PID-reuse case, or an
                    // identity check that the current user cannot inspect. Do
                    // not delete a profile while any process is still alive.
                    if (IsProcessAlive(pid)) continue;
                }
                TryDelete(lease);
                TryDeleteDirectory(profile);
            }
            catch
            {
                // A malformed lease is left in place. A new run uses a fresh
                // UUID and never reuses this profile.
            }
        }
    }

    private bool IsOwnedRunPath(string path)
    {
        try
        {
            var root = Path.GetFullPath(_root).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar)
                + Path.DirectorySeparatorChar;
            var candidate = Path.GetFullPath(path);
            return candidate.StartsWith(root, OperatingSystem.IsWindows()
                ? StringComparison.OrdinalIgnoreCase
                : StringComparison.Ordinal);
        }
        catch { return false; }
    }

    private static bool IsProcessAlive(int pid)
    {
        try
        {
            using var process = Process.GetProcessById(pid);
            return !process.HasExited;
        }
        catch { return false; }
    }

    private static bool IsProcessForProfileAlive(
        int pid,
        string? profile,
        string? expectedExecutable,
        string? expectedStartTime)
    {
        if (string.IsNullOrWhiteSpace(profile)) return false;
        try
        {
            using var process = Process.GetProcessById(pid);
            if (process.HasExited) return false;
            var executable = process.MainModule?.FileName ?? "";
            if (!executable.Contains("chrome", StringComparison.OrdinalIgnoreCase)
                || !Directory.Exists(profile)) return false;
            if (!string.IsNullOrWhiteSpace(expectedExecutable)
                && !string.Equals(
                    Path.GetFullPath(executable),
                    Path.GetFullPath(expectedExecutable),
                    OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal))
                return false;
            if (DateTimeOffset.TryParse(expectedStartTime, out var expectedStart)
                && Math.Abs((process.StartTime.ToUniversalTime() - expectedStart.UtcDateTime).TotalSeconds) > 2)
                return false;
            if (OperatingSystem.IsLinux())
            {
                var commandLinePath = $"/proc/{pid}/cmdline";
                if (File.Exists(commandLinePath))
                {
                    var commandLine = Encoding.UTF8.GetString(File.ReadAllBytes(commandLinePath));
                    if (!commandLine.Contains(profile, StringComparison.Ordinal)) return false;
                }
            }
            return true;
        }
        catch { return false; }
    }

    private static int ReservePort()
    {
        using var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        return ((IPEndPoint)listener.LocalEndpoint).Port;
    }

    private static string? FindChromeExecutable()
    {
        var candidates = new List<string>();
        var configured = Environment.GetEnvironmentVariable("HERNESS_CHROME_PATH");
        if (!string.IsNullOrWhiteSpace(configured)) candidates.Add(configured);
        if (OperatingSystem.IsWindows())
        {
            candidates.Add(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "Google", "Chrome", "Application", "chrome.exe"));
            candidates.Add(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Google", "Chrome", "Application", "chrome.exe"));
        }
        else
        {
            candidates.AddRange(["/usr/bin/google-chrome", "/usr/bin/google-chrome-stable", "/usr/bin/chromium", "/usr/bin/chromium-browser"]);
        }
        return candidates.FirstOrDefault(File.Exists);
    }

    private static string? SafeStartTime(Process process)
    {
        try { return process.StartTime.ToUniversalTime().ToString("O"); }
        catch { return null; }
    }

    private static async Task WaitForExitAsync(Process process, TimeSpan timeout)
    {
        if (process.HasExited) return;
        try { await process.WaitForExitAsync().WaitAsync(timeout).ConfigureAwait(false); }
        catch (TimeoutException) { }
    }

    private static void ValidateUrl(string url)
    {
        if (!Uri.TryCreate(url, UriKind.Absolute, out var parsed)
            || parsed.Scheme is not ("http" or "https"))
            throw new InvalidOperationException("Only http and https browser URLs are allowed.");
    }

    private static void TryDelete(string path)
    {
        try { if (File.Exists(path)) File.Delete(path); } catch { }
    }

    private static void TryDeleteDirectory(string path)
    {
        try { if (Directory.Exists(path)) Directory.Delete(path, recursive: true); } catch { }
    }
}

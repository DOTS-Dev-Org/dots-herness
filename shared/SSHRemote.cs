// Copyright (c) 2026 DOTS
// Remote work locations for the Windows and Linux shells. Port of the macOS
// SSHHost / SSHConfigStore / SSHRunner / SSHHostStore / SSHEnrollment files:
// hosts come from ~/.ssh/config, every remote command is built from one
// argument vector, and the app never stores or writes an SSH password.

using System.Diagnostics;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using PluginRuntime;

namespace DotsHarnessCore;

/// <summary>One entry of the remote section of the work-location picker.</summary>
public sealed record SSHHost(
    string Alias,
    string HostName,
    string User,
    int Port = 22,
    string? IdentityFile = null,
    bool ManagedByApp = false)
{
    public string DisplayDestination
    {
        get
        {
            var host = string.IsNullOrEmpty(User) ? HostName : $"{User}@{HostName}";
            return Port == 22 ? host : $"{host}:{Port}";
        }
    }
}

/// <summary>A host plus the folder on it that the agent works in.</summary>
public sealed record SSHTarget(string Alias, string RemotePath)
{
    /// <summary>Conversation identity; never collides with a local path.</summary>
    public string Identity => $"ssh://{Alias}{(RemotePath.StartsWith('/') ? "" : "/")}{RemotePath}";
}

public enum SSHErrorKind
{
    SshUnavailable,
    NotReachable,
    HostKeyChanged,
    AuthFailed,
    PasswordAuthDisabled,
    PathMissing,
    ConfigWriteFailed,
}

public sealed class SSHException : Exception
{
    public SSHErrorKind Kind { get; }
    public string Detail { get; }

    public SSHException(SSHErrorKind kind, string detail = "")
        : base(Describe(kind, detail))
    {
        Kind = kind;
        Detail = detail;
    }

    private static string Describe(SSHErrorKind kind, string detail)
    {
        var key = kind switch
        {
            SSHErrorKind.SshUnavailable => "ssh.error.unavailable",
            SSHErrorKind.NotReachable => "ssh.error.notReachable",
            SSHErrorKind.HostKeyChanged => "ssh.error.hostKeyChanged",
            SSHErrorKind.AuthFailed => "ssh.error.authFailed",
            SSHErrorKind.PasswordAuthDisabled => "ssh.error.passwordAuthDisabled",
            SSHErrorKind.PathMissing => "ssh.error.pathMissing",
            SSHErrorKind.ConfigWriteFailed => "ssh.error.configWriteFailed",
            _ => "",
        };
        return key.Length == 0 ? detail : LocalizationService.Current.Get(key, detail);
    }
}

/// <summary>The composer's work-location selection, persisted in app settings.</summary>
public readonly record struct WorkLocationSetting
{
    public enum LocationKind { Local, LocalWorktree, Remote }

    public LocationKind Kind { get; }
    public string? RemoteAlias { get; }

    private WorkLocationSetting(LocationKind kind, string? alias)
    {
        Kind = kind;
        RemoteAlias = alias;
    }

    public static WorkLocationSetting Local => new(LocationKind.Local, null);
    public static WorkLocationSetting LocalWorktree => new(LocationKind.LocalWorktree, null);
    public static WorkLocationSetting Remote(string alias) => new(LocationKind.Remote, alias);

    public bool IsRemote => Kind == LocationKind.Remote;

    /// <summary>Compact form: <c>local</c>, <c>localWorktree</c>, <c>remote:&lt;alias&gt;</c>.</summary>
    public string StorageValue => Kind switch
    {
        LocationKind.LocalWorktree => "localWorktree",
        LocationKind.Remote => $"remote:{RemoteAlias}",
        _ => "local",
    };

    public static WorkLocationSetting Parse(string? value)
    {
        if (value is not null && value.StartsWith("remote:", StringComparison.Ordinal))
        {
            var alias = value["remote:".Length..];
            return alias.Length == 0 ? Local : Remote(alias);
        }
        return value == "localWorktree" ? LocalWorktree : Local;
    }
}

public static class SSHConfigStore
{
    internal const string BeginMarker = "# >>> DotsHarness managed host: ";
    internal const string EndMarker = "# <<< DotsHarness managed host: ";

    private static readonly char[] Blank = { ' ', '\t' };

    /// <summary>
    /// Parses <c>Host</c> stanzas into pickable hosts. Pattern stanzas and
    /// <c>Match</c> blocks are skipped; <c>Include</c> is followed one level
    /// deep for reading only.
    /// </summary>
    public static IReadOnlyList<SSHHost> Parse(
        string text,
        Func<string, string?>? includeLoader = null,
        bool followIncludes = true)
    {
        var hosts = new List<SSHHost>();
        var managedAliases = new HashSet<string>(StringComparer.Ordinal);
        string? currentAlias = null;
        var currentIsPattern = false;
        var currentManaged = false;
        var fields = new Dictionary<string, string>(StringComparer.Ordinal);
        var skippingMatch = false;

        void Flush()
        {
            var alias = currentAlias;
            var isPattern = currentIsPattern;
            var managed = currentManaged;
            var captured = fields;
            currentAlias = null;
            currentIsPattern = false;
            currentManaged = false;
            fields = new Dictionary<string, string>(StringComparer.Ordinal);
            if (alias is null || isPattern) return;
            var port = captured.TryGetValue("port", out var rawPort) && int.TryParse(rawPort, out var parsed)
                ? parsed
                : 22;
            hosts.Add(new SSHHost(
                alias,
                captured.GetValueOrDefault("hostname", alias),
                captured.GetValueOrDefault("user", ""),
                port is >= 1 and <= 65535 ? port : 22,
                captured.GetValueOrDefault("identityfile"),
                managed || managedAliases.Contains(alias)));
        }

        foreach (var rawLine in SplitLines(text))
        {
            var line = rawLine.Trim(Blank);
            if (line.StartsWith(BeginMarker, StringComparison.Ordinal))
            {
                managedAliases.Add(line[BeginMarker.Length..].Trim(Blank));
                continue;
            }
            if (line.Length == 0 || line.StartsWith('#')) continue;
            if (SplitDirective(line) is not { } directive) continue;
            var (keyword, value) = directive;
            switch (keyword)
            {
                case "host":
                    Flush();
                    skippingMatch = false;
                    var aliases = value.Split(Blank, StringSplitOptions.RemoveEmptyEntries);
                    if (aliases.Length == 0) continue;
                    currentAlias = aliases[0];
                    currentIsPattern = aliases.Any(a => a.Contains('*') || a.Contains('?') || a.StartsWith('!'));
                    currentManaged = managedAliases.Contains(aliases[0]);
                    break;
                case "match":
                    Flush();
                    skippingMatch = true;
                    break;
                case "include":
                    if (!followIncludes || skippingMatch) continue;
                    foreach (var pattern in value.Split(Blank, StringSplitOptions.RemoveEmptyEntries))
                    {
                        foreach (var path in ExpandIncludePaths(pattern))
                        {
                            var included = includeLoader?.Invoke(path) ?? DefaultIncludeLoader(path);
                            if (included is null) continue;
                            hosts.AddRange(Parse(included, includeLoader, followIncludes: false));
                        }
                    }
                    break;
                default:
                    if (skippingMatch || currentAlias is null) continue;
                    fields.TryAdd(keyword, value);
                    break;
            }
        }
        Flush();

        // First stanza wins, the way ssh itself resolves a repeated alias.
        var seen = new HashSet<string>(StringComparer.Ordinal);
        return hosts.Where(h => seen.Add(h.Alias)).ToList();
    }

    /// <summary><c>Keyword value</c>, <c>Keyword=value</c> and quoted values, comments stripped.</summary>
    internal static (string Keyword, string Value)? SplitDirective(string line)
    {
        var body = line;
        var hash = body.IndexOf('#');
        if (hash >= 0) body = body[..hash];
        body = body.Trim(Blank);
        if (body.Length == 0) return null;
        var split = body.IndexOfAny(new[] { ' ', '\t', '=' });
        if (split < 0) return null;
        var keyword = body[..split].ToLowerInvariant();
        var value = body[(split + 1)..].Trim(' ', '\t', '=');
        if (value.Length >= 2 && value[0] == '"' && value[^1] == '"') value = value[1..^1];
        return keyword.Length == 0 || value.Length == 0 ? null : (keyword, value);
    }

    private static IEnumerable<string> ExpandIncludePaths(string pattern)
    {
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var path = pattern;
        if (path.StartsWith("~/", StringComparison.Ordinal))
            path = Path.Combine(home, path[2..]);
        else if (!Path.IsPathRooted(path))
            path = Path.Combine(home, ".ssh", path);
        if (!path.Contains('*') && !path.Contains('?')) return new[] { path };

        var directory = Path.GetDirectoryName(path);
        var glob = Path.GetFileName(path);
        if (string.IsNullOrEmpty(directory) || !Directory.Exists(directory)) return Array.Empty<string>();
        return Directory.EnumerateFiles(directory, glob)
            .OrderBy(p => p, StringComparer.Ordinal)
            .ToList();
    }

    private static string? DefaultIncludeLoader(string path)
    {
        try { return File.ReadAllText(path, Encoding.UTF8); }
        catch (IOException) { return null; }
        catch (UnauthorizedAccessException) { return null; }
    }

    public static string Render(SSHHost host)
    {
        var lines = new List<string>
        {
            BeginMarker + host.Alias,
            $"Host {host.Alias}",
            $"    HostName {host.HostName}",
        };
        if (host.User.Length > 0) lines.Add($"    User {host.User}");
        lines.Add($"    Port {host.Port}");
        if (!string.IsNullOrEmpty(host.IdentityFile))
        {
            lines.Add($"    IdentityFile {host.IdentityFile}");
            lines.Add("    IdentitiesOnly yes");
        }
        lines.Add(EndMarker + host.Alias);
        return string.Join("\n", lines) + "\n";
    }

    /// <summary>
    /// Adds or replaces the app's own stanza. Everything outside the markers is
    /// preserved, and an alias already present in a hand-written stanza is
    /// refused rather than rewritten.
    /// </summary>
    public static string Upsert(SSHHost host, string text)
    {
        if (!IsValidAlias(host.Alias))
            throw new SSHException(SSHErrorKind.ConfigWriteFailed, host.Alias);
        if (Parse(StripManagedBlocks(text), followIncludes: false).Any(h => h.Alias == host.Alias))
            throw new SSHException(SSHErrorKind.ConfigWriteFailed, host.Alias);
        var body = RemoveManagedBlock(host.Alias, text);
        if (body.Length > 0 && !body.EndsWith('\n')) body += "\n";
        if (body.Length > 0) body += "\n";
        return body + Render(host);
    }

    public static string Remove(string alias, string text) => RemoveManagedBlock(alias, text);

    /// <summary>True when the alias is safe as a config token and as an ssh argument.</summary>
    public static bool IsValidAlias(string alias) =>
        alias.Length is > 0 and <= 64
        && !alias.StartsWith('-')
        && alias.All(c => c is (>= 'a' and <= 'z') or (>= 'A' and <= 'Z') or (>= '0' and <= '9') or '.' or '_' or '-');

    internal static string StripManagedBlocks(string text)
    {
        var kept = new List<string>();
        var inside = false;
        foreach (var line in SplitLines(text))
        {
            var trimmed = line.Trim(Blank);
            if (trimmed.StartsWith(BeginMarker, StringComparison.Ordinal)) { inside = true; continue; }
            if (trimmed.StartsWith(EndMarker, StringComparison.Ordinal)) { inside = false; continue; }
            if (!inside) kept.Add(line);
        }
        return string.Join("\n", kept);
    }

    private static string RemoveManagedBlock(string alias, string text)
    {
        var kept = new List<string>();
        var inside = false;
        foreach (var line in SplitLines(text))
        {
            var trimmed = line.Trim(Blank);
            if (trimmed == BeginMarker + alias) { inside = true; continue; }
            if (inside)
            {
                if (trimmed == EndMarker + alias) inside = false;
                continue;
            }
            kept.Add(line);
        }
        var result = string.Join("\n", kept);
        while (result.EndsWith("\n\n\n", StringComparison.Ordinal)) result = result[..^1];
        return result;
    }

    private static string[] SplitLines(string text) => text.Split(new[] { "\r\n", "\n", "\r" }, StringSplitOptions.None);
}

/// <summary>File-level access to <c>~/.ssh/config</c>, apart from the pure string logic.</summary>
public sealed class SSHConfigFile
{
    public string Path { get; }

    public SSHConfigFile(string? path = null)
    {
        Path = path ?? System.IO.Path.Combine(SSHRunner.SshDirectory, "config");
    }

    public string Read()
    {
        try { return File.ReadAllText(Path, Encoding.UTF8); }
        catch (IOException) { return ""; }
        catch (UnauthorizedAccessException) { return ""; }
    }

    public IReadOnlyList<SSHHost> Hosts() => SSHConfigStore.Parse(Read());

    public void Add(SSHHost host) => Write(SSHConfigStore.Upsert(host, Read()));

    public void Remove(string alias)
    {
        if (!File.Exists(Path)) return;
        Write(SSHConfigStore.Remove(alias, Read()));
    }

    /// <summary>Atomic: a crash or full disk leaves the previous config intact.</summary>
    private void Write(string text)
    {
        var directory = System.IO.Path.GetDirectoryName(Path)!;
        SSHRunner.EnsurePrivateDirectory(directory);
        var backup = Path + ".dots-backup";
        if (File.Exists(Path) && !File.Exists(backup))
        {
            try { File.Copy(Path, backup); } catch (IOException) { }
        }
        var temporary = System.IO.Path.Combine(directory, $"config.dots-{Guid.NewGuid():N}");
        var body = text.EndsWith('\n') ? text : text + "\n";
        File.WriteAllText(temporary, body, new UTF8Encoding(false));
        if (!OperatingSystem.IsWindows())
            File.SetUnixFileMode(temporary, UnixFileMode.UserRead | UnixFileMode.UserWrite);
        File.Move(temporary, Path, overwrite: true);
    }
}

/// <summary>The single place the app spawns ssh. Every remote command is built here.</summary>
public static class SSHRunner
{
    public sealed record Output(int Status, string Text, bool TimedOut);

    public static string SshDirectory => System.IO.Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".ssh");

    /// <summary>Resolved ssh binary: OpenSSH in System32 on Windows, PATH lookup elsewhere.</summary>
    public static string? ExecutablePath => FindTool("ssh");

    public static bool IsAvailable => ExecutablePath is not null;

    internal static string? FindTool(string name)
    {
        if (OperatingSystem.IsWindows())
        {
            var system = Environment.GetFolderPath(Environment.SpecialFolder.System);
            var bundled = System.IO.Path.Combine(system, "OpenSSH", name + ".exe");
            if (File.Exists(bundled)) return bundled;
        }
        var suffix = OperatingSystem.IsWindows() ? ".exe" : "";
        var directories = (Environment.GetEnvironmentVariable("PATH") ?? "")
            .Split(System.IO.Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries)
            .Concat(OperatingSystem.IsWindows() ? Array.Empty<string>() : new[] { "/usr/bin", "/usr/local/bin" });
        foreach (var directory in directories)
        {
            var candidate = System.IO.Path.Combine(directory, name + suffix);
            if (File.Exists(candidate)) return candidate;
        }
        return null;
    }

    internal static void EnsurePrivateDirectory(string directory)
    {
        if (Directory.Exists(directory)) return;
        Directory.CreateDirectory(directory);
        if (!OperatingSystem.IsWindows())
            File.SetUnixFileMode(directory, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
    }

    // Connection multiplexing: one authenticated master connection is reused by
    // later commands. Windows OpenSSH has no unix-socket multiplexing, so there
    // every call pays a handshake instead.
    private static bool SupportsMultiplexing => !OperatingSystem.IsWindows();

    private static string ControlPath()
    {
        var directory = System.IO.Path.Combine(SupportPaths.Default().Root, "ssh");
        EnsurePrivateDirectory(directory);
        // %C is ssh's hash of (host, port, user); a literal path would risk the sun_path limit.
        return System.IO.Path.Combine(directory, "cm-%C");
    }

    /// <summary>
    /// ssh's own options, common to every invocation. BatchMode on the
    /// non-interactive path keeps a host that wants a password from blocking on
    /// a prompt nobody can answer; StrictHostKeyChecking is never relaxed.
    /// </summary>
    public static IReadOnlyList<string> Options(bool interactive)
    {
        var options = new List<string>();
        if (SupportsMultiplexing)
        {
            options.AddRange(new[]
            {
                "-o", "ControlMaster=auto",
                "-o", $"ControlPath={ControlPath()}",
                "-o", "ControlPersist=120",
            });
        }
        options.AddRange(new[]
        {
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "-o", "ConnectTimeout=10",
            "-o", "StrictHostKeyChecking=yes",
        });
        if (interactive) options.Add("-tt");
        else options.AddRange(new[] { "-o", "BatchMode=yes", "-T" });
        return options;
    }

    public static IReadOnlyList<string> LaunchPrefix(string alias, bool interactive) =>
        Options(interactive).Concat(new[] { alias, "--" }).ToList();

    /// <summary>
    /// Single-quote wrapping is the only quoting a POSIX shell honours without
    /// exception. Every remote path and command goes through here.
    /// </summary>
    public static string ShellQuote(string value) => "'" + value.Replace("'", "'\\''") + "'";

    /// <summary>/bin/sh, not zsh or bash: remote machines often lack them. The login flag keeps PATH.</summary>
    public static string RemoteCommand(string cwd, string command) =>
        $"cd -- {ShellQuote(cwd)} && exec /bin/sh -lc {ShellQuote(command)}";

    /// <summary>Arguments for an interactive login shell in the target folder (terminal panel).</summary>
    public static IReadOnlyList<string> InteractiveArguments(SSHTarget target) =>
        LaunchPrefix(target.Alias, interactive: true)
            .Append($"cd -- {ShellQuote(target.RemotePath)} && exec ${{SHELL:-/bin/sh}} -l")
            .ToList();

    public static Task<Output> RunAsync(
        SSHTarget target,
        string command,
        TimeSpan? timeout = null,
        Action<string>? onOutput = null,
        CancellationToken cancellationToken = default) =>
        SpawnAsync(
            LaunchPrefix(target.Alias, interactive: false).Append(RemoteCommand(target.RemotePath, command)).ToList(),
            timeout ?? TimeSpan.FromSeconds(90),
            onOutput,
            cancellationToken);

    /// <summary>Runs a command on the host with no working directory (probes, folder browsing).</summary>
    public static Task<Output> RunOnHostAsync(
        string alias,
        string command,
        TimeSpan? timeout = null,
        CancellationToken cancellationToken = default) =>
        SpawnAsync(
            LaunchPrefix(alias, interactive: false).Append($"/bin/sh -lc {ShellQuote(command)}").ToList(),
            timeout ?? TimeSpan.FromSeconds(30),
            null,
            cancellationToken);

    internal static async Task<Output> SpawnAsync(
        IReadOnlyList<string> arguments,
        TimeSpan timeout,
        Action<string>? onOutput,
        CancellationToken cancellationToken,
        IReadOnlyDictionary<string, string>? environment = null,
        string? executable = null)
    {
        var path = executable ?? ExecutablePath ?? throw new SSHException(SSHErrorKind.SshUnavailable);
        var start = new ProcessStartInfo(path)
        {
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            RedirectStandardInput = true,
            UseShellExecute = false,
            CreateNoWindow = true,
        };
        foreach (var argument in arguments) start.ArgumentList.Add(argument);
        if (environment is not null)
            foreach (var (key, value) in environment) start.Environment[key] = value;

        using var process = new Process { StartInfo = start };
        var sink = new StringBuilder();
        var gate = new object();
        void Collect(string? line)
        {
            if (line is null) return;
            lock (gate) sink.Append(line).Append('\n');
            onOutput?.Invoke(line + "\n");
        }
        process.OutputDataReceived += (_, e) => Collect(e.Data);
        process.ErrorDataReceived += (_, e) => Collect(e.Data);
        process.Start();
        process.StandardInput.Close();
        process.BeginOutputReadLine();
        process.BeginErrorReadLine();

        using var timer = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timer.CancelAfter(timeout);
        var timedOut = false;
        try
        {
            await process.WaitForExitAsync(timer.Token).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            timedOut = !cancellationToken.IsCancellationRequested;
            try { process.Kill(entireProcessTree: true); } catch (InvalidOperationException) { }
            await process.WaitForExitAsync().ConfigureAwait(false);
            if (!timedOut) throw;
        }
        // Parameterless wait flushes the async readers.
        process.WaitForExit();
        lock (gate) return new Output(process.ExitCode, sink.ToString(), timedOut);
    }

    /// <summary>Cheap "can we reach this host and is its key what we trusted".</summary>
    public static async Task ProbeAsync(string alias, CancellationToken cancellationToken = default)
    {
        if (!IsAvailable) throw new SSHException(SSHErrorKind.SshUnavailable);
        var output = await SpawnAsync(
            LaunchPrefix(alias, interactive: false).Append("true").ToList(),
            TimeSpan.FromSeconds(20), null, cancellationToken).ConfigureAwait(false);
        if (output.TimedOut) throw new SSHException(SSHErrorKind.NotReachable, alias);
        if (output.Status != 0) throw Classify(output.Text, alias);
    }

    public static async Task<bool> DirectoryExistsAsync(SSHTarget target, CancellationToken cancellationToken = default)
    {
        try
        {
            var output = await RunOnHostAsync(
                target.Alias, $"test -d {ShellQuote(target.RemotePath)}", null, cancellationToken).ConfigureAwait(false);
            return output.Status == 0 && !output.TimedOut;
        }
        catch (SSHException) { return false; }
    }

    /// <summary>Expands <c>~</c> and relative input as the remote login shell would.</summary>
    public static async Task<string?> ResolveDirectoryAsync(string alias, string path, CancellationToken cancellationToken = default)
    {
        var command = path.StartsWith('~')
            ? $"cd {path.Replace("'", "")} >/dev/null 2>&1 && pwd -P"
            : $"cd -- {ShellQuote(path)} >/dev/null 2>&1 && pwd -P";
        try
        {
            var output = await RunOnHostAsync(alias, command, null, cancellationToken).ConfigureAwait(false);
            var resolved = output.Text.Trim();
            return output.Status == 0 && resolved.Length > 0 ? resolved : null;
        }
        catch (SSHException) { return null; }
    }

    public static async Task<IReadOnlyList<string>> ListDirectoriesAsync(string alias, string path, CancellationToken cancellationToken = default)
    {
        try
        {
            var output = await RunOnHostAsync(
                alias, $"cd -- {ShellQuote(path)} && ls -1Ap", null, cancellationToken).ConfigureAwait(false);
            if (output.Status != 0) return Array.Empty<string>();
            return output.Text
                .Split('\n')
                .Select(l => l.TrimEnd('\r'))
                .Where(l => l.EndsWith('/'))
                .Select(l => l[..^1])
                .Where(l => l.Length > 0)
                .OrderBy(l => l, StringComparer.OrdinalIgnoreCase)
                .ToList();
        }
        catch (SSHException) { return Array.Empty<string>(); }
    }

    /// <summary>Tears the multiplexed master down after removing a host or a bad connection.</summary>
    public static async Task CloseMasterAsync(string alias)
    {
        if (!IsAvailable || !SupportsMultiplexing) return;
        try
        {
            await SpawnAsync(
                new[] { "-o", $"ControlPath={ControlPath()}", "-O", "exit", alias },
                TimeSpan.FromSeconds(5), null, CancellationToken.None).ConfigureAwait(false);
        }
        catch (SSHException) { }
    }

    /// <summary>Maps ssh's stderr onto errors the UI can act on; a changed host key matters most.</summary>
    public static SSHException Classify(string text, string alias)
    {
        var lower = text.ToLowerInvariant();
        if (lower.Contains("remote host identification has changed") || lower.Contains("host key verification failed"))
            return new SSHException(SSHErrorKind.HostKeyChanged, alias);
        if (lower.Contains("permission denied") || lower.Contains("too many authentication failures"))
            return new SSHException(SSHErrorKind.AuthFailed, alias);
        return new SSHException(SSHErrorKind.NotReachable, alias);
    }

    /// <summary>
    /// True when a failed remote command failed because the transport dropped,
    /// not because the command did, so the agent does not hunt a bug in code
    /// that never ran.
    /// </summary>
    public static bool IsTransportFailure(string text)
    {
        var lower = text.ToLowerInvariant();
        return (lower.Contains("connection to ") && lower.Contains("closed"))
            || lower.Contains("broken pipe")
            || lower.Contains("connection reset by peer")
            || lower.Contains("ssh: connect to host")
            || lower.Contains("control socket connect");
    }
}

/// <summary>The app's view of the user's SSH hosts plus per-host bookkeeping.</summary>
public sealed class SSHHostStore
{
    public sealed record Record(
        string Alias,
        bool ManagedByApp = false,
        DateTimeOffset? EnrolledAt = null,
        string? LastRemotePath = null,
        IReadOnlyList<string>? RecentRemotePaths = null,
        bool Missing = false)
    {
        public IReadOnlyList<string> Recent => RecentRemotePaths ?? Array.Empty<string>();
    }

    private readonly object _gate = new();
    private readonly SSHConfigFile _configFile;
    private readonly string _storePath;
    private Dictionary<string, Record> _records = new(StringComparer.Ordinal);
    private IReadOnlyList<SSHHost> _hosts = Array.Empty<SSHHost>();
    private bool _loaded;

    public SSHHostStore(SSHConfigFile? configFile = null, string? storePath = null)
    {
        _configFile = configFile ?? new SSHConfigFile();
        _storePath = storePath ?? Path.Combine(SupportPaths.Default().Root, "ssh-hosts.json");
    }

    public bool IsAvailable => SSHRunner.IsAvailable;

    public IReadOnlyList<SSHHost> Hosts { get { lock (_gate) { EnsureLoaded(); return _hosts; } } }

    public SSHHost? Host(string alias) => Hosts.FirstOrDefault(h => h.Alias == alias);

    public Record RecordFor(string alias)
    {
        lock (_gate)
        {
            EnsureLoaded();
            return _records.GetValueOrDefault(alias) ?? new Record(alias);
        }
    }

    /// <summary>~/.ssh/config is the source of truth; the user may have edited it since.</summary>
    public void Reload()
    {
        lock (_gate)
        {
            if (!_loaded) { _loaded = true; LoadRecords(); }
            Refresh(save: true);
        }
    }

    public void Add(SSHHost host, bool enrolled)
    {
        lock (_gate)
        {
            EnsureLoaded();
            _configFile.Add(host);
            var record = _records.GetValueOrDefault(host.Alias) ?? new Record(host.Alias);
            _records[host.Alias] = record with
            {
                ManagedByApp = true,
                EnrolledAt = enrolled ? DateTimeOffset.UtcNow : record.EnrolledAt,
                Missing = false,
            };
            SaveRecords();
            Refresh(save: true);
        }
    }

    public async Task RemoveAsync(string alias)
    {
        await SSHRunner.CloseMasterAsync(alias).ConfigureAwait(false);
        lock (_gate)
        {
            EnsureLoaded();
            _configFile.Remove(alias);
            _records.Remove(alias);
            SaveRecords();
            Refresh(save: true);
        }
    }

    public void RememberRemotePath(string alias, string path)
    {
        lock (_gate)
        {
            EnsureLoaded();
            var record = _records.GetValueOrDefault(alias) ?? new Record(alias);
            var recent = new[] { path }.Concat(record.Recent.Where(p => p != path)).Take(8).ToList();
            _records[alias] = record with { LastRemotePath = path, RecentRemotePaths = recent };
            SaveRecords();
        }
    }

    private void EnsureLoaded()
    {
        if (_loaded) return;
        _loaded = true;
        LoadRecords();
        Refresh(save: false);
    }

    private void Refresh(bool save)
    {
        var configured = _configFile.Hosts();
        _hosts = configured;
        var aliases = configured.Select(h => h.Alias).ToHashSet(StringComparer.Ordinal);
        var changed = false;
        foreach (var (alias, record) in _records.ToList())
        {
            if (record.Missing == aliases.Contains(alias))
            {
                _records[alias] = record with { Missing = !aliases.Contains(alias) };
                changed = true;
            }
        }
        foreach (var host in configured)
        {
            if (_records.ContainsKey(host.Alias)) continue;
            _records[host.Alias] = new Record(host.Alias, host.ManagedByApp);
            changed = true;
        }
        if (save && changed) SaveRecords();
    }

    private void LoadRecords()
    {
        try
        {
            var decoded = JsonSerializer.Deserialize<Dictionary<string, Record>>(File.ReadAllText(_storePath));
            if (decoded is not null) _records = new Dictionary<string, Record>(decoded, StringComparer.Ordinal);
        }
        catch (Exception e) when (e is IOException or JsonException or UnauthorizedAccessException) { }
    }

    private void SaveRecords()
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(_storePath)!);
            var temporary = _storePath + ".tmp";
            File.WriteAllText(temporary, JsonSerializer.Serialize(_records));
            File.Move(temporary, _storePath, overwrite: true);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
    }
}

/// <summary>
/// First-time setup for a remote work location: trust the host key, generate a
/// key pair, and hand the password to ssh exactly once to install the public
/// key. Unlike macOS (pty), the password reaches ssh through SSH_ASKPASS so the
/// same code runs on Linux and Windows; it lives only in the child environment.
/// </summary>
public static class SSHEnrollment
{
    public const string KeyName = "dots_harness_ed25519";

    public sealed record HostKeyScan(IReadOnlyList<string> Lines, IReadOnlyList<string> Fingerprints);

    public static string PrivateKeyPath => Path.Combine(SSHRunner.SshDirectory, KeyName);
    public static string PublicKeyPath => PrivateKeyPath + ".pub";
    public static string KnownHostsPath => Path.Combine(SSHRunner.SshDirectory, "known_hosts");

    /// <summary><c>~/.ssh/&lt;key&gt;</c> rather than an absolute path: the config stays portable.</summary>
    public static string IdentityFileReference => $"~/.ssh/{KeyName}";

    public static async Task<string> EnsureKeyPairAsync()
    {
        SSHRunner.EnsurePrivateDirectory(SSHRunner.SshDirectory);
        if (PublicKey() is { } existing) return existing;
        // A stale private key with no public half would make ssh-keygen refuse.
        if (File.Exists(PrivateKeyPath)) File.Delete(PrivateKeyPath);
        var comment = $"dotsharness@{Environment.MachineName}";
        var result = await RunToolAsync("ssh-keygen",
            new[] { "-t", "ed25519", "-N", "", "-C", comment, "-f", PrivateKeyPath }).ConfigureAwait(false);
        if (result.Status != 0) throw new SSHException(SSHErrorKind.ConfigWriteFailed, result.Text.Trim());
        return PublicKey() ?? throw new SSHException(SSHErrorKind.ConfigWriteFailed, PublicKeyPath);
    }

    public static string? PublicKey()
    {
        try
        {
            var key = File.ReadAllText(PublicKeyPath).Trim();
            return key.Length == 0 ? null : key;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return null; }
    }

    /// <summary>Fetches host keys so the user can confirm the fingerprint. Nothing is trusted yet.</summary>
    public static async Task<HostKeyScan> ScanHostKeyAsync(string hostName, int port)
    {
        var scan = await RunToolAsync("ssh-keyscan", new[] { "-p", port.ToString(), "-T", "5", hostName }).ConfigureAwait(false);
        var lines = scan.Text.Split('\n')
            .Select(l => l.Trim())
            .Where(l => l.Length > 0 && !l.StartsWith('#'))
            .ToList();
        if (lines.Count == 0) throw new SSHException(SSHErrorKind.NotReachable, hostName);

        var temporary = Path.Combine(Path.GetTempPath(), $"dots-hostkey-{Guid.NewGuid():N}");
        try
        {
            await File.WriteAllTextAsync(temporary, string.Join("\n", lines) + "\n").ConfigureAwait(false);
            var printed = await RunToolAsync("ssh-keygen", new[] { "-lf", temporary }).ConfigureAwait(false);
            var fingerprints = printed.Status == 0
                ? printed.Text.Split('\n').Select(l => l.Trim()).Where(l => l.Length > 0).ToList()
                : new List<string>();
            return new HostKeyScan(lines, fingerprints);
        }
        finally
        {
            try { File.Delete(temporary); } catch (IOException) { }
        }
    }

    /// <summary>
    /// Writes confirmed host keys into known_hosts. Only called after a human
    /// has seen the fingerprint; the app never passes accept-new to ssh instead.
    /// </summary>
    public static void Trust(HostKeyScan scan)
    {
        SSHRunner.EnsurePrivateDirectory(SSHRunner.SshDirectory);
        var existing = File.Exists(KnownHostsPath) ? File.ReadAllText(KnownHostsPath) : "";
        var known = existing.Split('\n').Select(l => l.Trim()).ToHashSet(StringComparer.Ordinal);
        var additions = scan.Lines.Where(l => !known.Contains(l)).ToList();
        if (additions.Count == 0) return;
        if (existing.Length > 0 && !existing.EndsWith('\n')) existing += "\n";
        existing += string.Join("\n", additions) + "\n";
        File.WriteAllText(KnownHostsPath, existing);
        if (!OperatingSystem.IsWindows())
            File.SetUnixFileMode(KnownHostsPath, UnixFileMode.UserRead | UnixFileMode.UserWrite);
    }

    /// <summary>Drops a remembered host key so a reinstalled machine can be re-trusted. Explicit user action only.</summary>
    public static async Task ForgetHostKeyAsync(string hostName, int port)
    {
        var target = port == 22 ? hostName : $"[{hostName}]:{port}";
        try { await RunToolAsync("ssh-keygen", new[] { "-R", target }).ConfigureAwait(false); }
        catch (SSHException) { }
    }

    /// <summary>Authenticates once with the password and appends our public key to authorized_keys.</summary>
    public static async Task InstallPublicKeyAsync(
        string user, string hostName, int port, string password, string publicKey)
    {
        var remote =
            "umask 077; mkdir -p ~/.ssh && " +
            $"printf '%s\\n' {SSHRunner.ShellQuote(publicKey)} >> ~/.ssh/authorized_keys && " +
            "chmod 600 ~/.ssh/authorized_keys && chmod 700 ~/.ssh";
        var arguments = new[]
        {
            "-o", "PreferredAuthentications=password,keyboard-interactive",
            "-o", "PubkeyAuthentication=no",
            "-o", "StrictHostKeyChecking=yes",
            "-o", "NumberOfPasswordPrompts=1",
            "-o", "ConnectTimeout=10",
            "-p", port.ToString(),
            $"{user}@{hostName}",
            "--",
            remote,
        };

        var askpass = WriteAskpassScript();
        try
        {
            var output = await SSHRunner.SpawnAsync(
                arguments,
                TimeSpan.FromSeconds(45),
                null,
                CancellationToken.None,
                new Dictionary<string, string>
                {
                    ["SSH_ASKPASS"] = askpass,
                    ["SSH_ASKPASS_REQUIRE"] = "force",
                    // Older ssh only consults SSH_ASKPASS when DISPLAY is set.
                    ["DISPLAY"] = Environment.GetEnvironmentVariable("DISPLAY") ?? "dots:0",
                    ["DOTS_SSH_PASSWORD"] = password,
                }).ConfigureAwait(false);
            var lower = output.Text.ToLowerInvariant();
            if (lower.Contains("permission denied (publickey")
                || lower.Contains("no matching authentications")
                || (lower.Contains("permission denied") && !lower.Contains("assword")))
                throw new SSHException(SSHErrorKind.PasswordAuthDisabled);
            if (lower.Contains("remote host identification has changed")
                || lower.Contains("host key verification failed"))
                throw new SSHException(SSHErrorKind.HostKeyChanged, hostName);
            if (lower.Contains("permission denied") || output.Status != 0 || output.TimedOut)
                throw new SSHException(SSHErrorKind.AuthFailed, hostName);
        }
        finally
        {
            try { File.Delete(askpass); } catch (IOException) { }
        }
    }

    /// <summary>A throwaway helper that prints the password from the child environment; it never contains it.</summary>
    private static string WriteAskpassScript()
    {
        var directory = Path.Combine(SupportPaths.Default().Root, "ssh");
        SSHRunner.EnsurePrivateDirectory(directory);
        if (OperatingSystem.IsWindows())
        {
            var path = Path.Combine(directory, $"askpass-{Guid.NewGuid():N}.cmd");
            File.WriteAllText(path,
                "@echo off\r\npowershell -NoProfile -NonInteractive -Command \"[Console]::Out.Write($env:DOTS_SSH_PASSWORD)\"\r\n");
            return path;
        }
        var script = Path.Combine(directory, $"askpass-{Guid.NewGuid():N}.sh");
        File.WriteAllText(script, "#!/bin/sh\nprintf '%s\\n' \"$DOTS_SSH_PASSWORD\"\n");
        File.SetUnixFileMode(script, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
        return script;
    }

    private static async Task<SSHRunner.Output> RunToolAsync(string tool, IReadOnlyList<string> arguments)
    {
        var path = SSHRunner.FindTool(tool) ?? throw new SSHException(SSHErrorKind.SshUnavailable);
        return await SSHRunner.SpawnAsync(arguments, TimeSpan.FromSeconds(30), null, CancellationToken.None, null, path)
            .ConfigureAwait(false);
    }
}

/// <summary>
/// Runs tool calls on a remote work location. Only <c>run_command</c> crosses the
/// wire; every other workspace tool is refused rather than quietly falling back
/// to the local disk, because writing to the wrong machine is the one failure
/// this feature must not have.
/// </summary>
public static class RemoteWorkspaceTools
{
    private const int MaxOutput = 24_000;
    private static readonly Regex MemPath = new(@"(?:^|[\s/])\.mem(?:[\s/]|$)", RegexOptions.Compiled);

    /// <summary>The only workspace tool offered on a remote host (plan mode has none).</summary>
    public static IReadOnlyList<NativeToolDefinition> Definitions(bool planMode) =>
        planMode
            ? Array.Empty<NativeToolDefinition>()
            : NativeWorkspaceTools.Definitions.Where(t => t.Name == "run_command").ToList();

    public static async Task<string> ExecuteAsync(NativeToolCall call, SSHTarget target, CancellationToken ct = default)
    {
        if (call.Name != "run_command")
            return $"Tool error: {call.Name} is not available on remote host {target.Alias}. Use run_command instead.";
        string? command;
        try { command = System.Text.Json.Nodes.JsonNode.Parse(call.Arguments)?["command"]?.GetValue<string>(); }
        catch (Exception e) when (e is JsonException or InvalidOperationException) { command = null; }
        if (string.IsNullOrWhiteSpace(command)) return "Tool error: run_command needs a command.";
        if (MemPath.IsMatch(command)) return "Tool error: that path is unavailable.";
        try
        {
            var output = await SSHRunner.RunAsync(target, command, null, null, ct).ConfigureAwait(false);
            if (output.TimedOut) return "Tool error: the command timed out.";
            var text = output.Text.Length > MaxOutput ? output.Text[..MaxOutput] : output.Text;
            // Told apart from an ordinary non-zero exit so the agent does not hunt a bug in code that never ran.
            if (output.Status != 0 && SSHRunner.IsTransportFailure(text))
                return $"The connection to {target.Alias} dropped. The command may not have run.\n{text}";
            var suffix = output.Status == 0 ? "" : $"\nCommand exited with status {output.Status}.";
            return text.Length == 0 ? "(no output)" + suffix : text + suffix;
        }
        catch (SSHException e) { return $"Tool error: {e.Message}"; }
    }

    public static string Guidance(SSHTarget target) => $"""

        Remote execution over SSH
        - This run works on the remote host {target.Alias}, in {target.RemotePath}.
        - run_command executes there through a non-interactive `/bin/sh -lc`. There is no
          TTY, so anything that prompts (`sudo` without NOPASSWD, an editor, a pager) fails
          instead of waiting; avoid those.
        - The local machine's files are not visible: list_files, read_file, write_file,
          remove_file and grep_files are unavailable in this mode. Use shell commands
          (`ls`, `sed -n`, `grep -rn`, a heredoc write) through run_command instead.
        """;
}

/// <summary>
/// The "Add a computer" sequence shared by the Avalonia and WPF shells: fetch the
/// host key, let the user confirm its fingerprint, then trust it, install our key
/// with the one-time password, write the ~/.ssh/config stanza and verify.
/// </summary>
public static class SSHEnrollmentFlow
{
    public sealed record Request(string Alias, string HostName, string User, int Port);

    /// <summary>Step 1. Nothing is trusted yet; show <see cref="SSHEnrollment.HostKeyScan.Fingerprints"/> to the user.</summary>
    public static Task<SSHEnrollment.HostKeyScan> ScanAsync(Request request)
    {
        Validate(request);
        return SSHEnrollment.ScanHostKeyAsync(request.HostName, request.Port);
    }

    /// <summary>Step 2, only after the user confirmed the fingerprint. The password is used once and not kept.</summary>
    public static async Task<SSHHost> CompleteAsync(
        SSHHostStore store,
        Request request,
        SSHEnrollment.HostKeyScan scan,
        string? password,
        CancellationToken cancellationToken = default)
    {
        Validate(request);
        SSHEnrollment.Trust(scan);
        var publicKey = await SSHEnrollment.EnsureKeyPairAsync().ConfigureAwait(false);
        var enrolled = false;
        if (!string.IsNullOrEmpty(password))
        {
            await SSHEnrollment.InstallPublicKeyAsync(request.User, request.HostName, request.Port, password, publicKey)
                .ConfigureAwait(false);
            enrolled = true;
        }
        var host = new SSHHost(
            request.Alias, request.HostName, request.User, request.Port,
            SSHEnrollment.IdentityFileReference, ManagedByApp: true);
        store.Add(host, enrolled);
        await SSHRunner.ProbeAsync(host.Alias, cancellationToken).ConfigureAwait(false);
        return host;
    }

    private static void Validate(Request request)
    {
        if (!SSHConfigStore.IsValidAlias(request.Alias))
            throw new SSHException(SSHErrorKind.ConfigWriteFailed, request.Alias);
        if (string.IsNullOrWhiteSpace(request.HostName)
            || request.HostName.StartsWith('-')
            || request.HostName.Any(char.IsWhiteSpace)
            || request.Port is < 1 or > 65535
            || request.User.StartsWith('-')
            || request.User.Any(char.IsWhiteSpace))
            throw new SSHException(SSHErrorKind.NotReachable, request.HostName);
    }
}

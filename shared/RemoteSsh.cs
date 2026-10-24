// Copyright (c) 2026 DOTS
// SSH backed work locations shared by the Windows and Linux desktop clients.

using System.Diagnostics;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;

namespace DotsHarnessCore;

public sealed record SshHost(
    string Alias,
    string HostName,
    string User,
    int Port = 22,
    string? IdentityFile = null,
    bool ManagedByApp = false)
{
    public string DisplayDestination => (string.IsNullOrWhiteSpace(User) ? HostName : $"{User}@{HostName}")
        + (Port == 22 ? "" : $":{Port}");
    public string DisplayName => $"{Alias} — {DisplayDestination}";
}

public sealed record SshTarget(string Alias, string RemotePath)
{
    public string Identity => $"ssh://{Alias}{(RemotePath.StartsWith('/') ? "" : "/")}{RemotePath}";
}

public sealed record SshHostKey(string KeyType, string PublicKey, string Fingerprint)
{
    public string KnownHostsLine(string hostToken) => $"{hostToken} {KeyType} {PublicKey}";
}

public sealed record SshCommandResult(int ExitCode, string StandardOutput, string StandardError, bool TimedOut)
{
    public string CombinedOutput => string.Join("\n", new[] { StandardOutput.TrimEnd(), StandardError.TrimEnd() }
        .Where(value => value.Length > 0));
}

/// <summary>
/// Reads user host aliases and writes only DotsHarness-managed stanzas in
/// ~/.ssh/config. Passwords and private keys are never embedded in its stanzas.
/// </summary>
public static class RemoteSsh
{
    private const string BeginMarker = "# >>> DotsHarness managed host: ";
    private const string EndMarker = "# <<< DotsHarness managed host: ";
    private static string SshDirectory => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".ssh");
    public static string ConfigFile => Path.Combine(SshDirectory, "config");
    public static string KnownHostsFile => Path.Combine(SshDirectory, "known_hosts");
    public static bool IsAvailable => FindExecutable("ssh") is not null;
    public static bool IsValidHostInput(string hostName, string user, int port) =>
        !string.IsNullOrWhiteSpace(hostName) && IsSingleConfigToken(hostName)
        && IsSingleConfigToken(user) && port is >= 1 and <= 65535;

    public static IReadOnlyList<SshHost> ReadHosts()
    {
        var result = new List<SshHost>();
        var managedAliases = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        ReadConfig(ConfigFile, result, managedAliases, followIncludes: true);
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        return result.Where(host => seen.Add(host.Alias)).OrderBy(host => host.Alias, StringComparer.CurrentCultureIgnoreCase).ToArray();
    }

    private static void ReadConfig(string file, List<SshHost> output, HashSet<string> managedAliases, bool followIncludes)
    {
        if (!File.Exists(file)) return;
        string text;
        try { text = File.ReadAllText(file); }
        catch { return; }

        string? alias = null;
        var pattern = false;
        var inMatch = false;
        var fields = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        void Flush()
        {
            if (alias is not null && !pattern && !inMatch)
            {
                var port = int.TryParse(fields.GetValueOrDefault("port"), out var parsed) && parsed is >= 1 and <= 65535 ? parsed : 22;
                output.Add(new SshHost(
                    alias,
                    fields.GetValueOrDefault("hostname") ?? alias,
                    fields.GetValueOrDefault("user") ?? "",
                    port,
                    fields.GetValueOrDefault("identityfile"),
                    managedAliases.Contains(alias)));
            }
            alias = null;
            pattern = false;
            fields.Clear();
        }

        foreach (var rawLine in text.Split('\n'))
        {
            var line = rawLine.Trim();
            if (line.StartsWith(BeginMarker, StringComparison.Ordinal))
            {
                managedAliases.Add(line[BeginMarker.Length..].Trim());
                continue;
            }
            if (line.Length == 0 || line.StartsWith('#')) continue;
            var directive = SplitDirective(line);
            if (directive is null) continue;
            var (key, value) = directive.Value;
            if (key.Equals("host", StringComparison.OrdinalIgnoreCase))
            {
                Flush();
                inMatch = false;
                var names = value.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
                if (names.Length == 0) continue;
                alias = names[0];
                pattern = names.Any(name => name.Contains('*') || name.Contains('?') || name.StartsWith('!'));
            }
            else if (key.Equals("match", StringComparison.OrdinalIgnoreCase))
            {
                Flush();
                inMatch = true;
            }
            else if (key.Equals("include", StringComparison.OrdinalIgnoreCase))
            {
                if (!followIncludes || inMatch) continue;
                foreach (var include in value.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries))
                    foreach (var includeFile in ExpandInclude(file, include))
                        ReadConfig(includeFile, output, managedAliases, followIncludes: false);
            }
            else if (!inMatch && alias is not null && !fields.ContainsKey(key))
            {
                fields[key] = value;
            }
        }
        Flush();
    }

    private static (string Key, string Value)? SplitDirective(string line)
    {
        var quoted = false;
        var end = line.Length;
        for (var index = 0; index < line.Length; index++)
        {
            if (line[index] == '"') quoted = !quoted;
            else if (line[index] == '#' && !quoted) { end = index; break; }
        }
        line = line[..end].Trim();
        if (line.Length == 0) return null;
        var split = line.IndexOfAny([' ', '\t', '=']);
        if (split < 0) return null;
        var key = line[..split].Trim().ToLowerInvariant();
        var value = line[split..].Trim().TrimStart('=', ' ', '\t').TrimEnd();
        if (value.Length >= 2 && value[0] == '"' && value[^1] == '"') value = value[1..^1];
        return key.Length == 0 || value.Length == 0 ? null : (key, value);
    }

    private static IEnumerable<string> ExpandInclude(string currentFile, string include)
    {
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var path = include.StartsWith("~/", StringComparison.Ordinal)
            ? Path.Combine(home, include[2..])
            : Path.IsPathRooted(include) ? include : Path.Combine(Path.GetDirectoryName(currentFile) ?? SshDirectory, include);
        var directory = Path.GetDirectoryName(path) ?? SshDirectory;
        var pattern = Path.GetFileName(path);
        try
        {
            return Directory.GetFiles(directory, pattern).OrderBy(item => item, StringComparer.Ordinal).ToArray();
        }
        catch { return File.Exists(path) ? [path] : []; }
    }

    public static bool IsValidAlias(string alias) => alias.Length is > 0 and <= 64
        && !alias.StartsWith('-')
        && alias.All(character => char.IsAsciiLetterOrDigit(character) || character is '.' or '_' or '-');

    public static void AddManagedHost(string alias, string hostName, string user, int port, string? identityFile = null)
    {
        if (!IsValidAlias(alias) || !IsValidHostInput(hostName, user, port))
            throw new InvalidOperationException("Enter a valid alias, host name, user name, and port.");

        Directory.CreateDirectory(SshDirectory);
        SetPrivateDirectoryMode();
        var text = File.Exists(ConfigFile) ? File.ReadAllText(ConfigFile) : "";
        var existing = ReadHosts().FirstOrDefault(host => host.Alias.Equals(alias, StringComparison.OrdinalIgnoreCase));
        if (existing is not null)
        {
            if (!existing.ManagedByApp)
                throw new InvalidOperationException($"The SSH alias '{alias}' already exists. Edit its existing Host entry instead.");
            RemoveManagedHost(alias);
            text = File.Exists(ConfigFile) ? File.ReadAllText(ConfigFile) : "";
        }
        if (!string.IsNullOrWhiteSpace(identityFile) && !IsSingleConfigToken(identityFile))
            throw new InvalidOperationException("The SSH identity file path is invalid.");
        if (text.Length > 0 && !text.EndsWith('\n')) text += Environment.NewLine;
        if (text.Length > 0 && !text.EndsWith(Environment.NewLine + Environment.NewLine, StringComparison.Ordinal)) text += Environment.NewLine;
        text += $"{BeginMarker}{alias}{Environment.NewLine}Host {alias}{Environment.NewLine}    HostName {hostName}{Environment.NewLine}";
        if (!string.IsNullOrWhiteSpace(user)) text += $"    User {user}{Environment.NewLine}";
        text += $"    Port {port}{Environment.NewLine}";
        if (!string.IsNullOrWhiteSpace(identityFile))
            text += $"    IdentityFile {identityFile}{Environment.NewLine}    IdentitiesOnly yes{Environment.NewLine}";
        text += $"{EndMarker}{alias}{Environment.NewLine}";
        if (!string.IsNullOrWhiteSpace(identityFile))
        {
            if (!IsSingleConfigToken(identityFile)) throw new InvalidOperationException("The SSH identity file path is invalid.");
            text = text.Replace($"    Port {port}{Environment.NewLine}{EndMarker}{alias}",
                $"    Port {port}{Environment.NewLine}    IdentityFile {identityFile}{Environment.NewLine}    IdentitiesOnly yes{Environment.NewLine}{EndMarker}{alias}",
                StringComparison.Ordinal);
        }
        WritePrivateFile(ConfigFile, text);
    }

    public static void RemoveManagedHost(string alias)
    {
        if (!File.Exists(ConfigFile)) return;
        var lines = File.ReadAllLines(ConfigFile);
        var kept = new List<string>();
        var removing = false;
        foreach (var line in lines)
        {
            var trimmed = line.Trim();
            if (trimmed.Equals(BeginMarker + alias, StringComparison.Ordinal)) { removing = true; continue; }
            if (removing)
            {
                if (trimmed.Equals(EndMarker + alias, StringComparison.Ordinal)) removing = false;
                continue;
            }
            kept.Add(line);
        }
        WritePrivateFile(ConfigFile, string.Join(Environment.NewLine, kept).TrimEnd() + Environment.NewLine);
    }

    public static IReadOnlyList<string> BuildSshArguments(string alias, bool interactive)
    {
        if (!IsValidAlias(alias)) throw new InvalidOperationException("The SSH host alias is invalid.");
        var args = new List<string>
        {
            "-o", "ConnectTimeout=10",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "-o", "StrictHostKeyChecking=yes",
        };
        if (interactive) args.Add("-tt");
        else
        {
            args.AddRange(["-o", "BatchMode=yes", "-T"]);
        }
        args.Add("--");
        args.Add(alias);
        return args;
    }

    public static string? FindSshExecutable() => FindExecutable("ssh");

    public static IReadOnlyList<string> BuildTerminalArguments(SshTarget target)
    {
        var args = BuildSshArguments(target.Alias, interactive: true).ToList();
        args.Add($"cd -- {ShellQuote(target.RemotePath)} && exec ${{SHELL:-/bin/sh}} -l");
        return args;
    }

    public static string ShellQuote(string value) => "'" + value.Replace("'", "'\\''", StringComparison.Ordinal) + "'";

    public static string RemoteCommand(string path, string command) =>
        $"cd -- {ShellQuotePath(path)} && exec /bin/sh -lc {ShellQuote(command)}";

    public static async Task<SshCommandResult> RunCommandAsync(SshTarget target, string command, CancellationToken ct)
    {
        if (!IsAvailable) throw new InvalidOperationException("OpenSSH is not installed or was not found on PATH.");
        if (Regex.IsMatch(command, @"(?:^|[\s/])\.mem(?:[\s/]|$)", RegexOptions.CultureInvariant))
            throw new InvalidOperationException("Remote commands cannot access this computer's private memory folder.");
        var args = BuildSshArguments(target.Alias, interactive: false).ToList();
        args.Add(RemoteCommand(target.RemotePath, command));
        return await RunAsync("ssh", args, TimeSpan.FromSeconds(90), ct);
    }

    public static async Task<SshCommandResult> ProbeAsync(string alias, CancellationToken ct = default)
    {
        var args = BuildSshArguments(alias, interactive: false).ToList();
        args.Add("true");
        return await RunAsync("ssh", args, TimeSpan.FromSeconds(20), ct);
    }

    public static async Task<string> ResolveDirectoryAsync(string alias, string path, CancellationToken ct = default)
    {
        var args = BuildSshArguments(alias, interactive: false).ToList();
        args.Add($"cd -- {ShellQuotePath(path)} && pwd -P");
        var result = await RunAsync("ssh", args, TimeSpan.FromSeconds(20), ct);
        var resolved = result.StandardOutput.Trim();
        if (result.ExitCode != 0 || result.TimedOut || !resolved.StartsWith('/'))
            throw new InvalidOperationException(result.CombinedOutput.Length > 0 ? result.CombinedOutput : "The folder could not be resolved on the remote host.");
        return resolved;
    }

    public static async Task<IReadOnlyList<string>> ListDirectoriesAsync(string alias, string path, CancellationToken ct = default)
    {
        var args = BuildSshArguments(alias, interactive: false).ToList();
        args.Add($"find -- {ShellQuotePath(path)} -mindepth 1 -maxdepth 1 -type d -print");
        var result = await RunAsync("ssh", args, TimeSpan.FromSeconds(25), ct);
        if (result.TimedOut || result.ExitCode != 0)
            throw new InvalidOperationException(result.CombinedOutput.Length > 0 ? result.CombinedOutput : "Remote folders could not be listed.");
        return result.StandardOutput.Split('\n', StringSplitOptions.RemoveEmptyEntries)
            .Select(value => value.TrimEnd('\r'))
            .Where(value => value.StartsWith('/'))
            .OrderBy(value => Path.GetFileName(value), StringComparer.CurrentCultureIgnoreCase)
            .ToArray();
    }

    public static async Task<IReadOnlyList<SshHostKey>> ScanHostKeysAsync(SshHost host, CancellationToken ct = default)
    {
        var executable = FindExecutable("ssh-keyscan") ?? throw new InvalidOperationException("OpenSSH ssh-keyscan was not found on PATH.");
        var info = new ProcessStartInfo(executable) { UseShellExecute = false, RedirectStandardOutput = true, RedirectStandardError = true, CreateNoWindow = true };
        info.ArgumentList.Add("-T"); info.ArgumentList.Add("5");
        info.ArgumentList.Add("-p"); info.ArgumentList.Add(host.Port.ToString(System.Globalization.CultureInfo.InvariantCulture));
        info.ArgumentList.Add(host.HostName);
        using var process = Process.Start(info) ?? throw new InvalidOperationException("ssh-keyscan could not start.");
        var stdout = process.StandardOutput.ReadToEndAsync(ct);
        var stderr = process.StandardError.ReadToEndAsync(ct);
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct);
        timeout.CancelAfter(TimeSpan.FromSeconds(8));
        try { await process.WaitForExitAsync(timeout.Token); }
        catch (OperationCanceledException) { try { process.Kill(entireProcessTree: true); } catch { } if (ct.IsCancellationRequested) throw; }
        var output = await stdout;
        _ = await stderr;
        return output.Split('\n', StringSplitOptions.RemoveEmptyEntries)
            .Where(line => !line.StartsWith('#'))
            .Select(line => line.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries))
            .Where(parts => parts.Length >= 3)
            .Select(parts => new SshHostKey(parts[1], parts[2], Fingerprint(parts[2])))
            .Where(key => key.Fingerprint.Length > 0)
            .GroupBy(key => key.KeyType + " " + key.PublicKey, StringComparer.Ordinal)
            .Select(group => group.First())
            .ToArray();
    }

    public static void TrustScannedHostKeys(SshHost host, IReadOnlyList<SshHostKey> keys)
    {
        if (keys.Count == 0) throw new InvalidOperationException("No SSH host key was returned by the server.");
        Directory.CreateDirectory(SshDirectory);
        SetPrivateDirectoryMode();
        var hostToken = host.Port == 22 ? host.HostName : $"[{host.HostName}]:{host.Port}";
        var existing = FindKnownHostEntries(hostToken);
        var parsedExisting = existing
            .Select(line => line.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries))
            .Where(parts => parts.Length >= 3)
            .GroupBy(parts => parts[^2], StringComparer.Ordinal)
            .ToDictionary(group => group.Key, group => group.Select(parts => parts[^1]).ToArray(), StringComparer.Ordinal);
        foreach (var key in keys)
        {
            if (parsedExisting.TryGetValue(key.KeyType, out var storedKeys)
                && !storedKeys.Contains(key.PublicKey, StringComparer.Ordinal))
                throw new InvalidOperationException("A different key is already stored for this host. Review ~/.ssh/known_hosts before replacing it.");
        }
        var lines = keys
            .Where(key => !parsedExisting.ContainsKey(key.KeyType))
            .Select(key => key.KnownHostsLine(hostToken))
            .ToArray();
        if (lines.Length == 0) return;
        using (var stream = new FileStream(KnownHostsFile, FileMode.Append, FileAccess.Write, FileShare.Read))
        using (var writer = new StreamWriter(stream, new UTF8Encoding(false)))
        {
            if (stream.Length > 0) writer.WriteLine();
            writer.Write(string.Join(Environment.NewLine, lines));
        }
        SetPrivateMode(KnownHostsFile);
    }

    private static IReadOnlyList<string> FindKnownHostEntries(string hostToken)
    {
        var executable = FindExecutable("ssh-keygen");
        if (executable is null || !File.Exists(KnownHostsFile)) return [];
        var info = new ProcessStartInfo(executable) { UseShellExecute = false, RedirectStandardOutput = true, RedirectStandardError = true, CreateNoWindow = true };
        info.ArgumentList.Add("-F"); info.ArgumentList.Add(hostToken); info.ArgumentList.Add("-f"); info.ArgumentList.Add(KnownHostsFile);
        try
        {
            using var process = Process.Start(info);
            if (process is null) return [];
            var output = process.StandardOutput.ReadToEnd();
            process.WaitForExit(3000);
            return output.Split('\n', StringSplitOptions.RemoveEmptyEntries).Where(line => !line.StartsWith('#')).ToArray();
        }
        catch { return []; }
    }

    private static string Fingerprint(string publicKey)
    {
        try
        {
            var digest = SHA256.HashData(Convert.FromBase64String(publicKey));
            return "SHA256:" + Convert.ToBase64String(digest).TrimEnd('=');
        }
        catch { return ""; }
    }

    private static string ShellQuotePath(string path) => path == "~"
        ? "\"$HOME\""
        : path.StartsWith("~/", StringComparison.Ordinal)
            ? "\"$HOME\"/" + ShellQuote(path[2..])
            : ShellQuote(path);

    private static async Task<SshCommandResult> RunAsync(string executableName, IReadOnlyList<string> arguments, TimeSpan timeout, CancellationToken ct)
    {
        var executable = FindExecutable(executableName) ?? throw new InvalidOperationException($"{executableName} was not found on PATH.");
        var info = new ProcessStartInfo(executable)
        {
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true,
        };
        foreach (var argument in arguments) info.ArgumentList.Add(argument);
        using var process = Process.Start(info) ?? throw new InvalidOperationException($"{executableName} could not start.");
        using var timeoutSource = CancellationTokenSource.CreateLinkedTokenSource(ct);
        timeoutSource.CancelAfter(timeout);
        var stdout = process.StandardOutput.ReadToEndAsync(timeoutSource.Token);
        var stderr = process.StandardError.ReadToEndAsync(timeoutSource.Token);
        var timedOut = false;
        try { await process.WaitForExitAsync(timeoutSource.Token); }
        catch (OperationCanceledException)
        {
            timedOut = !ct.IsCancellationRequested;
            try { process.Kill(entireProcessTree: true); } catch { }
            if (ct.IsCancellationRequested) throw;
        }
        string outputText;
        string errorText;
        try { outputText = await stdout; } catch { outputText = ""; }
        try { errorText = await stderr; } catch { errorText = ""; }
        return new SshCommandResult(process.HasExited ? process.ExitCode : -1, outputText, errorText, timedOut);
    }

    private static string? FindExecutable(string name)
    {
        var path = Environment.GetEnvironmentVariable("PATH") ?? "";
        foreach (var directory in path.Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries))
        {
            var candidate = Path.Combine(directory.Trim('"'), OperatingSystem.IsWindows() && !name.EndsWith(".exe", StringComparison.OrdinalIgnoreCase) ? name + ".exe" : name);
            if (File.Exists(candidate)) return candidate;
        }
        return null;
    }

    private static bool IsSingleConfigToken(string value) => !value.StartsWith("-", StringComparison.Ordinal)
        && !value.Any(character => char.IsControl(character) || char.IsWhiteSpace(character) || character is '#' or '"');

    private static void WritePrivateFile(string path, string contents)
    {
        File.WriteAllText(path, contents, new UTF8Encoding(false));
        SetPrivateMode(path);
    }

    internal static void SetPrivateMode(string path)
    {
        if (OperatingSystem.IsWindows() || !File.Exists(path)) return;
        try { File.SetUnixFileMode(path, UnixFileMode.UserRead | UnixFileMode.UserWrite); } catch { }
    }

    internal static void SetPrivateDirectoryMode()
    {
        if (OperatingSystem.IsWindows() || !Directory.Exists(SshDirectory)) return;
        try { File.SetUnixFileMode(SshDirectory, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute); } catch { }
    }
}

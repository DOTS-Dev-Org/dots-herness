// Copyright (c) 2026 DOTS
// First-time SSH setup shared by the Windows and Linux desktop clients.

using System.Diagnostics;
using System.IO.Pipes;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;

namespace DotsHarnessCore;

public enum SshEnrollmentFailure
{
    PasswordAuthenticationDisabled,
    AuthenticationFailed,
    HostKeyChanged,
    TimedOut,
}

public sealed class SshEnrollmentException : Exception
{
    public SshEnrollmentFailure Failure { get; }

    public SshEnrollmentException(SshEnrollmentFailure failure, string message) : base(message) => Failure = failure;
}

public static class SshEnrollment
{
    private const string AskPassEndpointEnvironment = "DOTS_HARNESS_SSH_ASKPASS_ENDPOINT";
    private const string KeyName = "dots_harness_ed25519";
    private static string SshDirectory => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".ssh");
    private static string PrivateKeyPath => Path.Combine(SshDirectory, KeyName);
    private static string PublicKeyPath => PrivateKeyPath + ".pub";

    public static string IdentityFileReference => "~/.ssh/" + KeyName;

    public static string? ReadPublicKey()
    {
        try
        {
            var value = File.ReadAllText(PublicKeyPath, Encoding.UTF8).Trim();
            return IsEd25519PublicKey(value) ? value : null;
        }
        catch { return null; }
    }

    public static async Task<string> EnsureKeyPairAsync(CancellationToken ct = default)
    {
        Directory.CreateDirectory(SshDirectory);
        RemoteSsh.SetPrivateDirectoryMode();
        if (File.Exists(PrivateKeyPath) && File.Exists(PublicKeyPath) && ReadPublicKey() is { } existing)
        {
            RemoteSsh.SetPrivateMode(PrivateKeyPath);
            return existing;
        }

        // This fixed name is reserved for the app. A half-written app key is
        // safe to replace; user-created keys elsewhere are never touched.
        if (File.Exists(PrivateKeyPath)) File.Delete(PrivateKeyPath);
        if (File.Exists(PublicKeyPath)) File.Delete(PublicKeyPath);

        var keygen = FindExecutable("ssh-keygen")
            ?? throw new InvalidOperationException("OpenSSH ssh-keygen was not found on PATH.");
        var info = new ProcessStartInfo(keygen)
        {
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true,
        };
        info.ArgumentList.Add("-t"); info.ArgumentList.Add("ed25519");
        info.ArgumentList.Add("-N"); info.ArgumentList.Add(string.Empty);
        info.ArgumentList.Add("-C"); info.ArgumentList.Add("dotsharness@" + Environment.UserName);
        info.ArgumentList.Add("-f"); info.ArgumentList.Add(PrivateKeyPath);

        using var process = Process.Start(info) ?? throw new InvalidOperationException("ssh-keygen could not start.");
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct);
        timeout.CancelAfter(TimeSpan.FromSeconds(30));
        var stdout = process.StandardOutput.ReadToEndAsync();
        var stderr = process.StandardError.ReadToEndAsync();
        try { await process.WaitForExitAsync(timeout.Token).ConfigureAwait(false); }
        catch (OperationCanceledException)
        {
            try { process.Kill(entireProcessTree: true); } catch { }
            if (ct.IsCancellationRequested) throw;
            throw new TimeoutException("ssh-keygen did not finish within 30 seconds.");
        }

        var output = (await stdout.ConfigureAwait(false)) + (await stderr.ConfigureAwait(false));
        if (process.ExitCode != 0 || ReadPublicKey() is not { } generated)
            throw new InvalidOperationException(string.IsNullOrWhiteSpace(output) ? "ssh-keygen could not create an SSH key." : output.Trim());
        RemoteSsh.SetPrivateMode(PrivateKeyPath);
        RemoteSsh.SetPrivateMode(PublicKeyPath);
        return generated;
    }

    public static void TrustHostKeys(string alias, string hostName, string user, int port, IReadOnlyList<SshHostKey> keys)
    {
        if (keys.Count == 0) throw new InvalidOperationException("No SSH host key was returned by the server.");
        RemoteSsh.TrustScannedHostKeys(new SshHost(alias, hostName, user, port, ManagedByApp: true), keys);
    }

    public static async Task InstallPublicKeyAsync(
        string hostName,
        string user,
        int port,
        string password,
        string publicKey,
        CancellationToken ct = default)
    {
        if (!RemoteSsh.IsValidAlias("ssh-enrollment") || string.IsNullOrWhiteSpace(hostName) || string.IsNullOrWhiteSpace(user))
            throw new InvalidOperationException("Enter a host name and user name.");
        if (!IsEd25519PublicKey(publicKey)) throw new InvalidOperationException("The generated SSH public key is invalid.");
        if (port is < 1 or > 65535) throw new InvalidOperationException("The SSH port is invalid.");
        if (password.Length == 0) throw new InvalidOperationException("Enter the SSH password.");

        var ssh = FindExecutable("ssh") ?? throw new InvalidOperationException("OpenSSH ssh was not found on PATH.");
        var quotedKey = RemoteSsh.ShellQuote(publicKey);
        var remote = "umask 077; mkdir -p ~/.ssh && touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && "
            + $"if ! grep -Fqx -- {quotedKey} ~/.ssh/authorized_keys; then printf '%s\\n' {quotedKey} >> ~/.ssh/authorized_keys; fi && chmod 700 ~/.ssh";
        var info = new ProcessStartInfo(ssh)
        {
            UseShellExecute = false,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true,
        };
        foreach (var argument in new[]
        {
            "-o", "BatchMode=no",
            "-o", "PreferredAuthentications=password,keyboard-interactive",
            "-o", "PubkeyAuthentication=no",
            "-o", "NumberOfPasswordPrompts=1",
            "-o", "ConnectTimeout=10",
            "-o", "StrictHostKeyChecking=yes",
            "-o", "ControlMaster=no",
            "-p", port.ToString(System.Globalization.CultureInfo.InvariantCulture),
            "-l", user,
            "--", hostName,
            remote,
        }) info.ArgumentList.Add(argument);

        using var askPass = new SshAskPassEndpoint(password);
        askPass.Configure(info);
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct);
        timeout.CancelAfter(TimeSpan.FromSeconds(45));
        var sendPassword = askPass.SendOnceAsync(timeout.Token);
        var timedOut = false;
        var exitCode = -1;
        var output = "";
        try
        {
            using var process = Process.Start(info) ?? throw new InvalidOperationException("OpenSSH ssh could not start.");
            process.StandardInput.Close();
            var stdout = process.StandardOutput.ReadToEndAsync();
            var stderr = process.StandardError.ReadToEndAsync();
            try { await process.WaitForExitAsync(timeout.Token).ConfigureAwait(false); }
            catch (OperationCanceledException)
            {
                timedOut = !ct.IsCancellationRequested;
                try { process.Kill(entireProcessTree: true); } catch { }
                if (ct.IsCancellationRequested) throw;
                try { await process.WaitForExitAsync().ConfigureAwait(false); } catch { }
            }
            output = (await stdout.ConfigureAwait(false)) + "\n" + (await stderr.ConfigureAwait(false));
            if (process.HasExited) exitCode = process.ExitCode;
        }
        finally
        {
            timeout.Cancel();
            askPass.Dispose();
            try { await sendPassword.ConfigureAwait(false); } catch { }
        }

        var failure = Classify(output, timedOut);
        if (failure is { } kind) throw new SshEnrollmentException(kind, output.Trim());
        if (exitCode != 0) throw new InvalidOperationException(output.Trim());
    }

    /// <summary>
    /// The GUI executable is also OpenSSH's one-shot askpass program. Its
    /// parent exposes the password through a random, single-use local channel;
    /// neither the password nor a password-bearing helper file is persisted.
    /// </summary>
    public static bool TryServePasswordPrompt()
    {
        var endpoint = Environment.GetEnvironmentVariable(AskPassEndpointEnvironment);
        if (string.IsNullOrWhiteSpace(endpoint)) return false;
        Environment.SetEnvironmentVariable(AskPassEndpointEnvironment, null);
        try
        {
            byte[] secret;
            if (endpoint.StartsWith("unix:", StringComparison.Ordinal))
            {
                if (OperatingSystem.IsWindows()) return true;
                using var socket = new Socket(AddressFamily.Unix, SocketType.Stream, ProtocolType.Unspecified);
                socket.Connect(new UnixDomainSocketEndPoint(endpoint["unix:".Length..]));
                using var stream = new NetworkStream(socket, ownsSocket: false);
                using var data = new MemoryStream();
                stream.CopyTo(data);
                secret = data.ToArray();
            }
            else
            {
                using var pipe = new NamedPipeClientStream(".", endpoint, PipeDirection.In, PipeOptions.CurrentUserOnly);
                pipe.Connect(10_000);
                using var data = new MemoryStream();
                pipe.CopyTo(data);
                secret = data.ToArray();
            }

            var answer = new byte[secret.Length + 1];
            secret.CopyTo(answer, 0);
            answer[^1] = (byte)'\n';
            using var standardOutput = Console.OpenStandardOutput();
            standardOutput.Write(answer);
            standardOutput.Flush();
            CryptographicOperations.ZeroMemory(secret);
            CryptographicOperations.ZeroMemory(answer);
        }
        catch { /* OpenSSH reports a failed askpass response through stderr. */ }
        return true;
    }

    private static SshEnrollmentFailure? Classify(string output, bool timedOut)
    {
        if (timedOut) return SshEnrollmentFailure.TimedOut;
        var lower = output.ToLowerInvariant();
        if (lower.Contains("remote host identification has changed", StringComparison.Ordinal)
            || lower.Contains("host key verification failed", StringComparison.Ordinal)) return SshEnrollmentFailure.HostKeyChanged;
        if (lower.Contains("permission denied (publickey", StringComparison.Ordinal)
            || lower.Contains("no matching authentication methods", StringComparison.Ordinal)
            || lower.Contains("no supported authentication methods", StringComparison.Ordinal))
            return SshEnrollmentFailure.PasswordAuthenticationDisabled;
        if (lower.Contains("permission denied", StringComparison.Ordinal)) return SshEnrollmentFailure.AuthenticationFailed;
        return null;
    }

    private static bool IsEd25519PublicKey(string value) => value.StartsWith("ssh-ed25519 ", StringComparison.Ordinal)
        && value.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).Length >= 2;

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

    private sealed class SshAskPassEndpoint : IDisposable
    {
        private readonly byte[] _secret;
        private readonly string _endpoint;
        private readonly NamedPipeServerStream? _pipe;
        private readonly Socket? _listener;
        private readonly string? _privateDirectory;
        private bool _disposed;

        public SshAskPassEndpoint(string password)
        {
            _secret = Encoding.UTF8.GetBytes(password);
            if (OperatingSystem.IsWindows())
            {
                _endpoint = "dots-ssh-" + Convert.ToHexString(RandomNumberGenerator.GetBytes(24)).ToLowerInvariant();
                _pipe = new NamedPipeServerStream(_endpoint, PipeDirection.Out, 1, PipeTransmissionMode.Byte,
                    PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
                return;
            }

            _privateDirectory = Path.Combine(Path.GetTempPath(), "dots-ssh-" + Convert.ToHexString(RandomNumberGenerator.GetBytes(24)).ToLowerInvariant());
            Directory.CreateDirectory(_privateDirectory);
            File.SetUnixFileMode(_privateDirectory, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
            var socketPath = Path.Combine(_privateDirectory, "askpass.sock");
            _listener = new Socket(AddressFamily.Unix, SocketType.Stream, ProtocolType.Unspecified);
            _listener.Bind(new UnixDomainSocketEndPoint(socketPath));
            File.SetUnixFileMode(socketPath, UnixFileMode.UserRead | UnixFileMode.UserWrite);
            _listener.Listen(1);
            _endpoint = "unix:" + socketPath;
        }

        public void Configure(ProcessStartInfo info)
        {
            var app = Environment.ProcessPath;
            if (string.IsNullOrWhiteSpace(app)) throw new InvalidOperationException("The DotsHarness executable path is unavailable.");
            info.Environment["SSH_ASKPASS"] = app;
            info.Environment["SSH_ASKPASS_REQUIRE"] = "force";
            info.Environment[AskPassEndpointEnvironment] = _endpoint;
        }

        public async Task SendOnceAsync(CancellationToken ct)
        {
            if (_pipe is not null)
            {
                await _pipe.WaitForConnectionAsync(ct).ConfigureAwait(false);
                await _pipe.WriteAsync(_secret, ct).ConfigureAwait(false);
                await _pipe.FlushAsync(ct).ConfigureAwait(false);
                return;
            }

            if (_listener is null) return;
            using var client = await _listener.AcceptAsync(ct).ConfigureAwait(false);
            // Close the listening endpoint as soon as the sole response is
            // accepted. A second askpass invocation must fail promptly instead
            // of waiting in the socket backlog for a password we will not send.
            _listener.Dispose();
            using var stream = new NetworkStream(client, ownsSocket: false);
            await stream.WriteAsync(_secret.AsMemory(), ct).ConfigureAwait(false);
            await stream.FlushAsync(ct).ConfigureAwait(false);
        }

        public void Dispose()
        {
            if (_disposed) return;
            _disposed = true;
            CryptographicOperations.ZeroMemory(_secret);
            _pipe?.Dispose();
            _listener?.Dispose();
            if (_privateDirectory is not null)
            {
                try { Directory.Delete(_privateDirectory, recursive: true); } catch { }
            }
        }
    }
}

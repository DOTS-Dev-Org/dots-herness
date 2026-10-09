// Copyright (c) 2026 DOTS
// Long-lived shell process used by paired mobile terminals on Windows and Linux.

using System.Diagnostics;
using System.Text;

namespace DotsHarnessCore;

public sealed class RemoteInteractiveShell : IDisposable
{
    private readonly Process _process;
    private readonly CancellationTokenSource _lifetime = new();
    private readonly object _gate = new();
    private readonly StringBuilder _output = new();

    public string Id { get; } = Guid.NewGuid().ToString("N");
    public bool IsRunning
    {
        get { try { return !_process.HasExited; } catch (InvalidOperationException) { return false; } }
    }

    private RemoteInteractiveShell(string workspace)
    {
        if (!Directory.Exists(workspace)) throw new DirectoryNotFoundException($"Working directory does not exist: {workspace}");
        var start = new ProcessStartInfo
        {
            FileName = ShellPath(),
            WorkingDirectory = workspace,
            UseShellExecute = false,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8,
        };
        if (!OperatingSystem.IsWindows()) start.ArgumentList.Add("-i");
        else start.ArgumentList.Add("/Q");
        start.Environment["TERM"] = "dumb";
        _process = new Process { StartInfo = start, EnableRaisingEvents = true };
        if (!_process.Start()) throw new InvalidOperationException("The remote terminal process could not start.");
        _ = PumpAsync(_process.StandardOutput);
        _ = PumpAsync(_process.StandardError);
    }

    public static RemoteInteractiveShell Start(string workspace) => new(workspace);

    public async Task SendAsync(string input, CancellationToken cancellationToken = default)
    {
        if (!IsRunning) throw new InvalidOperationException("The remote terminal session has ended.");
        await _process.StandardInput.WriteAsync(input.AsMemory(), cancellationToken).ConfigureAwait(false);
        await _process.StandardInput.FlushAsync(cancellationToken).ConfigureAwait(false);
    }

    public void Send(string input)
    {
        if (!IsRunning) throw new InvalidOperationException("The remote terminal session has ended.");
        if (input.Contains('\u0003'))
        {
            _process.Kill(entireProcessTree: true);
            return;
        }
        _process.StandardInput.Write(input);
        _process.StandardInput.Flush();
    }

    public string ReadOutput()
    {
        lock (_gate) return _output.ToString();
    }

    private async Task PumpAsync(StreamReader reader)
    {
        var buffer = new char[2048];
        try
        {
            while (!_lifetime.IsCancellationRequested)
            {
                var read = await reader.ReadAsync(buffer.AsMemory(), _lifetime.Token).ConfigureAwait(false);
                if (read == 0) return;
                lock (_gate)
                {
                    _output.Append(buffer, 0, read);
                    if (_output.Length > 200_000)
                    {
                        var excess = _output.Length - 180_000;
                        _output.Remove(0, excess);
                    }
                }
            }
        }
        catch (OperationCanceledException) { }
        catch (ObjectDisposedException) { }
    }

    public void Dispose()
    {
        _lifetime.Cancel();
        try { if (!_process.HasExited) _process.Kill(entireProcessTree: true); } catch { }
        try { _process.StandardInput.Close(); } catch { }
        try { _process.Dispose(); } catch { }
        _lifetime.Dispose();
    }

    private static string ShellPath()
    {
        if (OperatingSystem.IsWindows()) return Environment.GetEnvironmentVariable("ComSpec") ?? "cmd.exe";
        var candidate = Environment.GetEnvironmentVariable("SHELL");
        if (!string.IsNullOrWhiteSpace(candidate) && File.Exists(candidate)) return candidate;
        return File.Exists("/bin/bash") ? "/bin/bash" : "/bin/sh";
    }
}

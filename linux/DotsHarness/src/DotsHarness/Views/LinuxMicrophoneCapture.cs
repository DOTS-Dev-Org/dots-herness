using System.Diagnostics;

namespace DotsHarness.Views;

/// <summary>Uses the first available native Linux capture utility and emits raw 16 kHz mono PCM16.</summary>
public sealed class LinuxMicrophoneCapture : IDisposable
{
    private Process? _process;
    private CancellationTokenSource? _cancel;
    private Task? _reader;

    public event Action<ReadOnlyMemory<byte>>? DataAvailable;
    public bool IsRunning => _process is { HasExited: false };

    public void Start()
    {
        Stop();
        var command = Commands.FirstOrDefault(item => FindOnPath(item.Name) is not null);
        if (command is null) throw new InvalidOperationException("No microphone capture utility found. Install pw-record, parec, or arecord.");

        var process = new Process
        {
            StartInfo = new ProcessStartInfo
            {
                FileName = FindOnPath(command.Name)!,
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
            },
        };
        foreach (var argument in command.Arguments) process.StartInfo.ArgumentList.Add(argument);
        if (!process.Start()) throw new InvalidOperationException($"Could not start {command.Name}.");
        _process = process;
        _cancel = new CancellationTokenSource();
        _reader = Task.Run(() => ReadLoopAsync(process, _cancel.Token));
    }

    public void Stop()
    {
        var process = _process;
        _process = null;
        _cancel?.Cancel();
        _cancel = null;
        if (process is null) return;
        try { if (!process.HasExited) process.Kill(entireProcessTree: true); } catch { }
        try { process.Dispose(); } catch { }
        _reader = null;
    }

    public void Dispose() => Stop();

    private async Task ReadLoopAsync(Process process, CancellationToken ct)
    {
        var buffer = new byte[4_096];
        try
        {
            while (!ct.IsCancellationRequested)
            {
                var read = await process.StandardOutput.BaseStream.ReadAsync(buffer.AsMemory(), ct).ConfigureAwait(false);
                if (read <= 0) break;
                var copy = buffer[..read].ToArray();
                DataAvailable?.Invoke(copy.AsMemory());
            }
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested) { }
        catch (ObjectDisposedException) { }
    }

    private static string? FindOnPath(string name)
    {
        var path = Environment.GetEnvironmentVariable("PATH") ?? "";
        return path.Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries)
            .Select(directory => Path.Combine(directory, name))
            .FirstOrDefault(File.Exists);
    }

    private static readonly CaptureCommand[] Commands =
    {
        new("pw-record", new[] { "--rate", "16000", "--channels", "1", "--format", "s16", "-" }),
        new("parec", new[] { "--raw", "--format=s16le", "--rate=16000", "--channels=1" }),
        new("arecord", new[] { "-q", "-t", "raw", "-f", "S16_LE", "-r", "16000", "-c", "1" }),
    };

    private sealed record CaptureCommand(string Name, string[] Arguments);
}

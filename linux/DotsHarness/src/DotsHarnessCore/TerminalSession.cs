// Copyright (c) 2026 DOTS
// Linux native pseudo-terminal session.

using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace DotsHarnessCore;

public sealed class TerminalSession : IDisposable
{
    private const int Sighup = 1;
    private const int Sigterm = 15;

    private readonly object _gate = new();
    private readonly string _workingDirectory;
    private FileStream? _master;
    private CancellationTokenSource? _readCancellation;
    private int _childPid;
    private long _generation;
    private string _output = "";
    private bool _isRunning;

    public TerminalSession(string workingDirectory) => _workingDirectory = workingDirectory;

    public event EventHandler? Changed;

    public string Output
    {
        get { lock (_gate) return _output; }
    }

    public bool IsRunning
    {
        get { lock (_gate) return _isRunning; }
    }

    public void Start()
    {
        Stop();

        if (!Directory.Exists(_workingDirectory))
        {
            SetMessage($"Working directory does not exist: {_workingDirectory}");
            return;
        }

        var shell = Environment.GetEnvironmentVariable("SHELL");
        if (string.IsNullOrWhiteSpace(shell) || !File.Exists(shell)) shell = "/bin/bash";

        var shellPointer = IntPtr.Zero;
        var namePointer = IntPtr.Zero;
        var loginPointer = IntPtr.Zero;
        var interactivePointer = IntPtr.Zero;
        var argumentsPointer = IntPtr.Zero;
        try
        {
            shellPointer = Marshal.StringToCoTaskMemUTF8(shell);
            namePointer = Marshal.StringToCoTaskMemUTF8(Path.GetFileName(shell));
            loginPointer = Marshal.StringToCoTaskMemUTF8("-l");
            interactivePointer = Marshal.StringToCoTaskMemUTF8("-i");
            argumentsPointer = Marshal.AllocHGlobal(IntPtr.Size * 4);
            Marshal.WriteIntPtr(argumentsPointer, 0 * IntPtr.Size, namePointer);
            Marshal.WriteIntPtr(argumentsPointer, 1 * IntPtr.Size, loginPointer);
            Marshal.WriteIntPtr(argumentsPointer, 2 * IntPtr.Size, interactivePointer);
            Marshal.WriteIntPtr(argumentsPointer, 3 * IntPtr.Size, IntPtr.Zero);

            var size = new WinSize { Rows = 24, Columns = 120 };
            var childPid = forkpty(out var masterFd, IntPtr.Zero, IntPtr.Zero, ref size);
            if (childPid == 0)
            {
                if (chdir(_workingDirectory) != 0) _exit(126);
                setenv("TERM", "xterm-256color", 1);
                setenv("TERM_PROGRAM", "DotsHarness", 1);
                setenv("COLORTERM", "truecolor", 1);
                _ = execv(shellPointer, argumentsPointer);
                _exit(127);
            }

            if (childPid < 0)
            {
                SetMessage($"Terminal unavailable: {Marshal.GetLastPInvokeError()}");
                return;
            }

            var master = new FileStream(
                new SafeFileHandle((IntPtr)masterFd, ownsHandle: true),
                FileAccess.ReadWrite,
                bufferSize: 4096,
                isAsync: true);
            CancellationTokenSource cancellation;
            long generation;
            lock (_gate)
            {
                _master = master;
                _childPid = childPid;
                _isRunning = true;
                _output = "";
                generation = ++_generation;
                cancellation = new CancellationTokenSource();
                _readCancellation = cancellation;
            }
            RaiseChanged();
            _ = ReadOutputAsync(master, childPid, generation, cancellation.Token);
            _ = ReapChildAsync(childPid, generation);
        }
        catch (Exception error)
        {
            SetMessage($"Terminal unavailable: {error.Message}");
        }
        finally
        {
            if (shellPointer != IntPtr.Zero) Marshal.FreeCoTaskMem(shellPointer);
            if (namePointer != IntPtr.Zero) Marshal.FreeCoTaskMem(namePointer);
            if (loginPointer != IntPtr.Zero) Marshal.FreeCoTaskMem(loginPointer);
            if (interactivePointer != IntPtr.Zero) Marshal.FreeCoTaskMem(interactivePointer);
            if (argumentsPointer != IntPtr.Zero) Marshal.FreeHGlobal(argumentsPointer);
        }
    }

    public void Send(string command) => SendInput(command + "\r");

    public void SendInput(string input)
    {
        if (string.IsNullOrEmpty(input)) return;
        var bytes = Encoding.UTF8.GetBytes(input);
        try
        {
            lock (_gate)
            {
                if (!_isRunning || _master is null) return;
                _master.Write(bytes, 0, bytes.Length);
                _master.Flush();
            }
        }
        catch (Exception error)
        {
            SetMessage($"Terminal write failed: {error.Message}");
        }
    }

    public void Stop()
    {
        CancellationTokenSource? cancellation;
        FileStream? master;
        int childPid;
        var changed = false;
        lock (_gate)
        {
            cancellation = _readCancellation;
            _readCancellation = null;
            master = _master;
            _master = null;
            childPid = _childPid;
            _childPid = 0;
            changed = _isRunning;
            _isRunning = false;
            _generation++;
        }

        cancellation?.Cancel();
        if (childPid > 0)
        {
            _ = kill(-childPid, Sighup);
            _ = kill(childPid, Sigterm);
        }
        try { master?.Dispose(); } catch { }
        cancellation?.Dispose();
        if (changed) RaiseChanged();
    }

    public void Dispose() => Stop();

    private async Task ReadOutputAsync(FileStream master, int childPid, long generation, CancellationToken token)
    {
        try
        {
            using var reader = new StreamReader(master, new UTF8Encoding(false), detectEncodingFromByteOrderMarks: false, 4096, leaveOpen: true);
            var buffer = new char[4096];
            while (true)
            {
                var count = await reader.ReadAsync(buffer.AsMemory(), token).ConfigureAwait(false);
                if (count == 0) break;
                Append(new string(buffer, 0, count), generation);
            }
        }
        catch (OperationCanceledException) { }
        catch (IOException) { }
        catch (ObjectDisposedException) { }
        finally
        {
            Complete(childPid, generation);
        }
    }

    private async Task ReapChildAsync(int childPid, long generation)
    {
        await Task.Run(() => waitpid(childPid, out _, 0)).ConfigureAwait(false);
        Complete(childPid, generation);
    }

    private void Complete(int childPid, long generation)
    {
        var changed = false;
        lock (_gate)
        {
            if (_generation != generation || _childPid != childPid) return;
            _childPid = 0;
            _isRunning = false;
            changed = true;
        }
        if (changed) RaiseChanged();
    }

    private void SetMessage(string message)
    {
        lock (_gate)
        {
            _output = message + Environment.NewLine;
            _isRunning = false;
        }
        RaiseChanged();
    }

    private void Append(string text, long generation)
    {
        if (string.IsNullOrEmpty(text)) return;
        lock (_gate)
        {
            if (_generation != generation) return;
            _output = TranscriptText(_output + RenderableText(text));
            if (_output.Length > 200_000) _output = _output[^180_000..];
        }
        RaiseChanged();
    }

    private void RaiseChanged() => Changed?.Invoke(this, EventArgs.Empty);

    private static string RenderableText(string text)
    {
        // ponytail: strip control sequences; add a full terminal emulator only for TUI fidelity.
        var result = new StringBuilder(text.Length);
        for (var index = 0; index < text.Length; index++)
        {
            var value = text[index];
            if (value == '\u001b')
            {
                if (++index >= text.Length) break;
                var control = text[index];
                if (control == '[')
                {
                    while (++index < text.Length && !(text[index] >= '@' && text[index] <= '~')) { }
                }
                else if (control == ']')
                {
                    while (++index < text.Length)
                    {
                        if (text[index] == '\a') break;
                        if (text[index] == '\u001b' && index + 1 < text.Length && text[index + 1] == '\\')
                        {
                            index++;
                            break;
                        }
                    }
                }
                continue;
            }

            if (value is '\r' or '\b' or '\t' or '\n' || value >= ' ')
                result.Append(value);
        }
        return result.ToString();
    }

    private static string TranscriptText(string raw)
    {
        var result = new StringBuilder(raw.Length);
        for (var index = 0; index < raw.Length; index++)
        {
            switch (raw[index])
            {
                case '\r' when index + 1 >= raw.Length || raw[index + 1] != '\n':
                    while (result.Length > 0 && result[result.Length - 1] != '\n') result.Length--;
                    break;
                case '\b' when result.Length > 0:
                    result.Length--;
                    break;
                default:
                    result.Append(raw[index]);
                    break;
            }
        }

        var lines = result.ToString().Split('\n');
        for (var index = 0; index < lines.Length; index++) lines[index] = lines[index].TrimEnd(' ', '\t');
        return string.Join('\n', lines);
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct WinSize
    {
        public ushort Rows;
        public ushort Columns;
        public ushort XPixels;
        public ushort YPixels;
    }

    [DllImport("libutil.so.1", SetLastError = true)]
    private static extern int forkpty(out int master, IntPtr name, IntPtr termp, ref WinSize windowSize);

    [DllImport("libc.so.6", SetLastError = true)]
    private static extern int chdir([MarshalAs(UnmanagedType.LPUTF8Str)] string path);

    [DllImport("libc.so.6", SetLastError = true)]
    private static extern int setenv(
        [MarshalAs(UnmanagedType.LPUTF8Str)] string name,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string value,
        int overwrite);

    [DllImport("libc.so.6", SetLastError = true)]
    private static extern int execv(IntPtr path, IntPtr arguments);

    [DllImport("libc.so.6", SetLastError = true)]
    private static extern int waitpid(int pid, out int status, int options);

    [DllImport("libc.so.6", SetLastError = true)]
    private static extern int kill(int pid, int signal);

    [DllImport("libc.so.6", SetLastError = true)]
    private static extern void _exit(int status);
}

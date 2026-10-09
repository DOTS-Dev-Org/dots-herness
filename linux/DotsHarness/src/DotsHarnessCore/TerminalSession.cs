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
    private const int TranscriptLimit = 200_000;
    private const int TranscriptTrimTo = 180_000;

    // A shell at 4 KB per read can produce dozens of chunks a second. Repainting
    // the transcript for each one re-lays out up to 200 KB of text, so change
    // events are coalesced to this interval instead.
    private const int RefreshIntervalMs = 50;

    private enum EscapeState
    {
        None,
        AfterEscape,
        ControlSequence,
        OperatingString,
        OperatingStringEscape,
    }

    private readonly object _gate = new();
    private readonly string _workingDirectory;
    private readonly SshTarget? _remoteTarget;
    private readonly bool _sandboxed;
    private readonly IReadOnlyList<string> _sandboxWritableRoots;
    private readonly bool _sandboxNetworkAccess;
    private readonly StringBuilder _transcript = new();
    private FileStream? _master;
    private CancellationTokenSource? _readCancellation;
    private int _childPid;
    private long _generation;
    private int _lineStart;
    private bool _pendingCarriageReturn;
    private EscapeState _escape;
    private string? _renderedOutput;
    private bool _refreshScheduled;
    private bool _isRunning;

    public TerminalSession(
        string workingDirectory,
        SshTarget? remoteTarget = null,
        bool sandboxed = false,
        IReadOnlyList<string>? sandboxWritableRoots = null,
        bool sandboxNetworkAccess = false)
    {
        _workingDirectory = workingDirectory;
        _remoteTarget = remoteTarget;
        _sandboxed = sandboxed && remoteTarget is null;
        _sandboxWritableRoots = sandboxWritableRoots?.ToArray() ?? [];
        _sandboxNetworkAccess = sandboxNetworkAccess;
    }

    public event EventHandler? Changed;

    public string Output
    {
        get { lock (_gate) return _renderedOutput ??= RenderTranscript(); }
    }

    public bool IsRunning
    {
        get { lock (_gate) return _isRunning; }
    }

    public void Start()
    {
        Stop();

        if (_remoteTarget is null && !Directory.Exists(_workingDirectory))
        {
            SetMessage($"Working directory does not exist: {_workingDirectory}");
            return;
        }

        var shell = Environment.GetEnvironmentVariable("SHELL");
        if (string.IsNullOrWhiteSpace(shell) || !File.Exists(shell)) shell = "/bin/bash";

        var executablePointer = IntPtr.Zero;
        var argumentsPointer = IntPtr.Zero;
        var argumentStringPointers = new List<IntPtr>();
        try
        {
            var isRemote = _remoteTarget is not null;
            var executable = isRemote
                ? RemoteSsh.FindSshExecutable() ?? throw new InvalidOperationException("OpenSSH was not found on PATH.")
                : shell;
            var arguments = isRemote
                ? RemoteSsh.BuildTerminalArguments(_remoteTarget!).ToArray()
                : new[] { "-l", "-i" };
            if (_sandboxed)
            {
                var sandboxInfo = new System.Diagnostics.ProcessStartInfo
                {
                    WorkingDirectory = _workingDirectory,
                    UseShellExecute = false,
                };
                if (!AgentCommandSandbox.TryConfigure(
                        sandboxInfo,
                        _workingDirectory,
                        out var sandboxError,
                        _sandboxWritableRoots,
                        _sandboxNetworkAccess,
                        newSession: false))
                {
                    SetMessage("Terminal unavailable: " + sandboxError);
                    return;
                }
                sandboxInfo.ArgumentList.RemoveAt(sandboxInfo.ArgumentList.Count - 1); // -lc
                sandboxInfo.ArgumentList.RemoveAt(sandboxInfo.ArgumentList.Count - 1); // /bin/sh
                sandboxInfo.ArgumentList.Add(shell);
                sandboxInfo.ArgumentList.Add("-l");
                sandboxInfo.ArgumentList.Add("-i");
                executable = sandboxInfo.FileName;
                arguments = sandboxInfo.ArgumentList.ToArray();
            }
            executablePointer = Marshal.StringToCoTaskMemUTF8(executable);
            var argumentPointers = new List<IntPtr> { Marshal.StringToCoTaskMemUTF8(Path.GetFileName(executable)) };
            argumentStringPointers.AddRange(argumentPointers);
            foreach (var argument in arguments) argumentStringPointers.Add(Marshal.StringToCoTaskMemUTF8(argument));
            argumentsPointer = Marshal.AllocHGlobal(IntPtr.Size * (argumentStringPointers.Count + 1));
            for (var index = 0; index < argumentStringPointers.Count; index++)
                Marshal.WriteIntPtr(argumentsPointer, index * IntPtr.Size, argumentStringPointers[index]);
            Marshal.WriteIntPtr(argumentsPointer, argumentStringPointers.Count * IntPtr.Size, IntPtr.Zero);

            var size = new WinSize { Rows = 24, Columns = 120 };
            var childPid = forkpty(out var masterFd, IntPtr.Zero, IntPtr.Zero, ref size);
            if (childPid == 0)
            {
                if (!isRemote && chdir(_workingDirectory) != 0) _exit(126);
                setenv("TERM", "xterm-256color", 1);
                setenv("TERM_PROGRAM", "DotsHarness", 1);
                setenv("COLORTERM", "truecolor", 1);
                _ = execv(executablePointer, argumentsPointer);
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
                ResetTranscript();
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
            if (executablePointer != IntPtr.Zero) Marshal.FreeCoTaskMem(executablePointer);
            foreach (var pointer in argumentStringPointers) Marshal.FreeCoTaskMem(pointer);
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
            FlushPendingCarriageReturn();
            _renderedOutput = RenderTranscript();
            changed = true;
        }
        if (changed) RaiseChanged();
    }

    private void SetMessage(string message)
    {
        lock (_gate)
        {
            ResetTranscript();
            _transcript.Append(message).Append(Environment.NewLine);
            _lineStart = _transcript.Length;
            _isRunning = false;
            _renderedOutput = _transcript.ToString();
        }
        RaiseChanged();
    }

    private void ResetTranscript()
    {
        _transcript.Clear();
        _lineStart = 0;
        _pendingCarriageReturn = false;
        _escape = EscapeState.None;
        _renderedOutput = null;
    }

    private void Append(string text, long generation)
    {
        if (string.IsNullOrEmpty(text)) return;
        lock (_gate)
        {
            if (_generation != generation) return;
            for (var index = 0; index < text.Length; index++) Feed(text[index]);
            if (_transcript.Length > TranscriptLimit)
            {
                var removed = _transcript.Length - TranscriptTrimTo;
                _transcript.Remove(0, removed);
                _lineStart = _lineStart > removed ? _lineStart - removed : 0;
            }
            _renderedOutput = null;
        }
        ScheduleRefresh();
    }

    // Consumes one raw character. The parser is resumable across read chunks:
    // an escape sequence or a CRLF pair that straddles a chunk boundary used to
    // be re-parsed from the whole transcript, which made every append linear in
    // the transcript size — quadratic for a build that prints megabytes.
    private void Feed(char value)
    {
        switch (_escape)
        {
            case EscapeState.None:
                if (value == '\u001b') _escape = EscapeState.AfterEscape;
                else if (value is '\r' or '\b' or '\t' or '\n' || value >= ' ') Render(value);
                return;
            case EscapeState.AfterEscape:
                _escape = value switch
                {
                    '[' => EscapeState.ControlSequence,
                    ']' => EscapeState.OperatingString,
                    _ => EscapeState.None,
                };
                return;
            case EscapeState.ControlSequence:
                if (value >= '@' && value <= '~') _escape = EscapeState.None;
                return;
            case EscapeState.OperatingString:
                if (value == '\a') _escape = EscapeState.None;
                else if (value == '\u001b') _escape = EscapeState.OperatingStringEscape;
                return;
            case EscapeState.OperatingStringEscape:
                _escape = value == '\\' ? EscapeState.None : EscapeState.OperatingString;
                return;
        }
    }

    private void Render(char value)
    {
        if (_pendingCarriageReturn)
        {
            _pendingCarriageReturn = false;
            if (value == '\n') _transcript.Append('\r');
            else _transcript.Length = _lineStart;
        }

        switch (value)
        {
            case '\r':
                _pendingCarriageReturn = true;
                return;
            case '\n':
                // Completed lines lose trailing blanks, except CRLF lines, whose
                // terminator sits after the spaces.
                if (_transcript.Length > _lineStart && _transcript[^1] != '\r')
                {
                    while (_transcript.Length > _lineStart && _transcript[^1] is ' ' or '\t') _transcript.Length--;
                }
                _transcript.Append('\n');
                _lineStart = _transcript.Length;
                return;
            case '\b':
                if (_transcript.Length == 0)
                {
                    _transcript.Append('\b');
                    return;
                }
                var erased = _transcript[^1];
                _transcript.Length--;
                if (erased == '\n')
                {
                    var index = _transcript.Length - 1;
                    while (index >= 0 && _transcript[index] != '\n') index--;
                    _lineStart = index + 1;
                }
                return;
            default:
                _transcript.Append(value);
                return;
        }
    }

    private void FlushPendingCarriageReturn()
    {
        if (!_pendingCarriageReturn) return;
        _pendingCarriageReturn = false;
        _transcript.Length = _lineStart;
    }

    private string RenderTranscript()
    {
        var length = _transcript.Length;
        while (length > _lineStart && _transcript[length - 1] is ' ' or '\t') length--;
        return length == _transcript.Length ? _transcript.ToString() : _transcript.ToString(0, length);
    }

    private void ScheduleRefresh()
    {
        lock (_gate)
        {
            if (_refreshScheduled) return;
            _refreshScheduled = true;
        }
        _ = RaiseRefreshAsync();
    }

    private async Task RaiseRefreshAsync()
    {
        await Task.Delay(RefreshIntervalMs).ConfigureAwait(false);
        lock (_gate) _refreshScheduled = false;
        RaiseChanged();
    }

    private void RaiseChanged() => Changed?.Invoke(this, EventArgs.Empty);

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

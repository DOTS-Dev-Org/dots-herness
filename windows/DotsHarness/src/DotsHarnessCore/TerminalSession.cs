// Copyright (c) 2026 DOTS
// Windows native ConPTY session.

using System.Runtime.InteropServices;
using System.Text;
using System.ComponentModel;
using Microsoft.Win32.SafeHandles;

namespace DotsHarnessCore;

public sealed class TerminalSession : IDisposable
{
    private const uint ExtendedStartupInfoPresent = 0x0008_0000;
    private const uint CreateUnicodeEnvironment = 0x0000_0400;
    private static readonly IntPtr ProcThreadAttributePseudoConsole = (IntPtr)0x0002_0016;
    private static readonly Encoding Utf8 = new UTF8Encoding(encoderShouldEmitUTF8Identifier: false);

    private readonly object _gate = new();
    private readonly string _workingDirectory;
    private FileStream? _input;
    private FileStream? _output;
    private IntPtr _pseudoConsole;
    private IntPtr _processHandle;
    private long _generation;
    private string _outputText = "";
    private bool _isRunning;

    public TerminalSession(string workingDirectory) => _workingDirectory = workingDirectory;

    public event EventHandler? Changed;

    public string Output
    {
        get { lock (_gate) return _outputText; }
    }

    public bool IsRunning
    {
        get { lock (_gate) return _isRunning; }
    }

    public void Start()
    {
        Stop();
        lock (_gate)
        {
            _outputText = "";
            _generation++;
        }

        if (!Directory.Exists(_workingDirectory))
        {
            SetMessage($"Working directory does not exist: {_workingDirectory}");
            return;
        }

        try
        {
            StartConPty();
        }
        catch (Exception error)
        {
            SetMessage($"Terminal unavailable: {error.Message}");
        }
    }

    public void Send(string command) => SendInput(command + "\r");

    public void SendInput(string input)
    {
        if (string.IsNullOrEmpty(input)) return;
        var bytes = Utf8.GetBytes(input);
        try
        {
            lock (_gate)
            {
                if (!_isRunning || _input is null) return;
                _input.Write(bytes, 0, bytes.Length);
                _input.Flush();
            }
        }
        catch (Exception error)
        {
            Append($"\r\nTerminal write failed: {error.Message}\r\n");
        }
    }

    public void Stop()
    {
        FileStream? input;
        FileStream? output;
        IntPtr pseudoConsole;
        IntPtr processHandle;
        var changed = false;
        lock (_gate)
        {
            _generation++;
            input = _input;
            output = _output;
            pseudoConsole = _pseudoConsole;
            processHandle = _processHandle;
            _input = null;
            _output = null;
            _pseudoConsole = IntPtr.Zero;
            _processHandle = IntPtr.Zero;
            changed = _isRunning;
            _isRunning = false;
        }

        try { input?.Dispose(); } catch { }
        try { output?.Dispose(); } catch { }
        if (processHandle != IntPtr.Zero)
        {
            _ = TerminateProcess(processHandle, 1);
            CloseHandle(processHandle);
        }
        if (pseudoConsole != IntPtr.Zero) ClosePseudoConsole(pseudoConsole);
        if (changed) RaiseChanged();
    }

    public void Dispose() => Stop();

    private void StartConPty()
    {
        IntPtr inputRead = IntPtr.Zero;
        IntPtr inputWrite = IntPtr.Zero;
        IntPtr outputRead = IntPtr.Zero;
        IntPtr outputWrite = IntPtr.Zero;
        IntPtr pseudoConsole = IntPtr.Zero;
        IntPtr processHandle = IntPtr.Zero;
        IntPtr threadHandle = IntPtr.Zero;
        IntPtr attributeList = IntPtr.Zero;
        var attributesInitialized = false;

        try
        {
            if (!CreatePipe(out inputRead, out inputWrite, IntPtr.Zero, 0)) ThrowLastError("CreatePipe");
            if (!CreatePipe(out outputRead, out outputWrite, IntPtr.Zero, 0)) ThrowLastError("CreatePipe");

            var result = CreatePseudoConsole(
                new Coord { X = 120, Y = 24 },
                inputRead,
                outputWrite,
                0,
                out pseudoConsole);
            if (result != 0) throw new Win32Exception(result, "CreatePseudoConsole failed");

            CloseHandle(inputRead);
            inputRead = IntPtr.Zero;
            CloseHandle(outputWrite);
            outputWrite = IntPtr.Zero;

            var attributeBytes = IntPtr.Zero;
            _ = InitializeProcThreadAttributeList(IntPtr.Zero, 1, 0, ref attributeBytes);
            if (attributeBytes == IntPtr.Zero) ThrowLastError("InitializeProcThreadAttributeList");
            attributeList = Marshal.AllocHGlobal(attributeBytes);
            if (!InitializeProcThreadAttributeList(attributeList, 1, 0, ref attributeBytes))
                ThrowLastError("InitializeProcThreadAttributeList");
            attributesInitialized = true;

            if (!UpdateProcThreadAttribute(
                    attributeList,
                    0,
                    ProcThreadAttributePseudoConsole,
                    pseudoConsole,
                    (IntPtr)IntPtr.Size,
                    IntPtr.Zero,
                    IntPtr.Zero))
            {
                ThrowLastError("UpdateProcThreadAttribute");
            }

            var startup = new StartupInfoEx
            {
                StartupInfo = new StartupInfo
                {
                    cb = Marshal.SizeOf<StartupInfoEx>(),
                },
                lpAttributeList = attributeList,
            };
            var shell = Environment.GetEnvironmentVariable("ComSpec")
                ?? Path.Combine(Environment.SystemDirectory, "cmd.exe");
            var commandLine = new StringBuilder($"\"{shell}\" /Q /K \"chcp 65001>nul & prompt $P$G\"");
            if (!CreateProcess(
                    shell,
                    commandLine,
                    IntPtr.Zero,
                    IntPtr.Zero,
                    false,
                    ExtendedStartupInfoPresent | CreateUnicodeEnvironment,
                    IntPtr.Zero,
                    _workingDirectory,
                    ref startup,
                    out var processInformation))
            {
                ThrowLastError("CreateProcess");
            }

            processHandle = processInformation.Process;
            threadHandle = processInformation.Thread;
            CloseHandle(threadHandle);
            threadHandle = IntPtr.Zero;

            var input = new FileStream(
                new SafeFileHandle(inputWrite, ownsHandle: true),
                FileAccess.Write,
                bufferSize: 4096,
                isAsync: false);
            inputWrite = IntPtr.Zero;
            var output = new FileStream(
                new SafeFileHandle(outputRead, ownsHandle: true),
                FileAccess.Read,
                bufferSize: 4096,
                isAsync: false);
            outputRead = IntPtr.Zero;

            long generation;
            lock (_gate)
            {
                _input = input;
                _output = output;
                _pseudoConsole = pseudoConsole;
                _processHandle = processHandle;
                _isRunning = true;
                generation = _generation;
            }
            var processForWait = processHandle;
            pseudoConsole = IntPtr.Zero;
            processHandle = IntPtr.Zero;
            RaiseChanged();
            _ = ReadOutputAsync(output, generation);
            _ = WaitForExitAsync(processForWait, generation);
        }
        finally
        {
            if (attributesInitialized) DeleteProcThreadAttributeList(attributeList);
            if (attributeList != IntPtr.Zero) Marshal.FreeHGlobal(attributeList);
            CloseHandle(inputRead);
            CloseHandle(inputWrite);
            CloseHandle(outputRead);
            CloseHandle(outputWrite);
            if (threadHandle != IntPtr.Zero) CloseHandle(threadHandle);
            if (processHandle != IntPtr.Zero) CloseHandle(processHandle);
            if (pseudoConsole != IntPtr.Zero) ClosePseudoConsole(pseudoConsole);
        }
    }

    private async Task ReadOutputAsync(FileStream output, long generation)
    {
        try
        {
            using var reader = new StreamReader(output, Utf8, detectEncodingFromByteOrderMarks: false, 4096, leaveOpen: true);
            var buffer = new char[4096];
            while (true)
            {
                var count = await reader.ReadAsync(buffer.AsMemory()).ConfigureAwait(false);
                if (count == 0) break;
                Append(new string(buffer, 0, count), generation);
            }
        }
        catch (IOException) { }
        catch (ObjectDisposedException) { }
        finally
        {
            Complete(generation);
        }
    }

    private async Task WaitForExitAsync(IntPtr processHandle, long generation)
    {
        await Task.Run(() => WaitForSingleObject(processHandle, uint.MaxValue)).ConfigureAwait(false);
        Complete(generation);
    }

    private void Complete(long generation)
    {
        FileStream? input = null;
        FileStream? output = null;
        IntPtr pseudoConsole = IntPtr.Zero;
        IntPtr processHandle = IntPtr.Zero;
        lock (_gate)
        {
            if (_generation != generation || !_isRunning) return;
            input = _input;
            output = _output;
            pseudoConsole = _pseudoConsole;
            processHandle = _processHandle;
            _input = null;
            _output = null;
            _pseudoConsole = IntPtr.Zero;
            _processHandle = IntPtr.Zero;
            _isRunning = false;
        }
        try { input?.Dispose(); } catch { }
        try { output?.Dispose(); } catch { }
        if (processHandle != IntPtr.Zero) CloseHandle(processHandle);
        if (pseudoConsole != IntPtr.Zero) ClosePseudoConsole(pseudoConsole);
        RaiseChanged();
    }

    private void SetMessage(string message)
    {
        lock (_gate)
        {
            _outputText = message + Environment.NewLine;
            _isRunning = false;
        }
        RaiseChanged();
    }

    private void Append(string text, long? generation = null)
    {
        if (string.IsNullOrEmpty(text)) return;
        lock (_gate)
        {
            if (generation is not null && _generation != generation.Value) return;
            _outputText = TranscriptText(_outputText + RenderableText(text));
            if (_outputText.Length > 200_000) _outputText = _outputText[^180_000..];
        }
        RaiseChanged();
    }

    private static void ThrowLastError(string operation) =>
        throw new Win32Exception(Marshal.GetLastWin32Error(), $"{operation} failed");

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
    private struct Coord
    {
        public short X;
        public short Y;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct StartupInfo
    {
        public int cb;
        public IntPtr lpReserved;
        public IntPtr lpDesktop;
        public IntPtr lpTitle;
        public int dwX;
        public int dwY;
        public int dwXSize;
        public int dwYSize;
        public int dwXCountChars;
        public int dwYCountChars;
        public int dwFillAttribute;
        public int dwFlags;
        public short wShowWindow;
        public short cbReserved2;
        public IntPtr lpReserved2;
        public IntPtr hStdInput;
        public IntPtr hStdOutput;
        public IntPtr hStdError;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct StartupInfoEx
    {
        public StartupInfo StartupInfo;
        public IntPtr lpAttributeList;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct ProcessInformation
    {
        public IntPtr Process;
        public IntPtr Thread;
        public int ProcessId;
        public int ThreadId;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CreatePipe(out IntPtr readPipe, out IntPtr writePipe, IntPtr attributes, int size);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern int CreatePseudoConsole(Coord size, IntPtr input, IntPtr output, uint flags, out IntPtr pseudoConsole);

    [DllImport("kernel32.dll")]
    private static extern void ClosePseudoConsole(IntPtr pseudoConsole);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr handle);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool TerminateProcess(IntPtr process, uint exitCode);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool InitializeProcThreadAttributeList(
        IntPtr attributeList,
        uint attributeCount,
        uint flags,
        ref IntPtr size);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool UpdateProcThreadAttribute(
        IntPtr attributeList,
        uint flags,
        IntPtr attribute,
        IntPtr value,
        IntPtr size,
        IntPtr previousValue,
        IntPtr returnSize);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern void DeleteProcThreadAttributeList(IntPtr attributeList);

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool CreateProcess(
        string applicationName,
        [In, Out] StringBuilder commandLine,
        IntPtr processAttributes,
        IntPtr threadAttributes,
        bool inheritHandles,
        uint creationFlags,
        IntPtr environment,
        string currentDirectory,
        ref StartupInfoEx startupInfo,
        out ProcessInformation processInformation);
}

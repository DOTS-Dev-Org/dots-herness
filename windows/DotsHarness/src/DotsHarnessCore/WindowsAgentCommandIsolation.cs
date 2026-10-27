// Copyright (c) 2026 DOTS
// Windows agent command isolation. Commands run in an AppContainer with no capabilities,
// so they have no network, and they can write only where this runner granted the AppContainer
// SID: the sandbox worktree and its git metadata. Ancestor folders get traverse-only access.
// A probe must pass before the first command. If it does not, every command fails closed.
// Not verified on a Windows host yet; the probe is the guard until it is.

using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace DotsHarnessCore;

public sealed class WindowsAppContainerIsolation : IAgentCommandIsolation
{
    private const string ProfileName = "DotsHarness.AgentCommand";
    private const int ErrorAlreadyExists = unchecked((int)0x800700B7);
    private const uint CreateNoWindow = 0x08000000;
    private const uint ExtendedStartupInfoPresent = 0x00080000;
    private const uint StartfUseStdHandles = 0x00000100;
    private const uint HandleFlagInherit = 0x00000001;
    private const uint GenericRead = 0x80000000;
    private const uint FileShareReadWrite = 0x00000003;
    private const uint OpenExisting = 3;
    private const uint FileAllAccess = 0x001F01FF;
    private const uint FileTraverse = 0x00000020;
    /// Every write right, used to keep a path read-only for the sandbox SID.
    private const uint WriteDenyMask = 0x000D0156;
    /// FILE_DELETE_CHILD | WRITE_DAC | WRITE_OWNER, denied on a git metadata dir.
    private const uint MetadataRootDenyMask = 0x000C0040;
    private const int DenyAccess = 2;
    private const int RevokeAccess = 3;
    private const uint DaclSecurityInformation = 0x00000004;
    private const int SeFileObject = 1;
    private const int GrantAccess = 1;
    private const uint InheritObjectAndContainer = 0x3;
    private const int TrusteeIsSid = 0;
    private const int TrusteeIsUnknown = 0;
    private const uint WaitTimeout = 0x102;
    private const uint Infinite = 0xFFFFFFFF;
    private static readonly IntPtr ProcThreadAttributeSecurityCapabilities = (IntPtr)0x00020009;
    private static readonly IntPtr ProcThreadAttributeHandleList = (IntPtr)0x00020002;

    private readonly object _gate = new();
    private readonly HashSet<string> _granted = new(StringComparer.OrdinalIgnoreCase);
    /// Every ACL entry this runner added, so Release() can take it back.
    private readonly List<AppliedAce> _applied = new();
    private IntPtr _sid;
    private Task<bool>? _probe;
    private string? _probeError;

    private sealed record AppliedAce(string Path, uint Access, bool Inherit, int Mode);

    public string? Unavailable(string workspace, IReadOnlyList<string> writableRoots, bool networkAccess)
    {
        if (!OperatingSystem.IsWindows()) return "Windows process isolation is unavailable on this platform.";
        // AppContainer grants network only through capabilities, which this runner does not hand out.
        if (networkAccess) return "Agent commands run without network access on Windows; network-enabled sandboxes are not supported here.";
        // Only sandbox worktrees carry git-metadata roots. Granting ACLs on a user's own project folder is out of scope.
        if (writableRoots.Count == 0) return "Windows command isolation runs only inside a sandbox worktree.";
        lock (_gate)
        {
            if (_probe is { IsCompleted: true } && _probe.Result is false)
            {
                return $"Windows process isolation failed its self-test: {_probeError}";
            }
        }
        return null;
    }

    private static readonly TimeSpan ProbeLimit = TimeSpan.FromSeconds(45);


    public async Task<IsolatedCommandResult> RunAsync(
        string command,
        string workspace,
        IReadOnlyList<string> writableRoots,
        Action<string>? onOutput,
        TimeSpan timeout,
        CancellationToken ct)
    {
        if (!await ProbeAsync(ct))
        {
            return new IsolatedCommandResult(null, "", "", false, $"Windows process isolation failed its self-test: {_probeError}");
        }
        var roots = new List<string> { Path.GetFullPath(workspace) };
        roots.AddRange(writableRoots.Select(Path.GetFullPath));
        return await Task.Run(() => Execute(command, Path.GetFullPath(workspace), roots, onOutput, timeout, ct), ct);
    }

    private Task<bool> ProbeAsync(CancellationToken ct)
    {
        lock (_gate)
        {
            _probe ??= Task.Run(RunProbe);
            return _probe;
        }
    }

    /// Writes inside a granted folder must succeed and a write outside must be refused.
    private bool RunProbe()
    {
        var probeRoot = Path.Combine(Path.GetTempPath(), "DotsHarnessIsolationProbe-" + Guid.NewGuid().ToString("N"));
        var outside = Path.Combine(Path.GetTempPath(), "DotsHarnessIsolationOutside-" + Guid.NewGuid().ToString("N") + ".txt");
        try
        {
            Directory.CreateDirectory(probeRoot);
            var inside = Path.Combine(probeRoot, "inside.txt");
            var insideExit = Execute($"echo ok > \"{inside}\"", probeRoot, [probeRoot], null, ProbeLimit, CancellationToken.None).ExitCode;
            var outsideExit = Execute($"echo no > \"{outside}\"", probeRoot, [probeRoot], null, ProbeLimit, CancellationToken.None).ExitCode;
            if (File.Exists(outside))
            {
                File.Delete(outside);
                _probeError = "a probe command wrote outside its granted folder";
                return false;
            }
            if (insideExit != 0 || !File.Exists(inside))
            {
                _probeError = $"the sandboxed shell could not write its own worktree (exit {insideExit})";
                return false;
            }
            if (outsideExit == 0)
            {
                _probeError = "a probe command reported success for a write outside its granted folder";
                return false;
            }
            return true;
        }
        catch (Exception error)
        {
            _probeError = error.Message;
            return false;
        }
        finally
        {
            try { Directory.Delete(probeRoot, recursive: true); } catch (IOException) { } catch (UnauthorizedAccessException) { }
        }
    }

    private IsolatedCommandResult Execute(string command, string workingDirectory, IReadOnlyList<string> roots, Action<string>? onOutput, TimeSpan timeout, CancellationToken ct)
    {
        try
        {
            lock (_gate)
            {
                var sid = ProfileSid();
                foreach (var root in roots) GrantTree(root, sid);
                DenyGitMetadata(roots, sid);
            }
        }
        catch (Exception error) when (error is Win32Exception or System.Runtime.InteropServices.COMException or IOException or InvalidOperationException or UnauthorizedAccessException)
        {
            return new IsolatedCommandResult(null, "", "", false, $"Windows process isolation could not set up access, so the command did not run: {error.Message}");
        }

        var stdoutRead = CreateInheritableRead(out var stdoutWrite);
        var stderrRead = CreateInheritableRead(out var stderrWrite);
        var nul = OpenNul();
        IntPtr attributes = IntPtr.Zero;
        IntPtr capabilities = IntPtr.Zero;
        IntPtr handles = IntPtr.Zero;
        var readersStarted = false;
        try
        {
            var capabilityValue = new SecurityCapabilities { AppContainerSid = _sid };
            capabilities = Marshal.AllocHGlobal(Marshal.SizeOf<SecurityCapabilities>());
            Marshal.StructureToPtr(capabilityValue, capabilities, fDeleteOld: false);

            handles = Marshal.AllocHGlobal(IntPtr.Size * 3);
            Marshal.WriteIntPtr(handles, 0, nul);
            Marshal.WriteIntPtr(handles, IntPtr.Size, stdoutWrite);
            Marshal.WriteIntPtr(handles, IntPtr.Size * 2, stderrWrite);

            var size = IntPtr.Zero;
            InitializeProcThreadAttributeList(IntPtr.Zero, 2, 0, ref size);
            attributes = Marshal.AllocHGlobal(size);
            if (!InitializeProcThreadAttributeList(attributes, 2, 0, ref size)) throw new Win32Exception(Marshal.GetLastWin32Error());
            if (!UpdateProcThreadAttribute(attributes, 0, ProcThreadAttributeSecurityCapabilities, capabilities, (IntPtr)Marshal.SizeOf<SecurityCapabilities>(), IntPtr.Zero, IntPtr.Zero))
                throw new Win32Exception(Marshal.GetLastWin32Error());
            if (!UpdateProcThreadAttribute(attributes, 0, ProcThreadAttributeHandleList, handles, (IntPtr)(IntPtr.Size * 3), IntPtr.Zero, IntPtr.Zero))
                throw new Win32Exception(Marshal.GetLastWin32Error());

            var startup = new StartupInfoEx
            {
                StartupInfo = new StartupInfo
                {
                    cb = (uint)Marshal.SizeOf<StartupInfoEx>(),
                    dwFlags = StartfUseStdHandles,
                    hStdInput = nul,
                    hStdOutput = stdoutWrite,
                    hStdError = stderrWrite,
                },
                lpAttributeList = attributes,
            };
            var commandLine = new StringBuilder($"cmd.exe /d /s /c \"{command}\"");
            if (!CreateProcessW(null, commandLine, IntPtr.Zero, IntPtr.Zero, true,
                    ExtendedStartupInfoPresent | CreateNoWindow, IntPtr.Zero, workingDirectory, ref startup, out var info))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            CloseHandle(info.hThread);
            // The parent keeps only the read ends, so the readers see end-of-file when the command exits.
            CloseHandle(stdoutWrite);
            CloseHandle(stderrWrite);
            CloseHandle(nul);
            stdoutWrite = stderrWrite = nul = IntPtr.Zero;

            var stdout = new StringBuilder();
            var stderr = new StringBuilder();
            readersStarted = true;
            var started = DateTime.UtcNow;
            var deadline = started + timeout;
            var sawSwiftPmLock = 0;
            void ForwardOutput(string line)
            {
                if (NativeWorkspaceTools.IsSwiftPmLockMessage(line)) Interlocked.Exchange(ref sawSwiftPmLock, 1);
                onOutput?.Invoke(line);
            }
            var outputTask = Task.Run(() => ReadAll(stdoutRead, stdout, ForwardOutput));
            var errorTask = Task.Run(() => ReadAll(stderrRead, stderr, ForwardOutput));
            var timedOut = false;
            while (WaitForSingleObject(info.hProcess, 100) == WaitTimeout)
            {
                if (Volatile.Read(ref sawSwiftPmLock) != 0)
                {
                    var lockDeadline = started + TimeSpan.FromSeconds(NativeWorkspaceTools.MaxCommandTimeout);
                    if (lockDeadline > deadline) deadline = lockDeadline;
                }
                if (ct.IsCancellationRequested || DateTime.UtcNow > deadline)
                {
                    timedOut = !ct.IsCancellationRequested;
                    KillTree(info.dwProcessId, info.hProcess);
                    break;
                }
            }
            WaitForSingleObject(info.hProcess, 5000);
            GetExitCodeProcess(info.hProcess, out var exitCode);
            CloseHandle(info.hProcess);
            Task.WaitAll([outputTask, errorTask], TimeSpan.FromSeconds(5));
            ct.ThrowIfCancellationRequested();
            return new IsolatedCommandResult((int)exitCode, stdout.ToString(), stderr.ToString(), timedOut);
        }
        catch (Exception error) when (error is Win32Exception or System.Runtime.InteropServices.COMException or IOException or InvalidOperationException)
        {
            return new IsolatedCommandResult(null, "", "", false, $"The command could not start in the isolated shell: {error.Message}");
        }
        finally
        {
            if (!readersStarted)
            {
                CloseHandle(stdoutRead);
                CloseHandle(stderrRead);
            }
            if (attributes != IntPtr.Zero)
            {
                DeleteProcThreadAttributeList(attributes);
                Marshal.FreeHGlobal(attributes);
            }
            if (capabilities != IntPtr.Zero) Marshal.FreeHGlobal(capabilities);
            if (handles != IntPtr.Zero) Marshal.FreeHGlobal(handles);
            foreach (var handle in new[] { stdoutWrite, stderrWrite, nul }) if (handle != IntPtr.Zero) CloseHandle(handle);
        }
    }

    private static void KillTree(uint processId, IntPtr processHandle)
    {
        try
        {
            using var process = Process.GetProcessById((int)processId);
            process.Kill(entireProcessTree: true);
        }
        catch (ArgumentException)
        {
            // The command already exited.
        }
        catch (InvalidOperationException)
        {
        }
        catch (Win32Exception)
        {
            TerminateProcess(processHandle, 1);
        }
    }

    private static void ReadAll(IntPtr handle, StringBuilder target, Action<string>? onOutput)
    {
        using var stream = new FileStream(new SafeFileHandle(handle, ownsHandle: true), FileAccess.Read, 4096, isAsync: false);
        // cmd.exe writes in the console code page, not UTF-8.
        using var reader = new StreamReader(stream, Console.OutputEncoding);
        string? line;
        while ((line = reader.ReadLine()) is not null)
        {
            target.Append(line).Append('\n');
            onOutput?.Invoke(line);
        }
    }

    private static IntPtr CreateInheritableRead(out IntPtr write)
    {
        var attributes = new SecurityAttributes { nLength = Marshal.SizeOf<SecurityAttributes>(), bInheritHandle = true };
        if (!CreatePipe(out var read, out write, ref attributes, 0)) throw new Win32Exception(Marshal.GetLastWin32Error());
        if (!SetHandleInformation(read, HandleFlagInherit, 0)) throw new Win32Exception(Marshal.GetLastWin32Error());
        return read;
    }

    private static IntPtr OpenNul()
    {
        var attributes = new SecurityAttributes { nLength = Marshal.SizeOf<SecurityAttributes>(), bInheritHandle = true };
        var handle = CreateFileW("NUL", GenericRead, FileShareReadWrite, ref attributes, OpenExisting, 0, IntPtr.Zero);
        if (handle == new IntPtr(-1)) throw new Win32Exception(Marshal.GetLastWin32Error());
        return handle;
    }

    /// Caller holds _gate.
    private IntPtr ProfileSid()
    {
        if (_sid != IntPtr.Zero) return _sid;
        var hresult = CreateAppContainerProfile(ProfileName, "DotsHarness", "Agent command isolation", IntPtr.Zero, 0, out var sid);
        if (hresult == ErrorAlreadyExists)
        {
            hresult = DeriveAppContainerSidFromAppContainerName(ProfileName, out sid);
        }
        Marshal.ThrowExceptionForHR(hresult);
        _sid = sid;
        return sid;
    }

    /// Grants the AppContainer full access to `path` (inherited) and traverse-only access to each ancestor.
    private void GrantTree(string path, IntPtr sid)
    {
        var ancestor = Path.GetDirectoryName(path);
        while (!string.IsNullOrEmpty(ancestor) && Path.GetPathRoot(ancestor) != ancestor)
        {
            GrantOnce(ancestor, FileTraverse, inherit: false, sid);
            ancestor = Path.GetDirectoryName(ancestor);
        }
        GrantOnce(path, FileAllAccess, inherit: true, sid);
    }

    /// Git metadata that can execute code stays read-only for the sandbox SID.
    /// A rewritten hook or config would run on the user's next git command,
    /// outside the sandbox this runner is supposed to enforce.
    /// A path that cannot be denied throws, and Execute refuses to run the command.
    private void DenyGitMetadata(IReadOnlyList<string> roots, IntPtr sid)
    {
        // ProtectedPaths lists only paths that exist, and the sandbox could create a
        // missing one (a fresh hooks dir, config.worktree). Create them empty first
        // so each one gets its deny entry. Empty hooks and config change nothing for git.
        foreach (var root in roots.Where(GitMetadataGuards.IsGitMetadataDirectory))
        {
            // The inherited full grant includes FILE_DELETE_CHILD, which lets a child be
            // deleted or renamed despite its own DELETE deny, and WRITE_DAC, which could
            // strip these deny entries. Take both away on the metadata dir itself only;
            // git still replaces index, refs and lock files through their own DELETE right.
            GrantOnce(root, MetadataRootDenyMask, inherit: false, sid, DenyAccess);
            Directory.CreateDirectory(Path.Combine(root, "hooks"));
            foreach (var name in new[] { "config", "config.worktree" })
            {
                using var _ = new FileStream(Path.Combine(root, name), FileMode.OpenOrCreate, FileAccess.Write);
            }
        }
        foreach (var path in GitMetadataGuards.ProtectedPaths(roots))
        {
            GrantOnce(path, WriteDenyMask, inherit: Directory.Exists(path), sid, DenyAccess);
        }
    }

    /// Gives back every permission this runner granted. Without it the
    /// AppContainer SID keeps full access to the user's workspace and git
    /// metadata for the rest of the session.
    public void Release()
    {
        lock (_gate)
        {
            foreach (var ace in Enumerable.Reverse(_applied))
            {
                try { RevokeAce(ace); }
                catch { /* best effort: the entry is gone either way */ }
            }
            _applied.Clear();
            _granted.Clear();
        }
    }

    /// Caller holds _gate.
    private void RevokeAce(AppliedAce ace)
    {
        var status = GetNamedSecurityInfoW(ace.Path, SeFileObject, DaclSecurityInformation, out _, out _, out var dacl, out _, out var descriptor);
        if (status != 0) return;
        try
        {
            var entry = new ExplicitAccess
            {
                grfAccessPermissions = ace.Access,
                grfAccessMode = RevokeAccess,
                grfInheritance = 0,
                Trustee = new Trustee { TrusteeForm = TrusteeIsSid, TrusteeType = TrusteeIsUnknown, ptstrName = _sid },
            };
            status = SetEntriesInAclW(1, ref entry, dacl, out var merged);
            if (status != 0) return;
            try
            {
                SetNamedSecurityInfoW(ace.Path, SeFileObject, DaclSecurityInformation, IntPtr.Zero, IntPtr.Zero, merged, IntPtr.Zero);
            }
            finally
            {
                LocalFree(merged);
            }
        }
        finally
        {
            LocalFree(descriptor);
        }
    }

    /// Caller holds _gate.
    private void GrantOnce(string path, uint access, bool inherit, IntPtr sid, int mode = GrantAccess)
    {
        var key = $"{mode}:{access:X}:{path}";
        if (_granted.Contains(key)) return;
        var status = GetNamedSecurityInfoW(path, SeFileObject, DaclSecurityInformation, out _, out _, out var dacl, out _, out var descriptor);
        if (status != 0) throw new Win32Exception((int)status);
        try
        {
            var entry = new ExplicitAccess
            {
                grfAccessPermissions = access,
                grfAccessMode = mode,
                grfInheritance = inherit ? InheritObjectAndContainer : 0,
                Trustee = new Trustee { TrusteeForm = TrusteeIsSid, TrusteeType = TrusteeIsUnknown, ptstrName = sid },
            };
            status = SetEntriesInAclW(1, ref entry, dacl, out var merged);
            if (status != 0) throw new Win32Exception((int)status);
            try
            {
                status = SetNamedSecurityInfoW(path, SeFileObject, DaclSecurityInformation, IntPtr.Zero, IntPtr.Zero, merged, IntPtr.Zero);
                if (status != 0) throw new Win32Exception((int)status);
            }
            finally
            {
                LocalFree(merged);
            }
            // Recorded only after the ACL is set, so a failed path is retried next command.
            _granted.Add(key);
            _applied.Add(new AppliedAce(path, access, inherit, mode));
        }
        finally
        {
            LocalFree(descriptor);
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct SecurityCapabilities
    {
        public IntPtr AppContainerSid;
        public IntPtr Capabilities;
        public uint CapabilityCount;
        public uint Reserved;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct SecurityAttributes
    {
        public int nLength;
        public IntPtr lpSecurityDescriptor;
        public bool bInheritHandle;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct StartupInfo
    {
        public uint cb;
        public string? lpReserved;
        public string? lpDesktop;
        public string? lpTitle;
        public uint dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
        public ushort wShowWindow;
        public ushort cbReserved2;
        public IntPtr lpReserved2;
        public IntPtr hStdInput;
        public IntPtr hStdOutput;
        public IntPtr hStdError;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct StartupInfoEx
    {
        public StartupInfo StartupInfo;
        public IntPtr lpAttributeList;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct ProcessInformation
    {
        public IntPtr hProcess;
        public IntPtr hThread;
        public uint dwProcessId;
        public uint dwThreadId;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct Trustee
    {
        public IntPtr pMultipleTrustee;
        public int MultipleTrusteeOperation;
        public int TrusteeForm;
        public int TrusteeType;
        public IntPtr ptstrName;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct ExplicitAccess
    {
        public uint grfAccessPermissions;
        public int grfAccessMode;
        public uint grfInheritance;
        public Trustee Trustee;
    }

    [DllImport("userenv.dll", CharSet = CharSet.Unicode, PreserveSig = true)]
    private static extern int CreateAppContainerProfile(string pszAppContainerName, string pszDisplayName, string pszDescription, IntPtr pCapabilities, uint dwCapabilityCount, out IntPtr ppSidAppContainerSid);

    [DllImport("userenv.dll", CharSet = CharSet.Unicode, PreserveSig = true)]
    private static extern int DeriveAppContainerSidFromAppContainerName(string pszAppContainerName, out IntPtr ppsidAppContainerSid);

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern uint GetNamedSecurityInfoW(string pObjectName, int objectType, uint securityInfo, out IntPtr ppsidOwner, out IntPtr ppsidGroup, out IntPtr ppDacl, out IntPtr ppSacl, out IntPtr ppSecurityDescriptor);

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern uint SetNamedSecurityInfoW(string pObjectName, int objectType, uint securityInfo, IntPtr psidOwner, IntPtr psidGroup, IntPtr pDacl, IntPtr pSacl);

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern uint SetEntriesInAclW(uint cCountOfExplicitEntries, ref ExplicitAccess pListOfExplicitEntries, IntPtr oldAcl, out IntPtr newAcl);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr LocalFree(IntPtr hMem);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CreatePipe(out IntPtr hReadPipe, out IntPtr hWritePipe, ref SecurityAttributes lpPipeAttributes, uint nSize);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetHandleInformation(IntPtr hObject, uint dwMask, uint dwFlags);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateFileW(string lpFileName, uint dwDesiredAccess, uint dwShareMode, ref SecurityAttributes lpSecurityAttributes, uint dwCreationDisposition, uint dwFlagsAndAttributes, IntPtr hTemplateFile);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool InitializeProcThreadAttributeList(IntPtr lpAttributeList, int dwAttributeCount, int dwFlags, ref IntPtr lpSize);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool UpdateProcThreadAttribute(IntPtr lpAttributeList, uint dwFlags, IntPtr attribute, IntPtr lpValue, IntPtr cbSize, IntPtr lpPreviousValue, IntPtr lpReturnSize);

    [DllImport("kernel32.dll")]
    private static extern void DeleteProcThreadAttributeList(IntPtr lpAttributeList);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CreateProcessW(string? lpApplicationName, StringBuilder lpCommandLine, IntPtr lpProcessAttributes, IntPtr lpThreadAttributes, bool bInheritHandles, uint dwCreationFlags, IntPtr lpEnvironment, string lpCurrentDirectory, ref StartupInfoEx lpStartupInfo, out ProcessInformation lpProcessInformation);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint WaitForSingleObject(IntPtr hHandle, uint dwMilliseconds);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetExitCodeProcess(IntPtr hProcess, out uint lpExitCode);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool TerminateProcess(IntPtr hProcess, uint uExitCode);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr hObject);
}

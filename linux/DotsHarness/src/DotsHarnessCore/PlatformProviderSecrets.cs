using System.Diagnostics;
using System.Security.Cryptography;
using System.Text;

namespace DotsHarnessCore;

/// Uses Secret Service when the desktop exposes secret-tool. If it is not
/// available, credentials use a user-only 700/600 fallback directory so device
/// pairing survives a desktop restart without making secrets world-readable.
public sealed class PlatformProviderSecrets : IProviderSecretStore
{
    private const UnixFileMode PrivateDirectoryMode = UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute;
    private const UnixFileMode PrivateFileMode = UnixFileMode.UserRead | UnixFileMode.UserWrite;
    private readonly string _fallbackRoot;
    /// Absolute location of the real secret-tool, resolved once per process.
    /// Resolving it through PATH would let anything on the user's PATH steal
    /// every provider key: the helper reads the plaintext secret from stdin.
    private static readonly Lazy<string?> SecretToolPath = new(ResolveSecretTool);
    private static readonly string? _secretTool = SecretToolPath.Value;
    private static bool Available => _secretTool is not null;

    public PlatformProviderSecrets(string root)
    {
        _fallbackRoot = Path.Combine(root, "provider-secrets");
        Directory.CreateDirectory(_fallbackRoot, PrivateDirectoryMode);
        EnsureMode(_fallbackRoot, PrivateDirectoryMode, "provider secret directory");
    }

    public string? Read(string id)
    {
        if (!Available)
        {
            var path = PathFor(id);
            if (!File.Exists(path)) return null;
            EnsureMode(path, PrivateFileMode, "provider secret file");
            try { return File.ReadAllText(path); }
            catch { return null; }
        }
        try
        {
            using var process = Start("lookup", "service", "dots-harness", "account", id);
            var output = process.StandardOutput.ReadToEnd();
            process.WaitForExit(3000);
            return process.ExitCode == 0 ? output.TrimEnd('\r', '\n') : null;
        }
        catch { return null; }
    }

    public void Write(string id, string value)
    {
        if (!Available)
        {
            var path = PathFor(id);
            var temporary = path + ".part-" + Guid.NewGuid().ToString("N");
            try
            {
                WritePrivateFile(temporary, value);
                File.Move(temporary, path, true);
                EnsureMode(path, PrivateFileMode, "provider secret file");
            }
            finally
            {
                try { if (File.Exists(temporary)) File.Delete(temporary); } catch { }
            }
            return;
        }
        using var process = Start("store", "--label=Dots Harness provider credential", "service", "dots-harness", "account", id);
        process.StandardInput.Write(value);
        process.StandardInput.Close();
        process.WaitForExit(5000);
        if (process.ExitCode != 0) throw new NativeProviderException("The desktop credential service is unavailable.");
    }

    public void Delete(string id)
    {
        if (!Available) { try { File.Delete(PathFor(id)); } catch { } return; }
        try { using var process = Start("clear", "service", "dots-harness", "account", id); process.WaitForExit(3000); } catch { }
    }

    private string PathFor(string id) => Path.Combine(_fallbackRoot, Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(id))).ToLowerInvariant());

    private static void WritePrivateFile(string path, string value)
    {
        using var stream = new FileStream(path, new FileStreamOptions
        {
            Access = FileAccess.Write,
            Mode = FileMode.CreateNew,
            Options = FileOptions.SequentialScan,
            Share = FileShare.None,
            UnixCreateMode = PrivateFileMode,
        });
        var bytes = new UTF8Encoding(false).GetBytes(value);
        stream.Write(bytes);
        stream.Flush(flushToDisk: true);
        EnsureMode(path, PrivateFileMode, "temporary provider secret file");
    }

    private static void EnsureMode(string path, UnixFileMode expected, string description)
    {
        try
        {
            File.SetUnixFileMode(path, expected);
            if (File.GetUnixFileMode(path) != expected)
            {
                throw new IOException($"The {description} does not have mode {expected}.");
            }
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or PlatformNotSupportedException)
        {
            throw new NativeProviderException($"The {description} could not be protected: {error.Message}");
        }
    }

    private static Process Start(params string[] args)
    {
        var tool = _secretTool ?? throw new InvalidOperationException("secret-tool is unavailable");
        var info = new ProcessStartInfo(tool)
        {
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
        };
        foreach (var arg in args) info.ArgumentList.Add(arg);
        return Process.Start(info) ?? throw new InvalidOperationException("secret-tool could not start");
    }

    /// <summary>
    /// Finds the system secret-tool without consulting PATH. Only the two
    /// standard locations are accepted, and the binary and its directory must
    /// not be writable by anyone but their owner — a helper the user can
    /// replace is a helper that can read every secret this app stores.
    /// </summary>
    private static string? ResolveSecretTool()
    {
        const UnixFileMode worldWritable = UnixFileMode.GroupWrite | UnixFileMode.OtherWrite;
        foreach (var path in new[] { "/usr/bin/secret-tool", "/bin/secret-tool" })
        {
            try
            {
                if (!File.Exists(path)) continue;
                if ((File.GetUnixFileMode(path) & worldWritable) != 0) continue;
                var directory = Path.GetDirectoryName(path);
                if (string.IsNullOrEmpty(directory)) continue;
                if ((File.GetUnixFileMode(directory) & worldWritable) != 0) continue;
                return path;
            }
            catch { }
        }
        return null;
    }
}

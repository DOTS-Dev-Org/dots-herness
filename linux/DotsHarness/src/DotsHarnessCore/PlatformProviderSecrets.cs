using System.Diagnostics;
using System.Security.Cryptography;
using System.Text;

namespace DotsHarnessCore;

/// Uses Secret Service when the desktop exposes secret-tool. If it is not
/// available, credentials use a user-only 700/600 fallback directory so device
/// pairing survives a desktop restart without making secrets world-readable.
public sealed class PlatformProviderSecrets : IProviderSecretStore
{
    private readonly string _fallbackRoot;
    private readonly bool _available = CommandExists("secret-tool");

    public PlatformProviderSecrets(string root)
    {
        _fallbackRoot = Path.Combine(root, "provider-secrets");
        Directory.CreateDirectory(_fallbackRoot);
        // ponytail: best-effort 700; race ~ms between mkdir and chmod but chmod verified
        if (!TrySetMode(_fallbackRoot, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute))
        {
            // Platform without UnixFileMode (e.g. older runtime) — fallback dir inherits parent ACL, still user-private under ~/.local/share
        }
    }

    public string? Read(string id)
    {
        if (!_available)
        {
            try { return File.Exists(PathFor(id)) ? File.ReadAllText(PathFor(id)) : null; }
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
        if (!_available)
        {
            var path = PathFor(id);
            var temporary = path + ".part-" + Guid.NewGuid().ToString("N");
            File.WriteAllText(temporary, value, new UTF8Encoding(false));
            TrySetMode(temporary, UnixFileMode.UserRead | UnixFileMode.UserWrite);
            File.Move(temporary, path, true);
            // Ensure final file is 600 even if Move didn't preserve mode
            TrySetMode(path, UnixFileMode.UserRead | UnixFileMode.UserWrite);
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
        if (!_available) { try { File.Delete(PathFor(id)); } catch { } return; }
        try { using var process = Start("clear", "service", "dots-harness", "account", id); process.WaitForExit(3000); } catch { }
    }

    private string PathFor(string id) => Path.Combine(_fallbackRoot, Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(id))).ToLowerInvariant());

    private static bool TrySetMode(string path, UnixFileMode mode)
    {
        try { File.SetUnixFileMode(path, mode); return true; } catch { return false; }
    }

    private static Process Start(params string[] args)
    {
        var info = new ProcessStartInfo("secret-tool")
        {
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
        };
        foreach (var arg in args) info.ArgumentList.Add(arg);
        return Process.Start(info) ?? throw new InvalidOperationException("secret-tool could not start");
    }

    private static bool CommandExists(string command)
    {
        try { using var process = Process.Start(new ProcessStartInfo("sh", $"-c 'command -v {command}'") { RedirectStandardOutput = true, UseShellExecute = false }); process?.WaitForExit(1000); return process?.ExitCode == 0; }
        catch { return false; }
    }
}

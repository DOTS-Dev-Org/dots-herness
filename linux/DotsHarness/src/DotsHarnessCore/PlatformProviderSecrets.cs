using System.Diagnostics;

namespace DotsHarnessCore;

/// Uses Secret Service when the desktop exposes secret-tool. If it is not
/// available, credentials live only for this process and are never serialized.
public sealed class PlatformProviderSecrets : IProviderSecretStore
{
    private readonly IProviderSecretStore _fallback = new MemoryProviderSecretStore();
    private readonly bool _available = CommandExists("secret-tool");

    public string? Read(string id)
    {
        if (!_available) return _fallback.Read(id);
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
        if (!_available) { _fallback.Write(id, value); return; }
        using var process = Start("store", "--label=Dots Harness provider credential", "service", "dots-harness", "account", id);
        process.StandardInput.Write(value);
        process.StandardInput.Close();
        process.WaitForExit(5000);
        if (process.ExitCode != 0) throw new NativeProviderException("The desktop credential service is unavailable.");
    }

    public void Delete(string id)
    {
        if (!_available) { _fallback.Delete(id); return; }
        try { using var process = Start("clear", "service", "dots-harness", "account", id); process.WaitForExit(3000); } catch { }
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

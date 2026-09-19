// Copyright (c) 2026 DOTS
// Per-user Chrome Native Messaging manifest installation for Windows/Linux.

using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;

namespace DotsHarnessCore;

public sealed record NativeMessagingInstallResult(
    bool Installed,
    string ManifestPath,
    string DiagnosticCode);

public static class NativeMessagingManifestInstaller
{
    public const string DefaultHostName = "com.dots.herness.browser";
    private static readonly Regex ExtensionId = new("^[a-p]{32}$", RegexOptions.CultureInvariant);
    private static readonly Regex HostName = new("^[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?$", RegexOptions.CultureInvariant);

    public static NativeMessagingInstallResult Install(
        string extensionId,
        string executablePath,
        string hostName = DefaultHostName)
    {
        Validate(extensionId, executablePath, hostName);
        var manifestPath = ManifestPath(hostName);
        var directory = Path.GetDirectoryName(manifestPath)
            ?? throw new InvalidOperationException("Native Messaging manifest directory is unavailable.");
        Directory.CreateDirectory(directory);

        var payload = new Manifest(
            hostName,
            "HerNess Browser Native Messaging host",
            Path.GetFullPath(executablePath),
            "stdio",
            [$"chrome-extension://{extensionId}/"]);
        var json = JsonSerializer.Serialize(payload, new JsonSerializerOptions { WriteIndented = true });
        var original = File.Exists(manifestPath) ? File.ReadAllBytes(manifestPath) : null;
        var registryPath = $"Software\\Google\\Chrome\\NativeMessagingHosts\\{hostName}";
        string? originalRegistryValue = null;
        if (OperatingSystem.IsWindows())
        {
            using var existingRegistryKey = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(registryPath);
            originalRegistryValue = existingRegistryKey?.GetValue(null) as string;
        }
        try
        {
            WriteAtomic(manifestPath, json);
            if (OperatingSystem.IsWindows())
            {
                using var key = Microsoft.Win32.Registry.CurrentUser.CreateSubKey(registryPath);
                key?.SetValue(null, manifestPath, Microsoft.Win32.RegistryValueKind.String);
                if (key is null) throw new InvalidOperationException("HKCU Native Messaging registry key could not be created.");
            }
            VerifyManifest(manifestPath, hostName, extensionId, executablePath);
            return new NativeMessagingInstallResult(true, manifestPath, "installed");
        }
        catch
        {
            if (original is null) TryDelete(manifestPath);
            else WriteAtomic(manifestPath, System.Text.Encoding.UTF8.GetString(original));
            if (OperatingSystem.IsWindows())
            {
                try
                {
                    using var key = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(registryPath, writable: true);
                    if (originalRegistryValue is null) key?.DeleteValue("", throwOnMissingValue: false);
                    else key?.SetValue(null, originalRegistryValue, Microsoft.Win32.RegistryValueKind.String);
                }
                catch { }
            }
            throw;
        }
    }

    public static string ManifestPath(string hostName = DefaultHostName)
    {
        if (!HostName.IsMatch(hostName)) throw new ArgumentException("Invalid Native Messaging host name.", nameof(hostName));
        var user = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        if (OperatingSystem.IsWindows())
            return Path.Combine(user, "AppData", "Local", "DotsHarness", "NativeMessaging", hostName + ".json");
        if (OperatingSystem.IsLinux())
            return Path.Combine(user, ".config", "google-chrome", "NativeMessagingHosts", hostName + ".json");
        throw new PlatformNotSupportedException("Use the native Swift installer on macOS.");
    }

    private static void Validate(string extensionId, string executablePath, string hostName)
    {
        if (!ExtensionId.IsMatch(extensionId)) throw new ArgumentException("Chrome extension ID must be 32 lowercase a-p characters.", nameof(extensionId));
        if (!HostName.IsMatch(hostName)) throw new ArgumentException("Invalid Native Messaging host name.", nameof(hostName));
        if (!Path.IsPathFullyQualified(executablePath) || !File.Exists(executablePath))
            throw new ArgumentException("Native Messaging executable path must be an existing absolute file.", nameof(executablePath));
        if (OperatingSystem.IsLinux())
        {
            var mode = File.GetUnixFileMode(executablePath);
            if ((mode & (UnixFileMode.UserExecute | UnixFileMode.GroupExecute | UnixFileMode.OtherExecute)) == 0)
                throw new ArgumentException("Native Messaging executable must be executable.", nameof(executablePath));
        }
    }

    private static void VerifyManifest(string path, string hostName, string extensionId, string executablePath)
    {
        using var document = JsonDocument.Parse(File.ReadAllText(path));
        var root = document.RootElement;
        if (!string.Equals(root.GetProperty("name").GetString(), hostName, StringComparison.Ordinal)
            || !string.Equals(root.GetProperty("type").GetString(), "stdio", StringComparison.Ordinal)
            || !string.Equals(
                Path.GetFullPath(root.GetProperty("path").GetString() ?? ""),
                Path.GetFullPath(executablePath),
                OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal))
            throw new InvalidOperationException("Native Messaging manifest verification failed.");

        var expectedOrigin = $"chrome-extension://{extensionId}/";
        var origins = root.GetProperty("allowed_origins").EnumerateArray().Select(item => item.GetString());
        if (!origins.Any(origin => string.Equals(origin, expectedOrigin, StringComparison.Ordinal)))
            throw new InvalidOperationException("Native Messaging allowed_origins verification failed.");
        if (OperatingSystem.IsWindows())
        {
            using var key = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(
                $"Software\\Google\\Chrome\\NativeMessagingHosts\\{hostName}");
            if (!string.Equals(key?.GetValue(null) as string, path, StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException("Native Messaging registry verification failed.");
        }
    }

    private static void WriteAtomic(string path, string content)
    {
        var temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            File.WriteAllText(temporary, content);
            File.Move(temporary, path, overwrite: true);
        }
        catch
        {
            TryDelete(temporary);
            throw;
        }
    }

    private static void TryDelete(string path)
    {
        try { if (File.Exists(path)) File.Delete(path); } catch { }
    }

    private sealed record Manifest(
        [property: JsonPropertyName("name")] string Name,
        [property: JsonPropertyName("description")] string Description,
        [property: JsonPropertyName("path")] string Path,
        [property: JsonPropertyName("type")] string Type,
        [property: JsonPropertyName("allowed_origins")] string[] AllowedOrigins);
}

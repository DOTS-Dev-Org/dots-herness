// Copyright (c) 2026 DOTS
// Cross-platform native Marketplace reader and signed installer.

using System.IO.Compression;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using HarnessPluginKit;
using PluginRuntime;

namespace DotsHarnessCore;

public sealed record NativeMarketplaceArtifact(
    string Platform,
    string Architecture,
    string? DownloadURL,
    string? Sha256,
    MarketplaceSignature? Signature,
    long Size = 0,
    string Status = "pending",
    string? Error = null);

public sealed record NativeMarketplaceEntry(
    string Id,
    string Name,
    string Version,
    string Description,
    string Author,
    string Tier,
    string? Homepage,
    string? License,
    string VerificationStatus,
    string SourceVisibility,
    string? SourceURL,
    IReadOnlyList<NativeMarketplaceArtifact>? Artifacts = null);

public sealed record NativeMarketplaceIndex(
    int Version,
    IReadOnlyList<NativeMarketplaceEntry>? Plugins = null);

/// <summary>
/// Public Marketplace browsing and native package installation for Windows/Linux.
/// UI code must ask the user to accept the native-code warning before calling
/// InstallAsync; a successful install is immediately trusted and mounted.
/// </summary>
public sealed class NativeMarketplaceClient
{
    public const string RegistryURL = "https://dots.net.tr/harness/registry.json";
    private const string OfficialPublisherKey = "5BjXLUajc3JkmWmNHiBg5kmJoTFx2OVSe7BetYJEtCI=";
    private static readonly HttpClient Http = new() { Timeout = TimeSpan.FromSeconds(60) };
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNameCaseInsensitive = true,
        Converters = { new JsonStringEnumConverter() },
    };

    private readonly SupportPaths _paths;
    private readonly PluginCatalog _catalog;
    private readonly PluginHost _host;
    private readonly Action _remount;
    private readonly Func<string> _registryURL;

    public IReadOnlyList<NativeMarketplaceEntry> Entries { get; private set; } = Array.Empty<NativeMarketplaceEntry>();

    public NativeMarketplaceClient(
        SupportPaths paths,
        PluginCatalog catalog,
        PluginHost host,
        Action remount,
        Func<string>? registryURL = null)
    {
        _paths = paths;
        _catalog = catalog;
        _host = host;
        _remount = remount;
        _registryURL = registryURL ?? (() => RegistryURL);
    }

    public async Task<IReadOnlyList<NativeMarketplaceEntry>> RefreshAsync(CancellationToken cancellationToken = default)
    {
        var raw = _registryURL();
        if (!Uri.TryCreate(raw, UriKind.Absolute, out var uri) || uri.Scheme != Uri.UriSchemeHttps)
            throw new InvalidOperationException("Marketplace registry must use HTTPS.");
        using var request = new HttpRequestMessage(HttpMethod.Get, uri);
        request.Headers.UserAgent.ParseAdd("DotsHarness");
        using var response = await Http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, cancellationToken).ConfigureAwait(false);
        response.EnsureSuccessStatusCode();
        await using var stream = await response.Content.ReadAsStreamAsync(cancellationToken).ConfigureAwait(false);
        var index = await JsonSerializer.DeserializeAsync<NativeMarketplaceIndex>(stream, JsonOptions, cancellationToken).ConfigureAwait(false)
            ?? throw new InvalidOperationException("Marketplace registry is empty.");
        Entries = index.Plugins ?? Array.Empty<NativeMarketplaceEntry>();
        return Entries;
    }

    public async Task InstallAsync(NativeMarketplaceEntry entry, CancellationToken cancellationToken = default)
    {
        var artifact = SelectArtifact(entry.Artifacts ?? Array.Empty<NativeMarketplaceArtifact>());
        if (artifact is null || artifact.Status != "ready" || string.IsNullOrWhiteSpace(artifact.DownloadURL))
            throw new InvalidOperationException("This plugin has no ready native artifact for this platform.");
        if (!Uri.TryCreate(artifact.DownloadURL, UriKind.Absolute, out var uri) || uri.Scheme != Uri.UriSchemeHttps)
            throw new InvalidOperationException("Plugin artifact URL must use HTTPS.");
        if (artifact.Signature is null || string.IsNullOrWhiteSpace(artifact.Sha256))
            throw new InvalidOperationException("Plugin artifact is not signed.");

        var downloadDir = Path.Combine(_paths.Runtime, "downloads");
        Directory.CreateDirectory(downloadDir);
        var package = Path.Combine(downloadDir, entry.Id + ".dotsplugin");
        await FileDownloader.DownloadAsync(uri, package, artifact.Size, ct: cancellationToken, sha256: artifact.Sha256).ConfigureAwait(false);
        try
        {
            VerifySignature(package, artifact);
            _host.UnmountAll();
            try
            {
                InstallArchive(package, entry.Id, entry.Version);
            }
            catch
            {
                // A failed replacement must not leave the previously mounted
                // composition offline.
                _catalog.Refresh();
                _remount();
                throw;
            }
        }
        finally
        {
            TryDeleteFile(package);
        }

        _catalog.Refresh();
        _catalog.SetTrust(entry.Id, PluginTrust.Trusted);
        _remount();
    }

    private static string CurrentPlatform() =>
        OperatingSystem.IsWindows() ? "windows" : OperatingSystem.IsLinux() ? "linux" : "macos";

    private static string CurrentArchitecture() => RuntimeInformation.ProcessArchitecture switch
    {
        Architecture.Arm64 => "arm64",
        Architecture.X64 => "x64",
        _ => throw new PlatformNotSupportedException("Marketplace plugins support x64 and arm64 only."),
    };

    private static NativeMarketplaceArtifact? SelectArtifact(IReadOnlyList<NativeMarketplaceArtifact> artifacts)
    {
        var platform = CurrentPlatform();
        var architecture = CurrentArchitecture();
        return artifacts.FirstOrDefault(item =>
            item.Status.Equals("ready", StringComparison.OrdinalIgnoreCase)
            && item.Platform.Equals(platform, StringComparison.OrdinalIgnoreCase)
            && item.Architecture.Equals(architecture, StringComparison.OrdinalIgnoreCase));
    }

    private static void VerifySignature(string package, NativeMarketplaceArtifact artifact)
    {
        var signature = artifact.Signature!;
        if (!signature.Alg.Equals("ed25519", StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException($"Unsupported marketplace signature algorithm: {signature.Alg}.");
        if (!signature.Publisher.Equals("dots", StringComparison.Ordinal))
            throw new InvalidOperationException("Marketplace artifact publisher is not trusted.");
        if (!signature.PublicKey.Equals(OfficialPublisherKey, StringComparison.Ordinal))
            throw new InvalidOperationException("Marketplace publisher key mismatch.");
        using var stream = File.OpenRead(package);
        var digest = Convert.ToHexString(SHA256.HashData(stream)).ToLowerInvariant();
        if (!digest.Equals(artifact.Sha256, StringComparison.OrdinalIgnoreCase)
            || !digest.Equals(signature.Sha256, StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException("Marketplace artifact checksum mismatch.");
        try
        {
            var publicKey = Convert.FromBase64String(signature.PublicKey);
            var signed = Convert.FromBase64String(signature.Sig);
            if (!Ed25519Verifier.Verify(publicKey, signed, Encoding.UTF8.GetBytes(digest)))
                throw new InvalidOperationException("Marketplace artifact signature is invalid.");
        }
        catch (FormatException)
        {
            throw new InvalidOperationException("Marketplace artifact signature is malformed.");
        }
    }

    private void InstallArchive(string package, string expectedID, string expectedVersion)
    {
        var staging = Path.Combine(Path.GetTempPath(), "dotsplugin-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(staging);
        try
        {
            ExtractSafely(package, staging);
            var root = FindPluginRoot(staging);
            var manifest = MiniYaml.DecodeManifest(File.ReadAllText(Path.Combine(root, "plugin.yml")));
            if (!manifest.Id.Equals(expectedID, StringComparison.Ordinal))
                throw new InvalidOperationException("Plugin manifest id does not match the registry entry.");
            if (!manifest.Version.Equals(expectedVersion, StringComparison.Ordinal))
                throw new InvalidOperationException("Plugin manifest version does not match the registry release.");
            var library = manifest.Library;
            if (!manifest.Runtime.Equals("native", StringComparison.OrdinalIgnoreCase)
                || manifest.Main is not null
                || string.IsNullOrWhiteSpace(library)
                || Path.IsPathRooted(library)
                || library.Contains("..", StringComparison.Ordinal)
                || !File.Exists(Path.Combine(root, library))
                || !File.Exists(Path.Combine(root, "plugin.ir.json"))
                || !File.Exists(Path.Combine(root, "license"))
                || new FileInfo(Path.Combine(root, "license")).Length == 0)
                throw new InvalidOperationException("Only native packages with a compiled library and plugin.ir.json can be installed from Marketplace.");
            var destination = Path.GetFullPath(Path.Combine(_paths.Plugins, manifest.Id));
            EnsureChild(_paths.Plugins, destination);
            Directory.CreateDirectory(_paths.Plugins);
            var backup = destination + ".previous-" + Guid.NewGuid().ToString("N");
            var hadPrevious = Directory.Exists(destination);
            if (hadPrevious) Directory.Move(destination, backup);
            try
            {
                Directory.Move(root, destination);
            }
            catch
            {
                if (hadPrevious && !Directory.Exists(destination)) Directory.Move(backup, destination);
                throw;
            }
            if (hadPrevious) TryDeleteDirectory(backup);
        }
        finally
        {
            TryDeleteDirectory(staging);
        }
    }

    private static void ExtractSafely(string package, string destination)
    {
        using var archive = ZipFile.OpenRead(package);
        foreach (var entry in archive.Entries)
        {
            var relative = entry.FullName.Replace('\\', '/');
            if (string.IsNullOrWhiteSpace(relative)) continue;
            var isDirectory = relative.EndsWith('/');
            var pathForValidation = isDirectory ? relative[..^1] : relative;
            if (pathForValidation.StartsWith('/') || Path.IsPathRooted(pathForValidation)
                || pathForValidation.Split('/').Any(part => part is "" or "." or ".."))
                throw new InvalidOperationException("Plugin package contains an unsafe path.");
            var target = Path.GetFullPath(Path.Combine(destination, relative));
            EnsureChild(destination, target);
            if (isDirectory) Directory.CreateDirectory(target);
            else
            {
                Directory.CreateDirectory(Path.GetDirectoryName(target)!);
                entry.ExtractToFile(target, overwrite: true);
            }
        }
    }

    private static string FindPluginRoot(string staging)
    {
        if (File.Exists(Path.Combine(staging, "plugin.yml"))) return staging;
        var folders = Directory.GetDirectories(staging);
        return folders.SingleOrDefault(folder => File.Exists(Path.Combine(folder, "plugin.yml")))
            ?? throw new InvalidOperationException("Plugin package has no plugin.yml.");
    }

    private static void EnsureChild(string parent, string child)
    {
        var parentPath = Path.GetFullPath(parent).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
        if (!Path.GetFullPath(child).StartsWith(parentPath, StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException("Plugin package escapes its destination.");
    }

    private static void TryDeleteFile(string path) { try { if (File.Exists(path)) File.Delete(path); } catch { } }
    private static void TryDeleteDirectory(string path) { try { if (Directory.Exists(path)) Directory.Delete(path, true); } catch { } }
}

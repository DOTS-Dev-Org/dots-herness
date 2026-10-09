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
    IReadOnlyList<NativeMarketplaceArtifact>? Artifacts = null,
    string? ReleaseID = null,
    string CatalogScope = "community",
    string Category = "other",
    double CategoryConfidence = 0,
    string RiskLevel = "unknown",
    IReadOnlyList<string>? Permissions = null,
    string ModerationStatus = "pending_review");

public sealed record NativeMarketplaceIndex(
    int Version,
    IReadOnlyList<NativeMarketplaceEntry>? Plugins = null);

public sealed record MarketplaceFork(
    string Id,
    string UpstreamId,
    string UpstreamVersion,
    string? UpstreamVersionAvailable,
    DateTimeOffset CreatedAt,
    DateTimeOffset UpdatedAt);

/// <summary>Local non-destructive Marketplace forks, disabled and untrusted until explicit acceptance.</summary>
public sealed class MarketplaceForkStore
{
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web);
    private readonly PluginCatalog _catalog;
    private readonly string _storePath;
    private readonly List<MarketplaceFork> _forks = [];

    public IReadOnlyList<MarketplaceFork> Forks => _forks;

    public MarketplaceForkStore(PluginCatalog catalog)
    {
        _catalog = catalog;
        _storePath = Path.Combine(catalog.Paths.Root, "marketplace-forks.json");
        Load();
    }

    public MarketplaceFork? ForkFor(string upstreamId) => _forks.FirstOrDefault(fork => fork.UpstreamId == upstreamId);
    public bool HasFork(string upstreamId) => ForkFor(upstreamId) is not null;
    public string FolderFor(MarketplaceFork fork) => Path.Combine(_catalog.Paths.Plugins, fork.Id);

    public MarketplaceFork CreateFork(string upstreamId, string upstreamVersion)
    {
        if (ForkFor(upstreamId) is { } existing) return existing;
        if (!IsSafePluginId(upstreamId)) throw new InvalidOperationException("Marketplace plugin id is invalid.");
        var upstream = _catalog.Entries.FirstOrDefault(entry => entry.Id == upstreamId
            && entry.Kind == PluginKind.Dylib && !string.IsNullOrWhiteSpace(entry.Url));
        if (upstream?.Url is null || !Directory.Exists(upstream.Url))
            throw new InvalidOperationException($"Installed Marketplace source for {upstreamId} was not found.");

        var source = Path.GetFullPath(upstream.Url);
        EnsureChild(_catalog.Paths.Plugins, source);
        var id = upstreamId + ".fork." + Guid.NewGuid().ToString("N")[..12];
        var fork = new MarketplaceFork(id, upstreamId, upstreamVersion, null, DateTimeOffset.UtcNow, DateTimeOffset.UtcNow);
        var destination = Path.GetFullPath(FolderFor(fork));
        EnsureChild(_catalog.Paths.Plugins, destination);
        try
        {
            CopyFolder(source, destination);
            RewriteManifest(destination, id, upstreamId, upstream.Manifest.Name);
        }
        catch
        {
            TryDeleteDirectory(destination);
            throw;
        }
        _forks.Add(fork);
        Persist();
        _catalog.Refresh();
        _catalog.SetTrust(id, PluginTrust.Untrusted);
        _catalog.SetEnabled(id, false);
        return fork;
    }

    public void AcceptAndEnable(MarketplaceFork fork)
    {
        EnsureKnownFork(fork);
        _catalog.SetTrust(fork.Id, PluginTrust.Trusted);
        _catalog.SetEnabled(fork.Id, true);
    }

    public void Delete(MarketplaceFork fork)
    {
        EnsureKnownFork(fork);
        var target = Path.GetFullPath(FolderFor(fork));
        EnsureChild(_catalog.Paths.Plugins, target);
        if (!Directory.Exists(target)) throw new InvalidOperationException("Marketplace fork folder was not found.");
        Directory.Delete(target, recursive: true);
        _forks.RemoveAll(item => item.Id == fork.Id);
        Persist();
        _catalog.Refresh();
    }

    public void Export(MarketplaceFork fork, string destination)
    {
        EnsureKnownFork(fork);
        var source = Path.GetFullPath(FolderFor(fork));
        if (!Directory.Exists(source)) throw new InvalidOperationException("Marketplace fork folder was not found.");
        destination = Path.GetFullPath(destination);
        var sourcePrefix = source.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar) + Path.DirectorySeparatorChar;
        if (destination.StartsWith(sourcePrefix, OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal))
            throw new InvalidOperationException("Export the fork outside its source folder.");
        var temporary = destination + ".tmp-" + Guid.NewGuid().ToString("N");
        try
        {
            using (var stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.ReadWrite, FileShare.None))
            using (var archive = new ZipArchive(stream, ZipArchiveMode.Create))
            {
                foreach (var file in Directory.EnumerateFiles(source, "*", SearchOption.AllDirectories).Order(StringComparer.Ordinal))
                {
                    if ((File.GetAttributes(file) & FileAttributes.ReparsePoint) != 0)
                        throw new InvalidOperationException("Fork archive contains a symbolic link or reparse point.");
                    var relative = Path.GetRelativePath(source, file).Replace(Path.DirectorySeparatorChar, '/');
                    var entry = archive.CreateEntry(relative, CompressionLevel.Optimal);
                    using var input = File.OpenRead(file);
                    using var output = entry.Open();
                    input.CopyTo(output);
                }
            }
            File.Move(temporary, destination, overwrite: true);
        }
        finally { try { if (File.Exists(temporary)) File.Delete(temporary); } catch { } }
    }

    public void MarkUpstreamVersion(string upstreamId, string version)
    {
        var index = _forks.FindIndex(fork => fork.UpstreamId == upstreamId);
        if (index < 0 || !SemVer.TryParse(version, out var available)
            || !SemVer.TryParse(_forks[index].UpstreamVersion, out var current) || current.CompareTo(available) >= 0) return;
        _forks[index] = _forks[index] with { UpstreamVersionAvailable = version, UpdatedAt = DateTimeOffset.UtcNow };
        Persist();
    }

    public void AcknowledgeUpstream(MarketplaceFork fork, string version)
    {
        var index = _forks.FindIndex(item => item.Id == fork.Id);
        if (index < 0) return;
        _forks[index] = _forks[index] with { UpstreamVersion = version, UpstreamVersionAvailable = null, UpdatedAt = DateTimeOffset.UtcNow };
        Persist();
    }

    private void Load()
    {
        try
        {
            var decoded = JsonSerializer.Deserialize<List<MarketplaceFork>>(File.ReadAllBytes(_storePath), JsonOptions);
            if (decoded is null) return;
            foreach (var fork in decoded.Where(fork => IsSafePluginId(fork.Id) && IsSafePluginId(fork.UpstreamId)
                         && Directory.Exists(FolderFor(fork))))
                _forks.Add(fork);
        }
        catch { }
    }

    private void Persist()
    {
        try
        {
            Directory.CreateDirectory(_catalog.Paths.Root);
            var temporary = _storePath + ".tmp";
            File.WriteAllBytes(temporary, JsonSerializer.SerializeToUtf8Bytes(_forks, JsonOptions));
            File.Move(temporary, _storePath, overwrite: true);
        }
        catch { }
    }

    private void EnsureKnownFork(MarketplaceFork fork)
    {
        if (!_forks.Any(item => item.Id == fork.Id && item.UpstreamId == fork.UpstreamId) || !IsSafePluginId(fork.Id))
            throw new InvalidOperationException("Marketplace fork is not in the local fork catalog.");
    }

    private static void RewriteManifest(string folder, string id, string upstreamId, string upstreamName)
    {
        var path = Path.Combine(folder, "plugin.yml");
        var lines = File.ReadAllText(path).Split('\n');
        var idFound = false;
        var nameFound = false;
        var safeName = System.Text.RegularExpressions.Regex.IsMatch(upstreamName, "^[A-Za-z0-9 ._-]{1,100}$")
            ? upstreamName : upstreamId;
        for (var index = 0; index < lines.Length; index++)
        {
            var idMatch = System.Text.RegularExpressions.Regex.Match(lines[index], "^(\\s*id\\s*:\\s*).*$");
            if (idMatch.Success)
            {
                lines[index] = idMatch.Groups[1].Value + id;
                idFound = true;
                continue;
            }
            var nameMatch = System.Text.RegularExpressions.Regex.Match(lines[index], "^(\\s*name\\s*:\\s*).*$");
            if (!nameMatch.Success) continue;
            lines[index] = nameMatch.Groups[1].Value + safeName + " (Customized)";
            nameFound = true;
        }
        if (!idFound) lines = ["id: " + id, .. lines];
        if (!nameFound) lines = [.. lines.Take(1), "name: " + safeName + " (Customized)", .. lines.Skip(1)];
        Array.Resize(ref lines, lines.Length + 1);
        lines[^1] = "# DOTS upstream: " + upstreamId;
        File.WriteAllText(path, string.Join('\n', lines), new UTF8Encoding(false));
    }

    private static void CopyFolder(string source, string destination)
    {
        Directory.CreateDirectory(destination);
        foreach (var entry in Directory.EnumerateFileSystemEntries(source))
        {
            var attributes = File.GetAttributes(entry);
            if ((attributes & FileAttributes.ReparsePoint) != 0)
                throw new InvalidOperationException("Marketplace fork source contains a symbolic link or reparse point.");
            var target = Path.Combine(destination, Path.GetFileName(entry));
            if ((attributes & FileAttributes.Directory) != 0) CopyFolder(entry, target);
            else File.Copy(entry, target);
        }
    }

    private static bool IsSafePluginId(string id) => id.Length is > 0 and <= 100
        && char.IsAsciiLetterOrDigit(id[0])
        && id.All(character => char.IsAsciiLetterOrDigit(character) || character is '.' or '-' or '_')
        && !id.Contains("..", StringComparison.Ordinal);

    private static void EnsureChild(string parent, string child)
    {
        var prefix = Path.GetFullPath(parent).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar) + Path.DirectorySeparatorChar;
        if (!Path.GetFullPath(child).StartsWith(prefix, OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal))
            throw new InvalidOperationException("Marketplace fork escapes the plugin folder.");
    }

    private static void TryDeleteDirectory(string path) { try { if (Directory.Exists(path)) Directory.Delete(path, recursive: true); } catch { } }
}

/// <summary>
/// Public Marketplace browsing and native package installation for Windows/Linux.
/// UI code must ask the user to accept the native-code warning before calling
/// InstallAsync; a successful install is immediately trusted and mounted.
/// </summary>
public sealed class NativeMarketplaceClient : ObservableObject
{
    public const string RegistryURL = "https://dots.net.tr/harness/registry.json";
    public const string CommunityRegistryURL = "https://dots.net.tr/harness/community-registry.json";
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
    private readonly Func<string> _communityRegistryURL;
    private readonly MarketplaceSession? _session;
    private IReadOnlyList<NativeMarketplaceEntry> _entries = Array.Empty<NativeMarketplaceEntry>();
    private IReadOnlyList<NativeMarketplaceEntry> _communityEntries = Array.Empty<NativeMarketplaceEntry>();
    private IReadOnlyList<MarketplaceOwnedPlugin> _ownedPlugins = Array.Empty<MarketplaceOwnedPlugin>();
    private string? _ownedPluginsError;

    public IReadOnlyList<NativeMarketplaceEntry> Entries { get => _entries; private set => SetProperty(ref _entries, value); }
    public IReadOnlyList<NativeMarketplaceEntry> CommunityEntries { get => _communityEntries; private set => SetProperty(ref _communityEntries, value); }
    public IReadOnlyList<MarketplaceOwnedPlugin> OwnedPlugins { get => _ownedPlugins; private set => SetProperty(ref _ownedPlugins, value); }
    public string? OwnedPluginsError { get => _ownedPluginsError; private set => SetProperty(ref _ownedPluginsError, value); }
    public MarketplaceForkStore Forks { get; }

    public NativeMarketplaceClient(
        SupportPaths paths,
        PluginCatalog catalog,
        PluginHost host,
        Action remount,
        Func<string>? registryURL = null,
        Func<string>? communityRegistryURL = null,
        MarketplaceSession? session = null)
    {
        _paths = paths;
        _catalog = catalog;
        _host = host;
        _remount = remount;
        _registryURL = registryURL ?? (() => RegistryURL);
        _communityRegistryURL = communityRegistryURL ?? (() => CommunityRegistryURL);
        _session = session;
        Forks = new MarketplaceForkStore(catalog);
    }

    public async Task RefreshOwnedPluginsAsync(CancellationToken cancellationToken = default)
    {
        if (_session is null || !_session.IsSignedIn)
        {
            OwnedPlugins = Array.Empty<MarketplaceOwnedPlugin>();
            OwnedPluginsError = null;
            return;
        }
        try
        {
            var response = await _session.AuthorizedDataAsync("api/marketplace/me/plugins", cancellationToken: cancellationToken).ConfigureAwait(false);
            if (!response.IsSuccess) throw new InvalidOperationException($"Marketplace account query failed (HTTP {(int)response.StatusCode}): {response.Text}");
            var payload = JsonSerializer.Deserialize<OwnedPluginResponse>(response.Data, JsonOptions)
                ?? throw new InvalidDataException("Marketplace returned an invalid owned-plugin list.");
            OwnedPlugins = payload.Plugins ?? Array.Empty<MarketplaceOwnedPlugin>();
            OwnedPluginsError = null;
        }
        catch (Exception error)
        {
            OwnedPluginsError = error.Message;
            throw;
        }
    }

    public async Task UnpublishAsync(string pluginId, CancellationToken cancellationToken = default)
    {
        if (_session is null) throw new InvalidOperationException("Marketplace account session is unavailable.");
        var response = await _session.AuthorizedDataAsync(
            $"api/marketplace/plugins/{Uri.EscapeDataString(pluginId)}",
            HttpMethod.Delete,
            cancellationToken: cancellationToken).ConfigureAwait(false);
        if (!response.IsSuccess) throw new InvalidOperationException($"Marketplace unpublish failed (HTTP {(int)response.StatusCode}): {response.Text}");
        await RefreshOwnedPluginsAsync(cancellationToken).ConfigureAwait(false);
        await RefreshAsync(cancellationToken).ConfigureAwait(false);
        await RefreshCommunityAsync(cancellationToken).ConfigureAwait(false);
    }

    public async Task ReportAsync(
        NativeMarketplaceEntry entry,
        string reason,
        string details,
        CancellationToken cancellationToken = default)
    {
        if (_session is null || !_session.IsSignedIn)
            throw new InvalidOperationException("Sign in to your HerNess account before reporting a plugin.");
        if (string.IsNullOrWhiteSpace(entry.ReleaseID) || !Guid.TryParse(entry.ReleaseID, out _))
            throw new InvalidOperationException("This Marketplace entry has no valid release identifier.");
        var allowedReasons = new HashSet<string>(StringComparer.Ordinal)
        {
            "malware", "credential_theft", "data_exfiltration", "deceptive_listing", "spam", "copyright", "other",
        };
        if (!allowedReasons.Contains(reason)) throw new ArgumentOutOfRangeException(nameof(reason));
        details = (details ?? string.Empty).Trim();
        if (details.Length > 5_000) throw new InvalidOperationException("Report details must be 5,000 characters or fewer.");
        var body = JsonSerializer.SerializeToUtf8Bytes(new
        {
            release_id = entry.ReleaseID,
            reason,
            details,
        }, JsonOptions);
        var response = await _session.AuthorizedDataAsync(
            $"api/marketplace/plugins/{Uri.EscapeDataString(entry.Id)}/reports",
            HttpMethod.Post,
            body,
            "application/json",
            cancellationToken).ConfigureAwait(false);
        if (!response.IsSuccess)
            throw new InvalidOperationException($"Marketplace report failed (HTTP {(int)response.StatusCode}): {response.Text}");
    }

    private sealed record OwnedPluginResponse(
        [property: JsonPropertyName("plugins")] IReadOnlyList<MarketplaceOwnedPlugin>? Plugins);

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
        if (index.Version < 3)
            throw new InvalidOperationException("Marketplace registry is missing moderation metadata.");
        Entries = index.Plugins ?? Array.Empty<NativeMarketplaceEntry>();
        foreach (var entry in Entries) Forks.MarkUpstreamVersion(entry.Id, entry.Version);
        return Entries;
    }

    public async Task<IReadOnlyList<NativeMarketplaceEntry>> RefreshCommunityAsync(CancellationToken cancellationToken = default)
    {
        var raw = _communityRegistryURL();
        if (!Uri.TryCreate(raw, UriKind.Absolute, out var uri) || uri.Scheme != Uri.UriSchemeHttps)
            throw new InvalidOperationException("Community Marketplace registry must use HTTPS.");
        using var request = new HttpRequestMessage(HttpMethod.Get, uri);
        request.Headers.UserAgent.ParseAdd("DotsHarness");
        using var response = await Http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, cancellationToken).ConfigureAwait(false);
        response.EnsureSuccessStatusCode();
        await using var stream = await response.Content.ReadAsStreamAsync(cancellationToken).ConfigureAwait(false);
        var index = await JsonSerializer.DeserializeAsync<NativeMarketplaceIndex>(stream, JsonOptions, cancellationToken).ConfigureAwait(false)
            ?? throw new InvalidOperationException("Community Marketplace registry is empty.");
        if (index.Version < 3)
            throw new InvalidOperationException("Community Marketplace registry is missing moderation metadata.");
        CommunityEntries = index.Plugins ?? Array.Empty<NativeMarketplaceEntry>();
        foreach (var entry in CommunityEntries) Forks.MarkUpstreamVersion(entry.Id, entry.Version);
        return CommunityEntries;
    }

    public bool CanInstall(NativeMarketplaceEntry entry)
    {
        if (!entry.ModerationStatus.Equals("approved", StringComparison.OrdinalIgnoreCase)) return false;
        var artifact = SelectArtifact(entry.Artifacts ?? Array.Empty<NativeMarketplaceArtifact>());
        return artifact is { Status: "ready", Signature: not null }
            && !string.IsNullOrWhiteSpace(artifact.DownloadURL)
            && !string.IsNullOrWhiteSpace(artifact.Sha256);
    }

    public async Task InstallAsync(NativeMarketplaceEntry entry, CancellationToken cancellationToken = default)
    {
        if (!entry.ModerationStatus.Equals("approved", StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException("This plugin is not approved for Marketplace installation.");
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
        _catalog.SetEnabled(entry.Id, true);
        _remount();
    }

    public void RemoveInstalled(string pluginId)
    {
        var installed = _catalog.Entries.FirstOrDefault(entry => entry.Id == pluginId && entry.Kind == PluginKind.Dylib && entry.Url is not null);
        if (installed?.Url is null) throw new InvalidOperationException("Installed native plugin was not found.");
        var folder = Path.GetFullPath(installed.Url);
        var pluginsRoot = Path.GetFullPath(_paths.Plugins);
        var prefix = pluginsRoot.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar) + Path.DirectorySeparatorChar;
        if (!folder.StartsWith(prefix, OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal))
            throw new InvalidOperationException("Installed plugin path is outside the plugin folder.");
        _host.UnmountAll();
        try
        {
            Directory.Delete(folder, recursive: true);
            _catalog.SetTrust(pluginId, PluginTrust.Untrusted);
            _catalog.SetEnabled(pluginId, true);
            _catalog.Refresh();
        }
        catch
        {
            _catalog.Refresh();
            _remount();
            throw;
        }
        _remount();
    }

    public void DeleteFork(MarketplaceFork fork)
    {
        _host.UnmountAll();
        try
        {
            Forks.Delete(fork);
        }
        catch
        {
            _catalog.Refresh();
            _remount();
            throw;
        }
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

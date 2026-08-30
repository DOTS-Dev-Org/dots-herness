// Copyright (c) 2026 DOTS
// Signed marketplace installation for the removable Vision fallback plugin.

using System.IO.Compression;
using System.Numerics;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using HarnessPluginKit;
using PluginRuntime;

namespace DotsHarnessCore;

public sealed record MarketplaceSignature(
    string Alg,
    string Sha256,
    string Sig,
    string Publisher,
    string PublicKey);

public sealed record MarketplaceArtifact(
    string Platform,
    string Architecture,
    string DownloadURL,
    string Sha256,
    MarketplaceSignature? Signature = null,
    long Size = 0);

public sealed record VisionMarketplaceEntry(
    string Id,
    string Name,
    string Version,
    string Description,
    string Tier,
    IReadOnlyList<MarketplaceArtifact>? Artifacts = null,
    string? DownloadURL = null,
    string? Sha256 = null,
    MarketplaceSignature? Signature = null);

public sealed record VisionMarketplaceIndex(IReadOnlyList<VisionMarketplaceEntry>? Plugins = null);

/// <summary>
/// Installs only the signed Vision artifact. The general marketplace remains
/// a platform UI concern; this narrow installer is the fallback's root service.
/// </summary>
public sealed class VisionMarketplaceInstaller : IVisionFallbackInstaller
{
    private const string RegistryURL = "https://dots.net.tr/harness/registry.json";
    private static readonly HttpClient Http = new() { Timeout = TimeSpan.FromSeconds(30) };
    private static readonly IReadOnlyDictionary<string, string> OfficialPublishers =
        new Dictionary<string, string>(StringComparer.Ordinal)
        {
            // ponytail: keep the release key explicit; replace the empty value
            // in the release configuration instead of trusting registry keys.
            ["dots"] = "",
        };

    private readonly SupportPaths _paths;
    private readonly PluginCatalog _catalog;
    private readonly PluginHost _host;
    private readonly Action _remount;
    private readonly Func<string> _registryURL;

    public VisionMarketplaceInstaller(
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

    public async Task<IVisionFallbackService?> InstallAsync(CancellationToken cancellationToken = default)
    {
        var index = await ReadIndexAsync(cancellationToken).ConfigureAwait(false);
        var entry = (index.Plugins ?? Array.Empty<VisionMarketplaceEntry>()).FirstOrDefault(item =>
            string.Equals(item.Id, VisionFallbackDefaults.PluginId, StringComparison.Ordinal));
        if (entry is null) throw new InvalidOperationException("Vision plugin is not published in the marketplace.");

        var artifacts = entry.Artifacts ?? Array.Empty<MarketplaceArtifact>();
        var artifact = SelectArtifact(artifacts);
        if (artifact is null && artifacts.Count == 0)
        {
            // Backward-compatible registry entries are accepted only when they
            // still carry the signed single-artifact shape.
            artifact = entry.DownloadURL is not null
                ? new MarketplaceArtifact(
                    CurrentPlatform(),
                    CurrentArchitecture(),
                    entry.DownloadURL,
                    entry.Sha256 ?? "",
                    entry.Signature)
                : null;
        }
        if (artifact is null) throw new InvalidOperationException("Vision plugin has no artifact for this platform.");
        ValidateArtifact(artifact);

        var downloadDir = Path.Combine(_paths.Runtime, "downloads");
        Directory.CreateDirectory(downloadDir);
        var package = Path.Combine(downloadDir, "dots.vision-fallback.dotsplugin");
        await FileDownloader.DownloadAsync(
            new Uri(artifact.DownloadURL),
            package,
            expected: artifact.Size,
            ct: cancellationToken,
            sha256: artifact.Sha256).ConfigureAwait(false);
        try
        {
            VerifySignature(package, artifact);
            var installedDirectory = Path.Combine(_paths.Plugins, VisionFallbackDefaults.PluginId);
            var wasInstalled = Directory.Exists(installedDirectory);
            if (wasInstalled) _host.UnmountAll();
            try
            {
                InstallArchive(package);
            }
            catch
            {
                if (wasInstalled)
                {
                    _catalog.Refresh();
                    _remount();
                }
                throw;
            }
        }
        finally
        {
            TryDeleteFile(package);
        }

        _catalog.Refresh();
        _catalog.SetEnabled(VisionFallbackDefaults.PluginId, true);
        _catalog.SetTrust(VisionFallbackDefaults.PluginId, PluginTrust.Trusted);
        _remount();
        return _host.GetService<IVisionFallbackService>(VisionFallbackDefaults.ServiceName);
    }

    private async Task<VisionMarketplaceIndex> ReadIndexAsync(CancellationToken cancellationToken)
    {
        var raw = _registryURL();
        if (!Uri.TryCreate(raw, UriKind.Absolute, out var uri) || uri.Scheme != Uri.UriSchemeHttps)
        {
            throw new InvalidOperationException("Vision marketplace registry must use HTTPS.");
        }
        using var request = new HttpRequestMessage(HttpMethod.Get, uri);
        request.Headers.UserAgent.ParseAdd("DotsHarness");
        using var response = await Http.SendAsync(request, cancellationToken).ConfigureAwait(false);
        response.EnsureSuccessStatusCode();
        await using var stream = await response.Content.ReadAsStreamAsync(cancellationToken).ConfigureAwait(false);
        var index = await JsonSerializer.DeserializeAsync<VisionMarketplaceIndex>(stream, JsonOptions, cancellationToken).ConfigureAwait(false);
        return index ?? throw new InvalidOperationException("Marketplace registry is empty.");
    }

    private static MarketplaceArtifact? SelectArtifact(IReadOnlyList<MarketplaceArtifact> artifacts)
    {
        var platform = CurrentPlatform();
        var architecture = CurrentArchitecture();
        return artifacts.FirstOrDefault(item =>
            string.Equals(item.Platform, platform, StringComparison.OrdinalIgnoreCase)
            && string.Equals(item.Architecture, architecture, StringComparison.OrdinalIgnoreCase));
    }

    private static string CurrentPlatform() =>
        OperatingSystem.IsWindows() ? "windows" : OperatingSystem.IsLinux() ? "linux" : "macos";

    private static string CurrentArchitecture() => RuntimeInformation.ProcessArchitecture switch
    {
        Architecture.Arm64 => "arm64",
        Architecture.X64 => "x64",
        _ => throw new PlatformNotSupportedException("Vision fallback supports x64 and arm64 only."),
    };

    private static void ValidateArtifact(MarketplaceArtifact artifact)
    {
        if (!Uri.TryCreate(artifact.DownloadURL, UriKind.Absolute, out var uri)
            || uri.Scheme != Uri.UriSchemeHttps)
        {
            throw new InvalidOperationException("Vision artifact URL must use HTTPS.");
        }
        if (artifact.Size < 0 || !IsSha256(artifact.Sha256))
        {
            throw new InvalidOperationException("Vision artifact checksum is missing or malformed.");
        }
        if (artifact.Signature is null) throw new InvalidOperationException("Vision artifact is not signed.");
    }

    private void VerifySignature(string package, MarketplaceArtifact artifact)
    {
        var signature = artifact.Signature!;
        if (!string.Equals(signature.Alg, "ed25519", StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidOperationException($"Unsupported Vision signature algorithm: {signature.Alg}.");
        }
        if (!string.Equals(signature.Sha256, artifact.Sha256, StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidOperationException("Vision signature checksum does not match the artifact.");
        }
        var publishers = new Dictionary<string, string>(OfficialPublishers, StringComparer.Ordinal);
        var pinFile = Path.Combine(_paths.Root, "publishers.json");
        if (File.Exists(pinFile))
        {
            var extra = JsonSerializer.Deserialize<Dictionary<string, string>>(File.ReadAllText(pinFile), JsonOptions);
            if (extra is not null) publishers = new Dictionary<string, string>(extra, StringComparer.Ordinal);
        }
        if (!publishers.TryGetValue(signature.Publisher, out var pinned)
            || string.IsNullOrWhiteSpace(pinned)
            || !string.Equals(pinned, signature.PublicKey, StringComparison.Ordinal))
        {
            throw new InvalidOperationException($"Vision publisher key is not pinned: {signature.Publisher}.");
        }

        using var stream = File.OpenRead(package);
        var digest = Convert.ToHexString(SHA256.HashData(stream)).ToLowerInvariant();
        if (!string.Equals(digest, artifact.Sha256, StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidOperationException("Vision artifact checksum mismatch.");
        }
        try
        {
            var publicKey = Convert.FromBase64String(signature.PublicKey);
            var signed = Convert.FromBase64String(signature.Sig);
            if (!Ed25519Verifier.Verify(publicKey, signed, Encoding.UTF8.GetBytes(digest)))
            {
                throw new InvalidOperationException("Vision artifact signature is invalid.");
            }
        }
        catch (FormatException)
        {
            throw new InvalidOperationException("Vision artifact signature is malformed.");
        }
    }

    private void InstallArchive(string package)
    {
        var staging = Path.Combine(Path.GetTempPath(), "dotsplugin-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(staging);
        try
        {
            ExtractSafely(package, staging);
            var root = FindPluginRoot(staging);
            var manifest = MiniYaml.DecodeManifest(File.ReadAllText(Path.Combine(root, "plugin.yml")));
            if (!string.Equals(manifest.Id, VisionFallbackDefaults.PluginId, StringComparison.Ordinal))
            {
                throw new InvalidOperationException("Vision package manifest id does not match the requested plugin.");
            }
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
            {
                throw new InvalidOperationException("Vision package contains an unsafe path.");
            }
            var target = Path.GetFullPath(Path.Combine(destination, relative));
            EnsureChild(destination, target);
            if (isDirectory)
            {
                Directory.CreateDirectory(target);
                continue;
            }
            Directory.CreateDirectory(Path.GetDirectoryName(target)!);
            entry.ExtractToFile(target, overwrite: true);
        }
    }

    private static string FindPluginRoot(string staging)
    {
        if (File.Exists(Path.Combine(staging, "plugin.yml"))) return staging;
        var folders = Directory.GetDirectories(staging);
        var root = folders.SingleOrDefault(folder => File.Exists(Path.Combine(folder, "plugin.yml")));
        return root ?? throw new InvalidOperationException("Vision package has no plugin.yml.");
    }

    private static void EnsureChild(string parent, string child)
    {
        var parentPath = Path.GetFullPath(parent).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
        var childPath = Path.GetFullPath(child);
        if (!childPath.StartsWith(parentPath, StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidOperationException("Vision package escapes its destination.");
        }
    }

    private static bool IsSha256(string? value) =>
        !string.IsNullOrWhiteSpace(value) && value.Length == 64 && value.All(Uri.IsHexDigit);

    private static void TryDeleteFile(string path)
    {
        try { if (File.Exists(path)) File.Delete(path); } catch { }
    }

    private static void TryDeleteDirectory(string path)
    {
        try { if (Directory.Exists(path)) Directory.Delete(path, recursive: true); } catch { }
    }

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNameCaseInsensitive = true,
        Converters = { new JsonStringEnumConverter() },
    };
}

/// <summary>
/// Small dependency-free Ed25519 verifier for .NET 8, which does not expose
/// the public Ed25519 API used by newer runtimes. It verifies the exact
/// detached signature format already used by the macOS installer.
/// </summary>
internal static class Ed25519Verifier
{
    private static readonly BigInteger P = (BigInteger.One << 255) - 19;
    private static readonly BigInteger L = (BigInteger.One << 252)
        + BigInteger.Parse("27742317777372353535851937790883648493");
    private static readonly BigInteger D = Mod(-121665 * Inverse(121666));
    private static readonly BigInteger SqrtM1 = BigInteger.ModPow(2, (P - 1) / 4, P);
    private static readonly Point BasePoint = new(
        BigInteger.Parse("15112221349535400772501151409588531511454012693041857206046113283949847762202"),
        BigInteger.Parse("46316835694926478169428394003475163141307993866256225615783033603165251855960"));
    private static readonly Point Identity = new(BigInteger.Zero, BigInteger.One);

    public static bool Verify(byte[] publicKey, byte[] signature, byte[] message)
    {
        if (publicKey.Length != 32 || signature.Length != 64) return false;
        var sBytes = signature[32..];
        var s = FromLittleEndian(sBytes);
        if (s >= L) return false;
        if (!DecodePoint(publicKey, out var a) || !DecodePoint(signature[..32], out var r)) return false;
        if (ScalarMultiply(a, L) != Identity || ScalarMultiply(r, L) != Identity) return false;

        var hashInput = new byte[32 + 32 + message.Length];
        Buffer.BlockCopy(signature, 0, hashInput, 0, 32);
        Buffer.BlockCopy(publicKey, 0, hashInput, 32, 32);
        Buffer.BlockCopy(message, 0, hashInput, 64, message.Length);
        var k = FromLittleEndian(SHA512.HashData(hashInput)) % L;

        var left = ScalarMultiply(BasePoint, s);
        var right = Add(r, ScalarMultiply(a, k));
        return left.X == right.X && left.Y == right.Y;
    }

    private readonly record struct Point(BigInteger X, BigInteger Y);

    private static Point Add(Point left, Point right)
    {
        var xProduct = Mod(left.X * right.X);
        var yProduct = Mod(left.Y * right.Y);
        var xyProduct = Mod(xProduct * yProduct);
        var x = Mod((left.X * right.Y) + (left.Y * right.X)) * Inverse(Mod(1 + D * xyProduct));
        var y = Mod(yProduct + xProduct) * Inverse(Mod(1 - D * xyProduct));
        return new Point(Mod(x), Mod(y));
    }

    private static Point ScalarMultiply(Point point, BigInteger scalar)
    {
        var result = Identity;
        var current = point;
        while (scalar > 0)
        {
            if (!scalar.IsEven) result = Add(result, current);
            current = Add(current, current);
            scalar >>= 1;
        }
        return result;
    }

    private static bool DecodePoint(byte[] encoded, out Point point)
    {
        point = Identity;
        if (encoded.Length != 32) return false;
        var yBytes = encoded.ToArray();
        var sign = (yBytes[31] & 0x80) != 0;
        yBytes[31] &= 0x7f;
        var y = FromLittleEndian(yBytes);
        if (y >= P) return false;
        var y2 = Mod(y * y);
        var x2 = Mod((y2 - 1) * Inverse(Mod(D * y2 + 1)));
        var x = BigInteger.ModPow(x2, (P + 3) / 8, P);
        if (Mod(x * x - x2) != 0) x = Mod(x * SqrtM1);
        if (Mod(x * x - x2) != 0) return false;
        if ((x.IsEven) == sign) x = P - x;
        point = new Point(x, y);
        return true;
    }

    private static BigInteger Inverse(BigInteger value) => BigInteger.ModPow(Mod(value), P - 2, P);

    private static BigInteger Mod(BigInteger value)
    {
        var result = value % P;
        return result < 0 ? result + P : result;
    }

    private static BigInteger FromLittleEndian(byte[] bytes) =>
        new(bytes, isUnsigned: true, isBigEndian: false);
}

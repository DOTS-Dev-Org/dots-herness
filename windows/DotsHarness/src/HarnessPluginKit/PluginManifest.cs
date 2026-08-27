// Copyright (c) 2026 DOTS
// Plugin composition model derived from DeepSeek Harness.
// Copyright (c) 2026 DeepSeek. MIT. See NOTICE.

namespace HarnessPluginKit;

public enum PluginPlane
{
    Host,
    Session,
}

public enum PluginTrust
{
    /// <summary>Shipped with the app. Always enabled for loading.</summary>
    System,
    /// <summary>User accepted network / assembly privileges.</summary>
    Trusted,
    /// <summary>Prompt + local slots only.</summary>
    Untrusted,
}

public sealed record PromptSectionSpec(string Name, int Order, string? File = null, string? Text = null);

public sealed record PluginManifest(
    string Id,
    string Name,
    string Version,
    PluginPlane Plane,
    string Abi = PluginManifest.CurrentAbi,
    IReadOnlyList<string>? Inject = null,
    string Description = "",
    string? Library = null,
    PromptSectionSpec? PromptSection = null)
{
    public const string CurrentAbi = "1.0.0";

    public IReadOnlyList<string> Inject { get; init; } = Inject ?? Array.Empty<string>();

    public bool AbiCompatible => SemVer.TryParse(Abi, out var have)
        && SemVer.TryParse(CurrentAbi, out var want)
        && have.Major == want.Major;
}

public readonly record struct SemVer(int Major, int Minor, int Patch) : IComparable<SemVer>
{
    public static bool TryParse(string? raw, out SemVer value)
    {
        value = default;
        if (string.IsNullOrWhiteSpace(raw)) return false;
        var parts = raw.Split('.');
        if (parts.Length < 1 || !int.TryParse(parts[0], out var major)) return false;
        var minor = parts.Length > 1 && int.TryParse(parts[1], out var m) ? m : 0;
        var patch = parts.Length > 2 && int.TryParse(parts[2], out var p) ? p : 0;
        value = new SemVer(major, minor, patch);
        return true;
    }

    public int CompareTo(SemVer other) =>
        (Major, Minor, Patch).CompareTo((other.Major, other.Minor, other.Patch));
}

public readonly record struct PluginIdentity(string Id);

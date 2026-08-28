namespace HarnessPluginKit;

public sealed record ProviderImageRoute(
    string AccountId,
    string ProviderId,
    string BaseUrl,
    string Api,
    string Model,
    string AuthType = "",
    string? SessionAccountId = null);

public enum ProviderImageAuthentication
{
    None,
    Bearer,
    RawHeader,
}

public sealed record ProviderImageRequest(
    Uri Url,
    byte[] Body,
    IReadOnlyDictionary<string, string>? Headers = null,
    ProviderImageAuthentication Authentication = ProviderImageAuthentication.Bearer,
    string? AuthenticationHeader = null);

public sealed record ProviderImageOutput(byte[] Data, string MimeType = "image/png");

public enum ProviderImageFailureKind
{
    Auth,
    Network,
    RateLimit,
    Server,
    Safety,
    InvalidOutput,
    Other,
}

public sealed record ProviderImageFailure(ProviderImageFailureKind Kind, string Message);

public abstract record ProviderImageResult
{
    public sealed record Generated(ProviderImageOutput Output) : ProviderImageResult;
    public sealed record Unsupported(string Message) : ProviderImageResult;
    public sealed record Failed(ProviderImageFailure Failure) : ProviderImageResult;
}

public enum ProviderImageCapability
{
    Supported,
    Unsupported,
}

public interface IProviderImageAdapter
{
    string Id { get; }
    bool IsFallbackOnly => false;
    bool Matches(ProviderImageRoute route);
    ProviderImageRequest PrepareImageRequest(string prompt, string model, ProviderImageRoute route);
    ProviderImageResult ParseImageResponse(byte[] data, int status, IReadOnlyDictionary<string, string> headers);
}

public sealed class ProviderImageAdapterRegistry
{
    private sealed record Entry(string Owner, IProviderImageAdapter Adapter);

    private readonly List<Entry> _entries = [];
    private readonly Dictionary<string, ProviderImageCapability> _capabilities = new(StringComparer.Ordinal);

    public void Register(IProviderImageAdapter adapter, string owner, PluginTrust trust)
    {
        if (trust == PluginTrust.Untrusted) throw new InvalidOperationException("Only trusted native plugins can register network image adapters.");
        _entries.RemoveAll(entry => entry.Owner == owner && entry.Adapter.Id == adapter.Id);
        foreach (var key in _capabilities.Keys.Where(key => key.Contains($"|{adapter.Id}|", StringComparison.Ordinal)).ToList()) _capabilities.Remove(key);
        _entries.Add(new Entry(owner, adapter));
    }

    public void UnregisterOwner(string owner)
    {
        var ids = _entries.Where(entry => entry.Owner == owner).Select(entry => entry.Adapter.Id).ToHashSet(StringComparer.Ordinal);
        _entries.RemoveAll(entry => entry.Owner == owner);
        foreach (var key in _capabilities.Keys.Where(key => ids.Any(id => key.Contains($"|{id}|", StringComparison.Ordinal))).ToList()) _capabilities.Remove(key);
    }

    public IProviderImageAdapter? Find(ProviderImageRoute route, bool includeFallbackOnly = false) => _entries.AsEnumerable().Reverse().Select(entry => entry.Adapter).FirstOrDefault(adapter => adapter.Matches(route) && (includeFallbackOnly || !adapter.IsFallbackOnly));

    public ProviderImageCapability? Capability(ProviderImageRoute route, string adapterId) =>
        _capabilities.TryGetValue(Key(route, adapterId), out var value) ? value : null;

    public void Record(ProviderImageCapability capability, ProviderImageRoute route, string adapterId) => _capabilities[Key(route, adapterId)] = capability;

    public IReadOnlyList<string> RegisteredAdapterIds => _entries.Select(entry => entry.Adapter.Id).Distinct(StringComparer.Ordinal).OrderBy(id => id).ToList();

    private static string Key(ProviderImageRoute route, string adapterId) => $"{route.AccountId}|{route.BaseUrl}|{adapterId}|{route.Model}";
}

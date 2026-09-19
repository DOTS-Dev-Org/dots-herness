// Copyright (c) 2026 DOTS
// Read-only bridge from the native app into plugins. The app registers named
// snapshot providers; native plugins read
// the current snapshot through `harness.host("<topic>")`. No write path.

namespace HarnessPluginKit;

public interface IHostDataRegistry
{
    /// <summary>Native app: expose <paramref name="topic"/> as a live read-only
    /// snapshot. Re-registering replaces the provider. The delegate runs on every
    /// plugin read, so keep it to already-computed values.</summary>
    void Register(string topic, Func<JsonValue> snapshot);

    void Unregister(string topic);

    /// <summary>Plugin-facing: current snapshot for <paramref name="topic"/>, or null.</summary>
    JsonValue? Snapshot(string topic);

    IReadOnlyList<string> AvailableTopics();
}

public sealed class HostDataRegistry : IHostDataRegistry
{
    private readonly Dictionary<string, Func<JsonValue>> _topics = new(StringComparer.Ordinal);

    public void Register(string topic, Func<JsonValue> snapshot) => _topics[topic] = snapshot;

    public void Unregister(string topic) => _topics.Remove(topic);

    public JsonValue? Snapshot(string topic) =>
        _topics.TryGetValue(topic, out var provider) ? provider() : null;

    public IReadOnlyList<string> AvailableTopics() =>
        _topics.Keys.OrderBy(k => k, StringComparer.Ordinal).ToList();
}

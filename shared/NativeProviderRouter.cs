// Copyright (c) 2026 DOTS
// Small .NET 8 provider store and direct transport shared by WPF and Avalonia.

using System.Net;
using System.Net.Http.Headers;
using System.Collections.Concurrent;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using HarnessPluginKit;
using JsonNodeValue = System.Text.Json.Nodes.JsonValue;

namespace DotsHarnessCore;

public enum NativeProviderProtocol
{
    OpenAiCompatible,
    Anthropic,
    ChatGpt,
    OpenAiResponses,
    /// The locally installed, official `claude` binary, run as a complete agent.
    ClaudeCli,
}

/// <summary>Maps provider identities to bundled corporate marks shared by the desktop hosts.</summary>
public static class ProviderMarkCatalog
{
    private static readonly IReadOnlyDictionary<string, string> Marks = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
    {
        ["gpt"] = "OpenAIMark", ["openai"] = "OpenAIMark",
        ["claude"] = "AnthropicMark", ["claude-cli"] = "AnthropicMark", ["anthropic"] = "AnthropicMark",
        ["grok"] = "GrokMark", ["grok-cli"] = "GrokMark",
        ["xai"] = "SpaceXAIMark", ["spacexai"] = "SpaceXAIMark",
        ["gemini"] = "GeminiMark", ["gemini-cli"] = "GeminiMark",
        ["antigravity"] = "AntigravityMark", ["opencode"] = "OpenCodeMark", ["opencode-go"] = "OpenCodeMark",
        ["iflow"] = "IFlowMark", ["github"] = "GitHubMark", ["kiro"] = "KiroMark",
        ["nvidia"] = "NvidiaMark", ["zai"] = "ZaiMark", ["glm"] = "ZaiMark",
        ["deepseek"] = "DeepSeekMark", ["openrouter"] = "OpenRouterMark", ["qwen"] = "QwenMark",
        ["kimi"] = "KimiMark", ["minimax"] = "MiniMaxMark", ["groq"] = "GroqMark",
        ["mistral"] = "MistralMark", ["perplexity"] = "PerplexityMark", ["together"] = "TogetherAIMark",
        ["fireworks"] = "FireworksMark", ["cerebras"] = "CerebrasMark", ["deepinfra"] = "DeepInfraMark",
        ["cohere"] = "CohereMark", ["siliconflow"] = "SiliconFlowMark", ["nebius"] = "NebiusMark",
        ["chutes"] = "ChutesMark", ["hyperbolic"] = "HyperbolicMark", ["vertex"] = "GoogleCloudMark",
    };

    public static string? ResourceNameFor(string? providerKey) =>
        providerKey is not null && Marks.TryGetValue(providerKey, out var resource) ? resource : null;
}

/// <summary>Stable provider-specific request headers shared by model discovery and inference.</summary>
public static class NativeProviderTransportHeaders
{
    public static void Apply(HttpRequestHeaders headers, string provider)
    {
        if (provider is "opencode" or "opencode-go")
            headers.TryAddWithoutValidation("x-opencode-client", "desktop");
        if (provider == "grok-cli")
        {
            headers.TryAddWithoutValidation("x-grok-client-identifier", "grok-shell");
            headers.TryAddWithoutValidation("x-grok-client-version", "0.2.99");
            var platform = OperatingSystem.IsWindows() ? "windows" : OperatingSystem.IsLinux() ? "linux" : "unknown";
            var architecture = System.Runtime.InteropServices.RuntimeInformation.ProcessArchitecture.ToString().ToLowerInvariant();
            headers.TryAddWithoutValidation("User-Agent", $"grok-shell/0.2.99 ({platform}; {architecture})");
        }
    }
}

public sealed record NativeProviderDescriptor(
    string Id,
    string Name,
    string BaseUrl,
    string DefaultModel,
    NativeProviderProtocol Protocol,
    string AuthKind,
    string Hint,
    string LogoKey);

public sealed class NativeProviderAccount
{
    public string Id { get; set; } = Guid.NewGuid().ToString();
    public string Provider { get; set; } = "";
    public string ProviderName { get; set; } = "Provider";
    public string Name { get; set; } = "";
    public string? Email { get; set; }
    public string? SessionAccountId { get; set; }
    public bool Active { get; set; } = true;
    public bool ImageFallbackEnabled { get; set; }
    public string Status { get; set; } = "connected";
    public string AuthType { get; set; } = "apiKey";
    public string Model { get; set; } = "";
    // Discovered models are metadata only; credentials stay in the secret store.
    public List<string> Models { get; set; } = [];
    public string BaseUrl { get; set; } = "";
    public NativeProviderProtocol Protocol { get; set; }
    public string CredentialId { get; set; } = "";
    public string? RefreshCredentialId { get; set; }
    public int Priority { get; set; }
    public string? Error { get; set; }
    // Context window the user (or the bundled local server) declared. Local
    // servers rarely report one, so this beats every guess.
    public int? ContextWindow { get; set; }

    /// <summary>
    /// A custom endpoint saved without a model name is stored as <c>prefix/</c>.
    /// It names no model, so it must never reach a picker or a request.
    /// </summary>
    public static bool IsPlaceholderModel(string? model) => model is { Length: > 0 } && model.EndsWith('/');
}

public sealed class NativeCustomEndpoint
{
    public string Id { get; set; } = Guid.NewGuid().ToString();
    public string Name { get; set; } = "";
    public string Prefix { get; set; } = "custom";
    public string BaseUrl { get; set; } = "";
    public NativeProviderProtocol Protocol { get; set; }
    public string ApiType { get; set; } = "chat";
    public string? CredentialId { get; set; }
    // Model to request when the server's /models listing is unavailable.
    public string? Model { get; set; }
    public int? ContextWindow { get; set; }
}

public sealed class NativeProviderState
{
    public List<NativeProviderAccount> Accounts { get; set; } = [];
    public List<NativeCustomEndpoint> Endpoints { get; set; } = [];
    public string? SelectedAccountId { get; set; }
    /// <summary>Per-provider, per-model context sizes entered by the user.</summary>
    public Dictionary<string, int> ModelContextWindowOverrides { get; set; } = new(StringComparer.Ordinal);
}

public sealed record ConnectionTransition(
    string Action,
    string? PreviousConnectionLabel,
    string? CurrentConnectionLabel,
    string CleanupStatus,
    IReadOnlyList<string> RemovedLocalArtifacts,
    bool RemoteDataTouched = false,
    bool UserDataPreserved = true);

public interface IProviderSecretStore
{
    string? Read(string id);
    void Write(string id, string value);
    void Delete(string id);
}

public sealed class MemoryProviderSecretStore : IProviderSecretStore
{
    private readonly Dictionary<string, string> _values = new(StringComparer.Ordinal);
    public string? Read(string id) => _values.TryGetValue(id, out var value) ? value : null;
    public void Write(string id, string value) => _values[id] = value;
    public void Delete(string id) => _values.Remove(id);
}

public sealed class NativeProviderStore
{
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web) { WriteIndented = true };
    private readonly string _file;
    public NativeProviderState State { get; }
    public IProviderSecretStore Secrets { get; }

    public NativeProviderStore(string root, IProviderSecretStore secrets)
    {
        Directory.CreateDirectory(root);
        _file = Path.Combine(root, "provider-state.json");
        Secrets = secrets;
        var raw = File.Exists(_file) ? File.ReadAllText(_file) : null;
        try { State = raw is null ? new() : JsonSerializer.Deserialize<NativeProviderState>(raw, JsonOptions) ?? new(); }
        catch { State = new(); }
        var migratedOpenAiResponses = false;
        foreach (var account in State.Accounts.Where(account =>
                     string.Equals(account.Provider, "openai", StringComparison.OrdinalIgnoreCase)
                     && account.Protocol == NativeProviderProtocol.OpenAiCompatible))
        {
            account.Protocol = NativeProviderProtocol.OpenAiResponses;
            migratedOpenAiResponses = true;
        }
        if (raw is not null) MigratePlaintextSecrets(raw);
        if (migratedOpenAiResponses) Save();
    }

    public void Save() => File.WriteAllText(_file, JsonSerializer.Serialize(State, JsonOptions));

    public NativeProviderAccount AddAccount(
        NativeProviderDescriptor provider,
        string name,
        string secret,
        string? model = null,
        string? baseUrl = null,
        string authType = "apiKey",
        string? email = null,
        string? sessionAccountId = null,
        string? refreshSecret = null)
    {
        // The CLI signs in on its own: no key, and its address is not an HTTP endpoint.
        var cli = provider.Protocol == NativeProviderProtocol.ClaudeCli;
        if (string.IsNullOrWhiteSpace(name) || (!cli && string.IsNullOrWhiteSpace(secret))) throw new NativeProviderException("Name and API key are required.");
        var id = Guid.NewGuid().ToString();
        var account = new NativeProviderAccount
        {
            Id = id,
            Provider = provider.Id,
            ProviderName = provider.Name,
            Name = UniqueName(name.Trim(), provider.Id),
            Email = email,
            SessionAccountId = sessionAccountId,
            Model = model ?? provider.DefaultModel,
            Models = string.IsNullOrWhiteSpace(model) ? [provider.DefaultModel] : [model],
            BaseUrl = cli ? provider.BaseUrl : NormalizeUrl(baseUrl ?? provider.BaseUrl),
            Protocol = provider.Protocol,
            AuthType = authType,
            CredentialId = $"account.{id}",
            RefreshCredentialId = refreshSecret is null ? null : $"refresh.{id}",
        };
        Secrets.Write(account.CredentialId, secret);
        if (refreshSecret is not null) Secrets.Write(account.RefreshCredentialId!, refreshSecret);
        State.Accounts.Add(account);
        State.SelectedAccountId ??= account.Id;
        Save();
        return account;
    }

    public NativeCustomEndpoint AddCustom(string name, string prefix, string baseUrl, NativeProviderProtocol protocol, string apiType, string? secret, string? model = null, int? contextWindow = null)
    {
        var normalized = NormalizeUrl(baseUrl);
        var id = Guid.NewGuid().ToString();
        var endpoint = new NativeCustomEndpoint
        {
            Id = id,
            Name = name.Trim(),
            Prefix = SanitizePrefix(string.IsNullOrWhiteSpace(prefix) ? name : prefix),
            BaseUrl = normalized,
            Protocol = protocol,
            ApiType = apiType,
            CredentialId = string.IsNullOrWhiteSpace(secret) ? null : $"endpoint.{id}",
            Model = string.IsNullOrWhiteSpace(model) ? null : model.Trim(),
            ContextWindow = contextWindow is > 0 ? contextWindow : null,
        };
        if (endpoint.CredentialId is not null) Secrets.Write(endpoint.CredentialId, secret!);
        State.Endpoints.Add(endpoint);
        Save();
        return endpoint;
    }

    public void UpdateCustom(NativeCustomEndpoint endpoint, string name, string prefix, string baseUrl, NativeProviderProtocol protocol, string apiType, string? secret, string? model = null, int? contextWindow = null)
    {
        var index = State.Endpoints.FindIndex(item => item.Id == endpoint.Id);
        if (index < 0) throw new NativeProviderException("Custom endpoint not found.");
        var current = State.Endpoints[index];
        var normalized = NormalizeUrl(baseUrl);
        var trimmedName = name.Trim();
        if (trimmedName.Length == 0) throw new NativeProviderException("Name is required.");
        var sanitized = SanitizePrefix(string.IsNullOrWhiteSpace(prefix) ? trimmedName : prefix);
        var credentialId = current.CredentialId;
        if (secret is not null)
        {
            if (string.IsNullOrWhiteSpace(secret))
            {
                if (credentialId is not null) Secrets.Delete(credentialId);
                credentialId = null;
            }
            else
            {
                credentialId ??= $"endpoint.{current.Id}";
                Secrets.Write(credentialId, secret.Trim());
            }
        }
        State.Endpoints[index] = new NativeCustomEndpoint
        {
            Id = current.Id, Name = trimmedName, Prefix = sanitized, BaseUrl = normalized,
            Protocol = protocol, ApiType = apiType, CredentialId = credentialId,
            Model = string.IsNullOrWhiteSpace(model) ? null : model.Trim(),
            ContextWindow = contextWindow is > 0 ? contextWindow : null,
        };
        var updated = State.Endpoints[index];
        foreach (var account in State.Accounts.Where(account => account.Provider == $"custom:{current.Id}"))
        {
            account.Name = trimmedName;
            account.ProviderName = trimmedName;
            account.Model = updated.Model ?? sanitized + "/";
            account.Models = updated.Model is null ? [] : [updated.Model];
            account.ContextWindow = updated.ContextWindow;
            account.BaseUrl = normalized;
            account.Protocol = protocol;
            if (secret is not null)
            {
                if (string.IsNullOrWhiteSpace(secret)) Secrets.Delete(account.CredentialId);
                else Secrets.Write(account.CredentialId, secret.Trim());
            }
        }
        Save();
    }

    public NativeProviderAccount AddCustomAccount(NativeCustomEndpoint endpoint, string? secret)
    {
        var id = Guid.NewGuid().ToString();
        var account = new NativeProviderAccount
        {
            Id = id,
            Provider = $"custom:{endpoint.Id}",
            ProviderName = endpoint.Name,
            Name = endpoint.Name,
            Model = endpoint.Model ?? endpoint.Prefix + "/",
            BaseUrl = endpoint.BaseUrl,
            Protocol = endpoint.Protocol,
            AuthType = "custom",
            CredentialId = $"account.{id}",
            Models = endpoint.Model is null ? [] : [endpoint.Model],
            ContextWindow = endpoint.ContextWindow,
        };
        if (!string.IsNullOrWhiteSpace(secret)) Secrets.Write(account.CredentialId, secret);
        State.Accounts.Add(account);
        State.SelectedAccountId ??= account.Id;
        Save();
        return account;
    }

    public void SetActive(string id, bool active) { if (State.Accounts.FirstOrDefault(a => a.Id == id) is { } account) { account.Active = active; Save(); } }
    public void SetImageFallback(string id, bool enabled) { if (State.Accounts.FirstOrDefault(a => a.Id == id) is { } account) { account.ImageFallbackEnabled = enabled; Save(); } }
    public void ReplaceCredential(NativeProviderAccount account, string value) => Secrets.Write(account.CredentialId, value);
    public void ReplaceRefreshCredential(NativeProviderAccount account, string value)
    {
        if (account.RefreshCredentialId is not null) Secrets.Write(account.RefreshCredentialId, value);
    }

    public IReadOnlyList<string> Remove(NativeProviderAccount account)
    {
        Secrets.Delete(account.CredentialId);
        if (account.RefreshCredentialId is not null) Secrets.Delete(account.RefreshCredentialId);
        State.Accounts.RemoveAll(a => a.Id == account.Id);
        if (State.SelectedAccountId == account.Id) State.SelectedAccountId = State.Accounts.FirstOrDefault()?.Id;
        Save();
        return ["connection record", "credential reference", "model metadata"];
    }

    public IReadOnlyList<string> Remove(NativeCustomEndpoint endpoint)
    {
        if (endpoint.CredentialId is not null) Secrets.Delete(endpoint.CredentialId);
        var accounts = State.Accounts.Where(a => a.Provider == $"custom:{endpoint.Id}").ToArray();
        foreach (var account in accounts)
        {
            Secrets.Delete(account.CredentialId);
            if (account.RefreshCredentialId is not null) Secrets.Delete(account.RefreshCredentialId);
        }
        State.Endpoints.RemoveAll(e => e.Id == endpoint.Id);
        State.Accounts.RemoveAll(a => a.Provider == $"custom:{endpoint.Id}");
        if (State.SelectedAccountId is { } selected && accounts.Any(a => a.Id == selected)) State.SelectedAccountId = State.Accounts.FirstOrDefault()?.Id;
        Save();
        return ["endpoint record", "connection record", "credential references", "model metadata"];
    }

    public static string NormalizeUrl(string value)
    {
        if (!Uri.TryCreate(value.Trim(), UriKind.Absolute, out var uri) || uri.Host.Length == 0 || uri.Scheme is not ("http" or "https") || !string.IsNullOrEmpty(uri.UserInfo))
            throw new NativeProviderException("Enter a valid HTTP or HTTPS endpoint.");
        var path = uri.AbsolutePath.TrimEnd('/');
        while (path.EndsWith("/v1/v1", StringComparison.OrdinalIgnoreCase)) path = path[..^3];
        return new UriBuilder(uri) { Path = path }.Uri.ToString().TrimEnd('/');
    }

    public static string SanitizePrefix(string value)
    {
        var result = new string(value.Trim().ToLowerInvariant().Select(ch => char.IsLetterOrDigit(ch) ? ch : '-').ToArray()).Trim('-');
        return result.Length > 24 ? result[..24] : result;
    }

    private string UniqueName(string seed, string provider)
    {
        var names = State.Accounts.Where(a => a.Provider == provider).Select(a => a.Name).ToHashSet(StringComparer.OrdinalIgnoreCase);
        if (!names.Contains(seed)) return seed;
        for (var i = 2; ; i++) if (!names.Contains($"{seed} {i}")) return $"{seed} {i}";
    }

    private void MigratePlaintextSecrets(string raw)
    {
        try
        {
            var root = JsonNode.Parse(raw)?.AsObject();
            var changed = false;
            foreach (var item in root?["accounts"]?.AsArray() ?? new JsonArray())
            {
                if (item is not JsonObject obj || obj["id"]?.GetValue<string>() is not { } id) continue;
                var secret = SecretValue(obj);
                var account = State.Accounts.FirstOrDefault(value => value.Id == id);
                if (secret is null || account is null) continue;
                if (string.IsNullOrEmpty(account.CredentialId)) account.CredentialId = $"account.{id}";
                Secrets.Write(account.CredentialId, secret);
                if (!string.Equals(Secrets.Read(account.CredentialId), secret, StringComparison.Ordinal)) throw new NativeProviderException("Provider credential migration could not be verified.");
                changed = true;
            }
            foreach (var item in root?["endpoints"]?.AsArray() ?? new JsonArray())
            {
                if (item is not JsonObject obj || obj["id"]?.GetValue<string>() is not { } id) continue;
                var secret = SecretValue(obj);
                var endpoint = State.Endpoints.FirstOrDefault(value => value.Id == id);
                if (secret is null || endpoint is null) continue;
                endpoint.CredentialId ??= $"endpoint.{id}";
                Secrets.Write(endpoint.CredentialId, secret);
                if (!string.Equals(Secrets.Read(endpoint.CredentialId), secret, StringComparison.Ordinal)) throw new NativeProviderException("Custom API credential migration could not be verified.");
                changed = true;
            }
            if (changed) Save();
        }
        catch { /* leave the source JSON untouched if secure migration cannot be verified */ }
    }

    private static string? SecretValue(JsonObject obj) =>
        new[] { "apiKey", "api_key", "secret", "token" }
            .Select(key => obj[key]?.GetValue<string>())
            .FirstOrDefault(value => !string.IsNullOrWhiteSpace(value));
}

public sealed record NativeAttachment(
    string FilePath,
    string Name,
    string Kind,
    string MimeType,
    string? AttachmentId = null,
    int Revision = 0,
    string? ContentHash = null,
    string? DeliveredHash = null,
    string? SourceLocator = null,
    ChatAttachmentSourceStatus SourceStatus = ChatAttachmentSourceStatus.Current);
public sealed record NativeMessage(
    string Role,
    string Content,
    string? ToolCallId = null,
    IReadOnlyList<NativeToolCall>? ToolCalls = null,
    IReadOnlyList<NativeAttachment>? Attachments = null,
    IReadOnlyList<JsonObject>? ProviderItems = null,
    string? SystemKind = null,
    bool PromptContextCaptured = false,
    string? Thinking = null,
    bool IsTransientProgressText = false);

/// Captures host context on a user turn before it is sent or persisted. Shared
/// by Windows and Linux, independently of the selected provider protocol.
public static class NativePromptHistory
{
    private static readonly System.Text.RegularExpressions.Regex Section = new(
        @"\A<([a-z_]+)(?: trust=""[a-z]+"")?>\n[\s\S]*?\n</\1>",
        System.Text.RegularExpressions.RegexOptions.Compiled);

    private static (List<(string Tag, string Block)> Sections, bool Complete) Sections(string text)
    {
        var sections = new List<(string Tag, string Block)>();
        var rest = text;
        while (Section.Match(rest) is { Success: true } match)
        {
            sections.Add((match.Groups[1].Value, match.Value));
            rest = rest[match.Length..].TrimStart('\n');
        }
        return (sections, rest.Length == 0);
    }

    private static string ChangedSections(string context, IEnumerable<NativeMessage> history)
    {
        var current = Sections(context);
        if (!current.Complete) return context;
        var copies = new Dictionary<string, List<string>>(StringComparer.Ordinal);
        foreach (var user in history.Where(message => message.Role == "user" && message.PromptContextCaptured))
            foreach (var section in Sections(user.Content).Sections)
            {
                if (!copies.TryGetValue(section.Tag, out var list)) copies[section.Tag] = list = [];
                list.Add(section.Block);
            }
        var captured = copies.ToDictionary(pair => pair.Key, pair => pair.Value[^1], StringComparer.Ordinal);
        var live = current.Sections.Select(section => section.Tag).ToHashSet(StringComparer.Ordinal);
        return string.Join("\n\n", current.Sections
            .Select(section => section.Tag == "task_history"
                ? TaskHistoryAdditions(section.Block, copies.GetValueOrDefault(section.Tag) ?? [])
                : !captured.TryGetValue(section.Tag, out var previous) || previous != section.Block ? section.Block : null)
            .OfType<string>()
            .Concat(captured.Keys.Order(StringComparer.Ordinal)
                .Where(tag => !live.Contains(tag) && captured[tag] != Retired(tag)).Select(Retired)));
    }

    private static string Retired(string tag) => $"<{tag}>\nNo longer applies.\n</{tag}>";

    public const string TaskHistoryAdditionsMarker =
        "(Additions to the task_history captured earlier in this conversation; its earlier entries still hold.)";
    public const string TaskHistoryBacklogMarker =
        "(Additions to the task_history captured earlier in this conversation; its earlier entries still hold, except the backlog below, which replaces the earlier one.)";

    /// task_history is recalled for each request, so its text moves every turn while
    /// most entries repeat. Only entries the transcript has not seen since its last
    /// full copy are captured. The backlog is state rather than recall: when it
    /// changed, the new backlog is captured whole (an empty one as "None") under a
    /// marker saying it replaces the earlier one. Null when nothing is new.
    public static string? TaskHistoryAdditions(string block, IReadOnlyList<string> copies)
    {
        static string[] Body(string block) => block.Split('\n')[1..^1];
        // An entry is a line plus its indented continuation lines ("  Files: …").
        static List<string> Entries(IEnumerable<string> lines)
        {
            var result = new List<string>();
            foreach (var line in lines.Where(line => line.Length > 0))
                if (line.StartsWith(' ') && result.Count > 0) result[^1] += "\n" + line;
                else result.Add(line);
            return result;
        }
        static (int Start, int Count) BacklogRange(List<string> entries)
        {
            var start = entries.FindIndex(entry => entry.StartsWith("## Unfinished work", StringComparison.Ordinal));
            if (start < 0) return (entries.Count, 0);
            var end = entries.FindIndex(start + 1, entry => entry.StartsWith("## ", StringComparison.Ordinal));
            return (start, (end < 0 ? entries.Count : end) - start);
        }
        static List<string> Backlog(string copy)
        {
            var all = Entries(Body(copy));
            var (start, count) = BacklogRange(all);
            return all.GetRange(start, count);
        }
        List<string> none = ["## Unfinished work (backlog)", "- None"];
        string[] markers = [TaskHistoryAdditionsMarker, TaskHistoryBacklogMarker];

        if (copies.Count == 0 || copies[^1] == Retired("task_history")) return block;
        var baseIndex = -1;
        for (var index = copies.Count - 1; index >= 0 && baseIndex < 0; index--)
            if (!markers.Contains(Body(copies[index]).FirstOrDefault())) baseIndex = index;
        if (baseIndex < 0) return block;
        // The backlog the transcript last stated: the full copy's, unless an addition replaced it.
        var stated = copies.Skip(baseIndex + 1).Select(Backlog).LastOrDefault(backlog => backlog.Count > 0) ?? Backlog(copies[baseIndex]);
        var current = Entries(Body(block));
        var (backlogStart, backlogCount) = BacklogRange(current);
        var currentBacklog = backlogCount == 0 ? none : current.GetRange(backlogStart, backlogCount);
        current.RemoveRange(backlogStart, backlogCount);
        List<string> replaced = currentBacklog.SequenceEqual(stated.Count == 0 ? none : stated) ? [] : currentBacklog;
        var seen = copies.Skip(baseIndex).SelectMany(copy => Entries(Body(copy))).ToHashSet(StringComparer.Ordinal);
        var kept = new List<string>();
        string? heading = null;
        foreach (var entry in current)
        {
            if (entry.StartsWith("## ", StringComparison.Ordinal)) { heading = entry; continue; }
            if (seen.Contains(entry)) continue;
            if (heading is not null) { kept.Add(heading); heading = null; }
            kept.Add(entry);
        }
        kept.AddRange(replaced);
        if (kept.Count == 0) return null;
        var lines = block.Split('\n');
        var marker = replaced.Count == 0 ? TaskHistoryAdditionsMarker : TaskHistoryBacklogMarker;
        return string.Join("\n", new[] { lines[0], marker }.Concat(kept).Append(lines[^1]));
    }

    /// An opaque Responses checkpoint replaces the earlier provider history.
    public static List<NativeMessage> ResponsesReplay(IReadOnlyList<NativeMessage> messages)
    {
        var boundary = -1;
        for (var index = 0; index < messages.Count; index++)
            if (messages[index].ProviderItems?.Any(item => item["type"]?.GetValue<string>() == "compaction") == true)
                boundary = index;
        if (boundary < 0) return messages.ToList();
        var checkpoint = messages[boundary];
        var items = checkpoint.ProviderItems!.ToList();
        var start = items.FindLastIndex(item => item["type"]?.GetValue<string>() == "compaction");
        var retained = items.Skip(start).ToList();
        var calls = retained.Where(item => item["type"]?.GetValue<string>() == "function_call")
            .Select(item => item["call_id"]?.GetValue<string>()).ToHashSet();
        checkpoint = checkpoint with
        {
            ProviderItems = retained,
            ToolCalls = checkpoint.ToolCalls?.Where(call => calls.Contains(call.Id)).ToList(),
            Content = string.Join("\n", retained.Where(item => item["type"]?.GetValue<string>() == "message")
                .SelectMany(item => item["content"]?.AsArray() ?? [])
                .Select(block => block?["text"]?.GetValue<string>()).OfType<string>()),
            Thinking = null,
        };
        return messages.Take(boundary).Where(message => message.Role == "system" && !ContextCompaction.IsSummary(message))
            .Concat([checkpoint]).Concat(messages.Skip(boundary + 1)).ToList();
    }

    public static List<NativeMessage> Prepare(
        IReadOnlyList<NativeMessage> messages, string policy, string turnContext)
    {
        var result = messages.ToList();
        var systemIndex = result.FindIndex(message => message.Role == "system"
            && !ContextCompaction.IsSummary(message));
        var system = new NativeMessage("system", policy, SystemKind: "promptStable");
        if (systemIndex >= 0) result[systemIndex] = system;
        else result.Insert(0, system);
        var userIndex = result.FindLastIndex(message => message.Role == "user" && message.SystemKind != "contextNotice");
        if (userIndex >= 0 && !result[userIndex].PromptContextCaptured)
        {
            var user = result[userIndex];
            var changed = ChangedSections(turnContext, result.Take(userIndex));
            result[userIndex] = user with
            {
                Content = string.IsNullOrEmpty(changed) ? user.Content : changed + "\n\n" + user.Content,
                PromptContextCaptured = true,
            };
        }
        return result;
    }
}
public sealed record NativeToolCall(string Id, string Name, string Arguments);
public sealed record NativeToolDefinition(string Name, string Description, JsonNode Parameters);
public sealed record NativeUsage(
    int InputTokens,
    int OutputTokens,
    int? CachedInputTokens = null,
    int? CacheWriteTokens = null,
    int? CacheMissTokens = null,
    bool InputExcludesCache = false,
    int? ReasoningTokens = null,
    bool InputTokensReported = true,
    int? ContextClearedInputTokens = null,
    int? ContextClearedToolUses = null)
{
    public bool CacheAccountingAvailable => CachedInputTokens is not null || CacheWriteTokens is not null || CacheMissTokens is not null;
    public double? CacheHitRate => InputTokensReported && CachedInputTokens is >= 0 && TotalInputTokens > 0
        && CachedInputTokens <= TotalInputTokens ? (double)CachedInputTokens.Value / TotalInputTokens : null;
    public int TotalInputTokens => InputExcludesCache
        ? InputTokens + (CachedInputTokens ?? 0) + (CacheWriteTokens ?? 0)
        : Math.Max(InputTokens, (CachedInputTokens ?? 0) + (CacheMissTokens ?? 0) + (CacheWriteTokens ?? 0));
    /// Input newly processed for the current response, excluding cache reads.
    /// Cache writes remain included because the provider processes them now.
    public int FreshInputTokens => !CacheAccountingAvailable
        ? TotalInputTokens
        : InputExcludesCache
            ? Math.Max(0, InputTokens + (CacheWriteTokens ?? 0))
            : CacheMissTokens is { } misses
                ? Math.Max(0, misses + (CacheWriteTokens ?? 0))
                : CachedInputTokens is { } cached
                    ? Math.Max(0, TotalInputTokens - cached)
                    : TotalInputTokens;
}
public sealed record NativeResponse(
    NativeMessage Message,
    NativeUsage? Usage,
    string? IncompleteReason = null,
    int RetryCount = 0,
    NativeUsage? RetryUsage = null,
    string? AccountId = null,
    string? ResponseId = null,
    NativeCacheDiagnostics? CacheDiagnostics = null,
    NativeCacheReuseEvidence? CacheReuseEvidence = null,
    int? EffectiveCacheTTLSeconds = null,
    int? LatencyMilliseconds = null);

public sealed record NativeCacheDiagnostics(string Type, string? Reason, int? MissedTokens, int? ReusableTokens);

public enum NativeProviderLimitKind
{
    Rate,
    Quota,
    Credits,
    Usage,
    Balance,
}

public sealed class NativeProviderException : Exception
{
    public int? StatusCode { get; }
    public bool Retryable { get; }
    public bool IsLimit { get; }
    public NativeProviderLimitKind? LimitKind { get; }
    public string? ProviderName { get; }
    public string? AccountId { get; }
    /// When a rate-limited provider supplied a reset moment, this is the first
    /// instant at which an automatic continuation may be attempted.
    public DateTimeOffset? RetryAt { get; }
    public bool IsImageInputUnsupported { get; }
    public bool IsContextWindowExceeded => IndicatesContextWindowExceeded(Message);

    public static bool IndicatesContextWindowExceeded(string message)
    {
        var normalized = message.ToLowerInvariant().Replace('_', ' ');
        if (new[] { "prompt is too long", "prompt too long", "input is too long", "input too long" }.Any(normalized.Contains))
            return true;
        return new[] { "context window", "context length", "maximum context", "max context", "prompt length", "input length" }.Any(normalized.Contains)
            && new[] { "exceed", "too long", "too large", "too many tokens", "maximum", "max tokens", "full", "limit" }.Any(normalized.Contains);
    }

    public NativeProviderException(
        string message,
        int? statusCode = null,
        bool retryable = false,
        bool isLimit = false,
        NativeProviderLimitKind? limitKind = null,
        string? providerName = null,
        bool isImageInputUnsupported = false,
        DateTimeOffset? retryAt = null,
        string? accountId = null) : base(message)
    {
        StatusCode = statusCode;
        IsLimit = isLimit || statusCode == 429;
        LimitKind = limitKind ?? (statusCode == 429 ? NativeProviderLimitKind.Rate : null);
        ProviderName = providerName;
        AccountId = accountId;
        RetryAt = retryAt;
        IsImageInputUnsupported = isImageInputUnsupported;
        Retryable = IsLimit ? false : retryable;
    }

    public NativeProviderException MarkImageInputUnsupported() => new(
        Message,
        StatusCode,
        Retryable,
        IsLimit,
        LimitKind,
        ProviderName,
        true,
        RetryAt,
        AccountId);
}

internal static class ClaudeOAuthHeaders
{
    public const string Beta = "oauth-2025-04-20,claude-code-20250219,interleaved-thinking-2025-05-14,fine-grained-tool-streaming-2025-05-14";
    /// Replaced by the remote model catalog when it publishes a newer client user-agent.
    public static string UserAgent { get; set; } = "claude-cli/2.1.92 (external, sdk-cli)";
    public const string AgentIdentity = "You are Claude Code, Anthropic's official CLI for Claude.";
    private const string Dot = "-dot-";
    private const string Suffix = "_cc";

    public static void CloakTools(JsonObject body)
    {
        if (body["tools"] is not JsonArray tools || tools.Count == 0) return;
        var names = new HashSet<string>(StringComparer.Ordinal);
        foreach (var tool in tools.OfType<JsonObject>().ToArray())
        {
            if (tool["type"] is not null || tool["name"]?.GetValue<string>() is not { } name) continue;
            names.Add(name);
            tool["name"] = name.Replace(".", Dot, StringComparison.Ordinal) + Suffix;
        }
        if (!names.Contains("Read")) tools.Add(new JsonObject
        {
            ["name"] = "Read", ["description"] = "Read a file from the filesystem.",
            ["input_schema"] = new JsonObject { ["type"] = "object", ["properties"] = new JsonObject { ["file_path"] = new JsonObject { ["type"] = "string" } }, ["required"] = new JsonArray("file_path") },
        });
        if (!names.Contains("Bash")) tools.Add(new JsonObject
        {
            ["name"] = "Bash", ["description"] = "Run a shell command.",
            ["input_schema"] = new JsonObject { ["type"] = "object", ["properties"] = new JsonObject { ["command"] = new JsonObject { ["type"] = "string" } }, ["required"] = new JsonArray("command") },
        });

        foreach (var message in (body["messages"] as JsonArray ?? []).OfType<JsonObject>())
        {
            if (message["content"] is not JsonArray content) continue;
            foreach (var block in content.OfType<JsonObject>())
            {
                if (block["type"]?.GetValue<string>() != "tool_use" || block["name"]?.GetValue<string>() is not { } name || !names.Contains(name)) continue;
                block["name"] = name.Replace(".", Dot, StringComparison.Ordinal) + Suffix;
            }
        }
    }

    public static string RestoreToolName(string name) => name.EndsWith(Suffix, StringComparison.Ordinal)
        ? name[..^Suffix.Length].Replace(Dot, ".", StringComparison.Ordinal)
        : name;
}

public sealed class NativeProviderRouter
{
    public const string ChatGptCodexClientVersion = "0.155.0";

    // An endpoint that rejects this optional routing hint should not incur a
    // failed request on every later turn. This memory is process-local and
    // contains no prompt or credential data.
    private static readonly ConcurrentDictionary<string, byte> UnsupportedPromptCacheKeys = new(StringComparer.Ordinal);
    private static readonly ConcurrentDictionary<string, byte> UnsupportedNativeCompactionRoutes = new(StringComparer.Ordinal);
    private static readonly ConcurrentDictionary<string, byte> UnsupportedAnthropicContextEditingRoutes = new(StringComparer.Ordinal);

    private static readonly ConcurrentDictionary<string, byte> UnsupportedCacheDiagnostics = new(StringComparer.Ordinal);
    private static readonly ConcurrentDictionary<string, byte> UnsupportedExtendedCacheTtls = new(StringComparer.Ordinal);
    private static readonly ConcurrentDictionary<string, byte> UnsupportedStaticBreakpoints = new(StringComparer.Ordinal);
    private static readonly ConcurrentDictionary<string, byte> UnsupportedImplicitRetention = new(StringComparer.Ordinal);
    private static readonly ConcurrentDictionary<string, byte> UnsupportedAnthropicDiagnostics = new(StringComparer.Ordinal);
    private readonly ConcurrentDictionary<string, string> _cacheResponseIds = new(StringComparer.Ordinal);

    private readonly NativeProviderStore _store;
    private readonly HttpClient _http;
    private readonly Func<NativeProviderAccount, CancellationToken, Task<bool>>? _refresh;
    /// <summary>Current in-memory remaining quota, supplied by the app-wide usage poll.</summary>
    public Func<IReadOnlyDictionary<string, AccountUsageSnapshot>>? RefreshUsage { get; set; }

    /// Share left per account from the last completion's `x-ratelimit-*`
    /// headers, for subscriptions no usage endpoint covers (Grok Build).
    /// ponytail: those headers meter a short window, not the plan; replace with
    /// a usage endpoint once the provider publishes one.
    internal readonly ConcurrentDictionary<string, (double Remaining, DateTimeOffset ResetsAt)> HeaderUsage = new();

    internal static double? RateLimitRemaining(HttpResponseMessage response)
    {
        double? Number(string name) =>
            response.Headers.TryGetValues(name, out var values)
            && double.TryParse(values.FirstOrDefault()?.Trim(), NumberStyles.Float, CultureInfo.InvariantCulture, out var value)
                ? value : null;
        var shares = new[] { "requests", "tokens" }
            .Select(kind => Number($"x-ratelimit-remaining-{kind}") is { } left && Number($"x-ratelimit-limit-{kind}") is { } limit && limit > 0
                ? Math.Clamp(left / limit, 0, 1) : (double?)null)
            .OfType<double>()
            .ToList();
        return shares.Count == 0 ? null : shares.Min();
    }

    /// Reasoning effort for requests. Empty = provider default; ignored for models
    /// that do not list the level in <see cref="NativeEffortCatalog"/>.
    public string Effort { get; set; } = "";
    /// Fast (priority) output for models in <see cref="NativeFastCatalog"/>; off in Economy.
    public bool Fast { get; set; }
    public string AnthropicCacheTTL { get; set; } = "1h";
    /// Standard preserves the existing transport policy; Economy adds only
    /// deterministic output/context reductions and keeps Effort unchanged.
    public AgentUsageMode UsageMode { get; set; } = AgentUsageMode.Standard;
    public int CompactionThresholdPercent { get; set; } = 90;
    /// Persistent response prose preference. It is a dynamic request setting,
    /// not part of the stable prompt-cache prefix.
    public AgentResponseStylePreference ResponseStylePreference { get; set; } = AgentResponseStylePreference.Balanced;

    public bool SupportsNativeCompaction(NativeProviderAccount? account) => account is not null
        && (account.Protocol is NativeProviderProtocol.ChatGpt or NativeProviderProtocol.OpenAiResponses)
        && !UnsupportedNativeCompactionRoutes.ContainsKey($"{account.Id}:{account.Protocol}");

    /// One connection pool for every provider call: the startup model discovery
    /// leaves a warm TLS connection that the first chat request reuses.
    public static readonly HttpClient SharedHttp = new(new SocketsHttpHandler
    {
        PooledConnectionIdleTimeout = TimeSpan.FromMinutes(5),
    })
    {
        Timeout = TimeSpan.FromSeconds(180),
    };

    public NativeProviderRouter(NativeProviderStore store, Func<NativeProviderAccount, CancellationToken, Task<bool>>? refresh = null, HttpClient? http = null)
    {
        _store = store;
        _refresh = refresh;
        _http = http ?? SharedHttp;
    }

    public async Task<NativeResponse> CompleteAsync(
        IReadOnlyList<NativeMessage> messages,
        IReadOnlyList<NativeToolDefinition> tools,
        string? model = null,
        CancellationToken ct = default,
        string? promptCacheKey = null,
        string? effortOverride = null,
        int? contextWindow = null,
        bool nativeCompactionDisabled = false,
        string? preferredAccountId = null,
        bool allowAccountFailoverAfterLimit = false,
        string? excludedAccountId = null,
        string? cacheComparisonScope = null,
        NativeCacheSession? cacheSession = null)
    {
        var usageSnapshot = RefreshUsage?.Invoke();
        var now = DateTimeOffset.UtcNow;
        double RemainingRank(NativeProviderAccount account)
        {
            double? left = usageSnapshot is not null && usageSnapshot.TryGetValue(account.Id, out var snapshot)
                && snapshot.UsedFraction is { } used
                ? 1 - Math.Clamp(used, 0, 1)
                : HeaderUsage.TryGetValue(account.Id, out var header) && header.ResetsAt > now ? header.Remaining : null;
            if (left is not { } value) return 0;
            return value <= 0 ? -1 : value;
        }
        // Quota first; the first-connected account only breaks a tie.
        var allCandidates = _store.State.Accounts
            .Where(a => a.Active && (string.IsNullOrWhiteSpace(model) || CanServe(a, model)))
            .OrderByDescending(RemainingRank)
            .ThenBy(a => a.Priority)
            .ThenBy(a => string.Equals(a.Id, _store.State.SelectedAccountId, StringComparison.Ordinal) ? 0 : 1)
            .ToList();
        var candidates = allCandidates.ToList();
        if (!string.IsNullOrWhiteSpace(excludedAccountId))
            candidates.RemoveAll(a => string.Equals(a.Id, excludedAccountId, StringComparison.Ordinal));
        // If the limited account is the only one that can serve this model,
        // preserve the retry path; there is no alternate account to switch to.
        if (candidates.Count == 0 && allCandidates.Count > 0) candidates = allCandidates;
        var preferred = candidates.FirstOrDefault(a => string.Equals(a.Id, preferredAccountId, StringComparison.Ordinal));
        List<NativeProviderAccount> routes;
        if (preferred is not null && !allowAccountFailoverAfterLimit)
        {
            // A conversation stays on its account for ordinary requests. The
            // limit catch below decides whether another account may be tried.
            routes = [preferred];
        }
        else if (preferred is not null)
        {
            routes = [preferred, .. candidates.Where(a => !string.Equals(a.Id, preferred.Id, StringComparison.Ordinal))];
        }
        else
        {
            // A new conversation takes the account with the most quota left.
            routes = candidates;
        }
        if (routes.Count == 0) throw new NativeProviderException("Connect a provider account before starting a conversation.");
        var failures = new List<string>();
        NativeProviderException? limitFailure = null;
        string? limitAccountId = null;
        foreach (var route in routes)
        {
            var refreshed = false;
            try { return await SendAsync(route, messages, tools, string.IsNullOrWhiteSpace(model) ? null : model, promptCacheKey, ct, effortOverride, contextWindow: contextWindow, nativeCompactionDisabled: nativeCompactionDisabled, cacheComparisonScope: cacheComparisonScope, cacheSession: cacheSession); }
            catch (TaskCanceledException ex) when (!ct.IsCancellationRequested)
            {
                if (limitFailure is null) throw new NativeProviderException($"{route.ProviderName}: {ex.Message}", retryable: true);
                failures.Add($"{route.ProviderName}: {ex.Message}");
            }
            catch (OperationCanceledException) { throw; }
            catch (NativeProviderException ex)
            {
                if (ex.IsLimit)
                {
                    if (limitFailure is null || (limitFailure.RetryAt is null && ex.RetryAt is not null)) limitFailure = ex;
                    limitAccountId = route.Id;
                    failures.Add($"{route.ProviderName}: {ex.Message}");
                    if (!allowAccountFailoverAfterLimit) break;
                    continue;
                }
                if (HasImageAttachments(messages)
                    && VisionProviderCapability.IsImageInputUnsupported(ex.Message, ex.StatusCode))
                {
                    throw ex.MarkImageInputUnsupported();
                }
                failures.Add($"{route.ProviderName}: {ex.Message}");
                if (ex.StatusCode is 401 or 403 && !refreshed && _refresh is not null)
                {
                    refreshed = true;
                    if (await _refresh(route, ct))
                    {
                        try { return await SendAsync(route, messages, tools, string.IsNullOrWhiteSpace(model) ? null : model, promptCacheKey, ct, effortOverride, contextWindow: contextWindow, nativeCompactionDisabled: nativeCompactionDisabled, cacheComparisonScope: cacheComparisonScope, cacheSession: cacheSession); }
                        catch (TaskCanceledException retry) when (!ct.IsCancellationRequested) { failures.Add($"{route.ProviderName}: {retry.Message}"); continue; }
                        catch (HttpRequestException retry) { failures.Add($"{route.ProviderName}: {retry.Message}"); continue; }
                        catch (NativeProviderException retry)
                        {
                            if (retry.IsLimit)
                            {
                                if (limitFailure is null || (limitFailure.RetryAt is null && retry.RetryAt is not null)) limitFailure = retry;
                                limitAccountId = route.Id;
                                failures.Add($"{route.ProviderName}: {retry.Message}");
                                if (!allowAccountFailoverAfterLimit) break;
                                continue;
                            }
                            if (HasImageAttachments(messages)
                                && VisionProviderCapability.IsImageInputUnsupported(retry.Message, retry.StatusCode))
                            {
                                throw retry.MarkImageInputUnsupported();
                            }
                            failures.Add($"{route.ProviderName}: {retry.Message}");
                            if (!retry.Retryable) throw;
                            ex = retry;
                        }
                    }
                }
                if (!ex.Retryable) throw;
                if (limitFailure is null) throw;
            }
            catch (HttpRequestException ex)
            {
                if (limitFailure is null) throw new NativeProviderException($"{route.ProviderName}: {ex.Message}", retryable: true);
                failures.Add($"{route.ProviderName}: {ex.Message}");
            }
        }
        if (limitFailure is not null)
        {
            var message = string.Join(Environment.NewLine, failures);
            throw new NativeProviderException(
                string.IsNullOrWhiteSpace(message) ? limitFailure.Message : message,
                limitFailure.StatusCode,
                retryable: false,
                isLimit: true,
                limitKind: limitFailure.LimitKind,
                providerName: limitFailure.ProviderName,
                retryAt: limitFailure.RetryAt,
                accountId: limitAccountId);
        }
        throw new NativeProviderException(string.Join(Environment.NewLine, failures));
    }

    private static bool HasImageAttachments(IEnumerable<NativeMessage> messages) =>
        messages.Any(message => message.Attachments?.Any(attachment =>
            string.Equals(attachment.Kind, "image", StringComparison.OrdinalIgnoreCase)) == true);

    private async Task<NativeResponse> SendAsync(
        NativeProviderAccount route,
        IReadOnlyList<NativeMessage> messages,
        IReadOnlyList<NativeToolDefinition> tools,
        string? model,
        string? promptCacheKey,
        CancellationToken ct,
        string? effortOverride = null,
        bool expandedBudget = false,
        int? contextWindow = null,
        bool nativeCompactionDisabled = false,
        string? cacheComparisonScope = null,
        NativeCacheSession? cacheSession = null)
    {
        if (route.Protocol == NativeProviderProtocol.ClaudeCli)
            return await ClaudeCliClient.CompleteAsync(messages, model ?? route.Model, effortOverride ?? Effort, ct);
        var preparationStartedAt = DateTimeOffset.UtcNow;
        var key = _store.Secrets.Read(route.CredentialId);
        if ((route.Protocol is NativeProviderProtocol.Anthropic or NativeProviderProtocol.ChatGpt || route.AuthType == "oauth") && string.IsNullOrEmpty(key)) throw new NativeProviderException("The provider credential is unavailable.");
        // No model was requested and the endpoint never named one: its server is
        // down or lists nothing. Sending the prefix/ placeholder would only fail later.
        if (NativeProviderAccount.IsPlaceholderModel(model ?? route.Model))
            throw new NativeProviderException($"{route.Name} lists no models. Start its server or set a model name for the endpoint.");
        var endpoint = Endpoint(route);
        // Tool schemas are part of the provider prefix. Plugin discovery order
        // is not, so canonicalize it before building the request body.
        var orderedTools = AgentCacheNamespace.CanonicalTools(tools);
        // Keep the durable transcript untouched; only the provider-facing view
        // is reduced. This makes the Caveman-style reduction reversible locally.
        var requestMessages = EconomyPolicy.NormalizeToolMessages(messages);
        var effectiveEffort = effortOverride ?? Effort;
        var responseStyle = ResponseStyleResolver.Resolve(
            ResponseStylePreference,
            requestMessages.LastOrDefault(message => message.Role == "user" && message.SystemKind != "contextNotice")?.Content);
        // Standard mode also needs an output ceiling. Maximum reasoning without
        // max_output_tokens can consume the remaining context in one response.
        var budget = EconomyPolicy.Resolve(
            route.Protocol,
            model ?? route.Model,
            effectiveEffort,
            requestMessages,
            orderedTools,
            responseStyle);
        if (expandedBudget && budget is not null)
            budget = budget.Expand(model ?? route.Model, route.Protocol, ContextCompaction.DefaultContextWindow);
        // The wire names of the tools in this request. Anthropic and the OpenAI
        // function protocols only carry ASCII identifiers, while the harness
        // names its own tools `skill.read`.
        var wireNames = ToolWireNames.Map(
            orderedTools.Select(tool => tool.Name)
                .Concat(requestMessages.SelectMany(message => message.ToolCalls?.Select(call => call.Name) ?? Array.Empty<string>())),
            route.Protocol switch
            {
                NativeProviderProtocol.Anthropic => ToolWireNames.Anthropic,
                NativeProviderProtocol.ChatGpt or NativeProviderProtocol.OpenAiResponses => ToolWireNames.Responses,
                _ => ToolWireNames.OpenAi,
            });
        var body = route.Protocol switch
        {
            NativeProviderProtocol.Anthropic => AnthropicBody(route, requestMessages, orderedTools, model, UnsupportedExtendedCacheTtls.ContainsKey(CacheCapabilityKey(route, model ?? route.Model)) ? "5m" : AnthropicCacheTTL, wireNames),
            NativeProviderProtocol.ChatGpt or NativeProviderProtocol.OpenAiResponses => ResponsesBody(route, requestMessages, orderedTools, model, route.Protocol,
                SupportsStaticBreakpoint(route, model ?? route.Model), wireNames),
            _ => OpenAiBody(route, requestMessages, orderedTools, model, wireNames),
        };
        var contextEditingRouteKey = CacheCapabilityKey(route, model ?? route.Model);
        if (route.Protocol == NativeProviderProtocol.Anthropic
            && !UnsupportedAnthropicContextEditingRoutes.ContainsKey(contextEditingRouteKey))
        {
            var percent = UsageMode == AgentUsageMode.Economy ? 90 : Math.Clamp(CompactionThresholdPercent, 0, 100);
            var window = contextWindow ?? route.ContextWindow ?? 200_000;
            var triggerTokens = ContextCompaction.NativeThreshold(window, percent);
            body["context_management"] = new JsonObject
            {
                ["edits"] = new JsonArray(new JsonObject
                {
                    ["type"] = "clear_tool_uses_20250919",
                    ["trigger"] = new JsonObject { ["type"] = "input_tokens", ["value"] = triggerTokens },
                    ["keep"] = new JsonObject { ["type"] = "tool_uses", ["value"] = 3 },
                    // A cleared read_file body would leave the read ledger vouching for
                    // bytes the model no longer sees; local compaction drops those and
                    // forgets the reads together.
                    ["exclude_tools"] = new JsonArray("read_file"),
                    ["clear_at_least"] = new JsonObject
                    {
                        ["type"] = "input_tokens",
                        ["value"] = Math.Max(1, Math.Min(8_192, triggerTokens / 4)),
                    },
                }),
            };
        }
        var compactionRouteKey = $"{route.Id}:{route.Protocol}";
        var nativeCompactionEnabled = !nativeCompactionDisabled
            && SupportsNativeCompaction(route);
        if (nativeCompactionEnabled)
        {
            var percent = UsageMode == AgentUsageMode.Economy ? 90 : Math.Clamp(CompactionThresholdPercent, 0, 100);
            var window = contextWindow ?? (route.Protocol == NativeProviderProtocol.Anthropic ? 200_000 : 128_000);
            body["context_management"] = new JsonArray(new JsonObject
            {
                ["type"] = "compaction",
                ["compact_threshold"] = ContextCompaction.NativeThreshold(window, percent),
            });
        }
        var routeCacheKey = RouteCacheKey(promptCacheKey, route, model ?? route.Model);
        var effectivePromptCacheKey = UnsupportedPromptCacheKeys.ContainsKey(PromptCacheCapabilityKey(route))
            ? null
            : routeCacheKey;
        ApplyPromptCacheKey(body, route.Protocol, effectivePromptCacheKey);
        ApplyEffort(body, route.Protocol, model ?? route.Model, effectiveEffort, budget);
        if (Fast && UsageMode != AgentUsageMode.Economy && route.Protocol == NativeProviderProtocol.Anthropic
            && NativeFastCatalog.Supports(model ?? route.Model))
            body["speed"] = "fast";
        // Verbosity is a cached request setting. It follows the saved mode,
        // never one prompt's wording, so a short question keeps the prefix.
        if (UsageMode != AgentUsageMode.Economy
            && ResponseStylePreference is not (AgentResponseStylePreference.Concise or AgentResponseStylePreference.Ultra))
            body.Remove("text");
        var diagnosticsRoute = CacheCapabilityKey(route, model ?? route.Model);
        var effectiveModel = model ?? route.Model;
        if (SupportsPublicOpenAiCache(route, effectiveModel) && !UnsupportedImplicitRetention.ContainsKey(diagnosticsRoute))
            body["prompt_cache_options"] = new JsonObject { ["mode"] = "implicit", ["ttl"] = "30m" };
        var comparisonKey = cacheComparisonScope is null ? routeCacheKey
            : route.BaseUrl + "|" + route.Id + "|" + route.Protocol + "|" + cacheComparisonScope;
        var cacheDiagnosticsSupported = (route.Protocol is NativeProviderProtocol.ChatGpt or NativeProviderProtocol.OpenAiResponses)
            && (effectiveModel.StartsWith("gpt-6", StringComparison.OrdinalIgnoreCase)
                || System.Text.RegularExpressions.Regex.IsMatch(effectiveModel, @"^gpt-5\.[6-9](?:\D|$)", System.Text.RegularExpressions.RegexOptions.IgnoreCase))
            && !UnsupportedCacheDiagnostics.ContainsKey(diagnosticsRoute);
        string? previousResponse = null;
        if (comparisonKey is not null) _cacheResponseIds.TryGetValue(comparisonKey, out previousResponse);
        if (previousResponse is null && cacheSession is not null)
        {
            var priorScope = AgentCacheNamespace.Fingerprint(route.BaseUrl.ToLowerInvariant() + "|" + route.Id
                + "|" + route.Protocol + "|" + (cacheComparisonScope ?? promptCacheKey ?? "one-off"));
            previousResponse = cacheSession.LastAcceptedResponseIDs.GetValueOrDefault(priorScope)
                ?? cacheSession.Baselines.GetValueOrDefault(priorScope)?.ResponseId;
        }
        if (cacheDiagnosticsSupported && previousResponse is not null)
        {
            var options = body["prompt_cache_options"] as JsonObject ?? new JsonObject();
            options["comparison_response_id"] = previousResponse;
            if (body["prompt_cache_options"] is null) body["prompt_cache_options"] = options;
        }
        var scope = AgentCacheNamespace.Fingerprint(route.BaseUrl.ToLowerInvariant() + "|" + route.Id
            + "|" + route.Protocol + "|" + (cacheComparisonScope ?? promptCacheKey ?? "one-off"));
        NativeCacheBaseline? baseline = null;
        if (cacheSession is not null) cacheSession.Baselines.TryGetValue(scope, out baseline);
        if (route.Protocol == NativeProviderProtocol.Anthropic)
        {
            if (!UnsupportedAnthropicDiagnostics.ContainsKey(diagnosticsRoute))
                body["diagnostics"] = new JsonObject { ["previous_message_id"] =
                    cacheSession?.LastAcceptedResponseIDs.GetValueOrDefault(scope) ?? baseline?.ResponseId };
            ApplyAnthropicCacheBreakpoints(body, UnsupportedExtendedCacheTtls.ContainsKey(CacheCapabilityKey(route, model ?? route.Model)) ? "5m" : AnthropicCacheTTL,
                baseline?.Boundary, baseline?.StaticFingerprint, baseline?.MessageFingerprints);
        }
        var responsesBaseline = route.Protocol is NativeProviderProtocol.ChatGpt or NativeProviderProtocol.OpenAiResponses
            && ReportsExactCacheBoundary(effectiveModel);
        var cacheRequest = NativeCacheRequestEvidence.Capture(body, route.Protocol,
            SupportsPublicOpenAiCache(route, effectiveModel) && body["prompt_cache_options"]?["mode"]?.GetValue<string>() == "implicit", responsesBaseline);
        var effectiveTTL = route.Protocol == NativeProviderProtocol.Anthropic
            ? (UnsupportedExtendedCacheTtls.ContainsKey(CacheCapabilityKey(route, model ?? route.Model)) || AnthropicCacheTTL == "5m" ? 300 : 3600)
            : SupportsPublicOpenAiCache(route, effectiveModel) && body["prompt_cache_options"]?["mode"]?.GetValue<string>() == "implicit" ? 1800
            : (int?)null;

        using var request = new HttpRequestMessage(HttpMethod.Post, endpoint) { Content = new StringContent(body.ToJsonString(), Encoding.UTF8, "application/json") };
        if (!string.IsNullOrEmpty(key))
        {
            if (route.Protocol == NativeProviderProtocol.Anthropic && route.AuthType == "claudeOAuth")
                request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", key);
            else if (route.Protocol == NativeProviderProtocol.Anthropic) request.Headers.TryAddWithoutValidation("x-api-key", key);
            else request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", key);
        }
        if (route.Protocol == NativeProviderProtocol.Anthropic)
        {
            request.Headers.TryAddWithoutValidation("anthropic-version", "2023-06-01");
            if (body["context_management"]?["edits"] is JsonArray)
                request.Headers.TryAddWithoutValidation("anthropic-beta", "context-management-2025-06-27");
            if (body["speed"] is not null)
                request.Headers.TryAddWithoutValidation("anthropic-beta", "fast-mode-2026-02-01");
            if (route.AuthType == "claudeOAuth")
            {
                request.Headers.TryAddWithoutValidation("anthropic-beta", ClaudeOAuthHeaders.Beta);
                request.Headers.TryAddWithoutValidation("anthropic-dangerous-direct-browser-access", "true");
                request.Headers.TryAddWithoutValidation("user-agent", ClaudeOAuthHeaders.UserAgent);
                request.Headers.TryAddWithoutValidation("x-app", "cli");
            }
        }
        if (route.Protocol == NativeProviderProtocol.ChatGpt)
        {
            if (string.IsNullOrWhiteSpace(route.SessionAccountId)) throw new NativeProviderException("The GPT session account is unavailable.");
            request.Headers.TryAddWithoutValidation("Accept", "text/event-stream");
            request.Headers.TryAddWithoutValidation("ChatGPT-Account-ID", route.SessionAccountId);
            request.Headers.TryAddWithoutValidation("OAI-Product-Sku", "codex");
            request.Headers.TryAddWithoutValidation("OpenAI-Beta", "responses=v1");
            request.Headers.TryAddWithoutValidation("originator", "dots_harness");
            request.Headers.TryAddWithoutValidation("User-Agent", $"codex_cli_rs/{ChatGptCodexClientVersion}");
            // The backend routes its prompt cache by session: reuse the
            // conversation's cache key so follow-up turns hit a warm shard.
            // Session affinity remains useful even when the endpoint rejects the
            // optional JSON prompt_cache_key field.
            request.Headers.TryAddWithoutValidation("session_id", string.IsNullOrWhiteSpace(routeCacheKey) ? Guid.NewGuid().ToString() : routeCacheKey);
        }
        NativeProviderTransportHeaders.Apply(request.Headers, route.Provider);
        var prepareMilliseconds = (int)Math.Clamp((DateTimeOffset.UtcNow - preparationStartedAt).TotalMilliseconds, 0, int.MaxValue);
        var requestStartedAt = DateTimeOffset.UtcNow;
        using var response = await _http.SendAsync(request, ct);
        if (response.IsSuccessStatusCode && RateLimitRemaining(response) is { } headerRemaining)
            HeaderUsage[route.Id] = (headerRemaining, RetryAt(response) ?? DateTimeOffset.UtcNow.AddMinutes(1));
        var text = await response.Content.ReadAsStringAsync(ct);
        // A Codex success body is an SSE stream, not JSON. Error bodies stay JSON
        // on every route, so parsing failure here just means "no structured error".
        JsonNode? node;
        try { node = JsonNode.Parse(text); }
        catch (JsonException) { node = null; }
        if (!response.IsSuccessStatusCode)
        {
            var message = node?["error"]?["message"]?.GetValue<string>() ?? node?["message"]?.GetValue<string>() ?? $"HTTP {(int)response.StatusCode}";
            var status = (int)response.StatusCode;
            // A strict OpenAI-style server may reject the unknown field; resend
            // without it. Mirrors NativeAgentClient.complete on macOS.
            if (status is 400 or 422 && SupportsStaticBreakpoint(route, effectiveModel)
                && message.Contains("prompt_cache_breakpoint", StringComparison.OrdinalIgnoreCase))
            {
                UnsupportedStaticBreakpoints.TryAdd(diagnosticsRoute, 0);
                return await SendAsync(route, messages, tools, model, promptCacheKey, ct, effortOverride,
                    expandedBudget, contextWindow, nativeCompactionDisabled, cacheComparisonScope, cacheSession);
            }
            if (status is 400 or 422 && body["prompt_cache_options"]?["mode"] is not null
                && (message.Contains("prompt_cache_options.mode", StringComparison.OrdinalIgnoreCase)
                    || message.Contains("ttl", StringComparison.OrdinalIgnoreCase)
                    || (message.Contains("prompt_cache_options", StringComparison.OrdinalIgnoreCase)
                        && !message.Contains("comparison_response_id", StringComparison.OrdinalIgnoreCase))))
            {
                UnsupportedImplicitRetention.TryAdd(diagnosticsRoute, 0);
                if (message.Contains("prompt_cache_options", StringComparison.OrdinalIgnoreCase)
                    && !message.Contains("mode", StringComparison.OrdinalIgnoreCase)
                    && !message.Contains("ttl", StringComparison.OrdinalIgnoreCase)) UnsupportedCacheDiagnostics.TryAdd(diagnosticsRoute, 0);
                return await SendAsync(route, messages, tools, model, promptCacheKey, ct, effortOverride,
                    expandedBudget, contextWindow, nativeCompactionDisabled, cacheComparisonScope, cacheSession);
            }
            if (status is 400 or 422 && route.Protocol == NativeProviderProtocol.Anthropic
                && body["diagnostics"] is not null && message.Contains("diagnostics", StringComparison.OrdinalIgnoreCase))
            {
                UnsupportedAnthropicDiagnostics.TryAdd(diagnosticsRoute, 0);
                return await SendAsync(route, messages, tools, model, promptCacheKey, ct, effortOverride,
                    expandedBudget, contextWindow, nativeCompactionDisabled, cacheComparisonScope, cacheSession);
            }
            if (status is 400 or 422 && (body["prompt_cache_options"] as JsonObject)?["comparison_response_id"] is not null
                && (message.Contains("prompt_cache_options", StringComparison.OrdinalIgnoreCase)
                    || message.Contains("comparison_response_id", StringComparison.OrdinalIgnoreCase)))
            {
                UnsupportedCacheDiagnostics.TryAdd(diagnosticsRoute, 0);
                return await SendAsync(route, messages, tools, model, promptCacheKey, ct, effortOverride, expandedBudget, contextWindow, nativeCompactionDisabled, cacheComparisonScope, cacheSession);
            }
            if (status is 400 or 422 && route.Protocol == NativeProviderProtocol.Anthropic
                && !UnsupportedExtendedCacheTtls.ContainsKey(CacheCapabilityKey(route, model ?? route.Model))
                && message.Contains("ttl", StringComparison.OrdinalIgnoreCase))
            {
                UnsupportedExtendedCacheTtls.TryAdd(CacheCapabilityKey(route, model ?? route.Model), 0);
                return await SendAsync(route, messages, tools, model, promptCacheKey, ct, effortOverride, expandedBudget, contextWindow, nativeCompactionDisabled, cacheComparisonScope, cacheSession);
            }
            if (status is 400 or 422
                && body["prompt_cache_key"] is not null
                && message.Contains("prompt_cache_key", StringComparison.OrdinalIgnoreCase))
            {
                UnsupportedPromptCacheKeys.TryAdd(PromptCacheCapabilityKey(route), 0);
                return await SendAsync(route, messages, tools, model, promptCacheKey, ct, effortOverride, expandedBudget, contextWindow, nativeCompactionDisabled, cacheComparisonScope, cacheSession);
            }
            if (status is 400 or 422
                && route.Protocol == NativeProviderProtocol.Anthropic
                && body["context_management"]?["edits"] is JsonArray
                && IsAnthropicContextEditingRejection(message))
            {
                UnsupportedAnthropicContextEditingRoutes.TryAdd(contextEditingRouteKey, 0);
                return await SendAsync(route, messages, tools, model, promptCacheKey, ct, effortOverride,
                    expandedBudget, contextWindow, nativeCompactionDisabled, cacheComparisonScope, cacheSession);
            }
            if (status is 400 or 422
                && body["context_management"] is not null
                && IsNativeCompactionRejection(message))
            {
                UnsupportedNativeCompactionRoutes.TryAdd(compactionRouteKey, 0);
                return await SendAsync(
                    route,
                    messages,
                    tools,
                    model,
                    promptCacheKey,
                    ct,
                    effortOverride,
                    expandedBudget,
                    contextWindow,
                    nativeCompactionDisabled: true,
                    cacheComparisonScope: cacheComparisonScope, cacheSession: cacheSession);
            }
            var limitKind = DetectLimitKind(
                string.Join(" ", new[]
                {
                    message,
                    node?["error"]?["type"]?.GetValue<string>() ?? "",
                    node?["error"]?["code"]?.GetValue<string>() ?? "",
                    node?["type"]?.GetValue<string>() ?? "",
                    node?["code"]?.GetValue<string>() ?? "",
                }),
                status);
            throw new NativeProviderException(
                message,
                status,
                status is 408 or 409 or 425 or >= 500,
                limitKind is not null,
                limitKind,
                route.ProviderName,
                retryAt: RetryAt(response));
        }
        var result = route.Protocol switch
        {
            NativeProviderProtocol.Anthropic => node is null ? ParseAnthropicStream(text) : ParseAnthropic(node),
            NativeProviderProtocol.ChatGpt => ParseResponsesStream(text, route.ProviderName),
            NativeProviderProtocol.OpenAiResponses => ParseResponses(node),
            _ => ParseOpenAi(node),
        };
        if (route.AuthType == "claudeOAuth" && result.Message.ToolCalls is { Count: > 0 } oauthCalls)
            result = result with { Message = result.Message with { ToolCalls = oauthCalls.Select(call => call with { Name = ClaudeOAuthHeaders.RestoreToolName(call.Name) }).ToList() } };
        // The provider answered with the wire names; the app dispatches the real ones.
        if (wireNames.Count > 0 && result.Message.ToolCalls is { Count: > 0 } wireCalls)
            result = result with { Message = result.Message with { ToolCalls = wireCalls.Select(call => call with { Name = ToolWireNames.Restore(call.Name, wireNames) }).ToList() } };
        var eventId = Guid.NewGuid().ToString();
        var evidence = cacheRequest.Compare(baseline, result.Usage, requestStartedAt, effectiveTTL);
        if (evidence.Classification == "cold" && cacheSession is { LastEpochReason: not "new_session" } && cacheSession.Baselines.Count == 0)
            evidence = evidence with { Classification = "changed", Reason = cacheSession.LastEpochReason };
        var latency = (int)Math.Clamp((DateTimeOffset.UtcNow - requestStartedAt).TotalMilliseconds, 0, int.MaxValue);
        result = result with { CacheReuseEvidence = evidence, EffectiveCacheTTLSeconds = effectiveTTL,
            LatencyMilliseconds = latency };
        if (cacheSession is not null)
        {
            var usageScope = AgentCacheNamespace.Fingerprint(scope + "|" + effectiveModel);
            var routeFingerprint = AgentCacheNamespace.Fingerprint(route.BaseUrl.ToLowerInvariant()
                + "|" + route.Id + "|" + route.Protocol + "|" + effectiveModel);
            cacheSession.AppendEvent(new NativeCacheUsageEvent(eventId, requestStartedAt, usageScope, result.Usage,
                evidence, latency, PrepareMilliseconds: prepareMilliseconds, RouteFingerprint: routeFingerprint,
                Local: Uri.TryCreate(route.BaseUrl, UriKind.Absolute, out var baseUri) && baseUri.IsLoopback));
            var accepted = cacheRequest.Accepted(eventId, requestStartedAt, result.Usage, effectiveTTL, result.ResponseId);
            // A smaller extent cannot prove that the current terminal boundary was
            // written. Keep the last proven checkpoint without refreshing its expiry.
            var retainCheckpoint = baseline?.TerminalCacheTokens is > 0
                && baseline.SettingsFingerprint == cacheRequest.SettingsFingerprint
                && cacheRequest.Retains(baseline)
                && baseline.EffectiveTTLSeconds is { } previousTTL
                && (requestStartedAt - baseline.WrittenAt).TotalSeconds < previousTTL
                && (accepted.TerminalCacheTokens is null || accepted.TerminalCacheTokens < baseline.TerminalCacheTokens);
            if (!retainCheckpoint) cacheSession.Baselines[scope] = accepted;
            if (result.ResponseId is not null) cacheSession.LastAcceptedResponseIDs[scope] = result.ResponseId;
        }
        // A soft style/economy ceiling may get one bounded correctness retry;
        // a strict user limit is never expanded because it is an upper bound.
        if ((UsageMode == AgentUsageMode.Economy || responseStyle.IsShort)
            && string.Equals(result.IncompleteReason, "max_output_tokens", StringComparison.OrdinalIgnoreCase)
            && !expandedBudget
            && !responseStyle.IsHardLimit)
        {
            EconomyPolicy.RecordReasoning(route.Protocol, model ?? route.Model, effectiveEffort, result.Usage?.ReasoningTokens);
            var retry = await SendAsync(
                route,
                messages,
                tools,
                model,
                promptCacheKey,
                ct,
                effortOverride,
                expandedBudget: true,
                contextWindow: contextWindow,
                nativeCompactionDisabled: nativeCompactionDisabled,
                cacheComparisonScope: cacheComparisonScope, cacheSession: cacheSession);
            return retry with { RetryCount = retry.RetryCount + 1, RetryUsage = result.Usage };
        }
        EconomyPolicy.RecordReasoning(route.Protocol, model ?? route.Model, effectiveEffort, result.Usage?.ReasoningTokens);
        if (comparisonKey is not null && result.ResponseId is not null)
        {
            if (_cacheResponseIds.Count >= 2000) _cacheResponseIds.Clear();
            _cacheResponseIds[comparisonKey] = result.ResponseId;
        }
        return result with { AccountId = route.Id };
    }

    internal static bool SupportsPublicOpenAiCache(NativeProviderAccount route, string model) =>
        route.Protocol == NativeProviderProtocol.OpenAiResponses
        && Uri.TryCreate(route.BaseUrl, UriKind.Absolute, out var endpoint)
        && endpoint.Host.Equals("api.openai.com", StringComparison.OrdinalIgnoreCase)
        && ReportsExactCacheBoundary(model);

    /// GPT-5.6+ reports the exact eligible boundary; older models round it.
    private static bool ReportsExactCacheBoundary(string model) =>
        model.StartsWith("gpt-6", StringComparison.OrdinalIgnoreCase)
        || System.Text.RegularExpressions.Regex.IsMatch(model, @"^gpt-5\.(?:[6-9]|[1-9][0-9]+)(?:\D|$)",
            System.Text.RegularExpressions.RegexOptions.IgnoreCase);

    internal static bool SupportsStaticBreakpoint(NativeProviderAccount route, string model) =>
        SupportsPublicOpenAiCache(route, model)
        && !UnsupportedStaticBreakpoints.ContainsKey(CacheCapabilityKey(route, model));

    private static string CacheCapabilityKey(NativeProviderAccount route, string model) =>
        route.BaseUrl + "|" + route.Protocol + "|" + route.Id + "|" + model;

    private static bool IsNativeCompactionRejection(string message) =>
        message.Contains("context_management", StringComparison.OrdinalIgnoreCase)
        || message.Contains("compact_threshold", StringComparison.OrdinalIgnoreCase)
        || message.Contains("compaction", StringComparison.OrdinalIgnoreCase);

    private static bool IsAnthropicContextEditingRejection(string message) =>
        message.Contains("context_management", StringComparison.OrdinalIgnoreCase)
        || message.Contains("context-management", StringComparison.OrdinalIgnoreCase)
        || message.Contains("clear_tool_uses", StringComparison.OrdinalIgnoreCase);

    private static bool CanServe(NativeProviderAccount account, string? model)
    {
        if (string.IsNullOrWhiteSpace(model) || string.Equals(account.Model, model, StringComparison.Ordinal)) return true;
        return (account.Models ?? []).Contains(model, StringComparer.Ordinal);
    }

    private static void ApplyPromptCacheKey(JsonObject body, NativeProviderProtocol protocol, string? promptCacheKey)
    {
        if (string.IsNullOrWhiteSpace(promptCacheKey)) return;
        // OpenAI-compatible and Responses transports accept the stable cache
        // shard key. Anthropic uses cache_control breakpoints instead; adding
        // an unknown field there would make otherwise valid requests fail.
        if (protocol is NativeProviderProtocol.OpenAiCompatible or NativeProviderProtocol.ChatGpt or NativeProviderProtocol.OpenAiResponses)
            body["prompt_cache_key"] = promptCacheKey;
    }

    private static string? RouteCacheKey(string? baseKey, NativeProviderAccount route, string model)
    {
        if (string.IsNullOrWhiteSpace(baseKey)) return null;
        var identity = $"{baseKey}|{route.Provider}|{route.Protocol}|{route.Id}|{model}";
        var digest = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(identity))).ToLowerInvariant();
        return $"{baseKey}:route-{digest[..24]}";
    }

    private static string PromptCacheCapabilityKey(NativeProviderAccount route) =>
        $"{route.Id}|{route.Protocol}|{route.BaseUrl.Trim().ToLowerInvariant()}";

    private static NativeProviderLimitKind? DetectLimitKind(string message, int status)
    {
        if (status == 429 || message.Contains("rate limit", StringComparison.OrdinalIgnoreCase) || message.Contains("rate-limit", StringComparison.OrdinalIgnoreCase) || message.Contains("rate_limit", StringComparison.OrdinalIgnoreCase)) return NativeProviderLimitKind.Rate;
        if (status == 402) return NativeProviderLimitKind.Balance;
        if (message.Contains("quota", StringComparison.OrdinalIgnoreCase)) return NativeProviderLimitKind.Quota;
        if (message.Contains("credit", StringComparison.OrdinalIgnoreCase)) return NativeProviderLimitKind.Credits;
        if (message.Contains("usage limit", StringComparison.OrdinalIgnoreCase) || message.Contains("usage-limit", StringComparison.OrdinalIgnoreCase) || message.Contains("usage_limit", StringComparison.OrdinalIgnoreCase) || message.Contains("provider limit", StringComparison.OrdinalIgnoreCase) || message.Contains("provider_limit", StringComparison.OrdinalIgnoreCase) || message.Contains("resource exhausted", StringComparison.OrdinalIgnoreCase) || message.Contains("too many requests", StringComparison.OrdinalIgnoreCase) || message.Contains("billing limit", StringComparison.OrdinalIgnoreCase) || message.Contains("billing_limit", StringComparison.OrdinalIgnoreCase)) return NativeProviderLimitKind.Usage;
        if (message.Contains("insufficient balance", StringComparison.OrdinalIgnoreCase) || message.Contains("insufficient_balance", StringComparison.OrdinalIgnoreCase) || message.Contains("insufficient funds", StringComparison.OrdinalIgnoreCase) || message.Contains("insufficient_quota", StringComparison.OrdinalIgnoreCase)) return NativeProviderLimitKind.Balance;
        return null;
    }

    private static DateTimeOffset? RetryAt(HttpResponseMessage response, DateTimeOffset? now = null)
    {
        var current = now ?? DateTimeOffset.UtcNow;
        if (response.Headers.RetryAfter?.Delta is { } delta && delta > TimeSpan.Zero)
        {
            return current.Add(delta);
        }
        if (response.Headers.RetryAfter?.Date is { } date && date > current)
        {
            return date;
        }

        var names = new[]
        {
            "retry-after",
            "anthropic-ratelimit-unified-reset",
            "x-ratelimit-reset-requests",
            "x-ratelimit-reset-tokens",
            "x-ratelimit-reset",
        };
        foreach (var name in names)
        {
            var raw = response.Headers.TryGetValues(name, out var values)
                ? values.FirstOrDefault()
                : response.Content.Headers.TryGetValues(name, out var contentValues)
                    ? contentValues.FirstOrDefault()
                    : null;
            raw = raw?.Trim();
            if (string.IsNullOrWhiteSpace(raw)) continue;
            if (double.TryParse(raw, NumberStyles.Float, CultureInfo.InvariantCulture, out var seconds))
            {
                var candidate = seconds > 10_000_000
                    ? DateTimeOffset.FromUnixTimeSeconds((long)seconds)
                    : current.AddSeconds(seconds);
                if (candidate > current) return candidate;
                continue;
            }
            if (DateTimeOffset.TryParse(
                raw,
                CultureInfo.InvariantCulture,
                DateTimeStyles.AllowWhiteSpaces | DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal,
                out var parsed)
                && parsed > current)
            {
                return parsed;
            }
        }
        return null;
    }

    private static Uri Endpoint(NativeProviderAccount route)
    {
        var normalized = NativeProviderStore.NormalizeUrl(route.BaseUrl).TrimEnd('/');
        if (route.Protocol is NativeProviderProtocol.ChatGpt or NativeProviderProtocol.OpenAiResponses)
        {
            if (route.Protocol == NativeProviderProtocol.OpenAiResponses && new Uri(normalized).AbsolutePath == "/") normalized += "/v1";
            return new Uri(normalized + "/responses");
        }
        if (new Uri(normalized).AbsolutePath == "/") normalized += "/v1";
        var path = normalized + (route.Protocol == NativeProviderProtocol.Anthropic ? "/messages" : "/chat/completions");
        if (route.Protocol == NativeProviderProtocol.Anthropic && route.AuthType == "claudeOAuth") path += "?beta=true";
        return new Uri(path);
    }

    /// Mirrors NativeAgentClient.swift: Anthropic output_config + larger budget,
    /// Responses `reasoning`, Chat Completions `reasoning_effort`.
    private static void ApplyEffort(
        JsonObject body,
        NativeProviderProtocol protocol,
        string model,
        string effort,
        EconomyOutputBudget? economyBudget = null)
    {
        var effortSupported = !string.IsNullOrEmpty(effort) && NativeEffortCatalog.Levels(model).Contains(effort);
        if (economyBudget is not null)
        {
            switch (protocol)
            {
                case NativeProviderProtocol.Anthropic:
                    body["max_tokens"] = economyBudget.MaxOutputTokens;
                    if (effortSupported
                        && EconomyPolicy.SupportsLegacyThinkingBudget(model)
                        && economyBudget.ProviderReasoningBudgetTokens is { } reasoningBudget)
                    {
                        body["thinking"] = new JsonObject
                        {
                            ["type"] = "enabled",
                            ["budget_tokens"] = reasoningBudget,
                        };
                    }
                    else if (effortSupported && !EconomyPolicy.SupportsLegacyThinkingBudget(model))
                    {
                        // Adaptive-thinking models use effort/output_config;
                        // legacy extended-thinking models use thinking only.
                        body["output_config"] = new JsonObject { ["effort"] = effort };
                    }
                    break;
                case NativeProviderProtocol.ChatGpt:
                case NativeProviderProtocol.OpenAiResponses:
                    body["max_output_tokens"] = economyBudget.MaxOutputTokens;
                    body["text"] = new JsonObject { ["verbosity"] = "low" };
                    if (effortSupported) body["reasoning"] = new JsonObject { ["effort"] = effort };
                    break;
                default:
                    body["max_tokens"] = economyBudget.MaxOutputTokens;
                    if (effortSupported) body["reasoning_effort"] = effort;
                    break;
            }
            return;
        }
        if (!effortSupported) return;
        switch (protocol)
        {
            case NativeProviderProtocol.Anthropic:
                body["output_config"] = new JsonObject { ["effort"] = effort };
                body["max_tokens"] = effort switch { "max" => 32_000, "xhigh" => 24_000, "high" => 16_000, _ => 8_192 };
                break;
            case NativeProviderProtocol.ChatGpt:
            case NativeProviderProtocol.OpenAiResponses:
                body["reasoning"] = new JsonObject { ["effort"] = effort };
                break;
            default:
                body["reasoning_effort"] = effort;
                break;
        }
    }

    private static JsonObject OpenAiBody(NativeProviderAccount route, IReadOnlyList<NativeMessage> messages, IReadOnlyList<NativeToolDefinition> tools, string? model,
        IReadOnlyDictionary<string, string>? wireNames = null)
    {
        messages = ContextCompaction.ProviderContextMessages(messages);
        var wireMessages = new JsonArray();
        foreach (var message in messages)
        {
            wireMessages.Add(MessageNode(message, wireNames));
            if (message.Role == "tool" && message.Attachments is { Count: > 0 })
            {
                wireMessages.Add(new JsonObject
                {
                    ["role"] = "user",
                    ["content"] = OpenAiContent(message),
                });
            }
        }
        var body = new JsonObject { ["model"] = model ?? route.Model, ["messages"] = wireMessages, ["temperature"] = 0.2 };
        if (tools.Count > 0) body["tools"] = new JsonArray(tools.Select(tool => new JsonObject { ["type"] = "function", ["function"] = new JsonObject { ["name"] = WireName(tool.Name, wireNames), ["description"] = tool.Description, ["parameters"] = tool.Parameters.DeepClone() } }).ToArray());
        return body;
    }

    /// <summary>The wire name of a tool, or the name itself when nothing had to change.</summary>
    private static string WireName(string name, IReadOnlyDictionary<string, string>? wireNames) =>
        wireNames is null || wireNames.Count == 0 ? name : ToolWireNames.For(name, wireNames);

    private static JsonObject ResponsesBody(
        NativeProviderAccount route,
        IReadOnlyList<NativeMessage> messages,
        IReadOnlyList<NativeToolDefinition> tools,
        string? model,
        NativeProviderProtocol protocol,
        bool staticBreakpoint = false,
        IReadOnlyDictionary<string, string>? wireNames = null)
    {
        messages = ContextCompaction.ProviderContextMessages(NativePromptHistory.ResponsesReplay(messages));
        var systemMessages = messages.Where(message => message.Role == "system"
            && !string.IsNullOrWhiteSpace(message.Content)).ToList();
        var system = systemMessages.Select(message => message.Content).ToList();
        var stableIndex = systemMessages.FindLastIndex(message => message.SystemKind == "promptStable");
        if (stableIndex < 0 && systemMessages.Count > 0) stableIndex = 0;
        var input = new JsonArray();
        // The Codex subscription backend validates its own instructions, so DOTS
        // system content travels as developer input. The public Responses API
        // accepts the system prompt through `instructions`.
        if (protocol == NativeProviderProtocol.ChatGpt || staticBreakpoint)
        {
            for (var systemIndex = 0; systemIndex < system.Count; systemIndex++)
            {
                var block = new JsonObject { ["type"] = "input_text", ["text"] = system[systemIndex] };
                if (staticBreakpoint && systemIndex == stableIndex)
                    block["prompt_cache_breakpoint"] = new JsonObject { ["mode"] = "explicit" };
                input.Add(new JsonObject { ["role"] = "developer", ["content"] = new JsonArray(block) });
            }
        }
        foreach (var message in messages.Where(message => message.Role != "system"))
        {
            if (message.ProviderItems is { Count: > 0 }
                && message.ProviderItems.All(item => Str(item["type"]) is "message" or "function_call"
                    or "function_call_output" or "reasoning" or "compaction"))
            {
                foreach (var item in message.ProviderItems)
                {
                    var copy = item.DeepClone().AsObject();
                    // A replayed function_call still carries the wire name it had
                    // when the provider answered it.
                    if (copy["type"]?.GetValue<string>() == "function_call"
                        && copy["name"]?.GetValue<string>() is { } replayed)
                    {
                        copy["name"] = WireName(replayed, wireNames);
                    }
                    input.Add(copy);
                }
            }
            else if (message.Role == "tool")
            {
                input.Add(new JsonObject { ["type"] = "function_call_output", ["call_id"] = message.ToolCallId ?? "tool", ["output"] = message.Content });
                if (message.Attachments is { Count: > 0 })
                {
                    input.Add(new JsonObject { ["role"] = "user", ["content"] = ResponsesContent(message) });
                }
            }
            else if (message.Role == "assistant" && message.ToolCalls is { Count: > 0 })
            {
                if (!string.IsNullOrEmpty(message.Content)) input.Add(new JsonObject { ["role"] = "assistant", ["content"] = new JsonArray(new JsonObject { ["type"] = "output_text", ["text"] = message.Content }) });
                foreach (var call in message.ToolCalls)
                    input.Add(new JsonObject { ["type"] = "function_call", ["call_id"] = call.Id, ["name"] = WireName(call.Name, wireNames), ["arguments"] = call.Arguments });
            }
            else
            {
                var role = message.Role == "assistant" ? "assistant" : "user";
                var type = role == "assistant" ? "output_text" : "input_text";
                var content = message.Attachments is { Count: > 0 }
                    ? ResponsesContent(message)
                    : new JsonArray(new JsonObject { ["type"] = type, ["text"] = message.Content });
                input.Add(new JsonObject { ["role"] = role, ["content"] = content });
            }
        }
        var body = new JsonObject
        {
            ["model"] = model ?? route.Model,
            ["instructions"] = protocol == NativeProviderProtocol.ChatGpt
                ? CodexInstructions.Default
                : string.Join("\n\n", system),
            ["input"] = input,
            ["store"] = false,
            ["stream"] = protocol == NativeProviderProtocol.ChatGpt,
        };
        if (staticBreakpoint)
        {
            body.Remove("instructions");
        }
        if (tools.Count > 0) body["tools"] = new JsonArray(tools.Select(tool => new JsonObject { ["type"] = "function", ["name"] = WireName(tool.Name, wireNames), ["description"] = tool.Description, ["parameters"] = tool.Parameters.DeepClone() }).ToArray());
        return body;
    }

    private static JsonNode MessageNode(NativeMessage message, IReadOnlyDictionary<string, string>? wireNames = null)
    {
        JsonNode content = message.Role != "tool" && message.Attachments is { Count: > 0 }
            ? OpenAiContent(message)
            : JsonNodeValue.Create(message.Content)!;
        var node = new JsonObject { ["role"] = message.Role, ["content"] = content };
        if (message.ToolCallId is not null) node["tool_call_id"] = message.ToolCallId;
        if (message.ToolCalls is { Count: > 0 }) node["tool_calls"] = new JsonArray(message.ToolCalls.Select(call => new JsonObject { ["id"] = call.Id, ["type"] = "function", ["function"] = new JsonObject { ["name"] = WireName(call.Name, wireNames), ["arguments"] = call.Arguments } }).ToArray());
        return node;
    }

    private static JsonObject AnthropicBody(NativeProviderAccount route, IReadOnlyList<NativeMessage> messages, IReadOnlyList<NativeToolDefinition> tools, string? model, string ttl = "1h",
        IReadOnlyDictionary<string, string>? wireNames = null)
    {
        messages = ContextCompaction.ProviderContextMessages(messages);
        var converted = new JsonArray();
        foreach (var message in messages.Where(m => m.Role != "system")) converted.Add(AnthropicMessageNode(message, wireNames));
        var body = new JsonObject { ["model"] = model ?? route.Model, ["max_tokens"] = 4096, ["messages"] = converted };
        var system = string.Join("\n\n", messages.Where(m => m.Role == "system").Select(m => m.Content).Where(content => !string.IsNullOrWhiteSpace(content)));
        if (route.AuthType == "claudeOAuth")
        {
            var systemBlocks = new JsonArray
            {
                new JsonObject { ["type"] = "text", ["text"] = ClaudeOAuthHeaders.AgentIdentity },
            };
            if (!string.IsNullOrEmpty(system)) systemBlocks.Add(new JsonObject { ["type"] = "text", ["text"] = system });
            body["system"] = systemBlocks;
        }
        else if (!string.IsNullOrEmpty(system)) body["system"] = system;
        if (tools.Count > 0) body["tools"] = new JsonArray(tools.Select(t => new JsonObject { ["name"] = WireName(t.Name, wireNames), ["description"] = t.Description, ["input_schema"] = t.Parameters.DeepClone() }).ToArray());
        if (route.AuthType == "claudeOAuth") ClaudeOAuthHeaders.CloakTools(body);
        else CloakAnthropicToolNames(body, wireNames);
        ApplyAnthropicCacheBreakpoints(body, ttl);
        return body;
    }

    /// <summary>
    /// Renames the dotted tool names in an Anthropic body, in the tool list and
    /// in the tool_use blocks of the history. The OAuth cloak does this on its
    /// own; the API-key path needs it too, because Anthropic only accepts
    /// ASCII identifiers.
    /// </summary>
    private static void CloakAnthropicToolNames(JsonObject body, IReadOnlyDictionary<string, string>? wireNames)
    {
        if (wireNames is null || wireNames.Count == 0) return;
        if (body["tools"] is JsonArray tools)
        {
            foreach (var tool in tools.OfType<JsonObject>())
            {
                if (tool["name"]?.GetValue<string>() is not { } name) continue;
                tool["name"] = WireName(name, wireNames);
            }
        }
        if (body["messages"] is not JsonArray messages) return;
        foreach (var message in messages.OfType<JsonObject>())
        {
            if (message["content"] is not JsonArray content) continue;
            foreach (var block in content.OfType<JsonObject>())
            {
                if (block["type"]?.GetValue<string>() != "tool_use") continue;
                if (block["name"]?.GetValue<string>() is not { } name) continue;
                block["name"] = WireName(name, wireNames);
            }
        }
    }

    /// Mirrors applyAnthropicCacheBreakpoints in NativeAgentClient.swift: one
    /// `cache_control` breakpoint on the system prompt, the last tool and the
    /// last message, so each turn reads the previous turn's prefix from the
    /// prompt cache. Below the minimum cacheable length Anthropic ignores it.
    internal static void ApplyAnthropicCacheBreakpoints(JsonObject body, string ttl = "1h",
        NativeCacheBoundary? previousBoundary = null, string? previousStaticFingerprint = null,
        IReadOnlyList<string>? previousMessageFingerprints = null)
    {
        var clean = NativeCacheRequestEvidence.WithoutMarkers(body)!.AsObject();
        foreach (var key in new[] { "system", "tools", "messages" })
            if (clean[key] is { } value) body[key] = value.DeepClone();
        if (body["system"] is JsonNodeValue systemValue && systemValue.TryGetValue<string>(out var system) && system.Length > 0)
            body["system"] = new JsonArray(new JsonObject { ["type"] = "text", ["text"] = system });
        if (body["system"] is JsonArray { Count: > 0 } systemBlocks && systemBlocks[^1] is JsonObject lastSystem)
            lastSystem["cache_control"] = Ephemeral(ttl);
        if (body["tools"] is JsonArray { Count: > 0 } tools && tools[^1] is JsonObject lastTool)
            lastTool["cache_control"] = Ephemeral(ttl);
        if (body["messages"] is not JsonArray { Count: > 0 } messages) return;
        // Normalize content before computing the persisted wire fingerprints.
        foreach (var node in messages)
        {
            if (node is JsonObject message && message["content"] is JsonNodeValue value
                && value.TryGetValue<string>(out var text))
                message["content"] = new JsonArray(new JsonObject { ["type"] = "text", ["text"] = text });
        }
        var request = NativeCacheRequestEvidence.Capture(body, NativeProviderProtocol.Anthropic);
        if (previousBoundary is { } old && previousMessageFingerprints is not null
            && previousStaticFingerprint == request.StaticFingerprint
            && previousMessageFingerprints.Count <= request.MessageFingerprints.Count
            && previousMessageFingerprints.SequenceEqual(request.MessageFingerprints.Take(previousMessageFingerprints.Count)))
            Mark(old);
        if (messages[^1]?["content"] is JsonArray { Count: > 0 } tail)
            Mark(new NativeCacheBoundary(messages.Count - 1, tail.Count - 1));

        void Mark(NativeCacheBoundary location)
        {
            if (location.MessageIndex < 0 || location.MessageIndex >= messages.Count
                || messages[location.MessageIndex]?["content"] is not JsonArray blocks
                || location.BlockIndex < 0 || location.BlockIndex >= blocks.Count
                || blocks[location.BlockIndex] is not JsonObject block) return;
            // Thinking blocks may be cached only beneath a later eligible block.
            if (Str(block["type"]) is "thinking" or "redacted_thinking") return;
            block["cache_control"] = Ephemeral(ttl);
        }
    }

    private static JsonObject Ephemeral(string ttl) => new() { ["type"] = "ephemeral", ["ttl"] = ttl == "5m" ? "5m" : "1h" };

    private static JsonObject AnthropicMessageNode(NativeMessage message, IReadOnlyDictionary<string, string>? wireNames = null)
    {
        if (message.Role == "tool")
        {
            JsonNode resultContent = message.Attachments is { Count: > 0 }
                ? AnthropicContent(message)
                : JsonNodeValue.Create(message.Content)!;
            return new JsonObject
            {
                ["role"] = "user",
                ["content"] = new JsonArray(new JsonObject
                {
                    ["type"] = "tool_result",
                    ["tool_use_id"] = message.ToolCallId ?? "tool",
                    ["content"] = resultContent,
                }),
            };
        }

        if (message.Role == "assistant" && message.ProviderItems is { Count: > 0 }
            && message.ProviderItems.All(item => Str(item["type"]) is "text" or "thinking" or "redacted_thinking" or "tool_use"))
            return new JsonObject { ["role"] = "assistant",
                ["content"] = new JsonArray(message.ProviderItems.Select(item => item.DeepClone()).ToArray()) };
        if (message.Role == "assistant" && message.ToolCalls is { Count: > 0 })
        {
            var blocks = new JsonArray();
            if (!string.IsNullOrEmpty(message.Content)) blocks.Add(new JsonObject { ["type"] = "text", ["text"] = message.Content });
            foreach (var call in message.ToolCalls)
            {
                JsonNode input;
                try { input = JsonNode.Parse(call.Arguments) ?? new JsonObject(); }
                catch { input = new JsonObject(); }
                blocks.Add(new JsonObject { ["type"] = "tool_use", ["id"] = call.Id, ["name"] = WireName(call.Name, wireNames), ["input"] = input });
            }
            return new JsonObject { ["role"] = "assistant", ["content"] = blocks };
        }

        JsonNode content = message.Attachments is { Count: > 0 }
            ? AnthropicContent(message)
            : new JsonArray(new JsonObject { ["type"] = "text", ["text"] = message.Content });
        return new JsonObject { ["role"] = message.Role == "assistant" ? "assistant" : "user", ["content"] = content };
    }

    private const long MaxInlineImageBytes = 20L * 1024 * 1024;
    private const long MaxInlineFileBytes = 50L * 1024 * 1024;

    private static JsonArray OpenAiContent(NativeMessage message)
    {
        var blocks = new JsonArray();
        if (!string.IsNullOrEmpty(message.Content)) blocks.Add(new JsonObject { ["type"] = "text", ["text"] = message.Content });
        foreach (var attachment in message.Attachments ?? Enumerable.Empty<NativeAttachment>())
        {
            if (TryReadInlineImage(attachment, out var base64))
            {
                blocks.Add(new JsonObject
                {
                    ["type"] = "image_url",
                    ["image_url"] = new JsonObject { ["url"] = DataUrl(attachment, base64) },
                });
            }
            else if (TryReadInlineFile(attachment, out var fileBase64))
            {
                blocks.Add(new JsonObject
                {
                    ["type"] = "file",
                    ["file"] = new JsonObject
                    {
                        ["filename"] = attachment.Name,
                        ["file_data"] = DataUrl(attachment, fileBase64),
                    },
                });
            }
            else
            {
                blocks.Add(new JsonObject { ["type"] = "text", ["text"] = UnsupportedAttachmentNotice(attachment) });
            }
        }
        return blocks;
    }

    private static JsonArray ResponsesContent(NativeMessage message)
    {
        var blocks = new JsonArray();
        if (!string.IsNullOrEmpty(message.Content)) blocks.Add(new JsonObject { ["type"] = "input_text", ["text"] = message.Content });
        foreach (var attachment in message.Attachments ?? Enumerable.Empty<NativeAttachment>())
        {
            if (TryReadInlineImage(attachment, out var base64))
            {
                blocks.Add(new JsonObject { ["type"] = "input_image", ["image_url"] = DataUrl(attachment, base64) });
            }
            else if (TryReadInlineFile(attachment, out var fileBase64))
            {
                blocks.Add(new JsonObject
                {
                    ["type"] = "input_file",
                    ["filename"] = attachment.Name,
                    ["file_data"] = DataUrl(attachment, fileBase64),
                });
            }
            else
            {
                blocks.Add(new JsonObject { ["type"] = "input_text", ["text"] = UnsupportedAttachmentNotice(attachment) });
            }
        }
        return blocks;
    }

    private static JsonArray AnthropicContent(NativeMessage message)
    {
        var blocks = new JsonArray();
        if (!string.IsNullOrEmpty(message.Content)) blocks.Add(new JsonObject { ["type"] = "text", ["text"] = message.Content });
        foreach (var attachment in message.Attachments ?? Enumerable.Empty<NativeAttachment>())
        {
            if (TryReadInlineImage(attachment, out var base64))
            {
                blocks.Add(new JsonObject
                {
                    ["type"] = "image",
                    ["source"] = new JsonObject
                    {
                        ["type"] = "base64",
                        ["media_type"] = attachment.MimeType,
                        ["data"] = base64,
                    },
                });
            }
            else if (IsPdf(attachment) && TryReadInlineFile(attachment, out var documentBase64))
            {
                blocks.Add(new JsonObject
                {
                    ["type"] = "document",
                    ["source"] = new JsonObject
                    {
                        ["type"] = "base64",
                        ["media_type"] = "application/pdf",
                        ["data"] = documentBase64,
                    },
                });
            }
            else
            {
                blocks.Add(new JsonObject { ["type"] = "text", ["text"] = UnsupportedAttachmentNotice(attachment) });
            }
        }
        return blocks;
    }

    // ponytail: inline images are capped at 20 MB; use provider file uploads if larger media needs model input.
    private static bool TryReadInlineImage(NativeAttachment attachment, out string base64)
    {
        base64 = "";
        if (!string.Equals(attachment.Kind, "image", StringComparison.OrdinalIgnoreCase)) return false;
        try
        {
            var info = new FileInfo(attachment.FilePath);
            if (!info.Exists || info.Length > MaxInlineImageBytes) return false;
            base64 = Convert.ToBase64String(File.ReadAllBytes(info.FullName));
            return true;
        }
        catch
        {
            return false;
        }
    }

    private static bool TryReadInlineFile(NativeAttachment attachment, out string base64)
    {
        base64 = "";
        if (!string.Equals(attachment.Kind, "file", StringComparison.OrdinalIgnoreCase)) return false;
        try
        {
            var info = new FileInfo(attachment.FilePath);
            if (!info.Exists || info.Length > MaxInlineFileBytes) return false;
            base64 = Convert.ToBase64String(File.ReadAllBytes(info.FullName));
            return true;
        }
        catch
        {
            return false;
        }
    }

    private static bool IsPdf(NativeAttachment attachment) =>
        string.Equals(attachment.MimeType, "application/pdf", StringComparison.OrdinalIgnoreCase)
        || attachment.Name.EndsWith(".pdf", StringComparison.OrdinalIgnoreCase);

    private static string DataUrl(NativeAttachment attachment, string base64) =>
        $"data:{(string.IsNullOrWhiteSpace(attachment.MimeType) ? "application/octet-stream" : attachment.MimeType)};base64,{base64}";

    private static string UnsupportedAttachmentNotice(NativeAttachment attachment)
    {
        var id = attachment.AttachmentId ?? attachment.Name;
        if (string.IsNullOrWhiteSpace(attachment.FilePath))
            return $"source_missing: attachment_id {id}; historical_revision_preserved; latest_revision_unavailable";
        return $"unsupported_attachment_kind: {attachment.Kind}; attachment_id: {id}; name: {attachment.Name}. The host did not silently drop this attachment, but this provider route does not support its wire format.";
    }

    private static NativeResponse ParseOpenAi(JsonNode? node)
    {
        var message = node?["choices"]?[0]?["message"] ?? throw new NativeProviderException("The provider returned no message.");
        var calls = new List<NativeToolCall>();
        foreach (var item in message["tool_calls"]?.AsArray() ?? new JsonArray()) calls.Add(new NativeToolCall(item?["id"]?.GetValue<string>() ?? Guid.NewGuid().ToString(), item?["function"]?["name"]?.GetValue<string>() ?? "tool", item?["function"]?["arguments"]?.GetValue<string>() ?? "{}"));
        var usage = node?["usage"] is JsonObject u ? ParseUsage(u) : null;
        var reasoning = message["reasoning_content"]?.GetValue<string>() ?? message["reasoning"]?.GetValue<string>();
        var incompleteReason = node?["choices"]?[0]?["finish_reason"]?.GetValue<string>() == "length"
            ? "max_output_tokens"
            : null;
        return new NativeResponse(new NativeMessage("assistant", message["content"]?.GetValue<string>() ?? "", ToolCalls: calls, Thinking: reasoning), usage, incompleteReason);
    }

    /// <summary>
    /// The Codex `/responses` endpoint answers only as an SSE stream, and its
    /// terminal `response.completed` payload ships an EMPTY `output` array -
    /// content lives solely in the incremental events. So the stream itself is
    /// the source of truth for text and tool calls; `response.completed` only
    /// contributes usage (and the output blocks, on backends that do send them).
    ///
    /// Mirrors responseFromSSE in macos/.../NativeAgentClient.swift.
    /// </summary>
    public static NativeResponse ParseResponsesStream(string body, string? providerName = null)
    {
        var trimmed = body.TrimStart();
        // Some gateways in front of the same protocol answer as plain JSON.
        if (trimmed.StartsWith('{') || trimmed.StartsWith('['))
        {
            return ParseResponses(JsonNode.Parse(body));
        }

        JsonNode? finalResponse = null;
        var text = new StringBuilder();
        var callOrder = new List<string>();
        var calls = new Dictionary<string, (string Name, string Arguments)>(StringComparer.Ordinal);
        var providerItems = new List<JsonObject>();

        foreach (var rawLine in body.Split('\n'))
        {
            var line = rawLine.Trim();
            if (!line.StartsWith("data:", StringComparison.Ordinal)) continue;
            var payload = line[5..].Trim();
            if (payload.Length == 0 || payload == "[DONE]") continue;
            JsonNode? evt;
            try { evt = JsonNode.Parse(payload); }
            catch (JsonException) { continue; }
            if (evt is null) continue;

            switch (Str(evt["type"]))
            {
                case "response.output_text.delta":
                    text.Append(Str(evt["delta"]) ?? "");
                    break;

                case "response.completed":
                case "response.incomplete":
                    finalResponse = evt["response"];
                    break;

                case "response.output_item.done":
                    if (evt["item"] is not JsonObject item) break;
                    providerItems.Add(item.DeepClone().AsObject());
                    switch (Str(item["type"]))
                    {
                        case "function_call":
                            var id = Str(item["call_id"])
                                ?? Str(item["id"])
                                ?? Guid.NewGuid().ToString();
                            if (!calls.ContainsKey(id)) callOrder.Add(id);
                            calls[id] = (
                                Str(item["name"]) ?? "",
                                Str(item["arguments"]) ?? "{}");
                            break;

                        // No text deltas arrived (some models emit the message whole).
                        case "message" when text.Length == 0:
                            foreach (var block in item["content"]?.AsArray() ?? new JsonArray())
                            {
                                if (Str(block?["text"]) is { } chunk) text.Append(chunk);
                            }
                            break;
                    }
                    break;

                case "response.failed":
                case "error":
                    throw StreamFailure(evt, providerName);
            }
        }

        var toolCalls = callOrder
            .Where(calls.ContainsKey)
            .Select(id => new NativeToolCall(id, calls[id].Name, calls[id].Arguments))
            .ToList();
        var usage = finalResponse?["usage"] is JsonObject value
            ? ParseUsage(value)
            : null;

        if (text.Length == 0 && toolCalls.Count == 0 && providerItems.Count == 0)
        {
            // Nothing in the stream - fall back to the terminal payload for
            // backends that do populate `output` there.
            if (finalResponse?["output"] is JsonArray output && output.Count > 0)
            {
                return ParseResponses(finalResponse);
            }
            var incompleteReason = Str(finalResponse?["incomplete_details"]?["reason"]);
            if (!string.IsNullOrWhiteSpace(incompleteReason))
            {
                return new NativeResponse(new NativeMessage("assistant", ""), usage, incompleteReason);
            }
            throw new NativeProviderException("The provider returned no message.", providerName: providerName);
        }

        var mergedProviderItems = finalResponse?["output"] is JsonArray terminalOutput
            ? terminalOutput.OfType<JsonObject>().Select(item => item.DeepClone().AsObject()).ToList()
            : new List<JsonObject>();
        if (mergedProviderItems.Count == 0) mergedProviderItems.AddRange(providerItems.Select(item => item.DeepClone().AsObject()));
        else
        {
            foreach (var item in providerItems)
            {
                if (!mergedProviderItems.Any(existing => SameResponsesOutputItem(existing, item)))
                    mergedProviderItems.Add(item.DeepClone().AsObject());
            }
        }

        return new NativeResponse(
            new NativeMessage("assistant", text.ToString(), ToolCalls: toolCalls, ProviderItems: mergedProviderItems),
            usage,
            Str(finalResponse?["incomplete_details"]?["reason"]), ResponseId: Str(finalResponse?["id"]), CacheDiagnostics: ParseCacheDiagnostics(finalResponse));
    }

    private static bool SameResponsesOutputItem(JsonObject left, JsonObject right)
    {
        var leftId = Str(left["id"]);
        if (!string.IsNullOrEmpty(leftId) && string.Equals(leftId, Str(right["id"]), StringComparison.Ordinal))
            return true;
        if (Str(left["type"]) == "function_call")
        {
            var leftCallId = Str(left["call_id"]);
            if (!string.IsNullOrEmpty(leftCallId)
                && string.Equals(leftCallId, Str(right["call_id"]), StringComparison.Ordinal))
                return true;
        }
        return JsonNode.DeepEquals(left, right);
    }

    private static NativeProviderException StreamFailure(JsonNode evt, string? providerName)
    {
        var message = Str(evt["message"])
            ?? Str(evt["error"]?["message"])
            ?? Str(evt["response"]?["error"]?["message"])
            ?? "The Codex stream reported an error.";
        var status = Int(evt["status"])
            ?? Int(evt["error"]?["status"])
            ?? Int(evt["response"]?["status"])
            ?? Int(evt["response"]?["error"]?["status"])
            ?? 502;
        var limitKind = DetectLimitKind(
            string.Join(" ", new[]
            {
                message,
                Str(evt["error"]?["type"]) ?? "",
                Str(evt["error"]?["code"]) ?? "",
            }),
            status);
        return new NativeProviderException(
            message,
            status,
            status is 408 or 409 or 425 or >= 500,
            limitKind is not null,
            limitKind,
            providerName);
    }

    /// <summary>Tolerant reads: a stream event may carry an unexpected node type,
    /// and <c>GetValue&lt;T&gt;</c> throws rather than returning null on mismatch.</summary>
    private static string? Str(JsonNode? node)
    {
        try { return node?.GetValue<string>(); }
        catch (InvalidOperationException) { return null; }
        catch (FormatException) { return null; }
    }

    private static int? Int(JsonNode? node)
    {
        try { return node?.GetValue<int>(); }
        catch (InvalidOperationException) { return null; }
        catch (FormatException) { return null; }
    }

    private static NativeResponse ParseResponses(JsonNode? node)
    {
        var output = node?["output"]?.AsArray();
        if (output is null)
        {
            var incompleteReason = Str(node?["incomplete_details"]?["reason"]);
            if (!string.IsNullOrWhiteSpace(incompleteReason))
            {
                var emptyResponseUsage = node?["usage"] is JsonObject emptyUsage ? ParseUsage(emptyUsage) : null;
                return new NativeResponse(new NativeMessage("assistant", ""), emptyResponseUsage, incompleteReason,
                    ResponseId: Str(node?["id"]), CacheDiagnostics: ParseCacheDiagnostics(node));
            }
            throw new NativeProviderException("The provider returned no message.");
        }
        var text = string.Join("", output.Where(item => item?["type"]?.GetValue<string>() == "message").SelectMany(item => item?["content"]?.AsArray() ?? new JsonArray()).Where(item => item?["text"] is not null).Select(item => item?["text"]?.GetValue<string>() ?? ""));
        var calls = output.Where(item => item?["type"]?.GetValue<string>() == "function_call").Select(item => new NativeToolCall(item?["call_id"]?.GetValue<string>() ?? item?["id"]?.GetValue<string>() ?? Guid.NewGuid().ToString(), item?["name"]?.GetValue<string>() ?? "tool", item?["arguments"]?.GetValue<string>() ?? "{}")).ToList();
        var usage = node?["usage"] is JsonObject value ? ParseUsage(value) : null;
        var providerItems = output.OfType<JsonObject>().Select(item => item.DeepClone().AsObject()).ToList();
        return new NativeResponse(
            new NativeMessage("assistant", text, ToolCalls: calls, ProviderItems: providerItems),
            usage,
            Str(node?["incomplete_details"]?["reason"]), ResponseId: Str(node?["id"]), CacheDiagnostics: ParseCacheDiagnostics(node));
    }

    private static NativeResponse ParseAnthropic(JsonNode? node)
    {
        var content = node?["content"]?.AsArray() ?? throw new NativeProviderException("The provider returned no message.");
        var text = string.Join("", content.Where(x => x?["type"]?.GetValue<string>() == "text").Select(x => x?["text"]?.GetValue<string>() ?? ""));
        var thinking = string.Join("\n\n", content.Where(x => x?["type"]?.GetValue<string>() == "thinking").Select(x => x?["thinking"]?.GetValue<string>() ?? ""));
        var calls = content.Where(x => x?["type"]?.GetValue<string>() == "tool_use").Select(x => new NativeToolCall(x?["id"]?.GetValue<string>() ?? Guid.NewGuid().ToString(), x?["name"]?.GetValue<string>() ?? "tool", (x?["input"] ?? new JsonObject()).ToJsonString())).ToList();
        var usage = node?["usage"] is JsonObject u ? ParseUsage(u, inputExcludesCache: true) : null;
        if (usage is not null)
        {
            var contextEditStats = ParseAnthropicContextEditStats(node);
            usage = usage with
            {
                ContextClearedInputTokens = contextEditStats.clearedInputTokens,
                ContextClearedToolUses = contextEditStats.clearedToolUses,
            };
        }
        var incompleteReason = node?["stop_reason"]?.GetValue<string>() == "max_tokens"
            ? "max_output_tokens"
            : null;
        return new NativeResponse(new NativeMessage("assistant", text, ToolCalls: calls,
            Thinking: string.IsNullOrEmpty(thinking) ? null : thinking,
            ProviderItems: content.OfType<JsonObject>().Select(item => item.DeepClone().AsObject()).ToList()),
            usage, incompleteReason, ResponseId: Str(node?["id"]), CacheDiagnostics: ParseAnthropicDiagnostics(node));
    }

    internal static NativeCacheDiagnostics? ParseAnthropicDiagnostics(JsonNode? node)
    {
        if (node?["diagnostics"] is not JsonObject diagnostics) return null;
        if (diagnostics["cache_miss_reason"] is not JsonObject reason)
            return new NativeCacheDiagnostics("comparison_match", null, null, null);
        var type = Str(reason["type"]) ?? "unavailable";
        if (type is not ("model_changed" or "system_changed" or "tools_changed" or "messages_changed"
            or "previous_message_not_found" or "unavailable")) type = "other";
        return new NativeCacheDiagnostics("comparison_mismatch", type,
            Int(reason["cache_missed_input_tokens"]), null);
    }

    private static (int? clearedInputTokens, int? clearedToolUses) ParseAnthropicContextEditStats(JsonNode? node)
    {
        if (node?["context_management"]?["applied_edits"] is not JsonArray edits) return (null, null);
        var cleared = edits.OfType<JsonObject>()
            .Where(edit => Str(edit["type"]) == "clear_tool_uses_20250919")
            .ToArray();
        if (cleared.Length == 0) return (null, null);

        int? inputTokens = null;
        int? toolUses = null;
        foreach (var edit in cleared)
        {
            if (Int(edit["cleared_input_tokens"]) is { } tokens)
                inputTokens = (inputTokens ?? 0) + Math.Max(0, tokens);
            if (Int(edit["cleared_tool_uses"]) is { } uses)
                toolUses = (toolUses ?? 0) + Math.Max(0, uses);
        }
        return (inputTokens, toolUses);
    }

    public static NativeResponse ParseAnthropicStream(string body)
    {
        JsonObject? message = null;
        var blocks = new SortedDictionary<int, JsonObject>();
        var inputs = new Dictionary<int, StringBuilder>();
        foreach (var raw in body.Split('\n'))
        {
            var line = raw.Trim();
            if (!line.StartsWith("data:", StringComparison.Ordinal)) continue;
            JsonNode? evt;
            try { evt = JsonNode.Parse(line[5..].Trim()); } catch (JsonException) { continue; }
            if (evt is null) continue;
            switch (Str(evt["type"]))
            {
                case "message_start":
                    message = evt["message"]?.DeepClone().AsObject();
                    break;
                case "content_block_start" when evt["content_block"] is JsonObject block:
                    blocks[Int(evt["index"]) ?? 0] = block.DeepClone().AsObject();
                    break;
                case "content_block_delta":
                    var index = Int(evt["index"]) ?? 0;
                    if (!blocks.TryGetValue(index, out var current)) break;
                    var delta = evt["delta"];
                    switch (Str(delta?["type"]))
                    {
                        case "text_delta": current["text"] = (Str(current["text"]) ?? "") + (Str(delta?["text"]) ?? ""); break;
                        case "thinking_delta": current["thinking"] = (Str(current["thinking"]) ?? "") + (Str(delta?["thinking"]) ?? ""); break;
                        case "signature_delta": current["signature"] = (Str(current["signature"]) ?? "") + (Str(delta?["signature"]) ?? ""); break;
                        case "input_json_delta":
                            if (!inputs.TryGetValue(index, out var input)) inputs[index] = input = new StringBuilder();
                            input.Append(Str(delta?["partial_json"]) ?? ""); break;
                    }
                    break;
                case "message_delta" when message is not null:
                    if (evt["delta"] is JsonObject fields)
                        foreach (var field in fields) message[field.Key] = field.Value?.DeepClone();
                    if (evt["context_management"] is JsonObject contextManagement)
                        message["context_management"] = contextManagement.DeepClone();
                    if (evt["usage"] is JsonObject usage)
                    {
                        var totals = message["usage"] as JsonObject ?? new JsonObject();
                        foreach (var field in usage) totals[field.Key] = field.Value?.DeepClone();
                        if (message["usage"] is null) message["usage"] = totals;
                    }
                    break;
                case "error": throw StreamFailure(evt, "Claude");
            }
        }
        if (message is null) throw new NativeProviderException("The provider returned no message.");
        foreach (var input in inputs) blocks[input.Key]["input"] = JsonNode.Parse(input.Value.ToString());
        message["content"] = new JsonArray(blocks.Values.Select(value => value.DeepClone()).ToArray());
        return ParseAnthropic(message);
    }

    private static NativeCacheDiagnostics? ParseCacheDiagnostics(JsonNode? node)
    {
        if (node?["prompt_cache_diagnostics"] is not JsonObject diagnostics) return null;
        var type = Str(diagnostics["type"]) ?? "unavailable";
        if (type is not ("cache_hit" or "cache_miss" or "unavailable" or "comparison_response_not_found")) type = "unavailable";
        var reason = Str(diagnostics["reason"]);
        if (reason is not null && reason is not ("model_changed" or "prompt_cache_key_changed" or "tools_changed"
            or "instructions_changed" or "input_changed" or "reasoning_changed" or "reasoning_effort_changed"
            or "service_tier_changed" or "cache_expired" or "cache_evicted" or "cache_not_found" or "settings_changed" or "prefix_mismatch"
            or "text_format_changed" or "verbosity_changed" or "context_compacted")) reason = "other";
        return new NativeCacheDiagnostics(type, reason, Int(diagnostics["cache_missed_tokens"]), Int(diagnostics["comparison_reusable_tokens"]));
    }

    private static NativeUsage? ParseUsage(JsonObject usage, bool inputExcludesCache = false)
    {
        var input = Int(usage["prompt_tokens"] ?? usage["input_tokens"]);
        var output = Int(usage["completion_tokens"] ?? usage["output_tokens"]);
        var cached = Int(
            usage["prompt_cache_hit_tokens"]
            ?? usage["prompt_tokens_details"]?["cached_tokens"]
            ?? usage["input_tokens_details"]?["cached_tokens"]
            ?? usage["cache_read_input_tokens"]
            ?? usage["cachedContentTokenCount"]);
        var written = Int(
            usage["prompt_tokens_details"]?["cache_write_tokens"]
            ?? usage["input_tokens_details"]?["cache_write_tokens"]
            ?? usage["cache_write_tokens"]
            ?? usage["cache_creation_input_tokens"]);
        var missed = Int(usage["prompt_cache_miss_tokens"]);
        var reasoning = Int(
            usage["output_tokens_details"]?["reasoning_tokens"]
            ?? usage["completion_tokens_details"]?["reasoning_tokens"]
            ?? usage["reasoning_tokens"]
            ?? usage["thinking_tokens"]);
        if (input is null && output is null && cached is null && written is null && missed is null) return null;
        var normalizedInput = input ?? (cached ?? 0) + (missed ?? 0) + (written ?? 0);
        return new NativeUsage(normalizedInput, output ?? 0, cached, written, missed, inputExcludesCache, reasoning,
            InputTokensReported: input is not null);
    }
}

public sealed record NativeGatewayRequest(string Method, string Path, IReadOnlyDictionary<string, string> Headers, byte[] Body);
public sealed record NativeGatewayResponse(int Status, byte[] Body, string ContentType = "application/json");

public sealed class NativeProviderGateway : IDisposable
{
    private readonly HttpListener _listener = new();
    private readonly Func<NativeGatewayRequest, Task<NativeGatewayResponse>> _handler;
    private CancellationTokenSource? _stop;
    public bool Running { get; private set; }
    public Uri Url { get; }

    public NativeProviderGateway(ushort port, Func<NativeGatewayRequest, Task<NativeGatewayResponse>> handler)
    {
        Url = new Uri($"http://127.0.0.1:{port}/v1/");
        _handler = handler;
        _listener.Prefixes.Add($"http://127.0.0.1:{port}/");
    }

    public void Start()
    {
        if (Running) return;
        _listener.Start();
        _stop = new CancellationTokenSource();
        Running = true;
        _ = AcceptAsync(_stop.Token);
    }

    public void Stop()
    {
        if (!Running) return;
        Running = false;
        _stop?.Cancel();
        try { _listener.Stop(); } catch { }
    }

    private async Task AcceptAsync(CancellationToken ct)
    {
        try
        {
            while (!ct.IsCancellationRequested)
            {
                var context = await _listener.GetContextAsync().WaitAsync(ct);
                _ = HandleAsync(context, ct);
            }
        }
        catch (OperationCanceledException) { }
        catch (HttpListenerException) { }
    }

    private async Task HandleAsync(HttpListenerContext context, CancellationToken ct)
    {
        try
        {
            using var input = context.Request.InputStream;
            using var memory = new MemoryStream();
            await input.CopyToAsync(memory, ct);
            var headers = context.Request.Headers.AllKeys.Where(k => k is not null).ToDictionary(k => k!.ToLowerInvariant(), k => context.Request.Headers[k!] ?? "", StringComparer.OrdinalIgnoreCase);
            var response = await _handler(new NativeGatewayRequest(context.Request.HttpMethod, context.Request.Url?.AbsolutePath ?? "", headers, memory.ToArray()));
            context.Response.StatusCode = response.Status;
            context.Response.ContentType = response.ContentType;
            context.Response.ContentLength64 = response.Body.Length;
            await context.Response.OutputStream.WriteAsync(response.Body, ct);
        }
        catch (OperationCanceledException) { }
        catch { context.Response.StatusCode = 500; }
        finally { context.Response.Close(); }
    }

    public void Dispose()
    {
        Stop();
        // Closing removes the prefix from the process-wide endpoint table. When
        // another listener already owns that host and port, the removal fails
        // with "Address already in use" — the listener is gone either way, so a
        // teardown must not throw at the caller.
        try { _listener.Close(); } catch { }
    }
}

/// Effort levels per model, low to high. Keep in sync with the "efforts" fields in
/// macos/DotsHarness/Sources/DotsHarnessCore/Resources/providers.json.
/// Mirrors the `fast` flag in macOS providers.json.
public static class NativeFastCatalog
{
    private static readonly HashSet<string> Models = new(StringComparer.OrdinalIgnoreCase)
        { "claude-opus-5-5", "claude-opus-5", "claude-opus-4-8" };

    public static bool Supports(string? model) =>
        !string.IsNullOrEmpty(model) && Models.Contains(model[(model.LastIndexOf('/') + 1)..]);
}

public static class NativeEffortCatalog
{
    private static readonly string[] GptMax = ["none", "low", "medium", "high", "xhigh", "max"];
    private static readonly string[] Gpt = ["none", "low", "medium", "high", "xhigh"];
    private static readonly string[] ClaudeXhigh = ["low", "medium", "high", "xhigh", "max"];
    private static readonly string[] ClaudeMax = ["low", "medium", "high", "max"];
    private static readonly string[] StandardEffort = ["low", "medium", "high"];
    private static readonly string[] TwoLevelEffort = ["low", "high"];

    private static readonly Dictionary<string, string[]> Table = new(StringComparer.OrdinalIgnoreCase)
    {
        ["gpt-6.1-sol"] = GptMax,
        ["gpt-5.6-terra"] = GptMax, ["gpt-5.6-sol"] = GptMax, ["gpt-5.6-luna"] = GptMax,
        ["claude-sonnet-5-5"] = ClaudeXhigh, ["claude-opus-5-5"] = ClaudeXhigh, ["claude-haiku-5-5"] = ClaudeXhigh,
        ["claude-sonnet-5"] = ClaudeXhigh, ["claude-opus-5"] = ClaudeXhigh, ["claude-opus-4-8"] = ClaudeXhigh,
        ["claude-fable-5-1"] = ClaudeXhigh, ["claude-fable-5"] = ClaudeXhigh, ["claude-opus-4-7"] = ClaudeXhigh,
        ["claude-sonnet-4-6"] = ClaudeMax, ["claude-opus-4-6"] = ClaudeMax, ["claude-opus-4-6-thinking"] = ClaudeMax,
        ["claude-opus-4-5-20251101"] = StandardEffort,
        ["grok-4.5"] = ["low", "medium", "high", "xhigh"],
        ["gemini-3.8-pro"] = StandardEffort, ["gemini-3.8-flash"] = StandardEffort,
        ["gemini-3.5-pro"] = StandardEffort, ["gemini-3.5-flash"] = StandardEffort,
        ["gemini-3.1-pro"] = StandardEffort, ["gemini-3.1-pro-low"] = TwoLevelEffort,
        ["gemini-3-pro-preview"] = StandardEffort, ["gemini-3-flash-preview"] = StandardEffort,
        ["gemini-2.5-pro"] = StandardEffort, ["gemini-2.5-flash"] = StandardEffort,
        ["gemini-pro-agent"] = TwoLevelEffort, ["gemini-3-flash-agent"] = StandardEffort, ["gemini-3-flash"] = StandardEffort,
        ["gemini-3.6-flash-low"] = StandardEffort,
        ["gpt-oss-120b"] = StandardEffort,
        ["deepseek-reasoner"] = StandardEffort,
    };

    private static readonly System.Collections.Concurrent.ConcurrentDictionary<string, string[]> Overlay = new(StringComparer.OrdinalIgnoreCase);

    /// Levels published by the remote model catalog win over the built-in table for that model id.
    public static void SetOverlay(string model, IReadOnlyList<string> levels) => Overlay[model] = levels.ToArray();

    public static IReadOnlyList<string> Levels(string? model)
    {
        if (string.IsNullOrEmpty(model)) return [];
        // Router ids may carry a provider prefix ("claude/claude-opus-5").
        var bare = model[(model.LastIndexOf('/') + 1)..];
        if (Overlay.TryGetValue(bare, out var published)) return published;
        if (Table.TryGetValue(bare, out var levels)) return levels;

        // Dynamic heuristic fallback for newly released or unlisted models:
        var lower = bare.ToLowerInvariant();
        if (lower.Contains("reasoner") || lower.Contains("thinking") || lower.Contains("-r1") || lower.Contains("-r2"))
            return StandardEffort;
        if (lower.StartsWith("claude-") && !lower.Contains("haiku"))
            return ClaudeMax;
        if (lower.StartsWith("gemini-"))
            return StandardEffort;
        if (lower.StartsWith("gpt-5"))
            return Gpt;
        if (lower.StartsWith("grok-4"))
            return ["low", "medium", "high", "xhigh"];
        return [];
    }
}

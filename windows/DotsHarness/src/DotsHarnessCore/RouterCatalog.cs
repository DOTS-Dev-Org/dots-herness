using HarnessPluginKit;

namespace DotsHarnessCore;

public enum RouterAuthKind { OauthBrowser, OauthDevice, ApiKey }

public sealed record RouterProviderKind(
    string Id,
    string Name,
    RouterAuthKind Kind,
    string Hint,
    string BaseUrl = "",
    string DefaultModel = "",
    NativeProviderProtocol Protocol = NativeProviderProtocol.OpenAiCompatible,
    string LogoKey = "generic");

public static class RouterCatalog
{
    /// <summary>Stable cross-platform key for a user's per-model context override.</summary>
    public static string ModelContextOverrideKey(string provider, string model) =>
        $"{provider.ToLowerInvariant()}\u001f{model}";

    public static readonly IReadOnlyList<RouterProviderKind> Providers = new[]
    {
        new RouterProviderKind("gpt", "ChatGPT", RouterAuthKind.OauthBrowser, "Sign in with ChatGPT", "https://chatgpt.com/backend-api/codex", "gpt-6.1-sol", NativeProviderProtocol.ChatGpt, "openai"),
        new RouterProviderKind("claude", "Anthropic", RouterAuthKind.OauthBrowser, "Sign in with Claude", "https://api.anthropic.com/v1", "claude-sonnet-5-5", NativeProviderProtocol.Anthropic, "anthropic"),
        new RouterProviderKind("gemini", "Gemini", RouterAuthKind.ApiKey, "API key", "https://generativelanguage.googleapis.com/v1beta/openai", "gemini-3.8-pro", LogoKey: "gemini"),
        new RouterProviderKind("antigravity", "Antigravity", RouterAuthKind.ApiKey, "API key or Custom API", LogoKey: "antigravity"),
        new RouterProviderKind("iflow", "iFlow", RouterAuthKind.ApiKey, "API key or Custom API", LogoKey: "iflow"),
        new RouterProviderKind("github", "GitHub Copilot", RouterAuthKind.ApiKey, "API key or Custom API", LogoKey: "github"),
        new RouterProviderKind("qwen", "Qwen", RouterAuthKind.ApiKey, "API key", "https://dashscope.aliyuncs.com/compatible-mode/v1", "qwen-max", LogoKey: "qwen"),
        new RouterProviderKind("kiro", "Kiro", RouterAuthKind.ApiKey, "API key or Custom API", LogoKey: "kiro"),
        new RouterProviderKind("grok", "Grok", RouterAuthKind.ApiKey, "API key", "https://api.x.ai/v1", "grok-4.5", LogoKey: "grok"),
        // Subscription login exposed by the macOS registry as Grok Build. This is
        // separate from xAI's API-key endpoint and uses its Responses transport.
        new RouterProviderKind("grok-cli", "Grok Build", RouterAuthKind.OauthDevice, "Sign in with your xAI subscription", "https://cli-chat-proxy.grok.com/v1", "grok-build", NativeProviderProtocol.OpenAiResponses, "grok"),
        new RouterProviderKind("openrouter", "OpenRouter", RouterAuthKind.ApiKey, "API key", "https://openrouter.ai/api/v1", "openai/gpt-5.6-luna", LogoKey: "openrouter"),
        new RouterProviderKind("openai", "OpenAI", RouterAuthKind.ApiKey, "API key · Responses API", "https://api.openai.com/v1", "gpt-5.6-terra", NativeProviderProtocol.OpenAiResponses, "openai"),
        new RouterProviderKind("anthropic", "Anthropic", RouterAuthKind.ApiKey, "API key", "https://api.anthropic.com/v1", "claude-sonnet-5", NativeProviderProtocol.Anthropic, "anthropic"),
        new RouterProviderKind("glm", "GLM", RouterAuthKind.ApiKey, "API key", LogoKey: "glm"),
        new RouterProviderKind("kimi", "Kimi", RouterAuthKind.ApiKey, "API key", LogoKey: "kimi"),
        new RouterProviderKind("minimax", "MiniMax", RouterAuthKind.ApiKey, "API key", LogoKey: "minimax"),
        new RouterProviderKind("deepseek", "DeepSeek", RouterAuthKind.ApiKey, "API key", "https://api.deepseek.com/v1", "deepseek-chat", LogoKey: "deepseek"),
        new RouterProviderKind("deepinfra", "DeepInfra", RouterAuthKind.ApiKey, "API key", "https://api.deepinfra.com/v1/openai", "meta-llama/Meta-Llama-3.1-70B-Instruct", LogoKey: "deepinfra"),
        new RouterProviderKind("groq", "Groq", RouterAuthKind.ApiKey, "API key", "https://api.groq.com/openai/v1", "llama-3.3-70b-versatile", LogoKey: "groq"),
        new RouterProviderKind("xai", "SpaceXAI", RouterAuthKind.ApiKey, "API key", "https://api.x.ai/v1", "grok-3-mini", LogoKey: "spacexai"),
        new RouterProviderKind("mistral", "Mistral", RouterAuthKind.ApiKey, "API key", "https://api.mistral.ai/v1", "codestral-latest", LogoKey: "mistral"),
        new RouterProviderKind("perplexity", "Perplexity", RouterAuthKind.ApiKey, "API key", "https://api.perplexity.ai", "sonar", LogoKey: "perplexity"),
        new RouterProviderKind("together", "Together AI", RouterAuthKind.ApiKey, "API key", "https://api.together.xyz/v1", "meta-llama/Llama-3.3-70B-Instruct-Turbo", LogoKey: "together"),
        new RouterProviderKind("opencode", "OpenCode Zen", RouterAuthKind.ApiKey, "API key from opencode.ai", "https://opencode.ai/zen/v1", LogoKey: "opencode"),
        new RouterProviderKind("opencode-go", "OpenCode Go", RouterAuthKind.ApiKey, "Go subscription key from opencode.ai", "https://opencode.ai/zen/go/v1", LogoKey: "opencode-go"),
        new RouterProviderKind("zai", "GLM Coding (Z.ai)", RouterAuthKind.ApiKey, "Coding plan key from z.ai", "https://api.z.ai/api/coding/paas/v4", "glm-4.6", LogoKey: "zai"),
        new RouterProviderKind("fireworks", "Fireworks", RouterAuthKind.ApiKey, "API key", "https://api.fireworks.ai/inference/v1", "accounts/fireworks/models/llama-v3p1-70b-instruct", LogoKey: "fireworks"),
        new RouterProviderKind("cerebras", "Cerebras", RouterAuthKind.ApiKey, "API key", "https://api.cerebras.ai/v1", "llama-3.3-70b", LogoKey: "cerebras"),
        new RouterProviderKind("cohere", "Cohere", RouterAuthKind.ApiKey, "API key", LogoKey: "cohere"),
        new RouterProviderKind("nvidia", "NVIDIA", RouterAuthKind.ApiKey, "API key", LogoKey: "nvidia"),
        new RouterProviderKind("siliconflow", "SiliconFlow", RouterAuthKind.ApiKey, "API key", LogoKey: "siliconflow"),
        new RouterProviderKind("nebius", "Nebius", RouterAuthKind.ApiKey, "API key", LogoKey: "nebius"),
        new RouterProviderKind("chutes", "Chutes", RouterAuthKind.ApiKey, "API key", LogoKey: "chutes"),
        new RouterProviderKind("hyperbolic", "Hyperbolic", RouterAuthKind.ApiKey, "API key", LogoKey: "hyperbolic"),
        new RouterProviderKind("vertex", "Vertex AI", RouterAuthKind.ApiKey, "API key or Custom API", LogoKey: "vertex"),
    };

    public static RouterProviderKind? KindFor(string id) => Providers.FirstOrDefault(p => p.Id == id);
    public static string LabelFor(string id) => id.StartsWith("custom:", StringComparison.Ordinal) ? "Custom API" : KindFor(id)?.Name ?? "Provider";
    public static string HintFor(RouterProviderKind kind) => string.IsNullOrWhiteSpace(kind.BaseUrl) ? "Custom API endpoint" : kind.Hint;

    /// <summary>Official model capacities. For GPT-6, 272K is a long-context pricing threshold.</summary>
    private static readonly System.Collections.Concurrent.ConcurrentDictionary<string, int> ContextWindowOverlay = new(StringComparer.Ordinal);

    /// Context windows published by the remote model catalog, keyed like the stored overrides.
    public static void SetContextWindowOverlay(string provider, string model, int window) =>
        ContextWindowOverlay[ModelContextOverrideKey(provider, model)] = window;

    public static int? DocumentedContextWindow(string? provider, string? model)
    {
        if (string.IsNullOrWhiteSpace(provider) || string.IsNullOrWhiteSpace(model)) return null;
        var bareModel = model.Trim().ToLowerInvariant();
        var separator = bareModel.LastIndexOf('/');
        if (separator >= 0) bareModel = bareModel[(separator + 1)..];
        var isClaudeProvider = string.Equals(provider, "claude", StringComparison.OrdinalIgnoreCase)
            || string.Equals(provider, "anthropic", StringComparison.OrdinalIgnoreCase);
        if (isClaudeProvider && bareModel == "claude-haiku-5-5") return 1_000_000;
        if (ContextWindowOverlay.TryGetValue(ModelContextOverrideKey(provider, model), out var published)) return published;
        if (!string.Equals(provider, "gpt", StringComparison.OrdinalIgnoreCase)
            && !string.Equals(provider, "openai", StringComparison.OrdinalIgnoreCase)) return null;
        return OpenAIContextWindow(bareModel);
    }

    // OpenAI API windows for GPT-5.6+. Mini/nano variants are smaller and stay undocumented.
    internal static int? OpenAIContextWindow(string model)
    {
        if (!model.StartsWith("gpt-", StringComparison.Ordinal) || model.Contains("-mini") || model.Contains("-nano")) return null;
        var version = new string(model[4..].TakeWhile(c => char.IsDigit(c) || c == '.').ToArray())
            .Split('.', StringSplitOptions.RemoveEmptyEntries);
        if (version.Length == 0 || !int.TryParse(version[0], out var major)) return null;
        var minor = version.Length > 1 && int.TryParse(version[1], out var parsed) ? parsed : 0;
        return major >= 6 || (major == 5 && minor >= 6) ? 1_050_000 : null;
    }

    public static NativeProviderDescriptor Descriptor(RouterProviderKind kind) => new(kind.Id, kind.Name, kind.BaseUrl, kind.DefaultModel, kind.Protocol, kind.Kind switch
    {
        RouterAuthKind.OauthBrowser => "browser",
        RouterAuthKind.OauthDevice => "device",
        _ => "apiKey",
    }, kind.Hint, kind.LogoKey);
}

public sealed class RouterConnection
{
    public string Id { get; }
    public string Provider { get; }
    public string Name { get; }
    public string? Email { get; }
    public bool Active { get; }
    public bool ImageFallbackEnabled { get; }
    public string Status { get; }
    public string AuthType { get; }
    public string Model { get; }
    public IReadOnlyList<string> Models { get; }
    public int Priority { get; }
    public string? Error { get; }

    public RouterConnection(NativeProviderAccount account)
    {
        Id = account.Id; Provider = account.Provider; Name = account.Name; Email = account.Email; Active = account.Active; ImageFallbackEnabled = account.ImageFallbackEnabled; Status = account.Status; AuthType = account.AuthType; Model = account.Model; Models = account.Models ?? []; Priority = account.Priority; Error = account.Error;
    }

    public RouterConnection(IReadOnlyDictionary<string, JsonValue> obj)
    {
        Id = obj.TryGetValue("id", out var id) ? id.AsString() ?? Guid.NewGuid().ToString() : Guid.NewGuid().ToString();
        Provider = obj.TryGetValue("provider", out var provider) ? provider.AsString() ?? "unknown" : "unknown";
        Name = obj.TryGetValue("name", out var name) ? name.AsString() ?? "Unnamed" : "Unnamed";
        Email = obj.TryGetValue("email", out var email) ? email.AsString() : null;
        Active = !obj.TryGetValue("isActive", out var active) || active.AsBool() != false;
        ImageFallbackEnabled = obj.TryGetValue("imageFallbackEnabled", out var fallback) && fallback.AsBool() == true;
        Status = obj.TryGetValue("testStatus", out var status) ? status.AsString() ?? "connected" : "connected";
        AuthType = obj.TryGetValue("authType", out var auth) ? auth.AsString() ?? "" : "";
        Model = obj.TryGetValue("model", out var model) ? model.AsString() ?? "" : "";
        Models = Model.Length == 0 ? [] : [Model];
        Priority = obj.TryGetValue("priority", out var priority) ? priority.AsInt() ?? 0 : 0;
        Error = obj.TryGetValue("lastError", out var error) ? error.AsString() : null;
    }
}

public sealed record ModelContextSetting(
    string Provider,
    string Model,
    int? DetectedContextWindow,
    int? OverrideContextWindow)
{
    public string Id => RouterCatalog.ModelContextOverrideKey(Provider, Model);
    public string ProviderName => RouterCatalog.LabelFor(Provider);
}

public sealed class RouterTunnel
{
    public bool Enabled { get; }
    public bool Running { get; }
    public string TunnelUrl { get; }
    public string PublicUrl { get; }
    public string ShortId { get; }
    public bool Downloading { get; }
    public int Progress { get; }
    public static readonly RouterTunnel Idle = new(false, false, "", "", "", false, 0);
    public string ShareUrl => string.IsNullOrEmpty(PublicUrl) ? TunnelUrl : PublicUrl;
    public RouterTunnel(bool enabled, bool running, string tunnelUrl, string publicUrl, string shortId, bool downloading, int progress) { Enabled = enabled; Running = running; TunnelUrl = tunnelUrl; PublicUrl = publicUrl; ShortId = shortId; Downloading = downloading; Progress = progress; }
}

public enum CustomApiKind { OpenaiCompatible, AnthropicCompatible }
public static class CustomApiKindExtensions
{
    public static NativeProviderProtocol Protocol(this CustomApiKind kind) => kind == CustomApiKind.AnthropicCompatible ? NativeProviderProtocol.Anthropic : NativeProviderProtocol.OpenAiCompatible;
}
public enum CustomOpenAiApiType { Chat, Responses }

public sealed class RouterNode
{
    public string Id { get; }
    public string Name { get; }
    public string Prefix { get; }
    public string Type { get; }
    public string? ApiType { get; }
    public string BaseUrl { get; }
    public RouterNode(NativeCustomEndpoint endpoint) { Id = endpoint.Id; Name = endpoint.Name; Prefix = endpoint.Prefix; Type = endpoint.Protocol == NativeProviderProtocol.Anthropic ? "anthropic-compatible" : "openai-compatible"; ApiType = endpoint.ApiType; BaseUrl = endpoint.BaseUrl; }
}

public sealed class RouterKey
{
    public string Id { get; }
    public string Name { get; }
    public string Key { get; }
    public bool Active { get; }
    public RouterKey(string id, string name, string key, bool active = true) { Id = id; Name = name; Key = key; Active = active; }
}

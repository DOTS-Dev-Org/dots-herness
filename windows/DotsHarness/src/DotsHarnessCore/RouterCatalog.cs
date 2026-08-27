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
    public static readonly IReadOnlyList<RouterProviderKind> Providers = new[]
    {
        new RouterProviderKind("gpt", "GPT", RouterAuthKind.OauthBrowser, "Sign in with ChatGPT", "https://chatgpt.com/backend-api/codex", "gpt-4.1-mini", NativeProviderProtocol.ChatGpt, "gpt"),
        new RouterProviderKind("claude", "Claude", RouterAuthKind.ApiKey, "API key", "https://api.anthropic.com/v1", "claude-sonnet-4-20250514", NativeProviderProtocol.Anthropic, "claude"),
        new RouterProviderKind("gemini", "Gemini", RouterAuthKind.ApiKey, "API key", "https://generativelanguage.googleapis.com/v1beta/openai", "gemini-2.5-flash", LogoKey: "gemini"),
        new RouterProviderKind("antigravity", "Antigravity", RouterAuthKind.ApiKey, "API key or Custom API", LogoKey: "antigravity"),
        new RouterProviderKind("iflow", "iFlow", RouterAuthKind.ApiKey, "API key or Custom API", LogoKey: "iflow"),
        new RouterProviderKind("github", "GitHub Copilot", RouterAuthKind.ApiKey, "API key or Custom API", LogoKey: "github"),
        new RouterProviderKind("qwen", "Qwen", RouterAuthKind.ApiKey, "API key", "https://dashscope.aliyuncs.com/compatible-mode/v1", "qwen-plus", LogoKey: "qwen"),
        new RouterProviderKind("kiro", "Kiro", RouterAuthKind.ApiKey, "API key or Custom API", LogoKey: "kiro"),
        new RouterProviderKind("grok", "Grok", RouterAuthKind.ApiKey, "API key", "https://api.x.ai/v1", "grok-3-mini", LogoKey: "grok"),
        new RouterProviderKind("openrouter", "OpenRouter", RouterAuthKind.ApiKey, "API key", "https://openrouter.ai/api/v1", "openai/gpt-4.1-mini", LogoKey: "openrouter"),
        new RouterProviderKind("openai", "OpenAI", RouterAuthKind.ApiKey, "API key", "https://api.openai.com/v1", "gpt-4.1-mini", LogoKey: "openai"),
        new RouterProviderKind("anthropic", "Anthropic", RouterAuthKind.ApiKey, "API key", "https://api.anthropic.com/v1", "claude-sonnet-4-20250514", NativeProviderProtocol.Anthropic, "anthropic"),
        new RouterProviderKind("glm", "GLM", RouterAuthKind.ApiKey, "API key", LogoKey: "glm"),
        new RouterProviderKind("kimi", "Kimi", RouterAuthKind.ApiKey, "API key", LogoKey: "kimi"),
        new RouterProviderKind("minimax", "MiniMax", RouterAuthKind.ApiKey, "API key", LogoKey: "minimax"),
        new RouterProviderKind("deepseek", "DeepSeek", RouterAuthKind.ApiKey, "API key", "https://api.deepseek.com/v1", "deepseek-chat", LogoKey: "deepseek"),
        new RouterProviderKind("groq", "Groq", RouterAuthKind.ApiKey, "API key", "https://api.groq.com/openai/v1", "llama-3.3-70b-versatile", LogoKey: "groq"),
        new RouterProviderKind("xai", "xAI", RouterAuthKind.ApiKey, "API key", "https://api.x.ai/v1", "grok-3-mini", LogoKey: "xai"),
        new RouterProviderKind("mistral", "Mistral", RouterAuthKind.ApiKey, "API key", "https://api.mistral.ai/v1", "mistral-small-latest", LogoKey: "mistral"),
        new RouterProviderKind("perplexity", "Perplexity", RouterAuthKind.ApiKey, "API key", "https://api.perplexity.ai", "sonar", LogoKey: "perplexity"),
        new RouterProviderKind("together", "Together AI", RouterAuthKind.ApiKey, "API key", "https://api.together.xyz/v1", "meta-llama/Llama-3.3-70B-Instruct-Turbo", LogoKey: "together"),
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
    public static NativeProviderDescriptor Descriptor(RouterProviderKind kind) => new(kind.Id, kind.Name, kind.BaseUrl, kind.DefaultModel, kind.Protocol, kind.Kind == RouterAuthKind.OauthBrowser ? "browser" : "apiKey", kind.Hint, kind.LogoKey);
}

public sealed class RouterConnection
{
    public string Id { get; }
    public string Provider { get; }
    public string Name { get; }
    public string? Email { get; }
    public bool Active { get; }
    public string Status { get; }
    public string AuthType { get; }
    public string Model { get; }
    public int Priority { get; }
    public string? Error { get; }

    public RouterConnection(NativeProviderAccount account)
    {
        Id = account.Id; Provider = account.Provider; Name = account.Name; Email = account.Email; Active = account.Active; Status = account.Status; AuthType = account.AuthType; Model = account.Model; Priority = account.Priority; Error = account.Error;
    }

    public RouterConnection(IReadOnlyDictionary<string, JsonValue> obj)
    {
        Id = obj.TryGetValue("id", out var id) ? id.AsString() ?? Guid.NewGuid().ToString() : Guid.NewGuid().ToString();
        Provider = obj.TryGetValue("provider", out var provider) ? provider.AsString() ?? "unknown" : "unknown";
        Name = obj.TryGetValue("name", out var name) ? name.AsString() ?? "Unnamed" : "Unnamed";
        Email = obj.TryGetValue("email", out var email) ? email.AsString() : null;
        Active = !obj.TryGetValue("isActive", out var active) || active.AsBool() != false;
        Status = obj.TryGetValue("testStatus", out var status) ? status.AsString() ?? "connected" : "connected";
        AuthType = obj.TryGetValue("authType", out var auth) ? auth.AsString() ?? "" : "";
        Model = obj.TryGetValue("model", out var model) ? model.AsString() ?? "" : "";
        Priority = obj.TryGetValue("priority", out var priority) ? priority.AsInt() ?? 0 : 0;
        Error = obj.TryGetValue("lastError", out var error) ? error.AsString() : null;
    }
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
    public static string Wire(this CustomApiKind kind) => kind == CustomApiKind.AnthropicCompatible ? "anthropic-compatible" : "openai-compatible";
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

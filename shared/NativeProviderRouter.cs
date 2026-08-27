// Copyright (c) 2026 DOTS
// Small .NET 8 provider store and direct transport shared by WPF and Avalonia.

using System.Net;
using System.Net.Http.Headers;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace DotsHarnessCore;

public enum NativeProviderProtocol
{
    OpenAiCompatible,
    Anthropic,
    ChatGpt,
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
    public string Status { get; set; } = "connected";
    public string AuthType { get; set; } = "apiKey";
    public string Model { get; set; } = "";
    public string BaseUrl { get; set; } = "";
    public NativeProviderProtocol Protocol { get; set; }
    public string CredentialId { get; set; } = "";
    public string? RefreshCredentialId { get; set; }
    public int Priority { get; set; }
    public string? Error { get; set; }
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
}

public sealed class NativeProviderState
{
    public List<NativeProviderAccount> Accounts { get; set; } = [];
    public List<NativeCustomEndpoint> Endpoints { get; set; } = [];
    public string? SelectedAccountId { get; set; }
}

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
        if (raw is not null) MigratePlaintextSecrets(raw);
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
        if (string.IsNullOrWhiteSpace(name) || string.IsNullOrWhiteSpace(secret)) throw new NativeProviderException("Name and API key are required.");
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
            BaseUrl = NormalizeUrl(baseUrl ?? provider.BaseUrl),
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

    public NativeCustomEndpoint AddCustom(string name, string prefix, string baseUrl, NativeProviderProtocol protocol, string apiType, string? secret)
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
        };
        if (endpoint.CredentialId is not null) Secrets.Write(endpoint.CredentialId, secret!);
        State.Endpoints.Add(endpoint);
        Save();
        return endpoint;
    }

    public void UpdateCustom(NativeCustomEndpoint endpoint, string name, string prefix, string baseUrl, NativeProviderProtocol protocol, string apiType, string? secret)
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
        };
        foreach (var account in State.Accounts.Where(account => account.Provider == $"custom:{current.Id}"))
        {
            account.Name = trimmedName;
            account.ProviderName = trimmedName;
            account.Model = sanitized + "/";
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
            Model = endpoint.Prefix + "/",
            BaseUrl = endpoint.BaseUrl,
            Protocol = endpoint.Protocol,
            AuthType = "custom",
            CredentialId = $"account.{id}",
        };
        if (!string.IsNullOrWhiteSpace(secret)) Secrets.Write(account.CredentialId, secret);
        State.Accounts.Add(account);
        State.SelectedAccountId ??= account.Id;
        Save();
        return account;
    }

    public void SetActive(string id, bool active) { if (State.Accounts.FirstOrDefault(a => a.Id == id) is { } account) { account.Active = active; Save(); } }
    public void SetPriority(string id, int priority) { if (State.Accounts.FirstOrDefault(a => a.Id == id) is { } account) { account.Priority = priority; Save(); } }
    public void ReplaceCredential(NativeProviderAccount account, string value) => Secrets.Write(account.CredentialId, value);
    public void ReplaceRefreshCredential(NativeProviderAccount account, string value)
    {
        if (account.RefreshCredentialId is not null) Secrets.Write(account.RefreshCredentialId, value);
    }

    public void Remove(NativeProviderAccount account)
    {
        Secrets.Delete(account.CredentialId);
        if (account.RefreshCredentialId is not null) Secrets.Delete(account.RefreshCredentialId);
        State.Accounts.RemoveAll(a => a.Id == account.Id);
        Save();
    }

    public void Remove(NativeCustomEndpoint endpoint)
    {
        if (endpoint.CredentialId is not null) Secrets.Delete(endpoint.CredentialId);
        State.Endpoints.RemoveAll(e => e.Id == endpoint.Id);
        State.Accounts.RemoveAll(a => a.Provider == $"custom:{endpoint.Id}");
        Save();
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

public sealed record NativeMessage(string Role, string Content, string? ToolCallId = null, IReadOnlyList<NativeToolCall>? ToolCalls = null);
public sealed record NativeToolCall(string Id, string Name, string Arguments);
public sealed record NativeToolDefinition(string Name, string Description, JsonNode Parameters);
public sealed record NativeUsage(int InputTokens, int OutputTokens);
public sealed record NativeResponse(NativeMessage Message, NativeUsage? Usage);

public sealed class NativeProviderException : Exception
{
    public int? StatusCode { get; }
    public bool Retryable { get; }
    public NativeProviderException(string message, int? statusCode = null, bool retryable = false) : base(message) { StatusCode = statusCode; Retryable = retryable; }
}

public sealed class NativeProviderRouter
{
    private readonly NativeProviderStore _store;
    private readonly HttpClient _http;
    private readonly Func<NativeProviderAccount, CancellationToken, Task<bool>>? _refresh;

    public NativeProviderRouter(NativeProviderStore store, Func<NativeProviderAccount, CancellationToken, Task<bool>>? refresh = null, HttpClient? http = null)
    {
        _store = store;
        _refresh = refresh;
        _http = http ?? new HttpClient { Timeout = TimeSpan.FromSeconds(180) };
    }

    public async Task<NativeResponse> CompleteAsync(IReadOnlyList<NativeMessage> messages, IReadOnlyList<NativeToolDefinition> tools, string? model = null, CancellationToken ct = default)
    {
        var routes = _store.State.Accounts.Where(a => a.Active && (string.IsNullOrWhiteSpace(model) || a.Model == model)).OrderBy(a => a.Priority).ToList();
        if (routes.Count == 0) throw new NativeProviderException("Connect a provider account before starting a chat.");
        var failures = new List<string>();
        foreach (var route in routes)
        {
            var refreshed = false;
            try { return await SendAsync(route, messages, tools, string.IsNullOrWhiteSpace(model) ? null : model, ct); }
            catch (TaskCanceledException ex) when (!ct.IsCancellationRequested) { failures.Add($"{route.ProviderName}: {ex.Message}"); }
            catch (OperationCanceledException) { throw; }
            catch (NativeProviderException ex)
            {
                failures.Add($"{route.ProviderName}: {ex.Message}");
                if (ex.StatusCode == 401 && !refreshed && _refresh is not null)
                {
                    refreshed = true;
                    if (await _refresh(route, ct))
                    {
                        try { return await SendAsync(route, messages, tools, string.IsNullOrWhiteSpace(model) ? null : model, ct); }
                        catch (TaskCanceledException retry) when (!ct.IsCancellationRequested) { failures.Add($"{route.ProviderName}: {retry.Message}"); continue; }
                        catch (HttpRequestException retry) { failures.Add($"{route.ProviderName}: {retry.Message}"); continue; }
                        catch (NativeProviderException retry)
                        {
                            failures.Add($"{route.ProviderName}: {retry.Message}");
                            if (!retry.Retryable) throw;
                            ex = retry;
                        }
                    }
                }
                if (!ex.Retryable) throw;
            }
            catch (HttpRequestException ex) { failures.Add($"{route.ProviderName}: {ex.Message}"); }
        }
        throw new NativeProviderException(string.Join(Environment.NewLine, failures));
    }

    private async Task<NativeResponse> SendAsync(NativeProviderAccount route, IReadOnlyList<NativeMessage> messages, IReadOnlyList<NativeToolDefinition> tools, string? model, CancellationToken ct)
    {
        var key = _store.Secrets.Read(route.CredentialId);
        if ((route.Protocol is NativeProviderProtocol.Anthropic or NativeProviderProtocol.ChatGpt) && string.IsNullOrEmpty(key)) throw new NativeProviderException("The provider credential is unavailable.");
        var endpoint = Endpoint(route.BaseUrl, route.Protocol);
        var body = route.Protocol switch
        {
            NativeProviderProtocol.Anthropic => AnthropicBody(route, messages, tools, model),
            NativeProviderProtocol.ChatGpt => ResponsesBody(route, messages, tools, model),
            _ => OpenAiBody(route, messages, tools, model),
        };
        using var request = new HttpRequestMessage(HttpMethod.Post, endpoint) { Content = new StringContent(body.ToJsonString(), Encoding.UTF8, "application/json") };
        if (!string.IsNullOrEmpty(key))
        {
            if (route.Protocol == NativeProviderProtocol.Anthropic) request.Headers.TryAddWithoutValidation("x-api-key", key);
            else request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", key);
        }
        if (route.Protocol == NativeProviderProtocol.Anthropic) request.Headers.TryAddWithoutValidation("anthropic-version", "2023-06-01");
        if (route.Protocol == NativeProviderProtocol.ChatGpt)
        {
            if (string.IsNullOrWhiteSpace(route.SessionAccountId)) throw new NativeProviderException("The GPT session account is unavailable.");
            request.Headers.TryAddWithoutValidation("ChatGPT-Account-ID", route.SessionAccountId);
            request.Headers.TryAddWithoutValidation("OAI-Product-Sku", "codex");
            request.Headers.TryAddWithoutValidation("OpenAI-Beta", "responses=v1");
            request.Headers.TryAddWithoutValidation("originator", "dots_harness");
            request.Headers.TryAddWithoutValidation("session_id", Guid.NewGuid().ToString());
        }
        using var response = await _http.SendAsync(request, ct);
        var text = await response.Content.ReadAsStringAsync(ct);
        var node = JsonNode.Parse(text);
        if (!response.IsSuccessStatusCode)
        {
            var message = node?["error"]?["message"]?.GetValue<string>() ?? node?["message"]?.GetValue<string>() ?? $"HTTP {(int)response.StatusCode}";
            var status = (int)response.StatusCode;
            throw new NativeProviderException(message, status, status is 408 or 409 or 425 or 429 or >= 500);
        }
        return route.Protocol switch
        {
            NativeProviderProtocol.Anthropic => ParseAnthropic(node),
            NativeProviderProtocol.ChatGpt => ParseResponses(node),
            _ => ParseOpenAi(node),
        };
    }

    private static Uri Endpoint(string baseUrl, NativeProviderProtocol protocol)
    {
        var normalized = NativeProviderStore.NormalizeUrl(baseUrl).TrimEnd('/');
        if (protocol == NativeProviderProtocol.ChatGpt) return new Uri(normalized + "/responses");
        if (new Uri(normalized).AbsolutePath == "/") normalized += "/v1";
        return new Uri(normalized + (protocol == NativeProviderProtocol.Anthropic ? "/messages" : "/chat/completions"));
    }

    private static JsonObject OpenAiBody(NativeProviderAccount route, IReadOnlyList<NativeMessage> messages, IReadOnlyList<NativeToolDefinition> tools, string? model)
    {
        var body = new JsonObject { ["model"] = model ?? route.Model, ["messages"] = new JsonArray(messages.Select(MessageNode).ToArray()), ["temperature"] = 0.2 };
        if (tools.Count > 0) body["tools"] = new JsonArray(tools.Select(tool => new JsonObject { ["type"] = "function", ["function"] = new JsonObject { ["name"] = tool.Name, ["description"] = tool.Description, ["parameters"] = tool.Parameters.DeepClone() } }).ToArray());
        return body;
    }

    private static JsonObject ResponsesBody(NativeProviderAccount route, IReadOnlyList<NativeMessage> messages, IReadOnlyList<NativeToolDefinition> tools, string? model)
    {
        var input = new JsonArray();
        foreach (var message in messages.Where(message => message.Role != "system"))
        {
            if (message.Role == "tool")
            {
                input.Add(new JsonObject { ["type"] = "function_call_output", ["call_id"] = message.ToolCallId ?? "tool", ["output"] = message.Content });
            }
            else if (message.Role == "assistant" && message.ToolCalls is { Count: > 0 })
            {
                if (!string.IsNullOrEmpty(message.Content)) input.Add(new JsonObject { ["role"] = "assistant", ["content"] = new JsonArray(new JsonObject { ["type"] = "output_text", ["text"] = message.Content }) });
                foreach (var call in message.ToolCalls)
                    input.Add(new JsonObject { ["type"] = "function_call", ["call_id"] = call.Id, ["name"] = call.Name, ["arguments"] = call.Arguments });
            }
            else
            {
                var role = message.Role == "assistant" ? "assistant" : "user";
                var type = role == "assistant" ? "output_text" : "input_text";
                input.Add(new JsonObject { ["role"] = role, ["content"] = new JsonArray(new JsonObject { ["type"] = type, ["text"] = message.Content }) });
            }
        }
        var body = new JsonObject
        {
            ["model"] = model ?? route.Model,
            ["instructions"] = messages.FirstOrDefault(message => message.Role == "system")?.Content ?? "You are a helpful assistant.",
            ["input"] = input,
            ["store"] = false,
            ["stream"] = false,
        };
        if (tools.Count > 0) body["tools"] = new JsonArray(tools.Select(tool => new JsonObject { ["type"] = "function", ["name"] = tool.Name, ["description"] = tool.Description, ["parameters"] = tool.Parameters.DeepClone() }).ToArray());
        return body;
    }

    private static JsonNode MessageNode(NativeMessage message)
    {
        var node = new JsonObject { ["role"] = message.Role, ["content"] = message.Content };
        if (message.ToolCallId is not null) node["tool_call_id"] = message.ToolCallId;
        if (message.ToolCalls is { Count: > 0 }) node["tool_calls"] = new JsonArray(message.ToolCalls.Select(call => new JsonObject { ["id"] = call.Id, ["type"] = "function", ["function"] = new JsonObject { ["name"] = call.Name, ["arguments"] = call.Arguments } }).ToArray());
        return node;
    }

    private static JsonObject AnthropicBody(NativeProviderAccount route, IReadOnlyList<NativeMessage> messages, IReadOnlyList<NativeToolDefinition> tools, string? model)
    {
        var converted = new JsonArray();
        foreach (var message in messages.Where(m => m.Role != "system")) converted.Add(AnthropicMessageNode(message));
        var body = new JsonObject { ["model"] = model ?? route.Model, ["max_tokens"] = 4096, ["messages"] = converted };
        var system = messages.FirstOrDefault(m => m.Role == "system")?.Content;
        if (!string.IsNullOrEmpty(system)) body["system"] = system;
        if (tools.Count > 0) body["tools"] = new JsonArray(tools.Select(t => new JsonObject { ["name"] = t.Name, ["description"] = t.Description, ["input_schema"] = t.Parameters.DeepClone() }).ToArray());
        return body;
    }

    private static JsonObject AnthropicMessageNode(NativeMessage message)
    {
        if (message.Role == "tool")
        {
            return new JsonObject
            {
                ["role"] = "user",
                ["content"] = new JsonArray(new JsonObject
                {
                    ["type"] = "tool_result",
                    ["tool_use_id"] = message.ToolCallId ?? "tool",
                    ["content"] = message.Content,
                }),
            };
        }

        if (message.Role == "assistant" && message.ToolCalls is { Count: > 0 })
        {
            var blocks = new JsonArray();
            if (!string.IsNullOrEmpty(message.Content)) blocks.Add(new JsonObject { ["type"] = "text", ["text"] = message.Content });
            foreach (var call in message.ToolCalls)
            {
                JsonNode input;
                try { input = JsonNode.Parse(call.Arguments) ?? new JsonObject(); }
                catch { input = new JsonObject(); }
                blocks.Add(new JsonObject { ["type"] = "tool_use", ["id"] = call.Id, ["name"] = call.Name, ["input"] = input });
            }
            return new JsonObject { ["role"] = "assistant", ["content"] = blocks };
        }

        return new JsonObject { ["role"] = message.Role == "assistant" ? "assistant" : "user", ["content"] = message.Content };
    }

    private static NativeResponse ParseOpenAi(JsonNode? node)
    {
        var message = node?["choices"]?[0]?["message"] ?? throw new NativeProviderException("The provider returned no message.");
        var calls = new List<NativeToolCall>();
        foreach (var item in message["tool_calls"]?.AsArray() ?? new JsonArray()) calls.Add(new NativeToolCall(item?["id"]?.GetValue<string>() ?? Guid.NewGuid().ToString(), item?["function"]?["name"]?.GetValue<string>() ?? "tool", item?["function"]?["arguments"]?.GetValue<string>() ?? "{}"));
        var usage = node?["usage"] is JsonObject u ? new NativeUsage(u["prompt_tokens"]?.GetValue<int>() ?? 0, u["completion_tokens"]?.GetValue<int>() ?? 0) : null;
        return new NativeResponse(new NativeMessage("assistant", message["content"]?.GetValue<string>() ?? "", ToolCalls: calls), usage);
    }

    private static NativeResponse ParseResponses(JsonNode? node)
    {
        var output = node?["output"]?.AsArray() ?? throw new NativeProviderException("The provider returned no message.");
        var text = string.Join("", output.Where(item => item?["type"]?.GetValue<string>() == "message").SelectMany(item => item?["content"]?.AsArray() ?? new JsonArray()).Where(item => item?["text"] is not null).Select(item => item?["text"]?.GetValue<string>() ?? ""));
        var calls = output.Where(item => item?["type"]?.GetValue<string>() == "function_call").Select(item => new NativeToolCall(item?["call_id"]?.GetValue<string>() ?? item?["id"]?.GetValue<string>() ?? Guid.NewGuid().ToString(), item?["name"]?.GetValue<string>() ?? "tool", item?["arguments"]?.GetValue<string>() ?? "{}")).ToList();
        var usage = node?["usage"] is JsonObject value ? new NativeUsage(value["input_tokens"]?.GetValue<int>() ?? 0, value["output_tokens"]?.GetValue<int>() ?? 0) : null;
        return new NativeResponse(new NativeMessage("assistant", text, ToolCalls: calls), usage);
    }

    private static NativeResponse ParseAnthropic(JsonNode? node)
    {
        var content = node?["content"]?.AsArray() ?? throw new NativeProviderException("The provider returned no message.");
        var text = string.Join("", content.Where(x => x?["type"]?.GetValue<string>() == "text").Select(x => x?["text"]?.GetValue<string>() ?? ""));
        var calls = content.Where(x => x?["type"]?.GetValue<string>() == "tool_use").Select(x => new NativeToolCall(x?["id"]?.GetValue<string>() ?? Guid.NewGuid().ToString(), x?["name"]?.GetValue<string>() ?? "tool", (x?["input"] ?? new JsonObject()).ToJsonString())).ToList();
        var usage = node?["usage"] is JsonObject u ? new NativeUsage(u["input_tokens"]?.GetValue<int>() ?? 0, u["output_tokens"]?.GetValue<int>() ?? 0) : null;
        return new NativeResponse(new NativeMessage("assistant", text, ToolCalls: calls), usage);
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

    public void Dispose() { Stop(); _listener.Close(); }
}

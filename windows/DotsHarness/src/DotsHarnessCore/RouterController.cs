using System.Collections.ObjectModel;
using System.Diagnostics;
using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using HarnessPluginKit;
using PluginRuntime;

namespace DotsHarnessCore;

public abstract record RouterFlow
{
    public sealed record Idle : RouterFlow;
    public sealed record Browser(string Provider, string AuthUrl, string RedirectUri, string CodeVerifier, string State) : RouterFlow;
    public sealed record Device(string Provider, string UserCode, string VerificationUrl, string DeviceCode, string? CodeVerifier, IReadOnlyDictionary<string, HarnessPluginKit.JsonValue> Extra) : RouterFlow;
    public static readonly RouterFlow IdleFlow = new Idle();
}

public sealed class RouterController : ObservableObject, IDisposable
{
    private readonly NativeProviderStore _store;
    private readonly NativeProviderRouter _router;
    private readonly ProviderImageAdapterRegistry _imageAdapters;
    private readonly NativeProviderImageRouter _imageRouter;
    private readonly NativeProviderGateway _gateway;
    private readonly CloudTunnelProcess _tunnelProcess;
    private HttpListener? _callbackListener;
    private RouterFlow _flow = RouterFlow.IdleFlow;
    private RouterTunnel _tunnel = RouterTunnel.Idle;
    private RouterProviderKind _selectedKind = RouterCatalog.Providers[0];
    private string _status = "Idle";
    private string? _error;
    private string _callbackPaste = "";
    private string _apiKeyName = "";
    private string _apiKeyValue = "";
    private string _customName = "Local / Custom";
    private string _customPrefix = "custom";
    private string _customBaseUrl = "http://127.0.0.1:11434/v1";
    private string _customApiKey = "";
    private CustomApiKind _customKind = CustomApiKind.OpenaiCompatible;
    private CustomOpenAiApiType _customApiType = CustomOpenAiApiType.Chat;
    private string? _editingNodeId;
    private string _selectedModelID = "";
    private readonly Dictionary<string, int> _contextWindows = new(StringComparer.Ordinal);

    public ObservableCollection<RouterConnection> Connections { get; } = new();
    public ObservableCollection<string> Models { get; } = new();
    public ObservableCollection<RouterKey> Keys { get; } = new();
    public ObservableCollection<RouterNode> Nodes { get; } = new();
    public RouterFlow Flow { get => _flow; private set => SetProperty(ref _flow, value); }
    public RouterTunnel Tunnel { get => _tunnel; private set => SetProperty(ref _tunnel, value); }
    public string Status { get => _status; set => SetProperty(ref _status, value); }
    public string? Error { get => _error; set => SetProperty(ref _error, value); }
    public string CallbackPaste { get => _callbackPaste; set => SetProperty(ref _callbackPaste, value); }
    public string ApiKeyName { get => _apiKeyName; set => SetProperty(ref _apiKeyName, value); }
    public string ApiKeyValue { get => _apiKeyValue; set => SetProperty(ref _apiKeyValue, value); }
    public RouterProviderKind SelectedKind { get => _selectedKind; set => SetProperty(ref _selectedKind, value); }
    public bool Reachable { get; private set; }
    public string CustomName { get => _customName; set => SetProperty(ref _customName, value); }
    public string CustomPrefix { get => _customPrefix; set => SetProperty(ref _customPrefix, value); }
    public string CustomBaseUrl { get => _customBaseUrl; set => SetProperty(ref _customBaseUrl, value); }
    public string CustomApiKey { get => _customApiKey; set => SetProperty(ref _customApiKey, value); }
    public CustomApiKind CustomKind { get => _customKind; set => SetProperty(ref _customKind, value); }
    public CustomOpenAiApiType CustomApiType { get => _customApiType; set => SetProperty(ref _customApiType, value); }
    public string SelectedModelID { get => _selectedModelID; set => SetProperty(ref _selectedModelID, value?.Trim() ?? ""); }
    public bool IsEditingCustom => _editingNodeId is not null;
    public NativeProviderStore Store => _store;
    public ProviderImageAdapterRegistry ImageAdapters => _imageAdapters;

    public RouterController(SupportPaths paths, ProviderImageAdapterRegistry? imageAdapters = null)
    {
        paths.Ensure();
        _store = new NativeProviderStore(paths.Root, new PlatformProviderSecrets(paths.Root));
        _router = new NativeProviderRouter(_store, RefreshCredentialAsync);
        _imageAdapters = imageAdapters ?? new ProviderImageAdapterRegistry();
        NativeProviderImageAdapters.Register(_imageAdapters);
        _imageRouter = new NativeProviderImageRouter(_store, _imageAdapters);
        _gateway = new NativeProviderGateway(18767, HandleGatewayAsync);
        _tunnelProcess = new CloudTunnelProcess(paths);
        RefreshState();
    }

    public async Task RefreshAsync()
    {
        RefreshState();
        await RefreshModelsAsync();
        Status = $"{Connections.Count(c => c.Active)} active · {Connections.Count} connections";
    }

    public Task StartConnectAsync() => SelectedKind.Kind switch
    {
        RouterAuthKind.ApiKey => CreateApiKeyAsync(),
        RouterAuthKind.OauthBrowser => StartBrowserAsync(),
        _ => StartDeviceAsync(),
    };

    public async Task CreateApiKeyAsync()
    {
        try
        {
            if (string.IsNullOrWhiteSpace(ApiKeyName) || string.IsNullOrWhiteSpace(ApiKeyValue)) throw new NativeProviderException("Name and API key are required.");
            if (string.IsNullOrWhiteSpace(SelectedKind.BaseUrl)) throw new NativeProviderException("Use Custom API for this provider until a direct endpoint is configured.");
            _store.AddAccount(RouterCatalog.Descriptor(SelectedKind), ApiKeyName, ApiKeyValue);
            ApiKeyValue = "";
            Status = $"Connected {SelectedKind.Name}";
            await RefreshAsync();
        }
        catch (Exception ex) { Error = ex.Message; }
    }

    public async Task StartBrowserAsync()
    {
        if (SelectedKind.Id != "gpt") { Error = "Native browser login is currently available for GPT. Use an API key or Custom API for this provider."; return; }
        try
        {
            var verifier = Token();
            var challenge = Convert.ToBase64String(SHA256.HashData(Encoding.UTF8.GetBytes(verifier))).Replace("+", "-").Replace("/", "_").TrimEnd('=');
            var state = Token();
            var redirect = "http://localhost:1455/auth/callback";
            var query = new Dictionary<string, string> { ["response_type"] = "code", ["client_id"] = "app_EMoamEEZ73f0CkXaXp7hrann", ["redirect_uri"] = redirect, ["scope"] = "openid profile email offline_access api.connectors.read api.connectors.invoke", ["code_challenge"] = challenge, ["code_challenge_method"] = "S256", ["id_token_add_organizations"] = "true", ["codex_cli_simplified_flow"] = "true", ["originator"] = "dots_harness", ["state"] = state };
            var authUrl = "https://auth.openai.com/oauth/authorize?" + string.Join("&", query.Select(item => $"{Uri.EscapeDataString(item.Key)}={Uri.EscapeDataString(item.Value)}"));
            Flow = new RouterFlow.Browser("gpt", authUrl, redirect, verifier, state);
            StartCallbackListener();
            if (OperatingSystem.IsLinux()) Process.Start(new ProcessStartInfo("xdg-open", authUrl) { UseShellExecute = false });
            else Process.Start(new ProcessStartInfo(authUrl) { UseShellExecute = true });
            _ = ExpireBrowserAsync(state);
            Status = "Complete sign-in in the browser.";
        }
        catch (Exception ex) { Error = ex.Message; }
        await Task.CompletedTask;
    }

    public async Task FinishBrowserAsync()
    {
        if (Flow is not RouterFlow.Browser browser) return;
        if (!Uri.TryCreate(CallbackPaste.Trim(), UriKind.Absolute, out var callback)) { Error = "Paste the full callback URL."; return; }
        await FinishCallbackAsync(browser, callback);
    }

    private async Task FinishCallbackAsync(RouterFlow.Browser browser, Uri callback)
    {
        var query = ParseQuery(callback.Query);
        if (query["state"] != browser.State) { Error = "The login callback state did not match."; return; }
        if (!string.IsNullOrEmpty(query["error"])) { Error = query["error_description"] ?? query["error"]!; return; }
        if (string.IsNullOrEmpty(query["code"])) { Error = "No authorization code in callback."; return; }
        try
        {
            var token = await ExchangeCodeAsync(query["code"]!, browser.RedirectUri, browser.CodeVerifier);
            var claims = Claims(token.IdToken ?? token.AccessToken);
            var provider = RouterCatalog.KindFor("gpt")!;
            _store.AddAccount(RouterCatalog.Descriptor(provider), claims.TryGetValue("email", out var email) ? email : "GPT account", token.AccessToken, authType: "chatgpt", email: claims.GetValueOrDefault("email"), sessionAccountId: claims.GetValueOrDefault("chatgpt_account_id"), refreshSecret: token.RefreshToken);
            CallbackPaste = "";
            Flow = RouterFlow.IdleFlow;
            _callbackListener?.Stop(); _callbackListener = null;
            Status = "Connected GPT";
            await RefreshAsync();
        }
        catch (Exception ex) { Error = ex.Message; }
    }

    public Task StartDeviceAsync() { Error = "This provider does not expose a verified native device login yet. Use an API key or Custom API."; return Task.CompletedTask; }
    public void CancelFlow() { try { _callbackListener?.Stop(); } catch { } _callbackListener = null; Flow = RouterFlow.IdleFlow; CallbackPaste = ""; }

    private async Task ExpireBrowserAsync(string state)
    {
        await Task.Delay(TimeSpan.FromMinutes(5));
        if (Flow is RouterFlow.Browser browser && browser.State == state)
        {
            Error = "The sign-in request timed out. Start it again.";
            CancelFlow();
        }
    }

    public Task ToggleAsync(RouterConnection connection) { _store.SetActive(connection.Id, !connection.Active); return RefreshAsync(); }

    public Task ToggleImageFallbackAsync(RouterConnection connection)
    {
        _store.SetImageFallback(connection.Id, !connection.ImageFallbackEnabled);
        return RefreshAsync();
    }

    public async Task TestAsync(RouterConnection connection)
    {
        try
        {
            var account = _store.State.Accounts.FirstOrDefault(a => a.Id == connection.Id) ?? throw new NativeProviderException("Connection not found.");
            if (account.Protocol == NativeProviderProtocol.ChatGpt)
            {
                await _router.CompleteAsync([new NativeMessage("user", "ping")], [], account.Model);
                Status = $"Connected {RouterCatalog.LabelFor(account.Provider)}";
                return;
            }
            var key = _store.Secrets.Read(account.CredentialId);
            var url = NativeProviderStore.NormalizeUrl(account.BaseUrl).TrimEnd('/') + "/models";
            using var request = new HttpRequestMessage(HttpMethod.Get, url);
            if (!string.IsNullOrEmpty(key))
            {
                if (account.Protocol == NativeProviderProtocol.Anthropic) request.Headers.TryAddWithoutValidation("x-api-key", key);
                else request.Headers.Authorization = new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", key);
            }
            if (account.Protocol == NativeProviderProtocol.Anthropic) request.Headers.TryAddWithoutValidation("anthropic-version", "2023-06-01");
            using var response = await new HttpClient { Timeout = TimeSpan.FromSeconds(8) }.SendAsync(request);
            if (!response.IsSuccessStatusCode) throw new NativeProviderException($"Provider returned HTTP {(int)response.StatusCode}.");
            Status = $"Connected {RouterCatalog.LabelFor(account.Provider)}";
        }
        catch (Exception ex) { Error = ex.Message; }
    }

    public Task RemoveAsync(RouterConnection connection)
    {
        if (_store.State.Accounts.FirstOrDefault(a => a.Id == connection.Id) is { } account) _store.Remove(account);
        return RefreshAsync();
    }

    public async Task TestNodeAsync(RouterNode node)
    {
        try
        {
            var endpoint = _store.State.Endpoints.FirstOrDefault(item => item.Id == node.Id) ?? throw new NativeProviderException("Custom endpoint not found.");
            var key = endpoint.CredentialId is null ? null : _store.Secrets.Read(endpoint.CredentialId);
            var baseUrl = NativeProviderStore.NormalizeUrl(endpoint.BaseUrl).TrimEnd('/');
            using var request = endpoint.Protocol == NativeProviderProtocol.Anthropic
                ? new HttpRequestMessage(HttpMethod.Post, baseUrl + "/messages") { Content = new StringContent(JsonSerializer.Serialize(new { model = "claude-3-5-haiku-latest", max_tokens = 1, messages = new[] { new { role = "user", content = "ping" } } }), Encoding.UTF8, "application/json") }
                : new HttpRequestMessage(HttpMethod.Get, baseUrl + "/models");
            if (!string.IsNullOrEmpty(key))
            {
                if (endpoint.Protocol == NativeProviderProtocol.Anthropic) request.Headers.TryAddWithoutValidation("x-api-key", key);
                else request.Headers.Authorization = new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", key);
            }
            if (endpoint.Protocol == NativeProviderProtocol.Anthropic) request.Headers.TryAddWithoutValidation("anthropic-version", "2023-06-01");
            using var response = await new HttpClient { Timeout = TimeSpan.FromSeconds(8) }.SendAsync(request);
            if (!response.IsSuccessStatusCode) throw new NativeProviderException($"Custom endpoint returned HTTP {(int)response.StatusCode}.");
            Status = $"Connected {endpoint.Name}";
        }
        catch (Exception ex) { Error = ex.Message; }
    }

    public async Task EnableTunnelAsync()
    {
        try
        {
            var key = _store.Secrets.Read("share.key") ?? CreateShareKey();
            _gateway.Start();
            Tunnel = new RouterTunnel(true, _gateway.Running, _gateway.Url.ToString().TrimEnd('/'), "", "", true, 0);
            Keys.Clear(); Keys.Add(new RouterKey("share.key", "Share key", key));
            var publicUrl = await _tunnelProcess.StartAsync(
                _gateway.Url.Port,
                progress => Tunnel = new RouterTunnel(true, _gateway.Running, _gateway.Url.ToString().TrimEnd('/'), "", "", true, (int)(progress.Fraction * 100)));
            var shortId = Uri.TryCreate(publicUrl, UriKind.Absolute, out var share)
                ? share.Host.Split('.')[0]
                : "";
            Tunnel = new RouterTunnel(true, _gateway.Running, _gateway.Url.ToString().TrimEnd('/'), publicUrl, shortId, false, 100);
            Status = "Sharing is enabled.";
        }
        catch (Exception ex) { _tunnelProcess.Stop(); _gateway.Stop(); Error = ex.Message; Tunnel = RouterTunnel.Idle; }
    }

    public Task DisableTunnelAsync() { _tunnelProcess.Stop(); _gateway.Stop(); Tunnel = RouterTunnel.Idle; return Task.CompletedTask; }
    public void CopyShareUrl() { if (!string.IsNullOrEmpty(Tunnel.ShareUrl)) { NativeClipboard.SetText(Tunnel.ShareUrl); Status = "Copied"; } }

    public Task CreateCustomNodeAsync(bool registerKey = true)
    {
        try
        {
            var secret = string.IsNullOrWhiteSpace(CustomApiKey) ? null : CustomApiKey.Trim();
            var endpoint = _editingNodeId is { } editingId && _store.State.Endpoints.FirstOrDefault(item => item.Id == editingId) is { } existing
                ? existing
                : null;
            if (endpoint is not null)
            {
                _store.UpdateCustom(endpoint, CustomName, CustomPrefix, CustomBaseUrl, CustomKind.Protocol(), CustomApiType == CustomOpenAiApiType.Responses ? "responses" : "chat", secret);
                _editingNodeId = null;
                OnPropertyChanged(nameof(IsEditingCustom));
                Status = $"Custom API “{CustomName.Trim()}” updated";
            }
            else
            {
                var added = _store.AddCustom(CustomName, SanitizedPrefix(string.IsNullOrWhiteSpace(CustomPrefix) ? CustomName : CustomPrefix), CustomBaseUrl, CustomKind.Protocol(), CustomApiType == CustomOpenAiApiType.Responses ? "responses" : "chat", secret);
                if (registerKey) _store.AddCustomAccount(added, CustomApiKey);
                Status = $"Custom API “{added.Name}” added";
            }
            CustomApiKey = "";
            return RefreshAsync();
        }
        catch (Exception ex) { Error = ex.Message; return Task.CompletedTask; }
    }

    public void BeginEditNode(RouterNode node)
    {
        if (_store.State.Endpoints.FirstOrDefault(item => item.Id == node.Id) is not { } endpoint) return;
        _editingNodeId = endpoint.Id;
        CustomName = endpoint.Name;
        CustomPrefix = endpoint.Prefix;
        CustomBaseUrl = endpoint.BaseUrl;
        CustomKind = endpoint.Type.StartsWith("anthropic", StringComparison.OrdinalIgnoreCase) ? CustomApiKind.AnthropicCompatible : CustomApiKind.OpenaiCompatible;
        CustomApiType = endpoint.ApiType == "responses" ? CustomOpenAiApiType.Responses : CustomOpenAiApiType.Chat;
        CustomApiKey = "";
        Error = null;
        OnPropertyChanged(nameof(IsEditingCustom));
    }

    public void CancelEditNode()
    {
        _editingNodeId = null;
        CustomApiKey = "";
        OnPropertyChanged(nameof(IsEditingCustom));
    }

    public Task DeleteNodeAsync(RouterNode node)
    {
        if (_store.State.Endpoints.FirstOrDefault(e => e.Id == node.Id) is { } endpoint) _store.Remove(endpoint);
        return RefreshAsync();
    }

    public Task ConnectExistingNodeAsync(RouterNode node)
    {
        if (_store.State.Endpoints.FirstOrDefault(e => e.Id == node.Id) is { } endpoint) _store.AddCustomAccount(endpoint, string.IsNullOrWhiteSpace(CustomApiKey) ? null : CustomApiKey.Trim());
        CustomApiKey = "";
        return RefreshAsync();
    }

    public string SanitizedPrefix(string raw) => NativeProviderStore.SanitizePrefix(raw);

    public Task CreateShareKeyAsync() { var key = CreateShareKey(); Keys.Clear(); Keys.Add(new RouterKey("share.key", "Share key", key)); return Task.CompletedTask; }

    public Task<NativeResponse> CompleteAsync(IReadOnlyList<NativeMessage> messages, IReadOnlyList<NativeToolDefinition> tools, string? model = null, CancellationToken ct = default) => _router.CompleteAsync(messages, tools, string.IsNullOrWhiteSpace(model) ? SelectedModelID : model, ct);
    public bool HasImageFallback => _imageRouter.HasFallback;
    public bool ImageGenerationCommandVisible => _imageRouter.CommandVisible(SelectedModelID);
    public Task<NativeImageGeneration> GenerateImageAsync(string prompt, CancellationToken ct = default) => _imageRouter.GenerateAsync(prompt, SelectedModelID, ct);
    public bool HasActiveRoute => _store.State.Accounts.Any(a => a.Active);
    public string CurrentProvider => CurrentAccount is { } account ? RouterCatalog.LabelFor(account.Provider) : "Provider";
    public string CurrentModel => CurrentAccount is { } account
        ? (CanServe(account, SelectedModelID) ? SelectedModelID : account.Model)
        : "";

    public int ContextWindowFor(string? model)
    {
        if (!string.IsNullOrWhiteSpace(model) && _contextWindows.TryGetValue(model, out var live) && live > 0) return live;
        var account = _store.State.Accounts
            .Where(a => a.Active)
            .OrderBy(a => a.Priority)
            .FirstOrDefault(a => CanServe(a, model))
            ?? CurrentAccount;
        return account?.Protocol switch
        {
            // Provider defaults are only a safety fallback; live context_length wins.
            NativeProviderProtocol.Anthropic => 200_000,
            NativeProviderProtocol.ChatGpt => 128_000,
            _ => ContextCompaction.DefaultContextWindow,
        };
    }

    public ContextBudget ContextBudgetFor(string? model, IReadOnlyList<NativeToolDefinition> tools) =>
        ContextCompaction.Budget(ContextWindowFor(model), toolDefinitionTokens: ContextCompaction.EstimateTokens(tools));

    public string? CompactionModelID(string? avoid)
    {
        var account = _store.State.Accounts
            .Where(a => a.Active)
            .OrderBy(a => a.Priority)
            .FirstOrDefault(a => CanServe(a, SelectedModelID))
            ?? CurrentAccount;
        if (account is null) return null;
        var candidates = ModelsFor(account)
            .Where(model => !string.IsNullOrWhiteSpace(model))
            .Distinct(StringComparer.Ordinal)
            .OrderBy(model => string.Equals(model, avoid, StringComparison.Ordinal) ? 1 : 0)
            .ThenBy(model => IsCompactModel(model) ? 0 : 1)
            .ToList();
        return candidates.FirstOrDefault() ?? account.Model;
    }

    public bool PreserveProviderItems(string? model) =>
        _store.State.Accounts.Any(account => account.Active
            && account.Protocol == NativeProviderProtocol.ChatGpt
            && CanServe(account, model));

    private NativeProviderAccount? CurrentAccount => _store.State.Accounts
        .Where(a => a.Active)
        .OrderBy(a => a.Priority)
        .FirstOrDefault(a => CanServe(a, SelectedModelID))
        ?? _store.State.Accounts.Where(a => a.Active).OrderBy(a => a.Priority).FirstOrDefault();

    private void RefreshState()
    {
        Connections.Clear(); foreach (var account in _store.State.Accounts) Connections.Add(new RouterConnection(account));
        Models.Clear();
        foreach (var model in _store.State.Accounts.Where(a => a.Active).SelectMany(ModelsFor))
        {
            if (!Models.Contains(model, StringComparer.Ordinal)) Models.Add(model);
        }
        if (string.IsNullOrWhiteSpace(SelectedModelID))
        {
            SelectedModelID = Models.FirstOrDefault() ?? "";
        }
        Nodes.Clear(); foreach (var endpoint in _store.State.Endpoints) Nodes.Add(new RouterNode(endpoint));
        Keys.Clear(); if (_store.Secrets.Read("share.key") is { } key) Keys.Add(new RouterKey("share.key", "Share key", key));
        Reachable = true; OnPropertyChanged(nameof(Reachable));
    }

    private async Task RefreshModelsAsync()
    {
        using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(8) };
        foreach (var account in _store.State.Accounts.Where(a => a.Active))
        {
            var fallback = ModelsFor(account).ToList();
            if (account.Protocol == NativeProviderProtocol.ChatGpt) { account.Models = fallback; continue; }
            try
            {
                var url = NativeProviderStore.NormalizeUrl(account.BaseUrl).TrimEnd('/') + "/models";
                using var request = new HttpRequestMessage(HttpMethod.Get, url);
                var key = _store.Secrets.Read(account.CredentialId);
                if (!string.IsNullOrWhiteSpace(key))
                {
                    if (account.Protocol == NativeProviderProtocol.Anthropic) request.Headers.TryAddWithoutValidation("x-api-key", key);
                    else request.Headers.Authorization = new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", key);
                }
                if (account.Protocol == NativeProviderProtocol.Anthropic) request.Headers.TryAddWithoutValidation("anthropic-version", "2023-06-01");
                using var response = await http.SendAsync(request);
                var root = JsonNode.Parse(await response.Content.ReadAsStringAsync());
                var live = new List<string>();
                if (response.IsSuccessStatusCode)
                {
                    foreach (var item in root?["data"]?.AsArray() ?? new JsonArray())
                    {
                        var id = item?["id"]?.GetValue<string>();
                        if (string.IsNullOrWhiteSpace(id)) continue;
                        var context = item?["context_length"]?.GetValue<int>() ?? item?["context_window"]?.GetValue<int>() ?? 0;
                        if (context > 0) _contextWindows[id] = context;
                        if (!live.Contains(id, StringComparer.Ordinal)) live.Add(id);
                    }
                }
                account.Models = live.Count > 0 ? live : fallback;
            }
            catch { account.Models = fallback; }
        }
        _store.Save();
        RefreshState();
    }

    private static IEnumerable<string> ModelsFor(NativeProviderAccount account)
    {
        if ((account.Models ?? []).Count > 0)
        {
            foreach (var model in account.Models.Where(model => !string.IsNullOrWhiteSpace(model))) yield return model;
            yield break;
        }
        if (!string.IsNullOrWhiteSpace(account.Model)) yield return account.Model;
        if (RouterCatalog.KindFor(account.Provider) is { DefaultModel: { Length: > 0 } fallback }) yield return fallback;
    }

    private static bool CanServe(NativeProviderAccount account, string? model) =>
        string.IsNullOrWhiteSpace(model)
        || string.Equals(account.Model, model, StringComparison.Ordinal)
        || (account.Models ?? []).Contains(model, StringComparer.Ordinal)
        || (account.Models ?? []).Count == 0
            && string.Equals(RouterCatalog.KindFor(account.Provider)?.DefaultModel, model, StringComparison.Ordinal);

    private static bool IsCompactModel(string model)
    {
        var id = model.ToLowerInvariant();
        return id.Contains("mini") || id.Contains("nano") || id.Contains("haiku")
            || id.Contains("flash") || id.Contains("lite") || id.Contains("small");
    }

    private string CreateShareKey()
    {
        var key = Convert.ToBase64String(RandomNumberGenerator.GetBytes(24)).Replace("+", "-").Replace("/", "_").TrimEnd('=');
        _store.Secrets.Write("share.key", key); return key;
    }

    private async Task<NativeGatewayResponse> HandleGatewayAsync(NativeGatewayRequest request)
    {
        var expected = _store.Secrets.Read("share.key");
        if (string.IsNullOrEmpty(expected) || !string.Equals(request.Headers.GetValueOrDefault("authorization"), $"Bearer {expected}", StringComparison.Ordinal)) return JsonResponse(401, new { error = new { message = "A valid share key is required" } });
        if (request.Method == "GET" && request.Path == "/v1/models")
        {
            var data = _store.State.Accounts.Where(a => a.Active).SelectMany(account => ModelsFor(account).Distinct(StringComparer.Ordinal).Select(model => new { id = model, @object = "model", owned_by = RouterCatalog.LabelFor(account.Provider) }));
            return JsonResponse(200, new { @object = "list", data });
        }
        if (request.Method != "POST" || request.Path != "/v1/chat/completions") return JsonResponse(404, new { error = new { message = "Not found" } });
        try
        {
            var root = JsonNode.Parse(request.Body)!.AsObject();
            var messages = (root["messages"]?.AsArray() ?? throw new NativeProviderException("messages is required")).Select(MessageFromJson).ToList();
            var tools = (root["tools"]?.AsArray() ?? new JsonArray()).Select(ToolFromJson).Where(t => t is not null).Cast<NativeToolDefinition>().ToList();
            var response = await _router.CompleteAsync(messages, tools, root["model"]?.GetValue<string>());
            var message = new JsonObject { ["role"] = "assistant", ["content"] = response.Message.Content };
            if (response.Message.ToolCalls is { Count: > 0 }) message["tool_calls"] = new JsonArray(response.Message.ToolCalls.Select(call => new JsonObject { ["id"] = call.Id, ["type"] = "function", ["function"] = new JsonObject { ["name"] = call.Name, ["arguments"] = call.Arguments } }).ToArray());
            var result = new JsonObject { ["id"] = $"chatcmpl-{Guid.NewGuid():N}", ["object"] = "chat.completion", ["choices"] = new JsonArray(new JsonObject { ["index"] = 0, ["message"] = message, ["finish_reason"] = response.Message.ToolCalls?.Count > 0 ? "tool_calls" : "stop" }) };
            if (response.Usage is { } usage) result["usage"] = new JsonObject { ["prompt_tokens"] = usage.InputTokens, ["completion_tokens"] = usage.OutputTokens, ["total_tokens"] = usage.InputTokens + usage.OutputTokens };
            return new NativeGatewayResponse(200, Encoding.UTF8.GetBytes(result.ToJsonString()));
        }
        catch (NativeProviderException ex) { return JsonResponse(ex.StatusCode ?? 502, new { error = new { message = ex.Message, type = ex.IsLimit ? "provider_limit" : "provider_error" } }); }
        catch (Exception ex) { return JsonResponse(400, new { error = new { message = ex.Message } }); }
    }

    private static NativeMessage MessageFromJson(JsonNode node)
    {
        var obj = node.AsObject();
        var calls = (obj["tool_calls"]?.AsArray() ?? new JsonArray()).Select(call => new NativeToolCall(call?["id"]?.GetValue<string>() ?? Guid.NewGuid().ToString(), call?["function"]?["name"]?.GetValue<string>() ?? "tool", call?["function"]?["arguments"]?.GetValue<string>() ?? "{}" )).ToList();
        return new NativeMessage(obj["role"]?.GetValue<string>() ?? "user", obj["content"]?.GetValue<string>() ?? "", obj["tool_call_id"]?.GetValue<string>(), calls);
    }

    private static NativeToolDefinition? ToolFromJson(JsonNode? node)
    {
        var function = node?["function"]?.AsObject() ?? node?.AsObject();
        var name = function?["name"]?.GetValue<string>();
        return name is null ? null : new NativeToolDefinition(name, function?["description"]?.GetValue<string>() ?? "", function?["parameters"]?.DeepClone() ?? new JsonObject { ["type"] = "object" });
    }

    private static NativeGatewayResponse JsonResponse(int status, object body) => new(status, Encoding.UTF8.GetBytes(JsonSerializer.Serialize(body)));

    private void StartCallbackListener()
    {
        _callbackListener?.Stop();
        _callbackListener = new HttpListener();
        _callbackListener.Prefixes.Add("http://localhost:1455/");
        _callbackListener.Start();
        _ = Task.Run(async () =>
        {
            try
            {
                var context = await _callbackListener.GetContextAsync();
                var callback = context.Request.Url;
                var bytes = Encoding.UTF8.GetBytes("Login received. Return to the app.");
                context.Response.ContentType = "text/plain"; context.Response.ContentLength64 = bytes.Length; await context.Response.OutputStream.WriteAsync(bytes); context.Response.Close();
                if (callback is not null && Flow is RouterFlow.Browser browser) await FinishCallbackAsync(browser, callback);
            }
            catch { }
        });
    }

    private async Task<OAuthToken> ExchangeCodeAsync(string code, string redirect, string verifier)
    {
        using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(20) };
        var form = new Dictionary<string, string> { ["grant_type"] = "authorization_code", ["code"] = code, ["redirect_uri"] = redirect, ["client_id"] = "app_EMoamEEZ73f0CkXaXp7hrann", ["code_verifier"] = verifier };
        using var response = await http.PostAsync("https://auth.openai.com/oauth/token", new FormUrlEncodedContent(form));
        var json = JsonNode.Parse(await response.Content.ReadAsStringAsync())?.AsObject() ?? throw new NativeProviderException("The sign-in response was invalid.");
        if (!response.IsSuccessStatusCode) throw new NativeProviderException(json["error_description"]?.GetValue<string>() ?? "Sign-in failed.", (int)response.StatusCode);
        var access = json["access_token"]?.GetValue<string>() ?? throw new NativeProviderException("The sign-in response did not contain a token.");
        return new OAuthToken(access, json["refresh_token"]?.GetValue<string>(), json["id_token"]?.GetValue<string>());
    }

    private async Task<bool> RefreshCredentialAsync(NativeProviderAccount account, CancellationToken ct)
    {
        if (account.Provider != "gpt" || account.AuthType != "chatgpt" || account.RefreshCredentialId is null) return false;
        var refresh = _store.Secrets.Read(account.RefreshCredentialId);
        if (string.IsNullOrWhiteSpace(refresh)) return false;
        try
        {
            using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(20) };
            var form = new Dictionary<string, string>
            {
                ["grant_type"] = "refresh_token",
                ["refresh_token"] = refresh,
                ["client_id"] = "app_EMoamEEZ73f0CkXaXp7hrann",
            };
            using var response = await http.PostAsync("https://auth.openai.com/oauth/token", new FormUrlEncodedContent(form), ct);
            var json = JsonNode.Parse(await response.Content.ReadAsStringAsync(ct))?.AsObject();
            if (!response.IsSuccessStatusCode || json is null) return false;
            var access = json["access_token"]?.GetValue<string>();
            if (string.IsNullOrWhiteSpace(access)) return false;
            _store.ReplaceCredential(account, access);
            if (json["id_token"]?.GetValue<string>() is { Length: > 0 } idToken)
            {
                account.SessionAccountId = Claims(idToken).GetValueOrDefault("chatgpt_account_id");
                _store.Save();
            }
            if (json["refresh_token"]?.GetValue<string>() is { Length: > 0 } nextRefresh) _store.ReplaceRefreshCredential(account, nextRefresh);
            return true;
        }
        catch (OperationCanceledException) when (!ct.IsCancellationRequested) { return false; }
        catch { return false; }
    }

    private static Dictionary<string, string> Claims(string token)
    {
        var parts = token.Split('.'); if (parts.Length < 2) return [];
        try { var raw = parts[1].Replace('-', '+').Replace('_', '/'); raw += new string('=', (4 - raw.Length % 4) % 4); return JsonSerializer.Deserialize<Dictionary<string, string>>(Convert.FromBase64String(raw)) ?? []; } catch { return []; }
    }

    private static Dictionary<string, string> ParseQuery(string value) => value.TrimStart('?').Split('&', StringSplitOptions.RemoveEmptyEntries).Select(part => part.Split('=', 2)).Where(parts => parts.Length == 2).ToDictionary(parts => Uri.UnescapeDataString(parts[0]), parts => Uri.UnescapeDataString(parts[1]), StringComparer.OrdinalIgnoreCase);
    private static string Token() => Convert.ToBase64String(RandomNumberGenerator.GetBytes(32)).Replace("+", "-").Replace("/", "_").TrimEnd('=');
    private sealed record OAuthToken(string AccessToken, string? RefreshToken, string? IdToken);

    public void Dispose() { CancelFlow(); _tunnelProcess.Dispose(); _gateway.Dispose(); }
}

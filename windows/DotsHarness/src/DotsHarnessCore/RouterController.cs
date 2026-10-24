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
    private CancellationTokenSource? _devicePollCancellation;
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
    private string _customModel = "";
    private string _customContextWindow = "";
    private CustomApiKind _customKind = CustomApiKind.OpenaiCompatible;
    private CustomOpenAiApiType _customApiType = CustomOpenAiApiType.Chat;
    private string? _editingNodeId;
    private string _selectedModelID = "";
    private AgentUsageMode _usageMode = AgentUsageMode.Standard;
    private AgentResponseStylePreference _responseStylePreference = AgentResponseStylePreference.Ultra;
    public bool AutoAccountFailoverAfterLimit { get; set; }
    private int _contextCompactionThresholdPercent = 90;
    private readonly Dictionary<string, int> _contextWindows = new(StringComparer.Ordinal);
    private DateTimeOffset? _lastModelRefreshUtc;
    private string? _pendingClaudeUsageRefreshAccountId;

    public ObservableCollection<RouterConnection> Connections { get; } = new();
    public ObservableCollection<string> Models { get; } = new();
    public IReadOnlyList<ModelContextSetting> ModelContextSettings => _store.State.Accounts
        .SelectMany(account => ModelsFor(account)
            .Where(model => !string.IsNullOrWhiteSpace(model))
            .Select(model => new { Account = account, account.Provider, Model = model }))
        .GroupBy(item => RouterCatalog.ModelContextOverrideKey(item.Provider, item.Model), StringComparer.Ordinal)
        .Select(group => group.First())
        .Select(item => new ModelContextSetting(
            item.Provider,
            item.Model,
            DetectedContextWindowFor(item.Model, item.Provider)
                ?? (item.Account.ContextWindow is > 0 and var declared ? declared : null),
            ModelContextWindowOverrideFor(item.Model, item.Provider)))
        .OrderBy(item => RouterCatalog.LabelFor(item.Provider), StringComparer.CurrentCultureIgnoreCase)
        .ThenBy(item => item.Model, StringComparer.CurrentCultureIgnoreCase)
        .ToList();
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
    /// <summary>Optional: the model to request when the server cannot list its models.</summary>
    public string CustomModel { get => _customModel; set => SetProperty(ref _customModel, value); }
    /// <summary>Optional context window in tokens; empty asks the server, then guesses.</summary>
    public string CustomContextWindow { get => _customContextWindow; set => SetProperty(ref _customContextWindow, value); }
    /// <summary>OpenAI-compatible servers already running on this machine and not connected yet.</summary>
    public IReadOnlyList<LocalServer> DetectedServers { get; private set; } = [];
    public CustomApiKind CustomKind { get => _customKind; set => SetProperty(ref _customKind, value); }
    public CustomOpenAiApiType CustomApiType { get => _customApiType; set => SetProperty(ref _customApiType, value); }
    public string SelectedModelID { get => _selectedModelID; set => SetProperty(ref _selectedModelID, value?.Trim() ?? ""); }
    public AgentUsageMode UsageMode
    {
        get => _usageMode;
        set
        {
            if (!SetProperty(ref _usageMode, value)) return;
            _router.UsageMode = value;
        }
    }
    /// <summary>Whether a run may delegate. Off until the user opts in.</summary>
    public bool? SubagentsPreference { get; set; }
    public bool SubagentsEnabled => SubagentsPreference ?? false;
    /// <summary>Fast mode may delegate even when the Settings preference is off.</summary>
    public bool SubagentsActive => SubagentsEnabled || (FastMode && SupportsFast(SelectedModelID));
    public bool FastMode
    {
        get => _router.Fast;
        set { _router.Fast = value; OnPropertyChanged(); }
    }
    public bool SupportsFast(string? model) => NativeFastCatalog.Supports(model);
    public AgentResponseStylePreference ResponseStylePreference
    {
        get => _responseStylePreference;
        set
        {
            if (!SetProperty(ref _responseStylePreference, value)) return;
            _router.ResponseStylePreference = value;
        }
    }
    public int ContextCompactionThresholdPercent
    {
        get => _contextCompactionThresholdPercent;
        set
        {
            var normalized = Math.Clamp(value, 0, 100);
            if (!SetProperty(ref _contextCompactionThresholdPercent, normalized)) return;
            _router.CompactionThresholdPercent = normalized;
        }
    }
    public string SelectedEffort
    {
        get => _router.Effort;
        set { _router.Effort = value ?? ""; OnPropertyChanged(); }
    }
    public IReadOnlyList<string> Efforts(string? model) => NativeEffortCatalog.Levels(model);
    public bool IsEditingCustom => _editingNodeId is not null;
    public NativeProviderStore Store => _store;
    public ProviderImageAdapterRegistry ImageAdapters => _imageAdapters;
    public event Action<ConnectionTransition>? ConnectionChanged;

    public RouterController(
        SupportPaths paths,
        ProviderImageAdapterRegistry? imageAdapters = null,
        IProviderSecretStore? providerSecrets = null,
        NativeProviderStore? providerStore = null)
    {
        paths.Ensure();
        _store = providerStore ?? new NativeProviderStore(paths.Root, providerSecrets ?? new PlatformProviderSecrets(paths.Root));
        _router = new NativeProviderRouter(_store, RefreshCredentialAsync);
        _router.RefreshUsage = () => _accountUsage;
        _imageAdapters = imageAdapters ?? new ProviderImageAdapterRegistry();
        NativeProviderImageAdapters.Register(_imageAdapters);
        _imageRouter = new NativeProviderImageRouter(_store, _imageAdapters);
        _gateway = new NativeProviderGateway(18767, HandleGatewayAsync);
        _tunnelProcess = new CloudTunnelProcess(paths);
        RefreshState();
    }

    public async Task RefreshAsync()
    {
        // Accounts and cached models are local: publish them now, then refine from the network.
        RefreshState(readShareKey: false);
        await RefreshModelsAsync(force: true);
        Status = $"{Connections.Count(c => c.Active)} active · {Connections.Count} connections";
    }

    public Task RefreshModelsIfNeededAsync() => RefreshModelsAsync(force: false);

    public Task StartConnectAsync() => SelectedKind.Kind switch
    {
        RouterAuthKind.ApiKey => CreateApiKeyAsync(),
        RouterAuthKind.OauthBrowser => StartBrowserAsync(),
        RouterAuthKind.OauthDevice => StartDeviceAsync(),
        _ => Task.CompletedTask,
    };

    public async Task CreateApiKeyAsync()
    {
        try
        {
            if (string.IsNullOrWhiteSpace(ApiKeyName) || string.IsNullOrWhiteSpace(ApiKeyValue)) throw new NativeProviderException("Name and API key are required.");
            if (string.IsNullOrWhiteSpace(SelectedKind.BaseUrl)) throw new NativeProviderException("Use Custom API for this provider until a direct endpoint is configured.");
            var previous = CurrentAccount?.Name;
            var added = _store.AddAccount(RouterCatalog.Descriptor(SelectedKind), ApiKeyName, ApiKeyValue);
            ApiKeyValue = "";
            ConnectionChanged?.Invoke(new ConnectionTransition("added", previous, added.Name, "preserved", []));
            Status = $"Connected {SelectedKind.Name}";
            await RefreshAsync();
        }
        catch (Exception ex) { Error = ex.Message; }
    }

    public async Task StartBrowserAsync()
    {
        if (SelectedKind.Id is not ("gpt" or "claude")) { Error = "Native browser login is not available for this provider. Use an API key or Custom API."; return; }
        try
        {
            var verifier = Token();
            var challenge = Convert.ToBase64String(SHA256.HashData(Encoding.UTF8.GetBytes(verifier))).Replace("+", "-").Replace("/", "_").TrimEnd('=');
            var state = Token();
            var isClaude = SelectedKind.Id == "claude";
            var port = isClaude ? 54545 : 1455;
            var redirect = isClaude ? "http://localhost:54545/callback" : "http://localhost:1455/auth/callback";
            var clientId = isClaude ? "9d1c250a-e61b-44d9-88ed-5944d1962f5e" : "app_EMoamEEZ73f0CkXaXp7hrann";
            var query = isClaude
                ? new Dictionary<string, string> { ["response_type"] = "code", ["client_id"] = clientId, ["redirect_uri"] = redirect, ["scope"] = "org:create_api_key user:profile user:inference", ["code_challenge"] = challenge, ["code_challenge_method"] = "S256", ["state"] = state }
                : new Dictionary<string, string> { ["response_type"] = "code", ["client_id"] = clientId, ["redirect_uri"] = redirect, ["scope"] = "openid profile email offline_access api.connectors.read api.connectors.invoke", ["code_challenge"] = challenge, ["code_challenge_method"] = "S256", ["id_token_add_organizations"] = "true", ["codex_cli_simplified_flow"] = "true", ["originator"] = "dots_harness", ["state"] = state };
            var authEndpoint = isClaude ? "https://claude.ai/oauth/authorize" : "https://auth.openai.com/oauth/authorize";
            var authUrl = authEndpoint + "?" + string.Join("&", query.Select(item => $"{Uri.EscapeDataString(item.Key)}={Uri.EscapeDataString(item.Value)}"));
            Flow = new RouterFlow.Browser(SelectedKind.Id, authUrl, redirect, verifier, state);
            StartCallbackListener(port);
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
        if (!string.IsNullOrEmpty(query.GetValueOrDefault("error"))) { Error = query.GetValueOrDefault("error_description") ?? query["error"]!; return; }
        var rawCode = query.GetValueOrDefault("code");
        if (string.IsNullOrEmpty(rawCode)) { Error = "No authorization code in callback."; return; }
        var codeParts = rawCode.Split('#', 2);
        var returnedState = query.GetValueOrDefault("state") ?? (codeParts.Length > 1 ? codeParts[1] : null);
        if (returnedState != browser.State) { Error = "The login callback state did not match."; return; }
        try
        {
            var token = browser.Provider == "claude"
                ? await ExchangeClaudeCodeAsync(rawCode, returnedState, browser.RedirectUri, browser.CodeVerifier)
                : await ExchangeCodeAsync(rawCode, browser.RedirectUri, browser.CodeVerifier);
            var claims = Claims(token.IdToken ?? token.AccessToken);
            var provider = RouterCatalog.KindFor(browser.Provider)!;
            var isGpt = browser.Provider == "gpt";
            var accountName = claims.GetValueOrDefault("email") ?? (isGpt ? "GPT account" : "Claude account");
            var previous = CurrentAccount?.Name;
            var added = _store.AddAccount(RouterCatalog.Descriptor(provider), accountName, token.AccessToken,
                authType: isGpt ? "chatgpt" : "claudeOAuth", email: claims.GetValueOrDefault("email"),
                sessionAccountId: claims.GetValueOrDefault("chatgpt_account_id"), refreshSecret: token.RefreshToken);
            ConnectionChanged?.Invoke(new ConnectionTransition("added", previous, added.Name, "preserved", []));
            CallbackPaste = "";
            Flow = RouterFlow.IdleFlow;
            _callbackListener?.Stop(); _callbackListener = null;
            Status = $"Connected {provider.Name}";
            await RefreshAsync();
        }
        catch (Exception ex) { Error = ex.Message; }
    }

    public async Task StartDeviceAsync()
    {
        if (SelectedKind.Id != "grok-cli")
        {
            Error = "This provider does not expose a verified native device login yet. Use an API key or Custom API.";
            return;
        }

        CancelDevicePoll();
        var cancellation = new CancellationTokenSource(TimeSpan.FromMinutes(5));
        _devicePollCancellation = cancellation;
        var ct = cancellation.Token;
        var provider = SelectedKind;
        const string clientId = "b1a00492-073a-47ea-816f-4c329264a828";
        const string scope = "openid profile email offline_access grok-cli:access api:access conversations:read conversations:write";
        const string deviceCodeUrl = "https://auth.x.ai/oauth2/device/code";
        const string tokenUrl = "https://auth.x.ai/oauth2/token";

        try
        {
            using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(20) };
            using var startResponse = await http.PostAsync(deviceCodeUrl, new FormUrlEncodedContent(new Dictionary<string, string>
            {
                ["client_id"] = clientId,
                ["scope"] = scope,
            }), ct);
            var startText = await startResponse.Content.ReadAsStringAsync(ct);
            var start = JsonNode.Parse(startText)?.AsObject();
            if (!startResponse.IsSuccessStatusCode || start is null)
                throw new NativeProviderException(start?["error_description"]?.GetValue<string>() ?? start?["error"]?.GetValue<string>() ?? $"Device sign-in returned HTTP {(int)startResponse.StatusCode}.", (int)startResponse.StatusCode);

            var deviceCode = start["device_code"]?.GetValue<string>();
            var userCode = start["user_code"]?.GetValue<string>();
            var verificationUrl = start["verification_uri_complete"]?.GetValue<string>()
                ?? start["verification_uri"]?.GetValue<string>()
                ?? "https://accounts.x.ai/oauth2/device";
            if (string.IsNullOrWhiteSpace(deviceCode) || string.IsNullOrWhiteSpace(userCode))
                throw new NativeProviderException("The device sign-in response did not include a verification code.");

            var device = new RouterFlow.Device(provider.Id, userCode, verificationUrl, deviceCode, null,
                new Dictionary<string, HarnessPluginKit.JsonValue>());
            Flow = device;
            Status = "Complete sign-in in the browser.";
            Error = null;
            try
            {
                if (OperatingSystem.IsLinux()) Process.Start(new ProcessStartInfo("xdg-open", verificationUrl) { UseShellExecute = false });
                else Process.Start(new ProcessStartInfo(verificationUrl) { UseShellExecute = true });
            }
            catch { /* The verification URL remains visible in Settings. */ }

            var interval = Math.Clamp(start["interval"]?.GetValue<int>() ?? 5, 1, 30);
            while (true)
            {
                await Task.Delay(TimeSpan.FromSeconds(interval), ct);
                using var tokenResponse = await http.PostAsync(tokenUrl, new FormUrlEncodedContent(new Dictionary<string, string>
                {
                    ["grant_type"] = "urn:ietf:params:oauth:grant-type:device_code",
                    ["device_code"] = deviceCode,
                    ["client_id"] = clientId,
                }), ct);
                var tokenText = await tokenResponse.Content.ReadAsStringAsync(ct);
                var tokenJson = JsonNode.Parse(tokenText)?.AsObject();
                if (!tokenResponse.IsSuccessStatusCode)
                {
                    var errorCode = tokenJson?["error"]?.GetValue<string>() ?? "";
                    if (errorCode == "authorization_pending") continue;
                    if (errorCode == "slow_down") { interval += 5; continue; }
                    var errorMessage = tokenJson?["error_description"]?.GetValue<string>();
                    throw new NativeProviderException(!string.IsNullOrWhiteSpace(errorMessage)
                        ? errorMessage
                        : !string.IsNullOrWhiteSpace(errorCode) ? errorCode : $"Device sign-in returned HTTP {(int)tokenResponse.StatusCode}.", (int)tokenResponse.StatusCode);
                }

                var accessToken = tokenJson?["access_token"]?.GetValue<string>();
                if (string.IsNullOrWhiteSpace(accessToken))
                    throw new NativeProviderException("The sign-in response did not contain an access token.");
                if (!ReferenceEquals(Flow, device) || ct.IsCancellationRequested) return;

                var idToken = tokenJson?["id_token"]?.GetValue<string>();
                var claims = idToken is null ? new Dictionary<string, string>() : Claims(idToken);
                var accountName = claims.GetValueOrDefault("email") ?? "Grok Build account";
                var previous = CurrentAccount?.Name;
                var added = _store.AddAccount(RouterCatalog.Descriptor(provider), accountName, accessToken,
                    authType: "oauth", email: claims.GetValueOrDefault("email"), refreshSecret: tokenJson?["refresh_token"]?.GetValue<string>());
                ConnectionChanged?.Invoke(new ConnectionTransition("added", previous, added.Name, "preserved", []));
                Flow = RouterFlow.IdleFlow;
                Status = $"Connected {provider.Name}";
                await RefreshAsync();
                return;
            }
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested)
        {
            if (ReferenceEquals(_devicePollCancellation, cancellation)) Flow = RouterFlow.IdleFlow;
        }
        catch (Exception ex)
        {
            Error = ex.Message;
            if (Flow is RouterFlow.Device active && active.Provider == provider.Id) Flow = RouterFlow.IdleFlow;
        }
        finally
        {
            if (ReferenceEquals(_devicePollCancellation, cancellation)) _devicePollCancellation = null;
            cancellation.Dispose();
        }
    }

    public void CancelFlow()
    {
        try { _callbackListener?.Stop(); } catch { }
        _callbackListener = null;
        CancelDevicePoll();
        Flow = RouterFlow.IdleFlow;
        CallbackPaste = "";
    }

    private void CancelDevicePoll()
    {
        var cancellation = _devicePollCancellation;
        _devicePollCancellation = null;
        try { cancellation?.Cancel(); } catch (ObjectDisposedException) { }
    }

    private async Task ExpireBrowserAsync(string state)
    {
        await Task.Delay(TimeSpan.FromMinutes(5));
        if (Flow is RouterFlow.Browser browser && browser.State == state)
        {
            Error = "The sign-in request timed out. Start it again.";
            CancelFlow();
        }
    }

    public Task ToggleAsync(RouterConnection connection)
    {
        _store.SetActive(connection.Id, !connection.Active);
        ConnectionChanged?.Invoke(new ConnectionTransition("selected", connection.Name, connection.Name, "preserved", []));
        return RefreshAsync();
    }

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
            if (account.AuthType is "chatgpt" or "claudeOAuth" or "oauth")
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
            NativeProviderTransportHeaders.Apply(request.Headers, account.Provider);
            if (account.Protocol == NativeProviderProtocol.Anthropic) request.Headers.TryAddWithoutValidation("anthropic-version", "2023-06-01");
            using var response = await new HttpClient { Timeout = TimeSpan.FromSeconds(8) }.SendAsync(request);
            if (!response.IsSuccessStatusCode) throw new NativeProviderException($"Provider returned HTTP {(int)response.StatusCode}.");
            Status = $"Connected {RouterCatalog.LabelFor(account.Provider)}";
        }
        catch (Exception ex) { Error = ex.Message; }
    }

    public async Task RemoveAsync(RouterConnection connection)
    {
        if (_store.State.Accounts.FirstOrDefault(a => a.Id == connection.Id) is { } account)
        {
            try
            {
                var artifacts = _store.Remove(account);
                var verified = !_store.State.Accounts.Any(item => item.Id == account.Id)
                    && _store.Secrets.Read(account.CredentialId) is null
                    && (account.RefreshCredentialId is null || _store.Secrets.Read(account.RefreshCredentialId) is null);
                ConnectionChanged?.Invoke(new ConnectionTransition(
                    "removed", connection.Name, null, verified ? "verified" : "failed", artifacts));
            }
            catch (Exception ex)
            {
                Error = ex.Message;
                ConnectionChanged?.Invoke(new ConnectionTransition("removed", connection.Name, null, "failed", []));
            }
        }
        await RefreshAsync();
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
            var model = string.IsNullOrWhiteSpace(CustomModel) ? null : CustomModel.Trim();
            int? contextWindow = null;
            if (!string.IsNullOrWhiteSpace(CustomContextWindow))
            {
                if (!int.TryParse(CustomContextWindow.Trim(), out var parsed) || parsed <= 0)
                    throw new NativeProviderException("Context window must be a positive number.");
                contextWindow = parsed;
            }
            var endpoint = _editingNodeId is { } editingId && _store.State.Endpoints.FirstOrDefault(item => item.Id == editingId) is { } existing
                ? existing
                : null;
            if (endpoint is not null)
            {
                var previous = endpoint.Name;
                _store.UpdateCustom(endpoint, CustomName, CustomPrefix, CustomBaseUrl, CustomKind.Protocol(), CustomApiType == CustomOpenAiApiType.Responses ? "responses" : "chat", secret, model, contextWindow);
                _editingNodeId = null;
                OnPropertyChanged(nameof(IsEditingCustom));
                ConnectionChanged?.Invoke(new ConnectionTransition("replaced", previous, CustomName.Trim(), "preserved", []));
                Status = $"Custom API “{CustomName.Trim()}” updated";
            }
            else
            {
                var added = _store.AddCustom(CustomName, SanitizedPrefix(string.IsNullOrWhiteSpace(CustomPrefix) ? CustomName : CustomPrefix), CustomBaseUrl, CustomKind.Protocol(), CustomApiType == CustomOpenAiApiType.Responses ? "responses" : "chat", secret, model, contextWindow);
                if (registerKey) _store.AddCustomAccount(added, CustomApiKey);
                ConnectionChanged?.Invoke(new ConnectionTransition("added", null, added.Name, "preserved", []));
                Status = $"Custom API “{added.Name}” added";
            }
            CustomApiKey = "";
            CustomModel = "";
            CustomContextWindow = "";
            return RefreshAsync();
        }
        catch (Exception ex) { Error = ex.Message; return Task.CompletedTask; }
    }

    /// <summary>
    /// Finds OpenAI-compatible servers the user already runs on this machine
    /// (Ollama, LM Studio, llama.cpp, …) that are not connected yet.
    /// </summary>
    public async Task DetectLocalServersAsync()
    {
        var known = _store.State.Endpoints.Select(endpoint => endpoint.BaseUrl.TrimEnd('/')).ToHashSet(StringComparer.OrdinalIgnoreCase);
        DetectedServers = (await LocalServerDiscovery.ScanAsync()).Where(server => !known.Contains(server.BaseUrl)).ToList();
        OnPropertyChanged(nameof(DetectedServers));
    }

    /// <summary>One-click connect for a detected server: no key, models listed live.</summary>
    public async Task ConnectDetectedAsync(LocalServer server)
    {
        _editingNodeId = null;
        CustomName = server.Name;
        CustomPrefix = server.Name;
        CustomBaseUrl = server.BaseUrl;
        CustomApiKey = "";
        CustomModel = "";
        CustomContextWindow = "";
        CustomKind = CustomApiKind.OpenaiCompatible;
        CustomApiType = CustomOpenAiApiType.Chat;
        await CreateCustomNodeAsync(registerKey: true);
        await DetectLocalServersAsync();
    }

    /// <summary>
    /// Registers the bundled local server as one endpoint with one account,
    /// replacing whatever model it served before.
    /// </summary>
    public async Task PublishLocalNodeAsync(string name, string prefix, string baseUrl, string model, int contextWindow)
    {
        try
        {
            var endpoint = _store.State.Endpoints.FirstOrDefault(item => item.Prefix == prefix);
            if (endpoint is null)
            {
                endpoint = _store.AddCustom(name, prefix, baseUrl, NativeProviderProtocol.OpenAiCompatible, "chat", null, model, contextWindow);
            }
            else
            {
                _store.UpdateCustom(endpoint, name, prefix, baseUrl, NativeProviderProtocol.OpenAiCompatible, "chat", null, model, contextWindow);
                endpoint = _store.State.Endpoints.First(item => item.Id == endpoint.Id);
            }
            if (!_store.State.Accounts.Any(account => account.Provider == $"custom:{endpoint.Id}"))
                _store.AddCustomAccount(endpoint, null);
            await RefreshAsync();
        }
        catch (Exception ex) { Error = ex.Message; }
    }

    public void BeginEditNode(RouterNode node)
    {
        if (_store.State.Endpoints.FirstOrDefault(item => item.Id == node.Id) is not { } endpoint) return;
        _editingNodeId = endpoint.Id;
        CustomName = endpoint.Name;
        CustomPrefix = endpoint.Prefix;
        CustomBaseUrl = endpoint.BaseUrl;
        CustomKind = endpoint.Protocol == NativeProviderProtocol.Anthropic ? CustomApiKind.AnthropicCompatible : CustomApiKind.OpenaiCompatible;
        CustomApiType = endpoint.ApiType == "responses" ? CustomOpenAiApiType.Responses : CustomOpenAiApiType.Chat;
        CustomApiKey = "";
        CustomModel = endpoint.Model ?? "";
        CustomContextWindow = endpoint.ContextWindow?.ToString() ?? "";
        Error = null;
        OnPropertyChanged(nameof(IsEditingCustom));
    }

    public void CancelEditNode()
    {
        _editingNodeId = null;
        CustomApiKey = "";
        CustomModel = "";
        CustomContextWindow = "";
        OnPropertyChanged(nameof(IsEditingCustom));
    }

    public async Task DeleteNodeAsync(RouterNode node)
    {
        if (_store.State.Endpoints.FirstOrDefault(e => e.Id == node.Id) is { } endpoint)
        {
            try
            {
                var accounts = _store.State.Accounts.Where(account => account.Provider == $"custom:{endpoint.Id}").ToArray();
                var artifacts = _store.Remove(endpoint);
                var verified = !_store.State.Endpoints.Any(item => item.Id == endpoint.Id)
                    && !_store.State.Accounts.Any(account => account.Provider == $"custom:{endpoint.Id}")
                    && (endpoint.CredentialId is null || _store.Secrets.Read(endpoint.CredentialId) is null)
                    && accounts.All(account => _store.Secrets.Read(account.CredentialId) is null
                        && (account.RefreshCredentialId is null || _store.Secrets.Read(account.RefreshCredentialId) is null));
                ConnectionChanged?.Invoke(new ConnectionTransition("removed", endpoint.Name, null, verified ? "verified" : "failed", artifacts));
            }
            catch (Exception ex)
            {
                Error = ex.Message;
                ConnectionChanged?.Invoke(new ConnectionTransition("removed", endpoint.Name, null, "failed", []));
            }
        }
        await RefreshAsync();
    }

    public async Task ConnectExistingNodeAsync(RouterNode node)
    {
        try
        {
            if (_store.State.Endpoints.FirstOrDefault(e => e.Id == node.Id) is { } endpoint)
            {
                var previous = CurrentAccount?.Name;
                var added = _store.AddCustomAccount(endpoint, string.IsNullOrWhiteSpace(CustomApiKey) ? null : CustomApiKey.Trim());
                ConnectionChanged?.Invoke(new ConnectionTransition("added", previous, added.Name, "preserved", []));
            }
            CustomApiKey = "";
            await RefreshAsync();
        }
        catch (Exception ex)
        {
            Error = ex.Message;
        }
    }

    public string SanitizedPrefix(string raw) => NativeProviderStore.SanitizePrefix(raw);

    public Task CreateShareKeyAsync() { var key = CreateShareKey(); Keys.Clear(); Keys.Add(new RouterKey("share.key", "Share key", key)); return Task.CompletedTask; }

    public Task<NativeResponse> CompleteAsync(
        IReadOnlyList<NativeMessage> messages,
        IReadOnlyList<NativeToolDefinition> tools,
        string? model = null,
        CancellationToken ct = default,
        string? promptCacheKey = null,
        bool nativeCompactionDisabled = false,
        string? preferredAccountId = null,
        bool allowAccountFailoverAfterLimit = false,
        string? excludedAccountId = null,
        string? cacheComparisonScope = null,
        NativeCacheSession? cacheSession = null,
        string? effortOverride = null) =>
        _router.CompleteAsync(
            messages,
            tools,
            string.IsNullOrWhiteSpace(model) ? SelectedModelID : model,
            ct,
            promptCacheKey,
            effortOverride: effortOverride,
            contextWindow: ContextWindowFor(string.IsNullOrWhiteSpace(model) ? SelectedModelID : model),
            nativeCompactionDisabled: nativeCompactionDisabled,
            preferredAccountId: preferredAccountId,
            allowAccountFailoverAfterLimit: allowAccountFailoverAfterLimit,
            excludedAccountId: excludedAccountId,
            cacheComparisonScope: cacheComparisonScope,
            cacheSession: cacheSession);

    /// <summary>
    /// Background evaluators use the lightest connected model at its lowest
    /// supported effort, keeping repeated feedback analysis out of the main model's
    /// cost and latency path.
    /// </summary>
    public Task<NativeResponse> CompleteCheapestAsync(
        IReadOnlyList<NativeMessage> messages,
        CancellationToken ct = default)
    {
        var model = CheapestConnectedModelID() ?? CompactionModelID(null);
        var effort = model is null ? null : NativeEffortCatalog.Levels(model).FirstOrDefault();
        return _router.CompleteAsync(
            messages,
            [],
            model,
            ct,
            effortOverride: effort,
            contextWindow: ContextWindowFor(model));
    }

    /// One-shot translation with the lightest connected model at its lowest supported
    /// effort, whatever the conversation uses. Leaves router state untouched.
    public async Task<string> TranslateAsync(string text, string language, CancellationToken ct = default)
    {
        var model = CheapestConnectedModelID() ?? CompactionModelID(null);
        var effort = model is null ? "" : NativeEffortCatalog.Levels(model).FirstOrDefault() ?? "";
        var response = await _router.CompleteAsync(
            [
                new NativeMessage("system", $"Translate the user's text into {language}. If it is already in {language}, translate it into English. Output only the translation, nothing else."),
                new NativeMessage("user", text.Length > 8000 ? text[..8000] : text),
            ],
            [],
            model,
            ct,
            null,
            effort);
        return response.Message.Content.Trim();
    }

    public bool HasImageFallback => _imageRouter.HasFallback;
    public bool ImageGenerationCommandVisible => _imageRouter.CommandVisible(SelectedModelID);
    public Task<NativeImageGeneration> GenerateImageAsync(string prompt, CancellationToken ct = default) => _imageRouter.GenerateAsync(prompt, SelectedModelID, ct);
    public Task<NativeGeneratedMedia> GenerateMediaAsync(NativeMediaKind kind, string prompt, string root, CancellationToken ct = default) =>
        _imageRouter.GenerateMediaAsync(kind, prompt, root, ct);
    public bool HasActiveRoute => _store.State.Accounts.Any(a => a.Active);
    public string CurrentProvider => CurrentAccount is { } account ? RouterCatalog.LabelFor(account.Provider) : "Provider";
    public string CurrentProviderID => CurrentAccount?.Provider ?? "unknown-provider";
    public string? CurrentAccountID => CurrentAccount?.Id;

    /// <summary>
    /// Reorders provider families while preserving the existing order of accounts
    /// within each family. The same priority field drives routing and the settings list.
    /// </summary>
    public void ReorderProviders(IReadOnlyList<string> orderedProviderIDs)
    {
        var accounts = _store.State.Accounts;
        var present = accounts.Select(account => account.Provider)
            .Distinct(StringComparer.Ordinal)
            .ToList();
        var presentSet = present.ToHashSet(StringComparer.Ordinal);
        var ordered = orderedProviderIDs.Where(presentSet.Contains)
            .Distinct(StringComparer.Ordinal)
            .Concat(present.Where(provider => !orderedProviderIDs.Contains(provider, StringComparer.Ordinal)))
            .ToList();
        var previous = accounts.ToDictionary(account => account.Id, account => account.Priority, StringComparer.Ordinal);

        try
        {
            for (var providerIndex = 0; providerIndex < ordered.Count; providerIndex++)
            {
                var providerAccounts = accounts
                    .Where(account => string.Equals(account.Provider, ordered[providerIndex], StringComparison.Ordinal))
                    .OrderBy(account => account.Priority)
                    .ToList();
                for (var accountIndex = 0; accountIndex < providerAccounts.Count; accountIndex++)
                    providerAccounts[accountIndex].Priority = providerIndex * 100 + accountIndex;
            }
            _store.Save();
            Error = null;
            RefreshState(readShareKey: false);
        }
        catch (Exception ex)
        {
            foreach (var account in accounts)
                if (previous.TryGetValue(account.Id, out var priority)) account.Priority = priority;
            Error = ex.Message;
        }
    }

    /// <summary>
    /// The model an explore subagent runs on: the lightest model of the account that serves
    /// the conversation's model, so a read-only search costs a compact model on the same
    /// route. The conversation's model when that account has no lighter one.
    /// </summary>
    public string ExploreModelID(string? conversationModel)
    {
        var model = string.IsNullOrWhiteSpace(conversationModel) ? SelectedModelID : conversationModel;
        var account = _store.State.Accounts.Where(item => item.Active).OrderBy(item => item.Priority)
            .FirstOrDefault(item => CanServe(item, model));
        return account is null || IsCompactModel(model)
            ? model
            : ModelsFor(account).Where(IsCompactModel).OrderBy(item => item, StringComparer.Ordinal).FirstOrDefault() ?? model;
    }

    // The picked model's provider first (in auto, the one with the most quota left):
    // project text reaches another provider only when that one has no model left.
    private string? CheapestConnectedModelID()
    {
        var active = _store.State.Accounts.Where(account => account.Active).ToList();
        var usage = _router.RefreshUsage?.Invoke();
        // Unknown quota counts as full.
        double Room(NativeProviderAccount account) =>
            usage is not null && usage.TryGetValue(account.Id, out var snapshot) && snapshot.UsedFraction is { } used
                ? 1 - Math.Clamp(used, 0, 1)
                : 1;
        var provider = string.IsNullOrWhiteSpace(SelectedModelID) || SelectedModelID == "auto"
            ? active.OrderByDescending(Room).ThenBy(account => account.Priority).FirstOrDefault()?.Provider
            : CurrentAccount?.Provider;
        var sameProvider = active.Where(account => account.Provider == provider).SelectMany(ModelsFor).ToList();
        return (sameProvider.Count > 0 ? sameProvider : active.SelectMany(ModelsFor))
            .Distinct(StringComparer.Ordinal)
            .OrderBy(ModelTierRank)
            .FirstOrDefault();
    }

    public string CurrentModel => CurrentAccount is { } account
        ? (CanServe(account, SelectedModelID) ? SelectedModelID : account.Model)
        : "";

    public int ContextWindowFor(string? model, string? preferredProvider = null)
    {
        var account = _store.State.Accounts
            .Where(a => a.Active)
            .OrderBy(a => a.Priority)
            .FirstOrDefault(a => (preferredProvider is null || string.Equals(a.Provider, preferredProvider, StringComparison.OrdinalIgnoreCase))
                && CanServe(a, model))
            ?? (preferredProvider is null ? CurrentAccount : null);
        var provider = preferredProvider ?? account?.Provider;
        if (!string.IsNullOrWhiteSpace(model) && !string.IsNullOrWhiteSpace(provider)
            && ModelContextWindowOverrideFor(model, provider) is { } configured && configured > 0) return configured;
        if (DetectedContextWindowFor(model, preferredProvider) is { } detected && detected > 0) return detected;
        var protocol = account?.Protocol ?? RouterCatalog.KindFor(provider ?? "")?.Protocol;
        return protocol switch
        {
            // Provider defaults are only a safety fallback; live context_length wins.
            NativeProviderProtocol.Anthropic => 200_000,
            NativeProviderProtocol.ChatGpt or NativeProviderProtocol.OpenAiResponses => 128_000,
            _ => ContextCompaction.DefaultContextWindow,
        };
    }

    public int? ModelContextWindowOverrideFor(string model, string provider) =>
        _store.State.ModelContextWindowOverrides.TryGetValue(
            RouterCatalog.ModelContextOverrideKey(provider, model), out var value) && value > 0
                ? value
                : null;

    /// <summary>Provider-reported or documented value, excluding user overrides and generic fallbacks.</summary>
    public int? DetectedContextWindowFor(string? model, string? preferredProvider = null)
    {
        var account = _store.State.Accounts
            .Where(value => value.Active)
            .OrderBy(value => value.Priority)
            .FirstOrDefault(value => (preferredProvider is null || string.Equals(value.Provider, preferredProvider, StringComparison.OrdinalIgnoreCase))
                && CanServe(value, model))
            ?? (preferredProvider is null ? CurrentAccount : null);
        var provider = preferredProvider ?? account?.Provider;
        if (RouterCatalog.DocumentedContextWindow(provider, model) is { } documented) return documented;
        if (!string.IsNullOrWhiteSpace(model) && !string.IsNullOrWhiteSpace(provider)
            && _contextWindows.TryGetValue(RouterCatalog.ModelContextOverrideKey(provider, model), out var live) && live > 0) return live;
        if (account?.ContextWindow is > 0 and var declared) return declared;
        return null;
    }

    public void SetModelContextWindowOverride(string provider, string model, int? contextWindow)
    {
        if (contextWindow is <= 0) throw new ArgumentOutOfRangeException(nameof(contextWindow), "Context size must be a positive token count.");
        var key = RouterCatalog.ModelContextOverrideKey(provider, model);
        if (contextWindow is { } value) _store.State.ModelContextWindowOverrides[key] = value;
        else _store.State.ModelContextWindowOverrides.Remove(key);
        _store.Save();
        OnPropertyChanged(nameof(ModelContextSettings));
    }

    public ContextBudget ContextBudgetFor(
        string? model,
        IReadOnlyList<NativeToolDefinition> tools,
        IReadOnlyList<NativeMessage>? messages = null)
    {
        var contextWindow = ContextWindowFor(model);
        var reservedOutputTokens = 4_096;
        var responseStyle = ResponseStyleResolver.Resolve(
            ResponseStylePreference,
            messages?.LastOrDefault(message => message.Role == "user")?.Content);
        if (messages is not null)
        {
            var account = _store.State.Accounts
                .Where(value => value.Active)
                .OrderBy(value => value.Priority)
                .FirstOrDefault(value => CanServe(value, model))
                ?? CurrentAccount;
            var protocol = account?.Protocol ?? NativeProviderProtocol.OpenAiCompatible;
            reservedOutputTokens = EconomyPolicy.Resolve(
                protocol,
                model ?? account?.Model ?? "",
                SelectedEffort,
                messages,
                tools,
                responseStyle,
                contextWindow).MaxOutputTokens;
        }
        return ContextCompaction.Budget(
            contextWindow,
            reservedOutputTokens,
            toolDefinitionTokens: ContextCompaction.EstimateTokens(tools),
            economy: UsageMode == AgentUsageMode.Economy,
            triggerPercent: ContextCompactionThresholdPercent);
    }

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
            && (account.Protocol is NativeProviderProtocol.ChatGpt or NativeProviderProtocol.OpenAiResponses)
            && CanServe(account, model));

    public bool SupportsNativeCompactionFor(string? model)
    {
        var account = _store.State.Accounts
            .Where(value => value.Active)
            .OrderBy(value => value.Priority)
            .FirstOrDefault(value => CanServe(value, model));
        return _router.SupportsNativeCompaction(account);
    }

    public string ContextRouteIdentityFor(string? model, string? preferredAccountId = null, string? excludedAccountId = null)
    {
        var allCandidates = _store.State.Accounts
            .Where(value => value.Active && CanServe(value, model))
            .OrderBy(value => value.Priority)
            .ToList();
        var candidates = allCandidates
            .Where(value => !string.Equals(value.Id, excludedAccountId, StringComparison.Ordinal))
            .ToList();
        if (candidates.Count == 0) candidates = allCandidates;
        var account = candidates.FirstOrDefault(value => string.Equals(value.Id, preferredAccountId, StringComparison.Ordinal))
            ?? candidates.FirstOrDefault(value => string.Equals(value.Id, _store.State.SelectedAccountId, StringComparison.Ordinal))
            ?? candidates.FirstOrDefault();
        return account is null
            ? $"unresolved|{model ?? SelectedModelID}"
            : $"{account.Id}|{account.Provider}|{account.Protocol}|{model ?? account.Model}";
    }

    private NativeProviderAccount? CurrentAccount => _store.State.Accounts
        .Where(a => a.Active)
        .OrderBy(a => a.Priority)
        .FirstOrDefault(a => CanServe(a, SelectedModelID))
        ?? _store.State.Accounts.Where(a => a.Active).OrderBy(a => a.Priority).FirstOrDefault();

    private void RefreshState(bool readShareKey = true)
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
        if (readShareKey) ApplyShareKey(_store.Secrets.Read("share.key"));
        Reachable = true; OnPropertyChanged(nameof(Reachable));
        OnPropertyChanged(nameof(ModelContextSettings));
    }

    private void ApplyShareKey(string? key)
    {
        Keys.Clear(); if (key is not null) Keys.Add(new RouterKey("share.key", "Share key", key));
    }

    private sealed record ModelDiscovery(List<string> Models, Dictionary<string, int> ContextWindows);

    private async Task RefreshModelsAsync(bool force)
    {
        if (!force && _lastModelRefreshUtc is { } refreshed
            && DateTimeOffset.UtcNow - refreshed < TimeSpan.FromHours(6)) return;
        _lastModelRefreshUtc = DateTimeOffset.UtcNow;
        // All providers at once, off the UI thread (secret lookups may spawn a process on Linux).
        var accounts = _store.State.Accounts.Where(a => a.Active).ToList();
        var shareKey = Task.Run(() => _store.Secrets.Read("share.key"));
        var results = await Task.WhenAll(accounts.Select(DiscoverSharedAsync));
        _contextWindows.Clear();
        for (var i = 0; i < accounts.Count; i++)
        {
            accounts[i].Models = results[i].Models;
            foreach (var (id, context) in results[i].ContextWindows)
                _contextWindows[RouterCatalog.ModelContextOverrideKey(accounts[i].Provider, id)] = context;
        }
        _store.Save();
        RefreshState(readShareKey: false);
        ApplyShareKey(await shareKey);
    }

    // Multiple startup paths can refresh the same accounts at the same time. The second
    // caller joins the request already in flight instead of sending a duplicate; the entry
    // is dropped when it finishes, so a later refresh always asks the provider again.
    private static readonly System.Collections.Concurrent.ConcurrentDictionary<string, Task<ModelDiscovery>> InFlightDiscovery = new(StringComparer.Ordinal);

    private Task<ModelDiscovery> DiscoverSharedAsync(NativeProviderAccount account)
    {
        var key = $"{account.Id}|{account.BaseUrl}|{account.Protocol}|{account.CredentialId}";
        var task = InFlightDiscovery.GetOrAdd(key, _ => Task.Run(() => DiscoverModelsAsync(account)));
        _ = task.ContinueWith(_ => InFlightDiscovery.TryRemove(key, out _), TaskScheduler.Default);
        return task;
    }

    private static string BuildModelCatalogUrl(NativeProviderAccount account)
    {
        var builder = new UriBuilder(NativeProviderStore.NormalizeUrl(account.BaseUrl).TrimEnd('/'));
        builder.Path = builder.Path.TrimEnd('/') + "/models";
        if (account.Protocol == NativeProviderProtocol.ChatGpt)
        {
            var queryItems = builder.Query.TrimStart('?')
                .Split('&', StringSplitOptions.RemoveEmptyEntries)
                .Where(item => !string.Equals(item.Split('=', 2)[0], "client_version", StringComparison.OrdinalIgnoreCase))
                .Append($"client_version={Uri.EscapeDataString(NativeProviderRouter.ChatGptCodexClientVersion)}");
            builder.Query = string.Join("&", queryItems);
        }
        return builder.Uri.AbsoluteUri;
    }

    private async Task<ModelDiscovery> DiscoverModelsAsync(NativeProviderAccount account)
    {
        var fallback = ModelsFor(account).ToList();
        var contexts = new Dictionary<string, int>(StringComparer.Ordinal);
        if ((account.Provider == "claude" && account.AuthType == "claudeOAuth")
            || (account.Provider == "grok-cli" && account.AuthType == "oauth"))
            return new(fallback, contexts);
        try
        {
            var url = BuildModelCatalogUrl(account);
            HttpRequestMessage CreateRequest()
            {
                var request = new HttpRequestMessage(HttpMethod.Get, url);
                var key = _store.Secrets.Read(account.CredentialId);
                if (!string.IsNullOrWhiteSpace(key))
                {
                    if (account.Protocol == NativeProviderProtocol.Anthropic) request.Headers.TryAddWithoutValidation("x-api-key", key);
                    else request.Headers.Authorization = new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", key);
                }
                if (account.Protocol == NativeProviderProtocol.Anthropic) request.Headers.TryAddWithoutValidation("anthropic-version", "2023-06-01");
                if (account.Protocol == NativeProviderProtocol.ChatGpt)
                {
                    request.Headers.TryAddWithoutValidation("ChatGPT-Account-ID", account.SessionAccountId);
                    request.Headers.TryAddWithoutValidation("OAI-Product-Sku", "codex");
                    request.Headers.TryAddWithoutValidation("OpenAI-Beta", "responses=v1");
                    request.Headers.TryAddWithoutValidation("originator", "dots_harness");
                    request.Headers.TryAddWithoutValidation("Accept", "application/json");
                    request.Headers.TryAddWithoutValidation(
                        "User-Agent",
                        $"codex_cli_rs/{NativeProviderRouter.ChatGptCodexClientVersion}");
                }
                NativeProviderTransportHeaders.Apply(request.Headers, account.Provider);
                return request;
            }
            if (account.Protocol == NativeProviderProtocol.ChatGpt && string.IsNullOrWhiteSpace(account.SessionAccountId))
                return new(fallback, contexts);
            // Shared pool with chat requests (warms the connection); discovery keeps its 8 s cap.
            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(8));
            using var request = CreateRequest();
            using var response = await NativeProviderRouter.SharedHttp.SendAsync(request, timeout.Token).ConfigureAwait(false);
            var responseText = await response.Content.ReadAsStringAsync(timeout.Token).ConfigureAwait(false);
            var successful = response.IsSuccessStatusCode;
            if (account.Protocol == NativeProviderProtocol.ChatGpt && response.StatusCode == HttpStatusCode.Unauthorized
                && await RefreshCredentialAsync(account, timeout.Token).ConfigureAwait(false))
            {
                using var retryRequest = CreateRequest();
                using var retry = await NativeProviderRouter.SharedHttp.SendAsync(retryRequest, timeout.Token).ConfigureAwait(false);
                responseText = await retry.Content.ReadAsStringAsync(timeout.Token).ConfigureAwait(false);
                successful = retry.IsSuccessStatusCode;
            }
            var root = JsonNode.Parse(responseText);
            var live = new List<string>();
            if (successful)
            {
                if (account.Protocol == NativeProviderProtocol.ChatGpt)
                {
                    var catalog = root?["models"]?.AsArray()
                        .Select((item, index) => (item, index))
                        .Where(entry => string.Equals(entry.item?["visibility"]?.GetValue<string>(), "list", StringComparison.OrdinalIgnoreCase))
                        .OrderBy(entry => entry.item?["priority"]?.GetValue<int>() ?? int.MaxValue)
                        .ThenBy(entry => entry.index);
                    foreach (var entry in catalog?.ToList() ?? [])
                    {
                        var id = entry.item?["slug"]?.GetValue<string>();
                        if (!string.IsNullOrWhiteSpace(id) && !live.Contains(id, StringComparer.Ordinal)) live.Add(id);
                        var context = ContextWindowMetadata.Read(entry.item);
                        if (!string.IsNullOrWhiteSpace(id) && context > 0) contexts[id] = context;
                    }
                }
                else foreach (var item in ModelRows(root))
                {
                    var id = ContextWindowMetadata.FirstString(item, "id", "slug", "name", "model", "modelId");
                    if (string.IsNullOrWhiteSpace(id)) continue;
                    if (id.StartsWith("models/", StringComparison.OrdinalIgnoreCase)) id = id["models/".Length..];
                    var context = ContextWindowMetadata.Read(item);
                    if (context > 0) contexts[id] = context;
                    if (!live.Contains(id, StringComparer.Ordinal)) live.Add(id);
                }
            }
            if (successful && account.Provider == "gemini" && account.ContextWindow is null)
            {
                foreach (var (id, context) in await DiscoverGeminiContextsAsync(account, timeout.Token).ConfigureAwait(false))
                    contexts[id] = context;
            }
            // Local servers report the context they actually serve through their
            // own endpoints, not /models.
            if (successful && account.AuthType == "custom" && account.ContextWindow is null)
            {
                var served = await LocalServerProbe.ContextWindowsAsync(account.BaseUrl, live, timeout.Token).ConfigureAwait(false);
                foreach (var id in live)
                {
                    if (served.TryGetValue(id, out var context) || served.TryGetValue(LocalServerProbe.AnyModel, out context))
                        contexts[id] = context;
                }
            }
            return new(live.Count > 0 ? live : fallback, contexts);
        }
        catch { return new(fallback, contexts); }
    }

    private static IEnumerable<JsonNode?> ModelRows(JsonNode? root)
    {
        if (root is JsonArray array) return array;
        if (root is not JsonObject obj) return [];
        foreach (var name in new[] { "data", "models", "modelList", "buckets" })
        {
            var rows = obj.FirstOrDefault(pair => string.Equals(pair.Key, name, StringComparison.OrdinalIgnoreCase)).Value;
            if (rows is JsonArray listed) return listed;
            if (name == "models" && rows is JsonObject mapped)
                return mapped.Select(pair =>
                {
                    if (pair.Value is not JsonObject value) return (JsonNode?)null;
                    var copy = value.DeepClone().AsObject();
                    if (!copy.ContainsKey("id")) copy["id"] = pair.Key;
                    return copy;
                }).Where(value => value is not null);
        }
        return [];
    }

    private async Task<Dictionary<string, int>> DiscoverGeminiContextsAsync(NativeProviderAccount account, CancellationToken ct)
    {
        var result = new Dictionary<string, int>(StringComparer.Ordinal);
        if (!Uri.TryCreate(NativeProviderStore.NormalizeUrl(account.BaseUrl), UriKind.Absolute, out var baseUri)
            || !string.Equals(baseUri.Host, "generativelanguage.googleapis.com", StringComparison.OrdinalIgnoreCase)) return result;
        var token = _store.Secrets.Read(account.CredentialId);
        if (string.IsNullOrWhiteSpace(token)) return result;
        try
        {
            var path = baseUri.AbsolutePath.TrimEnd('/');
            if (path.EndsWith("/openai", StringComparison.OrdinalIgnoreCase)) path = path[..^"/openai".Length];
            if (string.IsNullOrWhiteSpace(path)) path = "/v1beta";
            var builder = new UriBuilder(baseUri)
            {
                Path = path + "/models",
                Query = "pageSize=1000",
            };
            using var request = new HttpRequestMessage(HttpMethod.Get, builder.Uri);
            request.Headers.TryAddWithoutValidation("x-goog-api-key", token);
            using var response = await NativeProviderRouter.SharedHttp.SendAsync(request, ct).ConfigureAwait(false);
            if (!response.IsSuccessStatusCode) return result;
            var payload = JsonNode.Parse(await response.Content.ReadAsStringAsync(ct).ConfigureAwait(false));
            foreach (var item in ModelRows(payload))
            {
                var id = ContextWindowMetadata.FirstString(item, "name", "id", "model");
                if (string.IsNullOrWhiteSpace(id)) continue;
                if (id.StartsWith("models/", StringComparison.OrdinalIgnoreCase)) id = id["models/".Length..];
                var context = ContextWindowMetadata.Read(item);
                if (context > 0) result[id] = context;
            }
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw; }
        catch { }
        return result;
    }

    private static IEnumerable<string> ModelsFor(NativeProviderAccount account)
    {
        if (account.Provider == "grok-cli")
        {
            yield return "grok-build";
            yield return "grok-4.5";
            yield break;
        }
        if ((account.Models ?? []).Count > 0)
        {
            // A stored prefix/ placeholder names no model; older state files still hold one.
            foreach (var model in account.Models.Where(model => !string.IsNullOrWhiteSpace(model) && !NativeProviderAccount.IsPlaceholderModel(model))) yield return model;
            yield break;
        }
        if (!string.IsNullOrWhiteSpace(account.Model) && !NativeProviderAccount.IsPlaceholderModel(account.Model)) yield return account.Model;
        // Before live discovery answers, offer the models the remote catalog publishes for this provider.
        foreach (var published in RemoteModelCatalog.ModelIdsFor(account.Provider)) yield return published;
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
        return ModelTierRank(model) == 0;
    }

    private static int ModelTierRank(string model)
    {
        var id = model.ToLowerInvariant();
        if (id.Contains("haiku") || id.Contains("mini") || id.Contains("nano")
            || id.Contains("flash") || id.Contains("lite") || id.Contains("small")) return 0;
        if (id.Contains("opus") || id.Contains("fable") || id.Contains("mythos")
            || id.Contains("-pro") || id.Contains("ultra") || id.Contains("max")) return 2;
        return 1;
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
            if (response.Usage is { } usage)
            {
                result["usage"] = new JsonObject
                {
                    ["prompt_tokens"] = usage.InputTokens,
                    ["completion_tokens"] = usage.OutputTokens,
                    ["total_tokens"] = usage.InputTokens + usage.OutputTokens,
                    ["prompt_cache_hit_tokens"] = usage.CachedInputTokens,
                    ["prompt_cache_miss_tokens"] = usage.CacheMissTokens,
                    ["cache_write_tokens"] = usage.CacheWriteTokens,
                };
            }
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

    private void StartCallbackListener(int port)
    {
        _callbackListener?.Stop();
        _callbackListener = new HttpListener();
        _callbackListener.Prefixes.Add($"http://localhost:{port}/");
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

    private async Task<OAuthToken> ExchangeClaudeCodeAsync(string rawCode, string state, string redirect, string verifier)
    {
        var code = rawCode.Split('#', 2)[0];
        using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(20) };
        var payload = new JsonObject
        {
            ["grant_type"] = "authorization_code",
            ["code"] = code,
            ["state"] = state,
            ["redirect_uri"] = redirect,
            ["client_id"] = "9d1c250a-e61b-44d9-88ed-5944d1962f5e",
            ["code_verifier"] = verifier,
        };
        using var response = await http.PostAsync("https://api.anthropic.com/v1/oauth/token",
            new StringContent(payload.ToJsonString(), Encoding.UTF8, "application/json"));
        var json = JsonNode.Parse(await response.Content.ReadAsStringAsync())?.AsObject()
            ?? throw new NativeProviderException("The sign-in response was invalid.");
        if (!response.IsSuccessStatusCode)
            throw new NativeProviderException(json["error_description"]?.GetValue<string>() ?? json["error"]?.GetValue<string>() ?? "Sign-in failed.", (int)response.StatusCode);
        var access = json["access_token"]?.GetValue<string>() ?? throw new NativeProviderException("The sign-in response did not contain a token.");
        return new OAuthToken(access, json["refresh_token"]?.GetValue<string>(), json["id_token"]?.GetValue<string>());
    }

    private async Task<bool> RefreshCredentialAsync(NativeProviderAccount account, CancellationToken ct)
    {
        if (account.RefreshCredentialId is null) return false;
        var refresh = _store.Secrets.Read(account.RefreshCredentialId);
        if (string.IsNullOrWhiteSpace(refresh)) return false;
        try
        {
            using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(20) };
            using var response = account.Provider == "claude" && account.AuthType == "claudeOAuth"
                ? await http.PostAsync("https://api.anthropic.com/v1/oauth/token",
                    new StringContent(new JsonObject
                    {
                        ["grant_type"] = "refresh_token",
                        ["refresh_token"] = refresh,
                        ["client_id"] = "9d1c250a-e61b-44d9-88ed-5944d1962f5e",
                    }.ToJsonString(), Encoding.UTF8, "application/json"), ct)
                : account.Provider == "gpt" && account.AuthType == "chatgpt"
                    ? await http.PostAsync("https://auth.openai.com/oauth/token", new FormUrlEncodedContent(new Dictionary<string, string>
                    {
                        ["grant_type"] = "refresh_token",
                        ["refresh_token"] = refresh,
                        ["client_id"] = "app_EMoamEEZ73f0CkXaXp7hrann",
                    }), ct)
                    : account.Provider == "grok-cli" && account.AuthType == "oauth"
                        ? await http.PostAsync("https://auth.x.ai/oauth2/token", new FormUrlEncodedContent(new Dictionary<string, string>
                        {
                            ["grant_type"] = "refresh_token",
                            ["refresh_token"] = refresh,
                            ["client_id"] = "b1a00492-073a-47ea-816f-4c329264a828",
                        }), ct)
                    : null;
            if (response is null) return false;
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

    // --- Subscription limits (ChatGPT wham/usage; mirrors macOS ChatGPTUsageService) ---

    private volatile IReadOnlyDictionary<string, AccountUsageSnapshot> _accountUsage = new Dictionary<string, AccountUsageSnapshot>();
    private CancellationTokenSource? _usagePolling;

    /// Limits by account id. Accounts with no usage endpoint (API keys) are absent.
    /// Replaced wholesale by the poll, so readers can keep the reference they got.
    public IReadOnlyDictionary<string, AccountUsageSnapshot> AccountUsage => _accountUsage;

    /// One app-wide poll: limits are current before any view asks for them and
    /// keep updating while the window is hidden behind the tray icon.
    public void StartUsagePolling()
    {
        if (_usagePolling is not null) return;
        _usagePolling = new CancellationTokenSource();
        var ct = _usagePolling.Token;
        _ = Task.Run(async () =>
        {
            while (!ct.IsCancellationRequested)
            {
                try
                {
                    await RefreshAccountUsageAsync(ct).ConfigureAwait(false);
                    await Task.Delay(TimeSpan.FromSeconds(60), ct).ConfigureAwait(false);
                }
                catch (OperationCanceledException) { return; }
                // The account list can change under the snapshot; the next round reads it again.
                catch { await Task.Delay(TimeSpan.FromSeconds(5)).ConfigureAwait(false); }
            }
        });
    }

    public async Task RefreshAccountUsageAsync(CancellationToken ct = default)
    {
        var accounts = _store.State.Accounts.Where(a => a.Active && (a.AuthType == "chatgpt" || a.AuthType == "claudeOAuth")).ToList();
        var loaded = await Task.WhenAll(accounts.Select(async account =>
            (account.Id, Usage: account.AuthType == "claudeOAuth"
                ? await LoadClaudeUsageAsync(account, ct).ConfigureAwait(false)
                : await LoadChatGptUsageAsync(account, ct).ConfigureAwait(false)))).ConfigureAwait(false);
        _accountUsage = loaded.Where(item => item.Usage is not null).ToDictionary(item => item.Id, item => item.Usage!);
        _router.RefreshUsage = () => _accountUsage;
    }

    public bool OpenClaudeResetPage(string accountId)
    {
        var account = _store.State.Accounts.FirstOrDefault(item => item.Id == accountId && item.Active
            && item.Provider == "claude" && item.AuthType == "claudeOAuth");
        if (account is null) return false;
        try
        {
            const string url = "https://claude.ai/settings/usage";
            if (OperatingSystem.IsLinux()) Process.Start(new ProcessStartInfo("xdg-open", url) { UseShellExecute = false });
            else Process.Start(new ProcessStartInfo(url) { UseShellExecute = true });
            _pendingClaudeUsageRefreshAccountId = account.Id;
            return true;
        }
        catch { return false; }
    }

    public async Task RefreshClaudeUsageAfterActivationAsync()
    {
        if (_pendingClaudeUsageRefreshAccountId is null) return;
        _pendingClaudeUsageRefreshAccountId = null;
        await RefreshAccountUsageAsync().ConfigureAwait(false);
    }

    private async Task<AccountUsageSnapshot?> LoadClaudeUsageAsync(NativeProviderAccount account, CancellationToken ct)
    {
        try
        {
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct);
            timeout.CancelAfter(TimeSpan.FromSeconds(30));
            try { return await FetchClaudeUsageAsync(account, timeout.Token).ConfigureAwait(false); }
            catch (ClaudeUsageUnauthorizedException)
            {
                if (!await RefreshCredentialAsync(account, timeout.Token).ConfigureAwait(false)) return null;
                return await FetchClaudeUsageAsync(account, timeout.Token).ConfigureAwait(false);
            }
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw; }
        catch { return null; }
    }

    private async Task<AccountUsageSnapshot?> FetchClaudeUsageAsync(NativeProviderAccount account, CancellationToken ct)
    {
        var token = _store.Secrets.Read(account.CredentialId);
        if (string.IsNullOrWhiteSpace(token)) return null;
        foreach (var endpoint in new[] { "https://api.anthropic.com/api/oauth/usage", "https://api.anthropic.com/v1/oauth/usage" })
        {
            using var request = ClaudeUsageRequest(HttpMethod.Get, endpoint, token);
            using var response = await NativeProviderRouter.SharedHttp.SendAsync(request, ct).ConfigureAwait(false);
            if (response.StatusCode is HttpStatusCode.Unauthorized or HttpStatusCode.Forbidden) throw new ClaudeUsageUnauthorizedException();
            if (!response.IsSuccessStatusCode) continue;
            var parsed = AccountUsageSnapshot.ParseClaude(await response.Content.ReadAsStringAsync(ct).ConfigureAwait(false));
            if (parsed is not null) return parsed;
        }

        // Mirrors macOS's minimal header probe when the usage endpoint is unavailable.
        var probe = new JsonObject
        {
            ["model"] = "claude-haiku-4-5",
            ["max_tokens"] = 1,
            ["messages"] = new JsonArray(new JsonObject { ["role"] = "user", ["content"] = "." }),
        };
        using var fallback = ClaudeUsageRequest(HttpMethod.Post, "https://api.anthropic.com/v1/messages", token,
            new StringContent(probe.ToJsonString(), Encoding.UTF8, "application/json"));
        using var fallbackResponse = await NativeProviderRouter.SharedHttp.SendAsync(fallback, ct).ConfigureAwait(false);
        if (fallbackResponse.StatusCode is HttpStatusCode.Unauthorized or HttpStatusCode.Forbidden) throw new ClaudeUsageUnauthorizedException();
        return AccountUsageSnapshot.FromClaudeHeaders(fallbackResponse);
    }

    private sealed class ClaudeUsageUnauthorizedException : Exception { }

    private static HttpRequestMessage ClaudeUsageRequest(HttpMethod method, string url, string token, HttpContent? content = null)
    {
        var request = new HttpRequestMessage(method, url) { Content = content };
        request.Headers.Authorization = new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", token);
        request.Headers.TryAddWithoutValidation("anthropic-version", "2023-06-01");
        request.Headers.TryAddWithoutValidation("anthropic-beta", "oauth-2025-04-20,claude-code-20250219,interleaved-thinking-2025-05-14,fine-grained-tool-streaming-2025-05-14");
        request.Headers.TryAddWithoutValidation("anthropic-dangerous-direct-browser-access", "true");
        request.Headers.TryAddWithoutValidation("user-agent", "claude-cli/2.1.92 (external, sdk-cli)");
        request.Headers.TryAddWithoutValidation("x-app", "cli");
        return request;
    }

    private async Task<AccountUsageSnapshot?> LoadChatGptUsageAsync(NativeProviderAccount account, CancellationToken ct)
    {
        try
        {
            // `…/backend-api/codex` serves chat; usage hangs off the same backend.
            var baseUrl = NativeProviderStore.NormalizeUrl(account.BaseUrl).TrimEnd('/');
            if (baseUrl.EndsWith("/codex", StringComparison.OrdinalIgnoreCase)) baseUrl = baseUrl[..^"/codex".Length];
            HttpRequestMessage? CreateRequest()
            {
                var token = _store.Secrets.Read(account.CredentialId);
                if (string.IsNullOrWhiteSpace(token)) return null;
                var request = new HttpRequestMessage(HttpMethod.Get, baseUrl + "/wham/usage");
                request.Headers.Authorization = new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", token);
                if (!string.IsNullOrWhiteSpace(account.SessionAccountId))
                    request.Headers.TryAddWithoutValidation("ChatGPT-Account-Id", account.SessionAccountId);
                request.Headers.TryAddWithoutValidation("originator", "codex_cli_rs");
                request.Headers.TryAddWithoutValidation("User-Agent", $"codex_cli_rs/{NativeProviderRouter.ChatGptCodexClientVersion}");
                request.Headers.TryAddWithoutValidation("Accept", "application/json");
                return request;
            }
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct);
            timeout.CancelAfter(TimeSpan.FromSeconds(30));
            using var request = CreateRequest();
            if (request is null) return null;
            var response = await NativeProviderRouter.SharedHttp.SendAsync(request, timeout.Token).ConfigureAwait(false);
            if (response.StatusCode is HttpStatusCode.Unauthorized or HttpStatusCode.Forbidden
                && await RefreshCredentialAsync(account, timeout.Token).ConfigureAwait(false))
            {
                response.Dispose();
                using var retry = CreateRequest();
                if (retry is null) return null;
                response = await NativeProviderRouter.SharedHttp.SendAsync(retry, timeout.Token).ConfigureAwait(false);
            }
            using (response)
            {
                if (!response.IsSuccessStatusCode) return null;
                return AccountUsageSnapshot.ParseChatGpt(await response.Content.ReadAsStringAsync(timeout.Token).ConfigureAwait(false));
            }
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw; }
        catch { return null; }
    }

    public void Dispose() { CancelFlow(); _usagePolling?.Cancel(); _tunnelProcess.Dispose(); _gateway.Dispose(); }
}

/// One rate-limit window: the short one (5h) or the weekly one.
public sealed record UsageWindow(bool Weekly, double? UsedFraction, DateTimeOffset? ResetsAt);

/// A subscription account's limits, worst window first in <see cref="UsedFraction"/>.
public sealed record AccountUsageSnapshot(double? UsedFraction, DateTimeOffset? ResetsAt, IReadOnlyList<UsageWindow> Windows, int? ResetsAvailable = null)
{
    /// The active short window for display; aggregate UsedFraction remains the
    /// most constrained window for account routing.
    public double? CurrentWindowUsedFraction => Windows.FirstOrDefault(window => !window.Weekly)?.UsedFraction ?? UsedFraction;

    /// Null when the body carries no rate-limit window.
    public static AccountUsageSnapshot? ParseChatGpt(string json)
    {
        using var document = JsonDocument.Parse(json);
        if (document.RootElement.ValueKind != JsonValueKind.Object
            || !document.RootElement.TryGetProperty("rate_limit", out var rateLimit)
            || rateLimit.ValueKind != JsonValueKind.Object) return null;
        var windows = new[] { "primary_window", "secondary_window" }
            .Select(name => rateLimit.TryGetProperty(name, out var block) ? Window(block) : null)
            .OfType<UsageWindow>()
            .ToList();
        if (windows.Count == 0) return null;
        return Snapshot(windows);
    }

    public static AccountUsageSnapshot? ParseClaude(string json)
    {
        using var document = JsonDocument.Parse(json);
        if (document.RootElement.ValueKind != JsonValueKind.Object) return null;
        var windows = new[]
        {
            ClaudeWindow(document.RootElement, ["five_hour", "fiveHour", "5h"], weekly: false),
            ClaudeWindow(document.RootElement, ["seven_day", "sevenDay", "week", "7d"], weekly: true),
        }.OfType<UsageWindow>().ToList();
        var resetsAvailableValue = Property(document.RootElement, "resets_available", "resetsAvailable");
        int? resetsAvailable = Number(resetsAvailableValue) is { } count ? Math.Max(0, (int)count) : null;
        return Snapshot(windows, resetsAvailable);
    }

    public static AccountUsageSnapshot? FromClaudeHeaders(HttpResponseMessage response)
    {
        var values = new[]
        {
            (Remaining: "anthropic-ratelimit-requests-remaining", Limit: "anthropic-ratelimit-requests-limit"),
            (Remaining: "anthropic-ratelimit-tokens-remaining", Limit: "anthropic-ratelimit-tokens-limit"),
        };
        var used = new List<double>();
        foreach (var pair in values)
        {
            if (!response.Headers.TryGetValues(pair.Remaining, out var remainingRaw)
                || !response.Headers.TryGetValues(pair.Limit, out var limitRaw)
                || !double.TryParse(remainingRaw.FirstOrDefault(), System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var remaining)
                || !double.TryParse(limitRaw.FirstOrDefault(), System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var limit)
                || limit <= 0) continue;
            used.Add(Math.Clamp(1 - remaining / limit, 0, 1));
        }
        var reset = HeaderReset(response);
        if (used.Count == 0)
            return reset is { } resetOnly
                ? new AccountUsageSnapshot(null, resetOnly, [new UsageWindow(false, null, resetOnly)])
                : null;
        return new AccountUsageSnapshot(used.Max(), reset, [new UsageWindow(false, used.Max(), reset)]);
    }

    private static DateTimeOffset? HeaderReset(HttpResponseMessage response)
    {
        var now = DateTimeOffset.UtcNow;
        if (response.Headers.RetryAfter?.Delta is { } delta && delta > TimeSpan.Zero) return now.Add(delta);
        if (response.Headers.RetryAfter?.Date is { } date && date > now) return date;
        foreach (var name in new[] { "retry-after", "anthropic-ratelimit-unified-reset", "x-ratelimit-reset-requests", "x-ratelimit-reset-tokens", "x-ratelimit-reset" })
        {
            var raw = response.Headers.TryGetValues(name, out var headers) ? headers.FirstOrDefault()
                : response.Content.Headers.TryGetValues(name, out var contentHeaders) ? contentHeaders.FirstOrDefault() : null;
            if (string.IsNullOrWhiteSpace(raw)) continue;
            if (double.TryParse(raw, System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var seconds))
            {
                try
                {
                    var parsed = seconds > 10_000_000 ? DateTimeOffset.FromUnixTimeSeconds((long)seconds) : now.AddSeconds(seconds);
                    if (parsed > now) return parsed;
                }
                catch (ArgumentOutOfRangeException) { }
                continue;
            }
            if (DateTimeOffset.TryParse(raw, System.Globalization.CultureInfo.InvariantCulture, System.Globalization.DateTimeStyles.AssumeUniversal, out var parsedDate)
                && parsedDate > now) return parsedDate;
        }
        return null;
    }

    private static UsageWindow? ClaudeWindow(JsonElement root, string[] names, bool weekly)
    {
        JsonElement block = default;
        if (!names.Any(name => root.TryGetProperty(name, out block) && block.ValueKind == JsonValueKind.Object)) return null;
        var utilizationValue = Property(block, "utilization");
        var usedValue = utilizationValue ?? Property(block, "used_percent", "percent");
        var used = Number(usedValue);
        if (used is { } percent)
        {
            // The OAuth usage endpoint's `utilization` is percentage points:
            // `1` means 1% used, not a full 1.0 fraction (100%).
            var fraction = utilizationValue is not null || percent > 1 ? percent / 100 : percent;
            used = Math.Clamp(fraction, 0, 1);
        }
        var resetValue = Property(block, "resets_at", "reset_at", "resetsAt");
        var reset = ResetDate(resetValue);
        return used is null && reset is null ? null : new UsageWindow(weekly, used, reset);
    }

    private static JsonElement? Property(JsonElement obj, params string[] keys)
    {
        foreach (var key in keys) if (obj.TryGetProperty(key, out var value)) return value;
        return null;
    }

    private static DateTimeOffset? ResetDate(JsonElement? value)
    {
        if (value is not { } raw) return null;
        if (raw.ValueKind == JsonValueKind.Number && raw.TryGetDouble(out var unix))
            try { return DateTimeOffset.FromUnixTimeMilliseconds(unix > 10_000_000_000 ? (long)unix : (long)(unix * 1000)); } catch { return null; }
        if (raw.ValueKind == JsonValueKind.String)
        {
            var text = raw.GetString();
            if (DateTimeOffset.TryParse(text, System.Globalization.CultureInfo.InvariantCulture, System.Globalization.DateTimeStyles.AssumeUniversal, out var parsed)) return parsed;
            if (double.TryParse(text, System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var number))
                try { return DateTimeOffset.FromUnixTimeMilliseconds(number > 10_000_000_000 ? (long)number : (long)(number * 1000)); } catch { return null; }
        }
        return null;
    }

    private static double? Number(JsonElement? value) => value is { } raw ? Number(raw) : null;

    private static AccountUsageSnapshot? Snapshot(IReadOnlyList<UsageWindow> windows, int? resetsAvailable = null)
    {
        if (windows.Count == 0) return null;
        var reset = windows.Where(window => window.ResetsAt is not null).MinBy(window => window.ResetsAt)?.ResetsAt;
        var fractions = windows.Where(window => window.UsedFraction is not null).Select(window => window.UsedFraction!.Value).ToArray();
        return new AccountUsageSnapshot(fractions.Length == 0 ? null : fractions.Max(), reset, windows, resetsAvailable);
    }

    private static UsageWindow? Window(JsonElement block)
    {
        if (block.ValueKind != JsonValueKind.Object
            || !block.TryGetProperty("used_percent", out var raw) || Number(raw) is not { } used) return null;
        var seconds = block.TryGetProperty("limit_window_seconds", out var length) ? Number(length) : null;
        var reset = block.TryGetProperty("reset_at", out var at) ? Number(at) : null;
        return new UsageWindow(
            seconds is > 6 * 3600,
            Math.Clamp(used / 100, 0, 1),
            reset is { } unix ? DateTimeOffset.FromUnixTimeSeconds((long)unix) : null);
    }

    private static double? Number(JsonElement value) => value.ValueKind switch
    {
        JsonValueKind.Number => value.GetDouble(),
        JsonValueKind.String when double.TryParse(
            value.GetString(), System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var parsed) => parsed,
        _ => null,
    };
}

internal static class ContextWindowMetadata
{
    private static readonly string[] ContextKeys =
    [
        "context_length", "context_window", "max_context_length", "context_size",
        "contextLength", "contextWindow", "maxContextLength", "contextSize",
        "input_token_limit", "inputTokenLimit", "max_input_tokens", "maxInputTokens",
        "input_token_count", "max_input_token_count", "maxInputTokenCount",
    ];

    private static readonly string[] NestedKeys =
        ["limits", "limit", "metadata", "model_info", "modelInfo", "top_provider", "details", "config", "info"];

    /// <summary>Reads model input/context limits, never output-token limits.</summary>
    public static int Read(JsonNode? node, int depth = 0)
    {
        if (node is not JsonObject obj) return 0;
        foreach (var key in ContextKeys)
        {
            var value = obj.FirstOrDefault(pair => string.Equals(pair.Key, key, StringComparison.OrdinalIgnoreCase)).Value;
            var parsed = PositiveInteger(value);
            if (parsed > 0) return parsed;
        }
        foreach (var (key, value) in obj)
        {
            if (key.EndsWith(".context_length", StringComparison.OrdinalIgnoreCase))
            {
                var parsed = PositiveInteger(value);
                if (parsed > 0) return parsed;
            }
        }
        if (depth >= 4) return 0;
        foreach (var key in NestedKeys)
        {
            var nested = obj.FirstOrDefault(pair => string.Equals(pair.Key, key, StringComparison.OrdinalIgnoreCase)).Value;
            var parsed = Read(nested, depth + 1);
            if (parsed > 0) return parsed;
        }
        return 0;
    }

    public static string? FirstString(JsonNode? node, params string[] names)
    {
        if (node is not JsonObject obj) return null;
        foreach (var name in names)
        {
            var value = obj.FirstOrDefault(pair => string.Equals(pair.Key, name, StringComparison.OrdinalIgnoreCase)).Value;
            if (value is System.Text.Json.Nodes.JsonValue json && json.TryGetValue<string>(out var text)
                && !string.IsNullOrWhiteSpace(text)) return text.Trim();
        }
        return null;
    }

    private static int PositiveInteger(JsonNode? node)
    {
        if (node is not System.Text.Json.Nodes.JsonValue value) return 0;
        if (value.TryGetValue<int>(out var integer)) return integer > 0 ? integer : 0;
        if (value.TryGetValue<long>(out var longInteger)) return longInteger is > 0 and <= int.MaxValue ? (int)longInteger : 0;
        if (value.TryGetValue<string>(out var text)
            && int.TryParse(text, System.Globalization.NumberStyles.Integer, System.Globalization.CultureInfo.InvariantCulture, out integer))
            return integer > 0 ? integer : 0;
        return 0;
    }
}

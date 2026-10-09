// Copyright (c) 2026 DOTS
// Cross-platform Marketplace account, publishing, and ownership operations.

using System.IO.Compression;
using System.IO.Pipes;
using System.Diagnostics;
using System.Reflection;
using System.Net;
using System.Runtime.Versioning;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using Microsoft.Win32;
using PluginRuntime;

namespace DotsHarnessCore;

public sealed record MarketplaceUserProfile(
    [property: JsonPropertyName("id")] string Id,
    [property: JsonPropertyName("email")] string Email,
    [property: JsonPropertyName("name")] string Name,
    [property: JsonPropertyName("surname")] string Surname,
    [property: JsonPropertyName("username")] string? Username = null,
    [property: JsonPropertyName("workspace_id")] string? WorkspaceId = null,
    [property: JsonPropertyName("workspace_name")] string? WorkspaceName = null,
    [property: JsonPropertyName("workspace_role")] string? WorkspaceRole = null);

public sealed record MarketplaceOwnedArtifact(
    [property: JsonPropertyName("platform")] string Platform,
    [property: JsonPropertyName("architecture")] string Architecture,
    [property: JsonPropertyName("build_status")] string Status,
    [property: JsonPropertyName("build_error")] string? Error = null);

public sealed record MarketplaceOwnedRelease(
    [property: JsonPropertyName("id")] string Id,
    [property: JsonPropertyName("version")] string Version,
    [property: JsonPropertyName("license")] string License,
    [property: JsonPropertyName("status")] string Status,
    [property: JsonPropertyName("moderation_status")] string ModerationStatus,
    [property: JsonPropertyName("catalog_scope")] string CatalogScope,
    [property: JsonPropertyName("category")] string Category,
    [property: JsonPropertyName("risk_level")] string RiskLevel,
    [property: JsonPropertyName("artifacts")] IReadOnlyList<MarketplaceOwnedArtifact>? Artifacts = null);

public sealed record MarketplaceOwnedPlugin(
    [property: JsonPropertyName("id")] string Id,
    [property: JsonPropertyName("name")] string Name,
    [property: JsonPropertyName("license")] string License,
    [property: JsonPropertyName("source_visibility")] string SourceVisibility,
    [property: JsonPropertyName("verification_status")] string VerificationStatus,
    [property: JsonPropertyName("releases")] IReadOnlyList<MarketplaceOwnedRelease>? Releases = null);

public sealed record MarketplaceHttpResult(byte[] Data, HttpStatusCode StatusCode)
{
    public string Text => Encoding.UTF8.GetString(Data);
    public bool IsSuccess => (int)StatusCode is >= 200 and < 300;
}

public enum MarketplaceProvider
{
    Google,
    GitHub,
}

/// <summary>HerNess Marketplace account session. Tokens remain in the OS credential store.</summary>
public sealed class MarketplaceSession : ObservableObject
{
    public const string DefaultApiBase = "https://dotsherness-unified-backend.dotsherness-unified-backend.workers.dev/";
    private const string AccessCredentialId = "marketplace.access-token";
    private const string RefreshCredentialId = "marketplace.refresh-token";
    private const string OAuthVerifierCredentialId = "marketplace.oauth-verifier";
    private const string OAuthStateCredentialId = "marketplace.oauth-state";
    private static readonly HttpClient Http = new() { Timeout = TimeSpan.FromSeconds(60) };
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web)
    {
        PropertyNameCaseInsensitive = true,
    };

    private readonly IProviderSecretStore _secrets;
    private readonly Uri _apiBase;
    private readonly SemaphoreSlim _refreshGate = new(1, 1);
    private string? _accessToken;
    private string? _refreshToken;
    private string? _pendingVerifier;
    private string? _pendingState;
    private MarketplaceUserProfile? _profile;
    private bool _isLoading;
    private bool _restoreAttempted;
    private string? _lastError;

    public MarketplaceSession(IProviderSecretStore secrets, string apiBase = DefaultApiBase)
    {
        _secrets = secrets;
        if (!Uri.TryCreate(apiBase, UriKind.Absolute, out var parsedApiBase) || parsedApiBase.Scheme != Uri.UriSchemeHttps)
            throw new ArgumentException("Marketplace API must use HTTPS.", nameof(apiBase));
        _apiBase = parsedApiBase.AbsoluteUri.EndsWith("/", StringComparison.Ordinal)
            ? parsedApiBase
            : new Uri(parsedApiBase.AbsoluteUri + "/", UriKind.Absolute);
        _accessToken = secrets.Read(AccessCredentialId);
        _refreshToken = secrets.Read(RefreshCredentialId);
        _pendingVerifier = secrets.Read(OAuthVerifierCredentialId);
        _pendingState = secrets.Read(OAuthStateCredentialId);
    }

    public MarketplaceUserProfile? Profile { get => _profile; private set => SetProperty(ref _profile, value); }
    public bool IsSignedIn => !string.IsNullOrWhiteSpace(_accessToken);
    public bool IsLoading { get => _isLoading; private set => SetProperty(ref _isLoading, value); }
    public string? LastError { get => _lastError; private set => SetProperty(ref _lastError, value); }

    public void BeginOAuth(MarketplaceProvider provider)
    {
        LastError = null;
        var verifier = OAuthToken() + OAuthToken();
        var state = OAuthToken();
        try
        {
            _secrets.Write(OAuthVerifierCredentialId, verifier);
            _secrets.Write(OAuthStateCredentialId, state);
            _pendingVerifier = verifier;
            _pendingState = state;
            var challenge = Base64Url(SHA256.HashData(Encoding.UTF8.GetBytes(verifier)));
            var name = provider == MarketplaceProvider.Google ? "google" : "github";
            var relative = $"api/auth/{name}?client=desktop&code_challenge={Uri.EscapeDataString(challenge)}"
                + $"&client_state={Uri.EscapeDataString(state)}&terms_version=2026-08-26"
                + "&privacy_notice_version=2026-08-26&locale=tr";
            var authorize = new Uri(_apiBase, relative);
            MarketplaceOAuthProtocol.EnsureRegistered();
            var browser = Process.Start(new ProcessStartInfo(authorize.AbsoluteUri) { UseShellExecute = true });
            if (browser is null) throw new InvalidOperationException("The system browser could not be opened.");
            browser.Dispose();
        }
        catch (Exception error)
        {
            _pendingVerifier = null;
            _pendingState = null;
            _secrets.Delete(OAuthVerifierCredentialId);
            _secrets.Delete(OAuthStateCredentialId);
            LastError = error.Message;
            throw;
        }
    }

    public async Task HandleOAuthCallbackAsync(Uri callback, CancellationToken cancellationToken = default)
    {
        if (!callback.IsAbsoluteUri || callback.Scheme != "herness" || callback.Host != "oauth" || callback.AbsolutePath != "/desktop")
        {
            LastError = "The HerNess sign-in callback was invalid.";
            return;
        }
        var query = ParseQuery(callback.Query);
        if (!query.TryGetValue("code", out var code) || string.IsNullOrWhiteSpace(code)
            || !query.TryGetValue("state", out var state) || string.IsNullOrWhiteSpace(state)
            || string.IsNullOrWhiteSpace(_pendingVerifier))
        {
            LastError = "The HerNess sign-in callback was invalid or expired.";
            return;
        }
        if (!string.Equals(state, _pendingState, StringComparison.Ordinal))
        {
            LastError = "The HerNess sign-in state did not match.";
            return;
        }

        var verifier = _pendingVerifier;
        _pendingVerifier = null;
        _pendingState = null;
        _secrets.Delete(OAuthVerifierCredentialId);
        _secrets.Delete(OAuthStateCredentialId);
        IsLoading = true;
        LastError = null;
        try
        {
            var body = JsonSerializer.SerializeToUtf8Bytes(new { code, code_verifier = verifier, client = "desktop" }, JsonOptions);
            var response = await SendAsync("api/auth/desktop/exchange", HttpMethod.Post, body, "application/json", cancellationToken);
            EnsureSuccess(response, "HerNess sign-in");
            AcceptTokens(response.Data);
            await FetchProfileAsync(cancellationToken);
        }
        catch (Exception error)
        {
            LastError = error.Message;
        }
        finally { IsLoading = false; }
    }

    public async Task RestoreAsync(CancellationToken cancellationToken = default)
    {
        if (_restoreAttempted) return;
        _restoreAttempted = true;
        if (!IsSignedIn) return;
        try { await FetchProfileAsync(cancellationToken); }
        catch (MarketplaceSessionException error) when (error.StatusCode is HttpStatusCode.Unauthorized or HttpStatusCode.Forbidden)
        {
            ClearTokens();
            Profile = null;
        }
        catch (Exception error) { LastError = error.Message; }
        OnPropertyChanged(nameof(IsSignedIn));
    }

    public async Task SignInAsync(string email, string password, CancellationToken cancellationToken = default)
    {
        var normalizedEmail = email.Trim().ToLowerInvariant();
        if (normalizedEmail.Length == 0 || password.Length == 0)
            throw new InvalidOperationException("Email and password are required.");
        IsLoading = true;
        LastError = null;
        try
        {
            var payload = JsonSerializer.SerializeToUtf8Bytes(new { email = normalizedEmail, password }, JsonOptions);
            var result = await SendAsync("api/auth/login", HttpMethod.Post, payload, "application/json", cancellationToken);
            EnsureSuccess(result, "Marketplace sign-in");
            AcceptTokens(result.Data);
            await FetchProfileAsync(cancellationToken);
        }
        catch (Exception error)
        {
            LastError = error.Message;
            throw;
        }
        finally { IsLoading = false; }
    }

    public async Task SignOutAsync(CancellationToken cancellationToken = default)
    {
        var refresh = _refreshToken;
        if (!string.IsNullOrWhiteSpace(refresh))
        {
            var body = JsonSerializer.SerializeToUtf8Bytes(new { refresh_token = refresh }, JsonOptions);
            try { _ = await SendAsync("api/auth/logout", HttpMethod.Post, body, "application/json", cancellationToken); }
            catch { }
        }
        ClearTokens();
        Profile = null;
        LastError = null;
        OnPropertyChanged(nameof(IsSignedIn));
    }

    public async Task FetchProfileAsync(CancellationToken cancellationToken = default)
    {
        var result = await AuthorizedDataAsync("api/user/profile", cancellationToken: cancellationToken);
        EnsureSuccess(result, "Marketplace profile");
        Profile = JsonSerializer.Deserialize<MarketplaceUserProfile>(result.Data, JsonOptions)
            ?? throw new InvalidDataException("Marketplace returned an invalid user profile.");
    }

    public async Task<MarketplaceHttpResult> AuthorizedDataAsync(
        string path,
        HttpMethod? method = null,
        byte[]? body = null,
        string? contentType = null,
        CancellationToken cancellationToken = default)
    {
        if (!IsSignedIn) throw new InvalidOperationException("Sign in to your HerNess account first.");
        var tokenUsed = _accessToken!;
        var result = await SendAuthorizedAsync(path, method ?? HttpMethod.Get, body, contentType, tokenUsed, cancellationToken);
        if (result.StatusCode != HttpStatusCode.Unauthorized || string.IsNullOrWhiteSpace(_refreshToken)) return result;

        await _refreshGate.WaitAsync(cancellationToken);
        try
        {
            if (string.Equals(_accessToken, tokenUsed, StringComparison.Ordinal))
                await RefreshAsync(_refreshToken!, cancellationToken);
        }
        catch
        {
            ClearTokens();
            Profile = null;
            OnPropertyChanged(nameof(IsSignedIn));
            throw;
        }
        finally { _refreshGate.Release(); }

        if (!IsSignedIn) throw new InvalidOperationException("Marketplace sign-in expired. Sign in again.");
        return await SendAuthorizedAsync(path, method ?? HttpMethod.Get, body, contentType, _accessToken!, cancellationToken);
    }

    private async Task<MarketplaceHttpResult> SendAuthorizedAsync(
        string path, HttpMethod method, byte[]? body, string? contentType, string token, CancellationToken cancellationToken)
    {
        var request = CreateRequest(path, method, body, contentType);
        request.Headers.Authorization = new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", token);
        return await SendAsync(request, cancellationToken);
    }

    private async Task RefreshAsync(string refreshToken, CancellationToken cancellationToken)
    {
        var body = JsonSerializer.SerializeToUtf8Bytes(new { refresh_token = refreshToken }, JsonOptions);
        var result = await SendAsync("api/auth/refresh", HttpMethod.Post, body, "application/json", cancellationToken);
        EnsureSuccess(result, "Marketplace token refresh");
        AcceptTokens(result.Data);
    }

    private void AcceptTokens(byte[] data)
    {
        using var document = JsonDocument.Parse(data);
        if (!document.RootElement.TryGetProperty("access_token", out var access)
            || access.ValueKind != JsonValueKind.String
            || string.IsNullOrWhiteSpace(access.GetString()))
            throw new InvalidDataException("Marketplace did not return an access token.");
        var accessToken = access.GetString()!;
        var refreshToken = document.RootElement.TryGetProperty("refresh_token", out var refresh)
            && refresh.ValueKind == JsonValueKind.String ? refresh.GetString() : _refreshToken;
        _secrets.Write(AccessCredentialId, accessToken);
        if (!string.IsNullOrWhiteSpace(refreshToken)) _secrets.Write(RefreshCredentialId, refreshToken);
        _accessToken = accessToken;
        _refreshToken = refreshToken;
        OnPropertyChanged(nameof(IsSignedIn));
    }

    private void ClearTokens()
    {
        _accessToken = null;
        _refreshToken = null;
        _secrets.Delete(AccessCredentialId);
        _secrets.Delete(RefreshCredentialId);
        _secrets.Delete(OAuthVerifierCredentialId);
        _secrets.Delete(OAuthStateCredentialId);
        OnPropertyChanged(nameof(IsSignedIn));
    }

    private Task<MarketplaceHttpResult> SendAsync(
        string path, HttpMethod method, byte[]? body, string? contentType, CancellationToken cancellationToken) =>
        SendAsync(CreateRequest(path, method, body, contentType), cancellationToken);

    private static async Task<MarketplaceHttpResult> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        using (request)
        using (var response = await Http.SendAsync(request, HttpCompletionOption.ResponseContentRead, cancellationToken))
            return new MarketplaceHttpResult(await response.Content.ReadAsByteArrayAsync(cancellationToken), response.StatusCode);
    }

    private HttpRequestMessage CreateRequest(string path, HttpMethod method, byte[]? body, string? contentType)
    {
        if (string.IsNullOrWhiteSpace(path) || Uri.TryCreate(path, UriKind.Absolute, out _))
            throw new ArgumentException("Marketplace API path must be relative.", nameof(path));
        var uri = new Uri(_apiBase, path.TrimStart('/'));
        if (uri.Scheme != Uri.UriSchemeHttps || uri.Host != _apiBase.Host)
            throw new InvalidOperationException("Marketplace API path escaped its HTTPS origin.");
        var request = new HttpRequestMessage(method, uri);
        request.Headers.UserAgent.ParseAdd("DotsHarness");
        if (body is not null)
        {
            request.Content = new ByteArrayContent(body);
            if (!string.IsNullOrWhiteSpace(contentType)) request.Content.Headers.ContentType = new System.Net.Http.Headers.MediaTypeHeaderValue(contentType);
        }
        return request;
    }

    private static void EnsureSuccess(MarketplaceHttpResult result, string operation)
    {
        if (!result.IsSuccess) throw new MarketplaceSessionException(result.StatusCode, $"{operation} failed (HTTP {(int)result.StatusCode}): {result.Text}");
    }

    private static string OAuthToken() => Base64Url(RandomNumberGenerator.GetBytes(32));

    private static string Base64Url(byte[] bytes) => Convert.ToBase64String(bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_');

    private static Dictionary<string, string> ParseQuery(string query)
    {
        var result = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var pair in query.TrimStart('?').Split('&', StringSplitOptions.RemoveEmptyEntries))
        {
            var separator = pair.IndexOf('=');
            var key = separator < 0 ? pair : pair[..separator];
            var value = separator < 0 ? string.Empty : pair[(separator + 1)..];
            result[Uri.UnescapeDataString(key.Replace('+', ' '))] = Uri.UnescapeDataString(value.Replace('+', ' '));
        }
        return result;
    }
}

public static class MarketplaceOAuthProtocol
{
    private const string Scheme = "herness";
    private const string DesktopFileName = "dots-harness-oauth.desktop";
    private const string CallbackPipeName = "DotsHarnessMarketplaceOAuth";

    public static async Task<bool> TryForwardCallbackAsync(Uri callback, CancellationToken cancellationToken = default)
    {
        if (!callback.IsAbsoluteUri || callback.Scheme != Scheme || callback.Host != "oauth" || callback.AbsolutePath != "/desktop")
            return false;
        try
        {
            await using var pipe = new NamedPipeClientStream(".", CallbackPipeName, PipeDirection.Out, PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
            await pipe.ConnectAsync(650, cancellationToken).ConfigureAwait(false);
            await using var writer = new StreamWriter(pipe, new UTF8Encoding(false), 1024, leaveOpen: true);
            await writer.WriteLineAsync(callback.AbsoluteUri.AsMemory(), cancellationToken).ConfigureAwait(false);
            await writer.FlushAsync(cancellationToken).ConfigureAwait(false);
            return true;
        }
        catch (Exception error) when (error is IOException or TimeoutException or System.ComponentModel.Win32Exception)
        {
            return false;
        }
    }

    public static async Task ListenForCallbacksAsync(Func<Uri, Task> handle, CancellationToken cancellationToken)
    {
        NamedPipeServerStream pipe;
        try
        {
            pipe = new NamedPipeServerStream(CallbackPipeName, PipeDirection.In, 1, PipeTransmissionMode.Byte,
                PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
        }
        catch (IOException) { return; }
        await using (pipe.ConfigureAwait(false))
        {
            while (!cancellationToken.IsCancellationRequested)
            {
                try
                {
                    await pipe.WaitForConnectionAsync(cancellationToken).ConfigureAwait(false);
                    using (var reader = new StreamReader(pipe, Encoding.UTF8, detectEncodingFromByteOrderMarks: false, bufferSize: 1024, leaveOpen: true))
                    {
                        var value = await reader.ReadLineAsync(cancellationToken).ConfigureAwait(false);
                        if (Uri.TryCreate(value, UriKind.Absolute, out var callback)
                            && callback.Scheme == Scheme && callback.Host == "oauth" && callback.AbsolutePath == "/desktop")
                            await handle(callback).ConfigureAwait(false);
                    }
                }
                catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { return; }
                catch (IOException) { return; }
                catch { }
                finally
                {
                    try { if (pipe.IsConnected) pipe.Disconnect(); } catch { }
                }
            }
        }
    }

    public static void EnsureRegistered()
    {
        if (OperatingSystem.IsWindows()) EnsureWindowsRegistration();
        else if (OperatingSystem.IsLinux()) EnsureLinuxRegistration();
        else throw new PlatformNotSupportedException("HerNess OAuth callback is supported on Windows and Linux desktop builds.");
    }

    [SupportedOSPlatform("windows")]
    private static void EnsureWindowsRegistration()
    {
        var executable = LaunchParts();
        var launchCommand = string.Join(" ", executable.Select(QuoteWindows)) + " \"%1\"";
        using var existing = Registry.CurrentUser.OpenSubKey($"Software\\Classes\\{Scheme}\\shell\\open\\command");
        var registeredCommand = existing?.GetValue(null) as string;
        if (!string.IsNullOrWhiteSpace(registeredCommand)
            && !registeredCommand.Contains(executable[0], StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException("The herness URL scheme is already registered to another application.");
        using var protocol = Registry.CurrentUser.CreateSubKey($"Software\\Classes\\{Scheme}", writable: true)
            ?? throw new InvalidOperationException("Windows could not register the HerNess sign-in callback.");
        protocol.SetValue(null, "URL:HerNess desktop sign-in");
        protocol.SetValue("URL Protocol", string.Empty);
        using var command = Registry.CurrentUser.CreateSubKey($"Software\\Classes\\{Scheme}\\shell\\open\\command", writable: true)
            ?? throw new InvalidOperationException("Windows could not register the HerNess sign-in callback.");
        command.SetValue(null, launchCommand);
    }

    private static void EnsureLinuxRegistration()
    {
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        if (string.IsNullOrWhiteSpace(home)) throw new InvalidOperationException("The current user home directory is unavailable.");
        var applications = Path.Combine(home, ".local", "share", "applications");
        Directory.CreateDirectory(applications);
        var desktopPath = Path.Combine(applications, DesktopFileName);
        var currentDefault = RunXdgMime("query", "default", $"x-scheme-handler/{Scheme}", allowMissing: true).Trim();
        if (currentDefault.Length > 0 && !currentDefault.Equals(DesktopFileName, StringComparison.Ordinal))
            throw new InvalidOperationException($"The herness URL scheme is already handled by {currentDefault}.");
        var exec = string.Join(" ", LaunchParts().Select(QuoteDesktop)) + " %u";
        var desktop = "[Desktop Entry]\nType=Application\nName=Dots Harness OAuth\nNoDisplay=true\nTerminal=false\n"
            + $"Exec={exec}\nMimeType=x-scheme-handler/{Scheme};\n";
        File.WriteAllText(desktopPath, desktop, new UTF8Encoding(false));
        var update = RunXdgMime("default", DesktopFileName, $"x-scheme-handler/{Scheme}", allowMissing: false);
        _ = update;
        try
        {
            using var database = Process.Start(new ProcessStartInfo("update-desktop-database", applications) { UseShellExecute = false });
            database?.WaitForExit(2_000);
        }
        catch { }
    }

    private static string RunXdgMime(string first, string second, string third, bool allowMissing)
    {
        var start = new ProcessStartInfo("xdg-mime") { UseShellExecute = false, RedirectStandardOutput = true, RedirectStandardError = true };
        start.ArgumentList.Add(first);
        start.ArgumentList.Add(second);
        start.ArgumentList.Add(third);
        try
        {
            using var process = Process.Start(start) ?? throw new InvalidOperationException("Could not start xdg-mime.");
            var output = process.StandardOutput.ReadToEnd();
            process.WaitForExit(5_000);
            if (process.ExitCode != 0 && !allowMissing)
                throw new InvalidOperationException("Linux could not register the HerNess sign-in callback: " + process.StandardError.ReadToEnd());
            return output;
        }
        catch (System.ComponentModel.Win32Exception) when (allowMissing) { return string.Empty; }
    }

    private static string[] LaunchParts()
    {
        var executable = Environment.ProcessPath ?? throw new InvalidOperationException("The application executable path is unavailable.");
        var name = Path.GetFileNameWithoutExtension(executable);
        if (name.Equals("dotnet", StringComparison.OrdinalIgnoreCase))
        {
            var assembly = Assembly.GetEntryAssembly()?.Location;
            if (!string.IsNullOrWhiteSpace(assembly)) return [executable, assembly];
        }
        return [executable];
    }

    private static string QuoteWindows(string value) => "\"" + value.Replace("\"", "\\\"", StringComparison.Ordinal) + "\"";

    private static string QuoteDesktop(string value) => "\"" + value.Replace("%", "%%", StringComparison.Ordinal)
        .Replace("\\", "\\\\", StringComparison.Ordinal).Replace("\"", "\\\"", StringComparison.Ordinal) + "\"";
}

public sealed class MarketplaceSessionException(HttpStatusCode statusCode, string message) : Exception(message)
{
    public HttpStatusCode StatusCode { get; } = statusCode;
}

public sealed record MarketplaceTarget(string Platform, string Architecture)
{
    public string Id => Platform + "/" + Architecture;
    public string Title => $"{Platform} · {Architecture}";
    public static IReadOnlyList<MarketplaceTarget> DefaultTargets { get; } =
    [
        new("macos", "arm64"), new("macos", "x64"),
        new("windows", "x64"), new("linux", "x64"),
    ];
}

public sealed record MarketplacePublishDraft(
    string Folder,
    string License,
    string Version,
    string SourceVisibility,
    IReadOnlyList<MarketplaceTarget> Targets);

/// <summary>Validates, packages, and submits the same native-source release flow as the macOS client.</summary>
public sealed class MarketplacePublisher : ObservableObject
{
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web)
    {
        Converters = { new JsonStringEnumConverter() },
    };
    private bool _isPublishing;
    private string? _status;

    public MarketplacePublisher(MarketplaceSession session) => Session = session;
    public MarketplaceSession Session { get; }
    public bool IsPublishing { get => _isPublishing; private set => SetProperty(ref _isPublishing, value); }
    public string? Status { get => _status; private set => SetProperty(ref _status, value); }

    public async Task PublishAsync(MarketplacePublishDraft draft, CancellationToken cancellationToken = default)
    {
        if (!Session.IsSignedIn) throw new InvalidOperationException("Marketplace publishing requires a HerNess account.");
        if (IsPublishing) return;
        IsPublishing = true;
        Status = null;
        var temporary = Path.Combine(Path.GetTempPath(), "dots-marketplace-" + Guid.NewGuid().ToString("N"));
        try
        {
            if (string.IsNullOrWhiteSpace(draft.License)) throw new InvalidOperationException("Select a plugin license before publishing.");
            if (!IsReleaseSemVer(draft.Version)) throw new InvalidOperationException("Enter a valid three-part SemVer version.");
            if (draft.SourceVisibility is not ("public" or "private") || draft.Targets.Count == 0)
                throw new InvalidOperationException("Select at least one platform target and a valid source visibility.");

            var sourceFolder = Path.GetFullPath(draft.Folder);
            if (!Directory.Exists(sourceFolder)) throw new DirectoryNotFoundException("The selected plugin folder does not exist.");
            var manifestPath = Path.Combine(sourceFolder, "plugin.yml");
            if (!File.Exists(manifestPath)) throw new InvalidOperationException("The selected folder does not contain plugin.yml.");
            var manifest = MiniYaml.DecodeManifest(await File.ReadAllTextAsync(manifestPath, cancellationToken));
            var library = manifest.Library?.Trim() ?? "";
            if (!manifest.Runtime.Equals("native", StringComparison.OrdinalIgnoreCase)
                || manifest.Main is not null || library.Length == 0 || Path.IsPathRooted(library)
                || library.Split(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar).Any(part => part == ".."))
                throw new InvalidOperationException("Only native plugins with a safe compiled library can be published.");
            ValidatePluginId(manifest.Id);

            var irPath = Path.Combine(sourceFolder, "plugin.ir.json");
            var licensePath = Path.Combine(sourceFolder, "license");
            if (!File.Exists(irPath) || !File.Exists(licensePath) || new FileInfo(licensePath).Length == 0)
                throw new InvalidOperationException("The package must contain plugin.ir.json and a non-empty license file.");
            using var irDocument = JsonDocument.Parse(await File.ReadAllBytesAsync(irPath, cancellationToken));
            if (!irDocument.RootElement.TryGetProperty("version", out var irVersion) || irVersion.GetInt32() != 1)
                throw new InvalidOperationException("plugin.ir.json must use version 1.");

            Directory.CreateDirectory(temporary);
            var stagedPlugin = Path.Combine(temporary, manifest.Id);
            CopyPluginFolder(sourceFolder, stagedPlugin);
            var stagedManifestPath = Path.Combine(stagedPlugin, "plugin.yml");
            await RewriteManifestVersionAsync(stagedManifestPath, draft.Version, cancellationToken);
            var releasedManifest = MiniYaml.DecodeManifest(await File.ReadAllTextAsync(stagedManifestPath, cancellationToken));
            var releasedManifestJson = JsonSerializer.SerializeToElement(releasedManifest, JsonOptions);
            var ir = irDocument.RootElement.Clone();
            var targets = draft.Targets.Select(target => new { target.Platform, target.Architecture }).ToArray();
            var pluginMetadata = new
            {
                id = manifest.Id,
                name = manifest.Name,
                description = manifest.Description,
                author = "",
                license = draft.License,
                source_visibility = draft.SourceVisibility,
                targets,
                version = draft.Version,
                ir,
                manifest = releasedManifestJson,
            };
            var metadata = JsonSerializer.SerializeToUtf8Bytes(pluginMetadata, JsonOptions);

            Status = "Creating Marketplace release…";
            var create = await Session.AuthorizedDataAsync("api/marketplace/plugins", HttpMethod.Post, metadata, "application/json", cancellationToken);
            string releaseId;
            if (create.IsSuccess) releaseId = ReadReleaseId(create.Data);
            else if (create.StatusCode == HttpStatusCode.Conflict)
            {
                var releaseMetadata = JsonSerializer.SerializeToUtf8Bytes(new
                {
                    version = draft.Version,
                    license = draft.License,
                    ir,
                    manifest = releasedManifestJson,
                    targets,
                }, JsonOptions);
                var release = await Session.AuthorizedDataAsync(
                    $"api/marketplace/plugins/{Uri.EscapeDataString(manifest.Id)}/releases",
                    HttpMethod.Post, releaseMetadata, "application/json", cancellationToken);
                EnsureSuccess(release, "Marketplace release creation");
                releaseId = ReadReleaseId(release.Data);
            }
            else throw new MarketplaceSessionException(
                create.StatusCode,
                $"Marketplace plugin creation failed (HTTP {(int)create.StatusCode}): {create.Text}");

            Status = "Uploading native source package…";
            var archivePath = Path.Combine(temporary, "source.dotsplugin");
            await PackFolderAsync(stagedPlugin, archivePath, cancellationToken);
            var sourcePackage = await File.ReadAllBytesAsync(archivePath, cancellationToken);
            var source = await Session.AuthorizedDataAsync(
                $"api/marketplace/releases/{Uri.EscapeDataString(releaseId)}/source",
                HttpMethod.Put, sourcePackage, "application/zip", cancellationToken);
            EnsureSuccess(source, "Marketplace source upload");

            var moderation = ReadModerationSummary(source.Data);
            Status = moderation + " Queueing native platform builds…";
            var build = await Session.AuthorizedDataAsync(
                $"api/marketplace/releases/{Uri.EscapeDataString(releaseId)}/build",
                HttpMethod.Post, null, null, cancellationToken);
            EnsureSuccess(build, "Marketplace build request");
            Status = "Source uploaded; waiting for native CI verification and human review.";
        }
        catch (Exception error)
        {
            Status = error.Message;
            throw;
        }
        finally
        {
            try { if (Directory.Exists(temporary)) Directory.Delete(temporary, recursive: true); } catch { }
            IsPublishing = false;
        }
    }

    private static void CopyPluginFolder(string source, string destination)
    {
        Directory.CreateDirectory(destination);
        foreach (var entry in Directory.EnumerateFileSystemEntries(source))
        {
            var name = Path.GetFileName(entry);
            if (name is ".git" or ".mem" or ".DS_Store" or "node_modules" or "bin" or "obj" or ".vs") continue;
            if (name.Equals(".env", StringComparison.OrdinalIgnoreCase)
                || name.StartsWith(".env.", StringComparison.OrdinalIgnoreCase)
                || name.EndsWith(".pem", StringComparison.OrdinalIgnoreCase)
                || name.EndsWith(".key", StringComparison.OrdinalIgnoreCase)) continue;
            var attributes = File.GetAttributes(entry);
            if ((attributes & FileAttributes.ReparsePoint) != 0)
                throw new InvalidOperationException($"Plugin packages cannot include symbolic links or reparse points: {name}");
            var target = Path.Combine(destination, name);
            if ((attributes & FileAttributes.Directory) != 0) CopyPluginFolder(entry, target);
            else File.Copy(entry, target, overwrite: false);
        }
    }

    private static async Task RewriteManifestVersionAsync(string path, string version, CancellationToken cancellationToken)
    {
        var lines = (await File.ReadAllTextAsync(path, cancellationToken)).Split('\n');
        var index = Array.FindIndex(lines, line => line.TrimStart().StartsWith("version:", StringComparison.Ordinal));
        if (index < 0) throw new InvalidOperationException("plugin.yml is missing its version field.");
        var indentation = lines[index][..(lines[index].Length - lines[index].TrimStart().Length)];
        lines[index] = indentation + "version: " + version;
        await File.WriteAllTextAsync(path, string.Join('\n', lines), new UTF8Encoding(false), cancellationToken);
    }

    private static async Task PackFolderAsync(string folder, string destination, CancellationToken cancellationToken)
    {
        await using var stream = new FileStream(destination, FileMode.CreateNew, FileAccess.ReadWrite, FileShare.None, 64 * 1024, useAsync: true);
        using var archive = new ZipArchive(stream, ZipArchiveMode.Create, leaveOpen: true);
        var root = Path.GetFullPath(folder).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar) + Path.DirectorySeparatorChar;
        foreach (var file in Directory.EnumerateFiles(folder, "*", SearchOption.AllDirectories).Order(StringComparer.Ordinal))
        {
            cancellationToken.ThrowIfCancellationRequested();
            if ((File.GetAttributes(file) & FileAttributes.ReparsePoint) != 0)
                throw new InvalidOperationException("Plugin archive contains a symbolic link or reparse point.");
            var relative = Path.GetRelativePath(root, Path.GetFullPath(file)).Replace(Path.DirectorySeparatorChar, '/');
            var entry = archive.CreateEntry(relative, CompressionLevel.Optimal);
            await using var input = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.Read, 64 * 1024, useAsync: true);
            await using var output = entry.Open();
            await input.CopyToAsync(output, cancellationToken);
        }
    }

    private static string ReadReleaseId(byte[] data)
    {
        using var document = JsonDocument.Parse(data);
        if (document.RootElement.TryGetProperty("release_id", out var id)
            && id.ValueKind == JsonValueKind.String && !string.IsNullOrWhiteSpace(id.GetString())) return id.GetString()!;
        throw new InvalidDataException("Marketplace did not return a release ID.");
    }

    private static string ReadModerationSummary(byte[] data)
    {
        try
        {
            using var document = JsonDocument.Parse(data);
            var root = document.RootElement;
            var status = root.TryGetProperty("moderation_status", out var s) ? s.GetString() : null;
            var category = root.TryGetProperty("category", out var c) ? c.GetString() : null;
            var scope = root.TryGetProperty("catalog_scope", out var a) ? a.GetString() : null;
            var model = root.TryGetProperty("moderation_model", out var m) ? m.GetString() : null;
            if (!string.IsNullOrWhiteSpace(category) && !string.IsNullOrWhiteSpace(scope))
                return model == "unavailable"
                    ? $"AI classification unavailable; provisional label: {category} · {scope} · {status}. Human review required."
                    : $"AI classification: {category} · {scope} · {status}. Waiting for human review.";
        }
        catch { }
        return "AI classification could not be confirmed; human review is pending.";
    }

    private static bool IsReleaseSemVer(string version)
    {
        var parts = version.Split('.');
        return parts.Length == 3 && parts.All(part => part.Length > 0
            && part.All(char.IsAsciiDigit) && (part.Length == 1 || part[0] != '0'));
    }

    private static void ValidatePluginId(string id)
    {
        if (id.Length is 0 or > 80 || !char.IsAsciiLetterOrDigit(id[0])
            || id.Any(character => !char.IsAsciiLetterOrDigit(character) && character is not ('.' or '-' or '_'))
            || id.Contains("..", StringComparison.Ordinal))
            throw new InvalidOperationException("plugin.yml contains an unsafe Marketplace plugin id.");
    }

    private static void EnsureSuccess(MarketplaceHttpResult result, string operation)
    {
        if (!result.IsSuccess) throw new MarketplaceSessionException(result.StatusCode, $"{operation} failed (HTTP {(int)result.StatusCode}): {result.Text}");
    }
}

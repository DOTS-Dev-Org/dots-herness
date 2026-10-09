// Copyright (c) 2026 DOTS
// Cross-platform service for the native in-app live browser (WebView2 on Windows, WebKitGTK on Linux).

using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text.Json.Nodes;

namespace DotsHarnessCore;

/// <summary>
/// Interface allowing the UI layer (WPF/WinUI WebView2 or GTK WebKit) to register its active browser view.
/// </summary>
public interface INativeBrowserBridge
{
    Task NavigateAsync(string url, CancellationToken ct = default);
    Task<string> TakeSnapshotAsync(string destinationPath, CancellationToken ct = default);
    Task<string> EvaluateJavaScriptAsync(string script, CancellationToken ct = default);
    Task<string> GetContentAsync(CancellationToken ct = default);
    Task<string> ClickAsync(string? selector, int? x, int? y, CancellationToken ct = default);
    Task<string> TypeTextAsync(string selector, string text, CancellationToken ct = default);
    Task ReloadAsync(CancellationToken ct = default);
    Task GoBackAsync(CancellationToken ct = default);
    Task GoForwardAsync(CancellationToken ct = default);
}

public static class NativeBrowserService
{
    private static INativeBrowserBridge? _activeBridge;
    public static bool IsAvailable => _activeBridge is not null;

    public static string EngineName
    {
        get
        {
            if (RuntimeInformation.IsOSPlatform(OSPlatform.Windows)) return "Microsoft.Web.WebView2";
            if (RuntimeInformation.IsOSPlatform(OSPlatform.Linux)) return "WebKitGTK";
            if (RuntimeInformation.IsOSPlatform(OSPlatform.OSX)) return "Apple WebKit (WKWebView)";
            return "Native Web Engine";
        }
    }

    /// <summary>
    /// Event fired when navigation is requested, notifying the Right Dock panel to focus or switch tabs.
    /// </summary>
    public static event Action<string>? OnNavigateRequested;

    /// <summary>
    /// Register the active UI bridge (e.g. from the Right Dock Live Browser control).
    /// </summary>
    public static void RegisterBridge(INativeBrowserBridge? bridge)
    {
        _activeBridge = bridge;
    }

    public static async Task<string> ExecuteAsync(
        JsonObject arguments,
        string workspace,
        CancellationToken ct = default)
    {
        var actionStr = arguments["action"]?.GetValue<string>()?.Trim().ToLowerInvariant();
        if (string.IsNullOrWhiteSpace(actionStr))
            return "Missing action for native_browser. Supported: open, navigate, screenshot, evaluate_js, get_content, click, type, reload, back, forward.";

        // If a UI bridge is attached, delegate to it directly
        if (_activeBridge != null)
        {
            return await ExecuteWithBridgeAsync(_activeBridge, actionStr, arguments, workspace, ct).ConfigureAwait(false);
        }

        return "Native live browser is unavailable because no platform browser control is attached.";
    }

    private static async Task<string> ExecuteWithBridgeAsync(
        INativeBrowserBridge bridge,
        string action,
        JsonObject arguments,
        string workspace,
        CancellationToken ct)
    {
        switch (action)
        {
            case "open":
            case "navigate":
                var url = arguments["url"]?.GetValue<string>() ?? "about:blank";
                OnNavigateRequested?.Invoke(url);
                await bridge.NavigateAsync(url, ct).ConfigureAwait(false);
                return $"Navigated native browser ({EngineName}) to {url}.";

            case "screenshot":
                var relPath = arguments["path"]?.GetValue<string>() ?? "native_browser.png";
                var destPath = ResolveScreenshotDestination(workspace, relPath);
                Directory.CreateDirectory(Path.GetDirectoryName(destPath)!);
                return await bridge.TakeSnapshotAsync(destPath, ct).ConfigureAwait(false);

            case "evaluate_js":
                var script = arguments["script"]?.GetValue<string>() ?? "";
                if (string.IsNullOrWhiteSpace(script)) return "Missing script parameter for evaluate_js.";
                var res = await bridge.EvaluateJavaScriptAsync(script, ct).ConfigureAwait(false);
                return $"JavaScript result: {res}";

            case "get_content":
                return await bridge.GetContentAsync(ct).ConfigureAwait(false);

            case "click":
                var selector = arguments["selector"]?.GetValue<string>();
                var x = arguments["x"]?.GetValue<int>();
                var y = arguments["y"]?.GetValue<int>();
                return await bridge.ClickAsync(selector, x, y, ct).ConfigureAwait(false);

            case "type":
                var targetSelector = arguments["selector"]?.GetValue<string>() ?? "input";
                var text = arguments["text"]?.GetValue<string>() ?? "";
                return await bridge.TypeTextAsync(targetSelector, text, ct).ConfigureAwait(false);

            case "reload":
                await bridge.ReloadAsync(ct).ConfigureAwait(false);
                return "Reloaded native browser page.";

            case "back":
                await bridge.GoBackAsync(ct).ConfigureAwait(false);
                return "Navigated back in native browser history.";

            case "forward":
                await bridge.GoForwardAsync(ct).ConfigureAwait(false);
                return "Navigated forward in native browser history.";

            default:
                return $"Unknown native_browser action: {action}";
        }
    }

    private static string ResolveScreenshotDestination(string workspace, string relativePath)
    {
        if (string.IsNullOrWhiteSpace(workspace) || !Directory.Exists(workspace))
            throw new InvalidOperationException("Open a project workspace before capturing a browser screenshot.");
        if (string.IsNullOrWhiteSpace(relativePath) || Path.IsPathRooted(relativePath))
            throw new InvalidOperationException("Browser screenshots must use a relative path inside the workspace.");

        var root = Path.GetFullPath(workspace);
        var destination = Path.GetFullPath(Path.Combine(root, relativePath));
        var comparison = OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal;
        var rootPrefix = root.EndsWith(Path.DirectorySeparatorChar)
            ? root
            : root + Path.DirectorySeparatorChar;
        if (!destination.StartsWith(rootPrefix, comparison))
            throw new InvalidOperationException("Browser screenshots must stay inside the workspace.");

        for (var current = Path.GetDirectoryName(destination); current is not null
             && !string.Equals(Path.GetFullPath(current), root, comparison);
             current = Path.GetDirectoryName(current))
        {
            var node = Directory.Exists(current) ? (FileSystemInfo)new DirectoryInfo(current) : new FileInfo(current);
            if (node.Exists && ((node.Attributes & FileAttributes.ReparsePoint) != 0 || node.LinkTarget is not null))
                throw new InvalidOperationException("Browser screenshot paths cannot cross symbolic links or reparse points.");
        }

        var targetFile = new FileInfo(destination);
        if (targetFile.Exists && ((targetFile.Attributes & FileAttributes.ReparsePoint) != 0 || targetFile.LinkTarget is not null))
            throw new InvalidOperationException("Browser screenshot paths cannot overwrite symbolic links or reparse points.");
        return destination;
    }

}

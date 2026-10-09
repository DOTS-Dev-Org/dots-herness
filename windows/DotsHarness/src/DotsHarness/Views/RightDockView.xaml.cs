// Copyright (c) 2026 DOTS
// Windows companion for the macOS right-hand Review/Terminal/Files/Browser dock.

using System.Diagnostics;
using System.IO;
using System.Text;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using DotsHarnessCore;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.Wpf;

namespace DotsHarness.Views;

public partial class RightDockView : UserControl
{
    private TerminalSession? _terminal;
    private string? _terminalWorkspace;
    private string? _loadedFilesWorkspace;
    private WebView2 _browser = null!;
    private WpfNativeBrowserBridge _browserBridge = null!;
    private bool _browserSubscribed;

    private AppModel? Model => DataContext as AppModel;

    public RightDockView()
    {
        InitializeComponent();
        _browser = new WebView2 { DefaultBackgroundColor = System.Drawing.Color.Transparent };
        BrowserHost.Children.Add(_browser);
        _browserBridge = new WpfNativeBrowserBridge(this, _browser);
        _browser.NavigationCompleted += OnBrowserNavigationCompleted;
        _browser.CoreWebView2InitializationCompleted += OnBrowserInitializationCompleted;
        BrowserBackButton.IsEnabled = false;
        BrowserForwardButton.IsEnabled = false;
        TerminalBox.InputReceived += OnTerminalInput;
        Loaded += (_, _) =>
        {
            RefreshLocalization();
            SubscribeNativeBrowser();
        };
    }

    public void RefreshLocalization()
    {
        var model = Model;
        if (model is null) return;

        ReviewTab.Header = "Review";
        TerminalTab.Header = "Terminal";
        FilesTab.Header = "Files";
        BrowserTab.Header = "Browser";
        RefreshButton.ToolTip = "Refresh panel";
        RestartTerminalButton.Content = "Restart";
        OpenBrowserButton.Content = "Go";
        BrowserExternalButton.ToolTip = "Open externally";
        FilesFilter.ToolTip = "Filter files";
        WorkspaceLabel.Text = model.IsRemoteWorkLocation
            ? model.WorkLocationLabel
            : string.IsNullOrWhiteSpace(model.WorkspacePath)
            ? "No workspace"
            : model.WorkspacePath;
        ReviewTab.IsEnabled = !model.IsRemoteWorkLocation;
        FilesTab.IsEnabled = !model.IsRemoteWorkLocation;
        if (model.IsRemoteWorkLocation
            && (Tabs.SelectedItem as TabItem)?.Tag is string selected
            && selected is "review" or "files")
            SelectTab("terminal");
        BrowserStatus.Text = "In-app browser uses Microsoft Edge WebView2.";
        TerminalStatus.Text = string.IsNullOrWhiteSpace(model.TerminalWorkspacePath)
            ? "Select a project to start a terminal."
            : model.TerminalWorkspacePath;
    }

    public void SelectTab(string tag)
    {
        var item = Tabs.Items.OfType<TabItem>().FirstOrDefault(candidate =>
            string.Equals(candidate.Tag as string, tag, StringComparison.Ordinal));
        if (item is not null) item.IsSelected = true;
    }

    public void OpenBrowser(string url)
    {
        BrowserAddress.Text = url;
        SelectTab("browser");
        OnOpenBrowser(this, new RoutedEventArgs());
    }

    private async void OnTabChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!ReferenceEquals(sender, Tabs) || !e.AddedItems.OfType<TabItem>().Any()) return;
        switch ((Tabs.SelectedItem as TabItem)?.Tag as string)
        {
            case "review": await LoadReviewAsync(); break;
            case "files": await LoadFilesAsync(); break;
            case "terminal": StartTerminal(); break;
        }
    }

    private async void OnRefresh(object sender, RoutedEventArgs e)
    {
        switch ((Tabs.SelectedItem as TabItem)?.Tag as string)
        {
            case "review": await LoadReviewAsync(); break;
            case "files": await LoadFilesAsync(); break;
            case "terminal": StartTerminal(force: true); break;
        }
    }

    private async Task LoadReviewAsync()
    {
        var workspace = Model?.WorkspacePath;
        if (string.IsNullOrWhiteSpace(workspace)
            || (Model?.IsRemoteWorkLocation != true && !Directory.Exists(workspace)))
        {
            BranchText.Text = "No workspace";
            ReviewCount.Text = "";
            ReviewList.ItemsSource = Array.Empty<string>();
            ReviewDiff.Text = "Select a project to review its working tree.";
            return;
        }

        var branch = await RunGitAsync(workspace, "branch", "--show-current");
        var status = await RunGitAsync(workspace, "status", "--short", "--branch");
        BranchText.Text = branch.ExitCode == 0 && !string.IsNullOrWhiteSpace(branch.Output.Trim())
            ? branch.Output.Trim()
            : "Git review";

        if (status.ExitCode != 0)
        {
            ReviewCount.Text = "Not a Git repository";
            ReviewList.ItemsSource = Array.Empty<string>();
            ReviewDiff.Text = status.Output.Trim();
            return;
        }

        var lines = status.Output
            .Split('\n', StringSplitOptions.RemoveEmptyEntries)
            .Select(line => line.TrimEnd('\r'))
            .Where(line => !line.StartsWith("## ", StringComparison.Ordinal))
            .ToList();
        ReviewList.ItemsSource = lines;
        ReviewCount.Text = lines.Count == 0 ? "Clean" : $"{lines.Count} change(s)";
        ReviewDiff.Text = lines.Count == 0
            ? "Working tree is clean."
            : "Select a changed file to inspect its diff.";
    }

    private async void OnReviewSelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (ReviewList.SelectedItem is not string line) return;
        var workspace = Model?.WorkspacePath;
        if (string.IsNullOrWhiteSpace(workspace)) return;
        var relative = StatusPath(line);
        if (string.IsNullOrWhiteSpace(relative)) return;

        if (line.StartsWith("??", StringComparison.Ordinal))
        {
            ReviewDiff.Text = await ReadTextPreviewAsync(Path.Combine(workspace, relative));
            return;
        }

        var result = await RunGitAsync(workspace, "diff", "HEAD", "--", relative);
        ReviewDiff.Text = result.Output.TrimEnd();
    }

    private void StartTerminal(bool force = false)
    {
        var workspace = Model?.TerminalWorkspacePath;
        if (string.IsNullOrWhiteSpace(workspace) || !Directory.Exists(workspace))
        {
            StopTerminal();
            TerminalStatus.Text = "Select a project to start a terminal.";
            return;
        }
        if (Model?.ActiveSandbox is not null && Model.SandboxProcessIsolationAvailable == false)
        {
            StopTerminal();
            TerminalStatus.Text = Model.SandboxProcessIsolationStatus;
            return;
        }
        if (!force && _terminal is not null && string.Equals(_terminalWorkspace, workspace, StringComparison.Ordinal)) return;

        StopTerminal();
        _terminalWorkspace = workspace;
        _terminal = new TerminalSession(workspace, Model?.RemoteTarget);
        _terminal.Changed += OnTerminalChanged;
        TerminalStatus.Text = workspace;
        _terminal.Start();
        BindTerminal();
        Dispatcher.BeginInvoke(() => TerminalBox.Focus());
    }

    private void OnRestartTerminal(object sender, RoutedEventArgs e) => StartTerminal(force: true);

    public void StopTerminal()
    {
        if (_terminal is { } terminal)
        {
            terminal.Changed -= OnTerminalChanged;
            terminal.Dispose();
        }
        _terminal = null;
        _terminalWorkspace = null;
        TerminalBox.IsInputEnabled = false;
        TerminalBox.SetTranscript("");
    }

    public void RefreshSandboxPolicy()
    {
        if ((Tabs.SelectedItem as TabItem)?.Tag as string == "terminal") StartTerminal(force: true);
        else StopTerminal();
    }

    private void BindTerminal()
    {
        if (_terminal is null) return;
        TerminalBox.IsInputEnabled = _terminal.IsRunning;
        TerminalBox.SetTranscript(_terminal.Output);
    }

    private void OnTerminalInput(string input) => _terminal?.SendInput(input);

    private void OnTerminalChanged(object? sender, EventArgs e)
    {
        try
        {
            Dispatcher.BeginInvoke(() =>
            {
                if (!ReferenceEquals(sender, _terminal) || _terminal is null) return;
                BindTerminal();
            });
        }
        catch (InvalidOperationException) { }
    }

    private async void OnFilesFilterChanged(object sender, TextChangedEventArgs e) => await LoadFilesAsync();

    private async Task LoadFilesAsync()
    {
        var workspace = Model?.WorkspacePath;
        if (string.IsNullOrWhiteSpace(workspace) || !Directory.Exists(workspace))
        {
            FilesList.ItemsSource = Array.Empty<FileEntry>();
            FilePreview.Text = "Select a project to browse its files.";
            return;
        }
        if (!string.Equals(_loadedFilesWorkspace, workspace, StringComparison.Ordinal))
        {
            _loadedFilesWorkspace = workspace;
            FilePreview.Text = "Select a file to preview it.";
        }

        var filter = FilesFilter.Text.Trim();
        var entries = await Task.Run(() => EnumerateFiles(workspace, filter));
        FilesList.ItemsSource = entries;
    }

    private async void OnFileSelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (FilesList.SelectedItem is not FileEntry entry || entry.IsDirectory)
        {
            if (FilesList.SelectedItem is FileEntry directory && directory.IsDirectory)
                FilePreview.Text = directory.FullPath;
            return;
        }
        FilePreview.Text = await ReadTextPreviewAsync(entry.FullPath);
    }

    private void OnOpenBrowser(object sender, RoutedEventArgs e)
    {
        var address = NormalizeAddress(BrowserAddress.Text);
        if (address is null)
        {
            BrowserStatus.Text = "Enter a valid URL.";
            return;
        }
        _ = NavigateBrowserFromUiAsync(address);
    }

    private async Task NavigateBrowserFromUiAsync(string address)
    {
        try { await _browserBridge.NavigateAsync(address); }
        catch (Exception error) { BrowserStatus.Text = $"Could not open in-app browser: {error.Message}"; }
    }

    private void OnBrowserBack(object sender, RoutedEventArgs e) => _browser.GoBack();
    private void OnBrowserForward(object sender, RoutedEventArgs e) => _browser.GoForward();
    private void OnBrowserReload(object sender, RoutedEventArgs e) => _browser.CoreWebView2?.Reload();

    private void OnOpenBrowserExternally(object sender, RoutedEventArgs e)
    {
        var address = NormalizeAddress(_browser.Source?.AbsoluteUri ?? BrowserAddress.Text);
        if (address is null) return;
        try { Process.Start(new ProcessStartInfo(address) { UseShellExecute = true }); }
        catch (Exception error) { BrowserStatus.Text = $"Could not open system browser: {error.Message}"; }
    }

    private void OnBrowserNavigationCompleted(object? sender, CoreWebView2NavigationCompletedEventArgs e)
    {
        BrowserBackButton.IsEnabled = _browser.CanGoBack;
        BrowserForwardButton.IsEnabled = _browser.CanGoForward;
        BrowserAddress.Text = _browser.Source?.AbsoluteUri ?? "";
        BrowserStatus.Text = e.IsSuccess
            ? (_browser.CoreWebView2?.DocumentTitle is { Length: > 0 } title ? title + " · " : "") + BrowserAddress.Text
            : $"Navigation failed: {e.WebErrorStatus}";
        _browserBridge.CompleteNavigation(e.IsSuccess, e.WebErrorStatus.ToString());
    }

    private void OnBrowserInitializationCompleted(object? sender, CoreWebView2InitializationCompletedEventArgs e)
    {
        if (!e.IsSuccess)
            BrowserStatus.Text = "WebView2 could not start. Install or repair the Microsoft Edge WebView2 Runtime.";
    }

    private void SubscribeNativeBrowser()
    {
        if (_browserSubscribed) return;
        _browserSubscribed = true;
        NativeBrowserService.OnNavigateRequested += OnNativeBrowserNavigateRequested;
        NativeBrowserService.RegisterBridge(_browserBridge);
    }

    private void UnsubscribeNativeBrowser()
    {
        if (!_browserSubscribed) return;
        _browserSubscribed = false;
        NativeBrowserService.OnNavigateRequested -= OnNativeBrowserNavigateRequested;
        NativeBrowserService.RegisterBridge(null);
    }

    private void OnNativeBrowserNavigateRequested(string url)
    {
        Dispatcher.BeginInvoke(new Action(() =>
        {
            BrowserAddress.Text = url;
            SelectTab("browser");
        }));
    }

    private void OnBrowserKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter)
        {
            OnOpenBrowser(sender, new RoutedEventArgs());
            e.Handled = true;
        }
    }

    private void OnUnloaded(object sender, RoutedEventArgs e)
    {
        StopTerminal();
        UnsubscribeNativeBrowser();
    }

    private static async Task<ProcessResult> RunGitAsync(string workingDirectory, params string[] arguments)
    {
        var startInfo = new ProcessStartInfo
        {
            FileName = "git",
            WorkingDirectory = workingDirectory,
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true,
        };
        startInfo.Environment["GIT_TERMINAL_PROMPT"] = "0";
        foreach (var argument in arguments) startInfo.ArgumentList.Add(argument);
        try
        {
            using var process = new Process { StartInfo = startInfo };
            if (!process.Start()) return new ProcessResult(-1, "Unable to start git.");
            var output = process.StandardOutput.ReadToEndAsync();
            var error = process.StandardError.ReadToEndAsync();
            await process.WaitForExitAsync();
            return new ProcessResult(process.ExitCode, (await output) + (await error));
        }
        catch (Exception error)
        {
            return new ProcessResult(-1, error.Message);
        }
    }

    private static IEnumerable<FileEntry> EnumerateFiles(string root, string filter)
    {
        var ignored = new[] { ".git", "node_modules", ".build", "bin", "obj" };
        if (string.IsNullOrWhiteSpace(filter))
        {
            IEnumerable<string> paths;
            try { paths = Directory.EnumerateFileSystemEntries(root); }
            catch { return []; }
            return paths.Select(path => new FileEntry(path, Directory.Exists(path)))
                .OrderByDescending(item => item.IsDirectory)
                .ThenBy(item => item.Name, StringComparer.OrdinalIgnoreCase)
                .ToList();
        }

        var result = new List<FileEntry>();
        try
        {
            foreach (var path in Directory.EnumerateFiles(root, "*", SearchOption.AllDirectories))
            {
                var relative = Path.GetRelativePath(root, path);
                if (relative.Split(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar)
                    .Any(part => ignored.Contains(part, StringComparer.OrdinalIgnoreCase))) continue;
                if (!relative.Contains(filter, StringComparison.OrdinalIgnoreCase)) continue;
                result.Add(new FileEntry(path, false));
                if (result.Count >= 300) break;
            }
        }
        catch { }
        return result.OrderBy(item => item.Name, StringComparer.OrdinalIgnoreCase).ToList();
    }

    private static async Task<string> ReadTextPreviewAsync(string path)
    {
        try
        {
            var bytes = await Task.Run(() => File.ReadAllBytes(path));
            if (bytes.Length > 200_000) bytes = bytes[..200_000];
            return Encoding.UTF8.GetString(bytes);
        }
        catch (Exception error) { return $"Unable to preview file: {error.Message}"; }
    }

    private static string StatusPath(string line)
    {
        if (line.Length < 4) return "";
        var path = line[3..].Trim();
        var rename = path.LastIndexOf(" -> ", StringComparison.Ordinal);
        return rename >= 0 ? path[(rename + 4)..] : path;
    }

    private static string? NormalizeAddress(string? value)
    {
        var text = value?.Trim() ?? "";
        if (text.Length == 0) return null;
        if (!text.Contains("://", StringComparison.Ordinal)) text = "https://" + text;
        return Uri.TryCreate(text, UriKind.Absolute, out var uri)
            && (uri.Scheme is "http" or "https") ? uri.AbsoluteUri : null;
    }

    private sealed class WpfNativeBrowserBridge(RightDockView owner, WebView2 browser) : INativeBrowserBridge
    {
        private TaskCompletionSource<string>? _navigation;
        private Task<string> OnUiAsync(Func<Task<string>> action, CancellationToken ct) =>
            owner.Dispatcher.CheckAccess()
                ? action()
                : owner.Dispatcher.InvokeAsync(action, System.Windows.Threading.DispatcherPriority.Normal, ct).Task.Unwrap();

        private Task OnUiAsync(Action action, CancellationToken ct) => owner.Dispatcher.CheckAccess()
            ? Run(action)
            : owner.Dispatcher.InvokeAsync(action, System.Windows.Threading.DispatcherPriority.Normal, ct).Task;

        private static Task Run(Action action) { action(); return Task.CompletedTask; }

        public async Task NavigateAsync(string url, CancellationToken ct = default)
        {
            var normalized = SafeUrl(url);
            var completion = new TaskCompletionSource<string>(TaskCreationOptions.RunContinuationsAsynchronously);
            await (owner.Dispatcher.CheckAccess()
                ? InitializeAndNavigateAsync()
                : owner.Dispatcher.InvokeAsync(InitializeAndNavigateAsync, System.Windows.Threading.DispatcherPriority.Normal, ct).Task.Unwrap());
            try { _ = await completion.Task.WaitAsync(TimeSpan.FromSeconds(45), ct); }
            finally
            {
                if (ReferenceEquals(_navigation, completion)) _navigation = null;
            }

            async Task InitializeAndNavigateAsync()
            {
                await browser.EnsureCoreWebView2Async();
                _navigation?.TrySetCanceled();
                _navigation = completion;
                owner.BrowserAddress.Text = normalized;
                owner.SelectTab("browser");
                browser.CoreWebView2.Navigate(normalized);
            }
        }

        public void CompleteNavigation(bool success, string detail)
        {
            var pending = _navigation;
            _navigation = null;
            if (success) pending?.TrySetResult("Loaded: " + (browser.Source?.AbsoluteUri ?? ""));
            else pending?.TrySetException(new InvalidOperationException("Browser navigation failed: " + detail));
        }

        public Task<string> TakeSnapshotAsync(string destinationPath, CancellationToken ct = default) => OnUiAsync(async () =>
        {
            await browser.EnsureCoreWebView2Async();
            Directory.CreateDirectory(Path.GetDirectoryName(destinationPath)!);
            await using var stream = new FileStream(destinationPath, FileMode.Create, FileAccess.Write, FileShare.Read);
            await browser.CoreWebView2.CapturePreviewAsync(CoreWebView2CapturePreviewImageFormat.Png, stream);
            return $"Captured native browser screenshot to {destinationPath}.";
        }, ct);

        public Task<string> EvaluateJavaScriptAsync(string script, CancellationToken ct = default) => OnUiAsync(async () =>
        {
            await browser.EnsureCoreWebView2Async();
            return DecodeScriptResult(await browser.ExecuteScriptAsync(script));
        }, ct);

        public Task<string> GetContentAsync(CancellationToken ct = default) =>
            EvaluateJavaScriptAsync("document.body ? document.body.innerText : ''", ct);

        public Task<string> ClickAsync(string? selector, int? x, int? y, CancellationToken ct = default)
        {
            string script;
            if (!string.IsNullOrWhiteSpace(selector))
            {
                var encoded = JsonSerializer.Serialize(selector);
                script = $"(() => {{ const e = document.querySelector({encoded}); if (!e) return 'No element matches the selector.'; e.click(); return 'Clicked the selected element.'; }})()";
            }
            else if (x is not null && y is not null)
            {
                script = $"(() => {{ const e = document.elementFromPoint({x.Value},{y.Value}); if (!e) return 'No element at those coordinates.'; e.click(); return 'Clicked the element at those coordinates.'; }})()";
            }
            else return Task.FromResult("Provide a CSS selector or both x and y coordinates.");
            return EvaluateJavaScriptAsync(script, ct);
        }

        public Task<string> TypeTextAsync(string selector, string text, CancellationToken ct = default)
        {
            var encodedSelector = JsonSerializer.Serialize(selector);
            var encodedText = JsonSerializer.Serialize(text);
            var script = $"(() => {{ const e = document.querySelector({encodedSelector}); if (!e) return 'No element matches the selector.'; e.focus(); if ('value' in e) {{ const p = Object.getPrototypeOf(e); const d = Object.getOwnPropertyDescriptor(p,'value'); if (d && d.set) d.set.call(e,{encodedText}); else e.value = {encodedText}; }} else e.textContent = {encodedText}; e.dispatchEvent(new Event('input',{{bubbles:true}})); e.dispatchEvent(new Event('change',{{bubbles:true}})); return 'Entered text into the selected element.'; }})()";
            return EvaluateJavaScriptAsync(script, ct);
        }

        public Task ReloadAsync(CancellationToken ct = default) => OnUiAsync(() => browser.CoreWebView2?.Reload(), ct);
        public Task GoBackAsync(CancellationToken ct = default) => OnUiAsync(() => { if (browser.CanGoBack) browser.GoBack(); }, ct);
        public Task GoForwardAsync(CancellationToken ct = default) => OnUiAsync(() => { if (browser.CanGoForward) browser.GoForward(); }, ct);

        private static string SafeUrl(string value)
        {
            if (string.Equals(value, "about:blank", StringComparison.OrdinalIgnoreCase)) return "about:blank";
            var normalized = NormalizeAddress(value);
            if (normalized is null) throw new InvalidOperationException("Only http and https browser URLs are allowed.");
            return normalized;
        }

        private static string DecodeScriptResult(string result)
        {
            try
            {
                using var document = JsonDocument.Parse(result);
                return document.RootElement.ValueKind == JsonValueKind.String
                    ? document.RootElement.GetString() ?? ""
                    : document.RootElement.ToString();
            }
            catch (JsonException) { return result; }
        }
    }

    private sealed record ProcessResult(int ExitCode, string Output);

    private sealed record FileEntry(string FullPath, bool IsDirectory)
    {
        public string Name => Path.GetRelativePath(Path.GetDirectoryName(FullPath) ?? FullPath, FullPath);
        public override string ToString() => (IsDirectory ? "▸ " : "  ") + Name;
    }
}

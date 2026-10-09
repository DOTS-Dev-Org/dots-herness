// Copyright (c) 2026 DOTS
// Linux companion for the macOS right-hand Review/Terminal/Files/Browser dock.

using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Interactivity;
using Avalonia.Platform;
using Avalonia.Threading;
using DotsHarnessCore;

namespace DotsHarness.Views;

public partial class RightDockView : UserControl
{
    private TerminalSession? _terminal;
    private string? _terminalWorkspace;
    private string? _loadedFilesWorkspace;
    private NativeWebView _browser = null!;
    private LinuxNativeBrowserBridge _browserBridge = null!;
    private bool _browserSubscribed;

    private AppModel? Model => DataContext as AppModel;

    public RightDockView()
    {
        InitializeComponent();
        _browser = new NativeWebView();
        _browser.EnvironmentRequested += (_, args) =>
        {
            if (args is LinuxWpeWebViewEnvironmentRequestedEventArgs wpe)
                wpe.PreferWebKitGtkInstead = true;
        };
        BrowserHost.Children.Add(_browser);
        _browserBridge = new LinuxNativeBrowserBridge(this, _browser);
        _browser.NavigationCompleted += OnBrowserNavigationCompleted;
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
        ToolTip.SetTip(RefreshButton, "Refresh panel");
        RestartTerminalButton.Content = "Restart";
        OpenBrowserButton.Content = "Go";
        ToolTip.SetTip(BrowserExternalButton, "Open externally");
        FilesFilter.Watermark = "Filter files";
        BrowserAddress.Watermark = "URL";
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
        BrowserStatus.Text = "In-app browser uses the system WebKit runtime.";
        TerminalStatus.Text = string.IsNullOrWhiteSpace(model.TerminalWorkspacePath)
            ? "Select a project to start a terminal."
            : model.TerminalWorkspacePath;
    }

    public void RefreshSandboxPolicy()
    {
        if ((Tabs.SelectedItem as TabItem)?.Tag as string == "terminal") StartTerminal(force: true);
        else StopTerminal();
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

    private async void OnTabChanged(object? sender, SelectionChangedEventArgs e)
    {
        if (!ReferenceEquals(sender, Tabs) || !e.AddedItems.OfType<TabItem>().Any()) return;
        switch ((Tabs.SelectedItem as TabItem)?.Tag as string)
        {
            case "review": await LoadReviewAsync(); break;
            case "files": await LoadFilesAsync(); break;
            case "terminal": StartTerminal(); break;
        }
    }

    private async void OnRefresh(object? sender, RoutedEventArgs e)
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

    private async void OnReviewSelectionChanged(object? sender, SelectionChangedEventArgs e)
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
        if (!force && _terminal is not null && string.Equals(_terminalWorkspace, workspace, StringComparison.Ordinal)) return;

        StopTerminal();
        _terminalWorkspace = workspace;
        var model = Model;
        var sandbox = model?.ActiveSandbox;
        IReadOnlyList<string> writableRoots = [];
        if (sandbox is not null)
        {
            try { writableRoots = SandboxWorkspaces.AgentWritableRoots(sandbox); }
            catch (Exception error)
            {
                TerminalStatus.Text = "Terminal sandbox unavailable: " + error.Message;
                return;
            }
        }
        _terminal = new TerminalSession(
            workspace,
            model?.RemoteTarget,
            sandboxed: sandbox is not null,
            sandboxWritableRoots: writableRoots,
            sandboxNetworkAccess: model?.SandboxNetworkAccess ?? false);
        _terminal.Changed += OnTerminalChanged;
        TerminalStatus.Text = workspace;
        _terminal.Start();
        BindTerminal();
        Dispatcher.UIThread.Post(() => TerminalBox.Focus());
    }

    private void OnRestartTerminal(object? sender, RoutedEventArgs e) => StartTerminal(force: true);

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

    private void BindTerminal()
    {
        if (_terminal is null) return;
        TerminalBox.IsInputEnabled = _terminal.IsRunning;
        TerminalBox.SetTranscript(_terminal.Output);
    }

    private void OnTerminalInput(string input) => _terminal?.SendInput(input);

    private void OnTerminalChanged(object? sender, EventArgs e)
    {
        Dispatcher.UIThread.Post(() =>
        {
            if (!ReferenceEquals(sender, _terminal) || _terminal is null) return;
            BindTerminal();
        });
    }

    private async void OnFilesFilterChanged(object? sender, TextChangedEventArgs e) => await LoadFilesAsync();

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

        var filter = FilesFilter.Text?.Trim() ?? "";
        var entries = await Task.Run(() => EnumerateFiles(workspace, filter));
        FilesList.ItemsSource = entries;
    }

    private async void OnFileSelectionChanged(object? sender, SelectionChangedEventArgs e)
    {
        if (FilesList.SelectedItem is not FileEntry entry)
        {
            FilePreview.Text = "Select a file to preview it.";
            return;
        }
        if (entry.IsDirectory)
        {
            FilePreview.Text = entry.FullPath;
            return;
        }
        FilePreview.Text = await ReadTextPreviewAsync(entry.FullPath);
    }

    private void OnOpenBrowser(object? sender, RoutedEventArgs e)
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

    private void OnBrowserBack(object? sender, RoutedEventArgs e) => _browser.GoBack();
    private void OnBrowserForward(object? sender, RoutedEventArgs e) => _browser.GoForward();
    private void OnBrowserReload(object? sender, RoutedEventArgs e) => _browser.Refresh();

    private void OnOpenBrowserExternally(object? sender, RoutedEventArgs e)
    {
        var address = NormalizeAddress(_browser.Source?.AbsoluteUri ?? BrowserAddress.Text);
        if (address is null) return;
        try { Process.Start(new ProcessStartInfo(address) { UseShellExecute = true }); }
        catch (Exception error) { BrowserStatus.Text = $"Could not open system browser: {error.Message}"; }
    }

    private void OnBrowserNavigationCompleted(object? sender, WebViewNavigationCompletedEventArgs e)
    {
        BrowserBackButton.IsEnabled = _browser.CanGoBack;
        BrowserForwardButton.IsEnabled = _browser.CanGoForward;
        BrowserAddress.Text = _browser.Source?.AbsoluteUri ?? "";
        BrowserStatus.Text = e.IsSuccess
            ? BrowserAddress.Text
            : "Navigation failed in the system WebKit browser.";
        _browserBridge.CompleteNavigation(e.IsSuccess);
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
        Dispatcher.UIThread.Post(() =>
        {
            BrowserAddress.Text = url;
            SelectTab("browser");
        });
    }

    private void OnBrowserKeyDown(object? sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter)
        {
            OnOpenBrowser(sender, new RoutedEventArgs());
            e.Handled = true;
        }
    }

    private void OnUnloaded(object? sender, RoutedEventArgs e)
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

    private sealed class LinuxNativeBrowserBridge(RightDockView owner, NativeWebView browser) : INativeBrowserBridge
    {
        private TaskCompletionSource<string>? _navigation;

        private static string SafeUrl(string value)
        {
            if (string.Equals(value, "about:blank", StringComparison.OrdinalIgnoreCase)) return "about:blank";
            return NormalizeAddress(value)
                ?? throw new InvalidOperationException("Only http and https browser URLs are allowed.");
        }

        private static async Task<T> OnUiAsync<T>(Func<Task<T>> action, CancellationToken ct)
        {
            if (Dispatcher.UIThread.CheckAccess()) return await action();
            var completion = new TaskCompletionSource<T>(TaskCreationOptions.RunContinuationsAsynchronously);
            Dispatcher.UIThread.Post(async () =>
            {
                try { completion.TrySetResult(await action()); }
                catch (Exception error) { completion.TrySetException(error); }
            });
            return await completion.Task.WaitAsync(ct);
        }

        private static Task OnUiActionAsync(Action action, CancellationToken ct)
        {
            if (Dispatcher.UIThread.CheckAccess()) { action(); return Task.CompletedTask; }
            var completion = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
            Dispatcher.UIThread.Post(() =>
            {
                try { action(); completion.TrySetResult(true); }
                catch (Exception error) { completion.TrySetException(error); }
            });
            return completion.Task.WaitAsync(ct);
        }

        public async Task NavigateAsync(string url, CancellationToken ct = default)
        {
            var normalized = SafeUrl(url);
            var completion = new TaskCompletionSource<string>(TaskCreationOptions.RunContinuationsAsynchronously);
            await OnUiActionAsync(() =>
            {
                _navigation?.TrySetCanceled();
                _navigation = completion;
                owner.BrowserAddress.Text = normalized;
                owner.SelectTab("browser");
                browser.Navigate(new Uri(normalized, UriKind.Absolute));
            }, ct);
            try { _ = await completion.Task.WaitAsync(TimeSpan.FromSeconds(45), ct); }
            finally { if (ReferenceEquals(_navigation, completion)) _navigation = null; }
        }

        public void CompleteNavigation(bool success)
        {
            var pending = _navigation;
            _navigation = null;
            if (success) pending?.TrySetResult("Loaded: " + (browser.Source?.AbsoluteUri ?? ""));
            else pending?.TrySetException(new InvalidOperationException("Browser navigation failed."));
        }

        public Task<string> TakeSnapshotAsync(string destinationPath, CancellationToken ct = default) => OnUiAsync(async () =>
        {
            if (browser.TryGetPlatformHandle() is not IGtkWebViewPlatformHandle gtk)
                throw new PlatformNotSupportedException("The Linux WebKit adapter is unavailable; install WebKitGTK 4.1 and restart the application.");
            Directory.CreateDirectory(Path.GetDirectoryName(destinationPath)!);
            await LinuxWebKitSnapshot.SaveAsync(gtk.WebKitWebView, destinationPath, ct);
            return $"Captured native browser screenshot to {destinationPath}.";
        }, ct);

        public Task<string> EvaluateJavaScriptAsync(string script, CancellationToken ct = default) =>
            OnUiAsync(async () => (await browser.InvokeScript(script)) ?? "", ct);

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

        public Task ReloadAsync(CancellationToken ct = default) => OnUiActionAsync(() => browser.Refresh(), ct);
        public Task GoBackAsync(CancellationToken ct = default) => OnUiActionAsync(() => { if (browser.CanGoBack) browser.GoBack(); }, ct);
        public Task GoForwardAsync(CancellationToken ct = default) => OnUiActionAsync(() => { if (browser.CanGoForward) browser.GoForward(); }, ct);
    }

    private static class LinuxWebKitSnapshot
    {
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
        private delegate void SnapshotCallback(IntPtr source, IntPtr result, IntPtr userData);

        [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
        private delegate void GetSnapshot(IntPtr webView, int region, int options, IntPtr cancellable, SnapshotCallback callback, IntPtr userData);

        [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
        private delegate IntPtr GetSnapshotFinish(IntPtr webView, IntPtr result, out IntPtr error);

        [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
        private delegate int WritePng(IntPtr surface, [MarshalAs(UnmanagedType.LPUTF8Str)] string filename);

        [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
        private delegate void DestroySurface(IntPtr surface);

        [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
        private delegate void FreeGError(IntPtr error);

        [StructLayout(LayoutKind.Sequential)]
        private struct GError
        {
            public uint Domain;
            public int Code;
            public IntPtr Message;
        }

        private sealed class SnapshotRequest
        {
            public TaskCompletionSource<IntPtr> Completion { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        }

        private sealed record SnapshotApi(
            IntPtr WebKitLibrary,
            GetSnapshot Start,
            GetSnapshotFinish Finish,
            IntPtr CairoLibrary,
            WritePng Write,
            DestroySurface Destroy,
            FreeGError FreeError);

        private static readonly SnapshotCallback Callback = OnSnapshotReady;
        private static readonly object ApiGate = new();
        private static SnapshotApi? _api;

        public static async Task SaveAsync(IntPtr webView, string path, CancellationToken cancellationToken)
        {
            if (webView == IntPtr.Zero) throw new InvalidOperationException("The WebKitGTK view handle is not ready.");
            var api = GetApi();
            var request = new SnapshotRequest();
            var requestHandle = GCHandle.Alloc(request);
            try
            {
                api.Start(webView, 0, 0, IntPtr.Zero, Callback, GCHandle.ToIntPtr(requestHandle));
            }
            catch
            {
                requestHandle.Free();
                throw;
            }

            IntPtr surface;
            try { surface = await request.Completion.Task.WaitAsync(cancellationToken); }
            catch
            {
                _ = request.Completion.Task.ContinueWith(completed =>
                {
                    if (completed.Status == TaskStatus.RanToCompletion && completed.Result != IntPtr.Zero)
                        api.Destroy(completed.Result);
                }, TaskScheduler.Default);
                throw;
            }
            try
            {
                var status = api.Write(surface, path);
                if (status != 0) throw new IOException($"Cairo could not write the browser snapshot (status {status}).");
            }
            finally { api.Destroy(surface); }
        }

        private static void OnSnapshotReady(IntPtr source, IntPtr result, IntPtr userData)
        {
            var requestHandle = GCHandle.FromIntPtr(userData);
            var request = (SnapshotRequest)requestHandle.Target!;
            try
            {
                var surface = GetApi().Finish(source, result, out var error);
                if (surface == IntPtr.Zero)
                {
                    var message = "WebKitGTK failed to capture the browser view.";
                    if (error != IntPtr.Zero)
                    {
                        try
                        {
                            var nativeError = Marshal.PtrToStructure<GError>(error);
                            if (nativeError.Message != IntPtr.Zero)
                                message = Marshal.PtrToStringUTF8(nativeError.Message) ?? message;
                        }
                        finally { GetApi().FreeError(error); }
                    }
                    request.Completion.TrySetException(new InvalidOperationException(message));
                }
                else request.Completion.TrySetResult(surface);
            }
            catch (Exception error) { request.Completion.TrySetException(error); }
            finally { requestHandle.Free(); }
        }

        private static SnapshotApi GetApi()
        {
            if (_api is not null) return _api;
            lock (ApiGate)
            {
                if (_api is not null) return _api;
                var webKit = LoadFirst("libwebkit2gtk-4.1.so.0", "libwebkit2gtk-4.0.so.37");
                var cairo = NativeLibrary.Load("libcairo.so.2");
                var glib = NativeLibrary.Load("libglib-2.0.so.0");
                _api = new SnapshotApi(
                    webKit,
                    Load<GetSnapshot>(webKit, "webkit_web_view_get_snapshot"),
                    Load<GetSnapshotFinish>(webKit, "webkit_web_view_get_snapshot_finish"),
                    cairo,
                    Load<WritePng>(cairo, "cairo_surface_write_to_png"),
                    Load<DestroySurface>(cairo, "cairo_surface_destroy"),
                    Load<FreeGError>(glib, "g_error_free"));
                return _api;
            }
        }

        private static IntPtr LoadFirst(params string[] libraries)
        {
            foreach (var name in libraries)
                if (NativeLibrary.TryLoad(name, out var handle)) return handle;
            throw new DllNotFoundException("WebKitGTK 4.1 or 4.0 is required for in-app browser screenshots.");
        }

        private static T Load<T>(IntPtr library, string symbol) where T : Delegate =>
            Marshal.GetDelegateForFunctionPointer<T>(NativeLibrary.GetExport(library, symbol));
    }

    private sealed record ProcessResult(int ExitCode, string Output);

    private sealed record FileEntry(string FullPath, bool IsDirectory)
    {
        public string Name => Path.GetRelativePath(Path.GetDirectoryName(FullPath) ?? FullPath, FullPath);
        public override string ToString() => (IsDirectory ? "▸ " : "  ") + Name;
    }
}

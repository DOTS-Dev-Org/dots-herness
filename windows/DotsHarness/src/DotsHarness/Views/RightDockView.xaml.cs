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

    private bool _gitBusy;
    private bool _settingBranches;

    private AppModel? Model => DataContext as AppModel;

    private static void Show(UIElement element, bool visible) =>
        element.Visibility = visible ? Visibility.Visible : Visibility.Collapsed;

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

        ReviewTab.Header = model.L("conversation.review");
        TerminalTab.Header = model.L("conversation.terminal");
        FilesTab.Header = model.L("conversation.files");
        BrowserTab.Header = model.L("conversation.browser");
        PlanTab.Header = model.L("plan.title");
        TasksTab.Header = model.L("backgroundTasks.title");
        PlanApplyButton.Content = model.L("conversation.applyPlan");
        PlanCancelButton.Content = model.L("conversation.cancelPlan");
        PlanReviseButton.Content = model.L("plan.revise");
        PlanAutoButton.Content = model.L("plan.acceptAuto");
        TaskStopButton.Content = model.L("common.stop");
        RefreshButton.ToolTip = model.L("dock.refresh");
        FetchButton.Content = model.L("dock.fetch");
        PushButton.Content = model.L("dock.push");
        PushButton.ToolTip = model.L("dock.push");
        BranchPicker.ToolTip = model.L("git.branchHelp");
        InstallGitButton.Content = model.L("dock.installGit");
        CommitButton.Content = model.L("dock.commit");
        CommitButton.ToolTip = model.L("dock.commitOrPush");
        CommitHint.Text = model.L("dock.commitMessage");
        RestartTerminalButton.Content = model.L("dock.restart");
        OpenBrowserButton.Content = model.L("dock.go");
        BrowserBackButton.ToolTip = model.L("navigation.back");
        BrowserForwardButton.ToolTip = model.L("navigation.forward");
        BrowserReloadButton.ToolTip = model.L("settings.reload");
        BrowserExternalButton.ToolTip = model.L("dock.openExternal");
        FilesFilter.ToolTip = model.L("dock.filterFiles");
        WorkspaceLabel.Text = model.IsRemoteWorkLocation
            ? model.WorkLocationLabel
            : string.IsNullOrWhiteSpace(model.WorkspacePath)
            ? model.L("dock.noWorkspace")
            : model.WorkspacePath;
        ReviewTab.IsEnabled = !model.IsRemoteWorkLocation;
        FilesTab.IsEnabled = !model.IsRemoteWorkLocation;
        if (model.IsRemoteWorkLocation
            && (Tabs.SelectedItem as TabItem)?.Tag is string selected
            && selected is "review" or "files")
            SelectTab("terminal");
        BrowserStatus.Text = model.L("settings.browser.desktopHint");
        TerminalStatus.Text = string.IsNullOrWhiteSpace(model.TerminalWorkspacePath)
            ? model.L("dock.noWorkspace")
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

    public void OpenFile(string path, string displayName)
    {
        if (!File.Exists(path)) return;
        FilesTab.IsEnabled = true;
        SelectTab("files");
        _ = ShowAttachmentPreviewAsync(path, displayName);
    }

    private async Task ShowAttachmentPreviewAsync(string path, string displayName)
    {
        var content = await ReadTextPreviewAsync(path);
        FilePreview.Text = $"{displayName}{Environment.NewLine}{Environment.NewLine}{content}";
    }

    private async void OnTabChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!ReferenceEquals(sender, Tabs) || !e.AddedItems.OfType<TabItem>().Any()) return;
        switch ((Tabs.SelectedItem as TabItem)?.Tag as string)
        {
            case "review": await LoadReviewAsync(); break;
            case "files": await LoadFilesAsync(); break;
            case "terminal": StartTerminal(); break;
            case "plan": LoadPlan(); break;
            case "tasks": LoadTasks(); break;
        }
    }

    private async void OnRefresh(object sender, RoutedEventArgs e)
    {
        switch ((Tabs.SelectedItem as TabItem)?.Tag as string)
        {
            case "review": await LoadReviewAsync(); break;
            case "files": await LoadFilesAsync(); break;
            case "terminal": StartTerminal(force: true); break;
            case "plan": LoadPlan(); break;
            case "tasks": LoadTasks(); break;
        }
    }

    /// <summary>The plan the agent proposed, with the same actions the conversation offers.</summary>
    private void LoadPlan()
    {
        var model = Model;
        if (model is null) return;
        var conversation = model.Selected;
        var plan = conversation?.PendingPlanMessageId is { } id
            ? conversation?.Messages.FirstOrDefault(item => item.Kind == ChatKind.Plan && item.Id == id)
            : conversation?.Messages.LastOrDefault(item => item.Kind == ChatKind.Plan);
        PlanText.Text = plan?.Text ?? "";
        var pending = plan is not null && conversation?.PendingPlanMessageId == plan.Id;
        var canApply = pending
            && conversation?.Running != true
            && conversation?.Continuation is null
            && model.Bridge.CanSendSelectedConversation
            && model.Router.HasActiveRoute;
        PlanProposedLabel.Text = pending ? model.L("plan.proposed") : "";
        PlanApplyButton.IsEnabled = canApply;
        PlanAutoButton.IsEnabled = canApply;
        PlanCancelButton.IsEnabled = pending;
        PlanReviseButton.IsEnabled = pending;
    }

    private void OnPlanApply(object sender, RoutedEventArgs e) => Model?.ApplyPlan();

    private void OnPlanCancel(object sender, RoutedEventArgs e) => Model?.CancelPlan();

    private void OnPlanRevise(object sender, RoutedEventArgs e) => Model?.RevisePlan();

    private void OnPlanApplyAuto(object sender, RoutedEventArgs e) => Model?.ApplyPlanAndAutoApprove();

    /// <summary>The agent's own shells: what the terminal_session tool started.</summary>
    private void LoadTasks()
    {
        var model = Model;
        if (model is null) return;
        var sessions = model.Bridge.AgentTerminalSessions;
        TaskList.ItemsSource = sessions.Count == 0
            ? new[] { model.L("backgroundTasks.empty") }
            : sessions.Select(TaskLabel).ToArray();
        if (sessions.Count > 0 && TaskList.SelectedIndex < 0) TaskList.SelectedIndex = 0;
        else ShowSelectedTask();
    }

    private static string TaskLabel(TerminalSessionTool.SessionInfo session)
    {
        var state = session.IsRunning
            ? "running"
            : session.ExitCode is { } code ? $"exited {code}" : "exited";
        var elapsed = DateTime.Now - session.StartedAt;
        return $"{session.Title} [{state}] {elapsed.TotalMinutes:F0}m";
    }

    private void OnTaskSelectionChanged(object sender, SelectionChangedEventArgs e) => ShowSelectedTask();

    private void ShowSelectedTask()
    {
        var model = Model;
        if (model is null) return;
        var sessions = model.Bridge.AgentTerminalSessions;
        var index = TaskList.SelectedIndex;
        TaskStopButton.IsEnabled = index >= 0 && index < sessions.Count && sessions[index].IsRunning;
        TaskOutput.Text = index >= 0 && index < sessions.Count ? sessions[index].Output : "";
    }

    private void OnTaskStop(object sender, RoutedEventArgs e)
    {
        var model = Model;
        if (model is null) return;
        var sessions = model.Bridge.AgentTerminalSessions;
        var index = TaskList.SelectedIndex;
        if (index < 0 || index >= sessions.Count) return;
        model.Bridge.StopAgentTerminal(sessions[index].Id);
        LoadTasks();
    }

    private async Task LoadReviewAsync()
    {
        var workspace = Model?.WorkspacePath;
        Show(InstallGitButton, false);
        ShowGitActions(false);
        if (string.IsNullOrWhiteSpace(workspace)
            || (Model?.IsRemoteWorkLocation != true && !Directory.Exists(workspace)))
        {
            BranchText.Text = Model?.L("dock.noWorkspace") ?? "";
            ReviewCount.Text = "";
            ReviewList.ItemsSource = Array.Empty<string>();
            ReviewDiff.Text = Model?.L("dock.noWorkspace") ?? "";
            return;
        }

        var branch = await RunGitAsync(workspace, "branch", "--show-current");
        var status = await RunGitAsync(workspace, "status", "--short", "--branch");
        // ExitCode -1 means the process never started: git is not on PATH.
        if (status.ExitCode == -1)
        {
            BranchText.Text = Model?.L("conversation.review") ?? "";
            ReviewCount.Text = Model?.L("dock.gitMissing") ?? "";
            ReviewList.ItemsSource = Array.Empty<string>();
            ReviewDiff.Text = Model?.L("dock.gitMissing") ?? "";
            Show(InstallGitButton, true);
            return;
        }
        BranchText.Text = branch.ExitCode == 0 && !string.IsNullOrWhiteSpace(branch.Output.Trim())
            ? branch.Output.Trim()
            : Model?.L("conversation.review") ?? "";

        if (status.ExitCode != 0)
        {
            ReviewCount.Text = Model?.L("dock.notRepo") ?? "";
            ReviewList.ItemsSource = Array.Empty<string>();
            ReviewDiff.Text = Model?.L("dock.notRepo") ?? "";
            return;
        }

        var heads = await RunGitAsync(workspace, "for-each-ref", "--format=%(refname:short)", "refs/heads");
        var current = branch.ExitCode == 0 ? branch.Output.Trim() : "";
        _settingBranches = true;
        BranchPicker.ItemsSource = heads.ExitCode == 0
            ? heads.Output.Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
                .Order(StringComparer.OrdinalIgnoreCase).ToList()
            : new List<string>();
        // Detached HEAD leaves the picker empty; pushing then reports it.
        BranchPicker.SelectedItem = current.Length == 0 ? null : current;
        _settingBranches = false;
        ShowGitActions(true);

        var lines = status.Output
            .Split('\n', StringSplitOptions.RemoveEmptyEntries)
            .Select(line => line.TrimEnd('\r'))
            .Where(line => !line.StartsWith("## ", StringComparison.Ordinal))
            .ToList();
        ReviewList.ItemsSource = lines;
        ReviewCount.Text = lines.Count == 0 ? Model?.L("dock.clean") ?? "" : Model?.L("git.uncommitted", lines.Count) ?? "";
        ReviewDiff.Text = lines.Count == 0
            ? Model?.L("dock.clean") ?? ""
            : Model?.L("dock.selectFile") ?? "";
    }

    private void ShowGitActions(bool visible)
    {
        Show(BranchText, !visible);
        Show(BranchPicker, visible);
        Show(GitActions, visible);
        Show(CommitBar, visible);
    }

    private void ShowGitError(string? text)
    {
        ReviewError.Text = text ?? "";
        Show(ReviewError, !string.IsNullOrWhiteSpace(text));
    }

    private async void OnBranchSelected(object sender, SelectionChangedEventArgs e)
    {
        if (_settingBranches || BranchPicker.SelectedItem is not string name) return;
        await RunGitStepsAsync(["switch", name]);
    }

    private void OnCommitMessageChanged(object sender, TextChangedEventArgs e)
    {
        var empty = string.IsNullOrWhiteSpace(CommitMessage.Text);
        CommitButton.IsEnabled = !empty;
        Show(CommitHint, empty);
    }

    private async void OnCommit(object sender, RoutedEventArgs e)
    {
        var message = (CommitMessage.Text ?? "").Trim();
        if (message.Length == 0) return;
        if (await RunGitStepsAsync(["add", "-A"], ["commit", "-m", message])) CommitMessage.Text = "";
    }

    /// Sets upstream so a branch's first push works too.
    private async void OnPush(object sender, RoutedEventArgs e)
    {
        var workspace = Model?.WorkspacePath;
        if (_gitBusy || string.IsNullOrWhiteSpace(workspace)) return;
        var current = (await RunGitAsync(workspace, "branch", "--show-current")).Output.Trim();
        if (current.Length == 0)
        {
            ShowGitError(Model?.L("git.branchHelp"));
            return;
        }
        await RunGitStepsAsync(["push", "--set-upstream", "origin", current]);
    }

    private async void OnFetch(object sender, RoutedEventArgs e) =>
        await RunGitStepsAsync(["fetch", "--prune", "--all"]);

    /// Runs the git commands in order, stops at the first failure, shows its output, then reloads.
    private async Task<bool> RunGitStepsAsync(params string[][] steps)
    {
        var workspace = Model?.WorkspacePath;
        if (_gitBusy || string.IsNullOrWhiteSpace(workspace)) return false;
        _gitBusy = true;
        GitActions.IsEnabled = CommitBar.IsEnabled = BranchPicker.IsEnabled = false;
        ProcessResult? failed = null;
        foreach (var step in steps)
        {
            var result = await RunGitAsync(workspace, step);
            if (result.ExitCode != 0) { failed = result; break; }
        }
        _gitBusy = false;
        GitActions.IsEnabled = CommitBar.IsEnabled = BranchPicker.IsEnabled = true;
        await LoadReviewAsync();
        ShowGitError(failed?.Output.Trim());
        return failed is null;
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
            TerminalStatus.Text = Model?.L("dock.noWorkspace") ?? "";
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
            FilePreview.Text = Model?.L("dock.noWorkspace") ?? "";
            return;
        }
        if (!string.Equals(_loadedFilesWorkspace, workspace, StringComparison.Ordinal))
        {
            _loadedFilesWorkspace = workspace;
            FilePreview.Text = Model?.L("dock.selectFile") ?? "";
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
            BrowserStatus.Text = Model?.L("dock.invalidAddress") ?? "";
            return;
        }
        _ = NavigateBrowserFromUiAsync(address);
    }

    private async Task NavigateBrowserFromUiAsync(string address)
    {
        try { await _browserBridge.NavigateAsync(address); }
        catch (Exception error) { BrowserStatus.Text = $"{Model?.L("settings.taskFailed")}: {error.Message}"; }
    }

    private void OnBrowserBack(object sender, RoutedEventArgs e) => _browser.GoBack();
    private void OnBrowserForward(object sender, RoutedEventArgs e) => _browser.GoForward();
    private void OnBrowserReload(object sender, RoutedEventArgs e) => _browser.CoreWebView2?.Reload();

    private void OnOpenBrowserExternally(object sender, RoutedEventArgs e)
    {
        var address = NormalizeAddress(_browser.Source?.AbsoluteUri ?? BrowserAddress.Text);
        if (address is null) return;
        try { Process.Start(new ProcessStartInfo(address) { UseShellExecute = true }); }
        catch (Exception error) { BrowserStatus.Text = $"{Model?.L("settings.taskFailed")}: {error.Message}"; }
    }

    private void OnBrowserNavigationCompleted(object? sender, CoreWebView2NavigationCompletedEventArgs e)
    {
        BrowserBackButton.IsEnabled = _browser.CanGoBack;
        BrowserForwardButton.IsEnabled = _browser.CanGoForward;
        BrowserAddress.Text = _browser.Source?.AbsoluteUri ?? "";
        BrowserStatus.Text = e.IsSuccess
            ? (_browser.CoreWebView2?.DocumentTitle is { Length: > 0 } title ? title + " · " : "") + BrowserAddress.Text
            : $"{Model?.L("settings.taskFailed")}: {e.WebErrorStatus}";
        _browserBridge.CompleteNavigation(e.IsSuccess, e.WebErrorStatus.ToString());
    }

    private void OnBrowserInitializationCompleted(object? sender, CoreWebView2InitializationCompletedEventArgs e)
    {
        if (!e.IsSuccess)
            BrowserStatus.Text = Model?.L("dock.browser.webview2Unavailable") ?? "";
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

    private void OnInstallGit(object sender, RoutedEventArgs e)
    {
        try { Process.Start(new ProcessStartInfo("https://git-scm.com/download/win") { UseShellExecute = true }); } catch { }
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

    private async Task<string> ReadTextPreviewAsync(string path)
    {
        try
        {
            var bytes = await Task.Run(() => File.ReadAllBytes(path));
            if (bytes.Length > 200_000) bytes = bytes[..200_000];
            return Encoding.UTF8.GetString(bytes);
        }
        catch (Exception error) { return $"{Model?.L("settings.taskFailed")}: {error.Message}"; }
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

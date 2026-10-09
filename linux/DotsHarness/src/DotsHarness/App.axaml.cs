// Copyright (c) 2026 DOTS
// Plugin composition model derived from DeepSeek Harness.
// Copyright (c) 2026 DeepSeek. MIT. See NOTICE.

using System.ComponentModel;
using System.Diagnostics;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.ApplicationLifetimes;
using Avalonia.Layout;
using Avalonia.Markup.Xaml;
using Avalonia.Media;
using Avalonia.Media.Imaging;
using Avalonia.Platform;
using Avalonia.Styling;
using Avalonia.Threading;
using DotsHarnessCore;

namespace DotsHarness;

public partial class App : Application
{
    public AppModel Model { get; } = new();

    private TrayIcon? _trayIcon;
    private Views.TrayPanel? _trayPanel;
    private NativeMenuItem? _trayChatsItem;
    private NativeMenuItem? _trayShowItem;
    private NativeMenuItem? _trayQuitItem;
    private CancellationTokenSource? _oauthCallbackCancellation;
    private IClassicDesktopStyleApplicationLifetime? _desktopLifetime;
    private bool _hideHintShown;
    private bool _confirmOpen;
    private bool _exiting;

    /// <summary>True once the user really asked to leave, as opposed to just closing the window.</summary>
    public bool IsExiting => _exiting;

    private static async Task PromptForUpdateAsync(IClassicDesktopStyleApplicationLifetime desktop)
    {
        var update = await CrossPlatformUpdateChecker.CheckOnStartupAsync("linux");
        if (update is null || desktop.MainWindow is not { } owner) return;
        var open = new Button { Content = "İndir" };
        var later = new Button { Content = "Sonra", IsVisible = !update.Mandatory };
        var dialog = new Window
        {
            Title = "Güncelleme",
            Width = 420,
            SizeToContent = SizeToContent.Height,
            WindowStartupLocation = WindowStartupLocation.CenterOwner,
            Content = new StackPanel
            {
                Margin = new Thickness(20),
                Spacing = 12,
                Children =
                {
                    new TextBlock { Text = $"Yeni sürüm: {update.LatestVersion}\n\n{update.ReleaseNotes}", TextWrapping = TextWrapping.Wrap },
                    new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Children = { open, later } },
                },
            },
        };
        open.Click += (_, _) =>
        {
            if (Uri.TryCreate(update.DownloadUrl, UriKind.Absolute, out var url) && url.Scheme == Uri.UriSchemeHttps)
                Process.Start(new ProcessStartInfo(url.AbsoluteUri) { UseShellExecute = true })?.Dispose();
            dialog.Close();
        };
        later.Click += (_, _) => dialog.Close();
        await dialog.ShowDialog(owner);
        if (update.Mandatory) desktop.Shutdown();
    }

    public override void Initialize() => AvaloniaXamlLoader.Load(this);

    public override void OnFrameworkInitializationCompleted()
    {
        var marketplaceCallback = MarketplaceOAuthCallback();
        if (marketplaceCallback is not null
            && ApplicationLifetime is IClassicDesktopStyleApplicationLifetime existingDesktop
            && MarketplaceOAuthProtocol.TryForwardCallbackAsync(marketplaceCallback).GetAwaiter().GetResult())
        {
            existingDesktop.Shutdown();
            base.OnFrameworkInitializationCompleted();
            return;
        }
        Model.PropertyChanged += OnModelPropertyChanged;
        Model.Bridge.AssistantResponseReceived += OnAssistantResponse;
        Model.Bridge.RunSummaryReceived += OnRunSummary;
        Model.Bridge.AttentionNeeded += OnAttentionNeeded;
        Model.Router.ConnectionChanged += OnConnectionChanged;
        ApplyAppearance(Model.Appearance);
        Model.Start();
        if (ApplicationLifetime is IClassicDesktopStyleApplicationLifetime desktop)
        {
            _desktopLifetime = desktop;
            _oauthCallbackCancellation = new CancellationTokenSource();
            _ = Task.Run(() => MarketplaceOAuthProtocol.ListenForCallbacksAsync(
                HandleForwardedMarketplaceOAuthAsync, _oauthCallbackCancellation.Token));
            // The tray keeps this process alive, so the window is not the
            // lifetime: runs, terminals and the scheduler outlive it.
            desktop.ShutdownMode = ShutdownMode.OnExplicitShutdown;
            desktop.ShutdownRequested += (_, e) => OnShutdownRequested(desktop, e);
            desktop.Exit += (_, _) =>
            {
                _oauthCallbackCancellation?.Cancel();
                _oauthCallbackCancellation?.Dispose();
                Model.PropertyChanged -= OnModelPropertyChanged;
                Model.Bridge.AssistantResponseReceived -= OnAssistantResponse;
                Model.Bridge.RunSummaryReceived -= OnRunSummary;
                Model.Bridge.AttentionNeeded -= OnAttentionNeeded;
                Model.Router.ConnectionChanged -= OnConnectionChanged;
                if (desktop.MainWindow is MainWindow window) window.StopTerminal();
                Model.Bridge.Stop();
                Model.McpRegistry.DisposeAsync().AsTask().GetAwaiter().GetResult();
                Model.Bridge.CloseBrowserSessions();
                Model.Local.Stop();
            };
            desktop.MainWindow = new MainWindow();
            InstallTrayIcon();
            desktop.MainWindow.Opened += async (_, _) =>
            {
                await Model.LoadLegalAsync();
                if (Model.LegalNeedsAcceptance && desktop.MainWindow is { } owner)
                {
                    var accepted = await new Views.LegalWindow(Model, gate: true).ShowDialog<bool>(owner);
                    if (!accepted) { desktop.Shutdown(); return; }
                }
                if (marketplaceCallback is { } callback)
                    await CompleteMarketplaceOAuthAsync(callback, desktop);
                await PromptForUpdateAsync(desktop);
            };
        }
        base.OnFrameworkInitializationCompleted();
    }

    private static Uri? MarketplaceOAuthCallback() => Environment.GetCommandLineArgs().Skip(1)
        .Select(value => Uri.TryCreate(value, UriKind.Absolute, out var uri) ? uri : null)
        .FirstOrDefault(uri => uri is { Scheme: "herness", Host: "oauth", AbsolutePath: "/desktop" });

    private async Task CompleteMarketplaceOAuthAsync(Uri callback, IClassicDesktopStyleApplicationLifetime desktop)
    {
        if (desktop.MainWindow is { } main)
        {
            if (!main.IsVisible) main.Show();
            if (main.WindowState == WindowState.Minimized) main.WindowState = WindowState.Normal;
            main.Activate();
        }
        await Model.MarketplaceSession.HandleOAuthCallbackAsync(callback);
        if (Model.MarketplaceSession.IsSignedIn)
        {
            try { await Model.Marketplace.RefreshOwnedPluginsAsync(); } catch { }
        }
        var signedIn = Model.MarketplaceSession.IsSignedIn;
        var message = signedIn
            ? $"Signed in to HerNess as {Model.MarketplaceSession.Profile?.Email}. You can publish plugins from Settings → Plugins."
            : Model.MarketplaceSession.LastError ?? "HerNess sign-in did not complete.";
        if (desktop.MainWindow is not { } owner) return;
        var close = new Button { Content = "Close", Padding = new Thickness(12, 6), HorizontalAlignment = HorizontalAlignment.Right };
        var dialog = new Window
        {
            Title = "HerNess Marketplace",
            Width = 440,
            SizeToContent = SizeToContent.Height,
            WindowStartupLocation = WindowStartupLocation.CenterOwner,
            Content = new StackPanel
            {
                Margin = new Thickness(20),
                Spacing = 14,
                Children =
                {
                    new TextBlock { Text = message, TextWrapping = TextWrapping.Wrap },
                    close,
                },
            },
        };
        close.Click += (_, _) => dialog.Close();
        await dialog.ShowDialog(owner);
    }

    private Task HandleForwardedMarketplaceOAuthAsync(Uri callback)
    {
        if (_desktopLifetime is not { } desktop) return Task.CompletedTask;
        var completion = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        Dispatcher.UIThread.Post(async () =>
        {
            try
            {
                await CompleteMarketplaceOAuthAsync(callback, desktop);
                completion.TrySetResult(true);
            }
            catch (Exception error) { completion.TrySetException(error); }
        });
        return completion.Task;
    }

    private void InstallTrayIcon()
    {
        _trayShowItem = new NativeMenuItem(Model.L("tray.show"));
        _trayShowItem.Click += (_, _) => ShowMainWindow();
        _trayQuitItem = new NativeMenuItem(Model.L("tray.quit"));
        _trayQuitItem.Click += (_, _) => RequestExit();
        // Some desktops open the menu on every click, so the panel is in it too.
        _trayChatsItem = new NativeMenuItem(Model.L("sidebar.chats"));
        _trayChatsItem.Click += (_, _) => ToggleTrayPanel();
        var menu = new NativeMenu();
        menu.Items.Add(_trayChatsItem);
        menu.Items.Add(_trayShowItem);
        menu.Items.Add(new NativeMenuItemSeparator());
        menu.Items.Add(_trayQuitItem);

        _trayIcon = new TrayIcon
        {
            Icon = LoadTrayIcon(),
            ToolTipText = Model.L("app.title"),
            Menu = menu,
        };
        _trayIcon.Clicked += (_, _) => ToggleTrayPanel();
        TrayIcon.SetIcons(this, new TrayIcons { _trayIcon });
    }

    private void ToggleTrayPanel()
    {
        // The legal gate lives in the window; nothing is usable before it.
        if (Model.LegalNeedsAcceptance)
        {
            ShowMainWindow();
            return;
        }
        (_trayPanel ??= new Views.TrayPanel(Model)).Toggle();
    }

    private static WindowIcon LoadTrayIcon()
    {
        using var stream = AssetLoader.Open(new Uri("avares://DotsHarness/Resources/TrayIcon.png"));
        return new WindowIcon(stream);
    }

    public void ShowMainWindow()
    {
        if ((ApplicationLifetime as IClassicDesktopStyleApplicationLifetime)?.MainWindow is not { } window) return;
        if (!window.IsVisible) window.Show();
        if (window.WindowState == WindowState.Minimized) window.WindowState = WindowState.Normal;
        window.Activate();
    }

    /// <summary>Explains where the window went the first time it is hidden.</summary>
    public void NotifyHidden()
    {
        if (_hideHintShown) return;
        _hideHintShown = true;
        try
        {
            var start = new ProcessStartInfo("notify-send") { UseShellExecute = false, CreateNoWindow = true };
            start.ArgumentList.Add(Model.L("app.title"));
            start.ArgumentList.Add(Model.L("settings.closeToTray.hint"));
            Process.Start(start)?.Dispose();
        }
        catch
        {
            // libnotify is optional on Linux; the tray icon still carries the app.
        }
    }

    public void ExitApplication()
    {
        if (_exiting) return;
        _exiting = true;
        if (ApplicationLifetime is IClassicDesktopStyleApplicationLifetime desktop) desktop.Shutdown();
    }

    /// <summary>
    /// Quit request from the tray or from a closing window. Hiding is reversible,
    /// quitting is not, so this is where the exit confirmation belongs.
    /// </summary>
    public void RequestExit()
    {
        if (_exiting || _confirmOpen) return;
        if (!Model.ConfirmBeforeExit)
        {
            ExitApplication();
            return;
        }
        _ = ConfirmExitAsync();
    }

    private async Task ConfirmExitAsync()
    {
        if ((ApplicationLifetime as IClassicDesktopStyleApplicationLifetime)?.MainWindow is not { } owner) return;
        // The tray works while the window is hidden, and a modal dialog needs a
        // visible owner to center on and to receive the click.
        ShowMainWindow();
        _confirmOpen = true;
        var accepted = false;
        var remember = new CheckBox { Content = Model.L("window.remember") };
        var quit = new Button { Content = Model.L("window.close"), IsDefault = true };
        var cancel = new Button { Content = Model.L("window.cancel"), IsCancel = true };
        var dialog = new Window
        {
            Title = Model.L("window.confirmClose"),
            Width = 420,
            SizeToContent = SizeToContent.Height,
            CanResize = false,
            ShowInTaskbar = false,
            WindowStartupLocation = WindowStartupLocation.CenterOwner,
            Content = new StackPanel
            {
                Margin = new Thickness(20),
                Spacing = 12,
                Children =
                {
                    new TextBlock { Text = Model.L("window.closeQuestion"), TextWrapping = TextWrapping.Wrap },
                    remember,
                    new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Children = { quit, cancel } },
                },
            },
        };
        quit.Click += (_, _) =>
        {
            accepted = true;
            dialog.Close();
        };
        await dialog.ShowDialog(owner);
        _confirmOpen = false;
        if (!accepted) return;
        if (remember.IsChecked == true) Model.SetConfirmBeforeExit(false);
        ExitApplication();
    }

    private void OnModelPropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName != nameof(AppModel.Language)) return;
        Dispatcher.UIThread.Post(() =>
        {
            if (_trayIcon is not null) _trayIcon.ToolTipText = Model.L("app.title");
            if (_trayChatsItem is not null) _trayChatsItem.Header = Model.L("sidebar.chats");
            if (_trayShowItem is not null) _trayShowItem.Header = Model.L("tray.show");
            if (_trayQuitItem is not null) _trayQuitItem.Header = Model.L("tray.quit");
        });
    }

    private void OnAssistantResponse(object? sender, AssistantResponseEventArgs e)
    {
        try
        {
            var start = new ProcessStartInfo("notify-send")
            {
                UseShellExecute = false,
                CreateNoWindow = true,
            };
            start.ArgumentList.Add(e.ConversationTitle);
            start.ArgumentList.Add(Preview(e.Text));
            Process.Start(start)?.Dispose();
        }
        catch
        {
            // libnotify is optional on Linux; the chat still contains the response.
        }
    }

    private void OnRunSummary(object? sender, RunSummaryEventArgs e)
    {
        try
        {
            // The user stopped it themselves; nothing to tell them.
            if (e.Outcome == "cancelled") return;
            var failed = e.Outcome is "failed" or "paused";
            var start = new ProcessStartInfo("notify-send") { UseShellExecute = false, CreateNoWindow = true };
            if (failed) start.ArgumentList.Add("--urgency=critical");
            start.ArgumentList.Add(e.ConversationTitle);
            start.ArgumentList.Add(Preview(failed
                ? Model.L("settings.taskFailed") + ": " + e.FailureMessage
                : Model.L("conversation.runSummary") + ": "
                    + Model.L("conversation.filesSummary", e.Summary.AddedCount, e.Summary.ModifiedCount, e.Summary.DeletedCount)
                    + " · " + e.Summary.CleanupNote));
            Process.Start(start)?.Dispose();
        }
        catch { }
    }

    /// Only chats the user cannot see right now: the visible one shows its own card.
    private void OnAttentionNeeded(object? sender, RunAttentionEventArgs e)
    {
        try
        {
            var window = (ApplicationLifetime as IClassicDesktopStyleApplicationLifetime)?.MainWindow;
            var visible = window?.IsActive == true
                && ReferenceEquals(Model.Bridge, sender)
                && Model.Bridge.SelectedId == e.ConversationId;
            if (visible) return;
            var start = new ProcessStartInfo("notify-send") { UseShellExecute = false, CreateNoWindow = true };
            start.ArgumentList.Add(e.ConversationTitle);
            start.ArgumentList.Add(Preview(Model.L("conversation.waitingApproval") + ": " + e.Detail));
            Process.Start(start)?.Dispose();
        }
        catch { }
    }

    private void OnConnectionChanged(ConnectionTransition transition)
    {
        try
        {
            var previous = transition.PreviousConnectionLabel ?? Model.L("router.unknown");
            var current = transition.CurrentConnectionLabel ?? Model.L("router.unknown");
            var message = transition.Action switch
            {
                "removed" when transition.CleanupStatus == "verified" => Model.L("conversation.connectionRemoved"),
                "removed" when transition.CleanupStatus == "failed" => Model.L("conversation.connectionCleanupFailed"),
                "added" when transition.PreviousConnectionLabel is null => Model.L("conversation.connectionAdded", current),
                "selected" => Model.L("conversation.connectionSelected", current),
                _ => Model.L("conversation.connectionSummary", previous, current) + " · "
                    + Model.L("conversation.connectionPreserved", previous),
            };
            var start = new ProcessStartInfo("notify-send") { UseShellExecute = false, CreateNoWindow = true };
            start.ArgumentList.Add(Model.L("conversation.connectionChanged"));
            start.ArgumentList.Add(Preview(message));
            Process.Start(start)?.Dispose();
        }
        catch { }
    }

    private static string Preview(string text)
    {
        var compact = string.Join(" ", text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));
        return compact.Length > 240 ? compact[..240] + "…" : compact;
    }

    private bool _isConfirmingShutdown;

    private async void OnShutdownRequested(
        IClassicDesktopStyleApplicationLifetime desktop,
        ShutdownRequestedEventArgs e)
    {
        if (!Model.ConfirmBeforeExit || _isConfirmingShutdown) return;
        if (desktop.MainWindow is not { } owner) return;

        e.Cancel = true;
        _isConfirmingShutdown = true;
        try
        {
            var dialog = new CloseConfirmationWindow(Model) { Icon = owner.Icon };
            if (await dialog.ShowDialog<bool>(owner))
            {
                if (dialog.Remember) Model.SetConfirmBeforeExit(false);
                desktop.Shutdown();
            }
        }
        finally
        {
            _isConfirmingShutdown = false;
        }
    }

    public void ApplyAppearance(AppModel.AppearanceKind kind)
    {
        var dark = kind switch
        {
            AppModel.AppearanceKind.Dark => true,
            AppModel.AppearanceKind.Light => false,
            _ => IsSystemDark(),
        };
        RequestedThemeVariant = dark ? ThemeVariant.Dark : ThemeVariant.Light;
        SetBrush("WindowBackground", dark ? 0x121214u : 0xF6F6F8u);
        SetBrush("PanelBackground", dark ? 0x1C1C1Fu : 0xFFFFFFu);
        SetBrush("ChromeBackground", dark ? 0x161618u : 0xEEEFF1u);
        SetBrush("TextPrimary", dark ? 0xF2F2F4u : 0x1A1A1Cu);
        SetBrush("TextSecondary", dark ? 0x9A9AA0u : 0x66666Eu);
        SetBrush("Accent", 0x2F6FEDu);
        SetBrush("BubbleUser", dark ? 0x1E3355u : 0xE4EDFFu);
        SetBrush("BubbleAssistant", dark ? 0x28282Cu : 0xF0F0F2u);
        SetBrush("BubbleTool", dark ? 0x3A2C18u : 0xFFF1D6u);
        SetBrush("BubbleSystem", dark ? 0x3A1C1Cu : 0xFFE4E4u);
        SetBrush("BorderSubtle", dark ? 0x2A2A30u : 0xE0E0E4u);
    }

    private void SetBrush(string key, uint rgb)
    {
        var color = Color.FromUInt32(0xFF000000 | rgb);
        Resources[key] = new SolidColorBrush(color);
    }

    private static bool IsSystemDark()
    {
        var gtk = Environment.GetEnvironmentVariable("GTK_THEME") ?? "";
        if (gtk.Contains("dark", StringComparison.OrdinalIgnoreCase)) return true;
        try
        {
            var psi = new ProcessStartInfo
            {
                FileName = "gsettings",
                Arguments = "get org.gnome.desktop.interface color-scheme",
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false,
            };
            using var process = Process.Start(psi);
            var output = process?.StandardOutput.ReadToEnd() ?? "";
            return output.Contains("dark", StringComparison.OrdinalIgnoreCase);
        }
        catch
        {
            return false;
        }
    }
}

internal sealed class CloseConfirmationWindow : Window
{
    public bool Remember { get; private set; }

    public CloseConfirmationWindow(AppModel model)
    {
        Title = model.L("window.confirmClose");
        FlowDirection = model.IsRightToLeft ? Avalonia.Media.FlowDirection.RightToLeft : Avalonia.Media.FlowDirection.LeftToRight;
        Width = 420;
        SizeToContent = SizeToContent.Height;
        CanResize = false;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;

        var remember = new CheckBox
        {
            Content = model.L("window.remember"),
            Margin = new Thickness(0, 10, 0, 0),
        };
        var copy = new StackPanel
        {
            VerticalAlignment = VerticalAlignment.Center,
            Spacing = 4,
            Children =
            {
                new TextBlock
                {
                    Text = model.L("window.closeQuestion"),
                    FontSize = 16,
                    FontWeight = FontWeight.SemiBold,
                    Foreground = Application.Current?.Resources["TextPrimary"] as IBrush,
                    TextWrapping = Avalonia.Media.TextWrapping.Wrap,
                },
                remember,
            },
        };
        var body = new Grid
        {
            ColumnDefinitions = new ColumnDefinitions("64,14,*"),
        };
        var icon = new Border
        {
            Width = 64,
            Height = 64,
            CornerRadius = new CornerRadius(14),
            ClipToBounds = true,
            Child = new Image
            {
                Source = LoadApplicationIcon(),
                Stretch = Stretch.UniformToFill,
            },
        };
        Grid.SetColumn(icon, 0);
        Grid.SetColumn(copy, 2);
        body.Children.Add(icon);
        body.Children.Add(copy);

        var close = new Button
        {
            Content = model.L("window.close"),
            Padding = new Thickness(14, 7),
        };
        close.Click += (_, _) =>
        {
            Remember = remember.IsChecked == true;
            Close(true);
        };
        var cancel = new Button
        {
            Content = model.L("window.cancel"),
            Padding = new Thickness(14, 7),
        };
        cancel.Click += (_, _) => Close(false);

        var buttons = new Grid
        {
            ColumnDefinitions = new ColumnDefinitions("*,8,*"),
        };
        Grid.SetColumn(close, 0);
        Grid.SetColumn(cancel, 2);
        buttons.Children.Add(close);
        buttons.Children.Add(cancel);

        Content = new Border
        {
            Background = Application.Current?.Resources["PanelBackground"] as IBrush,
            Padding = new Thickness(20),
            Child = new StackPanel
            {
                Spacing = 14,
                Children = { body, buttons },
            },
        };
    }

    private static Bitmap LoadApplicationIcon()
    {
        using var stream = AssetLoader.Open(new Uri("avares://DotsHarness/Resources/DotsHarness.png"));
        return new Bitmap(stream);
    }
}

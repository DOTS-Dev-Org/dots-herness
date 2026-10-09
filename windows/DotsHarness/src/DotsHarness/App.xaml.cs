// Copyright (c) 2026 DOTS
// Plugin composition model derived from DeepSeek Harness.
// Copyright (c) 2026 DeepSeek. MIT. See NOTICE.

using System.ComponentModel;
using System.Windows;
using DotsHarnessCore;
using DrawingSystemIcons = System.Drawing.SystemIcons;
using FormsContextMenuStrip = System.Windows.Forms.ContextMenuStrip;
using FormsNotifyIcon = System.Windows.Forms.NotifyIcon;
using FormsToolStripSeparator = System.Windows.Forms.ToolStripSeparator;
using FormsToolStripMenuItem = System.Windows.Forms.ToolStripMenuItem;
using FormsToolTipIcon = System.Windows.Forms.ToolTipIcon;

namespace DotsHarness;

public partial class App : Application
{
    private FormsNotifyIcon? _notificationIcon;
    private FormsToolStripMenuItem? _trayShowItem;
    private FormsToolStripMenuItem? _trayQuitItem;
    private Views.TrayPanel? _trayPanel;
    private CancellationTokenSource? _oauthCallbackCancellation;
    private bool _hideHintShown;
    private bool _exiting;

    public AppModel Model { get; } = new();

    /// <summary>True once the user really asked to leave, as opposed to just closing the window.</summary>
    public bool IsExiting => _exiting;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        var marketplaceCallback = MarketplaceOAuthCallback(e.Args);
        if (marketplaceCallback is not null
            && MarketplaceOAuthProtocol.TryForwardCallbackAsync(marketplaceCallback).GetAwaiter().GetResult())
        {
            _exiting = true;
            Shutdown();
            return;
        }
        // The window is no longer the process lifetime: agent runs, terminals and
        // the scheduler live here, so closing the window must not end them.
        ShutdownMode = ShutdownMode.OnExplicitShutdown;
        _notificationIcon = new FormsNotifyIcon
        {
            Icon = ApplicationIcon(),
            Text = Model.L("app.title"),
            Visible = true,
        };
        var menu = new FormsContextMenuStrip();
        _trayShowItem = new FormsToolStripMenuItem(Model.L("tray.show"), null, (_, _) => ShowMainWindow());
        _trayQuitItem = new FormsToolStripMenuItem(Model.L("tray.quit"), null, (_, _) => RequestExit());
        menu.Items.Add(_trayShowItem);
        menu.Items.Add(new FormsToolStripSeparator());
        menu.Items.Add(_trayQuitItem);
        _notificationIcon.ContextMenuStrip = menu;
        // Left click opens the panel; the context menu stays on right click.
        _notificationIcon.MouseClick += (_, click) =>
        {
            if (click.Button == System.Windows.Forms.MouseButtons.Left) ToggleTrayPanel();
        };
        Model.PropertyChanged += OnModelPropertyChanged;
        Model.Bridge.AssistantResponseReceived += OnAssistantResponse;
        Model.Bridge.RunSummaryReceived += OnRunSummary;
        Model.Bridge.AttentionNeeded += OnAttentionNeeded;
        Model.Router.ConnectionChanged += OnConnectionChanged;
        _oauthCallbackCancellation = new CancellationTokenSource();
        _ = Task.Run(() => MarketplaceOAuthProtocol.ListenForCallbacksAsync(
            HandleForwardedMarketplaceOAuthAsync, _oauthCallbackCancellation.Token));
        ApplyAppearance(Model.Appearance);
        Model.Start();
        if (marketplaceCallback is { } callback)
            _ = CompleteMarketplaceOAuthAsync(callback);
    }

    private static Uri? MarketplaceOAuthCallback(IEnumerable<string> arguments) => arguments
        .Select(value => Uri.TryCreate(value, UriKind.Absolute, out var uri) ? uri : null)
        .FirstOrDefault(uri => uri is { Scheme: "herness", Host: "oauth", AbsolutePath: "/desktop" });

    private async Task CompleteMarketplaceOAuthAsync(Uri callback)
    {
        ShowMainWindow();
        await Model.MarketplaceSession.HandleOAuthCallbackAsync(callback);
        if (Model.MarketplaceSession.IsSignedIn)
        {
            try { await Model.Marketplace.RefreshOwnedPluginsAsync(); } catch { }
        }
        var message = Model.MarketplaceSession.IsSignedIn
            ? $"Signed in to HerNess as {Model.MarketplaceSession.Profile?.Email}. You can publish plugins from Settings → Plugins."
            : Model.MarketplaceSession.LastError ?? "HerNess sign-in did not complete.";
        MessageBox.Show(MainWindow, message, "HerNess Marketplace", MessageBoxButton.OK,
            Model.MarketplaceSession.IsSignedIn ? MessageBoxImage.Information : MessageBoxImage.Error);
    }

    private Task HandleForwardedMarketplaceOAuthAsync(Uri callback) =>
        Dispatcher.InvokeAsync(async () => await CompleteMarketplaceOAuthAsync(callback)).Task.Unwrap();

    private void OnModelPropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName != nameof(AppModel.Language)) return;
        Dispatcher.Invoke(() =>
        {
            if (_notificationIcon is not null) _notificationIcon.Text = Model.L("app.title");
            if (_trayShowItem is not null) _trayShowItem.Text = Model.L("tray.show");
            if (_trayQuitItem is not null) _trayQuitItem.Text = Model.L("tray.quit");
        });
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

    public void ShowMainWindow()
    {
        if (MainWindow is not { } window) return;
        if (!window.IsVisible) window.Show();
        if (window.WindowState == WindowState.Minimized) window.WindowState = WindowState.Normal;
        window.Activate();
        // A hidden-then-shown window does not always come forward on its own.
        window.Topmost = true;
        window.Topmost = false;
    }

    /// <summary>Explains where the window went the first time it is hidden.</summary>
    public void NotifyHidden()
    {
        if (_hideHintShown) return;
        _hideHintShown = true;
        try
        {
            _notificationIcon?.ShowBalloonTip(
                5000, Model.L("app.title"), Model.L("settings.closeToTray.hint"), FormsToolTipIcon.Info);
        }
        catch (ObjectDisposedException) { }
    }

    public void ExitApplication()
    {
        if (_exiting) return;
        _exiting = true;
        Shutdown();
    }

    /// <summary>
    /// Quit request from the tray. Hiding is reversible, quitting is not, so the
    /// exit confirmation belongs here rather than on the close button.
    /// </summary>
    public void RequestExit()
    {
        if (_exiting) return;
        if (!Model.ConfirmBeforeExit)
        {
            ExitApplication();
            return;
        }
        // The tray works while the window is hidden, and the confirmation dialog
        // centers on its owner, so bring the window back first.
        ShowMainWindow();
        var dialog = new CloseConfirmationDialog(Model, MainWindow?.Icon) { Owner = MainWindow };
        if (dialog.ShowDialog() != true) return;
        if (dialog.Remember) Model.SetConfirmBeforeExit(false);
        ExitApplication();
    }

    protected override void OnExit(ExitEventArgs e)
    {
        _oauthCallbackCancellation?.Cancel();
        _oauthCallbackCancellation?.Dispose();
        Model.PropertyChanged -= OnModelPropertyChanged;
        Model.Bridge.AssistantResponseReceived -= OnAssistantResponse;
        Model.Bridge.RunSummaryReceived -= OnRunSummary;
        Model.Bridge.AttentionNeeded -= OnAttentionNeeded;
        Model.Router.ConnectionChanged -= OnConnectionChanged;
        _notificationIcon?.Dispose();
        Model.Bridge.Stop();
        Model.McpRegistry.DisposeAsync().AsTask().GetAwaiter().GetResult();
        Model.Bridge.CloseBrowserSessions();
        Model.Local.Stop();
        base.OnExit(e);
    }

    private static System.Drawing.Icon ApplicationIcon()
    {
        try
        {
            var path = Environment.ProcessPath;
            return path is not null
                ? System.Drawing.Icon.ExtractAssociatedIcon(path) ?? DrawingSystemIcons.Application
                : DrawingSystemIcons.Application;
        }
        catch
        {
            return DrawingSystemIcons.Application;
        }
    }

    private void OnAssistantResponse(object? sender, AssistantResponseEventArgs e)
    {
        try
        {
            _notificationIcon?.ShowBalloonTip(5000, e.ConversationTitle, Preview(e.Text), FormsToolTipIcon.Info);
        }
        catch (ObjectDisposedException)
        {
            // The app can finish closing while an in-flight response completes.
        }
    }

    private void OnRunSummary(object? sender, RunSummaryEventArgs e)
    {
        // The user stopped it themselves; nothing to tell them.
        if (e.Outcome == "cancelled") return;
        try
        {
            var failed = e.Outcome is "failed" or "paused";
            var summary = failed
                ? Model.L("settings.taskFailed") + ": " + e.FailureMessage
                : Model.L("conversation.runSummary") + ": "
                    + Model.L("conversation.filesSummary", e.Summary.AddedCount, e.Summary.ModifiedCount, e.Summary.DeletedCount)
                    + " · " + e.Summary.CleanupNote;
            _notificationIcon?.ShowBalloonTip(5000, e.ConversationTitle, Preview(summary), failed ? FormsToolTipIcon.Error : FormsToolTipIcon.Info);
        }
        catch (ObjectDisposedException) { }
    }

    /// Only chats the user cannot see right now: the visible one shows its own card.
    private void OnAttentionNeeded(object? sender, RunAttentionEventArgs e)
    {
        try
        {
            var visible = MainWindow?.IsActive == true
                && ReferenceEquals(Model.Bridge, sender)
                && Model.Bridge.SelectedId == e.ConversationId;
            if (visible) return;
            _notificationIcon?.ShowBalloonTip(
                5000,
                e.ConversationTitle,
                Preview(Model.L("conversation.waitingApproval") + ": " + e.Detail),
                FormsToolTipIcon.Warning);
        }
        catch (ObjectDisposedException) { }
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
            _notificationIcon?.ShowBalloonTip(5000, Model.L("conversation.connectionChanged"), Preview(message), FormsToolTipIcon.Info);
        }
        catch (ObjectDisposedException) { }
    }

    private static string Preview(string text)
    {
        var compact = string.Join(" ", text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));
        return compact.Length > 240 ? compact[..240] + "…" : compact;
    }

    public void ApplyAppearance(AppModel.AppearanceKind kind)
    {
        var dark = kind switch
        {
            AppModel.AppearanceKind.Dark => true,
            AppModel.AppearanceKind.Light => false,
            _ => IsSystemDark(),
        };
        var dict = Current.Resources.MergedDictionaries.OfType<ResourceDictionary>()
            .FirstOrDefault(d => d.Source?.OriginalString.Contains("Colors", StringComparison.Ordinal) == true);
        if (dict is null) return;
        dict["WindowBackground"] = dark ? ColorBrush(0x12, 0x12, 0x14) : ColorBrush(0xF6, 0xF6, 0xF8);
        dict["PanelBackground"] = dark ? ColorBrush(0x1C, 0x1C, 0x1F) : ColorBrush(0xFF, 0xFF, 0xFF);
        dict["ChromeBackground"] = dark ? ColorBrush(0x16, 0x16, 0x18) : ColorBrush(0xEE, 0xEE, 0xF1);
        dict["TextPrimary"] = dark ? ColorBrush(0xF2, 0xF2, 0xF4) : ColorBrush(0x1A, 0x1A, 0x1C);
        dict["TextSecondary"] = dark ? ColorBrush(0x9A, 0x9A, 0xA0) : ColorBrush(0x66, 0x66, 0x6E);
        dict["Accent"] = ColorBrush(0x2F, 0x6F, 0xED);
        dict["BubbleUser"] = dark ? ColorBrush(0x1E, 0x33, 0x55) : ColorBrush(0xE4, 0xED, 0xFF);
        dict["BubbleAssistant"] = dark ? ColorBrush(0x28, 0x28, 0x2C) : ColorBrush(0xF0, 0xF0, 0xF2);
        dict["BubbleTool"] = dark ? ColorBrush(0x3A, 0x2C, 0x18) : ColorBrush(0xFF, 0xF1, 0xD6);
        dict["BubbleSystem"] = dark ? ColorBrush(0x3A, 0x1C, 0x1C) : ColorBrush(0xFF, 0xE4, 0xE4);
        dict["BorderSubtle"] = dark ? ColorBrush(0x2A, 0x2A, 0x30) : ColorBrush(0xE0, 0xE0, 0xE4);
    }

    private static bool IsSystemDark()
    {
        try
        {
            var value = Microsoft.Win32.Registry.GetValue(
                @"HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize",
                "AppsUseLightTheme",
                1);
            return value is int i && i == 0;
        }
        catch
        {
            return false;
        }
    }

    private static System.Windows.Media.SolidColorBrush ColorBrush(byte r, byte g, byte b)
    {
        var brush = new System.Windows.Media.SolidColorBrush(System.Windows.Media.Color.FromRgb(r, g, b));
        brush.Freeze();
        return brush;
    }
}

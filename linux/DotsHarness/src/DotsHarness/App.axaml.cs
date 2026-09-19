// Copyright (c) 2026 DOTS
// Plugin composition model derived from DeepSeek Harness.
// Copyright (c) 2026 DeepSeek. MIT. See NOTICE.

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
using DotsHarnessCore;

namespace DotsHarness;

public partial class App : Application
{
    public AppModel Model { get; } = new();

    public override void Initialize() => AvaloniaXamlLoader.Load(this);

    public override void OnFrameworkInitializationCompleted()
    {
        Model.ChatBridge.AssistantResponseReceived += OnAssistantResponse;
        Model.CodingBridge.AssistantResponseReceived += OnAssistantResponse;
        Model.ChatBridge.RunSummaryReceived += OnRunSummary;
        Model.CodingBridge.RunSummaryReceived += OnRunSummary;
        Model.ChatBridge.AttentionNeeded += OnAttentionNeeded;
        Model.CodingBridge.AttentionNeeded += OnAttentionNeeded;
        Model.ChatRouter.ConnectionChanged += OnConnectionChanged;
        Model.CodingRouter.ConnectionChanged += OnConnectionChanged;
        ApplyAppearance(Model.Appearance);
        Model.Start();
        if (ApplicationLifetime is IClassicDesktopStyleApplicationLifetime desktop)
        {
            desktop.ShutdownRequested += (_, e) => OnShutdownRequested(desktop, e);
            desktop.Exit += (_, _) =>
            {
                Model.ChatBridge.AssistantResponseReceived -= OnAssistantResponse;
                Model.CodingBridge.AssistantResponseReceived -= OnAssistantResponse;
                Model.ChatBridge.RunSummaryReceived -= OnRunSummary;
                Model.CodingBridge.RunSummaryReceived -= OnRunSummary;
                Model.ChatBridge.AttentionNeeded -= OnAttentionNeeded;
                Model.CodingBridge.AttentionNeeded -= OnAttentionNeeded;
                Model.ChatRouter.ConnectionChanged -= OnConnectionChanged;
                Model.CodingRouter.ConnectionChanged -= OnConnectionChanged;
                if (desktop.MainWindow is MainWindow window) window.StopTerminal();
                Model.ChatBridge.Stop();
                Model.CodingBridge.Stop();
                Model.ChatBridge.CloseBrowserSessions();
                Model.CodingBridge.CloseBrowserSessions();
                Model.Local.Stop();
            };
            desktop.MainWindow = new MainWindow();
            desktop.MainWindow.Opened += async (_, _) =>
            {
                await Model.LoadLegalAsync();
                if (Model.LegalNeedsAcceptance && desktop.MainWindow is { } owner)
                {
                    var accepted = await new Views.LegalWindow(Model, gate: true).ShowDialog<bool>(owner);
                    if (!accepted) desktop.Shutdown();
                }
            };
        }
        base.OnFrameworkInitializationCompleted();
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

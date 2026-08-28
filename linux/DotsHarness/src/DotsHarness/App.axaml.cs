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
using Avalonia.Styling;
using DotsHarnessCore;

namespace DotsHarness;

public partial class App : Application
{
    public AppModel Model { get; } = new();

    public override void Initialize() => AvaloniaXamlLoader.Load(this);

    public override void OnFrameworkInitializationCompleted()
    {
        Model.Bridge.AssistantResponseReceived += OnAssistantResponse;
        ApplyAppearance(Model.Appearance);
        Model.Start();
        if (ApplicationLifetime is IClassicDesktopStyleApplicationLifetime desktop)
        {
            desktop.ShutdownRequested += (_, e) => OnShutdownRequested(desktop, e);
            desktop.Exit += (_, _) =>
            {
                Model.Bridge.AssistantResponseReceived -= OnAssistantResponse;
                if (desktop.MainWindow is MainWindow window) window.StopTerminal();
                Model.Bridge.Stop();
                Model.Local.Stop();
            };
            desktop.MainWindow = new MainWindow();
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
        FlowDirection = model.IsRightToLeft ? Avalonia.Layout.FlowDirection.RightToLeft : Avalonia.Layout.FlowDirection.LeftToRight;
        Width = 380;
        SizeToContent = SizeToContent.Height;
        CanResize = false;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;

        var remember = new CheckBox
        {
            Content = model.L("window.remember"),
            Margin = new Thickness(0, 14, 0, 18),
        };
        var close = new Button
        {
            Content = model.L("window.close"),
            Padding = new Thickness(14, 6),
            Margin = new Thickness(0, 0, 8, 0),
        };
        close.Click += (_, _) =>
        {
            Remember = remember.IsChecked == true;
            Close(true);
        };
        var cancel = new Button
        {
            Content = model.L("window.cancel"),
            Padding = new Thickness(14, 6),
        };
        cancel.Click += (_, _) => Close(false);

        Content = new StackPanel
        {
            Margin = new Thickness(24),
            Children =
            {
                new TextBlock
                {
                    Text = model.L("window.closeQuestion"),
                    TextWrapping = Avalonia.Media.TextWrapping.Wrap,
                },
                remember,
                new StackPanel
                {
                    Orientation = Orientation.Horizontal,
                    HorizontalAlignment = Avalonia.Layout.HorizontalAlignment.Right,
                    Children = { close, cancel },
                },
            },
        };
    }
}

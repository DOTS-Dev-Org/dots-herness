// Copyright (c) 2026 DOTS
// Plugin composition model derived from DeepSeek Harness.
// Copyright (c) 2026 DeepSeek. MIT. See NOTICE.

using System.Windows;
using DotsHarnessCore;
using DrawingSystemIcons = System.Drawing.SystemIcons;
using FormsNotifyIcon = System.Windows.Forms.NotifyIcon;
using FormsToolTipIcon = System.Windows.Forms.ToolTipIcon;

namespace DotsHarness;

public partial class App : Application
{
    private FormsNotifyIcon? _notificationIcon;

    public AppModel Model { get; } = new();

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        _notificationIcon = new FormsNotifyIcon
        {
            Icon = ApplicationIcon(),
            Text = Model.L("app.title"),
            Visible = true,
        };
        Model.Bridge.AssistantResponseReceived += OnAssistantResponse;
        ApplyAppearance(Model.Appearance);
        Model.Start();
    }

    protected override void OnExit(ExitEventArgs e)
    {
        Model.Bridge.AssistantResponseReceived -= OnAssistantResponse;
        _notificationIcon?.Dispose();
        Model.Bridge.Stop();
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

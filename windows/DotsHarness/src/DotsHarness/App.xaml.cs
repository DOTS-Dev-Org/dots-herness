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
    }

    protected override void OnExit(ExitEventArgs e)
    {
        Model.ChatBridge.AssistantResponseReceived -= OnAssistantResponse;
        Model.CodingBridge.AssistantResponseReceived -= OnAssistantResponse;
        Model.ChatBridge.RunSummaryReceived -= OnRunSummary;
        Model.CodingBridge.RunSummaryReceived -= OnRunSummary;
        Model.ChatBridge.AttentionNeeded -= OnAttentionNeeded;
        Model.CodingBridge.AttentionNeeded -= OnAttentionNeeded;
        Model.ChatRouter.ConnectionChanged -= OnConnectionChanged;
        Model.CodingRouter.ConnectionChanged -= OnConnectionChanged;
        _notificationIcon?.Dispose();
        Model.ChatBridge.Stop();
        Model.CodingBridge.Stop();
        Model.ChatBridge.CloseBrowserSessions();
        Model.CodingBridge.CloseBrowserSessions();
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

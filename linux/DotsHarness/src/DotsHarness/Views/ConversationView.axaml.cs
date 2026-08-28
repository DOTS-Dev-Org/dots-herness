// Copyright (c) 2026 DOTS
// Plugin composition model derived from DeepSeek Harness.
// Copyright (c) 2026 DeepSeek. MIT. See NOTICE.

using System.ComponentModel;
using System.Globalization;
using Avalonia;
using Avalonia.Automation;
using Avalonia.Controls;
using Avalonia.Data.Converters;
using Avalonia.Input;
using Avalonia.Interactivity;
using Avalonia.Media;
using Avalonia.Media.Imaging;
using Avalonia.Threading;
using DotsHarnessCore;
using HarnessPluginKit;

namespace DotsHarness.Views;

public partial class ConversationView : UserControl
{
    private TerminalSession? _terminal;
    private string? _terminalWorkspace;
    private INotifyPropertyChanged? _observedModel;
    private readonly DispatcherTimer _workingTimer = new() { Interval = TimeSpan.FromSeconds(1) };

    public ConversationView()
    {
        InitializeComponent();
        TerminalBox.InputReceived += OnTerminalInput;
        _workingTimer.Tick += (_, _) => BindWorkingIndicator();
        Loaded += (_, _) => { _workingTimer.Start(); Bind(); };
        Unloaded += (_, _) => { _workingTimer.Stop(); StopTerminal(); };
    }

    private AppModel? Model => DataContext as AppModel;

    protected override void OnDataContextChanged(EventArgs e)
    {
        base.OnDataContextChanged(e);
        if (_observedModel is not null) _observedModel.PropertyChanged -= OnModel;
        _observedModel = DataContext as INotifyPropertyChanged;
        if (_observedModel is not null) _observedModel.PropertyChanged += OnModel;
        Bind();
    }

    private void OnModel(object? sender, PropertyChangedEventArgs e) => Dispatcher.UIThread.Post(() =>
    {
        Bind();
        if (e.PropertyName is nameof(AppModel.Language) or nameof(AppModel.IsRightToLeft))
        {
            Messages.ItemsSource = null;
            PendingMessages.ItemsSource = null;
            Messages.ItemsSource = Model?.Selected?.Messages;
            PendingMessages.ItemsSource = Model?.Selected?.PendingPrompts;
        }
    });

    private void Bind()
    {
        if (Model is null) return;
        ComposerAccessory.Slot = WellKnownSlot.ComposerAccessory;
        ComposerAccessory.Registry = Model.Host.Slots;
        var conversation = Model.Selected;
        TitleText.Text = conversation?.Title ?? Model.L("conversation.title");
        BindWorkingIndicator();
        TerminalButton.Content = Model.L("conversation.terminal");
        ModelPicker.ToolTip = Model.L("conversation.model");
        DropHint.Text = Model.L("conversation.dropFiles");
        PlanButton.Content = "💡 " + Model.L("conversation.planMode");
        ToolTip.SetTip(PlanButton, Model.L("conversation.planMode"));
        AutomationProperties.SetName(PlanButton, Model.L("conversation.planMode"));
        TerminalTitle.Text = Model.L("conversation.terminal");
        ToolTip.SetTip(CloseTerminalButton, Model.L("conversation.closeTerminal"));
        RejectButton.Content = Model.L("conversation.reject");
        AllowButton.Content = Model.L("conversation.allowOnce");
        EmptyHint.IsVisible = conversation is null;
        EmptyHint.Text = Model.Bridge.Connection is null
            ? Model.L("conversation.emptyNoProvider")
            : Model.L("conversation.emptySidebar");
        Messages.ItemsSource = conversation?.Messages;
        PendingMessages.ItemsSource = conversation?.PendingPrompts;
        DraftAttachments.ItemsSource = Model.DraftAttachments;
        PlanButton.IsChecked = Model.IsPlanMode;
        var pendingPlanId = conversation?.PendingPlanMessageId;
        foreach (var item in Model.Conversations.SelectMany(item => item.Messages))
        {
            var isPending = conversation is not null
                && item.Kind == ChatKind.Plan
                && item.Id == pendingPlanId;
            item.IsPendingPlan = isPending;
            item.IsApplyingPlan = isPending && conversation!.Running;
            item.CanApplyPlan = isPending
                && !conversation!.Running
                && Model.Bridge.Connection is not null;
        }
        var canContinue = conversation?.CanContinue == true && Model.Bridge.CanContinue;
        ModelPicker.ItemsSource = Model.Router.Models;
        ModelPicker.SelectedItem = Model.SelectedModelID;
        ModelPicker.IsEnabled = Model.Router.Models.Count > 0 && conversation?.Running != true;
        StopButton.Content = conversation?.Running == true
            ? Model.L("conversation.stop")
            : Model.L("conversation.continue");
        StopButton.IsVisible = conversation?.Running == true || canContinue;
        SendButton.Content = canContinue ? Model.L("conversation.continue") : Model.L("conversation.send");
        DraftBox.Text = Model.Draft;
        DraftBox.IsEnabled = Model.Bridge.Connection is not null;
        BindApproval();
        BindQuestion();
        BindTerminal();
        Scroller.ScrollToEnd();
    }

    private void BindWorkingIndicator()
    {
        var conversation = Model?.Selected;
        if (conversation?.Running != true || conversation.RunStartedAt is not { } started)
        {
            WorkingIndicator.IsVisible = false;
            WorkingIndicator.Text = "";
            return;
        }

        var elapsed = FormatElapsed(DateTimeOffset.UtcNow - started);
        var skills = Model!.Bridge.ActiveUsedSkills;
        WorkingIndicator.Text = skills.Count == 0
            ? Model.L("conversation.workingFor", elapsed)
            : Model.L("conversation.workingUsing", elapsed, string.Join(", ", skills));
        WorkingIndicator.IsVisible = true;
        AutomationProperties.SetName(WorkingIndicator, WorkingIndicator.Text);
    }

    private static string FormatElapsed(TimeSpan elapsed)
    {
        var seconds = Math.Max(0, (int)elapsed.TotalSeconds);
        if (seconds < 60) return $"{seconds}s";
        var minutes = seconds / 60;
        return minutes < 60
            ? $"{minutes}m {seconds % 60:00}s"
            : $"{minutes / 60}h {minutes % 60:00}m";
    }

    private void BindTerminal()
    {
        var workspace = Model?.WorkspacePath;
        TerminalButton.IsEnabled = !string.IsNullOrWhiteSpace(workspace) && Directory.Exists(workspace);
        if (_terminal is not null && !string.Equals(_terminalWorkspace, workspace, StringComparison.Ordinal))
        {
            StopTerminal();
        }

        if (_terminal is not null)
        {
            TerminalBox.IsInputEnabled = _terminal.IsRunning;
            TerminalBox.SetTranscript(_terminal.Output);
        }
    }

    private void OnTerminal(object? sender, RoutedEventArgs e)
    {
        if (TerminalPanel.IsVisible)
        {
            StopTerminal();
            return;
        }

        var workspace = Model?.WorkspacePath;
        if (string.IsNullOrWhiteSpace(workspace) || !Directory.Exists(workspace)) return;

        _terminalWorkspace = workspace;
        _terminal = new TerminalSession(workspace);
        _terminal.Changed += OnTerminalChanged;
        TerminalPanel.IsVisible = true;
        _terminal.Start();
        BindTerminal();
        Dispatcher.UIThread.Post(() => TerminalBox.Focus(NavigationMethod.Unspecified, KeyModifiers.None));
    }

    private void OnCloseTerminal(object? sender, RoutedEventArgs e) => StopTerminal();

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
        TerminalPanel.IsVisible = false;
    }

    private void OnTerminalInput(string input) => _terminal?.SendInput(input);

    private void OnTerminalChanged(object? sender, EventArgs e)
    {
        Dispatcher.UIThread.Post(() =>
        {
            if (!ReferenceEquals(sender, _terminal) || _terminal is null) return;
            TerminalBox.IsInputEnabled = _terminal.IsRunning;
            TerminalBox.SetTranscript(_terminal.Output);
        });
    }

    private void BindApproval()
    {
        var approval = Model?.Bridge.PendingApproval;
        if (approval is not null && approval.SessionId == Model!.SelectedConversationId)
        {
            ApprovalBar.IsVisible = true;
            ApprovalTitle.Text = Model.L("conversation.allow", approval.ToolName);
            ApprovalReason.Text = approval.Reason ?? "";
        }
        else
        {
            ApprovalBar.IsVisible = false;
        }
    }

    private void BindQuestion()
    {
        var question = Model?.Bridge.PendingQuestion;
        QuestionOptions.Children.Clear();
        if (question is not null && question.SessionId == Model!.SelectedConversationId)
        {
            QuestionBar.IsVisible = true;
            QuestionPrompt.Text = question.Prompt;
            if (question.Options.Count == 0)
            {
                var ok = new Button { Content = Model.L("conversation.ok"), Padding = new Avalonia.Thickness(10, 4) };
                ok.Click += async (_, _) => await Model.Bridge.AnswerQuestionAsync("");
                QuestionOptions.Children.Add(ok);
            }
            else
            {
                foreach (var option in question.Options)
                {
                    var button = new Button { Content = option, Margin = new Avalonia.Thickness(0, 0, 8, 4), Padding = new Avalonia.Thickness(10, 4) };
                    button.Click += async (_, _) => await Model.Bridge.AnswerQuestionAsync(option);
                    QuestionOptions.Children.Add(button);
                }
            }
        }
        else
        {
            QuestionBar.IsVisible = false;
        }
    }

    private void OnSend(object? sender, RoutedEventArgs e)
    {
        Send(PromptMode.Queue);
    }

    private void OnModelChanged(object? sender, SelectionChangedEventArgs e)
    {
        if (ModelPicker.SelectedItem is string model
            && Model is { } app
            && !string.Equals(model, app.SelectedModelID, StringComparison.Ordinal))
        {
            app.SetSelectedModel(model);
        }
    }

    private void OnPlanMode(object? sender, RoutedEventArgs e)
    {
        Model?.TogglePlanMode();
        e.Handled = true;
    }

    private void OnDragOver(object? sender, DragEventArgs e)
    {
        var acceptsFiles = e.DataTransfer.Formats.Contains(DataFormat.File);
        e.DragEffects = acceptsFiles ? DragDropEffects.Copy : DragDropEffects.None;
        DropHint.IsVisible = acceptsFiles;
        e.Handled = true;
    }

    private void OnDragLeave(object? sender, DragEventArgs e)
    {
        DropHint.IsVisible = false;
    }

    private void OnDrop(object? sender, DragEventArgs e)
    {
        DropHint.IsVisible = false;
        if (Model is not null && e.DataTransfer.GetFiles() is { } files)
        {
            Model.AddDraftAttachments(files.Select(file => file.Path.LocalPath));
        }
        e.Handled = true;
    }

    private void OnRemoveAttachment(object? sender, RoutedEventArgs e)
    {
        if (sender is Button { Tag: ChatAttachment attachment }) Model?.RemoveDraftAttachment(attachment);
        e.Handled = true;
    }

    private void Send(PromptMode mode)
    {
        if (Model is null) return;
        Model.Draft = DraftBox.Text ?? "";
        Model.Send(mode);
        DraftBox.Text = "";
    }

    private void OnStop(object? sender, RoutedEventArgs e)
    {
        if (Model?.Bridge.CanContinue == true) Model.Continue();
        else Model?.Cancel();
    }

    private void OnSteerPending(object? sender, RoutedEventArgs e)
    {
        if (sender is Button { Tag: PendingPrompt prompt }
            && Model?.SelectedConversationId is { } conversationId)
        {
            Model.Bridge.SteerPendingPrompt(conversationId, prompt.Id);
        }
        e.Handled = true;
    }

    private void OnApplyPlan(object? sender, RoutedEventArgs e)
    {
        if (sender is Button { Tag: ChatMessage message } && message.CanApplyPlan)
        {
            Model?.ApplyPlan();
        }
        e.Handled = true;
    }

    private void OnDraftKey(object? sender, KeyEventArgs e)
    {
        if (e.Key != Key.Enter) return;
        var steer = e.KeyModifiers.HasFlag(KeyModifiers.Control)
            || e.KeyModifiers.HasFlag(KeyModifiers.Meta);
        if (steer || !e.KeyModifiers.HasFlag(KeyModifiers.Shift))
        {
            Send(steer ? PromptMode.Steer : PromptMode.Queue);
            e.Handled = true;
        }
    }

    private async void OnReject(object? sender, RoutedEventArgs e)
    {
        if (Model is not null) await Model.Bridge.AnswerApprovalAsync("rejected");
    }

    private async void OnAllow(object? sender, RoutedEventArgs e)
    {
        if (Model is not null) await Model.Bridge.AnswerApprovalAsync("allowed-once");
    }
}

public sealed class PromptModeLabel : IValueConverter
{
    public static readonly PromptModeLabel Instance = new();
    public object? Convert(object? value, Type targetType, object? parameter, CultureInfo culture) => value switch
    {
        PromptMode.Steer => LocalizationService.Current.Get("conversation.priority"),
        _ => LocalizationService.Current.Get("conversation.queued"),
    };
    public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) =>
        throw new NotSupportedException();
}

public sealed class LocalizedCopy : IValueConverter
{
    public static readonly LocalizedCopy Instance = new();

    public object? Convert(object? value, Type targetType, object? parameter, CultureInfo culture) =>
        parameter is string key ? LocalizationService.Current.Get(key) : "";

    public object? ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) =>
        throw new NotSupportedException();
}

public sealed class PromptPlacementLabel : IValueConverter
{
    public static readonly PromptPlacementLabel Instance = new();
    public object? Convert(object? value, Type targetType, object? parameter, CultureInfo culture) => value switch
    {
        PromptPlacement.Steering => LocalizationService.Current.Get("conversation.interrupting"),
        PromptPlacement.Context => LocalizationService.Current.Get("conversation.inContext"),
        _ => LocalizationService.Current.Get("conversation.waiting"),
    };
    public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) =>
        throw new NotSupportedException();
}

public sealed class PromptModeSteerVisibility : IValueConverter
{
    public static readonly PromptModeSteerVisibility Instance = new();

    public object? Convert(object? value, Type targetType, object? parameter, CultureInfo culture) =>
        value is PromptMode.Queue;

    public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) =>
        throw new NotSupportedException();
}

public sealed class KindLabel : IValueConverter
{
    public static readonly KindLabel Instance = new();
    public object? Convert(object? value, Type targetType, object? parameter, CultureInfo culture) => value switch
    {
        ChatKind.User => LocalizationService.Current.Get("conversation.you"),
        ChatKind.Assistant => LocalizationService.Current.Get("conversation.assistant"),
        ChatKind.Plan => LocalizationService.Current.Get("conversation.plan"),
        ChatKind.Tool => LocalizationService.Current.Get("conversation.tool"),
        ChatKind.System => LocalizationService.Current.Get("conversation.system"),
        _ => "",
    };
    public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) =>
        throw new NotSupportedException();
}

public sealed class KindBrush : IValueConverter
{
    public static readonly KindBrush Instance = new();
    public object? Convert(object? value, Type targetType, object? parameter, CultureInfo culture)
    {
        var key = value switch
        {
            ChatKind.User => "BubbleUser",
            ChatKind.Assistant => "BubbleAssistant",
            ChatKind.Plan => "PanelBackground",
            ChatKind.Tool => "BubbleTool",
            ChatKind.System => "BubbleSystem",
            _ => "BubbleAssistant",
        };
        if (Application.Current?.TryGetResource(key, Application.Current.ActualThemeVariant, out var resource) == true
            && resource is IBrush brush)
        {
            return brush;
        }
        return Brushes.Transparent;
    }
    public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) =>
        throw new NotSupportedException();
}

public sealed class PlanVisibility : IValueConverter
{
    public static readonly PlanVisibility Instance = new();
    public object? Convert(object? value, Type targetType, object? parameter, CultureInfo culture) =>
        value is ChatKind.Plan;
    public object? ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) =>
        throw new NotSupportedException();
}

public sealed class NotPlanVisibility : IValueConverter
{
    public static readonly NotPlanVisibility Instance = new();
    public object? Convert(object? value, Type targetType, object? parameter, CultureInfo culture) =>
        value is not ChatKind.Plan;
    public object? ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) =>
        throw new NotSupportedException();
}

public sealed class PlanStatus : IValueConverter
{
    public static readonly PlanStatus Instance = new();
    public object? Convert(object? value, Type targetType, object? parameter, CultureInfo culture) => value is ChatMessage message
        ? message.PlanError is { Length: > 0 } error
            ? LocalizationService.Current.Get("conversation.error", error)
            : message.IsApplyingPlan ? LocalizationService.Current.Get("conversation.applying")
            : message.IsPendingPlan ? LocalizationService.Current.Get("conversation.waitingApproval")
            : LocalizationService.Current.Get("conversation.applied")
        : "";
    public object? ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) =>
        throw new NotSupportedException();
}

public sealed class MetadataVisibility : IValueConverter
{
    public static readonly MetadataVisibility Instance = new();

    public object? Convert(object? value, Type targetType, object? parameter, CultureInfo culture)
    {
        if (value is not ChatMessage message) return false;
        return string.Equals(parameter?.ToString(), "files", StringComparison.OrdinalIgnoreCase)
            ? message.ChangedFiles.Count > 0
            : message.UsedSkills.Count > 0 || message.UsedTools.Count > 0;
    }

    public object? ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) =>
        throw new NotSupportedException();
}

public sealed class AttachmentImage : IValueConverter
{
    public static readonly AttachmentImage Instance = new();

    public object? Convert(object? value, Type targetType, object? parameter, CultureInfo culture)
    {
        if (value is not string path || !File.Exists(path)) return null;
        var extension = Path.GetExtension(path).ToLowerInvariant();
        if (extension is not (".png" or ".jpg" or ".jpeg" or ".gif" or ".webp" or ".bmp" or ".tif" or ".tiff" or ".heic" or ".heif" or ".avif")) return null;
        try { return new Bitmap(path); }
        catch { return null; }
    }

    public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) =>
        throw new NotSupportedException();
}

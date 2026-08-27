// Copyright (c) 2026 DOTS
// Plugin composition model derived from DeepSeek Harness.
// Copyright (c) 2026 DeepSeek. MIT. See NOTICE.

using System.ComponentModel;
using System.Globalization;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Data.Converters;
using Avalonia.Input;
using Avalonia.Interactivity;
using Avalonia.Media;
using Avalonia.Threading;
using DotsHarnessCore;
using HarnessPluginKit;

namespace DotsHarness.Views;

public partial class ConversationView : UserControl
{
    public ConversationView()
    {
        InitializeComponent();
        DataContextChanged += (_, _) => Bind();
        Loaded += (_, _) => Bind();
    }

    private AppModel? Model => DataContext as AppModel;

    protected override void OnDataContextChanged(EventArgs e)
    {
        base.OnDataContextChanged(e);
        if (DataContext is INotifyPropertyChanged next) next.PropertyChanged += OnModel;
        Bind();
    }

    private void OnModel(object? sender, PropertyChangedEventArgs e) => Dispatcher.UIThread.Post(Bind);

    private void Bind()
    {
        if (Model is null) return;
        ComposerAccessory.Slot = WellKnownSlot.ComposerAccessory;
        ComposerAccessory.Registry = Model.Host.Slots;
        var conversation = Model.Selected;
        TitleText.Text = conversation?.Title ?? "Dots Harness";
        EmptyHint.IsVisible = conversation is null;
        EmptyHint.Text = Model.Bridge.Connection is null
            ? "Connect a provider account to start chatting."
            : "Start a conversation from the sidebar.";
        Messages.ItemsSource = conversation?.Messages;
        PendingMessages.ItemsSource = conversation?.PendingPrompts;
        StopButton.IsVisible = conversation?.Running == true;
        DraftBox.Text = Model.Draft;
        DraftBox.IsEnabled = Model.Bridge.Connection is not null;
        BindApproval();
        BindQuestion();
        Scroller.ScrollToEnd();
    }

    private void BindApproval()
    {
        var approval = Model?.Bridge.PendingApproval;
        if (approval is not null && approval.SessionId == Model!.SelectedConversationId)
        {
            ApprovalBar.IsVisible = true;
            ApprovalTitle.Text = $"Allow {approval.ToolName}?";
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
                var ok = new Button { Content = "OK", Padding = new Avalonia.Thickness(10, 4) };
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

    private void Send(PromptMode mode)
    {
        if (Model is null) return;
        Model.Draft = DraftBox.Text ?? "";
        Model.Send(mode);
        DraftBox.Text = "";
    }

    private void OnStop(object? sender, RoutedEventArgs e) => Model?.Cancel();

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
        PromptMode.Steer => "Priority instruction",
        _ => "Queued message",
    };
    public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) =>
        throw new NotSupportedException();
}

public sealed class PromptPlacementLabel : IValueConverter
{
    public static readonly PromptPlacementLabel Instance = new();
    public object? Convert(object? value, Type targetType, object? parameter, CultureInfo culture) => value switch
    {
        PromptPlacement.Steering => "Interrupting",
        PromptPlacement.Context => "In context",
        _ => "Waiting",
    };
    public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) =>
        throw new NotSupportedException();
}

public sealed class KindLabel : IValueConverter
{
    public static readonly KindLabel Instance = new();
    public object? Convert(object? value, Type targetType, object? parameter, CultureInfo culture) => value switch
    {
        ChatKind.User => "You",
        ChatKind.Assistant => "Harness",
        ChatKind.Tool => "Tool",
        ChatKind.System => "System",
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

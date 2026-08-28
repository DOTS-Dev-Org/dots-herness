// Copyright (c) 2026 DOTS
// Plugin composition model derived from DeepSeek Harness.
// Copyright (c) 2026 DeepSeek. MIT. See NOTICE.

using System.ComponentModel;
using System.Globalization;
using System.Speech.Recognition;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using DotsHarnessCore;
using HarnessPluginKit;

namespace DotsHarness.Views;

public partial class ConversationView : UserControl
{
    private TerminalSession? _terminal;
    private string? _terminalWorkspace;
    private readonly System.Windows.Threading.DispatcherTimer _workingTimer = new() { Interval = TimeSpan.FromSeconds(1) };

    public ConversationView()
    {
        InitializeComponent();
        TerminalBox.InputReceived += OnTerminalInput;
        DataContextChanged += OnCtx;
        _workingTimer.Tick += (_, _) => BindWorkingIndicator();
        Loaded += (_, _) => { _workingTimer.Start(); Bind(); };
        Unloaded += (_, _) =>
        {
            _workingTimer.Stop();
            StopVoiceInput();
            StopTerminal();
        };
    }

    private AppModel? Model => DataContext as AppModel;
    private SpeechRecognitionEngine? _voiceRecognizer;

    private void OnCtx(object sender, DependencyPropertyChangedEventArgs e)
    {
        if (e.OldValue is INotifyPropertyChanged oldM) oldM.PropertyChanged -= OnModel;
        if (e.NewValue is INotifyPropertyChanged next) next.PropertyChanged += OnModel;
        Bind();
    }

    private void OnModel(object? sender, PropertyChangedEventArgs e)
    {
        Dispatcher.Invoke(() =>
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
    }

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
        PlanButton.ToolTip = Model.L("conversation.planMode");
        System.Windows.Automation.AutomationProperties.SetName(PlanButton, Model.L("conversation.planMode"));
        TerminalTitle.Text = Model.L("conversation.terminal");
        CloseTerminalButton.ToolTip = Model.L("conversation.closeTerminal");
        RejectButton.Content = Model.L("conversation.reject");
        AllowButton.Content = Model.L("conversation.allowOnce");
        EmptyHint.Visibility = conversation is null ? Visibility.Visible : Visibility.Collapsed;
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
        StopButton.Visibility = conversation?.Running == true || canContinue
            ? Visibility.Visible
            : Visibility.Collapsed;
        SendButton.Content = canContinue ? Model.L("conversation.continue") : Model.L("conversation.send");
        if (!DraftBox.IsFocused)
        {
            DraftBox.Text = Model.Draft;
        }
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
            WorkingIndicator.Visibility = Visibility.Collapsed;
            WorkingIndicator.Text = "";
            return;
        }

        var elapsed = FormatElapsed(DateTimeOffset.UtcNow - started);
        var skills = Model!.Bridge.ActiveUsedSkills;
        WorkingIndicator.Text = skills.Count == 0
            ? Model.L("conversation.workingFor", elapsed)
            : Model.L("conversation.workingUsing", elapsed, string.Join(", ", skills));
        WorkingIndicator.Visibility = Visibility.Visible;
        System.Windows.Automation.AutomationProperties.SetName(WorkingIndicator, WorkingIndicator.Text);
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

    private void OnTerminal(object sender, RoutedEventArgs e)
    {
        if (TerminalPanel.Visibility == Visibility.Visible)
        {
            StopTerminal();
            return;
        }

        var workspace = Model?.WorkspacePath;
        if (string.IsNullOrWhiteSpace(workspace) || !Directory.Exists(workspace)) return;

        _terminalWorkspace = workspace;
        _terminal = new TerminalSession(workspace);
        _terminal.Changed += OnTerminalChanged;
        TerminalPanel.Visibility = Visibility.Visible;
        _terminal.Start();
        BindTerminal();
        Dispatcher.BeginInvoke(() => TerminalBox.Focus());
    }

    private void OnCloseTerminal(object sender, RoutedEventArgs e) => StopTerminal();

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
        TerminalPanel.Visibility = Visibility.Collapsed;
    }

    private void OnTerminalInput(string input) => _terminal?.SendInput(input);

    private void OnTerminalChanged(object? sender, EventArgs e)
    {
        try
        {
            Dispatcher.BeginInvoke(() =>
            {
                if (!ReferenceEquals(sender, _terminal) || _terminal is null) return;
                TerminalBox.IsInputEnabled = _terminal.IsRunning;
                TerminalBox.SetTranscript(_terminal.Output);
            });
        }
        catch (InvalidOperationException)
        {
            // The dispatcher can be shutting down while the child process exits.
        }
    }

    private void BindApproval()
    {
        var approval = Model?.Bridge.PendingApproval;
        if (approval is not null && approval.SessionId == Model!.SelectedConversationId)
        {
            ApprovalBar.Visibility = Visibility.Visible;
            ApprovalTitle.Text = Model.L("conversation.allow", approval.ToolName);
            ApprovalReason.Text = approval.Reason ?? "";
        }
        else
        {
            ApprovalBar.Visibility = Visibility.Collapsed;
        }
    }

    private void BindQuestion()
    {
        var question = Model?.Bridge.PendingQuestion;
        QuestionOptions.Children.Clear();
        if (question is not null && question.SessionId == Model!.SelectedConversationId)
        {
            QuestionBar.Visibility = Visibility.Visible;
            QuestionPrompt.Text = question.Prompt;
            if (question.Options.Count == 0)
            {
                var ok = new Button { Content = Model.L("conversation.ok"), Padding = new Thickness(10, 4, 10, 4) };
                ok.Click += async (_, _) => await Model.Bridge.AnswerQuestionAsync("");
                QuestionOptions.Children.Add(ok);
            }
            else
            {
                foreach (var option in question.Options)
                {
                    var button = new Button { Content = option, Margin = new Thickness(0, 0, 8, 4), Padding = new Thickness(10, 4, 10, 4) };
                    button.Click += async (_, _) => await Model.Bridge.AnswerQuestionAsync(option);
                    QuestionOptions.Children.Add(button);
                }
            }
        }
        else
        {
            QuestionBar.Visibility = Visibility.Collapsed;
        }
    }

    private void OnSend(object sender, RoutedEventArgs e)
    {
        Send(PromptMode.Queue);
    }

    private void OnModelChanged(object sender, SelectionChangedEventArgs e)
    {
        if (ModelPicker.SelectedItem is string model
            && Model is { } app
            && !string.Equals(model, app.SelectedModelID, StringComparison.Ordinal))
        {
            app.SetSelectedModel(model);
        }
    }

    private void OnPlanMode(object sender, RoutedEventArgs e)
    {
        Model?.TogglePlanMode();
        e.Handled = true;
    }

    private void OnDragOver(object sender, DragEventArgs e)
    {
        var acceptsFiles = e.Data.GetDataPresent(DataFormats.FileDrop);
        e.Effects = acceptsFiles ? DragDropEffects.Copy : DragDropEffects.None;
        DropHint.Visibility = acceptsFiles ? Visibility.Visible : Visibility.Collapsed;
        e.Handled = true;
    }

    private void OnDragLeave(object sender, DragEventArgs e)
    {
        DropHint.Visibility = Visibility.Collapsed;
    }

    private void OnDrop(object sender, DragEventArgs e)
    {
        DropHint.Visibility = Visibility.Collapsed;
        if (Model is not null && e.Data.GetData(DataFormats.FileDrop) is string[] paths)
        {
            Model.AddDraftAttachments(paths);
        }
        e.Handled = true;
    }

    private void OnRemoveAttachment(object sender, RoutedEventArgs e)
    {
        if (sender is Button { Tag: ChatAttachment attachment }) Model?.RemoveDraftAttachment(attachment);
        e.Handled = true;
    }

    private void OnVoice(object sender, RoutedEventArgs e)
    {
        if (_voiceRecognizer is not null)
        {
            StopVoiceInput();
            return;
        }

        SpeechRecognitionEngine? recognizer = null;
        try
        {
            recognizer = new SpeechRecognitionEngine();
            recognizer.LoadGrammar(new DictationGrammar());
            recognizer.SetInputToDefaultAudioDevice();
            recognizer.SpeechRecognized += OnSpeechRecognized;
            recognizer.RecognizeCompleted += OnRecognizeCompleted;
            _voiceRecognizer = recognizer;
            recognizer.RecognizeAsync(RecognizeMode.Multiple);
            VoiceButton.Content = Model?.L("conversation.stop") ?? "Stop";
            VoiceButton.ToolTip = Model?.L("conversation.stopVoice") ?? "Stop voice input";
            VoiceStatus.Text = Model?.L("conversation.listening") ?? "Listening…";
            VoiceStatus.Visibility = Visibility.Visible;
        }
        catch (Exception error)
        {
            if (ReferenceEquals(_voiceRecognizer, recognizer)) _voiceRecognizer = null;
            recognizer?.Dispose();
            ShowVoiceError(error);
        }
    }

    public void StopVoiceInput()
    {
        var recognizer = _voiceRecognizer;
        if (recognizer is null) return;

        _voiceRecognizer = null;
        VoiceButton.Content = Model?.L("conversation.mic") ?? "Mic";
        VoiceButton.ToolTip = Model?.L("conversation.startVoice") ?? "Start voice input";
        try
        {
            recognizer.RecognizeAsyncCancel();
        }
        catch (Exception)
        {
            recognizer.Dispose();
        }
    }

    private void OnSpeechRecognized(object? sender, SpeechRecognizedEventArgs e)
    {
        var text = e.Result?.Text?.Trim();
        if (string.IsNullOrEmpty(text)) return;

        Dispatcher.BeginInvoke(() =>
        {
            if (!ReferenceEquals(_voiceRecognizer, sender)) return;
            var separator = string.IsNullOrWhiteSpace(DraftBox.Text) ? "" : " ";
            DraftBox.AppendText(separator + text);
            DraftBox.CaretIndex = DraftBox.Text.Length;
            DraftBox.ScrollToEnd();
            if (Model is { } model) model.Draft = DraftBox.Text;
            VoiceStatus.Text = Model?.L("conversation.heard", text) ?? $"Heard: {text}";
        });
    }

    private void OnRecognizeCompleted(object? sender, RecognizeCompletedEventArgs e)
    {
        if (sender is not SpeechRecognitionEngine recognizer) return;
        recognizer.SpeechRecognized -= OnSpeechRecognized;
        recognizer.RecognizeCompleted -= OnRecognizeCompleted;

        Dispatcher.BeginInvoke(() =>
        {
            if (ReferenceEquals(_voiceRecognizer, recognizer))
            {
                _voiceRecognizer = null;
                VoiceButton.Content = Model?.L("conversation.mic") ?? "Mic";
                VoiceButton.ToolTip = Model?.L("conversation.startVoice") ?? "Start voice input";
                if (e.Error is not null) ShowVoiceError(e.Error);
                else if (!e.Cancelled)
                {
                    VoiceStatus.Text = Model?.L("conversation.voiceStopped") ?? "Voice input stopped.";
                    VoiceStatus.Visibility = Visibility.Visible;
                }
            }
            recognizer.Dispose();
        });
    }

    private void ShowVoiceError(Exception error)
    {
        VoiceButton.Content = Model?.L("conversation.mic") ?? "Mic";
        VoiceButton.ToolTip = Model?.L("conversation.startVoice") ?? "Start voice input";
        VoiceStatus.Text = Model?.L("conversation.voiceUnavailable", error.Message)
            ?? $"Voice input unavailable. Check Windows microphone privacy and an installed speech language. {error.Message}";
        VoiceStatus.Visibility = Visibility.Visible;
    }

    private void Send(PromptMode mode)
    {
        if (Model is null) return;
        StopVoiceInput();
        Model.Draft = DraftBox.Text;
        Model.Send(mode);
        DraftBox.Text = "";
    }

    private void OnStop(object sender, RoutedEventArgs e)
    {
        if (Model?.Bridge.CanContinue == true) Model.Continue();
        else Model?.Cancel();
    }

    private void OnSteerPending(object sender, RoutedEventArgs e)
    {
        if (sender is Button { Tag: PendingPrompt prompt }
            && Model?.SelectedConversationId is { } conversationId)
        {
            Model.Bridge.SteerPendingPrompt(conversationId, prompt.Id);
        }
        e.Handled = true;
    }

    private void OnApplyPlan(object sender, RoutedEventArgs e)
    {
        if (sender is Button { Tag: ChatMessage message } && message.CanApplyPlan)
        {
            Model?.ApplyPlan();
        }
        e.Handled = true;
    }

    private void OnDraftKey(object sender, KeyEventArgs e)
    {
        if (e.Key != Key.Enter) return;
        var steer = Keyboard.Modifiers.HasFlag(ModifierKeys.Control);
        if (steer || !Keyboard.Modifiers.HasFlag(ModifierKeys.Shift))
        {
            Send(steer ? PromptMode.Steer : PromptMode.Queue);
            e.Handled = true;
        }
    }

    private async void OnReject(object sender, RoutedEventArgs e)
    {
        if (Model is not null) await Model.Bridge.AnswerApprovalAsync("rejected");
    }

    private async void OnAllow(object sender, RoutedEventArgs e)
    {
        if (Model is not null) await Model.Bridge.AnswerApprovalAsync("allowed-once");
    }
}

public sealed class PromptModeLabel : IValueConverter
{
    public static readonly PromptModeLabel Instance = new();
    public object? Convert(object value, Type targetType, object parameter, System.Globalization.CultureInfo culture) => value switch
    {
        PromptMode.Steer => LocalizationService.Current.Get("conversation.priority"),
        _ => LocalizationService.Current.Get("conversation.queued"),
    };
    public object ConvertBack(object value, Type targetType, object parameter, System.Globalization.CultureInfo culture) =>
        throw new NotSupportedException();
}

public sealed class LocalizedCopy : IValueConverter
{
    public static readonly LocalizedCopy Instance = new();

    public object Convert(object value, Type targetType, object parameter, CultureInfo culture) =>
        parameter is string key ? LocalizationService.Current.Get(key) : "";

    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) =>
        Binding.DoNothing;
}

public sealed class PromptPlacementLabel : IValueConverter
{
    public static readonly PromptPlacementLabel Instance = new();
    public object? Convert(object value, Type targetType, object parameter, System.Globalization.CultureInfo culture) => value switch
    {
        PromptPlacement.Steering => LocalizationService.Current.Get("conversation.interrupting"),
        PromptPlacement.Context => LocalizationService.Current.Get("conversation.inContext"),
        _ => LocalizationService.Current.Get("conversation.waiting"),
    };
    public object ConvertBack(object value, Type targetType, object parameter, System.Globalization.CultureInfo culture) =>
        throw new NotSupportedException();
}

public sealed class PromptModeSteerVisibility : IValueConverter
{
    public static readonly PromptModeSteerVisibility Instance = new();

    public object Convert(object value, Type targetType, object parameter, CultureInfo culture) =>
        value is PromptMode.Queue ? Visibility.Visible : Visibility.Collapsed;

    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) =>
        Binding.DoNothing;
}

public sealed class KindLabel : IValueConverter
{
    public static readonly KindLabel Instance = new();
    public object Convert(object value, Type targetType, object parameter, CultureInfo culture) => value switch
    {
        ChatKind.User => LocalizationService.Current.Get("conversation.you"),
        ChatKind.Assistant => LocalizationService.Current.Get("conversation.assistant"),
        ChatKind.Plan => LocalizationService.Current.Get("conversation.plan"),
        ChatKind.Tool => LocalizationService.Current.Get("conversation.tool"),
        ChatKind.System => LocalizationService.Current.Get("conversation.system"),
        _ => "",
    };
    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) => Binding.DoNothing;
}

public sealed class KindBrush : IValueConverter
{
    public static readonly KindBrush Instance = new();
    public object Convert(object value, Type targetType, object parameter, CultureInfo culture)
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
        return Application.Current?.TryFindResource(key) as Brush ?? Brushes.Transparent;
    }
    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) => Binding.DoNothing;
}

public sealed class PlanVisibility : IValueConverter
{
    public static readonly PlanVisibility Instance = new();
    public object Convert(object value, Type targetType, object parameter, CultureInfo culture) =>
        value is ChatKind.Plan ? Visibility.Visible : Visibility.Collapsed;
    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) => Binding.DoNothing;
}

public sealed class NotPlanVisibility : IValueConverter
{
    public static readonly NotPlanVisibility Instance = new();
    public object Convert(object value, Type targetType, object parameter, CultureInfo culture) =>
        value is ChatKind.Plan ? Visibility.Collapsed : Visibility.Visible;
    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) => Binding.DoNothing;
}

public sealed class PlanStatus : IValueConverter
{
    public static readonly PlanStatus Instance = new();
    public object Convert(object value, Type targetType, object parameter, CultureInfo culture) => value is ChatMessage message
        ? message.PlanError is { Length: > 0 } error
            ? LocalizationService.Current.Get("conversation.error", error)
            : message.IsApplyingPlan ? LocalizationService.Current.Get("conversation.applying")
            : message.IsPendingPlan ? LocalizationService.Current.Get("conversation.waitingApproval")
            : LocalizationService.Current.Get("conversation.applied")
        : "";
    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) => Binding.DoNothing;
}

public sealed class MetadataVisibility : IValueConverter
{
    public static readonly MetadataVisibility Instance = new();

    public object Convert(object value, Type targetType, object parameter, CultureInfo culture)
    {
        if (value is not ChatMessage message) return Visibility.Collapsed;
        return string.Equals(parameter?.ToString(), "files", StringComparison.OrdinalIgnoreCase)
            ? message.ChangedFiles.Count > 0 ? Visibility.Visible : Visibility.Collapsed
            : message.UsedSkills.Count > 0 || message.UsedTools.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) => Binding.DoNothing;
}

public sealed class AttachmentImage : IValueConverter
{
    public static readonly AttachmentImage Instance = new();

    public object Convert(object value, Type targetType, object parameter, CultureInfo culture)
    {
        if (value is not string path || !File.Exists(path)) return null!;
        var extension = Path.GetExtension(path).ToLowerInvariant();
        if (extension is not (".png" or ".jpg" or ".jpeg" or ".gif" or ".webp" or ".bmp" or ".tif" or ".tiff" or ".heic" or ".heif" or ".avif")) return null!;
        try
        {
            var image = new BitmapImage();
            image.BeginInit();
            image.CacheOption = BitmapCacheOption.OnLoad;
            image.UriSource = new Uri(Path.GetFullPath(path));
            image.EndInit();
            image.Freeze();
            return image;
        }
        catch
        {
            return null!;
        }
    }

    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) =>
        Binding.DoNothing;
}

// Copyright (c) 2026 DOTS
// Plugin composition model derived from DeepSeek Harness.
// Copyright (c) 2026 DeepSeek. MIT. See NOTICE.

using System.Collections.Specialized;
using System.ComponentModel;
using System.Globalization;
using System.IO;
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
    private Conversation? _observedConversation;
    private INotifyCollectionChanged? _observedMessages;
    private INotifyCollectionChanged? _observedPending;
    private readonly HashSet<ChatMessage> _observedMessageItems = new();
    private MessageTail<ChatMessage>? _messageTail;
    private bool _loadingOlder;

    public ConversationView()
    {
        InitializeComponent();
        TerminalBox.InputReceived += OnTerminalInput;
        DataContextChanged += OnCtx;
        _workingTimer.Tick += (_, _) => BindWorkingIndicator();
        Scroller.ScrollChanged += OnScrollChanged;
        Loaded += (_, _) => { _workingTimer.Start(); Bind(); };
        Unloaded += (_, _) =>
        {
            _workingTimer.Stop();
            StopVoiceInput();
            StopTerminal();
            ObserveConversation(null);
            _messageTail?.Dispose();
            _messageTail = null;
        };
    }

    private AppModel? Model => DataContext as AppModel;
    private WindowsMicrophoneCapture? _microphone;
    private VoiceInputController? _observedVoice;
    private Guid _activeVoiceSessionId;

    private void OnCtx(object sender, DependencyPropertyChangedEventArgs e)
    {
        if (e.OldValue is INotifyPropertyChanged oldM) oldM.PropertyChanged -= OnModel;
        if (e.NewValue is INotifyPropertyChanged next) next.PropertyChanged += OnModel;
        if (_observedVoice is not null)
        {
            _observedVoice.TranscriptUpdated -= OnVoiceTranscript;
            _observedVoice.Error -= OnVoiceError;
            _observedVoice = null;
        }
        _activeVoiceSessionId = Guid.Empty;
        if (e.NewValue is AppModel nextModel)
        {
            _observedVoice = nextModel.Voice;
            _observedVoice.TranscriptUpdated += OnVoiceTranscript;
            _observedVoice.Error += OnVoiceError;
        }
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
                Messages.ItemsSource = MessageSource(Model?.Selected);
                PendingMessages.ItemsSource = Model?.Selected?.PendingPrompts;
            }
        });
    }

    private bool IsNearBottom()
    {
        if (Scroller is null) return true;
        var extent = Scroller.ExtentHeight;
        var viewport = Scroller.ViewportHeight;
        var offset = Scroller.VerticalOffset;
        if (viewport <= 0) return true;
        if (extent <= viewport + 1) return true;
        return extent - (offset + viewport) < 40;
    }

    // Long chats render the newest page first; older pages load as the user scrolls up.
    private MessageTail<ChatMessage>? MessageSource(Conversation? conversation)
    {
        if (conversation is null)
        {
            _messageTail?.Dispose();
            _messageTail = null;
            return null;
        }
        if (_messageTail is null || !ReferenceEquals(_messageTail.Source, conversation.Messages))
        {
            _messageTail?.Dispose();
            _messageTail = new MessageTail<ChatMessage>(conversation.Messages);
        }
        return _messageTail;
    }

    private void OnScrollChanged(object sender, ScrollChangedEventArgs e)
    {
        if (!ReferenceEquals(e.OriginalSource, Scroller) || _loadingOlder || _messageTail is not { HasOlder: true } tail) return;
        var scrolledNearTop = e.VerticalChange < 0 && e.VerticalOffset < 200;
        var cannotScroll = e.ExtentHeight <= e.ViewportHeight && e.ViewportHeight > 0;
        if (!scrolledNearTop && !cannotScroll) return;
        _loadingOlder = true;
        var extent = Scroller.ExtentHeight;
        var offset = Scroller.VerticalOffset;
        tail.LoadOlder();
        // After layout: keep the message under the cursor in place while older ones appear above it.
        Dispatcher.BeginInvoke(new Action(() =>
        {
            Scroller.ScrollToVerticalOffset(offset + Scroller.ExtentHeight - extent);
            _loadingOlder = false;
        }), System.Windows.Threading.DispatcherPriority.Loaded);
    }

    private void TryScrollToEndIfNearBottom()
    {
        if (!IsNearBottom()) return;
        Dispatcher.BeginInvoke(new Action(() => Scroller.ScrollToEnd()), System.Windows.Threading.DispatcherPriority.Background);
    }

    private void OnMessagesChanged(object? sender, NotifyCollectionChangedEventArgs e)
    {
        if (e.NewItems is not null)
            foreach (ChatMessage m in e.NewItems)
            {
                m.PropertyChanged += OnMessagePropertyChanged;
                _observedMessageItems.Add(m);
            }
        if (e.OldItems is not null)
            foreach (ChatMessage m in e.OldItems)
            {
                m.PropertyChanged -= OnMessagePropertyChanged;
                _observedMessageItems.Remove(m);
            }
        if (e.Action == NotifyCollectionChangedAction.Reset)
        {
            foreach (var m in _observedMessageItems.ToList())
                m.PropertyChanged -= OnMessagePropertyChanged;
            _observedMessageItems.Clear();
            if (sender is System.Collections.IEnumerable enumerable)
                foreach (ChatMessage m in enumerable)
                {
                    m.PropertyChanged += OnMessagePropertyChanged;
                    _observedMessageItems.Add(m);
                }
        }
        Dispatcher.BeginInvoke(new Action(TryScrollToEndIfNearBottom), System.Windows.Threading.DispatcherPriority.Background);
    }

    private void OnPendingChanged(object? sender, NotifyCollectionChangedEventArgs e) =>
        Dispatcher.BeginInvoke(new Action(TryScrollToEndIfNearBottom), System.Windows.Threading.DispatcherPriority.Background);

    private void OnMessagePropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName is nameof(ChatMessage.Text) or nameof(ChatMessage.Streaming))
            Dispatcher.BeginInvoke(new Action(TryScrollToEndIfNearBottom), System.Windows.Threading.DispatcherPriority.Background);
    }

    private void ObserveConversation(Conversation? conversation)
    {
        if (ReferenceEquals(_observedConversation, conversation)) return;
        if (_observedMessages is not null)
        {
            _observedMessages.CollectionChanged -= OnMessagesChanged;
            _observedMessages = null;
        }
        if (_observedPending is not null)
        {
            _observedPending.CollectionChanged -= OnPendingChanged;
            _observedPending = null;
        }
        foreach (var m in _observedMessageItems)
            m.PropertyChanged -= OnMessagePropertyChanged;
        _observedMessageItems.Clear();
        _observedConversation = conversation;
        if (conversation is null) return;
        _observedMessages = conversation.Messages as INotifyCollectionChanged;
        if (_observedMessages is not null)
            _observedMessages.CollectionChanged += OnMessagesChanged;
        _observedPending = conversation.PendingPrompts as INotifyCollectionChanged;
        if (_observedPending is not null)
            _observedPending.CollectionChanged += OnPendingChanged;
        foreach (var m in conversation.Messages)
        {
            m.PropertyChanged += OnMessagePropertyChanged;
            _observedMessageItems.Add(m);
        }
    }

    private void Bind()
    {
        if (Model is null) return;
        ComposerAccessory.Slot = WellKnownSlot.ComposerAccessory;
        ComposerAccessory.Registry = Model.Host.Slots;
        var previousId = _observedConversation?.Id;
        var conversation = Model.Selected;
        // Same id but a new object = transcript just hydrated; also jump to the newest message.
        var switched = previousId != conversation?.Id || !ReferenceEquals(_observedConversation, conversation);
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
        VisionRejectButton.Content = Model.L("vision.notNow");
        VisionAllowButton.Content = Model.L("vision.downloadAndContinue");
        EmptyHint.Visibility = conversation is null ? Visibility.Visible : Visibility.Collapsed;
        EmptyHint.Text = Model.Bridge.Connection is null
            ? Model.L("conversation.emptyNoProvider")
            : Model.L("conversation.emptySidebar");
        Messages.ItemsSource = MessageSource(conversation);
        PendingMessages.ItemsSource = conversation?.PendingPrompts;
        DraftAttachments.ItemsSource = Model.DraftAttachments;
        PlanButton.IsChecked = Model.IsPlanMode;
        var pendingPlanId = conversation?.PendingPlanMessageId;
        // Only the shown conversation's flags matter; they are recomputed when another one is selected.
        foreach (var item in conversation?.Messages ?? Enumerable.Empty<ChatMessage>())
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
        RefreshModelPicker();
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
        var suggestion = Model.ActiveSkillSuggestions.Pending;
        SkillSuggestionBanner.Visibility = suggestion is not null ? Visibility.Visible : Visibility.Collapsed;
        if (suggestion is not null)
        {
            SkillSuggestionTitle.Text = $"Suggested skill: {suggestion.DraftName}";
            SkillSuggestionDescription.Text = suggestion.DraftDescription;
        }
        VoiceIntro.Visibility = Model.ShowsVoiceIntro ? Visibility.Visible : Visibility.Collapsed;
        VoiceIntroTitle.Text = Model.L("voice.intro.title");
        VoiceIntroBody.Text = Model.L("voice.intro.body");
        StartVoiceIntroButton.Content = Model.L("voice.intro.start");
        DismissVoiceIntroButton.ToolTip = Model.L("voice.intro.dismiss");
        DraftBox.IsEnabled = true;
        VoiceButton.IsEnabled = true;
        VoiceButton.Content = Model.IsVoiceRunning ? Model.L("conversation.stop") : Model.L("conversation.mic");
        VoiceButton.ToolTip = Model.IsVoiceRunning ? Model.L("conversation.stopVoice") : Model.L("conversation.startVoice");
        ObserveConversation(conversation);
        BindApproval();
        BindVision();
        BindQuestion();
        BindTerminal();
        if (switched && conversation is not null)
            Dispatcher.BeginInvoke(new Action(() => Scroller.ScrollToEnd()), System.Windows.Threading.DispatcherPriority.Background);
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
        var workspace = Model?.TerminalWorkspacePath;
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

        var workspace = Model?.TerminalWorkspacePath;
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

    private void BindVision()
    {
        var pending = Model?.Bridge.PendingVisionInstall;
        if (pending is not null && pending.ConversationId == Model!.SelectedConversationId)
        {
            VisionBar.Visibility = Visibility.Visible;
            VisionTitle.Text = Model.L("vision.installTitle");
            VisionReason.Text = Model.L(
                "vision.installReason",
                pending.Provider,
                ByteCount(pending.ModelBytes));
        }
        else
        {
            VisionBar.Visibility = Visibility.Collapsed;
        }
    }

    private static string ByteCount(long bytes)
    {
        var value = bytes;
        var units = new[] { "B", "KB", "MB", "GB" };
        var index = 0;
        while (value >= 1024 && index < units.Length - 1)
        {
            value /= 1024;
            index++;
        }
        return $"{value} {units[index]}";
    }

    private readonly List<Func<string>> _questionAnswers = [];
    private string? _boundQuestionId;

    private void BindQuestion()
    {
        var question = Model?.Bridge.PendingQuestion;
        if (question is not null
            && question.QuestionId == _boundQuestionId
            && question.SessionId == Model!.SelectedConversationId)
        {
            // Already rendered: rebuilding here would wipe what the user is typing.
            return;
        }

        QuestionOptions.Children.Clear();
        _questionAnswers.Clear();
        if (question is null || question.SessionId != Model!.SelectedConversationId)
        {
            _boundQuestionId = null;
            QuestionBar.Visibility = Visibility.Collapsed;
            return;
        }

        _boundQuestionId = question.QuestionId;

        QuestionBar.Visibility = Visibility.Visible;
        QuestionTitle.Text = Model.L("ask.title");
        QuestionSubmitButton.Content = Model.L("ask.submit");
        QuestionSkipButton.Content = Model.L("ask.skip");
        foreach (var item in question.Questions)
        {
            var block = new StackPanel { Margin = new Thickness(0, 0, 0, 10) };
            block.Children.Add(new TextBlock
            {
                Text = item.Header.ToUpperInvariant(),
                FontSize = 10,
                Opacity = 0.7,
            });
            block.Children.Add(new TextBlock { Text = item.Prompt, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 2, 0, 6) });

            var group = $"question-{item.Id}-{question.QuestionId}";
            var buttons = new List<RadioButton>();
            foreach (var option in item.Options)
            {
                var radio = new RadioButton { Content = option, GroupName = group, Margin = new Thickness(0, 0, 0, 4) };
                buttons.Add(radio);
                block.Children.Add(radio);
            }

            var custom = new TextBox { Margin = new Thickness(0, 4, 0, 0), TextWrapping = TextWrapping.Wrap, AcceptsReturn = true, Tag = Model.L("ask.customPlaceholder") };
            // A written answer always wins over the suggestions.
            custom.TextChanged += (_, _) =>
            {
                if (string.IsNullOrWhiteSpace(custom.Text)) return;
                foreach (var radio in buttons) radio.IsChecked = false;
            };
            block.Children.Add(new TextBlock { Text = Model.L("ask.customPlaceholder"), FontSize = 10, Opacity = 0.7, Margin = new Thickness(0, 4, 0, 0) });
            block.Children.Add(custom);
            QuestionOptions.Children.Add(block);
            _questionAnswers.Add(() => string.IsNullOrWhiteSpace(custom.Text)
                ? buttons.FirstOrDefault(radio => radio.IsChecked == true)?.Content as string ?? string.Empty
                : custom.Text.Trim());
        }
    }

    private async void OnQuestionSubmit(object sender, RoutedEventArgs e)
    {
        if (Model is null) return;
        var answers = _questionAnswers.Select(read => read()).ToList();
        await Model.Bridge.AnswerQuestionAsync(answers);
    }

    private async void OnQuestionSkip(object sender, RoutedEventArgs e)
    {
        if (Model is null) return;
        await Model.Bridge.AnswerQuestionAsync(null);
    }

    private void OnSend(object sender, RoutedEventArgs e)
    {
        Send(PromptMode.Queue);
    }

    private void OnModelChanged(object sender, SelectionChangedEventArgs e)
    {
        if (ModelList.SelectedItem is string model
            && Model is { } app
            && !string.Equals(model, app.SelectedModelID, StringComparison.Ordinal))
        {
            app.SetSelectedModel(model);
            ShowModelList(false);
            RefreshModelPicker();
        }
    }

    // Effort stops: "" (provider default) then the model's levels, low to high.
    private string[] EffortStops =>
        Model is null ? [""] : ["", .. Model.Router.Efforts(Model.SelectedModelID)];

    private string EffortLabel(string level) =>
        Model!.L(level.Length == 0 ? "modelPicker.effort.default" : $"modelPicker.effort.{level}");

    private static Brush ThemeBrush(string key) =>
        Application.Current.TryFindResource(key) as Brush ?? Brushes.Gray;

    private void RefreshModelPicker()
    {
        if (Model is null) return;
        var selected = Model.SelectedModelID;
        var hasEfforts = EffortStops.Length > 1;
        ModelPickerName.Text = selected.Length == 0 ? Model.L("modelPicker.selectModel") : selected;
        ModelPickerEffort.Text = hasEfforts ? EffortLabel(Model.Router.SelectedEffort) : "";
        EffortTitle.Text = (hasEfforts ? EffortLabel(Model.Router.SelectedEffort) : Model.L("modelPicker.effortUnsupported")) + "  ›";
        EffortTitle.Foreground = IsUltraEffort ? UltraBrush : ThemeBrush(hasEfforts ? "Accent" : "TextSecondary");
        EffortModelName.Text = selected;
        EffortResetButton.ToolTip = Model.L("modelPicker.reset");
        ModelListHeader.Text = "‹  " + (Model.Router.Models.Count == 0 ? Model.L("modelPicker.noModel") : Model.L("modelPicker.selectModel"));
        EffortTitleButton.ToolTip = Model.L("modelPicker.selectModel");
        if (!ReferenceEquals(ModelList.ItemsSource, Model.Router.Models)) ModelList.ItemsSource = Model.Router.Models;
        ModelList.SelectedItem = selected;
        EffortTrack.IsEnabled = hasEfforts;
        EffortTrack.Opacity = hasEfforts ? 1 : 0.45;
        DrawEffortTrack();
    }

    private void OnModelPopupOpened(object? sender, EventArgs e)
    {
        ShowModelList(false);
        RefreshModelPicker();
    }

    // Card shows only the selected model; its title swaps in the model list.
    private void ShowModelList(bool show)
    {
        ModelListPanel.Visibility = show ? Visibility.Visible : Visibility.Collapsed;
        EffortCard.Visibility = show ? Visibility.Collapsed : Visibility.Visible;
    }

    private void OnShowModels(object sender, RoutedEventArgs e) => ShowModelList(true);

    private void OnHideModels(object sender, RoutedEventArgs e) => ShowModelList(false);

    /// Top "max" level gets the Codex-style purple gradient track.
    private bool IsUltraEffort =>
        Model?.Router.SelectedEffort == "max" && EffortStops[^1] == "max";

    private static readonly LinearGradientBrush UltraBrush = new()
    {
        StartPoint = new Point(0, 0.5), EndPoint = new Point(1, 0.5),
        GradientStops =
        {
            new GradientStop(Color.FromRgb(64, 51, 191), 0),
            new GradientStop(Color.FromRgb(184, 153, 255), 0.6),
            new GradientStop(Color.FromRgb(77, 38, 179), 1),
        },
    };

    private void OnEffortTrackSized(object sender, SizeChangedEventArgs e) => DrawEffortTrack();

    private void OnEffortReset(object sender, RoutedEventArgs e)
    {
        Model?.SetEffort("");
        RefreshModelPicker();
    }

    // Codex-style discrete slider: filled accent track, stop dots, white knob.
    private const double EffortKnob = 26;

    private double EffortStep(int count) =>
        count > 1 ? Math.Max(EffortTrack.ActualWidth - EffortKnob - 4, 1) / (count - 1) : 0;

    private void DrawEffortTrack()
    {
        if (Model is null) return;
        var stops = EffortStops;
        var index = Math.Max(Array.IndexOf(stops, Model.Router.SelectedEffort), 0);
        var width = EffortTrack.ActualWidth;
        if (width <= 0) return;
        var step = EffortStep(stops.Length);
        var knobX = 2 + index * step;
        EffortTrack.Children.Clear();
        EffortTrack.Children.Add(new Border { Width = width, Height = 30, CornerRadius = new CornerRadius(15), Background = new SolidColorBrush(Color.FromArgb(28, 128, 128, 128)) });
        EffortTrack.Children.Add(new Border { Width = knobX + EffortKnob + 2, Height = 30, CornerRadius = new CornerRadius(15), Background = IsUltraEffort ? UltraBrush : ThemeBrush("Accent") });
        for (var i = 0; i < stops.Length; i++)
        {
            var dot = new System.Windows.Shapes.Ellipse
            {
                Width = 5, Height = 5,
                Fill = new SolidColorBrush(i <= index ? Color.FromArgb(140, 255, 255, 255) : Color.FromArgb(90, 128, 128, 128)),
            };
            Canvas.SetLeft(dot, 2 + i * step + EffortKnob / 2 - 2.5);
            Canvas.SetTop(dot, 12.5);
            EffortTrack.Children.Add(dot);
        }
        var knob = new System.Windows.Shapes.Ellipse
        {
            Width = EffortKnob, Height = EffortKnob, Fill = Brushes.White,
            Effect = new System.Windows.Media.Effects.DropShadowEffect { BlurRadius = 4, ShadowDepth = 1, Direction = 270, Opacity = 0.25 },
        };
        Canvas.SetLeft(knob, knobX);
        Canvas.SetTop(knob, 2);
        EffortTrack.Children.Add(knob);
    }

    private void OnEffortPointer(object sender, MouseEventArgs e)
    {
        if (Model is null || !EffortTrack.IsEnabled || e.LeftButton != MouseButtonState.Pressed) return;
        var stops = EffortStops;
        if (stops.Length < 2) return;
        var raw = (e.GetPosition(EffortTrack).X - 2 - EffortKnob / 2) / EffortStep(stops.Length);
        var next = stops[Math.Clamp((int)Math.Round(raw), 0, stops.Length - 1)];
        if (next == Model.Router.SelectedEffort) return;
        Model.SetEffort(next);
        RefreshModelPicker();
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

    private void OnStartVoiceIntro(object sender, RoutedEventArgs e)
    {
        Model?.DismissVoiceIntro();
        OnVoice(sender, e);
    }

    private void OnDismissVoiceIntro(object sender, RoutedEventArgs e) => Model?.DismissVoiceIntro();

    private void OnAcceptSkillSuggestion(object sender, RoutedEventArgs e)
    {
        if (Model?.ActiveSkillSuggestions.Pending is not { } suggestion) return;
        try { Model.AcceptSkillSuggestion(suggestion.DraftName, suggestion.DraftDescription); }
        catch { }
    }

    private void OnDismissSkillSuggestion(object sender, RoutedEventArgs e) => Model?.DismissSkillSuggestion();

    private void OnVoice(object sender, RoutedEventArgs e)
    {
        if (Model is not { } model) return;
        if (model.IsVoiceRunning)
        {
            StopVoiceInput();
            return;
        }
        model.DismissVoiceIntro();
        if (!model.IsVoiceReady)
        {
            VoiceStatus.Text = model.L("voice.status.notReady");
            VoiceStatus.Visibility = Visibility.Visible;
            if (Window.GetWindow(this) is MainWindow window) window.ShowSettings();
            return;
        }
        _ = StartVoiceInputAsync(model);
    }

    private async Task StartVoiceInputAsync(AppModel model)
    {
        try
        {
            await model.StartVoiceAsync();
            if (!ReferenceEquals(Model, model) || !model.IsVoiceRunning)
            {
                model.Voice.Cancel();
                return;
            }
            _activeVoiceSessionId = model.Voice.SessionId;
            var microphone = new WindowsMicrophoneCapture();
            microphone.DataAvailable += data => model.Voice.PushPcm16(data.Span);
            _microphone = microphone;
            microphone.Start();
            VoiceButton.Content = model.L("conversation.stop");
            VoiceButton.ToolTip = model.L("conversation.stopVoice");
            VoiceStatus.Text = model.L("conversation.listening");
            VoiceStatus.Visibility = Visibility.Visible;
        }
        catch (Exception error)
        {
            _microphone?.Dispose();
            _microphone = null;
            model.Voice.Cancel();
            ShowVoiceError(error);
        }
    }

    public void StopVoiceInput()
    {
        var microphone = _microphone;
        _microphone = null;
        microphone?.Dispose();
        if (Model is { } model && (microphone is not null || model.IsVoiceRunning))
            _ = FinishStopVoiceAsync(model);
    }

    private async Task FinishStopVoiceAsync(AppModel model)
    {
        try
        {
            await model.StopVoiceAsync();
            await Dispatcher.InvokeAsync(() =>
            {
                if (!ReferenceEquals(Model, model)) return;
                VoiceButton.Content = model.L("conversation.mic");
                VoiceButton.ToolTip = model.L("conversation.startVoice");
                VoiceStatus.Text = model.L("conversation.voiceStopped");
                VoiceStatus.Visibility = Visibility.Visible;
            });
        }
        catch (Exception error)
        {
            await Dispatcher.InvokeAsync(() => ShowVoiceError(error));
        }
    }

    private void OnVoiceTranscript(object? sender, VoiceTranscriptUpdate update)
    {
        Dispatcher.BeginInvoke(() =>
        {
            if (Model is not { } model
                || !ReferenceEquals(model.Voice, sender)
                || update.SessionId != _activeVoiceSessionId) return;
            if (update.IsFinal) AppendVoiceText(update.Text);
            else
            {
                VoiceStatus.Text = update.Text;
                VoiceStatus.Visibility = Visibility.Visible;
            }
        });
    }

    private void AppendVoiceText(string text)
    {
        text = text.Trim();
        if (text.Length == 0) return;
        var separator = string.IsNullOrWhiteSpace(DraftBox.Text) ? "" : " ";
        DraftBox.AppendText(separator + text);
        DraftBox.CaretIndex = DraftBox.Text.Length;
        DraftBox.ScrollToEnd();
        if (Model is { } model)
        {
            model.Draft = DraftBox.Text;
            VoiceStatus.Text = model.L("conversation.heard", text);
        }
        VoiceStatus.Visibility = Visibility.Visible;
    }

    private void OnVoiceError(object? sender, Exception error)
    {
        Dispatcher.BeginInvoke(() =>
        {
            if (Model is { } model && ReferenceEquals(model.Voice, sender)) ShowVoiceError(error);
        });
    }

    private void ShowVoiceError(Exception error)
    {
        VoiceButton.Content = Model?.L("conversation.mic") ?? "Mic";
        VoiceButton.ToolTip = Model?.L("conversation.startVoice") ?? "Start voice input";
        VoiceStatus.Text = Model?.L("voice.error", error.Message) ?? $"Voice input error: {error.Message}";
        VoiceStatus.Visibility = Visibility.Visible;
    }

    private async void Send(PromptMode mode)
    {
        if (Model is null) return;
        StopVoiceInput();
        if (Model.IsVoiceRunning)
        {
            try { await Model.StopVoiceAsync(); }
            catch (Exception error) { ShowVoiceError(error); return; }
        }
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

    private void OnCopyMessage(object sender, RoutedEventArgs e)
    {
        if (sender is Button { Tag: ChatMessage message })
        {
            try { Clipboard.SetText(message.Text ?? ""); } catch (System.Runtime.InteropServices.ExternalException) { }
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

    private async void OnVisionReject(object sender, RoutedEventArgs e)
    {
        if (Model is not null) await Model.Bridge.AnswerVisionInstallAsync(false);
    }

    private async void OnVisionAllow(object sender, RoutedEventArgs e)
    {
        if (Model is not null) await Model.Bridge.AnswerVisionInstallAsync(true);
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

public sealed class ContextRootLabel : IValueConverter
{
    public static readonly ContextRootLabel Instance = new();

    public object Convert(object value, Type targetType, object parameter, CultureInfo culture)
    {
        var count = value is System.Collections.ICollection collection ? collection.Count : 0;
        return count == 0 ? "" : $"📎 Chat context · {count} root{(count == 1 ? "" : "s")}";
    }

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

public sealed class MessageActionsVisibility : IValueConverter
{
    public static readonly MessageActionsVisibility Instance = new();
    public object Convert(object value, Type targetType, object parameter, CultureInfo culture) =>
        value is ChatMessage { Streaming: false, Kind: ChatKind.User or ChatKind.Assistant or ChatKind.Plan }
            ? Visibility.Visible : Visibility.Collapsed;
    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) => Binding.DoNothing;
}

public sealed class RelativeTime : IValueConverter
{
    public static readonly RelativeTime Instance = new();
    public object Convert(object value, Type targetType, object parameter, CultureInfo culture)
    {
        if (value is not DateTimeOffset at) return "";
        var d = DateTimeOffset.Now - at;
        return d.TotalMinutes < 1 ? "now"
            : d.TotalHours < 1 ? $"{(int)d.TotalMinutes} min ago"
            : d.TotalDays < 1 ? $"{(int)d.TotalHours} h ago"
            : at.ToLocalTime().ToString("g", culture);
    }
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

public sealed class ChangedFileLabel : IValueConverter
{
    public static readonly ChangedFileLabel Instance = new();

    public object Convert(object value, Type targetType, object parameter, CultureInfo culture) => value is ChangedFile file
        ? $"{file.Operation switch { ChangedFileOperation.Added => "＋", ChangedFileOperation.Modified => "✎", _ => "−" }} {LocalizationService.Current.Get(file.Operation switch
        {
            ChangedFileOperation.Added => "conversation.fileAdded",
            ChangedFileOperation.Modified => "conversation.fileModified",
            _ => "conversation.fileDeleted",
        })}: {file.Path}"
        : "";

    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) => Binding.DoNothing;
}

public sealed class RunSummaryVisibility : IValueConverter
{
    public static readonly RunSummaryVisibility Instance = new();
    public object Convert(object value, Type targetType, object parameter, CultureInfo culture) =>
        value is ChatMessage message && message.Summary is not null ? Visibility.Visible : Visibility.Collapsed;
    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) => Binding.DoNothing;
}

public sealed class RunSummaryLabel : IValueConverter
{
    public static readonly RunSummaryLabel Instance = new();
    public object Convert(object value, Type targetType, object parameter, CultureInfo culture)
    {
        if (value is not ChatMessage { Summary: { } summary }) return "";
        var files = LocalizationService.Current.Get("conversation.filesSummary", summary.AddedCount, summary.ModifiedCount, summary.DeletedCount);
        var test = summary.TestStatus == "not_reported" ? "" : $" · {LocalizationService.Current.Get("conversation.testStatus", summary.TestStatus)}";
        return $"{LocalizationService.Current.Get("conversation.runSummary")}: {files} · {summary.CleanupNote}{test}";
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

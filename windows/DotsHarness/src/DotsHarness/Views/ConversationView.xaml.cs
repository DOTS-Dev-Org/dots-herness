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
    private sealed record ModelPickerItem(string Model, string ProviderName, string ProviderKey);

    private TerminalSession? _terminal;
    private string? _terminalWorkspace;
    private readonly System.Windows.Threading.DispatcherTimer _workingTimer = new() { Interval = TimeSpan.FromSeconds(1) };
    private readonly System.Windows.Threading.DispatcherTimer _loadingAnimationTimer = new() { Interval = TimeSpan.FromMilliseconds(220) };
    private bool _composerLoadingAnimationVisible;
    private bool _leaseWaitingLoadingAnimationVisible;
    private int _loadingFrame;
    private static readonly BitmapImage[] LoadingFrames = Enumerable.Range(0, 4).Select(CreateLoadingFrame).ToArray();
    private Conversation? _observedConversation;
    private INotifyCollectionChanged? _observedMessages;
    private INotifyCollectionChanged? _observedPending;
    private ChatMessage? _observedTailMessage;
    private MessageTail<ChatMessage>? _messageTail;
    private bool _loadingOlder;
    private bool _followTranscriptTail = true;
    private int _modelChangeRevision;
    private int _modelBindScheduled;
    private int _messageLanguageRefreshPending;
    private int _scrollScheduled;
    private ChatMessage? _boundPlanMessage;
    private string? _boundGitWorkspace;
    private int _gitTick;
    private bool _queueExpanded;
    private bool _gitBarHidden;
    private readonly List<Button> _queueEditButtons = new();

    public ConversationView()
    {
        InitializeComponent();
        ModelList.ItemTemplate = CreateModelPickerItemTemplate();
        TerminalBox.InputReceived += OnTerminalInput;
        DataContextChanged += OnCtx;
        _workingTimer.Tick += (_, _) =>
        {
            BindWorkingIndicator();
            BindProviderLimitNotice(Model?.Selected);
            if (++_gitTick % 15 == 0)
            {
                BindGitBar();
                BindCacheResumeNotice();
            }
        };
        _loadingAnimationTimer.Tick += (_, _) =>
        {
            _loadingFrame = (_loadingFrame + 1) % LoadingFrames.Length;
            ApplyLoadingFrame();
        };
        DraftBox.TextChanged += (_, _) =>
        {
            UpdateQueueEditState();
            BindFollowUpSuggestion();
        };
        Scroller.ScrollChanged += OnScrollChanged;
        Scroller.SizeChanged += OnTranscriptSizeChanged;
        Loaded += (_, _) => { _workingTimer.Start(); Bind(); };
        Unloaded += (_, _) =>
        {
            _workingTimer.Stop();
            _loadingAnimationTimer.Stop();
            _composerLoadingAnimationVisible = false;
            _leaseWaitingLoadingAnimationVisible = false;
            ComposerLoadingAnimation.Visibility = Visibility.Collapsed;
            LeaseWaitingLoadingAnimation.Visibility = Visibility.Collapsed;
            LeaseWaitingLoadingAnimation.Source = null;
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
        if (e.PropertyName is nameof(AppModel.Language) or nameof(AppModel.IsRightToLeft))
            System.Threading.Interlocked.Exchange(ref _messageLanguageRefreshPending, 1);
        System.Threading.Interlocked.Increment(ref _modelChangeRevision);
        QueueModelBind();
    }

    private void QueueModelBind()
    {
        if (System.Threading.Interlocked.Exchange(ref _modelBindScheduled, 1) != 0) return;
        Dispatcher.BeginInvoke(new Action(DrainModelBind), System.Windows.Threading.DispatcherPriority.Background);
    }

    private void DrainModelBind()
    {
        var revision = System.Threading.Volatile.Read(ref _modelChangeRevision);
        try
        {
            Bind();
            if (System.Threading.Interlocked.Exchange(ref _messageLanguageRefreshPending, 0) != 0)
            {
                Messages.ItemsSource = null;
                PendingMessages.ItemsSource = null;
                Messages.ItemsSource = MessageSource(Model?.Selected);
                PendingMessages.ItemsSource = Model?.Selected?.PendingPrompts;
            }
        }
        finally
        {
            System.Threading.Interlocked.Exchange(ref _modelBindScheduled, 0);
            if (System.Threading.Volatile.Read(ref _modelChangeRevision) != revision)
                QueueModelBind();
        }
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
        if (!ReferenceEquals(e.OriginalSource, Scroller)) return;
        if (e.VerticalChange != 0)
            _followTranscriptTail = IsNearBottom();
        if (_loadingOlder) return;
        var scrolledNearTop = e.VerticalChange < 0 && e.VerticalOffset < 200;
        if (!scrolledNearTop) return;
        if (_messageTail is { HasOlder: true } tail)
        {
            _loadingOlder = true;
            var extent = Scroller.ExtentHeight;
            var offset = Scroller.VerticalOffset;
            tail.LoadOlder();
            Dispatcher.BeginInvoke(new Action(() =>
            {
                Scroller.ScrollToVerticalOffset(offset + Scroller.ExtentHeight - extent);
                _loadingOlder = false;
            }), System.Windows.Threading.DispatcherPriority.Loaded);
            return;
        }
        if (Model?.Bridge.Selected is not { HasOlderMessages: true } conversation) return;
        _loadingOlder = true;
        var storeExtent = Scroller.ExtentHeight;
        var storeOffset = Scroller.VerticalOffset;
        _ = LoadOlderFromStoreAsync(conversation, storeOffset, storeExtent);
    }

    private async Task LoadOlderFromStoreAsync(Conversation conversation, double offset, double extent)
    {
        try
        {
            if (Model is null || !await Model.Bridge.LoadOlderMessagesAsync(conversation.Id)) return;
            _messageTail?.LoadOlder();
            Bind();
            Dispatcher.BeginInvoke(new Action(() =>
                Scroller.ScrollToVerticalOffset(offset + Scroller.ExtentHeight - extent)),
                System.Windows.Threading.DispatcherPriority.Loaded);
        }
        finally { _loadingOlder = false; }
    }

    private void TryScrollToEndIfFollowing()
    {
        if (_followTranscriptTail) Scroller.ScrollToEnd();
    }

    private void QueueScrollToEndIfFollowing()
    {
        if (System.Threading.Interlocked.Exchange(ref _scrollScheduled, 1) != 0) return;
        Dispatcher.BeginInvoke(new Action(() =>
        {
            System.Threading.Interlocked.Exchange(ref _scrollScheduled, 0);
            TryScrollToEndIfFollowing();
        }), System.Windows.Threading.DispatcherPriority.Background);
    }

    private void QueueScrollToEndAfterLayout()
    {
        Dispatcher.BeginInvoke(new Action(() =>
        {
            if (_followTranscriptTail) Scroller.ScrollToEnd();
        }), System.Windows.Threading.DispatcherPriority.Loaded);
    }

    // Keep the latest content visible after layout only while the reader follows the tail.
    private void OnTranscriptSizeChanged(object sender, SizeChangedEventArgs e)
    {
        if (e.NewSize.Height < e.PreviousSize.Height) QueueScrollToEndAfterLayout();
    }

    private void OnMessagesChanged(object? sender, NotifyCollectionChangedEventArgs e)
    {
        ObserveTailMessage(_observedConversation);
        Dispatcher.BeginInvoke(new Action(BindPlan));
        QueueScrollToEndIfFollowing();
    }

    private void OnPendingChanged(object? sender, NotifyCollectionChangedEventArgs e)
    {
        Dispatcher.BeginInvoke(new Action(BindQueue));
        QueueScrollToEndIfFollowing();
    }

    private void OnMessagePropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(ChatMessage.ChangedFiles))
        {
            // The changed-files card is attached after the response and can add
            // enough height to hide its own footer unless we follow it after layout.
            QueueScrollToEndAfterLayout();
        }
        else if (e.PropertyName is nameof(ChatMessage.Text) or nameof(ChatMessage.Streaming))
        {
            if (e.PropertyName == nameof(ChatMessage.Streaming) && _observedTailMessage?.Streaming == false)
                Dispatcher.BeginInvoke(new Action(BindPlan));
            QueueScrollToEndIfFollowing();
        }
        else if (e.PropertyName == nameof(ChatMessage.RawToolOutput))
            Dispatcher.BeginInvoke(new Action(BindPlan));
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
        if (_observedTailMessage is not null)
        {
            _observedTailMessage.PropertyChanged -= OnMessagePropertyChanged;
            _observedTailMessage = null;
        }
        _observedConversation = conversation;
        if (conversation is null) return;
        _observedMessages = conversation.Messages as INotifyCollectionChanged;
        if (_observedMessages is not null)
            _observedMessages.CollectionChanged += OnMessagesChanged;
        _observedPending = conversation.PendingPrompts as INotifyCollectionChanged;
        if (_observedPending is not null)
            _observedPending.CollectionChanged += OnPendingChanged;
        ObserveTailMessage(conversation);
    }

    private void ObserveTailMessage(Conversation? conversation)
    {
        var latest = conversation?.Messages.LastOrDefault();
        if (ReferenceEquals(_observedTailMessage, latest)) return;
        if (_observedTailMessage is not null)
            _observedTailMessage.PropertyChanged -= OnMessagePropertyChanged;
        _observedTailMessage = latest;
        if (_observedTailMessage is not null)
            _observedTailMessage.PropertyChanged += OnMessagePropertyChanged;
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
        var contextInputTokens = conversation?.LastContextInputTokens ?? 0;
        var contextOutputTokens = conversation?.LastContextOutputTokens ?? 0;
        var contextTokens = contextInputTokens + contextOutputTokens;
        var contextUsageIsEstimated = conversation is null
            || conversation.LastContextInputTokensIsEstimated
            || conversation.LastContextOutputTokens is null;
        var contextModel = Model.Router.SelectedModelID;
        string? contextProvider = null;
        if (conversation?.ContextRouteIdentity is { } contextRoute)
        {
            var parts = contextRoute.Split('|');
            if (parts.Length >= 4)
            {
                contextProvider = parts[1];
                contextModel = parts[^1];
            }
        }
        var contextWindow = contextProvider is not null
            && RouterCatalog.DocumentedContextWindow(contextProvider, contextModel) is null
            && conversation is { ContextWindow: > 0 } savedConversation
                ? savedConversation.ContextWindow
                : Model.Router.ContextWindowFor(contextModel, contextProvider);
        CacheUsageButton.Content = Model.L("usage.context.button");
        CacheUsageButton.ToolTip = Model.L("usage.context.tooltip");
        CacheUsageButton.Visibility = conversation?.CacheSession?.Events.Count > 0 || contextTokens > 0
            ? Visibility.Visible
            : Visibility.Collapsed;
        ContextUsageSummary.Text = contextWindow > 0 && contextTokens > 0
            ? $"{(contextUsageIsEstimated ? "≈" : "")}{FormatTokenCount(contextTokens)} / {FormatTokenCount(contextWindow)} ({((double)contextTokens / contextWindow).ToString("P0", CultureInfo.CurrentCulture)})"
            : "—";
        ContextUsageProgress.Visibility = contextWindow > 0 ? Visibility.Visible : Visibility.Collapsed;
        ContextUsageProgress.Value = contextWindow > 0 ? Math.Clamp((double)contextTokens / contextWindow, 0, 1) : 0;
        BindCacheResumeNotice();
        BindProviderLimitNotice(conversation);
        BindWorkingIndicator();
        TerminalButton.Content = Model.L("conversation.terminal");
        ModelPicker.ToolTip = Model.L("conversation.model");
        DropHint.Text = Model.L("conversation.dropFiles");
        PlanButton.Content = "💡 " + Model.L("conversation.planMode");
        PlanButton.ToolTip = Model.L("conversation.planMode");
        WorkLocationButton.Content = "⌖ " + Model.L("workLocation.title") + ": " + Model.WorkLocationLabel;
        WorkLocationButton.ToolTip = Model.L("workLocation.help");
        WorkLocationButton.IsEnabled = !Model.Bridge.AnyRunBusy;
        System.Windows.Automation.AutomationProperties.SetName(PlanButton, Model.L("conversation.planMode"));
        TerminalTitle.Text = Model.L("conversation.terminal");
        CloseTerminalButton.ToolTip = Model.L("conversation.closeTerminal");
        RejectButton.Content = Model.L("conversation.reject");
        AllowButton.Content = Model.L("conversation.allowOnce");
        VisionRejectButton.Content = Model.L("vision.notNow");
        VisionAllowButton.Content = Model.L("vision.downloadAndContinue");
        EmptyHint.Visibility = conversation is null ? Visibility.Visible : Visibility.Collapsed;
        EmptyHint.Text = !Model.Router.HasActiveRoute
            ? Model.L("conversation.emptyNoProvider")
            : Model.L("conversation.emptySidebar");
        Messages.ItemsSource = MessageSource(conversation);
        PendingMessages.ItemsSource = conversation?.PendingPrompts;
        DraftAttachments.ItemsSource = Model.DraftAttachments;
        PlanButton.IsChecked = Model.IsPlanMode;
        var pendingPlanId = conversation?.PendingPlanMessageId;
        var pendingPlan = pendingPlanId is null
            ? null
            : conversation?.Messages.FirstOrDefault(item => item.Kind == ChatKind.Plan && item.Id == pendingPlanId);
        if (!ReferenceEquals(_boundPlanMessage, pendingPlan))
        {
            if (_boundPlanMessage is not null)
            {
                _boundPlanMessage.IsPendingPlan = false;
                _boundPlanMessage.IsApplyingPlan = false;
                _boundPlanMessage.CanApplyPlan = false;
            }
            _boundPlanMessage = pendingPlan;
        }
        if (pendingPlan is not null && conversation is not null)
        {
            pendingPlan.IsPendingPlan = true;
            pendingPlan.IsApplyingPlan = conversation.Running;
            pendingPlan.CanApplyPlan = !conversation.Running
                && conversation.Continuation is null
                && Model.Bridge.CanSendSelectedConversation
                && Model.Router.HasActiveRoute;
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
        CancelPlanButton.Content = Model.L("conversation.cancelPlan");
        CancelPlanButton.ToolTip = Model.L("conversation.cancelPlanHelp");
        CancelPlanButton.Visibility = conversation?.PlanGateActive == true
            ? Visibility.Visible
            : Visibility.Collapsed;
        SendButton.Content = canContinue ? Model.L("conversation.continue") : Model.L("conversation.send");
        var projectLocationAvailable = Model.CanSendFromComposer;
        var missingProjectPath = Model.IsRemoteWorkLocation ? null : Model.MissingProjectPath;
        ProjectMissingBanner.Visibility = missingProjectPath is null ? Visibility.Collapsed : Visibility.Visible;
        ProjectMissingText.Text = missingProjectPath is null ? "" : Model.L("project.missing.readOnly");
        LocateProjectButton.Content = Model.L("project.missing.locate");
        SendButton.IsEnabled = projectLocationAvailable;
        if (!DraftBox.IsFocused)
        {
            DraftBox.Text = Model.Draft;
        }
        var suggestion = Model.ActiveSkillSuggestions.Pending;
        SkillSuggestionBanner.Visibility = suggestion is not null ? Visibility.Visible : Visibility.Collapsed;
        if (suggestion is not null)
        {
            SkillSuggestionTitle.Text = suggestion.CardTitle;
            SkillSuggestionDescription.Text = suggestion.CardDescription;
        }
        DismissSkillSuggestionButton.Content = Model.L("skill.suggestion.dismiss");
        AcceptSkillSuggestionButton.Content = Model.L("skill.suggestion.create");
        AcceptFollowUpSuggestionButton.Content = Model.L("access.accept");
        DismissFollowUpSuggestionButton.Content = Model.L("vision.notNow");
        BindFollowUpSuggestion();
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
        BindWorkspaceConflict();
        BindVision();
        BindContextOverflow();
        BindQuestion();
        BindQueue();
        BindPlan();
        var gitWorkspace = Model.WorkspacePath;
        if (!string.Equals(_boundGitWorkspace, gitWorkspace, StringComparison.Ordinal))
        {
            _boundGitWorkspace = gitWorkspace;
            BindGitBar();
        }
        BindTerminal();
        if (switched && conversation is not null)
        {
            _followTranscriptTail = true;
            Dispatcher.BeginInvoke(new Action(() =>
            {
                if (_followTranscriptTail) Scroller.ScrollToEnd();
            }), System.Windows.Threading.DispatcherPriority.Background);
        }
    }

    private string BuildContextComposition(Conversation? conversation)
    {
        var model = Model;
        if (model is null || conversation is null) return string.Empty;
        if (conversation.LastContextInputTokens <= 0 && conversation.LastContextOutputTokens is null)
            return string.Empty;
        var composition = NativeContextUsageComposition.Create(
            conversation.ModelContext,
            conversation.CacheSession?.Catalog ?? []);
        var culture = CultureInfo.CurrentCulture;
        var inputTokens = Math.Max(0, conversation.LastContextInputTokens);
        var outputTokens = Math.Max(0, conversation.LastContextOutputTokens ?? 0);
        var inputEstimated = conversation.LastContextInputTokensIsEstimated;
        var lines = new List<string> { model.L("usage.context.latestRequest") };
        if (inputTokens > 0)
            lines.Add($"{model.L(inputEstimated ? "usage.context.estimatedInput" : "usage.context.input")}: {(inputEstimated ? "≈" : "")}{FormatTokenCount(inputTokens)}");
        lines.Add($"{model.L("usage.context.output")}: {(conversation.LastContextOutputTokens is > 0 ? FormatTokenCount(outputTokens) : model.L("usage.context.notReported"))}");

        var estimates = new (string Key, int Tokens)[]
        {
            ("usage.context.conversation", composition.ConversationTokens),
            ("usage.context.toolDefinitions", composition.NativeToolDefinitionTokens),
            ("usage.context.mcpDefinitions", composition.McpToolDefinitionTokens),
            ("usage.context.systemPrompt", composition.SystemPromptTokens),
        };
        var estimatedTotal = estimates.Sum(value => Math.Max(0, value.Tokens));
        if (estimatedTotal > 0 && inputTokens > 0)
        {
            lines.Add(model.L("usage.context.estimatedBreakdown"));
            var positiveEstimates = estimates.Where(value => value.Tokens > 0).ToArray();
            var allocated = 0;
            for (var index = 0; index < positiveEstimates.Length; index++)
            {
                var estimate = positiveEstimates[index];
                var remaining = Math.Max(0, inputTokens - allocated);
                var scaled = index == positiveEstimates.Length - 1
                    ? remaining
                    : (int)Math.Round((double)estimate.Tokens / estimatedTotal * inputTokens, MidpointRounding.AwayFromZero);
                var tokens = Math.Min(remaining, Math.Max(0, scaled));
                allocated += tokens;
                if (tokens <= 0) continue;
                var percentage = ((double)tokens / inputTokens).ToString("P0", culture);
                lines.Add($"{model.L(estimate.Key)}: ≈{FormatTokenCount(tokens)} ({percentage})");
            }
        }
        return string.Join(Environment.NewLine, lines);
    }

    private string FormatTokenCount(int tokens)
    {
        var count = tokens < 1_000
            ? tokens.ToString("N0", CultureInfo.CurrentCulture)
            : tokens < 1_000_000
                ? $"{tokens / 1_000.0:0.0}K"
                : $"{tokens / 1_000_000.0:0.0}M";
        return Model?.L("conversation.processedTokensCount", count) ?? count;
    }

    private NativeCacheSummary? CacheSummaryFor(Conversation? conversation)
    {
        var session = conversation?.CacheSession;
        if (session is null) return null;
        var routeFingerprint = session.Events.OrderBy(value => value.Timestamp)
            .LastOrDefault(value => !string.IsNullOrWhiteSpace(value.RouteFingerprint))?.RouteFingerprint;
        if (routeFingerprint is null) return session.Summary();
        var events = Model!.Bridge.Conversations
            .SelectMany(item => item.CacheSession?.Events ?? [])
            .Where(value => string.Equals(value.RouteFingerprint, routeFingerprint, StringComparison.Ordinal))
            .OrderBy(value => value.Timestamp)
            .TakeLast(100)
            .ToArray();
        return events.Length == 0 ? session.Summary() : NativeCacheSummary.From(events);
    }

    private string BuildCacheDetails(NativeCacheSummary? cache)
    {
        var model = Model;
        if (model is null) return string.Empty;
        if (cache is null || cache.SampleCount == 0) return model.L("usage.context.notAvailable");
        var culture = CultureInfo.CurrentCulture;
        string Number(long value) => value.ToString("N0", culture);
        string Percent(double? value) => value is { } rate ? rate.ToString("P0", culture) : "—";
        var lines = new List<string>();
        if (cache.MeasuredTotalInputTokens > 0)
            lines.Add($"{model.L("usage.context.cacheHit")}: {Percent(cache.CacheHitRate)}");
        lines.Add(model.L("usage.context.cacheReuse", Percent(cache.ReuseRate), Number(cache.ReusedTokens), Number(cache.EligibleTokens)));
        lines.Add(model.L("usage.context.cacheCoverage", Percent(cache.ReuseMeasurementCoverage), cache.ExactReuseCount, cache.CandidateCount));
        lines.Add(model.L("usage.context.cacheStatus", cache.ColdCount, cache.ExpiredCount, cache.ChangedCount));
        lines.Add(model.L("usage.context.cacheWrite", Number(cache.CacheWriteTokens)));
        lines.Add(model.L("usage.context.freshInput", Number(cache.FreshInputTokens)));
        lines.Add(model.L("usage.context.reuseUnknown", cache.UnknownReuseRequestCount, cache.CandidateCount));
        if (cache.AverageLatencyMilliseconds is { } latency)
            lines.Add(model.L("usage.context.latency", latency.ToString("N0", culture) + " ms"));
        if (cache.AveragePrepareMilliseconds is { } prepare)
            lines.Add(model.L("usage.context.prepare", prepare.ToString("N0", culture) + " ms"));
        if (cache.LostTokensByReason.OrderByDescending(pair => pair.Value).FirstOrDefault() is { Key: { } reason, Value: > 0 } loss)
            lines.Add(model.L("usage.context.cacheLoss", reason, Number(loss.Value)));
        return string.Join(Environment.NewLine, lines);
    }

    private void OnCacheUsageOpened(object sender, RoutedEventArgs e) => BindCacheUsageDetails();

    private void BindCacheUsageDetails()
    {
        var conversation = Model?.Selected;
        ContextUsageBreakdown.Text = BuildContextComposition(conversation);
        CacheUsageDetails.Text = BuildCacheDetails(CacheSummaryFor(conversation));
    }

    private void BindCacheResumeNotice()
    {
        var model = Model;
        var conversation = model?.Selected;
        var routeMatches = model is not null && conversation is not null
            && !string.IsNullOrEmpty(conversation.ContextRouteIdentity)
            && string.Equals(
                conversation.ContextRouteIdentity,
                model.Router.ContextRouteIdentityFor(model.SelectedModelID, conversation.StickyAccountId),
                StringComparison.Ordinal);
        var expiredTokens = routeMatches
            ? conversation?.CacheSession?.ExpiredLargePrefixTokens(DateTimeOffset.UtcNow,
                others: model!.Conversations.Select(item => item.CacheSession).OfType<NativeCacheSession>())
            : null;
        // A local model costs nothing; the loss is prefill time.
        var localCache = expiredTokens is not null && conversation?.CacheSession?.Events.LastOrDefault()?.Local == true;
        // Every line names a reason the next request costs more than the last one.
        var notices = new List<string>();
        if (model is not null && conversation is not null)
        {
            // The route ends with the model; any other difference is the serving account.
            var routeChanged = !routeMatches && !string.IsNullOrEmpty(conversation.ContextRouteIdentity) && conversation.Messages.Count > 0;
            var modelChanged = routeChanged && !string.Equals(
                conversation.ContextRouteIdentity.Split('|')[^1], model.SelectedModelID, StringComparison.Ordinal);
            if (conversation.AccountSwitched || (routeChanged && !modelChanged))
                notices.Add(model.L("conversation.accountSwitched.notice"));
            if (modelChanged) notices.Add(model.L("conversation.modelSwitched.notice"));
            // Same 90% mark at which the conversation compacts.
            var routeParts = conversation.ContextRouteIdentity?.Split('|') ?? Array.Empty<string>();
            var window = routeParts.Length >= 4
                ? model.Router.ContextWindowFor(routeParts[^1], routeParts[1])
                : model.Router.ContextWindowFor(model.SelectedModelID);
            if (localCache) notices.Add(model.L("conversation.cacheLocal.notice"));
            else if (expiredTokens is not null) notices.Add(model.L("conversation.cacheExpired.notice"));
            else if (window > 0 && conversation.LastContextInputTokens > window * 0.9)
                notices.Add(model.L("conversation.contextFull.notice"));
        }

        CacheResumeWarning.Visibility = notices.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
        CacheResumeInfoButton.Visibility = expiredTokens is null || localCache ? Visibility.Collapsed : Visibility.Visible;
        CacheResumeText.Text = string.Join("\n", notices);
        CacheResumeInfoText.Text = model?.L("conversation.cacheExpired.explanation") ?? "";
        CacheResumeInfoButton.ToolTip = model?.L("conversation.cacheExpired.infoTitle");
        if (expiredTokens is null) CacheResumeInfoPopup.IsOpen = false;
    }

    private void BindProviderLimitNotice(Conversation? conversation)
    {
        var model = Model;
        if (model is null || conversation?.CanContinue != true
            || conversation.Continuation is not { Reason: ContinuationPauseReason.ProviderLimit } continuation)
        {
            ProviderLimitWarning.Visibility = Visibility.Collapsed;
            ProviderLimitTitle.Text = "";
            ProviderLimitCountdown.Text = "";
            return;
        }

        ProviderLimitTitle.Text = model.L("agent.providerLimitTitle");
        var target = string.Join(" / ", new[] { continuation.Provider, continuation.Model }
            .Where(value => !string.IsNullOrWhiteSpace(value)));
        var resetText = continuation.RetryAt is { } retryAt
            ? model.L("usage.resetsIn", FormatLimitCountdown(retryAt, DateTimeOffset.UtcNow))
            : model.L("usage.noLimitInfo");
        ProviderLimitCountdown.Text = string.IsNullOrEmpty(target)
            ? resetText
            : $"{target} · {resetText}";
        ProviderLimitWarning.Visibility = Visibility.Visible;
        System.Windows.Automation.AutomationProperties.SetName(
            ProviderLimitWarning,
            $"{ProviderLimitTitle.Text}. {ProviderLimitCountdown.Text}");
    }

    private static string FormatLimitCountdown(DateTimeOffset retryAt, DateTimeOffset now)
    {
        var totalSeconds = Math.Max(0L, (long)Math.Ceiling((retryAt - now).TotalSeconds));
        if (totalSeconds <= 10 * 60)
        {
            return $"{totalSeconds} s";
        }

        var totalMinutes = totalSeconds / 60;
        var hours = totalMinutes / 60;
        var minutes = totalMinutes % 60;
        return hours > 0
            ? string.Format(CultureInfo.InvariantCulture, "{0} h {1} min", hours, minutes)
            : string.Format(CultureInfo.InvariantCulture, "{0} min", totalMinutes);
    }

    private void OnCacheResumeInfo(object sender, RoutedEventArgs e)
    {
        CacheResumeInfoPopup.IsOpen = !CacheResumeInfoPopup.IsOpen;
    }

    private void BindWorkingIndicator()
    {
        var conversation = Model?.Selected;
        SetComposerLoadingAnimationVisible(conversation?.Running == true);
        if (conversation?.Running != true || conversation.RunStartedAt is not { } started)
        {
            WorkingIndicator.Visibility = Visibility.Collapsed;
            WorkingIndicator.Text = "";
            return;
        }

        var elapsed = FormatElapsed(DateTimeOffset.UtcNow - started);
        var skills = Model!.Bridge.ActiveUsedSkills;
        var last = conversation.Messages.LastOrDefault();
        var status = LiveStatus(elapsed, last?.Kind == ChatKind.Tool);
        // A long build or test shows its own clock, so a quiet model never looks like a hung app.
        if (last is { Kind: ChatKind.Tool, RawToolOutput: null } && DateTimeOffset.UtcNow - last.CreatedAt >= TimeSpan.FromSeconds(10))
            status += " · " + FormatElapsed(DateTimeOffset.UtcNow - last.CreatedAt);
        WorkingIndicator.Text = skills.Count == 0
            ? status
            : $"{status} · {string.Join(", ", skills)}";
        WorkingIndicator.Visibility = Visibility.Visible;
        System.Windows.Automation.AutomationProperties.SetName(WorkingIndicator, WorkingIndicator.Text);
    }

    private void SetComposerLoadingAnimationVisible(bool visible)
    {
        _composerLoadingAnimationVisible = visible;
        ComposerLoadingAnimation.Visibility = visible ? Visibility.Visible : Visibility.Collapsed;
        RefreshLoadingAnimation();
    }

    private void SetLeaseWaitingLoadingAnimationVisible(bool visible)
    {
        _leaseWaitingLoadingAnimationVisible = visible;
        LeaseWaitingLoadingAnimation.Visibility = visible ? Visibility.Visible : Visibility.Collapsed;
        RefreshLoadingAnimation();
    }

    private void RefreshLoadingAnimation()
    {
        var shouldAnimate = _composerLoadingAnimationVisible || _leaseWaitingLoadingAnimationVisible;
        if (shouldAnimate && !_loadingAnimationTimer.IsEnabled)
        {
            _loadingFrame = 0;
            ApplyLoadingFrame();
            _loadingAnimationTimer.Start();
        }
        else if (!shouldAnimate)
        {
            _loadingAnimationTimer.Stop();
        }
    }

    private void ApplyLoadingFrame()
    {
        var frame = LoadingFrames[_loadingFrame];
        if (_composerLoadingAnimationVisible) ComposerLoadingAnimation.Source = frame;
        if (_leaseWaitingLoadingAnimationVisible) LeaseWaitingLoadingAnimation.Source = frame;
    }

    private static BitmapImage CreateLoadingFrame(int frame)
    {
        var image = new BitmapImage();
        image.BeginInit();
        image.UriSource = new Uri($"pack://application:,,,/DotsHarness;component/Resources/HerNessLoaderFrame{frame}.png", UriKind.Absolute);
        image.CacheOption = BitmapCacheOption.OnLoad;
        image.EndInit();
        image.Freeze();
        return image;
    }

    /// <summary>"2m 16s · 1.4K tokens · Running tools…"</summary>
    private string LiveStatus(string elapsed, bool toolsRunning)
    {
        var parts = new List<string> { elapsed };
        var tokens = Model!.Bridge.ActiveRunTokens;
        if (tokens > 0)
            parts.Add($"{(Model.Bridge.ActiveRunTokensEstimated ? "≈" : "")}{FormatTokenCount(tokens)}");
        parts.Add(Model.L(toolsRunning ? "conversation.runningTools" : "conversation.thinkingPhase"));
        return string.Join(" · ", parts);
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
        TerminalButton.IsEnabled = !string.IsNullOrWhiteSpace(workspace)
            && (Model?.IsRemoteWorkLocation == true || Directory.Exists(workspace));
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
        if (string.IsNullOrWhiteSpace(workspace)
            || (Model?.IsRemoteWorkLocation != true && !Directory.Exists(workspace))) return;

        _terminalWorkspace = workspace;
        _terminal = new TerminalSession(workspace, Model?.RemoteTarget);
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
            ApprovalReason.Text = (approval.Reason ?? "") + (string.IsNullOrWhiteSpace(approval.InputPreview)
                ? ""
                : "\n\n" + Model.L("conversation.toolInput") + "\n" + approval.InputPreview);
        }
        else
        {
            ApprovalBar.Visibility = Visibility.Collapsed;
        }
    }

    private void BindWorkspaceConflict()
    {
        var model = Model;
        var conflict = model?.Bridge.PendingConflict;
        if (conflict is not null && conflict.ConversationId == model!.SelectedConversationId)
        {
            ConflictBar.Visibility = Visibility.Visible;
            LeaseWaitingBar.Visibility = Visibility.Collapsed;
            SetLeaseWaitingLoadingAnimationVisible(false);
            ConflictTitle.Text = model.L("conflict.banner.title");
            ConflictBody.Text = model.L("conflict.banner.body", conflict.Path, conflict.HolderTitle, conflict.HeldSeconds);
            ConflictKeepWaitingButton.Content = model.L("conflict.banner.keepWaiting");
            ConflictStopHolderButton.Content = model.L("conflict.banner.stopHolder", conflict.HolderTitle);
            ConflictStopAllButton.Content = model.L("conflict.banner.stopAllOthers");
            ConflictStopAllButton.Visibility = conflict.OtherRunningConversations > 1
                ? Visibility.Visible
                : Visibility.Collapsed;
            ConflictSkipButton.Content = model.L("conflict.banner.skip");
            return;
        }

        ConflictBar.Visibility = Visibility.Collapsed;
        var waiting = model?.Bridge.WaitingOnLease;
        LeaseWaitingBar.Visibility = waiting is null ? Visibility.Collapsed : Visibility.Visible;
        SetLeaseWaitingLoadingAnimationVisible(waiting is not null);
        LeaseWaitingText.Text = waiting is null
            ? ""
            : model!.L("conflict.waiting", waiting.ConversationTitle, waiting.Label);
    }

    private async void OnConflictKeepWaiting(object sender, RoutedEventArgs e) =>
        await AnswerWorkspaceConflictAsync(WorkspaceConflictChoice.KeepWaiting);

    private async void OnConflictStopHolder(object sender, RoutedEventArgs e) =>
        await AnswerWorkspaceConflictAsync(WorkspaceConflictChoice.StopHolder);

    private async void OnConflictStopAll(object sender, RoutedEventArgs e) =>
        await AnswerWorkspaceConflictAsync(WorkspaceConflictChoice.StopAllOthers);

    private async void OnConflictSkip(object sender, RoutedEventArgs e) =>
        await AnswerWorkspaceConflictAsync(WorkspaceConflictChoice.Skip);

    private Task AnswerWorkspaceConflictAsync(WorkspaceConflictChoice choice)
    {
        var model = Model;
        var conversationId = model?.Bridge.PendingConflict?.ConversationId;
        return conversationId is null
            ? Task.CompletedTask
            : model!.Bridge.AnswerWorkspaceConflictAsync(choice, conversationId);
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

    private void BindContextOverflow()
    {
        var pending = Model?.Bridge.PendingContextOverflow;
        if (pending is not null && pending.ConversationId == Model!.SelectedConversationId)
        {
            ContextOverflowBar.Visibility = Visibility.Visible;
            ContextOverflowTitle.Text = Model.L("context.overflowTitle");
            ContextOverflowReason.Text = Model.L(
                "context.overflowReason",
                pending.TargetModel,
                pending.RequiredTokens,
                pending.UsableTokens);
            ContextOverflowSummary.Text = pending.SummarizerModel is { } model
                ? Model.L("context.overflowByModel", model)
                : Model.L("context.overflowLocally");
            ContextOverflowDeclineButton.Content = Model.L("context.overflowNotNow");
            ContextOverflowAcceptButton.Content = Model.L("context.overflowCompress");
        }
        else
        {
            ContextOverflowBar.Visibility = Visibility.Collapsed;
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
        if (ModelList.SelectedItem is ModelPickerItem item
            && Model is { } app
            && !string.Equals(item.Model, app.SelectedModelID, StringComparison.Ordinal))
        {
            app.SetSelectedModel(item.Model);
            ShowModelList(false);
            RefreshModelPicker();
        }
    }

    private static DataTemplate CreateModelPickerItemTemplate()
    {
        var row = new FrameworkElementFactory(typeof(StackPanel));
        row.SetValue(StackPanel.OrientationProperty, Orientation.Horizontal);
        row.SetValue(FrameworkElement.VerticalAlignmentProperty, VerticalAlignment.Center);

        var badge = new FrameworkElementFactory(typeof(Border));
        badge.SetValue(FrameworkElement.WidthProperty, 22d);
        badge.SetValue(FrameworkElement.HeightProperty, 22d);
        badge.SetValue(Border.CornerRadiusProperty, new CornerRadius(5));
        badge.SetValue(Border.BackgroundProperty, Brushes.White);
        badge.SetValue(FrameworkElement.MarginProperty, new Thickness(0, 0, 8, 0));
        var badgeGrid = new FrameworkElementFactory(typeof(Grid));
        var image = new FrameworkElementFactory(typeof(Image));
        image.SetBinding(Image.SourceProperty, new Binding(nameof(ModelPickerItem.ProviderKey)) { Converter = ProviderMarkImageConverter.Instance });
        image.SetValue(Image.WidthProperty, 16d);
        image.SetValue(Image.HeightProperty, 16d);
        image.SetValue(Image.StretchProperty, Stretch.Uniform);
        badgeGrid.AppendChild(image);
        var fallback = new FrameworkElementFactory(typeof(TextBlock));
        fallback.SetBinding(TextBlock.TextProperty, new Binding(nameof(ModelPickerItem.ProviderKey)) { Converter = LogoMarkConverter.Instance });
        fallback.SetValue(TextBlock.FontSizeProperty, 9d);
        fallback.SetValue(TextBlock.FontWeightProperty, FontWeights.Bold);
        fallback.SetValue(TextBlock.HorizontalAlignmentProperty, HorizontalAlignment.Center);
        fallback.SetValue(TextBlock.VerticalAlignmentProperty, VerticalAlignment.Center);
        fallback.SetBinding(UIElement.VisibilityProperty, new Binding(nameof(ModelPickerItem.ProviderKey)) { Converter = ProviderMarkFallbackVisibilityConverter.Instance });
        badgeGrid.AppendChild(fallback);
        badge.AppendChild(badgeGrid);
        row.AppendChild(badge);

        var labels = new FrameworkElementFactory(typeof(StackPanel));
        labels.SetValue(StackPanel.VerticalAlignmentProperty, VerticalAlignment.Center);
        var model = new FrameworkElementFactory(typeof(TextBlock));
        model.SetBinding(TextBlock.TextProperty, new Binding(nameof(ModelPickerItem.Model)));
        labels.AppendChild(model);
        var provider = new FrameworkElementFactory(typeof(TextBlock));
        provider.SetBinding(TextBlock.TextProperty, new Binding(nameof(ModelPickerItem.ProviderName)));
        provider.SetValue(TextBlock.FontSizeProperty, 10d);
        provider.SetValue(TextBlock.ForegroundProperty, Brushes.Gray);
        labels.AppendChild(provider);
        row.AppendChild(labels);
        return new DataTemplate { VisualTree = row };
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
        var selectedConnection = Model.Router.Connections.FirstOrDefault(item => item.Active && item.Models.Contains(selected, StringComparer.Ordinal))
            ?? Model.Router.Connections.FirstOrDefault(item => item.Active && string.Equals(item.Model, selected, StringComparison.Ordinal));
        var selectedProviderName = selectedConnection is null ? "" : RouterCatalog.LabelFor(selectedConnection.Provider);
        ModelPickerName.Text = selected.Length == 0 ? Model.L("modelPicker.selectModel")
            : string.IsNullOrEmpty(selectedProviderName) ? selected : $"{selectedProviderName} · {selected}";
        ModelPickerEffort.Text = hasEfforts ? EffortLabel(Model.Router.SelectedEffort) : "";
        EffortTitle.Text = (hasEfforts ? EffortLabel(Model.Router.SelectedEffort) : Model.L("modelPicker.effortUnsupported")) + "  ›";
        EffortTitle.Foreground = IsUltraEffort ? UltraBrush : ThemeBrush(hasEfforts ? "Accent" : "TextSecondary");
        EffortModelName.Text = selected;
        EffortResetButton.ToolTip = Model.L("modelPicker.reset");
        ModelListHeader.Text = "‹  " + (Model.Router.Models.Count == 0 ? Model.L("modelPicker.noModel") : Model.L("modelPicker.selectModel"));
        EffortTitleButton.ToolTip = Model.L("modelPicker.selectModel");
        UsageModeButton.Content = Model.UsageMode == AgentUsageMode.Economy
            ? Model.L("modelPicker.economy")
            : Model.L("modelPicker.standard");
        UsageModeButton.ToolTip = Model.L("conversation.toggleResponseEconomy");
        var supportsFast = Model.Router.SupportsFast(selected);
        FastModeButton.Visibility = supportsFast ? Visibility.Visible : Visibility.Collapsed;
        FastModeButton.Content = (Model.Router.FastMode ? "⚡ " : "") + Model.L(Model.Router.FastMode ? "modelPicker.fast" : "modelPicker.standard");
        FastModeButton.ToolTip = Model.L("modelPicker.speed");
        var pickerItems = Model.Router.Models.Select(id =>
        {
            var connection = Model.Router.Connections.FirstOrDefault(item => item.Active && item.Models.Contains(id, StringComparer.Ordinal))
                ?? Model.Router.Connections.FirstOrDefault(item => item.Active && string.Equals(item.Model, id, StringComparison.Ordinal));
            var providerKey = connection?.Provider ?? "";
            return new ModelPickerItem(id, RouterCatalog.LabelFor(providerKey), providerKey);
        }).ToList();
        // Every model notification lands here. Swapping in an equal list would tear
        // down and rebuild each row of an open picker, so keep the bound one.
        if (ModelList.ItemsSource is not List<ModelPickerItem> boundItems || !boundItems.SequenceEqual(pickerItems))
            ModelList.ItemsSource = boundItems = pickerItems;
        var selectedItem = boundItems.FirstOrDefault(item => string.Equals(item.Model, selected, StringComparison.Ordinal));
        if (!Equals(ModelList.SelectedItem, selectedItem)) ModelList.SelectedItem = selectedItem;
        EffortTrack.IsEnabled = hasEfforts;
        EffortTrack.Opacity = hasEfforts ? 1 : 0.45;
        DrawEffortTrack();
    }

    private async void OnModelPopupOpened(object? sender, EventArgs e)
    {
        ShowModelList(false);
        RefreshModelPicker();
        await Model!.Router.RefreshModelsIfNeededAsync();
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

    private void OnFastMode(object sender, RoutedEventArgs e)
    {
        if (Model is null) return;
        Model.SetFast(!Model.Router.FastMode);
        RefreshModelPicker();
    }

    private void OnUsageMode(object sender, RoutedEventArgs e)
    {
        if (Model is null) return;
        Model.SetUsageMode(Model.UsageMode == AgentUsageMode.Economy
            ? AgentUsageMode.Standard
            : AgentUsageMode.Economy);
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

    private void OnWorkLocation(object sender, RoutedEventArgs e)
    {
        if (Model is null) return;
        var dialog = new RemoteWorkLocationWindow(Model) { Owner = Window.GetWindow(this) };
        dialog.ShowDialog();
    }

    private void OnDragOver(object sender, DragEventArgs e)
    {
        var acceptsDrop = e.Data.GetDataPresent(DataFormats.FileDrop)
            || e.Data.GetDataPresent(DataFormats.Bitmap);
        e.Effects = acceptsDrop ? DragDropEffects.Copy : DragDropEffects.None;
        DropHint.Visibility = acceptsDrop ? Visibility.Visible : Visibility.Collapsed;
        e.Handled = true;
    }

    private void OnDragLeave(object sender, DragEventArgs e)
    {
        DropHint.Visibility = Visibility.Collapsed;
    }

    private async void OnDrop(object sender, DragEventArgs e)
    {
        DropHint.Visibility = Visibility.Collapsed;
        e.Handled = true;
        if (Model is not { } model) return;

        var droppedPaths = e.Data.GetData(DataFormats.FileDrop) switch
        {
            string[] paths => paths,
            StringCollection paths => paths.Cast<string>().ToArray(),
            _ => Array.Empty<string>(),
        };
        if (droppedPaths.Length > 0)
        {
            await model.AddDraftAttachmentsAsync(droppedPaths);
            return;
        }

        if (e.Data.GetData(DataFormats.Bitmap) is not BitmapSource bitmap) return;
        if (!bitmap.IsFrozen && bitmap.CanFreeze) bitmap.Freeze();
        if (!bitmap.IsFrozen) return;
        try
        {
            var imageData = await Task.Run(() => EncodeBitmapAsPng(bitmap));
            await model.AddDraftImageDataAsync(imageData);
        }
        catch (Exception error)
        {
            System.Diagnostics.Debug.WriteLine($"Unable to import dropped bitmap: {error.Message}");
        }
    }

    private static byte[] EncodeBitmapAsPng(BitmapSource bitmap)
    {
        using var output = new MemoryStream();
        var encoder = new PngBitmapEncoder();
        encoder.Frames.Add(BitmapFrame.Create(bitmap));
        encoder.Save(output);
        return output.ToArray();
    }

    /// <summary>The composer's "+" menu: one line per action, with its shortcut on the trailing side.</summary>
    private void OnAddMenu(object sender, RoutedEventArgs e)
    {
        if (Model is not { } model) return;
        var menu = new ContextMenu { PlacementTarget = AddButton, Placement = System.Windows.Controls.Primitives.PlacementMode.Top };
        void Add(string glyph, string key, Action action, string? gesture = null)
        {
            var item = new MenuItem
            {
                Header = model.L(key),
                InputGestureText = gesture,
                Icon = new TextBlock { Text = glyph, FontFamily = new FontFamily("Segoe Fluent Icons, Segoe MDL2 Assets") },
            };
            item.Click += (_, _) => action();
            menu.Items.Add(item);
        }
        Add("\uE723", "attachment.files", ChooseFiles, "Ctrl+U");
        Add("\uE8B7", "attachment.project", ChooseProject);
        Add("\uE71B", "settings.mcpServers", () => (Window.GetWindow(this) as MainWindow)?.ShowSettings("mcp"));
        Add("\uEA86", "settings.plugins", () => (Window.GetWindow(this) as MainWindow)?.ShowSettings("plugins"));
        menu.IsOpen = true;
    }

    private async void ChooseFiles()
    {
        var dialog = new Microsoft.Win32.OpenFileDialog { Multiselect = true };
        if (dialog.ShowDialog(Window.GetWindow(this)) == true && Model is { } model)
            await model.AddDraftAttachmentsAsync(dialog.FileNames);
    }

    private void ChooseProject()
    {
        var dialog = new Microsoft.Win32.OpenFolderDialog();
        if (dialog.ShowDialog(Window.GetWindow(this)) == true) Model?.AddProject(dialog.FolderName);
    }

    private void OnRemoveAttachment(object sender, RoutedEventArgs e)
    {
        if (sender is Button { Tag: ChatAttachment attachment }) Model?.RemoveDraftAttachment(attachment);
        e.Handled = true;
    }

    private void OnOpenAttachment(object sender, RoutedEventArgs e)
    {
        if (sender is not Button { Tag: ChatAttachment attachment }) return;
        var path = File.Exists(attachment.ProviderFilePath) ? attachment.ProviderFilePath : attachment.FilePath;
        if (!File.Exists(path)) return;

        if (attachment.IsImage)
        {
            var source = AttachmentImage.Instance.Convert(path, typeof(ImageSource), null!, CultureInfo.InvariantCulture) as ImageSource;
            if (source is null) return;
            var owner = Window.GetWindow(this);
            var preview = new Window
            {
                Title = attachment.Name,
                Width = 900,
                Height = 700,
                MinWidth = 360,
                MinHeight = 260,
                WindowStartupLocation = owner is null ? WindowStartupLocation.CenterScreen : WindowStartupLocation.CenterOwner,
                Content = new Border
                {
                    Padding = new Thickness(12),
                    Child = new Image { Source = source, Stretch = Stretch.Uniform },
                },
            };
            if (owner is null) preview.Show();
            else
            {
                preview.Owner = owner;
                preview.ShowDialog();
            }
            return;
        }

        if (Window.GetWindow(this) is DotsHarness.MainWindow window)
            window.ShowFilePanel(path, attachment.Name);
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
        if (!Model.CanSendFromComposer)
        {
            Model.Draft = DraftBox.Text;
            return;
        }
        StopVoiceInput();
        if (Model.IsVoiceRunning)
        {
            try { await Model.StopVoiceAsync(); }
            catch (Exception error) { ShowVoiceError(error); return; }
        }
        Model.Draft = DraftBox.Text;
        Model.Send(mode);
        DraftBox.Text = "";
        if (Model.IsCloudWorkLocation) CloudRunsWindow.ShowFor(Model, Window.GetWindow(this));
    }

    private void OnLocateProject(object sender, RoutedEventArgs e)
    {
        if (Model?.MissingProjectPath is not { } missingPath) return;
        var model = Model;
        var owner = Window.GetWindow(this);
        var input = new TextBox { Margin = new Thickness(0, 8, 0, 8), Padding = new Thickness(8, 6, 8, 6), MinWidth = 360 };
        var dialog = new Window
        {
            Title = model.L("project.missing.title", model.ProjectTitle(missingPath)),
            Width = 440,
            SizeToContent = SizeToContent.Height,
            WindowStartupLocation = owner is null ? WindowStartupLocation.CenterScreen : WindowStartupLocation.CenterOwner,
            ResizeMode = ResizeMode.NoResize,
            ShowInTaskbar = false,
            Owner = owner,
        };
        var locate = new Button { Content = model.L("project.missing.locate"), MinWidth = 110, IsEnabled = false };
        var cancel = new Button { Content = model.L("settings.cancel"), MinWidth = 84, Margin = new Thickness(0, 0, 8, 0) };
        input.TextChanged += (_, _) => locate.IsEnabled = Directory.Exists(input.Text.Trim());
        cancel.Click += (_, _) => dialog.Close();
        locate.Click += async (_, _) =>
        {
            locate.IsEnabled = false;
            if (await model.RelocateProjectAsync(missingPath, input.Text.Trim())) dialog.Close();
            else locate.IsEnabled = Directory.Exists(input.Text.Trim());
        };
        var buttons = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            HorizontalAlignment = HorizontalAlignment.Right,
            Margin = new Thickness(0, 8, 0, 0),
            Children = { cancel, locate },
        };
        dialog.Content = new StackPanel
        {
            Margin = new Thickness(16),
            Children =
            {
                new TextBlock { Text = model.L("project.missing.message", missingPath), TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 0, 0, 8) },
                new TextBlock { Text = model.L("settings.folder") }, input, buttons,
            },
        };
        if (owner is not null) dialog.Owner = owner;
        dialog.ShowDialog();
    }

    private void OnStop(object sender, RoutedEventArgs e)
    {
        if (Model?.Bridge.CanContinue == true) Model.Continue();
        else Model?.Cancel();
    }

    private void OnCancelPlanFromComposer(object sender, RoutedEventArgs e) => Model?.CancelPlan();

    private static Button QueueIcon(string glyph, string tip, PendingPrompt prompt, RoutedEventHandler click)
    {
        var button = new Button
        {
            Content = glyph,
            Tag = prompt,
            Padding = new Thickness(8, 2, 8, 2),
            Background = Brushes.Transparent,
            BorderThickness = new Thickness(0),
            ToolTip = tip,
        };
        button.Click += click;
        return button;
    }

    /// <summary>Live checklist from the agent's latest update_plan, pinned above the composer.</summary>
    private void BindPlan()
    {
        PlanRows.Children.Clear();
        CompletedPlanRows.Children.Clear();
        var steps = Model?.Selected is { } conversation ? PlanStepsTool.CurrentSteps(conversation.Messages) : Array.Empty<PlanStep>();
        var selected = Model?.Selected;
        var transcript = selected?.Messages.ToList() ?? new List<ChatMessage>();
        var planName = PlanStepsTool.Name;
        var latestPlanEventIndex = transcript.FindLastIndex(message => message.Kind == ChatKind.Tool
            && (message.Text.StartsWith("→ " + planName, StringComparison.Ordinal)
                || message.Text.StartsWith("✓ " + planName, StringComparison.Ordinal)
                || message.Text.StartsWith("✕ " + planName, StringComparison.Ordinal)));
        var latestPlanResultIndex = transcript.FindLastIndex(message => message.Kind == ChatKind.Tool
            && message.Text.StartsWith("✓ " + planName, StringComparison.Ordinal)
            && message.RawToolOutput is not null);
        var lastToolIndex = transcript.FindLastIndex(message => message.Kind == ChatKind.Tool);
        var lastAssistantIndex = transcript.FindLastIndex(message => message.Kind == ChatKind.Assistant && !message.Streaming);
        var completed = selected is not null
            && steps.Count > 0
            && steps.All(step => step.Status == "done")
            && !selected.Running
            && selected.Continuation is null
            && selected.PendingPrompts.Count == 0
            && latestPlanEventIndex >= 0
            && latestPlanEventIndex == latestPlanResultIndex
            && lastAssistantIndex > lastToolIndex;
        PlanBar.Visibility = steps.Count > 0 && !completed ? Visibility.Visible : Visibility.Collapsed;
        CompletedPlanSummary.Visibility = completed ? Visibility.Visible : Visibility.Collapsed;
        if (Model is null || steps.Count == 0) return;
        var rows = completed ? CompletedPlanRows : PlanRows;
        rows.Children.Add(new TextBlock
        {
            Text = completed
                ? $"✓ {Model.L("conversation.plan")} · {steps.Count}/{steps.Count}"
                : $"{Model.L("conversation.plan")} · {steps.Count(step => step.Status == "done")}/{steps.Count}",
            FontWeight = FontWeights.SemiBold,
            FontSize = completed ? 11 : 12,
            Margin = new Thickness(0, 0, 0, completed ? 3 : 6),
        });
        foreach (var step in steps)
        {
            var row = new TextBlock
            {
                Text = (completed ? "✓  " : step.Status switch { "done" => "✓  ", "in_progress" => selected?.Running == true ? "◌  " : "⏸  ", _ => "○  " }) + step.Title,
                TextWrapping = TextWrapping.Wrap,
                Margin = new Thickness(0, completed ? 0 : 1, 0, completed ? 0 : 1),
                FontWeight = step.Status == "in_progress" ? FontWeights.SemiBold : FontWeights.Normal,
                FontSize = completed ? 11 : 12,
            };
            row.SetResourceReference(TextBlock.ForegroundProperty, completed || step.Status == "pending" ? "TextSecondary" : "TextPrimary");
            rows.Children.Add(row);
        }
    }

    /// <summary>"1 message queued  text" rows above the composer; each with send-now, edit and remove.</summary>
    private void BindQueue()
    {
        QueueRows.Children.Clear();
        _queueEditButtons.Clear();
        var queued = Model?.Selected?.PendingPrompts.Where(p => p.Mode == PromptMode.Queue).ToList() ?? [];
        QueueBar.Visibility = queued.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        if (Model is null) return;

        var multiple = queued.Count > 1;
        if (multiple)
        {
            var toggle = new Button
            {
                HorizontalContentAlignment = HorizontalAlignment.Stretch,
                Background = Brushes.Transparent,
                BorderThickness = new Thickness(0),
                Padding = new Thickness(0, 2, 0, 2),
            };
            var head = new DockPanel();
            var chevron = new TextBlock { Text = _queueExpanded ? "▴" : "▾", VerticalAlignment = VerticalAlignment.Center };
            DockPanel.SetDock(chevron, Dock.Right);
            head.Children.Add(chevron);
            var title = new TextBlock
            {
                Text = Model.L("composer.queue.many", queued.Count),
                FontWeight = FontWeights.SemiBold,
                Margin = new Thickness(0, 0, 10, 0),
                VerticalAlignment = VerticalAlignment.Center,
            };
            DockPanel.SetDock(title, Dock.Left);
            head.Children.Add(title);
            if (!_queueExpanded)
            {
                var next = new TextBlock
                {
                    Text = Model.L("composer.queue.next", QueueSummary(queued[0])),
                    TextTrimming = TextTrimming.CharacterEllipsis,
                    VerticalAlignment = VerticalAlignment.Center,
                };
                next.SetResourceReference(TextBlock.ForegroundProperty, "TextSecondary");
                head.Children.Add(next);
            }
            toggle.Content = head;
            toggle.Click += (_, _) => { _queueExpanded = !_queueExpanded; BindQueue(); };
            QueueRows.Children.Add(toggle);
        }

        if (!multiple || _queueExpanded)
        {
            for (var i = 0; i < queued.Count; i++)
            {
                var prompt = queued[i];
                var row = new DockPanel { Margin = new Thickness(0, multiple || i > 0 ? 6 : 0, 0, 0) };
                var remove = QueueIcon("✕", Model.L("composer.queue.remove"), prompt, OnQueueRemove);
                var edit = QueueIcon("✎", Model.L("composer.queue.edit"), prompt, OnQueueEdit);
                var steer = QueueIcon("↵", Model.L("conversation.steer"), prompt, OnSteerPending);
                _queueEditButtons.Add(edit);
                foreach (var button in new[] { remove, edit, steer })
                {
                    DockPanel.SetDock(button, Dock.Right);
                    row.Children.Add(button);
                }
                if (!multiple)
                {
                    var header = new TextBlock
                    {
                        Text = Model.L("composer.queue.one"),
                        FontWeight = FontWeights.SemiBold,
                        Margin = new Thickness(0, 0, 10, 0),
                        VerticalAlignment = VerticalAlignment.Center,
                    };
                    DockPanel.SetDock(header, Dock.Left);
                    row.Children.Add(header);
                }
                var text = new TextBlock
                {
                    Text = QueueSummary(prompt),
                    TextWrapping = multiple ? TextWrapping.Wrap : TextWrapping.NoWrap,
                    TextTrimming = TextTrimming.CharacterEllipsis,
                    VerticalAlignment = VerticalAlignment.Center,
                };
                text.SetResourceReference(TextBlock.ForegroundProperty, "TextSecondary");
                row.Children.Add(text);
                QueueRows.Children.Add(row);
            }
        }
        UpdateQueueEditState();
    }

    private static string QueueSummary(PendingPrompt prompt) =>
        string.IsNullOrEmpty(prompt.Text) ? "…" : prompt.Text.Replace('\n', ' ');

    /// <summary>Editing pulls the text into the composer, so it stays disabled until the box is empty.</summary>
    private void UpdateQueueEditState()
    {
        if (Model is null) return;
        var busy = !string.IsNullOrWhiteSpace(DraftBox.Text) || Model.DraftAttachments.Count > 0;
        foreach (var button in _queueEditButtons)
        {
            button.IsEnabled = !busy;
            button.ToolTip = Model.L(busy ? "composer.queue.editBlocked" : "composer.queue.edit");
        }
    }

    private void OnQueueRemove(object sender, RoutedEventArgs e)
    {
        if (sender is Button { Tag: PendingPrompt prompt } && Model?.SelectedConversationId is { } conversationId)
        {
            Model.Bridge.RemoveQueuedPrompt(conversationId, prompt.Id);
            BindQueue();
        }
        e.Handled = true;
    }

    private void OnQueueEdit(object sender, RoutedEventArgs e)
    {
        if (sender is Button { Tag: PendingPrompt prompt } && Model?.EditQueuedPrompt(prompt.Id) == true)
        {
            DraftBox.Text = Model.Draft;
            BindQueue();
            DraftBox.Focus();
        }
        e.Handled = true;
    }

    private async void BindGitBar()
    {
        var model = Model;
        var workspace = model?.WorkspacePath;
        if (model is null || _gitBarHidden || string.IsNullOrWhiteSpace(workspace))
        {
            GitBar.Visibility = Visibility.Collapsed;
            return;
        }

        var info = await model.ReadGitBarAsync();
        if (!ReferenceEquals(model, Model) || _gitBarHidden) return;
        if (info is null)
        {
            GitBar.Visibility = Visibility.Collapsed;
            return;
        }

        GitBar.Visibility = Visibility.Visible;
        GitBarText.Text = $"{Path.GetFileName(workspace.TrimEnd('/', '\\'))}  {info.Branch}";
        GitStat.Visibility = info.Added + info.Removed > 0 ? Visibility.Visible : Visibility.Collapsed;
        GitAdded.Text = $"+{info.Added:N0}";
        GitRemoved.Text = $"-{info.Removed:N0}";
        CreatePrButton.Content = model.L("git.createPR");
    }

    private async void OnCreatePr(object sender, RoutedEventArgs e)
    {
        if (Model is not null) await Model.OpenPullRequestsAsync();
    }

    private void OnGitBarClose(object sender, RoutedEventArgs e)
    {
        _gitBarHidden = true;
        GitBar.Visibility = Visibility.Collapsed;
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

    private void OnEditMessage(object sender, RoutedEventArgs e)
    {
        if (sender is Button { Tag: ChatMessage message }) Model?.RewindTo(message, edit: true);
        e.Handled = true;
    }

    private void OnRewindMessage(object sender, RoutedEventArgs e)
    {
        if (sender is Button { Tag: ChatMessage message }) Model?.RewindTo(message, edit: false);
        e.Handled = true;
    }

    private void OnUndoChanges(object sender, RoutedEventArgs e)
    {
        if (sender is Button { Tag: ChatMessage message }) Model?.Bridge.UndoTurn(message);
        e.Handled = true;
    }

    private void OnToggleChangedFiles(object sender, RoutedEventArgs e)
    {
        if (sender is Button { Tag: ChatMessage message }) message.IsChangedFilesExpanded = !message.IsChangedFilesExpanded;
        e.Handled = true;
    }

    private void OnSpeakMessage(object sender, RoutedEventArgs e)
    {
        if (sender is Button { Tag: ChatMessage message }) Model?.ToggleSpeech(message);
        e.Handled = true;
    }

    private async void OnTranslateMessage(object sender, RoutedEventArgs e)
    {
        if (sender is Button { Tag: ChatMessage message } && Model is { } model) await model.ToggleTranslationAsync(message);
        e.Handled = true;
    }

    private void OnFeedbackGood(object sender, RoutedEventArgs e)
    {
        if (sender is Button { Tag: ChatMessage message }) RequestFeedback(message, FeedbackType.Good);
        e.Handled = true;
    }

    private void OnFeedbackBad(object sender, RoutedEventArgs e)
    {
        if (sender is Button { Tag: ChatMessage message }) RequestFeedback(message, FeedbackType.Bad);
        e.Handled = true;
    }

    private void RequestFeedback(ChatMessage message, FeedbackType type)
    {
        if (Model is not { } model) return;
        var dialog = new FeedbackDialog(type, model.Bridge.FeedbackFor(message), submission =>
            model.Bridge.SubmitFeedback(message, submission.Type, submission.Tags, submission.Comment));
        if (Window.GetWindow(this) is { } owner) dialog.Owner = owner;
        dialog.ShowDialog();
    }

    private void OnApplyPlan(object sender, RoutedEventArgs e)
    {
        if (sender is Button { Tag: ChatMessage message } && message.CanApplyPlan)
        {
            Model?.ApplyPlan();
        }
        e.Handled = true;
    }

    private void OnCancelPlan(object sender, RoutedEventArgs e)
    {
        if (sender is Button { Tag: ChatMessage message } && message.IsPendingPlan)
        {
            Model?.CancelPlan();
        }
        e.Handled = true;
    }

    private void OnDraftKey(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Tab && Keyboard.Modifiers == ModifierKeys.None
            && string.IsNullOrWhiteSpace(DraftBox.Text) && Model?.ActiveFollowUpSuggestion is not null)
        {
            AcceptFollowUpSuggestion();
            e.Handled = true;
            return;
        }
        if (e.Key == Key.U && Keyboard.Modifiers == ModifierKeys.Control)
        {
            ChooseFiles();
            e.Handled = true;
            return;
        }
        if (e.Key != Key.Enter) return;
        var steer = Keyboard.Modifiers.HasFlag(ModifierKeys.Control);
        if (steer || !Keyboard.Modifiers.HasFlag(ModifierKeys.Shift))
        {
            Send(steer ? PromptMode.Steer : PromptMode.Queue);
            e.Handled = true;
        }
    }

    private void BindFollowUpSuggestion()
    {
        if (Model is null || FollowUpSuggestionBanner is null) return;
        var suggestion = string.IsNullOrWhiteSpace(DraftBox.Text) ? Model.ActiveFollowUpSuggestion : null;
        FollowUpSuggestionBanner.Visibility = suggestion is null ? Visibility.Collapsed : Visibility.Visible;
        FollowUpSuggestionText.Text = suggestion ?? "";

        IReadOnlyList<string> choices = string.IsNullOrWhiteSpace(DraftBox.Text)
            ? Model.ActiveFollowUpChoices
            : Array.Empty<string>();
        FollowUpReplyButtons.Children.Clear();
        FollowUpReplyButtons.Visibility = choices.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
        foreach (var choice in choices)
        {
            var button = new Button
            {
                Tag = choice,
                Padding = new Thickness(12, 6),
                Margin = new Thickness(0, 0, 8, 8),
                MaxWidth = 360,
                Content = new TextBlock { Text = choice, TextWrapping = TextWrapping.Wrap },
                ToolTip = choice,
            };
            button.SetResourceReference(Control.BackgroundProperty, "PanelBackground");
            button.SetResourceReference(Control.ForegroundProperty, "TextPrimary");
            button.SetResourceReference(Control.BorderBrushProperty, "BorderSubtle");
            button.Click += OnSendFollowUpReply;
            FollowUpReplyButtons.Children.Add(button);
        }

        if (suggestion is not null)
        {
            AcceptFollowUpSuggestionButton.ToolTip = Model.L("access.accept");
            DismissFollowUpSuggestionButton.ToolTip = Model.L("vision.notNow");
        }
    }

    private void AcceptFollowUpSuggestion()
    {
        if (Model?.ActiveFollowUpSuggestion is not { } suggestion) return;
        Model.Draft = suggestion;
        DraftBox.Text = suggestion;
        DraftBox.CaretIndex = DraftBox.Text.Length;
        Model.Bridge.ClearFollowUpSuggestion();
        DraftBox.Focus();
    }

    private void OnSendFollowUpReply(object sender, RoutedEventArgs e)
    {
        if (Model is null || !string.IsNullOrWhiteSpace(DraftBox.Text)
            || sender is not Button { Tag: string reply }) return;
        Model.Draft = reply;
        DraftBox.Text = reply;
        Model.Bridge.ClearFollowUpSuggestion();
        Model.Send(PromptMode.Queue);
    }

    private void OnAcceptFollowUpSuggestion(object sender, RoutedEventArgs e) => AcceptFollowUpSuggestion();

    private void OnDismissFollowUpSuggestion(object sender, RoutedEventArgs e) => Model?.Bridge.ClearFollowUpSuggestion();

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

    private async void OnContextOverflowDecline(object sender, RoutedEventArgs e)
    {
        if (Model?.Bridge.PendingContextOverflow is { } pending)
            await Model.Bridge.AnswerContextCompactionAsync(false, pending.ConversationId);
    }

    private async void OnContextOverflowAccept(object sender, RoutedEventArgs e)
    {
        if (Model?.Bridge.PendingContextOverflow is { } pending)
            await Model.Bridge.AnswerContextCompactionAsync(true, pending.ConversationId);
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
        PromptPlacement.WaitingForPlan => LocalizationService.Current.Get("queue.waitingForPlan"),
        _ => LocalizationService.Current.Get("conversation.waiting"),
    };
    public object ConvertBack(object value, Type targetType, object parameter, System.Globalization.CultureInfo culture) =>
        throw new NotSupportedException();
}

public sealed class PromptModeSteerOnly : IValueConverter
{
    public static readonly PromptModeSteerOnly Instance = new();

    public object Convert(object value, Type targetType, object parameter, CultureInfo culture) =>
        value is PromptMode.Steer ? Visibility.Visible : Visibility.Collapsed;

    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) =>
        Binding.DoNothing;
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
        return count == 0 ? "" : $"📎 Project context · {count} root{(count == 1 ? "" : "s")}";
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

public sealed class KindVisibility : IValueConverter
{
    public static readonly KindVisibility Instance = new();
    public object Convert(object value, Type targetType, object parameter, CultureInfo culture) =>
        value is ChatKind kind && (parameter as string) switch
        {
            "user" => kind == ChatKind.User,
            "assistant" => kind == ChatKind.Assistant,
            "feedback" => kind is ChatKind.Assistant or ChatKind.Plan,
            _ => kind is ChatKind.User or ChatKind.Assistant or ChatKind.Plan,
        } ? Visibility.Visible : Visibility.Collapsed;
    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) => Binding.DoNothing;
}

public sealed class InverseBoolToVis : IValueConverter
{
    public static readonly InverseBoolToVis Instance = new();
    public object Convert(object value, Type targetType, object parameter, CultureInfo culture) =>
        value is true ? Visibility.Collapsed : Visibility.Visible;
    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) => Binding.DoNothing;
}

public sealed class KindAlignment : IValueConverter
{
    public static readonly KindAlignment Instance = new();
    public object Convert(object value, Type targetType, object parameter, CultureInfo culture) =>
        value is ChatKind.User ? HorizontalAlignment.Right : HorizontalAlignment.Left;
    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) => Binding.DoNothing;
}

public sealed class KindTextAlignment : IValueConverter
{
    public static readonly KindTextAlignment Instance = new();
    public object Convert(object value, Type targetType, object parameter, CultureInfo culture) =>
        value is ChatKind.User ? TextAlignment.Right : TextAlignment.Left;
    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) => Binding.DoNothing;
}

public sealed class FeedbackBrush : IValueConverter
{
    public static readonly FeedbackBrush Instance = new();
    public object Convert(object value, Type targetType, object parameter, CultureInfo culture)
    {
        var key = value as string == parameter as string ? "Accent" : "TextSecondary";
        return Application.Current?.TryFindResource(key) as Brush ?? Brushes.Gray;
    }
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
        value is ChatMessage message
            ? message.Kind != ChatKind.Plan && string.IsNullOrEmpty(message.ActivityCode) ? Visibility.Visible : Visibility.Collapsed
            : value is ChatKind.Plan ? Visibility.Collapsed : Visibility.Visible;
    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) => Binding.DoNothing;
}

public sealed class ContextCompactionVisibility : IValueConverter
{
    public static readonly ContextCompactionVisibility Instance = new();
    public object Convert(object value, Type targetType, object parameter, CultureInfo culture) =>
        value is ChatMessage { ActivityCode: "context_compacted_auto" or "context_compacted" }
            ? Visibility.Visible
            : Visibility.Collapsed;
    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) => Binding.DoNothing;
}

public sealed class ContextCompactionLabel : IValueConverter
{
    public static readonly ContextCompactionLabel Instance = new();
    public object Convert(object value, Type targetType, object parameter, CultureInfo culture) =>
        LocalizationService.Current.Get(value is ChatMessage { ActivityCode: "context_compacted" }
            ? "status.contextCompacted"
            : "conversation.contextCompactedAuto");
    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) => Binding.DoNothing;
}

public sealed class ActivityDetailVisibility : IValueConverter
{
    public static readonly ActivityDetailVisibility Instance = new();
    public object Convert(object value, Type targetType, object parameter, CultureInfo culture) =>
        value is ChatMessage { Text.Length: > 0 } ? Visibility.Visible : Visibility.Collapsed;
    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) => Binding.DoNothing;
}

public sealed class MessageKindLabelVisibility : IValueConverter
{
    public static readonly MessageKindLabelVisibility Instance = new();
    public object Convert(object value, Type targetType, object parameter, CultureInfo culture) =>
        value is ChatKind.Tool ? Visibility.Collapsed : Visibility.Visible;
    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) => Binding.DoNothing;
}

public sealed class ToolActivityVisibility : IValueConverter
{
    public static readonly ToolActivityVisibility Instance = new();
    public object Convert(object value, Type targetType, object parameter, CultureInfo culture) =>
        value is ChatMessage { Kind: ChatKind.Tool } ? Visibility.Visible : Visibility.Collapsed;
    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) => Binding.DoNothing;
}

public sealed class ToolActivityRunningVisibility : IValueConverter
{
    public static readonly ToolActivityRunningVisibility Instance = new();
    public object Convert(object value, Type targetType, object parameter, CultureInfo culture) =>
        value is string text && text.StartsWith("→ ", StringComparison.Ordinal) ? Visibility.Visible : Visibility.Collapsed;
    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) => Binding.DoNothing;
}

public sealed class ToolActivityStateVisibility : IValueConverter
{
    public static readonly ToolActivityStateVisibility Instance = new();
    public object Convert(object value, Type targetType, object parameter, CultureInfo culture) =>
        value is string text && !text.StartsWith("→ ", StringComparison.Ordinal) ? Visibility.Visible : Visibility.Collapsed;
    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) => Binding.DoNothing;
}

public sealed class ToolActivityStateIcon : IValueConverter
{
    public static readonly ToolActivityStateIcon Instance = new();
    public object Convert(object value, Type targetType, object parameter, CultureInfo culture) =>
        value is string text && text.StartsWith("✕ ", StringComparison.Ordinal) ? "!" : "✓";
    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) => Binding.DoNothing;
}

public sealed class ToolActivityDetailVisibility : IValueConverter
{
    public static readonly ToolActivityDetailVisibility Instance = new();
    public object Convert(object value, Type targetType, object parameter, CultureInfo culture)
    {
        if (value is not string text) return Visibility.Collapsed;
        var separator = text.IndexOf('\n');
        return separator >= 0 && separator < text.Length - 1 ? Visibility.Visible : Visibility.Collapsed;
    }
    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) => Binding.DoNothing;
}

public sealed class ToolActivityDetail : IValueConverter
{
    public static readonly ToolActivityDetail Instance = new();
    public object Convert(object value, Type targetType, object parameter, CultureInfo culture)
    {
        if (value is not string text) return "";
        var separator = text.IndexOf('\n');
        if (separator < 0 || separator == text.Length - 1) return "";
        var detail = text[(separator + 1)..].Trim();
        return detail.Length <= 240 ? detail : detail[..240] + "…";
    }
    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) => Binding.DoNothing;
}

public sealed class MessageBodyVisibility : IValueConverter
{
    public static readonly MessageBodyVisibility Instance = new();
    public object Convert(object value, Type targetType, object parameter, CultureInfo culture) =>
        value is ChatMessage message && message.Kind != ChatKind.Tool && string.IsNullOrEmpty(message.ActivityCode)
            ? Visibility.Visible : Visibility.Collapsed;
    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) => Binding.DoNothing;
}

public sealed class ToolActivityLabel : IValueConverter
{
    public static readonly ToolActivityLabel Instance = new();
    public object Convert(object value, Type targetType, object parameter, CultureInfo culture)
    {
        if (value is not string text) return "";
        var title = text.Split('\n', 2)[0].Trim();
        var running = title.StartsWith("→ ", StringComparison.Ordinal);
        var failed = title.StartsWith("✕ ", StringComparison.Ordinal);
        var name = title.Length > 2 && title[1] == ' ' ? title[2..] : title;
        if (failed) return LocalizationService.Current.Get("conversation.activity.toolFailed", name.Replace('_', ' '));
        var key = ToolActivityKey(name, running) ?? (running ? "conversation.activity.otherRunning" : "conversation.activity.otherDone");
        return LocalizationService.Current.Get(key);
    }
    internal static string? ToolActivityKey(string name, bool running)
    {
        var tool = name.ToLowerInvariant();
        if (tool is "read_file" or "list_files" or "grep_files" or "glob_files" or "search_files" or "get_latest_attachment")
            return running ? "conversation.activity.filesReading" : "conversation.activity.filesRead";
        if (tool is "write_file" or "edit_file" or "create_file" or "delete_file" or "copy_generated_media")
            return running ? "conversation.activity.filesChanging" : "conversation.activity.filesChanged";
        if (tool is "run_command" or "terminal_session" or "shell" or "exec")
            return running ? "conversation.activity.commandsRunning" : "conversation.activity.commandsRun";
        if (tool.StartsWith("web_", StringComparison.Ordinal) || tool.StartsWith("browser_", StringComparison.Ordinal))
            return running ? "conversation.activity.webSearching" : "conversation.activity.webSearch";
        return null;
    }
    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) => Binding.DoNothing;
}

public sealed class ToolActivityIcon : IValueConverter
{
    public static readonly ToolActivityIcon Instance = new();
    public object Convert(object value, Type targetType, object parameter, CultureInfo culture)
    {
        if (value is not string text) return "•";
        var title = text.Split('\n', 2)[0].Trim();
        var name = title.Length > 2 && title[1] == ' ' ? title[2..] : title;
        var key = ToolActivityLabel.ToolActivityKey(name, running: false);
        if (key is null) return "⋯";
        if (key.Contains("filesRead", StringComparison.Ordinal)) return "⌕";
        if (key.Contains("filesChanged", StringComparison.Ordinal)) return "✎";
        if (key.Contains("commands", StringComparison.Ordinal)) return "⌘";
        return "⌕";
    }
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

public sealed class ToolOutputVisibility : IValueConverter
{
    public static readonly ToolOutputVisibility Instance = new();

    public object Convert(object value, Type targetType, object parameter, CultureInfo culture) =>
        value is ChatMessage message
            && message.Kind == ChatKind.Tool
            && !string.IsNullOrEmpty(message.RawToolOutput)
            ? Visibility.Visible
            : Visibility.Collapsed;

    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) => Binding.DoNothing;
}

public sealed class ChangedFileLabel : IValueConverter
{
    public static readonly ChangedFileLabel Instance = new();

    public object Convert(object value, Type targetType, object parameter, CultureInfo culture) => value is ChangedFile file
        ? $"{file.Operation switch { ChangedFileOperation.Added => "＋", ChangedFileOperation.Modified => "✎", _ => "−" }} {file.Path}"
        : "";

    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) => Binding.DoNothing;
}

public sealed class ChangedFileLineLabel : IValueConverter
{
    public static readonly ChangedFileLineLabel Instance = new();
    public object Convert(object value, Type targetType, object parameter, CultureInfo culture) => value is ChangedFile file
        ? file.AddedLines < 0 || file.DeletedLines < 0 ? "—" : $"+{file.AddedLines} −{file.DeletedLines}"
        : "";
    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) => Binding.DoNothing;
}

public sealed class ChangedFilesSummary : IValueConverter
{
    public static readonly ChangedFilesSummary Instance = new();
    public object Convert(object value, Type targetType, object parameter, CultureInfo culture) => value is ChatMessage message
        ? LocalizationService.Current.Get("conversation.filesChangedCount", message.ChangedFiles.Count)
        : "";
    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) => Binding.DoNothing;
}

public sealed class ChangedFilesLineSummary : IValueConverter
{
    public static readonly ChangedFilesLineSummary Instance = new();
    public object Convert(object value, Type targetType, object parameter, CultureInfo culture) => value is ChatMessage message
        ? message.ChangedFiles.Any(file => file.AddedLines < 0 || file.DeletedLines < 0)
            ? LocalizationService.Current.Get("conversation.lineCountsUnavailable")
            : LocalizationService.Current.Get(
            "conversation.filesLineSummary",
            message.ChangedFiles.Sum(file => file.AddedLines),
            message.ChangedFiles.Sum(file => file.DeletedLines))
        : "";
    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) => Binding.DoNothing;
}

public sealed class ChangedFilesExpansionLabel : IValueConverter
{
    public static readonly ChangedFilesExpansionLabel Instance = new();
    public object Convert(object value, Type targetType, object parameter, CultureInfo culture)
    {
        if (value is not ChatMessage message) return "";
        var remaining = message.ChangedFilesRemaining.Count;
        return message.IsChangedFilesExpanded
            ? LocalizationService.Current.Get("conversation.filesLess")
            : LocalizationService.Current.Get("conversation.filesMore", remaining);
    }
    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) => Binding.DoNothing;
}

public sealed class ChangedFilesExpansionVisibility : IValueConverter
{
    public static readonly ChangedFilesExpansionVisibility Instance = new();
    public object Convert(object value, Type targetType, object parameter, CultureInfo culture) =>
        value is ChatMessage message && message.ChangedFiles.Count > 3 ? Visibility.Visible : Visibility.Collapsed;
    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) => Binding.DoNothing;
}

public sealed class PositiveCountVisibility : IValueConverter
{
    public static readonly PositiveCountVisibility Instance = new();
    public object Convert(object value, Type targetType, object parameter, CultureInfo culture) =>
        value is int count && count > 0 ? Visibility.Visible : Visibility.Collapsed;
    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) => Binding.DoNothing;
}

public sealed class RunSummaryVisibility : IValueConverter
{
    public static readonly RunSummaryVisibility Instance = new();
    public object Convert(object value, Type targetType, object parameter, CultureInfo culture) =>
        value is ChatMessage message && message.Summary is not null && message.ChangedFiles.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
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

public sealed class AsyncAttachmentImage : Image
{
    public static readonly DependencyProperty FilePathProperty = DependencyProperty.Register(
        nameof(FilePath),
        typeof(string),
        typeof(AsyncAttachmentImage),
        new PropertyMetadata(null, OnFilePathChanged));

    private int _loadVersion;

    public string? FilePath
    {
        get => (string?)GetValue(FilePathProperty);
        set => SetValue(FilePathProperty, value);
    }

    private static void OnFilePathChanged(DependencyObject sender, DependencyPropertyChangedEventArgs args) =>
        ((AsyncAttachmentImage)sender).LoadThumbnail((string?)args.NewValue);

    private async void LoadThumbnail(string? path)
    {
        var version = ++_loadVersion;
        Source = null;
        if (!AttachmentImage.IsSupportedImagePath(path)) return;
        try
        {
            var image = await Task.Run(() =>
            {
                var bitmap = new BitmapImage();
                bitmap.BeginInit();
                bitmap.CacheOption = BitmapCacheOption.OnLoad;
                bitmap.DecodePixelWidth = 512;
                bitmap.UriSource = new Uri(Path.GetFullPath(path!));
                bitmap.EndInit();
                bitmap.Freeze();
                return bitmap;
            });
            if (version == _loadVersion) Source = image;
        }
        catch
        {
            if (version == _loadVersion) Source = null;
        }
    }
}

public sealed class AttachmentImage : IValueConverter
{
    public static readonly AttachmentImage Instance = new();

    internal static bool IsSupportedImagePath(string? path)
    {
        if (string.IsNullOrWhiteSpace(path)) return false;
        var extension = Path.GetExtension(path).ToLowerInvariant();
        return extension is ".png" or ".jpg" or ".jpeg" or ".gif" or ".webp" or ".bmp" or ".tif" or ".tiff" or ".heic" or ".heif" or ".avif";
    }

    public object Convert(object value, Type targetType, object parameter, CultureInfo culture)
    {
        if (value is not string path || !File.Exists(path) || !IsSupportedImagePath(path)) return null!;
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

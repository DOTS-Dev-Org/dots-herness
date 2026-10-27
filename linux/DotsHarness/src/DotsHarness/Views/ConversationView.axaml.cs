// Copyright (c) 2026 DOTS
// Plugin composition model derived from DeepSeek Harness.
// Copyright (c) 2026 DeepSeek. MIT. See NOTICE.

using System.Collections.Specialized;
using System.ComponentModel;
using System.Globalization;
using Avalonia;
using Avalonia.Automation;
using Avalonia.Controls;
using Avalonia.Controls.Templates;
using Avalonia.Data.Converters;
using Avalonia.Input;
using Avalonia.Interactivity;
using Avalonia.Media;
using Avalonia.Media.Imaging;
using Avalonia.Platform;
using Avalonia.Platform.Storage;
using Avalonia.Threading;
using DotsHarnessCore;
using HarnessPluginKit;

namespace DotsHarness.Views;

public partial class ConversationView : UserControl
{
    private sealed record ModelPickerItem(string Model, string ProviderName, string ProviderKey);
    private static readonly Dictionary<string, Bitmap> ModelPickerMarkCache = new(StringComparer.OrdinalIgnoreCase);

    private TerminalSession? _terminal;
    private string? _terminalWorkspace;
    private INotifyPropertyChanged? _observedModel;
    private VoiceInputController? _observedVoice;
    private LinuxMicrophoneCapture? _microphone;
    private Guid _activeVoiceSessionId;
    private readonly DispatcherTimer _workingTimer = new() { Interval = TimeSpan.FromSeconds(1) };
    private readonly DispatcherTimer _loadingAnimationTimer = new() { Interval = TimeSpan.FromMilliseconds(220) };
    private bool _loadingAnimationActive;
    private bool _composerLoadingAnimationVisible;
    private bool _leaseWaitingLoadingAnimationVisible;
    private int _loadingFrame;
    private static readonly Bitmap[] LoadingFrames = Enumerable.Range(0, 4)
        .Select(frame => new Bitmap(AssetLoader.Open(new Uri($"avares://DotsHarness/Resources/HerNessLoaderFrame{frame}.png"))))
        .ToArray();
    private Conversation? _observedConversation;
    private INotifyCollectionChanged? _observedMessages;
    private INotifyCollectionChanged? _observedPending;
    private ChatMessage? _observedTailMessage;
    private MessageTail<ChatMessage>? _messageTail;
    private bool _loadingOlder;
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
        CacheUsageButton.Click += (_, _) => BindCacheUsageDetails();
        TerminalBox.InputReceived += OnTerminalInput;
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
            _loadingAnimationActive = false;
            _composerLoadingAnimationVisible = false;
            _leaseWaitingLoadingAnimationVisible = false;
            ComposerLoadingAnimation.IsVisible = false;
            LeaseWaitingLoadingAnimation.IsVisible = false;
            StopVoiceInput();
            StopTerminal();
            ObserveConversation(null);
            _messageTail?.Dispose();
            _messageTail = null;
        };
    }

    private AppModel? Model => DataContext as AppModel;

    protected override void OnDataContextChanged(EventArgs e)
    {
        base.OnDataContextChanged(e);
        if (_observedModel is not null) _observedModel.PropertyChanged -= OnModel;
        if (_observedVoice is not null)
        {
            _observedVoice.TranscriptUpdated -= OnVoiceTranscript;
            _observedVoice.Error -= OnVoiceError;
            _observedVoice = null;
        }
        _activeVoiceSessionId = Guid.Empty;
        _observedModel = DataContext as INotifyPropertyChanged;
        if (_observedModel is not null) _observedModel.PropertyChanged += OnModel;
        if (DataContext is AppModel model)
        {
            _observedVoice = model.Voice;
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
        Dispatcher.UIThread.Post(DrainModelBind, DispatcherPriority.Background);
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
        var extent = Scroller.Extent.Height;
        var viewport = Scroller.Viewport.Height;
        if (viewport <= 0) viewport = Scroller.Bounds.Height;
        var offset = Scroller.Offset.Y;
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

    private void OnScrollChanged(object? sender, ScrollChangedEventArgs e)
    {
        if (!ReferenceEquals(e.Source, Scroller) || _loadingOlder) return;
        var scrolledNearTop = e.OffsetDelta.Y < 0 && Scroller.Offset.Y < 200;
        if (!scrolledNearTop) return;
        if (_messageTail is { HasOlder: true } tail)
        {
            _loadingOlder = true;
            var extent = Scroller.Extent.Height;
            var offset = Scroller.Offset.Y;
            tail.LoadOlder();
            Dispatcher.UIThread.Post(() =>
            {
                Scroller.Offset = new Vector(Scroller.Offset.X, offset + Scroller.Extent.Height - extent);
                _loadingOlder = false;
            }, DispatcherPriority.Loaded);
            return;
        }
        if (Model?.Bridge.Selected is not { HasOlderMessages: true } conversation) return;
        _loadingOlder = true;
        var storeExtent = Scroller.Extent.Height;
        var storeOffset = Scroller.Offset.Y;
        _ = LoadOlderFromStoreAsync(conversation, storeOffset, storeExtent);
    }

    private async Task LoadOlderFromStoreAsync(Conversation conversation, double offset, double extent)
    {
        try
        {
            if (Model is null || !await Model.Bridge.LoadOlderMessagesAsync(conversation.Id)) return;
            _messageTail?.LoadOlder();
            Bind();
            Dispatcher.UIThread.Post(() =>
                Scroller.Offset = new Vector(Scroller.Offset.X, offset + Scroller.Extent.Height - extent),
                DispatcherPriority.Loaded);
        }
        finally { _loadingOlder = false; }
    }

    private void TryScrollToEndIfNearBottom()
    {
        if (IsNearBottom()) Scroller.ScrollToEnd();
    }

    private void QueueScrollToEndIfNearBottom()
    {
        if (System.Threading.Interlocked.Exchange(ref _scrollScheduled, 1) != 0) return;
        Dispatcher.UIThread.Post(() =>
        {
            System.Threading.Interlocked.Exchange(ref _scrollScheduled, 0);
            TryScrollToEndIfNearBottom();
        }, DispatcherPriority.Background);
    }

    private void QueueScrollToEndAfterLayout()
    {
        Dispatcher.UIThread.Post(() => Scroller.ScrollToEnd(), DispatcherPriority.Loaded);
    }

    // Banners and a taller composer shrink the transcript without moving its offset, which slides the last message out of view.
    private void OnTranscriptSizeChanged(object? sender, SizeChangedEventArgs e)
    {
        if (e.NewSize.Height < e.PreviousSize.Height) QueueScrollToEndAfterLayout();
    }

    private void OnMessagesChanged(object? sender, NotifyCollectionChangedEventArgs e)
    {
        ObserveTailMessage(_observedConversation);
        Dispatcher.UIThread.Post(BindPlan);
        QueueScrollToEndIfNearBottom();
    }

    private void OnPendingChanged(object? sender, NotifyCollectionChangedEventArgs e)
    {
        Dispatcher.UIThread.Post(BindQueue);
        QueueScrollToEndIfNearBottom();
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
                Dispatcher.UIThread.Post(BindPlan);
            QueueScrollToEndIfNearBottom();
        }
        else if (e.PropertyName == nameof(ChatMessage.RawToolOutput))
            Dispatcher.UIThread.Post(BindPlan);
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
        ToolTip.SetTip(CacheUsageButton, Model.L("usage.context.tooltip"));
        CacheUsageButton.IsVisible = conversation?.CacheSession?.Events.Count > 0 || contextTokens > 0;
        ContextUsageSummary.Text = contextWindow > 0 && contextTokens > 0
            ? $"{(contextUsageIsEstimated ? "≈" : "")}{FormatTokenCount(contextTokens)} / {FormatTokenCount(contextWindow)} ({((double)contextTokens / contextWindow).ToString("P0", CultureInfo.CurrentCulture)})"
            : "—";
        ContextUsageProgress.IsVisible = contextWindow > 0;
        ContextUsageProgress.Value = contextWindow > 0 ? Math.Clamp((double)contextTokens / contextWindow, 0, 1) : 0;
        BindCacheResumeNotice();
        BindProviderLimitNotice(conversation);
        BindWorkingIndicator();
        TerminalButton.Content = Model.L("conversation.terminal");
        ToolTip.SetTip(ModelPicker, Model.L("conversation.model"));
        DropHint.Text = Model.L("conversation.dropFiles");
        PlanButton.Content = "💡 " + Model.L("conversation.planMode");
        ToolTip.SetTip(PlanButton, Model.L("conversation.planMode"));
        WorkLocationButton.Content = "⌖ " + Model.L("workLocation.title") + ": " + Model.WorkLocationLabel;
        ToolTip.SetTip(WorkLocationButton, Model.L("workLocation.help"));
        WorkLocationButton.IsEnabled = !Model.Bridge.AnyRunBusy;
        AutomationProperties.SetName(PlanButton, Model.L("conversation.planMode"));
        TerminalTitle.Text = Model.L("conversation.terminal");
        ToolTip.SetTip(CloseTerminalButton, Model.L("conversation.closeTerminal"));
        RejectButton.Content = Model.L("conversation.reject");
        AllowButton.Content = Model.L("conversation.allowOnce");
        VisionRejectButton.Content = Model.L("vision.notNow");
        VisionAllowButton.Content = Model.L("vision.downloadAndContinue");
        EmptyHint.IsVisible = conversation is null;
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
        StopButton.IsVisible = conversation?.Running == true || canContinue;
        CancelPlanButton.Content = Model.L("conversation.cancelPlan");
        ToolTip.SetTip(CancelPlanButton, Model.L("conversation.cancelPlanHelp"));
        CancelPlanButton.IsVisible = conversation?.PlanGateActive == true;
        SendButton.Content = canContinue ? Model.L("conversation.continue") : Model.L("conversation.send");
        var projectLocationAvailable = Model.Bridge.CanSendSelectedConversation;
        var missingProjectPath = Model.IsRemoteWorkLocation ? null : Model.MissingProjectPath;
        ProjectMissingBanner.IsVisible = missingProjectPath is not null;
        ProjectMissingText.Text = missingProjectPath is null ? "" : Model.L("project.missing.readOnly");
        LocateProjectButton.Content = Model.L("project.missing.locate");
        SendButton.IsEnabled = projectLocationAvailable;
        if (!DraftBox.IsFocused) DraftBox.Text = Model.Draft;
        var suggestion = Model.ActiveSkillSuggestions.Pending;
        SkillSuggestionBanner.IsVisible = suggestion is not null;
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
        VoiceIntro.IsVisible = Model.ShowsVoiceIntro;
        VoiceIntroTitle.Text = Model.L("voice.intro.title");
        VoiceIntroBody.Text = Model.L("voice.intro.body");
        StartVoiceIntroButton.Content = Model.L("voice.intro.start");
        ToolTip.SetTip(DismissVoiceIntroButton, Model.L("voice.intro.dismiss"));
        DraftBox.IsEnabled = true;
        VoiceButton.IsEnabled = true;
        VoiceButton.Content = Model.IsVoiceRunning ? Model.L("conversation.stop") : Model.L("conversation.mic");
        ToolTip.SetTip(VoiceButton, Model.IsVoiceRunning ? Model.L("conversation.stopVoice") : Model.L("conversation.startVoice"));
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
            Dispatcher.UIThread.Post(() => Scroller.ScrollToEnd(), DispatcherPriority.Background);
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
                ? $"{tokens / 1_000.0:0.0}k"
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

        CacheResumeWarning.IsVisible = notices.Count > 0;
        CacheResumeInfoButton.IsVisible = expiredTokens is not null && !localCache;
        CacheResumeText.Text = string.Join("\n", notices);
        CacheResumeInfoText.Text = model?.L("conversation.cacheExpired.explanation") ?? "";
        ToolTip.SetTip(CacheResumeInfoButton, model?.L("conversation.cacheExpired.infoTitle"));
    }

    private void BindProviderLimitNotice(Conversation? conversation)
    {
        var model = Model;
        if (model is null || conversation?.CanContinue != true
            || conversation.Continuation is not { Reason: ContinuationPauseReason.ProviderLimit } continuation)
        {
            ProviderLimitWarning.IsVisible = false;
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
        ProviderLimitWarning.IsVisible = true;
        AutomationProperties.SetName(ProviderLimitWarning, $"{ProviderLimitTitle.Text}. {ProviderLimitCountdown.Text}");
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

    private void BindWorkingIndicator()
    {
        var conversation = Model?.Selected;
        SetComposerLoadingAnimationVisible(conversation?.Running == true);
        if (conversation?.Running != true || conversation.RunStartedAt is not { } started)
        {
            WorkingIndicator.IsVisible = false;
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
        WorkingIndicator.IsVisible = true;
        AutomationProperties.SetName(WorkingIndicator, WorkingIndicator.Text);
    }

    private void SetComposerLoadingAnimationVisible(bool visible)
    {
        _composerLoadingAnimationVisible = visible;
        ComposerLoadingAnimation.IsVisible = visible;
        RefreshLoadingAnimation();
    }

    private void SetLeaseWaitingLoadingAnimationVisible(bool visible)
    {
        _leaseWaitingLoadingAnimationVisible = visible;
        LeaseWaitingLoadingAnimation.IsVisible = visible;
        RefreshLoadingAnimation();
    }

    private void RefreshLoadingAnimation()
    {
        var shouldAnimate = _composerLoadingAnimationVisible || _leaseWaitingLoadingAnimationVisible;
        if (shouldAnimate && !_loadingAnimationActive)
        {
            _loadingAnimationActive = true;
            _loadingFrame = 0;
            ApplyLoadingFrame();
            _loadingAnimationTimer.Start();
        }
        else if (!shouldAnimate && _loadingAnimationActive)
        {
            _loadingAnimationActive = false;
            _loadingAnimationTimer.Stop();
        }
    }

    private void ApplyLoadingFrame()
    {
        var frame = LoadingFrames[_loadingFrame];
        if (_composerLoadingAnimationVisible) ComposerLoadingAnimation.Source = frame;
        if (_leaseWaitingLoadingAnimationVisible) LeaseWaitingLoadingAnimation.Source = frame;
    }

    /// <summary>"2m 16s · 1.4k tokens · Running tools…"</summary>
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

    private void OnTerminal(object? sender, RoutedEventArgs e)
    {
        if (TerminalPanel.IsVisible)
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
            ApprovalReason.Text = (approval.Reason ?? "") + (string.IsNullOrWhiteSpace(approval.InputPreview)
                ? ""
                : "\n\n" + Model.L("conversation.toolInput") + "\n" + approval.InputPreview);
        }
        else
        {
            ApprovalBar.IsVisible = false;
        }
    }

    private void BindWorkspaceConflict()
    {
        var model = Model;
        var conflict = model?.Bridge.PendingConflict;
        if (conflict is not null && conflict.ConversationId == model!.SelectedConversationId)
        {
            ConflictBar.IsVisible = true;
            LeaseWaitingBar.IsVisible = false;
            SetLeaseWaitingLoadingAnimationVisible(false);
            ConflictTitle.Text = model.L("conflict.banner.title");
            ConflictBody.Text = model.L("conflict.banner.body", conflict.Path, conflict.HolderTitle, conflict.HeldSeconds);
            ConflictKeepWaitingButton.Content = model.L("conflict.banner.keepWaiting");
            ConflictStopHolderButton.Content = model.L("conflict.banner.stopHolder", conflict.HolderTitle);
            ConflictStopAllButton.Content = model.L("conflict.banner.stopAllOthers");
            ConflictStopAllButton.IsVisible = conflict.OtherRunningConversations > 1;
            ConflictSkipButton.Content = model.L("conflict.banner.skip");
            return;
        }

        ConflictBar.IsVisible = false;
        var waiting = model?.Bridge.WaitingOnLease;
        LeaseWaitingBar.IsVisible = waiting is not null;
        SetLeaseWaitingLoadingAnimationVisible(waiting is not null);
        LeaseWaitingText.Text = waiting is null
            ? ""
            : model!.L("conflict.waiting", waiting.ConversationTitle, waiting.Label);
    }

    private void BindVision()
    {
        var pending = Model?.Bridge.PendingVisionInstall;
        if (pending is not null && pending.ConversationId == Model!.SelectedConversationId)
        {
            VisionBar.IsVisible = true;
            VisionTitle.Text = Model.L("vision.installTitle");
            VisionReason.Text = Model.L("vision.installReason", pending.Provider, ByteCount(pending.ModelBytes));
        }
        else
        {
            VisionBar.IsVisible = false;
        }
    }

    private void BindContextOverflow()
    {
        var pending = Model?.Bridge.PendingContextOverflow;
        if (pending is not null && pending.ConversationId == Model!.SelectedConversationId)
        {
            ContextOverflowBar.IsVisible = true;
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
            ContextOverflowBar.IsVisible = false;
        }
    }

    private static string ByteCount(long bytes) =>
        bytes > 0 ? FormatBytes(bytes) : "279 MB";

    private static string FormatBytes(long bytes)
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
            QuestionBar.IsVisible = false;
            return;
        }

        _boundQuestionId = question.QuestionId;

        QuestionBar.IsVisible = true;
        QuestionTitle.Text = Model.L("ask.title");
        QuestionSubmitButton.Content = Model.L("ask.submit");
        QuestionSkipButton.Content = Model.L("ask.skip");
        foreach (var item in question.Questions)
        {
            var block = new StackPanel { Margin = new Avalonia.Thickness(0, 0, 0, 10) };
            block.Children.Add(new TextBlock
            {
                Text = item.Header.ToUpperInvariant(),
                FontSize = 10,
                Opacity = 0.7,
            });
            block.Children.Add(new TextBlock
            {
                Text = item.Prompt,
                TextWrapping = Avalonia.Media.TextWrapping.Wrap,
                Margin = new Avalonia.Thickness(0, 2, 0, 6),
            });

            var group = $"question-{item.Id}-{question.QuestionId}";
            var buttons = new List<RadioButton>();
            foreach (var option in item.Options)
            {
                var radio = new RadioButton { Content = option, GroupName = group, Margin = new Avalonia.Thickness(0, 0, 0, 4) };
                buttons.Add(radio);
                block.Children.Add(radio);
            }

            var custom = new TextBox
            {
                Margin = new Avalonia.Thickness(0, 4, 0, 0),
                Watermark = Model.L("ask.customPlaceholder"),
                AcceptsReturn = true,
                TextWrapping = Avalonia.Media.TextWrapping.Wrap,
            };
            // A written answer always wins over the suggestions.
            custom.TextChanged += (_, _) =>
            {
                if (string.IsNullOrWhiteSpace(custom.Text)) return;
                foreach (var radio in buttons) radio.IsChecked = false;
            };
            block.Children.Add(custom);
            QuestionOptions.Children.Add(block);
            _questionAnswers.Add(() => string.IsNullOrWhiteSpace(custom.Text)
                ? buttons.FirstOrDefault(radio => radio.IsChecked == true)?.Content as string ?? string.Empty
                : custom.Text!.Trim());
        }
    }

    private async void OnQuestionSubmit(object? sender, RoutedEventArgs e)
    {
        if (Model is null) return;
        var answers = _questionAnswers.Select(read => read()).ToList();
        await Model.Bridge.AnswerQuestionAsync(answers);
    }

    private async void OnQuestionSkip(object? sender, RoutedEventArgs e)
    {
        if (Model is null) return;
        await Model.Bridge.AnswerQuestionAsync(null);
    }

    private void OnSend(object? sender, RoutedEventArgs e)
    {
        Send(PromptMode.Queue);
    }

    private void OnModelChanged(object? sender, SelectionChangedEventArgs e)
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

    private static FuncDataTemplate<ModelPickerItem> CreateModelPickerItemTemplate() => new((item, _) =>
    {
        if (item is null) return null;
        Control mark = LoadModelPickerMark(item.ProviderKey) is { } bitmap
            ? new Image { Source = bitmap, Width = 16, Height = 16, Stretch = Avalonia.Media.Stretch.Uniform }
            : new TextBlock
            {
                Text = ModelPickerFallback(item.ProviderName),
                FontSize = 9,
                FontWeight = FontWeight.Bold,
                HorizontalAlignment = Avalonia.Layout.HorizontalAlignment.Center,
                VerticalAlignment = Avalonia.Layout.VerticalAlignment.Center,
            };
        var badge = new Border
        {
            Width = 22,
            Height = 22,
            CornerRadius = new CornerRadius(5),
            Background = Brushes.White,
            Margin = new Thickness(0, 0, 8, 0),
            Child = mark,
        };
        var labels = new StackPanel
        {
            VerticalAlignment = Avalonia.Layout.VerticalAlignment.Center,
            Children =
            {
                new TextBlock { Text = item.Model },
                new TextBlock { Text = item.ProviderName, FontSize = 10, Foreground = Brushes.Gray },
            },
        };
        return new StackPanel
        {
            Orientation = Avalonia.Layout.Orientation.Horizontal,
            Spacing = 0,
            VerticalAlignment = Avalonia.Layout.VerticalAlignment.Center,
            Children = { badge, labels },
        };
    }, supportsRecycling: true);

    private static Bitmap? LoadModelPickerMark(string providerKey)
    {
        var resource = ProviderMarkCatalog.ResourceNameFor(providerKey);
        if (resource is null) return null;
        if (ModelPickerMarkCache.TryGetValue(resource, out var cached)) return cached;
        try
        {
            using var stream = AssetLoader.Open(new Uri($"avares://DotsHarness/Resources/ProviderMarks/{resource}.png"));
            var bitmap = new Bitmap(stream);
            ModelPickerMarkCache[resource] = bitmap;
            return bitmap;
        }
        catch { return null; }
    }

    private static string ModelPickerFallback(string value)
    {
        var words = value.Split(' ', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        return words.Length > 1 ? string.Concat(words.Take(2).Select(word => word[0])).ToUpperInvariant() : value[..Math.Min(2, value.Length)].ToUpperInvariant();
    }

    // Effort stops: "" (provider default) then the model's levels, low to high.
    private string[] EffortStops =>
        Model is null ? [""] : ["", .. Model.Router.Efforts(Model.SelectedModelID)];

    private string EffortLabel(string level) =>
        Model!.L(level.Length == 0 ? "modelPicker.effort.default" : $"modelPicker.effort.{level}");

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
        ToolTip.SetTip(EffortResetButton, Model.L("modelPicker.reset"));
        ModelListHeader.Text = "‹  " + (Model.Router.Models.Count == 0 ? Model.L("modelPicker.noModel") : Model.L("modelPicker.selectModel"));
        ToolTip.SetTip(EffortTitleButton, Model.L("modelPicker.selectModel"));
        UsageModeButton.Content = Model.UsageMode == AgentUsageMode.Economy
            ? Model.L("modelPicker.economy")
            : Model.L("modelPicker.standard");
        ToolTip.SetTip(UsageModeButton, Model.L("conversation.toggleResponseEconomy"));
        var supportsFast = Model.Router.SupportsFast(selected);
        FastModeButton.IsVisible = supportsFast;
        FastModeButton.Content = (Model.Router.FastMode ? "⚡ " : "") + Model.L(Model.Router.FastMode ? "modelPicker.fast" : "modelPicker.standard");
        ToolTip.SetTip(FastModeButton, Model.L("modelPicker.speed"));
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

    private static IBrush ThemeBrush(string key) =>
        Application.Current?.TryGetResource(key, Application.Current.ActualThemeVariant, out var resource) == true
            && resource is IBrush brush ? brush : Brushes.Gray;

    private async void OnModelFlyoutOpened(object? sender, EventArgs e)
    {
        ShowModelList(false);
        RefreshModelPicker();
        await Model!.Router.RefreshModelsIfNeededAsync();
        RefreshModelPicker();
    }

    // Card shows only the selected model; its title swaps in the model list.
    private void ShowModelList(bool show)
    {
        ModelListPanel.IsVisible = show;
        EffortCard.IsVisible = !show;
    }

    private void OnShowModels(object? sender, RoutedEventArgs e) => ShowModelList(true);

    private void OnHideModels(object? sender, RoutedEventArgs e) => ShowModelList(false);

    /// Top "max" level gets the Codex-style purple gradient track.
    private bool IsUltraEffort =>
        Model?.Router.SelectedEffort == "max" && EffortStops[^1] == "max";

    private static readonly LinearGradientBrush UltraBrush = new()
    {
        StartPoint = new RelativePoint(0, 0.5, RelativeUnit.Relative), EndPoint = new RelativePoint(1, 0.5, RelativeUnit.Relative),
        GradientStops =
        {
            new GradientStop(Color.FromRgb(64, 51, 191), 0),
            new GradientStop(Color.FromRgb(184, 153, 255), 0.6),
            new GradientStop(Color.FromRgb(77, 38, 179), 1),
        },
    };

    private void OnEffortTrackSized(object? sender, SizeChangedEventArgs e) => DrawEffortTrack();

    private void OnEffortReset(object? sender, RoutedEventArgs e)
    {
        Model?.SetEffort("");
        RefreshModelPicker();
    }

    private void OnFastMode(object? sender, RoutedEventArgs e)
    {
        if (Model is null) return;
        Model.SetFast(!Model.Router.FastMode);
        RefreshModelPicker();
    }

    private void OnUsageMode(object? sender, RoutedEventArgs e)
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
        count > 1 ? Math.Max(EffortTrack.Bounds.Width - EffortKnob - 4, 1) / (count - 1) : 0;

    private void DrawEffortTrack()
    {
        if (Model is null) return;
        var stops = EffortStops;
        var index = Math.Max(Array.IndexOf(stops, Model.Router.SelectedEffort), 0);
        var width = EffortTrack.Bounds.Width;
        if (width <= 0) return;
        var step = EffortStep(stops.Length);
        var knobX = 2 + index * step;
        var accent = ThemeBrush("Accent");
        EffortTrack.Children.Clear();
        EffortTrack.Children.Add(new Border { Width = width, Height = 30, CornerRadius = new CornerRadius(15), Background = new SolidColorBrush(Color.FromArgb(28, 128, 128, 128)) });
        EffortTrack.Children.Add(new Border { Width = knobX + EffortKnob + 2, Height = 30, CornerRadius = new CornerRadius(15), Background = IsUltraEffort ? UltraBrush : accent });
        for (var i = 0; i < stops.Length; i++)
        {
            var dot = new Avalonia.Controls.Shapes.Ellipse
            {
                Width = 5, Height = 5,
                Fill = i <= index ? new SolidColorBrush(Color.FromArgb(140, 255, 255, 255)) : new SolidColorBrush(Color.FromArgb(90, 128, 128, 128)),
            };
            Canvas.SetLeft(dot, 2 + i * step + EffortKnob / 2 - 2.5);
            Canvas.SetTop(dot, 12.5);
            EffortTrack.Children.Add(dot);
        }
        var knob = new Avalonia.Controls.Shapes.Ellipse
        {
            Width = EffortKnob, Height = EffortKnob, Fill = Brushes.White,
            Effect = new DropShadowEffect { BlurRadius = 4, OffsetY = 1, Opacity = 0.25 },
        };
        Canvas.SetLeft(knob, knobX);
        Canvas.SetTop(knob, 2);
        EffortTrack.Children.Add(knob);
    }

    // Avalonia's XAML compiler binds PointerPressed only to its exact args type.
    private void OnEffortPressed(object? sender, PointerPressedEventArgs e) => OnEffortPointer(sender, e);

    private void OnEffortPointer(object? sender, PointerEventArgs e)
    {
        if (Model is null || !EffortTrack.IsEnabled || !e.GetCurrentPoint(EffortTrack).Properties.IsLeftButtonPressed) return;
        var stops = EffortStops;
        if (stops.Length < 2) return;
        var raw = (e.GetPosition(EffortTrack).X - 2 - EffortKnob / 2) / EffortStep(stops.Length);
        var next = stops[Math.Clamp((int)Math.Round(raw), 0, stops.Length - 1)];
        if (next == Model.Router.SelectedEffort) return;
        Model.SetEffort(next);
        RefreshModelPicker();
    }

    private void OnPlanMode(object? sender, RoutedEventArgs e)
    {
        Model?.TogglePlanMode();
        e.Handled = true;
    }

    private void OnWorkLocation(object? sender, RoutedEventArgs e)
    {
        if (Model is null) return;
        var owner = TopLevel.GetTopLevel(this) as Window;
        if (owner is null) return;
        var dialog = new RemoteWorkLocationWindow(Model);
        _ = dialog.ShowDialog(owner);
    }

    private void OnDragOver(object? sender, DragEventArgs e)
    {
        var acceptsFiles = e.Data.Contains(DataFormats.Files);
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
        if (Model is not null && e.Data.GetFiles() is { } files)
        {
            var paths = files.Select(file => file.Path.LocalPath).ToArray();
            Model.AddDraftAttachments(paths);
        }
        e.Handled = true;
    }

    private void OnRemoveAttachment(object? sender, RoutedEventArgs e)
    {
        if (sender is Button { Tag: ChatAttachment attachment }) Model?.RemoveDraftAttachment(attachment);
        e.Handled = true;
    }

    private async void OnOpenAttachment(object? sender, RoutedEventArgs e)
    {
        if (sender is not Button { Tag: ChatAttachment attachment }) return;
        var path = File.Exists(attachment.ProviderFilePath) ? attachment.ProviderFilePath : attachment.FilePath;
        if (!File.Exists(path)) return;

        if (attachment.IsImage)
        {
            if (AttachmentImage.Instance.Convert(path, typeof(Bitmap), null!, CultureInfo.InvariantCulture) is not Bitmap bitmap) return;
            var preview = new Window
            {
                Title = attachment.Name,
                Width = 900,
                Height = 700,
                MinWidth = 360,
                MinHeight = 260,
                Content = new Border
                {
                    Padding = new Thickness(12),
                    Child = new Image { Source = bitmap, Stretch = Stretch.Uniform },
                },
            };
            if (TopLevel.GetTopLevel(this) is Window owner) await preview.ShowDialog(owner);
            else preview.Show();
            return;
        }

        if (TopLevel.GetTopLevel(this) is DotsHarness.MainWindow window)
            window.ShowFilePanel(path, attachment.Name);
    }

    /// <summary>
    /// Plays a generated audio file. Linux has no inline player in the shell, so
    /// the file goes to the system's default player.
    /// </summary>
    private void OnPlayAudio(object? sender, RoutedEventArgs e)
    {
        if (sender is not Button { Tag: ChatAttachment attachment }) return;
        AudioPlayback.OpenExternally(attachment.FilePath);
    }

    /// <summary>Plays a generated audio result.</summary>
    private void OnPlayMedia(object? sender, RoutedEventArgs e)
    {
        if (sender is not Button { Tag: ChatMedia media }) return;
        AudioPlayback.OpenExternally(media.FilePath);
    }

    private void OnStartVoiceIntro(object? sender, RoutedEventArgs e)
    {
        Model?.DismissVoiceIntro();
        OnVoice(sender, e);
    }

    private void OnDismissVoiceIntro(object? sender, RoutedEventArgs e) => Model?.DismissVoiceIntro();

    private void OnAcceptSkillSuggestion(object? sender, RoutedEventArgs e)
    {
        if (Model?.ActiveSkillSuggestions.Pending is not { } suggestion) return;
        try { Model.AcceptSkillSuggestion(suggestion.DraftName, suggestion.DraftDescription); }
        catch { }
    }

    private void OnDismissSkillSuggestion(object? sender, RoutedEventArgs e) => Model?.DismissSkillSuggestion();

    /// <summary>The composer's "+" menu: one line per action, with its shortcut on the trailing side.</summary>
    private void OnAddMenu(object? sender, RoutedEventArgs e)
    {
        if (Model is not { } model) return;
        var menu = new MenuFlyout { Placement = PlacementMode.TopEdgeAlignedLeft };
        void Add(string key, Action action, KeyGesture? gesture = null)
        {
            var item = new MenuItem { Header = model.L(key), InputGesture = gesture };
            item.Click += (_, _) => action();
            menu.Items.Add(item);
        }
        Add("attachment.files", () => _ = ChooseFilesAsync(), new KeyGesture(Key.U, KeyModifiers.Control));
        Add("attachment.project", () => _ = ChooseProjectAsync());
        Add("settings.mcpServers", () => OpenSettings("mcp"));
        Add("settings.plugins", () => OpenSettings("plugins"));
        menu.ShowAt(AddButton);
    }

    private async Task ChooseFilesAsync()
    {
        if (TopLevel.GetTopLevel(this) is not { } top) return;
        var files = await top.StorageProvider.OpenFilePickerAsync(new FilePickerOpenOptions { AllowMultiple = true });
        Model?.AddDraftAttachments(files.Select(file => file.Path.LocalPath));
    }

    private async Task ChooseProjectAsync()
    {
        if (TopLevel.GetTopLevel(this) is not { } top) return;
        var folders = await top.StorageProvider.OpenFolderPickerAsync(new FolderPickerOpenOptions());
        if (folders.Count > 0) Model?.AddProject(folders[0].Path.LocalPath);
    }

    private void OpenSettings(string? tab = null)
    {
        if (Model is not { } model || TopLevel.GetTopLevel(this) is not Window owner) return;
        var window = new SettingsWindow { DataContext = model };
        if (tab is not null) window.Opened += (_, _) => window.SelectTab(tab);
        window.Show(owner);
    }

    private void OnVoice(object? sender, RoutedEventArgs e)
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
            VoiceStatus.IsVisible = true;
            OpenSettings();
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
            var microphone = new LinuxMicrophoneCapture();
            microphone.DataAvailable += data => model.Voice.PushPcm16(data.Span);
            _microphone = microphone;
            microphone.Start();
            VoiceButton.Content = model.L("conversation.stop");
            ToolTip.SetTip(VoiceButton, model.L("conversation.stopVoice"));
            VoiceStatus.Text = model.L("conversation.listening");
            VoiceStatus.IsVisible = true;
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
        if (Model is { } model && (microphone is not null || model.IsVoiceRunning)) _ = FinishStopVoiceAsync(model);
    }

    private async Task FinishStopVoiceAsync(AppModel model)
    {
        try { await model.StopVoiceAsync(); }
        catch (Exception error)
        {
            Dispatcher.UIThread.Post(() => ShowVoiceError(error));
            return;
        }
        Dispatcher.UIThread.Post(() =>
        {
            if (!ReferenceEquals(Model, model)) return;
            VoiceButton.Content = model.L("conversation.mic");
            ToolTip.SetTip(VoiceButton, model.L("conversation.startVoice"));
            VoiceStatus.Text = model.L("conversation.voiceStopped");
            VoiceStatus.IsVisible = true;
        });
    }

    private void OnVoiceTranscript(object? sender, VoiceTranscriptUpdate update)
    {
        Dispatcher.UIThread.Post(() =>
        {
            if (Model is not { } model
                || !ReferenceEquals(model.Voice, sender)
                || update.SessionId != _activeVoiceSessionId) return;
            if (update.IsFinal) AppendVoiceText(update.Text);
            else
            {
                VoiceStatus.Text = update.Text;
                VoiceStatus.IsVisible = true;
            }
        });
    }

    private void AppendVoiceText(string text)
    {
        text = text.Trim();
        if (text.Length == 0) return;
        var separator = string.IsNullOrWhiteSpace(DraftBox.Text) ? "" : " ";
        DraftBox.Text += separator + text;
        DraftBox.CaretIndex = DraftBox.Text?.Length ?? 0;
        if (Model is { } model)
        {
            model.Draft = DraftBox.Text ?? "";
            VoiceStatus.Text = model.L("conversation.heard", text);
        }
        VoiceStatus.IsVisible = true;
    }

    private void OnVoiceError(object? sender, Exception error)
    {
        Dispatcher.UIThread.Post(() =>
        {
            if (Model is { } model && ReferenceEquals(model.Voice, sender)) ShowVoiceError(error);
        });
    }

    private void ShowVoiceError(Exception error)
    {
        VoiceButton.Content = Model?.L("conversation.mic") ?? "Mic";
        if (Model is { } model) ToolTip.SetTip(VoiceButton, model.L("conversation.startVoice"));
        VoiceStatus.Text = Model?.L("voice.error", error.Message) ?? $"Voice input error: {error.Message}";
        VoiceStatus.IsVisible = true;
    }

    private async void Send(PromptMode mode)
    {
        if (Model is null) return;
        var model = Model;
        if (!model.Bridge.CanSendSelectedConversation)
        {
            model.Draft = DraftBox.Text ?? "";
            return;
        }
        StopVoiceInput();
        if (model.IsVoiceRunning)
        {
            try { await model.StopVoiceAsync(); }
            catch (Exception error) { ShowVoiceError(error); return; }
        }
        model.Draft = DraftBox.Text ?? "";
        model.Send(mode);
        DraftBox.Text = "";
    }

    private void OnLocateProject(object? sender, RoutedEventArgs e)
    {
        if (Model?.MissingProjectPath is not { } missingPath) return;
        var model = Model;
        var input = new TextBox { Margin = new Avalonia.Thickness(0, 8, 0, 8), Padding = new Avalonia.Thickness(8, 6), MinWidth = 360 };
        var hint = new TextBlock
        {
            Text = model.L("project.missing.message", missingPath),
            TextWrapping = Avalonia.Media.TextWrapping.Wrap,
            Margin = new Avalonia.Thickness(0, 0, 0, 8),
        };
        var dialog = new Window
        {
            Title = model.L("project.missing.title", model.ProjectTitle(missingPath)),
            Width = 440,
            SizeToContent = SizeToContent.Height,
            WindowStartupLocation = WindowStartupLocation.CenterOwner,
            CanResize = false,
            Content = new StackPanel
            {
                Margin = new Avalonia.Thickness(16),
                Children = { hint, new TextBlock { Text = model.L("settings.folder") }, input },
            },
        };
        var cancel = new Button { Content = model.L("settings.cancel"), MinWidth = 84, Margin = new Avalonia.Thickness(0, 0, 8, 0) };
        var locate = new Button { Content = model.L("project.missing.locate"), MinWidth = 110, IsEnabled = false };
        input.TextChanged += (_, _) => locate.IsEnabled = Directory.Exists(input.Text?.Trim() ?? "");
        cancel.Click += (_, _) => dialog.Close();
        locate.Click += async (_, _) =>
        {
            locate.IsEnabled = false;
            if (await model.RelocateProjectAsync(missingPath, input.Text?.Trim() ?? "")) dialog.Close();
            else locate.IsEnabled = Directory.Exists(input.Text?.Trim() ?? "");
        };
        var buttons = new StackPanel
        {
            Orientation = Avalonia.Layout.Orientation.Horizontal,
            HorizontalAlignment = Avalonia.Layout.HorizontalAlignment.Right,
            Margin = new Avalonia.Thickness(0, 8, 0, 0),
            Children = { cancel, locate },
        };
        ((StackPanel)dialog.Content!).Children.Add(buttons);
        if (TopLevel.GetTopLevel(this) is Window owner) _ = dialog.ShowDialog(owner);
        else dialog.Show();
    }

    private void OnStop(object? sender, RoutedEventArgs e)
    {
        if (Model?.Bridge.CanContinue == true) Model.Continue();
        else Model?.Cancel();
    }

    private void OnCancelPlanFromComposer(object? sender, RoutedEventArgs e) => Model?.CancelPlan();

    private static Button QueueIcon(string glyph, string tip, PendingPrompt prompt, EventHandler<RoutedEventArgs> click)
    {
        var button = new Button
        {
            Content = glyph,
            Tag = prompt,
            Padding = new Thickness(8, 2),
            Background = Brushes.Transparent,
            BorderThickness = new Thickness(0),
        };
        ToolTip.SetTip(button, tip);
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
            && !selected.Running
            && selected.Continuation is null
            && selected.PendingPrompts.Count == 0
            && latestPlanEventIndex >= 0
            && latestPlanEventIndex == latestPlanResultIndex
            && lastAssistantIndex > lastToolIndex;
        PlanBar.IsVisible = steps.Count > 0 && !completed;
        CompletedPlanSummary.IsVisible = completed;
        if (Model is null || steps.Count == 0) return;
        var rows = completed ? CompletedPlanRows : PlanRows;
        rows.Children.Add(new TextBlock
        {
            Text = completed
                ? $"✓ {Model.L("conversation.plan")} · {steps.Count}/{steps.Count}"
                : $"{Model.L("conversation.plan")} · {steps.Count(step => step.Status == "done")}/{steps.Count}",
            FontWeight = FontWeight.SemiBold,
            FontSize = completed ? 11 : 12,
            Margin = new Thickness(0, 0, 0, completed ? 3 : 6),
        });
        var secondary = (IBrush?)this.FindResource("TextSecondary") ?? Brushes.Gray;
        foreach (var step in steps)
        {
            var row = new TextBlock
            {
                Text = (completed ? "✓  " : step.Status switch { "done" => "✓  ", "in_progress" => "◌  ", _ => "○  " }) + step.Title,
                TextWrapping = TextWrapping.Wrap,
                Margin = new Thickness(0, completed ? 0 : 1, 0, completed ? 0 : 1),
                FontWeight = step.Status == "in_progress" ? FontWeight.SemiBold : FontWeight.Normal,
                FontSize = completed ? 11 : 12,
            };
            if (completed || step.Status == "pending") row.Foreground = secondary;
            rows.Children.Add(row);
        }
    }

    /// <summary>"1 message queued  text" rows above the composer; each with send-now, edit and remove.</summary>
    private void BindQueue()
    {
        QueueRows.Children.Clear();
        _queueEditButtons.Clear();
        var queued = Model?.Selected?.PendingPrompts.Where(p => p.Mode == PromptMode.Queue).ToList() ?? [];
        QueueBar.IsVisible = queued.Count > 0;
        if (Model is null) return;

        var multiple = queued.Count > 1;
        if (multiple)
        {
            var toggle = new Button
            {
                HorizontalContentAlignment = Avalonia.Layout.HorizontalAlignment.Stretch,
                Background = Brushes.Transparent,
                BorderThickness = new Thickness(0),
                Padding = new Thickness(0, 2),
            };
            var head = new DockPanel();
            var chevron = new TextBlock { Text = _queueExpanded ? "▴" : "▾", VerticalAlignment = Avalonia.Layout.VerticalAlignment.Center };
            DockPanel.SetDock(chevron, Dock.Right);
            head.Children.Add(chevron);
            var title = new TextBlock
            {
                Text = Model.L("composer.queue.many", queued.Count),
                FontWeight = FontWeight.SemiBold,
                Margin = new Thickness(0, 0, 10, 0),
                VerticalAlignment = Avalonia.Layout.VerticalAlignment.Center,
            };
            DockPanel.SetDock(title, Dock.Left);
            head.Children.Add(title);
            if (!_queueExpanded)
            {
                var next = new TextBlock
                {
                    Text = Model.L("composer.queue.next", QueueSummary(queued[0])),
                    TextTrimming = TextTrimming.CharacterEllipsis,
                    VerticalAlignment = Avalonia.Layout.VerticalAlignment.Center,
                };
                next.Foreground = (IBrush?)this.FindResource("TextSecondary") ?? Brushes.Gray;
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
                        FontWeight = FontWeight.SemiBold,
                        Margin = new Thickness(0, 0, 10, 0),
                        VerticalAlignment = Avalonia.Layout.VerticalAlignment.Center,
                    };
                    DockPanel.SetDock(header, Dock.Left);
                    row.Children.Add(header);
                }
                var text = new TextBlock
                {
                    Text = QueueSummary(prompt),
                    TextWrapping = multiple ? TextWrapping.Wrap : TextWrapping.NoWrap,
                    TextTrimming = TextTrimming.CharacterEllipsis,
                    VerticalAlignment = Avalonia.Layout.VerticalAlignment.Center,
                };
                text.Foreground = (IBrush?)this.FindResource("TextSecondary") ?? Brushes.Gray;
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
            ToolTip.SetTip(button, Model.L(busy ? "composer.queue.editBlocked" : "composer.queue.edit"));
        }
    }

    private void OnQueueRemove(object? sender, RoutedEventArgs e)
    {
        if (sender is Button { Tag: PendingPrompt prompt } && Model?.SelectedConversationId is { } conversationId)
        {
            Model.Bridge.RemoveQueuedPrompt(conversationId, prompt.Id);
            BindQueue();
        }
        e.Handled = true;
    }

    private void OnQueueEdit(object? sender, RoutedEventArgs e)
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
            GitBar.IsVisible = false;
            return;
        }

        var info = await model.ReadGitBarAsync();
        if (!ReferenceEquals(model, Model) || _gitBarHidden) return;
        if (info is null)
        {
            GitBar.IsVisible = false;
            return;
        }

        GitBar.IsVisible = true;
        GitBarText.Text = $"{Path.GetFileName(workspace.TrimEnd('/', '\\'))}  {info.Branch}";
        GitStat.IsVisible = info.Added + info.Removed > 0;
        GitAdded.Text = $"+{info.Added:N0}";
        GitRemoved.Text = $"-{info.Removed:N0}";
        CreatePrButton.Content = model.L("git.createPR");
    }

    private async void OnCreatePr(object? sender, RoutedEventArgs e)
    {
        if (Model is not null) await Model.OpenPullRequestsAsync();
    }

    private void OnGitBarClose(object? sender, RoutedEventArgs e)
    {
        _gitBarHidden = true;
        GitBar.IsVisible = false;
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

    private async void OnCopyMessage(object? sender, RoutedEventArgs e)
    {
        if (sender is Button { Tag: ChatMessage message } && TopLevel.GetTopLevel(this)?.Clipboard is { } clipboard)
        {
            await clipboard.SetTextAsync(message.Text);
        }
        e.Handled = true;
    }

    private void OnEditMessage(object? sender, RoutedEventArgs e)
    {
        if (sender is Button { Tag: ChatMessage message }) Model?.RewindTo(message, edit: true);
        e.Handled = true;
    }

    private void OnRewindMessage(object? sender, RoutedEventArgs e)
    {
        if (sender is Button { Tag: ChatMessage message }) Model?.RewindTo(message, edit: false);
        e.Handled = true;
    }

    private void OnUndoChanges(object? sender, RoutedEventArgs e)
    {
        if (sender is Button { Tag: ChatMessage message }) Model?.Bridge.UndoTurn(message);
        e.Handled = true;
    }

    private void OnToggleChangedFiles(object? sender, RoutedEventArgs e)
    {
        if (sender is Button { Tag: ChatMessage message }) message.IsChangedFilesExpanded = !message.IsChangedFilesExpanded;
        e.Handled = true;
    }

    private void OnSpeakMessage(object? sender, RoutedEventArgs e)
    {
        if (sender is Button { Tag: ChatMessage message }) Model?.ToggleSpeech(message);
        e.Handled = true;
    }

    private async void OnTranslateMessage(object? sender, RoutedEventArgs e)
    {
        if (sender is Button { Tag: ChatMessage message } && Model is { } model) await model.ToggleTranslationAsync(message);
        e.Handled = true;
    }

    private async void OnFeedbackGood(object? sender, RoutedEventArgs e)
    {
        if (sender is Button { Tag: ChatMessage message }) await RequestFeedbackAsync(message, FeedbackType.Good);
        e.Handled = true;
    }

    private async void OnFeedbackBad(object? sender, RoutedEventArgs e)
    {
        if (sender is Button { Tag: ChatMessage message }) await RequestFeedbackAsync(message, FeedbackType.Bad);
        e.Handled = true;
    }

    private async Task RequestFeedbackAsync(ChatMessage message, FeedbackType type)
    {
        if (Model is not { } model || TopLevel.GetTopLevel(this) is not Window owner) return;
        var dialog = new FeedbackDialog(type, model.Bridge.FeedbackFor(message), submission =>
            model.Bridge.SubmitFeedback(message, submission.Type, submission.Tags, submission.Comment));
        await dialog.ShowDialog<FeedbackSubmission?>(owner);
    }

    private void OnApplyPlan(object? sender, RoutedEventArgs e)
    {
        if (sender is Button { Tag: ChatMessage message } && message.CanApplyPlan)
        {
            Model?.ApplyPlan();
        }
        e.Handled = true;
    }

    private void OnCancelPlan(object? sender, RoutedEventArgs e)
    {
        if (sender is Button { Tag: ChatMessage message } && message.IsPendingPlan)
        {
            Model?.CancelPlan();
        }
        e.Handled = true;
    }

    private void OnDraftKey(object? sender, KeyEventArgs e)
    {
        if (e.Key == Key.Tab && e.KeyModifiers == KeyModifiers.None
            && string.IsNullOrWhiteSpace(DraftBox.Text) && Model?.ActiveFollowUpSuggestion is not null)
        {
            AcceptFollowUpSuggestion();
            e.Handled = true;
            return;
        }
        if (e.Key == Key.U && e.KeyModifiers == KeyModifiers.Control)
        {
            _ = ChooseFilesAsync();
            e.Handled = true;
            return;
        }
        if (e.Key != Key.Enter) return;
        var steer = e.KeyModifiers.HasFlag(KeyModifiers.Control)
            || e.KeyModifiers.HasFlag(KeyModifiers.Meta);
        if (steer || !e.KeyModifiers.HasFlag(KeyModifiers.Shift))
        {
            Send(steer ? PromptMode.Steer : PromptMode.Queue);
            e.Handled = true;
        }
    }

    private void BindFollowUpSuggestion()
    {
        if (Model is null || FollowUpSuggestionBanner is null) return;
        var suggestion = string.IsNullOrWhiteSpace(DraftBox.Text) ? Model.ActiveFollowUpSuggestion : null;
        FollowUpSuggestionBanner.IsVisible = suggestion is not null;
        FollowUpSuggestionText.Text = suggestion ?? "";
        if (suggestion is not null)
        {
            ToolTip.SetTip(AcceptFollowUpSuggestionButton, Model.L("access.accept"));
            ToolTip.SetTip(DismissFollowUpSuggestionButton, Model.L("vision.notNow"));
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

    private void OnAcceptFollowUpSuggestion(object? sender, RoutedEventArgs e) => AcceptFollowUpSuggestion();

    private void OnDismissFollowUpSuggestion(object? sender, RoutedEventArgs e) => Model?.Bridge.ClearFollowUpSuggestion();

    private async void OnReject(object? sender, RoutedEventArgs e)
    {
        if (Model is not null) await Model.Bridge.AnswerApprovalAsync("rejected");
    }

    private async void OnAllow(object? sender, RoutedEventArgs e)
    {
        if (Model is not null) await Model.Bridge.AnswerApprovalAsync("allowed-once");
    }

    private async void OnVisionReject(object? sender, RoutedEventArgs e)
    {
        if (Model is not null) await Model.Bridge.AnswerVisionInstallAsync(false);
    }

    private async void OnVisionAllow(object? sender, RoutedEventArgs e)
    {
        if (Model is not null) await Model.Bridge.AnswerVisionInstallAsync(true);
    }

    private async void OnConflictKeepWaiting(object? sender, RoutedEventArgs e) =>
        await AnswerWorkspaceConflictAsync(WorkspaceConflictChoice.KeepWaiting);

    private async void OnConflictStopHolder(object? sender, RoutedEventArgs e) =>
        await AnswerWorkspaceConflictAsync(WorkspaceConflictChoice.StopHolder);

    private async void OnConflictStopAll(object? sender, RoutedEventArgs e) =>
        await AnswerWorkspaceConflictAsync(WorkspaceConflictChoice.StopAllOthers);

    private async void OnConflictSkip(object? sender, RoutedEventArgs e) =>
        await AnswerWorkspaceConflictAsync(WorkspaceConflictChoice.Skip);

    private Task AnswerWorkspaceConflictAsync(WorkspaceConflictChoice choice)
    {
        var model = Model;
        var conversationId = model?.Bridge.PendingConflict?.ConversationId;
        return conversationId is null
            ? Task.CompletedTask
            : model!.Bridge.AnswerWorkspaceConflictAsync(choice, conversationId);
    }

    private async void OnContextOverflowDecline(object? sender, RoutedEventArgs e)
    {
        if (Model?.Bridge.PendingContextOverflow is { } pending)
            await Model.Bridge.AnswerContextCompactionAsync(false, pending.ConversationId);
    }

    private async void OnContextOverflowAccept(object? sender, RoutedEventArgs e)
    {
        if (Model?.Bridge.PendingContextOverflow is { } pending)
            await Model.Bridge.AnswerContextCompactionAsync(true, pending.ConversationId);
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
        PromptPlacement.WaitingForPlan => LocalizationService.Current.Get("queue.waitingForPlan"),
        _ => LocalizationService.Current.Get("conversation.waiting"),
    };
    public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) =>
        throw new NotSupportedException();
}

public sealed class PromptModeSteerOnly : IValueConverter
{
    public static readonly PromptModeSteerOnly Instance = new();

    public object? Convert(object? value, Type targetType, object? parameter, CultureInfo culture) =>
        value is PromptMode.Steer;

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

public sealed class ContextRootLabel : IValueConverter
{
    public static readonly ContextRootLabel Instance = new();

    public object? Convert(object? value, Type targetType, object? parameter, CultureInfo culture)
    {
        var count = value is System.Collections.ICollection collection ? collection.Count : 0;
        return count == 0 ? "" : $"📎 Project context · {count} root{(count == 1 ? "" : "s")}";
    }

    public object? ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) => throw new NotSupportedException();
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

public sealed class KindVisibility : IValueConverter
{
    public static readonly KindVisibility Instance = new();
    public object? Convert(object? value, Type targetType, object? parameter, CultureInfo culture) =>
        value is ChatKind kind && (parameter as string) switch
        {
            "user" => kind == ChatKind.User,
            "assistant" => kind == ChatKind.Assistant,
            "feedback" => kind is ChatKind.Assistant or ChatKind.Plan,
            _ => kind is ChatKind.User or ChatKind.Assistant or ChatKind.Plan,
        };
    public object? ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) =>
        throw new NotSupportedException();
}

public sealed class KindAlignment : IValueConverter
{
    public static readonly KindAlignment Instance = new();
    public object? Convert(object? value, Type targetType, object? parameter, CultureInfo culture) =>
        value is ChatKind.User ? Avalonia.Layout.HorizontalAlignment.Right : Avalonia.Layout.HorizontalAlignment.Left;
    public object? ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) =>
        throw new NotSupportedException();
}

public sealed class KindTextAlignment : IValueConverter
{
    public static readonly KindTextAlignment Instance = new();
    public object? Convert(object? value, Type targetType, object? parameter, CultureInfo culture) =>
        value is ChatKind.User ? TextAlignment.Right : TextAlignment.Left;
    public object? ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) =>
        throw new NotSupportedException();
}

public sealed class FeedbackBrush : IValueConverter
{
    public static readonly FeedbackBrush Instance = new();
    public object? Convert(object? value, Type targetType, object? parameter, CultureInfo culture)
    {
        var key = value as string == parameter as string ? "Accent" : "TextSecondary";
        return Application.Current?.TryGetResource(key, Application.Current.ActualThemeVariant, out var resource) == true
            && resource is IBrush brush ? brush : Brushes.Gray;
    }
    public object? ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) =>
        throw new NotSupportedException();
}

public sealed class RelativeTime : IValueConverter
{
    public static readonly RelativeTime Instance = new();
    public object? Convert(object? value, Type targetType, object? parameter, CultureInfo culture)
    {
        if (value is not DateTimeOffset at) return "";
        var d = DateTimeOffset.Now - at;
        return d.TotalMinutes < 1 ? "now"
            : d.TotalHours < 1 ? $"{(int)d.TotalMinutes} min ago"
            : d.TotalDays < 1 ? $"{(int)d.TotalHours} h ago"
            : at.ToLocalTime().ToString("g", culture);
    }
    public object? ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) =>
        throw new NotSupportedException();
}

public sealed class NotPlanVisibility : IValueConverter
{
    public static readonly NotPlanVisibility Instance = new();
    public object? Convert(object? value, Type targetType, object? parameter, CultureInfo culture) =>
        value is ChatMessage message
            ? message.Kind != ChatKind.Plan && string.IsNullOrEmpty(message.ActivityCode)
            : value is not ChatKind.Plan;
    public object? ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) =>
        throw new NotSupportedException();
}

public sealed class ContextCompactionVisibility : IValueConverter
{
    public static readonly ContextCompactionVisibility Instance = new();
    public object? Convert(object? value, Type targetType, object? parameter, CultureInfo culture) =>
        value is ChatMessage { ActivityCode: "context_compacted_auto" or "context_compacted" };
    public object? ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) =>
        throw new NotSupportedException();
}

public sealed class ContextCompactionLabel : IValueConverter
{
    public static readonly ContextCompactionLabel Instance = new();
    public object? Convert(object? value, Type targetType, object? parameter, CultureInfo culture) =>
        LocalizationService.Current.Get(value is ChatMessage { ActivityCode: "context_compacted" }
            ? "status.contextCompacted"
            : "conversation.contextCompactedAuto");
    public object? ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) =>
        throw new NotSupportedException();
}

public sealed class ActivityDetailVisibility : IValueConverter
{
    public static readonly ActivityDetailVisibility Instance = new();
    public object? Convert(object? value, Type targetType, object? parameter, CultureInfo culture) =>
        value is ChatMessage message && !string.IsNullOrEmpty(message.Text);
    public object? ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) =>
        throw new NotSupportedException();
}

public sealed class MessageKindLabelVisibility : IValueConverter
{
    public static readonly MessageKindLabelVisibility Instance = new();
    public object? Convert(object? value, Type targetType, object? parameter, CultureInfo culture) =>
        value is not ChatKind.Tool;
    public object? ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) =>
        throw new NotSupportedException();
}

public sealed class ToolActivityVisibility : IValueConverter
{
    public static readonly ToolActivityVisibility Instance = new();
    public object? Convert(object? value, Type targetType, object? parameter, CultureInfo culture) =>
        value is ChatMessage { Kind: ChatKind.Tool };
    public object? ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) =>
        throw new NotSupportedException();
}

public sealed class ToolActivityRunningVisibility : IValueConverter
{
    public static readonly ToolActivityRunningVisibility Instance = new();
    public object? Convert(object? value, Type targetType, object? parameter, CultureInfo culture) =>
        value is string text && text.StartsWith("→ ", StringComparison.Ordinal);
    public object? ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) =>
        throw new NotSupportedException();
}

public sealed class ToolActivityStateVisibility : IValueConverter
{
    public static readonly ToolActivityStateVisibility Instance = new();
    public object? Convert(object? value, Type targetType, object? parameter, CultureInfo culture) =>
        value is string text && !text.StartsWith("→ ", StringComparison.Ordinal);
    public object? ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) =>
        throw new NotSupportedException();
}

public sealed class ToolActivityStateIcon : IValueConverter
{
    public static readonly ToolActivityStateIcon Instance = new();
    public object? Convert(object? value, Type targetType, object? parameter, CultureInfo culture) =>
        value is string text && text.StartsWith("✕ ", StringComparison.Ordinal) ? "!" : "✓";
    public object? ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) =>
        throw new NotSupportedException();
}

public sealed class ToolActivityDetailVisibility : IValueConverter
{
    public static readonly ToolActivityDetailVisibility Instance = new();
    public object? Convert(object? value, Type targetType, object? parameter, CultureInfo culture)
    {
        if (value is not string text) return false;
        var separator = text.IndexOf('\n');
        return separator >= 0 && separator < text.Length - 1;
    }
    public object? ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) =>
        throw new NotSupportedException();
}

public sealed class ToolActivityDetail : IValueConverter
{
    public static readonly ToolActivityDetail Instance = new();
    public object? Convert(object? value, Type targetType, object? parameter, CultureInfo culture)
    {
        if (value is not string text) return "";
        var separator = text.IndexOf('\n');
        if (separator < 0 || separator == text.Length - 1) return "";
        var detail = text[(separator + 1)..].Trim();
        return detail.Length <= 240 ? detail : detail[..240] + "…";
    }
    public object? ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) =>
        throw new NotSupportedException();
}

public sealed class MessageBodyVisibility : IValueConverter
{
    public static readonly MessageBodyVisibility Instance = new();
    public object? Convert(object? value, Type targetType, object? parameter, CultureInfo culture) =>
        value is ChatMessage message && message.Kind != ChatKind.Tool && string.IsNullOrEmpty(message.ActivityCode);
    public object? ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) =>
        throw new NotSupportedException();
}

public sealed class ToolActivityLabel : IValueConverter
{
    public static readonly ToolActivityLabel Instance = new();
    public object? Convert(object? value, Type targetType, object? parameter, CultureInfo culture)
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
    public object? ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) =>
        throw new NotSupportedException();
}

public sealed class ToolActivityIcon : IValueConverter
{
    public static readonly ToolActivityIcon Instance = new();
    public object? Convert(object? value, Type targetType, object? parameter, CultureInfo culture)
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

public sealed class ToolOutputVisibility : IValueConverter
{
    public static readonly ToolOutputVisibility Instance = new();

    public object? Convert(object? value, Type targetType, object? parameter, CultureInfo culture) =>
        value is ChatMessage message
            && message.Kind == ChatKind.Tool
            && !string.IsNullOrEmpty(message.RawToolOutput);

    public object? ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) =>
        throw new NotSupportedException();
}

public sealed class ChangedFileLabel : IValueConverter
{
    public static readonly ChangedFileLabel Instance = new();

    public object? Convert(object? value, Type targetType, object? parameter, CultureInfo culture) => value is ChangedFile file
        ? $"{file.Operation switch { ChangedFileOperation.Added => "＋", ChangedFileOperation.Modified => "✎", _ => "−" }} {file.Path}"
        : "";

    public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) => throw new NotSupportedException();
}

public sealed class ChangedFileLineLabel : IValueConverter
{
    public static readonly ChangedFileLineLabel Instance = new();
    public object? Convert(object? value, Type targetType, object? parameter, CultureInfo culture) => value is ChangedFile file
        ? file.AddedLines < 0 || file.DeletedLines < 0 ? "—" : $"+{file.AddedLines} −{file.DeletedLines}"
        : "";
    public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) => throw new NotSupportedException();
}

public sealed class ChangedFilesSummary : IValueConverter
{
    public static readonly ChangedFilesSummary Instance = new();
    public object? Convert(object? value, Type targetType, object? parameter, CultureInfo culture) => value is ChatMessage message
        ? LocalizationService.Current.Get("conversation.filesChangedCount", message.ChangedFiles.Count)
        : "";
    public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) => throw new NotSupportedException();
}

public sealed class ChangedFilesLineSummary : IValueConverter
{
    public static readonly ChangedFilesLineSummary Instance = new();
    public object? Convert(object? value, Type targetType, object? parameter, CultureInfo culture) => value is ChatMessage message
        ? message.ChangedFiles.Any(file => file.AddedLines < 0 || file.DeletedLines < 0)
            ? LocalizationService.Current.Get("conversation.lineCountsUnavailable")
            : LocalizationService.Current.Get(
            "conversation.filesLineSummary",
            message.ChangedFiles.Sum(file => file.AddedLines),
            message.ChangedFiles.Sum(file => file.DeletedLines))
        : "";
    public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) => throw new NotSupportedException();
}

public sealed class ChangedFilesExpansionLabel : IValueConverter
{
    public static readonly ChangedFilesExpansionLabel Instance = new();
    public object? Convert(object? value, Type targetType, object? parameter, CultureInfo culture)
    {
        if (value is not ChatMessage message) return "";
        return message.IsChangedFilesExpanded
            ? LocalizationService.Current.Get("conversation.filesLess")
            : LocalizationService.Current.Get("conversation.filesMore", message.ChangedFilesRemaining.Count);
    }
    public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) => throw new NotSupportedException();
}

public sealed class ChangedFilesExpansionVisibility : IValueConverter
{
    public static readonly ChangedFilesExpansionVisibility Instance = new();
    public object? Convert(object? value, Type targetType, object? parameter, CultureInfo culture) =>
        value is ChatMessage message && message.ChangedFiles.Count > 3;
    public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) => throw new NotSupportedException();
}

public sealed class PositiveCountVisibility : IValueConverter
{
    public static readonly PositiveCountVisibility Instance = new();
    public object? Convert(object? value, Type targetType, object? parameter, CultureInfo culture) =>
        value is int count && count > 0;
    public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) => throw new NotSupportedException();
}

public sealed class RunSummaryVisibility : IValueConverter
{
    public static readonly RunSummaryVisibility Instance = new();
    public object? Convert(object? value, Type targetType, object? parameter, CultureInfo culture) => value is ChatMessage message && message.Summary is not null && message.ChangedFiles.Count == 0;
    public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) => throw new NotSupportedException();
}

public sealed class RunSummaryLabel : IValueConverter
{
    public static readonly RunSummaryLabel Instance = new();
    public object? Convert(object? value, Type targetType, object? parameter, CultureInfo culture)
    {
        if (value is not ChatMessage { Summary: { } summary }) return "";
        var files = LocalizationService.Current.Get("conversation.filesSummary", summary.AddedCount, summary.ModifiedCount, summary.DeletedCount);
        var test = summary.TestStatus == "not_reported" ? "" : $" · {LocalizationService.Current.Get("conversation.testStatus", summary.TestStatus)}";
        return $"{LocalizationService.Current.Get("conversation.runSummary")}: {files} · {summary.CleanupNote}{test}";
    }
    public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) => throw new NotSupportedException();
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

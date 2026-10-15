// Copyright (c) 2026 DOTS
// Plugin composition model derived from DeepSeek Harness.
// Copyright (c) 2026 DeepSeek. MIT. See NOTICE.

using System.Diagnostics;
using System.ComponentModel;
using System.Globalization;
using System.IO;
using Avalonia;
using Avalonia.Automation;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using AvaloniaLine = Avalonia.Controls.Shapes.Line;
using Avalonia.Controls.Templates;
using Avalonia.Input;
using Avalonia.Interactivity;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Media.Imaging;
using Avalonia.Platform;
using Avalonia.Platform.Storage;
using Avalonia.Threading;
using DotsHarnessCore;
using HarnessPluginKit;
using PluginRuntime;
using QRCoder;

namespace DotsHarness.Views;

public partial class SettingsWindow : Window
{
    private string _tab = "general";
    private string _modelContextSearch = "";
    private string? _pendingArchiveDeleteID;
    private string? _archiveStatus;
    private Conversation? _archivePreview;
    private readonly HashSet<string> _expandedArchiveToolIDs = new(StringComparer.Ordinal);
    private AppModel? _observedModel;
    private AgentBridge? _observedBridge;
    private McpRegistry? _observedMcpRegistry;
    private StackPanel? _mcpStatusRows;
    private StackPanel? _mcpHttpFields;
    private StackPanel? _mcpStdioFields;
    private TextBlock? _mcpTestStatus;
    private string _mcpName = "";
    private string _mcpUrl = "";
    private string _mcpCommand = "";
    private string _mcpArguments = "";
    private string _mcpToken = "";
    private McpTransportKind _mcpTransport = McpTransportKind.Http;
    private bool _mcpAutoRunReadOnly;
    private MemoryVault _memoryVault = MemoryVault.Empty;
    private string? _memorySelectedId;
    private string? _memoryEditingLessonId;
    private string? _memoryStatus;
    private string _memorySearch = "";
    private ListBox? _memoryList;
    private ContentControl? _memoryDetail;
    private Canvas? _memoryGraph;
    private string _accessDisplayName = "";
    private string _accessPublicKey = "";
    private string _accessInvite = "";
    private string _accessToken = "";
    private string? _accessError;
    private string _sandboxName = "agent-work";
    private MemoryRole _accessInviteRole = MemoryRole.Contributor;
    private double _accessInviteScore = 50;
    private KeyboardShortcutAction? _recordingShortcut;
    private TextBlock? _shortcutStatus;
    private readonly Dictionary<KeyboardShortcutAction, Button> _shortcutButtons = new();
    private static readonly IReadOnlyDictionary<string, string> LegacyKeys = new Dictionary<string, string>(StringComparer.Ordinal)
    {
        ["Providers"] = "settings.providers", ["Provider"] = "settings.provider", ["Connected accounts"] = "settings.connectedAccounts",
        ["Name"] = "settings.name", ["API key"] = "settings.apiKeyOptional", ["API key (optional for local)"] = "settings.apiKeyOptional", ["Browser login"] = "settings.browserLogin",
        ["Auth URL"] = "settings.authUrl", ["Paste callback URL"] = "settings.pasteCallbackUrl",
        ["Finish login"] = "settings.finishLogin", ["Device login"] = "settings.deviceLogin", ["Verify"] = "settings.verify",
        ["Add a custom endpoint"] = "settings.addCustomEndpoint", ["Prefix (model id, e.g. local)"] = "settings.prefix",
        ["Base URL"] = "settings.baseUrl", ["API"] = "settings.api", ["Custom providers"] = "settings.customProviders",
        ["Local models"] = "settings.localModels", ["Listen"] = "settings.listen", ["Serving"] = "settings.serving",
        ["Voice input"] = "settings.voice",
        ["Download and run"] = "settings.downloadRun", ["Sharing"] = "settings.sharing", ["Status"] = "settings.status",
        ["Short id"] = "settings.shortId", ["Public URL"] = "settings.publicUrl", ["Endpoint"] = "settings.endpoint",
        ["Give this to a client"] = "settings.client", ["Plugins"] = "settings.plugins", ["Last mount failed"] = "settings.lastMountFailed",
        ["Scheduled Tasks"] = "settings.scheduledTasks", ["New task"] = "settings.newTask", ["Cron expression"] = "settings.cronExpression",
        ["Prompt"] = "settings.promptField", ["Tasks"] = "settings.scheduledTasks", ["Workspace"] = "settings.workspace",
        ["Installed"] = "settings.installed", ["Not installed"] = "settings.notInstalled", ["Running"] = "settings.running",
        ["Enabled"] = "settings.enabled", ["Stopped"] = "settings.stopped", ["No prompt sections mounted."] = "settings.noPrompt",
        ["SkillsMP Popular snapshot"] = "settings.skillsSnapshot", ["Downloaded and enabled"] = "settings.skillsInstalled",
    };

    private string T(string text) => Model.L(LegacyKeys.TryGetValue(text, out var key) ? key : text);

    private AppModel Model =>
        DataContext as AppModel
        ?? (Application.Current as App)?.Model
        ?? throw new InvalidOperationException("Settings needs an AppModel");

    public SettingsWindow()
    {
        InitializeComponent();
        AddHandler(InputElement.KeyDownEvent, OnWindowKeyDown, RoutingStrategies.Tunnel);
        Opened += (_, _) => RefreshLocalization();
        DataContextChanged += (_, _) =>
        {
            if (_observedModel is not null) _observedModel.PropertyChanged -= OnModel;
            if (_observedBridge is not null) _observedBridge.PropertyChanged -= OnBridge;
            if (_observedMcpRegistry is not null) _observedMcpRegistry.PropertyChanged -= OnMcpRegistry;
            _observedModel = DataContext as AppModel;
            _observedBridge = _observedModel?.Bridge;
            _observedMcpRegistry = _observedModel?.McpRegistry;
            if (_observedModel is not null) _observedModel.PropertyChanged += OnModel;
            if (_observedBridge is not null) _observedBridge.PropertyChanged += OnBridge;
            if (_observedMcpRegistry is not null) _observedMcpRegistry.PropertyChanged += OnMcpRegistry;
            RefreshLocalization();
        };
        Closed += (_, _) =>
        {
            if (_observedModel is not null) _observedModel.PropertyChanged -= OnModel;
            if (_observedBridge is not null) _observedBridge.PropertyChanged -= OnBridge;
            if (_observedMcpRegistry is not null) _observedMcpRegistry.PropertyChanged -= OnMcpRegistry;
            _observedModel = null;
            _observedBridge = null;
            _observedMcpRegistry = null;
        };
    }

    /// <summary>Opens a settings section from the desktop shell.</summary>
    public void SelectTab(string tab)
    {
        var item = Tabs.Items.OfType<ListBoxItem>().FirstOrDefault(candidate =>
            string.Equals(candidate.Tag as string, tab, StringComparison.Ordinal));
        if (item is null) return;
        item.IsSelected = true;
        _tab = tab;
        ShowCurrentTab();
    }

    private void OnTab(object? sender, SelectionChangedEventArgs e)
    {
        if (Tabs.SelectedItem is not ListBoxItem item) return;
        _tab = item.Tag as string ?? "general";
        ShowCurrentTab();
        if (_tab == "sandbox") _ = Model.RefreshAvailableSandboxesAsync();
    }

    private void OnModel(object? sender, PropertyChangedEventArgs e)
    {
        if (_tab == "sandbox" && e.PropertyName is (nameof(AppModel.ActiveSandbox)
            or nameof(AppModel.AvailableSandboxes) or nameof(AppModel.SandboxConflict)
            or nameof(AppModel.SandboxResolutionPreview) or nameof(AppModel.SandboxNotice)
            or nameof(AppModel.SandboxRecoveryRequired) or nameof(AppModel.SandboxCleanupPending)
            or nameof(AppModel.SandboxResolutionBusy) or nameof(AppModel.SandboxNetworkAccess)))
        {
            Dispatcher.UIThread.Post(ShowSandbox);
            return;
        }
        if (e.PropertyName is nameof(AppModel.VisionState)
            or nameof(AppModel.VisionModelProgress)
            or nameof(AppModel.VisionPluginInstalled)
            or nameof(AppModel.VisionPluginEnabled))
        {
            if (_tab == "plugins") Dispatcher.UIThread.Post(ShowCurrentTab);
            return;
        }
        if (e.PropertyName is nameof(AppModel.Language) or nameof(AppModel.IsRightToLeft))
            Dispatcher.UIThread.Post(RefreshLocalization);
    }

    private void OnBridge(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(AgentBridge.ArchivedConversations) && _tab == "archive")
            Dispatcher.UIThread.Post(ShowArchive);
    }

    private void OnMcpRegistry(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(McpRegistry.Statuses) && _tab == "mcp")
            Dispatcher.UIThread.Post(RefreshMcpStatuses);
    }

    private void ShowCurrentTab()
    {
        switch (_tab)
        {
            case "providers": ShowProviders(); break;
            case "model-context": ShowModelContexts(); break;
            case "archive": ShowArchive(); break;
            case "custom": ShowCustom(); break;
            case "local": ShowLocal(); break;
            case "voice": ShowVoice(); break;
            case "share": ShowShare(); break;
            case "mobile": ShowMobile(); break;
            case "tasks": ShowTasks(); break;
            case "skills": ShowSkills(); break;
            case "plugins": ShowPlugins(); break;
            case "mcp": ShowMcp(); break;
            case "memory": ShowMemory(); break;
            case "access": ShowAccess(); break;
            case "sandbox": ShowSandbox(); break;
            case "prompt": ShowPrompt(); break;
            case "legal": ShowLegal(); break;
            default: ShowGeneral(); break;
        }
    }

    private void RefreshLocalization()
    {
        var model = Model;
        Title = model.L("settings.title");
        FlowDirection = model.IsRightToLeft ? Avalonia.Media.FlowDirection.RightToLeft : Avalonia.Media.FlowDirection.LeftToRight;
        Tabs.Items.OfType<ListBoxItem>().FirstOrDefault(item => Equals(item.Tag, "general"))!.Content = model.L("settings.general");
        Tabs.Items.OfType<ListBoxItem>().FirstOrDefault(item => Equals(item.Tag, "model-context"))!.Content = model.L("usage.context.window");
        Tabs.Items.OfType<ListBoxItem>().FirstOrDefault(item => Equals(item.Tag, "archive"))!.Content = model.L("settings.archive");
        Tabs.Items.OfType<ListBoxItem>().FirstOrDefault(item => Equals(item.Tag, "providers"))!.Content = model.L("settings.providers");
        Tabs.Items.OfType<ListBoxItem>().FirstOrDefault(item => Equals(item.Tag, "custom"))!.Content = model.L("settings.custom");
        Tabs.Items.OfType<ListBoxItem>().FirstOrDefault(item => Equals(item.Tag, "local"))!.Content = model.L("settings.localModels");
        Tabs.Items.OfType<ListBoxItem>().FirstOrDefault(item => Equals(item.Tag, "voice"))!.Content = model.L("settings.voice");
        Tabs.Items.OfType<ListBoxItem>().FirstOrDefault(item => Equals(item.Tag, "share"))!.Content = model.L("settings.share");
        Tabs.Items.OfType<ListBoxItem>().FirstOrDefault(item => Equals(item.Tag, "mobile"))!.Content = "Mobile control";
        Tabs.Items.OfType<ListBoxItem>().FirstOrDefault(item => Equals(item.Tag, "tasks"))!.Content = model.L("settings.tasks");
        Tabs.Items.OfType<ListBoxItem>().FirstOrDefault(item => Equals(item.Tag, "skills"))!.Content = model.L("conversation.skills");
        Tabs.Items.OfType<ListBoxItem>().FirstOrDefault(item => Equals(item.Tag, "plugins"))!.Content = model.L("settings.plugins");
        Tabs.Items.OfType<ListBoxItem>().FirstOrDefault(item => Equals(item.Tag, "mcp"))!.Content = model.L("settings.mcpServers");
        Tabs.Items.OfType<ListBoxItem>().FirstOrDefault(item => Equals(item.Tag, "memory"))!.Content = model.L("settings.tab.memory");
        Tabs.Items.OfType<ListBoxItem>().FirstOrDefault(item => Equals(item.Tag, "access"))!.Content = model.L("settings.tab.access");
        Tabs.Items.OfType<ListBoxItem>().FirstOrDefault(item => Equals(item.Tag, "sandbox"))!.Content = model.L("settings.sandbox");
        Tabs.Items.OfType<ListBoxItem>().FirstOrDefault(item => Equals(item.Tag, "prompt"))!.Content = model.L("settings.systemPrompt");
        Tabs.Items.OfType<ListBoxItem>().FirstOrDefault(item => Equals(item.Tag, "legal"))!.Content = model.L("legal.title");
        ShowCurrentTab();
    }

    private void ShowArchive()
    {
        var panel = new StackPanel();
        if (_archivePreview is { } selected)
        {
            panel.Children.Add(ArchiveTranscript(selected));
            Body.Content = panel;
            return;
        }

        panel.Children.Add(new TextBlock
        {
            Text = Model.L("archive.title"),
            FontSize = 22,
            FontWeight = FontWeight.SemiBold,
            Margin = new Avalonia.Thickness(0, 0, 0, 16),
        });
        if (!string.IsNullOrWhiteSpace(_archiveStatus))
            panel.Children.Add(new TextBlock
            {
                Text = _archiveStatus,
                Foreground = TryBrush("TextSecondary"),
                TextWrapping = TextWrapping.Wrap,
                Margin = new Avalonia.Thickness(0, 0, 0, 10),
            });

        var archived = Model.Bridge.ArchivedConversations;
        if (archived.Count == 0)
        {
            panel.Children.Add(new TextBlock
            {
                Text = Model.L("archive.empty"),
                Foreground = TryBrush("TextSecondary"),
            });
        }
        foreach (var conversation in archived)
        {
            var row = new StackPanel();
            row.Children.Add(new TextBlock
            {
                Text = conversation.Title,
                FontWeight = FontWeight.SemiBold,
                TextTrimming = TextTrimming.CharacterEllipsis,
            });
            if (!string.IsNullOrWhiteSpace(conversation.Cwd))
                row.Children.Add(new TextBlock
                {
                    Text = conversation.Cwd,
                    FontSize = 11,
                    Foreground = TryBrush("TextSecondary"),
                    TextTrimming = TextTrimming.CharacterEllipsis,
                    Margin = new Avalonia.Thickness(0, 3, 0, 0),
                });

            var actions = new StackPanel
            {
                Orientation = Orientation.Horizontal,
                Margin = new Avalonia.Thickness(0, 10, 0, 0),
            };
            if (_pendingArchiveDeleteID == conversation.Id)
            {
                actions.Children.Add(new TextBlock
                {
                    Text = Model.L("archive.confirmDelete"),
                    VerticalAlignment = VerticalAlignment.Center,
                    Margin = new Avalonia.Thickness(0, 0, 10, 0),
                });
                var confirmDelete = new Button
                {
                    Content = Model.L("archive.deletePermanently"),
                    Margin = new Avalonia.Thickness(0, 0, 6, 0),
                    Padding = new Avalonia.Thickness(10, 4, 10, 4),
                };
                confirmDelete.Click += (_, _) =>
                {
                    _archiveStatus = Model.Bridge.DeleteConversation(conversation.Id)
                        ? null
                        : Model.L("archive.deleteFailed");
                    if (_archivePreview?.Id == conversation.Id) _archivePreview = null;
                    _pendingArchiveDeleteID = null;
                    ShowArchive();
                };
                actions.Children.Add(confirmDelete);
                var cancelDelete = new Button
                {
                    Content = Model.L("archive.cancel"),
                    Padding = new Avalonia.Thickness(10, 4, 10, 4),
                };
                cancelDelete.Click += (_, _) => { _pendingArchiveDeleteID = null; ShowArchive(); };
                actions.Children.Add(cancelDelete);
            }
            else
            {
                var view = new Button
                {
                    Content = Model.L("settings.view"),
                    Margin = new Avalonia.Thickness(0, 0, 6, 0),
                    Padding = new Avalonia.Thickness(10, 4, 10, 4),
                };
                view.Click += (_, _) =>
                {
                    _archivePreview = Model.Bridge.LoadArchivedConversation(conversation.Id);
                    _expandedArchiveToolIDs.Clear();
                    ShowArchive();
                };
                actions.Children.Add(view);
                var restore = new Button
                {
                    Content = Model.L("archive.restore"),
                    Margin = new Avalonia.Thickness(0, 0, 6, 0),
                    Padding = new Avalonia.Thickness(10, 4, 10, 4),
                };
                restore.Click += (_, _) =>
                {
                    _archiveStatus = Model.Bridge.SetArchived(conversation.Id, false)
                        ? null
                        : Model.L("archive.restoreFailed");
                    if (_archivePreview?.Id == conversation.Id) _archivePreview = null;
                    ShowArchive();
                };
                actions.Children.Add(restore);
                var delete = new Button
                {
                    Content = Model.L("archive.delete"),
                    Padding = new Avalonia.Thickness(10, 4, 10, 4),
                };
                delete.Click += (_, _) => { _archiveStatus = null; _pendingArchiveDeleteID = conversation.Id; ShowArchive(); };
                actions.Children.Add(delete);
            }
            row.Children.Add(actions);
            panel.Children.Add(new Border
            {
                Padding = new Avalonia.Thickness(12),
                Margin = new Avalonia.Thickness(0, 0, 0, 10),
                BorderBrush = TryBrush("BorderSubtle"),
                BorderThickness = new Avalonia.Thickness(1),
                CornerRadius = new Avalonia.CornerRadius(8),
                Child = row,
            });
        }
        Body.Content = panel;
    }

    private Control ArchiveTranscript(Conversation conversation)
    {
        var detail = new StackPanel { Spacing = 8 };
        var actions = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Margin = new Avalonia.Thickness(0, 0, 0, 6),
        };
        var back = new Button
        {
            Content = $"‹  {Model.L("archive.title")}",
            Margin = new Avalonia.Thickness(0, 0, 6, 0),
            Padding = new Avalonia.Thickness(10, 4, 10, 4),
        };
        back.Click += (_, _) =>
        {
            _archivePreview = null;
            _expandedArchiveToolIDs.Clear();
            ShowArchive();
        };
        actions.Children.Add(back);
        var restore = new Button
        {
            Content = Model.L("archive.restore"),
            Margin = new Avalonia.Thickness(0, 0, 6, 0),
            Padding = new Avalonia.Thickness(10, 4, 10, 4),
        };
        restore.Click += (_, _) =>
        {
            _archiveStatus = Model.Bridge.SetArchived(conversation.Id, false)
                ? null
                : Model.L("archive.restoreFailed");
            _archivePreview = null;
            _expandedArchiveToolIDs.Clear();
            ShowArchive();
        };
        actions.Children.Add(restore);
        var delete = new Button
        {
            Content = Model.L("archive.delete"),
            Padding = new Avalonia.Thickness(10, 4, 10, 4),
        };
        delete.Click += (_, _) =>
        {
            _archiveStatus = null;
            _pendingArchiveDeleteID = conversation.Id;
            _archivePreview = null;
            _expandedArchiveToolIDs.Clear();
            ShowArchive();
        };
        actions.Children.Add(delete);
        detail.Children.Add(actions);
        detail.Children.Add(new TextBlock
        {
            Text = conversation.Title,
            FontSize = 18,
            FontWeight = FontWeight.SemiBold,
            TextWrapping = TextWrapping.Wrap,
        });
        if (!string.IsNullOrWhiteSpace(conversation.Cwd))
            detail.Children.Add(new TextBlock
            {
                Text = conversation.Cwd,
                FontSize = 11,
                Foreground = TryBrush("TextSecondary"),
                TextWrapping = TextWrapping.Wrap,
                Margin = new Avalonia.Thickness(0, 0, 0, 8),
            });

        var messages = new StackPanel();
        if (conversation.Messages.Count == 0)
        {
            messages.Children.Add(new TextBlock
            {
                Text = "—",
                Foreground = TryBrush("TextSecondary"),
            });
        }
        foreach (var message in conversation.Messages)
        {
            if (message.Kind == ChatKind.Tool)
            {
                var isExpanded = _expandedArchiveToolIDs.Contains(message.Id);
                var toolToggle = new Button
                {
                    Content = $"{(isExpanded ? "▾" : "▸")}  {Model.L("conversation.tool")} · {ArchiveToolSummary(message.Text)}",
                    HorizontalContentAlignment = HorizontalAlignment.Left,
                    Padding = new Avalonia.Thickness(10, 8, 10, 8),
                };
                toolToggle.Click += (_, _) =>
                {
                    if (!_expandedArchiveToolIDs.Add(message.Id))
                        _expandedArchiveToolIDs.Remove(message.Id);
                    ShowArchive();
                };
                var toolContent = new StackPanel { Spacing = 4 };
                toolContent.Children.Add(toolToggle);
                if (isExpanded)
                {
                    toolContent.Children.Add(new Border
                    {
                        Padding = new Avalonia.Thickness(10),
                        Background = TryBrush("ChromeBackground"),
                        CornerRadius = new Avalonia.CornerRadius(6),
                        Child = new TextBlock
                        {
                            Text = string.IsNullOrWhiteSpace(message.RawToolOutput)
                                ? message.Text
                                : message.RawToolOutput,
                            TextWrapping = TextWrapping.Wrap,
                            FontFamily = new FontFamily("Consolas"),
                            Foreground = TryBrush("TextPrimary"),
                        },
                    });
                }
                messages.Children.Add(new Border
                {
                    Margin = new Avalonia.Thickness(0, 0, 0, 8),
                    BorderBrush = TryBrush("BorderSubtle"),
                    BorderThickness = new Avalonia.Thickness(1),
                    CornerRadius = new Avalonia.CornerRadius(6),
                    Child = toolContent,
                });
                continue;
            }

            var body = string.Join("\n", new[] { message.Text }
                .Concat(message.Attachments.Select(attachment => attachment.Name))
                .Where(value => !string.IsNullOrWhiteSpace(value)));
            var content = new StackPanel { Spacing = 4 };
            content.Children.Add(new TextBlock
            {
                Text = $"{Model.L(message.Kind switch
                {
                    ChatKind.User => "conversation.you",
                    ChatKind.Assistant => "conversation.assistant",
                    ChatKind.Plan => "conversation.plan",
                    _ => "conversation.system",
                })} · {message.CreatedAt.ToLocalTime():g}",
                FontSize = 11,
                FontWeight = FontWeight.SemiBold,
                Foreground = TryBrush("TextSecondary"),
            });
            content.Children.Add(new TextBlock
            {
                Text = string.IsNullOrWhiteSpace(body) ? "—" : body,
                TextWrapping = TextWrapping.Wrap,
                Foreground = TryBrush("TextPrimary"),
            });
            messages.Children.Add(new Border
            {
                Padding = new Avalonia.Thickness(10),
                Margin = new Avalonia.Thickness(0, 0, 0, 8),
                Background = TryBrush("ChromeBackground"),
                CornerRadius = new Avalonia.CornerRadius(6),
                Child = content,
            });
        }
        detail.Children.Add(new ScrollViewer
        {
            Content = messages,
            MaxHeight = 560,
            VerticalScrollBarVisibility = Avalonia.Controls.Primitives.ScrollBarVisibility.Auto,
            Margin = new Avalonia.Thickness(0, 10, 0, 0),
        });
        return detail;
    }

    private string ArchiveToolSummary(string text)
    {
        var firstLine = text.Split('\n', StringSplitOptions.RemoveEmptyEntries)
            .Select(line => line.Trim())
            .FirstOrDefault(line => line.Length > 0);
        if (string.IsNullOrWhiteSpace(firstLine)) return Model.L("conversation.tool");
        return firstLine.Length > 120 ? firstLine[..120] : firstLine;
    }

    private void ShowGeneral()
    {
        _recordingShortcut = null;
        _shortcutButtons.Clear();
        var panel = new StackPanel();
        panel.Children.Add(Heading("settings.general"));
        panel.Children.Add(Label("settings.language"));
        var language = new ComboBox { Margin = new Thickness(0, 0, 0, 12) };
        foreach (var item in Model.Localization.Languages)
            language.Items.Add(item == AppLanguage.System ? Model.L("language.system") : item.NativeName());
        language.SelectedIndex = Array.IndexOf(AppLanguages.All.ToArray(), Model.Language);
        language.SelectionChanged += (_, _) =>
        {
            if (language.SelectedIndex >= 0 && language.SelectedIndex < AppLanguages.All.Count)
                Model.SetAppLanguage(AppLanguages.All[language.SelectedIndex]);
        };
        panel.Children.Add(language);
        panel.Children.Add(Label("settings.appearance"));
        var appearance = new ComboBox { Margin = new Thickness(0, 0, 0, 12) };
        var appearanceKinds = Enum.GetValues<AppModel.AppearanceKind>();
        foreach (var kind in appearanceKinds) appearance.Items.Add(AppearanceLabel(kind));
        appearance.SelectedIndex = Array.IndexOf(appearanceKinds, Model.Appearance);
        appearance.SelectionChanged += (_, _) =>
        {
            if (appearance.SelectedIndex >= 0 && appearance.SelectedIndex < appearanceKinds.Length)
            {
                var kind = appearanceKinds[appearance.SelectedIndex];
                Model.SetAppearance(kind);
                (Application.Current as App)?.ApplyAppearance(kind);
            }
        };
        panel.Children.Add(appearance);
        AddKeyboardShortcutEditor(panel);
        var subagents = new CheckBox
        {
            Content = Model.Language == AppLanguage.Turkish ? "Alt ajanları kullan" : "Use subagents",
            IsChecked = Model.SubagentsEnabled,
            Margin = new Thickness(0, 0, 0, 4),
        };
        subagents.IsCheckedChanged += (_, _) => Model.SetSubagentsEnabled(subagents.IsChecked == true);
        panel.Children.Add(subagents);
        panel.Children.Add(new TextBlock
        {
            Text = Model.Language == AppLanguage.Turkish
                ? "Açıkken ajan, zor ve uzun görevlerde çok dosyalı aramaları ve birbirinden bağımsız düzenleme parçalarını paralel alt ajanlara devreder; ana konuşmaya yalnızca özet girer. Düzenleyen her alt ajan yalnızca kendisine atanan dosyalara yazabilir, atamalar çakışamaz. Basit görevlerde çağırmaz. Her alt ajan ayrı model çağrısıdır; maliyeti düşürmek için kapatın. Seçim yapılmadıysa Ekonomi modunda kapalıdır."
                : "When on, the agent hands searches that sweep many files, and independent parts of a large change, to parallel subagents on hard or long tasks; only their summary enters the main conversation. An editing subagent can write only the files assigned to it, and assignments cannot overlap. Simple tasks never call one. Each subagent is a separate model run; turn this off to lower cost. Until you choose, it is off in Economy mode.",
            FontSize = 11,
            Foreground = TryBrush("TextSecondary"),
            TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(0, 0, 0, 12),
        });
        panel.Children.Add(Label(ResponseStyleTitle()));
        var responseStyle = new ComboBox { Margin = new Thickness(0, 0, 0, 4) };
        var responseStyles = Enum.GetValues<AgentResponseStylePreference>();
        foreach (var preference in responseStyles) responseStyle.Items.Add(ResponseStyleLabel(preference));
        responseStyle.SelectedIndex = Array.IndexOf(responseStyles, Model.ResponseStylePreference);
        responseStyle.SelectionChanged += (_, _) =>
        {
            if (responseStyle.SelectedIndex >= 0 && responseStyle.SelectedIndex < responseStyles.Length)
                Model.SetResponseStylePreference(responseStyles[responseStyle.SelectedIndex]);
        };
        panel.Children.Add(responseStyle);
        panel.Children.Add(new TextBlock
        {
            Text = Model.Language == AppLanguage.Turkish
                ? "Bu ayar promptu değiştirmez. Kısa/ultra tercihi best-effort'tur; kesin token, tamamlanma veya maliyet garantisi vermez."
                : "This setting does not rewrite the prompt. Concise/Ultra are best-effort preferences; they do not guarantee a token count, completion, or lower cost.",
            FontSize = 11,
            Foreground = TryBrush("TextSecondary"),
            TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(0, 0, 0, 12),
        });
        panel.Children.Add(new TextBlock
        {
            Text = Model.Language == AppLanguage.Turkish ? "Bağlamı otomatik sıkıştırma eşiği" : "Auto-compact context at",
            Margin = new Thickness(0, 0, 0, 4),
        });
        var compactValue = new TextBox
        {
            Width = 64,
            Text = Model.UsageMode == AgentUsageMode.Economy ? "90" : Model.ContextCompactionThresholdPercent.ToString(),
            IsReadOnly = Model.UsageMode == AgentUsageMode.Economy,
            VerticalContentAlignment = VerticalAlignment.Center,
            TextAlignment = TextAlignment.Center,
        };
        TextBlock? compactThresholdLabel = null;
        string CompactThresholdLabelText()
        {
            var selectedModel = Model.SelectedModelID;
            var isAutoModel = string.IsNullOrWhiteSpace(selectedModel) || selectedModel == "auto";
            var compactPercentForModel = Model.UsageMode == AgentUsageMode.Economy ? 90 : Model.ContextCompactionThresholdPercent;
            var economy = Model.UsageMode == AgentUsageMode.Economy;
            if (isAutoModel && !economy)
            {
                return Model.Language == AppLanguage.Turkish
                    ? $"Otomatik modelde her modelin penceresinin %{compactPercentForModel}'i"
                    : $"Auto-routed models: {compactPercentForModel}% of each model's window";
            }
            var compactThreshold = isAutoModel
                ? ContextCompaction.EconomyReplayTokenLimit
                : ContextCompaction.NativeThreshold(
                    Model.Router.ContextWindowFor(selectedModel),
                    compactPercentForModel,
                    Model.UsageMode == AgentUsageMode.Economy);
            var compactCount = compactThreshold.ToString("N0", CultureInfo.GetCultureInfo(
                Model.Language == AppLanguage.Turkish ? "tr-TR" : "en-US"));
            return isAutoModel
                ? (Model.Language == AppLanguage.Turkish
                    ? $"Otomatik modelde en çok {compactCount} token"
                    : $"Auto-routed models: up to {compactCount} tokens")
                : (Model.Language == AppLanguage.Turkish
                    ? $"Etkin eşik: {compactCount} token"
                    : $"Effective threshold: {compactCount} tokens");
        }
        void RefreshCompactThresholdLabel()
        {
            if (compactThresholdLabel is not null) compactThresholdLabel.Text = CompactThresholdLabelText();
        }
        void SetCompactPercent(int value)
        {
            var normalized = Math.Clamp(value, 0, 100);
            Model.SetContextCompactionThresholdPercent(normalized);
            compactValue.Text = normalized.ToString();
            RefreshCompactThresholdLabel();
        }
        void CommitCompactPercent()
        {
            if (int.TryParse(compactValue.Text, out var value)) SetCompactPercent(value);
            else compactValue.Text = Model.ContextCompactionThresholdPercent.ToString();
        }
        compactValue.LostFocus += (_, _) => CommitCompactPercent();
        var compactControls = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 0, 0, 4) };
        var compactMinus = new Button { Content = "−", Margin = new Thickness(0, 0, 6, 0), Padding = new Thickness(10, 2, 10, 2), IsEnabled = Model.UsageMode != AgentUsageMode.Economy };
        compactMinus.Click += (_, _) => SetCompactPercent((int.TryParse(compactValue.Text, out var value) ? value : Model.ContextCompactionThresholdPercent) - 1);
        var compactPlus = new Button { Content = "+", Margin = new Thickness(6, 0, 0, 0), Padding = new Thickness(10, 2, 10, 2), IsEnabled = Model.UsageMode != AgentUsageMode.Economy };
        compactPlus.Click += (_, _) => SetCompactPercent((int.TryParse(compactValue.Text, out var value) ? value : Model.ContextCompactionThresholdPercent) + 1);
        compactControls.Children.Add(compactMinus);
        compactControls.Children.Add(compactValue);
        compactControls.Children.Add(new TextBlock { Text = "%", VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(6, 0, 0, 0) });
        compactControls.Children.Add(compactPlus);
        panel.Children.Add(compactControls);
        if (Model.UsageMode == AgentUsageMode.Economy)
        {
            ToolTip.SetTip(compactControls, Model.Language == AppLanguage.Turkish
                ? "Ekonomi politikasında eşik sabit olarak %90'dır."
                : "Economy policy uses a fixed 90% threshold.");
        }
        panel.Children.Add(new TextBlock
        {
            Text = Model.Language == AppLanguage.Turkish
                ? "Her modelin kendi bağlam penceresinin yüzdesi. Daha yüksek değer, sıkıştırmayı ve önbellek önekinin yeniden yazılmasını geciktirir."
                : "Percentage of the selected model's context window. Higher values delay compaction and rewriting the cache prefix.",
            FontSize = 11,
            Foreground = TryBrush("TextSecondary"),
            TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(0, 0, 0, 12),
        });
        compactThresholdLabel = new TextBlock
        {
            Text = CompactThresholdLabelText(),
            FontSize = 11,
            Foreground = TryBrush("TextSecondary"),
            Margin = new Thickness(0, -8, 0, 12),
        };
        panel.Children.Add(compactThresholdLabel);
        panel.Children.Add(Label("settings.workspaceConflictPolicy"));
        var conflictPolicies = new[]
        {
            (Policy: WorkspaceConflictPolicy.WaitThenAsk, Key: "waitThenAsk"),
            (Policy: WorkspaceConflictPolicy.Ask, Key: "ask"),
            (Policy: WorkspaceConflictPolicy.WaitOnly, Key: "waitOnly"),
        };
        var conflictPolicy = new ComboBox { Margin = new Thickness(0, 0, 0, 4) };
        foreach (var item in conflictPolicies)
            conflictPolicy.Items.Add(Model.L("conflict.policy." + item.Key));
        conflictPolicy.SelectedIndex = Array.FindIndex(conflictPolicies, item => item.Policy == Model.WorkspaceConflictPolicy);
        var conflictPolicyDetail = new TextBlock
        {
            Text = Model.L("conflict.policy." + conflictPolicies[Math.Max(0, conflictPolicy.SelectedIndex)].Key + ".detail"),
            FontSize = 11,
            Foreground = TryBrush("TextSecondary"),
            TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(0, 0, 0, 8),
        };
        ComboBox? conflictWait = null;
        conflictPolicy.SelectionChanged += (_, _) =>
        {
            if (conflictPolicy.SelectedIndex < 0 || conflictPolicy.SelectedIndex >= conflictPolicies.Length) return;
            var selectedPolicy = conflictPolicies[conflictPolicy.SelectedIndex];
            Model.SetWorkspaceConflictPolicy(selectedPolicy.Policy);
            conflictPolicyDetail.Text = Model.L("conflict.policy." + selectedPolicy.Key + ".detail");
            if (conflictWait is not null)
                conflictWait.IsEnabled = selectedPolicy.Policy == WorkspaceConflictPolicy.WaitThenAsk;
        };
        panel.Children.Add(conflictPolicy);
        panel.Children.Add(conflictPolicyDetail);
        panel.Children.Add(Label("settings.conflictWaitSeconds"));
        var waitChoices = new[] { 10, 30, 60, 120 };
        conflictWait = new ComboBox { Margin = new Thickness(0, 0, 0, 12) };
        foreach (var seconds in waitChoices)
            conflictWait.Items.Add(Model.L("settings.conflictWaitValue", seconds));
        conflictWait.SelectedIndex = Array.IndexOf(waitChoices, Model.ConflictWaitSeconds);
        if (conflictWait.SelectedIndex < 0) conflictWait.SelectedIndex = 1;
        conflictWait.IsEnabled = Model.WorkspaceConflictPolicy == WorkspaceConflictPolicy.WaitThenAsk;
        conflictWait.SelectionChanged += (_, _) =>
        {
            if (conflictWait.SelectedIndex >= 0 && conflictWait.SelectedIndex < waitChoices.Length)
                Model.SetConflictWaitSeconds(waitChoices[conflictWait.SelectedIndex]);
        };
        panel.Children.Add(conflictWait);
        panel.Children.Add(Label("Browser backend"));
        var browserBackends = new (string Label, BrowserBackend? Value)[]
        {
            ("In-App Native Live Browser (WebKit)", BrowserBackend.Native),
            ("Automatic (ask when unclear)", null),
            ("Managed isolated browser", BrowserBackend.Managed),
            ("Existing Chrome profile", BrowserBackend.Extension),
        };
        var browser = new ComboBox { Margin = new Thickness(0, 0, 0, 4) };
        foreach (var choice in browserBackends) browser.Items.Add(choice.Label);
        browser.SelectedIndex = Model.SelectedBrowserBackend switch
        {
            BrowserBackend.Native => 0,
            BrowserBackend.Managed => 2,
            BrowserBackend.Extension => 3,
            _ => 1,
        };
        browser.SelectionChanged += (_, _) =>
        {
            if (browser.SelectedIndex >= 0 && browser.SelectedIndex < browserBackends.Length)
                Model.SetBrowserBackend(browserBackends[browser.SelectedIndex].Value);
        };
        panel.Children.Add(browser);
        panel.Children.Add(new TextBlock
        {
            Text = "The selected backend is fixed for each run. The in-app browser uses the system WebKit runtime; the managed Chrome and extension backends remain available.",
            FontSize = 11,
            Foreground = TryBrush("TextSecondary"),
            TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(0, 0, 0, 12),
        });
        var confirmBeforeExit = new CheckBox
        {
            Content = Model.L("settings.confirmBeforeExit"),
            IsChecked = Model.ConfirmBeforeExit,
            Margin = new Thickness(0, 0, 0, 12),
        };
        confirmBeforeExit.IsCheckedChanged += (_, _) => Model.SetConfirmBeforeExit(confirmBeforeExit.IsChecked == true);
        panel.Children.Add(confirmBeforeExit);
        var closeToTray = new CheckBox
        {
            Content = Model.L("settings.closeToTray"),
            IsChecked = Model.CloseToTray,
            Margin = new Thickness(0, 0, 0, 4),
        };
        closeToTray.IsCheckedChanged += (_, _) => Model.SetCloseToTray(closeToTray.IsChecked == true);
        panel.Children.Add(closeToTray);
        panel.Children.Add(new TextBlock
        {
            Text = Model.L("settings.closeToTray.hint"),
            FontSize = 11,
            Foreground = TryBrush("TextSecondary"),
            TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(0, 0, 0, 12),
        });
        var selfVerification = new CheckBox
        {
            Content = Model.L("settings.selfVerification"),
            IsChecked = Model.SelfVerification,
            Margin = new Thickness(0, 0, 0, 12),
        };
        selfVerification.IsCheckedChanged += (_, _) => Model.SetSelfVerification(selfVerification.IsChecked == true);
        panel.Children.Add(selfVerification);
        var computerUse = new CheckBox
        {
            Content = Model.Language == AppLanguage.Turkish ? "Uygulamaları ekran üzerinden kontrol et (Computer Use)" : "Inspect and control desktop applications (Computer Use)",
            IsChecked = Model.IsComputerUseEnabled,
            Margin = new Thickness(0, 0, 0, 4),
        };
        computerUse.IsCheckedChanged += (_, _) => Model.SetComputerUseEnabled(computerUse.IsChecked == true);
        panel.Children.Add(computerUse);
        panel.Children.Add(new TextBlock
        {
            Text = Model.Language == AppLanguage.Turkish
                ? "Ajan ekranı inceleyebilir, fare ve klavyeyle işlem yapıp sonucu kontrol edebilir. X11, xdotool ve maim veya ImageMagick gerekir; Wayland desteklenmez. Masaüstü işlemleri erişim onayına tabidir."
                : "The agent can view screenshots, use the mouse and keyboard, and verify results. Requires X11, xdotool and maim or ImageMagick; Wayland is unavailable. Desktop actions require access approval.",
            TextWrapping = TextWrapping.Wrap, FontSize = 11, Margin = new Thickness(0, 0, 0, 12),
        });
        var seedProjectRules = new CheckBox
        {
            Content = Model.L("settings.seedProjectRules"),
            IsChecked = Model.SeedProjectRules,
            Margin = new Thickness(0, 0, 0, 12),
        };
        seedProjectRules.IsCheckedChanged += (_, _) => Model.SetSeedProjectRules(seedProjectRules.IsChecked == true);
        panel.Children.Add(seedProjectRules);
        var autoApprovePlans = new CheckBox
        {
            Content = Model.L("settings.autoApprovePlans"),
            IsChecked = Model.AutoApprovePlans,
            Margin = new Thickness(0, 0, 0, 12),
        };
        autoApprovePlans.IsCheckedChanged += (_, _) => Model.SetAutoApprovePlans(autoApprovePlans.IsChecked == true);
        panel.Children.Add(autoApprovePlans);
        if (!string.IsNullOrWhiteSpace(Model.WorkspacePath))
        {
            panel.Children.Add(BoundField("settings.workspace", Model.WorkspacePath, value => Model.SetWorkspace(value)));
            if (Model.Bridge.Connection is { } info)
            {
                panel.Children.Add(Readonly("settings.connectedModel", $"{info.Provider}/{info.Model}"));
                panel.Children.Add(Readonly("settings.workspace", info.Workspace));
            }
        }
        panel.Children.Add(Readonly("settings.supportFolder", Model.Paths.Root));
        panel.Children.Add(Readonly("settings.userPlugins", Model.Paths.Plugins));
        panel.Children.Add(new TextBlock
        {
            Text = Model.L("copyright"),
            FontSize = 11,
            Foreground = TryBrush("TextSecondary"),
            TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(0, 12, 0, 12),
        });
        panel.Children.Add(new SlotHost { Slot = WellKnownSlot.SettingsSections, Registry = Model.Host.Slots });
        Body.Content = panel;
    }

    private void AddKeyboardShortcutEditor(Panel parent)
    {
        parent.Children.Add(Heading("settings.shortcuts"));
        parent.Children.Add(new TextBlock
        {
            Text = Model.L("settings.shortcuts.hint"),
            FontSize = 11,
            Foreground = TryBrush("TextSecondary"),
            TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(0, 0, 0, 8),
        });
        foreach (var action in KeyboardShortcutCatalog.Actions)
        {
            var row = new Grid { Margin = new Thickness(0, 2, 0, 2) };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            var title = new TextBlock
            {
                Text = Model.KeyboardShortcutTitle(action),
                VerticalAlignment = VerticalAlignment.Center,
                TextWrapping = TextWrapping.Wrap,
                Margin = new Thickness(0, 0, 10, 0),
            };
            var button = new Button
            {
                MinWidth = 138,
                Padding = new Thickness(8, 4),
                HorizontalContentAlignment = HorizontalAlignment.Center,
                Content = Model.ShortcutFor(action).DisplayValue,
            };
            button.Click += (_, _) => BeginShortcutCapture(action);
            Grid.SetColumn(title, 0);
            Grid.SetColumn(button, 1);
            row.Children.Add(title);
            row.Children.Add(button);
            parent.Children.Add(row);
            _shortcutButtons[action] = button;
        }

        _shortcutStatus = new TextBlock
        {
            FontSize = 11,
            Foreground = TryBrush("TextSecondary"),
            TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(0, 6, 0, 4),
        };
        parent.Children.Add(_shortcutStatus);
        var reset = new Button
        {
            Content = Model.L("settings.shortcuts.reset"),
            HorizontalAlignment = HorizontalAlignment.Left,
            Margin = new Thickness(0, 0, 0, 12),
            Padding = new Thickness(10, 4),
        };
        reset.Click += (_, _) =>
        {
            _recordingShortcut = null;
            Model.ResetKeyboardShortcuts();
            SetShortcutStatus("");
            RefreshShortcutButtons();
        };
        parent.Children.Add(reset);
    }

    private void BeginShortcutCapture(KeyboardShortcutAction action)
    {
        _recordingShortcut = action;
        SetShortcutStatus("");
        RefreshShortcutButtons();
        if (_shortcutButtons.TryGetValue(action, out var button)) button.Focus();
    }

    private bool HandleShortcutKey(string key, byte modifiers)
    {
        if (_recordingShortcut is not { } action) return false;
        if (UserKeyboardShortcut.TryNormalizeKey(key, out var normalized) && normalized == "ESCAPE")
        {
            _recordingShortcut = null;
            SetShortcutStatus("");
            RefreshShortcutButtons();
            return true;
        }
        if (!UserKeyboardShortcut.TryNormalizeKey(key, out normalized)
            || modifiers == 0
            || (modifiers & UserKeyboardShortcut.AllModifiers) != modifiers)
        {
            SetShortcutStatus(Model.L("settings.shortcuts.hint"));
            return true;
        }

        var shortcut = new UserKeyboardShortcut(normalized, modifiers);
        var result = Model.UpdateShortcut(action, shortcut);
        _recordingShortcut = null;
        if (result.Status == KeyboardShortcutUpdateStatus.Conflict && result.ConflictingAction is { } conflict)
        {
            SetShortcutStatus(Model.L(
                "settings.shortcuts.conflict",
                shortcut.DisplayValue,
                Model.KeyboardShortcutTitle(conflict)));
        }
        else SetShortcutStatus("");
        RefreshShortcutButtons();
        return true;
    }

    private void RefreshShortcutButtons()
    {
        foreach (var (action, button) in _shortcutButtons)
        {
            button.Content = _recordingShortcut == action
                ? Model.L("settings.shortcuts.pressKeys")
                : Model.ShortcutFor(action).DisplayValue;
        }
    }

    private void SetShortcutStatus(string value)
    {
        if (_shortcutStatus is not null) _shortcutStatus.Text = value;
    }

    private void OnWindowKeyDown(object? sender, KeyEventArgs e)
    {
        var modifiers = ShortcutModifierMask(e.KeyModifiers);
        var key = e.Key.ToString();
        if (HandleShortcutKey(key, modifiers))
        {
            e.Handled = true;
            return;
        }
        if (Model.TryGetShortcutAction(key, modifiers, out var action)
            && Owner is MainWindow owner)
        {
            Close();
            owner.DispatchShortcut(action);
            e.Handled = true;
        }
    }

    private static byte ShortcutModifierMask(KeyModifiers modifiers)
    {
        byte mask = 0;
        if (modifiers.HasFlag(KeyModifiers.Control)) mask |= UserKeyboardShortcut.Control;
        if (modifiers.HasFlag(KeyModifiers.Alt)) mask |= UserKeyboardShortcut.Alt;
        if (modifiers.HasFlag(KeyModifiers.Shift)) mask |= UserKeyboardShortcut.Shift;
        if (modifiers.HasFlag(KeyModifiers.Meta)) mask |= UserKeyboardShortcut.Super;
        return mask;
    }

    private void ShowModelContexts()
    {
        var router = Model.Router;
        var panel = new StackPanel();
        panel.Children.Add(new TextBlock
        {
            Text = Model.L("usage.context.window"),
            FontSize = 22,
            FontWeight = FontWeight.SemiBold,
            Margin = new Avalonia.Thickness(0, 0, 0, 8),
        });
        panel.Children.Add(new TextBlock
        {
            Text = Model.L("model.context.description"),
            TextWrapping = TextWrapping.Wrap,
            Foreground = TryBrush("TextSecondary"),
            Margin = new Avalonia.Thickness(0, 0, 0, 12),
        });

        var toolbar = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Avalonia.Thickness(0, 0, 0, 12) };
        var search = new TextBox
        {
            Text = _modelContextSearch,
            Watermark = Model.L("model.context.search"),
            MinWidth = 220,
            Margin = new Avalonia.Thickness(0, 0, 8, 0),
        };
        toolbar.Children.Add(search);
        var refresh = new Button { Content = Model.L("settings.refresh"), Padding = new Avalonia.Thickness(10, 3) };
        refresh.Click += async (_, _) =>
        {
            await router.RefreshAsync();
            Dispatcher.UIThread.Post(ShowModelContexts);
        };
        toolbar.Children.Add(refresh);
        panel.Children.Add(toolbar);

        var settings = router.ModelContextSettings;
        if (settings.Count == 0)
        {
            panel.Children.Add(new TextBlock
            {
                Text = Model.L("model.context.empty"),
                Foreground = TryBrush("TextSecondary"),
                TextWrapping = TextWrapping.Wrap,
            });
            Body.Content = panel;
            return;
        }

        var rows = new List<(Control Element, string SearchText)>();
        foreach (var setting in settings)
        {
            var card = new StackPanel { Margin = new Avalonia.Thickness(0, 0, 0, 14) };
            card.Children.Add(new TextBlock
            {
                Text = $"{setting.ProviderName} · {setting.Model}",
                FontWeight = FontWeight.SemiBold,
                TextWrapping = TextWrapping.Wrap,
            });
            card.Children.Add(new TextBlock
            {
                Text = setting.DetectedContextWindow is { } detected
                    ? string.Format(CultureInfo.CurrentCulture, Model.L("model.context.detected"), detected.ToString("N0", CultureInfo.CurrentCulture))
                    : Model.L("model.context.notDetected"),
                FontSize = 11,
                Foreground = TryBrush("TextSecondary"),
                Margin = new Avalonia.Thickness(0, 2, 0, 5),
            });

            var controls = new StackPanel { Orientation = Orientation.Horizontal };
            var input = new TextBox
            {
                Text = setting.OverrideContextWindow?.ToString(CultureInfo.InvariantCulture) ?? "",
                Watermark = Model.L("usage.context.window"),
                Width = 170,
                Margin = new Avalonia.Thickness(0, 0, 8, 0),
            };
            controls.Children.Add(input);
            var status = new TextBlock { VerticalAlignment = VerticalAlignment.Center, Foreground = TryBrush("TextSecondary") };
            var save = new Button { Content = Model.L("settings.saveChanges"), Padding = new Avalonia.Thickness(10, 3), Margin = new Avalonia.Thickness(0, 0, 6, 0) };
            save.Click += (_, _) =>
            {
                if (string.IsNullOrWhiteSpace(input.Text))
                {
                    try
                    {
                        router.SetModelContextWindowOverride(setting.Provider, setting.Model, null);
                        status.Text = Model.L("model.context.saved");
                    }
                    catch (Exception ex) { status.Text = ex.Message; }
                    return;
                }
                var text = input.Text.Trim();
                var digits = new string(text.Where(char.IsDigit).ToArray());
                if (!text.All(character => char.IsDigit(character) || char.IsWhiteSpace(character) || character is '.' or ',' or '_')
                    || !int.TryParse(digits, NumberStyles.None, CultureInfo.InvariantCulture, out var parsed) || parsed <= 0)
                {
                    status.Text = Model.L("model.context.invalid");
                    return;
                }
                try
                {
                    router.SetModelContextWindowOverride(setting.Provider, setting.Model, parsed);
                    input.Text = parsed.ToString(CultureInfo.InvariantCulture);
                    status.Text = Model.L("model.context.saved");
                }
                catch (Exception ex) { status.Text = ex.Message; }
            };
            controls.Children.Add(save);
            var automatic = new Button { Content = Model.L("model.context.auto"), Padding = new Avalonia.Thickness(10, 3), Margin = new Avalonia.Thickness(0, 0, 8, 0) };
            automatic.Click += (_, _) =>
            {
                try
                {
                    router.SetModelContextWindowOverride(setting.Provider, setting.Model, null);
                    input.Text = "";
                    status.Text = Model.L("model.context.saved");
                }
                catch (Exception ex) { status.Text = ex.Message; }
            };
            controls.Children.Add(automatic);
            controls.Children.Add(status);
            card.Children.Add(controls);
            panel.Children.Add(card);
            rows.Add((card, $"{setting.ProviderName} {setting.Provider} {setting.Model}"));
        }

        void ApplyFilter()
        {
            _modelContextSearch = search.Text ?? "";
            var query = _modelContextSearch.Trim();
            foreach (var (element, searchText) in rows)
                element.IsVisible = query.Length == 0 || searchText.Contains(query, StringComparison.CurrentCultureIgnoreCase);
        }
        search.TextChanged += (_, _) => ApplyFilter();
        ApplyFilter();
        Body.Content = panel;
    }

    private void ShowProviders()
    {
        var router = Model.Router;
        var panel = new StackPanel();
        panel.Children.Add(HeaderRow("Providers", router.Status, () => _ = router.RefreshAsync()));
        if (router.Error is { } err) panel.Children.Add(ErrorText(err));
        panel.Children.Add(Label("Provider"));
        var picker = new ComboBox
        {
            Margin = new Thickness(0, 0, 0, 8),
            ItemTemplate = new FuncDataTemplate<RouterProviderKind>((kind, _) => ProviderLine(kind.Name, kind.LogoKey)),
        };
        foreach (var kind in RouterCatalog.Providers) picker.Items.Add(kind);
        picker.SelectedItem = router.SelectedKind;
        picker.SelectionChanged += (_, _) =>
        {
            if (picker.SelectedItem is RouterProviderKind kind) router.SelectedKind = kind;
            RebuildConnect(panel, router);
        };
        panel.Children.Add(picker);
        panel.Children.Add(new TextBlock
        {
            Text = RouterCatalog.HintFor(router.SelectedKind),
            FontSize = 11,
            Foreground = TryBrush("TextSecondary"),
            Margin = new Thickness(0, 0, 0, 8),
        });
        var connectHost = new StackPanel { Tag = "connect" };
        panel.Children.Add(connectHost);
        FillConnect(connectHost, router);
        panel.Children.Add(Heading("Connected accounts"));
        if (router.Connections.Count == 0)
        {
            panel.Children.Add(new TextBlock
            {
                Text = Model.L("settings.noConnections"),
                Foreground = TryBrush("TextSecondary"),
            });
        }
        var providerGroups = router.Connections
            .GroupBy(connection => connection.Provider)
            .OrderBy(group => group.Min(connection => connection.Priority))
            .ToList();
        var providerOrder = providerGroups.Select(group => group.Key).ToArray();
        for (var providerIndex = 0; providerIndex < providerGroups.Count; providerIndex++)
        {
            var group = providerGroups[providerIndex];
            var provider = RouterCatalog.KindFor(group.Key);
            panel.Children.Add(ProviderHeader(
                RouterCatalog.LabelFor(group.Key),
                provider?.LogoKey ?? "generic",
                group.Count(),
                router,
                providerOrder,
                providerIndex));
            foreach (var connection in group.OrderBy(connection => connection.Priority))
                panel.Children.Add(ConnectionCard(connection, router));
            if (provider is not null) panel.Children.Add(AddProviderButton(provider, picker, router));
        }
        _ = router.RefreshAsync();
        Body.Content = panel;
    }

    private void RebuildConnect(StackPanel panel, RouterController router)
    {
        var host = panel.Children.OfType<StackPanel>().FirstOrDefault(c => Equals(c.Tag, "connect"));
        if (host is null) return;
        host.Children.Clear();
        FillConnect(host, router);
    }

    private void FillConnect(StackPanel host, RouterController router)
    {
        if (router.SelectedKind.Kind == RouterAuthKind.ApiKey && !string.IsNullOrWhiteSpace(router.SelectedKind.BaseUrl))
        {
            host.Children.Add(BoundField("Name", router.ApiKeyName, v => router.ApiKeyName = v));
            host.Children.Add(BoundField("API key", router.ApiKeyValue, v => router.ApiKeyValue = v, password: true));
        }
        else if (router.SelectedKind.Kind == RouterAuthKind.ApiKey)
        {
            host.Children.Add(new TextBlock
            {
                Text = Model.L("settings.addProviderCustom"),
                FontSize = 11,
                Foreground = TryBrush("TextSecondary"),
                TextWrapping = TextWrapping.Wrap,
                Margin = new Thickness(0, 0, 0, 8),
            });
        }
        else
        {
            host.Children.Add(new TextBlock
            {
                Text = router.SelectedKind.Kind == RouterAuthKind.OauthDevice
                    ? Model.L("settings.deviceLogin")
                    : Model.L("settings.signInBrowser"),
                FontSize = 11,
                Foreground = TryBrush("TextSecondary"),
                TextWrapping = TextWrapping.Wrap,
                Margin = new Thickness(0, 0, 0, 8),
            });
        }
        var row = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 0, 0, 12) };
        var canConnect = router.SelectedKind.Kind != RouterAuthKind.ApiKey || !string.IsNullOrWhiteSpace(router.SelectedKind.BaseUrl);
        var connect = new Button { Content = Model.L("settings.connect"), Padding = new Thickness(12, 4), IsEnabled = router.Reachable && canConnect };
        connect.Click += (_, _) => _ = router.StartConnectAsync();
        row.Children.Add(connect);
        if (router.Flow is not RouterFlow.Idle)
        {
            var cancel = new Button { Content = Model.L("settings.cancel"), Margin = new Thickness(8, 0, 0, 0), Padding = new Thickness(12, 4) };
            cancel.Click += (_, _) => router.CancelFlow();
            row.Children.Add(cancel);
        }
        host.Children.Add(row);
        switch (router.Flow)
        {
            case RouterFlow.Browser browser:
                host.Children.Add(Label("Browser login"));
                host.Children.Add(Readonly("Auth URL", browser.AuthUrl));
                host.Children.Add(BoundField("Paste callback URL", router.CallbackPaste, v => router.CallbackPaste = v));
                var finish = new Button { Content = Model.L("settings.finishLogin"), Padding = new Thickness(12, 4), Margin = new Thickness(0, 0, 0, 12) };
                finish.Click += (_, _) => _ = router.FinishBrowserAsync();
                host.Children.Add(finish);
                break;
            case RouterFlow.Device device:
                host.Children.Add(Label("Device login"));
                if (!string.IsNullOrEmpty(device.UserCode))
                {
                    host.Children.Add(new TextBlock { Text = device.UserCode, FontSize = 20, FontFamily = new FontFamily("monospace"), Margin = new Thickness(0, 0, 0, 6) });
                }
                host.Children.Add(Readonly("Verify", device.VerificationUrl));
                host.Children.Add(new TextBlock { Text = Model.L("settings.waitingAuthorization"), Foreground = TryBrush("TextSecondary") });
                break;
        }
    }

    private Control ConnectionCard(RouterConnection connection, RouterController router)
    {
        var card = new Border
        {
            BorderBrush = TryBrush("BorderSubtle"),
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(8),
            Padding = new Thickness(12),
            Margin = new Thickness(0, 0, 0, 8),
            Background = TryBrush("PanelBackground"),
        };
        var stack = new StackPanel();
        stack.Children.Add(new TextBlock { Text = connection.Name, FontWeight = FontWeight.SemiBold });
        var row = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 8, 0, 0) };
        var active = new CheckBox { Content = Model.L("settings.active"), IsChecked = connection.Active, VerticalAlignment = VerticalAlignment.Center };
        active.IsCheckedChanged += (_, _) => _ = router.ToggleAsync(connection);
        row.Children.Add(active);
        var test = new Button
        {
            Content = "✓",
            Width = 28,
            Height = 26,
            Padding = new Thickness(0),
            Margin = new Thickness(12, 0, 0, 0),
        };
        ToolTip.SetTip(test, "Test");
        AutomationProperties.SetName(test, "Test");
        test.Click += (_, _) => _ = router.TestAsync(connection);
        row.Children.Add(test);
        var remove = new Button
        {
            Content = "×",
            Width = 28,
            Height = 26,
            Padding = new Thickness(0),
            Margin = new Thickness(8, 0, 0, 0),
        };
        ToolTip.SetTip(remove, "Remove");
        AutomationProperties.SetName(remove, "Remove");
        remove.Click += (_, _) => _ = router.RemoveAsync(connection);
        row.Children.Add(remove);
        stack.Children.Add(row);
        var fallback = new CheckBox
        {
            Content = Model.L("settings.imageFallback"),
            IsChecked = connection.ImageFallbackEnabled,
            Margin = new Thickness(0, 6, 0, 0),
        };
        fallback.IsCheckedChanged += (_, _) => _ = router.ToggleImageFallbackAsync(connection);
        stack.Children.Add(fallback);
        if (!string.IsNullOrEmpty(connection.Error)) stack.Children.Add(ErrorText(connection.Error));
        card.Child = stack;
        return card;
    }

    private Control ProviderHeader(
        string name,
        string key,
        int count,
        RouterController router,
        string[] providerOrder,
        int providerIndex)
    {
        var row = new DockPanel
        {
            Margin = new Thickness(0, 12, 0, 8),
        };
        var priority = new StackPanel
        {
            Orientation = Orientation.Horizontal,
        };
        var up = new Button
        {
            Content = "↑",
            Width = 26,
            Height = 24,
            Padding = new Thickness(0),
            IsEnabled = providerIndex > 0,
        };
        ToolTip.SetTip(up, Model.L("router.priorityUp"));
        AutomationProperties.SetName(up, Model.L("router.priorityUp"));
        up.Click += (_, _) => MoveProviderPriority(router, providerOrder, providerIndex, providerIndex - 1);
        priority.Children.Add(up);
        var down = new Button
        {
            Content = "↓",
            Width = 26,
            Height = 24,
            Padding = new Thickness(0),
            Margin = new Thickness(4, 0, 0, 0),
            IsEnabled = providerIndex < providerOrder.Length - 1,
        };
        ToolTip.SetTip(down, Model.L("router.priorityDown"));
        AutomationProperties.SetName(down, Model.L("router.priorityDown"));
        down.Click += (_, _) => MoveProviderPriority(router, providerOrder, providerIndex, providerIndex + 1);
        priority.Children.Add(down);
        DockPanel.SetDock(priority, Dock.Right);
        row.Children.Add(priority);

        var identity = new StackPanel { Orientation = Orientation.Horizontal };
        identity.Children.Add(ProviderBadge(name, key));
        identity.Children.Add(new TextBlock
        {
            Text = $"{name} · {count} {(count == 1 ? "account" : "accounts")}",
            FontSize = 14,
            FontWeight = FontWeight.SemiBold,
            Foreground = TryBrush("TextPrimary"),
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(8, 0, 0, 0),
        });
        row.Children.Add(identity);
        return row;
    }

    private void MoveProviderPriority(RouterController router, string[] providerOrder, int source, int destination)
    {
        if (source < 0 || source >= providerOrder.Length || destination < 0 || destination >= providerOrder.Length) return;
        var next = providerOrder.ToList();
        var provider = next[source];
        next.RemoveAt(source);
        next.Insert(destination, provider);
        router.ReorderProviders(next);
        ShowProviders();
    }

    private static Control AddProviderButton(RouterProviderKind provider, ComboBox picker, RouterController router)
    {
        var row = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            HorizontalAlignment = HorizontalAlignment.Right,
            Margin = new Thickness(0, 0, 0, 8),
        };
        var add = new Button
        {
            Content = "+",
            Width = 28,
            Height = 26,
            Padding = new Thickness(0),
        };
        ToolTip.SetTip(add, "Add account");
        AutomationProperties.SetName(add, "Add account");
        add.Click += (_, _) =>
        {
            router.SelectedKind = provider;
            picker.SelectedItem = provider;
            _ = router.StartConnectAsync();
        };
        row.Children.Add(add);
        return row;
    }

    private void ShowCustom()
    {
        var router = Model.Router;
        var panel = new StackPanel();
        panel.Children.Add(Heading("Add a custom endpoint"));
        panel.Children.Add(new TextBlock
        {
            Text = Model.L("settings.customEndpointHint"),
            FontSize = 11,
            Foreground = TryBrush("TextSecondary"),
            TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(0, 0, 0, 8),
        });
        panel.Children.Add(BoundField("Name", router.CustomName, v => router.CustomName = v));
        panel.Children.Add(BoundField("Prefix (model id, e.g. local)", router.CustomPrefix, v => router.CustomPrefix = v));
        panel.Children.Add(BoundField("Base URL", router.CustomBaseUrl, v => router.CustomBaseUrl = v));
        panel.Children.Add(BoundField("API key (optional for local)", router.CustomApiKey, v => router.CustomApiKey = v, password: true));
        panel.Children.Add(BoundField("Model name (optional)", router.CustomModel, v => router.CustomModel = v));
        panel.Children.Add(BoundField("Context window in tokens (optional; empty reads it from the server)", router.CustomContextWindow, v => router.CustomContextWindow = v));
        var kind = new ComboBox { Margin = new Thickness(0, 0, 0, 8) };
        kind.Items.Add(CustomApiKind.OpenaiCompatible);
        kind.Items.Add(CustomApiKind.AnthropicCompatible);
        kind.SelectedItem = router.CustomKind;
        kind.SelectionChanged += (_, _) =>
        {
            if (kind.SelectedItem is CustomApiKind k) router.CustomKind = k;
        };
        panel.Children.Add(Label("API"));
        panel.Children.Add(kind);
        var add = new Button { Content = router.IsEditingCustom ? Model.L("settings.saveChanges") : Model.L("settings.addCustomApi"), Padding = new Thickness(12, 4), IsEnabled = router.Reachable, Margin = new Thickness(0, 0, 0, 16) };
        add.Click += async (_, _) => { await router.CreateCustomNodeAsync(!router.IsEditingCustom); ShowCustom(); };
        panel.Children.Add(add);
        if (router.IsEditingCustom)
        {
            var cancel = new Button { Content = Model.L("settings.cancelEdit"), Padding = new Thickness(12, 4), Margin = new Thickness(0, 0, 0, 16) };
            cancel.Click += (_, _) => { router.CancelEditNode(); ShowCustom(); };
            panel.Children.Add(cancel);
        }
        if (router.DetectedServers.Count > 0)
        {
            panel.Children.Add(Heading("Running on this computer"));
            foreach (var server in router.DetectedServers)
            {
                var found = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 0, 0, 8) };
                var connectFound = new Button { Content = Model.L("settings.connect"), Padding = new Thickness(10, 2, 10, 2), Margin = new Thickness(0, 0, 8, 0) };
                connectFound.Click += async (_, _) => { await router.ConnectDetectedAsync(server); ShowCustom(); };
                found.Children.Add(connectFound);
                found.Children.Add(new TextBlock { Text = $"{server.Name} · {server.BaseUrl}", VerticalAlignment = VerticalAlignment.Center });
                panel.Children.Add(found);
            }
        }
        else if (!_scannedLocalServers)
        {
            _scannedLocalServers = true;
            _ = ScanLocalServersAsync();
        }
        panel.Children.Add(Heading("Custom providers"));
        if (router.Nodes.Count == 0)
        {
            panel.Children.Add(new TextBlock
            {
                Text = Model.L("settings.noneYet"),
                Foreground = TryBrush("TextSecondary"),
            });
        }
        foreach (var node in router.Nodes)
        {
            var card = new Border
            {
                BorderBrush = TryBrush("BorderSubtle"),
                BorderThickness = new Thickness(1),
                CornerRadius = new CornerRadius(8),
                Padding = new Thickness(12),
                Margin = new Thickness(0, 0, 0, 8),
            };
            var stack = new StackPanel();
            stack.Children.Add(new TextBlock { Text = node.Name, FontWeight = FontWeight.SemiBold });
            stack.Children.Add(new TextBlock { Text = $"{node.Prefix} · {node.Type} · {node.BaseUrl}", FontSize = 11, FontFamily = new FontFamily("monospace"), Foreground = TryBrush("TextSecondary"), TextWrapping = TextWrapping.Wrap });
            var row = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 8, 0, 0) };
            var connect = new Button { Content = Model.L("settings.connect"), Padding = new Thickness(10, 2) };
            connect.Click += (_, _) => _ = router.ConnectExistingNodeAsync(node);
            var test = new Button { Content = Model.L("settings.test"), Margin = new Thickness(8, 0, 0, 0), Padding = new Thickness(10, 2) };
            test.Click += (_, _) => _ = router.TestNodeAsync(node);
            var edit = new Button { Content = Model.L("settings.edit"), Margin = new Thickness(8, 0, 0, 0), Padding = new Thickness(10, 2) };
            edit.Click += (_, _) => { router.BeginEditNode(node); ShowCustom(); };
            var del = new Button { Content = Model.L("settings.delete"), Margin = new Thickness(8, 0, 0, 0), Padding = new Thickness(10, 2) };
            del.Click += (_, _) => _ = router.DeleteNodeAsync(node);
            row.Children.Add(connect);
            row.Children.Add(test);
            row.Children.Add(edit);
            row.Children.Add(del);
            stack.Children.Add(row);
            card.Child = stack;
            panel.Children.Add(card);
        }
        if (router.Error is { } err) panel.Children.Add(ErrorText(err));
        _ = router.RefreshAsync();
        _customPanel = panel;
        Body.Content = panel;
    }

    private StackPanel? _customPanel;
    private StackPanel? _localPanel;
    private bool _scannedLocalServers;
    private bool _scannedLocalDevices;
    private string _ggufPath = "";

    /// <summary>Looks for local servers once, then redraws if the tab is still showing.</summary>
    private async Task ScanLocalServersAsync()
    {
        await Model.Router.DetectLocalServersAsync();
        if (Model.Router.DetectedServers.Count > 0 && ReferenceEquals(Body.Content, _customPanel)) ShowCustom();
    }

    private async Task RefreshLocalDevicesAsync()
    {
        await Model.Local.RefreshDevicesAsync();
        if (ReferenceEquals(Body.Content, _localPanel)) ShowLocal();
    }

    private void ShowLocal()
    {
        var local = Model.Local;
        local.RefreshInstalled();
        var panel = new StackPanel();
        panel.Children.Add(HeaderRow("Local models", local.Status, null));
        if (local.Error is { } err) panel.Children.Add(ErrorText(err));
        if (local.RuntimeReady && local.Devices.Count == 0 && !_scannedLocalDevices)
        {
            _scannedLocalDevices = true;
            _ = RefreshLocalDevicesAsync();
        }
        panel.Children.Add(Readonly("Hardware", local.HardwareSummary));
        panel.Children.Add(Readonly($"llama.cpp {LocalRuntime.LlamaTag}", local.RuntimeReady ? Model.L("settings.installed") : Model.L("settings.notInstalled")));
        panel.Children.Add(Readonly("Listen", local.Runtime.ServerUrl.ToString()));
        if (local.Serving && local.RunningModelId is { } running)
        {
            panel.Children.Add(Readonly("Serving", local.ServedContext is { } served ? $"{running} · {served} tokens" : running));
        }
        var runtimeRow = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 0, 0, 16) };
        var install = new Button { Content = local.RuntimeReady ? Model.L("settings.reinstallRuntime") : Model.L("settings.installLlama"), Padding = new Thickness(12, 4) };
        install.Click += async (_, _) => { if (local.RuntimeReady) await local.ReinstallRuntimeAsync(); else await local.InstallRuntimeAsync(); _scannedLocalDevices = false; ShowLocal(); };
        runtimeRow.Children.Add(install);
        if (local.Serving)
        {
            var stop = new Button { Content = Model.L("settings.stopLocal"), Margin = new Thickness(8, 0, 0, 0), Padding = new Thickness(12, 4) };
            stop.Click += (_, _) => { local.Stop(); ShowLocal(); };
            runtimeRow.Children.Add(stop);
        }
        panel.Children.Add(runtimeRow);
        if (local.Downloads.TryGetValue("runtime", out var rt) && rt < 1)
        {
            panel.Children.Add(new ProgressBar { Value = rt * 100, Maximum = 100, Height = 8, Margin = new Thickness(0, 0, 0, 12) });
        }
        panel.Children.Add(Heading("Performance"));
        panel.Children.Add(Label("Empty or auto lets llama.cpp fit the model to your GPU memory. Changes apply the next time a model starts."));
        var tuning = local.Settings;
        void Tune(string label, string value, Action<string> set) =>
            panel.Children.Add(BoundField(label, value, v => { set(v.Trim()); local.SaveSettings(); }));
        static int Number(string text) => int.TryParse(text, out var number) && number > 0 ? number : 0;
        static string Shown(int value) => value > 0 ? value.ToString() : "";
        Tune("GPU build: auto, Cuda13, Cuda12, Rocm, Vulkan or Cpu (reinstall the runtime to apply)", tuning.Backend, v => tuning.Backend = v.Length == 0 ? "auto" : v);
        Tune("Context size in tokens", Shown(tuning.ContextSize), v => tuning.ContextSize = Number(v));
        Tune("GPU layers: auto, all or a number", tuning.GpuLayers, v => tuning.GpuLayers = v.Length == 0 ? "auto" : v);
        Tune("CPU threads", Shown(tuning.Threads), v => tuning.Threads = Number(v));
        Tune("Batch size", Shown(tuning.BatchSize), v => tuning.BatchSize = Number(v));
        Tune("Flash attention: auto, on or off", tuning.FlashAttention, v => tuning.FlashAttention = v.Length == 0 ? "auto" : v);
        Tune("KV cache type: empty (f16), q8_0, q5_1 or q4_0", tuning.KvCacheType, v => tuning.KvCacheType = v);
        Tune("Extra llama-server arguments", tuning.ExtraArgs, v => tuning.ExtraArgs = v);
        panel.Children.Add(Heading("Download and run"));
        panel.Children.Add(BoundField("Add your own GGUF (full file path)", _ggufPath, v => _ggufPath = v));
        var import = new Button { Content = "Add GGUF", Padding = new Thickness(12, 4, 12, 4), Margin = new Thickness(0, 0, 0, 12) };
        import.Click += (_, _) => { local.ImportModel(_ggufPath.Trim().Trim('"')); _ggufPath = ""; ShowLocal(); };
        panel.Children.Add(import);
        foreach (var spec in local.Models)
        {
            var card = new Border
            {
                BorderBrush = TryBrush("BorderSubtle"),
                BorderThickness = new Thickness(1),
                CornerRadius = new CornerRadius(8),
                Padding = new Thickness(12),
                Margin = new Thickness(0, 0, 0, 8),
            };
            var stack = new StackPanel();
            var title = new DockPanel();
            var name = new StackPanel { Orientation = Orientation.Horizontal };
            name.Children.Add(new TextBlock { Text = spec.Name, FontWeight = FontWeight.SemiBold, VerticalAlignment = VerticalAlignment.Center });
            if (spec.Reasoning)
            {
                name.Children.Add(new Border
                {
                    Background = new SolidColorBrush(Color.FromArgb(40, 230, 126, 34)),
                    CornerRadius = new CornerRadius(8),
                    Padding = new Thickness(6, 1),
                    Margin = new Thickness(8, 0, 0, 0),
                    Child = new TextBlock { Text = "LRM", FontSize = 10, FontWeight = FontWeight.SemiBold },
                });
            }
            if (spec.MinMemoryGb > 0 && !local.Fits(spec))
            {
                name.Children.Add(new TextBlock
                {
                    Text = "Too large for this GPU / RAM",
                    FontSize = 10,
                    Margin = new Thickness(8, 0, 0, 0),
                    VerticalAlignment = VerticalAlignment.Center,
                    Foreground = TryBrush("TextSecondary"),
                });
            }
            title.Children.Add(name);
            Button action;
            if (local.RunningModelId == spec.Id) action = new Button { Content = Model.L("settings.stop") };
            else if (local.Installed.Contains(spec.Id)) action = new Button { Content = Model.L("settings.start") };
            else action = new Button { Content = Model.L("settings.download") };
            action.Padding = new Thickness(10, 2);
            action.HorizontalAlignment = HorizontalAlignment.Right;
            action.Click += async (_, _) =>
            {
                if (local.RunningModelId == spec.Id) local.Stop();
                else if (local.Installed.Contains(spec.Id)) await local.StartAsync(spec);
                else await local.DownloadAsync(spec);
                ShowLocal();
            };
            DockPanel.SetDock(action, Dock.Right);
            title.Children.Add(action);
            stack.Children.Add(title);
            stack.Children.Add(new TextBlock { Text = $"{spec.Family} · {spec.SizeLabel}", FontSize = 11, Foreground = TryBrush("TextSecondary") });
            stack.Children.Add(new TextBlock { Text = spec.Notes, FontSize = 11, Foreground = TryBrush("TextSecondary"), TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 4, 0, 0) });
            if (local.Downloads.TryGetValue(spec.Id, out var frac) && frac < 1 && !local.Installed.Contains(spec.Id))
            {
                stack.Children.Add(new ProgressBar { Value = frac * 100, Maximum = 100, Height = 8, Margin = new Thickness(0, 8, 0, 0) });
            }
            if (local.Installed.Contains(spec.Id))
            {
                var disk = new DockPanel { Margin = new Thickness(0, 8, 0, 0) };
                disk.Children.Add(new TextBlock
                {
                    Text = Model.L("settings.onDisk", LocalModelCatalog.PrettyBytes(local.Runtime.InstalledBytes(spec))),
                    FontSize = 10,
                    Foreground = TryBrush("TextSecondary"),
                });
                var del = new Button { Content = Model.L("settings.delete"), HorizontalAlignment = HorizontalAlignment.Right, Padding = new Thickness(8, 2) };
                del.Click += (_, _) => { local.Delete(spec); ShowLocal(); };
                DockPanel.SetDock(del, Dock.Right);
                disk.Children.Add(del);
                stack.Children.Add(disk);
            }
            card.Child = stack;
            panel.Children.Add(card);
        }
        _localPanel = panel;
        Body.Content = panel;
    }

    private void ShowVoice()
    {
        var panel = new StackPanel();
        panel.Children.Add(Heading("settings.voice"));
        panel.Children.Add(Label("settings.provider"));
        var providers = Enum.GetValues<VoiceInputProvider>();
        var picker = new ComboBox { Margin = new Thickness(0, 0, 0, 10) };
        foreach (var voiceProvider in providers)
        {
            picker.Items.Add(voiceProvider switch
            {
                VoiceInputProvider.WhisperTinyQ5 => Model.L("voice.source.tiny"),
                VoiceInputProvider.WhisperLargeV3Turbo => Model.L("voice.source.large"),
                VoiceInputProvider.Nemotron => Model.L("voice.source.nemotron"),
                VoiceInputProvider.CustomLocal => Model.L("voice.source.custom"),
                _ => Model.L("voice.source.api"),
            });
        }
        picker.SelectedIndex = Array.IndexOf(providers, Model.VoiceProvider);
        picker.SelectionChanged += (_, _) =>
        {
            if (picker.SelectedIndex >= 0 && picker.SelectedIndex < providers.Length)
            {
                Model.SetVoiceProvider(providers[picker.SelectedIndex]);
                ShowVoice();
            }
        };
        panel.Children.Add(picker);

        var provider = Model.VoiceProvider;
        var spec = provider switch
        {
            VoiceInputProvider.WhisperTinyQ5 => VoiceModelCatalog.WhisperTinyQ5,
            VoiceInputProvider.WhisperLargeV3Turbo => VoiceModelCatalog.WhisperLargeV3Turbo,
            VoiceInputProvider.Nemotron => VoiceModelCatalog.Nemotron,
            _ => default,
        };
        var state = Model.IsVoiceReady ? Model.L("voice.status.ready") : Model.L("voice.status.notReady");
        panel.Children.Add(Readonly("settings.status", spec.Bytes > 0 ? $"{state} · {spec.Name} · {spec.Bytes / 1_048_576d:0} MiB" : state));
        if (provider == VoiceInputProvider.CustomLocal)
            panel.Children.Add(BoundField("voice.source.custom", Model.VoiceCustomModelPath, Model.SetVoiceCustomModelPath));
        panel.Children.Add(BoundField("voice.api.endpoint", Model.VoiceApiEndpoint, Model.SetVoiceApiEndpoint));
        panel.Children.Add(BoundField("voice.api.key", Model.VoiceApiKey, Model.SetVoiceApiKey, password: true));
        panel.Children.Add(BoundField("voice.api.model", Model.VoiceApiModel, Model.SetVoiceApiModel));
        panel.Children.Add(BoundField("voice.api.realtime", Model.VoiceApiRealtimeEndpoint, Model.SetVoiceApiRealtimeEndpoint));

        var status = new TextBlock
        {
            Text = Model.IsVoiceReady ? Model.L("voice.status.ready") : "",
            FontSize = 11,
            Foreground = TryBrush("TextSecondary"),
            TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(0, 0, 0, 8),
        };
        var downloadable = provider is VoiceInputProvider.WhisperTinyQ5 or VoiceInputProvider.WhisperLargeV3Turbo or VoiceInputProvider.Nemotron;
        var download = new Button { Content = Model.L("voice.download"), IsEnabled = downloadable, Padding = new Thickness(12, 4) };
        download.Click += async (_, _) =>
        {
            download.IsEnabled = false;
            status.Text = Model.L("voice.status.downloading");
            try
            {
                await Model.EnsureVoiceAssetsAsync(progress => Dispatcher.UIThread.Post(() => status.Text = $"{Model.L("voice.status.downloading")} {progress.Fraction:P0}"));
                status.Text = Model.L("voice.status.ready");
            }
            catch (Exception error) { status.Text = Model.L("voice.error", error.Message); }
            finally { download.IsEnabled = downloadable; }
        };
        panel.Children.Add(download);
        panel.Children.Add(status);
        Body.Content = panel;
    }

    private void ShowShare()
    {
        var router = Model.Router;
        var panel = new StackPanel();
        panel.Children.Add(Heading("Sharing"));
        panel.Children.Add(Readonly("Status", router.Tunnel.Running ? Model.L("settings.running") : router.Tunnel.Enabled ? Model.L("settings.enabled") : Model.L("settings.stopped")));
        if (!string.IsNullOrEmpty(router.Tunnel.ShortId)) panel.Children.Add(Readonly("Short id", router.Tunnel.ShortId));
        if (!string.IsNullOrEmpty(router.Tunnel.ShareUrl)) panel.Children.Add(Readonly("Public URL", router.Tunnel.ShareUrl));
        if (router.Tunnel.Downloading)
        {
            panel.Children.Add(new ProgressBar { Value = router.Tunnel.Progress, Maximum = 100, Height = 8, Margin = new Thickness(0, 0, 0, 8) });
        }
        var row = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 0, 0, 12) };
        if (router.Tunnel.Running || router.Tunnel.Enabled)
        {
            var stop = new Button { Content = Model.L("settings.stopSharing"), Padding = new Thickness(12, 4) };
            stop.Click += async (_, _) => { await router.DisableTunnelAsync(); ShowShare(); };
            row.Children.Add(stop);
        }
        else
        {
            var share = new Button { Content = Model.L("settings.enableSharing"), Padding = new Thickness(12, 4), IsEnabled = router.Reachable };
            share.Click += async (_, _) => { await router.EnableTunnelAsync(); ShowShare(); };
            row.Children.Add(share);
        }
        if (!string.IsNullOrEmpty(router.Tunnel.ShareUrl))
        {
            var copy = new Button { Content = Model.L("settings.copyUrl"), Margin = new Thickness(8, 0, 0, 0), Padding = new Thickness(12, 4) };
            copy.Click += (_, _) => router.CopyShareUrl();
            row.Children.Add(copy);
        }
        panel.Children.Add(row);
        panel.Children.Add(new TextBlock
        {
            Text = Model.L("settings.sharingHint"),
            FontSize = 11,
            Foreground = TryBrush("TextSecondary"),
            TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(0, 0, 0, 16),
        });
        panel.Children.Add(Heading("Give this to a client"));
        var key = router.Keys.FirstOrDefault(k => k.Active) ?? router.Keys.FirstOrDefault();
        var shareEndpoint = string.IsNullOrEmpty(router.Tunnel.ShareUrl) ? Model.L("settings.enableSharingEndpoint") : router.Tunnel.ShareUrl.TrimEnd('/') + "/v1";
        if (key is not null)
        {
            panel.Children.Add(Readonly("Endpoint", shareEndpoint));
            panel.Children.Add(Readonly(key.Name, key.Key.Length > 10 ? key.Key[..10] + "…" : key.Key));
            var copies = new StackPanel { Orientation = Orientation.Horizontal };
            var copyEp = new Button { Content = Model.L("settings.copyEndpoint"), Padding = new Thickness(12, 4) };
            copyEp.Click += (_, _) => { NativeClipboard.SetText(shareEndpoint); router.Status = Model.L("status.copied"); };
            var copyKey = new Button { Content = Model.L("settings.copyApiKey"), Margin = new Thickness(8, 0, 0, 0), Padding = new Thickness(12, 4) };
            copyKey.Click += (_, _) => { NativeClipboard.SetText(key.Key); router.Status = Model.L("status.copied"); };
            copies.Children.Add(copyEp);
            copies.Children.Add(copyKey);
            panel.Children.Add(copies);
        }
        else
        {
            panel.Children.Add(new TextBlock { Text = Model.L("settings.noShareKey"), Margin = new Thickness(0, 0, 0, 8) });
            var create = new Button { Content = Model.L("settings.createKey"), Padding = new Thickness(12, 4), IsEnabled = router.Reachable };
            create.Click += async (_, _) => { await router.CreateShareKeyAsync(); ShowShare(); };
            panel.Children.Add(create);
        }
        if (router.Error is { } err) panel.Children.Add(ErrorText(err));
        _ = router.RefreshAsync();
        Body.Content = panel;
    }

    private void ShowMobile()
    {
        var panel = new StackPanel();
        panel.Children.Add(Heading("Mobile control"));
        panel.Children.Add(Readonly("LAN endpoint", Model.RemoteControl.PreferredEndpoint));
        var pairing = Model.RemotePairing is { } current && current.ExpiresAt > DateTimeOffset.UtcNow
            ? current
            : Model.BeginRemotePairing();
        var qr = PairingQr(pairing.Payload);
        if (qr is not null)
        {
            panel.Children.Add(new Border
            {
                Background = Brushes.White,
                CornerRadius = new CornerRadius(10),
                Padding = new Avalonia.Thickness(12),
                HorizontalAlignment = HorizontalAlignment.Left,
                Margin = new Avalonia.Thickness(0, 4, 0, 12),
                Child = new Image { Source = qr, Width = 220, Height = 220 },
            });
        }
        panel.Children.Add(Readonly("One-time code", pairing.Code));
        panel.Children.Add(Readonly("Expires", pairing.ExpiresAt.ToLocalTime().ToString("g")));
        panel.Children.Add(Readonly("Pairing link", pairing.Payload));
        panel.Children.Add(new TextBlock { Text = "Enter this link/code in HerNess Mobile. It expires in five minutes and is consumed once.", TextWrapping = TextWrapping.Wrap, FontSize = 11, Foreground = TryBrush("TextSecondary"), Margin = new Avalonia.Thickness(0, 0, 0, 12) });
        var row = new StackPanel { Orientation = Avalonia.Layout.Orientation.Horizontal, Margin = new Avalonia.Thickness(0, 0, 0, 12) };
        var renew = new Button { Content = "New pairing code", Padding = new Avalonia.Thickness(12, 4) };
        renew.Click += (_, _) => { Model.BeginRemotePairing(); ShowMobile(); };
        var copy = new Button { Content = "Copy pairing link", Padding = new Avalonia.Thickness(12, 4), Margin = new Avalonia.Thickness(8, 0, 0, 0) };
        copy.Click += (_, _) => NativeClipboard.SetText(pairing.Payload);
        row.Children.Add(renew); row.Children.Add(copy); panel.Children.Add(row);
        var tunnel = new Button { Content = "Enable Cloudflare Quick Tunnel", Padding = new Avalonia.Thickness(12, 4) };
        tunnel.Click += async (_, _) => { tunnel.IsEnabled = false; try { await Model.EnableRemoteCloudTunnelAsync(); } finally { ShowMobile(); } };
        panel.Children.Add(tunnel);
        if (Model.RemoteControl.PublicEndpoint is { } publicEndpoint) panel.Children.Add(Readonly("Public endpoint", publicEndpoint));
        panel.Children.Add(new TextBlock { Text = "Provider keys stay on this computer; remote commands use the same ask / approve me / full access rules.", TextWrapping = TextWrapping.Wrap, FontSize = 11, Foreground = TryBrush("TextSecondary"), Margin = new Avalonia.Thickness(0, 12, 0, 0) });
        Body.Content = panel;
    }

    private static Bitmap? PairingQr(string payload)
    {
        using var generator = new QRCodeGenerator();
        using var data = generator.CreateQrCode(payload, QRCodeGenerator.ECCLevel.Q);
        var bytes = new PngByteQRCode(data).GetGraphic(8, true);
        return new Bitmap(new MemoryStream(bytes));
    }

    private void ShowSkills()
    {
        var tabs = new TabControl();
        var catalog = new StackPanel();
        catalog.Children.Add(Heading("SkillsMP Popular snapshot"));
        catalog.Children.Add(new TextBlock
        {
            Text = Model.L("settings.skillsMetadata"),
            FontSize = 11,
            Foreground = TryBrush("TextSecondary"),
            TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(0, 0, 0, 12),
        });
        foreach (var entry in Model.ActiveSkills.MarketplaceEntries)
        {
            var card = new Border
            {
                BorderBrush = TryBrush("BorderSubtle"),
                BorderThickness = new Thickness(1),
                CornerRadius = new CornerRadius(8),
                Padding = new Thickness(12),
                Margin = new Thickness(0, 0, 0, 8),
            };
            var stack = new StackPanel();
            var top = new DockPanel();
            var title = new StackPanel();
            title.Children.Add(new TextBlock { Text = entry.Name, FontWeight = FontWeight.SemiBold });
            title.Children.Add(new TextBlock { Text = entry.Id, FontSize = 11, FontFamily = new FontFamily("monospace"), Foreground = TryBrush("TextSecondary") });
            top.Children.Add(title);
            if (Model.ActiveSkills.IsInstalled(entry))
            {
                var installedLabel = new TextBlock { Text = Model.L("settings.installed"), FontSize = 11, Foreground = TryBrush("TextSecondary"), HorizontalAlignment = HorizontalAlignment.Right };
                DockPanel.SetDock(installedLabel, Dock.Right);
                top.Children.Add(installedLabel);
            }
            else if (!string.IsNullOrWhiteSpace(entry.DownloadUrl))
            {
                var download = new Button { Content = Model.L("settings.download"), Padding = new Thickness(10, 4), HorizontalAlignment = HorizontalAlignment.Right };
                download.Click += async (_, _) =>
                {
                    download.IsEnabled = false;
                    try { await Model.ActiveSkills.InstallAsync(entry); }
                    catch (Exception error) { Model.Bridge.Status = error.Message; }
                    ShowSkills();
                };
                DockPanel.SetDock(download, Dock.Right);
                top.Children.Add(download);
            }
            stack.Children.Add(top);
            stack.Children.Add(new TextBlock { Text = entry.Description, TextWrapping = TextWrapping.Wrap, FontSize = 11, Margin = new Thickness(0, 6, 0, 0) });
            var links = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 8, 0, 0) };
            AddExternalLink(links, "GitHub", entry.GithubUrl);
            AddExternalLink(links, "SKILL.md", entry.SkillUrl);
            links.Children.Add(new TextBlock { Text = Model.L("settings.skillsSnapshotDate", entry.SnapshotDate), FontSize = 10, Foreground = TryBrush("TextSecondary"), Margin = new Thickness(10, 4, 0, 0) });
            stack.Children.Add(links);
            card.Child = stack;
            catalog.Children.Add(card);
        }
        if (Model.ActiveSkills.MarketplaceEntries.Count == 0) catalog.Children.Add(new TextBlock { Text = Model.L("settings.noSnapshot"), Foreground = TryBrush("TextSecondary") });

        var installed = new StackPanel();
        installed.Children.Add(Heading("Downloaded and enabled"));
        foreach (var skill in Model.ActiveSkills.Entries)
        {
            var card = new Border
            {
                BorderBrush = TryBrush("BorderSubtle"),
                BorderThickness = new Thickness(1),
                CornerRadius = new CornerRadius(8),
                Padding = new Thickness(12),
                Margin = new Thickness(0, 0, 0, 8),
            };
            var row = new DockPanel();
            var info = new StackPanel();
            info.Children.Add(new TextBlock { Text = skill.Name, FontWeight = FontWeight.SemiBold });
            info.Children.Add(new TextBlock { Text = $"{skill.Id} · {skill.Source}", FontSize = 11, FontFamily = new FontFamily("monospace"), Foreground = TryBrush("TextSecondary") });
            info.Children.Add(new TextBlock { Text = skill.Description, FontSize = 11, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 4, 0, 0) });
            row.Children.Add(info);
            var actions = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Top };
            var view = new Button { Content = Model.L("settings.view"), Padding = new Thickness(8, 3), Margin = new Thickness(8, 0, 0, 0) };
            view.Click += (_, _) => ShowSkillContent(skill);
            actions.Children.Add(view);
            var toggle = new CheckBox { Content = Model.L("settings.enabled"), IsChecked = skill.Enabled, Margin = new Thickness(8, 3, 0, 0) };
            toggle.IsCheckedChanged += (_, _) => { Model.ActiveSkills.SetEnabled(skill.Id, toggle.IsChecked == true); ShowSkills(); };
            actions.Children.Add(toggle);
            if (skill.IsInstalled)
            {
                var remove = new Button { Content = Model.L("settings.delete"), Padding = new Thickness(8, 3), Margin = new Thickness(8, 0, 0, 0) };
                remove.Click += (_, _) =>
                {
                    try { Model.ActiveSkills.Remove(skill.Id); ShowSkills(); }
                    catch (Exception error) { Model.Bridge.Status = error.Message; }
                };
                actions.Children.Add(remove);
            }
            DockPanel.SetDock(actions, Dock.Right);
            row.Children.Add(actions);
            card.Child = row;
            installed.Children.Add(card);
        }
        if (Model.ActiveSkills.Entries.Count == 0) installed.Children.Add(new TextBlock { Text = Model.L("settings.noSkills"), Foreground = TryBrush("TextSecondary") });
        installed.Children.Add(new TextBlock
        {
            Text = Model.L("settings.skillsHint"),
            FontSize = 11,
            Foreground = TryBrush("TextSecondary"),
            TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(0, 8, 0, 0),
        });

        tabs.Items.Add(new TabItem { Header = Model.L("settings.skillsCatalog"), Content = catalog });
        tabs.Items.Add(new TabItem { Header = Model.L("settings.skillsInstalled"), Content = installed });
        Body.Content = tabs;
    }

    private void AddExternalLink(Panel panel, string label, string? value)
    {
        if (!Uri.TryCreate(value, UriKind.Absolute, out var uri)) return;
        var link = new Button { Content = label, Padding = new Thickness(8, 2), Margin = new Thickness(0, 0, 6, 0) };
        link.Click += (_, _) =>
        {
            try { Process.Start(new ProcessStartInfo(uri.ToString()) { UseShellExecute = true }); }
            catch { }
        };
        panel.Children.Add(link);
    }

    private void ShowSkillContent(SkillDescriptor skill)
    {
        var text = Model.L("settings.skillReadFailed");
        try { text = Model.ActiveSkills.Read(skill.Id, includeDisabled: true); }
        catch (Exception error) { text = error.Message; }
        var viewer = new TextBox
        {
            Text = text,
            IsReadOnly = true,
            AcceptsReturn = true,
            TextWrapping = TextWrapping.Wrap,
            FontFamily = new FontFamily("monospace"),
            Padding = new Thickness(12),
        };
        ScrollViewer.SetVerticalScrollBarVisibility(viewer, ScrollBarVisibility.Auto);
        ScrollViewer.SetHorizontalScrollBarVisibility(viewer, ScrollBarVisibility.Auto);
        var window = new Window
        {
            Title = skill.Name,
            Width = 760,
            Height = 560,
            Content = viewer,
        };
        window.Show(this);
    }

    private void ShowPlugins()
    {
        var panel = new StackPanel();
        var header = new DockPanel { Margin = new Thickness(0, 0, 0, 8) };
        header.Children.Add(Heading("Plugins"));
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
        var reveal = new Button { Content = Model.L("settings.revealFolder"), Padding = new Thickness(10, 4) };
        reveal.Click += (_, _) =>
        {
            try
            {
                Process.Start(new ProcessStartInfo { FileName = "xdg-open", Arguments = Model.Paths.Plugins, UseShellExecute = false });
            }
            catch { /* ignore */ }
        };
        var reload = new Button { Content = Model.L("settings.reload"), Margin = new Thickness(8, 0, 0, 0), Padding = new Thickness(10, 4) };
        reload.Click += (_, _) => { Model.Remount(); ShowPlugins(); };
        buttons.Children.Add(reveal);
        buttons.Children.Add(reload);
        DockPanel.SetDock(buttons, Dock.Right);
        header.Children.Add(buttons);
        panel.Children.Add(header);
        AddVisionSettings(panel);
        AddMarketplaceSettings(panel);
        panel.Children.Add(new TextBlock
        {
            Text = Model.L("settings.pluginsHint"),
            FontSize = 11,
            Foreground = TryBrush("TextSecondary"),
            TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(0, 0, 0, 12),
        });
        foreach (var entry in Model.Catalog.Entries)
        {
            var card = new Border
            {
                BorderBrush = TryBrush("BorderSubtle"),
                BorderThickness = new Thickness(1),
                CornerRadius = new CornerRadius(8),
                Padding = new Thickness(12),
                Margin = new Thickness(0, 0, 0, 8),
            };
            var stack = new StackPanel();
            var top = new DockPanel();
            var titles = new StackPanel();
            titles.Children.Add(new TextBlock { Text = entry.Manifest.Name, FontWeight = FontWeight.SemiBold });
            titles.Children.Add(new TextBlock { Text = entry.Manifest.Id, FontSize = 11, FontFamily = new FontFamily("monospace"), Foreground = TryBrush("TextSecondary") });
            top.Children.Add(titles);
            var enabled = new CheckBox { Content = Model.L("settings.enabled"), IsChecked = entry.Enabled, HorizontalAlignment = HorizontalAlignment.Right, IsEnabled = entry.Broken is null };
            enabled.IsCheckedChanged += (_, _) =>
            {
                Model.Catalog.SetEnabled(entry.Manifest.Id, enabled.IsChecked == true);
                Model.Remount();
                ShowPlugins();
            };
            DockPanel.SetDock(enabled, Dock.Right);
            top.Children.Add(enabled);
            stack.Children.Add(top);
            var badges = new WrapPanel { Margin = new Thickness(0, 6, 0, 0) };
            badges.Children.Add(Badge(entry.Kind.ToString().ToLowerInvariant()));
            badges.Children.Add(Badge(entry.Manifest.Plane.ToString().ToLowerInvariant()));
            badges.Children.Add(Badge(entry.Trust.ToString().ToLowerInvariant()));
            badges.Children.Add(new TextBlock
            {
                Text = $"v{entry.Manifest.Version} · ABI {entry.Manifest.Abi}",
                FontSize = 11,
                Foreground = TryBrush("TextSecondary"),
                VerticalAlignment = VerticalAlignment.Center,
                Margin = new Thickness(6, 0, 0, 0),
            });
            stack.Children.Add(badges);
            if (!string.IsNullOrEmpty(entry.Manifest.Description))
            {
                stack.Children.Add(new TextBlock { Text = entry.Manifest.Description, FontSize = 11, Margin = new Thickness(0, 6, 0, 0) });
            }
            if (entry.Broken is { } broken) stack.Children.Add(ErrorText(broken));
            if (entry.Kind == PluginKind.Dylib && entry.Trust != PluginTrust.System)
            {
                var trust = new ComboBox { Width = 160, Margin = new Thickness(0, 8, 0, 0), HorizontalAlignment = HorizontalAlignment.Left };
                trust.Items.Add(PluginTrust.Untrusted);
                trust.Items.Add(PluginTrust.Trusted);
                trust.SelectedItem = entry.Trust;
                trust.SelectionChanged += (_, _) =>
                {
                    if (trust.SelectedItem is PluginTrust t)
                    {
                        Model.Catalog.SetTrust(entry.Manifest.Id, t);
                        Model.Remount();
                        ShowPlugins();
                    }
                };
                stack.Children.Add(trust);
            }
            stack.Children.Add(new SlotHost { Slot = WellKnownSlot.PluginsDetail, Registry = Model.Host.Slots, Margin = new Thickness(0, 8, 0, 0) });
            card.Child = stack;
            panel.Children.Add(card);
        }
        if (Model.Host.Issues.Count > 0)
        {
            panel.Children.Add(Heading("Last mount failed"));
            foreach (var issue in Model.Host.Issues)
            {
                panel.Children.Add(ErrorText($"{issue.RowId}: {issue.Message}"));
            }
        }
        Body.Content = panel;
    }

    private void AddMarketplaceSettings(Panel panel)
    {
        var card = new Border
        {
            BorderBrush = TryBrush("BorderSubtle"),
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(8),
            Padding = new Thickness(12),
            Margin = new Thickness(0, 0, 0, 12),
        };
        var content = new StackPanel();
        var header = new DockPanel();
        header.Children.Add(new TextBlock { Text = "Native Marketplace", FontWeight = FontWeight.SemiBold });
        var refresh = new Button { Content = "Registry yenile", Padding = new Thickness(8, 3) };
        DockPanel.SetDock(refresh, Dock.Right);
        header.Children.Add(refresh);
        content.Children.Add(header);
        content.Children.Add(new TextBlock
        {
            Text = "Ana Marketplace yalnızca incelenmiş, Harness kapsamındaki pluginleri gösterir. Community / Experimental alanı ayrı tutulur; tüm native pluginler açık onayınızdan sonra etkinleştirilir.",
            FontSize = 11,
            Foreground = TryBrush("TextSecondary"),
            TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(0, 6, 0, 8),
        });
        var account = new StackPanel { Spacing = 5, Margin = new Thickness(0, 0, 0, 10) };
        content.Children.Add(account);
        var list = new StackPanel();
        content.Children.Add(list);
        card.Child = content;
        panel.Children.Add(card);

        void Render()
        {
            RenderAccount();
            list.Children.Clear();
            list.Children.Add(new TextBlock { Text = "Ana Marketplace", FontWeight = FontWeight.SemiBold, Margin = new Thickness(0, 8, 0, 2) });
            AddEntries(Model.Marketplace.Entries);
            list.Children.Add(new TextBlock { Text = "Community / Experimental", FontWeight = FontWeight.SemiBold, Margin = new Thickness(0, 12, 0, 2) });
            AddEntries(Model.Marketplace.CommunityEntries);
            if (Model.Marketplace.Entries.Count == 0 && Model.Marketplace.CommunityEntries.Count == 0)
                list.Children.Add(new TextBlock { Text = "Marketplace kaydı yok veya henüz yenilenmedi.", FontSize = 11, Foreground = TryBrush("TextSecondary") });
            AddForks();

            void AddEntries(IReadOnlyList<NativeMarketplaceEntry> entries)
            {
                foreach (var entry in entries)
                {
                    var row = new DockPanel { Margin = new Thickness(0, 4) };
                    var text = new StackPanel();
                    text.Children.Add(new TextBlock { Text = $"{entry.Name} v{entry.Version}", FontWeight = FontWeight.SemiBold });
                    text.Children.Add(new TextBlock { Text = $"{entry.Id} · {entry.CatalogScope} · {entry.Category} · {entry.VerificationStatus} · moderation:{entry.ModerationStatus} · risk:{entry.RiskLevel} · {string.Join(", ", (entry.Artifacts ?? Array.Empty<NativeMarketplaceArtifact>()).Select(a => $"{a.Platform}/{a.Architecture}:{a.Status}"))}", FontSize = 10, Foreground = TryBrush("TextSecondary") });
                    var actions = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center, Spacing = 6 };
                    var installed = Model.Catalog.Entries.FirstOrDefault(candidate => candidate.Id == entry.Id && candidate.Kind == PluginKind.Dylib);
                    var updateAvailable = installed is not null
                        && SemVer.TryParse(installed.Manifest.Version, out var installedVersion)
                        && SemVer.TryParse(entry.Version, out var releaseVersion)
                        && installedVersion.CompareTo(releaseVersion) < 0;
                    if (installed is null || updateAvailable)
                    {
                        var install = new Button
                        {
                            Content = updateAvailable ? "Update and enable" : "Accept and enable",
                            Padding = new Thickness(8, 3),
                            IsEnabled = Model.Marketplace.CanInstall(entry),
                        };
                        install.Click += async (_, _) =>
                        {
                            var consent = await new NativeMarketplaceConsentWindow(entry).ShowDialog<bool>(this);
                            if (!consent) return;
                            try
                            {
                                await Model.Marketplace.InstallAsync(entry);
                                Model.Remount();
                                ShowPlugins();
                            }
                            catch (Exception error) { list.Children.Add(ErrorText(error.Message)); }
                        };
                        actions.Children.Add(install);
                    }
                    else
                    {
                        actions.Children.Add(new TextBlock { Text = "Installed", VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(4) });
                        if (!Model.Marketplace.Forks.HasFork(entry.Id))
                        {
                            var customize = new Button { Content = "Customize", Padding = new Thickness(8, 3) };
                            customize.Click += (_, _) =>
                            {
                                try { Model.Marketplace.Forks.CreateFork(entry.Id, entry.Version); Model.Remount(); ShowPlugins(); }
                                catch (Exception error) { list.Children.Add(ErrorText(error.Message)); }
                            };
                            actions.Children.Add(customize);
                        }
                        var remove = new Button { Content = "Remove", Padding = new Thickness(8, 3) };
                        remove.Click += async (_, _) =>
                        {
                            var confirmed = await new SandboxDiscardWindow(
                                "Remove Marketplace plugin?",
                                $"Remove {entry.Name} from this device?",
                                "Cancel",
                                "Remove").ShowDialog<bool>(this);
                            if (!confirmed) return;
                            try { Model.Marketplace.RemoveInstalled(entry.Id); ShowPlugins(); }
                            catch (Exception error) { list.Children.Add(ErrorText(error.Message)); }
                        };
                        actions.Children.Add(remove);
                    }
                    if (Model.MarketplaceSession.IsSignedIn)
                    {
                        var report = new Button { Content = "Report", Padding = new Thickness(8, 3) };
                        report.Click += async (_, _) =>
                        {
                            var sent = await new MarketplaceReportWindow(Model.Marketplace, entry).ShowDialog<bool>(this);
                            if (sent) Render();
                        };
                        actions.Children.Add(report);
                    }
                    DockPanel.SetDock(actions, Dock.Right);
                    row.Children.Add(actions);
                    row.Children.Add(text);
                    list.Children.Add(row);
                }
            }

            void AddForks()
            {
                var forks = Model.Marketplace.Forks.Forks;
                if (forks.Count == 0) return;
                list.Children.Add(new TextBlock { Text = "Local customizations", FontWeight = FontWeight.SemiBold, Margin = new Thickness(0, 12, 0, 4) });
                foreach (var fork in forks)
                {
                    var card = new StackPanel { Spacing = 3, Margin = new Thickness(0, 3, 0, 8) };
                    card.Children.Add(new TextBlock { Text = $"{fork.Id} · upstream {fork.UpstreamId} · v{fork.UpstreamVersion}", FontFamily = new FontFamily("monospace") });
                    if (fork.UpstreamVersionAvailable is { } available)
                        card.Children.Add(new TextBlock { Text = $"New upstream v{available}; local changes are preserved.", Foreground = TryBrush("TextSecondary"), FontSize = 10 });
                    var actions = new WrapPanel();
                    var open = new Button { Content = "Open folder", Padding = new Thickness(7, 2), Margin = new Thickness(0, 0, 5, 4) };
                    open.Click += (_, _) =>
                    {
                        try
                        {
                            var start = new ProcessStartInfo("xdg-open") { UseShellExecute = false };
                            start.ArgumentList.Add(Model.Marketplace.Forks.FolderFor(fork));
                            Process.Start(start);
                        }
                        catch (Exception error) { list.Children.Add(ErrorText(error.Message)); }
                    };
                    var export = new Button { Content = "Export", Padding = new Thickness(7, 2), Margin = new Thickness(0, 0, 5, 4) };
                    export.Click += async (_, _) =>
                    {
                        try
                        {
                            var file = await StorageProvider.SaveFilePickerAsync(new FilePickerSaveOptions
                            {
                                Title = "Export local plugin fork",
                                SuggestedFileName = fork.Id + ".dotsplugin",
                                FileTypeChoices = [new FilePickerFileType("DOTS plugin package") { Patterns = ["*.dotsplugin"] }],
                            });
                            if (file is null) return;
                            if (!file.Path.IsFile) throw new InvalidOperationException("Export requires a local file path.");
                            Model.Marketplace.Forks.Export(fork, file.Path.LocalPath);
                        }
                        catch (Exception error) { list.Children.Add(ErrorText(error.Message)); }
                    };
                    var enable = new Button { Content = "Review and enable", Padding = new Thickness(7, 2), Margin = new Thickness(0, 0, 5, 4) };
                    enable.Click += async (_, _) =>
                    {
                        var consent = await new SandboxDiscardWindow(
                            "Custom native plugin consent",
                            $"{fork.Id} is a local native-code fork of {fork.UpstreamId}. Its source may have changed and it is not signed by the Marketplace. Enabling it grants native execution. Review its source first?",
                            "Cancel",
                            "I reviewed the source").ShowDialog<bool>(this);
                        if (!consent) return;
                        try { Model.Marketplace.Forks.AcceptAndEnable(fork); Model.Remount(); ShowPlugins(); }
                        catch (Exception error) { list.Children.Add(ErrorText(error.Message)); }
                    };
                    actions.Children.Add(open);
                    actions.Children.Add(export);
                    actions.Children.Add(enable);
                    if (fork.UpstreamVersionAvailable is { } newer)
                    {
                        var compared = new Button { Content = "Compared", Padding = new Thickness(7, 2), Margin = new Thickness(0, 0, 5, 4) };
                        compared.Click += (_, _) => { Model.Marketplace.Forks.AcknowledgeUpstream(fork, newer); Render(); };
                        actions.Children.Add(compared);
                    }
                    var delete = new Button { Content = "Delete", Padding = new Thickness(7, 2), Margin = new Thickness(0, 0, 5, 4) };
                    delete.Click += async (_, _) =>
                    {
                        var confirmed = await new SandboxDiscardWindow(
                            "Delete local plugin fork?",
                            $"Delete local fork {fork.Id}?",
                            "Cancel",
                            "Delete").ShowDialog<bool>(this);
                        if (!confirmed) return;
                        try { Model.Marketplace.DeleteFork(fork); ShowPlugins(); }
                        catch (Exception error) { list.Children.Add(ErrorText(error.Message)); }
                    };
                    actions.Children.Add(delete);
                    card.Children.Add(actions);
                    list.Children.Add(card);
                }
            }
        }

        void RenderAccount()
        {
            account.Children.Clear();
            if (Model.MarketplaceSession.IsSignedIn)
            {
                var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
                row.Children.Add(new TextBlock
                {
                    Text = "HerNess: " + (Model.MarketplaceSession.Profile?.Email ?? "Signed in"),
                    VerticalAlignment = VerticalAlignment.Center,
                    Margin = new Thickness(0, 0, 8, 0),
                });
                var publish = new Button { Content = "Publish native plugin", Padding = new Thickness(8, 3) };
                publish.Click += async (_, _) =>
                {
                    var dialog = new MarketplacePublishWindow(Model.MarketplacePublisher);
                    if (!await dialog.ShowDialog<bool>(this)) return;
                    try { await Model.Marketplace.RefreshOwnedPluginsAsync(); Render(); }
                    catch (Exception error) { account.Children.Add(ErrorText(error.Message)); }
                };
                var refreshOwned = new Button { Content = "Refresh my plugins", Padding = new Thickness(8, 3) };
                refreshOwned.Click += async (_, _) =>
                {
                    try { await Model.Marketplace.RefreshOwnedPluginsAsync(); Render(); }
                    catch (Exception error) { account.Children.Add(ErrorText(error.Message)); }
                };
                var signOut = new Button { Content = "Sign out", Padding = new Thickness(8, 3) };
                signOut.Click += async (_, _) => { await Model.MarketplaceSession.SignOutAsync(); Render(); };
                row.Children.Add(publish);
                row.Children.Add(refreshOwned);
                row.Children.Add(signOut);
                account.Children.Add(row);

                if (!string.IsNullOrWhiteSpace(Model.Marketplace.OwnedPluginsError))
                    account.Children.Add(ErrorText(Model.Marketplace.OwnedPluginsError));
                foreach (var plugin in Model.Marketplace.OwnedPlugins)
                {
                    var pluginCard = new StackPanel { Spacing = 3, Margin = new Thickness(0, 4, 0, 6) };
                    var pluginRow = new DockPanel();
                    pluginRow.Children.Add(new TextBlock
                    {
                        Text = $"{plugin.Name} · {plugin.Id} · {plugin.SourceVisibility}",
                        FontWeight = FontWeight.SemiBold,
                        VerticalAlignment = VerticalAlignment.Center,
                    });
                    var unpublish = new Button { Content = "Unpublish", Padding = new Thickness(7, 2) };
                    DockPanel.SetDock(unpublish, Dock.Right);
                    unpublish.Click += async (_, _) =>
                    {
                        var confirmed = await new SandboxDiscardWindow(
                            "Unpublish plugin?",
                            $"Unpublish {plugin.Name}? Existing installations will not be removed.",
                            "Cancel",
                            "Unpublish").ShowDialog<bool>(this);
                        if (!confirmed) return;
                        try { await Model.Marketplace.UnpublishAsync(plugin.Id); Render(); }
                        catch (Exception error) { account.Children.Add(ErrorText(error.Message)); }
                    };
                    pluginRow.Children.Add(unpublish);
                    pluginCard.Children.Add(pluginRow);
                    foreach (var release in plugin.Releases ?? Array.Empty<MarketplaceOwnedRelease>())
                    {
                        var artifacts = string.Join(", ", (release.Artifacts ?? Array.Empty<MarketplaceOwnedArtifact>())
                            .Select(item => $"{item.Platform}/{item.Architecture}:{item.Status}"));
                        pluginCard.Children.Add(new TextBlock
                        {
                            Text = $"v{release.Version} · {release.ModerationStatus} · {release.CatalogScope}/{release.Category} · risk:{release.RiskLevel} · {artifacts}",
                            FontSize = 10,
                            Foreground = TryBrush("TextSecondary"),
                            TextWrapping = TextWrapping.Wrap,
                        });
                    }
                    account.Children.Add(pluginCard);
                }
            }
            else
            {
                var login = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
                var email = new TextBox { Width = 210, Watermark = "HerNess account email" };
                var password = new TextBox { Width = 180, Watermark = "Password", PasswordChar = '●' };
                var status = new TextBlock { TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 3, 0, 0) };
                var signIn = new Button { Content = "Sign in to publish", Padding = new Thickness(8, 3) };
                signIn.Click += async (_, _) =>
                {
                    signIn.IsEnabled = false;
                    status.Text = "Signing in…";
                    try
                    {
                        await Model.MarketplaceSession.SignInAsync(email.Text ?? "", password.Text ?? "");
                        password.Text = "";
                        await Model.Marketplace.RefreshOwnedPluginsAsync();
                        Render();
                    }
                    catch (Exception error)
                    {
                        status.Text = error.Message;
                        signIn.IsEnabled = true;
                    }
                };
                login.Children.Add(email);
                login.Children.Add(password);
                login.Children.Add(signIn);
                account.Children.Add(login);
                account.Children.Add(status);
                var oauth = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, Margin = new Thickness(0, 2, 0, 4) };
                var google = new Button { Content = "Continue with Google", Padding = new Thickness(8, 3) };
                google.Click += (_, _) =>
                {
                    try { Model.MarketplaceSession.BeginOAuth(MarketplaceProvider.Google); status.Text = "Google sign-in opened in your browser…"; }
                    catch (Exception error) { status.Text = error.Message; }
                };
                var github = new Button { Content = "Continue with GitHub", Padding = new Thickness(8, 3) };
                github.Click += (_, _) =>
                {
                    try { Model.MarketplaceSession.BeginOAuth(MarketplaceProvider.GitHub); status.Text = "GitHub sign-in opened in your browser…"; }
                    catch (Exception error) { status.Text = error.Message; }
                };
                oauth.Children.Add(google);
                oauth.Children.Add(github);
                account.Children.Add(oauth);
                account.Children.Add(new TextBlock
                {
                    Text = "Sign in with Google, GitHub, or your HerNess email and password. Session tokens are stored by the platform credential service.",
                    FontSize = 10,
                    Foreground = TryBrush("TextSecondary"),
                    TextWrapping = TextWrapping.Wrap,
                });
            }
        }

        var observingMarketplace = false;
        void OnMarketplaceChanged(object? sender, PropertyChangedEventArgs e)
        {
            if (e.PropertyName is not (nameof(NativeMarketplaceClient.Entries)
                or nameof(NativeMarketplaceClient.CommunityEntries)
                or nameof(NativeMarketplaceClient.OwnedPlugins)
                or nameof(NativeMarketplaceClient.OwnedPluginsError))) return;
            Dispatcher.UIThread.Post(Render);
        }
        void OnMarketplaceSessionChanged(object? sender, PropertyChangedEventArgs e)
        {
            if (e.PropertyName is not (nameof(MarketplaceSession.Profile)
                or nameof(MarketplaceSession.IsSignedIn)
                or nameof(MarketplaceSession.LastError))) return;
            Dispatcher.UIThread.Post(Render);
        }
        void SetMarketplaceObservation(bool enabled)
        {
            if (observingMarketplace == enabled) return;
            observingMarketplace = enabled;
            if (enabled)
            {
                Model.Marketplace.PropertyChanged += OnMarketplaceChanged;
                Model.MarketplaceSession.PropertyChanged += OnMarketplaceSessionChanged;
            }
            else
            {
                Model.Marketplace.PropertyChanged -= OnMarketplaceChanged;
                Model.MarketplaceSession.PropertyChanged -= OnMarketplaceSessionChanged;
            }
        }
        card.AttachedToVisualTree += (_, _) => SetMarketplaceObservation(true);
        card.DetachedFromVisualTree += (_, _) => SetMarketplaceObservation(false);
        SetMarketplaceObservation(true);

        refresh.Click += async (_, _) =>
        {
            try { await Model.Marketplace.RefreshAsync(); await Model.Marketplace.RefreshCommunityAsync(); Render(); }
            catch (Exception error) { list.Children.Clear(); list.Children.Add(ErrorText(error.Message)); }
        };
        Render();
        _ = Task.Run(async () =>
        {
            try { await Model.MarketplaceSession.RestoreAsync(); } catch { }
            try { await Model.Marketplace.RefreshAsync(); await Model.Marketplace.RefreshCommunityAsync(); } catch { }
            if (Model.MarketplaceSession.IsSignedIn)
            {
                try { await Model.Marketplace.RefreshOwnedPluginsAsync(); } catch { }
            }
            Dispatcher.UIThread.Post(Render);
        });
    }

    private void AddVisionSettings(Panel panel)
    {
        var card = new Border
        {
            BorderBrush = TryBrush("BorderSubtle"),
            BorderThickness = new Avalonia.Thickness(1),
            CornerRadius = new Avalonia.CornerRadius(8),
            Padding = new Avalonia.Thickness(12),
            Margin = new Avalonia.Thickness(0, 0, 0, 12),
        };
        var stack = new StackPanel();
        var header = new DockPanel();
        header.Children.Add(new TextBlock { Text = Model.L("vision.title"), FontWeight = FontWeight.SemiBold });
        if (Model.VisionPluginInstalled)
        {
            var enabled = new CheckBox
            {
                Content = Model.L("settings.enabled"),
                IsChecked = Model.VisionPluginEnabled,
                HorizontalAlignment = HorizontalAlignment.Right,
            };
            enabled.IsCheckedChanged += (_, _) => { Model.SetVisionPluginEnabled(enabled.IsChecked == true); ShowPlugins(); };
            DockPanel.SetDock(enabled, Dock.Right);
            header.Children.Add(enabled);
        }
        stack.Children.Add(header);
        stack.Children.Add(new TextBlock
        {
            Text = Model.VisionPluginInstalled ? VisionStatus(Model) : Model.L("vision.notInstalled"),
            FontSize = 11,
            Foreground = TryBrush("TextSecondary"),
            TextWrapping = TextWrapping.Wrap,
            Margin = new Avalonia.Thickness(0, 6, 0, 8),
        });
        if (Model.VisionState is VisionFallbackState.Downloading or VisionFallbackState.Preparing)
        {
            stack.Children.Add(new ProgressBar
            {
                Value = Model.VisionModelProgress * 100,
                Maximum = 100,
                Height = 8,
                Margin = new Avalonia.Thickness(0, 0, 0, 8),
            });
        }
        var actions = new StackPanel { Orientation = Avalonia.Layout.Orientation.Horizontal };
        if (!Model.VisionPluginInstalled)
        {
            var install = new Button { Content = Model.L("vision.installPlugin"), Padding = new Avalonia.Thickness(10, 4) };
            install.Click += async (_, _) =>
            {
                try { await Model.InstallVisionPluginAsync(); ShowPlugins(); }
                catch (Exception error) { ShowVisionError(error); }
            };
            actions.Children.Add(install);
        }
        else
        {
            if (Model.VisionPluginEnabled && Model.VisionState != VisionFallbackState.Ready)
            {
                var prepare = new Button { Content = Model.L("vision.prepareModel"), Padding = new Avalonia.Thickness(10, 4) };
                prepare.Click += async (_, _) =>
                {
                    try { await Model.PrepareVisionAsync(); ShowPlugins(); }
                    catch (Exception error) { ShowVisionError(error); }
                };
                actions.Children.Add(prepare);
            }
            if (Model.VisionState != VisionFallbackState.Unavailable && Model.VisionState != VisionFallbackState.ModelMissing)
            {
                var deleteModel = new Button { Content = Model.L("vision.deleteModel"), Padding = new Avalonia.Thickness(10, 4), Margin = new Avalonia.Thickness(8, 0, 0, 0) };
                deleteModel.Click += async (_, _) =>
                {
                    try { await Model.DeleteVisionModelAsync(); ShowPlugins(); }
                    catch (Exception error) { ShowVisionError(error); }
                };
                actions.Children.Add(deleteModel);
            }
            var remove = new Button { Content = Model.L("vision.removePlugin"), Padding = new Avalonia.Thickness(10, 4), Margin = new Avalonia.Thickness(8, 0, 0, 0) };
            remove.Click += (_, _) =>
            {
                try { Model.RemoveVisionPlugin(); ShowPlugins(); }
                catch (Exception error) { ShowVisionError(error); }
            };
            actions.Children.Add(remove);
        }
        stack.Children.Add(actions);
        card.Child = stack;
        panel.Children.Add(card);
    }

    private void ShowVisionError(Exception error)
    {
        Model.Bridge.Status = error.Message;
        ShowPlugins();
    }

    private static string VisionStatus(AppModel model) => model.VisionState switch
    {
        VisionFallbackState.ModelMissing => $"{model.L("vision.modelMissing")} · {ByteCount(model.VisionModelBytes)}",
        VisionFallbackState.Downloading => $"{model.L("vision.downloading")} ({model.VisionModelProgress:P0})",
        VisionFallbackState.Preparing => $"{model.L("vision.preparing")} ({model.VisionModelProgress:P0})",
        VisionFallbackState.Ready => model.L("vision.ready", ByteCount(model.VisionModelBytes)),
        VisionFallbackState.Failed => model.L("vision.failed"),
        _ => model.L("vision.unavailable"),
    };

    private static string ByteCount(long bytes)
    {
        var value = bytes;
        var units = new[] { "B", "KB", "MB", "GB" };
        var index = 0;
        while (value >= 1024 && index < units.Length - 1) { value /= 1024; index++; }
        return $"{value} {units[index]}";
    }

    private void ShowTasks()
    {
        var scheduler = Model.Scheduler;
        var panel = new StackPanel();
        panel.Children.Add(Heading("Scheduled Tasks"));
        panel.Children.Add(new TextBlock
        {
            Text = Model.L("settings.tasksHint"),
            FontSize = 11,
            Foreground = TryBrush("TextSecondary"),
            TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(0, 0, 0, 12),
        });

        var status = new TextBlock
        {
            FontSize = 11,
            Foreground = new SolidColorBrush(Colors.IndianRed),
            TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(0, 0, 0, 8),
        };

        var daemon = new CheckBox
        {
            Content = Model.L("settings.backgroundTasks"),
            IsChecked = Model.IsBackgroundDaemonEnabled,
            Margin = new Thickness(0, 0, 0, 16),
        };
        daemon.IsCheckedChanged += (_, _) =>
        {
            try { Model.SetBackgroundDaemonEnabled(daemon.IsChecked == true); status.Text = ""; }
            catch (Exception ex) { status.Text = ex.Message; daemon.IsChecked = Model.IsBackgroundDaemonEnabled; }
        };
        panel.Children.Add(daemon);

        panel.Children.Add(Heading("New task"));
        var name = new TextBox { Margin = new Thickness(0, 0, 0, 8) };
        var cron = new TextBox { Text = "0 */5 * * *", Margin = new Thickness(0, 0, 0, 4), FontFamily = new FontFamily("monospace") };
        var cronPreview = new TextBlock { FontSize = 11, Foreground = TryBrush("TextSecondary"), Margin = new Thickness(0, 0, 0, 8) };
        void RefreshPreview()
        {
            var expr = CronExpression.TryParse(cron.Text ?? "");
            cronPreview.Text = expr is null
                ? Model.L("settings.invalidCron")
                : Model.L("settings.next", string.Join(" · ", NextRuns(expr, 3).Select(d => d.LocalDateTime.ToString("g", Model.Localization.Culture))));
        }
        cron.TextChanged += (_, _) => RefreshPreview();
        RefreshPreview();
        var workspace = new TextBox { Text = Model.WorkspacePath, Margin = new Thickness(0, 0, 0, 8) };
        var prompt = new TextBox { AcceptsReturn = true, Height = 72, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 0, 0, 8) };
        var autoApprove = new CheckBox { Content = Model.L("settings.autoApprove"), Margin = new Thickness(0, 0, 0, 8) };

        panel.Children.Add(Label("Name"));
        panel.Children.Add(name);
        panel.Children.Add(Label("Cron expression"));
        panel.Children.Add(cron);
        panel.Children.Add(cronPreview);
        panel.Children.Add(Label("Workspace"));
        panel.Children.Add(workspace);
        panel.Children.Add(Label("Prompt"));
        panel.Children.Add(prompt);
        panel.Children.Add(autoApprove);
        panel.Children.Add(status);

        var add = new Button { Content = Model.L("settings.addTask"), Padding = new Thickness(12, 4, 12, 4), Margin = new Thickness(0, 0, 0, 16) };
        add.Click += (_, _) =>
        {
            if (string.IsNullOrWhiteSpace(name.Text) || string.IsNullOrWhiteSpace(prompt.Text)
                || CronExpression.TryParse(cron.Text ?? "") is null || string.IsNullOrWhiteSpace(workspace.Text))
            {
                status.Text = Model.L("settings.required");
                return;
            }
            scheduler.Upsert(new ScheduledTask
            {
                Name = name.Text!.Trim(),
                Cron = cron.Text!.Trim(),
                Prompt = prompt.Text!.Trim(),
                WorkspacePath = workspace.Text!.Trim(),
                AutoApproveCommands = autoApprove.IsChecked == true,
            });
            ShowTasks();
        };
        panel.Children.Add(add);

        panel.Children.Add(Heading("Tasks"));
        if (scheduler.Tasks.Count == 0)
        {
            panel.Children.Add(new TextBlock { Text = Model.L("settings.noTasks"), Foreground = TryBrush("TextSecondary") });
        }
        foreach (var task in scheduler.Tasks)
        {
            var card = new Border
            {
                BorderBrush = TryBrush("BorderSubtle"),
                BorderThickness = new Thickness(1),
                CornerRadius = new CornerRadius(8),
                Padding = new Thickness(12),
                Margin = new Thickness(0, 0, 0, 8),
            };
            var stack = new StackPanel();
            stack.Children.Add(new TextBlock { Text = task.Name, FontWeight = FontWeight.SemiBold });
            stack.Children.Add(new TextBlock { Text = task.Cron, FontFamily = new FontFamily("monospace"), FontSize = 11, Foreground = TryBrush("TextSecondary") });
            var next = task.NextRun();
            stack.Children.Add(new TextBlock
            {
                Text = next is { } n
                    ? Model.L("settings.next", n.LocalDateTime.ToString("g", Model.Localization.Culture))
                    : Model.L("settings.invalidCron"),
                FontSize = 11,
                Foreground = TryBrush("TextSecondary"),
            });
            stack.Children.Add(new TextBlock
            {
                Text = Model.L("settings.last", LocalizedTaskState(task.LastState)
                    + (string.IsNullOrEmpty(task.LastMessage) ? "" : $" — {task.LastMessage}")),
                FontSize = 11,
                Foreground = task.LastState == TaskRunKind.Failed ? new SolidColorBrush(Colors.IndianRed) : TryBrush("TextSecondary"),
                TextWrapping = TextWrapping.Wrap,
                Margin = new Thickness(0, 2, 0, 0),
            });
            var row = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 8, 0, 0) };
            var enabled = new CheckBox { Content = Model.L("settings.enabled"), IsChecked = task.Enabled, VerticalAlignment = VerticalAlignment.Center };
            enabled.IsCheckedChanged += (_, _) => scheduler.SetEnabled(task.Id, enabled.IsChecked == true);
            row.Children.Add(enabled);
            var run = new Button { Content = Model.L("settings.runNow"), Margin = new Thickness(12, 0, 0, 0), Padding = new Thickness(10, 2, 10, 2) };
            run.Click += (_, _) => { scheduler.RunNow(task.Id); ShowTasks(); };
            row.Children.Add(run);
            var del = new Button { Content = Model.L("settings.delete"), Margin = new Thickness(8, 0, 0, 0), Padding = new Thickness(10, 2, 10, 2) };
            del.Click += (_, _) => { scheduler.Delete(task.Id); ShowTasks(); };
            row.Children.Add(del);
            stack.Children.Add(row);
            card.Child = stack;
            panel.Children.Add(card);
        }

        Body.Content = panel;
    }

    private static IEnumerable<DateTimeOffset> NextRuns(CronExpression expression, int count)
    {
        var cursor = DateTimeOffset.Now;
        for (var i = 0; i < count; i++)
        {
            var next = expression.NextDate(cursor);
            if (next is not { } value) yield break;
            yield return value;
            cursor = value;
        }
    }

    private void ShowMcp()
    {
        var model = Model;
        var panel = new StackPanel { Spacing = 8 };
        panel.Children.Add(new TextBlock
        {
            Text = model.L("settings.mcpServers"),
            FontSize = 22,
            FontWeight = FontWeight.SemiBold,
            Margin = new Thickness(0, 0, 0, 8),
        });

        _mcpStatusRows = new StackPanel { Spacing = 8 };
        panel.Children.Add(_mcpStatusRows);
        RefreshMcpStatuses();

        panel.Children.Add(new TextBlock
        {
            Text = model.L("mcp.addServer"),
            FontSize = 16,
            FontWeight = FontWeight.SemiBold,
            Margin = new Thickness(0, 20, 0, 0),
        });
        panel.Children.Add(new TextBlock { Text = model.L("mcp.name") });
        var name = new TextBox { Text = _mcpName, MinWidth = 340 };
        name.TextChanged += (_, _) => _mcpName = name.Text ?? "";
        panel.Children.Add(name);

        panel.Children.Add(new TextBlock { Text = model.L("mcp.transport") });
        var transport = new ComboBox { Width = 220, HorizontalAlignment = HorizontalAlignment.Left };
        transport.Items.Add(new ComboBoxItem { Content = model.L("mcp.http"), Tag = McpTransportKind.Http });
        transport.Items.Add(new ComboBoxItem { Content = model.L("mcp.stdio"), Tag = McpTransportKind.Stdio });
        transport.SelectedIndex = _mcpTransport == McpTransportKind.Http ? 0 : 1;
        panel.Children.Add(transport);

        _mcpHttpFields = new StackPanel { Spacing = 6 };
        _mcpHttpFields.Children.Add(new TextBlock { Text = model.L("mcp.url") });
        var url = new TextBox { Text = _mcpUrl, MinWidth = 340 };
        url.TextChanged += (_, _) => _mcpUrl = url.Text ?? "";
        _mcpHttpFields.Children.Add(url);
        _mcpHttpFields.Children.Add(new TextBlock { Text = model.L("mcp.bearerToken") });
        var token = new TextBox { Text = _mcpToken, PasswordChar = '●', MinWidth = 340 };
        token.TextChanged += (_, _) => _mcpToken = token.Text ?? "";
        _mcpHttpFields.Children.Add(token);
        panel.Children.Add(_mcpHttpFields);

        _mcpStdioFields = new StackPanel { Spacing = 6 };
        _mcpStdioFields.Children.Add(new TextBlock { Text = model.L("mcp.executable") });
        var command = new TextBox { Text = _mcpCommand, MinWidth = 340 };
        command.TextChanged += (_, _) => _mcpCommand = command.Text ?? "";
        _mcpStdioFields.Children.Add(command);
        _mcpStdioFields.Children.Add(new TextBlock { Text = model.L("mcp.arguments") });
        var arguments = new TextBox { Text = _mcpArguments, MinWidth = 340 };
        arguments.TextChanged += (_, _) => _mcpArguments = arguments.Text ?? "";
        _mcpStdioFields.Children.Add(arguments);
        panel.Children.Add(_mcpStdioFields);

        void SetTransport()
        {
            _mcpTransport = (transport.SelectedItem as ComboBoxItem)?.Tag is McpTransportKind selected
                ? selected
                : McpTransportKind.Http;
            _mcpHttpFields.IsVisible = _mcpTransport == McpTransportKind.Http;
            _mcpStdioFields.IsVisible = _mcpTransport == McpTransportKind.Stdio;
        }
        transport.SelectionChanged += (_, _) => SetTransport();
        SetTransport();

        var autoRun = new CheckBox
        {
            Content = model.L("mcp.autoRunReadOnly"),
            IsChecked = _mcpAutoRunReadOnly,
            Margin = new Thickness(0, 8, 0, 0),
        };
        autoRun.Click += (_, _) => _mcpAutoRunReadOnly = autoRun.IsChecked == true;
        panel.Children.Add(autoRun);
        panel.Children.Add(new TextBlock
        {
            Text = model.L("mcp.autoRunHelp"),
            TextWrapping = TextWrapping.Wrap,
            Foreground = TryBrush("TextSecondary"),
        });

        _mcpTestStatus = new TextBlock { TextWrapping = TextWrapping.Wrap, Foreground = TryBrush("TextSecondary") };
        panel.Children.Add(_mcpTestStatus);
        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        var test = new Button { Content = model.L("mcp.test"), Padding = new Thickness(12, 5) };
        test.Click += async (_, _) =>
        {
            _mcpTestStatus.Text = model.L("mcp.testing");
            var result = await model.McpRegistry.TestAsync(McpDraft(), _mcpTransport == McpTransportKind.Http ? _mcpToken : null);
            _mcpTestStatus.Text = result.ToolCount is { } count ? model.L("mcp.testConnected", count) : result.Error ?? "Connection failed.";
        };
        var add = new Button { Content = model.L("mcp.add"), Padding = new Thickness(12, 5) };
        add.Click += async (_, _) =>
        {
            try
            {
                var config = McpDraft();
                model.McpRegistry.Upsert(config, _mcpTransport == McpTransportKind.Http ? _mcpToken : null);
                _mcpName = _mcpUrl = _mcpCommand = _mcpArguments = _mcpToken = "";
                _mcpAutoRunReadOnly = false;
                _mcpTestStatus.Text = "";
                ShowMcp();
                await model.McpRegistry.ConnectAsync(config.Id);
            }
            catch (Exception error) { _mcpTestStatus.Text = error.Message; }
        };
        actions.Children.Add(test);
        actions.Children.Add(add);
        panel.Children.Add(actions);
        Body.Content = panel;
    }

    private McpServerConfig McpDraft() => new()
    {
        Name = _mcpName,
        Transport = _mcpTransport,
        Url = _mcpUrl,
        Command = _mcpCommand,
        Arguments = _mcpArguments.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries),
        AutoRunReadOnly = _mcpAutoRunReadOnly,
    };

    private void RefreshMcpStatuses()
    {
        if (_mcpStatusRows is null) return;
        var model = Model;
        _mcpStatusRows.Children.Clear();
        var statuses = model.McpRegistry.Statuses;
        if (statuses.Count == 0)
        {
            _mcpStatusRows.Children.Add(new TextBlock
            {
                Text = model.L("mcp.empty"),
                Foreground = TryBrush("TextSecondary"),
                Margin = new Thickness(0, 0, 0, 12),
            });
            return;
        }
        foreach (var status in statuses)
        {
            var row = new DockPanel { Margin = new Thickness(0, 0, 0, 8), LastChildFill = false };
            var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
            var reconnect = new Button { Content = model.L("mcp.reconnect"), Padding = new Thickness(8, 3) };
            reconnect.Click += async (_, _) => await model.McpRegistry.ConnectAsync(status.Id);
            var remove = new Button { Content = model.L("mcp.remove"), Padding = new Thickness(8, 3) };
            remove.Click += async (_, _) => await model.McpRegistry.RemoveAsync(status.Id);
            actions.Children.Add(reconnect);
            actions.Children.Add(remove);
            DockPanel.SetDock(actions, Dock.Right);
            row.Children.Add(actions);
            var label = status.State switch
            {
                McpConnectionState.Connecting => model.L("mcp.connecting"),
                McpConnectionState.Connected => model.L("mcp.connected", status.ToolCount),
                McpConnectionState.Failed => model.L("mcp.failed", status.Error ?? ""),
                _ => model.L("mcp.idle"),
            };
            row.Children.Add(new TextBlock
            {
                Text = status.Name + " · " + label,
                TextWrapping = TextWrapping.Wrap,
                VerticalAlignment = VerticalAlignment.Center,
                MaxWidth = 460,
            });
            _mcpStatusRows.Children.Add(row);
        }
    }

    private void ShowLegal()
    {
        var panel = new StackPanel { Spacing = 10 };
        panel.Children.Add(Heading("legal.title"));
        panel.Children.Add(new TextBlock
        {
            Text = Model.L("legal.gateIntro"),
            TextWrapping = TextWrapping.Wrap,
            Foreground = TryBrush("TextSecondary"),
        });
        var open = new Button { Content = Model.L("legal.openWeb") };
        open.Click += (_, _) => new LegalWindow(Model, gate: false).Show(this);
        panel.Children.Add(open);
        panel.Children.Add(new TextBlock
        {
            Text = Model.L("legal.consentPrefs"),
            FontWeight = FontWeight.SemiBold,
            Margin = new Thickness(0, 8, 0, 0),
        });
        foreach (var name in DotsHarnessCore.LegalService.ConsentKeys)
        {
            panel.Children.Add(new TextBlock { Text = Model.L($"legal.consent.{name}"), TextWrapping = TextWrapping.Wrap });
        }
        Body.Content = panel;
    }

    private string? MemoryWorkspace()
    {
        if (Model.IsRemoteWorkLocation) return null;
        var path = Model.Bridge.Selected?.Cwd ?? Model.WorkspacePath;
        return !string.IsNullOrWhiteSpace(path) && Directory.Exists(path) ? path : null;
    }

    private void ShowMemory()
    {
        var workspace = MemoryWorkspace();
        _memoryVault = WorkspaceMemoryVault.Read(workspace, Model.Paths.Root);
        var panel = new StackPanel();
        panel.Children.Add(new TextBlock { Text = Model.L("memory.vault.title"), FontSize = 22, FontWeight = FontWeight.SemiBold, Margin = new Thickness(0, 0, 0, 10) });
        var toolbar = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 0, 0, 8), Spacing = 6 };
        var refresh = new Button { Content = Model.L("memory.refresh"), Padding = new Thickness(10, 4) };
        refresh.Click += (_, _) => ShowMemory();
        toolbar.Children.Add(refresh);
        if (workspace is not null && Directory.Exists(Path.Combine(workspace, ".mem")))
        {
            var reveal = new Button { Content = Model.L("memory.reveal"), Padding = new Thickness(10, 4) };
            reveal.Click += (_, _) => Process.Start(new ProcessStartInfo("xdg-open", Path.Combine(workspace, ".mem")) { UseShellExecute = false });
            toolbar.Children.Add(reveal);
        }
        panel.Children.Add(toolbar);
        if (_memoryStatus is not null)
            panel.Children.Add(new TextBlock { Text = _memoryStatus, Foreground = _memoryStatus == Model.L("memory.refused") ? Brushes.IndianRed : TryBrush("TextSecondary"), TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 0, 0, 8) });
        if (workspace is null || _memoryVault.Notes.Count == 0)
        {
            panel.Children.Add(new TextBlock { Text = Model.L(workspace is null ? "memory.noWorkspace" : "memory.notInitialized"), Foreground = TryBrush("TextSecondary"), TextWrapping = TextWrapping.Wrap });
            Body.Content = panel;
            return;
        }

        var search = new TextBox { Text = _memorySearch, Watermark = Model.L("memory.search"), Margin = new Thickness(0, 0, 0, 8), Padding = new Thickness(8, 5) };
        panel.Children.Add(search);
        _memoryGraph = new Canvas { Height = 142, Margin = new Thickness(0, 0, 0, 8), Background = TryBrush("ChromeBackground") };
        _memoryGraph.SizeChanged += (_, _) => DrawMemoryGraph();
        panel.Children.Add(_memoryGraph);
        var content = new Grid { Height = 390 };
        content.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(230) });
        content.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        _memoryList = new ListBox { Margin = new Thickness(0, 0, 8, 0) };
        _memoryDetail = new ContentControl();
        Grid.SetColumn(_memoryDetail, 1);
        content.Children.Add(_memoryList);
        content.Children.Add(_memoryDetail);
        panel.Children.Add(content);
        Body.Content = panel;
        search.TextChanged += (_, _) => { _memorySearch = search.Text ?? ""; PopulateMemoryList(); };
        _memoryList.SelectionChanged += (_, _) =>
        {
            if (_memoryList.SelectedItem is not ListBoxItem { Tag: MemoryNote note }) return;
            _memorySelectedId = note.Id;
            ShowMemoryDetail(note);
            DrawMemoryGraph();
        };
        PopulateMemoryList();
        DrawMemoryGraph();
    }

    private static readonly string[] MemoryKindOrder = ["map", "index", "profile", "project", "rule", "preference", "task", "conversation", "decision", "file", "missing", "note"];

    private List<MemoryNote> FilteredMemoryNotes() => _memoryVault.Notes
        .Where(note => string.IsNullOrWhiteSpace(_memorySearch)
            || (note.Title + "\n" + note.Body + "\n" + string.Join(" ", note.Tags)).Contains(_memorySearch, StringComparison.OrdinalIgnoreCase))
        .OrderBy(note => Array.IndexOf(MemoryKindOrder, note.Kind) is var rank && rank >= 0 ? rank : MemoryKindOrder.Length)
        .ThenBy(note => note.Title, StringComparer.OrdinalIgnoreCase).ToList();

    private void PopulateMemoryList()
    {
        if (_memoryList is null) return;
        var selectedId = _memorySelectedId;
        _memoryList.Items.Clear();
        foreach (var note in FilteredMemoryNotes())
        {
            var row = new StackPanel { Margin = new Thickness(2), Spacing = 2 };
            row.Children.Add(new TextBlock { Text = note.Title, TextTrimming = TextTrimming.CharacterEllipsis, FontWeight = FontWeight.SemiBold });
            if (note.Tags.Count > 0) row.Children.Add(new TextBlock { Text = string.Join(" · ", note.Tags), FontSize = 10, Foreground = TryBrush("TextSecondary"), TextTrimming = TextTrimming.CharacterEllipsis });
            _memoryList.Items.Add(new ListBoxItem { Content = row, Tag = note });
        }
        var selected = _memoryList.Items.OfType<ListBoxItem>().FirstOrDefault(item => (item.Tag as MemoryNote)?.Id == selectedId)
            ?? _memoryList.Items.OfType<ListBoxItem>().FirstOrDefault();
        if (selected is not null)
        {
            selected.IsSelected = true;
            _memorySelectedId = (selected.Tag as MemoryNote)?.Id;
        }
        else if (_memoryDetail is not null) _memoryDetail.Content = new TextBlock { Text = Model.L("memory.selectNote"), Foreground = TryBrush("TextSecondary") };
    }

    private void ShowMemoryDetail(MemoryNote note)
    {
        if (_memoryDetail is null) return;
        var workspace = MemoryWorkspace();
        var panel = new StackPanel { Margin = new Thickness(8, 0, 0, 0), Spacing = 4 };
        panel.Children.Add(new TextBlock { Text = note.Title, FontSize = 19, FontWeight = FontWeight.SemiBold, TextWrapping = TextWrapping.Wrap });
        if (!string.IsNullOrWhiteSpace(note.Path)) panel.Children.Add(new TextBlock { Text = note.Path, FontSize = 11, FontFamily = new FontFamily("monospace"), Foreground = TryBrush("TextSecondary"), Margin = new Thickness(0, 3, 0, 6) });
        if (note.Kind == "project")
        {
            var editor = new TextBox { Text = note.Body, AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MinHeight = 130, MaxLength = WorkspaceFacts.KnowledgeKeys.Contains(note.Title) ? WorkspaceFacts.MaxKnowledgeLength : WorkspaceFacts.MaxTextLength };
            panel.Children.Add(editor);
            var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, Margin = new Thickness(0, 8, 0, 0) };
            var save = new Button { Content = Model.L("memory.save"), Padding = new Thickness(10, 4) };
            save.Click += (_, _) => SaveMemory(new MemoryEdit(MemoryEditKind.SetProject, Key: note.Title, Value: editor.Text ?? ""));
            var forget = new Button { Content = Model.L("memory.forget"), Padding = new Thickness(10, 4) };
            forget.Click += (_, _) => SaveMemory(new MemoryEdit(MemoryEditKind.ForgetProject, Key: note.Title), clearSelection: true);
            actions.Children.Add(save); actions.Children.Add(forget); panel.Children.Add(actions);
            panel.Children.Add(new TextBlock { Text = $"{editor.Text?.Length ?? 0} / {editor.MaxLength}", FontSize = 10, Foreground = TryBrush("TextSecondary") });
        }
        else if (note.Id == "learned_rules")
        {
            var manual = WorkspaceLessons.ManualRules(workspace);
            panel.Children.Add(new TextBlock { Text = Model.L("memory.ownRules"), FontWeight = FontWeight.SemiBold });
            panel.Children.Add(new TextBlock { Text = Model.L("memory.rulesHelp"), FontSize = 11, Foreground = TryBrush("TextSecondary"), TextWrapping = TextWrapping.Wrap });
            var rules = new TextBox { Text = manual, AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MinHeight = 80, MaxLength = WorkspaceLessons.MaxLessonCharacters };
            panel.Children.Add(rules);
            var saveRules = new Button { Content = Model.L("memory.save"), Padding = new Thickness(10, 4), HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(0, 6, 0, 10) };
            saveRules.Click += (_, _) => SaveMemory(new MemoryEdit(MemoryEditKind.SetManualRules, Value: rules.Text ?? ""));
            panel.Children.Add(saveRules);
            panel.Children.Add(new TextBlock { Text = Model.L("memory.lessons"), FontWeight = FontWeight.SemiBold, Margin = new Thickness(0, 2, 0, 4) });
            var stats = WorkspaceLessons.LearningStats(workspace);
            panel.Children.Add(new TextBlock { Text = Model.L("memory.learningStats", stats.Turns, stats.Corrected), FontSize = 11, Foreground = TryBrush("TextSecondary"), Margin = new Thickness(0, 0, 0, 8) });
            foreach (var lesson in WorkspaceLessons.RankedRead(workspace)) panel.Children.Add(BuildLessonRow(lesson, stats.Uses.FirstOrDefault(item => lesson.Cited.StartsWith("[" + item.Record + " ", StringComparison.Ordinal)).Count));
        }
        else panel.Children.Add(new TextBox { Text = note.Body, IsReadOnly = true, AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MinHeight = 180, BorderThickness = new Thickness(0), Background = Brushes.Transparent, Foreground = TryBrush("TextPrimary") });

        AddMemoryLinks(panel, note.Links, "memory.links");
        AddMemoryLinks(panel, note.Backlinks, "memory.backlinks");
        _memoryDetail.Content = new ScrollViewer { Content = panel, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
    }

    private void AddMemoryLinks(StackPanel panel, IReadOnlyList<string> ids, string titleKey)
    {
        var targets = ids.Select(id => _memoryVault.Notes.FirstOrDefault(note => note.Id == id)).Where(note => note is not null).Cast<MemoryNote>().ToList();
        if (targets.Count == 0) return;
        panel.Children.Add(new TextBlock { Text = Model.L(titleKey), FontWeight = FontWeight.SemiBold, Margin = new Thickness(0, 10, 0, 4) });
        foreach (var target in targets)
        {
            var button = new Button { Content = target.Title, HorizontalContentAlignment = HorizontalAlignment.Left, Padding = new Thickness(4, 2) };
            button.Click += (_, _) => SelectMemoryNote(target.Id);
            panel.Children.Add(button);
        }
    }

    private Control BuildLessonRow(Lesson lesson, int uses)
    {
        var panel = new StackPanel { Spacing = 4 };
        if (_memoryEditingLessonId == lesson.Id)
        {
            var edit = new TextBox { Text = lesson.Rule, AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MinHeight = 48 };
            var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
            var save = new Button { Content = Model.L("memory.save"), Padding = new Thickness(8, 3) };
            save.Click += (_, _) => { _memoryEditingLessonId = null; SaveMemory(new MemoryEdit(MemoryEditKind.EditLesson, Id: lesson.Id, Value: edit.Text ?? "")); };
            var cancel = new Button { Content = Model.L("memory.cancel"), Padding = new Thickness(8, 3) };
            cancel.Click += (_, _) => { _memoryEditingLessonId = null; ShowMemoryDetail(_memoryVault.Notes.First(note => note.Id == "learned_rules")); };
            actions.Children.Add(save); actions.Children.Add(cancel); panel.Children.Add(edit); panel.Children.Add(actions);
        }
        else panel.Children.Add(new TextBlock { Text = lesson.Line, TextWrapping = TextWrapping.Wrap });
        var metadata = string.Join(" · ", new[] { lesson.IsExplicit ? Model.L("memory.userAuthored") : Model.L("memory.inferred"), Model.L("memory.learnedCount", lesson.Hits), Model.L("memory.usedCount", uses), lesson.IsActive(DateTimeOffset.UtcNow) ? "" : Model.L("memory.inactive"), string.Join(", ", lesson.Paths) }.Where(value => value.Length > 0));
        panel.Children.Add(new TextBlock { Text = metadata, FontSize = 10, Foreground = TryBrush("TextSecondary"), TextWrapping = TextWrapping.Wrap });
        if (_memoryEditingLessonId != lesson.Id)
        {
            var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 5 };
            if (!lesson.IsExplicit)
            {
                var pin = new Button { Content = Model.L("memory.pin"), Padding = new Thickness(7, 3) };
                pin.Click += (_, _) => SaveMemory(new MemoryEdit(MemoryEditKind.PinLesson, Id: lesson.Id)); actions.Children.Add(pin);
            }
            var edit = new Button { Content = Model.L("memory.edit"), Padding = new Thickness(7, 3) };
            edit.Click += (_, _) => { _memoryEditingLessonId = lesson.Id; ShowMemoryDetail(_memoryVault.Notes.First(note => note.Id == "learned_rules")); };
            var forget = new Button { Content = Model.L("memory.forget"), Padding = new Thickness(7, 3) };
            forget.Click += (_, _) => SaveMemory(new MemoryEdit(MemoryEditKind.ForgetLesson, Id: lesson.Id));
            actions.Children.Add(edit); actions.Children.Add(forget); panel.Children.Add(actions);
        }
        return new Border { Child = panel, Padding = new Thickness(8), Margin = new Thickness(0, 0, 0, 6), BorderBrush = TryBrush("BorderSubtle"), BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(6) };
    }

    private void SaveMemory(MemoryEdit edit, bool clearSelection = false)
    {
        var saved = WorkspaceMemoryVault.Edit(MemoryWorkspace(), Model.Paths.Root, edit);
        _memoryStatus = saved ? null : Model.L("memory.refused");
        if (clearSelection) _memorySelectedId = null;
        ShowMemory();
    }

    private void SelectMemoryNote(string id) { _memorySelectedId = id; PopulateMemoryList(); }

    private void DrawMemoryGraph()
    {
        if (_memoryGraph is null) return;
        _memoryGraph.Children.Clear();
        var notes = _memoryVault.Notes.Where(note => note.Kind is not ("missing" or "file")).ToList();
        if (notes.Count == 0) return;
        var width = Math.Max(_memoryGraph.Bounds.Width, 500);
        var height = 142d;
        var center = new Point(width / 2, height / 2);
        var radius = Math.Max(28, Math.Min(width * .40, height * .38));
        var positions = new Dictionary<string, Point>(StringComparer.Ordinal);
        for (var index = 0; index < notes.Count; index++)
        {
            var angle = 2 * Math.PI * index / notes.Count - Math.PI / 2;
            positions[notes[index].Id] = new Point(center.X + Math.Cos(angle) * radius, center.Y + Math.Sin(angle) * radius);
        }
        foreach (var edge in _memoryVault.Edges)
        {
            if (!positions.TryGetValue(edge.From, out var from) || !positions.TryGetValue(edge.To, out var to)) continue;
            _memoryGraph.Children.Add(new AvaloniaLine { StartPoint = from, EndPoint = to, Stroke = TryBrush("BorderSubtle"), StrokeThickness = 1 });
        }
        foreach (var note in notes)
        {
            var point = positions[note.Id];
            var dot = new Button { Content = "●", FontSize = 18, Padding = new Thickness(0), Width = 24, Height = 24, Background = Brushes.Transparent, BorderThickness = new Thickness(0), Foreground = note.Id == _memorySelectedId ? Brushes.DodgerBlue : TryBrush("TextSecondary") };
            ToolTip.SetTip(dot, note.Title);
            dot.Click += (_, _) => SelectMemoryNote(note.Id);
            Canvas.SetLeft(dot, point.X - 12); Canvas.SetTop(dot, point.Y - 12); _memoryGraph.Children.Add(dot);
            var label = new TextBlock { Text = note.Title, FontSize = 9, Foreground = TryBrush("TextSecondary"), IsHitTestVisible = false };
            Canvas.SetLeft(label, point.X + 10); Canvas.SetTop(label, point.Y + 5); _memoryGraph.Children.Add(label);
        }
    }

    private void ShowAccess()
    {
        var workspace = MemoryWorkspace();
        var panel = new StackPanel();
        panel.Children.Add(new TextBlock { Text = Model.L("settings.tab.access"), FontSize = 22, FontWeight = FontWeight.SemiBold, Margin = new Thickness(0, 0, 0, 12) });
        if (workspace is null)
        {
            panel.Children.Add(new TextBlock { Text = Model.L("access.noWorkspace"), TextWrapping = TextWrapping.Wrap, Foreground = TryBrush("TextSecondary") });
            Body.Content = panel;
            return;
        }
        WorkspaceAccessStore store;
        WorkspaceAccessSnapshot access;
        try { store = new WorkspaceAccessStore(workspace, Model.Paths.Root); access = store.Snapshot(); }
        catch (Exception error)
        {
            panel.Children.Add(new TextBlock { Text = error.Message, Foreground = Brushes.IndianRed, TextWrapping = TextWrapping.Wrap });
            Body.Content = panel;
            return;
        }

        var actor = AccessSection("access.currentActor");
        AddAccessValue(actor, "access.role", access.Role is { } actorRole ? AccessRole(actorRole) : Model.L("access.notAuthorized"));
        AddAccessValue(actor, "access.score", access.Score.ToString(System.Globalization.CultureInfo.InvariantCulture));
        AddAccessValue(actor, "access.device", access.DeviceId.Length == 0 ? "—" : access.DeviceId[..Math.Min(20, access.DeviceId.Length)]);
        AddAccessValue(actor, "access.publicKey", access.PublicKey);
        AddAccessValue(actor, "access.memoryRevision", access.Revision.ToString(System.Globalization.CultureInfo.InvariantCulture));
        if (!access.MemoryReady)
        {
            actor.Children.Add(new TextBlock { Text = Model.L("access.initializeHelp"), FontSize = 11, TextWrapping = TextWrapping.Wrap, Foreground = TryBrush("TextSecondary"), Margin = new Thickness(0, 8, 0, 6) });
            var initialize = new Button { Content = Model.L("access.initialize"), Padding = new Thickness(10, 4) };
            initialize.Click += (_, _) => RunAccess(() => store.Initialize());
            actor.Children.Add(initialize);
        }
        panel.Children.Add(actor);

        if (access.MemoryReady)
        {
            var members = AccessSection("access.members");
            if (access.Members.Count == 0) members.Children.Add(new TextBlock { Text = Model.L("access.noMembers"), Foreground = TryBrush("TextSecondary") });
            foreach (var member in access.Members)
            {
                var row = new DockPanel { Margin = new Thickness(0, 0, 0, 8), LastChildFill = false };
                if (member.DeviceId != access.DeviceId && access.Role == MemoryRole.Owner && !member.Revoked)
                {
                    var revoke = new Button { Content = Model.L("access.revoke"), Padding = new Thickness(8, 3), Margin = new Thickness(8, 0, 0, 0) };
                    revoke.Click += (_, _) => RunAccess(() => store.Revoke(member.DeviceId));
                    DockPanel.SetDock(revoke, Dock.Right); row.Children.Add(revoke);
                }
                var summary = new StackPanel();
                summary.Children.Add(new TextBlock { Text = member.DisplayName.Length > 0 ? member.DisplayName : member.PersonId, FontWeight = FontWeight.SemiBold });
                var detail = $"{AccessRoleName(member.Role)} · {member.Score} · {member.DeviceId[..Math.Min(12, member.DeviceId.Length)]}" + (member.Revoked ? " · " + Model.L("access.revoked") : "");
                summary.Children.Add(new TextBlock { Text = detail, FontSize = 11, Foreground = TryBrush("TextSecondary"), TextWrapping = TextWrapping.Wrap });
                row.Children.Add(summary); members.Children.Add(row);
            }
            panel.Children.Add(members);

            var invite = AccessSection("access.inviteDevice");
            Button? create = null;
            void RefreshInviteEnabled()
            {
                if (create is not null) create.IsEnabled = access.Role == MemoryRole.Owner && _accessDisplayName.Length > 0 && _accessPublicKey.Length > 0;
            }
            invite.Children.Add(AccessField("access.displayName", _accessDisplayName, value => { _accessDisplayName = value; RefreshInviteEnabled(); }));
            invite.Children.Add(AccessField("access.newDevicePublicKey", _accessPublicKey, value => { _accessPublicKey = value; RefreshInviteEnabled(); }, true));
            invite.Children.Add(new TextBlock { Text = Model.L("access.role"), FontWeight = FontWeight.SemiBold, FontSize = 12 });
            var roleBox = new ComboBox { Margin = new Thickness(0, 2, 0, 8) };
            foreach (var role in Enum.GetValues<MemoryRole>()) roleBox.Items.Add(new ComboBoxItem { Content = AccessRole(role), Tag = role });
            roleBox.SelectedIndex = Array.IndexOf(Enum.GetValues<MemoryRole>(), _accessInviteRole);
            roleBox.SelectionChanged += (_, _) => { if (roleBox.SelectedItem is ComboBoxItem { Tag: MemoryRole selectedRole }) _accessInviteRole = selectedRole; };
            invite.Children.Add(roleBox);
            invite.Children.Add(new TextBlock { Text = Model.L("access.score"), FontWeight = FontWeight.SemiBold, FontSize = 12 });
            var score = new TextBox { Text = ((int)_accessInviteScore).ToString(System.Globalization.CultureInfo.InvariantCulture), MaxLength = 3, Margin = new Thickness(0, 2, 0, 8) };
            score.TextChanged += (_, _) => { if (int.TryParse(score.Text, out var value)) _accessInviteScore = Math.Clamp(value, 0, 100); };
            invite.Children.Add(score);
            create = new Button { Content = Model.L("access.createInvitation"), Padding = new Thickness(10, 4), IsEnabled = access.Role == MemoryRole.Owner && _accessDisplayName.Length > 0 && _accessPublicKey.Length > 0 };
            create.Click += (_, _) =>
            {
                try { _accessToken = store.CreateInvite(_accessDisplayName, _accessInviteRole, (int)_accessInviteScore, _accessPublicKey); _accessError = null; }
                catch (Exception error) { _accessError = error.Message; }
                ShowAccess();
            };
            invite.Children.Add(create);
            if (_accessToken.Length > 0) invite.Children.Add(new TextBox { Text = _accessToken, IsReadOnly = true, AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MinHeight = 70, Margin = new Thickness(0, 8, 0, 0) });
            panel.Children.Add(invite);

            var accept = AccessSection("access.acceptInvitation");
            var token = new TextBox { Text = _accessInvite, AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MinHeight = 65, Watermark = Model.L("access.signedInvitation") };
            var acceptButton = new Button { Content = Model.L("access.accept"), Padding = new Thickness(10, 4), Margin = new Thickness(0, 6, 0, 0), IsEnabled = !string.IsNullOrWhiteSpace(_accessInvite) };
            token.TextChanged += (_, _) => { _accessInvite = token.Text ?? ""; acceptButton.IsEnabled = !string.IsNullOrWhiteSpace(_accessInvite); };
            accept.Children.Add(token);
            acceptButton.Click += (_, _) => RunAccess(() => { store.AcceptInvite(_accessInvite); _accessInvite = ""; });
            accept.Children.Add(acceptButton);
            panel.Children.Add(accept);

            var decisions = AccessSection("access.pendingDecisions");
            if (access.PendingDecisions.Count == 0) decisions.Children.Add(new TextBlock { Text = Model.L("access.noPendingDecisions"), Foreground = TryBrush("TextSecondary") });
            foreach (var proposal in access.PendingDecisions)
            {
                var row = new StackPanel { Margin = new Thickness(0, 0, 0, 8) };
                row.Children.Add(new TextBlock { Text = proposal.Summary.Length > 0 ? proposal.Summary : proposal.EventId, TextWrapping = TextWrapping.Wrap });
                var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, Margin = new Thickness(0, 5, 0, 0) };
                var allowed = access.Role is { } actual && actual.Rank() >= MemoryRole.Approver.Rank();
                var approve = new Button { Content = Model.L("access.accept"), Padding = new Thickness(8, 3), IsEnabled = allowed };
                approve.Click += (_, _) => RunAccess(() => store.ResolveDecision(proposal.EventId, accept: true));
                var reject = new Button { Content = Model.L("access.reject"), Padding = new Thickness(8, 3), IsEnabled = allowed };
                reject.Click += (_, _) => RunAccess(() => store.ResolveDecision(proposal.EventId, accept: false));
                actions.Children.Add(approve); actions.Children.Add(reject); row.Children.Add(actions); decisions.Children.Add(row);
            }
            panel.Children.Add(decisions);
        }
        if (_accessError is not null) panel.Children.Add(new TextBlock { Text = _accessError, Foreground = Brushes.IndianRed, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 8, 0, 0) });
        Body.Content = panel;

        void RunAccess(Action operation)
        {
            try { operation(); _accessError = null; }
            catch (Exception error) { _accessError = error.Message; }
            ShowAccess();
        }
    }

    private StackPanel AccessSection(string titleKey)
    {
        var panel = new StackPanel { Margin = new Thickness(0, 0, 0, 14), Spacing = 4 };
        panel.Children.Add(new TextBlock { Text = Model.L(titleKey), FontSize = 15, FontWeight = FontWeight.SemiBold, Margin = new Thickness(0, 0, 0, 8) });
        return panel;
    }

    private void AddAccessValue(StackPanel section, string key, string value) =>
        section.Children.Add(new TextBlock { Text = Model.L(key) + ": " + value, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 2), FontSize = key == "access.publicKey" ? 10 : 12, FontFamily = key is "access.publicKey" or "access.device" ? new FontFamily("monospace") : new FontFamily("sans-serif") });

    private Control AccessField(string labelKey, string value, Action<string> changed, bool monospaced = false)
    {
        var field = new StackPanel { Margin = new Thickness(0, 0, 0, 8), Spacing = 3 };
        field.Children.Add(new TextBlock { Text = Model.L(labelKey), FontSize = 12, FontWeight = FontWeight.SemiBold });
        var input = new TextBox { Text = value, TextWrapping = TextWrapping.Wrap, AcceptsReturn = monospaced };
        input.TextChanged += (_, _) => changed(input.Text ?? "");
        field.Children.Add(input);
        return field;
    }

    private string AccessRole(MemoryRole role) => Model.L("access.role." + role.Value());
    private string AccessRoleName(string raw) => MemoryRoleRules.TryParse(raw, out var role) ? AccessRole(role) : raw;

    private void ShowPrompt()
    {
        var text = Model.EffectiveSystemPrompt();
        Body.Content = new TextBox
        {
            Text = string.IsNullOrEmpty(text) ? Model.L("settings.noPrompt") : text,
            IsReadOnly = true,
            TextWrapping = TextWrapping.Wrap,
            BorderThickness = new Thickness(0),
            Background = Brushes.Transparent,
            Foreground = TryBrush("TextPrimary"),
        };
    }

    private string AppearanceLabel(AppModel.AppearanceKind kind) => kind switch
    {
        AppModel.AppearanceKind.Light => Model.L("settings.appearanceLight"),
        AppModel.AppearanceKind.Dark => Model.L("settings.appearanceDark"),
        _ => Model.L("settings.appearanceSystem"),
    };

    private string ResponseStyleTitle() => Model.Language == AppLanguage.Turkish ? "Yanıt stili" : "Response style";

    private string ResponseStyleLabel(AgentResponseStylePreference preference) => Model.Language == AppLanguage.Turkish
        ? preference switch
        {
            AgentResponseStylePreference.Balanced => "Dengeli",
            AgentResponseStylePreference.Concise => "Kısa",
            AgentResponseStylePreference.Ultra => "Ultra kısa",
            _ => "Detaylı",
        }
        : preference switch
        {
            AgentResponseStylePreference.Balanced => "Balanced",
            AgentResponseStylePreference.Concise => "Concise",
            AgentResponseStylePreference.Ultra => "Ultra",
            _ => "Detailed",
        };

    private string LocalizedTaskState(TaskRunKind state) => state switch
    {
        TaskRunKind.Never => Model.L("settings.taskNever"),
        TaskRunKind.Running => Model.L("settings.taskRunning"),
        TaskRunKind.Ok => Model.L("settings.taskSucceeded"),
        TaskRunKind.Failed => Model.L("settings.taskFailed"),
        _ => state.ToString(),
    };

    private TextBlock Heading(string text) => new()
    {
        Text = T(text),
        FontSize = 18,
        FontWeight = FontWeight.SemiBold,
        Margin = new Thickness(0, 0, 0, 12),
    };

    private TextBlock Label(string text) => new()
    {
        Text = T(text),
        FontSize = 12,
        FontWeight = FontWeight.SemiBold,
        Margin = new Thickness(0, 0, 0, 4),
    };

    private static Control ProviderLine(string name, string key)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal };
        row.Children.Add(ProviderBadge(name, key));
        row.Children.Add(new TextBlock { Text = name, FontSize = 11, Foreground = TryBrush("TextSecondary"), VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(8, 0, 0, 0) });
        return row;
    }

    private static Border ProviderBadge(string name, string key)
    {
        Control content = LoadProviderMark(key) is { } mark
            ? new Image { Source = mark, Width = 16, Height = 16, Stretch = Avalonia.Media.Stretch.Uniform }
            : new TextBlock
            {
                Text = LogoMark(name, key),
                HorizontalAlignment = Avalonia.Layout.HorizontalAlignment.Center,
                VerticalAlignment = Avalonia.Layout.VerticalAlignment.Center,
                FontWeight = FontWeight.Bold,
                FontSize = 10,
                Foreground = Brushes.Black,
            };
        return new Border
        {
            Width = 25,
            Height = 25,
            CornerRadius = new CornerRadius(7),
            Background = Brushes.White,
            Child = content,
        };
    }

    private static readonly Dictionary<string, Bitmap> ProviderMarkCache = new(StringComparer.OrdinalIgnoreCase);

    private static Bitmap? LoadProviderMark(string key)
    {
        var resource = ProviderMarkCatalog.ResourceNameFor(key);
        if (resource is null) return null;
        if (ProviderMarkCache.TryGetValue(resource, out var cached)) return cached;
        try
        {
            using var stream = AssetLoader.Open(new Uri($"avares://DotsHarness/Resources/ProviderMarks/{resource}.png"));
            var bitmap = new Bitmap(stream);
            ProviderMarkCache[resource] = bitmap;
            return bitmap;
        }
        catch { return null; }
    }

    private static string LogoMark(string name, string key)
    {
        var known = key.ToLowerInvariant() switch
        {
            "gpt" => "✳",
            "gemini" => "✦",
            "openai" => "◎",
            "openrouter" => "↗",
            "github" => "GH",
            "iflow" => "iF",
            "minimax" => "MM",
            "cohere" => "Co",
            "siliconflow" => "SF",
            "chutes" => "Ch",
            "generic" => "•",
            _ => "",
        };
        if (!string.IsNullOrEmpty(known)) return known;
        var source = string.IsNullOrWhiteSpace(name) ? key : name;
        var words = source.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        return words.Length > 1
            ? string.Concat(words.Take(2).Select(word => word[0])).ToUpperInvariant()
            : source[..Math.Min(2, source.Length)].ToUpperInvariant();
    }

    private Control HeaderRow(string title, string status, Action? refresh)
    {
        var row = new DockPanel { Margin = new Thickness(0, 0, 0, 12) };
        row.Children.Add(Heading(title));
        var right = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
        right.Children.Add(new TextBlock { Text = status, FontSize = 11, Foreground = TryBrush("TextSecondary"), VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 8, 0) });
        if (refresh is not null)
        {
            var button = new Button { Content = Model.L("settings.refresh"), Padding = new Thickness(10, 4) };
            button.Click += (_, _) => refresh();
            right.Children.Add(button);
        }
        DockPanel.SetDock(right, Dock.Right);
        row.Children.Add(right);
        return row;
    }

    private Control BoundField(string label, string value, Action<string> set, bool password = false)
    {
        var stack = new StackPanel { Margin = new Thickness(0, 0, 0, 10) };
        stack.Children.Add(Label(label));
        if (password)
        {
            var box = new TextBox { Padding = new Thickness(8, 6), PasswordChar = '•', Text = value };
            box.TextChanged += (_, _) => set(box.Text ?? "");
            stack.Children.Add(box);
        }
        else
        {
            var box = new TextBox { Text = value, Padding = new Thickness(8, 6) };
            box.TextChanged += (_, _) => set(box.Text ?? "");
            stack.Children.Add(box);
        }
        return stack;
    }

    private Control Readonly(string label, string value)
    {
        var stack = new StackPanel { Margin = new Thickness(0, 0, 0, 10) };
        stack.Children.Add(Label(label));
        stack.Children.Add(new TextBox
        {
            Text = value,
            IsReadOnly = true,
            BorderThickness = new Thickness(0),
            Background = Brushes.Transparent,
            TextWrapping = TextWrapping.Wrap,
            Foreground = TryBrush("TextPrimary"),
        });
        return stack;
    }

    private void ShowSandbox()
    {
        var model = Model;
        var panel = new StackPanel { Spacing = 8 };
        panel.Children.Add(new TextBlock { Text = model.L("settings.sandbox"), FontSize = 22, FontWeight = FontWeight.SemiBold });
        panel.Children.Add(new TextBlock
        {
            Text = model.ActiveSandbox is null ? model.L("settings.sandboxOff") : model.L("settings.sandboxOn"),
            Foreground = TryBrush("TextSecondary"), TextWrapping = TextWrapping.Wrap,
        });
        panel.Children.Add(new TextBlock
        {
            Text = model.SandboxProcessIsolationStatus,
            Foreground = model.SandboxProcessIsolationAvailable ? TryBrush("TextSecondary") : Brushes.IndianRed,
            TextWrapping = TextWrapping.Wrap,
        });
        if (!string.IsNullOrWhiteSpace(model.SandboxNotice))
            panel.Children.Add(new TextBlock { Text = model.SandboxNotice, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 4) });

        var toolbar = new WrapPanel { Margin = new Thickness(0, 4, 0, 4) };
        var refresh = new Button { Content = model.L("settings.refresh"), Padding = new Thickness(10, 4), Margin = new Thickness(0, 0, 6, 6) };
        refresh.Click += async (_, _) => { await model.RefreshAvailableSandboxesAsync(); ShowSandbox(); };
        toolbar.Children.Add(refresh);
        if (model.ActiveSandbox is { } active)
        {
            var openSandbox = new Button { Content = model.L("settings.sandboxOpen"), Padding = new Thickness(10, 4), Margin = new Thickness(0, 0, 6, 6) };
            openSandbox.Click += (_, _) => model.RevealSandboxPath(active.Path);
            var openOrigin = new Button { Content = model.L("settings.sandboxOpenOrigin"), Padding = new Thickness(10, 4), Margin = new Thickness(0, 0, 6, 6) };
            openOrigin.Click += (_, _) => model.RevealSandboxPath(active.OriginPath);
            toolbar.Children.Add(openSandbox); toolbar.Children.Add(openOrigin);
        }
        panel.Children.Add(toolbar);

        if (model.SandboxRecoveryRequired)
        {
            panel.Children.Add(new TextBlock { Text = model.L("settings.sandboxRecoveryRequired"), Foreground = Brushes.IndianRed, TextWrapping = TextWrapping.Wrap });
            var retry = new Button { Content = model.L("settings.sandboxRetryRecovery"), Padding = new Thickness(10, 4), IsEnabled = !model.Bridge.AnyRunBusy };
            retry.Click += async (_, _) => await model.RetrySandboxRecoveryAsync();
            panel.Children.Add(retry);
        }

        if (model.ActiveSandbox is { } sandbox)
        {
            panel.Children.Add(SettingLine(model.L("settings.sandboxName"), sandbox.Name));
            panel.Children.Add(SettingLine(model.L("settings.sandboxOrigin"), sandbox.OriginPath));
            panel.Children.Add(SettingLine(model.L("settings.sandboxBranch"), sandbox.Branch));
            var network = new CheckBox { Content = model.L("settings.sandboxNetwork"), IsChecked = model.SandboxNetworkAccess };
            network.IsCheckedChanged += (_, _) => model.SandboxNetworkAccess = network.IsChecked == true;
            panel.Children.Add(network);
            panel.Children.Add(new TextBlock { Text = model.L("settings.sandboxNetwork.hint"), FontSize = 11, Foreground = TryBrush("TextSecondary"), TextWrapping = TextWrapping.Wrap });
            var actions = new WrapPanel();
            var merge = new Button { Content = model.L("settings.sandboxMerge"), Padding = new Thickness(10, 4), Margin = new Thickness(0, 0, 6, 6), IsEnabled = !model.Bridge.AnyRunBusy && !model.SandboxCleanupPending && !model.SandboxRecoveryRequired && model.SandboxConflict is null };
            merge.Click += async (_, _) => await model.ExitSandboxAsync(merge: true);
            var discard = new Button { Content = model.L("settings.sandboxDiscard"), Padding = new Thickness(10, 4), Margin = new Thickness(0, 0, 6, 6), IsEnabled = !model.Bridge.AnyRunBusy && !model.SandboxRecoveryRequired };
            discard.Click += async (_, _) =>
            {
                var confirmed = await new SandboxDiscardWindow(model.L("settings.sandbox"), model.L("settings.sandboxDiscardConfirm"), model.L("settings.cancel"), model.L("settings.sandboxDiscard")).ShowDialog<bool>(this);
                if (confirmed) await model.ExitSandboxAsync(merge: false);
            };
            actions.Children.Add(merge); actions.Children.Add(discard); panel.Children.Add(actions);
            if (model.SandboxCleanupPending)
            {
                panel.Children.Add(new TextBlock { Text = model.L("settings.sandboxCleanupPending"), Foreground = Brushes.DarkOrange, TextWrapping = TextWrapping.Wrap });
                var cleanup = new Button { Content = model.L("settings.sandboxRetryCleanup"), Padding = new Thickness(10, 4), IsEnabled = !model.Bridge.AnyRunBusy };
                cleanup.Click += async (_, _) => await model.RetrySandboxCleanupAsync();
                panel.Children.Add(cleanup);
            }
            if (model.SandboxConflict is { } conflict)
            {
                panel.Children.Add(new TextBlock { Text = model.L("settings.sandboxConflicts"), FontWeight = FontWeight.SemiBold, Margin = new Thickness(0, 8, 0, 0) });
                foreach (var file in conflict.Files) panel.Children.Add(new TextBlock { Text = "• " + file, FontFamily = new FontFamily("monospace"), TextWrapping = TextWrapping.Wrap });
                var conflictActions = new WrapPanel { Margin = new Thickness(0, 4, 0, 4) };
                var prepare = new Button { Content = model.L("settings.sandboxPrepareResolution"), Padding = new Thickness(10, 4), Margin = new Thickness(0, 0, 6, 6), IsEnabled = !model.SandboxResolutionBusy && !model.SandboxRecoveryRequired };
                prepare.Click += async (_, _) => await model.PrepareSandboxResolutionAsync();
                var ask = new Button { Content = model.L("settings.sandboxAskAgent"), Padding = new Thickness(10, 4), Margin = new Thickness(0, 0, 6, 6), IsEnabled = !model.Bridge.AnyRunBusy && !model.SandboxResolutionBusy };
                ask.Click += async (_, _) => await model.AskAgentToResolveSandboxConflictAsync();
                conflictActions.Children.Add(prepare); conflictActions.Children.Add(ask);
                if (model.SandboxResolutionPreview is not null)
                {
                    var previewButton = new Button { Content = model.L("settings.sandboxPreview"), Padding = new Thickness(10, 4), Margin = new Thickness(0, 0, 6, 6) };
                    previewButton.Click += async (_, _) => await model.PreviewSandboxResolutionAsync();
                    var cancel = new Button { Content = model.L("settings.sandboxCancelResolution"), Padding = new Thickness(10, 4), Margin = new Thickness(0, 0, 6, 6), IsEnabled = !model.SandboxResolutionBusy };
                    cancel.Click += async (_, _) => await model.CancelSandboxResolutionAsync();
                    conflictActions.Children.Add(previewButton); conflictActions.Children.Add(cancel);
                }
                panel.Children.Add(conflictActions);
                if (model.SandboxResolutionPreview is { } preview)
                {
                    panel.Children.Add(new TextBlock { Text = model.L("settings.sandboxResolutionReady"), FontWeight = FontWeight.SemiBold });
                    panel.Children.Add(new TextBlock { Text = model.L("settings.sandboxFingerprint") + ": " + preview.Fingerprint, FontSize = 10, Foreground = TryBrush("TextSecondary"), TextWrapping = TextWrapping.Wrap });
                    if (preview.UnresolvedFiles.Count > 0)
                        panel.Children.Add(new TextBlock { Text = model.L("settings.sandboxUnresolved") + ": " + string.Join(", ", preview.UnresolvedFiles), Foreground = Brushes.IndianRed, TextWrapping = TextWrapping.Wrap });
                    if (preview.IsTruncated) panel.Children.Add(ErrorText(model.L("settings.sandboxResolutionIncomplete")));
                    panel.Children.Add(new ScrollViewer
                    {
                        Content = new TextBox { Text = preview.Diff, IsReadOnly = true, AcceptsReturn = true, TextWrapping = TextWrapping.NoWrap, MinHeight = 180, FontFamily = new FontFamily("monospace") },
                        MaxHeight = 330,
                        HorizontalScrollBarVisibility = Avalonia.Controls.Primitives.ScrollBarVisibility.Auto,
                        VerticalScrollBarVisibility = Avalonia.Controls.Primitives.ScrollBarVisibility.Auto,
                    });
                    var approve = new Button { Content = model.L("settings.sandboxApprove"), Padding = new Thickness(10, 4), IsEnabled = !preview.IsTruncated && preview.UnresolvedFiles.Count == 0 && !model.SandboxResolutionBusy && !model.Bridge.AnyRunBusy };
                    approve.Click += async (_, _) => await model.ApplySandboxResolutionAsync();
                    panel.Children.Add(approve);
                }
            }
        }
        else
        {
            panel.Children.Add(new TextBlock { Text = model.L("settings.workspace") + ": " + (string.IsNullOrWhiteSpace(model.WorkspacePath) ? "—" : model.WorkspacePath), TextWrapping = TextWrapping.Wrap });
            var name = new TextBox { Text = _sandboxName, Width = 210, Watermark = model.L("settings.sandboxName"), Padding = new Thickness(7, 4) };
            name.TextChanged += (_, _) => _sandboxName = name.Text ?? "";
            var enter = new Button { Content = model.L("settings.sandboxEnter"), Padding = new Thickness(10, 4), IsEnabled = !string.IsNullOrWhiteSpace(model.WorkspacePath) && !model.IsRemoteWorkLocation && !model.SandboxRecoveryRequired && !model.Bridge.AnyRunBusy };
            enter.Click += async (_, _) => await model.EnterSandboxAsync(_sandboxName);
            panel.Children.Add(new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, Children = { name, enter } });
            if (model.AvailableSandboxes.Count > 0)
            {
                panel.Children.Add(new TextBlock { Text = model.L("settings.sandboxRecovery"), FontWeight = FontWeight.SemiBold, Margin = new Thickness(0, 8, 0, 0) });
                foreach (var candidate in model.AvailableSandboxes)
                {
                    var recover = new Button { Content = model.L("settings.sandboxRecover"), Padding = new Thickness(8, 3), Tag = candidate };
                    recover.Click += async (_, _) => await model.RecoverSandboxAsync(candidate);
                    panel.Children.Add(new StackPanel
                    {
                        Orientation = Orientation.Horizontal, Spacing = 8, Margin = new Thickness(0, 2),
                        Children = { recover, new TextBlock { Text = $"{candidate.Name} · {candidate.Branch}\n{candidate.Path}", TextWrapping = TextWrapping.Wrap, VerticalAlignment = VerticalAlignment.Center } },
                    });
                }
            }
        }
        Body.Content = new ScrollViewer { Content = panel, VerticalScrollBarVisibility = Avalonia.Controls.Primitives.ScrollBarVisibility.Auto };
    }

    private static Control SettingLine(string label, string value) => new StackPanel
    {
        Spacing = 2,
        Children =
        {
            new TextBlock { Text = label, FontWeight = FontWeight.SemiBold },
            new TextBlock { Text = value, TextWrapping = TextWrapping.Wrap, FontFamily = new FontFamily("monospace"), Foreground = TryBrush("TextSecondary") },
        },
    };

    private static TextBlock ErrorText(string text) => new()
    {
        Text = text,
        Foreground = Brushes.IndianRed,
        FontSize = 12,
        TextWrapping = TextWrapping.Wrap,
        Margin = new Thickness(0, 0, 0, 8),
    };

    private Border Badge(string text) => new()
    {
        Background = new SolidColorBrush(Color.FromArgb(20, 0, 0, 0)),
        CornerRadius = new CornerRadius(8),
        Padding = new Thickness(6, 2),
        Margin = new Thickness(0, 0, 6, 0),
        Child = new TextBlock { Text = text, FontSize = 10, FontWeight = FontWeight.SemiBold },
    };

    private static IBrush TryBrush(string key)
    {
        if (Application.Current?.TryGetResource(key, Application.Current.ActualThemeVariant, out var resource) == true
            && resource is IBrush brush)
        {
            return brush;
        }
        return Brushes.Gray;
    }
}

internal sealed class SandboxDiscardWindow : Window
{
    public SandboxDiscardWindow(string title, string message, string cancelText, string discardText)
    {
        Title = title;
        Width = 440;
        SizeToContent = SizeToContent.Height;
        CanResize = false;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        var cancel = new Button { Content = cancelText, Padding = new Thickness(12, 6) };
        cancel.Click += (_, _) => Close(false);
        var discard = new Button { Content = discardText, Padding = new Thickness(12, 6) };
        discard.Click += (_, _) => Close(true);
        Content = new StackPanel
        {
            Spacing = 14,
            Margin = new Thickness(20),
            Children =
            {
                new TextBlock { Text = message, TextWrapping = TextWrapping.Wrap },
                new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Spacing = 8, Children = { cancel, discard } },
            },
        };
    }
}

internal sealed class NativeMarketplaceConsentWindow : Window
{
    public NativeMarketplaceConsentWindow(NativeMarketplaceEntry entry)
    {
        Title = "Marketplace native plugin onayı";
        Width = 500;
        SizeToContent = SizeToContent.Height;
        CanResize = false;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;

        var accept = new Button
        {
            Content = "Kabul et ve etkinleştir",
            Padding = new Thickness(12, 7),
        };
        accept.Click += (_, _) => Close(true);

        var cancel = new Button
        {
            Content = "İptal",
            Padding = new Thickness(12, 7),
        };
        cancel.Click += (_, _) => Close(false);

        Content = new StackPanel
        {
            Spacing = 12,
            Margin = new Thickness(20),
            Children =
            {
                new TextBlock
                {
                    Text = $"{entry.Name} v{entry.Version}",
                    FontSize = 17,
                    FontWeight = FontWeight.SemiBold,
                    TextWrapping = TextWrapping.Wrap,
                },
                new TextBlock
                {
                    Text = $"Alan: {(entry.CatalogScope == "core" ? "Ana Marketplace" : entry.CatalogScope == "experimental" ? "Experimental" : "Community")} · Kategori: {entry.Category} · Risk: {entry.RiskLevel}\n\nBu işlem DOTS imzalı bir native kütüphane indirir ve çalıştırır. AI sınıflandırması yayın alanını ve kategori etiketini belirler; bu, güvenlik garantisi değildir. İzinler: {string.Join(", ", entry.Permissions ?? Array.Empty<string>())}. Kaynak kodunu ve lisansını inceledikten sonra açıkça kabul etmeden plugin etkinleştirilmeyecektir.",
                    TextWrapping = TextWrapping.Wrap,
                    Foreground = TryBrush("TextSecondary"),
                },
                new StackPanel
                {
                    Orientation = Orientation.Horizontal,
                    HorizontalAlignment = HorizontalAlignment.Right,
                    Spacing = 8,
                    Children = { cancel, accept },
                },
            },
        };
    }

    private static IBrush TryBrush(string key)
    {
        if (Application.Current?.TryGetResource(key, Application.Current.ActualThemeVariant, out var resource) == true
            && resource is IBrush brush)
        {
            return brush;
        }
        return Brushes.Gray;
    }
}

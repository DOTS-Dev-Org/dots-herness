using System.Diagnostics;
// Copyright (c) 2026 DOTS
// Plugin composition model derived from DeepSeek Harness.
// Copyright (c) 2026 DeepSeek. MIT. See NOTICE.

using System.Windows;
using System.ComponentModel;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using DotsHarnessCore;
using DotsHarness.Views;
using HarnessPluginKit;

namespace DotsHarness;

public partial class MainWindow : Window
{
    public MainWindow()
    {
        InitializeComponent();
        var model = ((App)Application.Current).Model;
        DataContext = model;
        Activated += (_, _) => { _ = model.Router.RefreshClaudeUsageAfterActivationAsync(); };
        Sidebar.DataContext = model;
        Conversation.DataContext = model;
        Settings.DataContext = model;
        RightDock.DataContext = model;
        model.PropertyChanged += OnModel;
        Settings.BackRequested += (_, _) => ShowConversation();
        OverlayHost.Slot = WellKnownSlot.Overlay;
        OverlayHost.Registry = model.Host.Slots;
        CommandBindings.Add(new CommandBinding(ApplicationCommands.New, (_, _) => model.NewConversation()));
        InputBindings.Add(new KeyBinding(new RelayCommand(_ => ShowSettings()), Key.OemComma, ModifierKeys.Control));
        Closing += OnClosing;
        // ShutdownMode is explicit now, so a window that really did close has to
        // end the process itself.
        Closed += (_, _) => ((App)Application.Current).ExitApplication();
        Loaded += OnLoaded;
        RefreshLocalization();
        ShowSection();
    }

    private readonly Dictionary<string, FrameworkElement> _sections = [];

    /// <summary>Builds the rail: one button per section, Settings at the foot. Mirrors macOS AppRailView.</summary>
    private void BuildRail()
    {
        var model = ((App)Application.Current).Model;
        Rail.Children.Clear();
        Button RailButton(string glyph, string title, bool selected, Action click)
        {
            var stack = new StackPanel();
            stack.Children.Add(new TextBlock { Text = glyph, FontSize = 17, HorizontalAlignment = HorizontalAlignment.Center });
            stack.Children.Add(new TextBlock { Text = title, FontSize = 10, HorizontalAlignment = HorizontalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis, FontWeight = selected ? FontWeights.SemiBold : FontWeights.Normal });
            var button = new Button
            {
                Content = stack, ToolTip = title, Width = 60, Height = 50, Margin = new Thickness(4, 2, 4, 2),
                BorderThickness = new Thickness(0), Foreground = Ui.Brush(selected ? "TextPrimary" : "TextSecondary"),
                Background = selected ? new SolidColorBrush(Color.FromArgb(0x30, 0x80, 0x80, 0x80)) : Brushes.Transparent,
            };
            button.Click += (_, _) => click();
            return button;
        }
        var glyphs = new Dictionary<string, string> { ["home"] = "⌂", ["media"] = "🖼", ["tasks"] = "◷", ["bots"] = "💬", ["marketplace"] = "🛍", ["memory"] = "🧠" };
        foreach (var section in AppModel.Sections.Where(s => s != "memory" || model.MemoryEnabled))
        {
            var button = RailButton(glyphs[section], model.L($"rail.{section}"), model.Section == section && Settings.Visibility != Visibility.Visible, () => OpenSection(section));
            DockPanel.SetDock(button, Dock.Top);
            Rail.Children.Add(button);
        }
        var settings = RailButton("⚙", model.L("rail.settings"), false, () => ShowSettings());
        DockPanel.SetDock(settings, Dock.Bottom);
        Rail.Children.Add(settings);
    }

    public void OpenSection(string section)
    {
        var model = ((App)Application.Current).Model;
        model.Section = section;
        if (section == "home") ShowConversation();
        ShowSection();
    }

    /// <summary>Only Home keeps the project sidebar and chat; the rest own the whole area.</summary>
    private void ShowSection()
    {
        var model = ((App)Application.Current).Model;
        var home = model.Section == "home";
        DesktopGrid.Visibility = home ? Visibility.Visible : Visibility.Collapsed;
        SectionHost.Visibility = home ? Visibility.Collapsed : Visibility.Visible;
        if (!home)
        {
            if (!_sections.TryGetValue(model.Section, out var view))
            {
                view = model.Section switch
                {
                    "media" => new MediaView(model),
                    "bots" => new BotsView(model),
                    "tasks" => new TasksSectionView(model),
                    "marketplace" => new MarketplaceSectionView(model),
                    _ => new MemorySectionView(model),
                };
                _sections[model.Section] = view;
            }
            SectionHost.Content = view;
            (view as ISectionView)?.Activate();
        }
        BuildRail();
    }

    private async void OnLoaded(object sender, RoutedEventArgs e)
    {
        var model = ((App)Application.Current).Model;
        await model.LoadLegalAsync();
        if (model.LegalNeedsAcceptance)
        {
            var dialog = new LegalDialog(model, gate: true) { Owner = this };
            if (dialog.ShowDialog() != true) Application.Current.Shutdown();
        }
        await PromptForUpdateAsync();
    }

    private async Task PromptForUpdateAsync()
    {
        var update = await CrossPlatformUpdateChecker.CheckOnStartupAsync("windows");
        if (update is null) return;
        var model = ((App)Application.Current).Model;
        var msg = $"{model.L("settings.updates.available", update.LatestVersion)}\n\n{update.ReleaseNotes}\n\n{model.L("settings.updates.download")}?";
        if (MessageBox.Show(this, msg, model.L("settings.updates.title"), update.Mandatory ? MessageBoxButton.OK : MessageBoxButton.YesNo) is MessageBoxResult.Yes or MessageBoxResult.OK
            && Uri.TryCreate(update.DownloadUrl, UriKind.Absolute, out var url) && url.Scheme == Uri.UriSchemeHttps)
            Process.Start(new ProcessStartInfo(url.AbsoluteUri) { UseShellExecute = true });
        if (update.Mandatory) Application.Current.Shutdown();
    }

    private void OnModel(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName is nameof(AppModel.Section) or nameof(AppModel.MemoryEnabled))
            Dispatcher.BeginInvoke(ShowSection);
        if (e.PropertyName is nameof(AppModel.Language) or nameof(AppModel.IsRightToLeft))
            Dispatcher.Invoke(RefreshLocalization);
        else if (e.PropertyName is nameof(AppModel.SelectedConversationId) or nameof(AppModel.WorkspacePath))
            Dispatcher.BeginInvoke(DismissCompactSidebar);
        if (e.PropertyName is nameof(AppModel.WorkspacePath)
            or nameof(AppModel.TerminalWorkspacePath)
            or nameof(AppModel.IsRemoteWorkLocation)
            or nameof(AppModel.WorkLocationLabel))
            Dispatcher.Invoke(RightDock.RefreshLocalization);
        if (e.PropertyName is nameof(AppModel.ActiveSandbox) or nameof(AppModel.SandboxNetworkAccess))
            Dispatcher.BeginInvoke(RightDock.RefreshSandboxPolicy);
    }

    private void RefreshLocalization()
    {
        var model = ((App)Application.Current).Model;
        Title = model.L("app.title");
        WindowTitle.Text = model.L("app.title");
        TasksButton.Content = model.L("settings.tasks");
        TasksButton.ToolTip = model.L("settings.tasks");
        PaneButton.Content = model.L("conversation.choosePane");
        SidebarToggle.ToolTip = model.L("sidebar.toggle");
        PaneButton.ToolTip = model.L("conversation.choosePane");
        FlowDirection = model.IsRightToLeft ? System.Windows.FlowDirection.RightToLeft : System.Windows.FlowDirection.LeftToRight;
        Sidebar.RefreshLocalization();
        Settings.RefreshLocalization();
        if (IsLoaded)
        {
            // Sections are rebuilt in the new language the next time they open.
            _sections.Clear();
            ShowSection();
        }
        RightDock.RefreshLocalization();
    }

    public void ShowSettings(string? tab = null)
    {
        var model = ((App)Application.Current).Model;
        if (model.Section != "home") { model.Section = "home"; ShowSection(); }
        Conversation.Visibility = Visibility.Collapsed;
        Settings.Visibility = Visibility.Visible;
        if (tab is not null) Settings.SelectTab(tab);
        BuildRail();
    }

    private void ShowConversation()
    {
        Settings.Visibility = Visibility.Collapsed;
        Conversation.Visibility = Visibility.Visible;
        BuildRail();
    }

    private bool _sidebarVisible = true;
    private bool _compactLayout;
    private bool _compactSidebarOpen;
    private bool _rightDockVisible;
    private double _sidebarWidth = 280;
    private double _rightDockWidth = 360;

    private void OnWindowSizeChanged(object sender, SizeChangedEventArgs e) => UpdateResponsiveLayout();

    private void UpdateResponsiveLayout()
    {
        var threshold = 840 + (_rightDockVisible ? 241 : 0);
        var compact = DesktopGrid.ActualWidth > 0 && DesktopGrid.ActualWidth < threshold;
        if (_compactLayout == compact)
        {
            if (compact) ApplyCompactSidebar();
            return;
        }

        _compactLayout = compact;
        if (compact)
        {
            if (SidebarColumn.ActualWidth > 1) _sidebarWidth = SidebarColumn.ActualWidth;
            SidebarColumn.MinWidth = 0;
            SidebarColumn.Width = new GridLength(0);
            SidebarSplitterColumn.Width = new GridLength(0);
            SidebarSplitter.Visibility = Visibility.Collapsed;
            Grid.SetColumnSpan(Sidebar, 3);
            Sidebar.HorizontalAlignment = HorizontalAlignment.Left;
            Sidebar.Width = Math.Min(300, Math.Max(250, DesktopGrid.ActualWidth - 48));
            Panel.SetZIndex(Sidebar, 11);
        }
        else
        {
            _compactSidebarOpen = false;
            CompactScrim.Visibility = Visibility.Collapsed;
            Grid.SetColumnSpan(Sidebar, 1);
            Sidebar.ClearValue(WidthProperty);
            Sidebar.HorizontalAlignment = HorizontalAlignment.Stretch;
            Panel.SetZIndex(Sidebar, 0);
            Sidebar.Visibility = _sidebarVisible ? Visibility.Visible : Visibility.Collapsed;
            SidebarSplitter.Visibility = _sidebarVisible ? Visibility.Visible : Visibility.Collapsed;
            SidebarSplitterColumn.Width = new GridLength(_sidebarVisible ? 5 : 0);
            SidebarColumn.MinWidth = _sidebarVisible ? 250 : 0;
            SidebarColumn.Width = new GridLength(_sidebarVisible ? _sidebarWidth : 0);
        }
        ApplyCompactSidebar();
    }

    private void ApplyCompactSidebar()
    {
        if (!_compactLayout) return;
        CompactScrim.Visibility = _compactSidebarOpen ? Visibility.Visible : Visibility.Collapsed;
        Sidebar.Visibility = _compactSidebarOpen ? Visibility.Visible : Visibility.Collapsed;
        Sidebar.HorizontalAlignment = ((App)Application.Current).Model.IsRightToLeft
            ? HorizontalAlignment.Right
            : HorizontalAlignment.Left;
        Sidebar.Width = Math.Min(300, Math.Max(250, DesktopGrid.ActualWidth - 48));
    }

    private void OnDismissCompactSidebar(object sender, RoutedEventArgs e)
    {
        DismissCompactSidebar();
    }

    private void DismissCompactSidebar()
    {
        _compactSidebarOpen = false;
        ApplyCompactSidebar();
    }

    private void OnPreviewKeyDown(object sender, KeyEventArgs e)
    {
        var key = (e.Key == Key.System ? e.SystemKey : e.Key).ToString();
        var modifiers = ShortcutModifierMask(Keyboard.Modifiers);
        if (Settings.HandleShortcutKey(key, modifiers))
        {
            e.Handled = true;
            return;
        }
        var model = ((App)Application.Current).Model;
        if (model.TryGetShortcutAction(key, modifiers, out var action))
        {
            DispatchShortcut(action);
            e.Handled = true;
            return;
        }
        if (e.Key != Key.Escape || !_compactLayout || !_compactSidebarOpen) return;
        DismissCompactSidebar();
        e.Handled = true;
    }

    private static byte ShortcutModifierMask(ModifierKeys modifiers)
    {
        byte mask = 0;
        if (modifiers.HasFlag(ModifierKeys.Control)) mask |= UserKeyboardShortcut.Control;
        if (modifiers.HasFlag(ModifierKeys.Alt)) mask |= UserKeyboardShortcut.Alt;
        if (modifiers.HasFlag(ModifierKeys.Shift)) mask |= UserKeyboardShortcut.Shift;
        if (modifiers.HasFlag(ModifierKeys.Windows)) mask |= UserKeyboardShortcut.Super;
        return mask;
    }

    public void DispatchShortcut(KeyboardShortcutAction action)
    {
        var model = ((App)Application.Current).Model;
        switch (action)
        {
            case KeyboardShortcutAction.ToggleSidebar:
                OnToggleSidebar(this, new RoutedEventArgs());
                break;
            case KeyboardShortcutAction.PullRequests:
                if (model.ActiveProjectLocationAvailable) _ = model.OpenPullRequestsAsync();
                break;
            case KeyboardShortcutAction.Scheduled:
                ShowSettings("tasks");
                break;
            case KeyboardShortcutAction.Review:
                ShowConversation();
                ShowDockTab("review");
                break;
            case KeyboardShortcutAction.Terminal:
                ShowConversation();
                ShowDockTab("terminal");
                break;
            case KeyboardShortcutAction.Browser:
                ShowConversation();
                ShowDockTab("browser");
                break;
            case KeyboardShortcutAction.Files:
                ShowConversation();
                ShowDockTab("files");
                break;
            case KeyboardShortcutAction.NewConversation:
                ShowConversation();
                model.NewConversation();
                break;
        }
    }

    private void ShowDockTab(string tab)
    {
        if (!_rightDockVisible) OnPanePicker(this, new RoutedEventArgs());
        RightDock.SelectTab(tab);
    }

    private void OnToggleSidebar(object sender, RoutedEventArgs e)
    {
        if (_compactLayout)
        {
            _compactSidebarOpen = !_compactSidebarOpen;
            ApplyCompactSidebar();
            return;
        }
        if (_sidebarVisible && SidebarColumn.ActualWidth > 1) _sidebarWidth = SidebarColumn.ActualWidth;
        _sidebarVisible = !_sidebarVisible;
        Sidebar.Visibility = _sidebarVisible ? Visibility.Visible : Visibility.Collapsed;
        SidebarSplitter.Visibility = _sidebarVisible ? Visibility.Visible : Visibility.Collapsed;
        SidebarSplitterColumn.Width = new GridLength(_sidebarVisible ? 5 : 0);
        SidebarColumn.MinWidth = _sidebarVisible ? 250 : 0;
        SidebarColumn.Width = _sidebarVisible ? new GridLength(_sidebarWidth) : new GridLength(0);
        SidebarToggle.Content = _sidebarVisible ? "☰" : "☷";
    }

    private void OnPanePicker(object sender, RoutedEventArgs e)
    {
        if (_rightDockVisible && RightDockColumn.ActualWidth > 1) _rightDockWidth = RightDockColumn.ActualWidth;
        _rightDockVisible = !_rightDockVisible;
        RightDock.Visibility = _rightDockVisible ? Visibility.Visible : Visibility.Collapsed;
        DockSplitter.Visibility = _rightDockVisible ? Visibility.Visible : Visibility.Collapsed;
        DockSplitterColumn.Width = _rightDockVisible ? new GridLength(5) : new GridLength(0);
        RightDockColumn.MinWidth = _rightDockVisible ? 240 : 0;
        RightDockColumn.Width = _rightDockVisible ? new GridLength(_rightDockWidth) : new GridLength(0);
        UpdateResponsiveLayout();
    }

    private void OnTasks(object sender, RoutedEventArgs e) => OpenSection("tasks");

    public void ShowBrowserPanel(string? url = null)
    {
        if (!_rightDockVisible) OnPanePicker(this, new RoutedEventArgs());
        if (url is null) RightDock.SelectTab("browser");
        else RightDock.OpenBrowser(url);
    }

    private bool _allowClose;

    private void OnClosing(object? sender, CancelEventArgs e)
    {
        var app = (App)Application.Current;
        var model = app.Model;
        if (app.IsExiting || _allowClose)
        {
            StopInteractiveSessions();
            return;
        }

        // The tray keeps this process alive, so the close button only hides the
        // window: runs, terminals and scheduled tasks carry on behind it.
        if (model.CloseToTray)
        {
            e.Cancel = true;
            Conversation.StopVoiceInput();
            Hide();
            app.NotifyHidden();
            return;
        }

        var dialog = new CloseConfirmationDialog(model, Icon) { Owner = this };
        if (dialog.ShowDialog() != true)
        {
            e.Cancel = true;
            return;
        }

        if (dialog.Remember) model.SetConfirmBeforeExit(false);
        _allowClose = true;
        StopInteractiveSessions();
    }

    private void StopInteractiveSessions()
    {
        Conversation.StopVoiceInput();
        Conversation.StopTerminal();
        RightDock.StopTerminal();
    }
}

internal sealed class CloseConfirmationDialog : Window
{
    private readonly CheckBox _remember;

    public bool Remember => _remember.IsChecked == true;

    public CloseConfirmationDialog(AppModel model, ImageSource? icon)
    {
        Title = model.L("window.confirmClose");
        FlowDirection = model.IsRightToLeft ? System.Windows.FlowDirection.RightToLeft : System.Windows.FlowDirection.LeftToRight;
        Width = 420;
        SizeToContent = SizeToContent.Height;
        ResizeMode = ResizeMode.NoResize;
        ShowInTaskbar = false;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        Background = (Brush)Application.Current.FindResource("PanelBackground");

        _remember = new CheckBox
        {
            Content = model.L("window.remember"),
            Margin = new Thickness(0, 10, 0, 0),
            FontSize = 13,
        };
        var copy = new StackPanel
        {
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(14, 0, 0, 0),
            Children =
            {
                new TextBlock
                {
                    Text = model.L("window.closeQuestion"),
                    FontSize = 16,
                    FontWeight = FontWeights.SemiBold,
                    Foreground = (Brush)Application.Current.FindResource("TextPrimary"),
                    TextWrapping = TextWrapping.Wrap,
                },
                _remember,
            },
        };
        var body = new Grid { Margin = new Thickness(0, 0, 0, 14) };
        body.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(64) });
        body.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var iconFrame = new Border
        {
            Width = 64,
            Height = 64,
            CornerRadius = new CornerRadius(14),
            ClipToBounds = true,
            Child = new Image
            {
                Source = icon,
                Stretch = Stretch.UniformToFill,
            },
        };
        Grid.SetColumn(copy, 1);
        body.Children.Add(iconFrame);
        body.Children.Add(copy);

        var close = new Button
        {
            Content = model.L("window.close"),
            IsDefault = true,
            Height = 36,
        };
        close.Click += (_, _) => DialogResult = true;
        var cancel = new Button
        {
            Content = model.L("window.cancel"),
            IsCancel = true,
            Height = 36,
        };

        var buttons = new Grid();
        buttons.ColumnDefinitions.Add(new ColumnDefinition());
        buttons.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(8) });
        buttons.ColumnDefinitions.Add(new ColumnDefinition());
        Grid.SetColumn(cancel, 2);
        buttons.Children.Add(close);
        buttons.Children.Add(cancel);

        Content = new Border
        {
            Padding = new Thickness(20),
            Child = new StackPanel
            {
                Children = { body, buttons },
            },
        };
    }
}

internal sealed class RelayCommand : ICommand
{
    private readonly Action<object?> _execute;
    private readonly Func<object?, bool>? _can;

    public RelayCommand(Action<object?> execute, Func<object?, bool>? can = null)
    {
        _execute = execute;
        _can = can;
    }

    public bool CanExecute(object? parameter) => _can?.Invoke(parameter) ?? true;
    public void Execute(object? parameter) => _execute(parameter);
    public event EventHandler? CanExecuteChanged
    {
        add => CommandManager.RequerySuggested += value;
        remove => CommandManager.RequerySuggested -= value;
    }
}

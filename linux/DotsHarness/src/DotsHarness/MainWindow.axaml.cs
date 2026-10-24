// Copyright (c) 2026 DOTS
// Plugin composition model derived from DeepSeek Harness.
// Copyright (c) 2026 DeepSeek. MIT. See NOTICE.

using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Interactivity;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Threading;
using DotsHarnessCore;
using System.ComponentModel;
using DotsHarness.Views;
using HarnessPluginKit;

namespace DotsHarness;

public partial class MainWindow : Window
{
    public MainWindow()
    {
        InitializeComponent();
        AddHandler(InputElement.KeyDownEvent, OnKeyDown, RoutingStrategies.Tunnel);
        var model = ((App)Application.Current!).Model;
        DataContext = model;
        Activated += (_, _) => { _ = model.Router.RefreshClaudeUsageAfterActivationAsync(); };
        Sidebar.DataContext = model;
        Conversation.DataContext = model;
        RightDock.DataContext = model;
        model.PropertyChanged += OnModel;
        OverlayHost.Slot = WellKnownSlot.Overlay;
        OverlayHost.Registry = model.Host.Slots;
        Closing += OnClosing;
        // ShutdownMode is explicit now, so a window that really did close has to
        // end the process itself.
        Closed += (_, _) => ((App)Application.Current!).ExitApplication();
        KeyBindings.Add(new KeyBinding
        {
            Gesture = new KeyGesture(Key.OemComma, KeyModifiers.Control),
            Command = new RelayCommand(_ => new SettingsWindow { DataContext = model }.Show(this)),
        });
        RefreshLocalization();
        ShowSection();
    }

    private readonly Dictionary<string, Control> _sections = [];

    /// <summary>Builds the rail: one button per section, Settings at the foot. Mirrors macOS AppRailView.</summary>
    private void BuildRail()
    {
        var model = ((App)Application.Current!).Model;
        Rail.Children.Clear();
        Button RailButton(string glyph, string title, bool selected, Action click)
        {
            var stack = new StackPanel();
            stack.Children.Add(new TextBlock { Text = glyph, FontSize = 17, HorizontalAlignment = HorizontalAlignment.Center });
            stack.Children.Add(new TextBlock { Text = title, FontSize = 10, HorizontalAlignment = HorizontalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis, FontWeight = selected ? FontWeight.SemiBold : FontWeight.Normal });
            var button = new Button
            {
                Content = stack, Width = 60, Height = 50, Margin = new Thickness(4, 2, 4, 2), HorizontalContentAlignment = HorizontalAlignment.Center,
                BorderThickness = new Thickness(0), Foreground = Ui.Brush(selected ? "TextPrimary" : "TextSecondary"),
                Background = selected ? new SolidColorBrush(Color.FromArgb(0x30, 0x80, 0x80, 0x80)) : Brushes.Transparent,
            };
            ToolTip.SetTip(button, title);
            button.Click += (_, _) => click();
            return button;
        }
        var glyphs = new Dictionary<string, string> { ["home"] = "⌂", ["media"] = "🖼", ["tasks"] = "◷", ["bots"] = "💬", ["marketplace"] = "🛍", ["memory"] = "🧠" };
        foreach (var section in AppModel.Sections.Where(s => s != "memory" || model.MemoryEnabled))
        {
            var button = RailButton(glyphs[section], model.L($"rail.{section}"), model.Section == section, () => OpenSection(section));
            DockPanel.SetDock(button, Dock.Top);
            Rail.Children.Add(button);
        }
        var settings = RailButton("⚙", model.L("rail.settings"), false, () => new SettingsWindow { DataContext = model }.Show(this));
        DockPanel.SetDock(settings, Dock.Bottom);
        Rail.Children.Add(settings);
    }

    public void OpenSection(string section)
    {
        ((App)Application.Current!).Model.Section = section;
        ShowSection();
    }

    /// <summary>Only Home keeps the project sidebar and chat; the rest own the whole area.</summary>
    private void ShowSection()
    {
        var model = ((App)Application.Current!).Model;
        var home = model.Section == "home";
        DesktopGrid.IsVisible = home;
        SectionHost.IsVisible = !home;
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

    private void OnModel(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName is nameof(AppModel.Section) or nameof(AppModel.MemoryEnabled))
            Dispatcher.UIThread.Post(ShowSection);
        if (e.PropertyName is nameof(AppModel.Language) or nameof(AppModel.IsRightToLeft))
        {
            Dispatcher.UIThread.Post(() =>
            {
                RefreshLocalization();
                // Sections are rebuilt in the new language the next time they open.
                _sections.Clear();
                ShowSection();
            });
            return;
        }
        if (e.PropertyName is nameof(AppModel.SelectedConversationId) or nameof(AppModel.WorkspacePath))
            Dispatcher.UIThread.Post(DismissCompactSidebar);
        if (e.PropertyName is nameof(AppModel.WorkspacePath)
            or nameof(AppModel.TerminalWorkspacePath)
            or nameof(AppModel.IsRemoteWorkLocation)
            or nameof(AppModel.WorkLocationLabel))
            Dispatcher.UIThread.Post(RightDock.RefreshLocalization);
        if (e.PropertyName is nameof(AppModel.ActiveSandbox) or nameof(AppModel.SandboxNetworkAccess))
            Dispatcher.UIThread.Post(RightDock.RefreshSandboxPolicy);
    }

    private void RefreshLocalization()
    {
        var model = ((App)Application.Current!).Model;
        Title = model.L("app.title");
        WindowTitle.Text = model.L("app.title");
        TasksButton.Content = model.L("settings.tasks");
        ToolTip.SetTip(TasksButton, model.L("settings.tasks"));
        PaneButton.Content = model.L("conversation.choosePane");
        ToolTip.SetTip(SidebarToggle, model.L("sidebar.toggle"));
        ToolTip.SetTip(PaneButton, model.L("conversation.choosePane"));
        FlowDirection = model.IsRightToLeft ? Avalonia.Media.FlowDirection.RightToLeft : Avalonia.Media.FlowDirection.LeftToRight;
        Sidebar.RefreshLocalization();
        RightDock.RefreshLocalization();
    }

    private bool _sidebarVisible = true;
    private bool _compactLayout;
    private bool _compactSidebarOpen;
    private bool _rightDockVisible;
    private double _sidebarWidth = 280;
    private double _rightDockWidth = 360;

    private void OnWindowSizeChanged(object? sender, SizeChangedEventArgs e) => UpdateResponsiveLayout();

    private void UpdateResponsiveLayout()
    {
        var threshold = 840 + (_rightDockVisible ? 241 : 0);
        var compact = DesktopGrid.Bounds.Width > 0 && DesktopGrid.Bounds.Width < threshold;
        if (_compactLayout == compact)
        {
            if (compact) ApplyCompactSidebar();
            return;
        }

        _compactLayout = compact;
        if (compact)
        {
            if (DesktopGrid.ColumnDefinitions[0].ActualWidth > 1)
                _sidebarWidth = DesktopGrid.ColumnDefinitions[0].ActualWidth;
            DesktopGrid.ColumnDefinitions[0].MinWidth = 0;
            DesktopGrid.ColumnDefinitions[0].Width = new GridLength(0);
            DesktopGrid.ColumnDefinitions[1].Width = new GridLength(0);
            SidebarSplitter.IsVisible = false;
            Grid.SetColumnSpan(Sidebar, 3);
            Sidebar.Width = Math.Min(300, Math.Max(250, DesktopGrid.Bounds.Width - 48));
            Sidebar.ZIndex = 11;
        }
        else
        {
            _compactSidebarOpen = false;
            CompactScrim.IsVisible = false;
            Grid.SetColumnSpan(Sidebar, 1);
            Sidebar.Width = double.NaN;
            Sidebar.HorizontalAlignment = HorizontalAlignment.Stretch;
            Sidebar.ZIndex = 0;
            Sidebar.IsVisible = _sidebarVisible;
            SidebarSplitter.IsVisible = _sidebarVisible;
            DesktopGrid.ColumnDefinitions[0].MinWidth = _sidebarVisible ? 250 : 0;
            DesktopGrid.ColumnDefinitions[0].Width = new GridLength(_sidebarVisible ? _sidebarWidth : 0);
            DesktopGrid.ColumnDefinitions[1].Width = new GridLength(_sidebarVisible ? 5 : 0);
        }
        ApplyCompactSidebar();
    }

    private void ApplyCompactSidebar()
    {
        if (!_compactLayout) return;
        CompactScrim.IsVisible = _compactSidebarOpen;
        Sidebar.IsVisible = _compactSidebarOpen;
        Sidebar.HorizontalAlignment = ((App)Application.Current!).Model.IsRightToLeft
            ? HorizontalAlignment.Right
            : HorizontalAlignment.Left;
        Sidebar.Width = Math.Min(300, Math.Max(250, DesktopGrid.Bounds.Width - 48));
    }

    private void OnDismissCompactSidebar(object? sender, RoutedEventArgs e)
    {
        DismissCompactSidebar();
    }

    private void DismissCompactSidebar()
    {
        _compactSidebarOpen = false;
        ApplyCompactSidebar();
    }

    private void OnKeyDown(object? sender, KeyEventArgs e)
    {
        var key = e.Key.ToString();
        var modifiers = ShortcutModifierMask(e.KeyModifiers);
        var model = ((App)Application.Current!).Model;
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

    private static byte ShortcutModifierMask(KeyModifiers modifiers)
    {
        byte mask = 0;
        if (modifiers.HasFlag(KeyModifiers.Control)) mask |= UserKeyboardShortcut.Control;
        if (modifiers.HasFlag(KeyModifiers.Alt)) mask |= UserKeyboardShortcut.Alt;
        if (modifiers.HasFlag(KeyModifiers.Shift)) mask |= UserKeyboardShortcut.Shift;
        if (modifiers.HasFlag(KeyModifiers.Meta)) mask |= UserKeyboardShortcut.Super;
        return mask;
    }

    public void DispatchShortcut(KeyboardShortcutAction action)
    {
        var model = ((App)Application.Current!).Model;
        switch (action)
        {
            case KeyboardShortcutAction.ToggleSidebar:
                OnToggleSidebar(this, new RoutedEventArgs());
                break;
            case KeyboardShortcutAction.PullRequests:
                if (model.ActiveProjectLocationAvailable) _ = model.OpenPullRequestsAsync();
                break;
            case KeyboardShortcutAction.Scheduled:
                OpenSettings("tasks");
                break;
            case KeyboardShortcutAction.Review:
                ShowDockTab("review");
                break;
            case KeyboardShortcutAction.Terminal:
                ShowDockTab("terminal");
                break;
            case KeyboardShortcutAction.Browser:
                ShowDockTab("browser");
                break;
            case KeyboardShortcutAction.Files:
                ShowDockTab("files");
                break;
            case KeyboardShortcutAction.NewConversation:
                model.NewConversation();
                break;
        }
    }

    private void ShowDockTab(string tab)
    {
        if (!_rightDockVisible) OnPanePicker(this, new RoutedEventArgs());
        RightDock.SelectTab(tab);
    }

    private void OnToggleSidebar(object? sender, RoutedEventArgs e)
    {
        if (_compactLayout)
        {
            _compactSidebarOpen = !_compactSidebarOpen;
            ApplyCompactSidebar();
            return;
        }
        if (_sidebarVisible)
        {
            _sidebarWidth = DesktopGrid.ColumnDefinitions[0].ActualWidth > 1
                ? DesktopGrid.ColumnDefinitions[0].ActualWidth
                : _sidebarWidth;
        }
        _sidebarVisible = !_sidebarVisible;
        Sidebar.IsVisible = _sidebarVisible;
        SidebarSplitter.IsVisible = _sidebarVisible;
        DesktopGrid.ColumnDefinitions[0].MinWidth = _sidebarVisible ? 250 : 0;
        DesktopGrid.ColumnDefinitions[0].Width = new GridLength(_sidebarVisible ? _sidebarWidth : 0);
        DesktopGrid.ColumnDefinitions[1].Width = new GridLength(_sidebarVisible ? 5 : 0);
        SidebarToggle.Content = _sidebarVisible ? "☰" : "☷";
    }

    private void OnPanePicker(object? sender, RoutedEventArgs e)
    {
        if (_rightDockVisible)
        {
            _rightDockWidth = DesktopGrid.ColumnDefinitions[4].ActualWidth > 1
                ? DesktopGrid.ColumnDefinitions[4].ActualWidth
                : _rightDockWidth;
        }
        _rightDockVisible = !_rightDockVisible;
        RightDock.IsVisible = _rightDockVisible;
        DockSplitter.IsVisible = _rightDockVisible;
        DesktopGrid.ColumnDefinitions[3].Width = new GridLength(_rightDockVisible ? 5 : 0);
        DesktopGrid.ColumnDefinitions[4].MinWidth = _rightDockVisible ? 240 : 0;
        DesktopGrid.ColumnDefinitions[4].Width = new GridLength(_rightDockVisible ? _rightDockWidth : 0);
        UpdateResponsiveLayout();
    }

    private void OnTasks(object? sender, RoutedEventArgs e) => OpenSection("tasks");

    public void ShowBrowserPanel(string? url = null)
    {
        if (!_rightDockVisible) OnPanePicker(this, new RoutedEventArgs());
        if (url is null) RightDock.SelectTab("browser");
        else RightDock.OpenBrowser(url);
    }

    private void OpenSettings(string tab)
    {
        var model = ((App)Application.Current!).Model;
        var window = new SettingsWindow { DataContext = model };
        window.Opened += (_, _) => window.SelectTab(tab);
        window.Show(this);
    }

    /// <summary>
    /// With the tray enabled the close button only hides the window: agent runs,
    /// terminals and the scheduler belong to this process, not to the UI.
    /// </summary>
    private void OnClosing(object? sender, CancelEventArgs e)
    {
        var app = (App)Application.Current!;
        if (app.IsExiting) return;
        if (app.Model.CloseToTray)
        {
            e.Cancel = true;
            Conversation.StopVoiceInput();
            Hide();
            app.NotifyHidden();
            return;
        }
        if (!app.Model.ConfirmBeforeExit) return;
        e.Cancel = true;
        app.RequestExit();
    }

    public void StopTerminal()
    {
        Conversation.StopTerminal();
        RightDock.StopTerminal();
    }
}

internal sealed class RelayCommand : System.Windows.Input.ICommand
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
    public event EventHandler? CanExecuteChanged;
}

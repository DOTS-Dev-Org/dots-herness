// Copyright (c) 2026 DOTS
// Project-first navigation shared in behavior with the macOS sidebar.

using System.ComponentModel;
using System.Globalization;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using DotsHarness;
using DotsHarnessCore;
using HarnessPluginKit;

namespace DotsHarness.Views;

public partial class SidebarView : UserControl
{
    private readonly System.Windows.Threading.DispatcherTimer _projectAvailabilityTimer = new() { Interval = TimeSpan.FromSeconds(5) };
    private bool _projectsExpanded = true;
    private bool _recentExpanded = true;
    private NotificationInboxStore? _observedInbox;
    private NotificationInboxWindow? _inboxWindow;

    public SidebarView()
    {
        InitializeComponent();
        DataContextChanged += OnCtx;
        // Pin and sort for the active project; the tray panel offers the same menu.
        ProjectList.MouseRightButtonUp += (_, _) =>
        {
            if (Model is { } model && !string.IsNullOrWhiteSpace(model.WorkspacePath))
                TrayPanel.OpenProjectMenu(model, model.WorkspacePath, ProjectList);
        };
        _projectAvailabilityTimer.Tick += (_, _) => Model?.RefreshProjectAvailability();
        Loaded += (_, _) => { Bind(); _projectAvailabilityTimer.Start(); };
        Unloaded += (_, _) => _projectAvailabilityTimer.Stop();
    }

    private AppModel? Model => DataContext as AppModel;

    private void OnCtx(object sender, DependencyPropertyChangedEventArgs e)
    {
        if (e.OldValue is INotifyPropertyChanged oldM) oldM.PropertyChanged -= OnModel;
        if (e.NewValue is INotifyPropertyChanged next) next.PropertyChanged += OnModel;
        if (_observedInbox is not null) _observedInbox.Changed -= OnInboxChanged;
        _observedInbox = (e.NewValue as AppModel)?.NotificationInbox;
        if (_observedInbox is not null) _observedInbox.Changed += OnInboxChanged;
        Bind();
    }

    private void OnInboxChanged(object? sender, EventArgs e) => Dispatcher.Invoke(Bind);

    private void OnModel(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName is nameof(AppModel.Language) or nameof(AppModel.IsRightToLeft))
            Dispatcher.Invoke(RefreshLocalization);
        if (e.PropertyName is nameof(AppModel.Conversations) or nameof(AppModel.SelectedConversationId)
            or nameof(AppModel.StatusLine) or nameof(AppModel.Selected) or nameof(AppModel.Projects)
            or nameof(AppModel.WorkspacePath) or null)
            Dispatcher.Invoke(Bind);
    }

    private void Bind()
    {
        if (Model is null) return;
        RefreshLocalization();
        FooterHost.Slot = WellKnownSlot.SidebarFooter;
        FooterHost.Registry = Model.Host.Slots;
        StatusText.Text = Model.StatusLine;
        var unread = Model.NotificationInbox.UnreadCount;
        NotificationsButton.Content = unread > 0 ? $"🔔 {unread}" : "🔔";

        var query = SearchBox.Text.Trim();
        var projects = Model.OrderedProjects
            .Where(path => MatchesProject(path, query))
            .Select(path => new ProjectSidebarEntry(
                path, (Model.IsProjectPinned(path) ? "★ " : "") + Model.ProjectTitle(path), Directory.Exists(path)))
            .ToList();
        ProjectList.ItemsSource = projects;
        ProjectList.SelectedItem = projects.FirstOrDefault(project => SamePath(project.Path, Model.WorkspacePath));

        var conversations = Model.Ordered(
                Model.Bridge.Conversations
                    .Where(item => SamePath(item.Cwd, Model.WorkspacePath))
                    .Where(item => !item.Archived)
                    .Where(item => MatchesConversation(item, query)),
                Model.WorkspacePath)
            .ToList();
        ConversationList.ItemsSource = conversations;
        ConversationList.SelectedItem = Model.Selected;

        var recent = Model.Bridge.RecentConversations(Model.ConnectedProjectPaths)
            .Where(item => !item.Archived)
            .Where(item => MatchesConversation(item, query))
            .OrderByDescending(RecentStamp)
            .Take(20)
            .ToList();
        RecentList.ItemsSource = recent;

        ProjectsPanel.Visibility = _projectsExpanded ? Visibility.Visible : Visibility.Collapsed;
        ConversationList.Visibility = _projectsExpanded ? Visibility.Visible : Visibility.Collapsed;
        RecentList.Visibility = _recentExpanded ? Visibility.Visible : Visibility.Collapsed;
        ProjectsToggle.Content = (_projectsExpanded ? "⌄  " : "›  ") + Model.L("sidebar.projects");
        RecentToggle.Content = (_recentExpanded ? "⌄  " : "›  ") + Model.L("sidebar.recent");
        NewButton.IsEnabled = Model.ActiveProjectLocationAvailable || Model.IsNoProjectScope;
        NewChatButton.IsEnabled = Model.ActiveProjectLocationAvailable || Model.IsNoProjectScope;
        PullRequestsButton.IsEnabled = !string.IsNullOrWhiteSpace(Model.WorkspacePath);
        ConversationList.IsEnabled = Model.Bridge.Connection is not null || conversations.Count > 0;
    }

    public void RefreshLocalization()
    {
        if (Model is null) return;
        ProjectsHeader.Text = Model.L("sidebar.projects");
        ConversationsHeader.Text = Model.L("memory.section.conversations");
        SearchButton.ToolTip = Model.L("sidebar.search");
        SearchBox.ToolTip = Model.L("sidebar.search");
        SettingsButton.ToolTip = Model.L("sidebar.settings");
        NotificationsButton.ToolTip = Model.L("notifications.title");
        UserButton.ToolTip = Model.L("sidebar.userMenu");
        UserMenuText.Text = Model.L("sidebar.userMenu");
        SettingsMenu.Header = Model.L("sidebar.settings");
        NewChatButton.Content = "□  " + Model.L("sidebar.newChat");
        NoProjectButton.Content = "◇  " + Model.L("workspace.noProject");
        PullRequestsButton.Content = "⑂  " + Model.L("sidebar.pullRequests");
        PullRequestsButton.ToolTip = Model.L("sidebar.pullRequests");
        SitesButton.Content = "▦  " + Model.L("sidebar.sites");
        NewButton.ToolTip = Model.L("sidebar.newChat");
        NewProjectButton.ToolTip = Model.L("sidebar.addProject");
        ScheduledButton.Content = "◷  " + Model.L("settings.tasks");
        PluginsButton.Content = "◌  " + Model.L("settings.plugins");
        StatusText.Text = Model.StatusLine;
    }

    private void OnNew(object sender, RoutedEventArgs e)
    {
        if (Model is { } model && (model.ActiveProjectLocationAvailable || model.IsNoProjectScope))
            model.NewConversation();
    }

    private void OnNoProject(object sender, RoutedEventArgs e) => Model?.SetWorkspace("");

    private async void OnPullRequests(object sender, RoutedEventArgs e)
    {
        if (Model is not null) await Model.OpenPullRequestsAsync();
    }

    private void OnNewProject(object sender, RoutedEventArgs e)
    {
        if (Model is null) return;
        var owner = Window.GetWindow(this);
        var input = new TextBox { Margin = new Thickness(0, 8, 0, 12), Padding = new Thickness(8, 6, 8, 6), MinWidth = 300 };
        var dialog = new Window
        {
            Title = Model.L("sidebar.addProject"),
            Width = 420,
            SizeToContent = SizeToContent.Height,
            WindowStartupLocation = owner is null ? WindowStartupLocation.CenterScreen : WindowStartupLocation.CenterOwner,
            ResizeMode = ResizeMode.NoResize,
            ShowInTaskbar = false,
            Owner = owner,
            Content = new StackPanel
            {
                Margin = new Thickness(16),
                Children = { new TextBlock { Text = Model.L("settings.folder") }, input },
            },
        };
        var buttons = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            HorizontalAlignment = HorizontalAlignment.Right,
            Margin = new Thickness(0, 0, 16, 12),
        };
        var cancel = new Button { Content = Model.L("settings.cancel"), MinWidth = 78, Margin = new Thickness(0, 0, 8, 0) };
        var create = new Button { Content = Model.L("workspace.use"), MinWidth = 78, IsDefault = true };
        cancel.Click += (_, _) => dialog.Close();
        create.Click += (_, _) =>
        {
            var path = input.Text.Trim();
            if (path.Length == 0) return;
            Model.AddProject(path);
            dialog.Close();
        };
        buttons.Children.Add(cancel);
        buttons.Children.Add(create);
        ((StackPanel)dialog.Content).Children.Add(buttons);
        dialog.ShowDialog();
    }

    private void OnProjectSelected(object sender, SelectionChangedEventArgs e)
    {
        if (Model is null || ProjectList.SelectedItem is not ProjectSidebarEntry project) return;
        if (!project.IsAvailable)
        {
            ShowProjectLocationDialog(project.Path);
            return;
        }
        if (!SamePath(Model.WorkspacePath, project.Path)) Model.SetWorkspace(project.Path);
    }

    private void ShowProjectLocationDialog(string missingPath)
    {
        if (Model is null) return;
        var owner = Window.GetWindow(this);
        var input = new TextBox { Margin = new Thickness(0, 8, 0, 8), Padding = new Thickness(8, 6, 8, 6), MinWidth = 360 };
        var hint = new TextBlock
        {
            Text = Model.L("project.missing.message", missingPath),
            TextWrapping = TextWrapping.Wrap,
            Foreground = System.Windows.Media.Brushes.Gray,
            Margin = new Thickness(0, 0, 0, 8),
        };
        var dialog = new Window
        {
            Title = Model.L("project.missing.title", Model.ProjectTitle(missingPath)),
            Width = 440,
            SizeToContent = SizeToContent.Height,
            WindowStartupLocation = owner is null ? WindowStartupLocation.CenterScreen : WindowStartupLocation.CenterOwner,
            ResizeMode = ResizeMode.NoResize,
            ShowInTaskbar = false,
            Owner = owner,
        };
        var cancel = new Button { Content = Model.L("settings.cancel"), MinWidth = 84, Margin = new Thickness(0, 0, 8, 0) };
        var locate = new Button { Content = Model.L("project.missing.locate"), MinWidth = 110, IsEnabled = false };
        input.TextChanged += (_, _) => locate.IsEnabled = Directory.Exists(input.Text.Trim());
        cancel.Click += (_, _) => dialog.Close();
        locate.Click += async (_, _) =>
        {
            locate.IsEnabled = false;
            if (await Model.RelocateProjectAsync(missingPath, input.Text.Trim())) dialog.Close();
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
            Children = { hint, new TextBlock { Text = Model.L("settings.folder") }, input, buttons },
        };
        if (owner is not null) dialog.Owner = owner;
        dialog.ShowDialog();
    }

    private void OnSelect(object sender, SelectionChangedEventArgs e) => SelectConversation(ConversationList.SelectedItem);

    private void OnArchiveConversation(object sender, RoutedEventArgs e)
    {
        if (sender is Button { Tag: Conversation conversation } && Model is { } model
            && model.Bridge.SetArchived(conversation.Id, true)
            && model.Bridge.SelectedId == conversation.Id)
            model.NewConversation();
        e.Handled = true;
    }

    private void OnArchiveConversationLoaded(object sender, RoutedEventArgs e)
    {
        if (sender is Button button && Model is { } model)
        {
            button.ToolTip = model.L("sidebar.archiveChat");
            System.Windows.Automation.AutomationProperties.SetName(button, model.L("sidebar.archiveChat"));
        }
    }

    private void OnPinConversationLoaded(object sender, RoutedEventArgs e)
    {
        if (sender is not Button { Tag: Conversation conversation } button || Model is not { } model) return;
        button.Content = conversation.Pinned ? "★" : "☆";
        button.ToolTip = model.L(conversation.Pinned ? "sidebar.unpinChat" : "sidebar.pinChat");
        System.Windows.Automation.AutomationProperties.SetName(button, model.L(conversation.Pinned ? "sidebar.unpinChat" : "sidebar.pinChat"));
    }

    private void OnTogglePinnedConversation(object sender, RoutedEventArgs e)
    {
        if (sender is Button { Tag: Conversation conversation } button && Model is { } model)
        {
            if (model.Bridge.TogglePinnedConversation(conversation.Id))
            {
                button.Content = conversation.Pinned ? "★" : "☆";
                button.ToolTip = model.L(conversation.Pinned ? "sidebar.unpinChat" : "sidebar.pinChat");
                System.Windows.Automation.AutomationProperties.SetName(button, model.L(conversation.Pinned ? "sidebar.unpinChat" : "sidebar.pinChat"));
            }
        }
        e.Handled = true;
    }

    private async void OnRecentSelect(object sender, SelectionChangedEventArgs e)
    {
        if (Model is { } model && RecentList.SelectedItem is Conversation conversation)
            await model.Bridge.OpenRecentConversationAsync(conversation.Id);
    }

    private void SelectConversation(object? value)
    {
        if (Model is not null && value is Conversation conversation)
            Model.SelectedConversationId = conversation.Id;
    }

    private void OnSearch(object sender, RoutedEventArgs e)
    {
        SearchPanel.Visibility = SearchPanel.Visibility == Visibility.Visible ? Visibility.Collapsed : Visibility.Visible;
        if (SearchPanel.Visibility == Visibility.Visible) SearchBox.Focus();
        else { SearchBox.Clear(); Bind(); }
    }

    private void OnNotifications(object sender, RoutedEventArgs e)
    {
        if (Model is not { } model) return;
        if (_inboxWindow is { IsVisible: true }) { _inboxWindow.Activate(); return; }
        var window = new NotificationInboxWindow(model.NotificationInbox, key => model.L(key), item =>
        {
            model.NotificationInbox.MarkRead(item.Id);
            if (!string.IsNullOrWhiteSpace(item.ConversationId))
                _ = model.Bridge.OpenRecentConversationAsync(item.ConversationId);
            _inboxWindow?.Close();
        });
        _inboxWindow = window;
        window.Closed += (_, _) => { if (ReferenceEquals(_inboxWindow, window)) _inboxWindow = null; };
        if (Window.GetWindow(this) is { } owner) { window.Owner = owner; window.Show(); }
        else window.Show();
    }

    private void OnClearSearch(object sender, RoutedEventArgs e) { SearchBox.Clear(); SearchBox.Focus(); }

    private void OnSearchChanged(object sender, TextChangedEventArgs e) => Bind();

    private void OnToggleProjects(object sender, RoutedEventArgs e) { _projectsExpanded = !_projectsExpanded; Bind(); }

    private void OnToggleRecent(object sender, RoutedEventArgs e) { _recentExpanded = !_recentExpanded; Bind(); }

    private void OnUserMenu(object sender, RoutedEventArgs e)
    {
        if (UserButton.ContextMenu is { } menu)
        {
            menu.PlacementTarget = UserButton;
            menu.IsOpen = true;
        }
        e.Handled = true;
    }

    private void OnSettings(object sender, RoutedEventArgs e)
    {
        if (Window.GetWindow(this) is MainWindow window) window.ShowSettings();
    }

    private void OnScheduled(object sender, RoutedEventArgs e)
    {
        if (Window.GetWindow(this) is MainWindow window) window.ShowSettings("tasks");
    }

    private void OnPlugins(object sender, RoutedEventArgs e)
    {
        if (Window.GetWindow(this) is MainWindow window) window.ShowSettings("plugins");
    }

    private void OnSites(object sender, RoutedEventArgs e)
    {
        if (Window.GetWindow(this) is MainWindow window)
            window.ShowBrowserPanel("https://dash.cloudflare.com/?to=/:account/pages");
    }

    private bool MatchesProject(string path, string query) =>
        string.IsNullOrWhiteSpace(query)
        || path.Contains(query, StringComparison.OrdinalIgnoreCase)
        || Model?.ProjectTitle(path).Contains(query, StringComparison.OrdinalIgnoreCase) == true;

    private static bool MatchesConversation(Conversation conversation, string query) =>
        string.IsNullOrWhiteSpace(query)
        || conversation.Title.Contains(query, StringComparison.OrdinalIgnoreCase)
        || conversation.Cwd?.Contains(query, StringComparison.OrdinalIgnoreCase) == true;

    private static DateTimeOffset RecentStamp(Conversation conversation) =>
        SessionProjector.LastActivity(conversation);

    internal static bool SamePath(string? left, string? right)
    {
        if (string.IsNullOrWhiteSpace(left) || string.IsNullOrWhiteSpace(right)) return false;
        try
        {
            return string.Equals(
                Path.GetFullPath(left).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar),
                Path.GetFullPath(right).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar),
                OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal);
        }
        catch { return false; }
    }
}

public sealed record ProjectSidebarEntry(string Path, string Title, bool IsAvailable)
{
    public double Opacity => IsAvailable ? 1.0 : 0.46;
}

public sealed class BoolToVis : IValueConverter
{
    public static readonly BoolToVis Instance = new();
    public object Convert(object value, Type targetType, object parameter, CultureInfo culture) =>
        value is true ? Visibility.Visible : Visibility.Collapsed;
    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) =>
        value is Visibility.Visible;
}

public sealed class ProjectTitleConverter : IValueConverter
{
    public static readonly ProjectTitleConverter Instance = new();

    public object Convert(object value, Type targetType, object parameter, CultureInfo culture)
    {
        if (value is not string path || string.IsNullOrWhiteSpace(path)) return "Project";
        try
        {
            var title = new DirectoryInfo(path).Name;
            return string.IsNullOrWhiteSpace(title) ? path : title;
        }
        catch { return path; }
    }

    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) =>
        System.Windows.Data.Binding.DoNothing;
}

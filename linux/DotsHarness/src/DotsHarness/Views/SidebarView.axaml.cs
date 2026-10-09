// Copyright (c) 2026 DOTS
// Project-first navigation shared in behavior with the macOS sidebar.

using System.ComponentModel;
using Avalonia.Controls;
using Avalonia.Data.Converters;
using Avalonia.Interactivity;
using Avalonia.Threading;
using DotsHarnessCore;
using HarnessPluginKit;

namespace DotsHarness.Views;

public partial class SidebarView : UserControl
{
    private bool _projectsExpanded = true;
    private bool _recentExpanded = true;
    private INotifyPropertyChanged? _observedModel;
    private readonly DispatcherTimer _projectAvailabilityTimer = new() { Interval = TimeSpan.FromSeconds(1) };

    public SidebarView()
    {
        InitializeComponent();
        // Pin and sort for the active project; the tray panel offers the same menu.
        ProjectList.ContextRequested += (_, e) =>
        {
            if (Model is not { } model || string.IsNullOrWhiteSpace(model.WorkspacePath)) return;
            TrayPanel.OpenProjectMenu(model, model.WorkspacePath, ProjectList);
            e.Handled = true;
        };
        _projectAvailabilityTimer.Tick += (_, _) => Model?.RefreshProjectAvailability();
        Loaded += (_, _) => { Bind(); _projectAvailabilityTimer.Start(); };
        Unloaded += (_, _) => _projectAvailabilityTimer.Stop();
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

    private void OnModel(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName is nameof(AppModel.Language) or nameof(AppModel.IsRightToLeft))
            Dispatcher.UIThread.Post(RefreshLocalization);
        if (e.PropertyName is nameof(AppModel.Conversations) or nameof(AppModel.SelectedConversationId)
            or nameof(AppModel.StatusLine) or nameof(AppModel.Selected) or nameof(AppModel.Projects)
            or nameof(AppModel.WorkspacePath) or null)
            Dispatcher.UIThread.Post(Bind);
    }

    private void Bind()
    {
        if (Model is null) return;
        RefreshLocalization();
        FooterHost.Slot = WellKnownSlot.SidebarFooter;
        FooterHost.Registry = Model.Host.Slots;
        StatusText.Text = Model.StatusLine;

        var query = SearchBox.Text?.Trim() ?? "";
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

        var recent = Model.Bridge.RecentConversations(Model.Projects)
            .Where(item => !item.Archived)
            .Where(item => MatchesConversation(item, query))
            .OrderByDescending(RecentStamp)
            .Take(20)
            .ToList();
        RecentList.ItemsSource = recent;

        ProjectsPanel.IsVisible = _projectsExpanded;
        ConversationList.IsVisible = _projectsExpanded;
        RecentList.IsVisible = _recentExpanded;
        ProjectsToggle.Content = (_projectsExpanded ? "⌄  " : "›  ") + "Projects";
        RecentToggle.Content = (_recentExpanded ? "⌄  " : "›  ") + "Recent";
        NewButton.IsEnabled = Model.ActiveProjectLocationAvailable || Model.IsNoProjectScope;
        NewChatButton.IsEnabled = Model.ActiveProjectLocationAvailable || Model.IsNoProjectScope;
        PullRequestsButton.IsEnabled = !string.IsNullOrWhiteSpace(Model.WorkspacePath);
        ConversationList.IsEnabled = Model.Bridge.Connection is not null || conversations.Count > 0;
    }

    public void RefreshLocalization()
    {
        if (Model is null) return;
        ProjectsHeader.Text = "Projects";
        ToolTip.SetTip(SearchButton, "Search");
        ToolTip.SetTip(SettingsButton, Model.L("sidebar.settings"));
        ToolTip.SetTip(UserButton, Model.L("sidebar.userMenu"));
        UserMenuText.Text = Model.L("sidebar.userMenu");
        NewChatButton.Content = "□  " + Model.L("sidebar.newChat");
        NoProjectButton.Content = "◇  " + Model.L("workspace.noProject");
        PullRequestsButton.Content = "⑂  Pull requests";
        SitesButton.Content = "▦  Sites";
        ScheduledButton.Content = "◷  " + Model.L("settings.tasks");
        PluginsButton.Content = "◌  " + Model.L("settings.plugins");
        StatusText.Text = Model.StatusLine;
    }

    private void OnNew(object? sender, RoutedEventArgs e)
    {
        if (Model is { } model && (model.ActiveProjectLocationAvailable || model.IsNoProjectScope))
            model.NewConversation();
    }

    private void OnNoProject(object? sender, RoutedEventArgs e) => Model?.SetWorkspace("");

    private async void OnPullRequests(object? sender, RoutedEventArgs e)
    {
        if (Model is not null) await Model.OpenPullRequestsAsync();
    }

    private void OnNewProject(object? sender, RoutedEventArgs e)
    {
        if (Model is null) return;
        var input = new TextBox
        {
            Margin = new Avalonia.Thickness(0, 8, 0, 12),
            Padding = new Avalonia.Thickness(8, 6),
            MinWidth = 360,
        };
        var dialog = new Window
        {
            Title = "Add project",
            Width = 420,
            SizeToContent = SizeToContent.Height,
            WindowStartupLocation = WindowStartupLocation.CenterOwner,
            CanResize = false,
            Content = new StackPanel
            {
                Margin = new Avalonia.Thickness(16),
                Children = { new TextBlock { Text = "Folder path" }, input },
            },
        };
        var buttons = new StackPanel
        {
            Orientation = Avalonia.Layout.Orientation.Horizontal,
            HorizontalAlignment = Avalonia.Layout.HorizontalAlignment.Right,
            Margin = new Avalonia.Thickness(0, 0, 16, 12),
        };
        var cancel = new Button { Content = Model.L("settings.cancel"), MinWidth = 78, Margin = new Avalonia.Thickness(0, 0, 8, 0) };
        var create = new Button { Content = Model.L("workspace.use"), MinWidth = 78 };
        cancel.Click += (_, _) => dialog.Close();
        create.Click += (_, _) =>
        {
            var path = input.Text?.Trim() ?? "";
            if (path.Length == 0) return;
            Model.AddProject(path);
            dialog.Close();
        };
        buttons.Children.Add(cancel);
        buttons.Children.Add(create);
        ((StackPanel)dialog.Content!).Children.Add(buttons);
        if (TopLevel.GetTopLevel(this) is Window owner) dialog.Show(owner);
        else dialog.Show();
    }

    private void OnProjectSelected(object? sender, SelectionChangedEventArgs e)
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
        var model = Model;
        var input = new TextBox { Margin = new Avalonia.Thickness(0, 8, 0, 8), Padding = new Avalonia.Thickness(8, 6), MinWidth = 360 };
        var hint = new TextBlock { Text = model.L("project.missing.message", missingPath), TextWrapping = Avalonia.Media.TextWrapping.Wrap, Margin = new Avalonia.Thickness(0, 0, 0, 8) };
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

    private void OnSelect(object? sender, SelectionChangedEventArgs e) => SelectConversation(ConversationList.SelectedItem);

    private void OnArchiveConversation(object? sender, RoutedEventArgs e)
    {
        if (sender is Button { Tag: Conversation conversation })
            Model?.Bridge.SetArchived(conversation.Id, true);
        e.Handled = true;
    }

    private void OnArchiveConversationLoaded(object? sender, RoutedEventArgs e)
    {
        if (sender is Button button && Model is { } model)
        {
            ToolTip.SetTip(button, model.L("sidebar.archiveChat"));
            Avalonia.Automation.AutomationProperties.SetName(button, model.L("sidebar.archiveChat"));
        }
    }

    private void OnPinConversationLoaded(object? sender, RoutedEventArgs e)
    {
        if (sender is not Button { Tag: Conversation conversation } button || Model is not { } model) return;
        button.Content = conversation.Pinned ? "★" : "☆";
        ToolTip.SetTip(button, model.L(conversation.Pinned ? "sidebar.unpinChat" : "sidebar.pinChat"));
        Avalonia.Automation.AutomationProperties.SetName(button, model.L(conversation.Pinned ? "sidebar.unpinChat" : "sidebar.pinChat"));
    }

    private void OnTogglePinnedConversation(object? sender, RoutedEventArgs e)
    {
        if (sender is Button { Tag: Conversation conversation } button && Model is { } model)
        {
            if (model.Bridge.TogglePinnedConversation(conversation.Id))
            {
                button.Content = conversation.Pinned ? "★" : "☆";
                ToolTip.SetTip(button, model.L(conversation.Pinned ? "sidebar.unpinChat" : "sidebar.pinChat"));
                Avalonia.Automation.AutomationProperties.SetName(button, model.L(conversation.Pinned ? "sidebar.unpinChat" : "sidebar.pinChat"));
            }
        }
        e.Handled = true;
    }

    private async void OnRecentSelect(object? sender, SelectionChangedEventArgs e)
    {
        if (Model is { } model && RecentList.SelectedItem is Conversation conversation)
            await model.Bridge.OpenRecentConversationAsync(conversation.Id);
    }

    private void SelectConversation(object? value)
    {
        if (Model is not null && value is Conversation conversation)
            Model.SelectedConversationId = conversation.Id;
    }

    private void OnSearch(object? sender, RoutedEventArgs e)
    {
        SearchPanel.IsVisible = !SearchPanel.IsVisible;
        if (SearchPanel.IsVisible) SearchBox.Focus();
        else { SearchBox.Text = ""; Bind(); }
    }

    private void OnClearSearch(object? sender, RoutedEventArgs e) { SearchBox.Text = ""; SearchBox.Focus(); }

    private void OnSearchChanged(object? sender, TextChangedEventArgs e) => Bind();

    private void OnToggleProjects(object? sender, RoutedEventArgs e) { _projectsExpanded = !_projectsExpanded; Bind(); }

    private void OnToggleRecent(object? sender, RoutedEventArgs e) { _recentExpanded = !_recentExpanded; Bind(); }

    private void OnUserMenu(object? sender, RoutedEventArgs e) => OnSettings(sender, e);

    private void OnSettings(object? sender, RoutedEventArgs e)
    {
        if (Model is null) return;
        var window = new SettingsWindow { DataContext = Model };
        if (TopLevel.GetTopLevel(this) is Window owner) window.Show(owner);
        else window.Show();
    }

    private void OnScheduled(object? sender, RoutedEventArgs e) => OpenSettings("tasks");

    private void OnPlugins(object? sender, RoutedEventArgs e) => OpenSettings("plugins");

    private void OnSites(object? sender, RoutedEventArgs e)
    {
        if (TopLevel.GetTopLevel(this) is MainWindow window)
            window.ShowBrowserPanel("https://dash.cloudflare.com/?to=/:account/pages");
    }

    private void OpenSettings(string tab)
    {
        if (Model is null) return;
        var window = new SettingsWindow { DataContext = Model };
        window.Opened += (_, _) => window.SelectTab(tab);
        if (TopLevel.GetTopLevel(this) is Window owner) window.Show(owner);
        else window.Show();
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

public sealed class ProjectTitleConverter : IValueConverter
{
    public static readonly ProjectTitleConverter Instance = new();

    public object? Convert(object? value, Type targetType, object? parameter, System.Globalization.CultureInfo culture)
    {
        if (value is not string path || string.IsNullOrWhiteSpace(path)) return "Project";
        try
        {
            var title = new DirectoryInfo(path).Name;
            return string.IsNullOrWhiteSpace(title) ? path : title;
        }
        catch { return path; }
    }

    public object? ConvertBack(object? value, Type targetType, object? parameter, System.Globalization.CultureInfo culture) =>
        throw new NotSupportedException();
}

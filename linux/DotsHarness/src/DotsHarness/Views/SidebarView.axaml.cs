// Copyright (c) 2026 DOTS
// Plugin composition model derived from DeepSeek Harness.
// Copyright (c) 2026 DeepSeek. MIT. See NOTICE.

using System.ComponentModel;
using Avalonia.Controls;
using Avalonia.Interactivity;
using Avalonia.Threading;
using DotsHarnessCore;
using HarnessPluginKit;

namespace DotsHarness.Views;

public partial class SidebarView : UserControl
{
    public SidebarView()
    {
        InitializeComponent();
        Loaded += (_, _) => Bind();
    }

    private AppModel? Model => DataContext as AppModel;
    private INotifyPropertyChanged? _observedModel;

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
        {
            Dispatcher.UIThread.Post(RefreshLocalization);
        }
        if (e.PropertyName is nameof(AppModel.Conversations) or nameof(AppModel.SelectedConversationId)
            or nameof(AppModel.StatusLine) or nameof(AppModel.Selected) or nameof(AppModel.ActiveArea)
            or nameof(AppModel.ChatProjects) or nameof(AppModel.CodingProjects)
            or nameof(AppModel.WorkspacePath) or nameof(AppModel.Bridge) or null)
        {
            Dispatcher.UIThread.Post(Bind);
        }
    }

    private void Bind()
    {
        if (Model is null) return;
        RefreshLocalization();
        FooterHost.Slot = WellKnownSlot.SidebarFooter;
        FooterHost.Registry = Model.Host.Slots;
        StatusText.Text = Model.StatusLine;
        ChatAreaButton.Opacity = Model.ActiveArea == AgentArea.Chat ? 1.0 : 0.65;
        CodingAreaButton.Opacity = Model.ActiveArea == AgentArea.Coding ? 1.0 : 0.65;
        CodingProjectsPanel.IsVisible = Model.ActiveArea == AgentArea.Coding;
        CodingProjectList.ItemsSource = Model.CodingProjects;
        CodingProjectList.SelectedItem = Model.CodingProjects.FirstOrDefault(path => SamePath(path, Model.WorkspacePath));
        ChatProjectsPanel.IsVisible = Model.ActiveArea == AgentArea.Chat;
        ChatProjectList.ItemsSource = Model.ChatProjects;
        var selectedProjectId = Model.Selected?.ChatProjectId;
        ChatProjectList.SelectedItem = Model.ChatProjects.FirstOrDefault(project => project.Id == selectedProjectId);
        var conversations = Model.ActiveArea == AgentArea.Chat
            ? Model.Bridge.Conversations.Where(item => item.ChatProjectId == selectedProjectId).ToList()
            : Model.Bridge.Conversations.Where(item => SamePath(item.Cwd, Model.WorkspacePath)).ToList();
        ChatList.ItemsSource = conversations;
        ChatList.SelectedItem = Model.Selected;
        NewButton.IsEnabled = Model.ActiveArea == AgentArea.Chat || !string.IsNullOrWhiteSpace(Model.WorkspacePath);
        ChatList.IsEnabled = Model.Bridge.Connection is not null || conversations.Count > 0;
    }

    public void RefreshLocalization()
    {
        if (Model is null) return;
        ChatsText.Text = Model.L("sidebar.chats");
        ToolTip.SetTip(NewButton, Model.L("sidebar.newChat"));
        ToolTip.SetTip(SettingsButton, Model.L("sidebar.settings"));
        StatusText.Text = Model.StatusLine;
        CodingProjectsText.Text = "Kodlama projeleri";
        ChatProjectsText.Text = "Sohbet projeleri";
        NoChatProjectButton.Content = "Genel sohbetler";
    }

    private void OnNew(object? sender, RoutedEventArgs e)
    {
        if (Model is null) return;
        if (Model.ActiveArea == AgentArea.Chat)
        {
            var project = ChatProjectList.SelectedItem as ChatProject;
            Model.NewChatConversation(project?.Id);
        }
        else if (!string.IsNullOrWhiteSpace(Model.WorkspacePath)) Model.NewConversation();
    }

    private void OnChatArea(object? sender, RoutedEventArgs e) => Model?.SetActiveArea(AgentArea.Chat);

    private void OnCodingArea(object? sender, RoutedEventArgs e) => Model?.SetActiveArea(AgentArea.Coding);

    private void OnNewChatProject(object? sender, RoutedEventArgs e)
    {
        if (Model is null) return;
        var input = new TextBox
        {
            Margin = new Avalonia.Thickness(0, 8, 0, 12),
            Padding = new Avalonia.Thickness(8, 6),
            MinWidth = 300,
        };
        var dialog = new Window
        {
            Title = "Yeni sohbet projesi",
            Width = 360,
            SizeToContent = SizeToContent.Height,
            WindowStartupLocation = WindowStartupLocation.CenterOwner,
            CanResize = false,
            Content = new StackPanel
            {
                Margin = new Avalonia.Thickness(16),
                Children =
                {
                    new TextBlock { Text = "Proje adı" },
                    input,
                },
            },
        };
        var buttons = new StackPanel
        {
            Orientation = Avalonia.Layout.Orientation.Horizontal,
            HorizontalAlignment = Avalonia.Layout.HorizontalAlignment.Right,
            Margin = new Avalonia.Thickness(0, 0, 16, 12),
        };
        var cancel = new Button { Content = "İptal", MinWidth = 78, Margin = new Avalonia.Thickness(0, 0, 8, 0) };
        var create = new Button { Content = "Oluştur", MinWidth = 78 };
        cancel.Click += (_, _) => dialog.Close();
        create.Click += (_, _) =>
        {
            var name = input.Text?.Trim() ?? "";
            if (name.Length == 0) return;
            var project = Model.CreateChatProject(name);
            Model.NewChatConversation(project.Id);
            dialog.Close();
        };
        buttons.Children.Add(cancel);
        buttons.Children.Add(create);
        ((StackPanel)dialog.Content!).Children.Add(buttons);
        if (TopLevel.GetTopLevel(this) is Window owner) dialog.Show(owner);
        else dialog.Show();
    }

    private void OnNewCodingProject(object? sender, RoutedEventArgs e)
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
            Title = "Yeni kodlama projesi",
            Width = 420,
            SizeToContent = SizeToContent.Height,
            WindowStartupLocation = WindowStartupLocation.CenterOwner,
            CanResize = false,
            Content = new StackPanel
            {
                Margin = new Avalonia.Thickness(16),
                Children =
                {
                    new TextBlock { Text = "Klasör yolu" },
                    input,
                },
            },
        };
        var buttons = new StackPanel
        {
            Orientation = Avalonia.Layout.Orientation.Horizontal,
            HorizontalAlignment = Avalonia.Layout.HorizontalAlignment.Right,
            Margin = new Avalonia.Thickness(0, 0, 16, 12),
        };
        var cancel = new Button { Content = "İptal", MinWidth = 78, Margin = new Avalonia.Thickness(0, 0, 8, 0) };
        var create = new Button { Content = "Aç", MinWidth = 78 };
        cancel.Click += (_, _) => dialog.Close();
        create.Click += (_, _) =>
        {
            var path = input.Text?.Trim() ?? "";
            if (path.Length == 0) return;
            Model.SetWorkspace(path);
            dialog.Close();
        };
        buttons.Children.Add(cancel);
        buttons.Children.Add(create);
        ((StackPanel)dialog.Content!).Children.Add(buttons);
        if (TopLevel.GetTopLevel(this) is Window owner) dialog.Show(owner);
        else dialog.Show();
    }

    private void OnNoChatProject(object? sender, RoutedEventArgs e)
    {
        if (Model is null) return;
        ChatProjectList.SelectedItem = null;
        Model.SetActiveArea(AgentArea.Chat);
        var conversation = Model.ChatBridge.Conversations.FirstOrDefault(item => item.ChatProjectId is null);
        if (conversation is not null) Model.SelectedConversationId = conversation.Id;
        else Model.NewChatConversation();
        Bind();
    }

    private void OnChatProjectSelected(object? sender, SelectionChangedEventArgs e)
    {
        if (ChatProjectList.SelectedItem is ChatProject project)
        {
            if (Model is null) return;
            Model.SetActiveArea(AgentArea.Chat);
            var conversation = Model.ChatBridge.Conversations
                .FirstOrDefault(item => item.ChatProjectId == project.Id);
            if (conversation is not null) Model.SelectedConversationId = conversation.Id;
            else Model.NewChatConversation(project.Id);
            Bind();
        }
    }

    private void OnCodingProjectSelected(object? sender, SelectionChangedEventArgs e)
    {
        if (Model is null || CodingProjectList.SelectedItem is not string path) return;
        if (!SamePath(Model.WorkspacePath, path)) Model.SetWorkspace(path);
    }

    private void OnSettings(object? sender, RoutedEventArgs e)
    {
        if (Model is null) return;
        var window = new SettingsWindow { DataContext = Model };
        if (TopLevel.GetTopLevel(this) is Window owner) window.Show(owner);
        else window.Show();
    }

    private void OnSelect(object? sender, SelectionChangedEventArgs e)
    {
        if (ChatList.SelectedItem is Conversation conversation && Model is not null)
        {
            Model.SelectedConversationId = conversation.Id;
        }
    }

    private static bool SamePath(string? left, string? right)
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

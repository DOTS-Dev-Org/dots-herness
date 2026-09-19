// Copyright (c) 2026 DOTS
// Plugin composition model derived from DeepSeek Harness.
// Copyright (c) 2026 DeepSeek. MIT. See NOTICE.

using System.ComponentModel;
using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using DotsHarness;
using DotsHarnessCore;
using HarnessPluginKit;

namespace DotsHarness.Views;

public partial class SidebarView : UserControl
{
    public SidebarView()
    {
        InitializeComponent();
        DataContextChanged += OnCtx;
        Loaded += (_, _) => Bind();
    }

    private AppModel? Model => DataContext as AppModel;

    private void OnCtx(object sender, DependencyPropertyChangedEventArgs e)
    {
        if (e.OldValue is INotifyPropertyChanged oldM) oldM.PropertyChanged -= OnModel;
        if (e.NewValue is INotifyPropertyChanged next) next.PropertyChanged += OnModel;
        Bind();
    }

    private void OnModel(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName is nameof(AppModel.Language) or nameof(AppModel.IsRightToLeft))
        {
            Dispatcher.Invoke(RefreshLocalization);
        }
        if (e.PropertyName is nameof(AppModel.Conversations) or nameof(AppModel.SelectedConversationId)
            or nameof(AppModel.StatusLine) or nameof(AppModel.Selected) or nameof(AppModel.ActiveArea)
            or nameof(AppModel.ChatProjects) or nameof(AppModel.CodingProjects)
            or nameof(AppModel.WorkspacePath) or nameof(AppModel.Bridge) or null)
        {
            Dispatcher.Invoke(Bind);
        }
    }

    private void Bind()
    {
        if (Model is null) return;
        RefreshLocalization();
        FooterHost.Slot = WellKnownSlot.SidebarFooter;
        FooterHost.Registry = Model.Host.Slots;
        StatusText.Text = Model.StatusLine;
        ChatAreaButton.FontWeight = Model.ActiveArea == AgentArea.Chat ? FontWeights.SemiBold : FontWeights.Normal;
        CodingAreaButton.FontWeight = Model.ActiveArea == AgentArea.Coding ? FontWeights.SemiBold : FontWeights.Normal;
        CodingProjectsPanel.Visibility = Model.ActiveArea == AgentArea.Coding ? Visibility.Visible : Visibility.Collapsed;
        CodingProjectList.ItemsSource = Model.CodingProjects;
        CodingProjectList.SelectedItem = Model.CodingProjects.FirstOrDefault(path => SamePath(path, Model.WorkspacePath));
        ChatProjectsPanel.Visibility = Model.ActiveArea == AgentArea.Chat ? Visibility.Visible : Visibility.Collapsed;
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
        NewButton.ToolTip = Model.L("sidebar.newChat");
        UserButton.ToolTip = Model.L("sidebar.userMenu");
        UserMenuText.Text = Model.L("sidebar.userMenu");
        SettingsMenu.Header = Model.L("sidebar.settings");
        StatusText.Text = Model.StatusLine;
        CodingProjectsText.Text = "Kodlama projeleri";
        ChatProjectsText.Text = "Sohbet projeleri";
        NoChatProjectButton.Content = "Genel sohbetler";
    }

    private void OnNew(object sender, RoutedEventArgs e)
    {
        if (Model is null) return;
        if (Model.ActiveArea == AgentArea.Chat)
        {
            var project = ChatProjectList.SelectedItem as ChatProject;
            Model.NewChatConversation(project?.Id);
        }
        else if (!string.IsNullOrWhiteSpace(Model.WorkspacePath)) Model.NewConversation();
    }

    private void OnChatArea(object sender, RoutedEventArgs e) => Model?.SetActiveArea(AgentArea.Chat);

    private void OnCodingArea(object sender, RoutedEventArgs e) => Model?.SetActiveArea(AgentArea.Coding);

    private void OnNewChatProject(object sender, RoutedEventArgs e)
    {
        if (Model is null) return;
        var owner = Window.GetWindow(this);
        var input = new TextBox
        {
            Margin = new Thickness(0, 8, 0, 12),
            Padding = new Thickness(8, 6, 8, 6),
            MinWidth = 300,
        };
        var dialog = new Window
        {
            Title = "Yeni sohbet projesi",
            Width = 360,
            SizeToContent = SizeToContent.Height,
            WindowStartupLocation = owner is null ? WindowStartupLocation.CenterScreen : WindowStartupLocation.CenterOwner,
            ResizeMode = ResizeMode.NoResize,
            ShowInTaskbar = false,
            Owner = owner,
            Content = new StackPanel
            {
                Margin = new Thickness(16),
                Children =
                {
                    new TextBlock { Text = "Proje adı" },
                    input,
                },
            },
        };
        var buttons = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            HorizontalAlignment = HorizontalAlignment.Right,
            Margin = new Thickness(0, 0, 16, 12),
        };
        var cancel = new Button { Content = "İptal", MinWidth = 78, Margin = new Thickness(0, 0, 8, 0) };
        var create = new Button { Content = "Oluştur", MinWidth = 78, IsDefault = true };
        cancel.Click += (_, _) => dialog.Close();
        create.Click += (_, _) =>
        {
            var name = input.Text.Trim();
            if (name.Length == 0) return;
            var project = Model.CreateChatProject(name);
            Model.NewChatConversation(project.Id);
            dialog.Close();
        };
        buttons.Children.Add(cancel);
        buttons.Children.Add(create);
        ((StackPanel)dialog.Content).Children.Add(buttons);
        dialog.ShowDialog();
    }

    private void OnNewCodingProject(object sender, RoutedEventArgs e)
    {
        if (Model is null) return;
        var owner = Window.GetWindow(this);
        var input = new TextBox
        {
            Margin = new Thickness(0, 8, 0, 12),
            Padding = new Thickness(8, 6, 8, 6),
            MinWidth = 300,
        };
        var dialog = new Window
        {
            Title = "Yeni kodlama projesi",
            Width = 420,
            SizeToContent = SizeToContent.Height,
            WindowStartupLocation = owner is null ? WindowStartupLocation.CenterScreen : WindowStartupLocation.CenterOwner,
            ResizeMode = ResizeMode.NoResize,
            ShowInTaskbar = false,
            Owner = owner,
            Content = new StackPanel
            {
                Margin = new Thickness(16),
                Children =
                {
                    new TextBlock { Text = "Klasör yolu" },
                    input,
                },
            },
        };
        var buttons = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            HorizontalAlignment = HorizontalAlignment.Right,
            Margin = new Thickness(0, 0, 16, 12),
        };
        var cancel = new Button { Content = "İptal", MinWidth = 78, Margin = new Thickness(0, 0, 8, 0) };
        var create = new Button { Content = "Aç", MinWidth = 78, IsDefault = true };
        cancel.Click += (_, _) => dialog.Close();
        create.Click += (_, _) =>
        {
            var path = input.Text.Trim();
            if (path.Length == 0) return;
            Model.SetWorkspace(path);
            dialog.Close();
        };
        buttons.Children.Add(cancel);
        buttons.Children.Add(create);
        ((StackPanel)dialog.Content).Children.Add(buttons);
        dialog.ShowDialog();
    }

    private void OnNoChatProject(object sender, RoutedEventArgs e)
    {
        if (Model is null) return;
        ChatProjectList.SelectedItem = null;
        Model.SetActiveArea(AgentArea.Chat);
        var conversation = Model.ChatBridge.Conversations.FirstOrDefault(item => item.ChatProjectId is null);
        if (conversation is not null) Model.SelectedConversationId = conversation.Id;
        else Model.NewChatConversation();
        Bind();
    }

    private void OnChatProjectSelected(object sender, SelectionChangedEventArgs e)
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

    private void OnCodingProjectSelected(object sender, SelectionChangedEventArgs e)
    {
        if (Model is null || CodingProjectList.SelectedItem is not string path) return;
        if (!SamePath(Model.WorkspacePath, path)) Model.SetWorkspace(path);
    }

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
        if (Window.GetWindow(this) is MainWindow window)
        {
            window.ShowSettings();
        }
    }

    private void OnSelect(object sender, SelectionChangedEventArgs e)
    {
        if (ChatList.SelectedItem is Conversation conversation)
        {
            Model!.SelectedConversationId = conversation.Id;
        }
    }

    private static bool SamePath(string? left, string? right)
    {
        if (string.IsNullOrWhiteSpace(left) || string.IsNullOrWhiteSpace(right)) return false;
        try
        {
            return string.Equals(
                System.IO.Path.GetFullPath(left).TrimEnd(System.IO.Path.DirectorySeparatorChar, System.IO.Path.AltDirectorySeparatorChar),
                System.IO.Path.GetFullPath(right).TrimEnd(System.IO.Path.DirectorySeparatorChar, System.IO.Path.AltDirectorySeparatorChar),
                OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal);
        }
        catch { return false; }
    }
}

public sealed class BoolToVis : IValueConverter
{
    public static readonly BoolToVis Instance = new();
    public object Convert(object value, Type targetType, object parameter, CultureInfo culture) =>
        value is true ? Visibility.Visible : Visibility.Collapsed;
    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) =>
        value is Visibility.Visible;
}

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
            or nameof(AppModel.StatusLine) or nameof(AppModel.Selected) or null)
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
        ChatList.ItemsSource = Model.Bridge.Conversations;
        ChatList.SelectedItem = Model.Selected;
        ChatList.IsEnabled = Model.Bridge.Connection is not null || Model.Bridge.Conversations.Count > 0;
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
    }

    private void OnNew(object sender, RoutedEventArgs e) => Model?.NewConversation();

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
}

public sealed class BoolToVis : IValueConverter
{
    public static readonly BoolToVis Instance = new();
    public object Convert(object value, Type targetType, object parameter, CultureInfo culture) =>
        value is true ? Visibility.Visible : Visibility.Collapsed;
    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) =>
        value is Visibility.Visible;
}

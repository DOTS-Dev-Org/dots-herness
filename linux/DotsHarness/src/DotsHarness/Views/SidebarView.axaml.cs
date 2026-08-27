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
        DataContextChanged += (_, _) => Bind();
        Loaded += (_, _) => Bind();
    }

    private AppModel? Model => DataContext as AppModel;

    protected override void OnDataContextChanged(EventArgs e)
    {
        base.OnDataContextChanged(e);
        if (DataContext is INotifyPropertyChanged next) next.PropertyChanged += OnModel;
        Bind();
    }

    private void OnModel(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName is nameof(AppModel.Conversations) or nameof(AppModel.SelectedConversationId)
            or nameof(AppModel.StatusLine) or nameof(AppModel.Selected) or null)
        {
            Dispatcher.UIThread.Post(Bind);
        }
    }

    private void Bind()
    {
        if (Model is null) return;
        FooterHost.Slot = WellKnownSlot.SidebarFooter;
        FooterHost.Registry = Model.Host.Slots;
        StatusText.Text = Model.StatusLine;
        ChatList.ItemsSource = Model.Bridge.Conversations;
        ChatList.SelectedItem = Model.Selected;
        ChatList.IsEnabled = Model.Bridge.Connection is not null || Model.Bridge.Conversations.Count > 0;
    }

    private void OnNew(object? sender, RoutedEventArgs e) => Model?.NewConversation();

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
}

// Copyright (c) 2026 DOTS
// Plugin composition model derived from DeepSeek Harness.
// Copyright (c) 2026 DeepSeek. MIT. See NOTICE.

using System.Windows;
using System.ComponentModel;
using System.Windows.Controls;
using System.Windows.Input;
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
        Sidebar.DataContext = model;
        Conversation.DataContext = model;
        Settings.DataContext = model;
        model.PropertyChanged += OnModel;
        Settings.BackRequested += (_, _) => ShowConversation();
        OverlayHost.Slot = WellKnownSlot.Overlay;
        OverlayHost.Registry = model.Host.Slots;
        CommandBindings.Add(new CommandBinding(ApplicationCommands.New, (_, _) => model.NewConversation()));
        InputBindings.Add(new KeyBinding(new RelayCommand(_ => ShowSettings()), Key.OemComma, ModifierKeys.Control));
        Closing += OnClosing;
        RefreshLocalization();
    }

    private void OnModel(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName is nameof(AppModel.Language) or nameof(AppModel.IsRightToLeft))
            Dispatcher.Invoke(RefreshLocalization);
    }

    private void RefreshLocalization()
    {
        var model = ((App)Application.Current).Model;
        Title = model.L("app.title");
        FlowDirection = model.IsRightToLeft ? System.Windows.FlowDirection.RightToLeft : System.Windows.FlowDirection.LeftToRight;
        Sidebar.RefreshLocalization();
        Settings.RefreshLocalization();
    }

    public void ShowSettings()
    {
        Conversation.Visibility = Visibility.Collapsed;
        Settings.Visibility = Visibility.Visible;
    }

    private void ShowConversation()
    {
        Settings.Visibility = Visibility.Collapsed;
        Conversation.Visibility = Visibility.Visible;
    }

    private bool _allowClose;

    private void OnClosing(object? sender, CancelEventArgs e)
    {
        var model = ((App)Application.Current).Model;
        if (_allowClose || !model.ConfirmBeforeExit)
        {
            Conversation.StopVoiceInput();
            Conversation.StopTerminal();
            return;
        }

        var dialog = new CloseConfirmationDialog(model) { Owner = this, Icon = this.Icon };
        if (dialog.ShowDialog() != true)
        {
            e.Cancel = true;
            return;
        }

        if (dialog.Remember) model.SetConfirmBeforeExit(false);
        _allowClose = true;
        Conversation.StopVoiceInput();
        Conversation.StopTerminal();
    }
}

internal sealed class CloseConfirmationDialog : Window
{
    private readonly CheckBox _remember;

    public bool Remember => _remember.IsChecked == true;

    public CloseConfirmationDialog(AppModel model)
    {
        Title = model.L("window.confirmClose");
        FlowDirection = model.IsRightToLeft ? System.Windows.FlowDirection.RightToLeft : System.Windows.FlowDirection.LeftToRight;
        Width = 380;
        SizeToContent = SizeToContent.Height;
        ResizeMode = ResizeMode.NoResize;
        ShowInTaskbar = false;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;

        _remember = new CheckBox
        {
            Content = model.L("window.remember"),
            Margin = new Thickness(0, 14, 0, 18),
        };
        var close = new Button
        {
            Content = model.L("window.close"),
            IsDefault = true,
            Padding = new Thickness(14, 6, 14, 6),
            Margin = new Thickness(0, 0, 8, 0),
        };
        close.Click += (_, _) => DialogResult = true;
        var cancel = new Button
        {
            Content = model.L("window.cancel"),
            IsCancel = true,
            Padding = new Thickness(14, 6, 14, 6),
        };

        Content = new StackPanel
        {
            Margin = new Thickness(24),
            Children =
            {
                new TextBlock
                {
                    Text = model.L("window.closeQuestion"),
                    TextWrapping = TextWrapping.Wrap,
                },
                _remember,
                new StackPanel
                {
                    Orientation = Orientation.Horizontal,
                    HorizontalAlignment = HorizontalAlignment.Right,
                    Children = { close, cancel },
                },
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

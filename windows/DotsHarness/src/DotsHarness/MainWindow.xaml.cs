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
        Loaded += OnLoaded;
        RefreshLocalization();
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

        var dialog = new CloseConfirmationDialog(model, Icon) { Owner = this };
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

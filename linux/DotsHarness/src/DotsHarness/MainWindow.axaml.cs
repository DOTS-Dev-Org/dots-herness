// Copyright (c) 2026 DOTS
// Plugin composition model derived from DeepSeek Harness.
// Copyright (c) 2026 DeepSeek. MIT. See NOTICE.

using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using DotsHarness.Views;
using HarnessPluginKit;

namespace DotsHarness;

public partial class MainWindow : Window
{
    public MainWindow()
    {
        InitializeComponent();
        var model = ((App)Application.Current!).Model;
        DataContext = model;
        Sidebar.DataContext = model;
        Conversation.DataContext = model;
        OverlayHost.Slot = WellKnownSlot.Overlay;
        OverlayHost.Registry = model.Host.Slots;
        KeyBindings.Add(new KeyBinding
        {
            Gesture = new KeyGesture(Key.OemComma, KeyModifiers.Control),
            Command = new RelayCommand(_ => new SettingsWindow { DataContext = model }.Show(this)),
        });
        Title = "Dots Harness";
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

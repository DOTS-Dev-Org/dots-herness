// Copyright (c) 2026 DOTS
// Plugin composition model derived from DeepSeek Harness.
// Copyright (c) 2026 DeepSeek. MIT. See NOTICE.

using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
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
        var model = ((App)Application.Current!).Model;
        DataContext = model;
        Sidebar.DataContext = model;
        Conversation.DataContext = model;
        model.PropertyChanged += OnModel;
        OverlayHost.Slot = WellKnownSlot.Overlay;
        OverlayHost.Registry = model.Host.Slots;
        KeyBindings.Add(new KeyBinding
        {
            Gesture = new KeyGesture(Key.OemComma, KeyModifiers.Control),
            Command = new RelayCommand(_ => new SettingsWindow { DataContext = model }.Show(this)),
        });
        model.Shortcuts.Changed += (_, _) => Dispatcher.UIThread.Post(ApplyShortcuts);
        ApplyShortcuts();
        RefreshLocalization();
    }

    private readonly List<KeyBinding> _shortcutBindings = new();
    private bool _sidebarHidden;

    /// <summary>Rebuilds the window's key bindings from the user's shortcut settings.</summary>
    private void ApplyShortcuts()
    {
        var model = ((App)Application.Current!).Model;
        foreach (var binding in _shortcutBindings) KeyBindings.Remove(binding);
        _shortcutBindings.Clear();
        foreach (var action in KeyboardShortcutActions.All)
        {
            var shortcut = model.Shortcuts.ShortcutFor(action);
            if (ShortcutKeyMap.ToKey(shortcut.Key) is not { } key) continue;
            var modifiers = (shortcut.NeedsCtrl ? KeyModifiers.Control : 0)
                | (shortcut.NeedsAlt ? KeyModifiers.Alt : 0)
                | (shortcut.NeedsShift ? KeyModifiers.Shift : 0);
            var binding = new KeyBinding { Gesture = new KeyGesture(key, modifiers), Command = new RelayCommand(_ => Run(action, model)) };
            _shortcutBindings.Add(binding);
            KeyBindings.Add(binding);
        }
    }

    private void Run(KeyboardShortcutAction action, AppModel model)
    {
        switch (action)
        {
            case KeyboardShortcutAction.ToggleSidebar:
                _sidebarHidden = !_sidebarHidden;
                Root.ColumnDefinitions[0].MinWidth = _sidebarHidden ? 0 : 200;
                Root.ColumnDefinitions[0].Width = new GridLength(_sidebarHidden ? 0 : 240);
                Sidebar.IsVisible = !_sidebarHidden;
                break;
            case KeyboardShortcutAction.Terminal:
                Conversation.ToggleTerminal();
                break;
            case KeyboardShortcutAction.Scheduled:
                var settings = new SettingsWindow { DataContext = model };
                settings.Show(this);
                settings.ShowTab("tasks");
                break;
        }
    }

    private void OnModel(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName is not (nameof(AppModel.Language) or nameof(AppModel.IsRightToLeft))) return;
        Dispatcher.UIThread.Post(RefreshLocalization);
    }

    private void RefreshLocalization()
    {
        var model = ((App)Application.Current!).Model;
        Title = model.L("app.title");
        FlowDirection = model.IsRightToLeft ? Avalonia.Media.FlowDirection.RightToLeft : Avalonia.Media.FlowDirection.LeftToRight;
        Sidebar.RefreshLocalization();
    }

    public void StopTerminal() => Conversation.StopTerminal();
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

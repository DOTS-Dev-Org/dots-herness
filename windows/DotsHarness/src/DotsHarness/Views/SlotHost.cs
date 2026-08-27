// Copyright (c) 2026 DOTS
// Plugin composition model derived from DeepSeek Harness.
// Copyright (c) 2026 DeepSeek. MIT. See NOTICE.

using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using PluginRuntime;

namespace DotsHarness.Views;

public sealed class SlotHost : Grid
{
    public static readonly DependencyProperty SlotProperty =
        DependencyProperty.Register(nameof(Slot), typeof(string), typeof(SlotHost),
            new PropertyMetadata(null, OnChanged));

    public static readonly DependencyProperty RegistryProperty =
        DependencyProperty.Register(nameof(Registry), typeof(InMemorySlotRegistry), typeof(SlotHost),
            new PropertyMetadata(null, OnRegistryChanged));

    public string? Slot
    {
        get => (string?)GetValue(SlotProperty);
        set => SetValue(SlotProperty, value);
    }

    public InMemorySlotRegistry? Registry
    {
        get => (InMemorySlotRegistry?)GetValue(RegistryProperty);
        set => SetValue(RegistryProperty, value);
    }

    private static void OnChanged(DependencyObject d, DependencyPropertyChangedEventArgs e) =>
        ((SlotHost)d).Rebuild();

    private static void OnRegistryChanged(DependencyObject d, DependencyPropertyChangedEventArgs e)
    {
        var host = (SlotHost)d;
        if (e.OldValue is INotifyPropertyChanged oldReg) oldReg.PropertyChanged -= host.OnRegistryChanged;
        if (e.NewValue is INotifyPropertyChanged next) next.PropertyChanged += host.OnRegistryChanged;
        host.Rebuild();
    }

    private void OnRegistryChanged(object? sender, PropertyChangedEventArgs e) =>
        Dispatcher.Invoke(Rebuild);

    private void Rebuild()
    {
        Children.Clear();
        if (Registry is null || string.IsNullOrEmpty(Slot)) return;
        foreach (var occupant in Registry.Occupants(Slot))
        {
            try
            {
                var view = occupant.ViewFactory();
                if (view is UIElement element) Children.Add(element);
            }
            catch
            {
                // a broken slot view must not take down the shell
            }
        }
    }
}

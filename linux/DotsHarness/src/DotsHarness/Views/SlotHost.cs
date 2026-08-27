// Copyright (c) 2026 DOTS
// Plugin composition model derived from DeepSeek Harness.
// Copyright (c) 2026 DeepSeek. MIT. See NOTICE.

using System.ComponentModel;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Threading;
using PluginRuntime;

namespace DotsHarness.Views;

public sealed class SlotHost : Grid
{
    public static readonly StyledProperty<string?> SlotProperty =
        AvaloniaProperty.Register<SlotHost, string?>(nameof(Slot));

    public static readonly StyledProperty<InMemorySlotRegistry?> RegistryProperty =
        AvaloniaProperty.Register<SlotHost, InMemorySlotRegistry?>(nameof(Registry));

    public string? Slot
    {
        get => GetValue(SlotProperty);
        set => SetValue(SlotProperty, value);
    }

    public InMemorySlotRegistry? Registry
    {
        get => GetValue(RegistryProperty);
        set => SetValue(RegistryProperty, value);
    }

    static SlotHost()
    {
        SlotProperty.Changed.AddClassHandler<SlotHost>((host, _) => host.Rebuild());
        RegistryProperty.Changed.AddClassHandler<SlotHost>((host, e) =>
        {
            if (e.OldValue is INotifyPropertyChanged oldReg) oldReg.PropertyChanged -= host.OnRegistryChanged;
            if (e.NewValue is INotifyPropertyChanged next) next.PropertyChanged += host.OnRegistryChanged;
            host.Rebuild();
        });
    }

    private void OnRegistryChanged(object? sender, PropertyChangedEventArgs e) =>
        Dispatcher.UIThread.Post(Rebuild);

    private void Rebuild()
    {
        Children.Clear();
        if (Registry is null || string.IsNullOrEmpty(Slot)) return;
        foreach (var occupant in Registry.Occupants(Slot))
        {
            try
            {
                var view = occupant.ViewFactory();
                if (view is Control element) Children.Add(element);
            }
            catch
            {
                // a broken slot view must not take down the shell
            }
        }
    }
}

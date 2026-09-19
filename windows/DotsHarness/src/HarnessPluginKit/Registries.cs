// Copyright (c) 2026 DOTS
// Plugin composition model derived from DeepSeek Harness.
// Copyright (c) 2026 DeepSeek. MIT. See NOTICE.

namespace HarnessPluginKit;

public sealed record PromptSection(string Name, int Order, string Text, string Owner)
{
    public string Id => Name;
}

public interface IPromptRegistry
{
    Action Section(string name, int order, string text);
    string AssembledText();
    IReadOnlyList<PromptSection> Sections();
}

public sealed record ToolParameter(string Name, string Type, string Description, bool Required = true);

public sealed record RegisteredTool(string Name, string Description, IReadOnlyList<ToolParameter> Parameters, string Owner)
{
    public string Id => Name;
}

public interface IToolRegistry
{
    Action Register(
        string name,
        string description,
        IReadOnlyList<ToolParameter> parameters,
        Func<IReadOnlyDictionary<string, string>, Task<string>> execute);
    IReadOnlyList<RegisteredTool> Tools();
    Task<string> CallAsync(string name, IReadOnlyDictionary<string, string> arguments);
}

/// <summary>
/// A named seat. The WPF/Avalonia shell erases the view as <see cref="object"/>
/// (a <c>FrameworkElement</c> or <c>Avalonia.Controls.Control</c> factory).
/// </summary>
public sealed record SlotRegistration(
    string Id,
    string Slot,
    int Order,
    string Label,
    string Owner,
    Func<object> ViewFactory);

public static class WellKnownSlot
{
    public const string Overlay = "shell.overlay";
    public const string SidebarFooter = "shell.sidebar.footer";
    public const string ComposerAccessory = "conversation.composer.accessory";
    public const string SettingsSections = "settings.sections";
    public const string PluginsDetail = "plugins.detail";
}

public interface ISlotRegistry
{
    Action Inject(string slot, string id, int order, string label, Func<object> viewFactory);
    IReadOnlyList<SlotRegistration> Occupants(string slot);
}

public interface ISettingsRegistry
{
    JsonValue? Get(string key);
    void Set(string key, JsonValue value);
    void Remove(string key);
}

public interface IEventBus
{
    Action On(string name, Action<object?> handler);
    void Emit(string name, object? payload);
}

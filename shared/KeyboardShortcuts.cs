// Copyright (c) 2026 DOTS
// User-editable keyboard shortcuts for the Windows and Linux shells. Port of the macOS
// KeyboardShortcuts.swift: same stored form (`key|modifierMask`), same conflict rule.
//
// macOS "Command" maps to Ctrl here, so the stored masks stay portable between platforms.
// Only actions that have a surface in these shells are offered; the macOS-only panels
// (pull requests, review, browser, files, side chat, simulator) are not.

namespace DotsHarnessCore;

/// <summary>Actions exposed in Settings › General › Keyboard shortcuts.</summary>
public enum KeyboardShortcutAction
{
    ToggleSidebar,
    Scheduled,
    Terminal,
}

public static class KeyboardShortcutActions
{
    public static IReadOnlyList<KeyboardShortcutAction> All { get; } = Enum.GetValues<KeyboardShortcutAction>();

    /// <summary>Same key names as macOS (<c>ui.keyboardShortcut.toggleSidebar</c>) so a settings file reads alike.</summary>
    public static string SettingsKey(this KeyboardShortcutAction action) =>
        "ui.keyboardShortcut." + char.ToLowerInvariant(action.ToString()[0]) + action.ToString()[1..];

    public static string TitleKey(this KeyboardShortcutAction action) => action switch
    {
        KeyboardShortcutAction.ToggleSidebar => "settings.shortcuts.sidebar",
        KeyboardShortcutAction.Scheduled => "sidebar.scheduled",
        _ => "conversation.terminal",
    };

    public static UserKeyboardShortcut Default(this KeyboardShortcutAction action) => action switch
    {
        KeyboardShortcutAction.ToggleSidebar => new('b', UserKeyboardShortcut.Command),
        KeyboardShortcutAction.Scheduled => new('t', UserKeyboardShortcut.Command | UserKeyboardShortcut.Shift),
        _ => new('`', UserKeyboardShortcut.Command),
    };
}

/// <summary>
/// A serializable shortcut. The stored form is deliberately small (<c>key|modifierMask</c>) so it
/// stays compatible with the settings JSON and bad data is simply ignored by a later version.
/// </summary>
public readonly record struct UserKeyboardShortcut
{
    public const byte Command = 1 << 0;
    public const byte Option = 1 << 1;
    public const byte Shift = 1 << 2;
    public const byte Control = 1 << 3;
    public const byte AllModifiers = Command | Option | Shift | Control;

    public char Key { get; }
    public byte ModifierMask { get; }

    public UserKeyboardShortcut(char key, byte modifierMask)
    {
        if (!IsValid(key, modifierMask)) throw new ArgumentException("Not a usable shortcut.");
        Key = char.ToLowerInvariant(key);
        ModifierMask = modifierMask;
    }

    public static bool IsValid(char key, byte modifierMask) =>
        !char.IsControl(key) || key is '\r' or '\n' or '\t' or '\u007f'
            ? modifierMask != 0 && (modifierMask & AllModifiers) == modifierMask
            : false;

    public static UserKeyboardShortcut? TryCreate(char key, byte modifierMask) =>
        IsValid(key, modifierMask) ? new UserKeyboardShortcut(key, modifierMask) : null;

    public static UserKeyboardShortcut? Parse(string? stored)
    {
        if (string.IsNullOrEmpty(stored)) return null;
        // The key itself may be "|", so split on the last separator.
        var separator = stored.LastIndexOf('|');
        if (separator != 1 || !byte.TryParse(stored[2..], out var mask)) return null;
        return TryCreate(stored[0], mask);
    }

    public string StoredValue => $"{Key}|{ModifierMask}";

    /// <summary>Menu-style text such as <c>Ctrl+Shift+T</c>.</summary>
    public string DisplayValue
    {
        get
        {
            var parts = new List<string>();
            if ((ModifierMask & Command) != 0 || (ModifierMask & Control) != 0) parts.Add("Ctrl");
            if ((ModifierMask & Option) != 0) parts.Add("Alt");
            if ((ModifierMask & Shift) != 0) parts.Add("Shift");
            parts.Add(Key switch
            {
                ' ' => "Space",
                '\r' or '\n' => "Enter",
                '\t' => "Tab",
                '\u007f' => "Backspace",
                _ => char.ToUpperInvariant(Key).ToString(),
            });
            return string.Join("+", parts);
        }
    }

    /// <summary>
    /// Ctrl-equivalent: on these platforms macOS's Command and Control both mean the Ctrl key, so a
    /// stored mask carrying either matches a real Ctrl press.
    /// </summary>
    public bool NeedsCtrl => (ModifierMask & (Command | Control)) != 0;
    public bool NeedsAlt => (ModifierMask & Option) != 0;
    public bool NeedsShift => (ModifierMask & Shift) != 0;

    /// <summary>The stored mask for a live key press; Ctrl is recorded as Command.</summary>
    public static byte MaskFor(bool ctrl, bool alt, bool shift) =>
        (byte)((ctrl ? Command : 0) | (alt ? Option : 0) | (shift ? Shift : 0));

    /// <summary>Two shortcuts collide when they press the same physical keys.</summary>
    public bool Collides(UserKeyboardShortcut other) =>
        Key == other.Key && NeedsCtrl == other.NeedsCtrl && NeedsAlt == other.NeedsAlt && NeedsShift == other.NeedsShift;
}

public abstract record KeyboardShortcutUpdateResult
{
    public sealed record Saved : KeyboardShortcutUpdateResult;
    public sealed record Conflict(KeyboardShortcutAction With) : KeyboardShortcutUpdateResult;
}

/// <summary>
/// Reads and writes the shortcut for each action through a key/value store (the app settings),
/// refusing a shortcut another action already uses.
/// </summary>
public sealed class KeyboardShortcutSettings
{
    private readonly Func<string, string?> _read;
    private readonly Action<string, string> _write;

    public KeyboardShortcutSettings(Func<string, string?> read, Action<string, string> write)
    {
        _read = read;
        _write = write;
    }

    public event EventHandler? Changed;

    public UserKeyboardShortcut ShortcutFor(KeyboardShortcutAction action) =>
        UserKeyboardShortcut.Parse(_read(action.SettingsKey())) ?? action.Default();

    public IReadOnlyDictionary<KeyboardShortcutAction, UserKeyboardShortcut> All() =>
        KeyboardShortcutActions.All.ToDictionary(action => action, ShortcutFor);

    public KeyboardShortcutUpdateResult Update(KeyboardShortcutAction action, UserKeyboardShortcut shortcut)
    {
        foreach (var other in KeyboardShortcutActions.All.Where(a => a != action))
            if (ShortcutFor(other).Collides(shortcut)) return new KeyboardShortcutUpdateResult.Conflict(other);
        _write(action.SettingsKey(), shortcut.StoredValue);
        Changed?.Invoke(this, EventArgs.Empty);
        return new KeyboardShortcutUpdateResult.Saved();
    }

    /// <summary>Restores the default; refused when another action has taken that combination.</summary>
    public KeyboardShortcutUpdateResult Reset(KeyboardShortcutAction action) => Update(action, action.Default());
}

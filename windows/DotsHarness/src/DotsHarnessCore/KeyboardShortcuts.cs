// Copyright (c) 2026 DOTS
// Editable desktop shortcuts shared by the Windows and Linux shells.

namespace DotsHarnessCore;

public enum KeyboardShortcutAction
{
    ToggleSidebar,
    PullRequests,
    Scheduled,
    Review,
    Terminal,
    Browser,
    Files,
    NewConversation,
}

/// <summary>
/// A portable key chord. Key names use the common WPF/Avalonia key identifiers
/// so the same persisted shortcut can be interpreted by either desktop shell.
/// </summary>
public readonly record struct UserKeyboardShortcut
{
    public const byte Control = 1 << 0;
    public const byte Alt = 1 << 1;
    public const byte Shift = 1 << 2;
    public const byte Super = 1 << 3;
    public const byte AllModifiers = Control | Alt | Shift | Super;

    public string Key { get; }
    public byte ModifierMask { get; }
    public string StoredValue => $"{Key}|{ModifierMask}";

    public UserKeyboardShortcut(string key, byte modifierMask)
    {
        if (!TryNormalizeKey(key, out var normalized)
            || modifierMask == 0
            || (modifierMask & AllModifiers) != modifierMask)
        {
            throw new ArgumentException("A shortcut needs a supported key and at least one modifier.");
        }

        Key = normalized;
        ModifierMask = modifierMask;
    }

    public static bool TryParse(string? value, out UserKeyboardShortcut shortcut)
    {
        shortcut = default;
        if (string.IsNullOrWhiteSpace(value)) return false;
        var parts = value.Split('|');
        if (parts.Length != 2
            || !byte.TryParse(parts[1], out var mask)
            || !TryNormalizeKey(parts[0], out var key)
            || mask == 0
            || (mask & AllModifiers) != mask)
        {
            return false;
        }

        shortcut = new UserKeyboardShortcut(key, mask);
        return true;
    }

    public static bool TryNormalizeKey(string? value, out string key)
    {
        key = "";
        if (string.IsNullOrWhiteSpace(value)) return false;
        var candidate = value.Trim();
        if (candidate.Equals("Return", StringComparison.OrdinalIgnoreCase)) candidate = "Enter";
        else if (candidate.Equals("Back", StringComparison.OrdinalIgnoreCase)) candidate = "Backspace";
        else if (candidate.Equals("Prior", StringComparison.OrdinalIgnoreCase)) candidate = "PageUp";
        else if (candidate.Equals("Next", StringComparison.OrdinalIgnoreCase)) candidate = "PageDown";

        var upper = candidate.ToUpperInvariant();
        var valid = upper.Length == 1 && upper[0] is >= 'A' and <= 'Z'
            || upper.Length == 2 && upper[0] == 'D' && upper[1] is >= '0' and <= '9'
            || upper.StartsWith("NUMPAD", StringComparison.Ordinal) && upper.Length == 7 && upper[^1] is >= '0' and <= '9'
            || upper.Length >= 2 && upper[0] == 'F' && int.TryParse(upper[1..], out var functionKey) && functionKey is >= 1 and <= 24
            || upper is "SPACE" or "ENTER" or "TAB" or "BACKSPACE" or "DELETE" or "INSERT"
                or "HOME" or "END" or "PAGEUP" or "PAGEDOWN" or "ESCAPE"
                or "UP" or "DOWN" or "LEFT" or "RIGHT"
            || upper.StartsWith("OEM", StringComparison.Ordinal) && upper.Length <= 16
                && upper.Skip(3).All(character => char.IsAsciiLetterOrDigit(character));
        if (!valid) return false;

        key = upper switch
        {
            "RETURN" => "Enter",
            "BACK" => "Backspace",
            "PRIOR" => "PageUp",
            "NEXT" => "PageDown",
            _ => upper,
        };
        return true;
    }

    public bool Matches(string? key, byte modifiers) =>
        TryNormalizeKey(key, out var normalized)
        && string.Equals(Key, normalized, StringComparison.Ordinal)
        && ModifierMask == (modifiers & AllModifiers);

    public string DisplayValue
    {
        get
        {
            var parts = new List<string>(5);
            if ((ModifierMask & Control) != 0) parts.Add("Ctrl");
            if ((ModifierMask & Alt) != 0) parts.Add("Alt");
            if ((ModifierMask & Shift) != 0) parts.Add("Shift");
            if ((ModifierMask & Super) != 0) parts.Add("Super");
            parts.Add(DisplayKey(Key));
            return string.Join("+", parts);
        }
    }

    private static string DisplayKey(string key) => key switch
    {
        "SPACE" => "Space",
        "BACKSPACE" => "Backspace",
        "PAGEUP" => "Page Up",
        "PAGEDOWN" => "Page Down",
        "OEMMINUS" => "-",
        "OEMPLUS" => "+",
        "OEMCOMMA" => ",",
        "OEMPERIOD" => ".",
        "OEM1" or "OEMSEMICOLON" => ";",
        "OEM2" or "OEMQUESTION" => "/",
        "OEM3" or "OEMTILDE" => "`",
        "OEM4" or "OEMOPENBRACKETS" => "[",
        "OEM5" or "OEMPIPE" => "\\",
        "OEM6" or "OEMCLOSEBRACKETS" => "]",
        "OEM7" or "OEMQUOTES" => "'",
        _ when key.Length == 2 && key[0] == 'D' && char.IsAsciiDigit(key[1]) => key[1].ToString(),
        _ when key.StartsWith("NUMPAD", StringComparison.Ordinal) => "Num " + key[^1],
        _ => key,
    };
}

public enum KeyboardShortcutUpdateStatus
{
    Saved,
    Conflict,
}

public readonly record struct KeyboardShortcutUpdateResult(
    KeyboardShortcutUpdateStatus Status,
    KeyboardShortcutAction? ConflictingAction = null);

public static class KeyboardShortcutCatalog
{
    public static IReadOnlyList<KeyboardShortcutAction> Actions { get; } =
        Enum.GetValues<KeyboardShortcutAction>();

    public static string SettingsKey(KeyboardShortcutAction action) =>
        "ui.keyboardShortcut." + char.ToLowerInvariant(action.ToString()[0]) + action.ToString()[1..];

    public static IReadOnlyDictionary<KeyboardShortcutAction, UserKeyboardShortcut> CreateDefaults() =>
        new Dictionary<KeyboardShortcutAction, UserKeyboardShortcut>
        {
            [KeyboardShortcutAction.ToggleSidebar] = new("B", UserKeyboardShortcut.Control),
            [KeyboardShortcutAction.PullRequests] = new("P", UserKeyboardShortcut.Control | UserKeyboardShortcut.Shift),
            [KeyboardShortcutAction.Scheduled] = new("T", UserKeyboardShortcut.Control | UserKeyboardShortcut.Shift),
            [KeyboardShortcutAction.Review] = new("G", UserKeyboardShortcut.Control | UserKeyboardShortcut.Shift),
            [KeyboardShortcutAction.Terminal] = new("T", UserKeyboardShortcut.Control | UserKeyboardShortcut.Alt),
            [KeyboardShortcutAction.Browser] = new("T", UserKeyboardShortcut.Control),
            [KeyboardShortcutAction.Files] = new("P", UserKeyboardShortcut.Control),
            [KeyboardShortcutAction.NewConversation] = new("S", UserKeyboardShortcut.Control | UserKeyboardShortcut.Alt),
        };

    public static IReadOnlyDictionary<KeyboardShortcutAction, UserKeyboardShortcut> Load(
        HarnessPluginKit.ISettingsRegistry settings)
    {
        var defaults = CreateDefaults();
        var loaded = new Dictionary<KeyboardShortcutAction, UserKeyboardShortcut>(defaults);
        var used = new HashSet<UserKeyboardShortcut>(defaults.Values);
        foreach (var action in Actions)
        {
            var defaultShortcut = defaults[action];
            used.Remove(defaultShortcut);
            if (UserKeyboardShortcut.TryParse(settings.Get(SettingsKey(action))?.AsString(), out var candidate)
                && !used.Contains(candidate))
            {
                loaded[action] = candidate;
            }
            used.Add(loaded[action]);
        }
        return loaded;
    }
}

// Copyright (c) 2026 DOTS
// Maps between the single characters keyboard shortcuts are stored as and Avalonia keys.

using Avalonia.Input;

namespace DotsHarness.Views;

internal static class ShortcutKeyMap
{
    private static readonly (char Character, Key Key)[] Punctuation =
    {
        ('`', Key.OemTilde), (' ', Key.Space), (',', Key.OemComma), ('.', Key.OemPeriod), ('/', Key.OemQuestion),
        (';', Key.OemSemicolon), ('-', Key.OemMinus), ('=', Key.OemPlus), ('[', Key.OemOpenBrackets),
        (']', Key.OemCloseBrackets), ('\\', Key.OemPipe), ('\'', Key.OemQuotes),
    };

    public static Key? ToKey(char character)
    {
        if (character is >= 'a' and <= 'z') return Key.A + (character - 'a');
        if (character is >= '0' and <= '9') return Key.D0 + (character - '0');
        foreach (var (c, key) in Punctuation) if (c == character) return key;
        return null;
    }

    public static char? ToCharacter(Key key)
    {
        if (key is >= Key.A and <= Key.Z) return (char)('a' + (key - Key.A));
        if (key is >= Key.D0 and <= Key.D9) return (char)('0' + (key - Key.D0));
        foreach (var (c, mapped) in Punctuation) if (mapped == key) return c;
        return null;
    }
}

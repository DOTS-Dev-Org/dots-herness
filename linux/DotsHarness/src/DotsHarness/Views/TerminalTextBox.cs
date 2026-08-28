// Copyright (c) 2026 DOTS
// Single-surface terminal input for Avalonia.

using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Input.Platform;
using Avalonia.Media;
using Avalonia.Threading;

namespace DotsHarness.Views;

public sealed class TerminalTextBox : TextBox
{
    public event Action<string>? InputReceived;

    public bool IsInputEnabled { get; set; }

    public TerminalTextBox()
    {
        IsReadOnly = true;
        AcceptsReturn = true;
        AcceptsTab = true;
        TextWrapping = TextWrapping.NoWrap;
        ClearSelectionOnLostFocus = false;
        KeyDown += OnKeyDown;
        TextInput += OnTextInput;
        Loaded += (_, _) => Dispatcher.UIThread.Post(FocusTerminal);
    }

    public void SetTranscript(string transcript)
    {
        if (Text != transcript) Text = transcript;
        CaretIndex = Text?.Length ?? 0;
        ScrollTerminalToEnd();
    }

    private void OnTextInput(object? sender, TextInputEventArgs e)
    {
        if (!IsInputEnabled || string.IsNullOrEmpty(e.Text)) return;
        InputReceived?.Invoke(e.Text);
        e.Handled = true;
    }

    private void OnKeyDown(object? sender, KeyEventArgs e)
    {
        var control = e.KeyModifiers.HasFlag(KeyModifiers.Control);

        // Keep the native copy gesture when the user has selected transcript text.
        if (control && e.Key == Key.C && SelectionStart != SelectionEnd) return;

        if (control && e.Key == Key.V)
        {
            e.Handled = true;
            _ = PasteAsync();
            return;
        }

        if (!IsInputEnabled) return;

        var input = InputFor(e.Key, control);
        if (input is null) return;
        InputReceived?.Invoke(input);
        e.Handled = true;
    }

    private async Task PasteAsync()
    {
        if (!IsInputEnabled) return;
        var clipboard = TopLevel.GetTopLevel(this)?.Clipboard;
        if (clipboard is null) return;
        try
        {
            var text = await clipboard.GetTextAsync();
            if (!string.IsNullOrEmpty(text)) InputReceived?.Invoke(text);
        }
        catch
        {
            // Clipboard access can be unavailable on a headless or closing desktop.
        }
    }

    private void FocusTerminal()
    {
        if (IsVisible) Focus(NavigationMethod.Unspecified, KeyModifiers.None);
        CaretIndex = Text?.Length ?? 0;
        ScrollTerminalToEnd();
    }

    private void ScrollTerminalToEnd()
    {
        var lines = Math.Max(1, (Text ?? "").Count(value => value == '\n') + 1);
        ScrollToLine(lines - 1);
    }

    private static string? InputFor(Key key, bool control)
    {
        if (control)
        {
            var keyValue = (int)key;
            if (keyValue >= (int)Key.A && keyValue <= (int)Key.Z)
                return ((char)('\u0001' + keyValue - (int)Key.A)).ToString();
            if (key == Key.Space) return "\0";
        }

        return key switch
        {
            Key.Enter => "\r",
            Key.Back => "\u007f",
            Key.Tab => "\t",
            Key.Escape => "\u001b",
            Key.Left => "\u001b[D",
            Key.Right => "\u001b[C",
            Key.Down => "\u001b[B",
            Key.Up => "\u001b[A",
            Key.Home => "\u001b[H",
            Key.End => "\u001b[F",
            Key.Delete => "\u001b[3~",
            _ => null,
        };
    }
}

// Copyright (c) 2026 DOTS
// Single-surface terminal input for WPF.

using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;

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
        PreviewKeyDown += OnPreviewKeyDown;
        PreviewTextInput += OnPreviewTextInput;
        Loaded += (_, _) => Dispatcher.BeginInvoke(FocusTerminal);
    }

    public void SetTranscript(string transcript)
    {
        if (Text != transcript) Text = transcript;
        CaretIndex = Text?.Length ?? 0;
        ScrollToEnd();
    }

    private void OnPreviewTextInput(object sender, TextCompositionEventArgs e)
    {
        if (!IsInputEnabled || string.IsNullOrEmpty(e.Text)) return;
        InputReceived?.Invoke(e.Text);
        e.Handled = true;
    }

    private void OnPreviewKeyDown(object sender, KeyEventArgs e)
    {
        var control = Keyboard.Modifiers.HasFlag(ModifierKeys.Control);

        // Keep the native copy gesture when the user has selected transcript text.
        if (control && e.Key == Key.C && SelectionLength > 0) return;

        if (control && e.Key == Key.V)
        {
            e.Handled = true;
            try
            {
                if (IsInputEnabled && Clipboard.ContainsText()) InputReceived?.Invoke(Clipboard.GetText());
            }
            catch
            {
                // Clipboard access can be unavailable while the desktop is closing.
            }
            return;
        }

        if (!IsInputEnabled) return;

        var input = InputFor(e.Key, control);
        if (input is null) return;
        InputReceived?.Invoke(input);
        e.Handled = true;
    }

    private void FocusTerminal()
    {
        if (IsVisible) Focus();
        CaretIndex = Text?.Length ?? 0;
        ScrollToEnd();
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

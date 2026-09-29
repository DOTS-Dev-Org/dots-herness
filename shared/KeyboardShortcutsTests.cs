using DotsHarnessCore;
using Xunit;

public sealed class KeyboardShortcutsTests
{
    private static KeyboardShortcutSettings Settings(Dictionary<string, string>? store = null)
    {
        store ??= new();
        return new KeyboardShortcutSettings(key => store.GetValueOrDefault(key), (key, value) => store[key] = value);
    }

    [Fact]
    public void StoredValueRoundTripsIncludingThePipeKey()
    {
        var shortcut = new UserKeyboardShortcut('|', UserKeyboardShortcut.Command | UserKeyboardShortcut.Shift);
        Assert.Equal("|", shortcut.Key.ToString());
        Assert.Equal(shortcut, UserKeyboardShortcut.Parse(shortcut.StoredValue));
    }

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("b")]
    [InlineData("b|")]
    [InlineData("bb|1")]
    [InlineData("b|0")]
    [InlineData("b|99")]
    [InlineData("b|x")]
    public void BadStoredDataIsIgnored(string? stored) => Assert.Null(UserKeyboardShortcut.Parse(stored));

    [Fact]
    public void KeyIsLowercasedAndNeedsAModifier()
    {
        Assert.Equal('b', new UserKeyboardShortcut('B', UserKeyboardShortcut.Command).Key);
        Assert.Null(UserKeyboardShortcut.TryCreate('b', 0));
        Assert.Null(UserKeyboardShortcut.TryCreate('\u0001', UserKeyboardShortcut.Command));
    }

    [Fact]
    public void DisplayUsesCtrlWhereMacUsesCommand()
    {
        Assert.Equal("Ctrl+Shift+T", KeyboardShortcutAction.Scheduled.Default().DisplayValue);
        Assert.Equal("Ctrl+`", KeyboardShortcutAction.Terminal.Default().DisplayValue);
        Assert.Equal("Alt+Space", new UserKeyboardShortcut(' ', UserKeyboardShortcut.Option).DisplayValue);
    }

    [Fact]
    public void DefaultsApplyUntilOverridden()
    {
        var store = new Dictionary<string, string>();
        var settings = Settings(store);
        Assert.Equal(KeyboardShortcutAction.ToggleSidebar.Default(), settings.ShortcutFor(KeyboardShortcutAction.ToggleSidebar));
        Assert.Equal("ui.keyboardShortcut.toggleSidebar", KeyboardShortcutAction.ToggleSidebar.SettingsKey());

        var custom = new UserKeyboardShortcut('k', UserKeyboardShortcut.Command);
        Assert.IsType<KeyboardShortcutUpdateResult.Saved>(settings.Update(KeyboardShortcutAction.ToggleSidebar, custom));
        Assert.Equal(custom, settings.ShortcutFor(KeyboardShortcutAction.ToggleSidebar));
        Assert.Equal("k|1", store["ui.keyboardShortcut.toggleSidebar"]);
    }

    [Fact]
    public void ACombinationAnotherActionUsesIsRefused()
    {
        var settings = Settings();
        var taken = KeyboardShortcutAction.Terminal.Default();
        var result = Assert.IsType<KeyboardShortcutUpdateResult.Conflict>(settings.Update(KeyboardShortcutAction.ToggleSidebar, taken));
        Assert.Equal(KeyboardShortcutAction.Terminal, result.With);
        Assert.Equal(KeyboardShortcutAction.ToggleSidebar.Default(), settings.ShortcutFor(KeyboardShortcutAction.ToggleSidebar));
    }

    [Fact]
    public void CommandAndControlCountAsTheSamePhysicalKeys()
    {
        var command = new UserKeyboardShortcut('x', UserKeyboardShortcut.Command);
        var control = new UserKeyboardShortcut('x', UserKeyboardShortcut.Control);
        Assert.True(command.Collides(control));
        Assert.False(command.Collides(new UserKeyboardShortcut('x', UserKeyboardShortcut.Command | UserKeyboardShortcut.Shift)));
    }

    [Fact]
    public void ChangedFiresOnlyForSavedUpdates()
    {
        var settings = Settings();
        var fired = 0;
        settings.Changed += (_, _) => fired++;
        settings.Update(KeyboardShortcutAction.Terminal, KeyboardShortcutAction.Scheduled.Default());
        Assert.Equal(0, fired);
        settings.Update(KeyboardShortcutAction.Terminal, new UserKeyboardShortcut('j', UserKeyboardShortcut.Command));
        Assert.Equal(1, fired);
    }

    [Fact]
    public void ResetRestoresTheDefault()
    {
        var settings = Settings();
        settings.Update(KeyboardShortcutAction.Terminal, new UserKeyboardShortcut('j', UserKeyboardShortcut.Command));
        Assert.IsType<KeyboardShortcutUpdateResult.Saved>(settings.Reset(KeyboardShortcutAction.Terminal));
        Assert.Equal(KeyboardShortcutAction.Terminal.Default(), settings.ShortcutFor(KeyboardShortcutAction.Terminal));
    }
}

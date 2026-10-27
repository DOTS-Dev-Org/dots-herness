// Copyright (c) 2026 DOTS

using DotsHarnessCore;
using Xunit;

namespace DotsHarness.Tests;

public class ToolRepeatGuardTests
{
    [Fact]
    public void RepeatIgnoresKeyOrderAndWhitespace()
    {
        var guard = new ToolRepeatGuard();
        var a = new NativeToolCall("1", "read_file", """{"path":"a.txt","offset":1}""");
        var b = new NativeToolCall("2", "read_file", """{ "offset": 1, "path": "a.txt" }""");
        Assert.Equal(ToolRepeatGuard.Signature(a), ToolRepeatGuard.Signature(b));
        Assert.False(guard.IsRepeat(a));
        Assert.False(guard.IsRepeat(b));
        Assert.False(guard.IsRepeat(a));
        Assert.True(guard.IsRepeat(b));
    }

    [Fact]
    public void EditNoticeAppearsOnlyPastTheLimitPerFile()
    {
        var guard = new ToolRepeatGuard();
        for (var i = 0; i < ToolRepeatGuard.MaxEditsPerFile; i++)
            Assert.Equal("", guard.EditNotice(new NativeToolCall($"{i}", "edit_file", $$"""{"path":"a.txt","n":{{i}}}""")));
        Assert.Equal("", guard.EditNotice(new NativeToolCall("x", "edit_file", """{"path":"b.txt"}""")));
        Assert.Contains("Repeated edits", guard.EditNotice(new NativeToolCall("y", "write_file", """{"path":"a.txt"}""")));
    }
}

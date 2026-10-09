// Copyright (c) 2026 DOTS

using DotsHarnessCore;
using Xunit;

namespace DotsHarness.Tests;

public sealed class AccountUsageTests
{
    [Fact]
    public void ParsesChatGptWindowsAndPicksTheWorst()
    {
        var usage = AccountUsageSnapshot.ParseChatGpt(
            """{"rate_limit":{"primary_window":{"used_percent":31,"limit_window_seconds":18000,"reset_at":1790000000},"secondary_window":{"used_percent":"5","limit_window_seconds":604800}}}""");

        Assert.NotNull(usage);
        Assert.Equal(0.31, usage!.UsedFraction!.Value, 3);
        Assert.Equal(DateTimeOffset.FromUnixTimeSeconds(1790000000), usage.ResetsAt);
        Assert.Equal(new[] { false, true }, usage.Windows.Select(window => window.Weekly));
        Assert.Null(AccountUsageSnapshot.ParseChatGpt("""{"rate_limit":{}}"""));
    }
}

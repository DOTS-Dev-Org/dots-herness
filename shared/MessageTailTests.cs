// Copyright (c) 2026 DOTS

using System.Collections.ObjectModel;
using DotsHarnessCore;
using Xunit;

namespace DotsHarness.Tests;

public sealed class MessageTailTests
{
    private const int Page = MessageTail<int>.PageSize;

    [Fact]
    public void ShowsNewestPageAndPagesOlderInOrder()
    {
        var total = Page * 2 + 3;
        var source = new ObservableCollection<int>(Enumerable.Range(0, total));
        using var tail = new MessageTail<int>(source);
        Assert.Equal(Enumerable.Range(total - Page, Page), tail);

        Assert.True(tail.LoadOlder());
        Assert.Equal(Enumerable.Range(total - Page * 2, Page * 2), tail);
        Assert.True(tail.LoadOlder());
        Assert.Equal(source, tail);
        Assert.False(tail.HasOlder);
        Assert.False(tail.LoadOlder());
    }

    [Fact]
    public void FollowsAppendsAndRebuildsOnOtherChanges()
    {
        var total = Page + 5;
        var source = new ObservableCollection<int>(Enumerable.Range(0, total));
        using var tail = new MessageTail<int>(source);
        source.Add(total);
        Assert.Equal(Enumerable.Range(total - Page, Page + 1), tail);

        source.RemoveAt(total - 1);
        Assert.Equal(source.Skip(source.Count - tail.Count), tail);
        Assert.Equal(total, tail.Last());

        source.Clear();
        Assert.Empty(tail);
    }
}

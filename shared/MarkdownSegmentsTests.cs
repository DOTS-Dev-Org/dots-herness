using DotsHarnessCore;
using Xunit;

public sealed class MarkdownSegmentsTests
{
    [Fact]
    public void FencedBlockSplitsFromProseAndKeepsItsColumns()
    {
        var segments = MarkdownSegments.Split("Akış:\n```\n┌─┐\n└─┘\n```\nSon");

        Assert.Equal(
            new[] { new MarkdownSegment(false, "Akış:"), new MarkdownSegment(true, "┌─┐\n└─┘"), new MarkdownSegment(false, "Son") },
            segments);
    }

    [Fact]
    public void UnclosedFenceStaysCodeWhileAReplyStreams()
    {
        Assert.Equal(new[] { new MarkdownSegment(true, "┌─┐") }, MarkdownSegments.Split("```\n┌─┐"));
    }

    [Fact]
    public void PlainTextIsOneProseSegment()
    {
        Assert.Equal(new[] { new MarkdownSegment(false, "merhaba") }, MarkdownSegments.Split("merhaba"));
    }

    [Fact]
    public void PipeTableBecomesItsOwnSegment()
    {
        var segments = MarkdownSegments.Split("Fark:\n| Özellik | `actor` | x |\n|---|:---:|--:|\n| Tür | a \\| b | 1 |\n| Kalıtım | yok |\nSon");

        Assert.Equal(3, segments.Count);
        Assert.Equal("table", segments[1].Language);
        var table = MarkdownSegments.Table(segments[1].Text);
        Assert.Equal(new[] { "Özellik", "`actor`", "x" }, table.Header);
        Assert.Equal(
            new[] { MarkdownTableAlignment.Left, MarkdownTableAlignment.Center, MarkdownTableAlignment.Right },
            table.Alignments);
        Assert.Equal(new[] { "Tür", "a | b", "1" }, table.Rows[0]);
        Assert.Equal(new[] { "Kalıtım", "yok" }, table.Rows[1]);
        Assert.Equal(new MarkdownSegment(false, "Son"), segments[2]);
    }

    [Fact]
    public void TableHeaderWithoutSeparatorStaysProse()
    {
        Assert.Equal(new[] { new MarkdownSegment(false, "| a | b |") }, MarkdownSegments.Split("| a | b |"));
    }
}

using DotsHarnessCore;
using Xunit;

public sealed class MarkdownDiagramsTests
{
    [Fact]
    public void FenceLanguageIsKept()
    {
        var segments = MarkdownSegments.Split("a\n```diagram\nA | B\n```");
        Assert.Equal(new MarkdownSegment(true, "A | B", "diagram"), segments[1]);
    }

    [Fact]
    public void FlowRowsCarryNumberNoteAndBadge()
    {
        var steps = MarkdownDiagrams.Flow("Harita: şema 4 `## x` [warn: Eski şema]\n\nBilgi: sırada [Sırada]");
        Assert.Equal(new FlowStep(1, "Harita", "şema 4 `## x`", new DiagramTag("warn", "Eski şema"), false), steps[0]);
        Assert.Equal(new FlowStep(2, "Bilgi", "sırada", new DiagramTag(null, "Sırada"), true), steps[1]);
        Assert.Equal(((byte)255, (byte)149, (byte)0), steps[0].Badge!.Color);
    }

    [Fact]
    public void DiagramParsesLayersCaptionsLegendAndColors()
    {
        var spec = new DiagramSpec("Kural: AGENTS.md [repo] | Kişisel: Mac [local] | Git index\n> System prompt\nModel çalışır\nlegend: repo = Repo | local = Bu Mac");
        Assert.Equal(new[] { 3, 1 }, spec.Layers.Select(l => l.Nodes.Count));
        Assert.Equal("System prompt", spec.Layers[1].Caption);
        Assert.Equal(new DiagramNode("Kişisel", "Mac", "local"), spec.Layers[0].Nodes[1]);
        Assert.Null(spec.Layers[0].Nodes[2].Group);
        Assert.Equal(new[] { "repo", "local" }, spec.Legend.Select(l => l.Group));
        Assert.NotEqual(spec.Color("repo"), spec.Color("local"));
        Assert.Equal(DiagramTag.Neutral, spec.Color(null));
    }

    [Fact]
    public void ChartScalesToPeakAndSkipsOtherLines()
    {
        var bars = MarkdownDiagrams.Chart("macOS: 40\nnot a row\nLinux: 10 ms");
        Assert.Equal(new[] { 1.0, 0.25 }, bars.Select(b => b.Fraction));
        Assert.Equal("10 ms", bars[1].Text);
    }
}

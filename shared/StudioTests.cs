using DotsHarnessCore;
using Xunit;

public sealed class StudioTests
{
    [Fact]
    public void MediaPlanUpdatesRemovesAndAddsInsideTheCanvas()
    {
        var canvas = new MediaCanvas { Width = 100, Height = 100, Layers =
        [
            new MediaLayer { Kind = "shape", Width = 10, Height = 10 },
            new MediaLayer { Kind = "text", Text = "a", Width = 10, Height = 10 },
        ] };
        var plan = MediaStudioAI.ParsePlan("""
            Sure: {"background":"#abcdef","remove":["L2","L9"],"update":[{"id":"L1","color":"#ff0000","x":500}],
            "layers":[{"type":"text","text":"Hi","width":40,"height":20},{"type":"text","width":5,"height":5},{"type":"video"}]}
            """, canvas)!;
        Assert.Equal("#ABCDEF", plan.BackgroundHex);
        Assert.Equal([canvas.Layers[1].Id], plan.Removals);
        Assert.Equal("#FF0000", plan.Updates.Single().ColorHex);
        Assert.Equal(90, plan.Updates.Single().X);
        Assert.Equal("Hi", plan.Steps.Single().Layer.Text);
        Assert.Null(MediaStudioAI.ParsePlan("no json", canvas));
    }

    [Fact]
    public void MusicPlanAddsAVocalTrackPerSingingArtist()
    {
        var project = MusicStudioAI.ParsePlan("""
            {"name":"Song","bpm":500,"artists":[{"name":"Ada"},{"name":"Bo"}],
             "sections":[{"name":"Verse","bars":4,"lines":[{"artist":"ada","text":"la"}]}],
             "tracks":[{"instrument":"drums"}]}
            """, "brief")!;
        Assert.Equal(240, project.Bpm);
        Assert.Equal(["drums", "vocals"], project.Tracks.Select(t => t.Instrument));
        Assert.Equal(project.Artists[0].Id, project.Tracks[1].ArtistID);
        Assert.Equal("[Verse]\nla", MusicStudioAI.Lyrics(project.Tracks[1], project));
        Assert.Equal(4, project.Seconds);
    }

    [Fact]
    public void BotRepliesSplitOnSeparatorsOutsideCodeFences()
    {
        var parts = BotStore.SplitMessages("Hi\n---\n```\n---\n```\nBye").Select(p => p.Trim()).ToList();
        Assert.Equal(["Hi", "```\n---\n```\nBye"], parts);
        var turns = BotStore.Turns([new() { Role = "user", Text = "a" }, new() { Role = "user", Text = "b" }, new() { Role = "assistant", Text = "c" }]);
        Assert.Equal(["a\n---\nb", "c"], turns.Select(t => t.Text));
    }

    [Fact]
    public void LibraryRecordsOncePerPathAndRemovesOnlyItsOwnCopies()
    {
        var root = Path.Combine(Path.GetTempPath(), $"StudioTests-{Guid.NewGuid():N}");
        try
        {
            var first = MediaLibrary.Record("/tmp/a.png", "image", "a cat\nmore", root);
            Assert.Equal(first.Id, MediaLibrary.Record("/tmp/a.png", "image", null, root).Id);
            Assert.Equal("a cat", MediaLibrary.Items(root).Single().Title);
            MediaLibrary.Remove(first.Id, root);
            Assert.Empty(MediaLibrary.Items(root));
        }
        finally { try { Directory.Delete(root, true); } catch (IOException) { } }
    }
}

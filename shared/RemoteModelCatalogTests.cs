using DotsHarnessCore;
using Xunit;

// Overlays are process-wide, so every case uses its own provider and model ids.
public sealed class RemoteModelCatalogTests
{
    private const string Catalog = """
        [{"id":"catalog-test","models":[
          {"id":"catalog-test-efforts","efforts":["low","high"],"contextWindow":123456},
          {"id":"catalog-test-plain"}
        ]},
        {"id":"catalog-test-bundled","models":[{"id":"claude-sonnet-5-5"}]}]
        """;

    [Fact]
    public void MalformedCatalogIsRejected()
    {
        Assert.Null(RemoteModelCatalog.Parse("not json"u8));
        Assert.Null(RemoteModelCatalog.Parse("{\"id\":\"catalog-test\"}"u8));
    }

    [Fact]
    public void PublishedEffortsReplaceBuiltInsAndMissingEffortsKeepThem()
    {
        var entries = RemoteModelCatalog.Parse(System.Text.Encoding.UTF8.GetBytes(Catalog))!;
        RemoteModelCatalog.Apply(entries);

        Assert.Equal(new[] { "low", "high" }, NativeEffortCatalog.Levels("catalog-test-efforts"));
        // A model published without efforts keeps the built-in table.
        Assert.Equal(new[] { "low", "medium", "high", "xhigh", "max" }, NativeEffortCatalog.Levels("claude-sonnet-5-5"));
    }

    [Fact]
    public void PublishedContextWindowAndModelIdsApply()
    {
        RemoteModelCatalog.Apply(RemoteModelCatalog.Parse(System.Text.Encoding.UTF8.GetBytes(Catalog))!);

        Assert.Equal(123456, RouterCatalog.DocumentedContextWindow("catalog-test", "catalog-test-efforts"));
        Assert.Equal(new[] { "catalog-test-efforts", "catalog-test-plain" }, RemoteModelCatalog.ModelIdsFor("catalog-test"));
        Assert.Empty(RemoteModelCatalog.ModelIdsFor("catalog-test-unknown"));
    }

    [Fact]
    public void CachedCatalogAppliesOnOfflineStart()
    {
        var directory = Path.Combine(Path.GetTempPath(), $"RemoteModelCatalogTests-{Guid.NewGuid():N}");
        Directory.CreateDirectory(directory);
        try
        {
            var cache = Path.Combine(directory, "providers.remote.json");
            File.WriteAllText(cache, """[{"id":"catalog-test-cache","models":[{"id":"catalog-test-cached","efforts":["medium"]}]}]""");

            RemoteModelCatalog.LoadCache(cache);

            Assert.Equal(new[] { "medium" }, NativeEffortCatalog.Levels("catalog-test-cached"));
            Assert.Equal(new[] { "catalog-test-cached" }, RemoteModelCatalog.ModelIdsFor("catalog-test-cache"));
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }
}

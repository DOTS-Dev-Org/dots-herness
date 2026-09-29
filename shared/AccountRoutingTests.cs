using DotsHarnessCore;
using PluginRuntime;
using Xunit;

public sealed class AccountRoutingTests : IDisposable
{
    private static readonly DateTimeOffset Now = new(2026, 9, 29, 12, 0, 0, TimeSpan.Zero);
    private readonly string _root = Path.Combine(Path.GetTempPath(), $"AccountRouting-{Guid.NewGuid():N}");

    public void Dispose()
    {
        try { Directory.Delete(_root, true); } catch (IOException) { }
    }

    private static NativeProviderAccount Account(string id, string provider = "claude", int priority = 0, string model = "m1") =>
        new() { Id = id, Provider = provider, ProviderName = provider, Model = model, Priority = priority };

    private static string[] Order(IEnumerable<NativeProviderAccount> accounts, string? preferred = null,
        Func<string, double?>? remaining = null, string? model = "m1") =>
        NativeProviderRouter.OrderedRoutes(accounts, model, preferred, remaining, Now).Select(a => a.Id).ToArray();

    [Fact]
    public void PriorityBreaksTiesWhenUsageIsUnknown() =>
        Assert.Equal(new[] { "b", "a" }, Order(new[] { Account("a", priority: 5), Account("b", priority: 1) }));

    [Fact]
    public void MostRemainingQuotaComesFirst()
    {
        var usage = new Dictionary<string, double> { ["a"] = 0.2, ["b"] = 0.9 };
        Assert.Equal(new[] { "b", "a" }, Order(new[] { Account("a"), Account("b") }, remaining: id => usage[id]));
    }

    [Fact]
    public void UnknownUsageSitsBetweenHealthyAndExhausted()
    {
        var usage = new Dictionary<string, double?> { ["healthy"] = 0.5, ["exhausted"] = 0 };
        var accounts = new[] { Account("exhausted"), Account("unknown"), Account("healthy") };
        Assert.Equal(new[] { "healthy", "unknown", "exhausted" },
            Order(accounts, remaining: id => usage.GetValueOrDefault(id)));
    }

    [Fact]
    public void CoolingDownAccountsAreLast()
    {
        var cooling = Account("a", priority: 0);
        cooling.CooldownUntil = Now.AddMinutes(5);
        Assert.Equal(new[] { "b", "a" }, Order(new[] { cooling, Account("b", priority: 9) }));
        cooling.CooldownUntil = Now.AddMinutes(-1);
        Assert.Equal(new[] { "a", "b" }, Order(new[] { cooling, Account("b", priority: 9) }));
    }

    [Fact]
    public void PreferredAccountLeadsUnlessCoolingDown()
    {
        var accounts = new[] { Account("a", priority: 0), Account("b", priority: 1) };
        Assert.Equal(new[] { "b", "a" }, Order(accounts, preferred: "b"));
        accounts[1].CooldownUntil = Now.AddMinutes(5);
        Assert.Equal(new[] { "a", "b" }, Order(accounts, preferred: "b"));
    }

    [Fact]
    public void InactiveAndNonServingAccountsAreSkipped()
    {
        var inactive = Account("a");
        inactive.Active = false;
        var other = Account("b", model: "other");
        Assert.Equal(new[] { "c" }, Order(new[] { inactive, other, Account("c") }));
    }

    private NativeProviderStore Store(params NativeProviderAccount[] accounts)
    {
        var store = new NativeProviderStore(_root, new MemoryProviderSecretStore());
        store.State.Accounts.AddRange(accounts);
        store.Save();
        return store;
    }

    [Fact]
    public void AffinityHoldsWhileTheAccountCanServe()
    {
        var router = new NativeProviderRouter(Store(Account("a")));
        Assert.Equal("a", router.AffinityAccountId("a", "m1", "m1", "auto"));
        Assert.Equal("a", router.AffinityAccountId("a", "m1", "auto", "auto"));
    }

    [Fact]
    public void AffinityDropsOnModelChangeCooldownOrMissingAccount()
    {
        var account = Account("a");
        account.Models = ["m1", "m2"];
        var store = Store(account);
        var router = new NativeProviderRouter(store);
        Assert.Null(router.AffinityAccountId("a", "m1", "m2", "auto"));
        Assert.Null(router.AffinityAccountId("gone", "m1", "m1", "auto"));
        store.SetCooldown("a", DateTimeOffset.UtcNow.AddMinutes(5));
        Assert.Null(router.AffinityAccountId("a", "m1", "m1", "auto"));
        store.SetCooldown("a", null);
        store.SetActive("a", false);
        Assert.Null(router.AffinityAccountId("a", "m1", "m1", "auto"));
    }

    [Fact]
    public void CooldownPersistsAcrossStoreReload()
    {
        var store = Store(Account("a"));
        var until = DateTimeOffset.UtcNow.AddMinutes(10);
        store.SetCooldown("a", until);
        var reloaded = new NativeProviderStore(_root, new MemoryProviderSecretStore());
        Assert.NotNull(reloaded.State.Accounts.Single().CooldownUntil);
    }

    [Fact]
    public void ConversationAffinityFieldsSurviveSerialization()
    {
        var conversation = new Conversation { StickyAccountId = "a", StickyModelId = "m1" };
        var json = System.Text.Json.JsonSerializer.Serialize(conversation);
        var back = System.Text.Json.JsonSerializer.Deserialize<Conversation>(json)!;
        Assert.Equal("a", back.StickyAccountId);
        Assert.Equal("m1", back.StickyModelId);
    }

    [Fact]
    public void ReorderProvidersRewritesPrioritiesFamilyByFamily()
    {
        var store = Store(
            Account("c1", "claude", priority: 0), Account("c2", "claude", priority: 1),
            Account("o1", "openai", priority: 2), Account("g1", "gemini", priority: 3));
        var paths = new SupportPaths(_root, Path.Combine(_root, "plugins"), Path.Combine(_root, "presets"),
            Path.Combine(_root, "settings.json"), Path.Combine(_root, "host.patch.yml"), Path.Combine(_root, "trust.json"),
            Path.Combine(_root, "models"), Path.Combine(_root, "runtime"));
        using var router = new RouterController(paths, providerStore: store);

        router.ReorderProviders(new[] { "gemini", "claude" });

        int PriorityOf(string id) => store.State.Accounts.Single(a => a.Id == id).Priority;
        Assert.Equal(0, PriorityOf("g1"));
        Assert.Equal(100, PriorityOf("c1"));
        Assert.Equal(101, PriorityOf("c2"));
        // Providers left out keep their relative order after the listed ones.
        Assert.Equal(200, PriorityOf("o1"));
    }
}

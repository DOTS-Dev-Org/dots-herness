using System.Runtime.CompilerServices;
using System.Text.Json.Nodes;
using DotsHarnessCore;
using Xunit;

public sealed class ProjectDecisionsTests : IDisposable
{
    private readonly string _root = Path.Combine(Path.GetTempPath(), $"ProjectDecisionsTests-{Guid.NewGuid():N}");
    private string Workspace => Path.Combine(_root, "project");
    private string Support => Path.Combine(_root, "support");

    public ProjectDecisionsTests() => Directory.CreateDirectory(Workspace);

    public void Dispose()
    {
        try { Directory.Delete(_root, true); } catch (IOException) { }
    }

    private static JsonObject Contract([CallerFilePath] string source = "") =>
        (JsonObject)JsonNode.Parse(File.ReadAllText(Path.Combine(Path.GetDirectoryName(source)!, "memory-contract", "decisions.json")))!;

    private static readonly string[] Words =
    [
        "alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf", "hotel", "india", "juliet", "kilo", "lima",
        "mike", "november", "oscar", "papa", "quebec", "romeo", "sierra", "tango", "uniform", "victor", "whiskey",
        "xray", "yankee", "zulu", "amber", "basalt", "cobalt", "dune", "ember", "fjord", "garnet", "harbor", "iris",
        "jasper", "kestrel", "lagoon", "marble", "nectar", "onyx", "prairie", "quartz", "raven", "saffron", "tundra",
        "umber", "velvet", "willow", "xenon", "yarrow", "zephyr", "acorn", "birch", "cedar", "dahlia", "elm", "fern",
        "gorse", "heather", "ivy", "juniper", "kelp", "larch", "maple", "nettle", "oak", "pine", "quince", "rowan",
    ];

    /// <summary>A decision sharing almost no words with any other, so none is taken for its twin.</summary>
    private static string Distinct(int index) =>
        $"{Words[index % Words.Length]} {Words[(index * 7 + 3) % Words.Length]} {Words[(index * 13 + 5) % Words.Length]} {Words[(index * 29 + 11) % Words.Length]} settled.";

    private static string S(JsonNode? node) => node!.GetValue<string>();
    private static List<string> L(JsonNode? node) => ((JsonArray)node!).Select(S).ToList();

    private string Remember(string kind, string key, string text, string? reason = null, string[]? platforms = null)
    {
        var call = new JsonObject { ["kind"] = kind, ["key"] = key, ["text"] = text };
        if (reason is not null) call["reason"] = reason;
        if (platforms is not null) call["platforms"] = new JsonArray(platforms.Select(name => (JsonNode)name).ToArray());
        return WorkspaceFacts.Record(Workspace, call.ToJsonString(), Support);
    }

    [Fact]
    public void AgreesWithTheSharedContract()
    {
        var contract = Contract();
        foreach (var row in (JsonArray)contract["same"]!)
            Assert.True(row!["same"]!.GetValue<bool>() == ProjectDecisions.Same(S(row["left"]), S(row["right"])), S(row["left"]));
        foreach (var row in (JsonArray)contract["platforms"]!)
            Assert.Equal(L(row!["platforms"]), ProjectDecisions.PlatformsOf(S(row["text"])));
        foreach (var row in (JsonArray)contract["applies"]!)
            Assert.Equal(row!["applies"]!.GetValue<bool>(), ProjectDecisions.Applies(S(row["text"]), S(row["platform"])));
        foreach (var row in (JsonArray)contract["compose"]!)
            Assert.Equal(S(row!["text"]), ProjectDecisions.Compose(S(row["statement"]), S(row["reason"]), L(row["platforms"])));
        foreach (var row in (JsonArray)contract["tidy"]!)
            Assert.Equal(S(row!["tidied"]), ProjectDecisions.Tidy([new WorkspaceFact(S(row["kind"]), S(row["key"]), S(row["text"]))]).Single().Text);
        var evict = contract["evict"]!;
        var facts = ((JsonArray)evict["facts"]!).Select(row => new WorkspaceFact(S(row!["kind"]), S(row["key"]), S(row["text"]))).ToList();
        ProjectDecisions.Evict(facts, evict["max"]!.GetValue<int>());
        Assert.Equal(L(evict["kept"]), facts.Select(fact => fact.Key));
        foreach (var row in (JsonArray)contract["remotes"]!)
            Assert.Equal(row!["normalized"]?.GetValue<string>(), WorkspaceFacts.NormalizeRemote(S(row["url"])));
    }

    [Fact]
    public void AFullFileLosesItsOldestDecisionAndNeverWhatWasLearnedOfTheCode()
    {
        Remember("project", "architecture", "Three layers: UI, core and providers.");
        Remember("project", "conventions", "Tests live beside the code they cover.");
        for (var index = 0; index < WorkspaceFacts.MaxFacts + 5; index++)
            Remember("decision", $"choice-{index}", Distinct(index));

        var facts = WorkspaceFacts.Read(Workspace);
        Assert.Equal(WorkspaceFacts.MaxFacts, facts.Count);
        Assert.Contains(facts, fact => fact.Key == "architecture");
        Assert.Contains(facts, fact => fact.Key == "conventions");
        Assert.DoesNotContain(facts, fact => fact.Key == "choice-0");
        Assert.Contains(facts, fact => fact.Key == $"choice-{WorkspaceFacts.MaxFacts + 4}");
        Assert.DoesNotContain("No project fact yet for: architecture", WorkspaceFacts.Text(Workspace, Support));
    }

    [Fact]
    public void ADecisionKeepsItsReasonAndPlatformsAndKeylessOnesDoNotOverwriteEachOther()
    {
        Assert.StartsWith("Recorded", Remember("decision", "", "Keep the effort level", "changing it invalidates the measured prompt cache", ["macos"]));
        Assert.StartsWith("Recorded", Remember("decision", "", "Ship SQLite, not Postgres."));
        var decisions = WorkspaceFacts.Read(Workspace).Where(fact => fact.Kind == "decision").ToList();
        Assert.Equal(2, decisions.Count);
        Assert.All(decisions, fact => Assert.StartsWith("decision-", fact.Key));
        Assert.Equal("[macos] Keep the effort level. Reason: changing it invalidates the measured prompt cache", decisions[0].Text);

        // A long statement is clipped on its own; the reason survives whole.
        var statement = string.Join(" ", Enumerable.Repeat("The composer keeps every control together.", 12));
        Remember("decision", "composer", statement, "the user wants branch controls together");
        Assert.EndsWith("Reason: the user wants branch controls together", WorkspaceFacts.Read(Workspace).Single(fact => fact.Key == "composer").Text);
    }

    [Fact]
    public void ADecisionRestatedInOtherWordsReplacesTheOldWording()
    {
        Remember("decision", "usage-a", "macOS provider settings display each account's reported 5-hour and weekly usage windows separately, including per-window percentages and reset times.");
        Remember("decision", "usage-b", "macOS, Windows, and Linux provider settings display each account's reported 5-hour and weekly usage windows separately, including per-window percentages and reset times.");
        var decisions = WorkspaceFacts.Read(Workspace).Where(fact => fact.Kind == "decision").ToList();
        Assert.Single(decisions);
        Assert.Equal("usage-b", decisions[0].Key);
    }

    [Fact]
    public void ThePromptCarriesThisPlatformsDecisionsAndRecallFindsTheRest()
    {
        var elsewhere = ProjectDecisions.CurrentPlatform == "ios" ? "android" : "ios";
        Remember("decision", "here", "Everyone ships SQLite, not Postgres.");
        Remember("decision", "there", "Notification permission is requested on first launch.", platforms: [elsewhere]);
        var text = WorkspaceFacts.Text(Workspace, Support);
        Assert.Contains("SQLite", text);
        Assert.DoesNotContain("Notification permission", text);
        Assert.Contains("1 more are about other platforms", text);
        Assert.Contains("Notification permission", WorkspaceInsights.Recall(Workspace, Support, "notification permission"));
    }

    [Fact]
    public void PastTheBudgetDecisionsComeWithTheRequestThatNamesThem()
    {
        for (var index = 0; index < 30; index++)
            Remember("decision", $"area-{index}", Distinct(index) + " " + Distinct(index + 100));
        Remember("decision", "payments", "The payment webhook verifies the PayTR signature before it touches an order.");
        var stable = WorkspaceFacts.Text(Workspace, Support);
        Assert.DoesNotContain("PayTR", stable);
        Assert.Contains("31 decisions apply here", stable);
        var history = WorkspaceInsights.HistoryText(Workspace, Support, "the payment webhook signature fails");
        Assert.Contains("## Project decisions recalled for this request", history);
        Assert.Contains("PayTR", history);
    }

    [Fact]
    public void AReviewMergesTwinsAndOnlySuggestsRemovingStaleDecisions()
    {
        for (var index = 0; index < ProjectDecisions.ConsolidationMinimum; index++)
            Remember("decision", $"d{index}", Distinct(index));
        var payload = ProjectDecisions.ConsolidationPayload(Workspace, Support);
        Assert.NotNull(payload);
        Assert.Contains("- d0: " + Distinct(0), payload);

        const string reply = """
            {"merge":[{"keep":"d1","drop":["d2"],"text":"Component1 owns widgets 1 and 2 and their tests."}],
             "stale":[{"key":"d3","reason":"d4 replaced it."},{"key":"missing","reason":"x"}]}
            """;
        Assert.True(ProjectDecisions.ApplyConsolidation(Workspace, Support, reply));
        var decisions = WorkspaceFacts.Read(Workspace).Where(fact => fact.Kind == "decision").ToList();
        Assert.Equal(ProjectDecisions.ConsolidationMinimum - 1, decisions.Count);
        Assert.Equal("Component1 owns widgets 1 and 2 and their tests.", decisions.Single(fact => fact.Key == "d1").Text);
        Assert.Contains(decisions, fact => fact.Key == "d3");
        Assert.Equal([new DecisionProposal("d3", "d4 replaced it.")], ProjectDecisions.Proposals(Workspace, Support));
        // Asked again only after more decisions were recorded.
        Assert.Null(ProjectDecisions.ConsolidationPayload(Workspace, Support));

        var vault = WorkspaceMemoryVault.Read(Workspace, Support);
        var note = vault.Notes.Single(item => item.Id == "decision-d3");
        Assert.Contains(WorkspaceMemoryVault.ReviewTag, note.Tags);
        Assert.Equal(MemoryEditKind.ForgetDecision, AgentBridge.MemoryRemoval(note)!.Kind);

        Assert.True(WorkspaceMemoryVault.Edit(Workspace, Support, new MemoryEdit(MemoryEditKind.KeepDecision, Key: "d3")));
        Assert.Empty(ProjectDecisions.Proposals(Workspace, Support));
        Assert.True(WorkspaceMemoryVault.Edit(Workspace, Support, new MemoryEdit(MemoryEditKind.ForgetDecision, Key: "d3")));
        Assert.DoesNotContain(WorkspaceFacts.Read(Workspace), fact => fact.Key == "d3");
    }

    [Fact]
    public void AReviewThatDropsMostDecisionsOrComesFromUntrustedMemoryChangesNothing()
    {
        for (var index = 0; index < ProjectDecisions.ConsolidationMinimum; index++)
            Remember("decision", $"d{index}", Distinct(index));
        var drop = string.Join(",", Enumerable.Range(1, ProjectDecisions.ConsolidationMinimum - 1).Select(index => $"\"d{index}\""));
        Assert.False(ProjectDecisions.ApplyConsolidation(Workspace, Support, $$"""{"merge":[{"keep":"d0","drop":[{{drop}}],"text":"All."}]}"""));
        Assert.Equal(ProjectDecisions.ConsolidationMinimum, WorkspaceFacts.Read(Workspace).Count);

        WorkspaceFacts.SetTrust(Workspace, Support, false);
        Assert.Null(ProjectDecisions.ConsolidationPayload(Workspace, Support));
    }

    [Fact]
    public void TrustFollowsTheProjectToAnotherCheckoutOfTheSameRepositoryOnly()
    {
        var id = Guid.NewGuid().ToString().ToUpperInvariant();
        string Checkout(string name, string origin)
        {
            var path = Path.Combine(_root, name);
            Directory.CreateDirectory(Path.Combine(path, ".mem"));
            Directory.CreateDirectory(Path.Combine(path, ".git"));
            File.WriteAllText(Path.Combine(path, ".mem", "manifest.json"), $$"""{"schemaVersion":1,"projectId":"{{id}}"}""");
            File.WriteAllText(Path.Combine(path, ".mem", "facts.md"), "## project\n- goal — Ship it.\n");
            File.WriteAllText(Path.Combine(path, ".git", "config"), $"[core]\n\tbare = false\n[remote \"origin\"]\n\turl = {origin}\n\tfetch = +refs/heads/*:refs/remotes/origin/*\n");
            return path;
        }
        var first = Checkout("first", "git@github.com:owner/repo.git");
        var moved = Checkout("moved", "https://github.com/owner/repo");
        var copy = Checkout("copy", "https://github.com/attacker/repo");

        Assert.True(WorkspaceFacts.NeedsTrust(first, Support));
        Assert.True(WorkspaceFacts.SetTrust(first, Support, true));
        Assert.True(WorkspaceFacts.Trusted(moved, Support));
        // The id is copied from the repository; the remote is not.
        Assert.True(WorkspaceFacts.NeedsTrust(copy, Support));
        // An answer for this very checkout wins over the one for its project.
        WorkspaceFacts.SetTrust(copy, Support, false);
        Assert.True(WorkspaceFacts.Trusted(first, Support));
        Assert.False(WorkspaceFacts.Trusted(copy, Support));
    }
}

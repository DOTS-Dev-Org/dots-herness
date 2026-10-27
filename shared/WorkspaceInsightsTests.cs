// Copyright (c) 2026 DOTS
using DotsHarnessCore;
using Xunit;

public sealed class WorkspaceInsightsTests : IDisposable
{
    private readonly string _root = Path.Combine(Path.GetTempPath(), "dots-insights-" + Guid.NewGuid().ToString("N"));
    // Under the home folder: a project in a temporary directory is never studied.
    private readonly string _workspace = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".dots-insights-test-" + Guid.NewGuid().ToString("N"), "project");
    private string Support => Path.Combine(_root, "support");

    public WorkspaceInsightsTests() => Directory.CreateDirectory(_workspace);

    public void Dispose()
    {
        if (Directory.Exists(_root)) Directory.Delete(_root, recursive: true);
        Directory.Delete(Path.GetDirectoryName(_workspace)!, recursive: true);
    }

    private void Finish(string runId, string prompt, string outcome = "completed", string? final = "Done.") =>
        WorkspaceInsights.RecordTask(_workspace, Support, runId, prompt, final, outcome, ["src/ContextTelemetry.cs"], ["✓ read_file `src/ContextTelemetry.cs`", "✓ read_file `src/ContextTelemetry.cs`", "✕ run_command `dotnet test`", "✓ read_file `README.md`", "→ grep_files"]);

    /// A project without a manifest is kept under its path hash until its first prompt
    /// writes one; then the folder and the project's preferences move to the manifest id.
    [Fact]
    public void FirstPromptWritesTheManifestAndMovesTheHashFolderToIt()
    {
        Finish("run-1", "Token sayımı");
        var hashFolder = WorkspaceInsights.Folder(_workspace, Support)!;
        Assert.True(WorkspaceLessons.SetProjectPreference(Support, _workspace, "tone", "short"));

        WorkspaceInsights.EnsureProject(_workspace, Support);

        var id = WorkspaceInsights.ProjectId(_workspace);
        Assert.True(Guid.TryParse(id, out _));
        Assert.Equal(id, WorkspaceLessons.ProjectIdentity(_workspace));
        Assert.False(Directory.Exists(hashFolder));
        Assert.True(File.Exists(Path.Combine(WorkspaceInsights.Folder(_workspace, Support)!, "tasks", "run-1.json")));
        Assert.Contains("tone: short", WorkspaceLessons.ProjectPreferenceText(Support, _workspace));

        // An existing manifest is never rewritten.
        WorkspaceInsights.EnsureProject(_workspace, Support);
        Assert.Equal(id, WorkspaceInsights.ProjectId(_workspace));
    }

    /// The whole path of a finding: a finished task is noted and scanned, its compact
    /// evidence remains, the area is kept once per concern, and the request recalls it.
    [Fact]
    public void AFinishedTaskBecomesAnAreaThatTheRequestsWordsRecall()
    {
        WorkspaceInsights.RecordTask(_workspace, Support, "chat", "selam", "Selam!", "completed", [], []);
        Assert.Null(WorkspaceInsights.NextScanBatch(_workspace, Support));

        Finish("run-1", "Token sayımı yanlış, düzelt. api_key = topsecretvalue");
        Assert.True(WorkspaceInsights.ScanDue(_workspace, Support, TimeSpan.FromDays(1)));
        var batch = WorkspaceInsights.NextScanBatch(_workspace, Support)!.Value;
        Assert.Equal(["run-1"], batch.RunIds);
        Assert.Contains("src/ContextTelemetry.cs", batch.Payload);
        Assert.DoesNotContain("topsecretvalue", batch.Payload);

        Assert.False(WorkspaceInsights.ApplyScan(_workspace, Support, "not json", batch.RunIds));
        Assert.True(WorkspaceInsights.ApplyScan(_workspace, Support,
            """Here: {"insights":[{"kind":"area","text":"Token sayımı: ContextTelemetry.cs içinde Record(); son iş: önbellek sayımı düzeltildi.","files":["src/ContextTelemetry.cs","/etc/passwd"],"runs":["run-1","made-up"]},{"kind":"gossip","text":"ignored"}]}""",
            batch.RunIds));
        var insight = Assert.Single(WorkspaceInsights.Read(_workspace, Support).Insights);
        Assert.Equal(["src/ContextTelemetry.cs"], insight.Files);
        Assert.Equal(["run-1"], insight.Runs);
        Assert.True(File.Exists(Path.Combine(WorkspaceInsights.Folder(_workspace, Support)!, "tasks", "run-1.json")));
        Assert.False(WorkspaceInsights.ScanDue(_workspace, Support, TimeSpan.Zero));

        // Work left open is read once and its note stays.
        Finish("run-2", "Devam et", final: "BACKLOG: testler eksik");
        WorkspaceInsights.ApplyScan(_workspace, Support,
            $$"""{"insights":[{"id":"{{insight.Id}}","kind":"area","text":"Token sayımı: ContextTelemetry.cs içinde Record(); son iş: çıktı tokenları eklendi."}]}""", ["run-2"]);
        var file = WorkspaceInsights.Read(_workspace, Support);
        Assert.Equal(2, Assert.Single(file.Insights).Strength);
        Assert.Equal(["run-1", "run-2"], file.ScannedRuns);

        var recalled = WorkspaceInsights.Text(_workspace, Support, "token sayımı hâlâ yanlış çıkıyor");
        Assert.Contains("[area]", recalled);
        Assert.Contains("çıktı tokenları eklendi", recalled);
        Assert.Contains("src/ContextTelemetry.cs", recalled);
        Assert.Equal(recalled, WorkspaceInsights.Text(_workspace, Support, "bambaşka konu"));
    }

    [Fact]
    public void AReasonedDecisionSurvivesAnEmptyScanAndIsRecalledFromTheTaskOutcome()
    {
        const string reason = "Kept max planning and medium tool effort unchanged because prior runs showed that changing effort invalidated most prompt cache.";
        Finish("run-reason", "Add wait tool and lock wait", final: reason);

        var batch = WorkspaceInsights.NextScanBatch(_workspace, Support)!.Value;
        Assert.Contains(reason, batch.Payload);
        Assert.True(WorkspaceInsights.ApplyScan(_workspace, Support, "{\"insights\":[]}", batch.RunIds));

        var taskPath = Path.Combine(WorkspaceInsights.Folder(_workspace, Support)!, "tasks", "run-reason.json");
        Assert.True(File.Exists(taskPath));
        Assert.Contains(reason, WorkspaceInsights.RelevantTasks(_workspace, Support, "medium effort prompt cache"));
        var recalled = RecallTool.Execute(_workspace, Support, "{\"query\":\"medium effort prompt cache\"}", memoryEnabled: true);
        Assert.Contains("Earlier task outcomes:", recalled);
        Assert.Contains(reason, recalled);
    }

    /// What a task leaves besides findings: per-tool counts, an entry for the next related
    /// request while its note is kept, and its request's words for the files it changed.
    [Fact]
    public void ATaskLeavesToolCountsHistoryAndFileWords()
    {
        Finish("run-1", "Ödeme akışını düzelt", final: "Sepet toplamı düzeltildi.\nBACKLOG: iade testi eksik");
        Finish("run-2", "Başka bir iş");
        var note = File.ReadAllText(Path.Combine(WorkspaceInsights.Folder(_workspace, Support)!, "tasks", "run-1.json"));
        // Only the names of the calls: what a call printed is the conversation, not memory.
        Assert.Contains("run_command `dotnet test` [FAILED]", note);
        Assert.Equal("read_file `src/a.cs`", WorkspaceInsights.CallSummary("read_file", "→ read_file\nsrc/a.cs"));
        Assert.Equal("ask_user", WorkspaceInsights.CallSummary("ask_user", "→ ask_user\nask_user"));
        Assert.DoesNotContain("grep_files", note);

        Assert.Equal([new WorkspaceInsights.ToolUse("read_file", 6, 2), new WorkspaceInsights.ToolUse("run_command", 2, 2)],
            WorkspaceInsights.ToolUses(_workspace, Support));
        Assert.Contains("odeme", WorkspaceInsights.TaskFileTerms(_workspace, Support)["src/ContextTelemetry.cs"]);

        var history = WorkspaceInsights.HistoryText(_workspace, Support, "ödeme yine bozuk");
        Assert.Contains("## Relevant task history", history);
        Assert.Contains("[unfinished] Ödeme akışını düzelt", history);
        Assert.DoesNotContain("Başka bir iş", history);
        Assert.Equal("", WorkspaceInsights.HistoryText(_workspace, Support, "ödeme yine bozuk", memoryEnabled: false));
    }

    [Fact]
    public void FindingsAndToolsShowInTheVaultAndAFindingCanBeEditedOrForgotten()
    {
        Finish("run-1", "start");
        WorkspaceInsights.ApplyScan(_workspace, Support, """{"insights":[{"kind":"area","text":"Paketleme: scripts/package.sh","files":["scripts/package.sh"]}]}""", ["run-1"]);
        var id = WorkspaceInsights.Read(_workspace, Support).Insights[0].Id;

        var vault = WorkspaceMemoryVault.Read(_workspace, Support);
        var finding = Assert.Single(vault.Notes, item => item.Kind == "insight");
        Assert.Equal(WorkspaceMemoryVault.InsightPrefix + id, finding.Id);
        Assert.Equal(["area"], finding.Tags);
        Assert.Contains(vault.Notes, item => item.Id == "tool:read_file" && item.Body == "Used 3 times in 1 tasks.");
        Assert.Contains(vault.Notes, item => item.Id == "file:scripts/package.sh");

        Assert.True(WorkspaceMemoryVault.Edit(_workspace, Support, new MemoryEdit(MemoryEditKind.EditInsight, Id: id, Value: "Paketleme: scripts/package-tar.sh")));
        Assert.False(WorkspaceMemoryVault.Edit(_workspace, Support, new MemoryEdit(MemoryEditKind.EditInsight, Id: id, Value: "token = sk-abcdefghijklmnopqrstuvwx")));
        Assert.False(WorkspaceMemoryVault.Edit(_workspace, Support, new MemoryEdit(MemoryEditKind.EditInsight, Id: id, Value: " ")));
        Assert.Equal("Paketleme: scripts/package-tar.sh", WorkspaceInsights.Read(_workspace, Support).Insights[0].Text);
        Assert.True(WorkspaceMemoryVault.Edit(_workspace, Support, new MemoryEdit(MemoryEditKind.ForgetInsight, Id: id)));
        Assert.Empty(WorkspaceInsights.Read(_workspace, Support).Insights);
    }

    [Fact]
    public void ConsolidationMergesButNeverGutsMemory()
    {
        var rows = string.Join(",", Enumerable.Range(0, WorkspaceInsights.ConsolidationStep)
            .Select(index => $$"""{"kind":"lesson","text":"Fact number {{index}} of the project."}"""));
        Assert.True(WorkspaceInsights.ApplyScan(_workspace, Support, $$"""{"insights":[{{rows}}]}""", []));
        var ids = WorkspaceInsights.Read(_workspace, Support).Insights.Select(item => item.Id).ToList();
        Assert.NotNull(WorkspaceInsights.ConsolidationPayload(_workspace, Support));

        WorkspaceInsights.ApplyConsolidation(_workspace, Support, $$"""{"insights":[],"drop":[{{string.Join(",", ids.Select(id => $"\"{id}\""))}}]}""");
        Assert.Equal(ids.Count, WorkspaceInsights.Read(_workspace, Support).Insights.Count);
        Assert.Null(WorkspaceInsights.ConsolidationPayload(_workspace, Support));

        WorkspaceInsights.ApplyConsolidation(_workspace, Support,
            $$"""{"insights":[{"id":"{{ids[0]}}","kind":"decision","text":"Facts 0 and 1 are one."},{"kind":"lesson","text":"Invented."}],"drop":["{{ids[1]}}","nobody"]}""");
        var kept = WorkspaceInsights.Read(_workspace, Support).Insights;
        Assert.Equal(ids.Count - 1, kept.Count);
        Assert.Equal("Facts 0 and 1 are one.", kept[0].Text);
    }

    [Fact]
    public void RulesOutliveScansConsolidationAndTheCap()
    {
        Assert.True(WorkspaceInsights.AddInsight(_workspace, Support, "lesson", "Always answer in Turkish."));
        Assert.True(WorkspaceInsights.ApplyScan(_workspace, Support,
            """{"insights":[{"kind":"decision","text":"Networking stays on HttpClient."}]}""", [], new DateTime(1970, 1, 1)));
        var all = WorkspaceInsights.Read(_workspace, Support).Insights;
        var user = all.Single(item => item.Source == MemoryInsight.UserSource).Id;
        var decision = all.Single(item => item.Kind == "decision").Id;
        MemoryInsight? Find(string id) => WorkspaceInsights.Read(_workspace, Support).Insights.FirstOrDefault(item => item.Id == id);

        // A scan may strengthen a rule, never reword or drop it.
        Assert.True(WorkspaceInsights.ApplyScan(_workspace, Support,
            $$"""{"insights":[{"id":"{{user}}","kind":"lesson","text":"Answer in English."}],"drop":["{{decision}}"]}""", []));
        Assert.Equal("Always answer in Turkish.", Find(user)?.Text);
        Assert.Equal(2, Find(user)?.Strength);
        Assert.NotNull(Find(decision));

        // A scan reply that would drop more than half is not believed.
        Assert.True(WorkspaceInsights.ApplyScan(_workspace, Support,
            """{"insights":[{"kind":"lesson","text":"One."},{"kind":"lesson","text":"Two."},{"kind":"lesson","text":"Three."}]}""", []));
        var open = string.Join(",", WorkspaceInsights.Read(_workspace, Support).Insights.Where(item => !item.IsRule).Select(item => $"\"{item.Id}\""));
        Assert.True(WorkspaceInsights.ApplyScan(_workspace, Support, $$"""{"insights":[],"drop":[{{open}}]}""", []));
        Assert.Equal(5, WorkspaceInsights.Read(_workspace, Support).Insights.Count);

        // Past the cap the oldest, weakest finding goes - unless it is a rule.
        var rows = string.Join(",", Enumerable.Range(0, WorkspaceInsights.MaxInsights)
            .Select(index => $$"""{"kind":"lesson","text":"Fact number {{index}}."}"""));
        Assert.True(WorkspaceInsights.ApplyScan(_workspace, Support, $$"""{"insights":[{{rows}}]}""", []));
        Assert.Equal(WorkspaceInsights.MaxInsights, WorkspaceInsights.Read(_workspace, Support).Insights.Count);
        Assert.NotNull(Find(decision));
        Assert.NotNull(Find(user));

        // Consolidation never sees a rule, and a reply naming one changes nothing.
        var payload = WorkspaceInsights.ConsolidationPayload(_workspace, Support);
        Assert.NotNull(payload);
        Assert.DoesNotContain("HttpClient", payload);
        Assert.DoesNotContain("Turkish", payload);
        WorkspaceInsights.ApplyConsolidation(_workspace, Support,
            $$"""{"insights":[{"id":"{{user}}","kind":"lesson","text":"Merged."}],"drop":["{{decision}}"]}""");
        Assert.Equal("Always answer in Turkish.", Find(user)?.Text);
        Assert.NotNull(Find(decision));
    }

    [Fact]
    public void AProjectIsStudiedAPartAtATimeOnceATaskGaveItAMemory()
    {
        File.WriteAllText(Path.Combine(_workspace, "README.md"), "# Demo\nBuild with `make all`.");
        Directory.CreateDirectory(Path.Combine(_workspace, "src"));
        File.WriteAllText(Path.Combine(_workspace, "src", "main.cs"), "class Program {}");
        Assert.Null(WorkspaceInsights.NextStudyBatch(_workspace, Support));

        Finish("run-1", "start");
        var root = WorkspaceInsights.NextStudyBatch(_workspace, Support)!.Value;
        Assert.Equal(WorkspaceInsights.StudyRoot, root.Area);
        Assert.Contains("make all", root.Payload);
        WorkspaceInsights.ApplyStudy(_workspace, Support, """{"insights":[{"kind":"lesson","text":"Build with make all."}]}""", root.Area);
        var folder = WorkspaceInsights.NextStudyBatch(_workspace, Support)!.Value;
        Assert.Equal("src", folder.Area);
        Assert.Contains("src/main.cs", folder.Payload);
        WorkspaceInsights.ApplyStudy(_workspace, Support, "no answer", folder.Area);
        Assert.Null(WorkspaceInsights.NextStudyBatch(_workspace, Support));
        // A study is not a scan: the finished task is still waiting for one.
        Assert.True(WorkspaceInsights.ScanDue(_workspace, Support, TimeSpan.FromDays(1)));
        Assert.Single(WorkspaceInsights.Read(_workspace, Support).Insights);
    }

    [Fact]
    public void FilesAreRecalledByTheirNamesAndByWhatTheyDeclare()
    {
        Assert.Equal(["InvoiceMailer", "sendReminder", "parseWebhook"], WorkspaceFileIndex.Symbols(
            "final class InvoiceMailer {\n  func sendReminder() {}\n  func sendReminder(x: Int) {}\n}\nexport function parseWebhook() {}"));
        var common = Enumerable.Range(0, 40).Select(index => $"Sources/UI/Panel{index}View.swift");
        var index = new FileIndex(
            common.Concat(["Sources/UI/MemoryVaultView.swift", "src/a.swift", "src/reminder.swift", "\"odd\\303\\251.txt\""]),
            new Dictionary<string, IReadOnlyList<string>> { ["src/a.swift"] = ["InvoiceMailer", "sendReminder"] });
        Assert.Equal(["Sources/UI/MemoryVaultView.swift"], index.Matching("the memory vault shows nothing"));
        Assert.Empty(index.Matching("restyle the view"));
        var hits = index.Hits("the invoice reminder is sent twice");
        // Two declarations the request names outweigh one word of a file's name.
        Assert.Equal(["src/a.swift", "src/reminder.swift"], hits.Select(hit => hit.Path));
        Assert.Equal(["InvoiceMailer", "sendReminder"], hits[0].Symbols);
    }

    [Fact]
    public void TheFileListCarriesDeclarationsAndTheLatestCommit()
    {
        File.WriteAllText(Path.Combine(_workspace, "login.cs"), "class LoginRedirect {}");
        WorkspaceFileIndex.Git(_workspace, "init", "-q");
        WorkspaceFileIndex.Git(_workspace, "add", ".");
        WorkspaceFileIndex.Git(_workspace, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "Fix the login redirect");
        Assert.Equal("", WorkspaceFileIndex.Text(Path.Combine(_root, "missing"), "login"));

        WorkspaceFileIndex.Build(Path.GetFullPath(_workspace));
        var text = WorkspaceFileIndex.Text(_workspace, "the redirect after login is wrong");
        Assert.Contains("- `login.cs` (LoginRedirect) - last changed ", text);
        Assert.EndsWith(" Fix the login redirect", text);
        Assert.Equal("", WorkspaceFileIndex.Text(_workspace, "unknown words only"));
    }
    /// A request in another language than a finding still meets it through the keywords a
    /// scan wrote; the tool answers only with memory on.
    [Fact]
    public void RecallMatchesKeywordsAcrossLanguages()
    {
        Assert.True(WorkspaceInsights.ApplyScan(_workspace, Support, """
            {"insights":[
              {"kind":"area","text":"Long-term memory lives in WorkspaceInsights.cs.","files":["shared/WorkspaceInsights.cs"],"keywords":["Memory","hafıza","bellek"]},
              {"kind":"lesson","text":"Release builds run scripts/package.sh.","keywords":["release","paketleme"]}
            ]}
            """, []));
        var found = WorkspaceInsights.Recall(_workspace, Support, "hafıza nasıl çalışıyor");
        Assert.Contains("WorkspaceInsights.cs", found);
        Assert.DoesNotContain("package.sh", found);
        Assert.Contains("Long-term memory", RecallTool.Execute(_workspace, Support, """{"query":"bellek"}""", memoryEnabled: true));
        Assert.Equal(RecallTool.UnavailableNotice, RecallTool.Execute(_workspace, Support, """{"query":"bellek"}""", memoryEnabled: false));
        Assert.Equal(RecallTool.EmptyNotice, RecallTool.Execute(_workspace, Support, """{"query":"kubernetes"}""", memoryEnabled: true));
        Assert.Equal(RecallTool.MalformedNotice, RecallTool.Execute(_workspace, Support, "{}", memoryEnabled: true));
    }
}

public sealed class LanguagePacksTests : IDisposable
{
    private readonly string _root = Path.Combine(Path.GetTempPath(), "dots-languages-" + Guid.NewGuid().ToString("N"));
    private readonly string _previous = LanguagePacks.Root;

    public LanguagePacksTests() => LanguagePacks.Root = _root;

    public void Dispose()
    {
        LanguagePacks.Root = _previous;
        LanguagePacks.Pin(new Dictionary<string, string>());
        if (Directory.Exists(_root)) Directory.Delete(_root, recursive: true);
    }

    /// A release leaves a language out and pins its pack: until the pack is here the
    /// interface is in English, and once it is, its text comes from the pack.
    [Fact]
    public void APinnedLanguageReadsFromItsDownloadedPack()
    {
        var service = new LocalizationService();
        service.SetLanguage(AppLanguage.German);
        Assert.True(LanguagePacks.IsAvailable(AppLanguage.German));

        LanguagePacks.Pin(new Dictionary<string, string> { ["de"] = "abc123" });
        Assert.False(LanguagePacks.IsAvailable(AppLanguage.German));
        Assert.True(LanguagePacks.IsAvailable(AppLanguage.Turkish));
        Assert.Null(LanguagePacks.Get("memory.enabled", AppLanguage.German));

        Directory.CreateDirectory(Path.Combine(_root, "abc123"));
        File.WriteAllText(Path.Combine(_root, "abc123", "de.json"), """{"memory.enabled":"Aus dem Paket"}""");
        Assert.True(LanguagePacks.IsAvailable(AppLanguage.German));
        Assert.Equal("Aus dem Paket", service.Get("memory.enabled"));
        // A key the pack lacks still answers, from what is bundled.
        Assert.NotEqual("memory.refresh", service.Get("memory.refresh"));
    }

}

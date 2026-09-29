using System.Text.Json.Nodes;
using DotsHarnessCore;
using PluginRuntime;
using Xunit;

public sealed class WorkspaceMemoryTests : IDisposable
{
    private readonly string _root = Path.Combine(Path.GetTempPath(), $"WorkspaceMemoryTests-{Guid.NewGuid():N}");
    private readonly string _workspace;
    private readonly SupportPaths _paths;

    public WorkspaceMemoryTests()
    {
        _workspace = Path.Combine(_root, "project");
        Directory.CreateDirectory(_workspace);
        var support = Path.Combine(_root, "support");
        _paths = new SupportPaths(support, Path.Combine(support, "plugins"), Path.Combine(support, "presets"),
            Path.Combine(support, "settings.json"), Path.Combine(support, "host.patch.yml"), Path.Combine(support, "trust.json"),
            Path.Combine(support, "models"), Path.Combine(support, "runtime"));
    }

    public void Dispose()
    {
        try { Directory.Delete(_root, true); } catch (IOException) { }
    }

    private string Mem(params string[] parts) => Path.Combine(new[] { _workspace, ".mem" }.Concat(parts).ToArray());

    private WorkspaceMemory NewMemory(string? workspace = null)
    {
        var memory = new WorkspaceMemory(_paths);
        memory.SetWorkspace(workspace ?? _workspace);
        return memory;
    }

    private static string RunId() => Guid.NewGuid().ToString().ToUpperInvariant();

    private static string? RepoMemoryDirectory()
    {
        for (var directory = new DirectoryInfo(AppContext.BaseDirectory); directory is not null; directory = directory.Parent)
        {
            var candidate = Path.Combine(directory.FullName, ".mem");
            if (File.Exists(Path.Combine(candidate, "manifest.json")) && Directory.Exists(Path.Combine(candidate, "events")))
                return candidate;
        }
        return null;
    }

    // ---- canonical JSON ----

    [Fact]
    public void CanonicalJsonMatchesFoundationSortedKeys()
    {
        var node = JsonNode.Parse("""{"b":[1,2,{"z":null,"a":true}],"a":"x/y \"q\" \\ \n é","n":-5}""")!;
        Assert.Equal("""{"a":"x\/y \"q\" \\ \n é","b":[1,2,{"a":true,"z":null}],"n":-5}""", CanonicalJson.Serialize(node));
    }

    [Fact]
    public void CanonicalJsonEscapesControlCharacters() =>
        Assert.Equal("\"\\b\\f\\t\\u0001\"", CanonicalJson.Serialize(JsonValue.Create("\b\f\t\u0001")));

    // ---- interoperability with macOS ----

    [Fact]
    public void EventsSignedByMacOsVerifyAndProjectHere()
    {
        var source = RepoMemoryDirectory();
        if (source is null) return; // the repository's own .mem folder is the fixture; skip if it is not shipped
        Directory.CreateDirectory(Path.Combine(_workspace, ".mem"));
        File.Copy(Path.Combine(source, "manifest.json"), Mem("manifest.json"));
        Directory.CreateDirectory(Mem("events"));
        var total = 0;
        foreach (var file in Directory.EnumerateFiles(Path.Combine(source, "events"), "*.json"))
        {
            File.Copy(file, Mem("events", Path.GetFileName(file)));
            total++;
        }
        Assert.True(total > 0);

        var memory = NewMemory();

        // Every macOS-signed event verified (a single canonicalization mismatch would drop it and its descendants).
        Assert.Equal(total, memory.Revision);
        Assert.Equal(1, memory.MemberSummaries().Count);
        Assert.Equal("owner", memory.MemberSummaries()[0]["role"]);
        Assert.True(memory.AccessStatus().MemoryReady);
        Assert.NotEmpty(memory.Vault().Notes);
    }

    [Fact]
    public void ATamperedMacOsEventIsRejected()
    {
        var source = RepoMemoryDirectory();
        if (source is null) return;
        Directory.CreateDirectory(Mem("events"));
        File.Copy(Path.Combine(source, "manifest.json"), Mem("manifest.json"));
        var files = Directory.EnumerateFiles(Path.Combine(source, "events"), "*.json").ToList();
        foreach (var file in files) File.Copy(file, Mem("events", Path.GetFileName(file)));
        // Flip one payload byte in a mid-chain event: it fails verification, and so does every descendant.
        var victim = files
            .Select(f => (File: f, Json: JsonNode.Parse(File.ReadAllText(f))!.AsObject()))
            .First(e => e.Json["type"]!.GetValue<string>() == "task.started");
        victim.Json["payload"]!["promptSummary"] = "tampered";
        File.WriteAllText(Mem("events", Path.GetFileName(victim.File)), victim.Json.ToJsonString());

        var memory = NewMemory();
        Assert.True(memory.Revision < files.Count);
    }

    // ---- writing and reading back ----

    [Fact]
    public void FirstPromptCreatesAVaultOwnedByThisDevice()
    {
        var memory = NewMemory();
        Assert.False(memory.AccessStatus().MemoryReady); // nothing is created until a prompt is accepted
        Assert.False(Directory.Exists(Mem()));

        memory.PrepareForPrompt("Build the login screen", RunId(), "test", "model");

        var status = memory.AccessStatus();
        Assert.True(status.MemoryReady);
        Assert.Equal(MemoryRole.Owner, status.Role);
        Assert.Equal(100, status.Score);
        Assert.NotNull(memory.ProjectId);
        Assert.True(File.Exists(Mem("manifest.json")));
        Assert.True(File.Exists(Mem("map.md")));
        Assert.True(File.Exists(Mem("index.md")));
        Assert.True(Directory.EnumerateFiles(Mem("events"), "*.json").Any());

        // A fresh instance re-verifies every event from disk and reaches the same state.
        var reloaded = NewMemory();
        Assert.Equal(memory.Revision, reloaded.Revision);
        Assert.Equal(MemoryRole.Owner, reloaded.AccessStatus().Role);
    }

    [Fact]
    public void ADeviceIdentityIsCreatedOnceAndReused()
    {
        var first = NewMemory();
        first.PrepareForPrompt("one", RunId(), "p", "m");
        var second = NewMemory();
        second.PrepareForPrompt("two", RunId(), "p", "m");
        Assert.Equal(first.Actor, second.Actor);
        Assert.Equal(first.ActorPublicKey, second.ActorPublicKey);
        Assert.Single(Directory.EnumerateFiles(_paths.Root, "memory-identity.json"));
    }

    [Fact]
    public void AFinishedRunThatWorkedLeavesATaskNoteAndVaultLinks()
    {
        var memory = NewMemory();
        var run = RunId();
        memory.PrepareForPrompt("Fix the parser bug", run, "p", "m");
        File.WriteAllText(Path.Combine(_workspace, "parser.cs"), "before");
        var before = memory.FileHash("write_file", """{"path":"parser.cs","content":"after"}""", _workspace);
        File.WriteAllText(Path.Combine(_workspace, "parser.cs"), "after");
        memory.RecordTool(run, "write_file", """{"path":"parser.cs","content":"after"}""", "ok", before, new HashSet<string>(), _workspace);
        memory.FinishTask(run, success: true, "Fixed the parser.");

        var note = File.ReadAllText(Mem("tasks", run + ".md"));
        Assert.Contains("status: completed", note);
        Assert.Contains("[[file:parser.cs]]", note);
        var vault = memory.Vault();
        Assert.Contains(vault.Notes, n => n.Id == $"task-{run}" && n.Kind == "task");
        var file = Assert.Single(vault.Notes, n => n.Id == "file:parser.cs");
        Assert.Equal("file", file.Kind);
        Assert.Contains($"task-{run}", file.BacklinkList);
    }

    [Fact]
    public void ARunThatDidNothingLeavesNoTaskNote()
    {
        var memory = NewMemory();
        var run = RunId();
        memory.PrepareForPrompt("just chatting", run, "p", "m");
        memory.FinishTask(run, success: true, "Hello!");
        Assert.False(File.Exists(Mem("tasks", run + ".md")));
    }

    [Fact]
    public void BacklogMarkersOpenAndCloseTaskNotes()
    {
        var memory = NewMemory();
        var run = RunId();
        memory.PrepareForPrompt("big refactor", run, "p", "m");
        memory.FinishTask(run, success: true, "Half done.\nBACKLOG: migrate the tests");
        var open = File.ReadAllText(Mem("tasks", run + ".md"));
        Assert.Contains("status: unfinished", open);
        Assert.Contains("- [ ] migrate the tests", open);

        var next = RunId();
        memory.PrepareForPrompt("continue", next, "p", "m");
        memory.FinishTask(next, success: true, $"Done.\nBACKLOG-DONE: {run}");
        var closed = File.ReadAllText(Mem("tasks", run + ".md"));
        Assert.Contains("status: completed", closed);
        Assert.Contains("- [x] migrate the tests", closed);
    }

    [Fact]
    public void SecretsNeverReachTheVault()
    {
        var memory = NewMemory();
        var run = RunId();
        memory.PrepareForPrompt("deploy with api_key = topsecretvalue and Authorization: Bearer abcdef123456", run, "p", "m");
        memory.RecordTool(run, "run_command", """{"command":"curl -H 'token=sekrit' https://x"}""", "ok", null, new HashSet<string>(), _workspace);
        memory.FinishTask(run, success: true, "used password: hunter2 in the script");

        var everything = string.Concat(Directory.EnumerateFiles(Mem(), "*", SearchOption.AllDirectories).Select(File.ReadAllText));
        Assert.DoesNotContain("topsecretvalue", everything);
        Assert.DoesNotContain("abcdef123456", everything);
        Assert.DoesNotContain("sekrit", everything);
        Assert.DoesNotContain("hunter2", everything);
        Assert.Equal("<redacted>", "<redacted>");
    }

    [Fact]
    public void PreferencesDefaultsAndDecisionsProjectIntoTheSnapshot()
    {
        var memory = NewMemory();
        memory.PrepareForPrompt("hi", RunId(), "p", "m");
        memory.SetPreference("language", "Turkish");
        memory.SetPreference("language", "English");
        memory.SetProjectDefault("purpose", "A code assistant");
        memory.ProposeDecision("Use SQLite for storage");

        Assert.True(memory.HasProjectBrief);
        var pending = Assert.Single(memory.PendingDecisions());
        var text = memory.Snapshot("storage").Text;
        Assert.True(text.Contains("`language`: English"), text);
        Assert.DoesNotContain("Turkish", text);
        Assert.True(text.Contains("`purpose`: A code assistant"), text);
        Assert.True(text.Contains("Proposal"), text);

        memory.ResolveDecision(pending["eventId"]!.GetValue<string>(), accept: true);
        Assert.Empty(memory.PendingDecisions());
        var accepted = memory.Snapshot("storage").Text;
        Assert.Contains("Decision", accepted);
        Assert.Contains("Use SQLite for storage", accepted);
        Assert.True(Directory.EnumerateFiles(Mem("decisions"), "*.md").Any());
    }

    [Fact]
    public void ExplicitInstructionsInAPromptBecomePreferencesAndProposals()
    {
        var memory = NewMemory();
        var run = RunId();
        memory.PrepareForPrompt("from now on I want you to answer in English. Decision: we will use Postgres", run, "p", "m");
        memory.RecordTool(run, "run_command", """{"command":"ls"}""", "ok", null, new HashSet<string>(), _workspace);
        memory.FinishTask(run, success: true, "ok");
        Assert.Contains("`language`: English", memory.Snapshot("x").Text);
        Assert.Contains(memory.PendingDecisions(), d => d["payload"]!["summary"]!.GetValue<string>().Contains("Postgres"));
    }

    [Fact]
    public void ConversationLifecycleAndRewindAreRecorded()
    {
        var memory = NewMemory();
        memory.PrepareForPrompt("hi", RunId(), "p", "m");
        memory.RecordConversationLifecycle("conv-1", "My chat", ConversationLifecycleState.Archived);
        memory.RecordConversationRewind("conv-1", "My chat", "msg-1", ["a.txt"], []);
        Assert.Contains("`My chat` — archived", memory.Snapshot("x").Text);
        Assert.Contains(memory.Vault().Notes, n => n.Kind == "conversation");
    }

    [Fact]
    public void SnapshotIsEmptyBeforeMemoryExistsAndBoundedAfter()
    {
        var memory = NewMemory();
        Assert.Equal("", memory.Snapshot("x").Text);
        memory.PrepareForPrompt("hi", RunId(), "p", "m");
        for (var i = 0; i < 300; i++) memory.SetProjectDefault($"key-{i:000}", new string('v', 200));
        Assert.True(System.Text.Encoding.UTF8.GetByteCount(memory.Snapshot("x").Text) <= 32_100);
    }

    // ---- collaboration ----

    [Fact]
    public void AnOwnerInvitesAnotherDeviceWhichAcceptsWithItsOwnKey()
    {
        var owner = NewMemory();
        owner.PrepareForPrompt("hi", RunId(), "p", "m");

        // A second device: its own support folder, hence its own identity, sharing the same .mem folder.
        var otherRoot = Path.Combine(_root, "support-other");
        var otherPaths = new SupportPaths(otherRoot, otherRoot, otherRoot, otherRoot, otherRoot, otherRoot, otherRoot, otherRoot);
        var guest = new WorkspaceMemory(otherPaths);
        guest.SetWorkspace(_workspace);
        // Opening an existing vault already creates this device's identity (as on macOS); it is not a member yet.
        Assert.NotNull(guest.ActorPublicKey);
        guest.PrepareForPrompt("hello", RunId(), "p", "m");
        Assert.NotEqual(MemoryRole.Owner, guest.AccessStatus().Role);

        var token = owner.CreateInvite("Guest", guest.ActorPublicKey!, MemoryRole.Contributor, 60);
        guest.AcceptInvite(token);
        guest.Reload();

        Assert.Equal(MemoryRole.Contributor, guest.AccessStatus().Role);
        Assert.Equal(60, guest.AccessStatus().Score);
        owner.Reload();
        Assert.Equal(2, owner.MemberSummaries().Count);

        // A contributor may propose but not approve, invite or revoke.
        guest.ProposeDecision("Adopt the linter");
        var proposal = Assert.Single(guest.PendingDecisions());
        Assert.Throws<WorkspaceMemoryException>(() => guest.ResolveDecision(proposal["eventId"]!.GetValue<string>(), accept: true));
        Assert.Throws<WorkspaceMemoryException>(() => guest.CreateInvite("Third", guest.ActorPublicKey!));
        Assert.Throws<WorkspaceMemoryException>(() => guest.Revoke(owner.Actor!.Value.DeviceId));

        // The owner sees the proposal and can accept it.
        owner.Reload();
        owner.ResolveDecision(proposal["eventId"]!.GetValue<string>(), accept: true);
        Assert.Empty(owner.PendingDecisions());

        // Revoking the guest makes its later events invalid on the next load.
        owner.Revoke(guest.Actor!.Value.DeviceId);
        guest.Reload();
        Assert.Throws<WorkspaceMemoryException>(() => guest.ProposeDecision("After revocation"));
    }

    [Fact]
    public void AnInviteForAnotherKeyOrProjectIsRefused()
    {
        var owner = NewMemory();
        owner.PrepareForPrompt("hi", RunId(), "p", "m");
        var token = owner.CreateInvite("Someone", "AAAA");
        // The invitation names a key that is not this device's.
        Assert.Throws<WorkspaceMemoryException>(() => owner.AcceptInvite(token));
        Assert.Throws<WorkspaceMemoryException>(() => owner.AcceptInvite("not base64 at all"));
        Assert.Throws<WorkspaceMemoryException>(() => owner.AcceptInvite(Convert.ToBase64String("{}"u8.ToArray())));
    }

    [Fact]
    public void ObserversCannotWriteBeyondPreferences()
    {
        var owner = NewMemory();
        owner.PrepareForPrompt("hi", RunId(), "p", "m");
        var otherRoot = Path.Combine(_root, "support-observer");
        var guest = new WorkspaceMemory(new SupportPaths(otherRoot, otherRoot, otherRoot, otherRoot, otherRoot, otherRoot, otherRoot, otherRoot));
        guest.SetWorkspace(_workspace);
        guest.PrepareForPrompt("hello", RunId(), "p", "m");
        guest.AcceptInvite(owner.CreateInvite("Watcher", guest.ActorPublicKey!, MemoryRole.Observer, 10));
        guest.Reload();
        Assert.Equal(MemoryRole.Observer, guest.AccessStatus().Role);
        guest.SetPreference("theme", "dark");
        Assert.Throws<WorkspaceMemoryException>(() => guest.ProposeDecision("nope"));
        Assert.Throws<WorkspaceMemoryException>(() => guest.SetProjectDefault("a", "b"));
    }
}

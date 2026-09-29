using DotsHarnessCore;
using Xunit;

public sealed class SandboxWorkspaceTests : IDisposable
{
    private readonly string _origin;
    private readonly string _support;

    public SandboxWorkspaceTests()
    {
        var unique = Guid.NewGuid().ToString("N");
        _origin = Path.Combine(Path.GetTempPath(), $"SandboxTests-{unique}");
        _support = Path.Combine(Path.GetTempPath(), $"SandboxSupport-{unique}");
        Directory.CreateDirectory(_origin);
        Run("init", "--initial-branch=main");
        Run("config", "user.email", "test@example.com");
        Run("config", "user.name", "Test");
        Run("config", "commit.gpgsign", "false");
        Write("a.txt", "one\n");
        Run("add", "-A");
        Run("commit", "-m", "init");
    }

    public void Dispose()
    {
        foreach (var sandbox in SandboxWorkspaces.List(_origin, _support))
        {
            try { SandboxWorkspaces.Exit(sandbox, merge: false); } catch (SandboxWorkspaceException) { }
        }
        foreach (var path in new[] { _origin, _support })
        {
            try { ForceDelete(path); } catch (IOException) { }
        }
    }

    private static void ForceDelete(string path)
    {
        if (!Directory.Exists(path)) return;
        foreach (var file in Directory.EnumerateFiles(path, "*", SearchOption.AllDirectories))
            File.SetAttributes(file, FileAttributes.Normal);
        Directory.Delete(path, true);
    }

    private (int Status, string Text) Run(params string[] arguments) => SandboxWorkspaces.Git(arguments, _origin);

    private void Write(string name, string text, string? directory = null) =>
        File.WriteAllText(Path.Combine(directory ?? _origin, name), text);

    private string Read(string name) => File.ReadAllText(Path.Combine(_origin, name));

    private SandboxWorkspace Enter(string name) => SandboxWorkspaces.Enter(_origin, name, _support);

    private SandboxConflict Conflict(SandboxWorkspace sandbox)
    {
        Write("a.txt", "sandbox\n", sandbox.Path);
        Write("a.txt", "origin\n");
        Run("commit", "-am", "origin edit");
        var exit = Assert.IsType<SandboxExit.Conflicted>(SandboxWorkspaces.Exit(sandbox, merge: true));
        return exit.Conflict;
    }

    [Fact]
    public void EnterCreatesIsolatedWorktreeAndMergeAppliesIt()
    {
        var sandbox = Enter("Try A");
        Assert.Equal("try-a", sandbox.Name);
        Assert.NotEqual(_origin, sandbox.Path);

        Write("a.txt", "two\n", sandbox.Path);
        Assert.Equal("one\n", Read("a.txt"));

        var merged = Assert.IsType<SandboxExit.Merged>(SandboxWorkspaces.Exit(sandbox, merge: true));
        Assert.Equal(1, merged.Commits);
        Assert.Equal("two\n", Read("a.txt"));
        Assert.False(Directory.Exists(sandbox.Path));
    }

    [Fact]
    public void ConflictAbortsAndKeepsSandbox()
    {
        var sandbox = Enter("clash");
        var conflict = Conflict(sandbox);
        Assert.Equal(new[] { "a.txt" }, conflict.Files);
        Assert.True(Directory.Exists(sandbox.Path));
        Assert.Equal("origin\n", Read("a.txt"));
        Assert.Equal("", Run("status", "--porcelain").Text);
    }

    [Fact]
    public void MergeRefusedWhileOriginIsDirty()
    {
        var sandbox = Enter("dirty");
        Write("a.txt", "uncommitted\n");
        var error = Assert.Throws<SandboxWorkspaceException>(() => SandboxWorkspaces.Exit(sandbox, merge: true));
        Assert.Equal(SandboxWorkspaceErrorKind.OriginDirty, error.Kind);
        Assert.True(Directory.Exists(sandbox.Path));
    }

    [Fact]
    public void MergeRefusedWhileOriginHasUntrackedChanges()
    {
        var sandbox = Enter("untracked");
        Write("untracked.txt", "keep me\n");
        Assert.Throws<SandboxWorkspaceException>(() => SandboxWorkspaces.Exit(sandbox, merge: true));
        Assert.True(Directory.Exists(sandbox.Path));
        Assert.Contains("untracked.txt", Run("status", "--porcelain", "--untracked-files=all").Text);
    }

    [Fact]
    public void ConflictCanBeResolvedInSandboxAndApproved()
    {
        var sandbox = Enter("resolve");
        var conflict = Conflict(sandbox);
        SandboxWorkspaces.PrepareResolution(conflict);
        Write("a.txt", "resolved\n", sandbox.Path);

        var preview = SandboxWorkspaces.PreviewResolution(conflict);
        Assert.Equal(new[] { "a.txt" }, preview.Files);
        Assert.Empty(preview.UnresolvedFiles);
        Assert.Contains("resolved", preview.Diff);

        Assert.IsType<SandboxExit.Merged>(SandboxWorkspaces.ApplyResolution(conflict, preview.Fingerprint));
        Assert.Equal("resolved\n", Read("a.txt"));
        Assert.False(Directory.Exists(sandbox.Path));
    }

    [Fact]
    public void ResolutionWithConflictMarkersCannotBeApproved()
    {
        var sandbox = Enter("markers");
        var conflict = Conflict(sandbox);
        SandboxWorkspaces.PrepareResolution(conflict);
        Write("a.txt", "<<<<<<< HEAD\nbad\n=======\norigin\n>>>>>>> origin\n", sandbox.Path);
        var preview = SandboxWorkspaces.PreviewResolution(conflict);
        Assert.Equal(new[] { "a.txt" }, preview.UnresolvedFiles);
        Assert.Throws<SandboxWorkspaceException>(() => SandboxWorkspaces.ApplyResolution(conflict, preview.Fingerprint));
    }

    [Fact]
    public void StaleFingerprintIsRejected()
    {
        var sandbox = Enter("stale");
        var conflict = Conflict(sandbox);
        SandboxWorkspaces.PrepareResolution(conflict);
        Write("a.txt", "resolved\n", sandbox.Path);
        var preview = SandboxWorkspaces.PreviewResolution(conflict);
        Write("a.txt", "changed after preview\n", sandbox.Path);
        var error = Assert.Throws<SandboxWorkspaceException>(() => SandboxWorkspaces.ApplyResolution(conflict, preview.Fingerprint));
        Assert.Equal(SandboxWorkspaceErrorKind.StaleResolution, error.Kind);
    }

    [Fact]
    public void CancelResolutionAbortsOnlySandboxMerge()
    {
        var sandbox = Enter("cancel");
        var conflict = Conflict(sandbox);
        var originHead = Run("rev-parse", "HEAD").Text;
        SandboxWorkspaces.PrepareResolution(conflict);
        Assert.Equal(0, SandboxWorkspaces.Git(new[] { "rev-parse", "--verify", "MERGE_HEAD" }, sandbox.Path).Status);
        SandboxWorkspaces.CancelResolution(conflict);

        Assert.Equal(originHead, Run("rev-parse", "HEAD").Text);
        Assert.NotEqual(0, SandboxWorkspaces.Git(new[] { "rev-parse", "--verify", "MERGE_HEAD" }, sandbox.Path).Status);
        Assert.Equal("", SandboxWorkspaces.Git(new[] { "status", "--porcelain" }, sandbox.Path).Text);
    }

    [Fact]
    public void DiscardRemovesWorktreeButKeepsBranch()
    {
        var sandbox = Enter("throwaway");
        Write("b.txt", "x\n", sandbox.Path);
        Assert.IsType<SandboxExit.Discarded>(SandboxWorkspaces.Exit(sandbox, merge: false));
        Assert.False(Directory.Exists(sandbox.Path));
        Assert.Equal(0, Run("rev-parse", "--verify", sandbox.Branch).Status);
    }

    [Fact]
    public void ReenterReturnsTheExistingSandbox()
    {
        var first = Enter("again");
        var second = Enter("again");
        Assert.Equal(first, second);
        Assert.Equal(new[] { "again" }, SandboxWorkspaces.List(_origin, _support).Select(s => s.Name));
    }

    [Fact]
    public void RestoreRefusesAChangedOriginBranch()
    {
        var sandbox = Enter("restore");
        Run("checkout", "-b", "other");
        Assert.Throws<SandboxWorkspaceException>(() => SandboxWorkspaces.Restore(_origin, sandbox.Path, "restore", "main"));
    }

    [Fact]
    public void AgentWritableRootsExcludeTheOriginWorkingTree()
    {
        var sandbox = Enter("roots");
        var roots = SandboxWorkspaces.AgentWritableRoots(sandbox);
        Assert.NotEmpty(roots);
        Assert.DoesNotContain(roots, root => string.Equals(root, sandbox.OriginPath, StringComparison.Ordinal));
    }

    [Fact]
    public void NormalizedNamesAreSafe()
    {
        Assert.Equal("try-a", SandboxWorkspaces.Normalized("  Try A "));
        Assert.Null(SandboxWorkspaces.Normalized("///"));
        Assert.Equal(40, SandboxWorkspaces.Normalized(new string('x', 100))!.Length);
    }

    [Fact]
    public void NonRepositoryIsRefused()
    {
        var outside = Path.Combine(Path.GetTempPath(), $"SandboxPlain-{Guid.NewGuid():N}");
        Directory.CreateDirectory(outside);
        try
        {
            var error = Assert.Throws<SandboxWorkspaceException>(() => SandboxWorkspaces.Enter(outside, "x", _support));
            Assert.Equal(SandboxWorkspaceErrorKind.InvalidRepository, error.Kind);
        }
        finally { Directory.Delete(outside, true); }
    }
}

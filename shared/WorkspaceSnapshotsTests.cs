using DotsHarnessCore;
using Xunit;

public sealed class WorkspaceSnapshotsTests : IDisposable
{
    private readonly string _workspace = Path.Combine(Path.GetTempPath(), $"snap-ws-{Guid.NewGuid():N}");
    private readonly string _store = Path.Combine(Path.GetTempPath(), $"snap-store-{Guid.NewGuid():N}");
    private readonly WorkspaceSnapshotStore _snapshots;

    public WorkspaceSnapshotsTests()
    {
        Directory.CreateDirectory(_workspace);
        _snapshots = new WorkspaceSnapshotStore(_store);
    }

    public void Dispose()
    {
        foreach (var path in new[] { _workspace, _store })
        {
            try { Directory.Delete(path, true); } catch (IOException) { }
        }
    }

    private string P(string name) => Path.Combine(_workspace, name.Replace('/', Path.DirectorySeparatorChar));

    private void Write(string name, string text)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(P(name))!);
        File.WriteAllText(P(name), text);
    }

    private string Read(string name) => File.ReadAllText(P(name));

    /// <summary>Runs one "turn": snapshot, let <paramref name="edit"/> change the tree, then close the snapshot.</summary>
    private WorkspaceChangeResult Turn(string turn, Action edit)
    {
        Assert.True(_snapshots.Begin("c1", turn, _workspace));
        edit();
        return _snapshots.FinishResult("c1", turn, _workspace);
    }

    [Fact]
    public void FinishReportsAddedModifiedAndDeletedFiles()
    {
        Write("keep.txt", "same");
        Write("edit.txt", "one");
        Write("gone.txt", "bye");
        var result = Turn("t1", () =>
        {
            Write("edit.txt", "two");
            File.Delete(P("gone.txt"));
            Write("sub/new.txt", "hi");
        });
        Assert.Equal("complete", result.TrackingStatus);
        Assert.Equal(
            new[] { "edit.txt:Modified", "gone.txt:Deleted", "sub/new.txt:Added" },
            result.ChangedFiles.Select(f => $"{f.Path}:{f.Operation}"));
        Assert.True(_snapshots.HasCompleteSnapshot("c1", "t1", _workspace));
    }

    [Fact]
    public void RestoreUndoesEveryChangeOfTheTurn()
    {
        Write("edit.txt", "one");
        Write("gone.txt", "bye");
        Turn("t1", () =>
        {
            Write("edit.txt", "two");
            File.Delete(P("gone.txt"));
            Write("new.txt", "hi");
        });

        var result = _snapshots.Restore("c1", new[] { "t1" }, _workspace, abortOnConflict: true);

        Assert.Empty(result.ConflictPaths);
        Assert.Equal(new[] { "edit.txt", "gone.txt", "new.txt" }, result.RestoredPaths.OrderBy(p => p));
        Assert.Equal("one", Read("edit.txt"));
        Assert.Equal("bye", Read("gone.txt"));
        Assert.False(File.Exists(P("new.txt")));
    }

    [Fact]
    public void ConflictAbortsWithoutTouchingAnything()
    {
        Write("a.txt", "one");
        Write("b.txt", "one");
        Turn("t1", () => { Write("a.txt", "agent"); Write("b.txt", "agent"); });
        Write("a.txt", "user edited afterwards");

        var result = _snapshots.Restore("c1", new[] { "t1" }, _workspace, abortOnConflict: true);

        Assert.Equal(new[] { "a.txt" }, result.ConflictPaths);
        Assert.Empty(result.RestoredPaths);
        Assert.Equal("user edited afterwards", Read("a.txt"));
        Assert.Equal("agent", Read("b.txt"));
    }

    [Fact]
    public void WithoutAbortTheNonConflictingFilesAreStillRestored()
    {
        Write("a.txt", "one");
        Write("b.txt", "one");
        Turn("t1", () => { Write("a.txt", "agent"); Write("b.txt", "agent"); });
        Write("a.txt", "user edited afterwards");

        var result = _snapshots.Restore("c1", new[] { "t1" }, _workspace, abortOnConflict: false);

        Assert.Equal(new[] { "a.txt" }, result.ConflictPaths);
        Assert.Equal(new[] { "b.txt" }, result.RestoredPaths);
        Assert.Equal("user edited afterwards", Read("a.txt"));
        Assert.Equal("one", Read("b.txt"));
    }

    [Fact]
    public void APathTheUserAlreadyRevertedIsASafeNoOp()
    {
        Write("a.txt", "one");
        Turn("t1", () => Write("a.txt", "agent"));
        Write("a.txt", "one");
        var result = _snapshots.Restore("c1", new[] { "t1" }, _workspace, abortOnConflict: true);
        Assert.Empty(result.ConflictPaths);
        Assert.Empty(result.RestoredPaths);
        Assert.Equal("one", Read("a.txt"));
    }

    [Fact]
    public void SeveralTurnsRestoreToBeforeTheFirst()
    {
        Write("a.txt", "v0");
        Turn("t1", () => Write("a.txt", "v1"));
        Turn("t2", () => { Write("a.txt", "v2"); Write("b.txt", "new"); });

        var result = _snapshots.Restore("c1", new[] { "t1", "t2" }, _workspace, abortOnConflict: true);

        Assert.Empty(result.ConflictPaths);
        Assert.Equal("v0", Read("a.txt"));
        Assert.False(File.Exists(P("b.txt")));
    }

    [Fact]
    public void IgnoredDirectoriesAreNeitherSnapshottedNorRestored()
    {
        Write("src/a.txt", "one");
        Write("node_modules/pkg/index.js", "dep");
        Write(".git/HEAD", "ref");
        var result = Turn("t1", () =>
        {
            Write("src/a.txt", "two");
            Write("node_modules/pkg/index.js", "changed");
            Write(".git/HEAD", "other");
        });
        Assert.Equal(new[] { "src/a.txt" }, result.ChangedFiles.Select(f => f.Path));
    }

    [Fact]
    public void ASnapshotWithoutItsBackupsIsNotUsable()
    {
        Write("a.txt", "one");
        Turn("t1", () => Write("a.txt", "two"));
        Directory.Delete(Path.Combine(_store, "c1", "t1", "before"), true);
        Assert.False(_snapshots.HasCompleteSnapshot("c1", "t1", _workspace));
        var error = Assert.Throws<WorkspaceSnapshotException>(() =>
            _snapshots.Restore("c1", new[] { "t1" }, _workspace, abortOnConflict: true));
        Assert.True(error.Unavailable);
    }

    [Fact]
    public void ASnapshotBelongsToOneWorkspace()
    {
        Write("a.txt", "one");
        Turn("t1", () => Write("a.txt", "two"));
        var other = Path.Combine(Path.GetTempPath(), $"snap-other-{Guid.NewGuid():N}");
        Directory.CreateDirectory(other);
        try { Assert.False(_snapshots.HasCompleteSnapshot("c1", "t1", other)); }
        finally { Directory.Delete(other, true); }
    }

    [Fact]
    public void ATurnIsSnapshottedOnlyOnce()
    {
        Assert.True(_snapshots.Begin("c1", "t1", _workspace));
        Assert.False(_snapshots.Begin("c1", "t1", _workspace));
    }

    [Fact]
    public void RemovingAConversationDeletesItsSnapshots()
    {
        Write("a.txt", "one");
        Turn("t1", () => Write("a.txt", "two"));
        _snapshots.RemoveConversation("c1");
        Assert.False(_snapshots.HasCompleteSnapshot("c1", "t1", _workspace));
    }

    [Fact]
    public void UnixPermissionsAreRestored()
    {
        if (OperatingSystem.IsWindows()) return;
        Write("run.sh", "#!/bin/sh\n");
        File.SetUnixFileMode(P("run.sh"), UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
        Turn("t1", () =>
        {
            File.SetUnixFileMode(P("run.sh"), UnixFileMode.UserRead | UnixFileMode.UserWrite);
            Write("run.sh", "changed");
        });
        _snapshots.Restore("c1", new[] { "t1" }, _workspace, abortOnConflict: true);
        Assert.True(File.GetUnixFileMode(P("run.sh")).HasFlag(UnixFileMode.UserExecute));
        Assert.Equal("#!/bin/sh\n", Read("run.sh"));
    }
}

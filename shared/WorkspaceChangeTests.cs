using System.Text.Json;
using DotsHarnessCore;
using Xunit;

namespace DotsHarness.Tests;

public sealed class WorkspaceChangeTests : IDisposable
{
    private readonly string _root = Path.Combine(Path.GetTempPath(), $"DotsHarnessWorkspaceTests-{Guid.NewGuid():N}");

    public WorkspaceChangeTests() => Directory.CreateDirectory(_root);

    [Fact]
    public void TrackerReportsAddedModifiedAndDeletedFiles()
    {
        var changed = Path.Combine(_root, "same-size.cs");
        var removed = Path.Combine(_root, "removed.cs");
        File.WriteAllText(changed, "abc");
        File.WriteAllText(removed, "old");
        var tracker = WorkspaceChangeTracker.Start(_root);
        Assert.NotNull(tracker);

        File.WriteAllText(changed, "xyz");
        File.WriteAllText(Path.Combine(_root, "added.cs"), "new");
        File.Delete(removed);

        var result = tracker!.FinishResult();
        Assert.Equal("complete", result.TrackingStatus);
        Assert.Contains(result.ChangedFiles, file => file.Path == "same-size.cs" && file.Operation == ChangedFileOperation.Modified);
        Assert.Contains(result.ChangedFiles, file => file.Path == "added.cs" && file.Operation == ChangedFileOperation.Added);
        Assert.Contains(result.ChangedFiles, file => file.Path == "removed.cs" && file.Operation == ChangedFileOperation.Deleted);
    }

    [Fact]
    public void TrackerIgnoresGeneratedMemoryAndSymlinkAreas()
    {
        Directory.CreateDirectory(Path.Combine(_root, ".git"));
        Directory.CreateDirectory(Path.Combine(_root, ".mem"));
        Directory.CreateDirectory(Path.Combine(_root, "build"));
        Directory.CreateDirectory(Path.Combine(_root, "node_modules"));
        Directory.CreateDirectory(Path.Combine(_root, "Pods"));
        Directory.CreateDirectory(Path.Combine(_root, "DerivedData"));
        File.WriteAllText(Path.Combine(_root, ".git", "ignored.cs"), "one");
        File.WriteAllText(Path.Combine(_root, ".mem", "ignored.cs"), "one");
        File.WriteAllText(Path.Combine(_root, "build", "ignored.cs"), "one");
        File.WriteAllText(Path.Combine(_root, "node_modules", "ignored.cs"), "one");
        File.WriteAllText(Path.Combine(_root, "Pods", "ignored.cs"), "one");
        File.WriteAllText(Path.Combine(_root, "DerivedData", "ignored.cs"), "one");
        var outside = Path.Combine(_root, "outside.cs");
        File.WriteAllText(outside, "outside");
        try { File.CreateSymbolicLink(Path.Combine(_root, "link.cs"), outside); } catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
        var tracker = WorkspaceChangeTracker.Start(_root);
        Assert.NotNull(tracker);

        File.WriteAllText(Path.Combine(_root, ".git", "ignored.cs"), "two");
        File.WriteAllText(Path.Combine(_root, ".mem", "ignored.cs"), "two");
        File.WriteAllText(Path.Combine(_root, "build", "ignored.cs"), "two");
        File.WriteAllText(Path.Combine(_root, "node_modules", "ignored.cs"), "two");
        File.WriteAllText(Path.Combine(_root, "Pods", "ignored.cs"), "two");
        File.WriteAllText(Path.Combine(_root, "DerivedData", "ignored.cs"), "two");
        File.WriteAllText(outside, "changed");

        var result = tracker!.FinishResult();
        Assert.DoesNotContain(result.ChangedFiles, file => file.Path.StartsWith(".git/", StringComparison.Ordinal));
        Assert.DoesNotContain(result.ChangedFiles, file => file.Path.StartsWith(".mem/", StringComparison.Ordinal));
        Assert.DoesNotContain(result.ChangedFiles, file => file.Path.StartsWith("build/", StringComparison.Ordinal));
        Assert.DoesNotContain(result.ChangedFiles, file => file.Path.StartsWith("node_modules/", StringComparison.Ordinal));
        Assert.DoesNotContain(result.ChangedFiles, file => file.Path.StartsWith("Pods/", StringComparison.Ordinal));
        Assert.DoesNotContain(result.ChangedFiles, file => file.Path.StartsWith("DerivedData/", StringComparison.Ordinal));
        Assert.DoesNotContain(result.ChangedFiles, file => file.Path == "link.cs");
    }

    [Fact]
    public void MissingSnapshotIsIncompleteRatherThanEmptySuccess()
    {
        var tracker = WorkspaceChangeTracker.Start(Path.Combine(_root, "missing"));
        Assert.Null(tracker);
    }

    [Fact]
    public void FinishReportsIncompleteWhenWorkspaceDisappears()
    {
        var tracker = WorkspaceChangeTracker.Start(_root);
        Assert.NotNull(tracker);
        Directory.Delete(_root, recursive: true);

        var result = tracker!.FinishResult();

        Assert.Equal("incomplete", result.TrackingStatus);
    }

    [Fact]
    public async Task SafeRemovalRequiresNoLiveReferenceAndProtectsState()
    {
        File.WriteAllText(Path.Combine(_root, "old.cs"), "class OldArchitecture {}");
        File.WriteAllText(Path.Combine(_root, "caller.cs"), "class Caller {}");
        var result = await NativeWorkspaceTools.ExecuteAsync(new NativeToolCall(
            "1", "remove_file", JsonSerializer.Serialize(new { path = "old.cs", reason = "Replaced by the new architecture.", referenceTerms = "OldArchitecture" })), _root);
        Assert.StartsWith("[cleanup:verified]", result, StringComparison.Ordinal);
        Assert.False(File.Exists(Path.Combine(_root, "old.cs")));

        File.WriteAllText(Path.Combine(_root, "old2.cs"), "class OldTwo {}");
        File.WriteAllText(Path.Combine(_root, "caller.cs"), "new OldTwo();");
        result = await NativeWorkspaceTools.ExecuteAsync(new NativeToolCall(
            "2", "remove_file", JsonSerializer.Serialize(new { path = "old2.cs", reason = "Old flow removed.", referenceTerms = "OldTwo" })), _root);
        Assert.StartsWith("[cleanup:preserved]", result, StringComparison.Ordinal);
        Assert.True(File.Exists(Path.Combine(_root, "old2.cs")));

        File.WriteAllText(Path.Combine(_root, "state.sqlite"), "state");
        result = await NativeWorkspaceTools.ExecuteAsync(new NativeToolCall(
            "3", "remove_file", JsonSerializer.Serialize(new { path = "state.sqlite", reason = "cleanup", referenceTerms = "state" })), _root);
        Assert.StartsWith("[cleanup:preserved]", result, StringComparison.Ordinal);
        Assert.True(File.Exists(Path.Combine(_root, "state.sqlite")));
    }

    public void Dispose()
    {
        try { Directory.Delete(_root, recursive: true); } catch { }
    }
}

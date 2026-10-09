// Copyright (c) 2026 DOTS
// edit_file and glob behaviour: the rejections that keep the model from guessing, and
// the pattern compiler that decides what a glob matches.

using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using DotsHarnessCore;
using Xunit;

namespace DotsHarness.Tests;

[Collection("ReadLedger")]
public sealed class NativeFileEditTests : IDisposable
{
    private readonly string _root = Path.Combine(Path.GetTempPath(), $"DotsHarnessFileEdit-{Guid.NewGuid():N}");

    public NativeFileEditTests()
    {
        Directory.CreateDirectory(_root);
        ReadLedger.Reset();
    }

    private string Seed(string relative, string content)
    {
        var file = Path.Combine(_root, relative.Replace('/', Path.DirectorySeparatorChar));
        Directory.CreateDirectory(Path.GetDirectoryName(file)!);
        File.WriteAllText(file, content);
        return file;
    }

    /// The read goes through read_file so the ledger holds the same resolved path the edit
    /// will look up, which is what "you have seen these bytes" means here.
    private async Task<string> ReadAsync(string relative) =>
        await NativeWorkspaceTools.ExecuteAsync(
            new NativeToolCall("read", "read_file", new JsonObject { ["path"] = relative }.ToJsonString()),
            _root);

    private static string EditArguments(string path, params (string Old, string New)[] replacements)
    {
        var edits = new JsonArray();
        foreach (var (oldText, newText) in replacements)
            edits.Add(new JsonObject { ["old_text"] = oldText, ["new_text"] = newText });
        return new JsonObject { ["path"] = path, ["edits"] = edits }.ToJsonString();
    }

    private string EditCall(string path, params (string Old, string New)[] replacements) =>
        NativeFileEdit.Execute(new NativeToolCall("edit", "edit_file", EditArguments(path, replacements)), _root);

    private string Glob(string pattern, string path = ".") =>
        NativeFileEdit.Execute(new NativeToolCall("glob", "glob",
            new JsonObject { ["pattern"] = pattern, ["path"] = path }.ToJsonString()), _root);

    private string Content(string relative) =>
        File.ReadAllText(Path.Combine(_root, relative.Replace('/', Path.DirectorySeparatorChar)));

    [Fact]
    public async Task PagedProjectFileCanBeEditedAndReread()
    {
        var original = string.Join('\n', Enumerable.Range(1, 240).Select(i => $"line-{i}:" + new string('x', 1000)));
        var file = Seed("project.swift", original);
        for (var start = 1; start <= 240; start += 20)
        {
            var args = new JsonObject { ["path"] = "project.swift", ["offset"] = start, ["limit"] = 20 }.ToJsonString();
            var page = await NativeWorkspaceTools.ExecuteAsync(new NativeToolCall("read", "read_file", args), _root);
            Assert.Equal(page, EconomyPolicy.NormalizeToolOutput(page, "read_file", args));
            if (start == 1) Assert.Contains("has not been read", EditCall("project.swift", ("line-180:", "fixed-180:")));
        }
        Assert.StartsWith("Edited", EditCall("project.swift", ("line-180:", "fixed-180:")));
        Assert.Equal(original.Replace("line-180:", "fixed-180:"), File.ReadAllText(file));
        var reread = await NativeWorkspaceTools.ExecuteAsync(new NativeToolCall("read", "read_file",
            new JsonObject { ["path"] = "project.swift", ["offset"] = 180, ["limit"] = 1 }.ToJsonString()), _root);
        Assert.StartsWith("fixed-180:", reread);
    }

    [Fact]
    public async Task NarrowReadKeepsCompleteReadButChangedPagesDoNotCombine()
    {
        var file = Seed("pages.txt", "one\ntwo\nthree\nfour");
        await ReadAsync("pages.txt");
        await NativeWorkspaceTools.ExecuteAsync(new NativeToolCall("read", "read_file",
            new JsonObject { ["path"] = "pages.txt", ["offset"] = 2, ["limit"] = 1 }.ToJsonString()), _root);
        Assert.StartsWith("Edited", EditCall("pages.txt", ("one", "updated")));
        ReadLedger.Reset();
        await NativeWorkspaceTools.ExecuteAsync(new NativeToolCall("read", "read_file",
            new JsonObject { ["path"] = "pages.txt", ["limit"] = 2 }.ToJsonString()), _root);
        File.WriteAllText(file, "changed\ntwo\nthree\nfour");
        await NativeWorkspaceTools.ExecuteAsync(new NativeToolCall("read", "read_file",
            new JsonObject { ["path"] = "pages.txt", ["offset"] = 3 }.ToJsonString()), _root);
        Assert.Contains("has not been read", EditCall("pages.txt", ("changed", "bad")));
    }

    [Fact]
    public void AnUnreadFileCannotBeEdited()
    {
        Seed("quiet.txt", "alpha beta\n");
        var answer = EditCall("quiet.txt", ("alpha", "omega"));
        Assert.Contains("has not been read in this conversation", answer, StringComparison.Ordinal);
        Assert.Equal("alpha beta\n", Content("quiet.txt"));
    }

    [Fact]
    public async Task AFileChangedSinceItWasReadCannotBeEdited()
    {
        var file = Seed("moved.txt", "alpha beta\n");
        await ReadAsync("moved.txt");
        File.WriteAllText(file, "alpha beta\ngamma\n");
        var answer = EditCall("moved.txt", ("alpha", "omega"));
        Assert.Contains("changed since it was read", answer, StringComparison.Ordinal);
        Assert.Equal("alpha beta\ngamma\n", Content("moved.txt"));
    }

    [Fact]
    public void EditingAMissingFilePointsAtWriteFile()
    {
        var answer = EditCall("ghost.txt", ("anything", "nothing"));
        Assert.Contains("does not exist", answer, StringComparison.Ordinal);
        Assert.Contains("write_file creates a new file", answer, StringComparison.Ordinal);
        Assert.False(File.Exists(Path.Combine(_root, "ghost.txt")));
    }

    [Fact]
    public void EditingOutsideTheWorkspaceIsRefused()
    {
        Assert.Contains("outside the workspace", EditCall("../elsewhere.txt", ("a", "b")), StringComparison.Ordinal);
    }

    [Fact]
    public async Task AnEmptyOldTextWouldMatchEverywhere()
    {
        Seed("empty.txt", "alpha\n");
        await ReadAsync("empty.txt");
        var answer = EditCall("empty.txt", ("", "inserted"));
        Assert.Contains("edit 1 has an empty old_text", answer, StringComparison.Ordinal);
        Assert.Contains("Nothing was written", answer, StringComparison.Ordinal);
        Assert.Equal("alpha\n", Content("empty.txt"));
    }

    [Fact]
    public async Task NoMatchNamesTheEditAndWritesNothing()
    {
        Seed("nothing.txt", "alpha\n");
        await ReadAsync("nothing.txt");
        var answer = EditCall("nothing.txt", ("absent", "replacement"));
        Assert.Contains("edit 1 matched nothing in nothing.txt", answer, StringComparison.Ordinal);
        Assert.Contains("check the exact text and whitespace", answer, StringComparison.Ordinal);
        Assert.Equal("alpha\n", Content("nothing.txt"));
    }

    [Fact]
    public async Task AnAmbiguousMatchIsRefusedAndSaysWhereItFound()
    {
        Seed("same.txt", "x\nx\nx\n");
        await ReadAsync("same.txt");
        var answer = EditCall("same.txt", ("x", "y"));
        Assert.Contains("matched 3 places in same.txt", answer, StringComparison.Ordinal);
        Assert.Contains("around lines 1, 2, 3", answer, StringComparison.Ordinal);
        Assert.Contains("Widen old_text", answer, StringComparison.Ordinal);
        Assert.Equal("x\nx\nx\n", Content("same.txt"));
    }

    [Fact]
    public async Task ReplaceAllIsWhatAnAmbiguousMatchNeeds()
    {
        Seed("all.txt", "x\nx\n");
        await ReadAsync("all.txt");
        var arguments = new JsonObject
        {
            ["path"] = "all.txt",
            ["edits"] = new JsonArray
            {
                new JsonObject { ["old_text"] = "x", ["new_text"] = "y", ["replace_all"] = true },
            },
        };
        var answer = NativeFileEdit.Execute(
            new NativeToolCall("edit", "edit_file", arguments.ToJsonString()), _root);
        Assert.Equal("Edited all.txt (replaced 2 occurrences).", answer);
        Assert.Equal("y\ny\n", Content("all.txt"));
    }

    [Fact]
    public async Task AUniqueMatchRewritesOnlyThatSpan()
    {
        Seed("one.txt", "first\nsecond\nthird\n");
        await ReadAsync("one.txt");
        Assert.Equal("Edited one.txt (replaced 1 occurrence).", EditCall("one.txt", ("second", "SECOND")));
        Assert.Equal("first\nSECOND\nthird\n", Content("one.txt"));
        // The edit re-arms the ledger with the bytes it wrote, so the next edit needs no
        // fresh read.
        Assert.Equal("Edited one.txt (replaced 1 occurrence).", EditCall("one.txt", ("SECOND", "second")));
    }

    [Fact]
    public async Task EditsAreAllOrNothing()
    {
        Seed("batch.txt", "one\ntwo\n");
        await ReadAsync("batch.txt");
        var answer = EditCall("batch.txt", ("one", "1"), ("missing", "2"));
        Assert.Contains("edit 2 matched nothing in batch.txt", answer, StringComparison.Ordinal);
        Assert.Equal("one\ntwo\n", Content("batch.txt"));
    }

    [Fact]
    public async Task MoreThanFiftyEditsMustBeSplit()
    {
        Seed("many.txt", "a\n");
        await ReadAsync("many.txt");
        var edits = new JsonArray();
        for (var index = 0; index < 51; index++)
            edits.Add(new JsonObject { ["old_text"] = "a", ["new_text"] = "b" });
        var answer = NativeFileEdit.Execute(
            new NativeToolCall("edit", "edit_file",
                new JsonObject { ["path"] = "many.txt", ["edits"] = edits }.ToJsonString()),
            _root);
        Assert.Contains("too many edits in one call (max 50)", answer, StringComparison.Ordinal);
        Assert.Equal("a\n", Content("many.txt"));
    }

    [Fact]
    public void AnEmptyEditListIsRefused()
    {
        var answer = NativeFileEdit.Execute(
            new NativeToolCall("edit", "edit_file",
                new JsonObject { ["path"] = "any.txt", ["edits"] = new JsonArray() }.ToJsonString()),
            _root);
        Assert.Equal("Tool error: edits is empty; at least one replacement is required.", answer);
    }

    // MARK: - the pattern compiler

    private static bool Matches(string pattern, string path)
    {
        var source = NativeFileEdit.GlobPattern(pattern);
        Assert.NotNull(source);
        return Regex.IsMatch(path, source!, RegexOptions.None, TimeSpan.FromSeconds(2));
    }

    [Theory]
    [InlineData("**/*.swift", "Sources/App/View.swift", true)]
    [InlineData("**/*.swift", "Sources/View.swift", true)]
    [InlineData("**/*.swift", "a.swift", true)]
    [InlineData("*.swift", "View.swift", true)]
    // One segment, so it stops where a separator begins; the tool's own matcher then tries
    // the filename component, which is how a bare pattern still reaches nested files.
    [InlineData("*.swift", "Sources/View.swift", false)]
    [InlineData("Sources/**/*.ts", "Sources/a.ts", true)]
    [InlineData("Sources/**/*.ts", "Sources/deep/nested/a.ts", true)]
    [InlineData("Sources/**/*.ts", "Tests/a.ts", false)]
    [InlineData("config.{json,yml}", "config.json", true)]
    [InlineData("config.{json,yml}", "config.yml", true)]
    [InlineData("config.{json,yml}", "config.toml", false)]
    [InlineData("a?c", "abc", true)]
    [InlineData("a?c", "ac", false)]
    [InlineData("a?c", "a/c", false)]
    [InlineData("a.b", "axb", false)]
    [InlineData("a.b", "a.b", true)]
    [InlineData("[abc]*.ts", "ax.ts", true)]
    [InlineData("[abc]*.ts", "zx.ts", false)]
    [InlineData("test_*", "test_a/b", false)]
    public void GlobPatternsCompileAsDocumented(string pattern, string path, bool expected) =>
        Assert.Equal(expected, Matches(pattern, path));

    [Theory]
    [InlineData("src/{a,b")]
    [InlineData("src/[abc")]
    [InlineData("[]")]
    [InlineData("}")]
    public void ABrokenPatternDoesNotCompile(string pattern) => Assert.Null(NativeFileEdit.GlobPattern(pattern));

    [Fact]
    public void ACommaOutsideABraceGroupStaysLiteral() =>
        Assert.Equal("^a,b$", NativeFileEdit.GlobPattern("a,b"));

    // MARK: - glob on disk

    [Fact]
    public void GlobAnswersNewestFirstAndSkipsBuildTrees()
    {
        Seed("src/old.cs", "class Old {}\n");
        Seed("src/new.cs", "class New {}\n");
        Seed("node_modules/pkg/index.js", "module.exports = 1;\n");
        Seed(".git/config", "x\n");
        File.SetLastWriteTimeUtc(Path.Combine(_root, "src", "old.cs"), DateTime.UtcNow.AddMinutes(-30));

        var answer = Glob("**/*.cs");
        Assert.StartsWith("glob **/*.cs under .: 2 files", answer, StringComparison.Ordinal);
        Assert.True(
            answer.IndexOf("new.cs", StringComparison.Ordinal) < answer.IndexOf("old.cs", StringComparison.Ordinal),
            "newest-first, got: " + answer);
        // An ignored tree is never descended into, so nothing inside it can be listed.
        Assert.Equal("glob **/*.js: no files found.", Glob("**/*.js"));
    }

    [Fact]
    public void ABarePatternReachesNestedFiles()
    {
        Seed("root.cs", "a\n");
        Seed("deep/deeper/nested.cs", "b\n");
        var answer = Glob("*.cs");
        Assert.Contains("root.cs", answer, StringComparison.Ordinal);
        Assert.Contains("deep/deeper/nested.cs", answer, StringComparison.Ordinal);
    }

    [Fact]
    public void GlobNamesItsScopeWhenThereIsNothingToReturn() =>
        Assert.Equal("glob **/*.nope: no files found.", Glob("**/*.nope"));

    [Fact]
    public void GlobNeedsAPattern() => Assert.Equal("Tool error: pattern is required.", Glob("   "));

    [Fact]
    public void ABrokenPatternSaysWhy() => Assert.Equal(
        "Tool error: the pattern could not be compiled \u2014 check for an unclosed { or [.",
        Glob("src/{a,b"));

    [Fact]
    public void APatternCannotLeaveTheWorkspace()
    {
        Assert.Contains("pattern must stay inside the workspace", Glob("../**/*"), StringComparison.Ordinal);
        Assert.Contains("pattern must stay inside the workspace", Glob("/**/*.env"), StringComparison.Ordinal);
    }

    [Fact]
    public void AGlobSearchesOneDirectoryAtATime()
    {
        Seed("docs/readme.md", "a\n");
        Seed("notes/readme.md", "b\n");
        var answer = Glob("*.md", "docs");
        Assert.StartsWith("glob *.md under docs: 1 file", answer, StringComparison.Ordinal);
        Assert.Equal("glob *.md under docs: 1 file\nreadme.md", answer);
    }

    [Fact]
    public void AFileIsNotADirectoryToSearch()
    {
        Seed("docs/readme.md", "a\n");
        Assert.Contains("is not a directory", Glob("*", "docs/readme.md"), StringComparison.Ordinal);
    }

    public void Dispose()
    {
        try { Directory.Delete(_root, recursive: true); } catch { }
    }
}

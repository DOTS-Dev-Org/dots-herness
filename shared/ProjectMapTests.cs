using DotsHarnessCore;
using Xunit;

public sealed class ProjectMapTests : IDisposable
{
    private readonly string _workspace = Path.Combine(Path.GetTempPath(), $"ProjectMapTests-{Guid.NewGuid():N}");

    public ProjectMapTests() => Directory.CreateDirectory(_workspace);

    public void Dispose()
    {
        try { Directory.Delete(_workspace, true); } catch (IOException) { }
    }

    private void Write(string relative, string contents = "x")
    {
        var path = Path.Combine(_workspace, relative.Replace('/', Path.DirectorySeparatorChar));
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllText(path, contents);
    }

    [Fact]
    public void MapNamesEachFolderWithCountPurposeAndEntryFiles()
    {
        string[] files =
        [
            "README.md", "api/README.md", "api/src/server.ts", "api/src/routes.ts", "api/package.json",
            "app/Package.swift", "app/Sources/App/main.swift", "app/Sources/App/View.swift", "tools/a.py",
        ];
        var reads = new Dictionary<string, string>
        {
            ["api/README.md"] = "# API\n\n[![badge](x)](y)\nThe HTTP backend that stores accounts.\n",
            ["api/package.json"] = """{ "name": "api", "description": "ignored when a README says it" }""",
        };
        var map = ProjectMap.Markdown(files, path => reads.GetValueOrDefault(path));

        Assert.Contains("- root - open: README.md", map);
        Assert.Contains("- `api/` - The HTTP backend that stores accounts. - open: README.md, package.json", map);
        Assert.Contains("  - `api/src/` - mostly .ts - open: server.ts", map);
        Assert.Contains("- `app/` - Swift package, mostly .swift - open: Package.swift", map);
        Assert.Contains("  - `app/Sources/` - mostly .swift", map);
        Assert.Contains("- `tools/` - mostly .py", map);
        Assert.Equal("", ProjectMap.Markdown(["README.md"], _ => null));
    }

    [Fact]
    public async Task SearchFollowsGitignoreAndSkipsHerNessCaches()
    {
        WorkspaceFileIndex.Git(_workspace, "init", "-q");
        if (!Directory.Exists(Path.Combine(_workspace, ".git"))) return; // no git on this machine
        Write(".gitignore", "generated/\n");
        Write("src/a.cs", "needle");
        Write("generated/b.cs", "needle");
        Write(".sandbox-cache/c.cs", "needle");

        var found = await NativeWorkspaceTools.ExecuteAsync(
            new NativeToolCall("1", "grep_files", """{"pattern":"needle"}"""), _workspace, CancellationToken.None);

        Assert.Contains("src/a.cs:1:needle", found);
        Assert.DoesNotContain("generated/", found);
        Assert.DoesNotContain(".sandbox-cache", found);
        var map = ProjectMap.Text(_workspace);
        Assert.Contains("`src/`", map);
        Assert.DoesNotContain("`generated/`", map);
    }
}

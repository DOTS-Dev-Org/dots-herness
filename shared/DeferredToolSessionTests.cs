using DotsHarnessCore;
using System.Text.Json.Nodes;
using Xunit;

public sealed class DeferredToolSessionTests
{
    private static NativeToolDefinition ReadTool => new("read_file", "Read a workspace file", JsonNode.Parse("""{"type":"object","properties":{"path":{"type":"string"}}}""")!);
    private static NativeToolDefinition FetchTool => new("web_fetch", "Fetch a URL", JsonNode.Parse("""{"type":"object"}""")!);
    private static NativeToolCall Call(string name, string arguments, string id = "call-1") => new(id, name, arguments);
    [Fact]
    public void EnterPlanModeIsADirectControlThatCarriesPlanGuidance()
    {
        var session = new DeferredToolSession();
        var call = Call(DeferredToolSession.EnterPlanName, "{}");
        Assert.Equal(DeferredToolSession.EnterPlanName, session.Resolve(call, []).Name);
        Assert.Contains("plan mode", session.Control(call, [], planMode: true)!);
        Assert.Contains("unavailable", session.Control(call, [], planMode: false)!);
    }
    [Fact]
    public void DiscoveryRequiredAndScopeAndSchemaChangesRevokeCalls()
    {
        var session = new DeferredToolSession();
        NativeToolDefinition[] catalog = [ReadTool];
        var call = Call("invoke_tool", """{"name":"read_file","arguments":"{\"path\":\"README.md\"}"}""");
        Assert.DoesNotContain(DeferredToolSession.Definitions, t => t.Name == "read_file");
        // A direct tool wrapped in invoke_tool runs without a discovery round.
        Assert.Equal("read_file", session.Resolve(call, catalog).Name);
        NativeToolDefinition removal = new("remove_file", "remove", JsonNode.Parse("""{"type":"object"}""")!);
        var invokeRemoval = Call("invoke_tool", """{"name":"remove_file","arguments":"{}"}""");
        Assert.Equal("invoke_tool", session.Resolve(invokeRemoval, [removal]).Name);
        session.Control(Call("discover_tools", """{"query":"remove_file"}"""), [removal], false);
        Assert.Equal("remove_file", session.Resolve(invokeRemoval, [removal]).Name);
        Assert.Equal("invoke_tool", session.Resolve(invokeRemoval, [new("remove_file", "changed", JsonNode.Parse("""{"type":"array"}""")!)]).Name);
        // A core tool is sent with its schema and called directly, but only while the catalog offers it.
        Assert.Equal("read_file", session.Resolve(Call("read_file", "{}"), catalog).Name);
        Assert.Equal("invoke_tool", session.Resolve(Call("read_file", "{}"), []).Name);
        Assert.Equal("run_command", session.Resolve(Call("run_command", "{}"), [new("run_command", "run", JsonNode.Parse("""{"type":"object"}""")!)]).Name);
        Assert.Equal("invoke_tool", session.Resolve(Call("remove_file", "{}"), [new("remove_file", "remove", JsonNode.Parse("""{"type":"object"}""")!)]).Name);
        Assert.Contains("parameters", session.Control(Call("discover_tools", """{"query":"read_file"}"""), catalog, false)!);
        var resolved = session.Resolve(call, catalog);
        Assert.Equal("read_file", resolved.Name);
        Assert.Equal(call.Id, resolved.Id);
        Assert.Equal("""{"path":"README.md"}""", resolved.Arguments);
        Assert.Equal("invoke_tool", session.Resolve(call, []).Name);
        // Direct tools always carry their current schema, so a changed one still resolves.
        Assert.Equal("read_file", session.Resolve(call, [new("read_file", "changed", JsonNode.Parse("""{"type":"array"}""")!)]).Name);
    }
    [Fact]
    public void PlanAtSelectedEffortExecuteLowAndRestoreOnFailure()
    {
        var session = new DeferredToolSession();
        Assert.Equal("max", session.Effort("max", false));
        session.Control(Call("execution_plan", """{"steps":["Edit known label","Run targeted check"],"routine":true,"uncertainties":[]}"""), [], false);
        Assert.Equal("low", session.Effort("max", false));
        Assert.Equal("none", session.Effort("none", false));
        Assert.Equal("max", session.Effort("max", true));
        session.Record("Process exited with status 2", "failure");
        Assert.Equal("max", session.Effort("max", false));
        session.Control(Call("execution_plan", """{"steps":["Investigate"],"routine":true,"uncertainties":["unknown"]}"""), [], false);
        Assert.Equal("high", session.Effort("high", false));
    }
    [Fact]
    public void DiscoveryHistoryResumesWithoutRestoringOldTaskEffort()
    {
        var prior = new DeferredToolSession();
        var search = Call("discover_tools", """{"query":"web_fetch"}""", "search");
        var result = prior.Control(search, [FetchTool], false)!;
        var resumed = new DeferredToolSession();
        resumed.RestoreDiscovery([new NativeMessage("assistant", "", ToolCalls: [search]), new NativeMessage("tool", result, "search")]);
        var call = Call("invoke_tool", """{"name":"web_fetch","arguments":"{}"}""");
        Assert.Equal("web_fetch", resumed.Resolve(call, [FetchTool]).Name);
        Assert.Equal("max", resumed.Effort("max", false));
        resumed.RestoreDiscovery([new NativeMessage("user", result)]);
        Assert.Equal("invoke_tool", resumed.Resolve(call, [FetchTool]).Name);
    }
    [Fact]
    public void ExactDottedNameLoadsOnlyThatSchemaAndFailuresRestorePlanning()
    {
        var session = new DeferredToolSession();
        var tools = new[] { "skill.read", "skill.list", "read_file" }.Select(name => new NativeToolDefinition(name, "read skill", new JsonObject())).ToArray();
        var result = session.Control(Call("discover_tools", """{"query":"skill.read"}"""), tools, false)!;
        Assert.Single(JsonNode.Parse(result)!["tools"]!.AsArray());
        Assert.True(DeferredToolSession.Failed("exit_code: -1"));
        Assert.True(DeferredToolSession.Failed("[check 1 FAILED]"));
    }
    [Fact]
    public void OutputRetainedAndReadLedgerAndDiscoverySurviveNormalization()
    {
        var session = new DeferredToolSession();
        var raw = new string('x', 20000) + "fatal: decisive failure";
        session.Record(raw, "original");
        Assert.Equal("fatal: decisive failure", session.Control(Call("read_tool_output", """{"call_id":"original","offset":20000,"limit":100}"""), [], false));
        Assert.Equal(raw, EconomyPolicy.NormalizeToolOutput(raw, "discover_tools"));
        var calls = new[] { Call("invoke_tool", """{"name":"read_file","arguments":"{}"}""") };
        var normalized = EconomyPolicy.NormalizeToolMessages([new NativeMessage("assistant", "", ToolCalls: calls), new NativeMessage("tool", raw, "call-1")]);
        Assert.Equal(raw, normalized[1].Content);
        Assert.Contains("fatal: decisive failure", EconomyPolicy.NormalizeToolOutput(raw, "run_command"));
    }

    [Fact]
    public void RepeatedUnchangedReadPointsAtEarlierResult()
    {
        var session = new DeferredToolSession();
        var lines = Enumerable.Range(1, 100).Select(i => $"line {i} of the file body").ToArray();
        var whole = string.Join("\n", lines);
        Assert.Null(session.RepeatedRead(whole, "./A.cs"));
        session.Record(whole, "c1", "read_file", "./A.cs");
        var page = string.Join("\n", lines[19..80]) + "\n\nContinue at line 81 (file has 100 lines)";
        var note = session.RepeatedRead(page, "A.cs");
        Assert.StartsWith(DeferredToolSession.RepeatedReadPrefix, note);
        Assert.Contains("call_id=c1", note);
        Assert.Null(session.RepeatedRead(whole.Replace("line 50 ", "line fifty "), "A.cs"));
        Assert.Null(session.RepeatedRead(whole, "B.cs"));
    }
}

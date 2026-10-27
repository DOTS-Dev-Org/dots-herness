using DotsHarnessCore;
using HarnessPluginKit;
using PluginRuntime;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Xunit;

[Collection("ReadLedger")]
public sealed class DeferredToolFlowTests
{
    [Fact]
    public async Task MainFlowSendsGatewayWithCoreToolsAndLowersEffortAfterPlan()
    {
        var root = Path.Combine(Path.GetTempPath(), "herness-deferred-flow-" + Guid.NewGuid());
        var workspace = Path.Combine(root, "workspace");
        Directory.CreateDirectory(workspace);
        File.WriteAllText(Path.Combine(workspace, "input.txt"), "retained exact file evidence");
        var paths = new SupportPaths(root, Path.Combine(root,"plugins"), Path.Combine(root,"presets"), Path.Combine(root,"settings.json"), Path.Combine(root,"host.patch.yml"), Path.Combine(root,"trust.json"), Path.Combine(root,"models"), Path.Combine(root,"runtime"));
        var requests = new List<JsonObject>();
        using var provider = LocalTestGateway.Start(request =>
        {
            var body = Encoding.UTF8.GetString(request.Body);
            if (body.Contains("private suggested follow-up user message", StringComparison.Ordinal))
                return Task.FromResult(new NativeGatewayResponse(200, "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"Continue.\"}}]}"u8.ToArray()));
            var node = JsonNode.Parse(body)!.AsObject();
            requests.Add(node);
            var index = requests.Count;
            var name = index == 1 ? "discover_tools" : index == 2 ? "execution_plan" : "invoke_tool";
            var args = index == 1 ? """{"query":"read_file"}""" : index == 2 ? """{"steps":["Read input.txt","Report evidence"],"routine":true,"uncertainties":[]}""" : """{"name":"read_file","arguments":"{\"path\":\"input.txt\"}"}""";
            var message = new JsonObject { ["role"]="assistant", ["content"] = index >= 4 ? "Read verified." : "" };
            if (index < 4) message["tool_calls"] = new JsonArray(new JsonObject { ["id"]="call-"+index, ["type"]="function", ["function"]=new JsonObject { ["name"]=name, ["arguments"]=args } });
            return Task.FromResult(new NativeGatewayResponse(200, JsonSerializer.SerializeToUtf8Bytes(new JsonObject { ["choices"]=new JsonArray(new JsonObject { ["message"]=message }) })));
        });
        try
        {
            using var router = new RouterController(paths);
            var endpoint = router.Store.AddCustom("Deferred flow", "deferred-flow", provider.Url.ToString().TrimEnd('/'), NativeProviderProtocol.OpenAiCompatible, "chat", null, "gpt-5");
            router.Store.AddCustomAccount(endpoint, null);
            await router.RefreshAsync(); router.SelectedEffort = "high";
            var bridge = new AgentBridge(router, paths);
            await bridge.StartAsync(workspace);
            await bridge.SendAsync("Read input.txt and report its content.").WaitAsync(TimeSpan.FromSeconds(20));
            Assert.Equal(4, requests.Count);
            foreach (var request in requests)
            {
                var names = request["tools"]!.AsArray().Select(t => t!["function"]!["name"]!.GetValue<string>()).ToArray();
                Assert.Equal(DeferredToolSession.Definitions.Select(t => t.Name).Concat(DeferredToolSession.DirectNames).OrderBy(n => n, StringComparer.Ordinal), names);
                Assert.Contains("run_command", names);
            }
            Assert.Equal(new[] { "high", "high", "low", "low" }, requests.Select(r => r["reasoning_effort"]!.GetValue<string>()));
            Assert.Contains("retained exact file evidence", requests[^1]["messages"]!.ToJsonString());
            Assert.Equal("high", router.SelectedEffort); // Per-request override never rewrites the user's preference.
        }
        finally { if (Directory.Exists(root)) Directory.Delete(root, true); }
    }
}

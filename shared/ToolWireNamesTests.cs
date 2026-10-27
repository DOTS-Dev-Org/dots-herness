// Copyright (c) 2026 DOTS
// The provider wire names of the harness's own tools.

using System.Net;
using System.Text.Json.Nodes;
using DotsHarnessCore;
using Xunit;

public sealed class ToolWireNamesTests
{
    [Fact]
    public void AnthropicKeepsTheNameReadableAndReversible()
    {
        Assert.Equal("skill-dot-read", ToolWireNames.Anthropic("skill.read"));
        Assert.Equal("skill.read", ToolWireNames.RestoreAnthropic("skill-dot-read"));
        Assert.Equal("write_file", ToolWireNames.Anthropic("write_file"));
    }

    [Fact]
    public void OpenAiReplacesOnlyTheCharactersTheProtocolRefuses()
    {
        Assert.Equal("skill_read", ToolWireNames.OpenAi("skill.read"));
        Assert.Equal("write_file", ToolWireNames.OpenAi("write_file"));
        Assert.Equal("plugin__thing", ToolWireNames.OpenAi("plugin__thing"));
    }

    [Fact]
    public void ResponsesNamesAreShortDeterministicAndDistinct()
    {
        var first = ToolWireNames.Responses("skill.read");
        var second = ToolWireNames.Responses("skill.list");
        Assert.Equal(first, ToolWireNames.Responses("skill.read"));
        Assert.NotEqual(first, second);
        Assert.Matches("^tool_[0-9a-f]{32}$", first);
    }

    [Theory]
    [InlineData(NativeProviderProtocol.Anthropic)]
    [InlineData(NativeProviderProtocol.OpenAiCompatible)]
    [InlineData(NativeProviderProtocol.OpenAiResponses)]
    public async Task DottedToolNamesTravelAsIdentifiersAndComeBackRestored(NativeProviderProtocol protocol)
    {
        var root = Path.Combine(Path.GetTempPath(), $"DotsHarnessTests-{Guid.NewGuid()}");
        try
        {
            const string model = "test-model";
            var secrets = new MemoryProviderSecretStore();
            var store = new NativeProviderStore(root, secrets);
            var account = new NativeProviderAccount
            {
                Provider = "wire-test",
                ProviderName = "Wire test",
                Name = "Wire test",
                AuthType = "apiKey",
                Model = model,
                Models = [model],
                BaseUrl = protocol switch
                {
                    NativeProviderProtocol.Anthropic => "https://anthropic.example",
                    NativeProviderProtocol.OpenAiResponses => "https://responses.example/v1",
                    _ => "https://openai.example/v1",
                },
                Protocol = protocol,
                CredentialId = "wire-test",
            };
            store.State.Accounts.Add(account);
            secrets.Write(account.CredentialId, "test-secret");

            var handler = new ToolCallHandler(protocol);
            var router = new NativeProviderRouter(store, http: new HttpClient(handler));
            var tools = new[]
            {
                new NativeToolDefinition("skill.read", "Read a skill.", new JsonObject { ["type"] = "object" }),
            };

            var response = await router.CompleteAsync([new NativeMessage("user", "hello")], tools);

            // The provider only accepts ASCII identifiers, so no dot travels.
            Assert.DoesNotContain(".", handler.ToolName);
            Assert.Matches("^[A-Za-z0-9_-]+$", handler.ToolName);
            // The app dispatches the real name, not the wire name.
            var call = Assert.Single(response.Message.ToolCalls!);
            Assert.Equal("skill.read", call.Name);
        }
        finally
        {
            if (Directory.Exists(root)) Directory.Delete(root, recursive: true);
        }
    }

    /// <summary>Answers with a tool call that carries the name the request used.</summary>
    private sealed class ToolCallHandler(NativeProviderProtocol protocol) : HttpMessageHandler
    {
        public string ToolName { get; private set; } = "";

        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            var body = JsonNode.Parse(await request.Content!.ReadAsStringAsync(cancellationToken))!.AsObject();
            ToolName = protocol switch
            {
                NativeProviderProtocol.Anthropic => body["tools"]!.AsArray()[0]!["name"]!.GetValue<string>(),
                NativeProviderProtocol.OpenAiResponses => body["tools"]!.AsArray()[0]!["name"]!.GetValue<string>(),
                _ => body["tools"]!.AsArray()[0]!["function"]!["name"]!.GetValue<string>(),
            };
            var payload = protocol switch
            {
                NativeProviderProtocol.Anthropic =>
                    $"{{\"content\":[{{\"type\":\"tool_use\",\"id\":\"call_1\",\"name\":\"{ToolName}\",\"input\":{{}}}}]}}",
                NativeProviderProtocol.OpenAiResponses =>
                    $"{{\"output\":[{{\"type\":\"function_call\",\"call_id\":\"call_1\",\"name\":\"{ToolName}\",\"arguments\":\"{{}}\"}}]}}",
                _ =>
                    $"{{\"choices\":[{{\"message\":{{\"role\":\"assistant\",\"content\":null,\"tool_calls\":[{{\"id\":\"call_1\",\"type\":\"function\",\"function\":{{\"name\":\"{ToolName}\",\"arguments\":\"{{}}\"}}}}]}}}}]}}",
            };
            return new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent(payload) };
        }
    }
}

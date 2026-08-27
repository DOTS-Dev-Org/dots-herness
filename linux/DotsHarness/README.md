# Dots Harness for Linux

The Avalonia shell uses the same shared .NET 8 native provider core as the
Windows build. Provider requests and the integrated agent loop stay inside the
application; the chat loop runs in-process without a separate web host.

`GPT` browser sign-in and `OpenAI` API-key connections remain separate.
`Custom API` supports validated HTTP/HTTPS OpenAI-compatible and
Anthropic-compatible endpoints. When Secret Service is unavailable, provider
secrets are session-only and are never persisted.

Runtime and model downloads require an explicit user action. Sharing starts a
loopback gateway only after Enable sharing is pressed and requires a bearer
share key.

Build and test on a Linux .NET 8 machine with:

```sh
dotnet test DotsHarness.sln
```

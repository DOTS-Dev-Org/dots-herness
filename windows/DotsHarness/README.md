# Dots Harness for Windows

The WPF shell uses the shared .NET 8 native provider core. It stores provider
metadata locally, protects credentials with Windows data protection, sends
requests directly to provider endpoints, and runs the agent loop in-process.

`GPT` browser sign-in and `OpenAI` API-key connections are separate. The
provider picker shows canonical names only. `Custom API` supports validated
HTTP/HTTPS OpenAI-compatible and Anthropic-compatible endpoints.

Runtime and model downloads are explicit: use Download/Install first, then
Start. Sharing is opt-in and starts a loopback gateway with a bearer share key.

The project targets .NET 8 and WPF. Build and test on a Windows .NET 8
machine with:

```powershell
dotnet test DotsHarness.sln
```

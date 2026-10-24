# Dots Harness for Linux

The Avalonia shell uses the same shared .NET 8 native provider core as the
Windows build. Provider requests and the integrated agent loop stay inside the
application; the chat loop runs in-process without a separate web host.

`GPT` browser sign-in and `OpenAI` API-key connections remain separate.
`Custom API` supports validated HTTP/HTTPS OpenAI-compatible and
Anthropic-compatible endpoints. When Secret Service is unavailable, provider
secrets use a user-only permissioned fallback directory.

Runtime and model downloads require an explicit user action. Sharing starts a
loopback gateway only after Enable sharing is pressed and requires a bearer
share key.

## Runtime requirements

Agent `run_command` calls and the dock terminal run inside a
[bubblewrap](https://github.com/containers/bubblewrap) sandbox. Install `bwrap`
before starting the app; without it those commands stay disabled and the app
reports `agent_command_sandbox_unavailable`.

```sh
sudo apt install bubblewrap      # Debian, Ubuntu
sudo dnf install bubblewrap      # Fedora
sudo pacman -S bubblewrap        # Arch
```

The sandbox keeps commands inside the sandbox worktree, hides the host home
directory, and disables network access by default. The Avalonia shell also
needs GTK 3 and WebKitGTK 4.1 (or 4.0) runtime libraries for the built-in browser.

Build and test on a Linux .NET 8 machine with:

```sh
dotnet test DotsHarness.sln
```

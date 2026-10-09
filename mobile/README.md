# HerNess mobile

The mobile app is local-first. After onboarding it opens the local workspace
without a desktop or `/v1/control/*` connection. The old desktop pairing link
is still accepted as an optional compatibility path for snapshot sync; it is
not required to open or use the app.

## Onboarding

1. Sign in to GitHub on the phone (authorization code + PKCE).
2. Select a repository and branch.
3. Clone it into the private app sandbox.
4. Choose a provider and model.
5. Use the local Code, Agent, Terminal, and Preview tabs.

The callback is `herness://oauth/github`. GitHub public client IDs are build
configuration, not secrets:

- iOS: set `HERNESS_GITHUB_CLIENT_ID` in the Xcode build configuration.
- Android: pass `-PhernessGithubClientId=...` to Gradle.

## On-device runtime

The Swift and Kotlin runtimes implement the same local contract: queued and
steered prompts, plan mode, approvals, questions, cancellation, continuation,
tool/event history, provider retries, context compaction, and interrupted-run
recovery. SQLite stores conversations, messages, model context, pending actions,
and events. API keys and OAuth tokens stay in Keychain or Android Keystore-backed
encrypted storage; SQLite stores references and metadata only.

Supported direct providers are Anthropic Messages, OpenAI Chat Completions,
OpenAI Responses, and the existing ChatGPT OAuth + PKCE Responses flow. The app
never ships a shared provider key. A user-entered API key is stored on that
device and sent directly to the selected provider.

## Workspace and Git

The workspace is private to the selected project. File tools, `skill.list`,
`skill.read`, `ask_user`, SQLite, and `run_command` are executed by the mobile
tool executor. `run_command` is deliberately constrained: path traversal and
`.mem` access are blocked, supported virtual commands are handled in-app, and
unsupported shell, signing, or arbitrary-process requests return
`unsupported_on_mobile` instead of claiming success. When a paired desktop
project is selected, build/test commands are sent through the authenticated
project-scoped control plane and remain subject to the desktop's approval mode.

`MobileGitClient` exposes clone, fetch, checkout, branch, status, diff, commit,
and push through the small C ABI in `mobile/native`. It supplies GitHub tokens
only through an in-memory libgit2 credential callback; tokens are never put in
remote URLs or Git config.

The checked-in builds compile the boundary and an explicit unavailable stub.
They do not vendor libgit2. A production build must link libgit2 (an iOS
XCFramework and Android per-ABI libraries) and define the platform build
settings accordingly. Until then, GitHub clone uses a clearly labelled REST
workspace mirror, while native Git operations report that libgit2 is not
linked. There is no fake Git success.

### Paired desktop development

Select the matching paired desktop project in the project picker to enable a
second Terminal runtime. It opens a persistent shell on that desktop; commands
such as `./run.sh`, `npm run dev`, `npm test`, and Git status/diff run there, not
inside the phone sandbox. The session is scoped to the paired device and project,
survives leaving the tab or briefly disconnecting, and is stopped when the
desktop host closes or the device is revoked. Starting a session and sending
commands follow the desktop access mode; the phone can always read output or
stop the session.

Preview stores the last URL per mobile project and loads it only after Open.
Back, forward, and reload controls are available. When the same remote project
is selected, Share port can publish a running desktop development server through
a Cloudflare Quick Tunnel; the generated HTTPS URL is opened automatically.
Quick Tunnels are temporary public development links: anyone with the URL can
reach that port until Stop sharing is selected. Cloudflare does not support SSE
through Quick Tunnels, so pages that depend on Server-Sent Events may not work.
Desktop approval mode also applies to starting a tunnel. The agent's
`native_browser` tool can open and inspect pages in the paired desktop's native
browser, with the desktop approval mode applied to browser actions.

On macOS, the paired shell is backed by a PTY. Windows and Linux use a persistent
redirected shell process, so ordinary commands and long-running dev servers work,
but full-screen terminal programs that require a real TTY may not.

## MCP, plugins, and loops

Only HTTP MCP servers are supported; a phone app cannot spawn a stdio server
process. Workspace plugins use the existing JavaScript runtime and receive the
restricted `harness` bridge. Foreground loops run while the app is open; the OS
controls background scheduling.

## Build and test

```sh
mobile/ios/run.sh
mobile/android/run.sh
```

```sh
xcodebuild -project mobile/ios/HerNessMobile.xcodeproj \
  -scheme HerNessMobile \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```

```sh
cd mobile/android && gradle testDebugUnitTest
```

Android targets API 35 and calls `enableEdgeToEdge()`; Compose content applies
system insets once at the scaffold/onboarding boundary. iOS uses a flexible
`WindowGroup`; iPhone scenes are full-screen by default. No
`UIRequiresFullScreen`, fixed frame, or letterbox setting is used.

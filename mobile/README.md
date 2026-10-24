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
5. Use the local Agent, Code, Terminal, Preview, Tasks, Memory, Media, Bots, and Marketplace screens from the workspace navigation drawer.

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

Pairing needs the desktop's QR code: it carries a one-time secret (`k`) and the
desktop certificate fingerprint (`fp`). While remote control is on, the desktop
also opens a Cloudflare Quick Tunnel by itself, so the phone reaches it off the
LAN. Every request, LAN and tunnel alike, goes through one sealed endpoint
(`/v3/sealed`): the raw HTTP exchange is AES-256-GCM encrypted with a key only
the desktop and the paired phone hold, so Cloudflare relays ciphertext only.
Replies to the event feed are long-polled because Quick Tunnels do not stream.

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

## Tasks, memory, MCP, and plugins

Tasks are saved as interval-based loops. They run on time while the app is open;
the OS controls when background refresh can run. The Memory screen shows project
facts and device-local preferences, and can add or remove project facts.

Only HTTP MCP servers are supported; a phone app cannot spawn a stdio server
process. Workspace plugins use the existing JavaScript runtime and receive the
restricted `harness` bridge.

## Media, bots, and Marketplace

Media projects, generated assets, and bot conversations are stored in the
selected mobile project's `.herness` folder and use the same JSON date format
on iOS and Android. Media includes size presets, project management, a shared
asset library, a touch canvas with editable text and shape layers, drag-to-move,
layer ordering, audio/video playback, and configurable image, speech, video,
and music generation endpoints. Music projects keep generated stems on separate
tracks with simultaneous mix playback, volume, mute, and solo controls.
Generated images can be placed on the canvas.
Provider keys are kept in device secure storage. The video model and music
endpoint are configurable because providers expose different generation APIs.

Bots have editable instructions and model overrides, saved per-bot chat history,
and direct requests through the currently selected provider. Marketplace lists
the plugin registry, skills, and project starters. A skill is installed only
from an HTTPS URL with a catalog SHA-256 checksum and a matching skill ID; the
installed `SKILL.md` is then included in the mobile agent's skill context.
Marketplace entries for compiled desktop plugins remain informational on
mobile; the app installs verified skills and starts projects from templates.
Native desktop plugins are listed for discovery, but cannot execute in the
mobile app. Starter cards create a mobile project and submit their prompt to the
local agent.

## Build and test

```sh
mobile/ios/run.sh
mobile/android/run.sh
```

```sh
xcodebuild -project mobile/ios/HerNessMobile.xcodeproj \
  -scheme HerNessMobile \
  -derivedDataPath mobile/ios/build/DerivedData \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```

```sh
cd mobile/android && gradle testDebugUnitTest
```

Android targets API 35 and calls `enableEdgeToEdge()`; Compose content applies
system insets once at the scaffold/onboarding boundary. iOS uses a flexible
`WindowGroup`; iPhone scenes are full-screen by default. No
`UIRequiresFullScreen`, fixed frame, or letterbox setting is used.

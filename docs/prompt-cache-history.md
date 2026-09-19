# Provider-independent prompt history

Each new user turn captures the current host context once, before the first
provider request. That snapshot is part of the stored model message. Later user
turns, tool calls, retries and continuations keep earlier snapshots unchanged.
The visible conversation still shows the user's original text.

- macOS keeps invariant `core_policy` in the system prefix. Runtime context,
  date, mode, project data, plugin guidance and skill metadata are captured on
  the user message. `promptContextCaptured` survives JSON persistence and
  prevents duplicate capture on continuation. Queued turns use the same rule.
- Windows and Linux share `NativePromptHistory` and the same `AgentBridge`.
  `PromptContextCaptured` is local transcript metadata, not a provider field.
- iOS and Android pin the initial policy using `MobilePromptHistory`. Changed
  policy and plugin context are appended to new user turns. Requests no longer
  reevaluate that context between tool steps. Tool definitions are ordered by
  name. Persisted mobile context contains `version`, `policy`, and `messages`.

Skill-read output stays intact in the desktop model transcript; the visible
tool preview remains abbreviated. Plan/apply transitions retain model history and the tool list: plan mode
withholds tools at run time (`planWithholds`) instead of removing them, so
toggling it keeps the cached prefix.

Anthropic message content consistently uses content-block arrays. Moving a cache
breakpoint therefore changes only `cache_control`, not the historical content
representation. OpenAI-compatible, Responses and Gemini routes consume the same
captured desktop transcript; no provider-specific cache feature is required to
preserve the prefix.

Compaction, an explicit conversation edit/rewind, image compatibility fallback,
or changing policy/tools/model/provider can start a new cache segment. Existing
sessions created before snapshot capture may need a cold request during the
transition. Snapshot metadata cannot reconstruct historical context that an old
client never stored. Actual cache hit rates remain provider-reported; these
changes do not establish a 99% rate or repair missing usage counters.

Regression tests compare request prefixes across provider adapters, capture and
reload snapshots, and cover changing host context, retries and tool results.

## Compaction (macOS)

- The threshold is the host's, never the model's. The user sets a share of each
  model's own context window (Settings, default 80%); the optional token
  ceiling `dots.contextCompactionMaxTokens` caps very large windows. Without a
  choice the `cacheAware` policy applies (80% trigger, 55% target).
- The summary is a fork: the exact request the chat just sent (same model,
  account, tools, cache key) plus one instruction, so it is almost all cache
  hits. If that request fails or the model calls a tool, the old archive-only
  summary request runs instead.
- `/compact` runs the same path on demand, always with the chat's own model
  (the archive-only fallback no longer switches to a cheaper one). It is
  offered only when the chat has a user message. While a run is active it is
  queued and honored before that run's next model request. `/compact <message>`
  compacts first, then answers the message.
- DeepSeek has no published window in `/models`, so `providers.json` pins
  `deepseek-chat` to 128000; raise it once the real limit is confirmed.
- Windows/Linux (`shared/`) do not have the fork, `/compact` or the threshold
  setting yet.

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

Anthropic requests carry up to four `cache_control` breakpoints: last system
block, last tool, the last message (new write point) and the message before
the newest assistant turn (the previous request's write point, which keeps
long tool loops inside the 20-block lookback). `prompt_cache_key` is derived
from conversation, project, model, account, tools and compaction segment only;
context revisions and attached roots no longer change it, because that context
is appended to later user turns and the earlier prefix stays valid.

Compaction, an explicit conversation edit/rewind, image compatibility fallback,
or changing policy/tools/model/provider can start a new cache segment. Existing
sessions created before snapshot capture may need a cold request during the
transition. Snapshot metadata cannot reconstruct historical context that an old
client never stored. Actual cache hit rates remain provider-reported; these
changes do not establish a 99% rate or repair missing usage counters.

Regression tests compare request prefixes across provider adapters, capture and
reload snapshots, and cover changing host context, retries and tool results.

## Model choice and subagents (macOS)

- The user's selected model is the parent and is never swapped. In automatic
  mode the router never picks the premium tier (a planner runs on the best
  standard model; premium is used only when nothing cheaper is connected) and
  it decides once per run instead of per tool step, because a tier flip
  between steps is a cold prompt cache.
- Delegated work (`explore` today) runs on the cheapest tier connected, never
  above the parent's tier, on the parent's provider when it offers one
  (`ModelRouter.sideRunModel`).
- Only the main agent starts subagents (up to `maxPerTurn` in parallel); a
  subagent cannot start another, and only its findings enter the main
  transcript, in tool-call order.
- Every subagent request of one parent turn uses the same `prompt_cache_key`
  (`<conversation key>:explore`) and one `RunRoute`, so each step and each
  sibling reuses the model and account of the first step. Failover replaces
  them only when a provider reports a limit.

## Delegated subagents (macOS)

`delegate` hands a self-contained job (code, a document, a plugin action) to a
side run on the cheapest tier, on its own `:delegate` cache key and `RunRoute`.
Its limits:

- Main agent only; a subagent has no `delegate`/`explore`, so runs never nest.
  Coding area with an open workspace only; withheld in plan mode.
- `paths` is required and normalized (no absolute, `~`, `..`, `.git`, `.mem`).
  `write_file` outside them is refused and counted; the parent's tool result
  lists the files the ledger saw written, not what the subagent claims.
- At most 3 per turn. Delegates with overlapping paths (component-wise,
  case-insensitive) run one after another; disjoint ones run in parallel.
- `mode: full` adds `run_command` and plugin/MCP tools. Their effects cannot be
  scoped, so a full delegate (or one claiming the whole workspace) runs alone.
- Approvals and every mutation pass one `DelegateGate`: one prompt at a time,
  no interleaved writes. Calls use the main run's approval, sandbox and change
  tracking. `write_file` still refuses a file that changed since it was read.
- Not covered: a symlink inside a scope that points elsewhere in the workspace,
  and macOS only (Windows/Linux `shared/` have no subagents yet).

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

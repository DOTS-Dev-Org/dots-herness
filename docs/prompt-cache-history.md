# Provider-independent prompt history

Each new user turn captures the current host context once, before the first
provider request. That snapshot is part of the stored model message. Later user
turns, tool calls, retries and continuations keep earlier snapshots unchanged.
The visible conversation still shows the user's original text.

- macOS keeps invariant `core_policy` in the system prefix. Runtime context,
  date, mode, project data, plugin guidance and skill metadata are captured on
  the user message. `promptContextCaptured` survives JSON persistence and
  prevents duplicate capture on continuation. Queued turns use the same rule.
  A new turn captures only the sections that differ from the copy the
  transcript last captured; a section that went away is closed with
  `No longer applies.`. History is never rewritten, and after compaction the
  sections are captured in full again.
- Every captured copy stays in the transcript and is read again on each later
  request, so a section costs its size times how often it moves. macOS therefore
  keeps what moves on its own in small sections: `current_date` and
  `project_brief` apart from `runtime_context`; memory as `user_memory`,
  `learned_rules`, `project_memory` and `task_history`, none of which carries a
  date or a counter. Settings › effective prompt lists, per section, how many copies
  the selected conversation holds and their size
  (`NativeAgentClient.promptSectionChurn`).
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

A skill keeps the id it was first seen under, so the id a conversation already
captured stays valid and history is not rewritten. `SkillCatalog` (macOS and
shared C#) records each id's location in `skills-state.json` and pins the id to
the skill by, in order: the skill folder itself (inode and creation date on
macOS, creation time in C#), the `SKILL.md` path, then a unique display name in
the same skill root. Renaming the folder, the display name or the frontmatter
id, alone or together, does not change the id, and the disabled state follows
it. A new skill that derives an id held by a renamed one gets a `-2` suffix. A
deleted skill gives its id up: it resolves to nothing and is not inherited.

Tool wire names are a pure function of the canonical tool name on every
transport, and tools are sent sorted; adding a tool never renames or reorders
the existing ones.

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
  model's own context window (Settings; the stored default is 90%, target
  = trigger - 25 points). The window comes from the route's provider: the
  documented capacity first, then the live catalog, so a catalog read that fails
  cannot shrink it. A failed catalog read keeps that provider's last good listing.
  The optional `dots.contextReplayBudgetTokens` caps the threshold when set. Without
  it, routes that cache their prompt (Anthropic, Responses) keep the percentage
  alone; a cap-driven prune rewrites history and drops the cached prefix. Other
  routes keep the 32K coding replay cap.
- Every main request logs the numbers behind its compaction verdict
  (`compactionTrace` in the context usage log: window, usable input, trigger,
  target, previous input, route change, fit, prune decision, tool count).
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

## Reuse measurement (all platforms)

One classification is shared by macOS, the C# router, iOS and Android:

| Class | Meaning | In the reuse denominator |
| --- | --- | --- |
| cold | no accepted baseline yet | no |
| expired | gap is at or beyond the baseline TTL | no |
| changed | model, account, endpoint, settings, tool catalog or policy changed | no |
| eligible / hit / miss / partial | unchanged settings inside the TTL; a rewritten message prefix counts with zero reused tokens | yes |
| unknown / inconclusive | counters or TTL missing | no; lowers coverage |

Coverage is measured requests over candidates (everything except cold, expired
and changed). Output ceilings (`max_tokens`, `max_output_tokens`) are not cache
settings. The legacy thinking budget follows the selected effort only, so it
stays constant across a conversation.

A Responses gateway on GPT-5.6+ that reports `cached_tokens` without
`cache_write_tokens` is not accepted as a reuse boundary: its boundary stays
unverified (`previous_boundary_unverified`), so its reuse is not measured. No
retention is assumed; `verifiedPromptCacheTTLSeconds` stays unset until a live
measurement sets it.

## Cache key scope

`prompt_cache_key` names account, project (desktop), provider/API, model, stable
policy revision and tool catalog. It no longer contains the conversation or the
compaction segment, so a new chat or a compacted chat reads the shared
tools+policy prefix instead of rewriting it. Reuse baselines, breakpoints and
diagnostic comparison IDs stay per conversation (`comparisonScope`), so chats
sharing a key never measure against each other. Claude sends no key; its prefix
was already shared.

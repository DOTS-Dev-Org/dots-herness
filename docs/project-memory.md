# Project memory

HerNess keeps three kinds of memory. The rules below hold on macOS (Swift) and on
Windows and Linux (shared C#); `shared/memory-contract/decisions.json` holds the cases
both implementations are tested against.

| Layer | Where | Written by |
|---|---|---|
| Project facts and decisions | `<repo>/.mem/facts.md`, committed | the `remember` tool, the memory vault |
| Personal preferences | app support, `user-facts.md` and the profile | `remember` with scope `user` or `project` |
| Findings, lessons, task notes | app support, `user-memory/<projectId>/` | the background scan on a light model |

## Decisions

- A decision line is `- <key> — [platforms] <statement>. Reason: <reason>`. The tag and the
  reason are optional; `remember` takes them as `platforms` and `reason` and clips the
  statement and the reason separately, so a long statement never cuts its reason off.
  Older decisions without a tag are read for the platforms their words name.
- A decision restated in other words (most content words shared) replaces the old wording.
- `facts.md` holds at most 60 entries. When it is full the oldest decision leaves first;
  the `architecture`, `conventions` and `design-system` entries never leave this way.
- The prompt carries this platform's decisions while they fit about 500 tokens. Past that,
  the ones a request names arrive with the request, and `recall` searches them all,
  whatever their platform.
- Once 12 decisions exist, and again after every 8 more, a light model reviews them: twins
  are merged in `facts.md`, and stale ones are only suggested. A suggestion waits in the
  person's folder (`decision-review.json`) until they keep or remove the decision in the
  memory vault. Memory that was never trusted is not reviewed.

## Trust

Memory that came with a clone is plain data until the person trusts it. The answer is kept
for the checkout's path and for the project's identity: the manifest's `projectId` joined to
the checkout's `origin` remote. A moved checkout or a second clone of the same repository
keeps the answer; a repository that copies the id but was cloned from elsewhere does not.

## Legacy event log

Builds before `facts.md` kept project memory as signed events in `.mem/events/` with a
derived `state.json`. The first time a current macOS build opens a trusted checkout, it
writes what those events still say into `facts.md` and removes them, the `decisions/` notes
and `state.json`. Git history keeps the removed files.

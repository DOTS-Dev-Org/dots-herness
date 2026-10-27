# Cloud runs

"Where HerNess runs" → **Cloud** sends a task to GitHub Actions in the project's own
repository instead of running it on this computer. The run keeps going when the app is
closed; its transcript streams back to the app and its changes land on a
`herness/cloud-<id>` branch.

## How a run works

1. The app reads the project's `origin` remote (it must be on github.com) and the checked-out
   branch. The runner starts from what GitHub has, so unpushed commits are not included.
2. It creates a run record with `POST /api/cloud-runs` using the HerNess account token.
3. It dispatches `.github/workflows/herness-cloud.yml` on that branch with the user's own
   GitHub token. Inputs: `run_id`, `prompt`, `model`, `api_url`, `runner_version`.
4. The workflow checks the branch out without credentials, installs the
   `herness-cloud-linux-x64` runner from the latest DOTS release (checksum verified) and runs
   `HerNessCloud run`. The agent works non-interactively with commands auto-approved: the job
   is a throwaway VM and the checkout holds no push token.
5. The runner posts the transcript to `/api/cloud-runs/<id>/runner/events` every few seconds
   and reads the cancel flag from each answer.
6. A separate step commits any changes, pushes them to `herness/cloud-<first 8 of id>` with the
   job token, then `HerNessCloud complete` reports the status, summary, branch and commit.

## Setup in the repository

| What | Where | Value |
|---|---|---|
| Workflow | `.github/workflows/herness-cloud.yml` | "Install workflow" in the Cloud pane commits it to the default branch. Branches created before that need it merged in. |
| `HERNESS_API_KEY` | Actions **secret** | Model provider API key. |
| `HERNESS_PROVIDER` | Actions variable (optional) | `anthropic` (default), `openai`, `openrouter`, `gemini`, `deepseek`, `groq`, `mistral`, … — any API-key provider with a fixed endpoint. |
| `HERNESS_BASE_URL` | Actions variable (optional) | An OpenAI-compatible endpoint used instead of a catalog provider. |

The model is the provider default unless a model id is set in the Cloud pane.

## Credentials

- **GitHub:** a token saved in the Cloud pane (Keychain), then `GH_TOKEN`/`GITHUB_TOKEN`, then
  `gh auth token`. Dispatch needs Actions write; installing the workflow needs Contents and
  Workflows write. The token is only sent to api.github.com.
- **HerNess API, runner side:** no secret is stored in the repository. Every runner call carries
  a GitHub Actions OIDC token for the `https://dots.net.tr/herness-cloud` audience
  (`CLOUD_RUN_OIDC_AUDIENCE`). The Worker accepts it only when its `repository` claim matches the
  run, its `workflow_ref` is that repository's `herness-cloud.yml`, the event is
  `workflow_dispatch`, and — after the first call pins it — the GitHub run id is the same.
- The runner removes `HERNESS_API_KEY` and the OIDC request variables from its environment
  before the agent starts, so agent commands do not inherit them.

## Limits and retention

- Three queued or running runs per account; prompts up to 32,000 characters.
- Up to 2,000 transcript events per run, 16,000 characters each.
- A run no runner has reached in 30 minutes, or one silent for 7 hours, is marked failed by the
  15-minute cron. Finished runs and transcripts are deleted after 30 days.

## Code map

| Part | File |
|---|---|
| API and retention | `cloudflare/src/routes/api/cloud-runs.ts`, `cloudflare/migrations/0009_cloud_runs.sql` |
| OIDC verification (shared with Marketplace CI) | `cloudflare/src/lib/github_oidc.ts` |
| Runner | `shared/CloudRunner.cs`, `linux/DotsHarness/src/HerNessCloud/Program.cs` |
| Workflow template | `shared/cloud/herness-cloud.yml` (macOS copy kept by `tools/sync_skills.py`) |
| macOS client and UI | `CloudRuns.swift`, `AppModel+Cloud.swift`, `DockCloudView.swift` |
| Release asset | `build-cloud-runner` job in `.github/workflows/release.yml` |

Windows and Linux do not offer the Cloud work location yet; the runner they share is the
headless part only.

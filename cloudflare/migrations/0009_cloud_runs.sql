-- ── HerNess cloud runs ────────────────────────────────────────────────────
-- A cloud run is one agent task executed by the herness-cloud.yml workflow
-- in the user's own GitHub repository. The desktop app creates the row and
-- dispatches the workflow with the user's GitHub token; the runner then
-- authenticates every callback with a GitHub Actions OIDC token whose
-- repository/workflow claims must match the row. The first runner call pins
-- the GitHub run id so no other workflow run can write to the same row.
CREATE TABLE IF NOT EXISTS cloud_runs (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  repository TEXT NOT NULL,
  base_ref TEXT NOT NULL,
  prompt TEXT NOT NULL,
  model TEXT,
  status TEXT NOT NULL DEFAULT 'queued'
    CHECK (status IN ('queued', 'running', 'succeeded', 'failed', 'cancelled')),
  cancel_requested INTEGER NOT NULL DEFAULT 0,
  github_run_id TEXT,
  github_run_url TEXT,
  result_branch TEXT,
  result_commit TEXT,
  summary TEXT,
  error TEXT,
  event_count INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  started_at TEXT,
  finished_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_cloud_runs_user_created ON cloud_runs(user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_cloud_runs_status_updated ON cloud_runs(status, updated_at);

CREATE TABLE IF NOT EXISTS cloud_run_events (
  run_id TEXT NOT NULL REFERENCES cloud_runs(id) ON DELETE CASCADE,
  seq INTEGER NOT NULL,
  kind TEXT NOT NULL,
  text TEXT NOT NULL,
  tool TEXT,
  created_at TEXT NOT NULL,
  PRIMARY KEY (run_id, seq)
);

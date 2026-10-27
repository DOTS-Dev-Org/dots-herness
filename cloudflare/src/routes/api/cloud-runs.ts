// HerNess cloud runs: agent tasks executed by the herness-cloud.yml workflow
// in the user's own GitHub repository.
//
// The desktop app owns the GitHub side (it dispatches the workflow with the
// user's own token); this API only keeps the run record and its event
// stream. User routes take the HerNess account token. Runner routes take a
// GitHub Actions OIDC token whose repository and workflow must match the
// run, and the first runner call pins the GitHub run id to the row.

import { Hono } from "hono";
import type { Context, Next } from "hono";
import { zValidator } from "@hono/zod-validator";
import { z } from "zod";
import type { Env, AppVariables } from "../../env";
import { db, nowIso, uuid } from "../../db/client";
import { requireAuth } from "../../middleware/auth";
import { rateLimit } from "../../middleware/rate-limit";
import { verifyGitHubOIDC, type GitHubOIDCClaims } from "../../lib/github_oidc";

type AppContext = Context<{ Bindings: Env; Variables: AppVariables & { cloudRun: CloudRunRow } }>;

export const CLOUD_RUN_WORKFLOW = ".github/workflows/herness-cloud.yml";
export const DEFAULT_CLOUD_RUN_OIDC_AUDIENCE = "https://dots.net.tr/herness-cloud";
const MAX_ACTIVE_RUNS_PER_USER = 3;
// Workflow-dispatch inputs share a 65,535-character payload limit.
const MAX_PROMPT_CHARS = 32_000;
const MAX_EVENTS_PER_RUN = 2_000;
const MAX_EVENT_TEXT_CHARS = 16_000;
const MAX_EVENTS_PER_BATCH = 50;
const EVENT_PAGE_SIZE = 200;
const QUEUED_TIMEOUT_MS = 30 * 60 * 1000;
// GitHub-hosted jobs stop at six hours; an hour of slack covers the push step.
const RUNNING_TIMEOUT_MS = 7 * 60 * 60 * 1000;
const RETENTION_MS = 30 * 24 * 60 * 60 * 1000;

const REPOSITORY_PATTERN = /^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})\/[A-Za-z0-9._-]{1,100}$/;
const REF_PATTERN = /^(?!.*\.\.)(?!\/)[A-Za-z0-9._\/-]{1,200}(?<!\/)$/;
const MODEL_PATTERN = /^[A-Za-z0-9._:\/-]{1,120}$/;
const TERMINAL = new Set(["succeeded", "failed", "cancelled"]);

export type CloudRunRow = {
  id: string;
  user_id: string;
  repository: string;
  base_ref: string;
  prompt: string;
  model: string | null;
  status: "queued" | "running" | "succeeded" | "failed" | "cancelled";
  cancel_requested: number;
  github_run_id: string | null;
  github_run_url: string | null;
  result_branch: string | null;
  result_commit: string | null;
  summary: string | null;
  error: string | null;
  event_count: number;
  created_at: string;
  updated_at: string;
  started_at: string | null;
  finished_at: string | null;
};

type CloudRunEventRow = { seq: number; kind: string; text: string; tool: string | null; created_at: string };

function publicRun(row: CloudRunRow) {
  return {
    id: row.id,
    repository: row.repository,
    base_ref: row.base_ref,
    prompt: row.prompt,
    model: row.model,
    status: row.status,
    cancel_requested: row.cancel_requested === 1,
    github_run_id: row.github_run_id,
    github_run_url: row.github_run_url,
    result_branch: row.result_branch,
    result_commit: row.result_commit,
    summary: row.summary,
    error: row.error,
    event_count: row.event_count,
    created_at: row.created_at,
    updated_at: row.updated_at,
    started_at: row.started_at,
    finished_at: row.finished_at,
  };
}

const createSchema = z.object({
  repository: z.string().trim().regex(REPOSITORY_PATTERN),
  base_ref: z.string().trim().regex(REF_PATTERN),
  prompt: z.string().trim().min(1).max(MAX_PROMPT_CHARS),
  model: z.string().trim().regex(MODEL_PATTERN).optional(),
}).strict();

const cancelSchema = z.object({
  // Set by the app when the workflow dispatch itself failed.
  error: z.string().trim().min(1).max(500).optional(),
}).strict();

const eventSchema = z.object({
  kind: z.enum(["user", "assistant", "tool", "system", "plan", "status"]),
  text: z.string().transform((value) => value.slice(0, MAX_EVENT_TEXT_CHARS)),
  tool: z.string().trim().max(120).optional(),
}).strict();

const eventsSchema = z.object({
  events: z.array(eventSchema).max(MAX_EVENTS_PER_BATCH).default([]),
}).strict();

const completeSchema = z.object({
  status: z.enum(["succeeded", "failed", "cancelled"]),
  summary: z.string().max(4_000).optional(),
  error: z.string().max(2_000).optional(),
  branch: z.string().trim().regex(REF_PATTERN).optional(),
  commit: z.string().trim().regex(/^[0-9a-f]{40}$/).optional(),
}).strict();

async function loadRun(env: Env, id: string): Promise<CloudRunRow | null> {
  return db(env).prepare("SELECT * FROM cloud_runs WHERE id = ?").bind(id).first<CloudRunRow>();
}

async function ownedRun(c: AppContext): Promise<CloudRunRow | null> {
  const run = await loadRun(c.env, c.req.param("id") || "");
  return run && run.user_id === c.get("user").id ? run : null;
}

/** Repository/workflow/run checks for a runner token; pure so it can be unit-tested. */
export function runnerClaimsMatch(run: Pick<CloudRunRow, "repository" | "github_run_id">, claims: GitHubOIDCClaims): boolean {
  const repository = claims.repository || "";
  if (repository.toLowerCase() !== run.repository.toLowerCase()) return false;
  if (claims.sub && !claims.sub.toLowerCase().startsWith(`repo:${run.repository.toLowerCase()}:`)) return false;
  if ((claims.workflow_ref || "").split("@", 1)[0] !== `${repository}/${CLOUD_RUN_WORKFLOW}`) return false;
  if (claims.event_name !== "workflow_dispatch" || !claims.run_id) return false;
  return run.github_run_id === null || run.github_run_id === claims.run_id;
}

async function requireRunner(c: AppContext, next: Next) {
  const audience = (c.env.CLOUD_RUN_OIDC_AUDIENCE || DEFAULT_CLOUD_RUN_OIDC_AUDIENCE).trim();
  const claims = await verifyGitHubOIDC(c.req.header("X-HerNess-OIDC-Token") || "", audience);
  const id = c.req.param("id") || "";
  let run = claims ? await loadRun(c.env, id) : null;
  if (!claims || !run || !runnerClaimsMatch(run, claims)) return c.json({ error: "forbidden" }, 403);
  if (run.github_run_id === null) {
    // Pin the first GitHub run that reaches this row; a concurrent second run loses here.
    const url = `https://github.com/${claims.repository}/actions/runs/${claims.run_id}`;
    await db(c.env).prepare(
      `UPDATE cloud_runs SET github_run_id = ?, github_run_url = ?, updated_at = ?
        WHERE id = ? AND github_run_id IS NULL`
    ).bind(claims.run_id, url, nowIso(), id).run();
    run = await loadRun(c.env, id);
    if (!run || run.github_run_id !== claims.run_id) return c.json({ error: "forbidden" }, 403);
  }
  c.set("cloudRun", run);
  await next();
}

const cloudRunsApi = new Hono<{ Bindings: Env; Variables: AppVariables & { cloudRun: CloudRunRow } }>();

cloudRunsApi.post(
  "/",
  requireAuth,
  rateLimit({ limit: 30, windowSeconds: 3600, keyPrefix: "cloud-runs:create" }),
  zValidator("json", createSchema),
  async (c) => {
    const user = c.get("user");
    const body = c.req.valid("json");
    const active = await db(c.env).prepare(
      "SELECT COUNT(*) AS count FROM cloud_runs WHERE user_id = ? AND status IN ('queued', 'running')"
    ).bind(user.id).first<{ count: number }>();
    if ((active?.count ?? 0) >= MAX_ACTIVE_RUNS_PER_USER) {
      return c.json({ error: "cloud_run_limit", limit: MAX_ACTIVE_RUNS_PER_USER }, 429);
    }
    const id = uuid();
    const now = nowIso();
    await db(c.env).prepare(
      `INSERT INTO cloud_runs (id, user_id, repository, base_ref, prompt, model, created_at, updated_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?)`
    ).bind(id, user.id, body.repository, body.base_ref, body.prompt, body.model ?? null, now, now).run();
    const run = await loadRun(c.env, id);
    return c.json({ run: publicRun(run!) }, 201);
  },
);

cloudRunsApi.get("/", requireAuth, async (c) => {
  const rows = await db(c.env).prepare(
    "SELECT * FROM cloud_runs WHERE user_id = ? ORDER BY created_at DESC LIMIT 50"
  ).bind(c.get("user").id).all<CloudRunRow>();
  return c.json({ runs: (rows.results || []).map(publicRun) });
});

cloudRunsApi.get("/:id", requireAuth, async (c) => {
  const run = await ownedRun(c);
  if (!run) return c.json({ error: "not_found" }, 404);
  const after = Math.max(0, Number.parseInt(c.req.query("after") || "0", 10) || 0);
  const events = await db(c.env).prepare(
    `SELECT seq, kind, text, tool, created_at FROM cloud_run_events
      WHERE run_id = ? AND seq > ? ORDER BY seq ASC LIMIT ?`
  ).bind(run.id, after, EVENT_PAGE_SIZE).all<CloudRunEventRow>();
  return c.json({ run: publicRun(run), events: events.results || [] });
});

cloudRunsApi.post("/:id/cancel", requireAuth, zValidator("json", cancelSchema), async (c) => {
  const run = await ownedRun(c);
  if (!run) return c.json({ error: "not_found" }, 404);
  if (TERMINAL.has(run.status)) return c.json({ run: publicRun(run) });
  const now = nowIso();
  const { error } = c.req.valid("json");
  if (run.status === "queued" && run.github_run_id === null) {
    // No runner has reached the row yet; close it now. A runner that starts
    // later sees cancel_requested on its first call and stops.
    await db(c.env).prepare(
      `UPDATE cloud_runs SET status = ?, error = ?, cancel_requested = 1, updated_at = ?, finished_at = ?
        WHERE id = ? AND status = 'queued'`
    ).bind(error ? "failed" : "cancelled", error ?? null, now, now, run.id).run();
  } else {
    await db(c.env).prepare(
      "UPDATE cloud_runs SET cancel_requested = 1, updated_at = ? WHERE id = ?"
    ).bind(now, run.id).run();
  }
  return c.json({ run: publicRun((await loadRun(c.env, run.id))!) });
});

cloudRunsApi.post("/:id/runner/events", requireRunner, zValidator("json", eventsSchema), async (c) => {
  const run = c.get("cloudRun");
  if (TERMINAL.has(run.status)) return c.json({ accepted: 0, cancel_requested: true });
  const now = nowIso();
  const remaining = Math.max(0, MAX_EVENTS_PER_RUN - run.event_count);
  const events = c.req.valid("json").events.slice(0, remaining);
  const database = db(c.env);
  const statements = events.map((event, index) => database.prepare(
    `INSERT INTO cloud_run_events (run_id, seq, kind, text, tool, created_at)
     VALUES (?, (SELECT event_count FROM cloud_runs WHERE id = ?) + ?, ?, ?, ?, ?)`
  ).bind(run.id, run.id, index + 1, event.kind, event.text, event.tool ?? null, now));
  statements.push(database.prepare(
    `UPDATE cloud_runs
        SET event_count = event_count + ?,
            status = CASE WHEN status = 'queued' THEN 'running' ELSE status END,
            started_at = COALESCE(started_at, ?),
            updated_at = ?
      WHERE id = ?`
  ).bind(events.length, now, now, run.id));
  await database.batch(statements);
  return c.json({ accepted: events.length, cancel_requested: run.cancel_requested === 1 });
});

cloudRunsApi.post("/:id/runner/complete", requireRunner, zValidator("json", completeSchema), async (c) => {
  const run = c.get("cloudRun");
  if (TERMINAL.has(run.status)) return c.json({ run: publicRun(run) });
  const body = c.req.valid("json");
  const now = nowIso();
  await db(c.env).prepare(
    `UPDATE cloud_runs
        SET status = ?, summary = ?, error = ?, result_branch = ?, result_commit = ?,
            started_at = COALESCE(started_at, ?), updated_at = ?, finished_at = ?
      WHERE id = ?`
  ).bind(
    body.status,
    body.summary ?? null,
    body.error ?? null,
    body.branch ?? null,
    body.commit ?? null,
    now,
    now,
    now,
    run.id,
  ).run();
  return c.json({ run: publicRun((await loadRun(c.env, run.id))!) });
});

/** Fails runs whose runner never arrived or went silent. Runs from the 15-minute cron. */
export async function expireStaleCloudRuns(env: Env): Promise<number> {
  if (!env.DOTSHERNESS_DB) return 0;
  const now = Date.now();
  const nowText = new Date(now).toISOString();
  const database = db(env);
  const results = await database.batch([
    database.prepare(
      `UPDATE cloud_runs SET status = 'failed', error = 'runner_not_started', updated_at = ?, finished_at = ?
        WHERE status = 'queued' AND created_at < ?`
    ).bind(nowText, nowText, new Date(now - QUEUED_TIMEOUT_MS).toISOString()),
    database.prepare(
      `UPDATE cloud_runs SET status = 'failed', error = 'runner_timed_out', updated_at = ?, finished_at = ?
        WHERE status = 'running' AND updated_at < ?`
    ).bind(nowText, nowText, new Date(now - RUNNING_TIMEOUT_MS).toISOString()),
  ]);
  return results.reduce((total, result) => total + (result.meta?.changes ?? 0), 0);
}

/** Daily retention: finished runs and their transcripts are kept for 30 days. */
export async function purgeOldCloudRuns(env: Env): Promise<number> {
  if (!env.DOTSHERNESS_DB) return 0;
  const cutoff = new Date(Date.now() - RETENTION_MS).toISOString();
  const database = db(env);
  const results = await database.batch([
    database.prepare(
      `DELETE FROM cloud_run_events WHERE run_id IN
         (SELECT id FROM cloud_runs WHERE finished_at IS NOT NULL AND finished_at < ?)`
    ).bind(cutoff),
    database.prepare("DELETE FROM cloud_runs WHERE finished_at IS NOT NULL AND finished_at < ?").bind(cutoff),
  ]);
  return results[1]?.meta?.changes ?? 0;
}

export { cloudRunsApi };

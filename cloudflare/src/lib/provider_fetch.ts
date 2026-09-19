import type { UsageWindowInput } from "./users";
import { vpsCacheBust } from "./vps_usage";

export type FetchUsageResult = {
  provider: string;
  ok: boolean;
  used_percent?: number | null;
  used?: string | null;
  total?: string | null;
  resets_at?: string | null;
  windows?: UsageWindowInput[];
  plan_name?: string | null;
  error?: string;
};

const MINIMAX_TOKEN_PLAN_ENDPOINTS = [
  "https://api.minimax.io/v1/token_plan/remains",
  "https://www.minimax.io/v1/token_plan/remains",
  "https://api.minimaxi.com/v1/token_plan/remains",
  "https://www.minimaxi.com/v1/token_plan/remains",
  "https://platform.minimax.io/v1/api/openplatform/coding_plan/remains",
] as const;

function pctFromUsedTotal(used: number, total: number): number | null {
  if (total <= 0) return null;
  return Math.round((used / total) * 100);
}

function readNum(val: unknown): number | null {
  if (typeof val === "number" && Number.isFinite(val)) return val;
  if (typeof val === "string") {
    const n = parseFloat(val.replace(/[^0-9.]/g, ""));
    return Number.isFinite(n) ? n : null;
  }
  return null;
}

function epochToIso(value: unknown): string | null {
  const n = readNum(value);
  if (n == null) return null;
  const ms = n > 1e12 ? n : n * 1000;
  const d = new Date(ms);
  return Number.isNaN(d.getTime()) ? null : d.toISOString();
}

function isWeeklyActive(status: unknown): boolean {
  if (status === 1 || status === true) return true;
  if (typeof status === "string") {
    const s = status.toLowerCase();
    return s === "1" || s === "active" || s === "enabled";
  }
  return false;
}

function isIntervalActive(status: unknown): boolean {
  if (status == null) return true;
  if (status === 3 || status === false) return false;
  if (typeof status === "string") {
    const s = status.toLowerCase();
    return s !== "3" && s !== "inactive" && s !== "disabled";
  }
  return true;
}

/** token_plan/remains: önce remaining_percent, sonra explicit remaining, en son usage_count (used). */
function usedPercentForWindow(
  entry: Record<string, unknown>,
  prefix: "current_interval" | "current_weekly"
): number | null {
  const remainingPercent = readNum(entry[`${prefix}_remaining_percent`]);
  if (remainingPercent != null) {
    return Math.max(0, Math.min(100, Math.round(100 - remainingPercent)));
  }

  const total = readNum(entry[`${prefix}_total_count`]);
  const explicitRemaining =
    readNum(entry[`${prefix}_remaining_count`]) ??
    readNum(entry[`${prefix}_remains_count`]);
  if (total != null && total > 0 && explicitRemaining != null) {
    return pctFromUsedTotal(Math.max(0, Math.round(total - explicitRemaining)), total);
  }

  const usageCount = readNum(entry[`${prefix}_usage_count`]);
  if (total != null && total > 0 && usageCount != null) {
    return pctFromUsedTotal(Math.max(0, Math.round(usageCount)), total);
  }

  return null;
}

function windowFromUsedPercent(
  windowName: string,
  label: string,
  usedPercent: number,
  resetsAt: string | null
): UsageWindowInput {
  return {
    window: windowName,
    label,
    used_percent: usedPercent,
    used: String(usedPercent),
    total: "100",
    resets_at: resetsAt,
  };
}

function pickModelEntry(remains: unknown[]): Record<string, unknown> | undefined {
  for (const item of remains) {
    if (!item || typeof item !== "object") continue;
    const row = item as Record<string, unknown>;
    const name = row.model ?? row.model_name;
    if (name === "general") return row;
  }
  return remains.find((m) => m && typeof m === "object") as Record<string, unknown> | undefined;
}

function windowsFromModelEntry(entry: Record<string, unknown>): UsageWindowInput[] {
  const windows: UsageWindowInput[] = [];

  if (isIntervalActive(entry.current_interval_status)) {
    const usedPercent = usedPercentForWindow(entry, "current_interval");
    if (usedPercent != null) {
      windows.push(
        windowFromUsedPercent(
          "5h",
          "5h limit",
          usedPercent,
          epochToIso(entry.end_time) ?? epochToIso(entry.remains_time)
        )
      );
    }
  }

  const weeklyTotal = readNum(entry.current_weekly_total_count);
  const weeklyRemainingPercent = readNum(entry.current_weekly_remaining_percent);
  const weeklyHasSignal =
    (weeklyTotal != null && weeklyTotal > 0) || weeklyRemainingPercent != null;

  if (isWeeklyActive(entry.current_weekly_status) && weeklyHasSignal) {
    const usedPercent = usedPercentForWindow(entry, "current_weekly");
    if (usedPercent != null) {
      windows.push(
        windowFromUsedPercent(
          "weekly",
          "Weekly limit",
          usedPercent,
          epochToIso(entry.weekly_end_time)
        )
      );
    }
  }

  return windows;
}

function windowsFromTopLevel(body: Record<string, unknown>): UsageWindowInput[] {
  const windows: UsageWindowInput[] = [];

  const intervalUsed = usedPercentForWindow(body, "current_interval");
  if (intervalUsed != null) {
    windows.push(
      windowFromUsedPercent(
        "5h",
        "5h limit",
        intervalUsed,
        epochToIso(body.end_time) ?? epochToIso(body.remains_time)
      )
    );
  }

  const weeklyTotal = readNum(body.current_weekly_total_count);
  const weeklyRemainingPercent = readNum(body.current_weekly_remaining_percent);
  if (
    isWeeklyActive(body.current_weekly_status) &&
    ((weeklyTotal != null && weeklyTotal > 0) || weeklyRemainingPercent != null)
  ) {
    const weeklyUsed = usedPercentForWindow(body, "current_weekly");
    if (weeklyUsed != null) {
      windows.push(
        windowFromUsedPercent(
          "weekly",
          "Weekly limit",
          weeklyUsed,
          epochToIso(body.weekly_end_time)
        )
      );
    }
  }

  return windows;
}

/** MiniMax Token Plan — token_plan/remains ve legacy coding_plan/remains yanıtlarını parse eder. */
export function parseMinimaxTokenPlanRemains(body: unknown): {
  used_percent: number | null;
  used: string | null;
  total: string | null;
  resets_at: string | null;
  windows: UsageWindowInput[];
  plan_name: string | null;
} {
  const empty = {
    used_percent: null as number | null,
    used: null as string | null,
    total: null as string | null,
    resets_at: null as string | null,
    windows: [] as UsageWindowInput[],
    plan_name: null as string | null,
  };

  const b = (body && typeof body === "object" ? body : {}) as Record<string, unknown>;
  const baseResp = b.base_resp as Record<string, unknown> | undefined;
  const statusCode = readNum(baseResp?.status_code);
  if (statusCode != null && statusCode !== 0) return empty;

  const plan_name =
    typeof b.current_subscribe_title === "string"
      ? b.current_subscribe_title
      : typeof b.plan_name === "string"
        ? b.plan_name
        : null;

  const remains = Array.isArray(b.model_remains) ? b.model_remains : [];
  const entry = remains.length > 0 ? pickModelEntry(remains) : undefined;

  let windows: UsageWindowInput[] = [];
  if (entry) {
    windows = windowsFromModelEntry(entry);
  }
  if (windows.length === 0) {
    windows = windowsFromTopLevel(b);
  }

  const primary = windows.find((w) => w.window === "5h") ?? windows[0];
  return {
    used_percent: primary?.used_percent ?? null,
    used: primary?.used ?? null,
    total: primary?.total ?? "100",
    resets_at: primary?.resets_at ?? null,
    windows,
    plan_name,
  };
}

async function fetchJson(
  url: string,
  init?: RequestInit
): Promise<{ ok: boolean; status: number; body: unknown; headers: Headers }> {
  const resp = await fetch(url, { ...init, signal: AbortSignal.timeout(10000) });
  let body: unknown = null;
  try {
    body = await resp.json();
  } catch {
    body = null;
  }
  return { ok: resp.ok, status: resp.status, body, headers: resp.headers };
}

async function fetchMinimaxUsage(apiKey: string): Promise<FetchUsageResult> {
  let lastStatus = 0;
  let sawOkBody = false;

  for (const url of MINIMAX_TOKEN_PLAN_ENDPOINTS) {
    const r = await fetchJson(url, {
      headers: {
        Authorization: `Bearer ${apiKey}`,
        "Content-Type": "application/json",
      },
    });
    lastStatus = r.status;
    if (!r.ok) continue;

    const baseResp = (r.body as { base_resp?: { status_code?: number } })?.base_resp;
    const statusCode = readNum(baseResp?.status_code);
    if (statusCode != null && statusCode !== 0) continue;

    sawOkBody = true;
    const parsed = parseMinimaxTokenPlanRemains(r.body);
    if (parsed.windows.length === 0) continue;

    const primary = parsed.windows.find((w) => w.window === "5h") ?? parsed.windows[0];
    return {
      provider: "minimax",
      ok: true,
      used: primary.used ?? parsed.used,
      total: primary.total ?? parsed.total,
      used_percent: primary.used_percent ?? parsed.used_percent,
      resets_at: primary.resets_at ?? parsed.resets_at,
      windows: parsed.windows,
      plan_name: parsed.plan_name,
    };
  }

  return {
    provider: "minimax",
    ok: false,
    error: sawOkBody
      ? "minimax_parse_empty"
      : lastStatus > 0
        ? `minimax_http_${lastStatus}`
        : "minimax_no_usage_data",
  };
}

export async function fetchUpstreamUsage(
  providerId: string,
  apiKey: string
): Promise<FetchUsageResult> {
  // Scan-bağlantısı sentinel'i — gerçek API key yok, upstream fetch yapılamaz
  if (apiKey === "scan") {
    return { provider: providerId, ok: false, error: "scan_provider_no_key" };
  }
  try {
    if (providerId === "openai" || providerId === "codex") {
      const today = new Date().toISOString().slice(0, 10);
      const r = await fetchJson(`https://api.openai.com/v1/usage?date=${today}`, {
        headers: { Authorization: `Bearer ${apiKey}` },
      });
      if (!r.ok) return { provider: providerId, ok: false, error: `openai_http_${r.status}` };
      const data =
        (r.body as { data?: Array<{ n_context_tokens_total?: number; n_generated_tokens_total?: number }> })
          ?.data || [];
      const tokens = data.reduce(
        (sum, d) => sum + (d.n_context_tokens_total || 0) + (d.n_generated_tokens_total || 0),
        0
      );
      return { provider: providerId, ok: true, used: `${tokens} tokens`, total: null, used_percent: null };
    }

    if (providerId === "claude") {
      const r = await fetchJson(
        "https://api.anthropic.com/v1/organizations/usage_report/messages",
        {
          headers: {
            "x-api-key": apiKey,
            "anthropic-version": "2023-06-01",
          },
        }
      );
      if (!r.ok) return { provider: providerId, ok: false, error: `anthropic_http_${r.status}` };
      // Key doğrulandı ama gerçek kullanım rakamı yok — usage döndürme ki scan verisi ezilmesin.
      return { provider: providerId, ok: true };
    }

    if (providerId === "minimax") {
      return fetchMinimaxUsage(apiKey);
    }

    return { provider: providerId, ok: false, error: "unsupported" };
  } catch (err) {
    return {
      provider: providerId,
      ok: false,
      error: err instanceof Error ? err.message : "fetch_failed",
    };
  }
}

import { normalizeSyncInterval } from "./sync_interval";

/** Gerçek kullanım rakamı var mı? "API aktif" gibi rakamsız sonuçlar upsert edilmez. */
function hasUsageNumbers(result: FetchUsageResult): boolean {
  return Boolean(
    result.windows?.length ||
      result.used_percent != null ||
      (result.used != null && /\d/.test(result.used))
  );
}

export async function markProviderRefreshStale(
  env: Parameters<typeof import("./users").upsertProviderUsage>[0],
  userId: string,
  providerId: string,
  connectionId: string,
  note: string
): Promise<void> {
  const { db } = await import("../db/client");
  const now = new Date().toISOString();
  await db(env)
    .prepare(
      `INSERT INTO provider_subscriptions (
         connection_id, user_id, provider_id, last_refreshed_at, refresh_status, refresh_note, source_updated_at
       ) VALUES (?, ?, ?, ?, 'stale', ?, ?)
       ON CONFLICT(connection_id) DO UPDATE SET
         last_refreshed_at = excluded.last_refreshed_at,
         refresh_status = 'stale',
         refresh_note = excluded.refresh_note,
         source_updated_at = excluded.source_updated_at`
    )
    .bind(connectionId, userId, providerId, now, note.slice(0, 500), now)
    .run();
  await vpsCacheBust(env, { prefix: `subs-meta:${userId}` });
}

export async function refreshStaleProviderUsage(
  env: Parameters<typeof import("./users").upsertProviderUsage>[0],
  workspaceId: string,
  userId: string,
  userEmail: string,
  connectedProviderIds: string[],
  existingUsage: Map<string, { observed_at: string | null; source: string | null }>
): Promise<void> {
  const { upsertProviderUsageBatch } = await import("./users");
  const { db } = await import("../db/client");
  const { mapPlatformToProviderId } = await import("./users");

  const { resolveUserKeyValue } = await import("./user_key_crypto");

  const { results: connectionRows } = await db(env)
    .prepare(
      `SELECT id, user_email, provider, key_value, sync_interval_secs
         FROM user_connections WHERE user_id = ? ORDER BY created_at DESC`
    )
    .bind(userId)
    .all<{
      id: string;
      user_email: string;
      provider: string;
      key_value: string;
      sync_interval_secs: number | null;
    }>();

  const connectionsByProvider = new Map<
    string,
    Array<{ connection_id: string; key_value: string; sync_interval_secs: number }>
  >();
  for (const row of connectionRows || []) {
    const pid = mapPlatformToProviderId(row.provider);
    if (!connectedProviderIds.includes(pid)) continue;
    let plain: string | null = null;
    try {
      plain = await resolveUserKeyValue(env, userId, row.user_email, row.key_value, {
        reencryptKeyId: row.id,
        db: db(env),
      });
    } catch {
      continue;
    }
    if (!plain) continue;
    const list = connectionsByProvider.get(pid) || [];
    list.push({
      connection_id: row.id,
      key_value: plain,
      sync_interval_secs: normalizeSyncInterval(row.sync_interval_secs),
    });
    connectionsByProvider.set(pid, list);
  }

  const now = Date.now();
  const toRefresh: Array<{
    provider_id: string;
    connection_id: string;
    key_value: string;
  }> = [];
  for (const [pid, connections] of connectionsByProvider) {
    for (const conn of connections) {
      const existing = existingUsage.get(conn.connection_id);
      const isStale =
        !existing || !existing.observed_at ||
        now - new Date(existing.observed_at).getTime() > conn.sync_interval_secs * 1000;
      if (isStale) {
        toRefresh.push({ provider_id: pid, connection_id: conn.connection_id, key_value: conn.key_value });
      }
    }
  }

  const inputs = (await Promise.all(
    toRefresh.map(async ({ provider_id, connection_id, key_value }) => {
      try {
        const result = await fetchUpstreamUsage(provider_id, key_value);
        if (!result.ok || !hasUsageNumbers(result)) return null;
        return {
          workspace_id: workspaceId,
          provider_id,
          connection_id,
          user_id: userId,
          user_email: userEmail,
          used_percent: result.used_percent ?? null,
          used: result.used ?? null,
          total: result.total ?? null,
          resets_at: result.resets_at ?? null,
          windows: result.windows,
          source: "api_key",
        };
      } catch {
        return null;
      }
    })
  )).filter((input): input is NonNullable<typeof input> => input !== null);

  if (inputs.length > 0) await upsertProviderUsageBatch(env, inputs);
}

export async function syncProviderUsageFromKey(
  env: Parameters<typeof import("./users").upsertProviderUsage>[0],
  workspaceId: string,
  userId: string,
  userEmail: string,
  providerId: string,
  apiKey: string,
  connectionId: string
): Promise<FetchUsageResult> {
  const result = await fetchUpstreamUsage(providerId, apiKey);
  if (!result.ok || !hasUsageNumbers(result)) {
    return result;
  }

  try {
    const { upsertProviderUsage } = await import("./users");
    await upsertProviderUsage(env, {
      workspace_id: workspaceId,
      provider_id: providerId,
      connection_id: connectionId,
      user_id: userId,
      user_email: userEmail,
      used_percent: result.used_percent ?? null,
      used: result.used ?? null,
      total: result.total ?? null,
      resets_at: result.resets_at ?? null,
      windows: result.windows,
      source: "api_key",
    });

    if (result.plan_name) {
      const { db, nowIso } = await import("../db/client");
      const { recordSubscriptionHistory } = await import("./usage");
      const now = nowIso();
      await db(env)
        .prepare(
          `INSERT INTO provider_subscriptions (
             connection_id, user_id, provider_id, plan_name, source, source_updated_at,
             last_refreshed_at, refresh_status, refresh_note
           ) VALUES (?, ?, ?, ?, 'api', ?, ?, 'fresh', NULL)
           ON CONFLICT(connection_id) DO UPDATE SET
             plan_name = excluded.plan_name,
             source = excluded.source,
             source_updated_at = excluded.source_updated_at,
             last_refreshed_at = excluded.last_refreshed_at,
             refresh_status = 'fresh',
             refresh_note = NULL`
        )
        .bind(connectionId, userId, providerId, result.plan_name, now, now)
        .run();

      await vpsCacheBust(env, { prefix: `subs-meta:${userId}` });

      const sub = await db(env)
        .prepare(
          `SELECT price_usd_cents, billing_cycle FROM provider_subscriptions
            WHERE connection_id = ?`
        )
        .bind(connectionId)
        .first<{ price_usd_cents: number | null; billing_cycle: string | null }>();

      await recordSubscriptionHistory(env, {
        workspaceId,
        userId,
        providerId,
        priceUsdCents: sub?.price_usd_cents ?? null,
        billingCycle: sub?.billing_cycle ?? "monthly",
        planName: result.plan_name,
        source: "api",
        observedAt: now,
      });
    }
  } catch (err) {
    return {
      ...result,
      ok: false,
      error: err instanceof Error ? `db_sync_failed: ${err.message}` : "db_sync_failed",
    };
  }

  return result;
}

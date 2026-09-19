import type { Env } from "../env";
import { issueVpsClientToken } from "./vps_client_token";

/**
 * Usage mirror to the self-hosted VPS (Redis live state + Postgres window rollups).
 *
 * Why it exists: D1 bills every row and index write, and usage samples arrive
 * per provider per poll. Redis absorbs the per-minute overwrite for free, and a
 * Postgres row is only written when a provider's window actually rolls over —
 * so persistent write volume tracks window count, not polling frequency.
 *
 * VPS is authoritative for live usage. D1 keeps only settings and a stale
 * fallback copy for deployments where the VPS is not configured.
 */

export type VpsUsageWindow = {
  window: string;
  label?: string | null;
  used_percent?: number | null;
  used?: string | null;
  total?: string | null;
  resets_at?: string | null;
};

export type VpsUsageItem = {
  workspace_id: string;
  user_id: string;
  provider_id: string;
  connection_id?: string | null;
  used_percent?: number | null;
  used?: string | null;
  total?: string | null;
  source?: string | null;
  observed_at?: string | null;
  windows?: VpsUsageWindow[];
};

export type VpsProviderPresence = {
  id: string;
  name: string;
  brand_color: string | null;
};

export function vpsConfigured(env: Env): boolean {
  return Boolean(env.VPS_API_URL && env.VPS_API_SECRET);
}

/**
 * Fire the mirror write. The boolean lets synchronous batch callers with a
 * local retry queue distinguish "accepted by VPS" from a logged failure;
 * waitUntil callers can continue treating this as best-effort.
 */
export async function mirrorUsageToVps(env: Env, items: VpsUsageItem[]): Promise<boolean> {
  if (!vpsConfigured(env) || !items.length) return true;

  try {
    const res = await fetch(`${env.VPS_API_URL}/ingest`, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        authorization: `Bearer ${env.VPS_API_SECRET}`,
      },
      body: JSON.stringify({ items }),
      signal: AbortSignal.timeout(10_000),
    });
    if (!res.ok) {
      // Do not copy an upstream response body into Worker logs: the mirror
      // payload is user usage data and the provider may echo identifiers.
      console.warn("vps mirror failed", res.status);
      return false;
    }
    return true;
  } catch (err) {
    console.warn("vps mirror error", err instanceof Error ? err.message : err);
    return false;
  }
}

async function vpsFetch(
  env: Env,
  path: string,
  init?: RequestInit & { timeoutMs?: number }
): Promise<Response> {
  const { timeoutMs = 5_000, ...rest } = init ?? {};
  return fetch(`${env.VPS_API_URL}${path}`, {
    ...rest,
    headers: {
      "content-type": "application/json",
      authorization: `Bearer ${env.VPS_API_SECRET}`,
      ...(rest.headers as Record<string, string> | undefined),
    },
    signal: AbortSignal.timeout(timeoutMs),
  });
}

/** Durable connection metadata mirror, separate from expiring live usage. */
export async function putVpsProviderPresence(
  env: Env,
  input: {
    userId: string;
    workspaceId: string;
    connectedProviders: VpsProviderPresence[];
  },
): Promise<boolean> {
  if (!vpsConfigured(env)) return true;
  try {
    const res = await vpsFetch(env, "/presence", {
      method: "PUT",
      body: JSON.stringify({
        user_id: input.userId,
        workspace_id: input.workspaceId,
        connected_providers: input.connectedProviders,
      }),
      timeoutMs: 5_000,
    });
    if (!res.ok) {
      console.warn("vps provider presence sync failed", res.status);
      return false;
    }
    return true;
  } catch (err) {
    console.warn("vps provider presence sync error", err instanceof Error ? err.message : err);
    return false;
  }
}

/**
 * Live snapshot read. Returns undefined (not null) when the store can't answer,
 * so the caller can tell "no snapshot for this user" apart from "ask D1
 * instead" — treating an outage as an empty snapshot would blank the user's
 * dashboard.
 */
export async function getVpsSnapshot(
  env: Env,
  userId: string
): Promise<Record<string, unknown> | null | undefined> {
  if (!vpsConfigured(env)) return undefined;
  try {
    const res = await vpsFetch(env, `/snapshot?user_id=${encodeURIComponent(userId)}`);
    if (!res.ok) return undefined;
    const data = (await res.json()) as { snapshot?: Record<string, unknown> | null };
    return data.snapshot ?? null;
  } catch {
    return undefined;
  }
}

/** Best-effort snapshot write; never throws into the request path. */
export async function putVpsSnapshot(
  env: Env,
  userId: string,
  snapshot: unknown
): Promise<boolean> {
  if (!vpsConfigured(env)) return true;
  try {
    const res = await vpsFetch(env, "/snapshot", {
      method: "POST",
      body: JSON.stringify({ user_id: userId, snapshot }),
    });
    return res.ok;
  } catch (err) {
    console.warn("vps snapshot write failed", err instanceof Error ? err.message : err);
    return false;
  }
}

/**
 * Cache-aside around a D1 read. On any cache trouble the loader still runs, so
 * the worst case is the query we would have made anyway.
 */
export async function vpsCached<T>(
  env: Env,
  key: string,
  ttlSecs: number,
  loader: () => Promise<T>
): Promise<T> {
  if (!vpsConfigured(env)) return loader();
  try {
    const res = await vpsFetch(env, `/cache?key=${encodeURIComponent(key)}`);
    if (res.ok) {
      const data = (await res.json()) as { hit?: boolean; value?: T };
      if (data.hit) return data.value as T;
    }
  } catch {
    /* fall through to the loader */
  }

  const value = await loader();
  try {
    await vpsFetch(env, "/cache", {
      method: "POST",
      body: JSON.stringify({ key, value, ttl_secs: ttlSecs }),
    });
  } catch {
    /* caching is an optimization, not a requirement */
  }
  return value;
}

export type VpsCacheLookup<T> = {
  available: boolean;
  hit: boolean;
  value?: T;
};

/** Read a Redis cache key without falling through to a D1 loader. */
export async function getVpsCacheValue<T>(
  env: Env,
  key: string
): Promise<VpsCacheLookup<T>> {
  if (!vpsConfigured(env)) return { available: false, hit: false };
  try {
    const res = await vpsFetch(env, `/cache?key=${encodeURIComponent(key)}`);
    if (!res.ok) return { available: false, hit: false };
    const data = (await res.json()) as { hit?: boolean; value?: T };
    return data.hit
      ? { available: true, hit: true, value: data.value }
      : { available: true, hit: false };
  } catch {
    return { available: false, hit: false };
  }
}

/** Write ephemeral coordination state to Redis; never throws into a request. */
export async function putVpsCacheValue(
  env: Env,
  key: string,
  value: unknown,
  ttlSecs: number
): Promise<boolean> {
  if (!vpsConfigured(env)) return false;
  try {
    const res = await vpsFetch(env, "/cache", {
      method: "POST",
      body: JSON.stringify({ key, value, ttl_secs: ttlSecs }),
    });
    return res.ok;
  } catch {
    return false;
  }
}

export type FreshnessMap = Record<string, { at: string; status: string }>;

/**
 * Per-connection "when did we last refresh this" stamps.
 *
 * This is live state, not durable record: it changes on every scan and is only
 * ever used to render a freshness indicator. Kept in one key per user so a
 * scan costs a single write no matter how many connections the user has —
 * in D1 it was a row plus two index writes per connection per hour, which was
 * the largest remaining write cost once usage history moved out.
 *
 * The day-long TTL is the semantics, not just cleanup: a stamp older than that
 * means nothing has refreshed in a day, which is exactly "stale".
 */
export async function putVpsFreshness(
  env: Env,
  userId: string,
  entries: FreshnessMap
): Promise<void> {
  if (!vpsConfigured(env) || !Object.keys(entries).length) return;
  try {
    const current = (await getVpsFreshness(env, userId)) ?? {};
    await vpsFetch(env, "/cache", {
      method: "POST",
      body: JSON.stringify({
        key: `fresh:${userId}`,
        value: { ...current, ...entries },
        ttl_secs: 86400,
      }),
    });
  } catch (err) {
    console.warn("vps freshness write failed", err instanceof Error ? err.message : err);
  }
}

export async function getVpsFreshness(
  env: Env,
  userId: string
): Promise<FreshnessMap | null> {
  if (!vpsConfigured(env)) return null;
  try {
    const res = await vpsFetch(env, `/cache?key=${encodeURIComponent(`fresh:${userId}`)}`);
    if (!res.ok) return null;
    const data = (await res.json()) as { hit?: boolean; value?: FreshnessMap };
    return data.hit ? data.value ?? null : null;
  } catch {
    return null;
  }
}

/** Drop cache entries after a mutation makes them wrong. */
export async function vpsCacheBust(
  env: Env,
  opts: { key?: string; prefix?: string }
): Promise<void> {
  if (!vpsConfigured(env)) return;
  const q = opts.key
    ? `key=${encodeURIComponent(opts.key)}`
    : `prefix=${encodeURIComponent(opts.prefix ?? "")}`;
  try {
    await vpsFetch(env, `/cache?${q}`, { method: "DELETE" });
  } catch (err) {
    console.warn("vps cache bust failed", err instanceof Error ? err.message : err);
  }
}

/**
 * Remove the current user-scoped state from the self-hosted hot store after
 * account deletion. The VPS API currently has no historical-rollup deletion
 * endpoint, so this deliberately clears only live snapshot, presence,
 * device-revocation and cache state; closed usage rollups remain an explicit
 * operator/provider erasure task until that API exists.
 */
export async function purgeVpsUserCurrentState(
  env: Env,
  input: {
    userId: string;
    workspaceIds?: string[];
    deviceFingerprints?: string[];
  },
): Promise<void> {
  if (!vpsConfigured(env) || !input.userId) return;

  const tasks: Promise<unknown>[] = [
    putVpsSnapshot(env, input.userId, {}),
    ...[
      `conns:${input.userId}`,
      `usage-meta:${input.userId}`,
      `subs-meta:${input.userId}`,
      `fresh:${input.userId}`,
      `presence-sync:${input.userId}:`,
      `workspace:${input.userId}:`,
    ].map((prefix) => vpsCacheBust(env, { prefix })),
    ...(input.workspaceIds ?? []).map((workspaceId) =>
      putVpsProviderPresence(env, {
        userId: input.userId,
        workspaceId,
        connectedProviders: [],
      }),
    ),
    ...(input.deviceFingerprints ?? [])
      .filter((fingerprint): fingerprint is string => Boolean(fingerprint))
      .map((deviceFingerprint) =>
        setVpsDeviceRevoked(env, {
          userId: input.userId,
          deviceFingerprint,
          revoked: true,
        }),
      ),
  ];

  await Promise.allSettled(tasks);
}

/** Keep extension device termination state in the VPS Redis hot path. */
export async function setVpsDeviceRevoked(
  env: Env,
  input: { userId: string; deviceFingerprint: string; revoked: boolean }
): Promise<void> {
  if (!vpsConfigured(env) || !input.userId || !input.deviceFingerprint) return;
  try {
    await vpsFetch(env, "/device-revoke", {
      method: "POST",
      body: JSON.stringify({
        user_id: input.userId,
        device_fingerprint: input.deviceFingerprint,
        revoked: input.revoked,
      }),
    });
  } catch (err) {
    console.warn("vps device revoke sync failed", err instanceof Error ? err.message : err);
  }
}

export type VpsDeviceHeartbeatResult =
  | "ok"
  | "force_logout"
  | "unavailable";

/**
 * Keep already-shipped clients off the D1 heartbeat write path too. The
 * direct clients call this VPS endpoint themselves; this compatibility helper
 * lets older clients use the same Redis device lease through the Worker.
 */
export async function heartbeatVpsDevice(
  env: Env,
  input: { userId: string; workspaceId: string; deviceFingerprint: string }
): Promise<VpsDeviceHeartbeatResult> {
  if (!vpsConfigured(env)) return "unavailable";
  const issued = await issueVpsClientToken(env, input.userId, input.workspaceId);
  if (!issued) return "unavailable";

  try {
    const res = await fetch(`${env.VPS_API_URL}/client/heartbeat`, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        authorization: `Bearer ${issued.token}`,
      },
      body: JSON.stringify({ device_fingerprint: input.deviceFingerprint }),
      signal: AbortSignal.timeout(5_000),
    });
    if (res.status === 401) {
      const body = await res.json().catch(() => ({})) as { force_logout?: boolean };
      return body.force_logout ? "force_logout" : "unavailable";
    }
    return res.ok ? "ok" : "unavailable";
  } catch {
    return "unavailable";
  }
}

type RollupQuery = {
  workspace_id: string;
  user_id?: string | null;
  provider_id?: string | null;
  window?: string | null;
  from?: string | null;
  to?: string | null;
  limit?: number;
  offset?: number;
};

export type VpsRollupRow = {
  id: string;
  workspace_id: string;
  user_id: string;
  provider_id: string;
  connection_id: string | null;
  window_id: string;
  window_start: string | null;
  window_end: string;
  peak_used_percent: string | null;
  peak_used: string | null;
  final_used: string | null;
  total: string | null;
  source: string | null;
};

/**
 * Archive rows in the shape the history read path already merges.
 *
 * A rollup row records a window that closed, so its `observed_at` is the
 * window end and its usage figure is the peak reached inside that window --
 * that peak is what the user cares about ("how much did I use in that 5h
 * block"), not whatever the counter happened to read at the reset instant.
 *
 * Returns null on failure so the caller can fall back to the hot store instead
 * of surfacing an empty history, matching how the AE archive behaved.
 */
export async function queryUsageHistoryFromVps(
  env: Env,
  opts: {
    workspaceId: string;
    userId?: string | null;
    providerId?: string | null;
    from?: string | null;
    to?: string | null;
    limit: number;
    offset: number;
    includeTotal?: boolean;
  }
): Promise<{ rows: VpsArchiveRow[]; total: number | null } | null> {
  if (!vpsConfigured(env)) return null;
  try {
    const { rows, total } = await fetchVpsRollups(env, {
      workspace_id: opts.workspaceId,
      user_id: opts.userId,
      provider_id: opts.providerId,
      from: opts.from,
      to: opts.to,
      limit: opts.limit,
      offset: opts.offset,
    });
    return {
      rows: rows.map((r) => ({
        id: `vps-${r.id}`,
        observed_at: r.window_end,
        user_id: r.user_id,
        user_email: null,
        provider_id: r.provider_id,
        provider_name: null,
        window: r.window_id,
        used_percent: r.peak_used_percent == null ? null : Number(r.peak_used_percent),
        used: r.peak_used,
        total: r.total,
        resets_at: r.window_end,
        source: r.source,
        user_name: null,
        user_avatar: null,
        // Rollups are per-provider window closes, not the hourly multi-provider
        // snapshot shape those two columns carry in the hot store.
        providers_json: null,
        hour_bucket: null,
      })),
      total: opts.includeTotal ? total : null,
    };
  } catch (err) {
    console.warn("vps history query failed", err instanceof Error ? err.message : err);
    return null;
  }
}

export type VpsArchiveRow = {
  id: string;
  observed_at: string;
  user_id: string | null;
  user_email: string | null;
  provider_id: string;
  provider_name: string | null;
  window: string | null;
  used_percent: number | null;
  used: string | null;
  total: string | null;
  resets_at: string | null;
  source: string | null;
  user_name: string | null;
  user_avatar: string | null;
  providers_json: string | null;
  hour_bucket: string | null;
};

/**
 * Read window rollups. Unlike the mirror write this DOES throw, because a read
 * path that silently returns nothing would look like "no usage history" to the
 * user rather than an outage.
 */
export async function fetchVpsRollups(
  env: Env,
  q: RollupQuery
): Promise<{ rows: VpsRollupRow[]; total: number }> {
  if (!vpsConfigured(env)) throw new Error("vps_not_configured");

  const params = new URLSearchParams({ workspace_id: q.workspace_id });
  if (q.user_id) params.set("user_id", q.user_id);
  if (q.provider_id) params.set("provider_id", q.provider_id);
  if (q.window) params.set("window", q.window);
  if (q.from) params.set("from", q.from);
  if (q.to) params.set("to", q.to);
  params.set("limit", String(q.limit ?? 50));
  params.set("offset", String(q.offset ?? 0));

  const res = await fetch(`${env.VPS_API_URL}/rollups?${params}`, {
    headers: { authorization: `Bearer ${env.VPS_API_SECRET}` },
    signal: AbortSignal.timeout(15_000),
  });
  if (!res.ok) throw new Error(`vps_rollups_failed_${res.status}`);
  const data = (await res.json()) as { rows?: VpsRollupRow[]; total?: number };
  return { rows: data.rows ?? [], total: data.total ?? 0 };
}

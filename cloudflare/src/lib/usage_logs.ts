import type { Env } from "../env";
import { db } from "../db/client";
import { mapPlatformToProviderId } from "./users";
import { queryUsageHistoryFromVps, type VpsArchiveRow } from "./vps_usage";

export type UsageLogRow = {
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
  /** New user/hour history bucket; clients expand this JSON on-device. */
  providers_json: string | null;
  hour_bucket: string | null;
  user_name: string | null;
  user_avatar: string | null;
};

export type EnrichedUsageLogRow = UsageLogRow & {
  price_usd_cents: number | null;
  plan_name: string | null;
  billing_cycle: string | null;
};

type SubscriptionHistoryRow = {
  id: string;
  provider_id: string;
  user_id: string | null;
  price_usd_cents: number | null;
  plan_name: string | null;
  billing_cycle: string | null;
  observed_at: string;
};

export type FetchUsageLogsOpts = {
  workspaceId: string;
  userId?: string;
  provider?: string;
  from?: string;
  to?: string;
  limit: number;
  offset: number;
};

export type FetchUsageHistoryOpts = Omit<FetchUsageLogsOpts, "offset"> & {
  offset?: number;
  order?: "asc" | "desc";
  includeTotal?: boolean;
  toExclusive?: boolean;
};

export type FetchUsageHistoryResult = {
  rows: UsageLogRow[];
  total: number | null;
};

const MAX_HISTORY_ROWS = 50000;




function hydrateAnalyticsRows(
  env: Env,
  rows: VpsArchiveRow[]
): Promise<UsageLogRow[]> {
  if (!rows.length) return Promise.resolve([]);

  return (async () => {
    const userIds = [...new Set(rows.map((row) => row.user_id).filter((id): id is string => Boolean(id)))];
    const providerIds = [...new Set(rows.map((row) => row.provider_id).filter(Boolean))];
    const userMap = new Map<string, { email: string | null; name: string | null; avatar: string | null }>();
    const providerMap = new Map<string, string>();

    // D1'nin tek statement bind limitini aşmamak için küçük gruplar.
    for (let i = 0; i < userIds.length; i += 80) {
      const ids = userIds.slice(i, i + 80);
      const { results } = await db(env)
        .prepare(
          `SELECT id, email, name, avatar FROM users
            WHERE id IN (${ids.map(() => "?").join(", ")})`
        )
        .bind(...ids)
        .all<{ id: string; email: string | null; name: string | null; avatar: string | null }>();
      for (const row of results || []) {
        userMap.set(row.id, { email: row.email, name: row.name, avatar: row.avatar });
      }
    }

    for (let i = 0; i < providerIds.length; i += 80) {
      const ids = providerIds.slice(i, i + 80);
      const { results } = await db(env)
        .prepare(
          `SELECT id, name FROM providers
            WHERE id IN (${ids.map(() => "?").join(", ")})`
        )
        .bind(...ids)
        .all<{ id: string; name: string }>();
      for (const row of results || []) providerMap.set(row.id, row.name);
    }

    return rows.map((row) => {
      const user = row.user_id ? userMap.get(row.user_id) : undefined;
      return {
        ...row,
        user_email: row.user_email ?? user?.email ?? null,
        provider_name: row.provider_name ?? providerMap.get(row.provider_id) ?? null,
        user_name: row.user_name ?? user?.name ?? null,
        user_avatar: row.user_avatar ?? user?.avatar ?? null,
      };
    });
  })();
}


/**
 * Usage history comes entirely from the self-hosted store: closed windows live
 * in Postgres, and the D1 table this used to read was dropped once the rollups
 * were migrated across.
 *
 * When the store is unreachable or unconfigured (local dev) this returns an
 * empty page rather than throwing — the logs view is informational, and a
 * blank list degrades better there than a failed request.
 */
export async function fetchUsageHistoryRows(
  env: Env,
  opts: FetchUsageHistoryOpts
): Promise<FetchUsageHistoryResult> {
  const includeTotal = opts.includeTotal === true;
  const requestedLimit = Math.min(Math.max(Math.floor(opts.limit), 1), MAX_HISTORY_ROWS);
  const requestedOffset = Math.max(Math.floor(opts.offset ?? 0), 0);

  const result = await queryUsageHistoryFromVps(env, {
    workspaceId: opts.workspaceId,
    userId: opts.userId,
    providerId: opts.provider ? mapPlatformToProviderId(opts.provider) : undefined,
    from: opts.from,
    to: opts.to,
    limit: requestedLimit,
    offset: requestedOffset,
    includeTotal,
  });

  if (!result) return { rows: [], total: includeTotal ? 0 : null };

  const rows = await hydrateAnalyticsRows(env, result.rows);
  return { rows, total: result.total };
}

export async function fetchUsageLogsPage(
  env: Env,
  opts: FetchUsageLogsOpts
): Promise<{ logs: UsageLogRow[]; total: number }> {
  const result = await fetchUsageHistoryRows(env, {
    ...opts,
    order: "desc",
    includeTotal: true,
  });
  return { logs: result.rows, total: result.total ?? result.rows.length };
}

function pickSubscriptionForLog(
  log: UsageLogRow,
  candidates: SubscriptionHistoryRow[]
): SubscriptionHistoryRow | null {
  const logMs = new Date(log.observed_at).getTime();
  let best: SubscriptionHistoryRow | null = null;
  let bestScore = -1;

  for (const row of candidates) {
    if (row.provider_id !== log.provider_id) continue;
    if (new Date(row.observed_at).getTime() > logMs) continue;
    if (row.user_id != null && row.user_id !== log.user_id) continue;

    const userMatch = row.user_id === log.user_id ? 1 : 0;
    const rowMs = new Date(row.observed_at).getTime();
    const score = userMatch * 1_000_000_000_000 + rowMs;
    if (score > bestScore) {
      bestScore = score;
      best = row;
    }
  }

  return best;
}

export async function enrichLogsWithSubscription(
  env: Env,
  workspaceId: string,
  rows: UsageLogRow[]
): Promise<EnrichedUsageLogRow[]> {
  if (!rows.length) return [];

  const providerIds = [...new Set(rows.map((r) => r.provider_id))];
  const maxObserved = rows.reduce((max, r) => {
    const t = new Date(r.observed_at).getTime();
    return t > max ? t : max;
  }, 0);
  const maxObservedIso = new Date(maxObserved).toISOString();

  const placeholders = providerIds.map(() => "?").join(", ");
  const { results: subRows } = await db(env)
    .prepare(
      `SELECT id, provider_id, user_id, price_usd_cents, plan_name, billing_cycle, observed_at
         FROM provider_subscription_history
        WHERE workspace_id = ?
          AND provider_id IN (${placeholders})
          AND observed_at <= ?
        ORDER BY observed_at ASC`
    )
    .bind(workspaceId, ...providerIds, maxObservedIso)
    .all<SubscriptionHistoryRow>();

  const subs = subRows || [];

  return rows.map((log) => {
    const match = pickSubscriptionForLog(log, subs);
    return {
      ...log,
      price_usd_cents: match?.price_usd_cents ?? null,
      plan_name: match?.plan_name ?? null,
      billing_cycle: match?.billing_cycle ?? null,
    };
  });
}

import { z } from "zod";
import type { Env } from "../env";
import { db, normalizeEmail, nowIso, stableId, uuid } from "../db/client";
import { planDefForSlug, planFeaturesForSlug } from "./plan_features";
import {
  getVpsCacheValue,
  getVpsSnapshot,
  mirrorUsageToVps,
  putVpsCacheValue,
  putVpsFreshness,
  putVpsProviderPresence,
  putVpsSnapshot,
  vpsCacheBust,
  vpsCached,
  vpsConfigured,
  type FreshnessMap,
  type VpsUsageItem,
} from "./vps_usage";

const PLATFORM_TO_PROVIDER: Record<string, string> = {
  claude: "claude",
  cursor: "cursor",
  // OpenAI: ChatGPT Plus/Pro abonelik + API (chat/image/video/codex) — tek kanonik id
  openai: "openai",
  chatgpt: "openai",
  codex: "openai",
  copilot: "github-copilot",
  "github-copilot": "github-copilot",
  gemini: "gemini",
  minimax: "minimax",
  perplexity: "perplexity",
  windsurf: "windsurf",
  deepseek: "deepseek",
  groq: "groq",
  // Desktop webview-scrape id'leri — kanonik id'ye indirgenir
  "claude-web": "claude",
  "chatgpt-web": "openai",
  "openai-web": "openai",
  "codex-web": "openai",
  "cursor-web": "cursor",
  "windsurf-web": "windsurf",
  "gemini-web": "gemini",
  "minimax-web": "minimax",
  "copilot-web": "github-copilot",
  commandcode: "commandcode",
  "commandcode-web": "commandcode",
};

/** Çift limit (5h + haftalık) — tek primary window fallback kullanılmaz */
export const DUAL_WINDOW_PROVIDERS = new Set(["minimax"]);
/** Capture the final sample when a usage window is about to reset. */
const D1_SNAPSHOT_TAIL_MS = 60 * 1000;

export function mapPlatformToProviderId(platform: string): string {
  const key = platform.toLowerCase().trim();
  return PLATFORM_TO_PROVIDER[key] || key;
}

type ProviderPresenceConnectionRow = { provider: string };
type ProviderPresenceMetaRow = { id: string; name: string; brand_color: string | null };

/** Mirror the full D1 connection list without making Redis usage the source of truth. */
export async function syncVpsProviderPresence(
  env: Env,
  userId: string,
  workspaceId: string,
  force = false,
): Promise<boolean> {
  if (!vpsConfigured(env) || !userId || !workspaceId) return true;

  const markerKey = `presence-sync:${userId}:${workspaceId}`;
  if (!force) {
    const marker = await getVpsCacheValue<boolean>(env, markerKey);
    if (marker.available && marker.hit) return true;
  }

  try {
    const rows = await vpsCached<ProviderPresenceConnectionRow[]>(
      env,
      `conns:${userId}:presence`,
      120,
      async () => {
        const { results } = await db(env)
          .prepare(
            `SELECT provider FROM user_connections
               WHERE user_id = ?
               ORDER BY created_at DESC`
          )
          .bind(userId)
          .all<ProviderPresenceConnectionRow>();
        return results || [];
      },
    );
    const providerIds = [
      ...new Set((rows || []).map((row) => mapPlatformToProviderId(row.provider))),
    ];
    let connectedProviders: Array<{
      id: string;
      name: string;
      brand_color: string | null;
    }> = [];

    if (providerIds.length) {
      const placeholders = providerIds.map(() => "?").join(", ");
      const { results } = await db(env)
        .prepare(`SELECT id, name, brand_color FROM providers WHERE id IN (${placeholders})`)
        .bind(...providerIds)
        .all<ProviderPresenceMetaRow>();
      const metadata = new Map((results || []).map((row) => [row.id, row]));
      connectedProviders = providerIds.map((id) => {
        const row = metadata.get(id);
        return { id, name: row?.name || id, brand_color: row?.brand_color ?? null };
      });
    }

    const synced = await putVpsProviderPresence(env, {
      userId,
      workspaceId,
      connectedProviders,
    });
    if (synced) await putVpsCacheValue(env, markerKey, true, 300);
    return synced;
  } catch (err) {
    console.warn("provider presence preparation failed", err instanceof Error ? err.message : err);
    return false;
  }
}

type CachedConnectionLookupRow = {
  id: string;
  provider: string;
  account_label: string | null;
  created_at: string | null;
};

async function cachedConnectionLookupRows(
  env: Env,
  userId: string
): Promise<CachedConnectionLookupRow[]> {
  return vpsCached<CachedConnectionLookupRow[]>(
    env,
    `conns:${userId}:lookup`,
    60,
    async () => {
      const { results } = await db(env)
        .prepare(
          `SELECT id, provider, account_label, created_at
             FROM user_connections
            WHERE user_id = ?
            ORDER BY created_at DESC`
        )
        .bind(userId)
        .all<CachedConnectionLookupRow>();
      return results || [];
    }
  );
}

/** Kullanıcının bu provider için bağlı en az bir bağlantısı (hesap/key) var mı? */
export async function userHasProviderConnection(
  env: Env,
  userId: string,
  providerId: string,
  providerRaw?: string
): Promise<boolean> {
  const raw = providerRaw?.trim() || providerId;
  const row = await db(env)
    .prepare(
      "SELECT 1 AS ok FROM user_connections WHERE user_id = ? AND provider IN (?, ?) LIMIT 1"
    )
    .bind(userId, raw, providerId)
    .first();
  return Boolean(row);
}

/** Bu provider için belirli bir account_label'a sahip bağlantıyı bulur (scan-connect eşleme). */
export async function findConnectionByLabel(
  env: Env,
  userId: string,
  providerId: string,
  accountLabel: string
): Promise<{ id: string } | null> {
  const row = await db(env)
    .prepare(
      "SELECT id FROM user_connections WHERE user_id = ? AND provider = ? AND account_label = ? LIMIT 1"
    )
    .bind(userId, providerId, accountLabel)
    .first<{ id: string }>();
  return row || null;
}

export async function findConnectionByLabelCached(
  env: Env,
  userId: string,
  providerId: string,
  accountLabel: string
): Promise<{ id: string } | null> {
  const row = (await cachedConnectionLookupRows(env, userId)).find(
    (candidate) =>
      candidate.provider === providerId && candidate.account_label === accountLabel
  );
  return row ? { id: row.id } : null;
}

/** En yeni bağlanan connection id'yi döner (account_label bilgisi yoksa fallback). */
/**
 * userHasProviderConnection + latestConnectionForProvider, tek sorguda.
 *
 * Usage POST yolunda ikisi arka arkaya cagriliyordu, yani ayni tabloya iki
 * ayri Worker <-> D1 gidis-donusu. Ikisi de aynen korunuyor cunku semantikleri
 * farkli: varlik kontrolu ham platform adini da kabul ediyor (`IN`), baglanti
 * secimi ise yalnizca kanonik id ile eslesiyor. Tek `IN` ile birlestirmek
 * davranisi degistirirdi.
 */
export async function connectionLookupForUsage(
  env: Env,
  userId: string,
  providerId: string,
  providerRaw?: string
): Promise<{ hasConnection: boolean; connectionId: string | null }> {
  const raw = providerRaw?.trim() || providerId;
  const rows = await cachedConnectionLookupRows(env, userId);
  const latest = rows.find((row) => row.provider === providerId);

  return {
    hasConnection: rows.some((row) => row.provider === raw || row.provider === providerId),
    connectionId: latest?.id ?? null,
  };
}

/**
 * Kullanicinin butun baglantilari, tek sorguda.
 *
 * Batch usage yolu icin: provider basina ayri arama yapmak yerine hepsini bir
 * kez cekip bellekte esliyoruz. Tek `connectionLookupForUsage` cagrisiyla ayni
 * semantik, ama N provider icin N sorgu yerine 1.
 */
export async function allConnectionsForUser(
  env: Env,
  userId: string
): Promise<{
  /** Kanonik provider id -> en yeni baglanti id'si. */
  latestByProvider: Map<string, string>;
  /** Hem ham hem kanonik saklanmis provider adlari (varlik kontrolu icin). */
  storedProviderNames: Set<string>;
}> {
  const rows = await cachedConnectionLookupRows(env, userId);

  const latestByProvider = new Map<string, string>();
  const storedProviderNames = new Set<string>();
  for (const row of rows) {
    storedProviderNames.add(row.provider);
    // ORDER BY created_at DESC, yani ilk gorulen en yenisi.
    const providerId = mapPlatformToProviderId(row.provider);
    if (!latestByProvider.has(providerId)) latestByProvider.set(providerId, row.id);
  }
  return { latestByProvider, storedProviderNames };
}

export async function latestConnectionForProvider(
  env: Env,
  userId: string,
  providerId: string
): Promise<{ id: string } | null> {
  const row = await db(env)
    .prepare(
      "SELECT id FROM user_connections WHERE user_id = ? AND provider = ? ORDER BY created_at DESC LIMIT 1"
    )
    .bind(userId, providerId)
    .first<{ id: string }>();
  return row || null;
}

export async function latestConnectionForProviderCached(
  env: Env,
  userId: string,
  providerId: string
): Promise<{ id: string } | null> {
  const row = (await cachedConnectionLookupRows(env, userId)).find(
    (candidate) => candidate.provider === providerId
  );
  return row ? { id: row.id } : null;
}

export type UsageWindowInput = {
  window: string;
  label: string;
  used_percent: number;
  used?: string | null;
  total?: string | null;
  resets_at?: string | null;
};

export const usageWindowSchema = z.object({
  window: z.string(),
  label: z.string(),
  used_percent: z.number(),
  used: z.string().nullable().optional(),
  total: z.string().nullable().optional(),
  resets_at: z.string().nullable().optional(),
});

export type UsageUpsertInput = {
  /** Kept for history/audit context only — usage rows are user-scoped. */
  workspace_id: string;
  provider_id: string;
  /** Required: provider usage belongs to the user, not the workspace. */
  user_id: string;
  /** Required: which connected account this usage belongs to. */
  connection_id: string;
  user_email?: string | null;
  used_percent?: number | null;
  used?: string | null;
  total?: string | null;
  resets_at?: string | null;
  error?: string | null;
  updated_at?: string | null;
  observed_at?: string | null;
  source?: string;
  windows?: UsageWindowInput[];
  /** Subscription ended: preserve the last sample and publish its new status. */
  no_subscription?: boolean;
  /** Optional client-provided retry key; otherwise a content key is used. */
  snapshot_id?: string | null;
};

type ExistingUsageRow = {
  used_percent: number | null;
  used: string | null;
  total: string | null;
  resets_at: string | null;
  error: string | null;
  /** JSON array of StoredWindow; provider_usage_windows tablosunun yerini aldi. */
  windows_json: string | null;
};

/** user_provider_usage.windows_json icindeki tek window kaydi. */
export type StoredWindow = {
  window: string;
  label: string;
  used_percent: number | null;
  used: string | null;
  total: string | null;
  resets_at: string | null;
  updated_at: string;
};

/** One user snapshot entry, keyed by connection_id in user_usage_snapshots. */
export type UsageSnapshotEntry = {
  connection_id: string;
  provider_id: string;
  used_percent: number | null;
  used: string | null;
  total: string | null;
  resets_at: string | null;
  error: string | null;
  updated_at: string;
  observed_at: string;
  source: string;
  windows: StoredWindow[];
};

export type UsageSnapshot = Record<string, UsageSnapshotEntry>;

export function parseUsageSnapshot(raw: string | null | undefined): UsageSnapshot {
  if (!raw) return {};
  try {
    const parsed = JSON.parse(raw);
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return {};
    return parsed as UsageSnapshot;
  } catch {
    return {};
  }
}

/**
 * Live usage snapshot, served from the self-hosted store.
 *
 * This is the hottest read in the product — every dashboard poll from every
 * client hits it — so it comes from Redis, where a read costs nothing per row.
 * D1 keeps a copy purely as the durability backstop: it answers only when the
 * store has no entry for this user yet (first read after a deploy, or after a
 * Redis loss), and that answer is written back so the next read is served hot.
 *
 * `getVpsSnapshot` returns undefined for "store unavailable" and null for
 * "store is up, this user has nothing" — only the former should fall through
 * to D1, otherwise every genuinely-empty user would keep querying it.
 */
export async function getUsageSnapshot(env: Env, userId: string): Promise<UsageSnapshot> {
  const cached = await getVpsSnapshot(env, userId);
  if (cached) return cached as UsageSnapshot;

  const row = await db(env)
    .prepare("SELECT snapshot_json FROM user_usage_snapshots WHERE user_id = ?")
    .bind(userId)
    .first<{ snapshot_json: string | null }>();
  const snapshot = parseUsageSnapshot(row?.snapshot_json);

  // Warm the store so this D1 query happens once per user, not once per poll.
  // Only when the store answered "no entry" (null); if it was unreachable
  // (undefined) the write would fail too, and D1 keeps serving meanwhile.
  if (cached === null && Object.keys(snapshot).length > 0) {
    await putVpsSnapshot(env, userId, snapshot);
  }
  return snapshot;
}

function hourBucketIso(value: string): string {
  const parsed = new Date(value);
  const date = Number.isFinite(parsed.getTime()) ? parsed : new Date();
  date.setUTCMinutes(0, 0, 0);
  return date.toISOString();
}

function snapshotProviders(snapshot: UsageSnapshot): Record<string, UsageSnapshotEntry[]> {
  const providers: Record<string, UsageSnapshotEntry[]> = {};
  for (const entry of Object.values(snapshot)) {
    (providers[entry.provider_id] ||= []).push(entry);
  }
  return providers;
}

function storedWindowsForInput(
  input: UsageUpsertInput,
  existing: UsageSnapshotEntry | undefined,
  updatedAt: string
): { windows: StoredWindow[]; changed: boolean } {
  const supplied = input.windows?.length
    ? input.windows
    : input.provider_id === "cursor" || DUAL_WINDOW_PROVIDERS.has(input.provider_id)
      ? []
      : input.used_percent != null
        ? [{
            window: "primary",
            label: "Primary",
            used_percent: input.used_percent,
            used: input.used ?? "",
            total: input.total ?? "",
            resets_at: input.resets_at ?? null,
          }]
        : [];

  // A partial scalar-only update keeps the previous window JSON, matching the
  // old COALESCE behavior while allowing a full batch to replace all windows.
  if (!supplied.length) return { windows: existing?.windows ?? [], changed: false };

  const previous = new Map((existing?.windows ?? []).map((window) => [window.window, window]));
  const windows = supplied.map((window) => {
    const old = previous.get(window.window);
    const resetsAt = window.resets_at ?? old?.resets_at ?? null;
    const changed =
      !old ||
      old.label !== window.label ||
      old.used_percent !== window.used_percent ||
      (old.used ?? "") !== (window.used ?? "") ||
      (old.total ?? "") !== (window.total ?? "") ||
      old.resets_at !== resetsAt;
    return {
      window: window.window,
      label: window.label,
      used_percent: window.used_percent,
      used: window.used ?? "",
      total: window.total ?? "",
      resets_at: resetsAt,
      updated_at: changed ? updatedAt : (old?.updated_at ?? updatedAt),
    };
  });

  return {
    windows,
    changed:
      windows.length !== (existing?.windows.length ?? 0) ||
      windows.some((window, index) => JSON.stringify(window) !== JSON.stringify(existing?.windows[index])),
  };
}

function validUsageTimestamp(value: string | null | undefined): string | null {
  if (!value || !Number.isFinite(Date.parse(value))) return null;
  return value;
}

export function resolveObservedAt(
  observedAt: string | null | undefined,
  updatedAt: string | null | undefined,
  previousObservedAt: string | null | undefined,
): string {
  return (
    validUsageTimestamp(observedAt) ??
    validUsageTimestamp(updatedAt) ??
    validUsageTimestamp(previousObservedAt) ??
    ""
  );
}

export function observedAtForUsageInput(
  input: Pick<UsageUpsertInput, "observed_at" | "updated_at" | "no_subscription" | "error">,
  previousObservedAt: string | null | undefined,
): string {
  if (input.no_subscription || input.error) {
    return validUsageTimestamp(previousObservedAt) ?? "";
  }
  return resolveObservedAt(input.observed_at, input.updated_at, previousObservedAt);
}

export function snapshotEntryChanged(old: UsageSnapshotEntry | undefined, next: UsageSnapshotEntry): boolean {
  if (!old) return true;
  return JSON.stringify({
    connection_id: old.connection_id,
    provider_id: old.provider_id,
    used_percent: old.used_percent,
    used: old.used,
    total: old.total,
    resets_at: old.resets_at,
    error: old.error,
    observed_at: old.observed_at,
    windows: old.windows,
  }) !== JSON.stringify({
    connection_id: next.connection_id,
    provider_id: next.provider_id,
    used_percent: next.used_percent,
    used: next.used,
    total: next.total,
    resets_at: next.resets_at,
    error: next.error,
    observed_at: next.observed_at,
    windows: next.windows,
  });
}

export function noSubscriptionSnapshotEntry(
  input: Pick<UsageUpsertInput, "connection_id" | "provider_id" | "source">,
  existing: UsageSnapshotEntry | undefined,
  updatedAt: string,
  observedAt: string,
): UsageSnapshotEntry {
  return {
    connection_id: input.connection_id,
    provider_id: mapPlatformToProviderId(input.provider_id),
    used_percent: existing?.used_percent ?? null,
    used: existing?.used ?? null,
    total: existing?.total ?? null,
    resets_at: existing?.resets_at ?? null,
    error: "no_subscription",
    updated_at: updatedAt,
    observed_at: observedAt,
    source: input.source || existing?.source || "scrape",
    windows: existing?.windows ?? [],
  };
}

function hasImminentReset(entry: UsageSnapshotEntry, nowMs: number): boolean {
  const resetTimes = [entry.resets_at, ...entry.windows.map((window) => window.resets_at)];
  return resetTimes.some((value) => {
    if (!value) return false;
    const resetMs = Date.parse(value);
    return Number.isFinite(resetMs) &&
      resetMs > nowMs &&
      resetMs <= nowMs + D1_SNAPSHOT_TAIL_MS;
  });
}

/**
 * Persists a complete multi-provider refresh as one user JSON snapshot row.
 * Single-provider callers use the same path for backwards compatibility;
 * usage history is mirrored to the VPS store.
 */
export async function upsertProviderUsageBatch(
  env: Env,
  rawInputs: UsageUpsertInput[],
  /**
   * Kept for compatibility with callers that also schedule cache invalidation.
   * VPS usage persistence itself is awaited before this function returns.
   */
  ctx?: { waitUntil: (promise: Promise<unknown>) => void },
  options: { requireVpsMirror?: boolean } = {}
) {
  if (!rawInputs.length) return;
  const inputs = [...new Map(rawInputs.map((input) => [input.connection_id, input])).values()];
  const first = inputs[0]!;
  if (!first.user_id) throw new Error("upsertProviderUsage requires user_id");
  if (inputs.some((input) => input.user_id !== first.user_id)) {
    throw new Error("upsertProviderUsageBatch requires one user_id");
  }

  const userId = first.user_id;
  const existing = await getUsageSnapshot(env, userId);
  const next: UsageSnapshot = { ...existing };
  const snapshotPatch: Record<string, UsageSnapshotEntry | null> = {};
  const statements: D1PreparedStatement[] = [];
  const freshness: FreshnessMap = {};
  let liveChanged = false;
  let captureD1Tail = false;
  const nowMs = Date.now();
  let latestObservedAt: string | null = null;
  for (const entry of Object.values(existing)) {
    const observedAt = validUsageTimestamp(entry.observed_at);
    if (
      observedAt &&
      (!latestObservedAt || Date.parse(observedAt) > Date.parse(latestObservedAt))
    ) {
      latestObservedAt = observedAt;
    }
  }
  const observedAtByConnection = new Map<string, string>();

  for (const input of inputs) {
    const old = existing[input.connection_id];
    const updatedAt = input.updated_at || nowIso();
    const observedAt = observedAtForUsageInput(input, old?.observed_at);
    if (observedAt) {
      observedAtByConnection.set(input.connection_id, observedAt);
      if (
        !latestObservedAt ||
        Date.parse(observedAt) > Date.parse(latestObservedAt)
      ) {
        latestObservedAt = observedAt;
      }
    }

    if (input.no_subscription) {
      const noSubscriptionEntry = noSubscriptionSnapshotEntry(input, old, updatedAt, observedAt);
      if (snapshotEntryChanged(old, noSubscriptionEntry)) {
        next[input.connection_id] = noSubscriptionEntry;
        snapshotPatch[input.connection_id] = noSubscriptionEntry;
        liveChanged = true;
        captureD1Tail = true;
      }
      // Live usage is owned by Redis when the VPS is configured. Keep the
      // legacy D1 usage row only for local/dev deployments without the VPS;
      // subscription metadata remains in D1 in both modes.
      if (!vpsConfigured(env)) {
        statements.push(
          db(env)
            .prepare(
              `UPDATE user_provider_usage SET
                 used_percent = NULL, used = NULL, total = NULL, resets_at = NULL,
                 error = 'no_subscription', windows_json = NULL,
                 updated_at = ?, observed_at = ?, source = ?
               WHERE connection_id = ?
                 AND (used_percent IS NOT NULL OR used IS NOT NULL OR total IS NOT NULL
                      OR resets_at IS NOT NULL OR windows_json IS NOT NULL
                      OR error IS NOT 'no_subscription')`
            )
            .bind(updatedAt, observedAt, input.source || 'scrape', input.connection_id)
        );
      }
      statements.push(
        db(env)
          .prepare(
            `UPDATE user_connections SET
               plan_name = NULL, price_usd_cents = NULL, billing_cycle = NULL,
               auto_renew = NULL, purchased_at = NULL, renews_at = NULL,
               sub_source = NULL, sub_refreshed_at = ?
             WHERE id = ?
               AND (plan_name IS NOT NULL OR price_usd_cents IS NOT NULL
                    OR billing_cycle IS NOT NULL OR auto_renew IS NOT NULL
                    OR purchased_at IS NOT NULL OR renews_at IS NOT NULL
                    OR sub_source IS NOT NULL)`
          )
          .bind(updatedAt, input.connection_id),
        db(env)
          .prepare("DELETE FROM provider_subscriptions WHERE connection_id = ?")
          .bind(input.connection_id)
      );
      continue;
    }

    const windowState = storedWindowsForInput(input, old, updatedAt);
    const nextEntry: UsageSnapshotEntry = {
      connection_id: input.connection_id,
      provider_id: mapPlatformToProviderId(input.provider_id),
      used_percent: input.used_percent ?? old?.used_percent ?? null,
      used: input.used ?? old?.used ?? null,
      total: input.total ?? old?.total ?? null,
      resets_at: input.resets_at ?? old?.resets_at ?? null,
      error: input.error ?? null,
      updated_at: updatedAt,
      observed_at: observedAt,
      source: input.source || old?.source || "scrape",
      windows: windowState.windows,
    };
    if (snapshotEntryChanged(old, nextEntry)) {
      next[input.connection_id] = nextEntry;
      snapshotPatch[input.connection_id] = nextEntry;
      liveChanged = true;
    }
    if (hasImminentReset(nextEntry, nowMs)) captureD1Tail = true;

    // Freshness stamp goes to Redis, not D1 — see putVpsFreshness. In D1 this
    // was a row plus two index writes per connection per hour, for a value
    // that only drives a "last refreshed" indicator.
    freshness[input.connection_id] = { at: updatedAt, status: "fresh" };
  }

  // Store only the changed connection keys. D1 serializes the upsert, and
  // json_patch prevents concurrent single-provider legacy clients from
  // overwriting another provider's freshly written snapshot entry.
  //
  // Redis is where this value is actually read from. When VPS is configured,
  // D1 receives no live-usage sample; it remains a fallback/settings store.
  const snapshotPatchJson = JSON.stringify(snapshotPatch);
  // A successful scan with unchanged metrics still changes observed_at, so the
  // live snapshot is written and the real provider sample time is preserved.
  // VPS is authoritative for live usage. In production, even the reset-minute
  // sample stays off D1; local/dev without a VPS keeps the compatibility row.
  if ((liveChanged || captureD1Tail) && !vpsConfigured(env)) {
    statements.unshift(
      db(env)
        .prepare(
          `INSERT INTO user_usage_snapshots (user_id, snapshot_json, updated_at, observed_at, source)
           VALUES (?, ?, ?, ?, ?)
           ON CONFLICT(user_id) DO UPDATE SET
             snapshot_json = json_patch(user_usage_snapshots.snapshot_json, excluded.snapshot_json),
             updated_at = excluded.updated_at,
             observed_at = excluded.observed_at,
             source = excluded.source`
        )
        .bind(
          userId,
          snapshotPatchJson,
          nowIso(),
          latestObservedAt,
          first.source || "scrape"
        )
    );
  }

  // No history row is written to D1 any more. Usage time-series lives on the
  // self-hosted store: Redis holds the live value and Postgres records a row
  // only when a provider's window closes, so history no longer costs a D1
  // write per user per hour. The mirror call at the end of this function is
  // what feeds it.

  if (statements.length > 0) await db(env).batch(statements);

  if (inputs.some((input) => input.no_subscription)) {
    const cacheBust = Promise.all([
      vpsCacheBust(env, { prefix: `conns:${userId}` }),
      vpsCacheBust(env, { prefix: `usage-meta:${userId}` }),
      vpsCacheBust(env, { prefix: `subs-meta:${userId}` }),
    ]);
    if (ctx) ctx.waitUntil(cacheBust);
    else await cacheBust;
  }

  // Redis holds the snapshot every client read is served from. When configured,
  // a request is not acknowledged until both the VPS snapshot and ingest write
  // succeed; this prevents a successful Worker response from hiding a lost
  // hot-store sample.
  if (vpsConfigured(env)) {
    const mirrorItems: VpsUsageItem[] = inputs
      .filter((input) => !input.no_subscription)
      .map((input) => ({
        workspace_id: input.workspace_id,
        user_id: userId,
        provider_id: mapPlatformToProviderId(input.provider_id),
        connection_id: input.connection_id,
        used_percent: input.used_percent ?? null,
        used: input.used ?? null,
        total: input.total ?? null,
        source: input.source || "scrape",
        observed_at: observedAtByConnection.get(input.connection_id) ?? null,
        windows: (input.windows ?? []).map((w) => ({
          window: w.window,
          label: w.label ?? w.window,
          used_percent: w.used_percent ?? null,
          used: w.used ?? null,
          total: w.total ?? null,
          resets_at: w.resets_at ?? null,
        })),
      }));

    const [snapshotWritten, , mirrored] = await Promise.all([
      liveChanged ? putVpsSnapshot(env, userId, next) : Promise.resolve(true),
      putVpsFreshness(env, userId, freshness),
      mirrorUsageToVps(env, mirrorItems),
    ]);
    if ((!snapshotWritten || !mirrored) && (options.requireVpsMirror || vpsConfigured(env))) {
      throw new Error("vps_usage_persistence_failed");
    }
  }
}

export async function upsertProviderUsage(
  env: Env,
  input: UsageUpsertInput,
  ctx?: { waitUntil: (promise: Promise<unknown>) => void }
) {
  return upsertProviderUsageBatch(env, [input], ctx);
}

/**
 * windows_json'u guvenle cozer. Bozuk/eski veri okuma yolunu patlatmamali:
 * bir sonraki tarama zaten dogru JSON'u yazacak.
 */
export function parseWindowsJson(raw: string | null | undefined): StoredWindow[] {
  if (!raw) return [];
  try {
    const parsed = JSON.parse(raw);
    return Array.isArray(parsed) ? (parsed as StoredWindow[]) : [];
  } catch {
    return [];
  }
}


/** Persist scraped/manual subscription fields onto user_connections (source of truth). */
export async function upsertConnectionSubscription(
  env: Env,
  input: {
    connection_id: string;
    plan_name?: string | null;
    price_usd_cents?: number | null;
    billing_cycle?: string | null;
    auto_renew?: number | null;
    purchased_at?: string | null;
    renews_at?: string | null;
    /** When true, write renews_at even if null (clear App Store / unknown). */
    renews_known?: boolean;
    sub_source?: string | null;
    sub_refreshed_at?: string | null;
  }
): Promise<void> {
  const now = nowIso();
  const renewsKnown = input.renews_known === true ? 1 : 0;

  // Bu fonksiyon scrape push yolundan cagriliyor (public.ts), yani sicak.
  // COALESCE'li UPDATE hicbir alan degismese bile satiri ve index'lerini
  // yeniden yaziyordu; ustelik `sub_refreshed_at: now` her cagrida geldigi icin
  // SQL tarafinda tek bir WHERE ile durdurulamiyordu.
  //
  // Onun yerine once okuyup TypeScript'te karsilastiriyoruz: okuma kotasinin
  // %5'indeyiz, yazma kotasini asiyoruz ve satir basina yazma okumadan 1000x
  // pahali. Bir okuma ekleyip bir yazma elemek her zaman kazancli.
  const existing = await db(env)
    .prepare(
      `SELECT plan_name, price_usd_cents, billing_cycle, auto_renew, purchased_at,
              renews_at, sub_source, sub_refreshed_at
         FROM user_connections WHERE id = ?`
    )
    .bind(input.connection_id)
    .first<{
      plan_name: string | null;
      price_usd_cents: number | null;
      billing_cycle: string | null;
      auto_renew: number | null;
      purchased_at: string | null;
      renews_at: string | null;
      sub_source: string | null;
      sub_refreshed_at: string | null;
    }>();

  if (existing) {
    // SET ifadesindeki COALESCE/CASE mantiginin birebir aynisi; ikisi birlikte
    // degismeli, yoksa guard gercek bir degisikligi yutar.
    const nextPlanName = input.plan_name ?? existing.plan_name;
    const nextPrice =
      input.price_usd_cents != null && input.price_usd_cents > 0
        ? input.price_usd_cents
        : existing.price_usd_cents;
    const nextBillingCycle = input.billing_cycle ?? existing.billing_cycle;
    const nextAutoRenew = input.auto_renew ?? existing.auto_renew;
    const nextPurchasedAt = input.purchased_at ?? existing.purchased_at;
    const nextRenewsAt = renewsKnown
      ? (input.renews_at ?? null)
      : (input.renews_at ?? existing.renews_at);
    const nextSubSource =
      existing.sub_source === "manual"
        ? "manual"
        : (input.sub_source ?? existing.sub_source);

    // Tazelik damgasi, abonelik alanlarindan bagimsiz olarak saatte bir
    // yenileniyor; canli usage freshness'i ise VPS Redis'te tutuluyor.
    const stampStale =
      !existing.sub_refreshed_at ||
      Date.parse(existing.sub_refreshed_at) < Date.now() - 60 * 60 * 1000;

    const unchanged =
      nextPlanName === existing.plan_name &&
      nextPrice === existing.price_usd_cents &&
      nextBillingCycle === existing.billing_cycle &&
      nextAutoRenew === existing.auto_renew &&
      nextPurchasedAt === existing.purchased_at &&
      nextRenewsAt === existing.renews_at &&
      nextSubSource === existing.sub_source &&
      !stampStale;

    if (unchanged) return;
  }

  await db(env)
    .prepare(
      `UPDATE user_connections SET
         plan_name = COALESCE(?, plan_name),
         price_usd_cents = CASE
           WHEN ? IS NOT NULL AND ? > 0 THEN ?
           ELSE price_usd_cents
         END,
         billing_cycle = COALESCE(?, billing_cycle),
         auto_renew = COALESCE(?, auto_renew),
         purchased_at = COALESCE(?, purchased_at),
         renews_at = CASE
           WHEN ? = 1 THEN ?
           ELSE COALESCE(?, renews_at)
         END,
         sub_source = CASE
           WHEN sub_source = 'manual' THEN 'manual'
           ELSE COALESCE(?, sub_source)
         END,
         sub_refreshed_at = COALESCE(?, sub_refreshed_at, ?)
       WHERE id = ?`
    )
    .bind(
      input.plan_name ?? null,
      input.price_usd_cents ?? null,
      input.price_usd_cents ?? null,
      input.price_usd_cents ?? null,
      input.billing_cycle ?? null,
      input.auto_renew ?? null,
      input.purchased_at ?? null,
      renewsKnown,
      input.renews_at ?? null,
      input.renews_at ?? null,
      input.sub_source ?? null,
      input.sub_refreshed_at ?? null,
      now,
      input.connection_id
    )
    .run();
}

export type UserRow = {
  id: string;
  email: string;
  name?: string;
  surname?: string;
  username: string;
  role?: string;
  avatar?: string;
  plan?: string;
  status?: string;
  phone?: string;
  address?: string;
  notifications_enabled?: number;
  created_at?: string;
  /** Primary OAuth provider when user signed up / linked via Google or GitHub. */
  auth_provider?: string | null;
  provider_id?: string | null;
};

/** Public handle: 3–32 chars, letters/digits/_/- only. Stored lowercase. */
export const USERNAME_REGEX = /^[a-zA-Z0-9_-]{3,32}$/;

export function normalizeUsername(raw: string): string {
  return raw.trim().toLowerCase();
}

export function validateUsername(raw: string): { ok: true; username: string } | { ok: false; error: string } {
  const username = normalizeUsername(raw);
  if (!username) return { ok: false, error: "Username required" };
  if (!USERNAME_REGEX.test(username)) {
    return { ok: false, error: "Username must be 3–32 characters (letters, numbers, _ or -)" };
  }
  return { ok: true, username };
}

/** Sanitize email/name into a valid username base. */
export function usernameBaseFromSeed(seed: string): string {
  const base = seed
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9_-]/g, "")
    .slice(0, 24);
  return base.length >= 3 ? base : `user${base || "x"}`.slice(0, 24);
}

export async function isUsernameTaken(
  env: Env,
  username: string,
  excludeUserId?: string
): Promise<boolean> {
  const normalized = normalizeUsername(username);
  if (!normalized) return false;
  if (excludeUserId) {
    const row = await db(env)
      .prepare(
        "SELECT id FROM users WHERE username = ? COLLATE NOCASE AND id != ? LIMIT 1"
      )
      .bind(normalized, excludeUserId)
      .first<{ id: string }>();
    return Boolean(row);
  }
  const row = await db(env)
    .prepare("SELECT id FROM users WHERE username = ? COLLATE NOCASE LIMIT 1")
    .bind(normalized)
    .first<{ id: string }>();
  return Boolean(row);
}

/** Allocate a free username; if preferred is free use it, else append numeric suffix. */
export async function allocateUsername(
  env: Env,
  preferred: string | undefined | null,
  seed: string
): Promise<string> {
  if (preferred) {
    const v = validateUsername(preferred);
    if (v.ok === false) throw new Error(v.error);
    if (await isUsernameTaken(env, v.username)) {
      throw new Error("Username already taken");
    }
    return v.username;
  }
  const base = usernameBaseFromSeed(seed);
  for (let i = 0; i < 50; i++) {
    const candidate = i === 0 ? base : `${base}${i + 1}`.slice(0, 32);
    if (candidate.length < 3) continue;
    if (!(await isUsernameTaken(env, candidate))) return candidate;
  }
  return `u${Date.now().toString(36)}`.slice(0, 32);
}

export async function getUserByEmail(env: Env, email: string): Promise<UserRow | null> {
  const row = await db(env)
    .prepare("SELECT id, email, name, surname, username, role, avatar, plan, status, phone, address, notifications_enabled, created_at, auth_provider, provider_id FROM users WHERE email = ?")
    .bind(normalizeEmail(email))
    .first<UserRow>();
  return row || null;
}

export async function getUserById(env: Env, id: string): Promise<UserRow | null> {
  const row = await db(env)
    .prepare("SELECT id, email, name, surname, username, role, avatar, plan, status, phone, address, notifications_enabled, created_at, auth_provider, provider_id FROM users WHERE id = ?")
    .bind(id)
    .first<UserRow>();
  return row || null;
}

export type ActiveAuthUser = {
  id: string;
  email: string;
  role: string;
};

export class InactiveAccountError extends Error {
  readonly code = "account_inactive";

  constructor() {
    super("account_inactive");
    this.name = "InactiveAccountError";
  }
}

/** Load the current account state; stale JWT claims are never sufficient. */
export async function getActiveAuthUser(env: Env, id: string): Promise<ActiveAuthUser | null> {
  const row = await getUserById(env, id);
  if (!row || row.status !== "active") return null;
  return { id: row.id, email: row.email, role: row.role || "user" };
}

/** Revoke every long-lived session after a password/security state change. */
export async function revokeAllRefreshTokens(env: Env, userId: string): Promise<number> {
  const result = await db(env)
    .prepare("DELETE FROM refresh_tokens WHERE user_id = ?")
    .bind(userId)
    .run();
  return result.meta?.changes ?? 0;
}

export type WorkspaceResolution = {
  workspace_id: string;
  role: string;
  workspace_name: string;
  plan_slug: string;
  plan_name: string;
  max_seats: number;
  extra_seats: number;
  max_providers: number;
  gift_months: number | null;
  gift_started_at: string | null;
  price_monthly_cents: number | null;
  price_yearly_cents: number | null;
  subscription_started_at: string | null;
  subscription_ends_at: string | null;
};

function hydrateWorkspacePlan<T extends {
  workspace_id: string;
  role: string;
  workspace_name: string;
  plan_slug?: string | null;
  gift_months: number | null;
  gift_started_at: string | null;
  subscription_started_at: string | null;
  subscription_ends_at: string | null;
  extra_seats?: number | null;
  store_extra_seats?: number | null;
}>(row: T | null): WorkspaceResolution | null {
  if (!row) return null;
  const def = planDefForSlug(row.plan_slug);
  return {
    workspace_id: row.workspace_id,
    role: row.role,
    workspace_name: row.workspace_name,
    plan_slug: def.slug,
    plan_name: def.name,
    extra_seats: Math.max(0, row.extra_seats ?? 0) + Math.max(0, row.store_extra_seats ?? 0),
    max_seats: def.max_seats === -1
      ? -1
      : def.max_seats + Math.max(0, row.extra_seats ?? 0) + Math.max(0, row.store_extra_seats ?? 0),
    max_providers: def.max_providers,
    gift_months: row.gift_months,
    gift_started_at: row.gift_started_at,
    price_monthly_cents: def.price_monthly_cents,
    price_yearly_cents: def.price_yearly_cents,
    subscription_started_at: row.subscription_started_at,
    subscription_ends_at: row.subscription_ends_at,
  };
}

export async function resolveWorkspaceForUser(env: Env, userId: string, preferredWorkspaceId?: string) {
  if (preferredWorkspaceId) {
    const member = await db(env)
      .prepare(
        `SELECT am.workspace_id, am.role, a.name AS workspace_name, a.plan_slug,
                a.extra_seats, a.store_extra_seats,
                a.gift_months, a.gift_started_at,
                a.subscription_started_at, a.subscription_ends_at
           FROM workspace_members am
           JOIN workspaces a ON a.id = am.workspace_id
          WHERE am.user_id = ? AND am.workspace_id = ?`
      )
      .bind(userId, preferredWorkspaceId)
      .first<{
        workspace_id: string;
        role: string;
        workspace_name: string;
        plan_slug: string | null;
        extra_seats: number | null;
        store_extra_seats: number | null;
        gift_months: number | null;
        gift_started_at: string | null;
        subscription_started_at: string | null;
        subscription_ends_at: string | null;
      }>();
    const hydrated = hydrateWorkspacePlan(member);
    if (hydrated) return hydrated;
  }

  const row = await db(env)
    .prepare(
      `SELECT am.workspace_id, am.role, a.name AS workspace_name, a.plan_slug,
              a.extra_seats, a.store_extra_seats,
              a.gift_months, a.gift_started_at,
              a.subscription_started_at, a.subscription_ends_at
         FROM workspace_members am
         JOIN workspaces a ON a.id = am.workspace_id
        WHERE am.user_id = ?
        ORDER BY CASE am.role WHEN 'owner' THEN 0 ELSE 1 END
        LIMIT 1`
    )
    .bind(userId)
    .first<{
      workspace_id: string;
      role: string;
      workspace_name: string;
      plan_slug: string | null;
      extra_seats: number | null;
      store_extra_seats: number | null;
      gift_months: number | null;
      gift_started_at: string | null;
      subscription_started_at: string | null;
      subscription_ends_at: string | null;
    }>();
  return hydrateWorkspacePlan(row);
}

/**
 * Read-only dashboard lookup. Role middleware and mutation paths continue to
 * use resolveWorkspaceForUser directly so authorization never depends on a
 * TTL cache.
 */
export async function resolveWorkspaceForUserCached(
  env: Env,
  userId: string,
  preferredWorkspaceId?: string
): Promise<WorkspaceResolution | null> {
  const key = `workspace:${userId}:${preferredWorkspaceId || "default"}`;
  return vpsCached<WorkspaceResolution | null>(
    env,
    key,
    30,
    () => resolveWorkspaceForUser(env, userId, preferredWorkspaceId)
  );
}

export async function listMemberships(env: Env, userId: string) {
  const { results } = await db(env)
    .prepare(
      `SELECT am.workspace_id, am.role, a.name AS workspace_name, a.plan_slug
         FROM workspace_members am
         JOIN workspaces a ON a.id = am.workspace_id
        WHERE am.user_id = ?`
    )
    .bind(userId)
    .all<{
      workspace_id: string;
      role: string;
      workspace_name: string;
      plan_slug: string | null;
    }>();
  return (results || []).map((m) => {
    const def = planDefForSlug(m.plan_slug);
    return {
      workspace_id: m.workspace_id,
      role: m.role,
      workspace_name: m.workspace_name,
      plan_slug: def.slug,
      plan_name: def.name,
    };
  });
}

export async function buildUserProfile(env: Env, userId: string, preferredWorkspaceId?: string) {
  const user = await getUserById(env, userId);
  if (!user) return null;

  const account = await resolveWorkspaceForUser(env, userId, preferredWorkspaceId);
  const memberships = await listMemberships(env, userId);
  const planSlug = account?.plan_slug || user.plan || "free";
  const features = planFeaturesForSlug(planSlug);

  return {
    id: user.id,
    email: user.email,
    name: user.name || "",
    surname: user.surname || "",
    username: user.username || null,
    role: user.role || "user",
    avatar: user.avatar || null,
    plan: planSlug,
    plan_name: account?.plan_name || "Free",
    plan_features: features,
    max_seats: account?.max_seats ?? 1,
    extra_seats: account?.extra_seats ?? 0,
    max_providers: account?.max_providers ?? 3,
    notifications_enabled: user.notifications_enabled !== 0,
    phone: user.phone || "",
    address: user.address || "",
    auth_provider: user.auth_provider || null,
    workspace_id: account?.workspace_id,
    workspace_name: account?.workspace_name ?? null,
    workspace_role: account?.role || "owner",
    active_workspace_id: account?.workspace_id,
    created_at: user.created_at,
    subscription_started_at: account?.subscription_started_at ?? null,
    subscription_ends_at: account?.subscription_ends_at ?? null,
    memberships: memberships.map((m: Record<string, unknown>) => ({
      workspace_id: m.workspace_id,
      workspace_name: m.workspace_name,
      role: m.role,
      plan_slug: m.plan_slug,
      plan_name: m.plan_name,
    })),
  };
}

export async function createDefaultWorkspace(env: Env, userId: string, userName: string) {
  const workspaceId = crypto.randomUUID();

  await db(env)
    .prepare(`INSERT INTO workspaces (id, name, plan_slug) VALUES (?, ?, 'free')`)
    .bind(workspaceId, `${userName}'s Workspace`)
    .run();

  await db(env)
    .prepare(
      `INSERT INTO workspace_members (workspace_id, user_id, role, joined_at) VALUES (?, ?, 'owner', datetime('now'))`
    )
    .bind(workspaceId, userId)
    .run();

  return workspaceId;
}

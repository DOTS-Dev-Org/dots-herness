import type { Env } from "../env";
import { db, nowIso, uuid } from "../db/client";
import { recordAudit, type RecordAuditOpts } from "./audit";
import {
  resolveEffectivePriceUsdCents,
  type SubscriptionPacketRow,
} from "./provider_prices";
import {
  DEFAULT_SYNC_INTERVAL_SECS,
  normalizeSyncInterval,
  type SyncIntervalSecs,
} from "./sync_interval";
import {
  DUAL_WINDOW_PROVIDERS,
  getUsageSnapshot,
  mapPlatformToProviderId,
  parseWindowsJson,
} from "./users";
import { getVpsFreshness, vpsCacheBust, vpsCached } from "./vps_usage";

const WINDOW_ORDER = ["5h", "daily", "weekly", "monthly", "models", "api", "auto", "fable", "primary"];

const CURSOR_WINDOW_LABELS: Record<string, string> = {
  models: "First-party models",
  api: "Cursor API",
  auto: "Cursor Auto",
};

/** Cursor UI has models/api(/auto) only — drop synthetic Total + old names. */
const LEGACY_CURSOR_WINDOWS = new Set(["5h", "weekly", "primary", "total", "monthly"]);

type ProviderRow = {
  id: string;
  name: string;
  status: string | null;
  brand_color: string | null;
  default_unit: string | null;
  default_price_usd_cents: number | null;
  support_type: string | null;
  image_key: string | null;
};

type UsageRow = {
  id: string;
  connection_id: string;
  account_label: string | null;
  name: string;
  status: string | null;
  brand_color: string | null;
  default_unit: string | null;
  image_key: string | null;
  used_percent: number | null;
  used: string | null;
  total: string | null;
  budget_limit: number | null;
  alert_threshold: number | null;
  /** JSON array of up to 3 percent thresholds, e.g. "[50,80,100]". */
  alert_thresholds: string | null;
  resets_at: string | null;
  error: string | null;
  observed_at: string | null;
  source: string | null;
  updated_at: string | null;
  support_type: string | null;
  custom_nickname: string | null;
  custom_logo_url: string | null;
  /** JSON array of StoredWindow; provider_usage_windows tablosunun yerini aldi. */
  windows_json: string | null;
};

/** Max custom alert thresholds per provider. */
export const MAX_ALERT_THRESHOLDS = 3;

/**
 * Normalize user-supplied alert thresholds:
 * integers 1–100, unique, sorted asc, max 3. Empty array allowed (no alerts).
 */
export function normalizeAlertThresholds(raw: unknown): number[] {
  if (raw == null) return [];
  const list = Array.isArray(raw) ? raw : [raw];
  const set = new Set<number>();
  for (const item of list) {
    const n = typeof item === "number" ? item : Number(item);
    if (!Number.isFinite(n)) continue;
    const rounded = Math.round(n);
    if (rounded < 1 || rounded > 100) continue;
    set.add(rounded);
  }
  return [...set].sort((a, b) => a - b).slice(0, MAX_ALERT_THRESHOLDS);
}

/** Parse stored JSON or fall back to legacy single alert_threshold. */
export function parseAlertThresholds(
  json: string | null | undefined,
  legacy: number | null | undefined
): number[] {
  if (json != null && String(json).trim()) {
    try {
      const parsed = JSON.parse(String(json));
      if (Array.isArray(parsed)) {
        // Explicit empty array = no custom alerts.
        return normalizeAlertThresholds(parsed);
      }
      const normalized = normalizeAlertThresholds(parsed);
      if (normalized.length) return normalized;
    } catch {
      /* fall through */
    }
  }
  const single = legacy != null && Number.isFinite(Number(legacy)) ? Math.round(Number(legacy)) : 80;
  if (single < 1 || single > 100) return [80];
  return [single];
}

export function alertThresholdsToJson(thresholds: number[]): string {
  return JSON.stringify(normalizeAlertThresholds(thresholds));
}

type WindowRow = {
  window: string;
  label: string;
  used_percent: number;
  used: string;
  total: string;
  resets_at: string | null;
  updated_at: string | null;
};

type SubscriptionRow = {
  provider_id: string;
  plan_name: string | null;
  price_usd_cents: number | null;
  billing_cycle: string | null;
  auto_renew: number | null;
  purchased_at: string | null;
  renews_at: string | null;
  source: string | null;
  last_refreshed_at: string | null;
  refresh_status: string | null;
  refresh_note: string | null;
};

export type UsageWindowPayload = {
  window: string;
  label: string;
  used: number;
  total: number;
  unit: string;
  resetsAt: string | null;
  /** Snake alias for desktop clients that only read resets_at. */
  resets_at?: string | null;
  /** Percent used (0–100). Desktop mapWindows prefers this over used/total. */
  used_percent?: number;
  usedRaw: string;
  totalRaw: string;
  pending?: boolean;
};

export type ProviderSubscriptionPayload = {
  planName: string | null;
  priceUsdCents: number | null;
  billingCycle: string | null;
  autoRenew: boolean | null;
  purchasedAt: string | null;
  /** Scraped/manual subscription renewal ISO, or null when unknown (App Store etc.). */
  renewsAt: string | null;
  /** Budget period anchor: renewsAt ?? connection.created_at. */
  periodAnchorAt: string | null;
  source: string;
  lastRefreshedAt: string | null;
  refreshStatus: string | null;
  refreshNote: string | null;
};

export type ProviderUsagePayload = {
  id: string;
  /** Which connected account this usage belongs to (user_connections.id). */
  connectionId: string;
  /** User-facing nickname/email for this account, or null for the default/only connection. */
  accountLabel: string | null;
  name: string;
  status: string;
  brandColor: string | null;
/** Relative R2 PNG asset path derived from providers.image_key. */
  logoUrl: string | null;
  current: number;
  total: number;
  budget: number | null;
  unit: string;
  resetTime: string;
  averageCost: string;
  /** Legacy primary threshold (lowest of alertThresholds, or 80). */
  alertThreshold: number;
  /** Up to 3 custom usage % alert thresholds. Empty = no custom alerts. */
  alertThresholds: number[];
  /** Per-provider sync/scan interval from user_connections (seconds). */
  syncIntervalSecs: number;
  used_percent: number | null;
  used: string | null;
  total_raw: string | null;
  resets_at: string | null;
  error: string | null;
  observed_at: string | null;
  source: string | null;
  updated_at: string | null;
  windows: UsageWindowPayload[];
  subscription: ProviderSubscriptionPayload | null;
  /** Catalog auth model: 'api_key' | 'subscription' | 'api_and_subscription'. */
  supportType: string | null;
  /** How this specific connection was made: 'api_key' | 'login'. */
  connectionType: string | null;
  pending?: boolean;
  /** User-chosen display name override for this connection, or null. */
  customNickname: string | null;
  /** User-uploaded logo URL override for this connection, or null. */
  customLogoUrl: string | null;
};

/**
 * Provider logos are catalog assets in R2; D1 stores the stable image_key only.
 * The PNG derivative is used by native clients, while the existing SVG remains the
 * canonical web asset. Fall back to the provider id for legacy rows whose image_key
 * was not backfilled.
 */
export function providerLogoPath(
  imageKey: string | null | undefined,
  providerId?: string | null
): string | null {
  const key = (imageKey || providerId || "").trim();
  return key ? `/assets/providers/${encodeURIComponent(key)}.png` : null;
}

export type ProviderBillingPayload = {
  id: string;
  name: string;
  brandColor: string | null;
  planName: string | null;
  priceUsdCents: number | null;
  billingCycle: string | null;
  autoRenew: boolean | null;
  purchasedAt: string | null;
  renewsAt: string | null;
  periodAnchorAt: string | null;
  source: string;
  type: string;
  lastRefreshedAt: string | null;
  refreshStatus: string | null;
  refreshNote: string | null;
  scope: "account" | "personal";
};

function parseNum(val: string | null | undefined, fallback = 0): number {
  if (val == null || val === "") return fallback;
  const cleaned = String(val).replace(/[^0-9.]/g, "");
  const n = parseFloat(cleaned);
  return Number.isFinite(n) ? n : fallback;
}

function sortWindows(windows: WindowRow[]): WindowRow[] {
  return [...windows].sort((a, b) => {
    const ai = WINDOW_ORDER.indexOf(a.window);
    const bi = WINDOW_ORDER.indexOf(b.window);
    return (ai === -1 ? 999 : ai) - (bi === -1 ? 999 : bi);
  });
}

function isTokenUnit(unit: string): boolean {
  return unit.toLowerCase() === "token" || unit.toLowerCase() === "tokens";
}

function windowUsedValue(w: WindowRow, unit: string): number {
  if (isTokenUnit(unit)) {
    const fromRaw = parseNum(w.used, -1);
    if (fromRaw >= 0) return fromRaw;
  }
  return w.used_percent;
}

function windowTotalValue(w: WindowRow, unit: string): number {
  const fromRaw = parseNum(w.total, -1);
  if (isTokenUnit(unit) && fromRaw > 0) return fromRaw;
  const totalNum = fromRaw > 0 ? fromRaw : 100;
  return totalNum > 0 ? totalNum : 100;
}

function mapWindow(w: WindowRow, unit: string): UsageWindowPayload {
  const usedVal = windowUsedValue(w, unit);
  const totalVal = windowTotalValue(w, unit);
  const pct =
    w.used_percent != null && Number.isFinite(w.used_percent)
      ? Math.min(100, Math.max(0, Math.round(w.used_percent)))
      : totalVal > 0
        ? Math.min(100, Math.max(0, Math.round((usedVal / totalVal) * 100)))
        : Math.min(100, Math.max(0, Math.round(usedVal)));
  return {
    window: w.window,
    label: w.label,
    used: usedVal,
    total: totalVal,
    unit,
    resetsAt: w.resets_at,
    resets_at: w.resets_at,
    used_percent: pct,
    usedRaw: w.used,
    totalRaw: w.total,
  };
}

function resolveUsageWindows(
  providerId: string,
  windows: UsageWindowPayload[]
): UsageWindowPayload[] {
  const normalized = normalizeProviderWindows(providerId, windows);
  return normalized;
}

function normalizeProviderWindows(
  providerId: string,
  windows: UsageWindowPayload[]
): UsageWindowPayload[] {
  if (providerId !== "cursor") return windows;

  return windows
    .filter((w) => !LEGACY_CURSOR_WINDOWS.has(w.window))
    .map((w) => ({
      ...w,
      label: CURSOR_WINDOW_LABELS[w.window] || w.label,
    }));
}

function resolveBillingSource(
  sub: SubscriptionRow | undefined,
  hasUsage: boolean,
  defaultPriceCents: number | null
): string {
  if (!sub) {
    // Fixed-fee plan (e.g. ChatGPT Plus $20/mo): price is known from the
    // provider catalog, no desktop scrape needed to count it in the budget.
    return defaultPriceCents != null && defaultPriceCents > 0 ? "default" : "needs_desktop";
  }
  if (sub.source === "manual" || sub.source === "scrape" || sub.source === "api") {
    return sub.source;
  }
  if (sub.plan_name || (sub.price_usd_cents != null && sub.price_usd_cents > 0)) {
    return sub.source || "scrape";
  }
  if (hasUsage) return sub.source || "default";
  return "needs_desktop";
}

function mapSubscription(
  sub: SubscriptionRow,
  catalog: SubscriptionPacketRow[] = [],
  connectionCreatedAt: string | null = null
): ProviderSubscriptionPayload {
  const renewsAt = sub.renews_at;
  return {
    planName: sub.plan_name,
    priceUsdCents: resolveEffectivePriceUsdCents({
      storedPriceUsdCents: sub.price_usd_cents,
      planName: sub.plan_name,
      catalog,
    }),
    billingCycle: sub.billing_cycle,
    autoRenew: sub.auto_renew == null ? null : sub.auto_renew !== 0,
    purchasedAt: sub.purchased_at,
    renewsAt,
    periodAnchorAt: renewsAt ?? connectionCreatedAt,
    source: sub.source || "manual",
    lastRefreshedAt: sub.last_refreshed_at,
    refreshStatus: sub.refresh_status,
    refreshNote: sub.refresh_note,
  };
}

function mapBillingProvider(
  provider: ProviderRow,
  sub: SubscriptionRow | undefined,
  hasUsage: boolean,
  scope: "account" | "personal" = "personal",
  catalog: SubscriptionPacketRow[] = [],
  connectionCreatedAt: string | null = null
): ProviderBillingPayload {
  const source = resolveBillingSource(sub, hasUsage, provider.default_price_usd_cents);
  const subscriptionModel = provider.default_price_usd_cents ? "fixed" : "usage";
  const priceUsdCents =
    source === "needs_desktop"
      ? null
      : resolveEffectivePriceUsdCents({
          storedPriceUsdCents: sub?.price_usd_cents,
          planName: sub?.plan_name,
          catalog,
          defaultPriceUsdCents: provider.default_price_usd_cents,
        }) ?? 0;
  const renewsAt = sub?.renews_at ?? null;
  return {
    id: provider.id,
    name: provider.name,
    brandColor: provider.brand_color,
    planName: sub?.plan_name ?? null,
    priceUsdCents,
    billingCycle: sub?.billing_cycle ?? "monthly",
    autoRenew: sub?.auto_renew == null ? null : sub.auto_renew !== 0,
    purchasedAt: sub?.purchased_at ?? null,
    renewsAt,
    periodAnchorAt: renewsAt ?? connectionCreatedAt,
    source,
    type: subscriptionModel,
    lastRefreshedAt: sub?.last_refreshed_at ?? null,
    refreshStatus: sub?.refresh_status ?? null,
    refreshNote: sub?.refresh_note ?? null,
    scope,
  };
}

function buildPlaceholderProviderUsage(
  provider: ProviderRow,
  sub: SubscriptionRow | undefined,
  syncIntervalSecs: SyncIntervalSecs = DEFAULT_SYNC_INTERVAL_SECS,
  catalog: SubscriptionPacketRow[] = [],
  connectionId = "",
  accountLabel: string | null = null,
  connectionCreatedAt: string | null = null,
  connectionType: string | null = null
): ProviderUsagePayload {
  const unit = provider.default_unit || "%";

  return {
    id: provider.id,
    connectionId,
    accountLabel,
    name: provider.name,
    status: provider.status || "active",
    brandColor: provider.brand_color,
    logoUrl: providerLogoPath(provider.image_key, provider.id),
    current: 0,
    total: 0,
    budget: null,
    unit,
    resetTime: "—",
    averageCost: sub?.plan_name || "—",
    alertThreshold: 80,
    alertThresholds: [80],
    syncIntervalSecs,
    used_percent: null,
    used: null,
    total_raw: null,
    resets_at: null,
    error: null,
    observed_at: null,
    source: "needs_sync",
    updated_at: null,
    windows: [],
    subscription: sub ? mapSubscription(sub, catalog, connectionCreatedAt) : null,
    supportType: provider.support_type,
    connectionType,
    pending: true,
    customNickname: null,
    customLogoUrl: null,
  };
}

function buildProviderUsage(
  row: UsageRow,
  windows: WindowRow[],
  sub: SubscriptionRow | undefined,
  syncIntervalSecs: SyncIntervalSecs = DEFAULT_SYNC_INTERVAL_SECS,
  catalog: SubscriptionPacketRow[] = [],
  connectionCreatedAt: string | null = null,
  connectionType: string | null = null
): ProviderUsagePayload {
  const unit = row.default_unit || "%";
  const scrapedTotal = parseNum(row.total, 100);
  // Kullanıcı bütçe override'ı set ise limit olarak onu kullan.
  const budget =
    row.budget_limit != null && Number(row.budget_limit) > 0
      ? Number(row.budget_limit)
      : null;
  const total = budget ?? (scrapedTotal > 0 ? scrapedTotal : 100);
  const current = isTokenUnit(unit)
    ? parseNum(row.used, row.used_percent ?? 0)
    : row.used_percent ?? parseNum(row.used);

  const mappedWindows = sortWindows(windows).map((w) => mapWindow(w, unit));
  const sortedWindows = resolveUsageWindows(row.id, mappedWindows);
  const pending =
    sortedWindows.length === 0 &&
    (DUAL_WINDOW_PROVIDERS.has(row.id) || row.source === "needs_sync");

  const primary5h = sortedWindows.find((w) => w.window === "5h") ?? sortedWindows[0];
  const displayCurrent = primary5h?.used ?? current;
  const displayTotal = primary5h?.total ?? (total > 0 ? total : 0);
  // Dual-window (MiniMax): surface 5h as primary % so clients don't show weekly as "5h"
  const displayUsedPercent =
    primary5h?.used_percent != null
      ? primary5h.used_percent
      : row.used_percent;

  const alertThresholds = parseAlertThresholds(row.alert_thresholds, row.alert_threshold);
  const alertThreshold = alertThresholds[0] ?? 80;

  return {
    id: row.id,
    connectionId: row.connection_id,
    accountLabel: row.account_label,
    name: row.name,
    status: row.status || "active",
    brandColor: row.brand_color,
    logoUrl: providerLogoPath(row.image_key, row.id),
    current: displayCurrent,
    total: displayTotal > 0 ? displayTotal : 0,
    budget,
    unit,
    resetTime: row.resets_at || primary5h?.resetsAt || "—",
    averageCost: sub?.plan_name || "—",
    alertThreshold,
    alertThresholds,
    syncIntervalSecs,
    used_percent: displayUsedPercent,
    used: row.used,
    total_raw: row.total,
    resets_at: row.resets_at || primary5h?.resetsAt || null,
    error: row.error,
    observed_at: row.observed_at,
    source: row.source,
    updated_at: row.updated_at,
    windows: sortedWindows,
    subscription: sub ? mapSubscription(sub, catalog, connectionCreatedAt) : null,
    supportType: row.support_type,
    connectionType,
    pending: pending || undefined,
    customNickname: row.custom_nickname,
    customLogoUrl: row.custom_logo_url,
  };
}

export type LoadAccountUsageOptions = {
  /** When false, skip upstream provider refresh and return cached D1 data only. */
  refresh?: boolean;
  /** When false, only return keys owned by userEmail (no team-shared keys). */
  includeTeamShared?: boolean;
};

export async function loadWorkspaceUsage(
  env: Env,
  workspaceId: string,
  userEmail: string,
  filterProviderId?: string,
  userId?: string,
  options?: LoadAccountUsageOptions
): Promise<{
  usage: Record<string, ProviderUsagePayload[]>;
  billingProviders: ProviderBillingPayload[];
  connectedProviderIds: string[];
  connectedProviders: Array<{ id: string; name: string; brand_color: string | null }>;
}> {
  const normalizedFilter = filterProviderId
    ? mapPlatformToProviderId(filterProviderId)
    : undefined;

  // Only the target user's own connections — never team-shared provider data.
  const includeTeamShared = options?.includeTeamShared === true;
  const connectionsQuery = includeTeamShared
    ? `SELECT id, user_id, provider, account_label, scope, sync_interval_secs, user_email, created_at,
              plan_name, price_usd_cents, billing_cycle, auto_renew, purchased_at,
              renews_at, sub_source, sub_refreshed_at, connection_type
         FROM user_connections
        WHERE user_id = ?
           OR (scope = 'account' AND user_id IN (
               SELECT user_id FROM workspace_members WHERE workspace_id = ?
           ))
        ORDER BY created_at DESC`
    : `SELECT id, user_id, provider, account_label, scope, sync_interval_secs, user_email, created_at,
              plan_name, price_usd_cents, billing_cycle, auto_renew, purchased_at,
              renews_at, sub_source, sub_refreshed_at, connection_type
         FROM user_connections WHERE user_id = ?
        ORDER BY created_at DESC`;
  const connectionsBind = includeTeamShared ? [userId ?? "", workspaceId] : [userId ?? ""];

  type ConnectionRow = {
    id: string;
    user_id: string;
    provider: string;
    account_label: string | null;
    scope: string | null;
    sync_interval_secs: number | null;
    user_email: string;
    created_at: string | null;
    plan_name: string | null;
    price_usd_cents: number | null;
    billing_cycle: string | null;
    auto_renew: number | null;
    purchased_at: string | null;
    renews_at: string | null;
    sub_source: string | null;
    sub_refreshed_at: string | null;
    connection_type: string | null;
  };

  // A user's connection list changes far less often than clients poll usage,
  // so it is cached per user and scope.
  //
  // Invalidation is split deliberately. Actions the user takes and expects to
  // see immediately — connecting, disconnecting, renaming, changing the sync
  // interval — bust this key explicitly. Background subscription refreshes
  // (plan name, price, renewal date, written by scrapes) do not: busting on
  // those would mean a cache-clear on nearly every poll, defeating the cache,
  // and a two-minute delay on a plan label the user did not just change is
  // invisible. Hence the short TTL — it bounds exactly that staleness.
  const connectionRows = await vpsCached<ConnectionRow[]>(
    env,
    `conns:${userId ?? "none"}:${includeTeamShared ? `team:${workspaceId}` : "own"}`,
    120,
    async () => {
      const { results } = await db(env)
        .prepare(connectionsQuery)
        .bind(...connectionsBind)
        .all<ConnectionRow>();
      return results || [];
    }
  );

  type ConnRow = {
    id: string;
    user_id: string;
    provider_id: string;
    account_label: string | null;
    scope: string | null;
    sync_interval_secs: number | null;
    user_email: string;
    created_at: string | null;
    plan_name: string | null;
    price_usd_cents: number | null;
    billing_cycle: string | null;
    auto_renew: number | null;
    purchased_at: string | null;
    renews_at: string | null;
    sub_source: string | null;
    sub_refreshed_at: string | null;
    connection_type: string | null;
  };
  const connectionRowsNormalized: ConnRow[] = (connectionRows || [])
    .filter((k) => !normalizedFilter || mapPlatformToProviderId(k.provider) === normalizedFilter)
    .map((k) => ({
      id: k.id,
      user_id: k.user_id,
      provider_id: mapPlatformToProviderId(k.provider),
      account_label: k.account_label,
      scope: k.scope,
      sync_interval_secs: k.sync_interval_secs,
      user_email: k.user_email,
      created_at: k.created_at,
      plan_name: k.plan_name,
      price_usd_cents: k.price_usd_cents,
      billing_cycle: k.billing_cycle,
      auto_renew: k.auto_renew,
      purchased_at: k.purchased_at,
      renews_at: k.renews_at,
      sub_source: k.sub_source,
      sub_refreshed_at: k.sub_refreshed_at,
      connection_type: k.connection_type,
    }));

  const intervalByProvider = new Map<string, SyncIntervalSecs>();
  const connectionsByProvider = new Map<string, ConnRow[]>();
  const connectedProviderIds: string[] = [];
  const seenProviders = new Set<string>();

  for (const k of connectionRowsNormalized) {
    if (!seenProviders.has(k.provider_id)) {
      seenProviders.add(k.provider_id);
      connectedProviderIds.push(k.provider_id);
    }
    const list = connectionsByProvider.get(k.provider_id) || [];
    list.push(k);
    connectionsByProvider.set(k.provider_id, list);
    // Prefer current user's connection interval over team-shared.
    const isOwn = k.user_id === userId;
    if (!intervalByProvider.has(k.provider_id) || isOwn) {
      intervalByProvider.set(k.provider_id, normalizeSyncInterval(k.sync_interval_secs));
    }
  }

  // GET/read paths are cache-only. Upstream refreshes belong to the explicit
  // POST refresh endpoints; keep this branch disabled for every GET caller.
  const shouldRefresh = false;

  if (shouldRefresh && userId && connectedProviderIds.length > 0) {
    const snapshot = await getUsageSnapshot(env, userId);
    const existingMap = new Map(
      Object.values(snapshot).map((entry) => [
        entry.connection_id,
        { observed_at: entry.observed_at, source: entry.source },
      ])
    );
    const { refreshStaleProviderUsage } = await import("./provider_fetch");
    await refreshStaleProviderUsage(
      env,
      workspaceId,
      userId,
      userEmail,
      connectedProviderIds,
      existingMap
    );
  }

  // Usage is always personal (user_id). Without userId we can only return connections + empty usage.
  const usageQuery = !userId
    ? null
    : normalizedFilter
      ? `SELECT p.id, apu.connection_id, uc.account_label, p.name, p.status, p.brand_color, p.default_unit,
                p.image_key, p.support_type,
                apu.used_percent, apu.used, apu.total, apu.budget_limit, apu.alert_threshold, apu.alert_thresholds,
                apu.resets_at, apu.error, apu.observed_at, apu.source, apu.updated_at,
                apu.custom_nickname, apu.custom_logo_url, apu.windows_json
           FROM user_provider_usage apu
           JOIN providers p ON p.id = apu.provider_id
           JOIN user_connections uc ON uc.id = apu.connection_id
          WHERE apu.user_id = ? AND apu.provider_id = ?`
      : `SELECT p.id, apu.connection_id, uc.account_label, p.name, p.status, p.brand_color, p.default_unit,
                p.image_key, p.support_type,
                apu.used_percent, apu.used, apu.total, apu.budget_limit, apu.alert_threshold, apu.alert_thresholds,
                apu.resets_at, apu.error, apu.observed_at, apu.source, apu.updated_at,
                apu.custom_nickname, apu.custom_logo_url, apu.windows_json
           FROM user_provider_usage apu
           JOIN providers p ON p.id = apu.provider_id
           JOIN user_connections uc ON uc.id = apu.connection_id
          WHERE apu.user_id = ?`;

  const usageBind = !userId
    ? []
    : normalizedFilter
      ? [userId, normalizedFilter]
      : [userId];

  const usageRows = userId && usageQuery
    ? await vpsCached<UsageRow[]>(
        env,
        `usage-meta:${userId}:${normalizedFilter || "all"}`,
        120,
        async () => {
          const { results } = await db(env)
            .prepare(usageQuery)
            .bind(...usageBind)
            .all<UsageRow>();
          return results || [];
        }
      )
    : [];
  const usageRowByConnection = new Map<string, UsageRow>();
  for (const row of usageRows || []) usageRowByConnection.set(row.connection_id, row);

  // Window'lar artik user_provider_usage.windows_json icinde geliyor, yani
  // yukaridaki sorguda zaten okundular. Eskiden provider_usage_windows'a ayri
  // bir sorgu daha gidiyordu; o round-trip tamamen kalkti.
  const windowsByConnection = new Map<string, WindowRow[]>();
  for (const row of usageRows || []) {
    const parsed = parseWindowsJson(row.windows_json);
    if (parsed.length) windowsByConnection.set(row.connection_id, parsed as WindowRow[]);
  }

  const subRows = userId
    ? await vpsCached<(SubscriptionRow & { connection_id: string })[]>(
        env,
        `subs-meta:${userId}`,
        120,
        async () => {
          const { results } = await db(env)
            .prepare(
              `SELECT connection_id, provider_id, plan_name, price_usd_cents,
                      billing_cycle, auto_renew, purchased_at, renews_at,
                      source, last_refreshed_at, refresh_status, refresh_note
                 FROM provider_subscriptions
                WHERE user_id = ?`
            )
            .bind(userId)
            .all<SubscriptionRow & { connection_id: string }>();
          return results || [];
        }
      )
    : [];

  // Freshness lives in Redis now; the D1 columns are only a last-known value
  // for rows written before the move, so Redis wins where it has an entry.
  const liveFreshness = userId ? await getVpsFreshness(env, userId) : null;
  const applyFreshness = (connectionId: string, row: SubscriptionRow): SubscriptionRow => {
    const live = liveFreshness?.[connectionId];
    if (!live) return row;
    return { ...row, last_refreshed_at: live.at, refresh_status: live.status };
  };

  const subsByConnection = new Map<string, SubscriptionRow>();
  const subsByProvider = new Map<string, SubscriptionRow>();
  // Prefer denormalized connection subscription as source of truth.
  for (const conn of connectionRowsNormalized) {
    if (!(conn.plan_name || conn.renews_at || conn.price_usd_cents != null)) continue;
    const row: SubscriptionRow = {
      provider_id: conn.provider_id,
      plan_name: conn.plan_name,
      price_usd_cents: conn.price_usd_cents,
      billing_cycle: conn.billing_cycle,
      auto_renew: conn.auto_renew,
      purchased_at: conn.purchased_at,
      renews_at: conn.renews_at,
      source: conn.sub_source,
      last_refreshed_at: conn.sub_refreshed_at,
      refresh_status: "fresh",
      refresh_note: null,
    };
    const withFreshness = applyFreshness(conn.id, row);
    subsByConnection.set(conn.id, withFreshness);
    if (!subsByProvider.has(conn.provider_id)) {
      subsByProvider.set(conn.provider_id, withFreshness);
    }
  }
  for (const s of subRows || []) {
    const withFreshness = applyFreshness(s.connection_id, s);
    if (!subsByConnection.has(s.connection_id)) {
      subsByConnection.set(s.connection_id, withFreshness);
    }
    if (!subsByProvider.has(s.provider_id)) {
      subsByProvider.set(s.provider_id, withFreshness);
    }
  }

  // Catalog list prices — used when user has not set a manual override.
  const catalogRows = await vpsCached<SubscriptionPacketRow[]>(
    env,
    "catalog:subscription_packets:v1",
    600,
    async () => {
      const { results } = await db(env)
        .prepare(
          `SELECT provider_id, plan_slug, plan_label, price_usd_cents
             FROM subscription_packets`
        )
        .all<SubscriptionPacketRow>();
      return results || [];
    }
  );
  const catalogByProvider = new Map<string, SubscriptionPacketRow[]>();
  for (const row of catalogRows || []) {
    const list = catalogByProvider.get(row.provider_id) || [];
    list.push(row);
    catalogByProvider.set(row.provider_id, list);
  }

  const scopeByProvider = new Map<string, "account" | "personal">();
  for (const k of connectionRowsNormalized) {
    if (!scopeByProvider.has(k.provider_id)) {
      scopeByProvider.set(k.provider_id, (k.scope as "account" | "personal") || "personal");
    }
  }

  // Provider meta (name/status/brand) — needed to render placeholder entries
  // for connections that haven't produced any usage row yet.
  const providerMetaById = new Map<string, ProviderRow>();
  if (connectedProviderIds.length > 0) {
    const placeholders = connectedProviderIds.map(() => "?").join(", ");
    // The provider catalog is editorial data — it changes when an admin edits
    // it, not per request — so it is cached by the exact id set requested.
    const metaRows = await vpsCached<ProviderRow[]>(
      env,
      `providers:${[...connectedProviderIds].sort().join(",")}`,
      600,
      async () => {
        const { results } = await db(env)
          .prepare(
            `SELECT id, name, status, brand_color, default_unit, default_price_usd_cents, support_type, image_key
               FROM providers WHERE id IN (${placeholders})`
          )
          .bind(...connectedProviderIds)
          .all<ProviderRow>();
        return results || [];
      }
    );
    for (const m of metaRows || []) providerMetaById.set(m.id, m);
  }

  // High-frequency live values come from one user JSON snapshot. Keep the
  // legacy user_provider_usage row as the settings/fallback source, then
  // overlay only its live fields. New connections may have no legacy row yet,
  // so create an in-memory row from the connection + provider catalog metadata.
  if (userId) {
    const snapshot = await getUsageSnapshot(env, userId);
    for (const conn of connectionRowsNormalized) {
      const entry = snapshot[conn.id];
      if (!entry) continue;

      const legacy = usageRowByConnection.get(conn.id);
      if (legacy) {
        legacy.used_percent = entry.used_percent;
        legacy.used = entry.used;
        legacy.total = entry.total;
        legacy.resets_at = entry.resets_at;
        legacy.error = entry.error;
        legacy.observed_at = entry.observed_at;
        legacy.source = entry.source;
        legacy.updated_at = entry.updated_at;
        legacy.windows_json = JSON.stringify(entry.windows);
      } else {
        const meta = providerMetaById.get(conn.provider_id);
        usageRowByConnection.set(conn.id, {
          id: conn.provider_id,
          connection_id: conn.id,
          account_label: conn.account_label,
          name: meta?.name ?? conn.provider_id,
          status: meta?.status ?? "active",
          brand_color: meta?.brand_color ?? null,
          default_unit: meta?.default_unit ?? null,
          image_key: meta?.image_key ?? null,
          used_percent: entry.used_percent,
          used: entry.used,
          total: entry.total,
          budget_limit: null,
          alert_threshold: null,
          alert_thresholds: null,
          resets_at: entry.resets_at,
          error: entry.error,
          observed_at: entry.observed_at,
          source: entry.source,
          updated_at: entry.updated_at,
          support_type: meta?.support_type ?? null,
          custom_nickname: null,
          custom_logo_url: null,
          windows_json: JSON.stringify(entry.windows),
        });
      }
      windowsByConnection.set(conn.id, entry.windows as WindowRow[]);
    }
  }

  // Her provider için, o provider'a bağlı TÜM bağlantılar (aynı provider'ın
  // birden fazla hesabı dahil) kendi entry'si olarak listelenir.
  const usage: Record<string, ProviderUsagePayload[]> = {};
  for (const providerId of connectedProviderIds) {
    const conns = connectionsByProvider.get(providerId) || [];
    const list: ProviderUsagePayload[] = [];
    for (const conn of conns) {
      const usageRow = usageRowByConnection.get(conn.id);
      // Prefer denormalized subscription on user_connections; fall back to legacy table.
      const subFromConn: SubscriptionRow | undefined =
        conn.plan_name || conn.renews_at || conn.price_usd_cents != null
          ? {
              provider_id: conn.provider_id,
              plan_name: conn.plan_name,
              price_usd_cents: conn.price_usd_cents,
              billing_cycle: conn.billing_cycle,
              auto_renew: conn.auto_renew,
              purchased_at: conn.purchased_at,
              renews_at: conn.renews_at,
              source: conn.sub_source,
              last_refreshed_at: conn.sub_refreshed_at,
              refresh_status: "fresh",
              refresh_note: null,
            }
          : undefined;
      const sub = subFromConn ?? subsByConnection.get(conn.id);
      const interval = intervalByProvider.get(providerId) ?? DEFAULT_SYNC_INTERVAL_SECS;
      const catalog = catalogByProvider.get(providerId) || [];
      if (usageRow) {
        list.push(
          buildProviderUsage(
            usageRow,
            windowsByConnection.get(conn.id) || [],
            sub,
            interval,
            catalog,
            conn.created_at,
            conn.connection_type
          )
        );
      } else {
        const meta = providerMetaById.get(providerId);
        if (meta) {
          list.push(
            buildPlaceholderProviderUsage(
              meta,
              sub,
              interval,
              catalog,
              conn.id,
              conn.account_label,
              conn.created_at,
              conn.connection_type
            )
          );
        }
      }
    }
    if (list.length > 0) usage[providerId] = list;
  }

  const providerIdsForBilling = new Set<string>([
    ...connectedProviderIds,
    ...Object.keys(usage),
  ]);

  const billingProviders: ProviderBillingPayload[] = [];
  if (providerIdsForBilling.size > 0) {
    const ids = [...providerIdsForBilling];
    const placeholders = ids.map(() => "?").join(", ");
    const providerRows = await vpsCached<ProviderRow[]>(
      env,
      `providers:${[...ids].sort().join(",")}`,
      600,
      async () => {
        const { results } = await db(env)
          .prepare(
            `SELECT id, name, status, brand_color, default_unit, default_price_usd_cents, support_type, image_key
               FROM providers WHERE id IN (${placeholders})`
          )
          .bind(...ids)
          .all<ProviderRow>();
        return results || [];
      }
    );

    for (const provider of providerRows || []) {
      const firstConn = connectionsByProvider.get(provider.id)?.[0];
      billingProviders.push(
        mapBillingProvider(
          provider,
          subsByProvider.get(provider.id),
          Boolean(usage[provider.id]?.length),
          scopeByProvider.get(provider.id) || "personal",
          catalogByProvider.get(provider.id) || [],
          firstConn?.created_at ?? null
        )
      );
    }
  }

  const connectedProviders = connectedProviderIds.map((id) => {
    const meta = providerMetaById.get(id);
    return { id, name: meta?.name ?? id, brand_color: meta?.brand_color ?? null };
  });

  return { usage, billingProviders, connectedProviderIds, connectedProviders };
}

export type SpendTrendGranularity = "daily" | "weekly" | "monthly" | "yearly";

export type SpendTrendPoint = {
  key: string;
  label: string;
  spendUsdCents: number;
};

export type SpendTrendResult = {
  granularity: SpendTrendGranularity;
  suggestedGranularity: SpendTrendGranularity;
  membershipStartedAt: string | null;
  membershipDays: number;
  title: string;
  unitLabel: string;
  points: SpendTrendPoint[];
};

/** @deprecated Use SpendTrendPoint */
export type SpendTrendMonth = SpendTrendPoint;

const TR_MONTH_LABELS = [
  "Oca", "Şub", "Mar", "Nis", "May", "Haz",
  "Tem", "Ağu", "Eyl", "Eki", "Kas", "Ara",
];

const MS_DAY = 86_400_000;

import {
  buildSpendTrendPoints,
  type SubscriptionHistoryInput,
} from "./spend_trend";

type SubscriptionHistoryRow = SubscriptionHistoryInput & {
  billing_cycle: string | null;
};

type TimeBucket = { key: string; label: string; endIso: string; startIso: string };

export function parseSpendTrendGranularity(
  raw?: string | null
): SpendTrendGranularity | null {
  if (raw === "daily" || raw === "weekly" || raw === "monthly" || raw === "yearly") {
    return raw;
  }
  return null;
}

export function suggestSpendTrendGranularity(membershipDays: number): SpendTrendGranularity {
  if (membershipDays < 180) return "weekly";
  if (membershipDays < 365) return "monthly";
  return "monthly";
}

function clampGranularity(
  requested: SpendTrendGranularity,
  membershipDays: number
): SpendTrendGranularity {
  if (requested === "yearly" && membershipDays < 365) {
    return membershipDays < 180 ? "weekly" : "monthly";
  }
  if (requested === "monthly" && membershipDays < 32) return "weekly";
  return requested;
}

async function resolveMembershipStart(
  env: Env,
  workspaceId: string,
  userId: string,
  account: { subscription_started_at: string | null; gift_started_at: string | null }
): Promise<Date> {
  const times: number[] = [];

  for (const raw of [account.subscription_started_at, account.gift_started_at]) {
    if (raw) {
      const t = Date.parse(raw);
      if (Number.isFinite(t)) times.push(t);
    }
  }

  const member = await db(env)
    .prepare("SELECT joined_at FROM workspace_members WHERE workspace_id = ? AND user_id = ?")
    .bind(workspaceId, userId)
    .first<{ joined_at: string | null }>();
  if (member?.joined_at) {
    const t = Date.parse(member.joined_at);
    if (Number.isFinite(t)) times.push(t);
  }

  const earliestKey = await db(env)
    .prepare("SELECT MIN(created_at) AS ts FROM user_connections WHERE user_id = ?")
    .bind(userId)
    .first<{ ts: string | null }>();
  if (earliestKey?.ts) {
    const t = Date.parse(earliestKey.ts);
    if (Number.isFinite(t)) times.push(t);
  }

  const userRow = await db(env)
    .prepare("SELECT created_at FROM users WHERE id = ?")
    .bind(userId)
    .first<{ created_at: string | null }>();
  if (userRow?.created_at) {
    const t = Date.parse(userRow.created_at);
    if (Number.isFinite(t)) times.push(t);
  }

  if (times.length === 0) return new Date();
  return new Date(Math.min(...times));
}

function pad2(n: number): string {
  return String(n).padStart(2, "0");
}

/** Pazartesi 00:00 — haftanın başlangıcı (Pzt–Paz). */
function startOfWeekMonday(d: Date): Date {
  const result = new Date(d);
  result.setHours(0, 0, 0, 0);
  const day = result.getDay();
  const diff = day === 0 ? -6 : 1 - day;
  result.setDate(result.getDate() + diff);
  return result;
}

function endOfWeekSunday(weekStartMonday: Date): Date {
  const end = new Date(weekStartMonday);
  end.setDate(end.getDate() + 6);
  end.setHours(23, 59, 59, 999);
  return end;
}

/** Örn. 30.06-04.07 (kısmi haftada bitiş bugüne kadar). */
function formatWeekRangeLabel(weekStart: Date, weekEnd: Date): string {
  const sd = weekStart.getDate();
  const sm = weekStart.getMonth() + 1;
  const ed = weekEnd.getDate();
  const em = weekEnd.getMonth() + 1;
  const sy = weekStart.getFullYear();
  const ey = weekEnd.getFullYear();

  if (sy !== ey) {
    return `${pad2(sd)}.${pad2(sm)}.${String(sy).slice(-2)}-${pad2(ed)}.${pad2(em)}.${String(ey).slice(-2)}`;
  }
  return `${pad2(sd)}.${pad2(sm)}-${pad2(ed)}.${pad2(em)}`;
}

function buildTimeBuckets(
  granularity: SpendTrendGranularity,
  membershipStart: Date,
  now: Date
): TimeBucket[] {
  const startMs = membershipStart.getTime();
  const nowMs = now.getTime();

  if (granularity === "daily") {
    const buckets: TimeBucket[] = [];
    const maxDays = 30;
    for (let i = maxDays - 1; i >= 0; i--) {
      const dayEnd = new Date(now);
      dayEnd.setHours(23, 59, 59, 999);
      dayEnd.setDate(dayEnd.getDate() - i);
      const dayStart = new Date(dayEnd);
      dayStart.setHours(0, 0, 0, 0);
      if (dayStart.getTime() < startMs) continue;
      buckets.push({
        key: dayStart.toISOString().slice(0, 10),
        label: String(dayStart.getDate()),
        endIso: dayEnd.toISOString(),
        startIso: dayStart.toISOString(),
      });
    }
    if (buckets.length === 0) {
      const dayEnd = new Date(now);
      dayEnd.setHours(23, 59, 59, 999);
      const dayStart = new Date(dayEnd);
      dayStart.setHours(0, 0, 0, 0);
      buckets.push({
        key: dayStart.toISOString().slice(0, 10),
        label: String(dayStart.getDate()),
        endIso: dayEnd.toISOString(),
        startIso: dayStart.toISOString(),
      });
    }
    return buckets;
  }

  if (granularity === "weekly") {
    const periodStartMs = Math.max(startMs, nowMs - 30 * MS_DAY);
    const buckets: TimeBucket[] = [];
    let weekStart = startOfWeekMonday(new Date(periodStartMs));

    while (weekStart.getTime() <= nowMs && buckets.length < 6) {
      const weekEndFull = endOfWeekSunday(weekStart);
      let effectiveEnd = weekEndFull.getTime() > nowMs ? new Date(now) : weekEndFull;
      effectiveEnd.setHours(23, 59, 59, 999);

      const effectiveStart = new Date(
        Math.max(weekStart.getTime(), startMs, periodStartMs)
      );
      effectiveStart.setHours(0, 0, 0, 0);

      if (effectiveEnd.getTime() >= effectiveStart.getTime()) {
        buckets.push({
          key: `w-${weekStart.toISOString().slice(0, 10)}`,
          label: formatWeekRangeLabel(effectiveStart, effectiveEnd),
          endIso: effectiveEnd.toISOString(),
          startIso: weekStart.toISOString(),
        });
      }

      const next = new Date(weekStart);
      next.setDate(next.getDate() + 7);
      weekStart = next;
    }
    return buckets;
  }

  if (granularity === "monthly") {
    const monthCount = Math.max(
      1,
      Math.min(6, Math.ceil((nowMs - startMs) / (30 * MS_DAY)))
    );
    const buckets: TimeBucket[] = [];
    for (let i = monthCount - 1; i >= 0; i--) {
      const d = new Date(now.getFullYear(), now.getMonth() - i, 1);
      const y = d.getFullYear();
      const m = d.getMonth();
      const monthStart = new Date(y, m, 1);
      if (monthStart.getTime() < startMs && i > 0) continue;
      const end = new Date(y, m + 1, 0, 23, 59, 59, 999);
      if (end.getTime() < startMs) continue;
      buckets.push({
        key: `${y}-${String(m + 1).padStart(2, "0")}`,
        label: TR_MONTH_LABELS[m],
        endIso: end.toISOString(),
        startIso: monthStart.toISOString(),
      });
    }
    return buckets.length > 0 ? buckets : buildTimeBuckets("weekly", membershipStart, now);
  }

  const startYear = membershipStart.getFullYear();
  const endYear = now.getFullYear();
  const buckets: TimeBucket[] = [];
  for (let y = startYear; y <= endYear; y++) {
    const yearStart = new Date(y, 0, 1);
    const yearEnd =
      y === endYear ? new Date(now) : new Date(y, 11, 31, 23, 59, 59, 999);
    if (yearEnd.getTime() < startMs) continue;
    buckets.push({
      key: String(y),
      label: String(y),
      endIso: yearEnd.toISOString(),
      startIso: yearStart.toISOString(),
    });
  }
  return buckets.slice(-5);
}

function metaForGranularity(
  granularity: SpendTrendGranularity,
  pointCount: number,
  refYear = new Date().getFullYear()
): { title: string; unitLabel: string } {
  switch (granularity) {
    case "daily":
      return { title: "Son 30 Günlük Harcama Akışı", unitLabel: `USD / Günlük · ${refYear}` };
    case "weekly":
      return { title: "Son Ay Haftalık Harcama", unitLabel: `USD / Haftalık · ${refYear}` };
    case "monthly":
      return {
        title:
          pointCount >= 6
            ? "Son 6 Aylık Harcama Akışı"
            : `Son ${pointCount} Aylık Harcama`,
        unitLabel: `USD / Aylık · ${refYear}`,
      };
    case "yearly":
      return { title: "Yıllık Harcama Akışı", unitLabel: "USD / Yıllık" };
  }
}

export async function getSpendTrend(
  env: Env,
  opts: {
    workspaceId: string;
    userId: string;
    userEmail: string;
    /** @deprecated Event-tabanlı hesaplamada kullanılmıyor */
    currentSpendUsdCents?: number;
    membershipStartedAt: string | null;
    giftStartedAt: string | null;
    granularity?: SpendTrendGranularity | null;
  }
): Promise<SpendTrendResult> {
  const now = new Date();
  let membershipStart = await resolveMembershipStart(env, opts.workspaceId, opts.userId, {
    subscription_started_at: opts.membershipStartedAt,
    gift_started_at: opts.giftStartedAt,
  });

  const userRow = await db(env)
    .prepare("SELECT created_at FROM users WHERE id = ?")
    .bind(opts.userId)
    .first<{ created_at: string | null }>();
  if (userRow?.created_at) {
    const regTime = Date.parse(userRow.created_at);
    if (Number.isFinite(regTime) && membershipStart.getTime() < regTime) {
      membershipStart = new Date(regTime);
    }
  }

  const membershipDays = Math.max(
    1,
    Math.floor((now.getTime() - membershipStart.getTime()) / MS_DAY)
  );
  const suggestedGranularity = suggestSpendTrendGranularity(membershipDays);
  const granularity = clampGranularity(
    opts.granularity ?? suggestedGranularity,
    membershipDays
  );

  const buckets = buildTimeBuckets(granularity, membershipStart, now);

  const { results: keyRows } = await db(env)
    .prepare("SELECT provider, created_at FROM user_connections WHERE user_id = ?")
    .bind(opts.userId)
    .all<{ provider: string; created_at: string }>();

  const keysByProvider = new Map<string, string>();
  for (const k of keyRows || []) {
    keysByProvider.set(mapPlatformToProviderId(k.provider), k.created_at);
  }

  const { results: allHistory } = await db(env)
    .prepare(
      `SELECT provider_id, price_usd_cents, billing_cycle, plan_name, source, observed_at
         FROM provider_subscription_history
        WHERE workspace_id = ?
        ORDER BY observed_at ASC`
    )
    .bind(opts.workspaceId)
    .all<SubscriptionHistoryRow>();

  const points: SpendTrendPoint[] = buildSpendTrendPoints(
    (allHistory || []).map((row) => ({
      ...row,
      provider_id: mapPlatformToProviderId(row.provider_id),
    })),
    keysByProvider,
    buckets
  );

  const { title, unitLabel } = metaForGranularity(granularity, points.length, now.getFullYear());

  return {
    granularity,
    suggestedGranularity,
    membershipStartedAt: membershipStart.toISOString(),
    membershipDays,
    title,
    unitLabel,
    points,
  };
}

/** Geriye dönük uyumluluk — aylık granülarite. */
export async function getMonthlySpendTrend(
  env: Env,
  workspaceId: string,
  userEmail: string,
  currentMonthSpendUsdCents: number,
  userId?: string,
  membershipStartedAt?: string | null,
  giftStartedAt?: string | null
): Promise<SpendTrendPoint[]> {
  const result = await getSpendTrend(env, {
    workspaceId,
    userId: userId ?? "",
    userEmail,
    membershipStartedAt: membershipStartedAt ?? null,
    giftStartedAt: giftStartedAt ?? null,
    granularity: "monthly",
  });
  return result.points;
}

/** Her abonelik sync/scrape'inde append-only fiyat geçmişi kaydı. */
export async function recordSubscriptionHistory(
  env: Env,
  opts: {
    workspaceId: string;
    userId?: string | null;
    providerId: string;
    priceUsdCents?: number | null;
    billingCycle?: string | null;
    planName?: string | null;
    source?: string | null;
    observedAt?: string;
  }
): Promise<void> {
  const price = opts.priceUsdCents ?? null;
  const plan = opts.planName ?? null;
  if ((!price || price <= 0) && !plan) return;

  const providerId = mapPlatformToProviderId(opts.providerId);

  const last = await db(env)
    .prepare(
      `SELECT price_usd_cents, plan_name FROM provider_subscription_history
        WHERE workspace_id = ? AND provider_id = ?
        ORDER BY observed_at DESC LIMIT 1`
    )
    .bind(opts.workspaceId, providerId)
    .first<{ price_usd_cents: number | null; plan_name: string | null }>();

  if (
    last &&
    (last.price_usd_cents ?? null) === price &&
    (last.plan_name ?? null) === (plan ?? null)
  ) {
    return;
  }

  await db(env)
    .prepare(
      `INSERT INTO provider_subscription_history (
         id, workspace_id, user_id, provider_id, price_usd_cents,
         billing_cycle, plan_name, source, observed_at
       ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`
    )
    .bind(
      uuid(),
      opts.workspaceId,
      opts.userId ?? null,
      providerId,
      price,
      opts.billingCycle ?? "monthly",
      plan,
      opts.source ?? "manual",
      opts.observedAt ?? nowIso()
    )
    .run();
}

export type ProviderUsageLimitPatch = {
  total?: number;
  /** Legacy single threshold — merged into alertThresholds when array not sent. */
  alertThreshold?: number;
  /** Up to 3 percent thresholds (1–100). Empty array clears custom alerts. */
  alertThresholds?: number[];
  /** User-chosen display name override. Empty string clears it. */
  customNickname?: string;
  /** User-uploaded logo URL override. Empty string clears it. */
  customLogoUrl?: string;
};

export type ProviderUsageLimitAuditContext = Pick<
  RecordAuditOpts,
  "actorUserId" | "actorEmail" | "ip" | "userAgent"
>;

/** PATCH semantiği: yalnızca gönderilen alanları günceller. Kullanıcıya özel. */
export async function patchProviderUsageLimits(
  env: Env,
  userId: string,
  providerId: string,
  patch: ProviderUsageLimitPatch,
  audit?: ProviderUsageLimitAuditContext,
  workspaceId?: string | null
): Promise<{
  provider_id: string;
  user_id: string;
  budget_limit: number | null;
  alert_threshold: number;
  alert_thresholds: number[];
  custom_nickname: string | null;
  custom_logo_url: string | null;
}> {
  // Budget/alert ayarı hâlâ provider bazlı bir UI kavramı — aynı provider'dan
  // birden fazla hesap varsa en yeni bağlantıya uygulanır (tek-hesaplı
  // kullanıcılar için davranış birebir aynı kalır).
  const { latestConnectionForProvider } = await import("./users");
  const connection = await latestConnectionForProvider(env, userId, providerId);
  if (!connection) {
    throw new Error("provider_not_connected");
  }
  const connectionId = connection.id;

  const existing = await db(env)
    .prepare(
      "SELECT budget_limit, alert_threshold, alert_thresholds, custom_nickname, custom_logo_url FROM user_provider_usage WHERE connection_id = ?"
    )
    .bind(connectionId)
    .first<{
      budget_limit: number | null;
      alert_threshold: number | null;
      alert_thresholds: string | null;
      custom_nickname: string | null;
      custom_logo_url: string | null;
    }>();

  const oldBudget = existing?.budget_limit ?? null;
  const oldThresholds = parseAlertThresholds(
    existing?.alert_thresholds,
    existing?.alert_threshold
  );

  const budget =
    patch.total !== undefined
      ? patch.total > 0
        ? patch.total
        : null
      : oldBudget;

  let thresholds: number[];
  if (patch.alertThresholds !== undefined) {
    thresholds = normalizeAlertThresholds(patch.alertThresholds);
  } else if (patch.alertThreshold !== undefined) {
    // Legacy: replace list with single value.
    thresholds = normalizeAlertThresholds([patch.alertThreshold]);
  } else {
    thresholds = oldThresholds;
  }

  // Legacy column: lowest threshold, or 80 when none set.
  const alertThreshold = thresholds[0] ?? 80;
  const thresholdsJson = alertThresholdsToJson(thresholds);
  const updatedAt = nowIso();

  const customNickname =
    patch.customNickname !== undefined
      ? patch.customNickname.trim() || null
      : (existing?.custom_nickname ?? null);
  const customLogoUrl =
    patch.customLogoUrl !== undefined
      ? patch.customLogoUrl.trim() || null
      : (existing?.custom_logo_url ?? null);

  await db(env)
    .prepare(
      `INSERT INTO user_provider_usage (connection_id, user_id, provider_id, budget_limit, alert_threshold, alert_thresholds, custom_nickname, custom_logo_url, updated_at, source)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'manual')
       ON CONFLICT(connection_id) DO UPDATE SET
         budget_limit = excluded.budget_limit,
         alert_threshold = excluded.alert_threshold,
         alert_thresholds = excluded.alert_thresholds,
         custom_nickname = excluded.custom_nickname,
         custom_logo_url = excluded.custom_logo_url,
         updated_at = excluded.updated_at`
    )
    .bind(
      connectionId,
      userId,
      providerId,
      budget,
      alertThreshold,
      thresholdsJson,
      customNickname,
      customLogoUrl,
      updatedAt
    )
    .run();

  await vpsCacheBust(env, { prefix: `usage-meta:${userId}` });

  if (workspaceId && patch.total !== undefined && budget != null && budget > 0) {
    const oldCents =
      oldBudget != null && oldBudget > 0 ? Math.round(oldBudget * 100) : 0;
    const newCents = Math.round(budget * 100);
    if (newCents > oldCents) {
      await recordSubscriptionHistory(env, {
        workspaceId,
        userId: audit?.actorUserId ?? userId,
        providerId,
        priceUsdCents: newCents,
        billingCycle: "monthly",
        planName: "Budget",
        source: "manual",
        observedAt: updatedAt,
      });
    }
  }

  if (audit) {
    await recordAudit(env, {
      workspaceId: workspaceId ?? undefined,
      actorUserId: audit.actorUserId,
      actorEmail: audit.actorEmail,
      action: "provider.limits.update",
      entityType: "provider",
      entityId: providerId,
      metadata: {
        provider_id: providerId,
        old_budget_limit: existing?.budget_limit ?? null,
        new_budget_limit: budget,
        old_alert_threshold: existing?.alert_threshold ?? null,
        new_alert_threshold: alertThreshold,
        old_alert_thresholds: oldThresholds,
        new_alert_thresholds: thresholds,
      },
      ip: audit.ip,
      userAgent: audit.userAgent,
    });
  }

  return {
    provider_id: providerId,
    user_id: userId,
    budget_limit: budget,
    alert_threshold: alertThreshold,
    alert_thresholds: thresholds,
    custom_nickname: customNickname,
    custom_logo_url: customLogoUrl,
  };
}

export type ProviderSubscriptionPatch = {
  planName?: string;
  /** Pass null to clear manual override and fall back to catalog list price. */
  priceUsdCents?: number | null;
  billingCycle?: "monthly" | "yearly";
  /** Manual subscription renewal ISO; pass null to clear. */
  renewsAt?: string | null;
};

/**
 * Manual override for a provider's subscription plan/price (e.g. user bought
 * Claude Pro yearly at $17/mo instead of the $20 catalog default). Always
 * wins over the subscription_packets fallback used in loadWorkspaceUsage.
 * Pass priceUsdCents: null to clear the override. User-scoped.
 */
export async function patchProviderSubscription(
  env: Env,
  userId: string,
  providerId: string,
  patch: ProviderSubscriptionPatch,
  audit?: ProviderUsageLimitAuditContext,
  workspaceId?: string | null
): Promise<ProviderSubscriptionPayload> {
  // Aynı provider'dan birden fazla hesap varsa en yeni bağlantıya uygulanır
  // (tek-hesaplı kullanıcılar için davranış birebir aynı kalır).
  const { latestConnectionForProvider } = await import("./users");
  const connection = await latestConnectionForProvider(env, userId, providerId);
  if (!connection) {
    throw new Error("provider_not_connected");
  }
  const connectionId = connection.id;

  const existing = await db(env)
    .prepare(
      `SELECT plan_name, price_usd_cents, billing_cycle, renews_at FROM provider_subscriptions
        WHERE connection_id = ?`
    )
    .bind(connectionId)
    .first<{
      plan_name: string | null;
      price_usd_cents: number | null;
      billing_cycle: string | null;
      renews_at: string | null;
    }>();

  const connMeta = await db(env)
    .prepare(`SELECT created_at, renews_at FROM user_connections WHERE id = ?`)
    .bind(connectionId)
    .first<{ created_at: string | null; renews_at: string | null }>();

  const planName = patch.planName !== undefined ? patch.planName : existing?.plan_name ?? null;
  // null clears override; undefined keeps existing
  const priceUsdCents =
    patch.priceUsdCents !== undefined ? patch.priceUsdCents : existing?.price_usd_cents ?? null;
  const billingCycle = patch.billingCycle ?? existing?.billing_cycle ?? "monthly";
  const renewsAt =
    patch.renewsAt !== undefined
      ? patch.renewsAt
      : existing?.renews_at ?? connMeta?.renews_at ?? null;
  const now = nowIso();

  await db(env)
    .prepare(
      `INSERT INTO provider_subscriptions (
         connection_id, user_id, provider_id, plan_name, price_usd_cents, billing_cycle,
         renews_at, source, source_updated_at, last_refreshed_at, refresh_status
       ) VALUES (?, ?, ?, ?, ?, ?, ?, 'manual', ?, ?, 'fresh')
       ON CONFLICT(connection_id) DO UPDATE SET
         plan_name = excluded.plan_name,
         price_usd_cents = excluded.price_usd_cents,
         billing_cycle = excluded.billing_cycle,
         renews_at = excluded.renews_at,
         source = 'manual',
         source_updated_at = excluded.source_updated_at`
    )
    .bind(
      connectionId,
      userId,
      providerId,
      planName,
      priceUsdCents,
      billingCycle,
      renewsAt,
      now,
      now
    )
    .run();

  // Keep denormalized connection subscription in sync (manual override).
  await db(env)
    .prepare(
      `UPDATE user_connections SET
         plan_name = ?,
         price_usd_cents = ?,
         billing_cycle = ?,
         renews_at = ?,
         sub_source = 'manual',
         sub_refreshed_at = ?
       WHERE id = ?`
    )
    .bind(planName, priceUsdCents, billingCycle, renewsAt, now, connectionId)
    .run();

  await Promise.all([
    vpsCacheBust(env, { prefix: `conns:${userId}` }),
    vpsCacheBust(env, { prefix: `subs-meta:${userId}` }),
  ]);

  // Effective price for response (catalog fill when override cleared).
  const { results: catalog } = await db(env)
    .prepare(
      `SELECT provider_id, plan_slug, plan_label, price_usd_cents
         FROM subscription_packets WHERE provider_id = ?`
    )
    .bind(providerId)
    .all<SubscriptionPacketRow>();
  const effectivePrice = resolveEffectivePriceUsdCents({
    storedPriceUsdCents: priceUsdCents,
    planName,
    catalog: catalog || [],
  });

  if (workspaceId) {
    await recordSubscriptionHistory(env, {
      workspaceId,
      userId: audit?.actorUserId ?? userId,
      providerId,
      priceUsdCents: effectivePrice,
      billingCycle,
      planName,
      source: "manual",
      observedAt: now,
    });
  }

  if (audit) {
    await recordAudit(env, {
      workspaceId: workspaceId ?? undefined,
      actorUserId: audit.actorUserId,
      actorEmail: audit.actorEmail,
      action: "provider.subscription.update",
      entityType: "provider",
      entityId: providerId,
      metadata: {
        provider_id: providerId,
        old_price_usd_cents: existing?.price_usd_cents ?? null,
        new_price_usd_cents: priceUsdCents,
        effective_price_usd_cents: effectivePrice,
        old_plan_name: existing?.plan_name ?? null,
        new_plan_name: planName,
        old_billing_cycle: existing?.billing_cycle ?? null,
        new_billing_cycle: billingCycle,
        old_renews_at: existing?.renews_at ?? connMeta?.renews_at ?? null,
        new_renews_at: renewsAt,
      },
      ip: audit.ip,
      userAgent: audit.userAgent,
    });
  }

  return {
    planName,
    priceUsdCents: effectivePrice,
    billingCycle,
    autoRenew: null,
    purchasedAt: null,
    renewsAt,
    periodAnchorAt: renewsAt ?? connMeta?.created_at ?? null,
    source: "manual",
    lastRefreshedAt: now,
    refreshStatus: "fresh",
    refreshNote: null,
  };
}

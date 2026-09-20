// Spend trend buckets and subscription history for the usage dashboards.
import type { Env } from "../env";
import { db, nowIso, uuid } from "../db/client";
import { mapPlatformToProviderId } from "./users";
import {
  buildSpendTrendPoints,
  type SubscriptionHistoryInput,
} from "./spend_trend";

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

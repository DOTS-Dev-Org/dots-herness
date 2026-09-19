import type { Env } from "../env";
import { db } from "../db/client";
import { getUsdTryRate } from "./tcmb";

/** PayTR stores payment amounts in TL kuruş (1/100 TL). */
export function tlKurusToTl(tlKurus: number): number {
  return tlKurus / 100;
}

export function tlKurusToUsd(tlKurus: number, usdTry: number): number {
  if (!usdTry || usdTry <= 0) return 0;
  return tlKurusToTl(tlKurus) / usdTry;
}

export function giftRenewDate(
  giftMonths: number | null | undefined,
  giftStartedAt: string | null | undefined,
): string | null {
  if ((giftMonths ?? 0) <= 0 || !giftStartedAt) return null;
  const end = new Date(
    new Date(giftStartedAt).getTime() + (giftMonths ?? 0) * 30 * 86_400_000,
  );
  return end.toISOString().slice(0, 10);
}

export async function getCompletedOrderTotals(env: Env, opts?: { days?: number }) {
  const rates = await getUsdTryRate(env);
  const usdTry = rates?.usd_try || 32;

  let sql = `SELECT COALESCE(SUM(amount_minor), 0) AS tl_kurus, COUNT(*) AS n
               FROM billing_orders
              WHERE status = 'completed'`;
  const params: unknown[] = [];
  if (opts?.days != null) {
    sql += ` AND completed_at >= NOW() - make_interval(days => ?)`;
    params.push(opts.days);
  }

  const row = await db(env).prepare(sql).bind(...params).first<{ tl_kurus: number; n: number }>();
  const tlKurus = row?.tl_kurus ?? 0;

  return {
    tl_kurus: tlKurus,
    tl: tlKurusToTl(tlKurus),
    usd: tlKurusToUsd(tlKurus, usdTry),
    order_count: row?.n ?? 0,
    usd_try: usdTry,
  };
}

export type RevenueBucket = {
  key: string;
  tl_kurus: number;
  tl: number;
  usd: number;
  order_count: number;
};

/**
 * Real revenue from completed orders, grouped by plan and by payment provider.
 * Gateway-agnostic and deletion-proof: it reads only billing_orders columns
 * (plan_slug, payment_provider, amount_minor), which persist after a user is deleted.
 */
export async function getPlanRevenue(env: Env) {
  const rates = await getUsdTryRate(env);
  const usdTry = rates?.usd_try || 32;

  const { results } = await db(env)
    .prepare(
      `SELECT plan_slug, payment_provider,
              COALESCE(SUM(amount_minor), 0) AS tl_kurus,
              COUNT(*) AS n
         FROM billing_orders
        WHERE status = 'completed'
        GROUP BY plan_slug, payment_provider`
    )
    .all<{ plan_slug: string; payment_provider: string | null; tl_kurus: number; n: number }>();

  const byPlan = new Map<string, RevenueBucket>();
  const byProvider = new Map<string, RevenueBucket>();

  const add = (map: Map<string, RevenueBucket>, key: string, kurus: number, n: number) => {
    const cur = map.get(key) ?? { key, tl_kurus: 0, tl: 0, usd: 0, order_count: 0 };
    cur.tl_kurus += kurus;
    cur.order_count += n;
    cur.tl = tlKurusToTl(cur.tl_kurus);
    cur.usd = tlKurusToUsd(cur.tl_kurus, usdTry);
    map.set(key, cur);
  };

  for (const r of results ?? []) {
    const kurus = r.tl_kurus ?? 0;
    const n = r.n ?? 0;
    add(byPlan, r.plan_slug || "unknown", kurus, n);
    add(byProvider, r.payment_provider || "unknown", kurus, n);
  }

  return {
    by_plan: [...byPlan.values()].map((b) => ({
      plan_slug: b.key,
      tl: b.tl,
      usd: b.usd,
      order_count: b.order_count,
    })),
    by_provider: [...byProvider.values()].map((b) => ({
      payment_provider: b.key,
      tl: b.tl,
      usd: b.usd,
      order_count: b.order_count,
    })),
    usd_try: usdTry,
  };
}

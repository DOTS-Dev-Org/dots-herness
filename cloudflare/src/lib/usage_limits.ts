// Provider usage-limit and subscription patch handlers.
import type { Env } from "../env";
import { db, nowIso } from "../db/client";
import { recordAudit, type RecordAuditOpts } from "./audit";
import { resolveEffectivePriceUsdCents, type SubscriptionPacketRow } from "./provider_prices";
import { vpsCacheBust } from "./vps_usage";
import {
  alertThresholdsToJson,
  loadWorkspaceUsage,
  normalizeAlertThresholds,
  parseAlertThresholds,
  type ProviderSubscriptionPayload,
} from "./usage";
import { recordSubscriptionHistory } from "./usage_spend";

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

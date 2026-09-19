import { Hono } from "hono";
import type { Context } from "hono";
import { zValidator } from "@hono/zod-validator";
import { z } from "zod";
import type { Env, AppVariables } from "../../env";
import { db, normalizeEmail, uuid } from "../../db/client";
import { requireAuth } from "../../middleware/auth";
import { rateLimit } from "../../middleware/rate-limit";
import {
  buildUserProfile,
  isUsernameTaken,
  listMemberships,
  mapPlatformToProviderId,
  resolveWorkspaceForUser,
  resolveWorkspaceForUserCached,
  revokeAllRefreshTokens,
  syncVpsProviderPresence,
  validateUsername,
} from "../../lib/users";
import { nowIso } from "../../db/client";
import { loadWorkspaceUsage, getSpendTrend, parseSpendTrendGranularity, patchProviderUsageLimits, patchProviderSubscription, providerLogoPath } from "../../lib/usage";
import { computeSpendIncrements } from "../../lib/spend_trend";
import { requireAccountRole } from "../../lib/team";
import {
  connectUserTelegramBot,
  disconnectUserTelegram,
  getTelegramConnectionStatus,
} from "../../lib/telegram";
import { clientIpFromRequest, recordAudit } from "../../lib/audit";
import { giftRenewDate } from "../../lib/billing";
import {
  ackUserNotificationEvents,
  insertUserNotificationEvent,
  pollUserNotificationEvents,
} from "../../lib/notification_events";
import { importApnsTokenToFcm } from "../../lib/fcm";
import { verifyPassword } from "../../lib/password";
import { issueTokensWithCookies } from "./auth";
import { sendEmailChangeNotificationEmail } from "../../lib/email";
import { planFeaturesForSlug } from "../../lib/plan_features";
import { issueVpsClientToken } from "../../lib/vps_client_token";
import { heartbeatVpsDevice, purgeVpsUserCurrentState, setVpsDeviceRevoked } from "../../lib/vps_usage";

const user = new Hono<{ Bindings: Env; Variables: AppVariables }>();

function maskExportSecret(value: string | null | undefined): string | null {
  if (!value) return null;
  if (value.length <= 8) return "••••";
  return `${value.slice(0, 4)}…${value.slice(-4)}`;
}

user.use("*", requireAuth);

user.get("/profile", async (c) => {
  const profile = await buildUserProfile(c.env, c.get("user").id, c.get("workspaceId"));
  if (!profile) return c.json({ error: "Not found" }, 404);
  return c.json(profile);
});

user.get("/recent-activity", async (c) => {
  const authUser = c.get("user");
  const activities: Array<{
    id: string;
    type: "login" | "provider" | "extension" | "external_login";
    label: string;
    created_at: string;
  }> = [];

  const [auditRows, connectionRows, deviceRows] = await Promise.all([
    db(c.env)
      .prepare(
        `SELECT id, action, created_at
           FROM audit_events
          WHERE actor_user_id = ? AND action IN ('auth.login', 'auth.qr.login')
          ORDER BY created_at DESC LIMIT 12`
      )
      .bind(authUser.id)
      .all<{ id: string; action: string; created_at: string }>(),
    db(c.env)
      .prepare(
        `SELECT uc.id, uc.name, uc.key_masked, uc.connection_type, uc.created_at,
                COALESCE(p.name, uc.provider) AS provider_name
           FROM user_connections uc
           LEFT JOIN providers p ON p.id = uc.provider
          WHERE uc.user_id = ?
          ORDER BY uc.created_at DESC LIMIT 12`
      )
      .bind(authUser.id)
      .all<{ id: string; name: string; key_masked: string | null; connection_type: string | null; created_at: string; provider_name: string }>(),
    db(c.env)
      .prepare(
        `SELECT id, device_name, platform, created_at
           FROM user_devices
          WHERE user_id = ? AND lower(COALESCE(platform, '')) <> 'web'
          ORDER BY created_at DESC LIMIT 12`
      )
      .bind(authUser.id)
      .all<{ id: string; device_name: string; platform: string | null; created_at: string }>(),
  ]);

  for (const row of auditRows.results || []) {
    activities.push({
      id: `login:${row.id}`,
      type: "login",
      label: row.action === "auth.qr.login" ? "QR ile giriş yapıldı" : "Giriş yapıldı",
      created_at: row.created_at,
    });
  }
  for (const row of connectionRows.results || []) {
    const extension = row.key_masked === "scan" || row.connection_type === "scan" || row.connection_type === "extension";
    activities.push({
      id: `provider:${row.id}`,
      type: extension ? "extension" : "provider",
      label: extension
        ? `Extension bağlandı — ${row.provider_name}`
        : `Provider eklendi — ${row.provider_name}`,
      created_at: row.created_at,
    });
  }
  for (const row of deviceRows.results || []) {
    const platform = (row.platform || "harici cihaz").toLowerCase();
    const kind = platform.includes("watch") || platform.includes("saat") ? "Saat" : "Mobil/harici cihaz";
    activities.push({
      id: `device:${row.id}`,
      type: "external_login",
      label: `${kind} girişi — ${row.device_name}`,
      created_at: row.created_at,
    });
  }

  activities.sort((a, b) => Date.parse(b.created_at) - Date.parse(a.created_at));
  return c.json({ activities: activities.slice(0, 8) });
});

user.patch(
  "/profile",
  zValidator(
    "json",
    z.object({
      name: z.string().min(1).max(64).optional(),
      username: z.string().min(3).max(32).optional(),
    })
  ),
  async (c) => {
    const authUser = c.get("user");
    const body = c.req.valid("json");
    if (body.name == null && body.username == null) {
      return c.json({ error: "Nothing to update" }, 400);
    }

    const sets: string[] = [];
    const binds: unknown[] = [];

    if (body.name != null) {
      sets.push("name = ?");
      binds.push(body.name.trim());
    }

    if (body.username != null) {
      const v = validateUsername(body.username);
      if (v.ok === false) return c.json({ error: v.error, code: "invalid_username" }, 400);
      if (await isUsernameTaken(c.env, v.username, authUser.id)) {
        return c.json({ error: "Username already taken", code: "username_taken" }, 409);
      }
      sets.push("username = ?");
      binds.push(v.username);
    }

    sets.push("updated_at = NOW()");
    binds.push(authUser.id);
    await db(c.env)
      .prepare(`UPDATE users SET ${sets.join(", ")} WHERE id = ?`)
      .bind(...binds)
      .run();

    await recordAudit(c.env, {
      actorUserId: authUser.id,
      actorEmail: authUser.email,
      action: "profile.update",
      entityType: "user",
      entityId: authUser.id,
      metadata: { fields: Object.keys(body) },
      ip: clientIpFromRequest(c.req),
      userAgent: c.req.header("User-Agent") ?? null,
    });

    const profile = await buildUserProfile(c.env, authUser.id, c.get("workspaceId"));
    if (!profile) return c.json({ error: "Not found" }, 404);
    return c.json(profile);
  }
);

user.get("/usage", async (c) => {
  const authUser = c.get("user");
  const email = normalizeEmail(c.req.query("email") || authUser.email);
  if (email !== authUser.email) return c.json({ error: "Forbidden" }, 403);

  const providerFilter =
    c.req.query("provider") || c.req.query("provider_id") || undefined;
  const normalizedProviderId = providerFilter
    ? mapPlatformToProviderId(providerFilter)
    : undefined;

  // GET is strictly a snapshot read. Upstream provider calls and D1 writes
  // belong to POST /api/provider/fetch-usage; refresh query parameters are
  // accepted for client compatibility but intentionally ignored.
  const shouldRefresh = false;

  const account = await resolveWorkspaceForUserCached(c.env, authUser.id, c.get("workspaceId"));
  if (!account?.workspace_id) {
    return c.json({
      usage: {},
      connected_providers: [],
      billingInfo: null,
      ...(normalizedProviderId ? { provider: null } : {}),
    });
  }

  const { usage, billingProviders, connectedProviderIds, connectedProviders } = await loadWorkspaceUsage(
    c.env,
    account.workspace_id,
    email,
    normalizedProviderId,
    authUser.id,
    { refresh: shouldRefresh, includeTeamShared: false }
  );

  const connectedBilling = billingProviders.filter((p) =>
    connectedProviderIds.includes(p.id)
  );
  const monthlySpendUsdCents = connectedBilling.reduce(
    (sum, p) => sum + (p.source === "needs_desktop" ? 0 : p.priceUsdCents ?? 0),
    0
  );

  const isGift = (account.gift_months ?? 0) > 0;
  const monthlyLimitUsdCents = isGift ? 0 : (account.price_monthly_cents ?? 0);
  const renewDate = isGift
    ? giftRenewDate(account.gift_months, account.gift_started_at)
    : (account.subscription_ends_at?.slice(0, 10) ?? null);

  const billingInfo = {
    mode: "subscription" as const,
    monthlySpendUsdCents,
    monthlyLimitUsdCents,
    currency: "USD",
    renewDate,
    isGift,
    paymentMethod: null as string | null,
    planName: account.plan_name,
    activeProvidersCount: connectedProviderIds.length,
    providers: billingProviders,
    subscriptionStartedAt: account.subscription_started_at ?? null,
    subscriptionEndsAt: account.subscription_ends_at ?? null,
  };

  // Presence is a durable VPS mirror of D1 connections, not a derivative of
  // the live usage snapshot. A failed mirror is intentionally non-fatal; the
  // next bootstrap retries the repair.
  await syncVpsProviderPresence(c.env, authUser.id, account.workspace_id).catch(() => false);

  // Direct clients ask for this field. The token lets them read/write the hot
  // usage path directly on the VPS for several hours, so normal API clients do
  // not receive a second long-lived bearer credential by default.
  const vpsClientToken =
    ["extension", "web", "mobile", "watch"].includes(c.req.query("client") ?? "")
      ? await issueVpsClientToken(c.env, authUser.id, account.workspace_id)
      : null;
  const vpsClientFields = vpsClientToken
    ? {
        vps_client_token: vpsClientToken.token,
        vps_client_token_expires_at: vpsClientToken.expires_at,
      }
    : {};

  if (normalizedProviderId) {
    // Legacy "provider" alanı: birden fazla bağlantı varsa ilkini (en yeni
    // oluşturulanı) döner — eski istemciler tekil obje bekliyor. Yeni
    // istemciler `usage[provider_id]` dizisinin tamamını kullanmalı.
    const provider = usage[normalizedProviderId]?.[0] ?? null;
    if (!provider) {
      const meta = await db(c.env)
        .prepare(
          `SELECT id, name, status, brand_color, default_unit, default_price_usd_cents, image_key
             FROM providers WHERE id = ?`
        )
        .bind(normalizedProviderId)
        .first<{
          id: string;
          name: string;
          status: string | null;
          brand_color: string | null;
          image_key: string | null;
        }>();

      if (!meta) {
        return c.json({ error: "provider_not_found" }, 404);
      }

      const sub = billingProviders.find((p) => p.id === normalizedProviderId);
      return c.json({
        usage,
        connected_providers: connectedProviders,
        billingInfo,
        provider: {
          id: meta.id,
          name: meta.name,
          status: meta.status || "active",
          brandColor: meta.brand_color,
          logoUrl: providerLogoPath(meta.image_key, meta.id),
          current: 0,
          total: 100,
          budget: null,
          unit: "%",
          resetTime: "—",
          averageCost: "—",
          alertThreshold: 80,
          alertThresholds: [80],
          used_percent: null,
          used: null,
          total_raw: null,
          resets_at: null,
          error: null,
          observed_at: null,
          source: null,
          updated_at: null,
          windows: [],
          subscription: sub
            ? {
                planName: sub.planName,
                priceUsdCents: sub.priceUsdCents,
                billingCycle: sub.billingCycle,
                autoRenew: sub.autoRenew,
                purchasedAt: sub.purchasedAt,
                renewsAt: sub.renewsAt,
                periodAnchorAt: sub.periodAnchorAt,
                source: sub.source,
                lastRefreshedAt: sub.lastRefreshedAt,
                refreshStatus: sub.refreshStatus,
                refreshNote: sub.refreshNote,
              }
            : null,
        },
      });
    }

    return c.json({ usage, connected_providers: connectedProviders, billingInfo, provider, ...vpsClientFields });
  }

  return c.json({ usage, connected_providers: connectedProviders, billingInfo, ...vpsClientFields });
});

user.get("/usage/activity-heatmap", async (c) => {
  const authUser = c.get("user");
  const days = Math.min(365, Math.max(7, parseInt(c.req.query("days") ?? "365", 10) || 365));
  const now = nowIso();
  const since = new Date(Date.now() - days * 86_400_000).toISOString();

  let account = await resolveWorkspaceForUser(c.env, authUser.id, c.get("workspaceId"));
  if (!account?.workspace_id) return c.json({ heatmap: {}, details: {} });

  type HeatmapHistoryRow = {
    provider_id: string;
    provider_name: string | null;
    price_usd_cents: number | null;
    plan_name: string | null;
    source: string | null;
    observed_at: string;
  };

  const { results: historyRows } = await db(c.env)
    .prepare(
      `SELECT h.provider_id, COALESCE(p.name, h.provider_id) AS provider_name,
              h.price_usd_cents, h.plan_name, h.source, h.observed_at
         FROM provider_subscription_history h
         LEFT JOIN providers p ON p.id = h.provider_id
        WHERE h.workspace_id = ?
          AND h.observed_at <= ?
          AND (
            h.observed_at >= ?
            OR h.observed_at = (
              SELECT MAX(previous.observed_at)
                FROM provider_subscription_history previous
               WHERE previous.workspace_id = h.workspace_id
                 AND previous.provider_id = h.provider_id
                 AND previous.observed_at < ?
            )
          )
        ORDER BY h.observed_at ASC`
    )
    .bind(account.workspace_id, now, since, since)
    .all<HeatmapHistoryRow>();

  const heatmap: Record<string, number> = {};
  const details: Record<
    string,
    {
      count: number;
      spend_usd_cents: number;
      providers: Array<{
        id: string;
        name: string;
        count: number;
        spend_usd_cents: number;
        plans: string[];
      }>;
    }
  > = {};

  const detailFor = (day: string) => {
    const detail = details[day] ?? { count: 0, spend_usd_cents: 0, providers: [] };
    details[day] = detail;
    return detail;
  };

  const providerFor = (
    detail: (typeof details)[string],
    providerId: string,
    providerName: string
  ) => {
    const provider = detail.providers.find((item) => item.id === providerId);
    if (provider) return provider;
    const created = { id: providerId, name: providerName, count: 0, spend_usd_cents: 0, plans: [] as string[] };
    detail.providers.push(created);
    return created;
  };

  const currentRows = (historyRows ?? []).filter((row) => row.observed_at >= since);
  for (const row of currentRows) {
    const day = row.observed_at.slice(0, 10);
    const providerId = mapPlatformToProviderId(row.provider_id);
    const detail = detailFor(day);
    const provider = providerFor(detail, providerId, row.provider_name || providerId);
    detail.count += 1;
    provider.count += 1;
    heatmap[day] = detail.count;
    if (row.plan_name && !provider.plans.includes(row.plan_name)) provider.plans.push(row.plan_name);
  }

  const { results: connectionRows } = await db(c.env)
    .prepare(
      `SELECT uc.provider, MIN(uc.created_at) AS created_at
         FROM user_connections uc
         JOIN workspace_members wm ON wm.user_id = uc.user_id
        WHERE wm.workspace_id = ? AND uc.created_at IS NOT NULL
        GROUP BY uc.provider`
    )
    .bind(account.workspace_id)
    .all<{ provider: string; created_at: string }>();

  const connectedAtByProvider = new Map<string, string>();
  for (const row of connectionRows ?? []) {
    connectedAtByProvider.set(mapPlatformToProviderId(row.provider), row.created_at);
  }

  const increments = computeSpendIncrements(
    (historyRows ?? []).map(({ provider_id, price_usd_cents, plan_name, source, observed_at }) => ({
      provider_id: mapPlatformToProviderId(provider_id),
      price_usd_cents,
      plan_name,
      source,
      observed_at,
    })),
    connectedAtByProvider
  );

  const providerNameById = new Map(
    currentRows.map((row) => [mapPlatformToProviderId(row.provider_id), row.provider_name || row.provider_id])
  );
  for (const increment of increments) {
    if (increment.observedAt < since) continue;
    const day = increment.observedAt.slice(0, 10);
    const detail = detailFor(day);
    const providerId = mapPlatformToProviderId(increment.providerId);
    const provider = providerFor(detail, providerId, providerNameById.get(providerId) || providerId);
    detail.spend_usd_cents += increment.incrementCents;
    provider.spend_usd_cents += increment.incrementCents;
  }

  return c.json({ heatmap, details });
});

user.get("/usage/spend-trend", async (c) => {
  const authUser = c.get("user");
  const email = normalizeEmail(authUser.email);
  const granularity = parseSpendTrendGranularity(c.req.query("granularity"));

  let account = await resolveWorkspaceForUser(c.env, authUser.id, c.get("workspaceId"));
  if (!account?.workspace_id) {
    return c.json({ error: "workspace_not_found" }, 404);
  }

  if (!planFeaturesForSlug(account.plan_slug).usageAnalytics) {
    return c.json(
      { error: "plan_feature_locked", message: "Bu özellik Pro planında kullanılabilir", feature: "usage_analytics" },
      403
    );
  }

  const trend = await getSpendTrend(c.env, {
    workspaceId: account.workspace_id,
    userId: authUser.id,
    userEmail: email,
    membershipStartedAt: account.subscription_started_at ?? null,
    giftStartedAt: account.gift_started_at ?? null,
    granularity,
  });

  return c.json(trend);
});

// Provider bazında kullanıcı bütçe/limit override'ı. `total` (bütçe) değeri
// user_provider_usage.budget_limit'e yazılır; scrape edilen `total`'ı ezmez
// ve okuma yolunda limit olarak öncelikli kullanılır. Silmek için total<=0 gönder.
const usageLimitSchema = z
  .object({
    email: z.string().email().optional(),
    providerId: z.string().min(1),
    total: z.number().optional(),
    alertThreshold: z.number().min(0).max(100).optional(),
    /** Up to 3 custom percent thresholds (1–100). Empty clears. */
    alertThresholds: z.array(z.number().min(1).max(100)).max(3).optional(),
    /** User-chosen display name override. Empty string clears it. */
    customNickname: z.string().max(60).optional(),
    /** User-uploaded logo URL override (from /provider-logo-upload). Empty string clears it. */
    customLogoUrl: z.string().max(500).optional(),
  })
  .refine(
    (data) =>
      data.total !== undefined ||
      data.alertThreshold !== undefined ||
      data.alertThresholds !== undefined ||
      data.customNickname !== undefined ||
      data.customLogoUrl !== undefined,
    {
      message:
        "At least one of total, alertThreshold, alertThresholds, customNickname, or customLogoUrl is required",
    }
  );

type UsageLimitBody = z.infer<typeof usageLimitSchema>;

async function handleUsageLimit(
  c: Context<{ Bindings: Env; Variables: AppVariables }>,
  body: UsageLimitBody
) {
  const authUser = c.get("user");
  if (body.email && normalizeEmail(body.email) !== authUser.email) {
    return c.json({ error: "Forbidden" }, 403);
  }

  const workspaceId = c.get("workspaceId");
  if (!workspaceId) {
    return c.json({ error: "workspace_not_found" }, 404);
  }

  const providerId = mapPlatformToProviderId(body.providerId);
  const result = await patchProviderUsageLimits(
    c.env,
    authUser.id,
    providerId,
    {
      total: body.total,
      alertThreshold: body.alertThreshold,
      alertThresholds: body.alertThresholds,
      customNickname: body.customNickname,
      customLogoUrl: body.customLogoUrl,
    },
    {
      actorUserId: authUser.id,
      actorEmail: authUser.email,
      ip: clientIpFromRequest(c.req),
      userAgent: c.req.header("User-Agent") ?? null,
    },
    workspaceId
  );

  return c.json({ ok: true, ...result });
}

user.patch(
  "/usage/limit",
  requireAccountRole(["owner", "admin"]),
  zValidator("json", usageLimitSchema),
  async (c) => handleUsageLimit(c, c.req.valid("json"))
);

user.post(
  "/usage/limit",
  requireAccountRole(["owner", "admin"]),
  zValidator("json", usageLimitSchema),
  async (c) => {
    const res = await handleUsageLimit(c, c.req.valid("json"));
    if (res instanceof Response) {
      res.headers.set("Deprecation", "true");
    }
    return res;
  }
);

const subscriptionPatchSchema = z
  .object({
    email: z.string().email().optional(),
    providerId: z.string().min(1),
    planName: z.string().max(80).optional(),
    /** null clears manual override → catalog list price applies. */
    priceUsdCents: z.number().min(0).nullable().optional(),
    billingCycle: z.enum(["monthly", "yearly"]).optional(),
    /** Manual renewal ISO; null clears (budget falls back to connection created_at). */
    renewsAt: z.string().min(1).nullable().optional(),
  })
  .refine(
    (data) =>
      data.planName !== undefined ||
      data.priceUsdCents !== undefined ||
      data.billingCycle !== undefined ||
      data.renewsAt !== undefined,
    { message: "At least one of planName, priceUsdCents, billingCycle, or renewsAt is required" }
  );

user.patch(
  "/subscription",
  requireAccountRole(["owner", "admin"]),
  zValidator("json", subscriptionPatchSchema),
  async (c) => {
    const body = c.req.valid("json");
    const authUser = c.get("user");
    if (body.email && normalizeEmail(body.email) !== authUser.email) {
      return c.json({ error: "Forbidden" }, 403);
    }

    const workspaceId = c.get("workspaceId");
    if (!workspaceId) {
      return c.json({ error: "workspace_not_found" }, 404);
    }

    const providerId = mapPlatformToProviderId(body.providerId);
    const result = await patchProviderSubscription(
      c.env,
      authUser.id,
      providerId,
      {
        planName: body.planName,
        priceUsdCents: body.priceUsdCents,
        billingCycle: body.billingCycle,
        renewsAt: body.renewsAt,
      },
      {
        actorUserId: authUser.id,
        actorEmail: authUser.email,
        ip: clientIpFromRequest(c.req),
        userAgent: c.req.header("User-Agent") ?? null,
      },
      workspaceId
    );

    return c.json({ ok: true, subscription: result });
  }
);

// Workspace listesi. Aktif workspace X-Workspace-Id header'ından
// (yoksa varsayılan üyelikten) çözülür; server-side persist edilmez.
type UserCtx = Context<{ Bindings: Env; Variables: AppVariables }>;

const listWorkspacesHandler = async (c: UserCtx) => {
  const authUser = c.get("user");
  const email = c.req.query("email");
  if (email && normalizeEmail(email) !== authUser.email) {
    return c.json({ error: "Forbidden" }, 403);
  }

  const memberships = await listMemberships(c.env, authUser.id);
  const active = await resolveWorkspaceForUser(c.env, authUser.id, c.get("workspaceId"));

  const workspaces = memberships.map((m: Record<string, unknown>) => ({
    workspace_id: m.workspace_id,
    workspace_name: m.workspace_name,
    role: m.role,
    plan_slug: m.plan_slug,
    plan_name: m.plan_name,
  }));

  return c.json({
    workspaces,
    accounts: workspaces, // legacy
    active_workspace_id: active?.workspace_id ?? null,
  });
};

user.get("/workspaces", listWorkspacesHandler);
user.get("/accounts", listWorkspacesHandler);

const switchWorkspaceBody = z.object({
  email: z.string().email().optional(),
  workspace_id: z.string().min(1).optional(),
  account_id: z.string().min(1).optional(),
});

const switchWorkspaceHandler = async (c: UserCtx) => {
  const body = await c.req.json().catch(() => ({})) as z.infer<typeof switchWorkspaceBody>;
  const parsed = switchWorkspaceBody.safeParse(body);
  if (!parsed.success) return c.json({ error: "invalid_body" }, 400);
  const authUser = c.get("user");
  if (parsed.data.email && normalizeEmail(parsed.data.email) !== authUser.email) {
    return c.json({ error: "Forbidden" }, 403);
  }

  const workspaceId = parsed.data.workspace_id || parsed.data.account_id;
  if (!workspaceId) return c.json({ error: "workspace_id required" }, 400);

  const member = await db(c.env)
    .prepare("SELECT 1 FROM workspace_members WHERE workspace_id = ? AND user_id = ?")
    .bind(workspaceId, authUser.id)
    .first();
  if (!member) return c.json({ error: "not_a_member" }, 403);

  const profile = await buildUserProfile(c.env, authUser.id, workspaceId);
  if (!profile) return c.json({ error: "Not found" }, 404);
  return c.json({ ok: true, user: profile, active_workspace_id: workspaceId });
};

user.post("/workspaces/switch", switchWorkspaceHandler);
user.post("/accounts/switch", switchWorkspaceHandler);

function clientIp(c: { req: { header: (name: string) => string | undefined } }): string {
  return (
    c.req.header("cf-connecting-ip") ||
    c.req.header("x-forwarded-for")?.split(",")[0]?.trim() ||
    ""
  );
}

function clientGeo(c: { req: { header: (name: string) => string | undefined } }): { country: string; city: string } {
  const cityRaw = c.req.header("cf-ipcity") || "";
  let city = "";
  try {
    city = decodeURIComponent(cityRaw);
  } catch {
    city = cityRaw;
  }
  return { country: c.req.header("cf-ipcountry") || "", city };
}

function deviceFieldsFromRegisterBody(
  body: Record<string, unknown>,
  ua: string
): { deviceName: string; os: string; browser: string; platform: string; appVersion: string } {
  const platform =
    typeof body.platform === "string" && body.platform.trim()
      ? body.platform.trim().slice(0, 32)
      : "web";
  const isWeb = platform === "web";
  const deviceName =
    typeof body.device_name === "string" && body.device_name.trim()
      ? body.device_name.trim().slice(0, 80)
      : ua.slice(0, 80) || "Unknown Device";
  const os =
    typeof body.os === "string" && body.os.trim()
      ? body.os.trim().slice(0, 80)
      : isWeb
        ? "Web"
        : "Unknown OS";
  const browser =
    typeof body.browser === "string"
      ? body.browser.slice(0, 40)
      : isWeb
        ? ua.slice(0, 40)
        : "";
  const appVersion =
    typeof body.app_version === "string" ? body.app_version.slice(0, 32) : "";
  return { deviceName, os, browser, platform, appVersion };
}

async function resolveDeviceFingerprint(
  c: { req: { header: (name: string) => string | undefined } },
  body?: Record<string, unknown>
): Promise<string | null> {
  const fromHeader = c.req.header("X-Device-Fingerprint")?.trim();
  if (fromHeader) return fromHeader;
  const fromBody = body?.device_fingerprint;
  if (typeof fromBody === "string" && fromBody.trim()) return fromBody.trim();
  return null;
}

user.post("/sessions/register", zValidator("json", z.object({
  email: z.string().email(),
  device_fingerprint: z.string().optional(),
  platform: z.string().optional(),
}).passthrough()), async (c) => {
  const body = c.req.valid("json") as Record<string, unknown> & {
    email: string;
    device_fingerprint?: string;
    platform?: string;
  };
  const authUser = c.get("user");
  if (normalizeEmail(body.email) !== authUser.email) return c.json({ error: "Forbidden" }, 403);

  const ua = c.req.header("User-Agent") || "Unknown";
  const fp = (await resolveDeviceFingerprint(c, body)) || uuid();
  const { deviceName, os, browser, platform, appVersion } = deviceFieldsFromRegisterBody(body, ua);
  const ip = clientIp(c);
  const { country, city } = clientGeo(c);

  const id = uuid();
  await db(c.env)
    .prepare(
      `INSERT INTO user_devices (id, user_id, device_name, os, browser, ip, last_active, current_session, device_fingerprint, platform, app_version, country, city, created_at)
       VALUES (?, ?, ?, ?, ?, ?, NOW(), 1, ?, ?, ?, ?, ?, NOW())
       ON CONFLICT(user_id, device_fingerprint) WHERE device_fingerprint IS NOT NULL DO UPDATE SET
         last_active = NOW(),
         current_session = 1,
         device_name = excluded.device_name,
         os = excluded.os,
         browser = excluded.browser,
         ip = excluded.ip,
         platform = excluded.platform,
         app_version = excluded.app_version,
         country = excluded.country,
         city = excluded.city`
    )
    .bind(id, authUser.id, deviceName, os, browser, ip, fp, platform, appVersion, country, city)
    .run();

  c.executionCtx.waitUntil(
    setVpsDeviceRevoked(c.env, {
      userId: authUser.id,
      deviceFingerprint: fp,
      revoked: false,
    })
  );

  const row = await db(c.env)
    .prepare("SELECT id FROM user_devices WHERE user_id = ? AND device_fingerprint = ?")
    .bind(authUser.id, fp)
    .first<{ id: string }>();
  return c.json({ id: row?.id ?? id });
});

user.post("/sessions/heartbeat", async (c) => {
  const authUser = c.get("user");
  let body: Record<string, unknown> = {};
  try {
    body = await c.req.json<Record<string, unknown>>();
  } catch {
    body = {};
  }
  const fp = (await resolveDeviceFingerprint(c, body)) || null;
  const ip = clientIp(c);
  const { country, city } = clientGeo(c);

  if (fp) {
    const row = await db(c.env)
      .prepare("SELECT id, current_session FROM user_devices WHERE user_id = ? AND device_fingerprint = ?")
    .bind(authUser.id, fp)
      .first<{ id: string; current_session: number }>();
    if (row && row.current_session === 0) {
      return c.json({ force_logout: true }, 401);
    }
    if (row) {
      const account = await resolveWorkspaceForUserCached(c.env, authUser.id, c.get("workspaceId"));
      if (account?.workspace_id) {
        const vpsHeartbeat = await heartbeatVpsDevice(c.env, {
          userId: authUser.id,
          workspaceId: account.workspace_id,
          deviceFingerprint: fp,
        });
        if (vpsHeartbeat === "force_logout") {
          return c.json({ force_logout: true }, 401);
        }
        if (vpsHeartbeat === "ok") {
          return c.json({ ok: true, source: "vps" });
        }
      }
      await db(c.env)
        .prepare(
          `UPDATE user_devices
              SET last_active = NOW(), ip = ?, country = ?, city = ?
            WHERE id = ?
              AND (last_active IS NULL OR last_active < datetime('now', '-600 seconds'))`
        )
        .bind(ip, country, city, row.id)
        .run();
    } else {
      const ua = c.req.header("User-Agent") || "Unknown";
      const { deviceName, os, browser, platform, appVersion } = deviceFieldsFromRegisterBody(body, ua);
      const id = uuid();
      await db(c.env)
        .prepare(
          `INSERT INTO user_devices (id, user_id, device_name, os, browser, ip, last_active, current_session, device_fingerprint, platform, app_version, country, city, created_at)
           VALUES (?, ?, ?, ?, ?, ?, NOW(), 1, ?, ?, ?, ?, ?, NOW())
           ON CONFLICT(user_id, device_fingerprint) WHERE device_fingerprint IS NOT NULL DO UPDATE SET
             last_active = NOW(), ip = excluded.ip, country = excluded.country, city = excluded.city`
        )
        .bind(id, authUser.id, deviceName, os, browser, ip, fp, platform, appVersion, country, city)
        .run();
    }
  }
  return c.json({ ok: true });
});

user.post("/sessions/terminate", zValidator("json", z.object({
  email: z.string().email(),
  device_id: z.string(),
})), async (c) => {
  const { email, device_id } = c.req.valid("json");
  if (normalizeEmail(email) !== c.get("user").email) return c.json({ error: "Forbidden" }, 403);
  const authUser = c.get("user");
  const device = await db(c.env)
    .prepare("SELECT device_fingerprint FROM user_devices WHERE id = ? AND user_id = ?")
    .bind(device_id, authUser.id)
    .first<{ device_fingerprint: string | null }>();
  await db(c.env)
    .prepare("UPDATE user_devices SET current_session = 0 WHERE id = ? AND user_id = ?")
    .bind(device_id, authUser.id)
    .run();
  if (device?.device_fingerprint) {
    c.executionCtx.waitUntil(
      setVpsDeviceRevoked(c.env, {
        userId: authUser.id,
        deviceFingerprint: device.device_fingerprint,
        revoked: true,
      })
    );
  }
  await recordAudit(c.env, {
    workspaceId: c.get("workspaceId"),
    actorUserId: authUser.id,
    actorEmail: authUser.email,
    action: "device.terminate",
    entityType: "device",
    entityId: device_id,
    ip: clientIpFromRequest(c.req),
    userAgent: c.req.header("User-Agent") ?? null,
  });
  return c.json({ ok: true });
});

user.get("/telegram", async (c) => {
  const status = await getTelegramConnectionStatus(c.env, c.get("user").id);
  return c.json(status);
});

user.post("/telegram/connect", rateLimit({ limit: 5, windowSeconds: 60, keyPrefix: "user:telegram-connect" }), zValidator("json", z.object({
  bot_token: z.string().trim().min(1).max(512),
})), async (c) => {
  const { bot_token } = c.req.valid("json");
  const result = await connectUserTelegramBot(
    c.env,
    c.get("user").id,
    bot_token,
    c.req.url
  );
  if (!result.ok) {
    return c.json({ error: "error" in result ? result.error : "Unknown error" }, 400);
  }
  return c.json(result.status);
});

user.post("/telegram/disconnect", async (c) => {
  await disconnectUserTelegram(c.env, c.get("user").id);
  return c.json({ ok: true });
});

// Kullanıcıya özel provider görüntüleme sırası — tüm istemciler (web,
// masaüstü eklentisi, mobil, watch) bu tek kaynaktan okur/yazar.
user.get("/provider-order", async (c) => {
  const row = await db(c.env)
    .prepare("SELECT order_json, updated_at FROM user_provider_order WHERE user_id = ?")
    .bind(c.get("user").id)
    .first<{ order_json: string; updated_at: string }>();
  let order: string[] = [];
  if (row?.order_json) {
    try {
      const parsed = JSON.parse(row.order_json);
      if (Array.isArray(parsed)) order = parsed.filter((v): v is string => typeof v === "string");
    } catch {
      /* bozuk kayıt — boş sıra döndür */
    }
  }
  return c.json({ order, updated_at: row?.updated_at ?? null });
});

user.put(
  "/provider-order",
  zValidator(
    "json",
    z.object({
      order: z.array(z.string().min(1).max(64)).max(200),
    })
  ),
  async (c) => {
    const authUser = c.get("user");
    const order = Array.from(new Set(c.req.valid("json").order));
    const updatedAt = nowIso();
    await db(c.env)
      .prepare(
        `INSERT INTO user_provider_order (user_id, order_json, updated_at)
         VALUES (?, ?, ?)
         ON CONFLICT(user_id) DO UPDATE SET
           order_json = excluded.order_json,
           updated_at = excluded.updated_at`
      )
      .bind(authUser.id, JSON.stringify(order), updatedAt)
      .run();
    return c.json({ ok: true, order, updated_at: updatedAt });
  }
);

user.get("/notifications/poll", async (c) => {
  const authUser = c.get("user");
  // `cursor` is the name used by released extensions; `since` is the clearer
  // API name. Accept both so old clients do not restart from the epoch.
  const since =
    c.req.query("since")?.trim() ||
    c.req.query("cursor")?.trim() ||
    "1970-01-01T00:00:00.000Z";
  const limitRaw = Number.parseInt(c.req.query("limit") || "5", 10);
  const limit = Number.isFinite(limitRaw) ? Math.min(Math.max(limitRaw, 1), 50) : 5;

  const account = await resolveWorkspaceForUserCached(c.env, authUser.id, c.get("workspaceId"));
  if (!account?.workspace_id) {
    return c.json({ cursor: since, items: [] });
  }

  const result = await pollUserNotificationEvents(
    c.env,
    authUser.id,
    account.workspace_id,
    since,
    limit
  );
  return c.json(result);
});

user.post(
  "/notifications/ack",
  zValidator("json", z.object({ ids: z.array(z.string().min(1)).min(1).max(50) })),
  async (c) => {
    const { ids } = c.req.valid("json");
    await ackUserNotificationEvents(c.env, c.get("user").id, ids);
    return c.json({ ok: true });
  }
);

user.post(
  "/notifications/cli",
  zValidator("json", z.object({
    title: z.string().min(1).max(200),
    body: z.string().min(1).max(1000),
    provider_id: z.string().max(64).optional(),
    payload: z.record(z.unknown()).optional(),
  })),
  async (c) => {
    const authUser = c.get("user");
    const { title, body, provider_id, payload } = c.req.valid("json");

    const account = await resolveWorkspaceForUser(c.env, authUser.id, c.get("workspaceId"));
    if (!account?.workspace_id) {
      return c.json({ error: "No account" }, 400);
    }

    await insertUserNotificationEvent(c.env, {
      userId: authUser.id,
      workspaceId: account.workspace_id,
      typeId: "cli_tool",
      body,
      providerId: provider_id ?? null,
      payload: payload ?? null,
    });

    const { fetchUserFcmTokens } = await import("../../lib/notify");
    const { sendFcmToUserTokens } = await import("../../lib/fcm");
    const fcmTokens = await fetchUserFcmTokens(c.env, authUser.id);
    if (fcmTokens.length > 0) {
      c.executionCtx.waitUntil(
        sendFcmToUserTokens(c.env, authUser.id, fcmTokens, {
          title,
          body,
          data: { type: "cli_tool", provider_id: provider_id ?? "" },
        })
      );
    }

    return c.json({ ok: true });
  }
);

user.post(
  "/device-token",
  zValidator(
    "json",
    z.object({
      email: z.string().email(),
      token: z.string().min(1).max(512),
      platform: z.enum(["ios", "android", "web", "desktop", "watch"]),
      // watchOS has no Firebase Messaging SDK — it sends its raw APNs device token instead.
      raw_apns: z.boolean().optional(),
    })
  ),
  async (c) => {
    const body = c.req.valid("json");
    const authUser = c.get("user");
    if (normalizeEmail(body.email) !== authUser.email) {
      return c.json({ error: "Forbidden" }, 403);
    }

    let token = body.token;
    if (body.platform === "watch" && body.raw_apns) {
      const bundleId = c.env.WATCH_APNS_BUNDLE_ID || "com.dots.aiwatcher.watchapp";
      const sandbox = c.env.WATCH_APNS_SANDBOX === "1";
      const fcmToken = await importApnsTokenToFcm(c.env, body.token, bundleId, sandbox);
      if (!fcmToken) {
        return c.json({ error: "APNs token exchange failed" }, 502);
      }
      token = fcmToken;
    }

    const existing = await db(c.env)
      .prepare("SELECT id FROM user_fcm_tokens WHERE user_id = ? AND token = ?")
      .bind(authUser.id, token)
      .first<{ id: string }>();

    if (existing) {
      await db(c.env)
        .prepare("UPDATE user_fcm_tokens SET platform = ?, updated_at = NOW() WHERE id = ?")
        .bind(body.platform, existing.id)
        .run();
      return c.json({ ok: true, updated: true });
    }

    const id = uuid();
    await db(c.env)
      .prepare(
        `INSERT INTO user_fcm_tokens (id, user_id, token, platform, updated_at, created_at)
         VALUES (?, ?, ?, ?, NOW(), NOW())`
      )
      .bind(id, authUser.id, token, body.platform)
      .run();
    return c.json({ ok: true, created: true });
  }
);

user.delete(
  "/device-token",
  zValidator("json", z.object({ token: z.string().min(1).max(512) })),
  async (c) => {
    const { token } = c.req.valid("json");
    const authUser = c.get("user");
    await db(c.env)
      .prepare("DELETE FROM user_fcm_tokens WHERE user_id = ? AND token = ?")
      .bind(authUser.id, token)
      .run();
    return c.json({ ok: true });
  },
);

const changeEmailSchema = z.object({
  current_password: z.string().min(1),
  new_email: z.string().email(),
});

user.post("/change-email", zValidator("json", changeEmailSchema), async (c) => {
  const authUser = c.get("user");
  const { current_password, new_email } = c.req.valid("json");
  const normalizedNewEmail = normalizeEmail(new_email);
  const normalizedOldEmail = normalizeEmail(authUser.email);

  if (normalizedNewEmail === normalizedOldEmail) {
    return c.json({ error: "Yeni e-posta adresi eski e-posta adresi ile aynı olamaz" }, 400);
  }

  // 1) Verify password
  const row = await db(c.env)
    .prepare("SELECT password_hash FROM users WHERE id = ?")
    .bind(authUser.id)
    .first<{ password_hash: string }>();

  if (!row || !(await verifyPassword(current_password, row.password_hash))) {
    return c.json({ error: "Mevcut şifre hatalı" }, 400);
  }

  // 2) Check if new email is already in use
  const existingUser = await db(c.env)
    .prepare("SELECT id FROM users WHERE email = ?")
    .bind(normalizedNewEmail)
    .first<{ id: string }>();

  if (existingUser) {
    return c.json({ error: "Bu e-posta adresi zaten kullanımda" }, 400);
  }

  // 3) Update email in DB
  await db(c.env)
    .prepare("UPDATE users SET email = ?, updated_at = NOW() WHERE id = ?")
    .bind(normalizedNewEmail, authUser.id)
    .run();

  // 4) Record Audit Log
  await recordAudit(c.env, {
    workspaceId: c.get("workspaceId"),
    actorUserId: authUser.id,
    actorEmail: normalizedOldEmail,
    action: "user.email_change",
    entityType: "user",
    entityId: authUser.id,
    ip: clientIpFromRequest(c.req),
    userAgent: c.req.header("User-Agent") ?? null,
  });

  // 5) Invalidate every existing session, then issue fresh cookies for the new
  //    email claim (matches /set-password and /reset-password).
  await revokeAllRefreshTokens(c.env, authUser.id);
  await issueTokensWithCookies(c, authUser.id, normalizedNewEmail, authUser.role || "user");

  // 6) Send notification email to the old email address
  try {
    const emailResult = await sendEmailChangeNotificationEmail(c.env, normalizedOldEmail, normalizedNewEmail);
    console.log("Email change notification sent successfully:", {
      messageId: emailResult.messageId,
      oldDomain: normalizedOldEmail.split("@")[1] || "unknown",
      newDomain: normalizedNewEmail.split("@")[1] || "unknown",
    });
  } catch (err) {
    console.error("Error sending email change notification:", err);
  }

  return c.json({ ok: true, email: normalizedNewEmail });
});

// Data portability endpoint. Secrets and raw provider credentials are never
// included; the response contains the account data needed for an access copy.
user.get("/data-export", async (c) => {
  const authUser = c.get("user");
  const [profile, connections, consents, legalDataRequests, subscriptionCancellationRequests, orders, memberships, devices, notificationPreferences, fcmTokens, usageSnapshot, providerUsage, providerSubscriptions, providerSubscriptionHistory, notificationEvents, auditEvents, providerOrder, purchases] = await Promise.all([
    db(c.env)
      .prepare("SELECT id, email, name, surname, username, role, created_at, updated_at FROM users WHERE id = ?")
      .bind(authUser.id)
      .first(),
    db(c.env)
      .prepare(
        `SELECT provider, name, key_masked, connection_type, created_at
           FROM user_connections
          WHERE user_id = ?
          ORDER BY created_at ASC`,
      )
      .bind(authUser.id)
      .all(),
    db(c.env)
      .prepare(
        `SELECT purpose, action, document_key, document_version, locale, source, ip, user_agent, created_at
           FROM legal_consent_events
          WHERE user_id = ?
          ORDER BY created_at ASC`,
      )
      .bind(authUser.id)
      .all(),
    db(c.env)
      .prepare(
        `SELECT id, request_type, details, locale, status, identity_status,
                received_at, due_at, responded_at, response_channel,
                response_summary, created_at, updated_at
           FROM legal_data_requests
          WHERE user_id = ?
          ORDER BY received_at ASC`,
      )
      .bind(authUser.id)
      .all(),
    db(c.env)
      .prepare(
        `SELECT id, workspace_id, requester_email, plan_slug, requested_effect,
                refund_requested, details, locale, service_period_ends_at,
                status, received_at, processing_due_at, refund_due_at,
                processed_at, response_channel, response_summary,
                created_at, updated_at
           FROM subscription_cancellation_requests
          WHERE user_id = ?
          ORDER BY received_at ASC`,
      )
      .bind(authUser.id)
      .all(),
    db(c.env)
      .prepare(
        `SELECT merchant_oid, plan_slug, amount_minor, currency, status, kind,
                customer_name, customer_phone, customer_address,
                terms_version, precontract_version, distance_sales_version,
                refund_version, subscription_version, immediate_performance_requested,
                accepted_locale, entitlement_available_at, entitlement_status,
                entitlement_activated_at, confirmation_email_status,
                confirmation_email_attempts, confirmation_email_sent_at,
                created_at, completed_at
           FROM billing_orders
          WHERE user_id = ? OR customer_email = ?
          ORDER BY created_at ASC`,
      )
      .bind(authUser.id, authUser.email)
      .all(),
    db(c.env)
      .prepare(
        `SELECT wm.workspace_id, w.name AS workspace_name, wm.role, wm.created_at, wm.joined_at, wm.note
           FROM workspace_members wm
           JOIN workspaces w ON w.id = wm.workspace_id
          WHERE wm.user_id = ?
          ORDER BY wm.created_at ASC`,
      )
      .bind(authUser.id)
      .all(),
    db(c.env)
      .prepare(
        `SELECT id, device_name, os, browser, ip, last_active, current_session,
                device_fingerprint, platform, app_version, country, city, created_at
           FROM user_devices
          WHERE user_id = ?
          ORDER BY created_at ASC`,
      )
      .bind(authUser.id)
      .all<{ id: string; device_name: string; os: string; browser: string; ip: string | null; last_active: string; current_session: number; device_fingerprint: string | null; platform: string; app_version: string; country: string; city: string; created_at: string | null }>(),
    db(c.env)
      .prepare(
        `SELECT telegram_bot_token, telegram_chat_id, telegram_webhook_secret, updated_at
           FROM notification_preferences
          WHERE user_id = ?`,
      )
      .bind(authUser.id)
      .first<{ telegram_bot_token: string | null; telegram_chat_id: string | null; telegram_webhook_secret: string | null; updated_at: string }>(),
    db(c.env)
      .prepare(
        `SELECT id, token, platform, updated_at, created_at
           FROM user_fcm_tokens
          WHERE user_id = ?
          ORDER BY created_at ASC`,
      )
      .bind(authUser.id)
      .all<{ id: string; token: string; platform: string; updated_at: string; created_at: string }>(),
    db(c.env)
      .prepare(
        `SELECT snapshot_json, updated_at, observed_at, source
           FROM user_usage_snapshots
          WHERE user_id = ?`,
      )
      .bind(authUser.id)
      .first(),
    db(c.env)
      .prepare(
        `SELECT provider_id, used_percent, used, total, budget_limit,
                alert_threshold, alert_thresholds, resets_at, error, updated_at,
                observed_at, source
           FROM user_provider_usage
          WHERE user_id = ?
          ORDER BY provider_id ASC`,
      )
      .bind(authUser.id)
      .all(),
    db(c.env)
      .prepare(
        `SELECT ps.workspace_id, ps.provider_id, ps.plan_name, ps.price_usd_cents,
                ps.billing_cycle, ps.auto_renew, ps.purchased_at, ps.renews_at,
                ps.source, ps.source_updated_at, ps.last_refreshed_at,
                ps.refresh_status, ps.refresh_note
           FROM provider_subscriptions ps
           JOIN workspace_members wm ON wm.workspace_id = ps.workspace_id
          WHERE wm.user_id = ?
          ORDER BY ps.purchased_at ASC`,
      )
      .bind(authUser.id)
      .all(),
    db(c.env)
      .prepare(
        `SELECT id, workspace_id, user_id, provider_id, price_usd_cents,
                billing_cycle, plan_name, source, observed_at
           FROM provider_subscription_history
          WHERE user_id = ?
             OR workspace_id IN (
                  SELECT workspace_id FROM workspace_members WHERE user_id = ?
                )
          ORDER BY observed_at ASC`,
      )
      .bind(authUser.id, authUser.id)
      .all(),
    db(c.env)
      .prepare(
        `SELECT id, workspace_id, type, title, body, provider_id, payload,
                created_at, delivered_at
           FROM user_notification_events
          WHERE user_id = ?
          ORDER BY created_at ASC`,
      )
      .bind(authUser.id)
      .all(),
    db(c.env)
      .prepare(
        `SELECT id, workspace_id, actor_email, action, entity_type, entity_id,
                metadata_json, ip, user_agent, created_at
           FROM audit_events
          WHERE actor_user_id = ?
          ORDER BY created_at ASC`,
      )
      .bind(authUser.id)
      .all(),
    db(c.env)
      .prepare(
        `SELECT order_json, updated_at
           FROM user_provider_order
          WHERE user_id = ?`,
      )
      .bind(authUser.id)
      .first(),
    db(c.env)
      .prepare(
        `SELECT id, workspace_id, billing_order_id, kind, plan_slug, quantity,
                amount_minor, currency, status, merchant_oid, metadata_json,
                created_at, completed_at
           FROM purchases
          WHERE user_id = ?
          ORDER BY created_at ASC`,
      )
      .bind(authUser.id)
      .all(),
  ]);

  await recordAudit(c.env, {
    actorUserId: authUser.id,
    actorEmail: authUser.email,
    action: "legal.data_request",
    entityType: "user",
    entityId: authUser.id,
    metadata: { type: "access_export" },
    ip: clientIpFromRequest(c.req),
    userAgent: c.req.header("User-Agent") ?? null,
  });

  return c.json({
    generated_at: nowIso(),
    profile,
    connections: connections.results || [],
    legal_consents: consents.results || [],
    legal_data_requests: legalDataRequests.results || [],
    subscription_cancellation_requests: subscriptionCancellationRequests.results || [],
    billing_orders: orders.results || [],
    memberships: memberships.results || [],
    devices: (devices.results || []).map((row) => ({
      ...row,
      device_fingerprint: maskExportSecret(row.device_fingerprint),
    })),
    notification_preferences: notificationPreferences
      ? {
          telegram_bot_token: maskExportSecret(notificationPreferences.telegram_bot_token),
          telegram_chat_id: notificationPreferences.telegram_chat_id,
          telegram_webhook_secret: maskExportSecret(notificationPreferences.telegram_webhook_secret),
          updated_at: notificationPreferences.updated_at,
        }
      : null,
    fcm_tokens: (fcmTokens.results || []).map((row) => ({
      ...row,
      token: maskExportSecret(row.token),
    })),
    usage_snapshot: usageSnapshot,
    provider_usage: providerUsage.results || [],
    provider_subscriptions: providerSubscriptions.results || [],
    provider_subscription_history: providerSubscriptionHistory.results || [],
    notification_events: notificationEvents.results || [],
    audit_events: auditEvents.results || [],
    provider_order: providerOrder,
    purchases: purchases.results || [],
  });
});

// Apple 5.1.1(v) / Play Store account-deletion requirement: irreversible,
// wipes the user row + everything owned by it. Most user_id-scoped tables
// cascade via FK (ON DELETE CASCADE); workspaces don't reference a user
// directly so sole-owned workspaces are torn down explicitly first, and the
// handful of tables with a non-cascading FK to users/workspaces get nulled
// out to avoid FK errors (mirrors deleteOverdueWorkspaces in subscription_cleanup.ts).
user.delete("/delete-account", async (c) => {
  const authUser = c.get("user");

  const [{ results: memberships }, { results: devices }] = await Promise.all([
    db(c.env)
      .prepare("SELECT workspace_id FROM workspace_members WHERE user_id = ?")
      .bind(authUser.id)
      .all<{ workspace_id: string }>(),
    db(c.env)
      .prepare("SELECT device_fingerprint FROM user_devices WHERE user_id = ? AND device_fingerprint IS NOT NULL")
      .bind(authUser.id)
      .all<{ device_fingerprint: string }>(),
  ]);

  // Disconnect the external Telegram webhook before deleting the local token;
  // otherwise Telegram could continue posting updates to a deleted account.
  await disconnectUserTelegram(c.env, authUser.id);

  // Clear the live self-hosted state before the D1 row disappears. Historical
  // VPS rollups are intentionally not silently claimed as erased: the current
  // VPS API has no historical deletion/export endpoint and remains an explicit
  // operator/provider retention task.
  await purgeVpsUserCurrentState(c.env, {
    userId: authUser.id,
    workspaceIds: (memberships ?? []).map((membership) => membership.workspace_id),
    deviceFingerprints: (devices ?? []).map((device) => device.device_fingerprint),
  });

  for (const m of memberships ?? []) {
    const memberCount = await db(c.env)
      .prepare("SELECT COUNT(*) AS c FROM workspace_members WHERE workspace_id = ?")
      .bind(m.workspace_id)
      .first<{ c: number }>();
    if ((memberCount?.c ?? 0) > 1) continue; // other members remain — leave workspace intact

    await db(c.env).prepare("DELETE FROM purchases WHERE workspace_id = ?").bind(m.workspace_id).run();
    // This historical table predates the current FK graph, so deleting the
    // workspace does not cascade into it. It contains provider-plan history,
    // not a statutory payment ledger, and must leave with a sole-owned
    // workspace rather than surviving account deletion indefinitely.
    await db(c.env).prepare("DELETE FROM provider_subscription_history WHERE workspace_id = ?").bind(m.workspace_id).run();
    await db(c.env).prepare("UPDATE billing_orders SET workspace_id = NULL WHERE workspace_id = ?").bind(m.workspace_id).run();
    await db(c.env).prepare("DELETE FROM workspaces WHERE id = ?").bind(m.workspace_id).run();
  }

  await db(c.env).prepare("UPDATE billing_orders SET user_id = NULL WHERE user_id = ?").bind(authUser.id).run();
  // A shared workspace may remain for its other members. Remove only this
  // user's denormalized historical rows in that case.
  await db(c.env).prepare("DELETE FROM provider_subscription_history WHERE user_id = ?").bind(authUser.id).run();
  await db(c.env).prepare("UPDATE team_invites SET invited_by = NULL WHERE invited_by = ?").bind(authUser.id).run();
  await db(c.env).prepare("DELETE FROM user_notification_events WHERE user_id = ?").bind(authUser.id).run();

  await recordAudit(c.env, {
    actorUserId: authUser.id,
    actorEmail: authUser.email,
    action: "user.delete_account",
    entityType: "user",
    entityId: authUser.id,
    ip: clientIpFromRequest(c.req),
    userAgent: c.req.header("User-Agent") ?? null,
  });

  // Everything else (refresh_tokens, user_devices, user_connections,
  // user_provider_usage, provider_usage_windows, provider_subscriptions,
  // alert_states, user_fcm_tokens, notification_preferences,
  // user_provider_order, user_usage_snapshots, remaining workspace_members)
  // is ON DELETE CASCADE on users.id.
  await db(c.env).prepare("DELETE FROM users WHERE id = ?").bind(authUser.id).run();

  return c.json({ ok: true });
});

export default user;

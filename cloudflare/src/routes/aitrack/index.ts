import { Hono } from "hono";
import { zValidator } from "@hono/zod-validator";
import { z } from "zod";
import type { Env, AppVariables } from "../../env";
import { db } from "../../db/client";
import { getUsdTryRate, isUsablePaymentRate } from "../../lib/tcmb";
import {
  calculateProration,
  clientIp,
  completeOrder,
  createOrder,
  createPaytrToken,
  genMerchantOid,
  getOrder,
  paytrIsConfigured,
  paytrLegalSalesEnabled,
  timingSafeEqual,
} from "../../lib/paytr";
import { fulfillDuePaidOrder, applyPlanToWorkspace } from "../../lib/billing_fulfill";
import { attemptPaidOrderConfirmation } from "../../lib/payment_confirmation";
import { rateLimit } from "../../middleware/rate-limit";
import {
  getUserByEmail,
  allConnectionsForUser,
  connectionLookupForUsage,
  mapPlatformToProviderId,
  resolveWorkspaceForUser,
  upsertProviderUsageBatch,
  usageWindowSchema,
} from "../../lib/users";
import { requireAuth } from "../../middleware/auth";
import {
  effectiveUsedPercent,
  scheduleUsageThresholdAlerts,
} from "../../lib/notify";
import {
  planFeaturesForSlug,
  listPlanDefs,
  planDefForSlug,
  isListedPlanSlug,
} from "../../lib/plan_features";
import {
  LegalAcceptanceRequiredError,
  recordLegalConsents,
  validatePlanChangeLegalAcceptance,
  validatePaymentLegalAcceptance,
} from "../../lib/legal";

const aitrack = new Hono<{ Bindings: Env; Variables: AppVariables }>();

aitrack.get("/plans", async (c) => {
  const rates = await getUsdTryRate(c.env);
  const usdTry = rates?.usd_try || null;

  // Response key kept as token_plans for mobile/desktop clients.
  const token_plans = listPlanDefs().map((row) => {
    const usdMonthly = row.price_monthly_cents;
    const usdYearly = row.price_yearly_cents;
    const tlMonthly = usdTry ? Math.round(usdMonthly * usdTry) : null;
    const tlYearly = usdTry ? Math.round(usdYearly * usdTry) : null;
    return {
      id: `plan-${row.slug}`,
      slug: row.slug,
      name: row.name,
      max_providers: row.max_providers,
      max_seats: row.max_seats,
      extra_seat_price_monthly_cents: row.extra_seat_price_monthly_cents,
      extra_seat_price_yearly_cents: row.extra_seat_price_yearly_cents,
      price_monthly_cents: tlMonthly,
      price_yearly_cents: tlYearly,
      price_monthly_usd_cents: usdMonthly,
      price_yearly_usd_cents: usdYearly,
      currency_primary: "USD",
      currency_secondary: "TL",
      plan_features: planFeaturesForSlug(row.slug),
    };
  });

  return c.json({ token_plans, rates });
});

aitrack.post("/usage", requireAuth, zValidator("json", z.object({
  user_id: z.string(),
  platform: z.string(),
  used_percent: z.number().nullable().optional(),
  used: z.string().nullable().optional(),
  total: z.string().nullable().optional(),
  resets_at: z.string().nullable().optional(),
  error: z.string().nullable().optional(),
  updated_at: z.string().optional(),
  snapshot_id: z.string().max(500).optional(),
  windows: z.array(usageWindowSchema).optional(),
}).passthrough()), async (c) => {
  const body = c.req.valid("json");
  const authUser = c.get("user");
  if (body.user_id !== authUser.id) {
    return c.json({ error: "forbidden", message: "user_id mismatch" }, 403);
  }

  const providerId = mapPlatformToProviderId(body.platform);

  // Workspace ve baglanti aramalari birbirine bagli degil, o yuzden ard arda
  // degil es zamanli. Eskiden bu yol POST basina uc ayri Worker <-> D1
  // gidis-donusu yapiyordu; simdi bir tane (baglanti sorgusu birlestirildi,
  // workspace sorgusu paralel).
  const [account, connectionLookup] = await Promise.all([
    resolveWorkspaceForUser(c.env, authUser.id, c.get("workspaceId")),
    connectionLookupForUsage(c.env, authUser.id, providerId, body.platform),
  ]);

  if (!account) {
    return c.json({ error: "workspace_not_found", message: "Hesap bulunamadı" }, 404);
  }
  if (!connectionLookup.hasConnection || !connectionLookup.connectionId) {
    return c.json({ error: "provider_not_connected", message: "Provider bağlı değil" }, 403);
  }
  const connection = { id: connectionLookup.connectionId };

  // VPS production path is authoritative: acknowledge only after the sample
  // reaches the VPS. This legacy endpoint remains for older clients, but it
  // must not silently report success while the hot-store write is pending.
  try {
    await upsertProviderUsageBatch(c.env, [{
      workspace_id: account.workspace_id,
      provider_id: providerId,
      connection_id: connection.id,
      user_id: authUser.id,
      user_email: authUser.email,
      used_percent: body.used_percent,
      used: body.used,
      total: body.total,
      resets_at: body.resets_at,
      error: body.error,
      updated_at: body.updated_at,
      snapshot_id: body.snapshot_id,
      windows: body.windows as any,
    }], undefined, { requireVpsMirror: true });
  } catch (err) {
    console.error("aitrack usage persistence failed", err instanceof Error ? err.message : err);
    return c.json({ error: "provider_persistence_failed" }, 503);
  }

  const usedPercent = effectiveUsedPercent(body.used_percent, body.windows as any);
  scheduleUsageThresholdAlerts(
    c.executionCtx,
    c.env,
    authUser.id,
    account.workspace_id,
    providerId,
    usedPercent
  );

  return c.json({ ok: true, provider_id: providerId, workspace_id: account.workspace_id });
});

/**
 * Cok saglayicili tek istek.
 *
 * `/usage` saglayici basina bir POST demek: 3-5 saglayicisi olan bir kullanicida
 * ayni auth, workspace ve baglanti aramalari her seferinde bastan yapiliyor ve
 * her biri ayri bir Worker invocation'i olusturuyor. Burada bunlarin hepsi bir
 * kez yapiliyor, ardindan tum kalemler tek snapshot/history upsert'ine gidiyor.
 *
 * `/usage` kaldirilmadi: yayindaki eski istemciler onu cagirmaya devam ediyor.
 */
aitrack.post("/usage/batch", requireAuth, zValidator("json", z.object({
  user_id: z.string(),
  items: z.array(z.object({
    platform: z.string(),
    used_percent: z.number().nullable().optional(),
    used: z.string().nullable().optional(),
    total: z.string().nullable().optional(),
    resets_at: z.string().nullable().optional(),
    error: z.string().nullable().optional(),
    updated_at: z.string().optional(),
    snapshot_id: z.string().max(500).optional(),
    windows: z.array(usageWindowSchema).optional(),
  }).passthrough()).min(1).max(50),
})), async (c) => {
  const body = c.req.valid("json");
  const authUser = c.get("user");
  if (body.user_id !== authUser.id) {
    return c.json({ error: "forbidden", message: "user_id mismatch" }, 403);
  }

  const [account, connections] = await Promise.all([
    resolveWorkspaceForUser(c.env, authUser.id, c.get("workspaceId")),
    allConnectionsForUser(c.env, authUser.id),
  ]);
  if (!account) {
    return c.json({ error: "workspace_not_found", message: "Hesap bulunamadı" }, 404);
  }

  const results: Array<{ platform: string; provider_id: string; ok: boolean; error?: string }> = [];
  const inputs: Parameters<typeof upsertProviderUsageBatch>[1] = [];

  for (const item of body.items) {
    const providerId = mapPlatformToProviderId(item.platform);
    const rawName = item.platform.trim() || providerId;
    // Tekil yoldaki iki kontrolun aynisi: varlik ham adi da kabul ediyor,
    // baglanti secimi yalnizca kanonik id ile esliyor.
    const hasConnection =
      connections.storedProviderNames.has(rawName) ||
      connections.storedProviderNames.has(providerId);
    const connectionId = connections.latestByProvider.get(providerId) ?? null;

    if (!hasConnection || !connectionId) {
      results.push({ platform: item.platform, provider_id: providerId, ok: false, error: "provider_not_connected" });
      continue;
    }

    inputs.push({
      workspace_id: account.workspace_id,
      provider_id: providerId,
      connection_id: connectionId,
      user_id: authUser.id,
      user_email: authUser.email,
      used_percent: item.used_percent,
      used: item.used,
      total: item.total,
      resets_at: item.resets_at,
      error: item.error,
      updated_at: item.updated_at,
      snapshot_id: item.snapshot_id,
      windows: item.windows as any,
    });

    scheduleUsageThresholdAlerts(
      c.executionCtx,
      c.env,
      authUser.id,
      account.workspace_id,
      providerId,
      effectiveUsedPercent(item.used_percent, item.windows as any)
    );

    results.push({ platform: item.platform, provider_id: providerId, ok: true });
  }

  // Tek bir kullanici snapshot'i + tek history satiri: 5 provider ayni batch'te
  // geldiyse D1'de 5 ayri JSON upsert yerine 1 upsert olur.
  if (inputs.length > 0) {
    // This endpoint also acknowledges usage batches consumed by clients. A
    // 2xx clears the client's retry state, so persistence must finish before
    // we acknowledge it; waitUntil alone would make a post-response failure
    // indistinguishable from a successful durable write.
    try {
      await upsertProviderUsageBatch(c.env, inputs, undefined, { requireVpsMirror: true });
    } catch (err) {
      console.error(
        "aitrack usage batch persistence failed",
        err instanceof Error ? err.message : err,
      );
      return c.json(
        {
          ok: false,
          error: "provider_persistence_failed",
          message: "Usage could not be persisted; retry the batch",
          results,
        },
        503,
      );
    }
  }

  return c.json({ ok: true, workspace_id: account.workspace_id, results });
});

aitrack.get("/billing/rates", async (c) => {
  const rates = await getUsdTryRate(c.env);
  return c.json({ rates });
});

aitrack.get("/billing/orders/:merchantOid", requireAuth, async (c) => {
  const oid = decodeURIComponent(c.req.param("merchantOid"));
  const order = await getOrder(c.env, oid);
  const authUser = c.get("user");
  const customerEmail = (order as { customer_email?: string | null } | null)?.customer_email;
  if (
    !order ||
    !customerEmail ||
    customerEmail.toLowerCase() !== authUser.email.toLowerCase()
  ) {
    return c.json({ error: "order_not_found", message: "Sipariş bulunamadı" }, 404);
  }
  const o = order as Record<string, unknown>;
  return c.json({
    order: {
      merchant_oid: o.merchant_oid,
      status: o.status,
      plan_slug: o.plan_slug,
      amount_minor: o.amount_minor,
      currency: o.currency,
      terms_version: o.terms_version,
      precontract_version: o.precontract_version,
      distance_sales_version: o.distance_sales_version,
      refund_version: o.refund_version,
      subscription_version: o.subscription_version,
      immediate_performance_requested: o.immediate_performance_requested,
      entitlement_available_at: o.entitlement_available_at,
      entitlement_status: o.entitlement_status,
      entitlement_activated_at: o.entitlement_activated_at,
      accepted_locale: o.accepted_locale,
      completed_at: o.completed_at,
      created_at: o.created_at,
      kind: o.kind,
    },
  });
});

aitrack.post("/billing/checkout", rateLimit({ limit: 10, windowSeconds: 60, keyPrefix: "billing:checkout" }), requireAuth, zValidator("json", z.object({
  plan_slug: z.string(),
  email: z.string().email(),
  name: z.string().trim().min(1).max(200),
  phone: z.string().trim().min(3).max(80),
  address: z.string().trim().min(1).max(500),
  terms_version: z.string().min(1).max(32),
  precontract_version: z.string().min(1).max(32),
  distance_sales_version: z.string().min(1).max(32),
  refund_version: z.string().min(1).max(32),
  subscription_version: z.string().min(1).max(32),
  immediate_performance_requested: z.boolean(),
  accepted_locale: z.string().min(2).max(10),
})), async (c) => {
  const body = c.req.valid("json");
  if (body.email.trim().toLowerCase() !== c.get("user").email.toLowerCase()) {
    return c.json({ error: "forbidden", message: "Email mismatch" }, 403);
  }
  try {
    validatePaymentLegalAcceptance({
      termsVersion: body.terms_version,
      precontractVersion: body.precontract_version,
      distanceSalesVersion: body.distance_sales_version,
      refundVersion: body.refund_version,
      subscriptionVersion: body.subscription_version,
      immediatePerformanceRequested: body.immediate_performance_requested,
      acceptedLocale: body.accepted_locale,
    });
  } catch (error) {
    return c.json({ error: "legal_acceptance_required", code: error instanceof LegalAcceptanceRequiredError ? error.code : "legal_acceptance_required" }, 409);
  }
  if (!paytrIsConfigured(c.env)) {
    return c.json({ error: "payment_not_configured", message: "PayTR yapılandırılmamış" }, 503);
  }
  if (!paytrLegalSalesEnabled(c.env)) {
    return c.json({
      error: "legal_sales_not_enabled",
      message: "Ücretli satışlar doğrulanmış hukuki fiyatlandırma ve faturalama ayarları yayımlanana kadar kapalıdır.",
    }, 503);
  }
  if (!isListedPlanSlug(body.plan_slug)) {
    return c.json({ error: "plan_not_found", message: "Plan bulunamadı" }, 404);
  }
  const plan = planDefForSlug(body.plan_slug);
  if (plan.price_monthly_cents <= 0) {
    return c.json({ error: "free_plan", message: "Ücretsiz plan için checkout gerekmez" }, 400);
  }

  const rates = await getUsdTryRate(c.env);
  if (!isUsablePaymentRate(rates)) {
    return c.json({
      error: "payment_rate_unavailable",
      message: "Ödeme için doğrulanmış güncel kur alınamadı; satış başlatılmadı.",
    }, 503);
  }
  const usdTry = rates.usd_try;
  const amountKurus = Math.round(plan.price_monthly_cents * usdTry);
  const merchantOid = genMerchantOid("NEW");

  const account = await resolveWorkspaceForUser(c.env, c.get("user").id, c.get("workspaceId"));
  if (!account) {
    return c.json({ error: "workspace_not_found", message: "Hesap bulunamadı" }, 404);
  }

  const orderId = await createOrder(c.env, {
    merchantOid,
    email: body.email.toLowerCase().trim(),
    planSlug: plan.slug,
    amountKurus,
    kind: "new",
    customerName: body.name,
    customerPhone: body.phone,
    customerAddress: body.address,
    workspaceId: account.workspace_id,
    termsVersion: body.terms_version,
    precontractVersion: body.precontract_version,
    distanceSalesVersion: body.distance_sales_version,
    refundVersion: body.refund_version,
    subscriptionVersion: body.subscription_version,
    immediatePerformanceRequested: body.immediate_performance_requested,
    acceptedLocale: body.accepted_locale,
  });

  await recordLegalConsents(
    c.env,
    {
      userId: c.get("user").id,
      locale: body.accepted_locale,
      source: "checkout",
      ip: clientIp(c),
      userAgent: c.req.header("User-Agent") ?? null,
    },
    [
      { purpose: "terms.acceptance", action: "accepted", documentKey: "terms", documentVersion: body.terms_version },
      { purpose: "precontract.acknowledgement", action: "acknowledged", documentKey: "precontract", documentVersion: body.precontract_version },
      { purpose: "distance_sales.acceptance", action: "accepted", documentKey: "distance_sales", documentVersion: body.distance_sales_version },
      { purpose: "refund_policy.acknowledgement", action: "acknowledged", documentKey: "refund", documentVersion: body.refund_version },
      { purpose: "subscription.acceptance", action: "accepted", documentKey: "subscription", documentVersion: body.subscription_version },
      ...(body.immediate_performance_requested
        ? [{ purpose: "digital_service.immediate_performance", action: "accepted" as const, documentKey: "distance_sales" as const, documentVersion: body.distance_sales_version }]
        : []),
    ],
  );

  const { token, iframeUrl } = await createPaytrToken(c.env, {
    merchantOid,
    email: body.email.toLowerCase().trim(),
    userIp: clientIp(c),
    paymentAmountKurus: amountKurus,
    userName: body.name,
    userPhone: body.phone,
    userAddress: body.address,
    planName: plan.name,
  });

  return c.json({
    checkout_url: iframeUrl,
    merchant_oid: merchantOid,
    amount_minor: amountKurus,
    currency: "TL",
    tax_inclusive: true,
    plan_slug: plan.slug,
  });
});

aitrack.post("/billing/upgrade-preview", rateLimit({ limit: 20, windowSeconds: 60, keyPrefix: "billing:upgrade-preview" }), requireAuth, zValidator("json", z.object({
  email: z.string().email(),
  plan_slug: z.string(),
})), async (c) => {
  const body = c.req.valid("json");
  if (body.email.trim().toLowerCase() !== c.get("user").email.toLowerCase()) {
    return c.json({ error: "forbidden", message: "Email mismatch" }, 403);
  }
  const user = await getUserByEmail(c.env, body.email);
  if (!user) return c.json({ error: "user_not_found", message: "Kullanıcı bulunamadı" }, 404);
  const account = await resolveWorkspaceForUser(c.env, user.id, c.get("workspaceId"));
  const proration = await calculateProration(
    c.env,
    user.id,
    body.plan_slug,
    account?.workspace_id
  );
  if ("error" in proration) return c.json({ error: proration.error, message: "Hesaplama hatası" }, 400);
  return c.json({ proration });
});

const upgradeRequestSchema = z.object({
  plan_slug: z.string(),
  email: z.string().email(),
  terms_version: z.string().min(1).max(32),
  subscription_version: z.string().min(1).max(32),
  accepted_locale: z.string().min(2).max(10),
  name: z.string().trim().min(1).max(200).optional(),
  phone: z.string().trim().min(3).max(80).optional(),
  address: z.string().trim().min(1).max(500).optional(),
  precontract_version: z.string().min(1).max(32).optional(),
  distance_sales_version: z.string().min(1).max(32).optional(),
  refund_version: z.string().min(1).max(32).optional(),
  immediate_performance_requested: z.boolean().optional(),
});

const paidUpgradeRequestSchema = upgradeRequestSchema.extend({
  name: z.string().trim().min(1).max(200),
  phone: z.string().trim().min(3).max(80),
  address: z.string().trim().min(1).max(500),
  precontract_version: z.string().min(1).max(32),
  distance_sales_version: z.string().min(1).max(32),
  refund_version: z.string().min(1).max(32),
  immediate_performance_requested: z.boolean(),
});

aitrack.post("/billing/upgrade", rateLimit({ limit: 10, windowSeconds: 60, keyPrefix: "billing:upgrade" }), requireAuth, zValidator("json", upgradeRequestSchema), async (c) => {
  const body = c.req.valid("json");
  if (body.email.trim().toLowerCase() !== c.get("user").email.toLowerCase()) {
    return c.json({ error: "forbidden", message: "Email mismatch" }, 403);
  }
  const user = await getUserByEmail(c.env, body.email);
  if (!user) return c.json({ error: "user_not_found", message: "Kullanıcı bulunamadı" }, 404);

  const account = await resolveWorkspaceForUser(c.env, user.id, c.get("workspaceId"));
  if (!account) {
    return c.json({ error: "workspace_not_found", message: "Hesap bulunamadı" }, 404);
  }

  const proration = await calculateProration(c.env, user.id, body.plan_slug, account.workspace_id);
  if ("error" in proration) return c.json({ error: proration.error, message: "Hesaplama hatası" }, 400);

  if (proration.payable_tl_cents <= 0) {
    try {
      validatePlanChangeLegalAcceptance({
        termsVersion: body.terms_version,
        subscriptionVersion: body.subscription_version,
        acceptedLocale: body.accepted_locale,
      });
    } catch (error) {
      return c.json({ error: "legal_acceptance_required", code: error instanceof LegalAcceptanceRequiredError ? error.code : "legal_acceptance_required" }, 409);
    }
    await recordLegalConsents(
      c.env,
      {
        userId: c.get("user").id,
        locale: body.accepted_locale,
        source: "upgrade",
        ip: clientIp(c),
        userAgent: c.req.header("User-Agent") ?? null,
      },
      [
        { purpose: "terms.acceptance", action: "accepted", documentKey: "terms", documentVersion: body.terms_version },
        { purpose: "subscription.acceptance", action: "accepted", documentKey: "subscription", documentVersion: body.subscription_version },
      ],
    );
    await applyPlanToWorkspace(c.env, account.workspace_id, proration.new_plan.slug);
    return c.json({
      checkout_url: null,
      merchant_oid: null,
      amount_minor: 0,
      currency: "TL",
      tax_inclusive: false,
      plan_slug: proration.new_plan.slug,
      applied: true,
      proration,
    });
  }

  const paidBody = paidUpgradeRequestSchema.safeParse(body);
  if (!paidBody.success) {
    return c.json({ error: "payment_legal_fields_required", message: "Ücretli plan değişikliği için fatura ve ödeme öncesi belgeler gereklidir." }, 400);
  }

  try {
    validatePaymentLegalAcceptance({
      termsVersion: paidBody.data.terms_version,
      precontractVersion: paidBody.data.precontract_version,
      distanceSalesVersion: paidBody.data.distance_sales_version,
      refundVersion: paidBody.data.refund_version,
      subscriptionVersion: paidBody.data.subscription_version,
      immediatePerformanceRequested: paidBody.data.immediate_performance_requested,
      acceptedLocale: paidBody.data.accepted_locale,
    });
  } catch (error) {
    return c.json({ error: "legal_acceptance_required", code: error instanceof LegalAcceptanceRequiredError ? error.code : "legal_acceptance_required" }, 409);
  }

  if (!paytrIsConfigured(c.env)) {
    return c.json({ error: "payment_not_configured", message: "PayTR yapılandırılmamış" }, 503);
  }
  if (!paytrLegalSalesEnabled(c.env)) {
    return c.json({
      error: "legal_sales_not_enabled",
      message: "Ücretli satışlar doğrulanmış hukuki fiyatlandırma ve faturalama ayarları yayımlanana kadar kapalıdır.",
    }, 503);
  }

  const merchantOid = genMerchantOid("UPG");
  await createOrder(c.env, {
    merchantOid,
    email: paidBody.data.email.toLowerCase().trim(),
    planSlug: proration.new_plan.slug,
    amountKurus: proration.payable_tl_cents,
    kind: "upgrade",
    fromPlanSlug: proration.current_plan.slug,
    prorationCreditKurus: proration.credit_tl_cents,
    cycleStartedAt: proration.cycle_started_at,
    customerName: paidBody.data.name,
    customerPhone: paidBody.data.phone,
    customerAddress: paidBody.data.address,
    workspaceId: account.workspace_id,
    termsVersion: paidBody.data.terms_version,
    precontractVersion: paidBody.data.precontract_version,
    distanceSalesVersion: paidBody.data.distance_sales_version,
    refundVersion: paidBody.data.refund_version,
    subscriptionVersion: paidBody.data.subscription_version,
    immediatePerformanceRequested: paidBody.data.immediate_performance_requested,
    acceptedLocale: paidBody.data.accepted_locale,
  });

  await recordLegalConsents(
    c.env,
    {
      userId: c.get("user").id,
      locale: paidBody.data.accepted_locale,
      source: "upgrade",
      ip: clientIp(c),
      userAgent: c.req.header("User-Agent") ?? null,
    },
    [
      { purpose: "terms.acceptance", action: "accepted", documentKey: "terms", documentVersion: paidBody.data.terms_version },
      { purpose: "precontract.acknowledgement", action: "acknowledged", documentKey: "precontract", documentVersion: paidBody.data.precontract_version },
      { purpose: "distance_sales.acceptance", action: "accepted", documentKey: "distance_sales", documentVersion: paidBody.data.distance_sales_version },
      { purpose: "refund_policy.acknowledgement", action: "acknowledged", documentKey: "refund", documentVersion: paidBody.data.refund_version },
      { purpose: "subscription.acceptance", action: "accepted", documentKey: "subscription", documentVersion: paidBody.data.subscription_version },
      ...(paidBody.data.immediate_performance_requested
        ? [{ purpose: "digital_service.immediate_performance", action: "accepted" as const, documentKey: "distance_sales" as const, documentVersion: paidBody.data.distance_sales_version }]
        : []),
    ],
  );

  const { iframeUrl } = await createPaytrToken(c.env, {
    merchantOid,
    email: paidBody.data.email.toLowerCase().trim(),
    userIp: clientIp(c),
    paymentAmountKurus: proration.payable_tl_cents,
    userName: paidBody.data.name,
    userPhone: paidBody.data.phone,
    userAddress: paidBody.data.address,
    planName: `${proration.new_plan.name} (Yükseltme)`,
  });

  return c.json({
    checkout_url: iframeUrl,
    merchant_oid: merchantOid,
    amount_minor: proration.payable_tl_cents,
    currency: "TL",
    tax_inclusive: true,
    plan_slug: proration.new_plan.slug,
    proration,
  });
});

aitrack.post("/billing/callback", rateLimit({ limit: 120, windowSeconds: 60, keyPrefix: "paytr:callback" }), async (c) => {
  if (!paytrIsConfigured(c.env)) {
    return new Response("payment_not_configured", { status: 503 });
  }

  const form = await c.req.formData().catch(() => null);
  if (!form) return new Response("bad request", { status: 400 });
  const merchantOid = form.get("merchant_oid") as string;
  const status = form.get("status") as string;
  const totalAmount = form.get("total_amount") as string;
  const hash = form.get("hash") as string;
  if (!merchantOid) return new Response("missing merchant_oid", { status: 400 });

  const merchantSalt = c.env.PAYTR_MERCHANT_SALT || "";
  const merchantKey = c.env.PAYTR_MERCHANT_KEY || "";
  const concat = merchantOid + merchantSalt + (status || "") + (totalAmount || "");
  const enc = new TextEncoder();
  const cryptoKey = await crypto.subtle.importKey(
    "raw", enc.encode(merchantKey), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]
  );
  const sig = await crypto.subtle.sign("HMAC", cryptoKey, enc.encode(concat));
  let bin = "";
  const bytes = new Uint8Array(sig);
  for (let i = 0; i < bytes.length; i++) bin += String.fromCharCode(bytes[i]);
  const expected = btoa(bin);
  if (!timingSafeEqual(expected, hash || "")) return new Response("hash mismatch", { status: 400 });

  const existing = await getOrder(c.env, merchantOid);
  if (!existing) return new Response("order_not_found", { status: 404 });

  const orderRow = existing as {
    id?: string | null;
    workspace_id?: string | null;
    user_id?: string | null;
    customer_email?: string | null;
    customer_name?: string | null;
    customer_phone?: string | null;
    customer_address?: string | null;
    plan_slug?: string | null;
    amount_minor?: number | null;
    currency?: string | null;
    kind?: string | null;
    metadata_json?: string | null;
    status?: string | null;
    terms_version?: string | null;
    precontract_version?: string | null;
    distance_sales_version?: string | null;
    refund_version?: string | null;
    subscription_version?: string | null;
    immediate_performance_requested?: number | null;
    accepted_locale?: string | null;
  };

  if (orderRow.status === "completed") {
    return new Response("OK", { status: 200 });
  }

  const expectedAmount = String(orderRow.amount_minor ?? "");
  const paidAmount = String(totalAmount ?? "").trim();
  if (status === "success" && expectedAmount && paidAmount !== expectedAmount) {
    return new Response("amount mismatch", { status: 400 });
  }

  const finalStatus = status === "success" ? "completed" : "failed";
  await completeOrder(c.env, merchantOid, finalStatus);

  if (finalStatus === "completed" && orderRow.plan_slug) {
    let workspaceId = orderRow.workspace_id || null;
    let userId = orderRow.user_id || null;
    if ((!workspaceId || !userId) && orderRow.customer_email) {
      const u = await db(c.env)
        .prepare("SELECT id FROM users WHERE email = ?")
        .bind(orderRow.customer_email.toLowerCase())
        .first<{ id: string }>();
      if (u) {
        userId = userId || u.id;
        if (!workspaceId) {
          const resolved = await resolveWorkspaceForUser(c.env, u.id);
          workspaceId = resolved?.workspace_id ?? null;
        }
      }
    }

    if (workspaceId && !orderRow.workspace_id) {
      await db(c.env)
        .prepare("UPDATE billing_orders SET workspace_id = ? WHERE merchant_oid = ?")
        .bind(workspaceId, merchantOid)
        .run();
    }

    if (workspaceId) {
      const entitlementResult = await fulfillDuePaidOrder(c.env, merchantOid);
      if (entitlementResult === "failed") {
        console.error("paid entitlement fulfillment failed", { merchantOid });
      }
    }

    if (orderRow.customer_email) {
      try {
        const emailStatus = await attemptPaidOrderConfirmation(c.env, merchantOid);
        if (emailStatus === "failed") {
          console.error("paid order confirmation email failed", { merchantOid });
        }
      } catch (error) {
        // Payment fulfillment must not be rolled back because SMTP is
        // temporarily unavailable; the retry queue keeps the evidence durable.
        console.error("paid order confirmation email failed", error instanceof Error ? error.message : error);
      }
    }
  }

  return new Response("OK", { status: 200 });
});

export default aitrack;

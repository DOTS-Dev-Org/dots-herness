import type { Env } from "../env";
import { db } from "../db/client";
import { CONSUMER_WITHDRAWAL_PERIOD_DAYS } from "./legal";

const PAYTR_GET_TOKEN_URL = "https://www.paytr.com/odeme/api/get-token";
const PAYTR_IFRAME_BASE = "https://www.paytr.com/odeme/guvenli/";

function paytrConfig(env: Env) {
  return {
    merchantId: env.PAYTR_MERCHANT_ID || "",
    merchantKey: env.PAYTR_MERCHANT_KEY || "",
    merchantSalt: env.PAYTR_MERCHANT_SALT || "",
    testMode: env.PAYTR_TEST_MODE || "1",
    okUrl: env.PAYTR_OK_URL || "https://herness.dots.net.tr/billing/success",
    failUrl: env.PAYTR_FAIL_URL || "https://herness.dots.net.tr/billing/fail",
  };
}

export function paytrIsConfigured(env: Env) {
  const c = paytrConfig(env);
  return !!(c.merchantId && c.merchantKey && c.merchantSalt);
}

/**
 * Paid PayTR sales remain fail-closed until the published legal pricing and
 * invoicing configuration has been verified outside the codebase.
 */
export function paytrLegalSalesEnabled(env: Env): boolean {
  return env.PAYTR_LEGAL_SALES_ENABLED === "1" &&
    env.LEGAL_PUBLICATION_ENABLED === "1" &&
    env.PAYTR_TAX_INCLUSIVE_CONFIRMED === "1" &&
    env.PAYTR_INVOICE_FLOW_CONFIRMED === "1" &&
    env.PAYTR_DURABLE_DELIVERY_CONFIRMED === "1";
}

export function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let result = 0;
  for (let i = 0; i < a.length; i++) result |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return result === 0;
}

async function hmacSha256Base64(key: string, message: string) {
  const enc = new TextEncoder();
  const cryptoKey = await crypto.subtle.importKey(
    "raw", enc.encode(key), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]
  );
  const sig = await crypto.subtle.sign("HMAC", cryptoKey, enc.encode(message));
  let bin = "";
  const bytes = new Uint8Array(sig);
  for (let i = 0; i < bytes.length; i++) bin += String.fromCharCode(bytes[i]);
  return btoa(bin);
}

function buildUserBasket(planName: string, priceKurus: number) {
  return JSON.stringify([[planName || "AI Watcher Plan", "1", String(priceKurus)]]);
}

export async function createPaytrToken(env: Env, opts: {
  merchantOid: string;
  email: string;
  userIp: string;
  paymentAmountKurus: number;
  userName: string;
  userPhone: string;
  userAddress: string;
  planName: string;
  installment?: number;
}) {
  if (!paytrIsConfigured(env)) throw new Error("payment_not_configured");
  const c = paytrConfig(env);
  const noInstallment = opts.installment ? "0" : "1";
  const maxInstallment = opts.installment ? String(opts.installment) : "0";
  const userBasket = buildUserBasket(opts.planName, opts.paymentAmountKurus);

  const hashStr =
    c.merchantId + opts.userIp + opts.merchantOid + opts.email +
    String(opts.paymentAmountKurus) + "TL" + c.testMode +
    noInstallment + maxInstallment +
    opts.userName + opts.userAddress + opts.userPhone +
    userBasket + c.merchantKey + c.merchantSalt;

  const realToken = await hmacSha256Base64(c.merchantKey, hashStr);

  const form = new URLSearchParams();
  form.set("merchant_id", c.merchantId);
  form.set("user_ip", opts.userIp);
  form.set("merchant_oid", opts.merchantOid);
  form.set("email", opts.email);
  form.set("payment_amount", String(opts.paymentAmountKurus));
  form.set("paytr_token", realToken);
  form.set("user_basket", userBasket);
  form.set("debug_on", "0");
  form.set("test_mode", c.testMode);
  form.set("no_installment", noInstallment);
  form.set("max_installment", maxInstallment);
  form.set("user_name", opts.userName);
  form.set("user_address", opts.userAddress);
  form.set("user_phone", opts.userPhone);
  form.set("merchant_ok_url", c.okUrl);
  form.set("merchant_fail_url", c.failUrl);
  form.set("currency", "TL");
  form.set("lang", "tr");

  const res = await fetch(PAYTR_GET_TOKEN_URL, {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: form.toString(),
  });
  const data = await res.json().catch(() => ({})) as { status?: string; token?: string };
  if (!res.ok || data?.status !== "success" || !data?.token) {
    throw new Error("payment_gateway_error");
  }
  return { token: data.token, iframeUrl: PAYTR_IFRAME_BASE + data.token };
}

export function genMerchantOid(prefix = "AIT") {
  const ts = Date.now().toString(36).toUpperCase();
  const rnd = crypto.getRandomValues(new Uint8Array(6));
  let rand = "";
  for (let i = 0; i < rnd.length; i++) rand += rnd[i].toString(36).padStart(2, "0");
  return `${prefix}-${ts}-${rand}`.slice(0, 64);
}

export async function createOrder(env: Env, data: {
  merchantOid: string;
  email?: string;
  planSlug: string;
  amountKurus: number;
  kind?: string;
  fromPlanSlug?: string;
  prorationCreditKurus?: number;
  cycleStartedAt?: string;
  workspaceId?: string;
  customerName?: string;
  customerPhone?: string;
  customerAddress?: string;
  tokenPlanId?: string;
  paymentProvider?: string;
  termsVersion?: string;
  precontractVersion?: string;
  distanceSalesVersion?: string;
  refundVersion?: string;
  subscriptionVersion?: string;
  immediatePerformanceRequested?: boolean;
  acceptedLocale?: string;
}) {
  const id = crypto.randomUUID();
  const user = data.email
    ? await db(env).prepare("SELECT id FROM users WHERE email = ?").bind(data.email.toLowerCase()).first<{ id: string }>()
    : null;

  await db(env)
    .prepare(
      `INSERT INTO billing_orders
         (id, merchant_oid, workspace_id, customer_email, customer_name, customer_phone, customer_address,
         plan_slug, amount_minor, currency, status, kind, from_plan_slug,
          proration_credit_minor, proration_currency, cycle_started_at, user_id,
          payment_provider, terms_version, precontract_version, distance_sales_version,
          refund_version, subscription_version, immediate_performance_requested,
          accepted_locale, confirmation_email_status, created_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'TL', 'pending', ?, ?, ?, 'TL', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'pending', datetime('now'))`
    )
    .bind(
      id, data.merchantOid, data.workspaceId || null, data.email || null,
      data.customerName || "", data.customerPhone || "",
      data.customerAddress || "",
      data.planSlug,
      data.amountKurus, data.kind || "new", data.fromPlanSlug || null,
      data.prorationCreditKurus || 0, data.cycleStartedAt || null,
      user?.id || null,
      data.paymentProvider || "paytr",
      data.termsVersion || null,
      data.precontractVersion || null,
      data.distanceSalesVersion || null,
      data.refundVersion || null,
      data.subscriptionVersion || null,
      data.immediatePerformanceRequested ? 1 : 0,
      data.acceptedLocale || null,
    )
    .run();
  return id;
}

export async function getOrder(env: Env, merchantOid: string) {
  return db(env)
    .prepare(
      `SELECT id, merchant_oid, workspace_id, user_id, customer_email, customer_name, customer_phone, customer_address,
              plan_slug, amount_minor,
              currency, status, kind, from_plan_slug, proration_credit_minor,
              metadata_json, terms_version, precontract_version,
              distance_sales_version, refund_version, subscription_version,
              immediate_performance_requested, accepted_locale,
              entitlement_available_at, entitlement_status,
              entitlement_activated_at, entitlement_last_error,
              completed_at, created_at
         FROM billing_orders WHERE merchant_oid = ?`
    )
    .bind(merchantOid)
    .first();
}

export async function completeOrder(env: Env, merchantOid: string, status = "completed") {
  await db(env)
    .prepare(
      `UPDATE billing_orders
          SET status = ?,
              completed_at = NOW(),
              entitlement_available_at = CASE
                WHEN ? = 'completed' THEN CASE
                  WHEN immediate_performance_requested = 1 THEN datetime('now')
                  ELSE datetime('now', '+${CONSUMER_WITHDRAWAL_PERIOD_DAYS} days')
                END
                ELSE NULL
              END,
              entitlement_status = CASE WHEN ? = 'completed' THEN 'pending' ELSE 'not_required' END,
              entitlement_activated_at = NULL,
              entitlement_last_error = NULL,
              confirmation_email_status = CASE
                WHEN ? = 'completed' AND confirmation_email_status = 'not_required' THEN 'pending'
                ELSE confirmation_email_status
              END,
              updated_at = NOW()
        WHERE merchant_oid = ?`
    )
    .bind(status, status, status, status, merchantOid)
    .run();
}

const DAYS_IN_CYCLE = 30;

export async function calculateProration(
  env: Env,
  userId: string,
  newPlanSlug: string,
  preferredWorkspaceId?: string
) {
  const { isListedPlanSlug, planDefForSlug } = await import("./plan_features");

  const acct = preferredWorkspaceId
    ? await db(env)
        .prepare(
          `SELECT a.id AS workspace_id, a.plan_slug AS current_slug
             FROM workspace_members am
             JOIN workspaces a ON a.id = am.workspace_id
            WHERE am.user_id = ? AND am.workspace_id = ?`
        )
        .bind(userId, preferredWorkspaceId)
        .first<{ workspace_id: string; current_slug: string | null }>()
    : await db(env)
        .prepare(
          `SELECT a.id AS workspace_id, a.plan_slug AS current_slug
             FROM workspace_members am
             JOIN workspaces a ON a.id = am.workspace_id
            WHERE am.user_id = ?
            ORDER BY CASE am.role WHEN 'owner' THEN 0 ELSE 1 END
            LIMIT 1`
        )
        .bind(userId)
        .first<{ workspace_id: string; current_slug: string | null }>();

  let cycleStartedAt: string | null = null;
  if (acct?.workspace_id) {
    const userEmail = await db(env).prepare("SELECT email FROM users WHERE id = ?").bind(userId).first<{ email: string }>();
    const row = await db(env)
      .prepare(
        `SELECT completed_at, created_at FROM billing_orders
          WHERE (workspace_id = ? OR customer_email = ?) AND status = 'completed'
          ORDER BY COALESCE(completed_at, created_at) ASC LIMIT 1`
      )
      .bind(acct.workspace_id, userEmail?.email || "")
      .first<{ completed_at: string; created_at: string }>();
    cycleStartedAt = row?.completed_at || row?.created_at || null;
  }
  if (!cycleStartedAt) {
    const u = await db(env).prepare("SELECT created_at FROM users WHERE id = ?").bind(userId).first<{ created_at: string }>();
    cycleStartedAt = u?.created_at || new Date().toISOString();
  }

  if (!isListedPlanSlug(newPlanSlug) && newPlanSlug !== "free" && newPlanSlug !== "pro" && newPlanSlug !== "team") {
    return { error: "plan_not_found" as const };
  }
  const newPlan = planDefForSlug(newPlanSlug);
  const currentDef = planDefForSlug(acct?.current_slug);

  const now = new Date();
  const start = new Date(cycleStartedAt);
  const usedMs = now.getTime() - start.getTime();
  const usedDays = Math.max(0, Math.min(DAYS_IN_CYCLE, usedMs / 86400000));
  const remainingDays = Math.max(0, DAYS_IN_CYCLE - usedDays);

  const { getUsdTryRate, isUsablePaymentRate } = await import("./tcmb");
  const rates = await getUsdTryRate(env);
  if (!isUsablePaymentRate(rates)) return { error: "payment_rate_unavailable" as const };
  const usdTry = rates.usd_try;

  const currentUsd = currentDef.price_monthly_cents;
  const newPlanUsd = newPlan.price_monthly_cents;
  const creditUsd = Math.round(currentUsd * (remainingDays / DAYS_IN_CYCLE));
  const payableUsd = Math.max(0, newPlanUsd - creditUsd);

  return {
    current_plan: {
      slug: currentDef.slug,
      name: currentDef.name,
      price_tl_cents: Math.round(currentUsd * usdTry),
    },
    new_plan: {
      slug: newPlan.slug,
      name: newPlan.name,
      price_tl_cents: Math.round(newPlanUsd * usdTry),
    },
    cycle_started_at: cycleStartedAt,
    used_days: Math.round(usedDays * 10) / 10,
    remaining_days: Math.round(remainingDays * 10) / 10,
    credit_tl_cents: Math.round(creditUsd * usdTry),
    payable_tl_cents: Math.round(payableUsd * usdTry),
    is_upgrade: payableUsd < newPlanUsd,
    is_downgrade_or_same:
      !acct?.current_slug || currentDef.slug === "free" || newPlanUsd <= currentUsd,
  };
}

export function clientIp(c: { req: { header: (n: string) => string | undefined } }) {
  return c.req.header("cf-connecting-ip") ||
    c.req.header("x-forwarded-for")?.split(",")[0]?.trim() ||
    "127.0.0.1";
}

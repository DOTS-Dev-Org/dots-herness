import { decodeJwt, importPKCS8, SignJWT } from "jose";
import type { Env } from "../env";
import { db, nowIso, stableId } from "../db/client";
import { applyPlanToWorkspace } from "./billing_fulfill";
import { planDefForSlug, type PlanSlug } from "./plan_features";
import { getEffectiveSeats } from "./team";

export type StoreProvider = "apple" | "google";
export type StoreCycle = "monthly" | "yearly";
export type StoreEntitlementKind = "plan" | "extra_seat";

export type VerifiedStoreEntitlement = {
  provider: StoreProvider;
  storeKey: string;
  productId: string;
  cycle: StoreCycle | null;
  kind: StoreEntitlementKind;
  planSlug: PlanSlug;
  quantity: number;
  expiresAt: string;
};

export class StoreVerificationError extends Error {
  readonly code: string;
  readonly httpStatus: 400 | 403 | 409 | 502 | 503;

  constructor(code: string, httpStatus: 400 | 403 | 409 | 502 | 503 = 502) {
    super(code);
    this.name = "StoreVerificationError";
    this.code = code;
    this.httpStatus = httpStatus;
  }
}

type ProductDefinition = {
  kind: StoreEntitlementKind;
  planSlug: PlanSlug;
  cycle: StoreCycle | null;
  priceCents: number;
};

const APPLE_PRODUCTS: Record<string, ProductDefinition> = {
  "com.dots.aiwatcher.pro.v2": { kind: "plan", planSlug: "pro", cycle: "monthly", priceCents: 99 },
  "com.dots.aiwatcher.pro.yearly": { kind: "plan", planSlug: "pro", cycle: "yearly", priceCents: 999 },
  "com.dots.aiwatcher.team": { kind: "plan", planSlug: "team", cycle: "monthly", priceCents: 499 },
  "com.dots.aiwatcher.team.yearly": { kind: "plan", planSlug: "team", cycle: "yearly", priceCents: 4999 },
  "com.dots.aiwatcher.extra_seat": { kind: "extra_seat", planSlug: "team", cycle: "monthly", priceCents: 99 },
  "com.dots.aiwatcher.extra_seat.yearly": { kind: "extra_seat", planSlug: "team", cycle: "yearly", priceCents: 999 },
  // Kept read-only for old restore flows. New clients never request these ids.
  "com.dots.aiwatcher.pro": { kind: "plan", planSlug: "pro", cycle: "monthly", priceCents: 99 },
  "com.dots.aiwatcher.starter": { kind: "plan", planSlug: "free", cycle: "monthly", priceCents: 0 },
  "com.dots.aiwatcher.plus": { kind: "plan", planSlug: "team", cycle: "monthly", priceCents: 499 },
  "com.dots.aiwatcher.business": { kind: "plan", planSlug: "team", cycle: "monthly", priceCents: 499 },
};

const GOOGLE_PRODUCTS: Record<string, ProductDefinition & { basePlanId: string }> = {
  "aiwatcher_pro:monthly": { kind: "plan", planSlug: "pro", cycle: "monthly", priceCents: 99, basePlanId: "monthly" },
  "aiwatcher_pro:yearly": { kind: "plan", planSlug: "pro", cycle: "yearly", priceCents: 999, basePlanId: "yearly" },
  "aiwatcher_team:monthly": { kind: "plan", planSlug: "team", cycle: "monthly", priceCents: 499, basePlanId: "monthly" },
  "aiwatcher_team:yearly": { kind: "plan", planSlug: "team", cycle: "yearly", priceCents: 4999, basePlanId: "yearly" },
  "aiwatcher_extra_seat:monthly": { kind: "extra_seat", planSlug: "team", cycle: "monthly", priceCents: 99, basePlanId: "monthly" },
  "aiwatcher_extra_seat:yearly": { kind: "extra_seat", planSlug: "team", cycle: "yearly", priceCents: 999, basePlanId: "yearly" },
  // Legacy products remain verifiable for restore only.
  "aiwatcher_starter:monthly": { kind: "plan", planSlug: "free", cycle: "monthly", priceCents: 0, basePlanId: "monthly" },
  "aiwatcher_plus:monthly": { kind: "plan", planSlug: "team", cycle: "monthly", priceCents: 499, basePlanId: "monthly" },
  "aiwatcher_business:monthly": { kind: "plan", planSlug: "team", cycle: "monthly", priceCents: 499, basePlanId: "monthly" },
};

export function appleProductDefinition(productId: string): ProductDefinition | null {
  return APPLE_PRODUCTS[productId] ?? null;
}

export function googleProductDefinition(productId: string, basePlanId: string): ProductDefinition | null {
  return GOOGLE_PRODUCTS[`${productId}:${basePlanId}`] ?? null;
}

export function storePurchaseVerificationConfigured(env: Env, provider: StoreProvider): boolean {
  if (provider === "apple") {
    return Boolean(
      env.APPLE_ISSUER_ID?.trim() &&
      env.APPLE_KEY_ID?.trim() &&
      env.APPLE_PRIVATE_KEY?.trim() &&
      env.APPLE_BUNDLE_ID?.trim(),
    );
  }
  return Boolean(env.GOOGLE_PLAY_SERVICE_ACCOUNT_JSON?.trim() && env.GOOGLE_PLAY_PACKAGE_NAME?.trim());
}

function required(value: unknown, code: string): string {
  if (typeof value !== "string" || !value.trim()) throw new StoreVerificationError(code, 502);
  return value;
}

function futureIso(value: unknown): string {
  const ms = typeof value === "number" ? value : Date.parse(String(value ?? ""));
  if (!Number.isFinite(ms) || ms <= Date.now()) {
    throw new StoreVerificationError("store_subscription_not_active", 409);
  }
  return new Date(ms).toISOString();
}

function isUuid(value: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value);
}

/** Same stable account identifier used by BillingFlowParams.setObfuscatedAccountId. */
export async function obfuscatedAccountId(userId: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(userId));
  return Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("");
}

async function appleApiToken(env: Env): Promise<string> {
  try {
    const key = await importPKCS8(env.APPLE_PRIVATE_KEY!.replace(/\\n/g, "\n"), "ES256");
    const now = Math.floor(Date.now() / 1000);
    return await new SignJWT({ bid: env.APPLE_BUNDLE_ID })
      .setProtectedHeader({ alg: "ES256", kid: env.APPLE_KEY_ID!, typ: "JWT" })
      .setIssuer(env.APPLE_ISSUER_ID!)
      .setAudience("appstoreconnect-v1")
      .setIssuedAt(now)
      .setExpirationTime(now + 300)
      .sign(key);
  } catch {
    throw new StoreVerificationError("apple_verifier_key_invalid", 503);
  }
}

async function fetchAppleTransaction(env: Env, transactionId: string): Promise<Record<string, unknown>> {
  const token = await appleApiToken(env);
  const encodedId = encodeURIComponent(transactionId);
  const hosts = [
    "https://api.storekit.itunes.apple.com",
    "https://api.storekit-sandbox.itunes.apple.com",
  ];

  for (const host of hosts) {
    let response: Response;
    try {
      response = await fetch(`${host}/inApps/v1/transactions/${encodedId}`, {
        headers: { Authorization: `Bearer ${token}` },
      });
    } catch {
      throw new StoreVerificationError("apple_verification_unavailable", 502);
    }
    if (response.status === 404) continue;
    if (!response.ok) throw new StoreVerificationError("apple_verification_failed", 502);
    const body = (await response.json().catch(() => null)) as { signedTransactionInfo?: unknown } | null;
    const signed = required(body?.signedTransactionInfo, "apple_transaction_missing");
    try {
      // The Store Server API response is authenticated over TLS; decode the signed
      // transaction returned by Apple and validate every entitlement field below.
      return decodeJwt(signed) as Record<string, unknown>;
    } catch {
      throw new StoreVerificationError("apple_transaction_invalid", 502);
    }
  }

  throw new StoreVerificationError("apple_transaction_not_found", 400);
}

export async function verifyApplePurchase(
  env: Env,
  input: { transactionId: string; originalTransactionId?: string; userId?: string },
): Promise<VerifiedStoreEntitlement> {
  if (!storePurchaseVerificationConfigured(env, "apple")) {
    throw new StoreVerificationError("store_purchase_verification_not_configured", 503);
  }
  const transaction = await fetchAppleTransaction(env, input.transactionId);
  const transactionId = required(transaction.transactionId, "apple_transaction_id_missing");
  const originalTransactionId = required(transaction.originalTransactionId, "apple_original_transaction_id_missing");
  const productId = required(transaction.productId, "apple_product_missing");
  const bundleId = required(transaction.bundleId, "apple_bundle_mismatch");
  if (transactionId !== input.transactionId || bundleId !== env.APPLE_BUNDLE_ID) {
    throw new StoreVerificationError("apple_transaction_mismatch", 400);
  }
  if (input.originalTransactionId && input.originalTransactionId !== originalTransactionId) {
    throw new StoreVerificationError("apple_original_transaction_mismatch", 400);
  }
  if (transaction.revocationDate != null || transaction.revocationReason != null) {
    throw new StoreVerificationError("apple_transaction_revoked", 409);
  }
  if (input.userId && typeof transaction.appAccountToken === "string" && isUuid(input.userId)) {
    if (transaction.appAccountToken.toLowerCase() !== input.userId.toLowerCase()) {
      throw new StoreVerificationError("store_account_mismatch", 409);
    }
  }
  const definition = appleProductDefinition(productId);
  if (!definition) throw new StoreVerificationError("apple_product_not_allowed", 400);

  return {
    provider: "apple",
    storeKey: originalTransactionId,
    productId,
    cycle: definition.cycle,
    kind: definition.kind,
    planSlug: definition.planSlug,
    quantity: Math.max(1, Number(transaction.quantity) || 1),
    expiresAt: futureIso(transaction.expiresDate),
  };
}

type GoogleServiceAccount = { client_email?: string; private_key?: string };
let googleTokenCache: { token: string; expiresAt: number } | null = null;

function googleServiceAccount(env: Env): Required<GoogleServiceAccount> {
  try {
    const parsed = JSON.parse(env.GOOGLE_PLAY_SERVICE_ACCOUNT_JSON || "") as GoogleServiceAccount;
    if (!parsed.client_email || !parsed.private_key) throw new Error("missing_key");
    return { client_email: parsed.client_email, private_key: parsed.private_key };
  } catch {
    throw new StoreVerificationError("google_service_account_invalid", 503);
  }
}

async function googleAccessToken(env: Env): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  if (googleTokenCache && googleTokenCache.expiresAt > now + 60) return googleTokenCache.token;
  const serviceAccount = googleServiceAccount(env);
  let assertion: string;
  try {
    const key = await importPKCS8(serviceAccount.private_key.replace(/\\n/g, "\n"), "RS256");
    assertion = await new SignJWT({ scope: "https://www.googleapis.com/auth/androidpublisher" })
      .setProtectedHeader({ alg: "RS256", typ: "JWT" })
      .setIssuer(serviceAccount.client_email)
      .setSubject(serviceAccount.client_email)
      .setAudience("https://oauth2.googleapis.com/token")
      .setIssuedAt(now)
      .setExpirationTime(now + 3600)
      .sign(key);
  } catch {
    throw new StoreVerificationError("google_service_account_invalid", 503);
  }

  let response: Response;
  try {
    response = await fetch("https://oauth2.googleapis.com/token", {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({
        grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
        assertion,
      }),
    });
  } catch {
    throw new StoreVerificationError("google_verification_unavailable", 502);
  }
  if (!response.ok) throw new StoreVerificationError("google_oauth_failed", 503);
  const body = (await response.json().catch(() => null)) as { access_token?: string; expires_in?: number } | null;
  const token = required(body?.access_token, "google_oauth_token_missing");
  googleTokenCache = { token, expiresAt: now + Math.max(300, body?.expires_in ?? 3600) };
  return token;
}

export async function verifyGooglePurchase(
  env: Env,
  input: { purchaseToken: string; productId?: string; userId?: string },
): Promise<VerifiedStoreEntitlement> {
  if (!storePurchaseVerificationConfigured(env, "google")) {
    throw new StoreVerificationError("store_purchase_verification_not_configured", 503);
  }
  const accessToken = await googleAccessToken(env);
  const url = `https://androidpublisher.googleapis.com/androidpublisher/v3/applications/${encodeURIComponent(env.GOOGLE_PLAY_PACKAGE_NAME!)}/purchases/subscriptionsv2/tokens/${encodeURIComponent(input.purchaseToken)}`;
  let response: Response;
  try {
    response = await fetch(url, { headers: { Authorization: `Bearer ${accessToken}` } });
  } catch {
    throw new StoreVerificationError("google_verification_unavailable", 502);
  }
  if (response.status === 404) throw new StoreVerificationError("google_purchase_not_found", 400);
  if (!response.ok) throw new StoreVerificationError("google_verification_failed", 502);
  const purchase = (await response.json().catch(() => null)) as {
    packageName?: string;
    subscriptionState?: string;
    externalAccountIdentifiers?: { obfuscatedExternalAccountId?: string };
    lineItems?: Array<{
      productId?: string;
      expiryTime?: string;
      offerDetails?: { basePlanId?: string };
    }>;
  } | null;
  if (purchase?.packageName && purchase.packageName !== env.GOOGLE_PLAY_PACKAGE_NAME) {
    throw new StoreVerificationError("google_package_mismatch", 400);
  }
  const item = purchase?.lineItems?.find((candidate) =>
    !input.productId || candidate.productId === input.productId,
  );
  const productId = required(item?.productId, "google_product_missing");
  const basePlanId = required(item?.offerDetails?.basePlanId, "google_base_plan_missing");
  const definition = googleProductDefinition(productId, basePlanId);
  if (!definition) throw new StoreVerificationError("google_product_not_allowed", 400);
  if (
    purchase?.subscriptionState !== "SUBSCRIPTION_STATE_ACTIVE" &&
    purchase?.subscriptionState !== "SUBSCRIPTION_STATE_IN_GRACE_PERIOD" &&
    purchase?.subscriptionState !== "SUBSCRIPTION_STATE_CANCELED"
  ) {
    throw new StoreVerificationError("google_subscription_not_active", 409);
  }
  if (input.userId && purchase?.externalAccountIdentifiers?.obfuscatedExternalAccountId) {
    const expected = await obfuscatedAccountId(input.userId);
    if (purchase.externalAccountIdentifiers.obfuscatedExternalAccountId !== expected) {
      throw new StoreVerificationError("store_account_mismatch", 409);
    }
  }

  return {
    provider: "google",
    storeKey: input.purchaseToken,
    productId,
    cycle: definition.cycle,
    kind: definition.kind,
    planSlug: definition.planSlug,
    quantity: 1,
    expiresAt: futureIso(item?.expiryTime),
  };
}

type StoreOrderRow = {
  id: string;
  workspace_id: string | null;
  payment_provider: string | null;
  product_id: string | null;
  kind: string | null;
  plan_slug: string | null;
  store_status: string | null;
  quantity: number | null;
  store_expires_at: string | null;
};

export type StoreFulfillment = {
  plan_slug: PlanSlug;
  kind: StoreEntitlementKind;
  cycle: StoreCycle | null;
  extra_seats: number;
  max_seats: number;
  store_expires_at: string;
};

async function syncStoreExtraSeats(env: Env, workspaceId: string): Promise<number> {
  const workspace = await db(env)
    .prepare(`SELECT plan_slug FROM workspaces WHERE id = ?`)
    .bind(workspaceId)
    .first<{ plan_slug: string | null }>();
  const isTeamWorkspace = planDefForSlug(workspace?.plan_slug).slug === "team";
  const row = await db(env)
    .prepare(
      `SELECT COALESCE(SUM(quantity), 0) AS seats
         FROM billing_orders
        WHERE workspace_id = ?
          AND kind = 'extra_seat'
          AND payment_provider IN ('apple', 'google')
          AND store_status = 'active'
          AND (store_expires_at IS NULL OR julianday(store_expires_at) > julianday('now'))`,
    )
    .bind(workspaceId)
    .first<{ seats: number }>();
  const seats = isTeamWorkspace ? Math.max(0, Number(row?.seats) || 0) : 0;
  await db(env)
    .prepare(
      `UPDATE workspaces
          SET store_extra_seats = ?, updated_at = datetime('now')
        WHERE id = ?`,
    )
    .bind(seats, workspaceId)
    .run();
  return seats;
}

async function applyStorePlan(
  env: Env,
  workspaceId: string,
  entitlement: VerifiedStoreEntitlement,
): Promise<void> {
  await applyPlanToWorkspace(env, workspaceId, entitlement.planSlug, {
    startedAt: new Date().toISOString(),
    endsAt: entitlement.expiresAt,
  });
}

/** Idempotently writes/updates one store subscription in billing_orders. */
export async function fulfillStoreEntitlement(
  env: Env,
  input: { userId: string; userEmail: string; workspaceId: string; workspacePlan: string; role: string },
  entitlement: VerifiedStoreEntitlement,
): Promise<StoreFulfillment> {
  if (input.role !== "owner" && input.role !== "admin") {
    throw new StoreVerificationError("workspace_billing_admin_required", 403);
  }
  if (entitlement.kind === "extra_seat" && input.workspacePlan !== "team") {
    throw new StoreVerificationError("extra_seat_team_required", 409);
  }

  const existing = await db(env)
    .prepare(
      `SELECT id, workspace_id, payment_provider, store_product_id AS product_id,
              kind, plan_slug, store_status, quantity, store_expires_at
         FROM billing_orders WHERE store_key = ?`,
    )
    .bind(entitlement.storeKey)
    .first<StoreOrderRow>();
  if (existing?.workspace_id && existing.workspace_id !== input.workspaceId) {
    throw new StoreVerificationError("store_purchase_already_linked", 409);
  }
  if (existing && existing.payment_provider && existing.payment_provider !== entitlement.provider) {
    throw new StoreVerificationError("store_provider_mismatch", 409);
  }
  if (existing?.kind === "extra_seat" && entitlement.kind !== "extra_seat") {
    throw new StoreVerificationError("store_product_kind_mismatch", 409);
  }

  const now = nowIso();
  const amount = planDefForSlug(entitlement.planSlug);
  const amountCents = entitlement.kind === "extra_seat"
    ? (entitlement.cycle === "yearly" ? amount.extra_seat_price_yearly_cents : amount.extra_seat_price_monthly_cents)
    : entitlement.cycle === "yearly" ? amount.price_yearly_cents : amount.price_monthly_cents;
  const metadata = JSON.stringify({ source: "store", productId: entitlement.productId, cycle: entitlement.cycle });
  const merchantOid = await stableId(["store", entitlement.provider, entitlement.storeKey]);

  if (existing) {
    await db(env)
      .prepare(
        `UPDATE billing_orders
            SET merchant_oid = ?, plan_slug = ?, customer_email = ?, amount_minor = ?,
                currency = 'USD', status = 'completed', user_id = ?, workspace_id = ?,
                metadata_json = ?, completed_at = COALESCE(completed_at, ?),
                kind = ?, payment_provider = ?, entitlement_status = 'not_required',
                store_product_id = ?, store_cycle = ?, store_expires_at = ?,
                store_revoked_at = NULL, store_status = 'active', quantity = ?,
                updated_at = datetime('now')
          WHERE store_key = ?`,
      )
      .bind(
        merchantOid,
        entitlement.planSlug,
        input.userEmail,
        amountCents,
        input.userId,
        input.workspaceId,
        metadata,
        now,
        entitlement.kind,
        entitlement.provider,
        entitlement.productId,
        entitlement.cycle,
        entitlement.expiresAt,
        entitlement.quantity,
        entitlement.storeKey,
      )
      .run();
  } else {
    await db(env)
      .prepare(
        `INSERT INTO billing_orders (
           id, merchant_oid, plan_slug, customer_email, customer_name, amount_minor,
           currency, status, user_id, workspace_id, metadata_json, completed_at,
           kind, payment_provider, entitlement_status, store_key, store_product_id,
           store_cycle, store_expires_at, store_status, quantity
         ) VALUES (?, ?, ?, ?, '', ?, 'USD', 'completed', ?, ?, ?, ?, ?, ?,
                   'not_required', ?, ?, ?, ?, 'active', ?)`,
      )
      .bind(
        crypto.randomUUID(),
        merchantOid,
        entitlement.planSlug,
        input.userEmail,
        amountCents,
        input.userId,
        input.workspaceId,
        metadata,
        now,
        entitlement.kind,
        entitlement.provider,
        entitlement.storeKey,
        entitlement.productId,
        entitlement.cycle,
        entitlement.expiresAt,
        entitlement.quantity,
      )
      .run();
  }

  if (entitlement.kind === "plan") await applyStorePlan(env, input.workspaceId, entitlement);
  await syncStoreExtraSeats(env, input.workspaceId);
  const workspace = await db(env)
    .prepare(`SELECT plan_slug, extra_seats, store_extra_seats FROM workspaces WHERE id = ?`)
    .bind(input.workspaceId)
    .first<{ plan_slug: string | null; extra_seats: number | null; store_extra_seats: number | null }>();
  const extraSeats = Math.max(0, workspace?.extra_seats ?? 0) + Math.max(0, workspace?.store_extra_seats ?? 0);
  return {
    plan_slug: planDefForSlug(workspace?.plan_slug).slug,
    kind: entitlement.kind,
    cycle: entitlement.cycle,
    extra_seats: extraSeats,
    max_seats: await getEffectiveSeats(env, input.workspaceId),
    store_expires_at: entitlement.expiresAt,
  };
}

async function reapplyStorePlanAfterRevocation(env: Env, workspaceId: string, revokedPlan: string, revokedExpiry: string): Promise<void> {
  const replacement = await db(env)
    .prepare(
      `SELECT plan_slug, store_expires_at
         FROM billing_orders
        WHERE workspace_id = ? AND kind = 'plan' AND payment_provider IN ('apple', 'google')
          AND store_status = 'active' AND julianday(store_expires_at) > julianday('now')
        ORDER BY julianday(store_expires_at) DESC LIMIT 1`,
    )
    .bind(workspaceId)
    .first<{ plan_slug: string; store_expires_at: string }>();
  if (replacement) {
    await applyPlanToWorkspace(env, workspaceId, replacement.plan_slug, { endsAt: replacement.store_expires_at });
    return;
  }
  // Do not erase a newer web/PayTR entitlement while handling a store refund.
  const webOrder = await db(env)
    .prepare(
      `SELECT 1 FROM billing_orders
        WHERE workspace_id = ? AND payment_provider NOT IN ('apple', 'google')
          AND status = 'completed'
          AND julianday(COALESCE(completed_at, created_at)) >= julianday(?) LIMIT 1`,
    )
    .bind(workspaceId, revokedExpiry)
    .first();
  if (!webOrder) {
    await db(env)
      .prepare(
        `UPDATE workspaces SET plan_slug = 'free', subscription_started_at = NULL,
                subscription_ends_at = NULL, updated_at = datetime('now')
          WHERE id = ? AND plan_slug = ?`,
      )
      .bind(workspaceId, revokedPlan)
      .run();
  }
}

/** Applies a provider refund/revoke/expiry notification idempotently. */
export async function revokeStoreEntitlement(
  env: Env,
  provider: StoreProvider,
  storeKey: string,
  status: "revoked" | "expired" = "revoked",
): Promise<boolean> {
  const row = await db(env)
    .prepare(
      `SELECT id, workspace_id, plan_slug, kind, store_status, store_expires_at
         FROM billing_orders WHERE payment_provider = ? AND store_key = ?`,
    )
    .bind(provider, storeKey)
    .first<{
      id: string;
      workspace_id: string | null;
      plan_slug: string | null;
      kind: string | null;
      store_status: string | null;
      store_expires_at: string | null;
    }>();
  if (!row || row.store_status !== "active") return false;
  await db(env)
    .prepare(
      `UPDATE billing_orders
          SET store_status = ?, store_revoked_at = ?, status = 'cancelled', updated_at = datetime('now')
        WHERE id = ? AND store_status = 'active'`,
    )
    .bind(status, nowIso(), row.id)
    .run();
  if (!row.workspace_id) return true;
  if (row.kind === "plan" && row.plan_slug && row.store_expires_at) {
    await reapplyStorePlanAfterRevocation(env, row.workspace_id, row.plan_slug, row.store_expires_at);
  }
  await syncStoreExtraSeats(env, row.workspace_id);
  return true;
}

/** Scheduled safety net for missed Play/Apple callbacks. */
export async function expireStoreEntitlements(env: Env): Promise<void> {
  const rows = await db(env)
    .prepare(
      `SELECT payment_provider, store_key
         FROM billing_orders
        WHERE store_status = 'active' AND store_key IS NOT NULL
          AND store_expires_at IS NOT NULL AND julianday(store_expires_at) <= julianday('now')
        ORDER BY store_expires_at ASC LIMIT 200`,
    )
    .all<{ payment_provider: StoreProvider; store_key: string }>();
  for (const row of rows.results || []) {
    if (row.payment_provider === "apple" || row.payment_provider === "google") {
      await revokeStoreEntitlement(env, row.payment_provider, row.store_key, "expired");
    }
  }
}

import { Hono } from "hono";
import type { Context } from "hono";
import { zValidator } from "@hono/zod-validator";
import { z } from "zod";
import type { Env, AppVariables } from "../../env";
import { requireAuth } from "../../middleware/auth";
import { resolveWorkspaceForUser } from "../../lib/users";
import {
  fulfillStoreEntitlement,
  StoreVerificationError,
  storePurchaseVerificationConfigured,
  verifyApplePurchase,
  verifyGooglePurchase,
} from "../../lib/store_billing";
import { clientIpFromRequest, recordAudit } from "../../lib/audit";
import { db, nowIso, uuid } from "../../db/client";
import { rateLimit } from "../../middleware/rate-limit";
import {
  LEGAL_DOCUMENT_VERSIONS,
  LegalAcceptanceRequiredError,
  PREPAID_REFUND_DEADLINE_DAYS,
  SUBSCRIPTION_CANCELLATION_RESPONSE_DEADLINE_DAYS,
  recordLegalConsents,
  validateRequiredLegalAcceptance,
} from "../../lib/legal";
import {
  sendSubscriptionCancellationRequestNotificationEmail,
  sendSubscriptionCancellationRequestReceiptEmail,
} from "../../lib/email";

const billing = new Hono<{ Bindings: Env; Variables: AppVariables }>();

billing.use("*", requireAuth);

const storePurchaseLegalSchema = z.object({
  termsVersion: z.string().min(1).max(32),
  privacyNoticeVersion: z.string().min(1).max(32),
  subscriptionVersion: z.string().min(1).max(32),
  refundVersion: z.string().min(1).max(32),
  immediatePerformanceRequested: z.boolean(),
  // Binding store-purchase evidence must carry the Turkish master locale;
  // validateStorePurchaseLegal rejects an omitted/non-master locale.
  locale: z.string().min(2).max(10),
});

const subscriptionCancellationRequestSchema = z.object({
  requested_effect: z.enum(["end_of_period", "immediate"]),
  refund_requested: z.boolean().default(false),
  details: z.string().trim().max(2000).default(""),
  locale: z.string().min(2).max(10).optional(),
});

type SubscriptionCancellationRequestRow = {
  id: string;
  user_id: string | null;
  workspace_id: string | null;
  requester_email: string;
  plan_slug: string;
  requested_effect: string;
  refund_requested: number;
  details: string;
  locale: string;
  service_period_ends_at: string | null;
  status: string;
  received_at: string;
  processing_due_at: string;
  refund_due_at: string | null;
  processed_at: string | null;
  response_channel: string | null;
  response_summary: string | null;
  created_at: string;
  updated_at: string;
};

function addDaysIso(from: string, days: number): string {
  return new Date(new Date(from).getTime() + days * 24 * 60 * 60 * 1000).toISOString();
}

function cancellationRequestPayload(row: SubscriptionCancellationRequestRow) {
  return {
    id: row.id,
    user_id: row.user_id,
    workspace_id: row.workspace_id,
    requester_email: row.requester_email,
    plan_slug: row.plan_slug,
    requested_effect: row.requested_effect,
    refund_requested: Boolean(row.refund_requested),
    details: row.details,
    locale: row.locale,
    service_period_ends_at: row.service_period_ends_at,
    status: row.status,
    received_at: row.received_at,
    processing_due_at: row.processing_due_at,
    refund_due_at: row.refund_due_at,
    processed_at: row.processed_at,
    response_channel: row.response_channel,
    response_summary: row.response_summary,
    created_at: row.created_at,
    updated_at: row.updated_at,
  };
}

/** Authenticated online cancellation/refund intake for the SaaS plan. */
billing.post(
  "/subscription-cancellation-requests",
  rateLimit({ limit: 5, windowSeconds: 3600, keyPrefix: "billing:subscription-cancellation" }),
  zValidator("json", subscriptionCancellationRequestSchema),
  async (c) => {
    const user = c.get("user");
    const body = c.req.valid("json");
    const account = await resolveWorkspaceForUser(c.env, user.id, c.get("workspaceId"));
    if (!account?.workspace_id) return c.json({ error: "workspace_not_found" }, 404);
    if (account.role !== "owner") {
      return c.json({ error: "workspace_owner_required" }, 403);
    }
    if (account.plan_slug === "free") {
      return c.json({ error: "no_paid_subscription" }, 409);
    }

    const existing = await db(c.env)
      .prepare(
        `SELECT id, user_id, workspace_id, requester_email, plan_slug,
                requested_effect, refund_requested, details, locale, service_period_ends_at,
                status, received_at, processing_due_at, refund_due_at, processed_at,
                response_channel, response_summary, created_at, updated_at
           FROM subscription_cancellation_requests
          WHERE workspace_id = ?
            AND status IN ('received', 'in_review', 'accepted', 'scheduled')
          ORDER BY received_at DESC
          LIMIT 1`,
      )
      .bind(account.workspace_id)
      .first<SubscriptionCancellationRequestRow>();
    if (existing) {
      return c.json({
        error: "cancellation_request_already_exists",
        request: cancellationRequestPayload(existing),
      }, 409);
    }

    const receivedAt = nowIso();
    const processingDueAt = addDaysIso(receivedAt, SUBSCRIPTION_CANCELLATION_RESPONSE_DEADLINE_DAYS);
    const refundDueAt = body.refund_requested
      ? addDaysIso(receivedAt, PREPAID_REFUND_DEADLINE_DAYS)
      : null;
    const id = uuid();

    await db(c.env)
      .prepare(
        `INSERT INTO subscription_cancellation_requests (
           id, user_id, workspace_id, requester_email, plan_slug,
           requested_effect, refund_requested, details, locale, service_period_ends_at,
           status, received_at, processing_due_at, refund_due_at, ip, user_agent
         ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'received', ?, ?, ?, ?, ?)`,
      )
      .bind(
        id,
        user.id,
        account.workspace_id,
        user.email,
        account.plan_slug,
        body.requested_effect,
        body.refund_requested ? 1 : 0,
        body.details,
        body.locale || "tr",
        account.subscription_ends_at,
        receivedAt,
        processingDueAt,
        refundDueAt,
        clientIpFromRequest(c.req),
        c.req.header("User-Agent") ?? null,
      )
      .run();

    await recordAudit(c.env, {
      workspaceId: account.workspace_id,
      actorUserId: user.id,
      actorEmail: user.email,
      action: "billing.subscription_cancellation_request",
      entityType: "subscription_cancellation_request",
      entityId: id,
      metadata: {
        planSlug: account.plan_slug,
        requestedEffect: body.requested_effect,
        refundRequested: body.refund_requested,
        processingDueAt,
        refundDueAt,
      },
      ip: clientIpFromRequest(c.req),
      userAgent: c.req.header("User-Agent") ?? null,
    });

    const notification = {
      id,
      requesterEmail: user.email,
      planSlug: account.plan_slug,
      requestedEffect: body.requested_effect,
      refundRequested: body.refund_requested,
      details: body.details,
      servicePeriodEndsAt: account.subscription_ends_at,
      receivedAt,
      processingDueAt,
      refundDueAt,
    };

    try {
      const result = await sendSubscriptionCancellationRequestNotificationEmail(c.env, notification);
      await recordAudit(c.env, {
        workspaceId: account.workspace_id,
        actorUserId: user.id,
        actorEmail: user.email,
        action: "billing.subscription_cancellation_request.notification_sent",
        entityType: "subscription_cancellation_request",
        entityId: id,
        metadata: { messageId: result.messageId },
        ip: clientIpFromRequest(c.req),
        userAgent: c.req.header("User-Agent") ?? null,
      });
    } catch (error) {
      console.error(
        "subscription cancellation notification failed",
        error instanceof Error ? error.message : error,
      );
    }

    try {
      const result = await sendSubscriptionCancellationRequestReceiptEmail(c.env, notification);
      await recordAudit(c.env, {
        workspaceId: account.workspace_id,
        actorUserId: user.id,
        actorEmail: user.email,
        action: "billing.subscription_cancellation_request.receipt_sent",
        entityType: "subscription_cancellation_request",
        entityId: id,
        metadata: { messageId: result.messageId },
        ip: clientIpFromRequest(c.req),
        userAgent: c.req.header("User-Agent") ?? null,
      });
    } catch (error) {
      console.error(
        "subscription cancellation receipt failed",
        error instanceof Error ? error.message : error,
      );
    }

    const request: SubscriptionCancellationRequestRow = {
      id,
      user_id: user.id,
      workspace_id: account.workspace_id,
      requester_email: user.email,
      plan_slug: account.plan_slug,
      requested_effect: body.requested_effect,
      refund_requested: body.refund_requested ? 1 : 0,
      details: body.details,
      locale: body.locale || "tr",
      service_period_ends_at: account.subscription_ends_at,
      status: "received",
      received_at: receivedAt,
      processing_due_at: processingDueAt,
      refund_due_at: refundDueAt,
      processed_at: null,
      response_channel: null,
      response_summary: null,
      created_at: receivedAt,
      updated_at: receivedAt,
    };
    return c.json({ ok: true, request: cancellationRequestPayload(request) }, 201);
  },
);

billing.get("/subscription-cancellation-requests", async (c) => {
  const user = c.get("user");
  const { results } = await db(c.env)
    .prepare(
      `SELECT id, user_id, workspace_id, requester_email, plan_slug,
              requested_effect, refund_requested, details, locale, service_period_ends_at,
              status, received_at, processing_due_at, refund_due_at, processed_at,
              response_channel, response_summary, created_at, updated_at
         FROM subscription_cancellation_requests
        WHERE user_id = ?
        ORDER BY received_at DESC
        LIMIT 50`,
    )
    .bind(user.id)
    .all<SubscriptionCancellationRequestRow>();
  return c.json({ requests: (results || []).map(cancellationRequestPayload) });
});

function validateStorePurchaseLegal(input: z.infer<typeof storePurchaseLegalSchema>): void {
  validateRequiredLegalAcceptance({
    termsVersion: input.termsVersion,
    privacyNoticeVersion: input.privacyNoticeVersion,
    locale: input.locale,
  });
  if (input.subscriptionVersion !== LEGAL_DOCUMENT_VERSIONS.subscription) {
    throw new LegalAcceptanceRequiredError("Current subscription terms must be accepted.");
  }
  if (input.refundVersion !== LEGAL_DOCUMENT_VERSIONS.refund) {
    throw new LegalAcceptanceRequiredError("The current cancellation and refund policy must be acknowledged.");
  }
}

async function recordStorePurchaseLegal(
  c: Context<{ Bindings: Env; Variables: AppVariables }>,
  input: z.infer<typeof storePurchaseLegalSchema>,
  source: string,
) {
  await recordLegalConsents(
    c.env,
    {
      userId: c.get("user").id,
      locale: input.locale,
      source,
      ip: clientIpFromRequest(c.req),
      userAgent: c.req.header("User-Agent") ?? null,
    },
    [
      { purpose: "terms.acceptance", action: "accepted", documentKey: "terms", documentVersion: input.termsVersion },
      { purpose: "privacy.notice", action: "acknowledged", documentKey: "privacy_notice", documentVersion: input.privacyNoticeVersion },
      { purpose: "subscription.acceptance", action: "accepted", documentKey: "subscription", documentVersion: input.subscriptionVersion },
      { purpose: "refund_policy.acknowledgement", action: "acknowledged", documentKey: "refund", documentVersion: input.refundVersion },
      ...(input.immediatePerformanceRequested
        ? [{ purpose: "digital_service.immediate_performance", action: "accepted" as const, documentKey: "refund" as const, documentVersion: input.refundVersion }]
        : []),
    ],
  );
}

function storeVerificationError(c: Context<{ Bindings: Env; Variables: AppVariables }>, error: unknown) {
  if (error instanceof StoreVerificationError) {
    return c.json({ error: error.code }, error.httpStatus);
  }
  console.error("store purchase fulfillment failed", error instanceof Error ? error.message : error);
  return c.json({ error: "store_verification_failed" }, 502);
}

// StoreKit2 fulfillment. Product and plan are derived from the verified Apple
// transaction; client planId is retained only for old client compatibility.
const appleVerifySchema = z.object({
  transactionId: z.string().min(1),
  originalTransactionId: z.string().optional(),
  productId: z.string().min(1).optional(),
  planId: z.string().min(1).optional(),
}).merge(storePurchaseLegalSchema);

billing.post("/apple/verify", zValidator("json", appleVerifySchema), async (c) => {
  const authUser = c.get("user");
  const body = c.req.valid("json");
  const { transactionId, originalTransactionId } = body;

  if (!storePurchaseVerificationConfigured(c.env, "apple")) {
    return c.json({ error: "store_purchase_verification_not_configured" }, 503);
  }

  const account = await resolveWorkspaceForUser(c.env, authUser.id, c.get("workspaceId"));
  if (!account?.workspace_id) {
    return c.json({ error: "workspace_not_found" }, 404);
  }
  if (account.role !== "owner" && account.role !== "admin") {
    return c.json({ error: "workspace_billing_admin_required" }, 403);
  }

  try {
    const verified = await verifyApplePurchase(c.env, {
      transactionId,
      originalTransactionId,
      userId: authUser.id,
    });
    if (body.productId && body.productId !== verified.productId) {
      return c.json({ error: "store_product_mismatch" }, 400);
    }
    validateStorePurchaseLegal(body);
    await recordStorePurchaseLegal(c, body, "billing-apple");
    const fulfilled = await fulfillStoreEntitlement(c.env, {
      userId: authUser.id,
      userEmail: authUser.email,
      workspaceId: account.workspace_id,
      workspacePlan: account.plan_slug,
      role: account.role,
    }, verified);

    await recordAudit(c.env, {
      workspaceId: account.workspace_id,
      actorUserId: authUser.id,
      actorEmail: authUser.email,
      action: "billing.apple_verify",
      entityType: "workspace",
      entityId: account.workspace_id,
      metadata: {
        productId: verified.productId,
        planSlug: verified.planSlug,
        kind: verified.kind,
        cycle: verified.cycle,
      },
      ip: clientIpFromRequest(c.req),
      userAgent: c.req.header("User-Agent") ?? null,
    });
    return c.json({ ok: true, ...fulfilled });
  } catch (error) {
    if (error instanceof LegalAcceptanceRequiredError) {
      return c.json({ error: "legal_acceptance_required", code: error.code }, 409);
    }
    return storeVerificationError(c, error);
  }
});

// Google Play Billing fulfillment. The plan is never activated from a
// client-supplied purchase token alone; Play Developer API verification must
// be configured first.
const googleVerifySchema = z.object({
  purchaseToken: z.string().min(1),
  productId: z.string().min(1).optional(),
  planId: z.string().min(1).optional(),
}).merge(storePurchaseLegalSchema);

billing.post("/google/verify", zValidator("json", googleVerifySchema), async (c) => {
  const authUser = c.get("user");
  const body = c.req.valid("json");
  const { purchaseToken, productId } = body;

  if (!storePurchaseVerificationConfigured(c.env, "google")) {
    return c.json({ error: "store_purchase_verification_not_configured" }, 503);
  }

  const account = await resolveWorkspaceForUser(c.env, authUser.id, c.get("workspaceId"));
  if (!account?.workspace_id) {
    return c.json({ error: "workspace_not_found" }, 404);
  }
  if (account.role !== "owner" && account.role !== "admin") {
    return c.json({ error: "workspace_billing_admin_required" }, 403);
  }

  try {
    const verified = await verifyGooglePurchase(c.env, {
      purchaseToken,
      productId,
      userId: authUser.id,
    });
    if (productId && productId !== verified.productId) {
      return c.json({ error: "store_product_mismatch" }, 400);
    }
    validateStorePurchaseLegal(body);
    await recordStorePurchaseLegal(c, body, "billing-google");
    const fulfilled = await fulfillStoreEntitlement(c.env, {
      userId: authUser.id,
      userEmail: authUser.email,
      workspaceId: account.workspace_id,
      workspacePlan: account.plan_slug,
      role: account.role,
    }, verified);

    await recordAudit(c.env, {
      workspaceId: account.workspace_id,
      actorUserId: authUser.id,
      actorEmail: authUser.email,
      action: "billing.google_verify",
      entityType: "workspace",
      entityId: account.workspace_id,
      metadata: {
        productId: verified.productId,
        planSlug: verified.planSlug,
        kind: verified.kind,
        cycle: verified.cycle,
      },
      ip: clientIpFromRequest(c.req),
      userAgent: c.req.header("User-Agent") ?? null,
    });
    return c.json({ ok: true, ...fulfilled });
  } catch (error) {
    if (error instanceof LegalAcceptanceRequiredError) {
      return c.json({ error: "legal_acceptance_required", code: error.code }, 409);
    }
    return storeVerificationError(c, error);
  }
});

export default billing;

export { subscriptionCancellationRequestSchema };

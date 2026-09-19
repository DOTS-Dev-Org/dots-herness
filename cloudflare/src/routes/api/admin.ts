import { Hono } from "hono";
import { zValidator } from "@hono/zod-validator";
import { z } from "zod";
import type { Env, AppVariables } from "../../env";
import { db, normalizeEmail, nowIso } from "../../db/client";
import { getCompletedOrderTotals, getPlanRevenue } from "../../lib/billing";
import { requireAuth, requireAdmin } from "../../middleware/auth";
import { clientIpFromRequest, recordAudit } from "../../lib/audit";
import {
  isCurrentUserKeyEncryption,
  resolveUserKeyValue,
  USER_KEY_ENC_PREFIX,
} from "../../lib/user_key_crypto";
import {
  sendLegalDataRequestResponseEmail,
  sendSubscriptionCancellationDecisionEmail,
} from "../../lib/email";

const admin = new Hono<{ Bindings: Env; Variables: AppVariables }>();

admin.use("*", requireAuth, requireAdmin);

const adminDataRequestUpdateSchema = z.object({
  status: z.enum(["received", "identity_pending", "in_review", "responded", "rejected", "closed"]).optional(),
  identity_status: z.enum(["pending", "verified", "failed", "not_required"]).optional(),
  response_channel: z.string().trim().max(80).optional().nullable(),
  response_summary: z.string().trim().max(5000).optional().nullable(),
}).refine((value) => Object.values(value).some((item) => item !== undefined), {
  message: "At least one status or response field is required",
});

const adminCancellationUpdateSchema = z.object({
  status: z.enum(["received", "in_review", "accepted", "scheduled", "completed", "rejected", "closed"]).optional(),
  response_channel: z.string().trim().max(80).optional().nullable(),
  response_summary: z.string().trim().max(5000).optional().nullable(),
}).refine((value) => Object.values(value).some((item) => item !== undefined), {
  message: "At least one status or response field is required",
});

const adminUserStatusSchema = z.object({
  status: z.enum(["active", "inactive"]),
});

admin.patch(
  "/users/:id/status",
  zValidator("json", adminUserStatusSchema),
  async (c) => {
    const targetUserId = c.req.param("id");
    const { status } = c.req.valid("json");
    const actor = c.get("user");
    if (actor.id === targetUserId && status === "inactive") {
      return c.json({ error: "Cannot deactivate your own account" }, 400);
    }

    const target = await db(c.env)
      .prepare("SELECT id, email, status FROM users WHERE id = ?")
      .bind(targetUserId)
      .first<{ id: string; email: string; status: string | null }>();
    if (!target) return c.json({ error: "user_not_found" }, 404);

    await db(c.env).batch([
      db(c.env)
        .prepare("UPDATE users SET status = ?, updated_at = NOW() WHERE id = ?")
        .bind(status, targetUserId),
      db(c.env)
        .prepare("DELETE FROM refresh_tokens WHERE user_id = ?")
        .bind(targetUserId),
    ]);

    await recordAudit(c.env, {
      actorUserId: actor.id,
      actorEmail: actor.email,
      action: "admin.user_status.update",
      entityType: "user",
      entityId: targetUserId,
      metadata: { from: target.status ?? null, to: status },
      ip: clientIpFromRequest(c.req),
      userAgent: c.req.header("User-Agent") ?? null,
    });

    return c.json({ ok: true, user_id: targetUserId, status });
  },
);

admin.get("/legal-data-requests", async (c) => {
  const status = c.req.query("status");
  const params: unknown[] = [];
  let sql = `SELECT id, user_id, requester_email, request_type, details, locale,
                    status, identity_status, received_at, due_at, responded_at,
                    response_channel, response_summary, created_at, updated_at
               FROM legal_data_requests`;
  if (status) {
    sql += " WHERE status = ?";
    params.push(status);
  }
  sql += " ORDER BY due_at ASC, received_at ASC LIMIT 200";
  const { results } = await db(c.env).prepare(sql).bind(...params).all();
  return c.json({ requests: results || [] });
});

admin.patch(
  "/legal-data-requests/:id",
  zValidator("json", adminDataRequestUpdateSchema),
  async (c) => {
    const id = c.req.param("id");
    const body = c.req.valid("json");
    const current = await db(c.env)
      .prepare(
        `SELECT id, requester_email, request_type, status, identity_status,
                response_channel, response_summary, responded_at
           FROM legal_data_requests
          WHERE id = ?`,
      )
      .bind(id)
      .first<{
        id: string;
        requester_email: string;
        request_type: string;
        status: string;
        identity_status: string;
        response_channel: string | null;
        response_summary: string | null;
        responded_at: string | null;
      }>();
    if (!current) return c.json({ error: "legal_data_request_not_found" }, 404);

    const nextStatus = body.status ?? current.status;
    const nextIdentityStatus = body.identity_status ?? current.identity_status;
    const nextResponseChannel = body.response_channel === undefined ? current.response_channel : body.response_channel;
    const nextResponseSummary = body.response_summary === undefined ? current.response_summary : body.response_summary;
    if (nextStatus === "responded" && !["verified", "not_required"].includes(nextIdentityStatus)) {
      return c.json({ error: "identity_verification_required_before_response" }, 409);
    }
    if ((nextStatus === "responded" || nextStatus === "rejected") && !nextResponseSummary?.trim()) {
      return c.json({ error: "response_summary_required" }, 400);
    }
    if (nextStatus === "responded" && !nextResponseChannel?.trim()) {
      return c.json({ error: "response_channel_required" }, 400);
    }
    const respondedAt = nextStatus === "responded" ? (current.responded_at || nowIso()) : null;

    await db(c.env)
      .prepare(
        `UPDATE legal_data_requests
            SET status = ?, identity_status = ?, response_channel = ?,
                response_summary = ?, responded_at = ?, updated_at = ?
          WHERE id = ?`,
      )
      .bind(
        nextStatus,
        nextIdentityStatus,
        nextResponseChannel ?? null,
        nextResponseSummary ?? null,
        respondedAt,
        nowIso(),
        id,
      )
      .run();

    const actor = c.get("user");
    await recordAudit(c.env, {
      actorUserId: actor.id,
      actorEmail: actor.email,
      action: "legal.data_request",
      entityType: "legal_data_request",
      entityId: id,
      metadata: {
        status: nextStatus,
        identityStatus: nextIdentityStatus,
        responseChannel: nextResponseChannel ?? null,
      },
      ip: clientIpFromRequest(c.req),
      userAgent: c.req.header("User-Agent") ?? null,
    });

    if (
      ["responded", "rejected"].includes(nextStatus) &&
      nextResponseChannel?.trim() &&
      nextResponseSummary?.trim() &&
      (current.status !== nextStatus || current.response_summary !== nextResponseSummary)
    ) {
      try {
        const emailResult = await sendLegalDataRequestResponseEmail(c.env, {
          id,
          requesterEmail: current.requester_email,
          requestType: current.request_type,
          status: nextStatus,
          responseChannel: nextResponseChannel,
          responseSummary: nextResponseSummary,
          respondedAt: respondedAt || nowIso(),
        });
        await recordAudit(c.env, {
          actorUserId: actor.id,
          actorEmail: actor.email,
          action: "legal.data_request.response_sent",
          entityType: "legal_data_request",
          entityId: id,
          metadata: { messageId: emailResult.messageId, status: nextStatus },
          ip: clientIpFromRequest(c.req),
          userAgent: c.req.header("User-Agent") ?? null,
        });
      } catch (error) {
        console.error(
          "legal data request response email failed",
          error instanceof Error ? error.message : error,
        );
      }
    }

    return c.json({ ok: true, request_id: id, status: nextStatus, identity_status: nextIdentityStatus });
  },
);

admin.get("/subscription-cancellation-requests", async (c) => {
  const status = c.req.query("status");
  const params: unknown[] = [];
  let sql = `SELECT id, user_id, workspace_id, requester_email, plan_slug,
                    requested_effect, refund_requested, details, locale, service_period_ends_at,
                    status, received_at, processing_due_at, refund_due_at, processed_at,
                    response_channel, response_summary, created_at, updated_at
               FROM subscription_cancellation_requests`;
  if (status) {
    sql += " WHERE status = ?";
    params.push(status);
  }
  sql += " ORDER BY processing_due_at ASC, received_at ASC LIMIT 200";
  const { results } = await db(c.env).prepare(sql).bind(...params).all();
  return c.json({ requests: results || [] });
});

admin.patch(
  "/subscription-cancellation-requests/:id",
  zValidator("json", adminCancellationUpdateSchema),
  async (c) => {
    const id = c.req.param("id");
    const body = c.req.valid("json");
    const current = await db(c.env)
      .prepare(
        `SELECT id, requester_email, requested_effect, refund_requested,
                status, response_channel, response_summary, processed_at
           FROM subscription_cancellation_requests
          WHERE id = ?`,
      )
      .bind(id)
      .first<{
        id: string;
        requester_email: string;
        requested_effect: string;
        refund_requested: number;
        status: string;
        response_channel: string | null;
        response_summary: string | null;
        processed_at: string | null;
      }>();
    if (!current) return c.json({ error: "subscription_cancellation_request_not_found" }, 404);

    const nextStatus = body.status ?? current.status;
    const nextResponseChannel = body.response_channel === undefined ? current.response_channel : body.response_channel;
    const nextResponseSummary = body.response_summary === undefined ? current.response_summary : body.response_summary;
    if (["accepted", "scheduled", "completed", "rejected"].includes(nextStatus) && !nextResponseSummary?.trim()) {
      return c.json({ error: "response_summary_required" }, 400);
    }
    if (["completed", "rejected"].includes(nextStatus) && !nextResponseChannel?.trim()) {
      return c.json({ error: "response_channel_required" }, 400);
    }
    const processedAt = nextStatus === "completed" ? (current.processed_at || nowIso()) : null;

    await db(c.env)
      .prepare(
        `UPDATE subscription_cancellation_requests
            SET status = ?, response_channel = ?, response_summary = ?,
                processed_at = ?, updated_at = ?
          WHERE id = ?`,
      )
      .bind(
        nextStatus,
        nextResponseChannel ?? null,
        nextResponseSummary ?? null,
        processedAt,
        nowIso(),
        id,
      )
      .run();

    const actor = c.get("user");
    await recordAudit(c.env, {
      actorUserId: actor.id,
      actorEmail: actor.email,
      action: "billing.subscription_cancellation_request.update",
      entityType: "subscription_cancellation_request",
      entityId: id,
      metadata: {
        status: nextStatus,
        responseChannel: nextResponseChannel ?? null,
      },
      ip: clientIpFromRequest(c.req),
      userAgent: c.req.header("User-Agent") ?? null,
    });

    if (
      ["accepted", "scheduled", "completed", "rejected"].includes(nextStatus) &&
      nextResponseChannel?.trim() &&
      nextResponseSummary?.trim() &&
      (current.status !== nextStatus || current.response_summary !== nextResponseSummary)
    ) {
      try {
        const emailResult = await sendSubscriptionCancellationDecisionEmail(c.env, {
          id,
          requesterEmail: current.requester_email,
          requestedEffect: current.requested_effect,
          refundRequested: Boolean(current.refund_requested),
          status: nextStatus,
          responseChannel: nextResponseChannel,
          responseSummary: nextResponseSummary,
          processedAt,
        });
        await recordAudit(c.env, {
          actorUserId: actor.id,
          actorEmail: actor.email,
          action: "billing.subscription_cancellation_request.response_sent",
          entityType: "subscription_cancellation_request",
          entityId: id,
          metadata: { messageId: emailResult.messageId, status: nextStatus },
          ip: clientIpFromRequest(c.req),
          userAgent: c.req.header("User-Agent") ?? null,
        });
      } catch (error) {
        console.error(
          "subscription cancellation decision email failed",
          error instanceof Error ? error.message : error,
        );
      }
    }

    return c.json({ ok: true, request_id: id, status: nextStatus });
  },
);

/**
 * One-shot: encrypt legacy plaintext user_connections.key_value rows.
 * Safe to re-run (skips rows already using the current enc:v2 format).
 */
admin.post("/encrypt-user-keys", async (c) => {
  const { results } = await db(c.env)
    .prepare("SELECT id, user_id, user_email, key_value FROM user_connections")
    .all<{ id: string; user_id: string | null; user_email: string; key_value: string }>();

  let encrypted = 0;
  let skipped = 0;
  let failed = 0;

  for (const row of results || []) {
    if (row.key_value === "" || isCurrentUserKeyEncryption(row.key_value)) {
      skipped++;
      continue;
    }
    try {
      if (!row.user_id) throw new Error("user_id_missing");
      await resolveUserKeyValue(c.env, row.user_id, row.user_email, row.key_value, {
        reencryptKeyId: row.id,
        db: db(c.env),
      });
      encrypted++;
    } catch {
      failed++;
    }
  }

  return c.json({
    ok: failed === 0,
    prefix: USER_KEY_ENC_PREFIX,
    total: (results || []).length,
    encrypted,
    skipped,
    failed,
  });
});

/** Aggregated user_connections counts — personal REST always enforces RLS. */
admin.get("/key-counts", async (c) => {
  const { results: byEmailRows } = await db(c.env)
    .prepare(
      `SELECT u.email AS email, COUNT(*) AS n
         FROM user_connections uc
         JOIN users u ON u.id = uc.user_id
        GROUP BY uc.user_id, u.email`
    )
    .all<{ email: string; n: number }>();

  const { results: byProviderRows } = await db(c.env)
    .prepare(
      `SELECT provider, COUNT(*) AS n
         FROM user_connections
        GROUP BY provider`
    )
    .all<{ provider: string; n: number }>();

  const by_email: Record<string, number> = {};
  for (const row of byEmailRows || []) {
    by_email[row.email] = Number(row.n) || 0;
  }
  const by_provider: Record<string, number> = {};
  for (const row of byProviderRows || []) {
    by_provider[row.provider] = Number(row.n) || 0;
  }

  return c.json({ by_email, by_provider });
});

/** List another user's keys for admin user detail (REST user_connections is always self-scoped). */
admin.get("/users/:email/keys", async (c) => {
  const email = normalizeEmail(c.req.param("email") || "");
  if (!email) return c.json({ error: "email required" }, 400);

  const target = await db(c.env)
    .prepare("SELECT id FROM users WHERE email = ?")
    .bind(email)
    .first<{ id: string }>();
  if (!target) return c.json({ error: "user_not_found" }, 404);

  const { results } = await db(c.env)
    .prepare(
      `SELECT id, provider, name, key_masked, created_at
         FROM user_connections
        WHERE user_id = ?
        ORDER BY created_at DESC`
    )
    .bind(target.id)
    .all<{
      id: string;
      provider: string;
      name: string;
      key_masked: string;
      created_at: string;
    }>();

  return c.json({ keys: results || [] });
});

admin.get("/stats", async (c) => {
  const total = await db(c.env).prepare("SELECT COUNT(*) AS n FROM users").first<{ n: number }>();
  const active = await db(c.env).prepare("SELECT COUNT(*) AS n FROM users WHERE status = 'active'").first<{ n: number }>();
  const { LISTED_PLAN_SLUGS } = await import("../../lib/plan_features");
  const plans = { n: LISTED_PLAN_SLUGS.length };
  const totalProviders = await db(c.env).prepare("SELECT COUNT(*) AS n FROM providers").first<{ n: number }>();
  const activeProviders = await db(c.env).prepare("SELECT COUNT(*) AS n FROM providers WHERE status = 'active'").first<{ n: number }>();

  const totalOrders = await getCompletedOrderTotals(c.env);
  const monthlyOrders = await getCompletedOrderTotals(c.env, { days: 30 });
  const planRevenue = await getPlanRevenue(c.env);

  const activePaidPlans = await db(c.env)
    .prepare("SELECT COUNT(*) AS n FROM workspaces WHERE plan_slug IS NOT NULL AND plan_slug != 'free'")
    .first<{ n: number }>();

  const { results: planDist } = await db(c.env)
    .prepare(
      `SELECT COALESCE(a.plan_slug, 'free') AS plan, COUNT(am.user_id) AS count
         FROM workspaces a
         LEFT JOIN workspace_members am ON am.workspace_id = a.id AND am.role = 'owner'
        GROUP BY COALESCE(a.plan_slug, 'free')`
    )
    .all();

  const { results: recentUsers } = await db(c.env)
    .prepare(
      `SELECT id, email, name, surname, role, plan, status, created_at
         FROM users ORDER BY created_at DESC LIMIT 10`
    )
    .all();

  return c.json({
    total_users: total?.n || 0,
    active_users: active?.n || 0,
    total_revenue: totalOrders.order_count === 0 ? 0 : totalOrders.usd,
    total_revenue_tl: totalOrders.tl,
    monthly_revenue: monthlyOrders.order_count === 0 ? 0 : monthlyOrders.usd,
    monthly_revenue_tl: monthlyOrders.tl,
    completed_orders_total: totalOrders.order_count,
    completed_orders_monthly: monthlyOrders.order_count,
    usd_try: monthlyOrders.usd_try,
    active_paid_plans: activePaidPlans?.n || 0,
    total_plans: plans?.n || 0,
    total_providers: totalProviders?.n || 0,
    active_providers: activeProviders?.n || 0,
    plan_distribution: planDist || [],
    plan_revenue: planRevenue.by_plan,
    revenue_by_provider: planRevenue.by_provider,
    recent_users: recentUsers || [],
  });
});

export default admin;

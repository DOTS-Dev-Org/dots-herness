import type { Env } from "../env";
import { db, nowIso } from "../db/client";

export type OrderFulfillKind = "plan" | "extra_seat" | "gift" | "upgrade" | "proration";

function mapOrderKind(orderKind: string | null | undefined): OrderFulfillKind {
  const k = (orderKind || "new").toLowerCase();
  if (k === "extra_seat" || k === "seat") return "extra_seat";
  if (k === "gift") return "gift";
  if (k === "upgrade") return "upgrade";
  if (k === "proration") return "proration";
  return "plan";
}

function quantityFromMetadata(metadataJson: string | null | undefined): number {
  if (!metadataJson) return 1;
  try {
    const meta = JSON.parse(metadataJson) as { quantity?: number };
    if (meta.quantity && meta.quantity > 0) return meta.quantity;
  } catch {
    /* ignore */
  }
  return 1;
}

/** Apply paid plan entitlement on workspace (snapshot). */
export async function applyPlanToWorkspace(
  env: Env,
  workspaceId: string,
  planSlug: string,
  opts?: { cycleDays?: number; startedAt?: string | null; endsAt?: string | null }
): Promise<void> {
  const { normalizePlanSlug } = await import("./plan_features");
  const slug = normalizePlanSlug(planSlug);
  const isFree = slug === "free";
  const cycleDays = opts?.cycleDays ?? 30;
  const started = isFree ? null : (opts?.startedAt ?? new Date().toISOString());
  const ends = isFree
    ? null
    : (opts?.endsAt ?? new Date(Date.now() + cycleDays * 86400000).toISOString());

  await db(env)
    .prepare(
      `UPDATE workspaces
          SET plan_slug = ?,
              subscription_started_at = ?,
              subscription_ends_at = ?,
              store_extra_seats = CASE WHEN ? = 'team' THEN store_extra_seats ELSE 0 END,
              updated_at = datetime('now')
        WHERE id = ?`
    )
    .bind(slug, started, ends, slug, workspaceId)
    .run();
}

/** Increment seat snapshot for an extra_seat order. */
export async function addExtraSeats(
  env: Env,
  workspaceId: string,
  quantity: number
): Promise<void> {
  const q = Math.max(1, quantity);
  await db(env)
    .prepare(
      `UPDATE workspaces
          SET extra_seats = COALESCE(extra_seats, 0) + ?,
              updated_at = datetime('now')
        WHERE id = ?`
    )
    .bind(q, workspaceId)
    .run();
}

type DueEntitlementRow = {
  merchant_oid: string;
  workspace_id: string | null;
  plan_slug: string | null;
  kind: string | null;
  metadata_json: string | null;
  updated_at: string;
};

/** Applies the workspace change and marks its order fulfilled in one D1 transaction. */
async function applyAndCompletePaidOrder(env: Env, merchantOid: string, order: DueEntitlementRow): Promise<void> {
  if (!order.workspace_id) throw new Error("entitlement_workspace_missing");

  const database = db(env);
  const statements: D1PreparedStatement[] = [];
  const kind = mapOrderKind(order.kind);

  if (kind === "extra_seat") {
    statements.push(
      database
        .prepare(
          `UPDATE workspaces
              SET extra_seats = COALESCE(extra_seats, 0) + ?,
                  updated_at = datetime('now')
            WHERE id = ?
              AND EXISTS (
                SELECT 1 FROM billing_orders
                 WHERE merchant_oid = ?
                   AND status = 'completed'
                   AND entitlement_status = 'processing'
                   AND updated_at = ?
              )`,
        )
        .bind(quantityFromMetadata(order.metadata_json), order.workspace_id, merchantOid, order.updated_at),
    );
  } else if (order.plan_slug && ["plan", "upgrade", "gift", "proration"].includes(kind)) {
    const { normalizePlanSlug } = await import("./plan_features");
    const slug = normalizePlanSlug(order.plan_slug);
    const isFree = slug === "free";
    const started = isFree ? null : new Date().toISOString();
    const ends = isFree ? null : new Date(Date.now() + 30 * 86400000).toISOString();
    statements.push(
      database
        .prepare(
          `UPDATE workspaces
              SET plan_slug = ?,
                  subscription_started_at = ?,
                  subscription_ends_at = ?,
                  store_extra_seats = CASE WHEN ? = 'team' THEN store_extra_seats ELSE 0 END,
                  updated_at = datetime('now')
            WHERE id = ?
              AND EXISTS (
                SELECT 1 FROM billing_orders
                 WHERE merchant_oid = ?
                   AND status = 'completed'
                   AND entitlement_status = 'processing'
                   AND updated_at = ?
              )`,
        )
        .bind(slug, started, ends, slug, order.workspace_id, merchantOid, order.updated_at),
    );
  }

  statements.push(
    database
      .prepare(
        `UPDATE billing_orders
            SET entitlement_status = 'fulfilled',
                entitlement_activated_at = ?,
                entitlement_last_error = NULL,
                updated_at = datetime('now')
          WHERE merchant_oid = ?
            AND status = 'completed'
            AND entitlement_status = 'processing'
            AND updated_at = ?
            AND EXISTS (SELECT 1 FROM workspaces WHERE id = ?)`,
      )
      .bind(nowIso(), merchantOid, order.updated_at, order.workspace_id),
  );

  const results = await database.batch(statements);
  for (const result of results) {
    if ((result.meta?.changes ?? 0) !== 1) {
      throw new Error("entitlement_claim_lost_or_workspace_missing");
    }
  }
}

/**
 * Claims and applies one paid order whose entitlement date has arrived.
 * Payment completion and service activation are deliberately separate: an
 * unchecked immediate-performance option waits until the withdrawal period,
 * while a checked option is due immediately. The claim makes callback and
 * scheduled retries idempotent.
 */
export async function fulfillDuePaidOrder(
  env: Env,
  merchantOid: string,
): Promise<"fulfilled" | "not_due" | "not_claimed" | "failed"> {
  const claimTimestamp = nowIso();
  const claim = await db(env)
    .prepare(
      `UPDATE billing_orders
          SET entitlement_status = 'processing',
              updated_at = ?
        WHERE merchant_oid = ?
          AND status = 'completed'
          AND entitlement_status = 'pending'
          AND (
            entitlement_available_at IS NULL
            OR entitlement_available_at <= datetime('now')
          )`,
    )
    .bind(claimTimestamp, merchantOid)
    .run();

  if ((claim.meta?.changes ?? 0) !== 1) {
    const row = await db(env)
      .prepare(
        `SELECT entitlement_status, entitlement_available_at
           FROM billing_orders
          WHERE merchant_oid = ?`,
      )
      .bind(merchantOid)
      .first<{ entitlement_status: string | null; entitlement_available_at: string | null }>();
    if (row?.entitlement_status === "pending" && row.entitlement_available_at) return "not_due";
    return "not_claimed";
  }

  try {
    const order = await db(env)
      .prepare(
        `SELECT merchant_oid, workspace_id, plan_slug, kind, metadata_json, updated_at
           FROM billing_orders
          WHERE merchant_oid = ?
            AND status = 'completed'
            AND entitlement_status = 'processing'
            AND updated_at = ?`,
      )
      .bind(merchantOid, claimTimestamp)
      .first<DueEntitlementRow>();
    if (!order) throw new Error("entitlement_order_missing");
    await applyAndCompletePaidOrder(env, merchantOid, order);
    return "fulfilled";
  } catch (error) {
    const message = (error instanceof Error ? error.message : String(error)).slice(0, 1000);
    await db(env)
      .prepare(
        `UPDATE billing_orders
            SET entitlement_status = 'pending',
                entitlement_last_error = ?,
                updated_at = datetime('now')
          WHERE merchant_oid = ?
            AND status = 'completed'
            AND entitlement_status = 'processing'
            AND updated_at = ?`,
      )
      .bind(message, merchantOid, claimTimestamp)
      .run();
    return "failed";
  }
}

/** Retry due paid entitlements from the Worker schedule. */
export async function processDuePaidEntitlements(env: Env): Promise<void> {
  try {
    // A Worker can terminate after claiming an order. Reopen claims that have
    // been stuck long enough for any in-flight request to have ended.
    await db(env)
      .prepare(
        `UPDATE billing_orders
            SET entitlement_status = 'pending',
                entitlement_last_error = COALESCE(entitlement_last_error, 'Previous fulfillment attempt timed out'),
                updated_at = datetime('now')
          WHERE status = 'completed'
            AND entitlement_status = 'processing'
            AND datetime(updated_at) <= datetime('now', '-30 minutes')`,
      )
      .run();

    const rows = await db(env)
      .prepare(
        `SELECT merchant_oid
           FROM billing_orders
          WHERE status = 'completed'
            AND entitlement_status = 'pending'
            AND (
              entitlement_available_at IS NULL
              OR entitlement_available_at <= datetime('now')
            )
          ORDER BY COALESCE(entitlement_available_at, completed_at, created_at) ASC
          LIMIT 10`,
      )
      .all<{ merchant_oid: string }>();

    for (const row of rows.results || []) {
      const result = await fulfillDuePaidOrder(env, row.merchant_oid);
      if (result === "failed") {
        console.error("paid entitlement fulfillment failed", { merchantOid: row.merchant_oid });
      }
    }
  } catch (error) {
    console.error(
      "paid entitlement retry queue failed",
      error instanceof Error ? error.message : String(error),
    );
  }
}

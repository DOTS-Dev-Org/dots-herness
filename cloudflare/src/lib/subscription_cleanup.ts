import type { Env } from "../env";
import { db } from "../db/client";
import { recordAudit } from "./audit";

const CYCLE_DAYS = 30;
const GRACE_DAYS = 30;
const DAY_MS = 86400000;

/**
 * End a fixed web plan when its paid/gift period is over. A completed order
 * whose entitlement is due is left alone so the 15-minute entitlement worker
 * can activate it before this expiry pass changes the workspace snapshot.
 */
export async function expireDueWorkspaceSubscriptions(env: Env): Promise<{ expired: string[] }> {
  const { results } = await db(env)
    .prepare(
      `SELECT w.id, w.plan_slug, w.subscription_ends_at
         FROM workspaces w
        WHERE w.plan_slug != 'free'
          AND w.subscription_ends_at IS NOT NULL
          AND julianday(w.subscription_ends_at) <= julianday('now')
          AND NOT EXISTS (
            SELECT 1
              FROM billing_orders b
             WHERE b.workspace_id = w.id
               AND b.status = 'completed'
               AND b.entitlement_status IN ('pending', 'processing')
               AND (
                 b.entitlement_available_at IS NULL
                 OR julianday(b.entitlement_available_at) <= julianday('now')
               )
          )
        ORDER BY w.subscription_ends_at ASC
        LIMIT 100`,
    )
    .all<{ id: string; plan_slug: string; subscription_ends_at: string }>();

  const expired: string[] = [];
  for (const workspace of results || []) {
    const result = await db(env)
      .prepare(
        `UPDATE workspaces
            SET plan_slug = 'free',
                subscription_started_at = NULL,
                subscription_ends_at = NULL,
                gift_months = NULL,
                gift_started_at = NULL,
                updated_at = datetime('now')
          WHERE id = ?
            AND plan_slug = ?
            AND subscription_ends_at = ?`,
      )
      .bind(workspace.id, workspace.plan_slug, workspace.subscription_ends_at)
      .run();
    if ((result.meta?.changes ?? 0) !== 1) continue;

    expired.push(workspace.id);
    await recordAudit(env, {
      workspaceId: workspace.id,
      actorUserId: "system:subscription-expiry",
      actorEmail: null,
      action: "billing.subscription_expired",
      entityType: "workspace",
      entityId: workspace.id,
      metadata: {
        previousPlanSlug: workspace.plan_slug,
        expiredAt: workspace.subscription_ends_at,
      },
    });
  }

  return { expired };
}

// ponytail: overdue = (last completed payment, or workspace creation if never paid) + cycle + grace, all elapsed.
export async function deleteOverdueWorkspaces(env: Env): Promise<{ deleted: string[] }> {
  const cutoff = new Date(Date.now() - (CYCLE_DAYS + GRACE_DAYS) * DAY_MS).toISOString();

  const rows = await db(env)
    .prepare(
      `SELECT w.id,
              COALESCE(
                (SELECT MAX(COALESCE(completed_at, created_at)) FROM billing_orders
                  WHERE workspace_id = w.id AND status = 'completed'),
                w.created_at
              ) AS last_paid
         FROM workspaces w
        WHERE w.plan_slug != 'free'`
    )
    .all<{ id: string; last_paid: string }>();

  const overdue = (rows.results || []).filter((w) => w.last_paid < cutoff);

  for (const w of overdue) {
    await db(env).prepare(`UPDATE billing_orders SET workspace_id = NULL WHERE workspace_id = ?`).bind(w.id).run();
    await db(env).prepare(`DELETE FROM workspaces WHERE id = ?`).bind(w.id).run();
  }

  return { deleted: overdue.map((w) => w.id) };
}

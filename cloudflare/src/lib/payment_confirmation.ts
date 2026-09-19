import type { Env } from "../env";
import { db } from "../db/client";
import {
  sendPaidOrderConfirmationEmail,
  type PaidOrderConfirmation,
} from "./email";

const MAX_ATTEMPTS = 8;
const STALE_CLAIM_MINUTES = 30;
const BACKOFF_MINUTES = [15, 30, 60, 180, 360, 720, 1440, 2880];

type ConfirmationRow = PaidOrderConfirmation & {
  confirmation_email_attempts: number | null;
};

function toPaidOrderConfirmation(row: ConfirmationRow): PaidOrderConfirmation {
  return {
    merchantOid: row.merchantOid,
    customerEmail: row.customerEmail,
    customerName: row.customerName,
    customerPhone: row.customerPhone,
    customerAddress: row.customerAddress,
    planSlug: row.planSlug,
    amountMinor: Number(row.amountMinor || 0),
    currency: row.currency || "TL",
    kind: row.kind || "new",
    termsVersion: row.termsVersion,
    precontractVersion: row.precontractVersion,
    distanceSalesVersion: row.distanceSalesVersion,
    refundVersion: row.refundVersion,
    subscriptionVersion: row.subscriptionVersion,
    immediatePerformanceRequested: row.immediatePerformanceRequested,
    acceptedLocale: row.acceptedLocale,
    entitlementAvailableAt: row.entitlementAvailableAt,
    entitlementStatus: row.entitlementStatus,
    entitlementActivatedAt: row.entitlementActivatedAt,
  };
}

async function loadConfirmationOrder(env: Env, merchantOid: string): Promise<ConfirmationRow | null> {
  const row = await db(env)
    .prepare(
      `SELECT merchant_oid AS merchantOid,
              customer_email AS customerEmail,
              customer_name AS customerName,
              customer_phone AS customerPhone,
              customer_address AS customerAddress,
              plan_slug AS planSlug,
              amount_minor AS amountMinor,
              currency,
              kind,
              terms_version AS termsVersion,
              precontract_version AS precontractVersion,
              distance_sales_version AS distanceSalesVersion,
              refund_version AS refundVersion,
              subscription_version AS subscriptionVersion,
              immediate_performance_requested AS immediatePerformanceRequested,
              accepted_locale AS acceptedLocale,
              entitlement_available_at AS entitlementAvailableAt,
              entitlement_status AS entitlementStatus,
              entitlement_activated_at AS entitlementActivatedAt,
              confirmation_email_attempts
         FROM billing_orders
        WHERE merchant_oid = ?
          AND status = 'completed'`
    )
    .bind(merchantOid)
    .first<ConfirmationRow>();
  return row || null;
}

function errorText(error: unknown): string {
  const message = error instanceof Error ? error.message : String(error);
  return message.slice(0, 1000);
}

async function markConfirmationFailed(
  env: Env,
  merchantOid: string,
  attempt: number,
  error: unknown,
): Promise<void> {
  const backoff = BACKOFF_MINUTES[Math.min(Math.max(attempt - 1, 0), BACKOFF_MINUTES.length - 1)];
  await db(env)
    .prepare(
      `UPDATE billing_orders
          SET confirmation_email_status = 'failed',
              confirmation_email_started_at = NULL,
              confirmation_email_next_attempt_at = CASE
                WHEN confirmation_email_attempts < ? THEN datetime('now', ?)
                ELSE NULL
              END,
              confirmation_email_last_error = ?,
              updated_at = datetime('now')
        WHERE merchant_oid = ?`
    )
    .bind(MAX_ATTEMPTS, `+${backoff} minutes`, errorText(error), merchantOid)
    .run();
}

/**
 * Claims one completed order and attempts its evidence email. The conditional
 * update makes callback and scheduled retry invocations mutually exclusive.
 * Delivery is intentionally at-least-once: the payment ledger and archived
 * legal versions remain the source of truth if the mail provider is down.
 */
export async function attemptPaidOrderConfirmation(
  env: Env,
  merchantOid: string,
): Promise<"sent" | "failed" | "not_claimed"> {
  const claim = await db(env)
    .prepare(
      `UPDATE billing_orders
          SET confirmation_email_status = 'sending',
              confirmation_email_attempts = COALESCE(confirmation_email_attempts, 0) + 1,
              confirmation_email_started_at = datetime('now'),
              confirmation_email_last_error = NULL,
              updated_at = datetime('now')
        WHERE merchant_oid = ?
          AND status = 'completed'
          AND customer_email IS NOT NULL
          AND TRIM(customer_email) <> ''
          AND confirmation_email_status IN ('pending', 'failed')
          AND COALESCE(confirmation_email_attempts, 0) < ?
          AND (
            confirmation_email_next_attempt_at IS NULL
            OR confirmation_email_next_attempt_at <= datetime('now')
          )`
    )
    .bind(merchantOid, MAX_ATTEMPTS)
    .run();

  if ((claim.meta?.changes ?? 0) !== 1) return "not_claimed";

  const order = await loadConfirmationOrder(env, merchantOid);
  if (!order || !order.customerEmail) {
    await markConfirmationFailed(env, merchantOid, Number(order?.confirmation_email_attempts || 1), "Customer email is missing");
    return "failed";
  }

  const attempt = Number(order.confirmation_email_attempts || 1);
  try {
    const result = await sendPaidOrderConfirmationEmail(env, toPaidOrderConfirmation(order));
    await db(env)
      .prepare(
        `UPDATE billing_orders
            SET confirmation_email_status = 'sent',
                confirmation_email_started_at = NULL,
                confirmation_email_next_attempt_at = NULL,
                confirmation_email_sent_at = datetime('now'),
                confirmation_email_message_id = ?,
                confirmation_email_last_error = NULL,
                updated_at = datetime('now')
          WHERE merchant_oid = ?`
      )
      .bind(result.messageId, merchantOid)
      .run();
    return "sent";
  } catch (error) {
    await markConfirmationFailed(env, merchantOid, attempt, error);
    return "failed";
  }
}

async function recoverStaleClaims(env: Env): Promise<void> {
  await db(env)
    .prepare(
      `UPDATE billing_orders
          SET confirmation_email_status = 'failed',
              confirmation_email_started_at = NULL,
              confirmation_email_next_attempt_at = CASE
                WHEN COALESCE(confirmation_email_attempts, 0) < ? THEN datetime('now')
                ELSE NULL
              END,
              confirmation_email_last_error = COALESCE(
                confirmation_email_last_error,
                'Previous confirmation email attempt timed out'
              ),
              updated_at = datetime('now')
        WHERE status = 'completed'
          AND confirmation_email_status = 'sending'
          AND confirmation_email_started_at < datetime('now', ?)`
    )
    .bind(MAX_ATTEMPTS, `-${STALE_CLAIM_MINUTES} minutes`)
    .run();
}

/** Retry due paid-order evidence emails from the 15-minute Worker schedule. */
export async function retryPendingPaidOrderConfirmations(env: Env): Promise<void> {
  try {
    await recoverStaleClaims(env);
    const rows = await db(env)
      .prepare(
        `SELECT merchant_oid
           FROM billing_orders
          WHERE status = 'completed'
            AND customer_email IS NOT NULL
            AND TRIM(customer_email) <> ''
            AND confirmation_email_status IN ('pending', 'failed')
            AND COALESCE(confirmation_email_attempts, 0) < ?
            AND (
              confirmation_email_next_attempt_at IS NULL
              OR confirmation_email_next_attempt_at <= datetime('now')
            )
          ORDER BY COALESCE(completed_at, created_at) ASC
          LIMIT 10`
      )
      .bind(MAX_ATTEMPTS)
      .all<{ merchant_oid: string }>();

    for (const row of rows.results || []) {
      const result = await attemptPaidOrderConfirmation(env, row.merchant_oid);
      if (result === "failed") {
        console.error("paid order confirmation email failed", { merchantOid: row.merchant_oid });
      }
    }
  } catch (error) {
    console.error("paid order confirmation retry queue failed", errorText(error));
  }
}

import type { Env } from "../env";
import { db, nowIso, uuid } from "../db/client";

export type NotificationEventInput = {
  userId: string;
  workspaceId: string;
  typeId: string;
  providerId?: string | null;
  usedPercent?: number | null;
  thresholdPercent?: number | null;
  body?: string | null;
  payload?: Record<string, unknown> | null;
};

export async function insertUserNotificationEvent(
  env: Env,
  input: NotificationEventInput
): Promise<string> {
  const id = uuid();
  const payload =
    input.payload != null ? JSON.stringify(input.payload) : null;
  await db(env)
    .prepare(
      `INSERT INTO user_notification_events
         (id, user_id, workspace_id, type_id, provider_id, used_percent, threshold_percent, body, payload, created_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`
    )
    .bind(
      id,
      input.userId,
      input.workspaceId,
      input.typeId,
      input.providerId ?? null,
      input.usedPercent ?? null,
      input.thresholdPercent ?? null,
      input.body ?? null,
      payload,
      nowIso()
    )
    .run();
  return id;
}

export type PollNotificationItem = {
  id: string;
  type_id: string;
  provider_id: string | null;
  used_percent: number | null;
  threshold_percent: number | null;
  body: string | null;
  created_at: string;
  payload: Record<string, unknown> | null;
};

export async function pollUserNotificationEvents(
  env: Env,
  userId: string,
  workspaceId: string,
  since: string,
  limit: number
): Promise<{ cursor: string; items: PollNotificationItem[] }> {
  // Bound the read to one poll snapshot. If there are no undelivered events,
  // the caller can safely advance past already-delivered history instead of
  // rescanning it from an old epoch cursor on every poll.
  const pollUntil = nowIso();
  const rows = await db(env)
    .prepare(
      `SELECT id, type_id, provider_id, used_percent, threshold_percent, body, payload, created_at
         FROM user_notification_events
        WHERE user_id = ? AND workspace_id = ? AND created_at > ? AND created_at <= ?
          AND delivered_at IS NULL
        ORDER BY created_at ASC
        LIMIT ?`
    )
    .bind(userId, workspaceId, since, pollUntil, limit)
    .all<{
      id: string;
      type_id: string;
      provider_id: string | null;
      used_percent: number | null;
      threshold_percent: number | null;
      body: string | null;
      payload: string | null;
      created_at: string;
    }>();

  const items: PollNotificationItem[] = (rows.results ?? []).map((row) => ({
    id: row.id,
    type_id: row.type_id,
    provider_id: row.provider_id,
    used_percent: row.used_percent,
    threshold_percent: row.threshold_percent,
    body: row.body,
    created_at: row.created_at,
    payload: row.payload ? (JSON.parse(row.payload) as Record<string, unknown>) : null,
  }));

  const cursor =
    items.length > 0 ? items[items.length - 1]!.created_at : pollUntil;

  return { cursor, items };
}

export async function ackUserNotificationEvents(
  env: Env,
  userId: string,
  ids: string[]
): Promise<void> {
  if (ids.length === 0) return;
  const now = nowIso();
  const placeholders = ids.map(() => "?").join(", ");
  await db(env)
    .prepare(
      `UPDATE user_notification_events
          SET delivered_at = ?
        WHERE user_id = ? AND delivered_at IS NULL AND id IN (${placeholders})`
    )
    .bind(now, userId, ...ids)
    .run();
}

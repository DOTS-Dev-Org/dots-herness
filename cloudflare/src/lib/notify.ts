import type { Env } from "../env";
import { db, nowIso } from "../db/client";
import { planFeaturesForSlug } from "./plan_features";
import { sendFcmToUserTokens } from "./fcm";
import { insertUserNotificationEvent } from "./notification_events";
import { parseAlertThresholds } from "./usage";
import { latestConnectionForProvider } from "./users";
import { escapeHtml } from "./html";
import { resolveTelegramSecret } from "./telegram";

const COOLDOWN_MS = 24 * 60 * 60 * 1000;

export type UserTelegramConfig = {
  botToken: string;
  chatId: string;
};

async function getProviderName(env: Env, providerId: string): Promise<string> {
  const row = await db(env)
    .prepare("SELECT name FROM providers WHERE id = ?")
    .bind(providerId)
    .first<{ name: string }>();
  return row?.name || providerId;
}

async function isNotificationsEnabled(env: Env, userId: string): Promise<boolean> {
  const row = await db(env)
    .prepare("SELECT notifications_enabled FROM users WHERE id = ?")
    .bind(userId)
    .first<{ notifications_enabled: number | null }>();
  return row?.notifications_enabled !== 0;
}

export async function fetchUserTelegramConfig(
  env: Env,
  userId: string
): Promise<UserTelegramConfig | null> {
  const row = await db(env)
    .prepare(
      `SELECT telegram_bot_token, telegram_chat_id
         FROM notification_preferences
        WHERE user_id = ?`
    )
    .bind(userId)
    .first<{
      telegram_bot_token: string | null;
      telegram_chat_id: string | null;
    }>();

  if (!row?.telegram_bot_token || !row.telegram_chat_id) return null;
  const botToken = await resolveTelegramSecret(env, userId, row.telegram_bot_token, "telegram_bot_token");
  if (!botToken) return null;

  return {
    botToken,
    chatId: row.telegram_chat_id,
  };
}

export async function fetchUserFcmTokens(
  env: Env,
  userId: string,
  opts?: { includeWatch?: boolean }
): Promise<string[]> {
  const rows = await db(env)
    .prepare("SELECT token, platform FROM user_fcm_tokens WHERE user_id = ?")
    .bind(userId)
    .all<{ token: string; platform: string }>();

  const includeWatch = opts?.includeWatch ?? true;
  return (rows.results ?? [])
    .filter((r) => includeWatch || r.platform !== "watch")
    .map((r) => r.token);
}

async function accountPlanSlug(env: Env, workspaceId: string): Promise<string> {
  const row = await db(env)
    .prepare(`SELECT plan_slug AS slug FROM workspaces WHERE id = ?`)
    .bind(workspaceId)
    .first<{ slug: string | null }>();
  return row?.slug ?? "free";
}

export async function sendTelegramAlert(
  env: Env,
  botToken: string,
  chatId: string,
  message: string
): Promise<void> {
  if (!botToken || !chatId || !message) return;

  try {
    const res = await fetch(`https://api.telegram.org/bot${botToken}/sendMessage`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        chat_id: chatId,
        text: message,
        parse_mode: "HTML",
      }),
    });
    if (!res.ok) {
      // Do not log token or chat id — only status for diagnostics
      console.warn(`Telegram sendMessage failed: HTTP ${res.status}`);
    }
  } catch {
    // Silent fail — notification must not break usage writes
  }
}

export function effectiveUsedPercent(
  usedPercent: number | null | undefined,
  windows?: { used_percent: number }[]
): number | null {
  const values: number[] = [];
  if (usedPercent != null) values.push(usedPercent);
  if (windows?.length) values.push(...windows.map((w) => w.used_percent));
  return values.length ? Math.max(...values) : null;
}

export async function checkUsageThresholdAlerts(
  env: Env,
  userId: string,
  workspaceId: string,
  providerId: string,
  usedPercent: number | null | undefined
): Promise<void> {
  if (usedPercent == null) return;

  if (!(await isNotificationsEnabled(env, userId))) return;

  // Aynı provider'dan birden fazla hesap varsa en yeni bağlantının eşiklerine
  // göre uyarı üretilir (tek-hesaplı kullanıcılar için davranış aynı kalır).
  const connection = await latestConnectionForProvider(env, userId, providerId);
  if (!connection) return;
  const connectionId = connection.id;

  const row = await db(env)
    .prepare(
      "SELECT alert_threshold, alert_thresholds FROM user_provider_usage WHERE connection_id = ?"
    )
    .bind(connectionId)
    .first<{ alert_threshold: number | null; alert_thresholds: string | null }>();

  const thresholds = parseAlertThresholds(row?.alert_thresholds, row?.alert_threshold ?? 80);
  // No custom thresholds configured → no alerts.
  if (!thresholds.length) return;

  // Fire for every crossed threshold that is not in cooldown (max 3).
  const crossed = thresholds.filter((t) => usedPercent >= t);
  if (!crossed.length) return;

  const now = nowIso();

  // First-ever check for this connection: existing usage must not be mistaken
  // for a just-crossed threshold. Seed state for currently-crossed thresholds
  // without notifying, same as the Android client's baseline handling.
  const hasPriorState = await db(env)
    .prepare("SELECT 1 FROM alert_states WHERE connection_id = ? LIMIT 1")
    .bind(connectionId)
    .first();
  if (!hasPriorState) {
    const cooldownUntil = new Date(Date.now() + COOLDOWN_MS).toISOString();
    for (const threshold of crossed) {
      await db(env)
        .prepare(
          `INSERT OR IGNORE INTO alert_states
             (connection_id, user_id, provider_id, threshold_percentage, triggered_at, cooldown_until)
           VALUES (?, ?, ?, ?, ?, ?)`
        )
        .bind(connectionId, userId, providerId, threshold, now, cooldownUntil)
        .run();
    }
    return;
  }

  const ready: number[] = [];
  for (const threshold of crossed) {
    const existing = await db(env)
      .prepare(
        `SELECT 1 FROM alert_states
         WHERE connection_id = ? AND threshold_percentage = ?
           AND cooldown_until > ?`
      )
      .bind(connectionId, threshold, now)
      .first();
    if (!existing) ready.push(threshold);
  }
  if (!ready.length) return;

  const [telegram, planSlug, providerName] = await Promise.all([
    fetchUserTelegramConfig(env, userId),
    accountPlanSlug(env, workspaceId),
    getProviderName(env, providerId),
  ]);
  const watchAllowed = planFeaturesForSlug(planSlug).watchNotifications;
  const fcmTokens = await fetchUserFcmTokens(env, userId, { includeWatch: watchAllowed });

  const pct = Math.round(usedPercent);
  const cooldownUntil = new Date(Date.now() + COOLDOWN_MS).toISOString();

  for (const threshold of ready) {
    const plainMessage = `⚠️ ${providerName} limit uyarısı: %${pct} (eşik %${threshold})`;
    const htmlMessage = `<b>⚠️ ${escapeHtml(providerName)}</b> limit uyarısı: %${pct} (eşik %${threshold})`;

    await insertUserNotificationEvent(env, {
      userId,
      workspaceId,
      typeId: "provider_limit_alert",
      providerId,
      usedPercent: pct,
      thresholdPercent: threshold,
    });

    const deliveries: Promise<void>[] = [];
    if (telegram) {
      deliveries.push(sendTelegramAlert(env, telegram.botToken, telegram.chatId, htmlMessage));
    }
    if (fcmTokens.length > 0) {
      deliveries.push(
        sendFcmToUserTokens(env, userId, fcmTokens, {
          title: "AI Watcher",
          body: plainMessage,
          data: {
            type: "usage_threshold",
            provider_id: providerId,
            used_percent: String(pct),
            threshold_percent: String(threshold),
          },
        })
      );
    }
    await Promise.all(deliveries);

    await db(env)
      .prepare(
        `INSERT INTO alert_states (connection_id, user_id, provider_id, threshold_percentage, triggered_at, cooldown_until)
         VALUES (?, ?, ?, ?, ?, ?)
         ON CONFLICT(connection_id, threshold_percentage) DO UPDATE SET
           triggered_at = excluded.triggered_at,
           cooldown_until = excluded.cooldown_until`
      )
      .bind(connectionId, userId, providerId, threshold, now, cooldownUntil)
      .run();
  }
}

export function scheduleUsageThresholdAlerts(
  executionCtx: { waitUntil: (promise: Promise<unknown>) => void },
  env: Env,
  userId: string,
  workspaceId: string,
  providerId: string,
  usedPercent: number | null | undefined
): void {
  const task = checkUsageThresholdAlerts(
    env,
    userId,
    workspaceId,
    providerId,
    usedPercent
  ).catch(() => {});
  executionCtx.waitUntil(task);
}

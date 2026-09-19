import type { Env } from "../env";
import { db, nowIso, uuid } from "../db/client";
import { timingSafeEqual } from "./paytr";
import {
  encryptUserKeyValue,
  isCurrentUserKeyEncryption,
  resolveUserKeyValue,
} from "./user_key_crypto";

const DEFAULT_API_PUBLIC_URL = "https://dotsherness-unified-backend.dotsherness-unified-backend.workers.dev";

export type TelegramConnectionStatus = {
  configured: boolean;
  connected: boolean;
  pending_chat: boolean;
  bot_username: string | null;
};

type TelegramSecretColumn = "telegram_bot_token" | "telegram_webhook_secret";

/** Decrypt and lazily migrate legacy plaintext Telegram secrets. */
export async function resolveTelegramSecret(
  env: Env,
  userId: string,
  stored: string | null | undefined,
  column: TelegramSecretColumn,
): Promise<string | null> {
  if (!stored) return null;
  const plain = await resolveUserKeyValue(env, userId, "", stored);
  if (!plain) return null;
  if (!isCurrentUserKeyEncryption(stored)) {
    const encrypted = await encryptUserKeyValue(env, userId, plain);
    await db(env)
      .prepare(`UPDATE notification_preferences SET ${column} = ? WHERE user_id = ? AND ${column} = ?`)
      .bind(encrypted, userId, stored)
      .run();
  }
  return plain;
}

function apiPublicBase(env: Env, requestUrl: string): string {
  return (env.API_PUBLIC_URL || DEFAULT_API_PUBLIC_URL).replace(/\/$/, "") || new URL(requestUrl).origin;
}

async function telegramApi<T>(
  botToken: string,
  method: string,
  body?: Record<string, unknown>
): Promise<{ ok: boolean; result?: T; description?: string }> {
  const res = await fetch(`https://api.telegram.org/bot${botToken}/${method}`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: body ? JSON.stringify(body) : undefined,
  });
  return res.json() as Promise<{ ok: boolean; result?: T; description?: string }>;
}

export async function getTelegramConnectionStatus(
  env: Env,
  userId: string
): Promise<TelegramConnectionStatus> {
  const row = await db(env)
    .prepare(
      `SELECT telegram_bot_token, telegram_chat_id FROM notification_preferences WHERE user_id = ?`
    )
    .bind(userId)
    .first<{ telegram_bot_token: string | null; telegram_chat_id: string | null }>();

  const botToken = await resolveTelegramSecret(env, userId, row?.telegram_bot_token, "telegram_bot_token");
  const hasToken = !!botToken;
  const hasChat = !!row?.telegram_chat_id;

  let botUsername: string | null = null;
  if (botToken) {
    const me = await telegramApi<{ username?: string }>(botToken, "getMe");
    if (me.ok && me.result?.username) {
      botUsername = me.result.username;
    }
  }

  return {
    configured: hasToken,
    connected: hasToken && hasChat,
    pending_chat: hasToken && !hasChat,
    bot_username: botUsername,
  };
}

export async function connectUserTelegramBot(
  env: Env,
  userId: string,
  botToken: string,
  requestUrl: string
): Promise<{ ok: true; status: TelegramConnectionStatus } | { ok: false; error: string }> {
  const trimmed = botToken.trim();
  if (!trimmed) {
    return { ok: false, error: "Bot token gerekli" };
  }

  const me = await telegramApi<{ username?: string; id?: number }>(trimmed, "getMe");
  if (!me.ok) {
    return { ok: false, error: "Geçersiz bot token" };
  }

  const webhookSecret = uuid();
  const webhookUrl = `${apiPublicBase(env, requestUrl)}/api/user/telegram/webhook/${userId}`;

  const webhook = await telegramApi(trimmed, "setWebhook", {
    url: webhookUrl,
    secret_token: webhookSecret,
    allowed_updates: ["message"],
    drop_pending_updates: true,
  });

  if (!webhook.ok) {
    return { ok: false, error: "Telegram webhook ayarlanamadı" };
  }

  const encryptedBotToken = await encryptUserKeyValue(env, userId, trimmed);
  const encryptedWebhookSecret = await encryptUserKeyValue(env, userId, webhookSecret);
  const now = nowIso();
  await db(env)
    .prepare(
      `INSERT INTO notification_preferences (user_id, telegram_bot_token, telegram_chat_id, telegram_webhook_secret, updated_at)
       VALUES (?, ?, NULL, ?, ?)
       ON CONFLICT(user_id) DO UPDATE SET
         telegram_bot_token = excluded.telegram_bot_token,
         telegram_chat_id = NULL,
         telegram_webhook_secret = excluded.telegram_webhook_secret,
         updated_at = excluded.updated_at`
    )
    .bind(userId, encryptedBotToken, encryptedWebhookSecret, now)
    .run();

  const status = await getTelegramConnectionStatus(env, userId);
  return { ok: true, status };
}

export async function handleTelegramWebhook(
  env: Env,
  userId: string,
  secretHeader: string | undefined,
  update: {
    message?: {
      chat?: { id?: number };
      text?: string;
    };
  }
): Promise<boolean> {
  const prefs = await db(env)
    .prepare(
      `SELECT telegram_bot_token, telegram_webhook_secret, telegram_chat_id
         FROM notification_preferences WHERE user_id = ?`
    )
    .bind(userId)
    .first<{
      telegram_bot_token: string | null;
      telegram_webhook_secret: string | null;
      telegram_chat_id: string | null;
    }>();

  if (!prefs?.telegram_bot_token || !prefs.telegram_webhook_secret) {
    return false;
  }

  const [botToken, webhookSecret] = await Promise.all([
    resolveTelegramSecret(env, userId, prefs.telegram_bot_token, "telegram_bot_token"),
    resolveTelegramSecret(env, userId, prefs.telegram_webhook_secret, "telegram_webhook_secret"),
  ]);
  if (!botToken || !webhookSecret) return false;

  if (!timingSafeEqual(secretHeader || "", webhookSecret)) {
    return false;
  }

  const chatId = update.message?.chat?.id;
  if (chatId == null) {
    return true;
  }

  const chatIdStr = String(chatId);
  if (prefs.telegram_chat_id === chatIdStr) {
    return true;
  }

  await db(env)
    .prepare(
      `UPDATE notification_preferences
          SET telegram_chat_id = ?, updated_at = ?
        WHERE user_id = ?`
    )
    .bind(chatIdStr, nowIso(), userId)
    .run();

  const welcomeText =
    "✅ AI Watcher bağlantısı kuruldu. Provider limit uyarıları bu sohbete gönderilecek.";
  await fetch(`https://api.telegram.org/bot${botToken}/sendMessage`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ chat_id: chatId, text: welcomeText }),
  }).catch(() => {});

  return true;
}

export async function disconnectUserTelegram(env: Env, userId: string): Promise<void> {
  const row = await db(env)
    .prepare(`SELECT telegram_bot_token FROM notification_preferences WHERE user_id = ?`)
    .bind(userId)
    .first<{ telegram_bot_token: string | null }>();

  if (row?.telegram_bot_token) {
    const botToken = await resolveTelegramSecret(env, userId, row.telegram_bot_token, "telegram_bot_token");
    if (botToken) await telegramApi(botToken, "deleteWebhook").catch(() => {});
  }

  await db(env)
    .prepare(
      `UPDATE notification_preferences
          SET telegram_bot_token = NULL,
              telegram_chat_id = NULL,
              telegram_webhook_secret = NULL,
              updated_at = ?
        WHERE user_id = ?`
    )
    .bind(nowIso(), userId)
    .run();
}

import { SignJWT, importPKCS8 } from "jose";
import type { Env } from "../env";
import { db } from "../db/client";

/** Firebase project: dotsherness-app — set via `wrangler secret put FCM_SERVICE_ACCOUNT_JSON` */
type ServiceAccount = {
  project_id: string;
  client_email: string;
  private_key: string;
};

export type FcmPayload = {
  title: string;
  body: string;
  data?: Record<string, string>;
};

let oauthCache: { token: string; exp: number } | null = null;

function parseServiceAccount(env: Env): ServiceAccount | null {
  const raw = env.FCM_SERVICE_ACCOUNT_JSON;
  if (!raw?.trim()) return null;
  try {
    const parsed = JSON.parse(raw) as ServiceAccount;
    if (!parsed.project_id || !parsed.client_email || !parsed.private_key) return null;
    return parsed;
  } catch {
    return null;
  }
}

async function getGoogleAccessToken(env: Env): Promise<string | null> {
  const sa = parseServiceAccount(env);
  if (!sa) return null;

  const now = Math.floor(Date.now() / 1000);
  if (oauthCache && oauthCache.exp > now + 60) {
    return oauthCache.token;
  }

  const key = await importPKCS8(sa.private_key.replace(/\\n/g, "\n"), "RS256");
  const assertion = await new SignJWT({
    scope: "https://www.googleapis.com/auth/firebase.messaging",
  })
    .setProtectedHeader({ alg: "RS256", typ: "JWT" })
    .setIssuer(sa.client_email)
    .setSubject(sa.client_email)
    .setAudience("https://oauth2.googleapis.com/token")
    .setIssuedAt(now)
    .setExpirationTime(now + 3600)
    .sign(key);

  try {
    const res = await fetch("https://oauth2.googleapis.com/token", {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({
        grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
        assertion,
      }),
    });
    if (!res.ok) {
      console.warn(`FCM OAuth token request failed: HTTP ${res.status}`);
      return null;
    }
    const data = (await res.json()) as { access_token: string; expires_in?: number };
    oauthCache = {
      token: data.access_token,
      exp: now + (data.expires_in ?? 3600),
    };
    return data.access_token;
  } catch {
    return null;
  }
}

function isInvalidFcmToken(status: number, body: unknown): boolean {
  if (status === 404) return true;
  if (!body || typeof body !== "object") return false;
  const err = body as {
    error?: { details?: { errorCode?: string }[]; status?: string };
  };
  const codes = err.error?.details?.map((d) => d.errorCode) ?? [];
  if (codes.includes("UNREGISTERED")) return true;
  if (err.error?.status === "NOT_FOUND") return true;
  return false;
}

export async function sendFcmMessage(
  env: Env,
  deviceToken: string,
  payload: FcmPayload
): Promise<{ ok: boolean; invalidToken?: boolean }> {
  const sa = parseServiceAccount(env);
  if (!sa) return { ok: false };

  const accessToken = await getGoogleAccessToken(env);
  if (!accessToken) return { ok: false };

  const message: Record<string, unknown> = {
    token: deviceToken,
    notification: { title: payload.title, body: payload.body },
    android: {
      priority: "HIGH",
      notification: {
        channel_id: "dotsherness_alerts",
        sound: "default",
      },
    },
    apns: {
      headers: {
        "apns-push-type": "alert",
        "apns-priority": "10",
      },
      payload: { aps: { sound: "default" } },
    },
  };
  if (payload.data && Object.keys(payload.data).length > 0) {
    message.data = payload.data;
  }

  try {
    const res = await fetch(
      `https://fcm.googleapis.com/v1/projects/${sa.project_id}/messages:send`,
      {
        method: "POST",
        headers: {
          Authorization: `Bearer ${accessToken}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({ message }),
      }
    );

    if (res.ok) return { ok: true };

    let errBody: unknown = null;
    try {
      errBody = await res.json();
    } catch {
      /* ignore */
    }
    console.warn(`FCM send failed: HTTP ${res.status}`);
    return { ok: false, invalidToken: isInvalidFcmToken(res.status, errBody) };
  } catch {
    return { ok: false };
  }
}

/**
 * watchOS has no Firebase Messaging SDK support — the watch registers a raw APNs
 * device token instead. Google's Instance ID batchImport API converts that into
 * a normal FCM registration token, which then flows through sendFcmMessage as usual.
 * https://firebase.google.com/docs/cloud-messaging/migrate-v1#import_apns_tokens_to_fcm
 */
export async function importApnsTokenToFcm(
  env: Env,
  apnsToken: string,
  bundleId: string,
  sandbox: boolean
): Promise<string | null> {
  const sa = parseServiceAccount(env);
  if (!sa) return null;

  const accessToken = await getGoogleAccessToken(env);
  if (!accessToken) return null;

  try {
    const res = await fetch("https://iid.googleapis.com/iid/v1:batchImport", {
      method: "POST",
      headers: {
        Authorization: `Bearer ${accessToken}`,
        "Content-Type": "application/json",
        access_token_auth: "true",
      },
      body: JSON.stringify({
        application: bundleId,
        sandbox,
        apns_tokens: [apnsToken],
      }),
    });
    if (!res.ok) {
      console.warn(`APNs->FCM import failed: HTTP ${res.status}`);
      return null;
    }
    const data = (await res.json()) as {
      results?: { apns_token: string; status: string; registration_token?: string }[];
    };
    const result = data.results?.[0];
    if (!result || result.status !== "OK" || !result.registration_token) return null;
    return result.registration_token;
  } catch {
    return null;
  }
}

export async function sendFcmToUserTokens(
  env: Env,
  userId: string,
  tokens: string[],
  payload: FcmPayload
): Promise<void> {
  if (!tokens.length) return;

  const stale: string[] = [];
  await Promise.all(
    tokens.map(async (token) => {
      const result = await sendFcmMessage(env, token, payload);
      if (result.invalidToken) stale.push(token);
    })
  );

  for (const token of stale) {
    await db(env)
      .prepare("DELETE FROM user_fcm_tokens WHERE user_id = ? AND token = ?")
      .bind(userId, token)
      .run();
  }
}

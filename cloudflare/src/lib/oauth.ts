import type { Env } from "../env";
import { db, sqliteTimestamp } from "../db/client";
import { hashToken } from "./jwt";
import { timingSafeEqual } from "./paytr";
import type { RequiredLegalAcceptance } from "./legal";

const STATE_TTL_SEC = 600;
const HANDOFF_TTL_SEC = 120;
const DEFAULT_API_URL = "https://dotsherness-unified-backend.dotsherness-unified-backend.workers.dev";
const DEFAULT_FRONTEND_URL = "https://herness.dots.net.tr";

export function apiPublicUrl(env: Env): string {
  return (env.API_PUBLIC_URL || DEFAULT_API_URL).replace(/\/$/, "");
}

export function frontendUrl(env: Env): string {
  return (env.FRONTEND_URL || DEFAULT_FRONTEND_URL).replace(/\/$/, "");
}

export function oauthRedirectUri(env: Env, provider: "google" | "github"): string {
  return `${apiPublicUrl(env)}/api/auth/${provider}/callback`;
}

export async function createOAuthState(
  env: Env,
  provider: string,
  client?: string,
  legal?: Partial<RequiredLegalAcceptance>,
  options?: { pkceChallenge?: string; clientState?: string },
): Promise<string> {
  const state = crypto.randomUUID();
  const expiresAt = sqliteTimestamp(new Date(Date.now() + STATE_TTL_SEC * 1000));

  await db(env)
    .prepare(
      `INSERT INTO oauth_states (
         state, provider, client, expires_at, pkce_challenge, client_state,
         terms_version, privacy_notice_version, explicit_consent_version,
         explicit_consent_granted, accepted_locale
       ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
    )
    .bind(
      state,
      provider,
      client || "web",
      expiresAt,
      options?.pkceChallenge || null,
      options?.clientState || null,
      legal?.termsVersion || null,
      legal?.privacyNoticeVersion || null,
      legal?.explicitConsentVersion || null,
      // The existing D1 column is NOT NULL DEFAULT 0. Zero means that no
      // positive optional-consent grant was carried through this state.
      legal?.explicitConsentGranted ? 1 : 0,
      legal?.locale || null,
    )
    .run();
  return state;
}

export async function consumeOAuthState(
  env: Env,
  state: string
): Promise<{
  provider: string | null;
  client: string;
  pkceChallenge: string | null;
  clientState: string | null;
  legal: RequiredLegalAcceptance | null;
}> {
  if (!state) {
    return { provider: null, client: "web", pkceChallenge: null, clientState: null, legal: null };
  }

  const row = await db(env)
    .prepare(
      `DELETE FROM oauth_states
        WHERE state = ? AND datetime(expires_at) > CURRENT_TIMESTAMP
        RETURNING provider, client, pkce_challenge, client_state,
                  terms_version, privacy_notice_version,
                  explicit_consent_version, explicit_consent_granted, accepted_locale`,
    )
    .bind(state)
    .first<{
      provider: string;
      client: string | null;
      pkce_challenge: string | null;
      client_state: string | null;
      terms_version: string | null;
      privacy_notice_version: string | null;
      explicit_consent_version: string | null;
      explicit_consent_granted: number | null;
      accepted_locale: string | null;
    }>();
  if (!row) {
    return { provider: null, client: "web", pkceChallenge: null, clientState: null, legal: null };
  }
  const legal = row.terms_version || row.privacy_notice_version
    ? {
        termsVersion: row.terms_version || "",
        privacyNoticeVersion: row.privacy_notice_version || "",
        explicitConsentVersion: row.explicit_consent_version,
        explicitConsentGranted: Boolean(row.explicit_consent_granted),
        locale: row.accepted_locale,
        source: "oauth",
      }
    : null;
  return {
    provider: row.provider,
    client: row.client || "web",
    pkceChallenge: row.pkce_challenge,
    clientState: row.client_state,
    legal,
  };
}

function base64UrlEncode(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
}

function randomHandoffCode(): string {
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  return base64UrlEncode(bytes);
}

export async function pkceChallengeForVerifier(verifier: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(verifier));
  return base64UrlEncode(new Uint8Array(digest));
}

export async function createOAuthHandoff(
  env: Env,
  input: {
    provider: string;
    client: string;
    userId: string;
    pkceChallenge: string;
    clientState?: string | null;
  },
): Promise<string> {
  const code = randomHandoffCode();
  const handoffExpiresAt = sqliteTimestamp(new Date(Date.now() + HANDOFF_TTL_SEC * 1000));
  await db(env)
    .prepare(
      `INSERT INTO oauth_states (
         state, user_id, provider, client, expires_at, pkce_challenge,
         client_state, handoff_code_hash, handoff_expires_at, consumed_at
       ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, NULL)`,
    )
    .bind(
      crypto.randomUUID(),
      input.userId,
      input.provider,
      input.client,
      handoffExpiresAt,
      input.pkceChallenge,
      input.clientState || null,
      await hashToken(code),
      handoffExpiresAt,
    )
    .run();
  return code;
}

export async function exchangeOAuthHandoff(
  env: Env,
  code: string,
  verifier: string,
  client: string,
): Promise<{ userId: string; clientState: string | null } | null> {
  const codeHash = await hashToken(code);
  const row = await db(env)
    .prepare(
      `SELECT state, user_id, pkce_challenge, client_state
         FROM oauth_states
        WHERE handoff_code_hash = ? AND client = ?
          AND consumed_at IS NULL
          AND datetime(handoff_expires_at) > CURRENT_TIMESTAMP`,
    )
    .bind(codeHash, client)
    .first<{
      state: string;
      user_id: string | null;
      pkce_challenge: string | null;
      client_state: string | null;
    }>();
  if (!row?.user_id || !row.pkce_challenge) return null;

  const challenge = await pkceChallengeForVerifier(verifier);
  if (!timingSafeEqual(challenge, row.pkce_challenge)) return null;

  const consumed = await db(env)
    .prepare(
      `UPDATE oauth_states
          SET consumed_at = CURRENT_TIMESTAMP
        WHERE state = ? AND handoff_code_hash = ?
          AND consumed_at IS NULL
          AND datetime(handoff_expires_at) > CURRENT_TIMESTAMP`,
    )
    .bind(row.state, codeHash)
    .run();
  if ((consumed.meta?.changes ?? 0) !== 1) return null;

  return { userId: row.user_id, clientState: row.client_state };
}

export type OAuthProfile = {
  providerId: string;
  email: string;
  name: string;
  surname: string;
  avatar: string;
};

export function googleAuthUrl(env: Env, state: string, redirectUri: string): string {
  const clientId = googleOAuthClientId(env);
  if (!clientId) throw new Error("google_oauth_not_configured");
  const params = new URLSearchParams({
    client_id: clientId,
    redirect_uri: redirectUri,
    response_type: "code",
    scope: "openid email profile",
    state,
    access_type: "online",
    prompt: "select_account",
  });
  return `https://accounts.google.com/o/oauth2/v2/auth?${params}`;
}

export async function exchangeGoogleCode(
  env: Env,
  code: string,
  redirectUri: string
): Promise<OAuthProfile> {
  const clientId = googleOAuthClientId(env);
  const clientSecret = (env.GOOGLE_CLIENT_SECRET || "").trim();
  if (!clientId || !clientSecret) {
    throw new Error("google_oauth_not_configured");
  }
  const tokenRes = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      code,
      client_id: clientId,
      client_secret: clientSecret,
      redirect_uri: redirectUri,
      grant_type: "authorization_code",
    }),
  });

  const tokenData = (await tokenRes.json()) as { access_token?: string; error?: string };
  if (!tokenRes.ok || !tokenData.access_token) {
    throw new Error(tokenData.error || "token_exchange_failed");
  }

  const userRes = await fetch("https://www.googleapis.com/oauth2/v3/userinfo", {
    headers: { Authorization: `Bearer ${tokenData.access_token}` },
  });
  const user = (await userRes.json()) as {
    sub?: string;
    email?: string;
    email_verified?: boolean;
    name?: string;
    given_name?: string;
    family_name?: string;
    picture?: string;
    error?: string;
  };

  if (!userRes.ok || !user.sub || !user.email) {
    throw new Error(user.error || "userinfo_failed");
  }

  const emailVerified =
    typeof user.email_verified === "boolean"
      ? user.email_verified
      : String(user.email_verified ?? "").toLowerCase() === "true";
  if (!emailVerified) {
    throw new Error("email_not_verified");
  }

  return {
    providerId: user.sub,
    email: user.email,
    name: user.given_name || user.name?.split(" ")[0] || "",
    surname: user.family_name || user.name?.split(" ").slice(1).join(" ") || "",
    avatar: user.picture || "",
  };
}

export function githubAuthUrl(env: Env, state: string, redirectUri: string): string {
  const params = new URLSearchParams({
    client_id: env.GITHUB_CLIENT_ID!,
    redirect_uri: redirectUri,
    scope: "read:user user:email",
    state,
  });
  return `https://github.com/login/oauth/authorize?${params}`;
}

async function githubTokenExchange(
  env: Env,
  code: string,
  redirectUri?: string
): Promise<{ access_token: string; scope?: string }> {
  const body = new URLSearchParams({
    client_id: env.GITHUB_CLIENT_ID || "",
    client_secret: env.GITHUB_CLIENT_SECRET || "",
    code,
  });
  if (redirectUri) body.set("redirect_uri", redirectUri);

  const tokenRes = await fetch("https://github.com/login/oauth/access_token", {
    method: "POST",
    headers: {
      "content-type": "application/x-www-form-urlencoded",
      accept: "application/json",
      "user-agent": "aiwatcher-oauth",
    },
    body,
  });

  let tokenData: {
    access_token?: string;
    error?: string;
    error_description?: string;
    scope?: string;
  } = {};
  try {
    tokenData = (await tokenRes.json()) as typeof tokenData;
  } catch {
    console.error("github token exchange non-json", tokenRes.status);
    throw new Error("token_exchange_failed");
  }
  if (!tokenRes.ok || !tokenData.access_token) {
    const detail = [tokenData.error, tokenData.error_description].filter(Boolean).join(": ");
    console.error("github token exchange failed", detail || tokenRes.status, {
      withRedirectUri: Boolean(redirectUri),
    });
    throw new Error(tokenData.error || "token_exchange_failed");
  }
  return { access_token: tokenData.access_token, scope: tokenData.scope };
}

export async function exchangeGithubCode(
  env: Env,
  code: string,
  redirectUri: string
): Promise<OAuthProfile> {
  // Prefer form-urlencoded (GitHub's documented primary format).
  // Retry without redirect_uri if the registered callback differs slightly.
  let accessToken: string;
  try {
    ({ access_token: accessToken } = await githubTokenExchange(env, code, redirectUri));
  } catch (err) {
    const msg = err instanceof Error ? err.message : "";
    if (msg === "redirect_uri_mismatch" || msg === "bad_verification_code") {
      // bad_verification_code after mismatch is not recoverable (code is single-use).
      // Only retry redirect_uri_mismatch — but code may still be unused if GitHub
      // rejected before consuming it.
      if (msg === "redirect_uri_mismatch") {
        ({ access_token: accessToken } = await githubTokenExchange(env, code));
      } else {
        throw err;
      }
    } else {
      throw err;
    }
  }

  const ghHeaders = {
    Authorization: `Bearer ${accessToken}`,
    "User-Agent": "aiwatcher-oauth",
    accept: "application/vnd.github+json",
  };

  const userRes = await fetch("https://api.github.com/user", { headers: ghHeaders });
  const user = (await userRes.json()) as {
    id?: number;
    email?: string | null;
    name?: string | null;
    login?: string | null;
    avatar_url?: string | null;
    message?: string;
  };
  if (!userRes.ok || user.id == null) {
    console.error("github userinfo failed", user.message || userRes.status);
    throw new Error(user.message || "userinfo_failed");
  }

  let email = "";
  const emailRes = await fetch("https://api.github.com/user/emails", { headers: ghHeaders });
  if (emailRes.ok) {
    const emails = (await emailRes.json()) as Array<{
      email: string;
      primary?: boolean;
      verified?: boolean;
    }>;
    if (Array.isArray(emails)) {
      const primary =
        emails.find((e) => e.primary && e.verified) ||
        emails.find((e) => e.verified) ||
        emails.find((e) => e.primary) ||
        emails[0];
      email = primary?.email || "";
    }
  } else {
    // Provider error bodies are not stable and may contain account details;
    // keep only the status in Worker logs.
    console.error("github emails failed", emailRes.status);
  }

  // Fallback: public profile email (may be null when private).
  if (!email && user.email) email = user.email;

  // Last resort: GitHub always has a noreply address for the account.
  if (!email && user.id != null) {
    const login = (user.login || "user").replace(/[^a-zA-Z0-9-]/g, "");
    email = `${user.id}+${login}@users.noreply.github.com`;
  }

  if (!email) throw new Error("email_required");

  const fullName = (user.name || "").trim();
  const parts = fullName ? fullName.split(/\s+/) : [];
  return {
    providerId: String(user.id),
    email,
    name: parts[0] || user.login || email.split("@")[0] || "User",
    surname: parts.slice(1).join(" "),
    avatar: user.avatar_url || "",
  };
}

/** Map OAuth exception messages to safe frontend error codes. */
export function oauthFailureCode(err: unknown): string {
  const msg = err instanceof Error ? err.message : "";
  if (msg === "email_required") return "email_required";
  if (msg === "email_not_verified") return "email_not_verified";
  if (
    msg === "bad_verification_code" ||
    msg === "incorrect_client_credentials" ||
    msg === "redirect_uri_mismatch" ||
    msg === "token_exchange_failed" ||
    msg === "application_suspended"
  ) {
    return "oauth_token_failed";
  }
  if (msg === "userinfo_failed" || /API rate limit/i.test(msg)) return "oauth_userinfo_failed";
  return "oauth_failed";
}

export function oauthErrorRedirect(env: Env, code: string): Response {
  const frontend = frontendUrl(env);
  return Response.redirect(`${frontend}/auth?error=${encodeURIComponent(code)}`, 302);
}

export function desktopOAuthSuccessRedirect(
  env: Env,
  handoff: { code: string; clientState?: string | null }
): Response {
  const params = new URLSearchParams({ code: handoff.code });
  if (handoff.clientState) params.set("state", handoff.clientState);
  const query = params.toString();
  const nativeCallback = (env.DESKTOP_OAUTH_CALLBACK_URL || "").trim();
  if (nativeCallback) {
    const separator = nativeCallback.includes("?") ? "&" : "?";
    return Response.redirect(`${nativeCallback}${separator}${query}`, 302);
  }
  const frontend = frontendUrl(env);
  return Response.redirect(`${frontend}/auth/desktop-callback.html?${query}`, 302);
}

export function mobileOAuthSuccessRedirect(
  code: string,
  clientState?: string | null,
): Response {
  const params = new URLSearchParams({ code });
  if (clientState) params.set("state", clientState);
  return Response.redirect(`com.dots.aiwatcher://oauth-callback#${params.toString()}`, 302);
}

function splitCsv(value?: string): string[] {
  return (value || "")
    .split(",")
    .map((part) => part.trim())
    .filter(Boolean);
}

export function allowedGoogleClientIds(env: Env): Set<string> {
  const ids = [
    ...splitCsv(env.GOOGLE_CLIENT_IDS),
    ...splitCsv(env.GOOGLE_CLIENT_ID),
  ];
  return new Set(ids);
}

/** Prefer explicit GOOGLE_CLIENT_ID; else first entry from GOOGLE_CLIENT_IDS. */
export function googleOAuthClientId(env: Env): string | null {
  const direct = (env.GOOGLE_CLIENT_ID || "").trim();
  if (direct) return direct;
  const fromList = splitCsv(env.GOOGLE_CLIENT_IDS)[0];
  return fromList || null;
}

export function isGoogleOAuthConfigured(env: Env): boolean {
  return Boolean(googleOAuthClientId(env) && (env.GOOGLE_CLIENT_SECRET || "").trim());
}

export async function verifyGoogleIdToken(env: Env, idToken: string): Promise<OAuthProfile | null> {
  const resp = await fetch(
    `https://oauth2.googleapis.com/tokeninfo?id_token=${encodeURIComponent(idToken)}`
  );
  if (!resp.ok) return null;

  const data = (await resp.json()) as Record<string, unknown>;
  const aud = String(data.aud || "");
  const allowed = allowedGoogleClientIds(env);
  if (allowed.size > 0 && !allowed.has(aud)) return null;

  const sub = String(data.sub || "").trim();
  const email = typeof data.email === "string" ? data.email : "";
  if (!sub || !email) return null;

  const emailVerifiedRaw = data.email_verified;
  const emailVerified =
    typeof emailVerifiedRaw === "boolean"
      ? emailVerifiedRaw
      : typeof emailVerifiedRaw === "string"
        ? emailVerifiedRaw.trim().toLowerCase() === "true"
        : false;
  if (!emailVerified) return null;

  const name = typeof data.given_name === "string"
    ? data.given_name
    : typeof data.name === "string"
      ? data.name.split(" ")[0] || ""
      : "";
  const surname = typeof data.family_name === "string"
    ? data.family_name
    : typeof data.name === "string"
      ? data.name.split(" ").slice(1).join(" ")
      : "";
  const avatar = typeof data.picture === "string" ? data.picture : "";

  return {
    providerId: sub,
    email,
    name,
    surname,
    avatar,
  };
}

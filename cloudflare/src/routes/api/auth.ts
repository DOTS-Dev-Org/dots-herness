import { Hono } from "hono";
import type { Context } from "hono";
import { zValidator } from "@hono/zod-validator";
import { z } from "zod";
import type { Env, AppVariables } from "../../env";
import { db, normalizeEmail, sqliteTimestamp, timestampMs, uuid } from "../../db/client";
import { generateResetCode, hashPassword, verifyPassword } from "../../lib/password";
import {
  signAccessToken,
  signRefreshToken,
  verifyRefreshToken,
  hashToken,
  refreshExpiresAt,
} from "../../lib/jwt";
import {
  allocateUsername,
  buildUserProfile,
  createDefaultWorkspace,
  getActiveAuthUser,
  getUserByEmail,
  InactiveAccountError,
  revokeAllRefreshTokens,
} from "../../lib/users";
import { sendPasswordResetEmail } from "../../lib/email";
import { timingSafeEqual } from "../../lib/paytr";
import { requireAuth } from "../../middleware/auth";
import { rateLimit } from "../../middleware/rate-limit";
import { hasSeatAvailable } from "../../lib/team";
import {
  createOAuthState,
  consumeOAuthState,
  exchangeGithubCode,
  exchangeGoogleCode,
  frontendUrl,
  githubAuthUrl,
  googleAuthUrl,
  verifyGoogleIdToken,
  allowedGoogleClientIds,
  oauthErrorRedirect,
  oauthFailureCode,
  createOAuthHandoff,
  exchangeOAuthHandoff,
  mobileOAuthSuccessRedirect,
  desktopOAuthSuccessRedirect,
  oauthRedirectUri,
  apiPublicUrl,
  isGoogleOAuthConfigured,
  type OAuthProfile,
} from "../../lib/oauth";
import { RegistrationClosedError, isRegistrationOpen } from "../../lib/settings";
import {
  clearAuthCookies,
  clearOAuthStateCookie,
  getOAuthStateCookie,
  getRefreshTokenFromCookie,
  setOAuthStateCookie,
  setAuthCookies,
} from "../../lib/auth-cookies";
import { clientIpFromRequest, recordAudit } from "../../lib/audit";
import {
  LEGAL_DOCUMENT_VERSIONS,
  LegalAcceptanceRequiredError,
  recordLegalConsents,
  legalPublicationEnabled,
  validateRequiredLegalAcceptance,
  type RequiredLegalAcceptance,
} from "../../lib/legal";

const auth = new Hono<{ Bindings: Env; Variables: AppVariables }>();

type LegalConsentEvent = Parameters<typeof recordLegalConsents>[2][number];

const PKCE_CHALLENGE_PATTERN = /^[A-Za-z0-9_-]{43,128}$/;
const OAUTH_CLIENT_STATE_MAX_LENGTH = 256;

export function validPkceChallenge(value: string | null | undefined): value is string {
  return Boolean(value && PKCE_CHALLENGE_PATTERN.test(value));
}

function readOAuthClientState(value: string | null | undefined): string | undefined {
  if (!value) return undefined;
  const state = value.trim();
  return state.length > 0 && state.length <= OAUTH_CLIENT_STATE_MAX_LENGTH ? state : undefined;
}

function oauthCallbackError(
  c: Context<{ Bindings: Env; Variables: AppVariables }>,
  code: string,
): Response {
  return c.redirect(`${frontendUrl(c.env)}/auth?error=${encodeURIComponent(code)}`);
}

function optionalAnalyticsConsentEvents(granted: boolean | undefined, version?: string | null): LegalConsentEvent[] {
  // An unchecked optional checkbox is not a deliberate withdrawal. Keep the
  // evidence model conservative: only a positive, explicit grant is created
  // here; an explicit withdrawal is recorded from account settings.
  if (granted !== true) return [];
  return [{
    purpose: "optional.analytics_product" as const,
    action: "granted" as const,
    documentKey: "explicit_consent" as const,
    documentVersion: version || LEGAL_DOCUMENT_VERSIONS.explicit_consent,
  }];
}

async function auditAuthLogin(
  c: Context<{ Bindings: Env; Variables: AppVariables }>,
  userId: string,
  email: string
) {
  await recordAudit(c.env, {
    actorUserId: userId,
    actorEmail: email,
    action: "auth.login",
    entityType: "user",
    entityId: userId,
    ip: clientIpFromRequest(c.req),
    userAgent: c.req.header("User-Agent") ?? null,
  });
}

export async function findOrCreateOAuthUser(
  env: Env,
  provider: "google" | "github",
  profile: OAuthProfile,
  legal?: RequiredLegalAcceptance | null,
  evidence?: { ip?: string | null; userAgent?: string | null },
): Promise<{ id: string; email: string; role: string } | null> {
  const email = normalizeEmail(profile.email);

  // 1) Strict (provider, provider_id) match. This is the canonical lookup so
  //    that the same OAuth identity always resolves to the same local user.
  let row = await db(env)
    .prepare("SELECT id, email, role, status FROM users WHERE auth_provider = ? AND provider_id = ?")
    .bind(provider, profile.providerId)
    .first<{ id: string; email: string; role: string; status: string | null }>();

  if (row) {
    if (row.status !== "active") throw new InactiveAccountError();
    return { id: row.id, email: row.email, role: row.role };
  }

  // 2) If the email is already taken by a local (email/password) account,
  //    refuse to silently merge — that would let anyone who controls the
  //    address at Google hijack the existing local account. The user must
  //    sign in with their password and explicitly link the provider from
  //    account settings. Returning null signals the endpoint to respond 409.
  const taken = await db(env)
    .prepare("SELECT id, email, role, status FROM users WHERE email = ?")
    .bind(email)
    .first<{ id: string; email: string; role: string; status: string | null }>();

  if (taken) {
    if (taken.status !== "active") throw new InactiveAccountError();
    return null;
  }

  // 3) Brand-new OAuth user.
  if (!(await isRegistrationOpen(env))) {
    throw new RegistrationClosedError();
  }
  if (!legalPublicationEnabled(env)) {
    throw new RegistrationClosedError();
  }

  if (!legal) throw new LegalAcceptanceRequiredError();
  validateRequiredLegalAcceptance(legal);

  const userId = uuid();
  const password_hash = await hashPassword(crypto.randomUUID());
  const username = await allocateUsername(
    env,
    null,
    profile.name || email.split("@")[0] || "user"
  );
  await db(env)
    .prepare(
      `INSERT INTO users (
         id, email, password_hash, name, surname, username, role, email_verified,
         auth_provider, provider_id, avatar
       ) VALUES (?, ?, ?, ?, ?, ?, 'user', 1, ?, ?, ?)`
    )
    .bind(
      userId,
      email,
      password_hash,
      profile.name,
      profile.surname,
      username,
      provider,
      profile.providerId,
      profile.avatar
    )
    .run();
  await createDefaultWorkspace(env, userId, profile.name || email.split("@")[0] || "User");
  await recordLegalConsents(
    env,
    {
      userId,
      locale: legal.locale,
      source: legal.source || "oauth",
      ip: evidence?.ip ?? null,
      userAgent: evidence?.userAgent ?? null,
    },
    [
      {
        purpose: "terms.acceptance",
        action: "accepted",
        documentKey: "terms",
        documentVersion: legal.termsVersion,
      },
      {
        purpose: "privacy.notice",
        action: "acknowledged",
        documentKey: "privacy_notice",
        documentVersion: legal.privacyNoticeVersion,
      },
      ...optionalAnalyticsConsentEvents(legal.explicitConsentGranted, legal.explicitConsentVersion),
    ],
  );

  return { id: userId, email, role: "user" };
}

async function issueTokensForUser(env: Env, userId: string) {
  const user = await getActiveAuthUser(env, userId);
  if (!user) throw new InactiveAccountError();

  const access_token = await signAccessToken(env, {
    sub: user.id,
    email: user.email,
    role: user.role,
  });
  const refresh_token = await signRefreshToken(env, user.id);
  const tokenHash = await hashToken(refresh_token);
  await db(env)
    .prepare("INSERT INTO refresh_tokens (id, user_id, token_hash, expires_at) VALUES (?, ?, ?, ?)")
    .bind(uuid(), user.id, tokenHash, refreshExpiresAt())
    .run();
  return { access_token, refresh_token };
}

export async function completeOAuthLogin(env: Env, userId: string, _email: string, _role: string) {
  return issueTokensForUser(env, userId);
}

export async function issueTokens(c: { env: Env; json: (d: unknown, s?: number) => Response }, userId: string, _email: string, _role: string) {
  return issueTokensForUser(c.env, userId);
}

export async function issueTokensWithCookies(
  c: Context<{ Bindings: Env; Variables: AppVariables }>,
  userId: string,
  email: string,
  role: string
) {
  const tokens = await issueTokens(c, userId, email, role);
  setAuthCookies(c, tokens.access_token, tokens.refresh_token);
  return tokens;
}

auth.post("/login", rateLimit({ limit: 10, windowSeconds: 60, keyPrefix: "auth:login" }), zValidator("json", z.object({
  email: z.string().email().max(320),
  password: z.string().min(1).max(512),
  terms_version: z.string().min(1).max(32).optional(),
  privacy_notice_version: z.string().min(1).max(32).optional(),
  explicit_consent: z.boolean().optional(),
  explicit_consent_version: z.string().min(1).max(32).optional(),
  locale: z.string().min(2).max(10).optional(),
})), async (c) => {
  const body = c.req.valid("json");
  const { email, password } = body;
  const row = await db(c.env)
    .prepare("SELECT id, email, password_hash, role, status FROM users WHERE email = ?")
    .bind(normalizeEmail(email))
    .first<{ id: string; email: string; password_hash: string; role: string; status: string | null }>();
  if (!row || row.status !== "active" || !(await verifyPassword(password, row.password_hash))) {
    return c.json({ error: "Invalid email or password" }, 401);
  }
  const tokens = await issueTokensWithCookies(c, row.id, row.email, row.role);
  await recordAudit(c.env, {
    actorUserId: row.id,
    actorEmail: row.email,
    action: "auth.login",
    entityType: "user",
    entityId: row.id,
    ip: clientIpFromRequest(c.req),
    userAgent: c.req.header("User-Agent") ?? null,
  });
  const user = await buildUserProfile(c.env, row.id);
  return c.json({ user, ...tokens });
});

auth.post("/register", rateLimit({ limit: 5, windowSeconds: 3600, keyPrefix: "auth:register" }), zValidator("json", z.object({
  name: z.string().trim().min(1).max(120),
  surname: z.string().trim().max(120).optional(),
  username: z.string().min(3).max(32).optional(),
  email: z.string().email().max(320),
  password: z.string().min(6).max(512),
  invite_token: z.string().trim().min(1).max(128).optional(),
  terms_version: z.string().min(1).max(32),
  privacy_notice_version: z.string().min(1).max(32),
  explicit_consent: z.boolean().optional(),
  explicit_consent_version: z.string().min(1).max(32).optional(),
  locale: z.string().min(2).max(10).optional(),
})), async (c) => {
  const body = c.req.valid("json");
  if (!legalPublicationEnabled(c.env)) {
    return c.json({ error: "Kayıtlar şu an kapalı.", code: "registration_closed" }, 503);
  }
  const email = normalizeEmail(body.email);
  try {
    validateRequiredLegalAcceptance({
      termsVersion: body.terms_version,
      privacyNoticeVersion: body.privacy_notice_version,
      explicitConsentGranted: body.explicit_consent,
      explicitConsentVersion: body.explicit_consent_version,
      locale: body.locale,
      source: "registration",
    });
  } catch (error) {
    return c.json({ error: "Güncel hukuki metinleri onaylamadan kayıt tamamlanamaz.", code: "legal_acceptance_required" }, 400);
  }
  if (!body.invite_token && !(await isRegistrationOpen(c.env))) {
    return c.json({ error: "Kayıtlar şu an kapalı.", code: "registration_closed" }, 403);
  }
  const existing = await getUserByEmail(c.env, email);
  if (existing) return c.json({ error: "Email already registered" }, 409);

  let username: string;
  try {
    username = await allocateUsername(
      c.env,
      body.username,
      body.name || email.split("@")[0] || "user"
    );
  } catch (e) {
    const msg = e instanceof Error ? e.message : "Invalid username";
    const status = msg.includes("taken") ? 409 : 400;
    return c.json({ error: msg, code: msg.includes("taken") ? "username_taken" : "invalid_username" }, status);
  }

  const userId = uuid();
  const password_hash = await hashPassword(body.password);
  await db(c.env)
    .prepare(
      `INSERT INTO users (id, email, password_hash, name, surname, username, role, email_verified)
       VALUES (?, ?, ?, ?, ?, ?, 'user', 0)`
    )
    .bind(userId, email, password_hash, body.name, body.surname || "", username)
    .run();

  await createDefaultWorkspace(c.env, userId, body.name);

  if (body.invite_token) {
    const invite = await db(c.env)
      .prepare(
        "SELECT id, workspace_id, role, email FROM team_invites WHERE (token = ? OR token = ?) AND accepted_at IS NULL AND datetime(expires_at) > CURRENT_TIMESTAMP"
      )
      .bind(await hashToken(body.invite_token), body.invite_token)
      .first<{ id: string; workspace_id: string; role: string; email: string }>();
    if (invite) {
      if (normalizeEmail(invite.email) !== email) {
        return c.json(
          { error: "Invite email does not match registration email", code: "invite_email_mismatch" },
          403
        );
      }
      const seats = await hasSeatAvailable(c.env, invite.workspace_id);
      if (!seats.available) {
        return c.json(
          { error: "seat_limit_reached", used: seats.used, limit: seats.limit },
          409
        );
      }
      await db(c.env)
        .prepare("INSERT INTO workspace_members (workspace_id, user_id, role, joined_at) VALUES (?, ?, ?, NOW()) ON CONFLICT (workspace_id, user_id) DO NOTHING")
        .bind(invite.workspace_id, userId, invite.role || "member")
        .run();
      await db(c.env)
        .prepare("UPDATE team_invites SET token = ?, accepted_at = NOW() WHERE id = ?")
        .bind(await hashToken(body.invite_token), invite.id)
        .run();
      await recordAudit(c.env, {
        workspaceId: invite.workspace_id,
        actorUserId: userId,
        actorEmail: email,
        action: "invite.accept",
        entityType: "invite",
        entityId: invite.id,
        ip: clientIpFromRequest(c.req),
        userAgent: c.req.header("User-Agent") ?? null,
      });
    }
  }

  await recordLegalConsents(
    c.env,
    {
      userId,
      locale: body.locale,
      source: "registration",
      ip: clientIpFromRequest(c.req),
      userAgent: c.req.header("User-Agent") ?? null,
    },
    [
      {
        purpose: "terms.acceptance",
        action: "accepted",
        documentKey: "terms",
        documentVersion: body.terms_version,
      },
      {
        purpose: "privacy.notice",
        action: "acknowledged",
        documentKey: "privacy_notice",
        documentVersion: body.privacy_notice_version,
      },
      ...optionalAnalyticsConsentEvents(body.explicit_consent, body.explicit_consent_version),
    ],
  );

  await recordAudit(c.env, {
    actorUserId: userId,
    actorEmail: email,
    action: "auth.register",
    entityType: "user",
    entityId: userId,
    ip: clientIpFromRequest(c.req),
    userAgent: c.req.header("User-Agent") ?? null,
  });

  const tokens = await issueTokensWithCookies(c, userId, email, "user");
  const user = await buildUserProfile(c.env, userId);
  return c.json({ user, ...tokens }, 201);
});

auth.post("/refresh", rateLimit({ limit: 30, windowSeconds: 60, keyPrefix: "auth:refresh" }), async (c) => {
  let refresh_token: string | undefined = getRefreshTokenFromCookie(c);
  const contentType = c.req.header("content-type") || "";
  if (contentType.includes("application/json")) {
    try {
      const body = await c.req.json<{ refresh_token?: string }>();
      if (body.refresh_token) refresh_token = body.refresh_token;
    } catch {
      /* cookie-only refresh */
    }
  }
  if (!refresh_token) return c.json({ error: "Invalid refresh token" }, 401);

  try {
    const userId = await verifyRefreshToken(c.env, refresh_token);
    const tokenHash = await hashToken(refresh_token);
    const stored = await db(c.env)
      .prepare("SELECT expires_at FROM refresh_tokens WHERE user_id = ? AND token_hash = ? AND datetime(expires_at) > CURRENT_TIMESTAMP")
      .bind(userId, tokenHash)
      .first<{ expires_at: string }>();
    const storedExpiry = stored ? timestampMs(stored.expires_at) : NaN;
    if (!stored || !Number.isFinite(storedExpiry) || storedExpiry <= Date.now()) {
      return c.json({ error: "Invalid refresh token" }, 401);
    }

    const user = await db(c.env)
      .prepare("SELECT id, email, role, status FROM users WHERE id = ?")
      .bind(userId)
      .first<{ id: string; email: string; role: string; status: string | null }>();
    if (!user || user.status !== "active") return c.json({ error: "Invalid refresh token" }, 401);

    // Keep the 30-day refresh token stable and only renew the short-lived access
    // token. If an MV3 worker or the computer stops after this response leaves the
    // server but before the client persists it, the already-persisted refresh
    // token remains valid and the request can be retried after startup.
    const access_token = await signAccessToken(c.env, {
      sub: user.id,
      email: user.email,
      role: user.role,
    });
    setAuthCookies(c, access_token, refresh_token);
    return c.json({ access_token, refresh_token });
  } catch {
    return c.json({ error: "Invalid refresh token" }, 401);
  }
});

auth.post(
  "/desktop/exchange",
  rateLimit({ limit: 20, windowSeconds: 60, keyPrefix: "auth:oauth:exchange" }),
  zValidator(
    "json",
    z.object({
      code: z.string().regex(/^[A-Za-z0-9_-]{43,128}$/),
      code_verifier: z.string().regex(/^[A-Za-z0-9._~-]{43,128}$/),
      client: z.enum(["desktop", "mobile"]),
    }),
  ),
  async (c) => {
    const body = c.req.valid("json");
    const handoff = await exchangeOAuthHandoff(
      c.env,
      body.code,
      body.code_verifier,
      body.client,
    );
    if (!handoff) return c.json({ error: "Invalid or expired OAuth handoff" }, 401);

    const user = await getActiveAuthUser(c.env, handoff.userId);
    if (!user) return c.json({ error: "Invalid or expired OAuth handoff" }, 401);

    const tokens = await issueTokens(c, user.id, user.email, user.role);
    await auditAuthLogin(c, user.id, user.email);
    return c.json(tokens);
  },
);

auth.post("/logout", rateLimit({ limit: 30, windowSeconds: 60, keyPrefix: "auth:logout" }), async (c) => {
  let refresh_token: string | undefined = getRefreshTokenFromCookie(c);
  const contentType = c.req.header("content-type") || "";
  if (contentType.includes("application/json")) {
    try {
      const body = await c.req.json<{ refresh_token?: string }>();
      if (body.refresh_token) refresh_token = body.refresh_token;
    } catch {
      /* cookie-only logout */
    }
  }
  if (refresh_token) {
    const tokenHash = await hashToken(refresh_token);
    const session = await db(c.env)
      .prepare(
        `SELECT rt.user_id, u.email
           FROM refresh_tokens rt
           JOIN users u ON u.id = rt.user_id
          WHERE rt.token_hash = ?`
      )
      .bind(tokenHash)
      .first<{ user_id: string; email: string }>();
    if (session) {
      await recordAudit(c.env, {
        actorUserId: session.user_id,
        actorEmail: session.email,
        action: "auth.logout",
        entityType: "user",
        entityId: session.user_id,
        ip: clientIpFromRequest(c.req),
        userAgent: c.req.header("User-Agent") ?? null,
      });
    }
    await db(c.env).prepare("DELETE FROM refresh_tokens WHERE token_hash = ?").bind(tokenHash).run();
  }
  clearAuthCookies(c);
  return c.json({ ok: true });
});

auth.post("/set-password", rateLimit({ limit: 10, windowSeconds: 3600, keyPrefix: "auth:set-password" }), requireAuth, zValidator("json", z.object({
  current_password: z.string().max(512),
  new_password: z.string().min(6).max(512).optional(),
  password: z.string().min(6).max(512).optional(),
}).refine(d => d.new_password || d.password, { message: "new password required" })), async (c) => {
  const user = c.get("user");
  const body = c.req.valid("json");
  const newPassword = body.new_password || body.password!;
  const row = await db(c.env)
    .prepare("SELECT password_hash FROM users WHERE id = ?")
    .bind(user.id)
    .first<{ password_hash: string }>();
  if (!row || !(await verifyPassword(body.current_password, row.password_hash))) {
    return c.json({ error: "Current password is incorrect" }, 400);
  }
  const password_hash = await hashPassword(newPassword);
  await db(c.env).prepare("UPDATE users SET password_hash = ?, updated_at = NOW() WHERE id = ?")
    .bind(password_hash, user.id).run();
  await revokeAllRefreshTokens(c.env, user.id);
  await recordAudit(c.env, {
    actorUserId: user.id,
    actorEmail: user.email,
    action: "auth.password_change",
    entityType: "user",
    entityId: user.id,
    ip: clientIpFromRequest(c.req),
    userAgent: c.req.header("User-Agent") ?? null,
  });
  return c.json({ success: true });
});

/** Min seconds before the same user may request a new reset token + email. */
const PASSWORD_RESET_COOLDOWN_SECONDS = 90;

auth.post("/forgot-password", rateLimit({ limit: 5, windowSeconds: 3600, keyPrefix: "auth:forgot-password" }), zValidator("json", z.object({ email: z.string().email().max(320) })), async (c) => {
  const email = normalizeEmail(c.req.valid("json").email);
  const user = await getUserByEmail(c.env, email);
  if (user) {
    // One row per user: within cooldown keep the existing unused token and do not re-send mail.
    const existing = await db(c.env)
      .prepare(
        `SELECT id, used_at, created_at FROM password_reset_tokens WHERE user_id = ?`
      )
      .bind(user.id)
      .first<{ id: string; used_at: string | null; created_at: string }>();

    if (existing && existing.used_at == null) {
      const createdMs = timestampMs(existing.created_at);
      const ageSeconds = Number.isFinite(createdMs)
        ? (Date.now() - createdMs) / 1000
        : PASSWORD_RESET_COOLDOWN_SECONDS + 1;
      if (ageSeconds < PASSWORD_RESET_COOLDOWN_SECONDS) {
        return c.json({ ok: true, message: "If the email exists, a reset link was sent." });
      }
    }

    const token = generateResetCode();
    const tokenHash = await hashToken(token);
    const tokenId = uuid();
    const expires = new Date();
    expires.setHours(expires.getHours() + 24);
    // Upsert: overwrite the single row for this user (unique on user_id).
    await db(c.env)
      .prepare(
        `INSERT INTO password_reset_tokens (id, user_id, token_hash, expires_at, used_at, created_at)
         VALUES (?, ?, ?, ?, NULL, datetime('now'))
         ON CONFLICT(user_id) DO UPDATE SET
           id = excluded.id,
           token_hash = excluded.token_hash,
           expires_at = excluded.expires_at,
           used_at = NULL,
           created_at = datetime('now')`
      )
      .bind(tokenId, user.id, tokenHash, sqliteTimestamp(expires))
      .run();
    try {
      const result = await sendPasswordResetEmail(c.env, email, token);
      const emailDomain = email.split("@")[1] || "unknown";
      console.log("password reset email sent", {
        toDomain: emailDomain,
        messageId: result.messageId,
      });
    } catch (err) {
      console.error(
        "password reset email failed",
        err instanceof Error ? err.message : err
      );
      await db(c.env)
        .prepare("DELETE FROM password_reset_tokens WHERE id = ?")
        .bind(tokenId)
        .run();
      return c.json(
        { error: "Şu an e-posta gönderilemiyor, lütfen daha sonra tekrar deneyin." },
        503
      );
    }
  }
  return c.json({ ok: true, message: "If the email exists, a reset link was sent." });
});

auth.post("/reset-password", rateLimit({ limit: 10, windowSeconds: 3600, keyPrefix: "auth:reset-password" }), zValidator("json", z.object({
  token: z.string().regex(/^[a-f0-9]{32}$/i, "Invalid reset token"),
  password: z.string().min(6).max(512),
})), async (c) => {
  const { token, password } = c.req.valid("json");
  const tokenHash = await hashToken(token);
  const row = await db(c.env)
    .prepare(
      `SELECT prt.id, prt.user_id FROM password_reset_tokens prt
        WHERE prt.token_hash = ? AND prt.used_at IS NULL
          AND datetime(prt.expires_at) > CURRENT_TIMESTAMP`
    )
    .bind(tokenHash)
    .first<{ id: string; user_id: string }>();
  if (!row) return c.json({ error: "Invalid or expired token" }, 400);
  const password_hash = await hashPassword(password);
  await db(c.env).prepare("UPDATE users SET password_hash = ? WHERE id = ?").bind(password_hash, row.user_id).run();
  // Remove the single token row after successful use (no history bloat).
  await db(c.env).prepare("DELETE FROM password_reset_tokens WHERE id = ?").bind(row.id).run();
  await revokeAllRefreshTokens(c.env, row.user_id);
  const userRow = await db(c.env)
    .prepare("SELECT email FROM users WHERE id = ?")
    .bind(row.user_id)
    .first<{ email: string }>();
  await recordAudit(c.env, {
    actorUserId: row.user_id,
    actorEmail: userRow?.email ?? null,
    action: "auth.password_reset",
    entityType: "user",
    entityId: row.user_id,
    ip: clientIpFromRequest(c.req),
    userAgent: c.req.header("User-Agent") ?? null,
  });
  return c.json({ ok: true });
});

auth.get("/google", rateLimit({ limit: 20, windowSeconds: 60, keyPrefix: "auth:google-start" }), async (c) => {
  if (!isGoogleOAuthConfigured(c.env)) {
    return oauthErrorRedirect(c.env, "oauth_not_configured");
  }
  const clientParam = c.req.query("client");
  const client = clientParam === "desktop" || clientParam === "mobile" ? clientParam : "web";
  const pkceChallenge = c.req.query("code_challenge");
  const clientState = readOAuthClientState(c.req.query("client_state"));
  if (client !== "web" && !validPkceChallenge(pkceChallenge)) {
    return oauthErrorRedirect(c.env, "oauth_pkce_required");
  }
  if (c.req.query("client_state") && !clientState) {
    return oauthErrorRedirect(c.env, "oauth_invalid_callback");
  }
  const explicitConsent = c.req.query("explicit_consent");
  const state = await createOAuthState(c.env, "google", client, {
    termsVersion: c.req.query("terms_version") || undefined,
    privacyNoticeVersion: c.req.query("privacy_notice_version") || undefined,
    explicitConsentVersion: c.req.query("explicit_consent_version") || undefined,
    explicitConsentGranted: explicitConsent === undefined ? undefined : explicitConsent === "1",
    locale: c.req.query("locale") || undefined,
    source: "oauth",
  }, { pkceChallenge: client === "web" ? undefined : pkceChallenge, clientState });
  if (client === "web") setOAuthStateCookie(c, state);
  const redirectUri = oauthRedirectUri(c.env, "google");
  return c.redirect(googleAuthUrl(c.env, state, redirectUri));
});

auth.post("/google", rateLimit({ limit: 10, windowSeconds: 60, keyPrefix: "auth:google" }), zValidator("json", z.object({
  id_token: z.string().min(1).max(4096),
  terms_version: z.string().min(1).max(32).optional(),
  privacy_notice_version: z.string().min(1).max(32).optional(),
  explicit_consent_version: z.string().min(1).max(32).optional(),
  explicit_consent: z.boolean().optional(),
  locale: z.string().min(2).max(10).optional(),
})), async (c) => {
  if (allowedGoogleClientIds(c.env).size === 0) {
    return c.json({ error: "Google sign-in is not configured" }, 503);
  }

  const body = c.req.valid("json");
  const { id_token } = body;
  const profile = await verifyGoogleIdToken(c.env, id_token);
  if (!profile) return c.json({ error: "Invalid Google token" }, 401);

  try {
    const user = await findOrCreateOAuthUser(c.env, "google", profile, {
      termsVersion: body.terms_version || "",
      privacyNoticeVersion: body.privacy_notice_version || "",
      explicitConsentVersion: body.explicit_consent_version,
      explicitConsentGranted: body.explicit_consent,
      locale: body.locale,
      source: "oauth",
    }, {
      ip: clientIpFromRequest(c.req),
      userAgent: c.req.header("User-Agent") ?? null,
    });
    if (!user) {
      return c.json(
        {
          error:
            "Bu e-posta adresi zaten şifreyle kayıtlı. Lütfen şifrenizle giriş yapın veya hesap ayarlarından Google'ı bağlayın.",
          code: "email_already_registered",
        },
        409
      );
    }
    const tokens = await issueTokensWithCookies(c, user.id, user.email, user.role);
    await auditAuthLogin(c, user.id, user.email);
    const fullUser = await buildUserProfile(c.env, user.id);
    return c.json({ user: fullUser, ...tokens });
  } catch (err) {
    if (err instanceof RegistrationClosedError) {
      return c.json({ error: "Kayıtlar şu an kapalı.", code: "registration_closed" }, 403);
    }
    if (err instanceof LegalAcceptanceRequiredError) {
      return c.json({ error: "OAuth ile yeni hesap açmak için güncel hukuki metinleri onaylayın.", code: err.code }, 409);
    }
    if (err instanceof InactiveAccountError) {
      return c.json({ error: "Account is inactive", code: err.code }, 403);
    }
    console.error("google id token login failed", oauthFailureCode(err));
    return c.json({ error: "Google sign-in failed" }, 500);
  }
});

auth.get("/google/callback", rateLimit({ limit: 20, windowSeconds: 60, keyPrefix: "auth:google-callback" }), async (c) => {
  const browserState = getOAuthStateCookie(c);
  clearOAuthStateCookie(c);
  if (!isGoogleOAuthConfigured(c.env)) {
    return oauthCallbackError(c, "oauth_not_configured");
  }

  const url = new URL(c.req.url);
  const error = url.searchParams.get("error");
  if (error) return oauthCallbackError(c, error === "access_denied" ? "oauth_denied" : "oauth_failed");

  const code = url.searchParams.get("code");
  const state = url.searchParams.get("state");
  if (!code || !state) return oauthCallbackError(c, "oauth_invalid_callback");

  const { provider, client, pkceChallenge, clientState, legal } = await consumeOAuthState(c.env, state);
  if (provider !== "google") return oauthCallbackError(c, "oauth_invalid_state");
  if (client === "web") {
    if (!browserState || !timingSafeEqual(browserState, state)) {
      return oauthCallbackError(c, "oauth_invalid_state");
    }
  } else if ((client !== "desktop" && client !== "mobile") || !validPkceChallenge(pkceChallenge)) {
    return oauthCallbackError(c, "oauth_pkce_required");
  }

  try {
    const redirectUri = oauthRedirectUri(c.env, "google");
    const profile = await exchangeGoogleCode(c.env, code, redirectUri);
    const user = await findOrCreateOAuthUser(c.env, "google", profile, legal, {
      ip: clientIpFromRequest(c.req),
      userAgent: c.req.header("User-Agent") ?? null,
    });
    if (!user) {
      return oauthCallbackError(c, "email_already_registered");
    }
    if (client === "desktop" || client === "mobile") {
      const handoffCode = await createOAuthHandoff(c.env, {
        provider: "google",
        client,
        userId: user.id,
        pkceChallenge: pkceChallenge!,
        clientState,
      });
      return client === "desktop"
        ? desktopOAuthSuccessRedirect(c.env, { code: handoffCode, clientState })
        : mobileOAuthSuccessRedirect(handoffCode, clientState);
    }
    const tokens = await completeOAuthLogin(c.env, user.id, user.email, user.role);
    await auditAuthLogin(c, user.id, user.email);
    setAuthCookies(c, tokens.access_token, tokens.refresh_token);
    const frontend = frontendUrl(c.env);
    return c.redirect(`${frontend}/auth?oauth=success`);
  } catch (err) {
    if (err instanceof RegistrationClosedError) {
      return oauthCallbackError(c, "registration_closed");
    }
    if (err instanceof LegalAcceptanceRequiredError) {
      return oauthCallbackError(c, err.code);
    }
    if (err instanceof InactiveAccountError) {
      return oauthCallbackError(c, err.code);
    }
    console.error("google oauth callback failed", oauthFailureCode(err));
    return oauthCallbackError(c, "oauth_failed");
  }
});

auth.get("/github", rateLimit({ limit: 20, windowSeconds: 60, keyPrefix: "auth:github-start" }), async (c) => {
  if (!c.env.GITHUB_CLIENT_ID || !c.env.GITHUB_CLIENT_SECRET) {
    return oauthErrorRedirect(c.env, "oauth_not_configured");
  }
  const clientParam = c.req.query("client");
  const client =
    clientParam === "desktop" ? "desktop" : clientParam === "mobile" ? "mobile" : "web";
  const pkceChallenge = c.req.query("code_challenge");
  const clientState = readOAuthClientState(c.req.query("client_state"));
  if (client !== "web" && !validPkceChallenge(pkceChallenge)) {
    return oauthErrorRedirect(c.env, "oauth_pkce_required");
  }
  if (c.req.query("client_state") && !clientState) {
    return oauthErrorRedirect(c.env, "oauth_invalid_callback");
  }
  const explicitConsent = c.req.query("explicit_consent");
  const state = await createOAuthState(c.env, "github", client, {
    termsVersion: c.req.query("terms_version") || undefined,
    privacyNoticeVersion: c.req.query("privacy_notice_version") || undefined,
    explicitConsentVersion: c.req.query("explicit_consent_version") || undefined,
    explicitConsentGranted: explicitConsent === undefined ? undefined : explicitConsent === "1",
    locale: c.req.query("locale") || undefined,
    source: "oauth",
  }, { pkceChallenge: client === "web" ? undefined : pkceChallenge, clientState });
  if (client === "web") setOAuthStateCookie(c, state);
  // Mobile legacy deep-link callback lives at /oauth/callback (not /api/auth/github/callback).
  const redirectUri =
    client === "mobile"
      ? `${apiPublicUrl(c.env)}/oauth/callback`
      : oauthRedirectUri(c.env, "github");
  return c.redirect(githubAuthUrl(c.env, state, redirectUri));
});

auth.get("/github/callback", rateLimit({ limit: 20, windowSeconds: 60, keyPrefix: "auth:github-callback" }), async (c) => {
  const browserState = getOAuthStateCookie(c);
  clearOAuthStateCookie(c);
  if (!c.env.GITHUB_CLIENT_ID || !c.env.GITHUB_CLIENT_SECRET) {
    return oauthCallbackError(c, "oauth_not_configured");
  }

  const url = new URL(c.req.url);
  const error = url.searchParams.get("error");
  if (error) return oauthCallbackError(c, error === "access_denied" ? "oauth_denied" : "oauth_failed");

  const code = url.searchParams.get("code");
  const state = url.searchParams.get("state");
  if (!code || !state) return oauthCallbackError(c, "oauth_invalid_callback");

  const { provider, client, pkceChallenge, clientState, legal } = await consumeOAuthState(c.env, state);
  if (provider !== "github") return oauthCallbackError(c, "oauth_invalid_state");
  if (client === "web") {
    if (!browserState || !timingSafeEqual(browserState, state)) {
      return oauthCallbackError(c, "oauth_invalid_state");
    }
  } else if ((client !== "desktop" && client !== "mobile") || !validPkceChallenge(pkceChallenge)) {
    return oauthCallbackError(c, "oauth_pkce_required");
  }

  let step = "exchange";
  try {
    const redirectUri =
      client === "mobile"
        ? `${apiPublicUrl(c.env)}/oauth/callback`
        : oauthRedirectUri(c.env, "github");
    const profile = await exchangeGithubCode(c.env, code, redirectUri);
    step = "find_or_create";
    const user = await findOrCreateOAuthUser(c.env, "github", profile, legal, {
      ip: clientIpFromRequest(c.req),
      userAgent: c.req.header("User-Agent") ?? null,
    });
    if (!user) {
      return oauthCallbackError(c, "email_already_registered");
    }
    step = "issue_tokens";
    if (client === "desktop" || client === "mobile") {
      step = "handoff";
      const handoffCode = await createOAuthHandoff(c.env, {
        provider: "github",
        client,
        userId: user.id,
        pkceChallenge: pkceChallenge!,
        clientState,
      });
      return client === "desktop"
        ? desktopOAuthSuccessRedirect(c.env, { code: handoffCode, clientState })
        : mobileOAuthSuccessRedirect(handoffCode, clientState);
    }
    const tokens = await completeOAuthLogin(c.env, user.id, user.email, user.role);
    step = "audit";
    await auditAuthLogin(c, user.id, user.email);
    step = "cookies";
    setAuthCookies(c, tokens.access_token, tokens.refresh_token);
    const frontend = frontendUrl(c.env);
    return c.redirect(`${frontend}/auth?oauth=success`);
  } catch (err) {
    if (err instanceof RegistrationClosedError) {
      return oauthCallbackError(c, "registration_closed");
    }
    if (err instanceof LegalAcceptanceRequiredError) {
      return oauthCallbackError(c, err.code);
    }
    if (err instanceof InactiveAccountError) {
      return oauthCallbackError(c, err.code);
    }
    const failureCode = oauthFailureCode(err);
    console.error("github oauth callback failed", { step, code: failureCode });
    return oauthCallbackError(c, failureCode);
  }
});

const QR_SESSION_TTL_MS = 2 * 60 * 1000;

type QrSessionPendingState = "ok" | "not_found" | "expired";

async function markQrSessionExpired(env: Env, sessionId: string) {
  await db(env)
    .prepare("UPDATE qr_sessions SET status = 'expired' WHERE id = ?")
    .bind(sessionId)
    .run();
}

async function assertQrSessionPending(
  env: Env,
  sessionId: string
): Promise<QrSessionPendingState> {
  const row = await db(env)
    .prepare("SELECT status, expires_at FROM qr_sessions WHERE id = ?")
    .bind(sessionId)
    .first<{ status: string; expires_at: string }>();

  if (!row) return "not_found";
  if (row.status === "consumed" || row.status === "confirmed") return "not_found";
  const expiry = timestampMs(row.expires_at);
  if (!Number.isFinite(expiry) || expiry < Date.now()) {
    await markQrSessionExpired(env, sessionId);
    return "expired";
  }
  if (row.status !== "pending") return "not_found";
  return "ok";
}

async function isQrSessionPastExpiry(
  env: Env,
  sessionId: string,
  expiresAt: string
): Promise<boolean> {
  const expiry = timestampMs(expiresAt);
  if (Number.isFinite(expiry) && expiry >= Date.now()) return false;
  await markQrSessionExpired(env, sessionId);
  return true;
}

async function verifyPollSecret(storedHash: string | null | undefined, secret: string | undefined): Promise<boolean> {
  if (!storedHash || !secret) return false;
  const computed = await hashToken(secret);
  return timingSafeEqual(storedHash, computed);
}

// Kamera ile taranamayan durumlar için: 0/O, 1/I gibi karıştırılabilecek
// karakterler hariç tutulmuş 6 haneli, harf-rakam karışık kod.
const SHORT_CODE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";

function generateShortCode(): string {
  const bytes = new Uint8Array(6);
  crypto.getRandomValues(bytes);
  return Array.from(bytes, (b) => SHORT_CODE_ALPHABET[b % SHORT_CODE_ALPHABET.length]).join("");
}

async function resolveQrSessionByCode(
  env: Env,
  code: string
): Promise<{ id: string; user_id: string | null; status: string; expires_at: string; poll_secret_hash: string | null } | null> {
  return db(env)
    .prepare("SELECT id, user_id, status, expires_at, poll_secret_hash FROM qr_sessions WHERE short_code = ?")
    .bind(code)
    .first<{ id: string; user_id: string | null; status: string; expires_at: string; poll_secret_hash: string | null }>();
}

// QR'a gömülen `sid`, taramayı kolaylaştırmak için uzun uuid yerine 6 haneli
// short_code olabilir — ikisini de kabul edip gerçek session id'ye çözer.
async function resolveQrSessionId(env: Env, raw: string): Promise<string | null> {
  if (raw.length <= 8) {
    const row = await resolveQrSessionByCode(env, raw.toUpperCase());
    return row?.id ?? null;
  }
  return raw;
}

async function consumeQrSession(
  c: Context<{ Bindings: Env; Variables: AppVariables }>,
  row: { id: string; user_id: string | null; status: string; expires_at: string }
) {
  if (row.status === "consumed") return c.json({ status: "expired" });
  if (await isQrSessionPastExpiry(c.env, row.id, row.expires_at)) {
    return c.json({ status: "expired" });
  }
  if (row.status !== "confirmed" || !row.user_id) {
    return c.json({ status: row.status === "pending" ? "pending" : "expired" });
  }

  const user = await getActiveAuthUser(c.env, row.user_id);
  if (!user) return c.json({ status: "expired" });

  const tokens = await issueTokens(c, user.id, user.email, user.role);
  await db(c.env)
    .prepare("UPDATE qr_sessions SET status = 'consumed', confirmed_at = COALESCE(confirmed_at, NOW()) WHERE id = ?")
    .bind(row.id)
    .run();

  await recordAudit(c.env, {
    actorUserId: user.id,
    actorEmail: user.email,
    action: "auth.qr.login",
    entityType: "qr_session",
    entityId: row.id,
    ip: clientIpFromRequest(c.req),
    userAgent: c.req.header("User-Agent") ?? null,
  });

  return c.json({
    status: "confirmed",
    user_id: user.id,
    email: user.email,
    access_token: tokens.access_token,
    refresh_token: tokens.refresh_token,
  });
}

// Ayrı router: /api/auth/qr/* altında ve kökte /auth/qr/* alias'ı olarak mount edilir
// (watch/mobil eski buildleri /auth/qr/* çağırıyor).
export const qrRoutes = new Hono<{ Bindings: Env; Variables: AppVariables }>();

qrRoutes.post("/create", rateLimit({ limit: 20, windowSeconds: 3600, keyPrefix: "auth:qr:create" }), async (c) => {
  const id = uuid();
  const pollSecret = crypto.randomUUID();
  const pollSecretHash = await hashToken(pollSecret);
  const expiresAt = sqliteTimestamp(new Date(Date.now() + QR_SESSION_TTL_MS));

  let shortCode = generateShortCode();
  for (let attempt = 0; attempt < 5; attempt++) {
    const existing = await db(c.env)
      .prepare("SELECT 1 FROM qr_sessions WHERE short_code = ?")
      .bind(shortCode)
      .first();
    if (!existing) break;
    shortCode = generateShortCode();
  }

  await db(c.env)
    .prepare(
      "INSERT INTO qr_sessions (id, status, expires_at, poll_secret_hash, short_code) VALUES (?, 'pending', ?, ?, ?)"
    )
    .bind(id, expiresAt, pollSecretHash, shortCode)
    .run();
  const frontend = frontendUrl(c.env);
  return c.json({
    sessionId: id,
    pollSecret,
    shortCode,
    qrUrl: `${frontend}/qr-login?sid=${shortCode}`,
    expiresAt,
    expiresIn: QR_SESSION_TTL_MS / 1000,
  });
});

qrRoutes.get("/poll", rateLimit({ limit: 60, windowSeconds: 60, keyPrefix: "auth:qr:poll" }), async (c) => {
  const sid = c.req.query("sid");
  const secret = c.req.query("secret");
  if (!sid) return c.json({ status: "expired" });

  const row = await db(c.env)
    .prepare(
      "SELECT id, user_id, status, expires_at, poll_secret_hash FROM qr_sessions WHERE id = ?"
    )
    .bind(sid)
    .first<{
      id: string;
      user_id: string | null;
      status: string;
      expires_at: string;
      poll_secret_hash: string | null;
    }>();

  if (!row) return c.json({ status: "expired" });
  if (row.status === "consumed") return c.json({ status: "expired" });
  if (await isQrSessionPastExpiry(c.env, sid, row.expires_at)) {
    return c.json({ status: "expired" });
  }
  if (!(await verifyPollSecret(row.poll_secret_hash, secret))) {
    return c.json({ status: "pending" });
  }

  return consumeQrSession(c, row);
});

// QR kamerayla taranamadığında, ekrandaki 6 haneli kodun elle girilmesiyle
// aynı oturumu tamamlamak için kullanılır.
qrRoutes.get("/poll-code", rateLimit({ limit: 30, windowSeconds: 60, keyPrefix: "auth:qr:poll_code" }), async (c) => {
  const code = (c.req.query("code") || "").trim().toUpperCase();
  const secret = c.req.query("secret");
  if (!code) return c.json({ status: "expired" });

  const row = await resolveQrSessionByCode(c.env, code);
  if (!row) return c.json({ status: "expired" });
  if (row.status === "consumed") return c.json({ status: "expired" });
  if (await isQrSessionPastExpiry(c.env, row.id, row.expires_at)) {
    return c.json({ status: "expired" });
  }
  // Same session-bound proof as /poll: the short code alone must not yield tokens.
  if (!(await verifyPollSecret(row.poll_secret_hash, secret))) {
    return c.json({ status: "pending" });
  }

  return consumeQrSession(c, row);
});

qrRoutes.get("/preview", rateLimit({ limit: 30, windowSeconds: 60, keyPrefix: "auth:qr:preview" }), async (c) => {
  const rawSid = c.req.query("sid");
  if (!rawSid) return c.json({ error: "sid_required" }, 400);
  const sid = await resolveQrSessionId(c.env, rawSid);
  if (!sid) return c.json({ status: "not_found" }, 404);

  const row = await db(c.env)
    .prepare("SELECT status, expires_at FROM qr_sessions WHERE id = ?")
    .bind(sid)
    .first<{ status: string; expires_at: string }>();

  if (!row) return c.json({ status: "not_found" }, 404);
  if (row.status === "consumed" || row.status === "confirmed") {
    return c.json({ status: "not_found" }, 404);
  }
  if (await isQrSessionPastExpiry(c.env, sid, row.expires_at)) {
    return c.json({ status: "expired", expires_at: row.expires_at }, 410);
  }
  if (row.status !== "pending") return c.json({ status: "not_found" }, 404);

  return c.json({ status: "pending", expires_at: row.expires_at });
});

qrRoutes.post("/confirm", rateLimit({ limit: 30, windowSeconds: 60, keyPrefix: "auth:qr:confirm" }), requireAuth, zValidator("json", z.object({ sessionId: z.string() })), async (c) => {
  const { sessionId: rawSessionId } = c.req.valid("json");
  const user = c.get("user");

  const sessionId = await resolveQrSessionId(c.env, rawSessionId);
  if (!sessionId) {
    return c.json({ error: "session_not_found" }, 404);
  }

  const state = await assertQrSessionPending(c.env, sessionId);
  if (state === "expired") {
    return c.json({ error: "session_expired" }, 410);
  }
  if (state === "not_found") {
    return c.json({ error: "session_not_found" }, 404);
  }

  const result = await db(c.env)
    .prepare(
      "UPDATE qr_sessions SET status = 'confirmed', user_id = ?, confirmed_at = NOW() WHERE id = ? AND status = 'pending'"
    )
    .bind(user.id, sessionId)
    .run();

  if (!result.meta.changes) {
    return c.json({ error: "session_not_found" }, 404);
  }

  await recordAudit(c.env, {
    actorUserId: user.id,
    actorEmail: user.email,
    action: "auth.qr.confirm",
    entityType: "qr_session",
    entityId: sessionId,
    ip: clientIpFromRequest(c.req),
    userAgent: c.req.header("User-Agent") ?? null,
  });

  return c.json({ ok: true });
});

auth.route("/qr", qrRoutes);

export default auth;

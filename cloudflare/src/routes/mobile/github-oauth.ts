import { Hono } from "hono";
import type { Env } from "../../env";
import {
  apiPublicUrl,
  consumeOAuthState,
  createOAuthHandoff,
  exchangeGithubCode,
  mobileOAuthSuccessRedirect,
} from "../../lib/oauth";
import { RegistrationClosedError } from "../../lib/settings";
import {
  findOrCreateOAuthUser,
  validPkceChallenge,
} from "../api/auth";
import { clientIpFromRequest } from "../../lib/audit";
import { InactiveAccountError } from "../../lib/users";

const mobileGithubOAuth = new Hono<{ Bindings: Env }>();

/** Mobile GitHub callback — returns a one-time PKCE-bound handoff code. */
mobileGithubOAuth.get("/oauth/callback", async (c) => {
  const code = c.req.query("code");
  const state = c.req.query("state");
  if (!code) {
    return c.text("Missing OAuth authorization code.", 400);
  }
  if (!state) {
    return c.text("Missing OAuth state.", 400);
  }

  const clientId = c.env.GITHUB_CLIENT_ID;
  const clientSecret = c.env.GITHUB_CLIENT_SECRET;
  if (!clientId || !clientSecret) {
    return c.text("Server configuration error: GitHub OAuth is not configured.", 500);
  }

  const { provider, client, pkceChallenge, clientState, legal } = await consumeOAuthState(c.env, state);
  if (provider !== "github" || client !== "mobile" || !validPkceChallenge(pkceChallenge)) {
    return c.text("Invalid or expired OAuth state.", 400);
  }

  try {
    const redirectUri = `${apiPublicUrl(c.env)}/oauth/callback`;
    const profile = await exchangeGithubCode(c.env, code, redirectUri);
    const user = await findOrCreateOAuthUser(c.env, "github", profile, legal, {
      ip: clientIpFromRequest(c.req),
      userAgent: c.req.header("User-Agent") ?? null,
    });
    if (!user) {
      return c.text("Email already registered with password. Sign in with password first.", 409);
    }

    const handoffCode = await createOAuthHandoff(c.env, {
      provider: "github",
      client: "mobile",
      userId: user.id,
      pkceChallenge,
      clientState,
    });
    return mobileOAuthSuccessRedirect(handoffCode, clientState);
  } catch (err) {
    if (err instanceof RegistrationClosedError) {
      return c.text("Registration is closed.", 403);
    }
    if (err instanceof InactiveAccountError) {
      return c.text("Account is inactive.", 403);
    }
    if (err instanceof Error && err.name === "LegalAcceptanceRequiredError") {
      return c.text("Current legal documents must be accepted before creating an account.", 409);
    }
    console.error("mobile github oauth callback failed", err instanceof Error ? err.name : typeof err);
    return c.text("Failed to complete OAuth.", 500);
  }
});

/** Unsigned webhook endpoint — do not log payloads; accept no-op. */
mobileGithubOAuth.post("/", async (c) => {
  return c.body(null, 204);
});

export default mobileGithubOAuth;

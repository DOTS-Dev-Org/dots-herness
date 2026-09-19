import { createMiddleware } from "hono/factory";
import type { Env, AppVariables } from "../env";
import { getAccessTokenFromCookie, getRefreshTokenFromCookie } from "../lib/auth-cookies";
import { isAllowedOrigin } from "./cors";

const STATE_CHANGING_METHODS = new Set(["POST", "PUT", "PATCH", "DELETE"]);

/**
 * Web auth cookies are cross-origin because the SPA lives on cPanel while the
 * API lives on Workers. SameSite=None is therefore required, but it also means
 * browser-origin verification must protect cookie-authenticated mutations.
 * Bearer-only mobile/desktop requests are not subject to this browser check.
 */
export const csrfProtection = createMiddleware<{ Bindings: Env; Variables: AppVariables }>(
  async (c, next) => {
    if (
      STATE_CHANGING_METHODS.has(c.req.method) &&
      (getAccessTokenFromCookie(c) || getRefreshTokenFromCookie(c)) &&
      !isAllowedOrigin(c.env, c.req.header("Origin") || "")
    ) {
      return c.json({ error: "csrf_origin_required" }, 403);
    }

    await next();
  },
);

import type { Context } from "hono";
import { deleteCookie, getCookie, setCookie } from "hono/cookie";
import type { Env, AppVariables } from "../env";

export const ACCESS_COOKIE = "dotsherness_access";
export const REFRESH_COOKIE = "dotsherness_refresh";
export const OAUTH_STATE_COOKIE = "dotsherness_oauth_state";

const ACCESS_MAX_AGE = 15 * 60;
const REFRESH_MAX_AGE = 30 * 24 * 60 * 60;
export const OAUTH_STATE_MAX_AGE = 10 * 60;

type AuthContext = Context<{ Bindings: Env; Variables: AppVariables }>;

/** Cross-origin SPA (dots.net.tr → workers.dev) requires SameSite=None; Secure. */
const cookieBase = {
  path: "/",
  httpOnly: true,
  secure: true,
  sameSite: "None" as const,
};

const oauthStateCookieBase = {
  path: "/api/auth",
  httpOnly: true,
  secure: true,
  sameSite: "Lax" as const,
};

export function setAuthCookies(c: AuthContext, accessToken: string, refreshToken: string) {
  setCookie(c, ACCESS_COOKIE, accessToken, { ...cookieBase, maxAge: ACCESS_MAX_AGE });
  setCookie(c, REFRESH_COOKIE, refreshToken, { ...cookieBase, maxAge: REFRESH_MAX_AGE });
}

export function clearAuthCookies(c: AuthContext) {
  deleteCookie(c, ACCESS_COOKIE, cookieBase);
  deleteCookie(c, REFRESH_COOKIE, cookieBase);
}

export function getAccessTokenFromCookie(c: AuthContext): string | undefined {
  return getCookie(c, ACCESS_COOKIE);
}

export function getRefreshTokenFromCookie(c: AuthContext): string | undefined {
  return getCookie(c, REFRESH_COOKIE);
}

export function setOAuthStateCookie(c: AuthContext, state: string): void {
  setCookie(c, OAUTH_STATE_COOKIE, state, {
    ...oauthStateCookieBase,
    maxAge: OAUTH_STATE_MAX_AGE,
  });
}

export function getOAuthStateCookie(c: AuthContext): string | undefined {
  return getCookie(c, OAUTH_STATE_COOKIE);
}

export function clearOAuthStateCookie(c: AuthContext): void {
  deleteCookie(c, OAUTH_STATE_COOKIE, oauthStateCookieBase);
}

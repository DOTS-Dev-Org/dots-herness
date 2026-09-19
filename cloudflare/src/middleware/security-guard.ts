import { createMiddleware } from "hono/factory";
import type { Context } from "hono";
import type { Env, AppVariables } from "../env";
import { checkRateLimit, getClientIp } from "./rate-limit";

/** Per-IP limits (requests per 60s window). */
export const RATE_LIMITS = {
  rest: 100,
  "public-rest": 30,
  admin: 30,
} as const;

export type SecurityZone = keyof typeof RATE_LIMITS;

const WINDOW_SEC = 60;

/** Obvious SQLi / probe patterns in query strings — blocked with 400 before DB. */
export const BLOCKED_QUERY_PATTERNS: RegExp[] = [
  /union\s+select/i,
  /;\s*drop/i,
  /--/,
  /\/\*/,
  /\bxp_/i,
  /benchmark\s*\(/i,
];

function resolveZone(path: string): SecurityZone | null {
  if (path === "/admin" || path.startsWith("/admin/")) return "admin";
  if (path === "/public-rest" || path.startsWith("/public-rest/")) return "public-rest";
  if (path.startsWith("/rest/public")) return "public-rest";
  if (path === "/rest" || path.startsWith("/rest/")) return "rest";
  return null;
}

function hasSuspiciousQuery(url: URL): boolean {
  const targets: string[] = [];
  if (url.search.length > 1) {
    try {
      targets.push(decodeURIComponent(url.search.slice(1)));
    } catch {
      targets.push(url.search.slice(1));
    }
  }
  url.searchParams.forEach((value) => {
    try {
      targets.push(decodeURIComponent(value));
    } catch {
      targets.push(value);
    }
  });
  return targets.some((chunk) => BLOCKED_QUERY_PATTERNS.some((p) => p.test(chunk)));
}

export function applySecurityHeaders(c: Context<{ Bindings: Env; Variables: AppVariables }>) {
  c.header("X-Content-Type-Options", "nosniff");
  c.header("X-Frame-Options", "DENY");
  c.header("Referrer-Policy", "no-referrer");
  c.header("Permissions-Policy", "camera=(), microphone=(), geolocation=()");
  c.header("Content-Security-Policy", "frame-ancestors 'none'; base-uri 'none'");
  const url = new URL(c.req.url);
  if (url.protocol === "https:" && !/^(localhost|127\.0\.0\.1|\[::1\])$/i.test(url.hostname)) {
    c.header("Strict-Transport-Security", "max-age=31536000; includeSubDomains");
  }
}

/** Reject cleartext requests outside local development. Cloudflare production URLs are HTTPS-only. */
export const httpsOnlyMiddleware = createMiddleware<{ Bindings: Env; Variables: AppVariables }>(
  async (c, next) => {
    const url = new URL(c.req.url);
    const localHost = /^(localhost|127\.0\.0\.1|\[::1\])$/i.test(url.hostname);
    if (url.protocol !== "https:" && !localHost) {
      return new Response("HTTPS required", { status: 426 });
    }
    await next();
  }
);

/** Apply the baseline headers to every response, including routes outside apiApp. */
export const securityHeadersMiddleware = createMiddleware<{
  Bindings: Env;
  Variables: AppVariables;
}>(async (c, next) => {
  await next();
  applySecurityHeaders(c);
});

async function runGuard(
  c: Context<{ Bindings: Env; Variables: AppVariables }>,
  zone: SecurityZone
): Promise<Response | null> {
  const url = new URL(c.req.url);
  if (hasSuspiciousQuery(url)) {
    applySecurityHeaders(c);
    return c.json({ error: "Bad request" }, 400);
  }

  const result = await checkRateLimit(
    c.env,
    `sg:${zone}:${getClientIp(c)}`,
    RATE_LIMITS[zone],
    WINDOW_SEC
  );

  if (!result.allowed) {
    c.header("Retry-After", String(result.retryAfter));
    applySecurityHeaders(c);
    return c.json({ error: "Too many requests" }, 429);
  }

  return null;
}

/** Per-route security guard (rest/admin sub-apps). Prefer `securityGuardMiddleware` on apiApp. */
export function securityGuard(zone: SecurityZone) {
  return createMiddleware<{ Bindings: Env; Variables: AppVariables }>(async (c, next) => {
    const blocked = await runGuard(c, zone);
    if (blocked) return blocked;
    await next();
    applySecurityHeaders(c);
  });
}

/**
 * WAF-like hardening for /api/rest/* and /api/admin/* — rate limits, query probes, security headers.
 * Mount on apiApp before rest/admin route handlers.
 */
export const securityGuardMiddleware = createMiddleware<{ Bindings: Env; Variables: AppVariables }>(
  async (c, next) => {
    const zone = resolveZone(c.req.path);
    if (!zone) {
      await next();
      return;
    }

    const blocked = await runGuard(c, zone);
    if (blocked) return blocked;

    await next();
    applySecurityHeaders(c);
  }
);

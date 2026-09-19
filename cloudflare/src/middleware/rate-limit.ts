import { createMiddleware } from "hono/factory";
import type { Context } from "hono";
import type { Env, AppVariables } from "../env";
import { db } from "../db/client";

export type RateLimitOptions = {
  limit: number;
  windowSeconds: number;
  key?: string;
  keyPrefix?: string;
};

export type RateLimitResult = {
  allowed: boolean;
  retryAfter: number;
};

/** Client IP from Cloudflare or reverse-proxy headers. */
export function getClientIp(c: Context | { req: { header: (name: string) => string | undefined } }): string {
  const header = c.req.header.bind(c.req);
  return (
    header("CF-Connecting-IP")?.trim() ||
    header("cf-connecting-ip")?.trim() ||
    header("X-Forwarded-For")?.split(",")[0]?.trim() ||
    header("x-forwarded-for")?.split(",")[0]?.trim() ||
    "unknown"
  );
}

/** Fixed-window rate limit backed by the D1 transient-state table. */
export async function checkRateLimit(
  env: Env,
  key: string,
  limit: number,
  windowSeconds: number
): Promise<RateLimitResult> {
  // Local/dev environments without D1 should remain usable. Production always
  // has DOTSHERNESS_DB; this guard keeps isolated route tests and local previews
  // from failing before the database binding is configured.
  if (!env.DOTSHERNESS_DB) return { allowed: true, retryAfter: 0 };

  const nowSec = Math.floor(Date.now() / 1000);
  const bucket = Math.floor(nowSec / windowSeconds);
  const retryAfter = windowSeconds - (nowSec % windowSeconds) || windowSeconds;
  const expiresAt = (bucket + 1) * windowSeconds + 5;

  // Atomic upsert: the CASE resets the counter when the window has rolled over,
  // otherwise increments it. A separate SELECT-then-INSERT would race under
  // concurrent requests and let bursts exceed `limit`.
  const row = await db(env)
    .prepare(
      `INSERT INTO request_rate_limits (rate_key, window_bucket, hit_count, expires_at)
       VALUES (?, ?, 1, ?)
       ON CONFLICT(rate_key) DO UPDATE SET
         window_bucket = excluded.window_bucket,
         hit_count = CASE
           WHEN request_rate_limits.window_bucket = excluded.window_bucket
           THEN request_rate_limits.hit_count + 1
           ELSE 1
         END,
         expires_at = excluded.expires_at
       RETURNING hit_count`
    )
    .bind(key, bucket, expiresAt)
    .first<{ hit_count: number }>();

  const current = row?.hit_count ?? 1;
  if (current > limit) return { allowed: false, retryAfter };

  return { allowed: true, retryAfter: 0 };
}

function resolveKey(opts: RateLimitOptions): string {
  return opts.key ?? opts.keyPrefix ?? "default";
}

export function rateLimit(opts: RateLimitOptions) {
  const key = resolveKey(opts);
  return createMiddleware<{ Bindings: Env; Variables: AppVariables }>(async (c, next) => {
    const ip = getClientIp(c);
    const result = await checkRateLimit(
      c.env,
      `${key}:${ip}`,
      opts.limit,
      opts.windowSeconds,
    );

    if (!result.allowed) {
      c.header("Retry-After", String(result.retryAfter));
      return c.json({ error: "Too many requests" }, 429);
    }

    await next();
  });
}

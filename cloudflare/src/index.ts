import { Hono } from "hono";
import type { Context } from "hono";
import type { Env, AppVariables } from "./env";
import { corsMiddleware } from "./middleware/cors";
import { csrfProtection } from "./middleware/csrf";
import { timingMiddleware } from "./middleware/timing";
import { httpsOnlyMiddleware, securityHeadersMiddleware } from "./middleware/security-guard";
import { apiApp, aitrackApp } from "./client-types";
import { createOpenApiRoutes } from "./openapi";
import mobileGithubOAuth from "./routes/mobile/github-oauth";
import { qrRoutes } from "./routes/api/auth";
import { marketplacePublic } from "./routes/api/marketplace";
import { harnessHelp } from "./routes/harness-help";
import { db } from "./db/client";
import { getAccessTokenFromCookie } from "./lib/auth-cookies";
import { verifyAccessToken } from "./lib/jwt";
import { getActiveAuthUser } from "./lib/users";
import { timingSafeEqual } from "./lib/paytr";
import {
  purgeStaleQrSessions,
  purgeExpiredRefreshTokens,
  purgeOldAuditEvents,
  purgeExpiredTransientState,
} from "./lib/retention";

function assetCacheControl(key: string): string {
  // User/provider uploads keep stable keys and may be replaced; keep their
  // edge/browser freshness bounded. Catalog assets are public but also not
  // content-hashed, so they use the same safe TTL.
  if (key.startsWith("avatars/") || key.startsWith("provider-logos/") || key.startsWith("providers/")) {
    return "public, max-age=3600, s-maxage=3600";
  }
  // Marketplace artifact keys are stable per release/target but a failed CI
  // retry may replace the object before the registry row is refreshed.
  if (key.startsWith("marketplace/")) {
    return "public, max-age=60, s-maxage=60";
  }
  return "public, max-age=86400, s-maxage=86400";
}

type AppContext = Context<{ Bindings: Env; Variables: AppVariables }>;

type MarketplaceSourceAccess = "public" | "private" | "denied";

async function marketplaceSourceAccess(c: AppContext, key: string): Promise<MarketplaceSourceAccess> {
  if (!key.startsWith("marketplace/plugins/") || !key.endsWith("/source.bundle")) return "public";

  const owner = await db(c.env).prepare(
    `SELECT p.owner_user_id, p.source_visibility
       FROM marketplace_releases r
       JOIN marketplace_plugins p ON p.id = r.plugin_id
      WHERE r.source_object_key = ?`
  ).bind(key).first<{ owner_user_id: string; source_visibility: string }>();
  if (!owner) return "denied";
  if (owner.source_visibility === "public") return "public";

  // The untrusted GitHub build step receives this header only for the one
  // source download step. It is never exposed to the compiler environment.
  const ciSecret = (c.env.MARKETPLACE_CI_SECRET || "").trim();
  const ciToken = c.req.header("X-Marketplace-CI-Token") || "";
  if (ciSecret && timingSafeEqual(ciSecret, ciToken)) return "private";

  const authorization = c.req.header("Authorization");
  const bearer = authorization?.match(/^Bearer\s+(\S+)/i)?.[1];
  const token = bearer || getAccessTokenFromCookie(c);
  if (!token) return "denied";
  try {
    const claims = await verifyAccessToken(c.env, token);
    const user = await getActiveAuthUser(c.env, claims.userId);
    return user?.id === owner.owner_user_id ? "private" : "denied";
  } catch {
    return "denied";
  }
}

async function serveAsset(c: AppContext) {
  const key = c.req.path.replace(/^\/assets\//, "");
  const sourceAccess = await marketplaceSourceAccess(c, key);
  if (sourceAccess === "denied") return new Response("Not Found", { status: 404 });
  const obj = await c.env.DOTSHERNESS_ASSETS.get(key);
  if (!obj) return new Response("Not Found", { status: 404 });
  const headers = new Headers();
  obj.writeHttpMetadata(headers);
  const cacheControl = sourceAccess === "private" ? "private, no-store" : assetCacheControl(key);
  headers.set("Cache-Control", cacheControl);
  headers.set("CDN-Cache-Control", cacheControl);
  headers.set("X-Content-Type-Options", "nosniff");
  return new Response(obj.body, { headers });
}

async function noStoreSensitiveResponses(c: { req: { path: string }; header: (name: string, value: string) => void }, next: () => Promise<void>) {
  await next();
  const path = c.req.path;
  if (path.startsWith("/api/") || path.startsWith("/aitrack/") || path.startsWith("/auth/")) {
    c.header("Cache-Control", "no-store, max-age=0");
    c.header("Pragma", "no-cache");
  }
}

const app = new Hono<{ Bindings: Env; Variables: AppVariables }>()
  .use("*", httpsOnlyMiddleware)
  .use("*", securityHeadersMiddleware)
  .use("*", corsMiddleware())
  .use("*", csrfProtection)
  .use("*", timingMiddleware)
  .use("*", noStoreSensitiveResponses)
  .route("/", mobileGithubOAuth)
  .get("/", (c) => c.json({ active: true, name: "DOTS Herness Unified Worker Backend" }))
  // Eski watch/mobil buildleri QR path'lerini /api prefix'i olmadan çağırıyor.
  .route("/auth/qr", qrRoutes)
  .route("/api", apiApp)
  .route("/aitrack", aitrackApp)
  .route("/harness", harnessHelp)
  .route("/harness", marketplacePublic)
  .route("/", createOpenApiRoutes())
  .get("/assets/*", (c) => serveAsset(c));

export type { ApiAppType, AitrackAppType } from "./client-types";
export default {
  fetch: app.fetch,
  scheduled: async (_event: ScheduledEvent, env: Env, ctx: ExecutionContext) => {
    // Purge 15 dakikada bir calisir; eski kayitlar AE'nin invocation basina
    // 250 data point limitine takilmadan kademeli tasinir. Gunluk abonelik
    // temizligi yalnizca 03:00 UTC turunda yapilir.
    // ponytail: skeleton cron only runs auth/security retention. Billing and
    // subscription-cleanup jobs from aiwatcher_web were dropped with their tables.
    const now = new Date();
    if (now.getUTCHours() === 3 && now.getUTCMinutes() === 0) {
      ctx.waitUntil(purgeStaleQrSessions(env));
      ctx.waitUntil(purgeExpiredRefreshTokens(env));
      ctx.waitUntil(purgeOldAuditEvents(env));
      ctx.waitUntil(purgeExpiredTransientState(env));
    }
  },
};

import type { Context } from "hono";
import type { Env, AppVariables } from "../env";

export const PRODUCTION_ALLOWED_ORIGINS = new Set([
  "https://herness.dots.net.tr",
  "https://aiwatcher.app",
]);

export const LOCAL_ALLOWED_ORIGINS = new Set([
  "http://localhost:3000",
  "http://127.0.0.1:3000",
  "http://localhost:3001",
  "http://127.0.0.1:3001",
  "http://localhost:3002",
  "http://127.0.0.1:3002",
]);

/** Kept as a compatibility export; request checks use isAllowedOrigin. */
export const ALLOWED_ORIGINS = new Set([
  ...PRODUCTION_ALLOWED_ORIGINS,
  ...LOCAL_ALLOWED_ORIGINS,
]);

export function isAllowedOrigin(
  env: Pick<Env, "ALLOW_LOCAL_ORIGINS"> | undefined,
  origin: string,
): boolean {
  return PRODUCTION_ALLOWED_ORIGINS.has(origin) ||
    (env?.ALLOW_LOCAL_ORIGINS === "1" && LOCAL_ALLOWED_ORIGINS.has(origin));
}

export function corsMiddleware() {
  return async (c: Context<{ Bindings: Env; Variables: AppVariables }>, next: () => Promise<void>) => {
    const origin = c.req.header("Origin") || "";
    if (c.req.method === "OPTIONS") {
      const headers: Record<string, string> = {
        "Access-Control-Allow-Methods": "GET, POST, PUT, PATCH, DELETE, OPTIONS",
        "Access-Control-Allow-Headers":
          "Content-Type, Authorization, Prefer, Accept, X-Workspace-Id, X-Device-Fingerprint, X-User-Email, X-Marketplace-CI-Token, X-Marketplace-OIDC-Token",
        Vary: "Origin",
        "Access-Control-Max-Age": "86400",
      };
      if (isAllowedOrigin(c.env, origin)) {
        headers["Access-Control-Allow-Origin"] = origin;
        headers["Access-Control-Allow-Credentials"] = "true";
      }
      return new Response(null, { status: 204, headers });
    }
    await next();
    if (isAllowedOrigin(c.env, origin)) {
      c.header("Access-Control-Allow-Origin", origin);
      c.header("Access-Control-Allow-Credentials", "true");
      c.header("Vary", "Origin");
    }
  };
}

export const MAX_AVATAR_BYTES = 2 * 1024 * 1024;

export function detectImageType(buffer: ArrayBuffer): string | null {
  const bytes = new Uint8Array(buffer.slice(0, 12));
  if (bytes.length < 4) return null;
  if (bytes[0] === 0x89 && bytes[1] === 0x50 && bytes[2] === 0x4e && bytes[3] === 0x47) return "png";
  if (bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff) return "jpeg";
  if (bytes[0] === 0x47 && bytes[1] === 0x49 && bytes[2] === 0x46) return "gif";
  const riff = String.fromCharCode(...bytes.slice(0, 4));
  const webp = String.fromCharCode(...bytes.slice(8, 12));
  if (riff === "RIFF" && webp === "WEBP") return "webp";
  return null;
}

import { SignJWT, jwtVerify } from "jose";
import type { Env } from "../env";
import { sqliteTimestamp } from "../db/client";

const ACCESS_TTL = "15m";
const REFRESH_TTL_DAYS = 30;

function secret(env: Env): Uint8Array {
  const key = env.JWT_SECRET;
  if (!key) {
    // Fail closed: signing/verifying with a hardcoded fallback would let anyone
    // forge tokens (incl. admin). Set JWT_SECRET via `wrangler secret put JWT_SECRET`
    // in prod and in .dev.vars for local dev.
    throw new Error("JWT_SECRET is not configured");
  }
  return new TextEncoder().encode(key);
}

export async function signAccessToken(env: Env, payload: { sub: string; email: string; role: string }) {
  return new SignJWT({ email: payload.email, role: payload.role })
    .setProtectedHeader({ alg: "HS256" })
    .setSubject(payload.sub)
    .setIssuer(env.JWT_ISSUER || "dotsherness")
    .setIssuedAt()
    .setExpirationTime(ACCESS_TTL)
    .sign(secret(env));
}

export async function signRefreshToken(env: Env, userId: string) {
  return new SignJWT({ type: "refresh" })
    .setProtectedHeader({ alg: "HS256" })
    .setSubject(userId)
    .setIssuer(env.JWT_ISSUER || "dotsherness")
    .setIssuedAt()
    .setExpirationTime(`${REFRESH_TTL_DAYS}d`)
    .sign(secret(env));
}

export async function verifyAccessToken(env: Env, token: string) {
  const { payload } = await jwtVerify(token, secret(env), {
    issuer: env.JWT_ISSUER || "dotsherness",
  });
  return {
    userId: payload.sub as string,
    email: payload.email as string,
    role: payload.role as string,
  };
}

export async function verifyRefreshToken(env: Env, token: string) {
  const { payload } = await jwtVerify(token, secret(env), {
    issuer: env.JWT_ISSUER || "dotsherness",
  });
  if (payload.type !== "refresh") throw new Error("invalid_token");
  return payload.sub as string;
}

export async function hashToken(token: string): Promise<string> {
  const data = new TextEncoder().encode(token);
  const digest = await crypto.subtle.digest("SHA-256", data);
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

export function refreshExpiresAt(): string {
  const d = new Date();
  d.setDate(d.getDate() + REFRESH_TTL_DAYS);
  return sqliteTimestamp(d);
}

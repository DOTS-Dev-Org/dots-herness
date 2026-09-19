import type { Env } from "../env";
import { wrapD1 } from "./d1-compat";

export type DbHandle = D1Database;

export function db(env: Env): DbHandle {
  if (!env.DOTSHERNESS_DB) {
    throw new Error("No database configured (DOTSHERNESS_DB binding missing)");
  }
  return wrapD1(env.DOTSHERNESS_DB);
}

export function uuid(): string {
  return crypto.randomUUID();
}

/** Stable primary-key value for retry-safe append-only records. */
export async function stableId(parts: readonly unknown[]): Promise<string> {
  const bytes = new TextEncoder().encode(JSON.stringify(parts));
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return `h_${Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("")}`;
}

export function nowIso(): string {
  return new Date().toISOString();
}

/** SQLite/D1 UTC timestamp format used by expiry columns and SQL comparisons. */
export function sqliteTimestamp(date = new Date()): string {
  return date.toISOString().slice(0, 19).replace("T", " ");
}

/** Parse both deployed ISO timestamps and the canonical SQLite UTC format. */
export function timestampMs(value: string): number {
  const normalized = value.includes("T") ? value : `${value.replace(" ", "T")}Z`;
  return Date.parse(normalized);
}

export function normalizeEmail(email: string): string {
  return email.toLowerCase().trim();
}

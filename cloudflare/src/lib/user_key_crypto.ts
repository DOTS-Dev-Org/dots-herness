/**
 * At-rest encryption for user_connections.key_value.
 *
 * New values use a user-id-bound AES-256-GCM key. The v1 email-bound format
 * remains readable so existing rows can be re-encrypted lazily or through the
 * admin endpoint after the user_connections.user_id backfill.
 *
 * Formats:
 * - enc:v1:<base64url(iv)>.<base64url(ciphertext||tag)> — legacy email-bound
 * - enc:v2:<base64url(iv)>.<base64url(ciphertext||tag)> — user-id-bound
 */

import type { Env } from "../env";
import { normalizeEmail } from "../db/client";

export const USER_KEY_ENC_PREFIX = "enc:v2:";
export const LEGACY_USER_KEY_ENC_PREFIX = "enc:v1:";

const V1_SALT = "aiwatcher-user-keys-v1";
const V2_SALT = "aiwatcher-user-keys-v2";
const IV_BYTES = 12;

function b64urlEncode(buf: ArrayBuffer | Uint8Array): string {
  const bytes = buf instanceof Uint8Array ? buf : new Uint8Array(buf);
  let bin = "";
  for (let i = 0; i < bytes.length; i++) bin += String.fromCharCode(bytes[i]!);
  return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function b64urlDecode(s: string): Uint8Array {
  const pad = s.length % 4 === 0 ? "" : "=".repeat(4 - (s.length % 4));
  const b64 = s.replace(/-/g, "+").replace(/_/g, "/") + pad;
  const bin = atob(b64);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

function jwtSecret(env: Env): string {
  const key = env.JWT_SECRET;
  if (!key) throw new Error("JWT_SECRET is not configured");
  return key;
}

async function deriveUserKey(
  env: Env,
  identity: string,
  version: 1 | 2
): Promise<CryptoKey> {
  const enc = new TextEncoder();
  const baseKey = await crypto.subtle.importKey(
    "raw",
    enc.encode(jwtSecret(env)),
    "HKDF",
    false,
    ["deriveKey"]
  );
  const info = version === 1 ? `user-key:${normalizeEmail(identity)}` : `user-key:id:${identity}`;
  return crypto.subtle.deriveKey(
    {
      name: "HKDF",
      hash: "SHA-256",
      salt: enc.encode(version === 1 ? V1_SALT : V2_SALT),
      info: enc.encode(info),
    },
    baseKey,
    { name: "AES-GCM", length: 256 },
    false,
    ["encrypt", "decrypt"]
  );
}

export function isEncryptedUserKey(stored: string | null | undefined): boolean {
  return (
    typeof stored === "string" &&
    (stored.startsWith(LEGACY_USER_KEY_ENC_PREFIX) || stored.startsWith(USER_KEY_ENC_PREFIX))
  );
}

export function isCurrentUserKeyEncryption(stored: string | null | undefined): boolean {
  return typeof stored === "string" && stored.startsWith(USER_KEY_ENC_PREFIX);
}

/** Encrypt plaintext API key for storage under user_connections.user_id. */
export async function encryptUserKeyValue(
  env: Env,
  userId: string,
  plaintext: string
): Promise<string> {
  const key = await deriveUserKey(env, userId, 2);
  const iv = crypto.getRandomValues(new Uint8Array(IV_BYTES));
  const enc = new TextEncoder();
  const aad = enc.encode(userId);
  const cipher = await crypto.subtle.encrypt(
    { name: "AES-GCM", iv, additionalData: aad },
    key,
    enc.encode(plaintext)
  );
  return `${USER_KEY_ENC_PREFIX}${b64urlEncode(iv)}.${b64urlEncode(cipher)}`;
}

/**
 * Decrypt stored key_value. Plaintext legacy values are returned as-is.
 * v1 rows use the email-bound key; v2 rows use the canonical user id.
 */
export async function decryptUserKeyValue(
  env: Env,
  userId: string,
  userEmail: string,
  stored: string
): Promise<string> {
  if (!isEncryptedUserKey(stored)) return stored;

  const version: 1 | 2 = stored.startsWith(LEGACY_USER_KEY_ENC_PREFIX) ? 1 : 2;
  const prefix = version === 1 ? LEGACY_USER_KEY_ENC_PREFIX : USER_KEY_ENC_PREFIX;
  const payload = stored.slice(prefix.length);
  const dot = payload.indexOf(".");
  if (dot <= 0) throw new Error("invalid_encrypted_key");

  const iv = b64urlDecode(payload.slice(0, dot));
  const data = b64urlDecode(payload.slice(dot + 1));
  if (iv.length !== IV_BYTES) throw new Error("invalid_encrypted_key");

  const identity = version === 1 ? userEmail : userId;
  const key = await deriveUserKey(env, identity, version);
  const enc = new TextEncoder();
  const aad = enc.encode(version === 1 ? normalizeEmail(userEmail) : userId);
  try {
    const plain = await crypto.subtle.decrypt(
      { name: "AES-GCM", iv, additionalData: aad },
      key,
      data
    );
    return new TextDecoder().decode(plain);
  } catch {
    throw new Error("key_decrypt_failed");
  }
}

/**
 * Decrypt for use and best-effort migrate plaintext/v1 values to v2.
 * Returns null when stored is empty.
 */
export async function resolveUserKeyValue(
  env: Env,
  userId: string,
  userEmail: string,
  stored: string | null | undefined,
  opts?: {
    /** When set, migrate a plaintext/v1 value to v2 in that row. */
    reencryptKeyId?: string;
    db?: D1Database;
  }
): Promise<string | null> {
  if (stored == null || stored === "") return null;

  const plain = await decryptUserKeyValue(env, userId, userEmail, stored);
  if (opts?.reencryptKeyId && opts.db && !isCurrentUserKeyEncryption(stored)) {
    try {
      const cipher = await encryptUserKeyValue(env, userId, plain);
      await opts.db
        .prepare("UPDATE user_connections SET key_value = ? WHERE id = ? AND user_id = ?")
        .bind(cipher, opts.reencryptKeyId, userId)
        .run();
    } catch {
      /* best-effort re-encrypt */
    }
  }
  return plain;
}

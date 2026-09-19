import type { Env } from "../env";

const encoder = new TextEncoder();

/**
 * The extension uses this token only for live usage reads/writes against the
 * self-hosted VPS. It is deliberately short-lived and user/workspace scoped;
 * the VPS API secret never leaves the Worker.
 */
export const VPS_CLIENT_TOKEN_TTL_SECS = 6 * 60 * 60;

function base64UrlEncode(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
}

async function sign(payload: string, secret: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"]
  );
  const mac = await crypto.subtle.sign("HMAC", key, encoder.encode(payload));
  return base64UrlEncode(new Uint8Array(mac));
}

export async function issueVpsClientToken(
  env: Env,
  userId: string,
  workspaceId: string
): Promise<{ token: string; expires_at: number } | null> {
  if (!env.VPS_API_URL || !env.VPS_API_SECRET || !userId || !workspaceId) return null;

  const iat = Math.floor(Date.now() / 1000);
  const exp = iat + VPS_CLIENT_TOKEN_TTL_SECS;
  const payload = base64UrlEncode(
    encoder.encode(
      JSON.stringify({
        v: 1,
        scope: "usage",
        user_id: userId,
        workspace_id: workspaceId,
        iat,
        exp,
      })
    )
  );
  const unsigned = `v1.${payload}`;
  const signature = await sign(unsigned, env.VPS_API_SECRET);
  return { token: `${unsigned}.${signature}`, expires_at: exp * 1000 };
}

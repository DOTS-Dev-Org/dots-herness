// GitHub Actions OIDC token verification shared by the Marketplace build
// callback and HerNess cloud runs. Callers check the repository/workflow
// claims that matter to them; this module only proves the token is a live,
// GitHub-signed token for the expected audience.

export const GITHUB_OIDC_ISSUER = "https://token.actions.githubusercontent.com";

export type GitHubOIDCClaims = {
  iss?: string;
  aud?: string | string[];
  exp?: number;
  nbf?: number;
  sub?: string;
  repository?: string;
  repository_id?: string;
  workflow_ref?: string;
  event_name?: string;
  ref?: string;
  run_id?: string;
  run_attempt?: string;
  actor?: string;
};

let githubOIDCKeys: { expiresAt: number; keys: Record<string, JsonWebKey> } | null = null;

export function decodeBase64URL(value: string): Uint8Array {
  const normalized = value.replace(/-/g, "+").replace(/_/g, "/") + "=".repeat((4 - (value.length % 4)) % 4);
  const binary = atob(normalized);
  return Uint8Array.from(binary, (character) => character.charCodeAt(0));
}

async function githubOIDCKeySet(forceRefresh = false): Promise<Record<string, JsonWebKey>> {
  if (!forceRefresh && githubOIDCKeys && githubOIDCKeys.expiresAt > Date.now()) return githubOIDCKeys.keys;
  const response = await fetch(`${GITHUB_OIDC_ISSUER}/.well-known/jwks`);
  if (!response.ok) throw new Error(`github_oidc_jwks_${response.status}`);
  const body = await response.json() as { keys?: Array<JsonWebKey & { kid?: string }> };
  const keys = Object.fromEntries((body.keys || []).filter((key) => key.kid).map((key) => [key.kid!, key]));
  githubOIDCKeys = { expiresAt: Date.now() + 10 * 60 * 1000, keys };
  return keys;
}

/** Returns the claims of a valid token for `audience`, or null. */
export async function verifyGitHubOIDC(token: string, audience: string): Promise<GitHubOIDCClaims | null> {
  if (!token || !audience) return null;
  const parts = token.split(".");
  if (parts.length !== 3) return null;
  let header: { alg?: string; kid?: string };
  let claims: GitHubOIDCClaims;
  try {
    header = JSON.parse(new TextDecoder().decode(decodeBase64URL(parts[0]))) as typeof header;
    claims = JSON.parse(new TextDecoder().decode(decodeBase64URL(parts[1]))) as GitHubOIDCClaims;
  } catch {
    return null;
  }
  if (header.alg !== "RS256" || !header.kid || claims.iss !== GITHUB_OIDC_ISSUER) return null;
  const audiences = Array.isArray(claims.aud) ? claims.aud : [claims.aud];
  if (!audiences.includes(audience)) return null;
  const now = Math.floor(Date.now() / 1000);
  if (typeof claims.exp !== "number" || claims.exp <= now || (typeof claims.nbf === "number" && claims.nbf > now + 30)) return null;

  let keyMaterial: JsonWebKey | undefined;
  try {
    keyMaterial = (await githubOIDCKeySet())[header.kid];
    if (!keyMaterial) keyMaterial = (await githubOIDCKeySet(true))[header.kid];
  } catch {
    return null;
  }
  if (!keyMaterial) return null;
  try {
    const key = await crypto.subtle.importKey(
      "jwk",
      keyMaterial,
      { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
      false,
      ["verify"],
    );
    const valid = await crypto.subtle.verify(
      { name: "RSASSA-PKCS1-v1_5" },
      key,
      decodeBase64URL(parts[2]),
      new TextEncoder().encode(`${parts[0]}.${parts[1]}`),
    );
    return valid ? claims : null;
  } catch {
    return null;
  }
}

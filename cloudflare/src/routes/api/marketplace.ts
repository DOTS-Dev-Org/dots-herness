import { Hono } from "hono";
import type { Context, Next } from "hono";
import { zValidator } from "@hono/zod-validator";
import { z } from "zod";
import type { Env, AppVariables } from "../../env";
import { db, uuid } from "../../db/client";
import { requireAuth } from "../../middleware/auth";
import { timingSafeEqual } from "../../lib/paytr";

const marketplaceApi = new Hono<{ Bindings: Env; Variables: AppVariables }>();
const marketplacePublic = new Hono<{ Bindings: Env; Variables: AppVariables }>();

const ID_PATTERN = /^[a-z0-9](?:[a-z0-9._-]{1,62}[a-z0-9])?$/;
const SEMVER_PATTERN = /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/;
const ARCHITECTURE_PATTERN = /^[a-z0-9](?:[a-z0-9._-]{0,30}[a-z0-9])?$/;
const DEFAULT_MAX_UPLOAD_BYTES = 50 * 1024 * 1024;
const DEFAULT_TARGETS = [
  { platform: "macos", architecture: "arm64" },
  { platform: "macos", architecture: "x64" },
  { platform: "windows", architecture: "x64" },
  { platform: "linux", architecture: "x64" },
] as const;

const targetSchema = z.object({
  platform: z.enum(["macos", "windows", "linux"]),
  architecture: z.enum(["arm64", "x64"]),
}).strict();

const targetsSchema = z.array(targetSchema).min(1).max(DEFAULT_TARGETS.length).default(
  DEFAULT_TARGETS.map((target) => ({ ...target })),
).superRefine((targets, ctx) => {
  const seen = new Set<string>();
  for (const target of targets) {
    const key = `${target.platform}/${target.architecture}`;
    if (seen.has(key)) {
      ctx.addIssue({ code: z.ZodIssueCode.custom, message: `duplicate target ${key}` });
    }
    seen.add(key);
    if (!DEFAULT_TARGETS.some((allowed) => allowed.platform === target.platform && allowed.architecture === target.architecture)) {
      ctx.addIssue({ code: z.ZodIssueCode.custom, message: `unsupported target ${key}` });
    }
  }
});
type MarketplaceTarget = z.infer<typeof targetSchema>;

const irParameterSchema = z.object({
  name: z.string().regex(/^[a-zA-Z][a-zA-Z0-9_.-]{0,63}$/),
  type: z.enum(["string", "number", "boolean", "object", "array"]),
  description: z.string().max(500).default(""),
  required: z.boolean().default(true),
}).strict();

const irPanelNodeSchema: z.ZodType<Record<string, unknown>> = z.lazy(() => z.object({
  type: z.enum(["vstack", "hstack", "text", "button", "field", "toggle", "spacer", "image"]),
  id: z.string().max(120).optional(),
  label: z.string().max(200).optional(),
  text: z.string().max(2_000).optional(),
  key: z.string().max(120).optional(),
  placeholder: z.string().max(200).optional(),
  tool: z.string().max(120).optional(),
  args: z.record(z.string(), z.string()).optional(),
  children: z.array(irPanelNodeSchema).max(100).optional(),
}).strict() as z.ZodType<Record<string, unknown>>);

const irSchema = z.object({
  version: z.literal(1),
  prompt: z.array(z.object({
    name: z.string().max(120),
    order: z.number().int().min(-10_000).max(10_000),
    text: z.string().max(20_000),
  }).strict()).max(100).default([]),
  tools: z.array(z.object({
    name: z.string().regex(/^[a-zA-Z][a-zA-Z0-9_.:-]{0,119}$/),
    description: z.string().max(2_000).default(""),
    parameters: z.array(irParameterSchema).max(64).default([]),
  }).strict()).max(100).default([]),
  events: z.array(z.object({
    name: z.string().regex(/^[a-zA-Z][a-zA-Z0-9_.:/-]{0,119}$/),
    direction: z.enum(["listen", "emit", "both"]).default("both"),
  }).strict()).max(100).default([]),
  settings: z.array(z.object({
    key: z.string().regex(/^[a-zA-Z][a-zA-Z0-9_.:-]{0,119}$/),
    type: z.enum(["string", "number", "boolean", "object", "array"]),
    default: z.unknown().optional(),
  }).strict()).max(100).default([]),
  panels: z.array(z.object({
    slot: z.enum(["conversation.composer.accessory", "shell.overlay", "settings.sections", "plugins.detail", "shell.sidebar.footer"]),
    id: z.string().max(120),
    order: z.number().int().min(-10_000).max(10_000),
    label: z.string().max(200),
    body: irPanelNodeSchema,
  }).strict()).max(50).default([]),
}).strict();

const manifestSchema = z.record(z.unknown()).optional().default({});

const metadataSchema = z.object({
  id: z.string().min(3).max(64).regex(ID_PATTERN),
  name: z.string().trim().min(1).max(120),
  description: z.string().max(4_000).default(""),
  author: z.string().trim().max(120).default(""),
  homepage: z.string().url().max(500).nullable().optional(),
  license: z.string().trim().min(1).max(64),
  source_visibility: z.enum(["public", "private"]).default("public"),
});

const releaseSchema = z.object({
  version: z.string().regex(SEMVER_PATTERN),
  license: z.string().trim().min(1).max(64),
  ir: irSchema,
  manifest: manifestSchema,
  targets: targetsSchema,
});

const createPluginSchema = metadataSchema.extend(releaseSchema.shape);

const ciCompleteSchema = z.object({
  platform: z.enum(["macos", "windows", "linux"]),
  architecture: z.string().regex(ARCHITECTURE_PATTERN),
  status: z.enum(["pending", "ready", "failed"]),
  error: z.string().max(2_000).optional().nullable(),
});

type PluginRow = {
  id: string;
  owner_user_id: string;
  name: string;
  description: string;
  author: string;
  homepage: string | null;
  license: string;
  verification_status: string;
  source_visibility: string;
  created_at: string;
  updated_at: string;
  unpublished_at: string | null;
};

type ReleaseRow = {
  id: string;
  plugin_id: string;
  version: string;
  license: string;
  manifest_json: string;
  ir_json: string;
  source_object_key: string | null;
  source_sha256: string | null;
  status: string;
  created_by: string;
  created_at: string;
  published_at: string | null;
};

type ArtifactRow = {
  release_id: string;
  platform: string;
  architecture: string;
  object_key: string | null;
  sha256: string | null;
  size: number;
  signature_json: string | null;
  build_status: "pending" | "ready" | "failed";
  build_error: string | null;
  built_at: string | null;
};

function jsonObject(value: string | null | undefined): Record<string, unknown> {
  if (!value) return {};
  try {
    const parsed = JSON.parse(value);
    return parsed && typeof parsed === "object" && !Array.isArray(parsed) ? parsed : {};
  } catch {
    return {};
  }
}

function maxUploadBytes(env: Env): number {
  const parsed = Number(env.MARKETPLACE_MAX_UPLOAD_BYTES || "");
  return Number.isFinite(parsed) && parsed > 0 ? Math.min(parsed, DEFAULT_MAX_UPLOAD_BYTES) : DEFAULT_MAX_UPLOAD_BYTES;
}

function publicAssetURL(env: Env, key: string): string {
  const base = (env.API_PUBLIC_URL || "https://dotsherness-unified-backend.dotsherness-unified-backend.workers.dev").replace(/\/$/, "");
  return `${base}/assets/${key.split("/").map(encodeURIComponent).join("/")}`;
}

function sourceKey(pluginID: string, releaseID: string): string {
  return `marketplace/plugins/${pluginID}/releases/${releaseID}/source.bundle`;
}

function artifactKey(pluginID: string, releaseID: string, platform: string, architecture: string): string {
  return `marketplace/plugins/${pluginID}/releases/${releaseID}/${platform}/${architecture}/plugin.dotsplugin`;
}

function validNativeDocument(
  ir: Record<string, unknown>,
  manifest: Record<string, unknown>,
  expectedID: string,
  expectedVersion: string,
): string | null {
  if (manifest.id !== expectedID) return "manifest id must match the Marketplace plugin id";
  if (manifest.version !== expectedVersion) return "manifest version must match the immutable release version";
  if (manifest.runtime !== "native") return "only native plugins are accepted";
  if (manifest.main !== undefined || ir.main !== undefined) return "script entrypoints are not supported";
  const library = typeof manifest.library === "string" ? manifest.library.trim() : "";
  if (
    !library ||
    library.startsWith("/") ||
    library.includes("\\") ||
    library.includes("\0") ||
    library.split("/").some((part) => part === "" || part === "." || part === "..")
  ) {
    return "native plugins require a safe compiled library path";
  }
  const serialized = JSON.stringify({ ir, manifest }).toLowerCase();
  if (serialized.includes('"runtime":"js"') || serialized.includes('"runtime":"javascript"')) {
    return "javascript runtime is not supported";
  }
  return null;
}

function parseKeyMaterial(value: string): JsonWebKey | null {
  try {
    const parsed = JSON.parse(value);
    if (parsed && typeof parsed === "object") return parsed as JsonWebKey;
  } catch {
    // The production secret may also be provided as a JWK base64/JSON string.
  }
  return null;
}

function base64(bytes: ArrayBuffer | Uint8Array): string {
  const view = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
  let binary = "";
  for (const byte of view) binary += String.fromCharCode(byte);
  return btoa(binary);
}

function normalizedBase64(value: string): string {
  return value.replace(/=+$/, "").replace(/-/g, "+").replace(/_/g, "/");
}

async function sha256(bytes: ArrayBuffer): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("");
}

async function signArtifact(env: Env, digest: string) {
  const raw = (env.MARKETPLACE_SIGNING_PRIVATE_KEY || "").trim();
  const publicKey = (env.MARKETPLACE_SIGNING_PUBLIC_KEY || "").trim();
  if (!raw || !publicKey) throw new Error("marketplace_signing_not_configured");
  const jwk = parseKeyMaterial(raw);
  if (!jwk || !jwk.x) throw new Error("marketplace_signing_key_must_be_jwk_json");
  if (normalizedBase64(base64(decodeBase64URL(jwk.x))) !== normalizedBase64(publicKey)) {
    throw new Error("marketplace_signing_public_key_mismatch");
  }
  const key = await crypto.subtle.importKey("jwk", jwk, { name: "Ed25519" } as any, false, ["sign"]);
  const signature = await crypto.subtle.sign({ name: "Ed25519" } as any, key, new TextEncoder().encode(digest));
  return {
    alg: "ed25519",
    sha256: digest,
    sig: base64(signature),
    publisher: env.MARKETPLACE_PUBLISHER_ID || "dots",
    publicKey,
  };
}

async function ownerPlugin(env: Env, id: string, userID: string): Promise<PluginRow | null> {
  return db(env).prepare("SELECT * FROM marketplace_plugins WHERE id = ? AND owner_user_id = ?").bind(id, userID).first<PluginRow>();
}

async function releaseForOwner(env: Env, releaseID: string, userID: string): Promise<{ plugin: PluginRow; release: ReleaseRow } | null> {
  const row = await db(env).prepare(
    `SELECT p.*, r.id AS release_id, r.plugin_id AS release_plugin_id, r.version,
            r.license, r.manifest_json, r.ir_json, r.source_object_key, r.source_sha256,
            r.status AS release_status, r.created_by AS release_created_by,
            r.created_at AS release_created_at, r.published_at AS release_published_at
       FROM marketplace_releases r
       JOIN marketplace_plugins p ON p.id = r.plugin_id
      WHERE r.id = ? AND p.owner_user_id = ?`
  ).bind(releaseID, userID).first<PluginRow & {
    release_id: string; release_plugin_id: string; version: string; license: string; manifest_json: string;
    ir_json: string; source_object_key: string | null; source_sha256: string | null;
    release_status: string; release_created_by: string; release_created_at: string; release_published_at: string | null;
  }>();
  if (!row) return null;
  return {
    plugin: row,
    release: {
      id: row.release_id,
      plugin_id: row.release_plugin_id,
      version: row.version,
      license: row.license,
      manifest_json: row.manifest_json,
      ir_json: row.ir_json,
      source_object_key: row.source_object_key,
      source_sha256: row.source_sha256,
      status: row.release_status,
      created_by: row.release_created_by,
      created_at: row.release_created_at,
      published_at: row.release_published_at,
    },
  };
}

async function artifactsFor(env: Env, releaseID: string): Promise<ArtifactRow[]> {
  const rows = await db(env).prepare("SELECT * FROM marketplace_artifacts WHERE release_id = ? ORDER BY platform, architecture").bind(releaseID).all<ArtifactRow>();
  return rows.results || [];
}

async function seedPendingArtifacts(
  env: Env,
  releaseID: string,
  targets: readonly MarketplaceTarget[] = DEFAULT_TARGETS,
): Promise<void> {
  for (const target of targets) {
    await db(env).prepare(
      `INSERT OR IGNORE INTO marketplace_artifacts (release_id, platform, architecture, build_status)
       VALUES (?, ?, ?, 'pending')`
    ).bind(releaseID, target.platform, target.architecture).run();
  }
}

async function markBuildFailure(env: Env, releaseID: string, error: string): Promise<void> {
  await db(env).prepare(
    `UPDATE marketplace_artifacts
        SET build_status = 'failed', build_error = ?, built_at = CURRENT_TIMESTAMP
      WHERE release_id = ? AND build_status = 'pending'`
  ).bind(error.slice(0, 2_000), releaseID).run();
}

function runnerForTarget(target: MarketplaceTarget): string | null {
  if (target.platform === "macos" && target.architecture === "arm64") return "macos-14";
  if (target.platform === "macos" && target.architecture === "x64") return "macos-13";
  if (target.platform === "windows" && target.architecture === "x64") return "windows-latest";
  if (target.platform === "linux" && target.architecture === "x64") return "ubuntu-latest";
  return null;
}

async function dispatchBuild(env: Env, release: ReleaseRow, plugin: PluginRow): Promise<boolean> {
  const endpoint = (env.MARKETPLACE_BUILD_DISPATCH_URL || "").trim();
  const token = (env.MARKETPLACE_BUILD_DISPATCH_TOKEN || "").trim();
  if (!endpoint || !token || !release.source_object_key || !release.source_sha256) return false;
  const storedTargets = await artifactsFor(env, release.id);
  const targets = storedTargets
    .map((artifact) => ({
      platform: artifact.platform,
      architecture: artifact.architecture,
    }))
    .filter((target): target is MarketplaceTarget =>
      DEFAULT_TARGETS.some((allowed) => allowed.platform === target.platform && allowed.architecture === target.architecture)
    )
    .map((target) => ({ ...target, runner: runnerForTarget(target) }))
    .filter((target): target is MarketplaceTarget & { runner: string } => target.runner !== null);
  const buildTargets = targets.length > 0
    ? targets
    : DEFAULT_TARGETS.map((target) => ({ ...target, runner: runnerForTarget(target)! }));
  const payload = {
    ref: env.MARKETPLACE_BUILD_DISPATCH_REF || "main",
    inputs: {
      release_id: release.id,
      plugin_id: plugin.id,
      version: release.version,
      source_url: publicAssetURL(env, release.source_object_key),
      source_sha256: release.source_sha256,
      targets: JSON.stringify(buildTargets),
    },
  };
  const response = await fetch(endpoint, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${token}`,
      Accept: "application/vnd.github+json",
      "Content-Type": "application/json",
      "X-GitHub-Api-Version": "2022-11-28",
      "User-Agent": "DotsHarness-Marketplace",
    },
    body: JSON.stringify(payload),
  });
  if (!response.ok) {
    console.error("marketplace build dispatch failed", response.status);
    return false;
  }
  return true;
}

function publicArtifact(env: Env, row: ArtifactRow) {
  const signature = jsonObject(row.signature_json);
  return {
    platform: row.platform,
    architecture: row.architecture,
    downloadURL: row.object_key ? publicAssetURL(env, row.object_key) : null,
    sha256: row.sha256,
    signature: Object.keys(signature).length ? signature : null,
    size: row.size || 0,
    status: row.build_status,
    error: row.build_status === "failed" ? row.build_error : null,
  };
}

async function registry(env: Env) {
  const plugins = await db(env).prepare(
    `SELECT * FROM marketplace_plugins
      WHERE unpublished_at IS NULL
      ORDER BY name COLLATE NOCASE, id`
  ).all<PluginRow>();
  const entries = [];
  for (const plugin of plugins.results || []) {
    const release = await db(env).prepare(
      `SELECT * FROM marketplace_releases
        WHERE plugin_id = ? AND status = 'published' AND source_object_key IS NOT NULL
        ORDER BY created_at DESC LIMIT 1`
    ).bind(plugin.id).first<ReleaseRow>();
    if (!release) continue;
    const storedArtifacts = await artifactsFor(env, release.id);
    const artifacts = storedArtifacts.length > 0 ? storedArtifacts : DEFAULT_TARGETS.map((target) => ({
      release_id: release.id,
      platform: target.platform,
      architecture: target.architecture,
      object_key: null,
      sha256: null,
      size: 0,
      signature_json: null,
      build_status: "pending" as const,
      build_error: null,
      built_at: null,
    }));
    entries.push({
      id: plugin.id,
      name: plugin.name,
      version: release.version,
      description: plugin.description,
      author: plugin.author,
      tier: "native",
      homepage: plugin.homepage,
      license: release.license || plugin.license,
      verificationStatus: plugin.verification_status,
      sourceVisibility: plugin.source_visibility,
      sourceURL: release.source_object_key && plugin.source_visibility === "public"
        ? publicAssetURL(env, release.source_object_key)
        : null,
      artifacts: artifacts.map((row) => publicArtifact(env, row)),
      screenshots: [],
    });
  }
  return { version: 2, generatedAt: new Date().toISOString(), plugins: entries };
}

const GITHUB_OIDC_ISSUER = "https://token.actions.githubusercontent.com";
let githubOIDCKeys: { expiresAt: number; keys: Record<string, JsonWebKey> } | null = null;

function decodeBase64URL(value: string): Uint8Array {
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

async function verifyGitHubOIDCToken(env: Env, token: string): Promise<boolean> {
  const audience = (env.MARKETPLACE_CI_OIDC_AUDIENCE || "").trim();
  const repository = (env.MARKETPLACE_CI_REPOSITORY || "").trim();
  const workflow = (env.MARKETPLACE_CI_WORKFLOW || "").trim();
  if (!audience || !repository || !workflow || !token) return false;

  const parts = token.split(".");
  if (parts.length !== 3) return false;
  let header: { alg?: string; kid?: string };
  let claims: {
    iss?: string;
    aud?: string | string[];
    exp?: number;
    nbf?: number;
    repository?: string;
    workflow_ref?: string;
    sub?: string;
  };
  try {
    header = JSON.parse(new TextDecoder().decode(decodeBase64URL(parts[0]))) as typeof header;
    claims = JSON.parse(new TextDecoder().decode(decodeBase64URL(parts[1]))) as typeof claims;
  } catch {
    return false;
  }
  if (header.alg !== "RS256" || !header.kid || claims.iss !== GITHUB_OIDC_ISSUER) return false;
  const audiences = Array.isArray(claims.aud) ? claims.aud : [claims.aud];
  if (!audiences.includes(audience) || claims.repository !== repository) return false;
  if (claims.sub && !claims.sub.startsWith(`repo:${repository}:`)) return false;
  const workflowRef = claims.workflow_ref || "";
  if (workflowRef.split("@", 1)[0] !== `${repository}/${workflow}`) return false;
  const now = Math.floor(Date.now() / 1000);
  if (typeof claims.exp !== "number" || claims.exp <= now || (typeof claims.nbf === "number" && claims.nbf > now + 30)) return false;

  let keyMaterial: JsonWebKey | undefined;
  try {
    keyMaterial = (await githubOIDCKeySet())[header.kid];
    if (!keyMaterial) keyMaterial = (await githubOIDCKeySet(true))[header.kid];
  } catch {
    return false;
  }
  if (!keyMaterial) return false;
  try {
    const key = await crypto.subtle.importKey(
      "jwk",
      keyMaterial,
      { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
      false,
      ["verify"],
    );
    return await crypto.subtle.verify(
      { name: "RSASSA-PKCS1-v1_5" },
      key,
      decodeBase64URL(parts[2]),
      new TextEncoder().encode(`${parts[0]}.${parts[1]}`),
    );
  } catch {
    return false;
  }
}

async function requireCi(
  c: Context<{ Bindings: Env; Variables: AppVariables }>,
  next: Next,
) {
  const expected = (c.env.MARKETPLACE_CI_SECRET || "").trim();
  const supplied = c.req.header("X-Marketplace-CI-Token") || "";
  const secretAuthorized = expected && timingSafeEqual(expected, supplied);
  const oidcAuthorized = !secretAuthorized && await verifyGitHubOIDCToken(
    c.env,
    c.req.header("X-Marketplace-OIDC-Token") || "",
  );
  if (!secretAuthorized && !oidcAuthorized) {
    const oidcConfigured = Boolean(
      c.env.MARKETPLACE_CI_OIDC_AUDIENCE &&
      c.env.MARKETPLACE_CI_REPOSITORY &&
      c.env.MARKETPLACE_CI_WORKFLOW,
    );
    return c.json({ error: expected || oidcConfigured ? "forbidden" : "ci_not_configured" }, expected || oidcConfigured ? 403 : 503);
  }
  await next();
}

marketplacePublic.get("/registry.json", async (c) => {
  const data = await registry(c.env);
  return c.json(data, 200, {
    "Cache-Control": "public, max-age=5, s-maxage=5",
    "CDN-Cache-Control": "public, max-age=5",
  });
});

marketplaceApi.get("/registry", async (c) => c.json(await registry(c.env)));

marketplaceApi.use("/plugins", requireAuth);
marketplaceApi.use("/plugins/*", requireAuth);
marketplaceApi.use("/me/*", requireAuth);
marketplaceApi.use("/releases/*", requireAuth);

marketplaceApi.post("/plugins", zValidator("json", createPluginSchema), async (c) => {
  const body = c.req.valid("json");
  const nativeError = validNativeDocument(body.ir, body.manifest, body.id, body.version);
  if (nativeError) return c.json({ error: "native_only", message: nativeError }, 400);
  const user = c.get("user");
  const existing = await db(c.env).prepare("SELECT owner_user_id FROM marketplace_plugins WHERE id = ?").bind(body.id).first<{ owner_user_id: string }>();
  if (existing) return c.json({ error: existing.owner_user_id === user.id ? "plugin_exists" : "plugin_id_taken" }, 409);
  const pluginID = body.id;
  const releaseID = uuid();
  const now = new Date().toISOString();
  try {
    await db(c.env).prepare(
      `INSERT INTO marketplace_plugins (id, owner_user_id, name, description, author, homepage, license, source_visibility, created_at, updated_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`
    ).bind(pluginID, user.id, body.name, body.description, body.author || user.name || user.email, body.homepage || null, body.license, body.source_visibility, now, now).run();
    await db(c.env).prepare(
      `INSERT INTO marketplace_releases (id, plugin_id, version, license, manifest_json, ir_json, status, created_by, created_at, published_at)
       VALUES (?, ?, ?, ?, ?, ?, 'draft', ?, ?, NULL)`
    ).bind(releaseID, pluginID, body.version, body.license, JSON.stringify(body.manifest), JSON.stringify(body.ir), user.id, now, now).run();
    await seedPendingArtifacts(c.env, releaseID, body.targets);
    return c.json({ plugin_id: pluginID, release_id: releaseID, status: "draft", verification_status: "unverified" }, 201);
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    if (/unique|constraint/i.test(message)) {
      const conflict = await db(c.env).prepare("SELECT owner_user_id FROM marketplace_plugins WHERE id = ?").bind(pluginID).first<{ owner_user_id: string }>();
      if (conflict) {
        return c.json({ error: conflict.owner_user_id === user.id ? "plugin_exists" : "plugin_id_taken" }, 409);
      }
    }
    await db(c.env).prepare("DELETE FROM marketplace_plugins WHERE id = ? AND owner_user_id = ?").bind(pluginID, user.id).run().catch(() => {});
    console.error("marketplace plugin create failed", message);
    return c.json({ error: "marketplace_create_failed" }, 500);
  }
});

marketplaceApi.post("/plugins/:id/releases", zValidator("json", releaseSchema), async (c) => {
  const id = c.req.param("id");
  const body = c.req.valid("json");
  const nativeError = validNativeDocument(body.ir, body.manifest, id, body.version);
  if (nativeError) return c.json({ error: "native_only", message: nativeError }, 400);
  const user = c.get("user");
  const plugin = await ownerPlugin(c.env, id, user.id);
  if (!plugin) return c.json({ error: "plugin_not_found" }, 404);
  const duplicate = await db(c.env).prepare("SELECT id FROM marketplace_releases WHERE plugin_id = ? AND version = ?").bind(id, body.version).first<{ id: string }>();
  if (duplicate) return c.json({ error: "release_version_exists" }, 409);
  const releaseID = uuid();
  const now = new Date().toISOString();
  try {
    await db(c.env).prepare(
      `INSERT INTO marketplace_releases (id, plugin_id, version, license, manifest_json, ir_json, status, created_by, created_at, published_at)
       VALUES (?, ?, ?, ?, ?, ?, 'draft', ?, ?, NULL)`
    ).bind(releaseID, id, body.version, body.license, JSON.stringify(body.manifest), JSON.stringify(body.ir), user.id, now, now).run();
  } catch (error) {
    const duplicateAfterRace = await db(c.env).prepare("SELECT id FROM marketplace_releases WHERE plugin_id = ? AND version = ?").bind(id, body.version).first<{ id: string }>();
    if (duplicateAfterRace) return c.json({ error: "release_version_exists" }, 409);
    console.error("marketplace release create failed", error instanceof Error ? error.message : error);
    return c.json({ error: "marketplace_release_create_failed" }, 500);
  }
  await seedPendingArtifacts(c.env, releaseID, body.targets);
  await db(c.env).prepare("UPDATE marketplace_plugins SET updated_at = ?, unpublished_at = NULL WHERE id = ?").bind(now, id).run();
  return c.json({ plugin_id: id, release_id: releaseID, status: "draft", verification_status: plugin.verification_status }, 201);
});

marketplaceApi.put("/releases/:releaseId/source", async (c) => {
  const releaseID = c.req.param("releaseId");
  const owned = await releaseForOwner(c.env, releaseID, c.get("user").id);
  if (!owned) return c.json({ error: "release_not_found" }, 404);
  if (owned.release.source_object_key) return c.json({ error: "source_immutable" }, 409);
  const length = Number(c.req.header("Content-Length") || "0");
  if (length > maxUploadBytes(c.env)) return c.json({ error: "upload_too_large", max_bytes: maxUploadBytes(c.env) }, 413);
  const data = await c.req.arrayBuffer();
  if (data.byteLength === 0 || data.byteLength > maxUploadBytes(c.env)) return c.json({ error: "invalid_source_bundle" }, 400);
  const key = sourceKey(owned.plugin.id, releaseID);
  const digest = await sha256(data);
  await c.env.DOTSHERNESS_ASSETS.put(key, data, {
    httpMetadata: { contentType: c.req.header("Content-Type") || "application/octet-stream", contentDisposition: "attachment" },
    customMetadata: { pluginId: owned.plugin.id, releaseId: releaseID, sha256: digest, kind: "marketplace-source" },
  });
  await db(c.env).prepare(
    `UPDATE marketplace_releases
        SET source_object_key = ?, source_sha256 = ?
      WHERE id = ?`
  ).bind(key, digest, releaseID).run();
  return c.json({
    release_id: releaseID,
    status: "draft",
    verification_status: "pending",
    source_url: owned.plugin.source_visibility === "public" ? publicAssetURL(c.env, key) : null,
    source_visibility: owned.plugin.source_visibility,
    sha256: digest,
    size: data.byteLength,
  });
});

marketplaceApi.post("/releases/:releaseId/build", async (c) => {
  const owned = await releaseForOwner(c.env, c.req.param("releaseId"), c.get("user").id);
  if (!owned) return c.json({ error: "release_not_found" }, 404);
  if (!owned.release.source_object_key || !owned.release.source_sha256) {
    return c.json({ error: "source_required" }, 409);
  }
  const queued = await dispatchBuild(c.env, owned.release, owned.plugin);
  if (!queued) await markBuildFailure(c.env, owned.release.id, "Marketplace CI build dispatch is not configured or unavailable.");
  return c.json({ release_id: owned.release.id, status: queued ? "pending" : "failed", queued }, 202);
});

marketplaceApi.get("/me/plugins", async (c) => {
  const rows = await db(c.env).prepare("SELECT * FROM marketplace_plugins WHERE owner_user_id = ? ORDER BY updated_at DESC").bind(c.get("user").id).all<PluginRow>();
  const result = [];
  for (const plugin of rows.results || []) {
    const releases = await db(c.env).prepare("SELECT * FROM marketplace_releases WHERE plugin_id = ? ORDER BY created_at DESC").bind(plugin.id).all<ReleaseRow>();
    const releaseData = [];
    for (const release of releases.results || []) {
      releaseData.push({ ...release, manifest: jsonObject(release.manifest_json), ir: jsonObject(release.ir_json), artifacts: await artifactsFor(c.env, release.id) });
    }
    result.push({ ...plugin, releases: releaseData });
  }
  return c.json({ plugins: result });
});

marketplaceApi.delete("/plugins/:id", async (c) => {
  const plugin = await ownerPlugin(c.env, c.req.param("id"), c.get("user").id);
  if (!plugin) return c.json({ error: "plugin_not_found" }, 404);
  await db(c.env).prepare("UPDATE marketplace_plugins SET unpublished_at = CURRENT_TIMESTAMP, updated_at = CURRENT_TIMESTAMP WHERE id = ?").bind(plugin.id).run();
  return c.json({ ok: true, id: plugin.id, status: "unpublished" });
});

marketplaceApi.use("/ci/*", requireCi);

marketplaceApi.put("/ci/:releaseId/artifacts/:platform/:architecture", async (c) => {
  const releaseID = c.req.param("releaseId");
  const platform = c.req.param("platform");
  const architecture = c.req.param("architecture");
  if (!["macos", "windows", "linux"].includes(platform)) return c.json({ error: "invalid_platform" }, 400);
  if (!ARCHITECTURE_PATTERN.test(architecture)) return c.json({ error: "invalid_architecture" }, 400);
  const release = await db(c.env).prepare("SELECT r.*, p.id AS plugin_id FROM marketplace_releases r JOIN marketplace_plugins p ON p.id = r.plugin_id WHERE r.id = ? AND r.status IN ('draft', 'published')").bind(releaseID).first<ReleaseRow & { plugin_id: string }>();
  if (!release) return c.json({ error: "release_not_found" }, 404);
  const requestedTarget = await db(c.env).prepare(
    "SELECT 1 AS requested FROM marketplace_artifacts WHERE release_id = ? AND platform = ? AND architecture = ?"
  ).bind(releaseID, platform, architecture).first<{ requested: number }>();
  if (!requestedTarget) return c.json({ error: "target_not_requested" }, 409);
  const length = Number(c.req.header("Content-Length") || "0");
  if (length > maxUploadBytes(c.env)) return c.json({ error: "upload_too_large", max_bytes: maxUploadBytes(c.env) }, 413);
  const data = await c.req.arrayBuffer();
  if (data.byteLength === 0 || data.byteLength > maxUploadBytes(c.env)) return c.json({ error: "invalid_artifact" }, 400);
  const digest = await sha256(data);
  let signature;
  try {
    signature = await signArtifact(c.env, digest);
  } catch (error) {
    console.error("marketplace artifact signing failed", error instanceof Error ? error.message : error);
    return c.json({ error: "marketplace_signing_unavailable" }, 503);
  }
  const key = artifactKey(release.plugin_id, releaseID, platform, architecture);
  await c.env.DOTSHERNESS_ASSETS.put(key, data, {
    httpMetadata: { contentType: "application/zip", contentDisposition: `attachment; filename="${release.plugin_id}-${release.version}-${platform}-${architecture}.dotsplugin"` },
    customMetadata: { pluginId: release.plugin_id, releaseId: releaseID, sha256: digest, kind: "marketplace-artifact" },
  });
  await db(c.env).prepare(
    `INSERT INTO marketplace_artifacts (release_id, platform, architecture, object_key, sha256, size, signature_json, build_status, built_at)
     VALUES (?, ?, ?, ?, ?, ?, ?, 'ready', CURRENT_TIMESTAMP)
     ON CONFLICT (release_id, platform, architecture) DO UPDATE SET object_key = excluded.object_key, sha256 = excluded.sha256, size = excluded.size, signature_json = excluded.signature_json, build_status = 'ready', build_error = NULL, built_at = CURRENT_TIMESTAMP`
  ).bind(releaseID, platform, architecture, key, digest, data.byteLength, JSON.stringify(signature)).run();
  await db(c.env).prepare(
    `UPDATE marketplace_releases
        SET status = 'published', published_at = COALESCE(published_at, CURRENT_TIMESTAMP)
      WHERE id = ? AND status = 'draft'`
  ).bind(releaseID).run();
  return c.json({ release_id: releaseID, platform, architecture, status: "ready", release_status: "published", sha256: digest, signature, download_url: publicAssetURL(c.env, key) });
});

marketplaceApi.post("/ci/:releaseId/complete", zValidator("json", ciCompleteSchema), async (c) => {
  const releaseID = c.req.param("releaseId");
  const body = c.req.valid("json");
  const release = await db(c.env).prepare("SELECT id, status FROM marketplace_releases WHERE id = ?").bind(releaseID).first<{ id: string; status: string }>();
  if (!release) return c.json({ error: "release_not_found" }, 404);
  if (!['draft', 'published'].includes(release.status)) return c.json({ error: "release_not_publishable" }, 409);
  const requestedTarget = await db(c.env).prepare(
    "SELECT 1 AS requested FROM marketplace_artifacts WHERE release_id = ? AND platform = ? AND architecture = ?"
  ).bind(releaseID, body.platform, body.architecture).first<{ requested: number }>();
  if (!requestedTarget) return c.json({ error: "target_not_requested" }, 409);
  if (body.status === "ready") {
    const artifact = await db(c.env).prepare(
      "SELECT build_status FROM marketplace_artifacts WHERE release_id = ? AND platform = ? AND architecture = ?"
    ).bind(releaseID, body.platform, body.architecture).first<{ build_status: string }>();
    if (artifact?.build_status !== "ready") return c.json({ error: "artifact_upload_required" }, 409);
  }
  await db(c.env).prepare(
    `INSERT INTO marketplace_artifacts (release_id, platform, architecture, build_status, build_error)
     VALUES (?, ?, ?, ?, ?)
     ON CONFLICT (release_id, platform, architecture) DO UPDATE SET build_status = excluded.build_status, build_error = excluded.build_error, built_at = CASE WHEN excluded.build_status = 'ready' THEN CURRENT_TIMESTAMP ELSE marketplace_artifacts.built_at END`
  ).bind(releaseID, body.platform, body.architecture, body.status, body.error || null).run();
  if (body.status === "ready") {
    await db(c.env).prepare(
      `UPDATE marketplace_releases
          SET status = 'published', published_at = COALESCE(published_at, CURRENT_TIMESTAMP)
        WHERE id = ? AND status = 'draft'`
    ).bind(releaseID).run();
  }
  return c.json({ ok: true, release_id: releaseID, platform: body.platform, architecture: body.architecture, status: body.status });
});

export { marketplaceApi, marketplacePublic };

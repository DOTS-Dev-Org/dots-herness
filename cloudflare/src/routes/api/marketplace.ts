import { Hono } from "hono";
import type { Context, Next } from "hono";
import { zValidator } from "@hono/zod-validator";
import { z } from "zod";
import type { Env, AppVariables } from "../../env";
import { db, nowIso, uuid } from "../../db/client";
import { requireAuth } from "../../middleware/auth";
import { checkRateLimit, getClientIp, rateLimit } from "../../middleware/rate-limit";
import { timingSafeEqual } from "../../lib/paytr";
import { decodeBase64URL, verifyGitHubOIDC } from "../../lib/github_oidc";
import { clientIpFromRequest, recordAudit } from "../../lib/audit";
import {
  MARKETPLACE_REPORT_REASONS,
  moderateMarketplaceRelease,
  type MarketplaceCatalogScope,
  type MarketplaceModerationInput,
} from "../../lib/marketplace-moderation";

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

const MAX_MODERATION_METADATA_BYTES = 250_000;

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

const reportSchema = z.object({
  release_id: z.string().uuid(),
  reason: z.enum(MARKETPLACE_REPORT_REASONS),
  details: z.string().trim().max(5_000).default(""),
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
  downloads: number;
  likes: number;
  featured: number;
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
  moderation_status: string;
  catalog_scope: MarketplaceCatalogScope;
  category: string;
  category_confidence: number;
  category_source: string;
  risk_level: string;
  risk_flags_json: string;
  permission_manifest_json: string;
  moderation_scores_json: string;
  moderation_reason: string;
  moderation_model: string | null;
  ai_reviewed_at: string | null;
  reviewed_by: string | null;
  reviewed_at: string | null;
  review_notes: string | null;
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

function jsonArray(value: string | null | undefined): string[] {
  if (!value) return [];
  try {
    const parsed = JSON.parse(value);
    return Array.isArray(parsed) ? parsed.filter((item): item is string => typeof item === "string") : [];
  } catch {
    return [];
  }
}

function metadataSize(value: unknown): number {
  try {
    return new TextEncoder().encode(JSON.stringify(value)).byteLength;
  } catch {
    return Number.POSITIVE_INFINITY;
  }
}

function moderationInput(
  plugin: PluginRow,
  release: Pick<ReleaseRow, "manifest_json" | "ir_json">,
): MarketplaceModerationInput {
  return {
    id: plugin.id,
    name: plugin.name,
    description: plugin.description,
    author: plugin.author,
    homepage: plugin.homepage,
    manifest: jsonObject(release.manifest_json),
    ir: jsonObject(release.ir_json),
  };
}

async function classifyRelease(
  env: Env,
  plugin: PluginRow,
  release: Pick<ReleaseRow, "manifest_json" | "ir_json" | "id">,
): Promise<void> {
  const decision = await moderateMarketplaceRelease(env, moderationInput(plugin, release));
  await db(env).prepare(
    `UPDATE marketplace_releases
        SET moderation_status = ?, catalog_scope = ?, category = ?,
            category_confidence = ?, category_source = ?, risk_level = ?,
            risk_flags_json = ?, permission_manifest_json = ?,
            moderation_scores_json = ?, moderation_reason = ?,
            moderation_model = ?, ai_reviewed_at = ?,
            reviewed_by = NULL, reviewed_at = NULL, review_notes = NULL
      WHERE id = ?`,
  ).bind(
    decision.status,
    decision.catalogScope,
    decision.category,
    decision.categoryConfidence,
    decision.model === "unavailable" ? "fallback" : "ai",
    decision.riskLevel,
    JSON.stringify(decision.riskFlags),
    JSON.stringify(decision.permissions),
    JSON.stringify(decision.scores),
    decision.reason,
    decision.model,
    nowIso(),
    release.id,
  ).run();
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
            r.created_at AS release_created_at, r.published_at AS release_published_at,
            r.moderation_status, r.catalog_scope, r.category, r.category_confidence,
            r.category_source, r.risk_level, r.risk_flags_json,
            r.permission_manifest_json, r.moderation_scores_json, r.moderation_reason,
            r.moderation_model, r.ai_reviewed_at, r.reviewed_by, r.reviewed_at,
            r.review_notes
       FROM marketplace_releases r
       JOIN marketplace_plugins p ON p.id = r.plugin_id
      WHERE r.id = ? AND p.owner_user_id = ?`
  ).bind(releaseID, userID).first<PluginRow & {
    release_id: string; release_plugin_id: string; version: string; license: string; manifest_json: string;
    ir_json: string; source_object_key: string | null; source_sha256: string | null;
    release_status: string; release_created_by: string; release_created_at: string; release_published_at: string | null;
    moderation_status: string; catalog_scope: MarketplaceCatalogScope; category: string;
    category_confidence: number; category_source: string; risk_level: string;
    risk_flags_json: string; permission_manifest_json: string; moderation_scores_json: string;
    moderation_reason: string; moderation_model: string | null; ai_reviewed_at: string | null;
    reviewed_by: string | null; reviewed_at: string | null; review_notes: string | null;
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
      moderation_status: row.moderation_status,
      catalog_scope: row.catalog_scope,
      category: row.category,
      category_confidence: row.category_confidence,
      category_source: row.category_source,
      risk_level: row.risk_level,
      risk_flags_json: row.risk_flags_json,
      permission_manifest_json: row.permission_manifest_json,
      moderation_scores_json: row.moderation_scores_json,
      moderation_reason: row.moderation_reason,
      moderation_model: row.moderation_model,
      ai_reviewed_at: row.ai_reviewed_at,
      reviewed_by: row.reviewed_by,
      reviewed_at: row.reviewed_at,
      review_notes: row.review_notes,
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

async function registry(env: Env, requestedScope: "core" | "community") {
  const plugins = await db(env).prepare(
    `SELECT * FROM marketplace_plugins
      WHERE unpublished_at IS NULL
      ORDER BY name COLLATE NOCASE, id`
  ).all<PluginRow>();
  const entries = [];
  for (const plugin of plugins.results || []) {
    const release = await db(env).prepare(
      `SELECT * FROM marketplace_releases
        WHERE plugin_id = ? AND source_object_key IS NOT NULL
        ORDER BY created_at DESC LIMIT 1`
    ).bind(plugin.id).first<ReleaseRow>();
    if (
      !release
      || release.status !== "published"
      || release.moderation_status !== "approved"
      || (requestedScope === "core" && release.catalog_scope !== "core")
      || (requestedScope === "community" && !["community", "experimental"].includes(release.catalog_scope))
    ) continue;
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
      releaseID: release.id,
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
      catalogScope: release.catalog_scope,
      category: release.category,
      categoryConfidence: release.category_confidence,
      riskLevel: release.risk_level,
      permissions: jsonArray(release.permission_manifest_json),
      moderationStatus: release.moderation_status,
      publishedAt: release.published_at,
      downloads: plugin.downloads,
      likes: plugin.likes,
      featured: plugin.featured === 1,
      artifacts: artifacts.map((row) => publicArtifact(env, row)),
      screenshots: [],
    });
  }
  return { version: 3, scope: requestedScope, generatedAt: new Date().toISOString(), plugins: entries };
}

const ARTIFACT_KEY_PATTERN = /^marketplace\/plugins\/([^/]+)\/releases\/[^/]+\/[^/]+\/[^/]+\/plugin\.dotsplugin$/;

/**
 * Counts a served artifact as one download. The same address counts once per
 * plugin per day, so retries, updates across architectures and refresh loops
 * do not inflate the public number.
 */
export async function recordMarketplaceDownload(env: Env, assetKey: string, ip: string): Promise<void> {
  const pluginID = assetKey.match(ARTIFACT_KEY_PATTERN)?.[1];
  if (!pluginID) return;
  const first = await checkRateLimit(env, `marketplace:download:${pluginID}:${ip}`, 1, 86_400);
  if (!first.allowed) return;
  await db(env).prepare("UPDATE marketplace_plugins SET downloads = downloads + 1 WHERE id = ?").bind(pluginID).run();
}

const CATALOG_KINDS = ["skill", "starter"] as const;
type CatalogKind = (typeof CATALOG_KINDS)[number];

function catalogKind(value: string): CatalogKind | null {
  return (CATALOG_KINDS as readonly string[]).includes(value) ? (value as CatalogKind) : null;
}

/** Skills or project starters as clients decode them, with the live counters merged in. */
async function catalog(env: Env, kind: CatalogKind) {
  const { results } = await db(env).prepare(
    `SELECT id, payload_json, downloads, likes, featured
       FROM marketplace_catalog_items
      WHERE kind = ?
      ORDER BY sort_order, id`
  ).bind(kind).all<{ id: string; payload_json: string; downloads: number; likes: number; featured: number }>();
  return (results || []).map((row) => ({
    ...jsonObject(row.payload_json),
    id: row.id,
    downloads: row.downloads,
    likes: row.likes,
    featured: row.featured === 1,
  }));
}

const CATALOG_CACHE = { "Cache-Control": "public, max-age=5, s-maxage=5", "CDN-Cache-Control": "public, max-age=5" };

marketplacePublic.get("/skills.json", async (c) => c.json(await catalog(c.env, "skill"), 200, CATALOG_CACHE));
marketplacePublic.get("/starters.json", async (c) => c.json(await catalog(c.env, "starter"), 200, CATALOG_CACHE));

// Skills download from their own source and starters are only a prompt, so the
// app reports the install. Same once-per-address-per-day rule as plugin artifacts.
marketplacePublic.post(
  "/catalog/:kind/:id/download",
  rateLimit({ limit: 120, windowSeconds: 3600, keyPrefix: "marketplace:catalog-download" }),
  async (c) => {
    const kind = catalogKind(c.req.param("kind"));
    const id = c.req.param("id");
    if (!kind) return c.json({ error: "catalog_kind_invalid" }, 400);
    const first = await checkRateLimit(c.env, `marketplace:download:${kind}:${id}:${getClientIp(c)}`, 1, 86_400);
    const row = await db(c.env).prepare(
      `UPDATE marketplace_catalog_items SET downloads = downloads + ? WHERE kind = ? AND id = ? RETURNING downloads`
    ).bind(first.allowed ? 1 : 0, kind, id).first<{ downloads: number }>();
    if (!row) return c.json({ error: "catalog_item_not_found" }, 404);
    return c.json({ downloads: row.downloads });
  },
);

async function verifyGitHubOIDCToken(env: Env, token: string): Promise<boolean> {
  const audience = (env.MARKETPLACE_CI_OIDC_AUDIENCE || "").trim();
  const repository = (env.MARKETPLACE_CI_REPOSITORY || "").trim();
  const workflow = (env.MARKETPLACE_CI_WORKFLOW || "").trim();
  if (!audience || !repository || !workflow || !token) return false;

  const claims = await verifyGitHubOIDC(token, audience);
  if (!claims || claims.repository !== repository) return false;
  if (claims.sub && !claims.sub.startsWith(`repo:${repository}:`)) return false;
  const workflowRef = claims.workflow_ref || "";
  return workflowRef.split("@", 1)[0] === `${repository}/${workflow}`;
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
  const data = await registry(c.env, "core");
  return c.json(data, 200, {
    "Cache-Control": "public, max-age=5, s-maxage=5",
    "CDN-Cache-Control": "public, max-age=5",
  });
});

marketplacePublic.get("/community-registry.json", async (c) => {
  const data = await registry(c.env, "community");
  return c.json(data, 200, {
    "Cache-Control": "public, max-age=30, s-maxage=30",
    "CDN-Cache-Control": "public, max-age=30, s-maxage=30",
  });
});

marketplaceApi.get("/registry", async (c) => c.json(await registry(c.env, "core")));
marketplaceApi.get("/community-registry", async (c) => c.json(await registry(c.env, "community")));

marketplaceApi.use("/plugins", requireAuth);
marketplaceApi.use("/plugins/*", requireAuth);
marketplaceApi.use("/me/*", requireAuth);
marketplaceApi.use("/catalog/*", requireAuth);
marketplaceApi.use("/releases/*", requireAuth);

marketplaceApi.post(
  "/plugins",
  rateLimit({ limit: 5, windowSeconds: 3600, keyPrefix: "marketplace:plugin-create" }),
  zValidator("json", createPluginSchema),
  async (c) => {
  const body = c.req.valid("json");
  if (metadataSize({ manifest: body.manifest, ir: body.ir }) > MAX_MODERATION_METADATA_BYTES) {
    return c.json({ error: "marketplace_metadata_too_large" }, 413);
  }
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
      `INSERT INTO marketplace_releases (id, plugin_id, version, license, manifest_json, ir_json, status, created_by, created_at, published_at, moderation_status)
       VALUES (?, ?, ?, ?, ?, ?, 'draft', ?, ?, NULL, 'pending_ai')`
    ).bind(releaseID, pluginID, body.version, body.license, JSON.stringify(body.manifest), JSON.stringify(body.ir), user.id, now, now).run();
    await seedPendingArtifacts(c.env, releaseID, body.targets);
    return c.json({
      plugin_id: pluginID,
      release_id: releaseID,
      status: "draft",
      moderation_status: "pending_ai",
      verification_status: "unverified",
    }, 201);
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
  },
);

marketplaceApi.post(
  "/plugins/:id/releases",
  rateLimit({ limit: 20, windowSeconds: 3600, keyPrefix: "marketplace:release-create" }),
  zValidator("json", releaseSchema),
  async (c) => {
  const id = c.req.param("id");
  const body = c.req.valid("json");
  if (metadataSize({ manifest: body.manifest, ir: body.ir }) > MAX_MODERATION_METADATA_BYTES) {
    return c.json({ error: "marketplace_metadata_too_large" }, 413);
  }
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
      `INSERT INTO marketplace_releases (id, plugin_id, version, license, manifest_json, ir_json, status, created_by, created_at, published_at, moderation_status)
       VALUES (?, ?, ?, ?, ?, ?, 'draft', ?, ?, NULL, 'pending_ai')`
    ).bind(releaseID, id, body.version, body.license, JSON.stringify(body.manifest), JSON.stringify(body.ir), user.id, now, now).run();
  } catch (error) {
    const duplicateAfterRace = await db(c.env).prepare("SELECT id FROM marketplace_releases WHERE plugin_id = ? AND version = ?").bind(id, body.version).first<{ id: string }>();
    if (duplicateAfterRace) return c.json({ error: "release_version_exists" }, 409);
    console.error("marketplace release create failed", error instanceof Error ? error.message : error);
    return c.json({ error: "marketplace_release_create_failed" }, 500);
  }
  await seedPendingArtifacts(c.env, releaseID, body.targets);
  await db(c.env).prepare(
    "UPDATE marketplace_plugins SET updated_at = ?, unpublished_at = NULL, verification_status = 'unverified' WHERE id = ?",
  ).bind(now, id).run();
  return c.json({
    plugin_id: id,
    release_id: releaseID,
    status: "draft",
    moderation_status: "pending_ai",
    verification_status: "unverified",
  }, 201);
  },
);

marketplaceApi.put(
  "/releases/:releaseId/source",
  rateLimit({ limit: 20, windowSeconds: 3600, keyPrefix: "marketplace:source-upload" }),
  async (c) => {
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

  try {
    await classifyRelease(c.env, owned.plugin, {
      id: owned.release.id,
      manifest_json: owned.release.manifest_json,
      ir_json: owned.release.ir_json,
    });
  } catch (error) {
    console.error("marketplace AI moderation failed", error instanceof Error ? error.message : error);
    await db(c.env).prepare(
      `UPDATE marketplace_releases
          SET moderation_status = 'pending_review', catalog_scope = 'community',
              category = 'other', category_confidence = 0, category_source = 'fallback',
              risk_level = 'unknown', moderation_reason = ?,
              permission_manifest_json = '[]', moderation_scores_json = '{}',
              ai_reviewed_at = ?
        WHERE id = ?`,
    ).bind("AI classification failed; manual review is required.", nowIso(), releaseID).run();
  }
  const moderation = await db(c.env).prepare(
    `SELECT moderation_status, catalog_scope, category, category_confidence,
            risk_level, risk_flags_json, permission_manifest_json, moderation_reason,
            moderation_model
       FROM marketplace_releases WHERE id = ?`,
  ).bind(releaseID).first<Record<string, unknown>>();
  return c.json({
    release_id: releaseID,
    status: "draft",
    moderation_status: moderation?.moderation_status || "pending_review",
    catalog_scope: moderation?.catalog_scope || "community",
    category: moderation?.category || "other",
    category_confidence: moderation?.category_confidence || 0,
    risk_level: moderation?.risk_level || "unknown",
    risk_flags: jsonArray(typeof moderation?.risk_flags_json === "string" ? moderation.risk_flags_json : null),
    permissions: jsonArray(typeof moderation?.permission_manifest_json === "string" ? moderation.permission_manifest_json : null),
    moderation_reason: moderation?.moderation_reason || "",
    moderation_model: moderation?.moderation_model || null,
    source_url: owned.plugin.source_visibility === "public" ? publicAssetURL(c.env, key) : null,
    source_visibility: owned.plugin.source_visibility,
    sha256: digest,
    size: data.byteLength,
  });
  },
);

marketplaceApi.post(
  "/releases/:releaseId/build",
  rateLimit({ limit: 20, windowSeconds: 3600, keyPrefix: "marketplace:build" }),
  async (c) => {
  const owned = await releaseForOwner(c.env, c.req.param("releaseId"), c.get("user").id);
  if (!owned) return c.json({ error: "release_not_found" }, 404);
  if (["rejected", "suspended"].includes(owned.release.moderation_status)) {
    return c.json({
      error: "marketplace_release_not_eligible",
      moderation_status: owned.release.moderation_status,
      moderation_reason: owned.release.moderation_reason,
    }, 409);
  }
  if (!owned.release.source_object_key || !owned.release.source_sha256) {
    return c.json({ error: "source_required" }, 409);
  }
  const queued = await dispatchBuild(c.env, owned.release, owned.plugin);
  if (!queued) await markBuildFailure(c.env, owned.release.id, "Marketplace CI build dispatch is not configured or unavailable.");
  return c.json({
    release_id: owned.release.id,
    status: queued ? "pending" : "failed",
    moderation_status: owned.release.moderation_status,
    queued,
  }, 202);
  },
);

marketplaceApi.get("/me/plugins", async (c) => {
  const rows = await db(c.env).prepare("SELECT * FROM marketplace_plugins WHERE owner_user_id = ? ORDER BY updated_at DESC").bind(c.get("user").id).all<PluginRow>();
  const result = [];
  for (const plugin of rows.results || []) {
    const releases = await db(c.env).prepare("SELECT * FROM marketplace_releases WHERE plugin_id = ? ORDER BY created_at DESC").bind(plugin.id).all<ReleaseRow>();
    const releaseData = [];
    for (const release of releases.results || []) {
      releaseData.push({
        ...release,
        manifest: jsonObject(release.manifest_json),
        ir: jsonObject(release.ir_json),
        permissions: jsonArray(release.permission_manifest_json),
        risk_flags: jsonArray(release.risk_flags_json),
        moderation_scores: jsonObject(release.moderation_scores_json),
        artifacts: await artifactsFor(c.env, release.id),
      });
    }
    result.push({ ...plugin, releases: releaseData });
  }
  return c.json({ plugins: result });
});

marketplaceApi.post(
  "/plugins/:id/reports",
  rateLimit({ limit: 10, windowSeconds: 3600, keyPrefix: "marketplace:reports" }),
  zValidator("json", reportSchema),
  async (c) => {
    const pluginID = c.req.param("id");
    const body = c.req.valid("json");
    const plugin = await db(c.env)
      .prepare("SELECT id, name FROM marketplace_plugins WHERE id = ? AND unpublished_at IS NULL")
      .bind(pluginID)
      .first<{ id: string; name: string }>();
    if (!plugin) return c.json({ error: "plugin_not_found" }, 404);

    const release = await db(c.env)
      .prepare("SELECT id, status, moderation_status FROM marketplace_releases WHERE id = ? AND plugin_id = ?")
      .bind(body.release_id, pluginID)
      .first<{ id: string; status: string; moderation_status: string }>();
    if (!release) return c.json({ error: "release_not_found" }, 404);

    const reporter = c.get("user");
    const reportID = uuid();
    try {
      await db(c.env).prepare(
        `INSERT INTO marketplace_reports (
           id, plugin_id, release_id, reporter_user_id, reason, details, status, created_at
         ) VALUES (?, ?, ?, ?, ?, ?, 'pending', ?)`
      ).bind(reportID, pluginID, release.id, reporter.id, body.reason, body.details, nowIso()).run();
    } catch (error) {
      if (/unique|constraint/i.test(error instanceof Error ? error.message : String(error))) {
        return c.json({ error: "report_already_exists" }, 409);
      }
      throw error;
    }

    const criticalReport = ["malware", "credential_theft", "data_exfiltration"].includes(body.reason);
    if (criticalReport && release.status === "published") {
      // ponytail: single report only flags; suspend after 2 distinct reporters to stop griefing delists.
      const distinct = await db(c.env).prepare(
        `SELECT COUNT(DISTINCT reporter_user_id) AS n FROM marketplace_reports WHERE release_id = ?`
      ).bind(release.id).first<{ n: number }>();
      if ((distinct?.n ?? 0) >= 2) {
        await db(c.env).prepare(
          `UPDATE marketplace_releases
              SET status = 'unpublished', moderation_status = 'suspended',
                  risk_level = 'critical', moderation_reason = ?
            WHERE id = ?`
        ).bind(`User reports require urgent review: ${body.reason}.`, release.id).run();
      } else {
        await db(c.env).prepare(
          `UPDATE marketplace_releases
              SET moderation_status = 'pending_review', risk_level = 'high',
                  moderation_reason = ?
            WHERE id = ? AND moderation_status = 'approved'`
        ).bind(`User report pending review: ${body.reason}.`, release.id).run();
      }
    }

    await recordAudit(c.env, {
      actorUserId: reporter.id,
      actorEmail: reporter.email,
      action: "marketplace.report",
      entityType: "marketplace_release",
      entityId: release.id,
      metadata: { pluginId: pluginID, reportId: reportID, reason: body.reason, critical: criticalReport },
      ip: clientIpFromRequest(c.req),
      userAgent: c.req.header("User-Agent") ?? null,
    });

    return c.json({
      ok: true,
      report_id: reportID,
      status: criticalReport ? "suspended_pending_review" : "pending",
    }, 201);
  },
);

marketplaceApi.get("/me/likes", async (c) => {
  const userID = c.get("user").id;
  const [plugins, items] = await db(c.env).batch<{ kind: string; id: string }>([
    db(c.env).prepare("SELECT 'plugin' AS kind, plugin_id AS id FROM marketplace_likes WHERE user_id = ?").bind(userID),
    db(c.env).prepare("SELECT kind, item_id AS id FROM marketplace_catalog_likes WHERE user_id = ?").bind(userID),
  ]);
  const ids = (kind: string) => [...(plugins.results || []), ...(items.results || [])]
    .filter((row) => row.kind === kind)
    .map((row) => row.id);
  return c.json({ plugin_ids: ids("plugin"), skill_ids: ids("skill"), starter_ids: ids("starter") });
});

marketplaceApi.post(
  "/catalog/:kind/:id/like",
  rateLimit({ limit: 120, windowSeconds: 3600, keyPrefix: "marketplace:like" }),
  zValidator("json", z.object({ liked: z.boolean() }).strict()),
  async (c) => {
    const kind = catalogKind(c.req.param("kind"));
    const id = c.req.param("id");
    if (!kind) return c.json({ error: "catalog_kind_invalid" }, 400);
    const item = await db(c.env)
      .prepare("SELECT 1 AS found FROM marketplace_catalog_items WHERE kind = ? AND id = ?")
      .bind(kind, id)
      .first<{ found: number }>();
    if (!item) return c.json({ error: "catalog_item_not_found" }, 404);
    await db(c.env).prepare(
      c.req.valid("json").liked
        ? "INSERT OR IGNORE INTO marketplace_catalog_likes (kind, item_id, user_id) VALUES (?, ?, ?)"
        : "DELETE FROM marketplace_catalog_likes WHERE kind = ? AND item_id = ? AND user_id = ?",
    ).bind(kind, id, c.get("user").id).run();
    const row = await db(c.env).prepare(
      `UPDATE marketplace_catalog_items
          SET likes = (SELECT COUNT(*) FROM marketplace_catalog_likes WHERE kind = ? AND item_id = ?)
        WHERE kind = ? AND id = ?
        RETURNING likes`,
    ).bind(kind, id, kind, id).first<{ likes: number }>();
    return c.json({ likes: row?.likes ?? 0 });
  },
);

marketplaceApi.post(
  "/plugins/:id/like",
  rateLimit({ limit: 120, windowSeconds: 3600, keyPrefix: "marketplace:like" }),
  zValidator("json", z.object({ liked: z.boolean() }).strict()),
  async (c) => {
    const id = c.req.param("id");
    const plugin = await db(c.env)
      .prepare("SELECT 1 AS found FROM marketplace_plugins WHERE id = ? AND unpublished_at IS NULL")
      .bind(id)
      .first<{ found: number }>();
    if (!plugin) return c.json({ error: "plugin_not_found" }, 404);
    await db(c.env).prepare(
      c.req.valid("json").liked
        ? "INSERT OR IGNORE INTO marketplace_likes (plugin_id, user_id) VALUES (?, ?)"
        : "DELETE FROM marketplace_likes WHERE plugin_id = ? AND user_id = ?",
    ).bind(id, c.get("user").id).run();
    // Recount instead of +/-1 so the counter can never drift from the like rows.
    const row = await db(c.env).prepare(
      `UPDATE marketplace_plugins
          SET likes = (SELECT COUNT(*) FROM marketplace_likes WHERE plugin_id = ?)
        WHERE id = ?
        RETURNING likes`,
    ).bind(id, id).first<{ likes: number }>();
    return c.json({ likes: row?.likes ?? 0 });
  },
);

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
        SET status = CASE WHEN moderation_status = 'approved' THEN 'published' ELSE status END,
            published_at = CASE WHEN moderation_status = 'approved' THEN COALESCE(published_at, CURRENT_TIMESTAMP) ELSE published_at END
      WHERE id = ? AND status = 'draft'`
  ).bind(releaseID).run();
  const releaseState = await db(c.env)
    .prepare("SELECT plugin_id, status, moderation_status, catalog_scope, category FROM marketplace_releases WHERE id = ?")
    .bind(releaseID)
    .first<{ plugin_id: string; status: string; moderation_status: string; catalog_scope: string; category: string }>();
  if (releaseState?.status === "published" && releaseState.moderation_status === "approved") {
    await db(c.env).prepare(
      "UPDATE marketplace_plugins SET verification_status = 'verified', updated_at = CURRENT_TIMESTAMP WHERE id = ?",
    ).bind(releaseState.plugin_id).run();
  }
  return c.json({
    release_id: releaseID,
    platform,
    architecture,
    status: "ready",
    release_status: releaseState?.status || "draft",
    moderation_status: releaseState?.moderation_status || "pending_review",
    catalog_scope: releaseState?.catalog_scope || "community",
    category: releaseState?.category || "other",
    sha256: digest,
    signature,
    download_url: publicAssetURL(c.env, key),
  });
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
          SET status = CASE WHEN moderation_status = 'approved' THEN 'published' ELSE status END,
              published_at = CASE WHEN moderation_status = 'approved' THEN COALESCE(published_at, CURRENT_TIMESTAMP) ELSE published_at END
        WHERE id = ? AND status = 'draft'`
    ).bind(releaseID).run();
  }
  const releaseState = await db(c.env)
    .prepare("SELECT plugin_id, status, moderation_status, catalog_scope, category FROM marketplace_releases WHERE id = ?")
    .bind(releaseID)
    .first<{ plugin_id: string; status: string; moderation_status: string; catalog_scope: string; category: string }>();
  if (releaseState?.status === "published" && releaseState.moderation_status === "approved") {
    await db(c.env).prepare(
      "UPDATE marketplace_plugins SET verification_status = 'verified', updated_at = CURRENT_TIMESTAMP WHERE id = ?",
    ).bind(releaseState.plugin_id).run();
  }
  return c.json({
    ok: true,
    release_id: releaseID,
    platform: body.platform,
    architecture: body.architecture,
    status: body.status,
    release_status: releaseState?.status || "draft",
    moderation_status: releaseState?.moderation_status || "pending_review",
    catalog_scope: releaseState?.catalog_scope || "community",
    category: releaseState?.category || "other",
  });
});

export { marketplaceApi, marketplacePublic };

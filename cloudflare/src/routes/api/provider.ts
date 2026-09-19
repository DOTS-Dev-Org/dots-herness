import { Hono } from "hono";
import { zValidator } from "@hono/zod-validator";
import { z } from "zod";
import type { Env, AppVariables } from "../../env";
import { db, normalizeEmail, nowIso, sqliteTimestamp, uuid } from "../../db/client";
import { requireAuth } from "../../middleware/auth";
import { rateLimit, checkRateLimit } from "../../middleware/rate-limit";
import {
  getUsageSnapshot,
  mapPlatformToProviderId,
  resolveWorkspaceForUser,
  syncVpsProviderPresence,
  upsertProviderUsageBatch,
} from "../../lib/users";
import { fetchUpstreamUsage, syncProviderUsageFromKey } from "../../lib/provider_fetch";
import { normalizeSyncInterval, clampSyncIntervalToPlan } from "../../lib/sync_interval";
import { planDefForSlug } from "../../lib/plan_features";
import { clientIpFromRequest, recordAudit } from "../../lib/audit";
import { maskApiKey } from "./team";
import { disconnectUserConnection } from "../../lib/provider_disconnect";
import { canConnectProvider } from "../../lib/plan_limits";
import {
  encryptUserKeyValue,
  resolveUserKeyValue,
} from "../../lib/user_key_crypto";
import {
  getVpsCacheValue,
  putVpsCacheValue,
  vpsCacheBust,
  vpsConfigured,
} from "../../lib/vps_usage";

// ponytail: statik map; yeni provider eklemek kod değişikliği ister,
// upgrade path = providers tablosuna login_url/usage_url kolonu eklemek.
const PROVIDER_URLS: Record<string, { login: string; usage: string }> = {
  claude: { login: "https://claude.ai/login", usage: "https://claude.ai/settings/usage" },
  openai: { login: "https://chatgpt.com/auth/login", usage: "https://chatgpt.com/#settings/Usage" },
  cursor: { login: "https://www.cursor.com/settings", usage: "https://www.cursor.com/settings" },
  windsurf: { login: "https://codeium.com/account/login", usage: "https://codeium.com/settings" },
  gemini: { login: "https://gemini.google.com/", usage: "https://aistudio.google.com/usage" },
  minimax: { login: "https://platform.minimax.io/login", usage: "https://platform.minimax.io/console/usage" },
  "github-copilot": { login: "https://github.com/login", usage: "https://github.com/settings/copilot" },
  perplexity: { login: "https://www.perplexity.ai/", usage: "https://www.perplexity.ai/settings/account" },
  deepseek: { login: "https://platform.deepseek.com/", usage: "https://platform.deepseek.com/usage" },
  groq: { login: "https://console.groq.com/login", usage: "https://console.groq.com/settings/usage" },
  commandcode: { login: "https://commandcode.ai/login", usage: "https://commandcode.ai/settings/usage" },
  cline: { login: "https://app.cline.bot/dashboard/subscription", usage: "https://app.cline.bot/dashboard/subscription" },
  opencode: { login: "https://opencode.ai/auth", usage: "https://opencode.ai/auth" },
};

const OAUTH_SESSION_TTL_S = 600;
const SCRAPE_SESSION_TTL_S = 900;

function forbiddenEmail(c: { get: (k: "user") => { email: string } }, email?: string | null) {
  return Boolean(email && normalizeEmail(email) !== c.get("user").email);
}

// ---------------------------------------------------------------------------
// /api/provider/*
// ---------------------------------------------------------------------------

export const providerRoutes = new Hono<{ Bindings: Env; Variables: AppVariables }>();

providerRoutes.use("*", requireAuth);

// Desktop ProviderConnect listesi: kullanıcının user_connections'ları + hesabın usage satırları.
// Her bağlantı (aynı provider'dan birden fazla hesap dahil) kendi entry'si olarak döner.
providerRoutes.get("/connected", async (c) => {
  const authUser = c.get("user");
  if (forbiddenEmail(c, c.req.query("email"))) return c.json({ error: "Forbidden" }, 403);

  await resolveWorkspaceForUser(c.env, authUser.id, c.get("workspaceId"));

  const { results: connectionRows } = await db(c.env)
    .prepare(
      "SELECT id, provider, account_label, scope FROM user_connections WHERE user_id = ? ORDER BY created_at DESC"
    )
    .bind(authUser.id)
    .all<{ id: string; provider: string; account_label: string | null; scope: string | null }>();

  if (!connectionRows || connectionRows.length === 0) return c.json({ providers: [] });

  const connections = connectionRows.map((r) => ({
    ...r,
    provider_id: mapPlatformToProviderId(r.provider),
  }));
  const providerIds = [...new Set(connections.map((c2) => c2.provider_id))];
  const placeholders = providerIds.map(() => "?").join(", ");
  const { results: metaRows } = await db(c.env)
    .prepare(`SELECT id, name, status FROM providers WHERE id IN (${placeholders})`)
    .bind(...providerIds)
    .all<{ id: string; name: string; status: string | null }>();
  const metaById = new Map((metaRows || []).map((m) => [m.id, m]));

  const snapshot = await getUsageSnapshot(c.env, authUser.id);

  const providers = connections.map((conn) => {
    const meta = metaById.get(conn.provider_id);
    const u = snapshot[conn.id];
    return {
      connection_id: conn.id,
      id: conn.provider_id,
      name: meta?.name ?? conn.provider_id,
      account_label: conn.account_label,
      scope: conn.scope ?? "personal",
      status: u?.error ? "error" : "connected",
      used_percent: u?.used_percent ?? null,
      used: u?.used ?? null,
      total: u?.total ?? null,
      updated_at: u?.updated_at ?? null,
      error: u?.error ?? null,
    };
  });

  return c.json({ providers });
});

// API key ile provider bağla → user_connections'a yazılır, tüm istemciler D1'den görür.
// Aynı provider'a birden fazla kez bağlanmak serbesttir — her çağrı yeni bir
// bağlantı (hesap) oluşturur, öncekini etkilemez.
providerRoutes.post("/connect", rateLimit({ limit: 20, windowSeconds: 60, keyPrefix: "provider:connect" }), zValidator("json", z.object({
  email: z.string().email().max(320).optional(),
  provider: z.string().trim().min(1).max(64),
  api_key: z.string().trim().min(1).max(4096),
  key_name: z.string().trim().max(120).optional(),
  account_label: z.string().trim().max(200).optional(),
  sync_interval_secs: z.number().int().optional(),
  scope: z.enum(["account", "personal"]).optional().default("personal"),
  validate_only: z.boolean().optional().default(false),
})), async (c) => {
  const body = c.req.valid("json");
  const authUser = c.get("user");
  if (forbiddenEmail(c, body.email)) return c.json({ error: "Forbidden" }, 403);

  const providerId = mapPlatformToProviderId(body.provider);
  const prov = await db(c.env)
    .prepare("SELECT id, name, support_type FROM providers WHERE id = ?")
    .bind(providerId)
    .first<{ id: string; name: string; support_type: string | null }>();
  if (!prov) return c.json({ error: "provider_not_found" }, 404);

  // The wizard uses this branch to test a key without creating an orphaned
  // connection. It intentionally runs before the plan/provider-limit gate, so
  // it gets its own tighter, user-keyed limit to prevent using it as a free
  // key-validation oracle against upstream providers.
  if (body.validate_only) {
    const probeLimit = await checkRateLimit(c.env, `provider:validate:${authUser.id}`, 5, 60);
    if (!probeLimit.allowed) {
      c.header("Retry-After", String(probeLimit.retryAfter));
      return c.json({ error: "Too many requests" }, 429);
    }
    const result = await fetchUpstreamUsage(providerId, body.api_key);
    return result.ok
      ? c.json({ ok: true, provider_id: providerId })
      : c.json(
          {
            ok: false,
            provider_id: providerId,
            error: result.error ?? "api_key_invalid",
          },
          422
        );
  }

  const account = await resolveWorkspaceForUser(c.env, authUser.id, c.get("workspaceId"));
  if (account?.workspace_id) {
    const gate = await canConnectProvider(
      c.env,
      account.workspace_id,
      account.max_providers,
      providerId
    );
    if (!gate.allowed) {
      return c.json(
        {
          error: "provider_limit_reached",
          message: "Plan provider limitine ulaşıldı",
          limit: gate.limit,
          used: gate.used,
        },
        403
      );
    }
  }

  const id = uuid();
  const masked = maskApiKey(body.api_key);
  const displayName = body.key_name?.trim() || prov.name;
  const createdAt = nowIso();
  const syncInterval = clampSyncIntervalToPlan(
    normalizeSyncInterval(body.sync_interval_secs),
    planDefForSlug(account?.plan_slug).min_sync_interval_secs
  );
  const scope = body.scope === "account" ? "account" : "personal";
  const encryptedKey = await encryptUserKeyValue(c.env, authUser.id, body.api_key);

  const accountLabel = body.account_label?.trim() || null;

  await db(c.env)
    .prepare(
      `INSERT INTO user_connections (id, user_id, user_email, provider, name, key_masked, key_value, created_at, sync_interval_secs, scope, account_label)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`
    )
    .bind(id, authUser.id, authUser.email, providerId, displayName, masked, encryptedKey, createdAt, syncInterval, scope, accountLabel)
    .run();
  await vpsCacheBust(c.env, { prefix: `conns:${authUser.id}` });
  if (account?.workspace_id) {
    await syncVpsProviderPresence(c.env, authUser.id, account.workspace_id, true);
  }

  let usage_sync: { ok: boolean; error?: string } | undefined;
  if (account?.workspace_id) {
    const fetchResult = await syncProviderUsageFromKey(
      c.env,
      account.workspace_id,
      authUser.id,
      authUser.email,
      providerId,
      body.api_key,
      id
    );
    usage_sync = fetchResult.ok
      ? { ok: true }
      : { ok: false, error: fetchResult.error };
  }

  await recordAudit(c.env, {
    workspaceId: account?.workspace_id,
    actorUserId: authUser.id,
    actorEmail: authUser.email,
    action: "key.create",
    entityType: "key",
    entityId: id,
    metadata: {
      provider_id: providerId,
      name: displayName,
      key_masked: masked,
      sync_interval_secs: syncInterval,
    },
    ip: clientIpFromRequest(c.req),
    userAgent: c.req.header("User-Agent") ?? null,
  });

  return c.json({
    ok: true,
    id,
    provider_id: providerId,
    key_masked: masked,
    sync_interval_secs: syncInterval,
    scope,
    usage_sync,
  });
});

providerRoutes.patch("/keys/:id", zValidator("json", z.object({
  name: z.string().trim().max(120).optional(),
  api_key: z.string().trim().min(1).max(4096).optional(),
  account_label: z.string().trim().max(200).nullable().optional(),
  sync_interval_secs: z.number().int().optional(),
  scope: z.enum(["account", "personal"]).optional(),
})), async (c) => {
  const keyId = c.req.param("id");
  const body = c.req.valid("json");
  const authUser = c.get("user");

  const row = await db(c.env)
    .prepare(
      `SELECT id, user_email, provider, name, key_value, sync_interval_secs, scope
         FROM user_connections WHERE id = ? AND user_id = ?`
    )
    .bind(keyId, authUser.id)
    .first<{
      id: string;
      user_email: string;
      provider: string;
      name: string;
      key_value: string;
      sync_interval_secs: number | null;
      scope: string | null;
    }>();
  if (!row) return c.json({ error: "key_not_found" }, 404);

  const account = await resolveWorkspaceForUser(c.env, authUser.id, c.get("workspaceId"));

  const updates: string[] = [];
  const params: unknown[] = [];

  if (body.name?.trim()) {
    updates.push("name = ?");
    params.push(body.name.trim());
  }
  if (body.sync_interval_secs != null) {
    updates.push("sync_interval_secs = ?");
    params.push(
      clampSyncIntervalToPlan(
        normalizeSyncInterval(body.sync_interval_secs),
        planDefForSlug(account?.plan_slug).min_sync_interval_secs
      )
    );
  }
  let nextKeyPlain: string | null = null;
  if (body.api_key?.trim()) {
    updates.push("key_value = ?");
    updates.push("key_masked = ?");
    nextKeyPlain = body.api_key.trim();
    const encrypted = await encryptUserKeyValue(c.env, authUser.id, nextKeyPlain);
    params.push(encrypted, maskApiKey(nextKeyPlain));
  }
  if (body.scope) {
    updates.push("scope = ?");
    params.push(body.scope);
  }
  if (body.account_label !== undefined) {
    updates.push("account_label = ?");
    params.push(body.account_label?.trim() || null);
  }

  if (updates.length === 0) {
    return c.json({ error: "no_updates" }, 400);
  }

  await db(c.env)
    .prepare(`UPDATE user_connections SET ${updates.join(", ")} WHERE id = ? AND user_id = ?`)
    .bind(...params, keyId, authUser.id)
    .run();
  await vpsCacheBust(c.env, { prefix: `conns:${authUser.id}` });

  const providerId = mapPlatformToProviderId(row.provider);
  let usage_sync: { ok: boolean; error?: string } | undefined;
  if (account?.workspace_id && nextKeyPlain) {
    const fetchResult = await syncProviderUsageFromKey(
      c.env,
      account.workspace_id,
      authUser.id,
      authUser.email,
      providerId,
      nextKeyPlain,
      keyId
    );
    usage_sync = fetchResult.ok
      ? { ok: true }
      : { ok: false, error: fetchResult.error };
  }

  const updated = await db(c.env)
    .prepare(
      `SELECT id, provider, name, key_masked, account_label, sync_interval_secs, scope, created_at
         FROM user_connections WHERE id = ?`
    )
    .bind(keyId)
    .first<{
      id: string;
      provider: string;
      name: string;
      key_masked: string;
      account_label: string | null;
      sync_interval_secs: number;
      scope: string | null;
      created_at: string;
    }>();

  await recordAudit(c.env, {
    workspaceId: account?.workspace_id,
    actorUserId: authUser.id,
    actorEmail: authUser.email,
    action: "key.update",
    entityType: "key",
    entityId: keyId,
    metadata: {
      provider_id: providerId,
      old_name: row.name,
      new_name: body.name?.trim() ?? row.name,
      key_rotated: Boolean(body.api_key?.trim()),
      old_sync_interval_secs: row.sync_interval_secs,
      new_sync_interval_secs:
        body.sync_interval_secs != null
          ? clampSyncIntervalToPlan(
              normalizeSyncInterval(body.sync_interval_secs),
              planDefForSlug(account?.plan_slug).min_sync_interval_secs
            )
          : row.sync_interval_secs,
      old_scope: row.scope ?? "account",
      new_scope: body.scope ?? row.scope ?? "account",
    },
    ip: clientIpFromRequest(c.req),
    userAgent: c.req.header("User-Agent") ?? null,
  });

  return c.json({
    ok: true,
    key: updated,
    usage_sync,
  });
});

/** Per-provider scan/sync interval (seconds) — updates all of the user's keys for that provider. */
providerRoutes.patch(
  "/sync-interval",
  zValidator(
    "json",
    z.object({
      provider: z.string().min(1),
      sync_interval_secs: z.number().int(),
    })
  ),
  async (c) => {
    const body = c.req.valid("json");
    const authUser = c.get("user");
    const providerId = mapPlatformToProviderId(body.provider);
    const account = await resolveWorkspaceForUser(c.env, authUser.id, c.get("workspaceId"));
    const syncInterval = clampSyncIntervalToPlan(
      normalizeSyncInterval(body.sync_interval_secs),
      planDefForSlug(account?.plan_slug).min_sync_interval_secs
    );

    const existing = await db(c.env)
      .prepare(
        `SELECT id, sync_interval_secs FROM user_connections
          WHERE user_id = ? AND provider IN (?, ?)
          ORDER BY created_at DESC LIMIT 1`
      )
      .bind(authUser.id, body.provider.trim(), providerId)
      .first<{ id: string; sync_interval_secs: number | null }>();

    if (!existing) {
      return c.json({ error: "provider_not_connected", message: "Provider bağlı değil" }, 404);
    }

    // Bilinçli olarak provider bazında toplu güncelleme: bu provider'a bağlı
    // TÜM hesapların (birden fazla connection olsa bile) tarama sıklığı aynı.
    await db(c.env)
      .prepare(
        `UPDATE user_connections SET sync_interval_secs = ?
          WHERE user_id = ? AND provider IN (?, ?)`
      )
      .bind(syncInterval, authUser.id, body.provider.trim(), providerId)
      .run();
    await vpsCacheBust(c.env, { prefix: `conns:${authUser.id}` });

    await recordAudit(c.env, {
      workspaceId: account?.workspace_id,
      actorUserId: authUser.id,
      actorEmail: authUser.email,
      action: "provider.sync_interval.update",
      entityType: "provider",
      entityId: providerId,
      metadata: {
        provider_id: providerId,
        old_sync_interval_secs: existing.sync_interval_secs,
        new_sync_interval_secs: syncInterval,
      },
      ip: clientIpFromRequest(c.req),
      userAgent: c.req.header("User-Agent") ?? null,
    });

    return c.json({
      ok: true,
      provider_id: providerId,
      sync_interval_secs: syncInterval,
    });
  }
);

providerRoutes.post("/disconnect", zValidator("json", z.object({
  email: z.string().email().optional(),
  connection_id: z.string().min(1),
})), async (c) => {
  const body = c.req.valid("json");
  const authUser = c.get("user");
  if (forbiddenEmail(c, body.email)) return c.json({ error: "Forbidden" }, 403);

  const account = await resolveWorkspaceForUser(c.env, authUser.id, c.get("workspaceId"));
  const result = await disconnectUserConnection(c.env, authUser.id, body.connection_id);
  if (!result) return c.json({ error: "connection_not_found" }, 404);
  const providerId = result.providerId;

  // Bu provider'ın başka bağlantısı kalmadıysa aktif oauth/start oturumunu temizle
  // — yoksa TTL bitene kadar gecikmiş bir scan push'u provider'ı sessizce yeniden
  // bağlayabilir. Başka bir hesap hâlâ bağlıysa oturumu bozma.
  const remaining = await db(c.env)
    .prepare("SELECT 1 FROM user_connections WHERE user_id = ? AND provider = ? LIMIT 1")
    .bind(authUser.id, providerId)
    .first();
  if (!remaining) {
    await db(c.env)
      .prepare("DELETE FROM provider_oauth_sessions WHERE user_id = ? AND provider = ?")
      .bind(authUser.id, providerId)
      .run();
  }

  if (account?.workspace_id) {
    await syncVpsProviderPresence(c.env, authUser.id, account.workspace_id, true);
  }

  await recordAudit(c.env, {
    workspaceId: account?.workspace_id,
    actorUserId: authUser.id,
    actorEmail: authUser.email,
    action: "key.delete",
    entityType: "provider",
    entityId: body.connection_id,
    metadata: { provider_id: providerId, connection_id: body.connection_id },
    ip: clientIpFromRequest(c.req),
    userAgent: c.req.header("User-Agent") ?? null,
  });

  return c.json({ ok: true, provider_id: providerId, connection_id: body.connection_id });
});

/**
 * Minimum spacing between two real upstream refreshes for the same user.
 *
 * The mobile clients call this before every usage GET, so it fires on app
 * launch, on background refresh and on every dashboard appearance. Each call
 * decrypts every stored key, hits every provider's API and then writes a full
 * usage upsert per connection — far too expensive to run because a user
 * switched tabs. Provider quotas do not move meaningfully inside this window
 * anyway.
 *
 * Bypassed by `force: true`, which clients send only for an explicit
 * pull-to-refresh.
 */
const FETCH_USAGE_MIN_INTERVAL_SECS = 300;

providerRoutes.post("/fetch-usage", rateLimit({ limit: 30, windowSeconds: 60, keyPrefix: "provider:fetch-usage" }), zValidator("json", z.object({
  email: z.string().email().optional(),
  provider: z.string().optional(),
  /** Explicit user-initiated refresh; skips the throttle below. */
  force: z.boolean().optional(),
}).passthrough()), async (c) => {
  const body = c.req.valid("json");
  const authUser = c.get("user");
  if (forbiddenEmail(c, body.email)) return c.json({ error: "Forbidden" }, 403);

  const account = await resolveWorkspaceForUser(c.env, authUser.id, c.get("workspaceId"));
  if (!account?.workspace_id) return c.json({ error: "workspace_not_found" }, 404);

  // Throttle lives server-side on purpose: it has to cover already-shipped app
  // versions that call this unconditionally, not just clients we can update.
  const throttleKey = `fetch-usage:${authUser.id}:${body.provider ?? "all"}`;
  const vpsThrottle = await getVpsCacheValue<boolean>(c.env, throttleKey);
  if (!vpsThrottle.available && vpsConfigured(c.env)) {
    return c.json({ error: "vps_usage_store_unavailable" }, 503);
  }
  if (vpsThrottle.available) {
    if (!body.force && vpsThrottle.hit) {
      // The caller's next move is a GET of stored usage, which is already
      // current — so this is a success, not an error.
      return c.json({ results: [], throttled: true });
    }
    const stored = await putVpsCacheValue(
      c.env,
      throttleKey,
      true,
      FETCH_USAGE_MIN_INTERVAL_SECS
    );
    if (!stored) return c.json({ error: "vps_usage_store_unavailable" }, 503);
  } else if (!body.force) {
    // Local/dev fallback only. Production has VPS_API_URL + VPS_API_SECRET and
    // therefore never creates a D1 throttle row.
    const recent = await db(c.env)
      .prepare("SELECT expires_at FROM usage_fetch_throttles WHERE throttle_key = ? AND datetime(expires_at) > CURRENT_TIMESTAMP")
      .bind(throttleKey)
      .first<{ expires_at: string }>();
    if (recent) return c.json({ results: [], throttled: true });
  }

  const filterProvider = body.provider
    ? mapPlatformToProviderId(body.provider)
    : undefined;

  const { results: connectionRows } = await db(c.env)
    .prepare(
      "SELECT id, user_email, provider, key_value FROM user_connections WHERE user_id = ? ORDER BY created_at DESC"
    )
    .bind(authUser.id)
    .all<{ id: string; user_email: string; provider: string; key_value: string }>();

  // Her bağlantı (aynı provider'ın birden fazla hesabı dahil) ayrı ayrı çekilir.
  const entries: Array<{ connectionId: string; providerId: string; key: string }> = [];
  for (const row of connectionRows || []) {
    const pid = mapPlatformToProviderId(row.provider);
    if (filterProvider && pid !== filterProvider) continue;
    const plain = await resolveUserKeyValue(c.env, authUser.id, row.user_email, row.key_value, {
      reencryptKeyId: row.id,
      db: db(c.env),
    });
    if (plain) entries.push({ connectionId: row.id, providerId: pid, key: plain });
  }

  const results = await Promise.all(
    entries.map(async (e) => ({ ...(await fetchUpstreamUsage(e.providerId, e.key)), connectionId: e.connectionId }))
  );

  const inputs: Parameters<typeof upsertProviderUsageBatch>[1] = [];
  for (const r of results) {
    if (!r.ok) continue;
    if (!r.windows?.length && !r.used && r.used_percent == null) continue;
    inputs.push({
      workspace_id: account.workspace_id,
      provider_id: r.provider,
      connection_id: r.connectionId,
      user_id: authUser.id,
      user_email: authUser.email,
      used_percent: r.used_percent ?? null,
      used: r.used ?? null,
      total: r.total ?? null,
      resets_at: r.resets_at ?? null,
      windows: r.windows,
      source: "api_key",
    });
  }
  if (inputs.length > 0) {
    await upsertProviderUsageBatch(c.env, inputs, undefined, { requireVpsMirror: true });
  }

  return c.json({ results });
});

// Provider "OAuth" akışı: gerçek OAuth değil — desktop webview'de login sayfası
// açılır, scrape push'u D1'e düşünce status "connected" olur.
providerRoutes.post("/oauth/start", rateLimit({ limit: 20, windowSeconds: 60, keyPrefix: "provider:oauth-start" }), zValidator("json", z.object({
  email: z.string().email().optional(),
  provider: z.string().min(1),
})), async (c) => {
  const body = c.req.valid("json");
  const authUser = c.get("user");
  if (forbiddenEmail(c, body.email)) return c.json({ error: "Forbidden" }, 403);

  const providerId = mapPlatformToProviderId(body.provider);
  const urls = PROVIDER_URLS[providerId];
  if (!urls) return c.json({ error: "unsupported_provider" }, 400);

  const account = await resolveWorkspaceForUser(c.env, authUser.id, c.get("workspaceId"));
  const sid = uuid();
  const startedAt = nowIso();
  const expiresAt = sqliteTimestamp(new Date(Date.now() + OAUTH_SESSION_TTL_S * 1000));
  await db(c.env).batch([
    db(c.env)
      .prepare("DELETE FROM provider_oauth_sessions WHERE user_id = ? AND provider = ?")
      .bind(authUser.id, providerId),
    db(c.env)
      .prepare(
        `INSERT INTO provider_oauth_sessions
           (id, user_id, workspace_id, provider, started_at, expires_at)
         VALUES (?, ?, ?, ?, ?, ?)`
      )
      .bind(sid, authUser.id, account?.workspace_id ?? null, providerId, startedAt, expiresAt),
  ]);

  return c.json({ url: urls.login, session_id: sid, type: "scrape" });
});

providerRoutes.get("/oauth/status", async (c) => {
  const authUser = c.get("user");
  const providerId = mapPlatformToProviderId(c.req.query("provider") || "");
  let sid = c.req.query("session_id") || null;
  if (!sid && providerId) {
    const latest = await db(c.env)
      .prepare(
        `SELECT id
           FROM provider_oauth_sessions
          WHERE user_id = ? AND provider = ? AND datetime(expires_at) > CURRENT_TIMESTAMP
          ORDER BY started_at DESC
          LIMIT 1`
      )
      .bind(authUser.id, providerId)
      .first<{ id: string }>();
    sid = latest?.id ?? null;
  }
  if (!sid) return c.json({ status: "error", message: "no_session" });

  const session = await db(c.env)
    .prepare(
      `SELECT user_id, workspace_id, provider, started_at
         FROM provider_oauth_sessions
        WHERE id = ? AND user_id = ? AND datetime(expires_at) > CURRENT_TIMESTAMP`
    )
    .bind(sid, authUser.id)
    .first<{ user_id: string; workspace_id: string | null; provider: string; started_at: string }>();
  if (!session) return c.json({ status: "error", message: "expired" });
  if (!session.workspace_id) return c.json({ status: "pending" });

  const snapshot = await getUsageSnapshot(c.env, session.user_id);
  const latest = Object.values(snapshot)
    .filter((entry) => mapPlatformToProviderId(entry.provider_id) === session.provider)
    .map((entry) => entry.updated_at)
    .sort()
    .pop() ?? null;

  const fresh =
    latest && new Date(latest).getTime() >= new Date(session.started_at).getTime();
  return c.json({ status: fresh ? "connected" : "pending" });
});

// ---------------------------------------------------------------------------
// /api/scrape/browser/* — desktop webview login oturumları (D1)
// ---------------------------------------------------------------------------

type ScrapeSession = {
  userId: string;
  provider: string;
  created_at: string;
  logged_in: boolean;
};

export const scrapeRoutes = new Hono<{ Bindings: Env; Variables: AppVariables }>();

scrapeRoutes.use("*", requireAuth);

scrapeRoutes.post("/browser/create", zValidator("json", z.object({
  // Eski desktop buildleri email alanında user_id gönderebiliyor; yalnızca
  // gerçekten email gibi görünüyorsa token email'iyle eşleşme zorunlu.
  email: z.string().optional(),
  provider: z.string().min(1),
  target_url: z.string().optional(),
}).passthrough()), async (c) => {
  const body = c.req.valid("json");
  const authUser = c.get("user");
  if (body.email?.includes("@") && forbiddenEmail(c, body.email)) {
    return c.json({ error: "Forbidden" }, 403);
  }

  const providerId = mapPlatformToProviderId(body.provider);
  // Only known providers: never follow a caller-supplied target_url (SSRF / open redirect).
  const loginUrl = PROVIDER_URLS[providerId]?.login;
  if (!loginUrl) return c.json({ error: "unsupported_provider" }, 400);
  if (!loginUrl.startsWith("https://")) {
    return c.json({ error: "invalid_login_url" }, 400);
  }

  const sid = uuid();
  const session: ScrapeSession = {
    userId: authUser.id,
    provider: providerId,
    created_at: nowIso(),
    logged_in: false,
  };
  await db(c.env)
    .prepare(
      `INSERT INTO browser_scrape_sessions
         (id, user_id, provider, created_at, expires_at, logged_in)
       VALUES (?, ?, ?, ?, ?, 0)`
    )
    .bind(
      sid,
      authUser.id,
      providerId,
      session.created_at,
      sqliteTimestamp(new Date(Date.now() + SCRAPE_SESSION_TTL_S * 1000)),
    )
    .run();

  return c.json({ session_id: sid, login_url: loginUrl });
});

scrapeRoutes.post("/browser/confirm", zValidator("json", z.object({
  session_id: z.string().min(1),
})), async (c) => {
  const { session_id } = c.req.valid("json");
  const session = await db(c.env)
    .prepare(
      `SELECT user_id
         FROM browser_scrape_sessions
        WHERE id = ? AND datetime(expires_at) > CURRENT_TIMESTAMP`
    )
    .bind(session_id)
    .first<{ user_id: string }>();
  if (!session) return c.json({ error: "expired" }, 404);
  if (session.user_id !== c.get("user").id) return c.json({ error: "Forbidden" }, 403);

  await db(c.env)
    .prepare("UPDATE browser_scrape_sessions SET logged_in = 1, expires_at = ? WHERE id = ?")
    .bind(sqliteTimestamp(new Date(Date.now() + SCRAPE_SESSION_TTL_S * 1000)), session_id)
    .run();
  return c.json({ ok: true });
});

scrapeRoutes.get("/browser/status", async (c) => {
  const sid = c.req.query("session_id");
  if (!sid) return c.json({ status: "expired", logged_in: false });

  const session = await db(c.env)
    .prepare(
      `SELECT user_id, logged_in
         FROM browser_scrape_sessions
        WHERE id = ? AND datetime(expires_at) > CURRENT_TIMESTAMP`
    )
    .bind(sid)
    .first<{ user_id: string; logged_in: number }>();
  if (!session || session.user_id !== c.get("user").id) {
    return c.json({ status: "expired", logged_in: false });
  }

  return c.json({ status: session.logged_in ? "logged_in" : "pending", logged_in: Boolean(session.logged_in) });
});

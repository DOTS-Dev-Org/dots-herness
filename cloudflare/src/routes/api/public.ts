import { Hono } from "hono";
import { bodyLimit } from "hono/body-limit";
import { zValidator } from "@hono/zod-validator";
import { z } from "zod";
import type { Env, AppVariables } from "../../env";
import { db, normalizeEmail, uuid } from "../../db/client";
import { requireAuth } from "../../middleware/auth";
import { rateLimit } from "../../middleware/rate-limit";
import {
  findConnectionByLabelCached,
  getUsageSnapshot,
  getUserByEmail,
  latestConnectionForProvider,
  latestConnectionForProviderCached,
  mapPlatformToProviderId,
  resolveWorkspaceForUser,
  syncVpsProviderPresence,
  upsertConnectionSubscription,
  upsertProviderUsage,
  upsertProviderUsageBatch,
  usageWindowSchema,
  userHasProviderConnection,
  type UsageUpsertInput,
} from "../../lib/users";
import { detectImageType, MAX_AVATAR_BYTES } from "../../middleware/cors";

const MAX_MULTIPART_BODY_BYTES = MAX_AVATAR_BYTES + 64 * 1024;
const uploadBodyLimit = bodyLimit({
  maxSize: MAX_MULTIPART_BODY_BYTES,
  onError: (c) => c.json({ error: "File too large (max 2 MB)" }, 413),
});
import {
  effectiveUsedPercent,
  scheduleUsageThresholdAlerts,
} from "../../lib/notify";
import { handleTelegramWebhook } from "../../lib/telegram";
import {
  markProviderRefreshStale,
  syncProviderUsageFromKey,
} from "../../lib/provider_fetch";
import { patchProviderUsageLimits, recordSubscriptionHistory } from "../../lib/usage";
import { canConnectProvider } from "../../lib/plan_limits";
import { normalizeSyncInterval } from "../../lib/sync_interval";
import {
  encryptUserKeyValue,
  resolveUserKeyValue,
} from "../../lib/user_key_crypto";
import { vpsCacheBust } from "../../lib/vps_usage";

const publicRoutes = new Hono<{ Bindings: Env; Variables: AppVariables }>();

publicRoutes.get("/app-links", async (c) => {
  return c.json({
    googlePlay: "https://play.google.com/store/apps/details?id=com.dots.aiwatcher",
    appStore: "https://apps.apple.com/app/ai-watcher/id6470000000",
    mac: "https://github.com/DOTS-Group/aitrack_desktop/releases/latest",
    windows: "https://github.com/DOTS-Group/aitrack_desktop/releases/latest",
    linux: "https://github.com/DOTS-Group/aitrack_desktop/releases/latest",
    chromeExtension: "https://chromewebstore.google.com",
  });
});

const refreshBodySchema = z.object({
  provider_id: z.string().optional(),
  provider: z.string().optional(),
  account_label: z.string().max(200).nullable().optional(),
  used_percent: z.number().nullable().optional(),
  used: z.string().nullable().optional(),
  total: z.string().nullable().optional(),
  resets_at: z.string().nullable().optional(),
  error: z.string().nullable().optional(),
  observed_at: z.string().optional(),
  updated_at: z.string().optional(),
  snapshot_id: z.string().max(500).optional(),
  windows: z.array(usageWindowSchema).optional(),
  no_subscription: z.boolean().optional(),
}).passthrough();

type RefreshBody = z.infer<typeof refreshBodySchema>;

/**
 * Bir POST icinde push edilen tek provider snapshot'ini isler. Ayri fonksiyona
 * cikarildi ki /refresh-batch ayni mantigi, ayni auth + workspace lookup'ini
 * tekrar etmeden, N provider icin tek Worker cagrisinda calistirabilsin --
 * istemci taraflarin (extension) birden fazla provider'i ayni pencerede
 * (deferred sync buffer) toplayip tek istekte gondermesini desteklemek icin.
 */
type PushResult = {
  httpStatus: number;
  /** Batch route'ta ortak snapshot upsert'i için yalnızca Worker içi alan. */
  usageInput?: UsageUpsertInput;
  body: {
    ok: boolean;
    provider_id: string;
    status?: string;
    error?: string;
    message?: string;
    synced?: boolean;
    limit?: number;
    used?: number;
  };
};

async function pushProviderUsage(
  env: Env,
  executionCtx: { waitUntil: (promise: Promise<unknown>) => void },
  account: NonNullable<Awaited<ReturnType<typeof resolveWorkspaceForUser>>>,
  authUser: { id: string; email: string },
  body: RefreshBody,
  persist = true
): Promise<PushResult> {
  const providerRaw = body.provider_id || body.provider;
  if (!providerRaw) {
    return {
      httpStatus: 400,
      body: { ok: false, provider_id: "", error: "provider_required", message: "provider is required" },
    };
  }

  const providerId = mapPlatformToProviderId(providerRaw);
  const hasUsage =
    body.no_subscription === true ||
    body.used_percent != null ||
    body.used != null ||
    body.total != null ||
    body.error != null ||
    (body.windows?.length ?? 0) > 0;

  if (hasUsage) {
    const accountLabel = body.account_label?.trim() || null;

    // account_label taşıyan bir scan push'u varsa önce o etikete ait bağlantıyı ara;
    // yoksa (eski extension'lar / label yok) en yeni bağlantıyı kullan — davranış
    // account_label göndermeyen istemciler için birebir korunur.
    let connection = accountLabel
      ? await findConnectionByLabelCached(env, authUser.id, providerId, accountLabel)
      : await latestConnectionForProviderCached(env, authUser.id, providerId);

    if (!connection) {
      // Tarayıcı-scan tabanlı provider (Claude vb.) — bağlantı yoksa otomatik scan
      // bağlantısı kur. Öncelik aktif bir oauth/start oturumunda (kullanıcı
      // gerçekten "bağla" dediyse); böyle bir oturum yoksa da (extension'ın eski
      // sürümleri /oauth/start'ı hiç çağırmıyor) katalogda aktif olan bir provider
      // için otomatik bağlanmaya izin ver — istemci taraflı disconnected_provider_ids
      // zaten disconnect sonrası arka planda kalan eski scan push'larının provider'ı
      // sessizce yeniden bağlamasını engelliyor, bu yüzden burada ek bir engel
      // gerekmiyor.
      const prov = await db(env)
        .prepare("SELECT id, name, status FROM providers WHERE id = ?")
        .bind(providerId)
        .first<{ id: string; name: string; status: string | null }>();
      if (!prov || prov.status !== "active") {
        return { httpStatus: 403, body: { ok: false, provider_id: providerId, error: "provider_not_connected" } };
      }
      const gate = await canConnectProvider(env, account.workspace_id, account.max_providers, providerId);
      if (!gate.allowed) {
        return {
          httpStatus: 403,
          body: {
            ok: false,
            provider_id: providerId,
            error: "provider_limit_reached",
            message: "Plan provider limitine ulaşıldı",
            limit: gate.limit,
            used: gate.used,
          },
        };
      }
      const scanPlaceholder = await encryptUserKeyValue(env, authUser.id, "scan");
      const newConnectionId = uuid();
      await db(env)
        .prepare(
          `INSERT INTO user_connections (id, user_id, user_email, provider, name, key_masked, key_value, created_at, sync_interval_secs, scope, account_label, connection_type)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`
        )
        .bind(
          newConnectionId,
          authUser.id,
          authUser.email,
          providerId,
          prov.name,
          "scan",
          scanPlaceholder,
          new Date().toISOString(),
          normalizeSyncInterval(undefined),
          "personal",
          accountLabel,
          "login"
        )
        .run();
      await vpsCacheBust(env, { prefix: `conns:${authUser.id}` });
      await syncVpsProviderPresence(env, authUser.id, account.workspace_id, true);
      connection = { id: newConnectionId };
    }

    const usageInput: UsageUpsertInput = {
      workspace_id: account.workspace_id,
      provider_id: providerId,
      connection_id: connection.id,
      user_id: authUser.id,
      user_email: authUser.email,
      used_percent: body.used_percent,
      used: body.used,
      total: body.total,
      resets_at: body.resets_at,
      error: body.error,
      observed_at: body.observed_at,
      updated_at: body.updated_at,
      snapshot_id: body.snapshot_id,
      windows: body.windows as any,
      source: "manual",
      no_subscription: body.no_subscription,
    };
    if (persist) await upsertProviderUsage(env, usageInput, executionCtx);

    if (!body.no_subscription) {
      const usedPercent = effectiveUsedPercent(body.used_percent, body.windows as any);
      scheduleUsageThresholdAlerts(
        executionCtx,
        env,
        authUser.id,
        account.workspace_id,
        providerId,
        usedPercent
      );
    }

    return {
      httpStatus: 200,
      usageInput: persist ? undefined : usageInput,
      body: { ok: true, provider_id: providerId, status: "fresh" },
    };
  }

  const keyRow = await db(env)
    .prepare(
      `SELECT id, user_email, key_value FROM user_connections
       WHERE user_id = ? AND provider IN (?, ?)
       ORDER BY created_at DESC LIMIT 1`
    )
    .bind(authUser.id, providerRaw.trim(), providerId)
    .first<{ id: string; user_email: string; key_value: string }>();

  const plainKey = keyRow
    ? await resolveUserKeyValue(env, authUser.id, keyRow.user_email, keyRow.key_value, {
        reencryptKeyId: keyRow.id,
        db: db(env),
      })
    : null;

  if (!plainKey || !keyRow) {
    return {
      httpStatus: 422,
      body: {
        ok: false,
        provider_id: providerId,
        error: "provider_key_missing",
        message: "Bu provider için kayıtlı API anahtarı yok",
        synced: false,
      },
    };
  }

  try {
    const synced = await syncProviderUsageFromKey(
      env,
      account.workspace_id,
      authUser.id,
      authUser.email,
      providerId,
      plainKey,
      keyRow.id
    );
    if (synced.ok) {
      const usedPercent = effectiveUsedPercent(
        synced.used_percent ?? null,
        synced.windows as Parameters<typeof effectiveUsedPercent>[1]
      );
      scheduleUsageThresholdAlerts(
        executionCtx,
        env,
        authUser.id,
        account.workspace_id,
        providerId,
        usedPercent
      );
      return { httpStatus: 200, body: { ok: true, provider_id: providerId, status: "fresh", synced: true } };
    }

    const syncError = synced.error ?? "sync_failed";
    await markProviderRefreshStale(env, authUser.id, providerId, keyRow.id, syncError);
    return {
      httpStatus: 422,
      body: { ok: false, provider_id: providerId, error: syncError, message: syncError, synced: false },
    };
  } catch (err) {
    const message = err instanceof Error ? err.message : "internal_sync_error";
    await markProviderRefreshStale(env, authUser.id, providerId, keyRow.id, message).catch(() => {});
    return {
      httpStatus: 500,
      body: { ok: false, provider_id: providerId, error: "internal_sync_error", message, synced: false },
    };
  }
}

publicRoutes.post(
  "/provider/refresh",
  requireAuth,
  zValidator("json", refreshBodySchema),
  async (c) => {
    const body = c.req.valid("json");
    const authUser = c.get("user");
    const account = await resolveWorkspaceForUser(c.env, authUser.id, c.get("workspaceId"));
    if (!account) {
      return c.json({ error: "workspace_not_found", message: "Hesap bulunamadı" }, 404);
    }
    const result = await pushProviderUsage(c.env, c.executionCtx, account, authUser, body);
    return c.json(result.body, result.httpStatus as any);
  }
);

/**
 * Ayni pencerede taranan birden fazla provider'i tek istekte isler.
 *
 * Extension'daki deferredSync 15sn'lik pencerede birikeni tek tek POST
 * ediyordu -- N provider degistiyse N ayri Worker cagrisi, her biri kendi
 * auth + workspace lookup'ini tekrar ediyordu. Bu route ayni islemi tek
 * cagrida, ortak auth/workspace lookup'iyla yapar; D1 satir sayisini
 * degistirmez (zaten windows_json ile provider basina 1 satira indirilmisti)
 * ama Worker invocation + round-trip sayisini N'den 1'e dusurur.
 */
publicRoutes.post(
  "/provider/refresh-batch",
  requireAuth,
  zValidator("json", z.object({ items: z.array(refreshBodySchema).min(1).max(20) })),
  async (c) => {
    const { items } = c.req.valid("json");
    const authUser = c.get("user");
    const account = await resolveWorkspaceForUser(c.env, authUser.id, c.get("workspaceId"));
    if (!account) {
      return c.json({ error: "workspace_not_found", message: "Hesap bulunamadı" }, 404);
    }
    const results = [];
    const inputs: UsageUpsertInput[] = [];
    for (const item of items) {
      const result = await pushProviderUsage(c.env, c.executionCtx, account, authUser, item, false);
      if (result.usageInput) inputs.push(result.usageInput);
      results.push(result.body);
    }
    if (inputs.length > 0) {
      // Do not acknowledge the client before the usage batch has reached its
      // durable stores. The extension clears its local pending entry on a 2xx;
      // leaving this in waitUntil could therefore lose the only retry after a
      // D1/VPS failure that happens after the response is sent.
      try {
        await upsertProviderUsageBatch(c.env, inputs, undefined, { requireVpsMirror: true });
      } catch (err) {
        console.error(
          "provider refresh batch persistence failed",
          err instanceof Error ? err.message : err,
        );
        return c.json(
          {
            ok: false,
            error: "provider_persistence_failed",
            message: "Usage could not be persisted; retry the batch",
            results,
          },
          503,
        );
      }
    }
    return c.json({ ok: results.every((r) => r.ok), results });
  }
);

publicRoutes.post("/provider/sync-subscription", rateLimit({ limit: 30, windowSeconds: 60, keyPrefix: "public:provider-sync-subscription" }), requireAuth, zValidator("json", z.object({
  email: z.string().email(),
  provider: z.string(),
  plan_name: z.string().nullable().optional(),
  price_usd_cents: z.number().nullable().optional(),
  billing_cycle: z.string().optional(),
  auto_renew: z.boolean().nullable().optional(),
  purchased_at: z.string().nullable().optional(),
  renews_at: z.string().nullable().optional(),
  /** When true, write renews_at even if null (App Store / unknown). */
  renews_known: z.boolean().optional(),
})), async (c) => {
  const body = c.req.valid("json");
  const authUser = c.get("user");
  if (normalizeEmail(body.email) !== authUser.email) {
    return c.json({ error: "forbidden", message: "Email mismatch" }, 403);
  }

  const user = await getUserByEmail(c.env, body.email);
  if (!user) {
    return c.json({ error: "user_not_found", message: "Kullanıcı bulunamadı" }, 404);
  }

  const account = await resolveWorkspaceForUser(c.env, user.id, c.get("workspaceId"));
  if (!account) {
    return c.json({ error: "workspace_not_found", message: "Hesap bulunamadı" }, 404);
  }

  const providerId = mapPlatformToProviderId(body.provider);
  const connection = await latestConnectionForProvider(c.env, user.id, providerId);
  if (!connection) {
    return c.json({ error: "provider_not_connected" }, 403);
  }
  const connectionId = connection.id;

  // Scrape may omit price — never clobber a manual override or a known price
  // with null/0. Catalog list prices fill the gap at read time.
  const scrapedPrice =
    body.price_usd_cents != null && body.price_usd_cents > 0 ? body.price_usd_cents : null;
  const renewsKnown = body.renews_known === true;
  const existingSubscription = await db(c.env)
    .prepare(
      `SELECT plan_name, price_usd_cents, billing_cycle, auto_renew,
              purchased_at, renews_at, source
         FROM provider_subscriptions WHERE connection_id = ?`
    )
    .bind(connectionId)
    .first<{
      plan_name: string | null;
      price_usd_cents: number | null;
      billing_cycle: string | null;
      auto_renew: number | null;
      purchased_at: string | null;
      renews_at: string | null;
      source: string | null;
    }>();

  const now = new Date().toISOString();
  const source = existingSubscription?.source === "manual" ? "manual" : "scrape";
  const planName = body.plan_name ?? existingSubscription?.plan_name ?? null;
  const priceUsdCents =
    existingSubscription?.source === "manual"
      ? existingSubscription.price_usd_cents
      : scrapedPrice ?? existingSubscription?.price_usd_cents ?? null;
  const billingCycle = body.billing_cycle ?? existingSubscription?.billing_cycle ?? "monthly";
  const autoRenew =
    body.auto_renew == null
      ? existingSubscription?.auto_renew ?? 1
      : body.auto_renew
        ? 1
        : 0;
  const purchasedAt = body.purchased_at ?? existingSubscription?.purchased_at ?? null;
  const renewsAt = renewsKnown
    ? (body.renews_at ?? null)
    : (body.renews_at ?? existingSubscription?.renews_at ?? null);

  const subscriptionChanged =
    !existingSubscription ||
    existingSubscription.plan_name !== planName ||
    existingSubscription.price_usd_cents !== priceUsdCents ||
    existingSubscription.billing_cycle !== billingCycle ||
    existingSubscription.auto_renew !== autoRenew ||
    existingSubscription.purchased_at !== purchasedAt ||
    existingSubscription.renews_at !== renewsAt ||
    existingSubscription.source !== source;

  if (subscriptionChanged) {
    await db(c.env)
      .prepare(
        `INSERT INTO provider_subscriptions (
           connection_id, user_id, provider_id, plan_name, price_usd_cents, billing_cycle,
           auto_renew, purchased_at, renews_at, source, source_updated_at,
           last_refreshed_at, refresh_status, refresh_note
         ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'fresh', NULL)
         ON CONFLICT(connection_id) DO UPDATE SET
           user_id = excluded.user_id,
           provider_id = excluded.provider_id,
           plan_name = excluded.plan_name,
           price_usd_cents = excluded.price_usd_cents,
           billing_cycle = excluded.billing_cycle,
           auto_renew = excluded.auto_renew,
           purchased_at = excluded.purchased_at,
           renews_at = excluded.renews_at,
           source = excluded.source,
           source_updated_at = excluded.source_updated_at,
           last_refreshed_at = excluded.last_refreshed_at,
           refresh_status = excluded.refresh_status,
           refresh_note = excluded.refresh_note`
      )
      .bind(
        connectionId,
        user.id,
        providerId,
        planName,
        priceUsdCents,
        billingCycle,
        autoRenew,
        purchasedAt,
        renewsAt,
        source,
        now,
        now
      )
      .run();
  }

  // Source of truth for clients: denormalize onto user_connections.
  if (subscriptionChanged) {
    await upsertConnectionSubscription(c.env, {
      connection_id: connectionId,
      plan_name: planName,
      price_usd_cents: priceUsdCents,
      billing_cycle: billingCycle,
      auto_renew: autoRenew,
      purchased_at: purchasedAt,
      renews_at: renewsAt,
      renews_known: true,
      sub_source: source,
      sub_refreshed_at: now,
    });
  }

  if (subscriptionChanged) {
    await recordSubscriptionHistory(c.env, {
      workspaceId: account.workspace_id,
      userId: user.id,
      providerId,
      priceUsdCents,
      billingCycle,
      planName,
      source,
      observedAt: now,
    });

    await Promise.all([
      vpsCacheBust(c.env, { prefix: `conns:${user.id}` }),
      vpsCacheBust(c.env, { prefix: `subs-meta:${user.id}` }),
    ]);
  }

  const usageSnapshot = await getUsageSnapshot(c.env, user.id);
  const usage = usageSnapshot[connectionId];

  scheduleUsageThresholdAlerts(
    c.executionCtx,
    c.env,
    user.id,
    account.workspace_id,
    providerId,
    usage?.used_percent ?? null
  );

  return c.json({ ok: true, provider_id: providerId, workspace_id: account.workspace_id });
});

publicRoutes.post("/avatar-upload", uploadBodyLimit, rateLimit({ limit: 10, windowSeconds: 60, keyPrefix: "public:avatar-upload" }), requireAuth, async (c) => {
  const user = c.get("user");
  const contentType = c.req.header("Content-Type") || "";
  if (!contentType.includes("multipart/form-data")) {
    return c.json({ error: "Content-Type must be multipart/form-data" }, 400);
  }
  const form = await c.req.formData();
  const fileEntry = form.get("file");
  if (!fileEntry || typeof fileEntry === "string") return c.json({ error: "No file provided" }, 400);
  const file = fileEntry as File;

  const arrayBuffer = await file.arrayBuffer();
  if (arrayBuffer.byteLength === 0) return c.json({ error: "Empty file" }, 400);
  if (arrayBuffer.byteLength > MAX_AVATAR_BYTES) return c.json({ error: "File too large (max 2 MB)" }, 413);

  const detectedType = detectImageType(arrayBuffer);
  if (!detectedType) return c.json({ error: "File must be a valid image" }, 400);

  const ext = detectedType === "jpeg" ? "jpg" : detectedType;
  const key = `avatars/${user.id}.${ext}`;
  await c.env.DOTSHERNESS_ASSETS.put(key, arrayBuffer, {
    httpMetadata: {
      contentType: `image/${detectedType === "jpeg" ? "jpeg" : detectedType}`,
      cacheControl: "public, max-age=3600, s-maxage=3600",
    },
  });

  const avatarUrl = `/assets/${key}`;
  await db(c.env).prepare("UPDATE users SET avatar = ?, updated_at = NOW() WHERE id = ?")
    .bind(avatarUrl, user.id).run();

  return c.json({ avatar: avatarUrl });
});

publicRoutes.post("/provider-logo-upload", uploadBodyLimit, rateLimit({ limit: 10, windowSeconds: 60, keyPrefix: "public:provider-logo-upload" }), requireAuth, async (c) => {
  const user = c.get("user");
  const contentType = c.req.header("Content-Type") || "";
  if (!contentType.includes("multipart/form-data")) {
    return c.json({ error: "Content-Type must be multipart/form-data" }, 400);
  }
  const form = await c.req.formData();
  const providerIdRaw = form.get("providerId");
  if (!providerIdRaw || typeof providerIdRaw !== "string") {
    return c.json({ error: "No providerId provided" }, 400);
  }
  const fileEntry = form.get("file");
  if (!fileEntry || typeof fileEntry === "string") return c.json({ error: "No file provided" }, 400);
  const file = fileEntry as File;

  const arrayBuffer = await file.arrayBuffer();
  if (arrayBuffer.byteLength === 0) return c.json({ error: "Empty file" }, 400);
  if (arrayBuffer.byteLength > MAX_AVATAR_BYTES) return c.json({ error: "File too large (max 2 MB)" }, 413);

  const detectedType = detectImageType(arrayBuffer);
  if (!detectedType) return c.json({ error: "File must be a valid image" }, 400);

  const providerId = mapPlatformToProviderId(providerIdRaw);
  const connection = await latestConnectionForProvider(c.env, user.id, providerId);
  if (!connection) return c.json({ error: "provider_not_connected" }, 404);

  const ext = detectedType === "jpeg" ? "jpg" : detectedType;
  const key = `provider-logos/${user.id}/${connection.id}.${ext}`;
  await c.env.DOTSHERNESS_ASSETS.put(key, arrayBuffer, {
    httpMetadata: {
      contentType: `image/${detectedType === "jpeg" ? "jpeg" : detectedType}`,
      cacheControl: "public, max-age=3600, s-maxage=3600",
    },
  });

  const logoUrl = `/assets/${key}`;
  await patchProviderUsageLimits(c.env, user.id, providerId, { customLogoUrl: logoUrl });

  return c.json({ logoUrl });
});

publicRoutes.post("/user/telegram/webhook/:userId", async (c) => {
  const userId = c.req.param("userId");
  if (!userId) return c.json({ error: "Not found" }, 404);

  let update: { message?: { chat?: { id?: number }; text?: string } };
  try {
    update = await c.req.json();
  } catch {
    return c.json({ error: "Invalid payload" }, 400);
  }

  const secret = c.req.header("X-Telegram-Bot-Api-Secret-Token");
  const ok = await handleTelegramWebhook(c.env, userId, secret, update);
  if (!ok) return c.json({ error: "Forbidden" }, 403);
  return c.json({ ok: true });
});

export default publicRoutes;

import type { Env } from "../env";
import { db } from "../db/client";

/**
 * Daily D1 cleanup jobs.
 *
 * Usage time-series no longer lives here: live state sits in Redis and closed
 * windows in Postgres on the self-hosted store (see `vps_usage.ts`), so the
 * old Analytics Engine mirror and the `provider_usage_history` retention pass
 * are gone. What remains are the D1 tables that grow without any bound of
 * their own.
 */

/**
 * QR login oturumlari kisa omurlu: pending 5-10 dk icinde expire olur,
 * confirmed/consumed olan da hemen ardindan islevsiz kalir. Arsivlenecek
 * deger tasimazlar, o yuzden 24 saatten eski hepsi silinir.
 */
export async function purgeStaleQrSessions(env: Env): Promise<number> {
  const res = await db(env)
    .prepare(`DELETE FROM qr_sessions WHERE datetime(created_at) <= datetime('now', '-1 day')`)
    .run();
  return res.meta?.changes ?? 0;
}

/**
 * Suresi dolmus refresh token'lar sadece logout'ta tek tek siliniyor;
 * logout olmadan expire olanlar hic temizlenmiyordu. expires_at gecmis
 * her satir artik hicbir sorguda gecerli sayilmadigindan guvenle silinir.
 */
export async function purgeExpiredRefreshTokens(env: Env): Promise<number> {
  const res = await db(env)
    .prepare(`DELETE FROM refresh_tokens WHERE datetime(expires_at) <= CURRENT_TIMESTAMP`)
    .run();
  return res.meta?.changes ?? 0;
}

/**
 * audit_events hicbir retention'a tabi degildi, sinirsiz buyume riski. Bu bir
 * compliance kaydi degil (guvenlik/debug amacli aktivite izi), 180 gunluk
 * pencere yeterli. Batch'li: tek seferde buyuk tabloyu silmek 30 sn sorgu
 * limitine takilabilir.
 */
export async function purgeOldAuditEvents(
  env: Env,
  opts: { retentionDays?: number; batchSize?: number; maxBatches?: number } = {}
): Promise<number> {
  const retentionDays = opts.retentionDays ?? 180;
  const batchSize = opts.batchSize ?? 5000;
  const maxBatches = opts.maxBatches ?? 20;
  const cutoff = new Date(
    Date.now() - retentionDays * 24 * 60 * 60 * 1000
  ).toISOString();

  let deleted = 0;
  for (let i = 0; i < maxBatches; i++) {
    const res = await db(env)
      .prepare(
        `DELETE FROM audit_events
          WHERE id IN (
            SELECT id FROM audit_events
             WHERE created_at < ?
             LIMIT ?
          )`
      )
      .bind(cutoff, batchSize)
      .run();

    const changes = res.meta?.changes ?? 0;
    deleted += changes;
    if (changes < batchSize) break;
  }
  return deleted;
}

/** Remove short-lived rows that previously lived in KV with TTLs. */
export async function purgeExpiredTransientState(env: Env): Promise<number> {
  const nowSec = Math.floor(Date.now() / 1000);
  const results = await db(env).batch([
    db(env)
      .prepare("DELETE FROM request_rate_limits WHERE expires_at < ?")
      .bind(nowSec),
    db(env)
      .prepare("DELETE FROM provider_oauth_sessions WHERE datetime(expires_at) <= CURRENT_TIMESTAMP"),
    db(env)
      .prepare("DELETE FROM browser_scrape_sessions WHERE datetime(expires_at) <= CURRENT_TIMESTAMP"),
    db(env)
      .prepare("DELETE FROM usage_fetch_throttles WHERE datetime(expires_at) <= CURRENT_TIMESTAMP"),
    db(env)
      .prepare("DELETE FROM oauth_states WHERE expires_at IS NOT NULL AND datetime(expires_at) <= CURRENT_TIMESTAMP"),
  ]);
  return results.reduce((total, result) => total + (result.meta?.changes ?? 0), 0);
}

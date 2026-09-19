import type { Env } from "../env";
import { db, nowIso } from "../db/client";
import { getUsageSnapshot } from "./users";
import { putVpsSnapshot, vpsCacheBust } from "./vps_usage";

/**
 * Tek bir bağlantıyı (hesabı) koparır — sadece bu connection_id'ye ait
 * user_connections satırını siler. user_provider_usage/provider_subscriptions/
 * alert_states satırları FK ON DELETE CASCADE ile
 * otomatik temizlenir; diğer bağlantıların (aynı provider'ın başka hesapları)
 * verisi etkilenmez.
 */
export async function disconnectUserConnection(
  env: Env,
  userId: string,
  connectionId: string
): Promise<{ providerId: string } | null> {
  const row = await db(env)
    .prepare("SELECT provider FROM user_connections WHERE id = ? AND user_id = ?")
    .bind(connectionId, userId)
    .first<{ provider: string }>();
  if (!row) return null;

  const snapshot = await getUsageSnapshot(env, userId);
  const hadSnapshotEntry = Boolean(snapshot[connectionId]);
  if (hadSnapshotEntry) delete snapshot[connectionId];

  // Usage history is no longer in D1, so there is no history row left holding a
  // connection_id to clear here. Rollups on the self-hosted store keep their
  // own copy of connection_id as a plain value with no FK back to D1, and are
  // deliberately retained after a disconnect. Current-state tables still clean
  // up through their ON DELETE CASCADE constraints.
  const statements = [
    db(env)
      .prepare("DELETE FROM user_connections WHERE id = ? AND user_id = ?")
      .bind(connectionId, userId),
  ];
  if (hadSnapshotEntry) {
    statements.unshift(
      db(env)
        .prepare(
          `UPDATE user_usage_snapshots
              SET snapshot_json = json_remove(snapshot_json, ?),
                  updated_at = ?, observed_at = ?, source = 'disconnect'
            WHERE user_id = ?`
        )
        .bind(
          `$."${connectionId.replaceAll('"', '""')}"`,
          nowIso(),
          nowIso(),
          userId
        )
    );
  }
  await db(env).batch(statements);

  // Redis serves every snapshot read, so the removal has to land there too —
  // otherwise the disconnected provider keeps showing up on dashboards until
  // the key happens to be rewritten. `snapshot` already has the entry deleted.
  if (hadSnapshotEntry) await putVpsSnapshot(env, userId, snapshot);
  // The connection list is cached per user; it just changed.
  await vpsCacheBust(env, { prefix: `conns:${userId}` });

  return { providerId: row.provider };
}

import type { Env } from "../env";
import { db } from "../db/client";
import { mapPlatformToProviderId } from "./users";

/** Free plan caps providers; paid plans use max_providers = -1 (unlimited). */
export function effectiveProviderLimit(maxProviders: number): number {
  return maxProviders < 0 ? -1 : maxProviders;
}

/** Distinct providers connected by any workspace member. */
export async function countWorkspaceProviders(
  env: Env,
  workspaceId: string
): Promise<number> {
  const { results } = await db(env)
    .prepare(
      `SELECT DISTINCT uk.provider AS provider
         FROM user_connections uk
         JOIN users u ON u.id = uk.user_id
         JOIN workspace_members wm ON wm.user_id = u.id
        WHERE wm.workspace_id = ?`
    )
    .bind(workspaceId)
    .all<{ provider: string }>();

  const ids = new Set(
    (results ?? []).map((r) => mapPlatformToProviderId(r.provider))
  );
  return ids.size;
}

export async function canConnectProvider(
  env: Env,
  workspaceId: string,
  maxProviders: number,
  providerId: string
): Promise<{ allowed: boolean; limit: number; used: number }> {
  const limit = effectiveProviderLimit(maxProviders);
  const used = await countWorkspaceProviders(env, workspaceId);

  if (limit < 0) return { allowed: true, limit, used };

  const alreadyConnected = await db(env)
    .prepare(
      `SELECT 1
         FROM user_connections uk
         JOIN users u ON u.id = uk.user_id
         JOIN workspace_members wm ON wm.user_id = u.id
        WHERE wm.workspace_id = ?
          AND uk.provider IN (?, ?)
        LIMIT 1`
    )
    .bind(workspaceId, providerId, mapPlatformToProviderId(providerId))
    .first();

  if (alreadyConnected) return { allowed: true, limit, used };

  return { allowed: used < limit, limit, used };
}

import { createMiddleware } from "hono/factory";
import type { Env, AppVariables } from "../env";
import { db } from "../db/client";
import { resolveWorkspaceForUser } from "./users";

export type TeamRole = "owner" | "admin" | "assistant" | "member";

export const TEAM_ROLES: TeamRole[] = ["owner", "admin", "assistant", "member"];

const ROLE_RANK: Record<TeamRole, number> = {
  owner: 4,
  admin: 3,
  assistant: 2,
  member: 1,
};

export function rank(role: string): number {
  return ROLE_RANK[role as TeamRole] ?? 0;
}

export function isTeamRole(role: string): role is TeamRole {
  return role in ROLE_RANK;
}

export type ResolvedTeamAccount = {
  workspace_id: string;
  role: TeamRole;
};

export async function resolveTeamAccount(
  env: Env,
  userId: string,
  headerWorkspaceId?: string
): Promise<ResolvedTeamAccount | null> {
  const account = await resolveWorkspaceForUser(env, userId, headerWorkspaceId);
  if (!account?.workspace_id || !isTeamRole(account.role)) return null;
  return { workspace_id: account.workspace_id, role: account.role };
}

/**
 * Effective seat limit for a workspace: plan max_seats + the workspace's
 * legacy/web extra seats and active store add-on seats.
 * Returns -1 for unlimited.
 */
export async function getEffectiveSeats(
  env: Env,
  workspaceId: string
): Promise<number> {
  const { planDefForSlug } = await import("./plan_features");
  const row = await db(env)
    .prepare(`SELECT plan_slug, extra_seats, store_extra_seats FROM workspaces WHERE id = ?`)
    .bind(workspaceId)
    .first<{ plan_slug: string | null; extra_seats: number; store_extra_seats?: number }>();
  if (!row) return 1;
  const maxSeats = planDefForSlug(row.plan_slug).max_seats;
  if (maxSeats === -1) return -1;
  return maxSeats + (row.extra_seats ?? 0) + (row.store_extra_seats ?? 0);
}

/**
 * Seats currently consumed: accepted members + pending (not-yet-accepted) invites.
 */
export async function countSeatsUsed(
  env: Env,
  workspaceId: string
): Promise<number> {
  const members = await db(env)
    .prepare("SELECT COUNT(*) AS c FROM workspace_members WHERE workspace_id = ?")
    .bind(workspaceId)
    .first<{ c: number }>();
  const pending = await db(env)
    .prepare(
      "SELECT COUNT(*) AS c FROM team_invites WHERE workspace_id = ? AND accepted_at IS NULL AND datetime(expires_at) > CURRENT_TIMESTAMP"
    )
    .bind(workspaceId)
    .first<{ c: number }>();
  return (members?.c ?? 0) + (pending?.c ?? 0);
}

export async function hasSeatAvailable(
  env: Env,
  workspaceId: string
): Promise<{ available: boolean; used: number; limit: number }> {
  const limit = await getEffectiveSeats(env, workspaceId);
  const used = await countSeatsUsed(env, workspaceId);
  return { available: limit === -1 ? true : used < limit, used, limit };
}

function seatLimitSql(workspaceAlias: string): string {
  const plan = `CASE
    WHEN lower(COALESCE(${workspaceAlias}.plan_slug, 'free')) LIKE 'token-%'
      THEN substr(lower(COALESCE(${workspaceAlias}.plan_slug, 'free')), 7)
    ELSE lower(COALESCE(${workspaceAlias}.plan_slug, 'free'))
  END`;
  return `(CASE WHEN ${plan} IN ('team', 'plus', 'business') THEN 3 ELSE 1 END
    + COALESCE(${workspaceAlias}.extra_seats, 0)
    + COALESCE(${workspaceAlias}.store_extra_seats, 0))`;
}

function seatsUsedSql(workspaceAlias: string, excludedInviteId?: string): string {
  const excluded = excludedInviteId ? "AND ti.id <> ?" : "";
  return `((SELECT COUNT(*) FROM workspace_members wm WHERE wm.workspace_id = ${workspaceAlias}.id)
    + (SELECT COUNT(*) FROM team_invites ti
        WHERE ti.workspace_id = ${workspaceAlias}.id
          AND ti.accepted_at IS NULL
          AND datetime(ti.expires_at) > CURRENT_TIMESTAMP
          ${excluded}))`;
}

type TeamInviteInsert = {
  id: string;
  workspaceId: string;
  email: string;
  role: string;
  token: string;
  invitedBy: string | null;
  expiresAt: string;
};

/** Insert an invitation only if a seat is still free at write time. */
export async function createTeamInviteWithinSeatLimit(env: Env, invite: TeamInviteInsert): Promise<boolean> {
  const used = seatsUsedSql("w");
  const limit = seatLimitSql("w");
  const result = await db(env)
    .prepare(
      `INSERT INTO team_invites (id, workspace_id, email, role, token, invited_by, expires_at)
       SELECT ?, ?, ?, ?, ?, ?, ?
         FROM workspaces w
        WHERE w.id = ?
          AND ${used} < ${limit}
          AND NOT EXISTS (
            SELECT 1 FROM team_invites ti
             WHERE ti.workspace_id = w.id AND lower(trim(ti.email)) = ?
               AND ti.accepted_at IS NULL AND datetime(ti.expires_at) > CURRENT_TIMESTAMP
          )
          AND NOT EXISTS (
            SELECT 1 FROM workspace_members wm JOIN users u ON u.id = wm.user_id
             WHERE wm.workspace_id = w.id AND lower(trim(u.email)) = ?
          )`,
    )
    .bind(
      invite.id,
      invite.workspaceId,
      invite.email,
      invite.role,
      invite.token,
      invite.invitedBy,
      invite.expiresAt,
      invite.workspaceId,
      invite.email,
      invite.email,
    )
    .run();
  return (result.meta?.changes ?? 0) === 1;
}

/**
 * Accept an invite by transferring its reserved seat to the new member in one
 * D1 batch. The capacity check excludes that invite, so a full workspace can
 * still accept the seat it already reserved.
 */
export async function acceptTeamInviteWithinSeatLimit(
  env: Env,
  input: { inviteId: string; workspaceId: string; userId: string; role: string; tokenHash: string },
): Promise<boolean> {
  const database = db(env);
  const used = seatsUsedSql("w", "excludedInviteId");
  const limit = seatLimitSql("w");
  const results = await database.batch([
    database
      .prepare(
        `INSERT INTO workspace_members (workspace_id, user_id, role, joined_at)
         SELECT ?, ?, ?, CURRENT_TIMESTAMP
          WHERE EXISTS (
            SELECT 1 FROM team_invites ti JOIN users u ON u.id = ?
             WHERE ti.id = ? AND ti.workspace_id = ?
               AND ti.accepted_at IS NULL AND datetime(ti.expires_at) > CURRENT_TIMESTAMP
               AND lower(trim(ti.email)) = lower(trim(u.email))
          )
            AND EXISTS (
              SELECT 1 FROM workspaces w
               WHERE w.id = ?
                 AND ${used} < ${limit}
            )
         ON CONFLICT (workspace_id, user_id) DO NOTHING`,
      )
      .bind(
        input.workspaceId,
        input.userId,
        input.role || "member",
        input.userId,
        input.inviteId,
        input.workspaceId,
        input.workspaceId,
        input.inviteId,
      ),
    database
      .prepare(
        `UPDATE team_invites
            SET token = ?, accepted_at = CURRENT_TIMESTAMP
          WHERE id = ? AND workspace_id = ?
            AND accepted_at IS NULL AND datetime(expires_at) > CURRENT_TIMESTAMP
            AND EXISTS (
              SELECT 1 FROM workspace_members wm JOIN users u ON u.id = wm.user_id
               WHERE wm.workspace_id = team_invites.workspace_id
                 AND wm.user_id = ?
                 AND lower(trim(team_invites.email)) = lower(trim(u.email))
            )`,
      )
      .bind(input.tokenHash, input.inviteId, input.workspaceId, input.userId),
  ]);
  return (results[1]?.meta?.changes ?? 0) === 1;
}

/** Guard generic REST member inserts with the same atomic seat calculation. */
export async function insertWorkspaceMemberWithinSeatLimit(
  env: Env,
  input: { columns: string[]; values: unknown[]; workspaceId: string },
): Promise<Record<string, unknown>[]> {
  const allowedColumns = new Set(["workspace_id", "user_id", "role", "created_at", "joined_at", "note"]);
  if (
    input.columns.length !== input.values.length ||
    !input.columns.includes("workspace_id") ||
    !input.columns.includes("user_id") ||
    input.columns.some((column) => !allowedColumns.has(column))
  ) {
    throw new Error("Invalid workspace member fields");
  }
  const used = seatsUsedSql("w");
  const limit = seatLimitSql("w");
  const sql = `INSERT INTO workspace_members (${input.columns.join(", ")})
               SELECT ${input.columns.map(() => "?").join(", ")}
                WHERE EXISTS (
                  SELECT 1 FROM workspaces w
                   WHERE w.id = ? AND ${used} < ${limit}
                )
               ON CONFLICT (workspace_id, user_id) DO NOTHING
               RETURNING *`;
  const result = await db(env).prepare(sql).bind(...input.values, input.workspaceId).all<Record<string, unknown>>();
  return result.results || [];
}

/**
 * Middleware factory: resolves the caller's workspace + role and enforces
 * that the role is in `allowedRoles`. Sets `workspaceId` and `workspaceRole` on context.
 * Must run after `requireAuth`.
 */
export function requireAccountRole(allowedRoles: TeamRole[]) {
  return createMiddleware<{ Bindings: Env; Variables: AppVariables }>(
    async (c, next) => {
      const authUser = c.get("user");
      if (!authUser) return c.json({ error: "Unauthorized" }, 401);

      const headerWorkspaceId =
        c.req.header("X-Workspace-Id") || c.req.header("X-Account-Id") || undefined;
      const resolved = await resolveTeamAccount(c.env, authUser.id, headerWorkspaceId);
      if (!resolved) return c.json({ error: "Forbidden" }, 403);

      c.set("workspaceId", resolved.workspace_id);
      c.set("workspaceRole", resolved.role);

      if (!allowedRoles.includes(resolved.role)) {
        return c.json({ error: "Forbidden" }, 403);
      }
      await next();
    }
  );
}

/**
 * Resolve the target member row for an account. Returns null if not a member.
 */
export async function getTeamMember(
  env: Env,
  workspaceId: string,
  userId: string
): Promise<{ user_id: string; role: TeamRole; email: string; name?: string | null; avatar?: string | null; joined_at?: string | null; note?: string | null } | null> {
  const row = await db(env)
    .prepare(
      `SELECT am.user_id, am.role, am.joined_at, am.note, u.email, u.name, u.avatar
         FROM workspace_members am
         JOIN users u ON u.id = am.user_id
        WHERE am.workspace_id = ? AND am.user_id = ?`
    )
    .bind(workspaceId, userId)
    .first<{ user_id: string; role: string; joined_at: string | null; note: string | null; email: string; name: string | null; avatar: string | null }>();
  if (!row || !isTeamRole(row.role)) return null;
  return {
    user_id: row.user_id,
    role: row.role,
    joined_at: row.joined_at,
    email: row.email,
    name: row.name ?? undefined,
    avatar: row.avatar ?? undefined,
    note: row.note ?? undefined,
  };
}

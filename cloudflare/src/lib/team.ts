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

export async function getMemberRole(
  env: Env,
  workspaceId: string,
  userId: string
): Promise<TeamRole | null> {
  const row = await db(env)
    .prepare("SELECT role FROM workspace_members WHERE workspace_id = ? AND user_id = ?")
    .bind(workspaceId, userId)
    .first<{ role: string }>();
  if (!row || !isTeamRole(row.role)) return null;
  return row.role;
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

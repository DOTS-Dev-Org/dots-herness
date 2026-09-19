import { Hono } from "hono";
import type { Env, AppVariables } from "../../env";
import { requireAuth, resolvePlatformRole } from "../../middleware/auth";
import { listAuditEvents } from "../../lib/audit";
import { resolveTeamAccount } from "../../lib/team";

const audit = new Hono<{ Bindings: Env; Variables: AppVariables }>();

audit.use("*", requireAuth);

function isPlatformAdmin(role: string): boolean {
  return role === "admin" || role === "superadmin";
}

audit.get("/", async (c) => {
  const authUser = c.get("user");
  const dbRole = (await resolvePlatformRole(c.env, authUser.id)) ?? authUser.role;
  c.set("user", { ...authUser, role: dbRole });
  const platformAdmin = isPlatformAdmin(dbRole);

  let workspaceId: string | undefined;
  let actorUserId: string | undefined;

  if (platformAdmin) {
    workspaceId = c.req.query("workspace_id") || undefined;
    actorUserId = c.req.query("actor_user_id") || undefined;
  } else {
    const headerWorkspaceId = c.req.header("X-Workspace-Id");
    const resolved = await resolveTeamAccount(c.env, authUser.id, headerWorkspaceId);
    if (!resolved || (resolved.role !== "owner" && resolved.role !== "admin")) {
      return c.json({ error: "Forbidden" }, 403);
    }
    workspaceId = resolved.workspace_id;
    actorUserId = c.req.query("actor_user_id") || undefined;
  }

  const limit = Number(c.req.query("limit")) || 50;
  const offset = Number(c.req.query("offset")) || 0;
  const action = c.req.query("action") || undefined;
  const entityType = c.req.query("entity_type") || undefined;
  const from = c.req.query("from") || undefined;
  const to = c.req.query("to") || undefined;

  const { events, total } = await listAuditEvents(c.env, {
    workspaceId,
    actorUserId,
    action,
    entityType,
    from,
    to,
    limit,
    offset,
  });

  return c.json({ events, total });
});

export default audit;

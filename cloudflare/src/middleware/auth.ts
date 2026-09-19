import { createMiddleware } from "hono/factory";
import type { Env, AppVariables } from "../env";
import { db } from "../db/client";
import { getAccessTokenFromCookie } from "../lib/auth-cookies";
import { verifyAccessToken } from "../lib/jwt";
import { getActiveAuthUser } from "../lib/users";

/** Fresh platform role from DB (not JWT) — demote closes privilege immediately. */
export async function resolvePlatformRole(
  env: Env,
  userId: string
): Promise<string | null> {
  const row = await db(env)
    .prepare("SELECT role FROM users WHERE id = ?")
    .bind(userId)
    .first<{ role: string }>();
  return row?.role ?? null;
}

export const requireAuth = createMiddleware<{ Bindings: Env; Variables: AppVariables }>(
  async (c, next) => {
    const auth = c.req.header("Authorization");
    const bearerMatch = auth?.match(/^Bearer\s+(\S+)/i);
    const token = bearerMatch?.[1] ?? getAccessTokenFromCookie(c);
    if (!token) return c.json({ error: "Unauthorized" }, 401);

    try {
      const claims = await verifyAccessToken(c.env, token);
      const user = await getActiveAuthUser(c.env, claims.userId);
      if (!user) return c.json({ error: "Unauthorized" }, 401);
      c.set("user", user);
      // Prefer X-Workspace-Id; accept legacy X-Account-Id for older clients.
      const workspaceId =
        c.req.header("X-Workspace-Id") || c.req.header("X-Account-Id") || undefined;
      if (workspaceId) c.set("workspaceId", workspaceId);
      await next();
    } catch {
      return c.json({ error: "Invalid token" }, 401);
    }
  }
);

export const requireAdmin = createMiddleware<{ Bindings: Env; Variables: AppVariables }>(
  async (c, next) => {
    const user = c.get("user");
    if (!user) return c.json({ error: "Forbidden" }, 403);

    const dbRole = await resolvePlatformRole(c.env, user.id);
    if (dbRole !== "admin" && dbRole !== "superadmin") {
      return c.json({ error: "Forbidden" }, 403);
    }

    c.set("user", { ...user, role: dbRole });
    await next();
  }
);

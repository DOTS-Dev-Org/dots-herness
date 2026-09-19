import { Hono } from "hono";
import { zValidator } from "@hono/zod-validator";
import { z } from "zod";
import type { Env, AppVariables } from "../../env";
import { db, normalizeEmail } from "../../db/client";
import { getUserByEmail, buildUserProfile } from "../../lib/users";
import { hashToken } from "../../lib/jwt";
import { hasSeatAvailable } from "../../lib/team";
import { rateLimit } from "../../middleware/rate-limit";

/** Public POST /team/accept-invite — mounted before authenticated teamRoutes. */
const acceptInviteRoutes = new Hono<{ Bindings: Env; Variables: AppVariables }>().post(
  "/accept-invite",
  rateLimit({ limit: 20, windowSeconds: 60, keyPrefix: "team:accept-invite" }),
  zValidator("json", z.object({
    email: z.string().email(),
    token: z.string(),
  })),
  async (c) => {
    const { email, token } = c.req.valid("json");
    const tokenHash = await hashToken(token);
    const invite = await db(c.env)
      .prepare("SELECT id, workspace_id, role FROM team_invites WHERE (token = ? OR token = ?) AND email = ? AND accepted_at IS NULL AND datetime(expires_at) > CURRENT_TIMESTAMP")
      .bind(tokenHash, token, normalizeEmail(email))
      .first<{ id: string; workspace_id: string; role: string }>();
    if (!invite) return c.json({ ok: false, error: "Invalid or expired invite" }, 400);

    const user = await getUserByEmail(c.env, email);
    if (!user) return c.json({ ok: false, error: "User not found. Please register first." }, 404);
    if (user.status !== "active") {
      return c.json({ ok: false, error: "account_inactive" }, 403);
    }

    const alreadyMember = await db(c.env)
      .prepare("SELECT 1 FROM workspace_members WHERE workspace_id = ? AND user_id = ?")
      .bind(invite.workspace_id, user.id)
      .first();
    if (alreadyMember) {
      await db(c.env).prepare("UPDATE team_invites SET token = ?, accepted_at = NOW() WHERE id = ?").bind(tokenHash, invite.id).run();
      const profile = await buildUserProfile(c.env, user.id, invite.workspace_id);
      return c.json({ ok: true, user: profile });
    }

    const seats = await hasSeatAvailable(c.env, invite.workspace_id);
    if (!seats.available) {
      return c.json({ ok: false, error: "seat_limit_reached", used: seats.used, limit: seats.limit }, 409);
    }

    await db(c.env)
      .prepare("INSERT INTO workspace_members (workspace_id, user_id, role, joined_at) VALUES (?, ?, ?, NOW()) ON CONFLICT (workspace_id, user_id) DO NOTHING")
      .bind(invite.workspace_id, user.id, invite.role || "member")
      .run();
    await db(c.env).prepare("UPDATE team_invites SET token = ?, accepted_at = NOW() WHERE id = ?").bind(tokenHash, invite.id).run();

    const profile = await buildUserProfile(c.env, user.id, invite.workspace_id);
    return c.json({ ok: true, user: profile });
  },
);

export default acceptInviteRoutes;

import { Hono } from "hono";
import { zValidator } from "@hono/zod-validator";
import { z } from "zod";
import type { Env, AppVariables } from "../../env";
import { db, normalizeEmail, sqliteTimestamp, uuid } from "../../db/client";
import { requireAuth } from "../../middleware/auth";
import { clientIpFromRequest, recordAudit } from "../../lib/audit";
import { hashToken } from "../../lib/jwt";
import { giftRenewDate } from "../../lib/billing";
import { loadWorkspaceUsage } from "../../lib/usage";
import { mapPlatformToProviderId, parseUsageSnapshot } from "../../lib/users";
import { normalizeSyncInterval } from "../../lib/sync_interval";
import {
  TEAM_ROLES,
  getTeamMember,
  hasSeatAvailable,
  rank,
  requireAccountRole,
  type TeamRole,
} from "../../lib/team";
import { planFeaturesForSlug } from "../../lib/plan_features";
import {
  fetchUsageHistoryRows,
  fetchUsageLogsPage,
  enrichLogsWithSubscription,
} from "../../lib/usage_logs";
import { encryptUserKeyValue } from "../../lib/user_key_crypto";
import { vpsCacheBust } from "../../lib/vps_usage";

const team = new Hono<{ Bindings: Env; Variables: AppVariables }>();

team.use("*", requireAuth);

const ROLE_ORDER = `CASE am.role WHEN 'owner' THEN 0 WHEN 'admin' THEN 1 WHEN 'assistant' THEN 2 ELSE 3 END`;

type MemberRow = {
  user_id: string;
  role: string;
  joined_at: string | null;
  email: string;
  name: string | null;
  avatar: string | null;
  note: string | null;
  plan: string | null;
  user_status: string | null;
  provider_count: number;
  max_used_percent: number | null;
};

function isManagerRole(role: TeamRole): boolean {
  return role === "owner" || role === "admin";
}

function canObserveRole(role: TeamRole): boolean {
  return isManagerRole(role);
}

// ---- CSV / usage-history yardımcıları ----

function csvEscape(val: unknown): string {
  if (val == null) return "";
  const s = String(val);
  return /[",\n\r]/.test(s) ? '"' + s.replace(/"/g, '""') + '"' : s;
}

function rowsToCsv(header: string[], rows: unknown[][]): string {
  const lines = [header.join(",")];
  for (const r of rows) lines.push(r.map(csvEscape).join(","));
  // Excel'in UTF-8'i doğru okuması için BOM ekle.
  return "\ufeff" + lines.join("\r\n");
}

function csvResponse(csv: string, filename: string): Response {
  const safe = filename.replace(/[^\w.\-]+/g, "_");
  return new Response(csv, {
    status: 200,
    headers: {
      "Content-Type": "text/csv; charset=utf-8",
      "Content-Disposition": `attachment; filename="${safe}"`,
      "Cache-Control": "no-store",
    },
  });
}

export function maskApiKey(key: string): string {
  const k = key.trim();
  return k.length <= 4 ? "••••" : "••••" + k.slice(-4);
}

type UsageHistoryRow = {
  observed_at: string;
  user_id: string | null;
  user_email: string | null;
  provider_id: string;
  provider_name: string | null;
  window: string;
  used_percent: number | null;
  used: string | null;
  total: string | null;
  resets_at: string | null;
  source: string | null;
  providers_json: string | null;
  hour_bucket: string | null;
};

async function queryUsageHistory(
  env: Env,
  opts: {
    workspaceId: string;
    userId?: string;
    provider?: string;
    from?: string;
    to?: string;
    limit?: number;
  }
): Promise<UsageHistoryRow[]> {
  const limit = Math.min(Math.max(opts.limit ?? 5000, 1), 50000);
  const { rows } = await fetchUsageHistoryRows(env, {
    workspaceId: opts.workspaceId,
    userId: opts.userId,
    provider: opts.provider,
    from: opts.from,
    to: opts.to,
    limit,
    offset: 0,
    order: "asc",
    includeTotal: false,
  });

  return rows.map((row) => ({
    observed_at: row.observed_at,
    user_id: row.user_id,
    user_email: row.user_email,
    provider_id: row.provider_id,
    provider_name: row.provider_name,
    window: row.window ?? "",
    used_percent: row.used_percent,
    used: row.used,
    total: row.total,
    resets_at: row.resets_at,
    source: row.source,
    providers_json: row.providers_json,
    hour_bucket: row.hour_bucket,
  }));
}

const USAGE_CSV_HEADER = [
  "observed_at",
  "user_email",
  "provider_id",
  "provider_name",
  "window",
  "used_percent",
  "used",
  "total",
  "resets_at",
  "source",
  "providers_json",
  "hour_bucket",
];

function usageHistoryToCsvRows(
  rows: UsageHistoryRow[],
  fallbackEmail?: string
): unknown[][] {
  return rows.map((r) => [
    r.observed_at,
    r.user_email ?? fallbackEmail ?? "",
    r.provider_id,
    r.provider_name ?? r.provider_id,
    r.window,
    r.used_percent,
    r.used,
    r.total,
    r.resets_at,
    r.source,
    r.providers_json,
    r.hour_bucket,
  ]);
}

// GET /api/team/members — team paneli yalnızca görevli roller içindir.
team.get("/members", requireAccountRole(["owner", "admin", "assistant"]), async (c) => {
  const workspaceId = c.get("workspaceId")!;
  const myRole = c.get("workspaceRole") as TeamRole;

  const { results } = await db(c.env)
    .prepare(
      `SELECT am.user_id, am.role, am.joined_at, am.note, u.email, u.name, u.avatar,
              u.plan, u.status AS user_status,
              COALESCE(uk_stats.provider_count, 0) AS provider_count,
              NULL AS max_used_percent
         FROM workspace_members am
         JOIN users u ON u.id = am.user_id
         LEFT JOIN (
           SELECT uk.user_id,
                  COUNT(*) AS provider_count
             FROM user_connections uk
            GROUP BY uk.user_id
         ) uk_stats ON uk_stats.user_id = am.user_id
        WHERE am.workspace_id = ?
        ORDER BY ${ROLE_ORDER}, am.joined_at ASC`
    )
    .bind(workspaceId)
    .all<MemberRow>();

  const maxUsageByUser = new Map<string, number>();
  const memberIds = (results || []).map((row) => row.user_id);
  if (memberIds.length > 0) {
    const { results: snapshots } = await db(c.env)
      .prepare(
        `SELECT user_id, snapshot_json FROM user_usage_snapshots
          WHERE user_id IN (${memberIds.map(() => "?").join(", ")})`
      )
      .bind(...memberIds)
      .all<{ user_id: string; snapshot_json: string | null }>();
    for (const row of snapshots || []) {
      let max = -1;
      for (const entry of Object.values(parseUsageSnapshot(row.snapshot_json))) {
        if (entry.used_percent != null) max = Math.max(max, entry.used_percent);
        for (const window of entry.windows || []) {
          if (window.used_percent != null) max = Math.max(max, window.used_percent);
        }
      }
      if (max >= 0) maxUsageByUser.set(row.user_id, max);
    }
  }

  const showNote = isManagerRole(myRole);
  const members = (results || []).map((r) => ({
    user_id: r.user_id,
    email: r.email,
    name: r.name ?? undefined,
    avatar: r.avatar ?? undefined,
    role: r.role as TeamRole,
    joined_at: r.joined_at ?? undefined,
    note: showNote ? (r.note ?? undefined) : undefined,
    plan: r.plan ?? "free",
    user_status: r.user_status ?? "active",
    provider_count: r.provider_count ?? 0,
    max_used_percent: maxUsageByUser.get(r.user_id) ?? null,
  }));

  const seats = await hasSeatAvailable(c.env, workspaceId);

  return c.json({ members, seats: { used: seats.used, limit: seats.limit } });
});

// GET /api/team/invites — owner/admin/assistant: all pending; member: 403
team.get("/invites", requireAccountRole(["owner", "admin", "assistant"]), async (c) => {
  const workspaceId = c.get("workspaceId")!;
  const { results } = await db(c.env)
    .prepare(
      `SELECT id, email, role, created_at, expires_at, invited_by
         FROM team_invites
        WHERE workspace_id = ? AND accepted_at IS NULL
          AND datetime(expires_at) > CURRENT_TIMESTAMP
        ORDER BY created_at DESC`
    )
    .bind(workspaceId)
    .all<{
      id: string;
      email: string;
      role: string;
      created_at: string;
      expires_at: string;
      invited_by: string | null;
    }>();

  return c.json(
    (results || []).map((r) => ({
      id: r.id,
      email: r.email,
      role: r.role as TeamRole,
      created_at: r.created_at,
      expires_at: r.expires_at,
      invited_by: r.invited_by ?? undefined,
    }))
  );
});

// GET /api/team/members/:memberId/providers — yalnızca owner/admin.
team.get(
  "/members/:memberId/providers",
  requireAccountRole(["owner", "admin"]),
  async (c) => {
    const workspaceId = c.get("workspaceId")!;
    const memberId = c.req.param("memberId");

    const target = await getTeamMember(c.env, workspaceId, memberId);
    if (!target) return c.json({ error: "Member not found" }, 404);

    const { results } = await db(c.env)
      .prepare(
        `SELECT id, provider, name, key_masked, account_label, created_at, scope
           FROM user_connections
          WHERE user_id = ?
          ORDER BY created_at DESC`
      )
      .bind(target.user_id)
      .all<{
        id: string;
        provider: string;
        name: string;
        key_masked: string;
        account_label: string | null;
        created_at: string;
        scope: string | null;
      }>();

    return c.json({
      member: { user_id: target.user_id, email: target.email, name: target.name, role: target.role },
      providers: (results || []).map((r) => ({
        id: r.id,
        provider: r.provider,
        name: r.name,
        key_masked: r.key_masked,
        account_label: r.account_label,
        created_at: r.created_at,
        scope: r.scope || "personal",
      })),
    });
  }
);

// GET /api/team/members/:memberId/usage — yalnızca owner/admin.
team.get(
  "/members/:memberId/usage",
  requireAccountRole(["owner", "admin"]),
  async (c) => {
    const workspaceId = c.get("workspaceId")!;
    const memberId = c.req.param("memberId");

    const target = await getTeamMember(c.env, workspaceId, memberId);
    if (!target) return c.json({ error: "Member not found" }, 404);

    const { usage, billingProviders, connectedProviderIds } = await loadWorkspaceUsage(
      c.env,
      workspaceId,
      normalizeEmail(target.email),
      undefined,
      target.user_id,
      { includeTeamShared: false }
    );

    const connectedBilling = billingProviders.filter((p) =>
      connectedProviderIds.includes(p.id)
    );
    const monthlySpendUsdCents = connectedBilling.reduce(
      (sum, p) => sum + (p.source === "needs_desktop" ? 0 : p.priceUsdCents ?? 0),
      0
    );

    const acc = await db(c.env)
      .prepare(
        `SELECT gift_months, gift_started_at, plan_slug
           FROM workspaces WHERE id = ?`
      )
      .bind(workspaceId)
      .first<{
        gift_months: number | null;
        gift_started_at: string | null;
        plan_slug: string | null;
      }>();

    const { planDefForSlug } = await import("../../lib/plan_features");
    const planDef = planDefForSlug(acc?.plan_slug);
    const isGift = (acc?.gift_months ?? 0) > 0;
    const monthlyLimitUsdCents = isGift ? 0 : planDef.price_monthly_cents;
    const renewDate = isGift
      ? giftRenewDate(acc?.gift_months, acc?.gift_started_at)
      : null;

    return c.json({
      member: { user_id: target.user_id, email: target.email, name: target.name, role: target.role },
      usage,
      connectedProviderIds,
      billingInfo: {
        mode: "subscription" as const,
        monthlySpendUsdCents,
        monthlyLimitUsdCents,
        currency: "USD",
        renewDate,
        isGift,
        paymentMethod: null,
        activeProvidersCount: connectedProviderIds.length,
        providers: billingProviders,
      },
    });
  }
);

// POST /api/team/invite — owner/admin/assistant. assistant: role forced to 'member'.
const inviteSchema = z.object({
  email: z.string().email(),
  role: z.enum(["admin", "assistant", "member"]).default("member"),
});

team.post(
  "/invite",
  requireAccountRole(["owner", "admin", "assistant"]),
  zValidator("json", inviteSchema),
  async (c) => {
    const parsed = c.req.valid("json");
    const workspaceId = c.get("workspaceId")!;
    const myRole = c.get("workspaceRole") as TeamRole;
    const myId = c.get("user").id;

  const email = normalizeEmail(parsed.email);
  let role = parsed.role;
  if (myRole === "assistant") role = "member"; // assistants can only invite members

  const planRow = await db(c.env)
    .prepare(`SELECT plan_slug AS slug FROM workspaces WHERE id = ?`)
    .bind(workspaceId)
    .first<{ slug: string | null }>();

  if (!planFeaturesForSlug(planRow?.slug).teamManagement) {
    return c.json(
      { error: "team_not_available", message: "Ekip yönetimi Team planında kullanılabilir" },
      403
    );
  }

  // Seat limit
  const seats = await hasSeatAvailable(c.env, workspaceId);
  if (!seats.available) {
    return c.json(
      { error: "seat_limit_reached", used: seats.used, limit: seats.limit },
      409
    );
  }

  // Prevent duplicate pending invite / existing member
  const existingMember = await db(c.env)
    .prepare("SELECT 1 FROM workspace_members WHERE workspace_id = ? AND user_id IN (SELECT id FROM users WHERE email = ?)")
    .bind(workspaceId, email)
    .first();
  if (existingMember) {
    return c.json({ error: "already_member" }, 409);
  }

  const existingPending = await db(c.env)
    .prepare("SELECT 1 FROM team_invites WHERE workspace_id = ? AND email = ? AND accepted_at IS NULL AND datetime(expires_at) > CURRENT_TIMESTAMP")
    .bind(workspaceId, email)
    .first();
  if (existingPending) {
    return c.json({ error: "invite_already_pending" }, 409);
  }

  const id = uuid();
  const token = crypto.randomUUID();
  const expires = new Date();
  expires.setDate(expires.getDate() + 7);
  const expiresAt = sqliteTimestamp(expires);

  await db(c.env)
    .prepare(
      `INSERT INTO team_invites (id, workspace_id, email, role, token, invited_by, expires_at)
       VALUES (?, ?, ?, ?, ?, ?, ?)`
    )
    .bind(id, workspaceId, email, role, await hashToken(token), myId, expiresAt)
    .run();

  await recordAudit(c.env, {
    workspaceId,
    actorUserId: myId,
    actorEmail: c.get("user").email,
    action: "team.invite",
    entityType: "team_invite",
    entityId: id,
    metadata: { email, role },
    ip: clientIpFromRequest(c.req),
    userAgent: c.req.header("User-Agent") ?? null,
  });

  return c.json({
    id,
    email,
    role,
    token,
    invited_by: myId,
    expires_at: expiresAt,
  });
});

// DELETE /api/team/invites/:id — owner/admin: any; assistant: only own
team.delete("/invites/:id", requireAccountRole(["owner", "admin", "assistant"]), async (c) => {
  const workspaceId = c.get("workspaceId")!;
  const myRole = c.get("workspaceRole") as TeamRole;
  const myId = c.get("user").id;

  const invite = await db(c.env)
    .prepare("SELECT invited_by FROM team_invites WHERE id = ? AND workspace_id = ? AND accepted_at IS NULL")
    .bind(c.req.param("id"), workspaceId)
    .first<{ invited_by: string | null }>();

  if (!invite) return c.json({ error: "Invite not found" }, 404);
  if (myRole === "assistant" && invite.invited_by !== myId) {
    return c.json({ error: "Forbidden" }, 403);
  }

  await db(c.env)
    .prepare("DELETE FROM team_invites WHERE id = ? AND workspace_id = ?")
    .bind(c.req.param("id"), workspaceId)
    .run();

  await recordAudit(c.env, {
    workspaceId,
    actorUserId: myId,
    actorEmail: c.get("user").email,
    action: "team.invite.revoke",
    entityType: "invite",
    entityId: c.req.param("id"),
    ip: clientIpFromRequest(c.req),
    userAgent: c.req.header("User-Agent") ?? null,
  });

  return c.json({ ok: true });
});

// PATCH /api/team/members/:memberId/role — owner/admin; target must not be owner
const roleSchema = z.object({
  role: z.enum(["admin", "assistant", "member"]),
});

team.patch(
  "/members/:memberId/role",
  requireAccountRole(["owner", "admin"]),
  zValidator("json", roleSchema),
  async (c) => {
    const parsed = c.req.valid("json");
    const workspaceId = c.get("workspaceId")!;
    const myRole = c.get("workspaceRole") as TeamRole;
    const myId = c.get("user").id;
    const memberId = c.req.param("memberId");

    if (memberId === myId) {
      return c.json({ error: "Cannot change your own role" }, 403);
    }

    const target = await getTeamMember(c.env, workspaceId, memberId);
    if (!target) return c.json({ error: "Member not found" }, 404);
    if (target.role === "owner") {
      return c.json({ error: "Cannot modify owner" }, 403);
    }
    if (rank(myRole) <= rank(target.role)) {
      return c.json({ error: "Forbidden" }, 403);
    }
    if (rank(myRole) <= rank(parsed.role)) {
      return c.json({ error: "Forbidden" }, 403);
    }

    await db(c.env)
      .prepare("UPDATE workspace_members SET role = ? WHERE workspace_id = ? AND user_id = ?")
      .bind(parsed.role, workspaceId, memberId)
      .run();

    await recordAudit(c.env, {
      workspaceId,
      actorUserId: myId,
      actorEmail: c.get("user").email,
      action: "team.member.role",
      entityType: "team_member",
      entityId: memberId,
      metadata: { old_role: target.role, new_role: parsed.role },
      ip: clientIpFromRequest(c.req),
      userAgent: c.req.header("User-Agent") ?? null,
    });

    return c.json({ ok: true, user_id: memberId, role: parsed.role });
  }
);

// DELETE /api/team/members/:memberId — owner/admin (target not owner); member: leave (self only)
team.delete("/members/:memberId", requireAccountRole(TEAM_ROLES), async (c) => {
  const workspaceId = c.get("workspaceId")!;
  const myRole = c.get("workspaceRole") as TeamRole;
  const myId = c.get("user").id;
  const memberId = c.req.param("memberId");

  const target = await getTeamMember(c.env, workspaceId, memberId);
  if (!target) return c.json({ error: "Member not found" }, 404);

  if (target.role === "owner") {
    return c.json({ error: "Cannot remove owner" }, 403);
  }

  if (target.user_id === myId) {
    // self-leave is allowed for any role except owner (already blocked above)
  } else if (!isManagerRole(myRole)) {
    return c.json({ error: "Forbidden" }, 403);
  } else if (rank(myRole) <= rank(target.role)) {
    return c.json({ error: "Forbidden" }, 403);
  }

  await db(c.env)
    .prepare("DELETE FROM workspace_members WHERE workspace_id = ? AND user_id = ?")
    .bind(workspaceId, memberId)
    .run();

  await recordAudit(c.env, {
    workspaceId,
    actorUserId: myId,
    actorEmail: c.get("user").email,
    action: "team.member.remove",
    entityType: "team_member",
    entityId: memberId,
    metadata: { email: target.email, role: target.role, self_leave: target.user_id === myId },
    ip: clientIpFromRequest(c.req),
    userAgent: c.req.header("User-Agent") ?? null,
  });

  return c.json({ ok: true });
});

// POST /api/team/transfer — owner only; target must be an existing admin; old owner becomes admin
const transferSchema = z.object({ memberId: z.string().min(1) });

team.post(
  "/transfer",
  requireAccountRole(["owner"]),
  zValidator("json", transferSchema),
  async (c) => {
    const parsed = c.req.valid("json");
    const workspaceId = c.get("workspaceId")!;
    const myId = c.get("user").id;
    const targetId = parsed.memberId;

  if (targetId === myId) return c.json({ error: "Cannot transfer to yourself" }, 400);

  const target = await getTeamMember(c.env, workspaceId, targetId);
  if (!target) return c.json({ error: "Member not found" }, 404);
  if (target.role !== "admin") {
    return c.json({ error: "transfer_target_must_be_admin" }, 400);
  }

  await db(c.env)
    .prepare("UPDATE workspace_members SET role = 'admin' WHERE workspace_id = ? AND user_id = ?")
    .bind(workspaceId, myId)
    .run();
  await db(c.env)
    .prepare("UPDATE workspace_members SET role = 'owner' WHERE workspace_id = ? AND user_id = ?")
    .bind(workspaceId, targetId)
    .run();

  await recordAudit(c.env, {
    workspaceId,
    actorUserId: myId,
    actorEmail: c.get("user").email,
    action: "team.transfer",
    entityType: "account",
    entityId: workspaceId,
    metadata: {
      previous_owner_id: myId,
      new_owner_id: targetId,
      new_owner_email: target.email,
    },
    ip: clientIpFromRequest(c.req),
    userAgent: c.req.header("User-Agent") ?? null,
  });

  return c.json({ ok: true, owner_id: targetId });
});

// GET /api/team/usage/logs — workspace'teki tüm kullanıcıların kullanım ve harcama logları
team.get(
  "/usage/logs",
  requireAccountRole(TEAM_ROLES),
  async (c) => {
    const workspaceId = c.get("workspaceId")!;
    const myRole = c.get("workspaceRole") as TeamRole;

    if (!canObserveRole(myRole)) {
      return c.json({ error: "Forbidden" }, 403);
    }

    const userId = c.req.query("user_id") || undefined;
    const provider = c.req.query("provider") || undefined;
    const from = c.req.query("from") || undefined;
    const to = c.req.query("to") || undefined;
    const limit = Math.min(Math.max(Number(c.req.query("limit")) || 25, 1), 100);
    const offset = Number(c.req.query("offset")) || 0;

    const { logs, total } = await fetchUsageLogsPage(c.env, {
      workspaceId,
      userId,
      provider,
      from,
      to,
      limit,
      offset,
    });

    const enriched = await enrichLogsWithSubscription(c.env, workspaceId, logs);

    return c.json({
      logs: enriched,
      total,
    });
  }
);

// GET /api/team/members/:memberId/usage/history — trend grafiği için zaman serisi
team.get(
  "/members/:memberId/usage/history",
  requireAccountRole(["owner", "admin"]),
  async (c) => {
    const workspaceId = c.get("workspaceId")!;
    const memberId = c.req.param("memberId");

    const target = await getTeamMember(c.env, workspaceId, memberId);
    if (!target) return c.json({ error: "Member not found" }, 404);

    const history = await queryUsageHistory(c.env, {
      workspaceId,
      userId: memberId,
      provider: c.req.query("provider") || undefined,
      from: c.req.query("from") || undefined,
      to: c.req.query("to") || undefined,
      limit: 3000,
    });

    return c.json({
      member: {
        user_id: target.user_id,
        email: target.email,
        name: target.name,
        role: target.role,
      },
      history,
    });
  }
);

// GET /api/team/members/:memberId/usage/export.csv — kullanıcı bazlı CSV
team.get(
  "/members/:memberId/usage/export.csv",
  requireAccountRole(["owner", "admin"]),
  async (c) => {
    const workspaceId = c.get("workspaceId")!;
    const memberId = c.req.param("memberId");

    const target = await getTeamMember(c.env, workspaceId, memberId);
    if (!target) return c.json({ error: "Member not found" }, 404);

    const rows = await queryUsageHistory(c.env, {
      workspaceId,
      userId: memberId,
      provider: c.req.query("provider") || undefined,
      from: c.req.query("from") || undefined,
      to: c.req.query("to") || undefined,
      limit: 50000,
    });

    const csv = rowsToCsv(
      USAGE_CSV_HEADER,
      usageHistoryToCsvRows(rows, target.email)
    );
    const stamp = new Date().toISOString().slice(0, 10);
    return csvResponse(csv, `usage-${target.email}-${stamp}.csv`);
  }
);

// GET /api/team/usage/export.csv — tüm ekip için toplu CSV (owner/admin)
team.get(
  "/usage/export.csv",
  requireAccountRole(["owner", "admin"]),
  async (c) => {
    const workspaceId = c.get("workspaceId")!;
    const rows = await queryUsageHistory(c.env, {
      workspaceId,
      provider: c.req.query("provider") || undefined,
      from: c.req.query("from") || undefined,
      to: c.req.query("to") || undefined,
      limit: 50000,
    });
    const csv = rowsToCsv(USAGE_CSV_HEADER, usageHistoryToCsvRows(rows));
    const stamp = new Date().toISOString().slice(0, 10);
    return csvResponse(csv, `team-usage-${stamp}.csv`);
  }
);

// PATCH /api/team/members/:memberId/note — üyeye özel yönetici notu (owner/admin)
const noteSchema = z.object({ note: z.string().max(2000).nullable().optional() });

team.patch(
  "/members/:memberId/note",
  requireAccountRole(["owner", "admin"]),
  zValidator("json", noteSchema),
  async (c) => {
    const workspaceId = c.get("workspaceId")!;
    const memberId = c.req.param("memberId");
    const target = await getTeamMember(c.env, workspaceId, memberId);
    if (!target) return c.json({ error: "Member not found" }, 404);

    const note = c.req.valid("json").note ?? null;
    await db(c.env)
      .prepare("UPDATE workspace_members SET note = ? WHERE workspace_id = ? AND user_id = ?")
      .bind(note, workspaceId, memberId)
      .run();

    await recordAudit(c.env, {
      workspaceId,
      actorUserId: c.get("user").id,
      actorEmail: c.get("user").email,
      action: "team.member.note",
      entityType: "team_member",
      entityId: memberId,
      metadata: { old_note: target.note ?? null, new_note: note },
      ip: clientIpFromRequest(c.req),
      userAgent: c.req.header("User-Agent") ?? null,
    });

    return c.json({ ok: true, user_id: memberId, note });
  }
);

// POST /api/team/members/:memberId/providers — üyeye API key provider ekle (owner only)
const addProviderSchema = z.object({
  provider: z.string().trim().min(1).max(64),
  name: z.string().trim().max(120).optional(),
  key_value: z.string().trim().min(1).max(4096),
  sync_interval_secs: z.number().int().optional(),
});

team.post(
  "/members/:memberId/providers",
  requireAccountRole(["owner"]),
  zValidator("json", addProviderSchema),
  async (c) => {
    const workspaceId = c.get("workspaceId")!;
    const memberId = c.req.param("memberId");
    const target = await getTeamMember(c.env, workspaceId, memberId);
    if (!target) return c.json({ error: "Member not found" }, 404);

    const { provider, name, key_value, sync_interval_secs } = c.req.valid("json");
    const providerId = mapPlatformToProviderId(provider);

    const prov = await db(c.env)
      .prepare("SELECT id, name, support_type FROM providers WHERE id = ?")
      .bind(providerId)
      .first<{ id: string; name: string; support_type: string | null }>();
    if (!prov) return c.json({ error: "provider_not_found" }, 404);
    const support = prov.support_type || "api_key";
    if (support !== "api_key" && support !== "api_and_subscription") {
      return c.json({ error: "not_api_key_provider" }, 400);
    }

    const id = uuid();
    const masked = maskApiKey(key_value);
    const displayName = (name && name.trim()) || prov.name;
    const createdAt = new Date().toISOString();
    const syncInterval = normalizeSyncInterval(sync_interval_secs);
    const ownerEmail = normalizeEmail(target.email);
    const encryptedKey = await encryptUserKeyValue(c.env, target.user_id, key_value);

    await db(c.env)
      .prepare(
        `INSERT INTO user_connections (id, user_id, user_email, provider, name, key_masked, key_value, created_at, sync_interval_secs, scope)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'account')`
      )
      .bind(id, target.user_id, ownerEmail, provider.trim(), displayName, masked, encryptedKey, createdAt, syncInterval)
      .run();
    await vpsCacheBust(c.env, { prefix: `conns:${target.user_id ?? c.get("user").id}` });

    await recordAudit(c.env, {
      workspaceId,
      actorUserId: c.get("user").id,
      actorEmail: c.get("user").email,
      action: "key.create",
      entityType: "key",
      entityId: id,
      metadata: {
        provider_id: providerId,
        member_id: memberId,
        member_email: target.email,
        name: displayName,
        key_masked: masked,
      },
      ip: clientIpFromRequest(c.req),
      userAgent: c.req.header("User-Agent") ?? null,
    });

    return c.json({
      ok: true,
      id,
      provider: provider.trim(),
      name: displayName,
      key_masked: masked,
      sync_interval_secs: syncInterval,
      created_at: createdAt,
    });
  }
);

// DELETE /api/team/members/:memberId/providers/:keyId — üyenin API key'ini sil (owner only)
team.delete(
  "/members/:memberId/providers/:keyId",
  requireAccountRole(["owner"]),
  async (c) => {
    const workspaceId = c.get("workspaceId")!;
    const memberId = c.req.param("memberId");
    const keyId = c.req.param("keyId");

    const target = await getTeamMember(c.env, workspaceId, memberId);
    if (!target) return c.json({ error: "Member not found" }, 404);

    const key = await db(c.env)
      .prepare("SELECT id FROM user_connections WHERE id = ? AND user_id = ?")
      .bind(keyId, target.user_id)
      .first();
    if (!key) return c.json({ error: "key_not_found" }, 404);

    // user_provider_usage/provider_subscriptions/alert_states FK ON DELETE
    // CASCADE ile otomatik temizlenir (0063 migration).
    await db(c.env)
      .prepare("DELETE FROM user_connections WHERE id = ? AND user_id = ?")
      .bind(keyId, target.user_id)
      .run();
    await vpsCacheBust(c.env, { prefix: `conns:${target.user_id}` });

    await recordAudit(c.env, {
      workspaceId,
      actorUserId: c.get("user").id,
      actorEmail: c.get("user").email,
      action: "key.delete",
      entityType: "key",
      entityId: keyId,
      metadata: { member_id: memberId, member_email: target.email },
      ip: clientIpFromRequest(c.req),
      userAgent: c.req.header("User-Agent") ?? null,
    });

    return c.json({ ok: true });
  }
);

// GET /api/team/settings — owner/admin/assistant/member: view settings
team.get("/settings", requireAccountRole(TEAM_ROLES), async (c) => {
  const workspaceId = c.get("workspaceId")!;
  const account = await db(c.env)
    .prepare(
      `SELECT id, name, plan_slug, subscription_ends_at, created_at
         FROM workspaces WHERE id = ?`
    )
    .bind(workspaceId)
    .first<{
      id: string;
      name: string;
      plan_slug: string | null;
      subscription_ends_at: string | null;
      created_at: string;
    }>();

  if (!account) return c.json({ error: "Account not found" }, 404);

  const { planDefForSlug } = await import("../../lib/plan_features");
  const planDef = planDefForSlug(account.plan_slug);
  const seats = await hasSeatAvailable(c.env, workspaceId);

  return c.json({
    id: account.id,
    name: account.name,
    plan_name: planDef.name,
    subscription_ends_at: account.subscription_ends_at,
    max_providers: planDef.max_providers,
    created_at: account.created_at,
    seats: {
      used: seats.used,
      limit: seats.limit,
    },
  });
});

// PATCH /api/team/settings — owner/admin only: update account name
const settingsSchema = z.object({
  name: z.string().min(1).max(100),
});

team.patch(
  "/settings",
  requireAccountRole(["owner", "admin"]),
  zValidator("json", settingsSchema),
  async (c) => {
    const parsed = c.req.valid("json");
    const workspaceId = c.get("workspaceId")!;

    await db(c.env)
      .prepare("UPDATE workspaces SET name = ?, updated_at = datetime('now') WHERE id = ?")
      .bind(parsed.name, workspaceId)
      .run();

    return c.json({ ok: true, name: parsed.name });
  }
);

// GET /api/team/shared-keys — owner/admin: list shared keys
team.get("/shared-keys", requireAccountRole(["owner", "admin"]), async (c) => {
  const workspaceId = c.get("workspaceId")!;

  const { results } = await db(c.env)
    .prepare(
      `SELECT uk.id, uk.user_email, u.id AS user_id, uk.provider, uk.name, uk.key_masked, uk.account_label, uk.created_at, u.name as user_name
         FROM user_connections uk
         JOIN users u ON u.id = uk.user_id
         JOIN workspace_members am ON am.user_id = u.id
        WHERE am.workspace_id = ? AND uk.scope = 'account'
        ORDER BY uk.created_at DESC`
    )
    .bind(workspaceId)
    .all<{
      id: string;
      user_email: string;
      user_id: string;
      provider: string;
      name: string;
      key_masked: string;
      account_label: string | null;
      created_at: string;
      user_name: string | null;
    }>();

  return c.json(results || []);
});

export default team;

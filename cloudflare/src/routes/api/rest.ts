import { Hono } from "hono";
import type { Env, AppVariables } from "../../env";
import { db, normalizeEmail, sqliteTimestamp, uuid } from "../../db/client";
import { requireAuth, resolvePlatformRole } from "../../middleware/auth";
import { clientIpFromRequest, recordAudit } from "../../lib/audit";
import { hashToken } from "../../lib/jwt";
import { hasSeatAvailable } from "../../lib/team";

// ─── Tablo Tanımları ve Güvenlik Kuralları ──────────────────────
//
//  rls        → RLS kolonu veya membership modu için null
//  rlsType    → "id" | "email" | "workspace_scope" | "membership"
//  readOnly   → true ise POST/PATCH/DELETE yasak (admin bypass hariç)
//  writePolicy → "workspace_owner" → yazma için owner rolü gerekir
//  hiddenCols / immutable → güvenlik
//
const TABLES = {
  users: {
    rls: "id",
    rlsType: "id" as const,
    readOnly: false,
    hiddenCols: ["password_hash"],
    immutable: ["id", "email", "role", "plan", "status", "email_verified", "auth_provider", "provider_id", "created_at"],
  },
  user_connections: {
    rls: "user_id",
    rlsType: "id" as const,
    readOnly: false,
    hiddenCols: ["key_value"],
    immutable: ["id", "user_id", "user_email", "created_at"],
  },
  user_devices: {
    rls: "user_id",
    rlsType: "id" as const,
    readOnly: false,
    hiddenCols: [] as string[],
    immutable: ["id", "user_id", "created_at"],
  },
  billing_orders: {
    rls: "customer_email",
    rlsType: "email" as const,
    readOnly: true,
    deletePolicy: "superadmin" as const,
    hiddenCols: ["paytr_token", "metadata_json"],
    immutable: [] as string[],
  },
  providers: {
    rls: null,
    rlsType: "id" as const,
    readOnly: true,
    hiddenCols: [] as string[],
    immutable: [] as string[],
  },
  system_settings: {
    rls: null,
    rlsType: "id" as const,
    readOnly: true,
    hiddenCols: [] as string[],
    immutable: [] as string[],
  },
  landing_stats: {
    rls: null,
    rlsType: "id" as const,
    readOnly: true,
    hiddenCols: [] as string[],
    immutable: [] as string[],
  },
  workspaces: {
    rls: null,
    rlsType: "membership" as const,
    readOnly: true,
    hiddenCols: [] as string[],
    // plan_slug mutable by superadmin (readOnly table) so admin can gift plans
    immutable: ["id", "created_at", "extra_seats"],
  },
  workspace_members: {
    rls: null,
    rlsType: "workspace_scope" as const,
    readOnly: false,
    writePolicy: "workspace_owner" as const,
    hiddenCols: [] as string[],
    immutable: ["workspace_id", "user_id", "created_at"],
  },
  team_invites: {
    rls: null,
    rlsType: "workspace_scope" as const,
    readOnly: false,
    writePolicy: "workspace_owner" as const,
    hiddenCols: ["token"],
    immutable: ["id", "workspace_id", "token", "invited_by", "created_at"],
  },
};

export const PUBLIC_REST_TABLES = new Set(["providers", "landing_stats", "system_settings"]);

/** Keys safe to expose on the unauthenticated landing/features pages. */
export const PUBLIC_SYSTEM_SETTINGS_KEYS = ["github_link", "holiday_mode", "app_size"] as const;

type RlsType = "id" | "email" | "membership" | "workspace_scope";

type TableRow = {
  rls: string | null;
  rlsType: RlsType;
  readOnly: boolean;
  hiddenCols: string[];
  immutable: string[];
  writePolicy?: "workspace_owner";
  deletePolicy?: "superadmin";
};

type TableName = keyof typeof TABLES;

type TableConfig = TableRow & { name: TableName };

const SAFE_IDENTIFIER = /^[a-zA-Z_][a-zA-Z0-9_]*$/;
const ALLOWED_OPS: Record<string, string> = {
  eq: "=", neq: "!=", gt: ">", gte: ">=",
  lt: "<", lte: "<=", like: "LIKE", ilike: "LIKE",
  is: "IS", in: "IN",
};
const GET_RESERVED = new Set(["select", "limit", "offset", "order"]);

function assertSafeId(val: string, label: string) {
  if (!SAFE_IDENTIFIER.test(val)) throw new Error(`Invalid ${label}: ${val}`);
}

function isAdminUser(role: string) {
  return role === "admin" || role === "superadmin";
}

function isSuperAdmin(role: string) {
  return role === "superadmin";
}

/**
 * Personal / identity-scoped tables: always enforce RLS even for admin/superadmin.
 * Global admin aggregates must use /api/admin/* instead of unscoped REST.
 */
export const ALWAYS_RLS_TABLES = new Set([
  "user_connections",
  "user_devices",
  "billing_orders",
]);

/** Admin + superadmin: global read via REST (except personal tables). */
export function skipRlsForRead(role: string, tableName: string) {
  if (ALWAYS_RLS_TABLES.has(tableName)) return false;
  return isAdminUser(role);
}

/** Superadmin only: global write via REST (except personal tables). */
export function skipRlsForWrite(role: string, tableName: string) {
  if (ALWAYS_RLS_TABLES.has(tableName)) return false;
  return isSuperAdmin(role);
}

/** Refresh JWT role from DB so demoted admins lose REST privilege immediately. */
async function syncUserRoleFromDb(
  env: Env,
  user: { id: string; email: string; role: string }
): Promise<{ id: string; email: string; role: string }> {
  const dbRole = await resolvePlatformRole(env, user.id);
  return { ...user, role: dbRole ?? user.role };
}

function getTable(name: string): TableConfig {
  if (!(name in TABLES)) throw new Error("Forbidden table");
  return { name: name as TableName, ...TABLES[name as TableName] };
}

function stripHiddenCols(rows: Record<string, unknown>[], hidden: string[]) {
  if (hidden.length === 0) return rows;
  return rows.map((row) => {
    const clean = { ...row };
    for (const col of hidden) delete clean[col];
    return clean;
  });
}

const DERIVED_LANDING_STATS = new Set(["supported_platforms"]);

function assertEditableLandingStat(statKey: string | undefined) {
  if (statKey && DERIVED_LANDING_STATS.has(statKey)) {
    throw new Error("supported_platforms is derived from providers and cannot be edited");
  }
}

async function supportedPlatformsStatValue(env: Env): Promise<string> {
  const row = await db(env).prepare("SELECT COUNT(*) AS n FROM providers").first<{ n: number }>();
  return `${row?.n ?? 0}+`;
}

async function applyDerivedLandingStats(
  env: Env,
  rows: Record<string, unknown>[]
): Promise<Record<string, unknown>[]> {
  const value = await supportedPlatformsStatValue(env);
  return rows.map((row) =>
    row.stat_key === "supported_platforms" ? { ...row, value } : row
  );
}

function assertWritable(tbl: TableConfig, role: string) {
  if (tbl.readOnly && !isSuperAdmin(role)) {
    throw new Error("This table is read-only");
  }
}

function assertDeletable(tbl: TableConfig, role: string) {
  if (tbl.deletePolicy === "superadmin" && role !== "superadmin") {
    throw new Error("Forbidden");
  }
}

const ALLOWED_USER_ROLES = new Set(["user", "moderator", "admin", "superadmin"]);

function assertNoImmutableCols(keys: string[], tbl: TableConfig, actorRole?: string) {
  const adminUserBypass = tbl.name === "users" && actorRole && isSuperAdmin(actorRole);
  for (const key of keys) {
    if (tbl.immutable.includes(key)) {
      // role changes: superadmin-only, validated in assertUserRoleChange
      if (key === "role" && tbl.name === "users") continue;
      // ponytail: admin REST bypass — id/created_at stay immutable for users table
      if (adminUserBypass && key !== "id" && key !== "created_at" && key !== "status") continue;
      throw new Error(`Column '${key}' cannot be modified`);
    }
  }
}

async function assertUserRoleChange(
  env: Env,
  actorId: string,
  actorRole: string,
  targetUserId: string,
  newRole: unknown
) {
  if (actorRole !== "superadmin") throw new Error("Forbidden");
  if (actorId === targetUserId) throw new Error("Cannot change your own role");
  if (typeof newRole !== "string" || !ALLOWED_USER_ROLES.has(newRole)) {
    throw new Error("Invalid role");
  }

  const target = await db(env)
    .prepare("SELECT role FROM users WHERE id = ?")
    .bind(targetUserId)
    .first<{ role: string }>();
  if (!target) throw new Error("User not found");
  if (target.role === "superadmin") throw new Error("Superadmin role cannot be changed");
}

function rlsValue(tbl: TableConfig, userId: string, userEmail: string) {
  return tbl.rlsType === "email" ? userEmail : userId;
}

function wantsRepresentation(c: { req: { header: (name: string) => string | undefined } }) {
  return (c.req.header("Prefer") ?? "").includes("return=representation");
}

async function auditUserProfilePatch(
  env: Env,
  c: { get: (k: "user") => { id: string; email: string }; req: { header: (name: string) => string | undefined } },
  targetUserId: string,
  patch: Record<string, unknown>
) {
  const actor = c.get("user");
  const isSelf = targetUserId === actor.id;
  const action = patch.role != null && !isSelf ? "user.role" : "profile.update";
  await recordAudit(env, {
    actorUserId: actor.id,
    actorEmail: actor.email,
    action,
    entityType: "user",
    entityId: targetUserId,
    metadata: { fields: Object.keys(patch), ...(patch.role != null ? { new_role: patch.role } : {}) },
    ip: clientIpFromRequest(c.req),
    userAgent: c.req.header("User-Agent") ?? null,
  });
}

type RestAuditAction = "admin.rest.read" | "admin.rest.write" | "admin.rest.delete";

async function auditAdminRest(
  env: Env,
  c: { get: (k: "user") => { id: string; email: string }; req: { header: (name: string) => string | undefined } },
  action: RestAuditAction,
  table: TableName,
  metadata?: Record<string, unknown>
) {
  const actor = c.get("user");
  await recordAudit(env, {
    actorUserId: actor.id,
    actorEmail: actor.email,
    action,
    entityType: `rest.${table}`,
    metadata: { table, ...metadata },
    ip: clientIpFromRequest(c.req),
    userAgent: c.req.header("User-Agent") ?? null,
  });
}

async function assertWorkspaceMember(env: Env, userId: string, workspaceId: string) {
  const row = await db(env)
    .prepare("SELECT role FROM workspace_members WHERE workspace_id = ? AND user_id = ?")
    .bind(workspaceId, userId)
    .first<{ role: string }>();
  if (!row) throw new Error("Forbidden");
  return row.role;
}

async function assertWorkspaceOwner(env: Env, userId: string, workspaceId: string) {
  const role = await assertWorkspaceMember(env, userId, workspaceId);
  if (role !== "owner") throw new Error("Forbidden");
}

async function resolveWorkspaceId(
  env: Env,
  userId: string,
  headerWorkspaceId: string | undefined,
  bodyWorkspaceId?: unknown
): Promise<string> {
  const workspaceId = (typeof bodyWorkspaceId === "string" && bodyWorkspaceId) || headerWorkspaceId;
  if (!workspaceId) throw new Error("X-Workspace-Id header required");
  await assertWorkspaceMember(env, userId, workspaceId);
  return workspaceId;
}

function buildFilters(
  tbl: TableConfig,
  query: Record<string, string>,
  userId: string,
  userEmail: string,
  options: {
    reserved?: Set<string>;
    requireUserFilters?: boolean;
    skipRls?: boolean;
    /** When set for workspace_scope writes, lock to this account (not membership IN). */
    writeWorkspaceId?: string;
  } = {}
): { conditions: string[]; params: unknown[] } {
  const reserved = options.reserved ?? GET_RESERVED;
  const conditions: string[] = [];
  const params: unknown[] = [];
  let userFilterCount = 0;

  if (!options.skipRls) {
    if (tbl.rlsType === "membership") {
      conditions.push(`id IN (SELECT workspace_id FROM workspace_members WHERE user_id = ?)`);
      params.push(userId);
    } else if (tbl.rlsType === "workspace_scope") {
      if (options.writeWorkspaceId) {
        conditions.push("workspace_id = ?");
        params.push(options.writeWorkspaceId);
      } else {
        conditions.push(
          `workspace_id IN (SELECT workspace_id FROM workspace_members WHERE user_id = ?)`
        );
        params.push(userId);
      }
    } else if (tbl.rls) {
      conditions.push(`${tbl.rls} = ?`);
      params.push(
        tbl.rlsType === "email" ? userEmail : rlsValue(tbl, userId, userEmail)
      );
    }
  }

  for (const [key, val] of Object.entries(query)) {
    if (reserved.has(key)) continue;
    assertSafeId(key, "column");
    if (tbl.hiddenCols.includes(key)) {
      throw new Error(`Cannot filter on column '${key}'`);
    }

    userFilterCount++;
    const dotIdx = val.indexOf(".");
    const op = dotIdx > -1 ? val.slice(0, dotIdx) : "eq";
    const value = dotIdx > -1 ? val.slice(dotIdx + 1) : val;

    if (!(op in ALLOWED_OPS)) throw new Error(`Unknown operator: ${op}`);

    if (op === "in") {
      const vals = value.replace(/^\(|\)$/g, "").split(",");
      if (vals.length === 0) throw new Error("Empty IN clause");
      if (vals.length > 100) throw new Error("IN clause too large");
      conditions.push(`${key} IN (${vals.map(() => "?").join(",")})`);
      params.push(...vals);
    } else if (op === "is") {
      conditions.push(`${key} IS ${value === "null" ? "NULL" : "NOT NULL"}`);
    } else {
      conditions.push(`${key} ${ALLOWED_OPS[op]} ?`);
      params.push(value);
    }
  }

  if (options.requireUserFilters && userFilterCount === 0) {
    throw new Error("At least one filter is required");
  }

  return { conditions, params };
}

/**
 * POST columns that are legitimately client-supplied even though they're
 * PATCH-immutable (required identifiers on insert, or values the table-specific
 * prep function overwrites unconditionally right after).
 */
const POST_IMMUTABLE_EXEMPT: Record<string, string[]> = {
  user_connections: ["user_email"],
  workspace_members: ["user_id", "workspace_id"],
  team_invites: ["workspace_id"],
};

const ALLOWED_TEAM_ASSIGN_ROLES = new Set(["admin", "assistant", "member"]);

function assertAssignableTeamRole(role: unknown) {
  if (typeof role !== "string" || !ALLOWED_TEAM_ASSIGN_ROLES.has(role)) {
    throw new Error("Invalid team role");
  }
}

/**
 * By-id PATCH/DELETE scope. workspace_scope rows must match the owner-validated
 * X-Workspace-Id (not a loose membership IN-subquery — that would allow
 * cross-account deletes when the actor is owner of A and member of B).
 */
export function buildByIdScopeClause(
  tbl: TableConfig,
  options: { skipRls: boolean; userId: string; userEmail: string; workspaceId?: string }
): { clause: string; params: unknown[] } {
  if (options.skipRls) return { clause: "", params: [] };

  if (tbl.rlsType === "workspace_scope") {
    if (!options.workspaceId) throw new Error("X-Workspace-Id header required");
    return { clause: "AND workspace_id = ?", params: [options.workspaceId] };
  }

  if (tbl.rlsType === "membership") {
    return {
      clause: "AND id IN (SELECT workspace_id FROM workspace_members WHERE user_id = ?)",
      params: [options.userId],
    };
  }

  if (tbl.rls) {
    return {
      clause: `AND ${tbl.rls} = ?`,
      params: [rlsValue(tbl, options.userId, options.userEmail)],
    };
  }

  return { clause: "", params: [] };
}

function assertNoByIdForCompositePk(tbl: TableConfig) {
  if (tbl.name === "workspace_members") {
    throw new Error("Use query filters for workspace_members (composite primary key)");
  }
}

async function assertWritePolicy(
  env: Env,
  tbl: TableConfig,
  userId: string,
  workspaceIdHeader: string | undefined,
  body: Record<string, unknown>,
  method: "POST" | "PATCH" | "DELETE",
  query: Record<string, string>
): Promise<string | undefined> {
  if (tbl.writePolicy !== "workspace_owner") return undefined;

  // Prefer X-Workspace-Id so body cannot retarget a different owned workspace.
  const workspaceId =
    workspaceIdHeader ||
    query.workspace_id?.replace(/^eq\./, "") ||
    (typeof body.workspace_id === "string" ? body.workspace_id : undefined);

  if (!workspaceId) throw new Error("X-Workspace-Id header required");
  await assertWorkspaceOwner(env, userId, workspaceId);

  if (tbl.name === "workspace_members" && method === "DELETE") {
    const targetUserId =
      query.user_id?.replace(/^eq\./, "") ||
      (typeof body.user_id === "string" ? body.user_id : undefined);
    if (targetUserId) {
      const target = await db(env)
        .prepare("SELECT role FROM workspace_members WHERE workspace_id = ? AND user_id = ?")
        .bind(workspaceId, targetUserId)
        .first<{ role: string }>();
      if (target?.role === "owner") throw new Error("Cannot remove account owner");
    }
  }

  return workspaceId;
}

async function applyTeamInviteDefaults(
  body: Record<string, unknown>,
  workspaceId: string,
  userId: string
): Promise<void> {
  body.workspace_id = workspaceId;
  if (!body.id) body.id = uuid();
  body.token = await hashToken(typeof body.token === "string" && body.token ? body.token : crypto.randomUUID());
  if (!body.invited_by) body.invited_by = userId;
  if (typeof body.email === "string") body.email = normalizeEmail(body.email);
  if (!body.expires_at) {
    const expires = new Date();
    expires.setDate(expires.getDate() + 7);
    body.expires_at = sqliteTimestamp(expires);
  }
  if (!body.role) body.role = "member";
  assertAssignableTeamRole(body.role);
}

async function prepareAccountMemberInsert(
  env: Env,
  userId: string,
  workspaceIdHeader: string | undefined,
  body: Record<string, unknown>
) {
  const workspaceId = await resolveWorkspaceId(env, userId, workspaceIdHeader, undefined);
  await assertWorkspaceOwner(env, userId, workspaceId);
  body.workspace_id = workspaceId;

  if (typeof body.user_id !== "string" || !body.user_id) {
    throw new Error("user_id is required");
  }
  assertAssignableTeamRole(body.role ?? "member");
  if (!body.role) body.role = "member";

  delete body.id;

  const existing = await db(env)
    .prepare("SELECT 1 FROM workspace_members WHERE workspace_id = ? AND user_id = ?")
    .bind(workspaceId, body.user_id)
    .first();
  if (existing) throw new Error("already_member");

  const seats = await hasSeatAvailable(env, workspaceId);
  if (!seats.available) throw new Error("seat_limit_reached");
}

function createRestApp(options: { publicOnly: boolean }) {
  const app = new Hono<{ Bindings: Env; Variables: AppVariables }>();

  if (!options.publicOnly) {
    app.use("*", requireAuth);
  }

  app.get("/:table", async (c) => {
    try {
      const tbl = getTable(c.req.param("table"));
      if (options.publicOnly && !PUBLIC_REST_TABLES.has(tbl.name)) {
        throw new Error("Forbidden table");
      }

      const q = c.req.query();
      let user = options.publicOnly ? null : c.get("user");
      if (user) {
        user = await syncUserRoleFromDb(c.env, user);
        c.set("user", user);
      }
      const skipRls = user ? skipRlsForRead(user.role, tbl.name) : false;

      if (skipRls && user) {
        await auditAdminRest(c.env, c, "admin.rest.read", tbl.name, {
          filters: Object.keys(q).filter((k) => !GET_RESERVED.has(k)),
          global_rls_bypass: true,
        });
      }

      const { conditions, params } = user
        ? buildFilters(tbl, q, user.id, user.email, { skipRls })
        : buildFilters(tbl, q, "", "", { skipRls: true });

      // Public + non-admin auth: only expose landing-safe settings keys.
      if (tbl.name === "system_settings" && (options.publicOnly || !skipRls)) {
        const placeholders = PUBLIC_SYSTEM_SETTINGS_KEYS.map(() => "?").join(", ");
        conditions.push(`key IN (${placeholders})`);
        params.push(...PUBLIC_SYSTEM_SETTINGS_KEYS);
      }

      let cols = "*";
      if (q.select) {
        const requested = q.select.split(",").map((col) => {
          const trimmed = col.trim();
          assertSafeId(trimmed, "select col");
          if (tbl.hiddenCols.includes(trimmed)) {
            throw new Error(`Column '${trimmed}' is not accessible`);
          }
          return trimmed;
        });
        cols = requested.join(", ");
      }

      let orderClause = "";
      if (q.order) {
        const [col, dir] = q.order.split(".");
        assertSafeId(col, "order col");
        orderClause = `ORDER BY ${col} ${dir === "desc" ? "DESC" : "ASC"}`;
      }

      const where = conditions.length ? `WHERE ${conditions.join(" AND ")}` : "";
      const limit = `LIMIT ${Math.min(Number(q.limit ?? 100), 1000)}`;
      const offset = q.offset ? `OFFSET ${Number(q.offset)}` : "";

      const sql = `SELECT ${cols} FROM ${tbl.name} ${where} ${orderClause} ${limit} ${offset}`.trim();
      const result = await db(c.env).prepare(sql).bind(...params).all();
      let rows = stripHiddenCols(result.results as Record<string, unknown>[], tbl.hiddenCols);
      if (tbl.name === "landing_stats") {
        rows = await applyDerivedLandingStats(c.env, rows);
      }
      return c.json(rows);
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : "Internal server error";
      return c.json({ error: message }, 400);
    }
  });

  if (options.publicOnly) return app;

  app.post("/:table", async (c) => {
    try {
      const tbl = getTable(c.req.param("table"));
      const user = await syncUserRoleFromDb(c.env, c.get("user"));
      c.set("user", user);
      assertWritable(tbl, user.role);

      const body = await c.req.json<Record<string, unknown>>();
      const rawClientKeys = Object.keys(body);
      await assertWritePolicy(c.env, tbl, user.id, c.req.header("X-Workspace-Id"), body, "POST", {});

      if (tbl.name === "team_invites") {
        const workspaceId = await resolveWorkspaceId(
          c.env,
          user.id,
          c.req.header("X-Workspace-Id"),
          undefined
        );
        await assertWorkspaceOwner(c.env, user.id, workspaceId);
        await applyTeamInviteDefaults(body, workspaceId, user.id);
      } else if (tbl.name === "workspace_members") {
        await prepareAccountMemberInsert(c.env, user.id, c.req.header("X-Workspace-Id"), body);
      } else if (tbl.name === "user_connections") {
        // user_id is canonical ownership; user_email remains a NOT NULL shadow
        // column until the final cleanup migration.
        body.user_id = user.id;
        body.user_email = user.email;
      } else if (tbl.rls && tbl.rlsType !== "membership" && tbl.rlsType !== "workspace_scope") {
        body[tbl.rls] = tbl.rlsType === "email" ? user.email : user.id;
      }

      if (
        !body.id &&
        tbl.name !== "landing_stats" &&
        tbl.name !== "system_settings" &&
        tbl.name !== "workspace_members"
      ) {
        body.id = crypto.randomUUID();
      }

      const keys = Object.keys(body);
      keys.forEach((k) => assertSafeId(k, "column"));
      for (const key of keys) {
        if (tbl.hiddenCols.includes(key)) {
          throw new Error(`Column '${key}' cannot be set`);
        }
      }
      if (tbl.name === "users") {
        // id is always server-forced (see RLS injection above) so the post-default
        // `keys` always contains it — this effectively blocks POST to users entirely.
        assertNoImmutableCols(keys, tbl, user.role);
      } else {
        // Check against what the client actually sent, before server defaults/RLS
        // injection ran — those overwrite the same columns unconditionally anyway,
        // so a client value there is inert, not a real "modification".
        const exempt = new Set<string>([tbl.rls ?? "", ...(POST_IMMUTABLE_EXEMPT[tbl.name] ?? [])]);
        assertNoImmutableCols(
          rawClientKeys.filter((k) => !exempt.has(k)),
          tbl,
          user.role
        );
      }

      const skipRls = skipRlsForWrite(user.role, tbl.name);
      if (skipRls) {
        await auditAdminRest(c.env, c, "admin.rest.write", tbl.name, { method: "POST" });
      }

      const sql = `INSERT INTO ${tbl.name} (${keys.join(", ")})
                   VALUES (${keys.map(() => "?").join(", ")}) RETURNING *`;
      const { results } = await db(c.env)
        .prepare(sql)
        .bind(...Object.values(body))
        .all();

      const rows = stripHiddenCols(results as Record<string, unknown>[], tbl.hiddenCols);
      if (wantsRepresentation(c)) return c.json(rows, 201);
      return c.body(null, 201);
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : "Internal server error";
      return c.json({ error: message }, 400);
    }
  });

  app.patch("/:table", async (c) => {
    try {
      const tbl = getTable(c.req.param("table"));
      const user = await syncUserRoleFromDb(c.env, c.get("user"));
      c.set("user", user);
      assertWritable(tbl, user.role);

      const body = await c.req.json<Record<string, unknown>>();
      const query = c.req.query();
      const scopedAccountId = await assertWritePolicy(
        c.env,
        tbl,
        user.id,
        c.req.header("X-Workspace-Id"),
        body,
        "PATCH",
        query
      );

      if (tbl.name === "landing_stats") {
        assertEditableLandingStat(query.stat_key?.replace(/^eq\./, ""));
      }

      const keys = Object.keys(body);
      if (keys.length === 0) throw new Error("Empty update body");
      keys.forEach((k) => assertSafeId(k, "column"));
      assertNoImmutableCols(keys, tbl, user.role);
      if (tbl.rls && keys.includes(tbl.rls)) {
        throw new Error(`Column '${tbl.rls}' cannot be modified`);
      }
      if (
        (tbl.name === "team_invites" || tbl.name === "workspace_members") &&
        keys.includes("role")
      ) {
        assertAssignableTeamRole(body.role);
      }

      if (tbl.name === "users" && keys.includes("role")) {
        const targetId = query.id?.replace(/^eq\./, "");
        if (!targetId) throw new Error("User id filter required for role change");
        await assertUserRoleChange(c.env, user.id, user.role, targetId, body.role);
      }

      const skipRls = skipRlsForWrite(user.role, tbl.name);
      if (skipRls) {
        await auditAdminRest(c.env, c, "admin.rest.write", tbl.name, {
          method: "PATCH",
          filters: Object.keys(query),
        });
      }
      const { conditions, params } = buildFilters(tbl, query, user.id, user.email, {
        requireUserFilters: true,
        skipRls,
        writeWorkspaceId: scopedAccountId,
      });
      const sets = keys.map((k) => `${k} = ?`).join(", ");
      const where = `WHERE ${conditions.join(" AND ")}`;

      if (wantsRepresentation(c)) {
        const { results } = await db(c.env)
          .prepare(`UPDATE ${tbl.name} SET ${sets} ${where} RETURNING *`)
          .bind(...Object.values(body), ...params)
          .all();
        if (tbl.name === "users") {
          const targetId = query.id?.replace(/^eq\./, "") || user.id;
          await auditUserProfilePatch(c.env, c, targetId, body);
        }
        return c.json(stripHiddenCols(results as Record<string, unknown>[], tbl.hiddenCols));
      }

      const { meta } = await db(c.env)
        .prepare(`UPDATE ${tbl.name} SET ${sets} ${where}`)
        .bind(...Object.values(body), ...params)
        .run();
      if (meta.changes === 0) return c.json({ error: "Not found or forbidden" }, 404);
      if (tbl.name === "users") {
        const targetId = query.id?.replace(/^eq\./, "") || user.id;
        await auditUserProfilePatch(c.env, c, targetId, body);
      }
      return c.body(null, 204);
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : "Internal server error";
      return c.json({ error: message }, 400);
    }
  });

  app.patch("/:table/:id", async (c) => {
    try {
      const tbl = getTable(c.req.param("table"));
      const user = await syncUserRoleFromDb(c.env, c.get("user"));
      c.set("user", user);
      assertWritable(tbl, user.role);
      assertNoByIdForCompositePk(tbl);

      const { id } = c.req.param();
      const body = await c.req.json<Record<string, unknown>>();
      const scopedAccountId = await assertWritePolicy(
        c.env,
        tbl,
        user.id,
        c.req.header("X-Workspace-Id"),
        body,
        "PATCH",
        { id: `eq.${id}` }
      );

      const pkCol = tbl.name === "landing_stats" ? "stat_key" : tbl.name === "system_settings" ? "key" : "id";
      if (tbl.name === "landing_stats") {
        assertEditableLandingStat(id);
      }

      const keys = Object.keys(body);
      keys.forEach((k) => assertSafeId(k, "column"));
      assertNoImmutableCols(keys, tbl, user.role);
      if (tbl.rls && keys.includes(tbl.rls)) {
        throw new Error(`Column '${tbl.rls}' cannot be modified`);
      }
      if (tbl.name === "team_invites" && keys.includes("role")) {
        assertAssignableTeamRole(body.role);
      }

      if (tbl.name === "users" && keys.includes("role")) {
        await assertUserRoleChange(c.env, user.id, user.role, id, body.role);
      }

      const sets = keys.map((k) => `${k} = ?`).join(", ");
      const skipRls = skipRlsForWrite(user.role, tbl.name);
      if (skipRls) {
        await auditAdminRest(c.env, c, "admin.rest.write", tbl.name, { method: "PATCH", id });
      }
      const { clause: rlsClause, params: rlsParam } = buildByIdScopeClause(tbl, {
        skipRls,
        userId: user.id,
        userEmail: user.email,
        workspaceId: scopedAccountId ?? c.req.header("X-Workspace-Id") ?? undefined,
      });
      const where = `WHERE ${pkCol} = ? ${rlsClause}`;

      if (wantsRepresentation(c)) {
        const { results } = await db(c.env)
          .prepare(`UPDATE ${tbl.name} SET ${sets} ${where} RETURNING *`)
          .bind(...Object.values(body), id, ...rlsParam)
          .all();
        if (tbl.name === "users") await auditUserProfilePatch(c.env, c, id, body);
        return c.json(stripHiddenCols(results as Record<string, unknown>[], tbl.hiddenCols));
      }

      const { meta } = await db(c.env)
        .prepare(`UPDATE ${tbl.name} SET ${sets} ${where}`)
        .bind(...Object.values(body), id, ...rlsParam)
        .run();
      if (meta.changes === 0) return c.json({ error: "Not found or forbidden" }, 404);
      if (tbl.name === "users") await auditUserProfilePatch(c.env, c, id, body);
      return c.body(null, 204);
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : "Internal server error";
      return c.json({ error: message }, 400);
    }
  });

  app.delete("/:table", async (c) => {
    try {
      const tbl = getTable(c.req.param("table"));
      const user = await syncUserRoleFromDb(c.env, c.get("user"));
      c.set("user", user);
      assertWritable(tbl, user.role);
      assertDeletable(tbl, user.role);

      const query = c.req.query();
      const scopedAccountId = await assertWritePolicy(
        c.env,
        tbl,
        user.id,
        c.req.header("X-Workspace-Id"),
        {},
        "DELETE",
        query
      );

      const skipRls = skipRlsForWrite(user.role, tbl.name);
      if (skipRls) {
        await auditAdminRest(c.env, c, "admin.rest.delete", tbl.name, {
          filters: Object.keys(query),
        });
      }
      const { conditions, params } = buildFilters(tbl, query, user.id, user.email, {
        requireUserFilters: true,
        skipRls,
        writeWorkspaceId: scopedAccountId,
      });

      if (tbl.name === "workspace_members") {
        conditions.push("role != 'owner'");
      }

      const where = `WHERE ${conditions.join(" AND ")}`;
      await db(c.env).prepare(`DELETE FROM ${tbl.name} ${where}`).bind(...params).run();
      return c.body(null, 204);
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : "Internal server error";
      return c.json({ error: message }, 400);
    }
  });

  app.delete("/:table/:id", async (c) => {
    try {
      const tbl = getTable(c.req.param("table"));
      const user = await syncUserRoleFromDb(c.env, c.get("user"));
      c.set("user", user);
      assertWritable(tbl, user.role);
      assertDeletable(tbl, user.role);
      assertNoByIdForCompositePk(tbl);

      const { id } = c.req.param();
      const scopedAccountId = await assertWritePolicy(
        c.env,
        tbl,
        user.id,
        c.req.header("X-Workspace-Id"),
        {},
        "DELETE",
        { id: `eq.${id}` }
      );

      const skipRls = skipRlsForWrite(user.role, tbl.name);
      if (skipRls) {
        await auditAdminRest(c.env, c, "admin.rest.delete", tbl.name, { method: "DELETE", id });
      }
      const { clause: rlsClause, params: rlsParam } = buildByIdScopeClause(tbl, {
        skipRls,
        userId: user.id,
        userEmail: user.email,
        workspaceId: scopedAccountId ?? c.req.header("X-Workspace-Id") ?? undefined,
      });
      const pkCol = tbl.name === "landing_stats" ? "stat_key" : tbl.name === "system_settings" ? "key" : "id";
      const ownerGuard = tbl.name === "workspace_members" ? "AND role != 'owner'" : "";

      // user_connections satırı silinince user_provider_usage/provider_subscriptions/
      // alert_states FK ON DELETE CASCADE ile otomatik temizlenir
      // (0063 migration) — ayrı bir cleanup çağrısına gerek yok.
      await db(c.env)
        .prepare(`DELETE FROM ${tbl.name} WHERE ${pkCol} = ? ${rlsClause} ${ownerGuard}`)
        .bind(id, ...rlsParam)
        .run();

      return c.body(null, 204);
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : "Internal server error";
      return c.json({ error: message }, 400);
    }
  });

  return app;
}

const rest = createRestApp({ publicOnly: false });
export const publicRest = createRestApp({ publicOnly: true });

export default rest;

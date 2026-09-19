import type { Env } from "../env";
import { db, nowIso, uuid } from "../db/client";

export type AuditAction =
  | "profile.update"
  | "key.create"
  | "key.delete"
  | "key.update"
  | "team.invite"
  | "team.invite.revoke"
  | "team.member.role"
  | "team.member.remove"
  | "team.member.note"
  | "team.transfer"
  | "team.limits.update"
  | "provider.limits.update"
  | "auth.login"
  | "auth.logout"
  | "auth.register"
  | "auth.password_reset"
  | "auth.password_change"
  | "auth.qr.confirm"
  | "auth.qr.login"
  | "admin.rest.read"
  | "admin.rest.write"
  | "admin.rest.delete"
  | "admin.user_status.update"
  | "device.terminate"
  | "account.switch"
  | "invite.accept"
  | "user.role"
  | "legal.consent"
  | "legal.withdraw"
  | "legal.data_request";

const SENSITIVE_KEY_RE =
  /password|passwd|secret|token|api[_-]?key|key[_-]?value|authorization|credential|refresh|bearer/i;

export type AuditEventRow = {
  id: string;
  workspace_id: string | null;
  actor_user_id: string;
  actor_email: string | null;
  action: AuditAction | string;
  entity_type: string;
  entity_id: string | null;
  metadata_json: string | null;
  ip: string | null;
  user_agent: string | null;
  created_at: string;
};

export type RecordAuditOpts = {
  actorUserId: string;
  actorEmail?: string | null;
  action: AuditAction | string;
  entityType: string;
  workspaceId?: string | null;
  entityId?: string | null;
  metadata?: Record<string, unknown> | null;
  ip?: string | null;
  userAgent?: string | null;
};

export type ListAuditEventsOpts = {
  workspaceId?: string;
  actorUserId?: string;
  action?: string;
  entityType?: string;
  from?: string;
  to?: string;
  limit?: number;
  offset?: number;
};

function normalizeDateFrom(value: string): string {
  const v = value.trim();
  if (/^\d{4}-\d{2}-\d{2}$/.test(v)) return `${v}T00:00:00`;
  return v;
}

function normalizeDateTo(value: string): string {
  const v = value.trim();
  if (/^\d{4}-\d{2}-\d{2}$/.test(v)) return `${v}T23:59:59`;
  return v;
}

export function clientIpFromRequest(req: {
  header: (name: string) => string | undefined;
}): string {
  return (
    req.header("cf-connecting-ip") ||
    req.header("CF-Connecting-IP") ||
    req.header("x-forwarded-for")?.split(",")[0]?.trim() ||
    ""
  );
}

function maskSecret(value: string): string {
  const v = value.trim();
  return v.length <= 4 ? "••••" : "••••" + v.slice(-4);
}

export function sanitizeMetadata(input: unknown): unknown {
  if (input == null) return input;
  if (Array.isArray(input)) return input.map(sanitizeMetadata);
  if (typeof input === "object") {
    const out: Record<string, unknown> = {};
    for (const [k, v] of Object.entries(input as Record<string, unknown>)) {
      if (SENSITIVE_KEY_RE.test(k)) {
        out[k] = typeof v === "string" ? maskSecret(v) : "[redacted]";
      } else {
        out[k] = sanitizeMetadata(v);
      }
    }
    return out;
  }
  return input;
}

function metadataToJson(metadata?: Record<string, unknown> | null): string | null {
  if (!metadata || Object.keys(metadata).length === 0) return null;
  const sanitized = sanitizeMetadata(metadata);
  return JSON.stringify(sanitized);
}

export async function recordAudit(env: Env, opts: RecordAuditOpts): Promise<string> {
  const id = uuid();
  try {
    await db(env)
      .prepare(
        `INSERT INTO audit_events (
           id, workspace_id, actor_user_id, actor_email, action, entity_type,
           entity_id, metadata_json, ip, user_agent, created_at
         ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`
      )
      .bind(
        id,
        opts.workspaceId ?? null,
        opts.actorUserId,
        opts.actorEmail ?? null,
        opts.action,
        opts.entityType,
        opts.entityId ?? null,
        metadataToJson(opts.metadata),
        opts.ip ?? null,
        opts.userAgent ?? null,
        nowIso()
      )
      .run();
  } catch (err) {
    console.error("audit record failed", err instanceof Error ? err.message : err);
  }
  return id;
}

export async function listAuditEvents(
  env: Env,
  opts: ListAuditEventsOpts
): Promise<{ events: AuditEventRow[]; total: number }> {
  const conditions: string[] = [];
  const binds: unknown[] = [];

  if (opts.workspaceId) {
    conditions.push("workspace_id = ?");
    binds.push(opts.workspaceId);
  }
  if (opts.actorUserId) {
    conditions.push("actor_user_id = ?");
    binds.push(opts.actorUserId);
  }
  if (opts.action) {
    conditions.push("action = ?");
    binds.push(opts.action);
  }
  if (opts.entityType) {
    conditions.push("entity_type = ?");
    binds.push(opts.entityType);
  }
  if (opts.from) {
    conditions.push("created_at >= ?");
    binds.push(normalizeDateFrom(opts.from));
  }
  if (opts.to) {
    conditions.push("created_at <= ?");
    binds.push(normalizeDateTo(opts.to));
  }

  const where = conditions.length ? `WHERE ${conditions.join(" AND ")}` : "";
  const limit = Math.min(Math.max(opts.limit ?? 50, 1), 200);
  const offset = Math.max(opts.offset ?? 0, 0);

  const countRow = await db(env)
    .prepare(`SELECT COUNT(*) AS n FROM audit_events ${where}`)
    .bind(...binds)
    .first<{ n: number }>();

  const { results } = await db(env)
    .prepare(
      `SELECT id, workspace_id, actor_user_id, actor_email, action, entity_type,
              entity_id, metadata_json, ip, user_agent, created_at
         FROM audit_events
         ${where}
        ORDER BY created_at DESC
        LIMIT ? OFFSET ?`
    )
    .bind(...binds, limit, offset)
    .all<AuditEventRow>();

  return { events: results || [], total: countRow?.n ?? 0 };
}

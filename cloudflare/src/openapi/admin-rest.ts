import { createRoute, z, type OpenAPIHono } from "@hono/zod-openapi";
import type { Env, AppVariables } from "../env";
import { accountHeader, authedSecurity } from "./schemas";

type Stub = () => (c: unknown) => Response;

const REST_TABLES = [
  "users",
  "user_connections",
  "user_devices",
  "billing_orders",
  "providers",
  "system_settings",
  "landing_stats",
  "workspaces",
  "workspace_members",
  "team_invites",
] as const;

const PUBLIC_REST_TABLES = ["providers", "landing_stats", "system_settings"] as const;

export function registerAdminAuditPublicOpenApi(
  app: OpenAPIHono<{ Bindings: Env; Variables: AppVariables }>,
  stub: Stub
) {
  const routes = [
    createRoute({
      method: "get",
      path: "/api/admin/stats",
      tags: ["Admin"],
      security: authedSecurity,
      responses: { 200: { description: "Platform admin statistics" } },
    }),
    createRoute({
      method: "patch",
      path: "/api/admin/users/{id}/status",
      tags: ["Admin"],
      security: authedSecurity,
      request: {
        params: z.object({ id: z.string() }),
        body: {
          content: {
            "application/json": {
              schema: z.object({ status: z.enum(["active", "inactive"]) }),
            },
          },
        },
      },
      responses: { 200: { description: "User status updated" }, 400: { description: "Invalid status change" } },
    }),
    createRoute({
      method: "get",
      path: "/api/audit",
      tags: ["Audit"],
      security: authedSecurity,
      request: {
        headers: accountHeader,
        query: z.object({
          workspace_id: z.string().optional(),
          actor_user_id: z.string().optional(),
          action: z.string().optional(),
          limit: z.string().optional(),
          offset: z.string().optional(),
        }),
      },
      responses: { 200: { description: "Audit events" } },
    }),
    createRoute({
      method: "get",
      path: "/api/app-links",
      tags: ["Public"],
      responses: { 200: { description: "Mobile/desktop download links" } },
    }),
  ];

  for (const route of routes) {
    app.openapi(route, stub() as never);
  }
}

export function registerRestOpenApi(
  app: OpenAPIHono<{ Bindings: Env; Variables: AppVariables }>,
  stub: Stub
) {
  const tableDoc = z
    .enum(REST_TABLES)
    .openapi({ description: `Whitelisted tables: ${REST_TABLES.join(", ")}` });

  const routes = [
    createRoute({
      method: "get",
      path: "/api/rest/{table}",
      tags: ["AdminREST"],
      summary: "PostgREST-style list/filter",
      description:
        "Query filters: `column=eq.value`, `select=col1,col2`, `order=col.desc`, `limit`, `offset`. RLS enforced per user.",
      security: authedSecurity,
      request: {
        params: z.object({ table: tableDoc }),
      },
      responses: { 200: { description: "Row array" } },
    }),
    createRoute({
      method: "patch",
      path: "/api/rest/{table}",
      tags: ["AdminREST"],
      security: authedSecurity,
      request: {
        params: z.object({ table: tableDoc }),
        body: { content: { "application/json": { schema: z.record(z.unknown()) } } },
      },
      responses: { 200: { description: "Updated rows" } },
    }),
    createRoute({
      method: "get",
      path: "/api/public-rest/{table}",
      tags: ["AdminREST"],
      summary: "Public read-only REST",
      description: `Tables: ${PUBLIC_REST_TABLES.join(", ")}`,
      request: {
        params: z.object({ table: z.enum(PUBLIC_REST_TABLES) }),
      },
      responses: { 200: { description: "Row array" } },
    }),
  ];

  for (const route of routes) {
    app.openapi(route, stub() as never);
  }
}

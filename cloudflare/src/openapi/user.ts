import { createRoute, z, type OpenAPIHono } from "@hono/zod-openapi";
import type { Env, AppVariables } from "../env";
import { accountHeader, authedSecurity, errorSchema } from "./schemas";

type Stub = () => (c: unknown) => Response;

export function registerUserOpenApi(
  app: OpenAPIHono<{ Bindings: Env; Variables: AppVariables }>,
  stub: Stub
) {
  const routes = [
    createRoute({
      method: "get",
      path: "/api/user/profile",
      tags: ["User"],
      summary: "Current user profile",
      security: authedSecurity,
      request: { headers: accountHeader },
      responses: {
        200: { description: "Profile", content: { "application/json": { schema: z.record(z.unknown()) } } },
        404: { description: "Not found", content: { "application/json": { schema: errorSchema } } },
      },
    }),
    createRoute({
      method: "get",
      path: "/api/user/usage",
      tags: ["User"],
      summary: "Provider usage dashboard",
      security: authedSecurity,
      request: {
        headers: accountHeader,
        query: z.object({
          email: z.string().email().optional(),
          provider: z.string().optional(),
          refresh: z.enum(["0", "1", "true", "false"]).optional(),
          skip_refresh: z.enum(["0", "1", "true", "false"]).optional(),
        }),
      },
      responses: { 200: { description: "Usage payload", content: { "application/json": { schema: z.record(z.unknown()) } } } },
    }),
    createRoute({
      method: "get",
      path: "/api/user/usage/spend-trend",
      tags: ["User"],
      security: authedSecurity,
      request: {
        headers: accountHeader,
        query: z.object({ granularity: z.enum(["day", "week", "month"]).optional() }),
      },
      responses: { 200: { description: "Spend trend series" } },
    }),
    createRoute({
      method: "get",
      path: "/api/user/workspaces",
      tags: ["User"],
      summary: "List workspaces",
      security: authedSecurity,
      responses: { 200: { description: "Workspace memberships" } },
    }),
    createRoute({
      method: "post",
      path: "/api/user/workspaces/switch",
      tags: ["User"],
      security: authedSecurity,
      request: {
        body: {
          content: {
            "application/json": {
              schema: z.object({
                workspace_id: z.string().uuid().optional(),
                account_id: z.string().uuid().optional(),
              }),
            },
          },
        },
      },
      responses: { 200: { description: "Switched active workspace" } },
    }),
    createRoute({
      method: "post",
      path: "/api/user/sessions/register",
      tags: ["User", "Sessions"],
      security: authedSecurity,
      request: {
        body: {
          content: {
            "application/json": {
              schema: z.object({
                device_name: z.string().optional(),
                platform: z.string().optional(),
              }),
            },
          },
        },
      },
      responses: { 200: { description: "Device session registered" } },
    }),
    createRoute({
      method: "post",
      path: "/api/user/sessions/heartbeat",
      tags: ["User", "Sessions"],
      security: authedSecurity,
      responses: { 200: { description: "Heartbeat ok" } },
    }),
    createRoute({
      method: "post",
      path: "/api/user/device-token",
      tags: ["User", "FCM"],
      security: authedSecurity,
      request: {
        body: {
          content: {
            "application/json": {
              schema: z.object({ token: z.string(), platform: z.string().optional() }),
            },
          },
        },
      },
      responses: { 200: { description: "FCM token stored" } },
    }),
    createRoute({
      method: "delete",
      path: "/api/user/device-token",
      tags: ["User", "FCM"],
      summary: "Withdraw and remove an FCM device token",
      security: authedSecurity,
      request: {
        body: {
          content: {
            "application/json": {
              schema: z.object({ token: z.string() }),
            },
          },
        },
      },
      responses: { 200: { description: "FCM token removed" } },
    }),
    createRoute({
      method: "get",
      path: "/api/user/data-export",
      tags: ["User"],
      summary: "Export the authenticated user's portable account data",
      security: authedSecurity,
      responses: {
        200: { description: "Portable account data", content: { "application/json": { schema: z.record(z.unknown()) } } },
      },
    }),
    createRoute({
      method: "delete",
      path: "/api/user/delete-account",
      tags: ["User"],
      summary: "Delete authenticated user's account and all owned data",
      security: authedSecurity,
      responses: {
        200: { description: "Account deleted", content: { "application/json": { schema: z.object({ ok: z.boolean() }) } } },
      },
    }),
    createRoute({
      method: "get",
      path: "/api/user/notifications/poll",
      tags: ["User", "Notifications"],
      security: authedSecurity,
      request: { query: z.object({ since: z.string().optional() }) },
      responses: { 200: { description: "Notification events" } },
    }),
  ];

  for (const route of routes) {
    app.openapi(route, stub() as never);
  }
}

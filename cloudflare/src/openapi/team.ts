import { createRoute, z, type OpenAPIHono } from "@hono/zod-openapi";
import type { Env, AppVariables } from "../env";
import { accountHeader, authedSecurity } from "./schemas";

type Stub = () => (c: unknown) => Response;

export function registerTeamOpenApi(
  app: OpenAPIHono<{ Bindings: Env; Variables: AppVariables }>,
  stub: Stub
) {
  const routes = [
    createRoute({
      method: "get",
      path: "/api/team/members",
      tags: ["Team"],
      security: authedSecurity,
      request: { headers: accountHeader },
      responses: { 200: { description: "Team members with usage summary" } },
    }),
    createRoute({
      method: "get",
      path: "/api/team/invites",
      tags: ["Team"],
      security: authedSecurity,
      request: { headers: accountHeader },
      responses: { 200: { description: "Pending invites" } },
    }),
    createRoute({
      method: "post",
      path: "/api/team/invites",
      tags: ["Team"],
      security: authedSecurity,
      request: {
        headers: accountHeader,
        body: {
          content: {
            "application/json": {
              schema: z.object({
                email: z.string().email(),
                role: z.enum(["admin", "assistant", "member"]).optional(),
              }),
            },
          },
        },
      },
      responses: { 200: { description: "Invite created" } },
    }),
    createRoute({
      method: "post",
      path: "/api/team/accept-invite",
      tags: ["Team"],
      summary: "Accept invite (public, token in body)",
      request: {
        body: {
          content: {
            "application/json": {
              schema: z.object({
                email: z.string().email(),
                token: z.string(),
              }),
            },
          },
        },
      },
      responses: { 200: { description: "Joined team" } },
    }),
    createRoute({
      method: "get",
      path: "/api/team/usage/logs",
      tags: ["Team"],
      security: authedSecurity,
      request: {
        headers: accountHeader,
        query: z.object({
          limit: z.string().optional(),
          offset: z.string().optional(),
          user_id: z.string().optional(),
          provider_id: z.string().optional(),
        }),
      },
      responses: { 200: { description: "Usage history rows" } },
    }),
    createRoute({
      method: "get",
      path: "/api/team/settings",
      tags: ["Team"],
      security: authedSecurity,
      request: { headers: accountHeader },
      responses: { 200: { description: "Team settings" } },
    }),
    createRoute({
      method: "get",
      path: "/api/team/shared-keys",
      tags: ["Team"],
      security: authedSecurity,
      request: { headers: accountHeader },
      responses: { 200: { description: "Shared provider keys" } },
    }),
  ];

  for (const route of routes) {
    app.openapi(route, stub() as never);
  }
}

import { createRoute, z, type OpenAPIHono } from "@hono/zod-openapi";
import type { Env, AppVariables } from "../env";
import { accountHeader, authedSecurity } from "./schemas";

type Stub = () => (c: unknown) => Response;

export function registerProviderOpenApi(
  app: OpenAPIHono<{ Bindings: Env; Variables: AppVariables }>,
  stub: Stub
) {
  const routes = [
    createRoute({
      method: "get",
      path: "/api/provider/connected",
      tags: ["Provider"],
      security: authedSecurity,
      request: { headers: accountHeader },
      responses: { 200: { description: "Connected providers with usage" } },
    }),
    createRoute({
      method: "post",
      path: "/api/provider/connect",
      tags: ["Provider"],
      security: authedSecurity,
      request: {
        headers: accountHeader,
        body: {
          content: {
            "application/json": {
              schema: z.object({
                provider_id: z.string(),
                key_value: z.string(),
                scope: z.enum(["personal", "account"]).optional(),
              }),
            },
          },
        },
      },
      responses: { 200: { description: "Provider connected" } },
    }),
    createRoute({
      method: "post",
      path: "/api/provider/disconnect",
      tags: ["Provider"],
      security: authedSecurity,
      request: {
        headers: accountHeader,
        body: {
          content: {
            "application/json": {
              schema: z.object({ connection_id: z.string().min(1), email: z.string().email().optional() }),
            },
          },
        },
      },
      responses: { 200: { description: "Disconnected" } },
    }),
    createRoute({
      method: "post",
      path: "/api/provider/fetch-usage",
      tags: ["Provider"],
      summary: "Refresh usage from upstream APIs",
      security: authedSecurity,
      request: {
        headers: accountHeader,
        body: {
          content: {
            "application/json": {
              schema: z.object({ provider_ids: z.array(z.string()).optional() }),
            },
          },
        },
      },
      responses: { 200: { description: "Fetch results" } },
    }),
    createRoute({
      method: "post",
      path: "/api/provider/oauth/start",
      tags: ["Provider"],
      security: authedSecurity,
      request: {
        headers: accountHeader,
        body: { content: { "application/json": { schema: z.object({ provider_id: z.string() }) } } },
      },
      responses: { 200: { description: "OAuth session started" } },
    }),
    createRoute({
      method: "get",
      path: "/api/provider/oauth/status",
      tags: ["Provider"],
      security: authedSecurity,
      request: { query: z.object({ provider_id: z.string() }) },
      responses: { 200: { description: "OAuth session status" } },
    }),
    createRoute({
      method: "post",
      path: "/api/scrape/browser/create",
      tags: ["Scrape"],
      security: authedSecurity,
      responses: { 200: { description: "Browser scrape session" } },
    }),
  ];

  for (const route of routes) {
    app.openapi(route, stub() as never);
  }
}

export function registerAitrackOpenApi(
  app: OpenAPIHono<{ Bindings: Env; Variables: AppVariables }>,
  stub: Stub
) {
  const routes = [
    createRoute({
      method: "get",
      path: "/aitrack/plans",
      tags: ["Aitrack"],
      summary: "Token plans (public)",
      responses: { 200: { description: "Plans with USD/TRY rates" } },
    }),
    createRoute({
      method: "post",
      path: "/aitrack/usage",
      tags: ["Aitrack"],
      summary: "Push usage from mobile/desktop",
      security: authedSecurity,
      request: {
        body: {
          content: {
            "application/json": {
              schema: z.object({
                user_id: z.string(),
                platform: z.string(),
                used_percent: z.number().nullable().optional(),
                windows: z.array(z.record(z.unknown())).optional(),
              }),
            },
          },
        },
      },
      responses: { 200: { description: "Usage recorded" } },
    }),
    createRoute({
      method: "get",
      path: "/aitrack/billing/rates",
      tags: ["Aitrack", "Billing"],
      responses: { 200: { description: "USD/TRY rates" } },
    }),
    createRoute({
      method: "post",
      path: "/aitrack/billing/checkout",
      tags: ["Aitrack", "Billing"],
      security: authedSecurity,
      request: {
        body: {
          content: {
            "application/json": {
              schema: z.object({
                plan_slug: z.string(),
                email: z.string().email(),
                name: z.string().min(1),
                phone: z.string().min(3),
                address: z.string().min(1),
                terms_version: z.string().min(1).max(32),
                precontract_version: z.string().min(1).max(32),
                distance_sales_version: z.string().min(1).max(32),
                refund_version: z.string().min(1).max(32),
                subscription_version: z.string().min(1).max(32),
                immediate_performance_requested: z.boolean(),
                accepted_locale: z.string().min(2).max(10),
              }),
            },
          },
        },
      },
      responses: { 200: { description: "PayTR checkout token" }, 409: { description: "Legal acceptance required" } },
    }),
    createRoute({
      method: "post",
      path: "/aitrack/billing/upgrade",
      tags: ["Aitrack", "Billing"],
      security: authedSecurity,
      request: {
        body: {
          content: {
            "application/json": {
              schema: z.object({
                plan_slug: z.string(),
                email: z.string().email(),
                terms_version: z.string().min(1).max(32),
                subscription_version: z.string().min(1).max(32),
                accepted_locale: z.string().min(2).max(10),
                name: z.string().min(1).optional(),
                phone: z.string().min(3).optional(),
                address: z.string().min(1).optional(),
                precontract_version: z.string().min(1).max(32).optional(),
                distance_sales_version: z.string().min(1).max(32).optional(),
                refund_version: z.string().min(1).max(32).optional(),
                immediate_performance_requested: z.boolean().optional(),
              }),
            },
          },
        },
      },
      responses: { 200: { description: "Plan upgrade checkout" }, 409: { description: "Legal acceptance required" } },
    }),
  ];

  for (const route of routes) {
    app.openapi(route, stub() as never);
  }
}

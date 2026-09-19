import { createRoute, z, type OpenAPIHono } from "@hono/zod-openapi";
import type { Env, AppVariables } from "../env";
import { accountHeader, authedSecurity, errorSchema } from "./schemas";

type Stub = () => (c: unknown) => Response;

export function registerBillingOpenApi(
  app: OpenAPIHono<{ Bindings: Env; Variables: AppVariables }>,
  stub: Stub
) {
  const routes = [
    createRoute({
      method: "post",
      path: "/api/billing/apple/verify",
      tags: ["Billing"],
      summary: "Fulfill a StoreKit2 in-app purchase",
      security: authedSecurity,
      request: {
        headers: accountHeader,
        body: {
          content: {
            "application/json": {
              schema: z.object({
                transactionId: z.string(),
                originalTransactionId: z.string().optional(),
                productId: z.string().optional(),
                planId: z.string().optional(),
                termsVersion: z.string(),
                privacyNoticeVersion: z.string(),
                subscriptionVersion: z.string(),
                refundVersion: z.string(),
                immediatePerformanceRequested: z.boolean(),
                locale: z.string().min(2).max(10),
              }),
            },
          },
        },
      },
      responses: {
        200: {
          description: "Plan applied",
          content: {
            "application/json": {
              schema: z.object({
                ok: z.boolean(),
                plan_slug: z.string(),
                kind: z.string(),
                cycle: z.string().nullable(),
                extra_seats: z.number(),
                max_seats: z.number(),
                store_expires_at: z.string(),
              }),
            },
          },
        },
        404: { description: "Workspace not found", content: { "application/json": { schema: errorSchema } } },
      },
    }),
    createRoute({
      method: "post",
      path: "/api/billing/google/verify",
      tags: ["Billing"],
      summary: "Fulfill a Google Play Billing purchase",
      security: authedSecurity,
      request: {
        headers: accountHeader,
        body: {
          content: {
            "application/json": {
              schema: z.object({
                purchaseToken: z.string(),
                productId: z.string().optional(),
                planId: z.string().optional(),
                termsVersion: z.string(),
                privacyNoticeVersion: z.string(),
                subscriptionVersion: z.string(),
                refundVersion: z.string(),
                immediatePerformanceRequested: z.boolean(),
                locale: z.string().min(2).max(10),
              }),
            },
          },
        },
      },
      responses: {
        200: {
          description: "Plan applied",
          content: {
            "application/json": {
              schema: z.object({
                ok: z.boolean(),
                plan_slug: z.string(),
                kind: z.string(),
                cycle: z.string().nullable(),
                extra_seats: z.number(),
                max_seats: z.number(),
                store_expires_at: z.string(),
              }),
            },
          },
        },
        404: { description: "Workspace not found", content: { "application/json": { schema: errorSchema } } },
      },
    }),
    createRoute({
      method: "post",
      path: "/api/billing/subscription-cancellation-requests",
      tags: ["Billing"],
      summary: "Create an authenticated subscription cancellation or refund request",
      security: authedSecurity,
      request: {
        headers: accountHeader,
        body: {
          content: {
            "application/json": {
              schema: z.object({
                requested_effect: z.enum(["end_of_period", "immediate"]),
                refund_requested: z.boolean().optional(),
                details: z.string().max(2000).optional(),
                locale: z.string().optional(),
              }),
            },
          },
        },
      },
      responses: {
        201: {
          description: "Request recorded",
          content: {
            "application/json": {
              schema: z.object({
                ok: z.boolean(),
                request: z.object({
                  id: z.string(),
                  status: z.string(),
                  processing_due_at: z.string(),
                  refund_due_at: z.string().nullable(),
                }),
              }),
            },
          },
        },
        403: { description: "Workspace owner required", content: { "application/json": { schema: errorSchema } } },
        409: { description: "No paid plan or an active request already exists", content: { "application/json": { schema: errorSchema } } },
      },
    }),
    createRoute({
      method: "get",
      path: "/api/billing/subscription-cancellation-requests",
      tags: ["Billing"],
      summary: "List the authenticated user's subscription cancellation requests",
      security: authedSecurity,
      request: { headers: accountHeader },
      responses: {
        200: {
          description: "Cancellation requests",
          content: {
            "application/json": {
              schema: z.object({ requests: z.array(z.object({ id: z.string(), status: z.string(), processing_due_at: z.string() })) }),
            },
          },
        },
      },
    }),
  ];

  for (const route of routes) {
    app.openapi(route, stub() as never);
  }
}

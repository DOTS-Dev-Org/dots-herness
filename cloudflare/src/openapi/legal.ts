import { createRoute, z, type OpenAPIHono } from "@hono/zod-openapi";
import type { Env, AppVariables } from "../env";
import { authedSecurity, errorSchema } from "./schemas";
import { LEGAL_SUPPORTED_LOCALES } from "../lib/legal";

type Stub = () => (c: unknown) => Response;

const legalConsentSchema = z.object({
  anonymous_id: z.string().uuid().optional(),
  purpose: z.string().min(1).max(80),
  action: z.enum(["accepted", "acknowledged", "granted", "denied", "withdrawn"]),
  document_key: z.enum([
    "terms",
    "privacy_notice",
    "explicit_consent",
    "cookies",
    "precontract",
    "distance_sales",
    "refund",
    "subscription",
  ]),
  document_version: z.string().min(1).max(32),
  locale: z.string().min(2).max(10).optional(),
  source: z.string().min(1).max(40).optional(),
});

const legalDataRequestSchema = z.object({
  request_type: z.enum(["access", "correction", "deletion", "objection", "transfer", "other"]),
  details: z.string().min(1).max(5000),
  locale: z.string().min(2).max(10).optional(),
});

export function registerLegalOpenApi(
  app: OpenAPIHono<{ Bindings: Env; Variables: AppVariables }>,
  stub: Stub,
) {
  const routes = [
    createRoute({
      method: "get",
      path: "/api/legal/documents",
      tags: ["Legal"],
      summary: "Read the versioned public legal documents for one locale",
      description:
        "Returns the Terms and Privacy Notice only when both D1 rows and their R2 objects exist, are approved/published, and have matching SHA-256 hashes. Missing translations are errors; the endpoint never falls back to Turkish.",
      request: {
        query: z.object({
          locale: z.enum(LEGAL_SUPPORTED_LOCALES),
          version: z.string().min(1).max(32).optional(),
        }),
      },
      responses: {
        200: {
          description: "Legal Markdown and immutable R2 URLs",
          content: {
            "application/json": {
              schema: z.object({
                app_slug: z.literal("dots-herness"),
                locale: z.string(),
                version: z.string(),
                documents: z.object({
                  terms: z.object({
                    markdown: z.string(),
                    sha256: z.string().length(64),
                    r2_key: z.string(),
                    r2_url: z.string().url(),
                    translation_status: z.enum(["draft", "approved", "published"]),
                    source_locale: z.string(),
                  }),
                  privacy_notice: z.object({
                    markdown: z.string(),
                    sha256: z.string().length(64),
                    r2_key: z.string(),
                    r2_url: z.string().url(),
                    translation_status: z.enum(["draft", "approved", "published"]),
                    source_locale: z.string(),
                  }),
                }),
              }),
            },
          },
        },
        400: { description: "Unsupported locale", content: { "application/json": { schema: errorSchema } } },
        404: { description: "Locale or version is not seeded", content: { "application/json": { schema: errorSchema } } },
        409: { description: "Translation is awaiting legal review", content: { "application/json": { schema: errorSchema } } },
        503: { description: "D1/R2 integrity or availability error", content: { "application/json": { schema: errorSchema } } },
      },
    }),
    createRoute({
      method: "post",
      path: "/api/legal/consents",
      tags: ["Legal"],
      summary: "Record a cookie or authenticated legal-consent event",
      description:
        "Anonymous cookie events use anonymous_id. Account legal acceptance and explicit consent events use the authenticated session; stale or invalid document/purpose combinations are rejected.",
      request: {
        body: {
          content: { "application/json": { schema: legalConsentSchema } },
        },
      },
      responses: {
        201: {
          description: "Consent event recorded",
          content: { "application/json": { schema: z.object({ ok: z.boolean(), id: z.string() }) } },
        },
        400: { description: "Invalid consent event", content: { "application/json": { schema: errorSchema } } },
        409: { description: "Stale legal document", content: { "application/json": { schema: errorSchema } } },
      },
    }),
    createRoute({
      method: "get",
      path: "/api/legal/consents",
      tags: ["Legal"],
      summary: "List the authenticated user's legal-consent history",
      security: authedSecurity,
      responses: {
        200: {
          description: "Consent history",
          content: { "application/json": { schema: z.object({ consents: z.array(z.record(z.unknown())) }) } },
        },
        401: { description: "Unauthorized", content: { "application/json": { schema: errorSchema } } },
      },
    }),
    createRoute({
      method: "post",
      path: "/api/legal/data-requests",
      tags: ["Legal"],
      summary: "Create an authenticated KVKK data-subject request",
      description:
        "The request is durably recorded with a receipt time and a 30-day response due date. Identity verification and the reasoned response are handled through the legal operations workflow.",
      security: authedSecurity,
      request: {
        body: {
          content: { "application/json": { schema: legalDataRequestSchema } },
        },
      },
      responses: {
        201: {
          description: "KVKK request recorded",
          content: {
            "application/json": {
              schema: z.object({
                ok: z.boolean(),
                request: z.object({
                  id: z.string(),
                  request_type: z.string(),
                  status: z.string(),
                  identity_status: z.string(),
                  received_at: z.string(),
                  due_at: z.string(),
                }),
              }),
            },
          },
        },
        401: { description: "Unauthorized", content: { "application/json": { schema: errorSchema } } },
      },
    }),
    createRoute({
      method: "get",
      path: "/api/legal/data-requests",
      tags: ["Legal"],
      summary: "List the authenticated user's KVKK requests",
      security: authedSecurity,
      responses: {
        200: {
          description: "KVKK requests",
          content: { "application/json": { schema: z.object({ requests: z.array(z.record(z.unknown())) }) } },
        },
        401: { description: "Unauthorized", content: { "application/json": { schema: errorSchema } } },
      },
    }),
  ];

  for (const route of routes) {
    app.openapi(route, stub() as never);
  }
}
